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
    ngx.status = 500 ngx.say(msg)
    ngx.log(ngx.ERR, msg) ngx.exit(500)
end

local function connectMySQL(dataSourceName)
    local mysql = require "resty.mysql"
    local db, err = mysql:new()
    if not db then return nil, "failed to instantiate mysql" .. err end
    db:set_timeout(1000) -- 1 second

    -- user:password@addr:port/dbname[?param1=value1&paramN=valueN]
    local regex = "(.+?):(.+?)@(.+?):(.+?)/(.+)"
    local m = ngx.re.match(dataSourceName, regex)
    if not m then return nil, "dataSourceName format is not recognized" end

    local ok, err, errno, sqlstate = db:connect {
        host = m[3], port = m[4], database = m[5],
        user = m[1], password = m[2],
        max_packet_size = 1024 * 1024 }
    if ok then return db, nil end

    return nil, "failed to connect mysql ".. err
end

local function closeDb(db)
    -- db:set_keepalive(10000, 10)
    db:close()
end

local function tryLock(locker, key)
    local elapsed, err = locker:lock(key)
    return elapsed
end

local function unlock(locker)
    local unlockok, err = locker:unlock()
    if not unlockok then error("failed to unlock: " .. err) end
end

local cjson = require "cjson"

local function getFromCache(dict, key)
   local value = dict:get(key)
   if not value then return nil end
   if value == "yes" then return value end
   return cjson.decode(value)
end

local function setToCache(dict, rows, pkColumnName)
   for k,v in pairs(rows) do
       local key = v[pkColumnName]
       local val = cjson.encode(v)
       local succ, err, forcible = dict:set(key, val)
   end
end

local function flushAllCache(dict)
    dict:flush_all()
end

local restyLock = require "resty.lock"

-- lua_shared_dict mysqldict_demo 128m;
-- lua_shared_dict mysqlDict_lock 100k;
-- 从缓存中获取数据
-- key: 缓存主键
-- opt: 相关MySQL信息，表信息等
--    opt.dataSourceName MySQL连接字符串，比如root:my-secret-pw@192.168.99.100:13306/dba
--    opt.dictTableName  字典表的表名
--    opt.pkColumnName   字典表的主键字段名
--    opt.luaSharedDictName LUA共享字典名
--    opt.dictLockName  锁名称，在从MySQL刷数据时防止缓存失效风暴
-- 返回 val, err
--      缓存key对应的取值，错误信息
function _M.get(key, opt)
    local dict = ngx.shared[opt.luaSharedDictName]

    -- 尝试从缓存中读取，如果读取到，直接返回
    local val = getFromCache(dict, key)
    if val then return val end

    -- 查看缓存数据是否已经加载，如果已经加载，则直接返回nil
    local loadedKey = "__loaded_key__" .. opt.luaSharedDictName
    local loaded = getFromCache(dict, loadedKey)
    if loaded == "yes" then return nil end

    -- 尝试获取锁，获取不到，直接返回nil
    local locker = restyLock:new(opt.dictLockName)
    local locked = tryLock(locker, loadedKey)
    if not locked then return nil end

    -- 获取锁后，再次尝试从缓存中读取（因为可能在等待锁时，缓存已经设定好）
    local val = getFromCache(dict, key)
    if val then unlock(lock) return val end

    local loaded = getFromCache(dict, loadedKey)
    if loaded == "yes" then return nil end

    -- 清楚已有缓存数据
    flushAllCache(dict)
    -- 从数据库字典表中加载数据到缓存
    local db, err = connectMySQL(opt.dataSourceName)
    if not db then unlock(locker) error(err) end

    local rows, err, errcode, sqlstate = db:query("select * from " .. opt.dictTableName)
    if rows then
        setToCache(dict, rows, opt.pkColumnName)
        dict:set(loadedKey, "yes")
    end

    unlock(locker) closeDb(db)

    if not rows then
        error("bad result: " .. err)
    end

    return getFromCache(dict, key)
end


return _M
