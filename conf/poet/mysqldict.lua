--- 本模块提供字典读取缓存功能
--- 第一次调用时，从MySQL中读取字典数据表所有需要缓存的数据（数量较少更新不频繁的表）
--- 为什么要一次性从数据库中加载所有的缓存数据呢？
--- 1) 效率高，只需要访问一次数据库
--- 2) 避免纯消耗的空查询（每次查询KEY都没有结果，每次都要访问数据库）
-------------- 将字典数据做成nginx的dict缓存
-------------- 根据key从缓存中读取数据
--- 后续调用时，直接从缓存中读取数据
--- 通过调用flushAll清除所有缓存

local _M = {
    _VERSION = '0.1'
}

local cjson = require "cjson"
local resty_lock = require "resty.lock"
local mysql = require "resty.mysql"
local ngx_re_match = ngx.re.match
local ngx_re_gsub = ngx.re.gsub
local cjson_decode = cjson.decode
local cjson_encode = cjson.encode
local ngx_log = ngx.log
local ngx_shared = ngx.shared
local string_find = string.find

local function error(msg)
    ngx.status = 500
    ngx.say(msg)
    ngx_log(ngx.ERR, msg)
    ngx.exit(500)
end

local function createDict(opt)
    opt.dict = opt.dict or ngx_shared[opt.luaSharedDictName]
end

local function createPrefix(opt)
    local prefix = opt.prefix or "__default_prefix"
    if string.sub(prefix, -1) ~= "." then
        prefix = prefix .. "."
    end

    opt.prefix = prefix
end

local function createCacheKey(opt)
    opt.cacheKey = opt.cacheKey or (opt.prefix .. opt.key)
end

local function createLockKey(opt)
    opt.lockKey = opt.lockKey or (opt.prefix .. "__lock_key__" )
end


local function createLoadedKey(opt)
    opt.loadedKey = opt.loadedKey or (opt.prefix .. "__loaded_key__" )
end

local function createMaxUpdateTimeKey(opt)
    opt.maxUpdateTimeKey = opt.maxUpdateTimeKey or (opt.prefix .. "__max_update_time__")
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
        host = m[3],
        port = m[4],
        database = m[5],
        user = m[1],
        password = m[2],
        max_packet_size = 1024 * 1024
    }
    if ok then return db, nil end

    return nil, "failed to connect mysql " .. err
end

local function closeDb(db)
    -- db:set_keepalive(10000, 10)
    db:close()
end

local function getFromCache(dict, key)
    local value = dict:get(key)
    if not value then return nil end

    return value == "yes" and value or cjson_decode(value)
end

local function setToCache(dict, prefix, rows, pkColumnName)
    for k, v in pairs(rows) do
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
    -- s for "single line mode" makes the dot match all characters, including line breaks.
    -- i case insensitive mode (similar to Perl's /i modifier)
    -- refer https://github.com/openresty/lua-nginx-module#ngxrematch
    opt.queryMaxUpdateTimeSql, n, err = ngx_re_gsub(opt.queryAllSql,
        "select\\s+(.*?)\\s+from\\s+(.*)",
        "select max(sync_update_time) as max_update_time from $2", "si")
    if not opt.queryMaxUpdateTimeSql then ngx_log(ngx.ERR, "error: ", err)
    else ngx_log(ngx.ERR, opt.queryMaxUpdateTimeSql)
    end
end


local startTimer -- 提前在此定义函数名，否则syncJob会报告找不到全局变量startTimer
local fastFlushDict -- 同上
local syncData  -- 同上
local function syncJob(premature, opt)
    -- premature，则是用于标识触发该回调的原因是否由于 timer 的到期。Nginx worker 的退出，也会触发当前所有有效的 timer。
    -- 这时候 premature 会被设置为 true。回调函数需要正确处理这一参数（通常直接返回即可）。
    -- 重要：reload时，premature为true，这时候timer需要重新启动，所以快速清理后退出。
    if premature then fastFlushDict(opt) return end
    local delay = opt.timerDurationSeconds or 60 -- 60 seconds
    if syncData(opt) then startTimer(opt, delay) end
end

startTimer = function(opt, delay)
    local ok, err = ngx.timer.at(delay, syncJob, opt)
    if not ok then ngx_log(ngx.ERR, "failed to create the timer: ", err) end
end

fastFlushDict = function(opt)
  opt.dict:delete(opt.loadedKey)
end

-- return true : need to go on looping
-- return false: end up looping
syncData = function(opt)
    createQueryLastUpdateSql(opt)
    if not opt.queryMaxUpdateTimeSql then return false end

    local db, err = connectMySQL(opt.dataSourceName)
    if not db then ngx_log(ngx.ERR, "failed to connect MySQL: ", err) return true end

    local rows, err, errcode, sqlstate = db:query(opt.queryMaxUpdateTimeSql)
    closeDb(db)

    if err then ngx_log(ngx.ERR, "error: ", err) return true end

    if rows then
        createMaxUpdateTimeKey(opt)
        local maxUpdateTime = opt.dict:get(opt.maxUpdateTimeKey)
        local maxUpdateTimeInDb = rows[1]["max_update_time"]
        local maxUpdateTimeChanged = maxUpdateTimeInDb ~= maxUpdateTime
        ngx_log(ngx.ERR, "maxUpdateTime in dict [", maxUpdateTime,
          "] vs db [", maxUpdateTimeInDb, "] maxUpdateTimeChanged ", maxUpdateTimeChanged)
        if maxUpdateTimeChanged then
            opt.dict:set(opt.maxUpdateTimeKey, maxUpdateTimeInDb)
            -- 失效的时候，也同时终止timer的定时运行，等待下次访问时重新启动
            if maxUpdateTime ~= nil then
              fastFlushDict(opt)
              ngx_log(ngx.ERR, "timer exited, prepare to restart until next access")
              return false
            end
        end
    end

    return true
end

local function flushAllPrefix(opt)
    local dict = opt.dict
    local prefix = opt.prefix
    ngx_log(ngx.ERR, "flush all in dict with prefix [", prefix, "]")

    dict:delete(opt.loadedKey)
    dict:delete(opt.maxUpdateTimeKey)

    local keys = dict:get_keys(0)
    for index, dictKey in pairs(keys) do
        if startsWith(dictKey, prefix) and dictKey ~= opt.lockKey then
          dict:delete(dictKey)
        end
    end
end


-- 清除所有缓存
-- opt: 相关MySQL信息，表信息等
--    opt.luaSharedDictName LUA共享字典名
--    opt.prefix  可选。前缀名，当多个不同缓存使用同一个luaSharedDictName时，使用前缀加以区分

-- 返回 清除结果
--    OK 清除成功， 否则为错误信息
function _M.flushAll(opt)
    createDict(opt)
    createPrefix(opt)
    createLoadedKey(opt)
    createLockKey(opt)

    -- 尝试获取锁，获取不到，直接返回错误信息
    local locker = resty_lock:new(opt.dictLockName)
    local locked, err = locker:lock(opt.lockKey)
    if not locked then return "failed to get lock" end

    -- dict:flush_all() -- 清除已有缓存数据
    flushAllPrefix(opt)

    locker:unlock()
    return "OK"
end

local function loadMySqlData()
end

-- lua_shared_dict mysqldict_demo 1m;
-- 从缓存中获取数据

-- opt: 相关MySQL信息，表信息等
--    opt.key: 缓存主键
--    opt.dataSourceName MySQL连接字符串，比如root:my-secret-pw@192.168.99.100:13306/dba
--    opt.queryAllSql 查询用的SQL语句，用于一次性从数据库中查询所有需要缓存的数据，一次性缓存后就不再访问数据库了
--    opt.pkColumnName   字典表的主键字段名
--    opt.luaSharedDictName LUA共享字典名
--    opt.prefix  可选。前缀名，当多个不同缓存使用同一个luaSharedDictName时，使用前缀加以区分
--    opt.timerDurationSeconds 可选。缓存更新检查时间间隔描述。默认60秒。

-- 返回 val
--    缓存key对应的取值，nil表示缓存值不存在
function _M.get(opt)
    createDict(opt)
    createPrefix(opt)
    createLoadedKey(opt)
    createCacheKey(opt)
    createLockKey(opt)

    local dict = opt.dict
    local cacheKey = opt.cacheKey

    -- 尝试从缓存中读取，如果读取到，直接返回
    local val = getFromCache(dict, cacheKey)
    if val then return val end

    -- 查看缓存数据是否已经加载，如果已经加载，则直接返回nil
    local loadedKey = opt.loadedKey
    local loaded = getFromCache(dict, loadedKey)
    if loaded == "yes" then return nil end

    -- 尝试获取锁，获取不到，直接返回nil
    local locker, err = resty_lock:new(opt.luaSharedDictName)
    if not locker then ngx_log(ngx.ERR, "failed to create lock: ", err) return nil end
    local elapsed, err = locker:lock(opt.lockKey)
    if not elapsed then return nil end

    -- 获取锁后，再次尝试从缓存中读取（因为可能在等待锁时，缓存已经设定好）
    local val = getFromCache(dict, cacheKey)
    if val then locker:unlock() return val end
    -- 查看缓存数据是否已经加载，如果已经加载，则直接返回nil
    local loaded = getFromCache(dict, loadedKey)
    if loaded == "yes" then locker:unlock() return nil end

    -- 从数据库字典表中加载数据到缓存
    local db, err = connectMySQL(opt.dataSourceName)
    if not db then locker:unlock() error(err) end

    local rows, err, errcode, sqlstate = db:query(opt.queryAllSql)
    closeDb(db)

    flushAllPrefix(opt) -- 清除已有缓存数据

    if rows then
        ngx_log(ngx.ERR, "get rows" .. cjson_encode(rows))
        setToCache(dict, opt.prefix, rows, opt.pkColumnName or "id")
        dict:set(loadedKey, "yes")
    end

    startTimer(opt, 0)

    locker:unlock()
    if not rows then error("bad result: " .. err) end

    return getFromCache(dict, cacheKey)
end

return _M
