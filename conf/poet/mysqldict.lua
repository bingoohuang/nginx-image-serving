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

local shared = ngx.shared
local cjson = require "cjson"
local restyLock = require "resty.lock"
local mysql = require "resty.mysql"

local function error(msg)
    ngx.status = 500 ngx.say(msg)
    ngx.log(ngx.ERR, msg) ngx.exit(500)
end

local function connectMySQL(dataSourceName)
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

local function getFromCache(dict, key)
   local value = dict:get(key)
   if not value then return nil end
   if value == "yes" then return value end
   return cjson.decode(value)
end

local function setToCache(dict, prefix, rows, pkColumnName)
   for k,v in pairs(rows) do
       local key = prefix .. v[pkColumnName]
       local val = cjson.encode(v)
       local succ, err, forcible = dict:set(key, val)
   end
end

local function startsWith(str, substr)
    if str == nil or substr == nil then
        return nil, "the string or the sub-stirng parameter is nil"
    end

    return string.find(str, substr) == 1
end

local function createQueryLastUpdateSql(opt)
    local originalSql = opt.queryAllSql
    -- ALTER TABLE `xxx` ADD COLUMN `sync_update_time`  TIMESTAMP ON UPDATE CURRENT_TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP;
    local sql, n, err = ngx.re.gsub(originalSql, "select\\s+(.*?)\\s+from\\s+(.*)", "select max(sync_update_time) as max_update_time from $2", "i")
    if not sql then ngx.log(ngx.ERR, "error: ", err) return nil end

    ngx.log(ngx.ERR, sql)
    return sql
end

-- return true : need to go on looping
-- return false: end up looping
local function syncData(opt)
    local sql = createQueryLastUpdateSql(opt)
    if not sql then return false end

    local db, err = connectMySQL(opt.dataSourceName)
    if not db then ngx.log(ngx.ERR, "failed to connect MySQL: ", err) return true end

    local rows, err, errcode, sqlstate = db:query(sql)
    if err then
        ngx.log(ngx.ERR, "error: ", err)
        closeDb(db)
        return false
    end

    if rows then
        ngx.log(ngx.ERR, "get max update time" .. cjson.encode(rows))
        local prefix = (opt.prefix or "__default_prefix") .. "."
        local maxUpdateTimeKey = prefix .. "__max_update_time__" .. opt.luaSharedDictName
        local dict = shared[opt.luaSharedDictName]
        local maxUpdateTime = dict:get(maxUpdateTimeKey)
        ngx.log(ngx.ERR, "maxUpdateTime in dict " .. (maxUpdateTime or "nil"))
        local maxUpdateTimeInDb = rows[1]["max_update_time"]
        ngx.log(ngx.ERR, "maxUpdateTime in db " .. maxUpdateTimeInDb)
        if maxUpdateTimeInDb ~= maxUpdateTime then
            dict:set(maxUpdateTimeKey, maxUpdateTimeInDb)
            -- 失效的时候，也同时终止timer的定时运行，等待下次访问时重新启动
            if maxUpdateTime ~= nil then _M.flushAll(opt) return false end
        end
    end

    closeDb(db)
    return true
end

local function syncJob(premature, opt)
    if premature then return end
    if syncData(opt) then opt.startTimer(opt) end
end

local function startTimer(opt)
    local delay = opt.timerDurationSeconds or 10 -- 60 seconds
    opt.startTimer = startTimer

    local ok, err = ngx.timer.at(delay, syncJob, opt)
    if not ok then
        ngx.log(ngx.ERR, "failed to create the timer: ", err)
    end
end

local function flushAllPrefix(dict, prefix)
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
    local dict = shared[opt.luaSharedDictName]
    local prefix = (opt.prefix or "__default_prefix") .. "."
    local loadedKey = prefix .. "__loaded_key__" .. opt.luaSharedDictName

    -- 尝试获取锁，获取不到，直接返回错误信息
    local locker = restyLock:new(opt.dictLockName)
    local locked, err = locker:lock(loadedKey)
    if not locked then return "failed to get lock" end

    -- dict:flush_all() -- 清除已有缓存数据
    flushAllPrefix(dict, prefix)

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

-- 返回 val
--    缓存key对应的取值，nil表示缓存值不存在
function _M.get(opt)
    local dict = shared[opt.luaSharedDictName]
    local prefix = (opt.prefix or "__default_prefix") .. "."
    local cacheKey = prefix .. opt.key
    local loadedKey = prefix .. "__loaded_key__" .. opt.luaSharedDictName
    local timerStartedKey = prefix .. "__timer_started_key__" .. opt.luaSharedDictName

    -- 尝试从缓存中读取，如果读取到，直接返回
    local val = getFromCache(dict, cacheKey)
    if val then return val end
    -- 查看缓存数据是否已经加载，如果已经加载，则直接返回nil
    local loaded = getFromCache(dict, loadedKey)
    if loaded == "yes" then return nil end

    -- 尝试获取锁，获取不到，直接返回nil
    local locker = restyLock:new(opt.dictLockName)
    local locked, err = locker:lock(loadedKey)
    if not locked then return nil end

    -- 获取锁后，再次尝试从缓存中读取（因为可能在等待锁时，缓存已经设定好）
    local val = getFromCache(dict, cacheKey)
    if val then locker:unlock() return val end
    -- 查看缓存数据是否已经加载，如果已经加载，则直接返回nil
    local loaded = getFromCache(dict, loadedKey)
    if loaded == "yes" then locker:unlock() return nil end

    flushAllPrefix(dict, prefix) -- 清除已有缓存数据

    -- 从数据库字典表中加载数据到缓存
    local db, err = connectMySQL(opt.dataSourceName)
    if not db then locker:unlock() error(err) end
    local rows, err, errcode, sqlstate = db:query(opt.queryAllSql)
    if rows then
        ngx.log(ngx.ERR, "get rows" .. cjson.encode(rows))
        setToCache(dict, prefix, rows, opt.pkColumnName)
        dict:set(loadedKey, "yes")
    end
    closeDb(db)

    -- 在锁定的状态下检查定时同步是否开启
    local timerStarted = getFromCache(dict, timerStartedKey)
    if timerStarted ~= "yes" then
        startTimer(opt)
        dict:set(timerStartedKey, "yes")
    end

    locker:unlock()
    if not rows then error("bad result: " .. err) end

    return getFromCache(dict, cacheKey)
end

return _M
