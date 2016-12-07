-- 本模块提供字典读取缓存功能
-- 第一次调用时，从MySQL中读取字典数据表所有需要缓存的数据（数量较少更新不频繁的表）
--- 为什么要一次性从数据库中加载所有的缓存数据呢？
--                    1) 效率高，只需要访问一次数据库
--                    2) 避免纯消耗的空查询（每次查询KEY都没有结果，每次都要访问数据库）
--------------将字典数据做成nginx的dict缓存
--------------根据key从缓存中读取数据
-- 后续调用时，直接从缓存中读取数据
-- 通过调用flushAll清除所有缓存

local _M = {
    _VERSION = '0.1'
}

local cjson = require "cjson"
local restyLock = require "resty.lock"
local mysql = require "resty.mysql"
local ngx_re_match = ngx.re.match
local ngx_re_gsub = ngx.re.gsub
local cjson_decode = cjson.decode
local cjson_encode = cjson.encode
local ngx_log = ngx.log
local ngx_shared = ngx.shared
local string_find = string.find

local function error(msg)
    ngx.status = 500 ngx.say(msg)
    ngx_log(ngx.ERR, msg) ngx.exit(500)
end

local function createDict(opt)
    opt.dict = opt.dict or ngx_shared[opt.luaSharedDictName]
end
local function createPrefix(opt)
    opt.prefix = (opt.prefix or "__default_prefix") .. "."
end
local function createCacheKey(opt)
    opt.cacheKey = opt.cacheKey or (opt.prefix .. opt.key)
end
local function createLoadedKey(opt)
    opt.loadedKey = opt.loadedKey or (opt.prefix .. "__loaded_key__" .. opt.luaSharedDictName)
end
local function createTimerStartedKey(opt)
    opt.timerStartedKey = opt.timerStartedKey or (opt.prefix .. "__timer_started_key__" .. opt.luaSharedDictName)
end
local function createMaxUpdateTimeKey(opt)
    opt.maxUpdateTimeKey = opt.maxUpdateTimeKey or (opt.prefix .. "__max_update_time__" .. opt.luaSharedDictName)
end

local function connectMySQL(dataSourceName)
    local db, err = mysql:new()
    if not db then return nil, "failed to instantiate mysql" .. err end
    db:set_timeout(1000) -- 1 second

    -- user:password@addr:port/dbname[?param1=value1&paramN=valueN]
    local regex = "(.+?):(.+?)@(.+?):(.+?)/(.+)"
    local m = ngx_re_match(dataSourceName, regex)
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

local function getFromCache(dict, key)
   local value = dict:get(key)
   if not value then return nil end
   if value == "yes" then return value end
   return cjson_decode(value)
end

local function setToCache(dict, prefix, rows, pkColumnName)
   for k,v in pairs(rows) do
       local key = prefix .. v[pkColumnName]
       local val = cjson_encode(v)
       local succ, err, forcible = dict:set(key, val)
   end
end

local function startsWith(str, substr)
    if str == nil or substr == nil then
        return nil, "the string or the sub-stirng parameter is nil"
    end

    return string_find(str, substr) == 1
end

local function createQueryLastUpdateSql(opt)
    if opt.queryMaxUpdateTimeSql then return opt.queryMaxUpdateTimeSql end

    -- ALTER TABLE `xxx` ADD COLUMN `sync_update_time`  TIMESTAMP ON UPDATE CURRENT_TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP;
    opt.queryMaxUpdateTimeSql, n, err = ngx_re_gsub(opt.queryAllSql, "select\\s+(.*?)\\s+from\\s+(.*)", "select max(sync_update_time) as max_update_time from $2", "i")
    if not opt.queryMaxUpdateTimeSql then ngx_log(ngx.ERR, "error: ", err)
    else ngx_log(ngx.ERR, opt.queryMaxUpdateTimeSql) end
end

-- return true : need to go on looping
-- return false: end up looping
local function syncData(opt)
    createQueryLastUpdateSql(opt)
    if not opt.queryMaxUpdateTimeSql then return false end

    local db, err = connectMySQL(opt.dataSourceName)
    if not db then ngx_log(ngx.ERR, "failed to connect MySQL: ", err) return true end

    local rows, err, errcode, sqlstate = db:query(opt.queryMaxUpdateTimeSql)
    closeDb(db)

    if err then ngx_log(ngx.ERR, "error: ", err) return false end

    if rows then
        createMaxUpdateTimeKey(opt)
        local maxUpdateTime = opt.dict:get(opt.maxUpdateTimeKey)
        local maxUpdateTimeInDb = rows[1]["max_update_time"]
        ngx_log(ngx.ERR, "maxUpdateTime in dict [", maxUpdateTime, "] vs db [", maxUpdateTimeInDb, "]")
        if maxUpdateTimeInDb ~= maxUpdateTime then
            opt.dict:set(opt.maxUpdateTimeKey, maxUpdateTimeInDb)
            -- 失效的时候，也同时终止timer的定时运行，等待下次访问时重新启动
            if maxUpdateTime ~= nil then _M.flushAll(opt) return false end
        end
    end

    return true
end

local startTimer -- 提前在此定义函数名，否则syncJob会报告找不到全局变量startTimer
local function syncJob(premature, opt)
    if premature then return end
    local delay = opt.timerDurationSeconds or 60 -- 60 seconds
    if syncData(opt) then startTimer(opt, delay) end
end

startTimer = function (opt, delay)
    local ok, err = ngx.timer.at(delay, syncJob, opt)
    if not ok then ngx_log(ngx.ERR, "failed to create the timer: ", err) end
end

local function flushAllPrefix(dict, prefix)
    ngx_log(ngx.ERR, "flush all in dict with prefix [", prefix, "]")
    local keys = dict:get_keys(0)
    for index,dictKey in pairs(keys) do
        if startsWith(dictKey, prefix) then dict:delete(dictKey) end
    end
end

-- 清除所有缓存
-- opt: 相关MySQL信息，表信息等
--    opt.luaSharedDictName LUA共享字典名
--    opt.dictLockName  锁名称，在从MySQL刷数据时防止缓存失效风暴
--    opt.prefix  可选。前缀名，当多个不同缓存使用同一个luaSharedDictName和dictLockName时，使用前缀加以区分

-- 返回 清除结果
--    OK 清除成功， 否则为错误信息
function _M.flushAll(opt)
    createDict(opt)
    createPrefix(opt)
    createLoadedKey(opt)

    -- 尝试获取锁，获取不到，直接返回错误信息
    local locker = restyLock:new(opt.dictLockName)
    local locked, err = locker:lock(opt.loadedKey)
    if not locked then return "failed to get lock" end

    -- dict:flush_all() -- 清除已有缓存数据
    flushAllPrefix(opt.dict, opt.prefix)

    locker:unlock()
    return "OK"
end

-- lua_shared_dict mysqldict_demo 1m;
-- lua_shared_dict mysqlDict_lock 1k;
-- 从缓存中获取数据

-- opt: 相关MySQL信息，表信息等
--    opt.key: 缓存主键
--    opt.dataSourceName MySQL连接字符串，比如root:my-secret-pw@192.168.99.100:13306/dba
--    opt.queryAllSql 查询用的SQL语句，用于一次性从数据库中查询所有需要缓存的数据，一次性缓存后就不再访问数据库了
--    opt.pkColumnName   字典表的主键字段名
--    opt.luaSharedDictName LUA共享字典名
--    opt.dictLockName  锁名称，在从MySQL刷数据时防止缓存失效风暴，可以多个luaSharedDictName共用
--    opt.prefix  可选。前缀名，当多个不同缓存使用同一个luaSharedDictName和dictLockName时，使用前缀加以区分
--    opt.timerDurationSeconds 可选。缓存更新检查时间间隔描述。默认60秒。

-- 返回 val
--    缓存key对应的取值，nil表示缓存值不存在
function _M.get(opt)
    createDict(opt)
    createPrefix(opt)
    createLoadedKey(opt)
    createCacheKey(opt)

    -- 尝试从缓存中读取，如果读取到，直接返回
    local val = getFromCache(opt.dict, opt.cacheKey)
    if val then return val end
    -- 查看缓存数据是否已经加载，如果已经加载，则直接返回nil
    local loaded = getFromCache(opt.dict, opt.loadedKey)
    if loaded == "yes" then return nil end

    -- 尝试获取锁，获取不到，直接返回nil
    local locker = restyLock:new(opt.dictLockName)
    local locked, err = locker:lock(opt.loadedKey)
    if not locked then return nil end

    -- 获取锁后，再次尝试从缓存中读取（因为可能在等待锁时，缓存已经设定好）
    local val = getFromCache(opt.dict, opt.cacheKey)
    if val then locker:unlock() return val end
    -- 查看缓存数据是否已经加载，如果已经加载，则直接返回nil
    local loaded = getFromCache(opt.dict, opt.loadedKey)
    if loaded == "yes" then locker:unlock() return nil end

    flushAllPrefix(opt.dict, opt.prefix) -- 清除已有缓存数据

    -- 从数据库字典表中加载数据到缓存
    local db, err = connectMySQL(opt.dataSourceName)
    if not db then locker:unlock() error(err) end
    local rows, err, errcode, sqlstate = db:query(opt.queryAllSql)
    if rows then
        ngx_log(ngx.ERR, "get rows" .. cjson_encode(rows))
        setToCache(opt.dict, opt.prefix, rows, opt.pkColumnName)
        opt.dict:set(opt.loadedKey, "yes")
    end
    closeDb(db)

    -- 在锁定的状态下检查定时同步是否开启
    createTimerStartedKey(opt)
    local timerStarted = getFromCache(opt.dict, opt.timerStartedKey)
    if timerStarted ~= "yes" then
        startTimer(opt, 0)
        opt.dict:set(opt.timerStartedKey, "yes")
    end

    locker:unlock()
    if not rows then error("bad result: " .. err) end

    return getFromCache(opt.dict, opt.cacheKey)
end

return _M
