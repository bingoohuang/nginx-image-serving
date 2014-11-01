local _M = {
    _VERSION = '0.1'
}

local function error(config, msg, httpCode, err)
    if config then config.redis:del(config.prefix .. config.mobile) end

    ngx.status = httpCode
    ngx.say(msg, err or "")
    ngx.log(ngx.ERR, msg)
    ngx.exit(httpCode)
end

local function connectRedis (config)
    local redis = require "resty.redis"
    local red = redis:new()
    red:set_timeout(config.redisTimeout or 1000) -- 1 second
    local ok, err = red:connect(config.redisHost, config.redisPort)
    if not ok then
        error(nil, "connecting redis", 500, err)
    end

    config.redis = red
end

local function connectMySQL (config)
    local mysql = require "resty.mysql"
    local db, err = mysql:new()
    if not db then
        error(config, "failed to instantiate mysql", 500, err)
    end

    db:set_timeout(config.mysqlTimeout or 1000) -- 1 second

    local ok, err, errno, sqlstate = db:connect{
        host = config.mysqlHost,
        port = config.mysqlPort,
        database = config.mysqlDb,
        user = config.mysqlUser,
        password = config.mysqlPass,
        max_packet_size = 1024 * 1024 }

    if not ok then
        error(config, "failed to connect mysql", 500, err)
    end

    config.mysql = db
end

local function checkExistence (config)
    local count = config.redis:incr(config.prefix .. config.mobile)

    if tonumber(count) > 1 then
        error(config, config.mobile .. " is already in second killing, please try later", 400)
    end

    local sql = "select price from miao where mobile = " .. config.mobile
    local res, err, errno, sqlstate = config.mysql:query(sql)
    if not res then
        error(config, "bad result: ", 500, err .. ": " .. errno .. ": " .. sqlstate .. ".", 400)
    end
    if res[1] then
        error(config, config.mobile .. " have got a favored price " .. res[1].price, 400);
    end
end

local function checkCurrentPrice(config)
    -- 检查是否超过允许价格
    local expectedPrice = config.redis:get(config.prefix .. "currentPrice")
    if expectedPrice == ngx.null then expectedPrice = 1 end

    if config.price ~= tonumber(expectedPrice) then
        error(config, "bad price " .. config.price .. " request expected " .. expectedPrice, 400)
    end

    local count, err = config.redis:incr(config.prefix .. config.price)
    if tonumber(count) > config.levelNum then
        error(config, "sold out for current price", 400)
    end
end

local function checkPriceRange(config)
    if config.price < 1 or config.price > 60 then
        error(nil, "bad price range value:" .. config.price, 400)
    end
end

local function updatePrice(config)
    local countStr, err = config.redis:incr(config.prefix .. "bought")
    local count = tonumber(countStr)
    if count % config.levelNum == 0 then
        config.redis:set(config.prefix .. "currentPrice", count / config.levelNum + 1)
    end
end

local function saveRecordToMysql(config)
    local sql = "insert into miao (mobile, price, ts) "
             .. "values (".. config.mobile .. ", ".. config.price .. ", now())"
    local res, err, errno, sqlstate = config.mysql:query(sql)
    if not res then
        error(config, "bad result: ", 500, err)
    end
end

local function checkFormat (name, value, format)
    if not value then
        error(nil, name .. " required", 400)
    end

    local valueStr = string.match(value, format)
    if not valueStr then
        error(nil, name .. " in bad format", 400)
    end

    return value
end

local function cleanUp(config)
    config.redis:del(config.prefix .. config.mobile)

    -- put it into the connection pool of size 100,
    -- with 10 seconds max idle timeout
    config.redis:set_keepalive(config.redisMaxIdleTimeout or 10000, config.redisPoolSize or 10)
    config.mysql:set_keepalive(config.mysqlMaxIdleTimeout or 10000, config.mysqlPoolSize or 10)
end

local function seckilling(config)
    checkPriceRange(config)

    connectRedis(config)
    connectMySQL(config)

    checkExistence(config)
    checkCurrentPrice(config)
    updatePrice(config)

    saveRecordToMysql(config)
end


function _M.seckill (option)
    local config = {
        prefix = option.prefix or "seckill:",
        mobile = checkFormat("mobile", option.mobile, "^1%d%d%d%d%d%d%d%d%d%d$"),
        price = tonumber(checkFormat("price", option.price, "^[1-6]?[0-9]$")),
        levelNum = option.levelNum or 100000,

        redisHost = "127.0.0.1",
        redisPort = 6379,
        redisTimeout = 3000, -- 3s
        redisMaxIdleTimeout = 10000, -- 10s
        redisPoolSize = 20,
        redis = nil,

        mysqlHost = "127.0.0.1",
        mysqlPort = 3306,
        mysqlDb = "diamond",
        mysqlUser = "diamond",
        mysqlPass = "diamond",
        mysqlTimeout = 3000,
        mysqlMaxIdleTimeout = 10000, -- 10s
        mysqlPoolSize = 20,
        mysql = nil
    }

    local success, result = pcall(seckilling, config)
    cleanUp(config)
    
    if not success then
        error(nil, result, 500)
    end

    ngx.say("OK")
end

return _M
