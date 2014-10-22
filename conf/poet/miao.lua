local _M = {
    _VERSION = '0.1'
}

local function error(msg, httpCode, err)
    ngx.status = httpCode
    ngx.say(msg, err or "")
    ngx.log(ngx.ERR, msg)
    ngx.exit(httpCode)
end

local function connectRedis (host, port)
    local redis = require "resty.redis"
    local red = redis:new()
    red:set_timeout(1000) -- 1 sec
    local ok, err = red:connect(host, port)
    if not ok then
        error("connecting redis", 500, err)
    end
 
    return red
end

local function connectMySQL (host, port, database, user, password)
    local mysql = require "resty.mysql"
    local db, err = mysql:new()
    if not db then
        error("failed to instantiate mysql", 500, err)
    end

    db:set_timeout(1000) -- 1 sec

    local ok, err, errno, sqlstate = db:connect{
        host = host,
        port = port,
        database = database,
        user = user,
        password = password,
        max_packet_size = 1024 * 1024 }

    if not ok then
        error("failed to connect mysql", 500, err)
    end

    return db
end

local function checkExistence (redis, prefix, mobile)
    local price = redis:get(prefix .. mobile)
    if price ~= ngx.null then
        error("already got favored price " .. price, 400)
    end
end

local function checkCurrentPrice(redis, prefix, price, levelNum)
    -- 检查是否超过允许价格
    local bought = redis:get(prefix .. "bought")
    if bought == ngx.null then bought = 1 end

    local expectedPrice = math.floor(tonumber(bought) / levelNum) + 1
    if price ~= expectedPrice then
        error("bad price request expected " .. expectedPrice, 400)
    end

    local count, err = redis:incr(prefix .. price)
    if tonumber(count) > levelNum then
        error("sold out for current price", 400)
    end
end

local function checkPriceRange(priceStr)
    local price = tonumber(priceStr)
    if price < 1 or price > 60 then
        error("bad price range", 400)
    end
    return price
end

local function updatePrice(redis, prefix, mobile, priceStr)
    redis:init_pipeline(2)
    redis:set(prefix .. mobile, priceStr)
    redis:incr(prefix .. "bought")
    redis:commit_pipeline()
end

local function miaoPrice (redis, prefix, mobile, priceStr, levelNum)
    local price = checkPriceRange(priceStr)
    checkCurrentPrice(redis, prefix, price, levelNum)
    updatePrice(redis, prefix, mobile, priceStr)
end

-- CREATE TABLE miao (
--   mobile bigint(20) unsigned NOT NULL,
--   price int(10) unsigned NOT NULL,
--   ts timestamp NOT NULL,
--   PRIMARY KEY (mobile)
-- )
local function saveRecordToMysql (mysql, mobile, price)
    local sql = "insert into miao (mobile, price, ts) "
             .. "values (".. mobile .. ", ".. price .. ", now())"
    local res, err, errno, sqlstate = mysql:query(sql)
    if not res then
        error("bad result: ", 500, err .. ": " .. errno .. ": " .. sqlstate .. ".")
    end
end

local function checkFormat (name, value, format)
    if not value then
        error(name .. " required", 400)
    end

    local valueStr = string.match(value, format)
    if not valueStr then
        error(name .. " in bad format", 400)
    end
end

function _M.miao (prefix, mobile, price)
    checkFormat("mobile", mobile, "^1%d%d%d%d%d%d%d%d%d%d$")
    checkFormat("price", price, "^[1-6]?[0-9]$")

    local redis = connectRedis("127.0.0.1", 6379)
    checkExistence(redis, prefix, mobile)
    miaoPrice(redis, prefix, mobile, price, 3)

    local mysql = connectMySQL("127.0.0.1", 3306, "diamond", "diamond", "diamond")
    saveRecordToMysql(mysql, mobile, price)

    ngx.say("OK")
end

return _M
