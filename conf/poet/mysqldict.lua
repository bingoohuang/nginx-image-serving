-- 本模块提供字典读取缓存功能
-- 第一次调用时，从MySQL中读取字典数据表（数量较少更新不频繁的表）
--------------将字典数据做成nginx的dict缓存
--------------根据key从缓存中读取数据
---------------------如果数据存在，返回
---------------------不存在，设置下次读取时间，返回nil

-- 后续调用时，如果从缓存中key读取不到值，尝试从MySQL中重新导入全部字典数据，重复上述逻辑

local _M = {
    _VERSION = '0.1'
}

local function error(msg)
    ngx.status = httpCode
    ngx.say(msg)
    ngx.log(ngx.ERR, msg)
    ngx.exit(500)
end


local function connectMySQL (dataSourceName)
    local mysql = require "resty.mysql"
    local db, err = mysql:new()
    if not db then
        error("failed to instantiate mysql" .. err)
    end

    db:set_timeout(1000) -- 1 second

    -- user:password@addr:port/dbname[?param1=value1&paramN=valueN]
    local regex = "(.+?):(.+?)@(.+?):(.+?)/(.+)"
    local m = ngx.re.match(dataSourceName, regex)
    if not m then
        error("dataSourceName format is not recognized")
    end

    local ok, err, errno, sqlstate = db:connect{
        host = m[3],
        port = m[4],
        database = m[5],
        user = m[1],
        password = m[2],
        max_packet_size = 1024 * 1024 }

    if not ok then
        error("failed to connect mysql ".. err )
    end

    return db
end

local function closeDb(db)
    -- db:set_keepalive(10000, 10)
    db:close()
end

local cjson = require "cjson"

local function getFromCache(cacheName, key)
   local cache_ngx = ngx.shared[cacheName]
   local value = cache_ngx:get(key)
   if value then
       return cjson.decode(value)
   end

   return nil
end

-- TODO: 处理并发设置
local function setToCache(cacheName, rows, pkColumnName, exptime)
   if not exptime then exptime = 0 end
   local cache_ngx = ngx.shared[cacheName]


   for k,v in pairs(res) do
       local key = v[pkColumnName]
       local succ, err, forcible = cache_ngx:set(key, cjson.encode(v), exptime)
   end
end

-- lua_shared_dict mysqldict_demo 128m;
-- 从缓存中获取数据
-- key: 缓存主键
-- opt: 相关MySQL信息，表信息等
-- 返回 val, err
--      缓存key对应的取值，错误信息
function _M.get(key, opt)
    local val = getFromCache(opt.luaSharedDictName, key)
    if val return val end

    // "root:my-secret-pw@192.168.99.100:13306/dba"

    local db = connectMySQL(opt.dataSourceName)

    res, err, errcode, sqlstate = db:query("select * from " .. opt.dictTableName)
    if not res then
        error("bad result: " .. err)
    end

    setToCache(opt.luaSharedDictName, res, opt.pkColumnName)

    closeDb(db)

    return getFromCache(opt.luaSharedDictName, key)
end





return _M
