local _M = {
    _VERSION = '0.1'
}

local function trim(s)
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end
--[[
    Aux function to split a string
]]--
local function split(str, delimiter)
    if not str then return {} end

    local delim = delimiter or ","
    local from = 1
    local delim_from, delim_to = str:find(delim, from, true)
    if delim_from == nil then
        local trimmed = trim(str)
        return trimmed:len() > 0 and {trimmed} or {}
    end

    local result = {}
    while delim_from do
        local substr = str:sub(from, delim_from - 1)
        local trimmed = trim(substr)
        if trimmed:len() > 0 then table.insert(result, trimmed) end

        from = delim_to + 1
        delim_from, delim_to = str:find(delim, from, true)
    end

    local trimmed = trim(str:sub(from))
    if trimmed:len() > 0 then table.insert(result, trimmed) end

    return result
end

local function splitToKeyTable(str, delimiter)
    if not str then return {} end

    local result = {}
    local delim = delimiter or ","
    local from = 1
    local delim_from, delim_to = str:find(delim, from, true)
    if delim_from == nil then
        local trimmed = trim(str)
        if trimmed:len() > 0 then result[trimmed] = true end
        return result;
    end

    while delim_from do
        local substr = str:sub(from, delim_from - 1)
        local trimmed = trim(substr)
        if trimmed:len() > 0 then result[substr] = true end

        from = delim_to + 1
        delim_from, delim_to = str:find(delim, from, true)
    end

    local trimmed = trim(str:sub(from))
    if trimmed:len() > 0 then result[trimmed] = true end

    return result
end

local function diff(a, b)
    local aa = {}
    for k,v in pairs(a) do aa[v] = true end
    for k,v in pairs(b) do aa[v] = nil end
    local ret = {}
    local n = 0
    for k,v in pairs(a) do
        if aa[v] then n = n + 1; ret[n] = v end
    end

    return ret
end

local function join(a, delimiter)
    return table.concat(a,  delimiter or ",")
end

local function merge(a, b)
    local ret = diff(a, b)
    local n = #ret
    for k,v in pairs(b) do
        n = n + 1; ret[n]=v
    end

    return ret
end

local function error(msg, httpCode, err)
    ngx.status = httpCode
    ngx.say(msg, err or "")
    ngx.log(ngx.ERR, msg)
    ngx.exit(httpCode)
end

local function checkOptGrayDictName(opt)
    if not opt or not opt.grayDict then
        error("grayDict in opt shoud be set", 400)
        return
    end

    local grayDict = ngx.shared[opt.grayDict]
    if not grayDict then
        error("lua_shared_dict " .. opt.grayDict .. " is not set", 400)
        return
    end

    return grayDict
end


local ups = require "ngx.upstream"

local function switchPeersState(upstreamName, targetPeers, downValue)
    local peers, err = ups.get_primary_peers(upstreamName)
    if not peers then
        error("failed to get peers in upstream " .. upstreamName, 400, err)
        return
    end

    local setDown = (downValue == "down")
    local targetPeersTable = splitToKeyTable(targetPeers)
    for _, peer in ipairs(peers) do
        local found = targetPeersTable[peer.name]
        if found then ups.set_peer_down(upstreamName, false, peer.id, setDown) end
    end
end

local function changeAllPeersState(upstreamName, downValue)
    local peers, err = ups.get_primary_peers(upstreamName)

    local setDown = (downValue == "down")
    for _, peer in ipairs(peers) do
        ups.set_peer_down(upstreamName, false, peer.id, setDown)
    end
end

--[[
    设定需要灰度的商户路由指向升级中
    opt.grayDic: 用来存储当前灰度的TID列表的Nginx共享内存的名称
    opt.tids, 以英文逗号分隔的需要灰度的TID列表
--]]
function _M.grayDoing(opt)
    local grayDict = ngx.shared[opt.grayDict]

    local tidsDoing = split(grayDict:get("tids_doing"))
    local todoTids = split(opt.tids)
    local mergedTids = merge(tidsDoing, todoTids)

    grayDict:set("tids_doing", join(mergedTids))
end


--[[
    设定需要灰度的商户及灰度路由指向
    opt.grayDic: 用来存储当前灰度的TID列表的Nginx共享内存的名称
    opt.tids:    以英文逗号分隔的需要灰度的增量TID列表
    opt.peers:   以英文逗号分隔的需要灰度的增量服务器
--]]
function _M.grayAdmin(opt)
    local grayDict = checkOptGrayDictName(opt);

    local tidsGrayed = split(grayDict:get("tids_gray"))
    local tidsGraying = split(opt.tids)
    local tidsDiff = diff(tidsGraying, tidsGrayed)
    if #tidsDiff == 0 then return end -- 所传商户ID都处于灰度之中

    local mergedTidsGrayed = merge(tidsGrayed, tidsDiff)
    grayDict:set("tids_gray", join(mergedTidsGrayed)) -- 设置当前正在灰度的商户列表

    local tidsDoing = split(grayDict:get("tids_doing"))
    local newTidsDoing = diff(tidsDoing, tidsDiff)  -- 从准备灰度升级的商户列表中移除已经灰度的商户
    grayDict:set("tids_doing", join(newTidsDoing))  -- 设置正在准备灰度升级的商户列表

    switchPeersState(opt.versionPrev, opt.peers, "down") -- 老版本中down灰度服务器
    switchPeersState(opt.versionGray, opt.peers, "up")   -- 灰度版本中up灰度服务器
end

--[[
    查询灰度路由，返回upstream名字
    opt.grayDic: 用来存储当前灰度的TID列表的Nginx共享内存的名称
    opt.tid, 商户的TID列表
--]]
function _M.queryGrayRoute(opt)
    local grayDict = ngx.shared[opt.grayDict]

    -- 已经设置灰度，指向灰度
    local grayTids = grayDict:get("tids_gray")
    local grayTidsTable = splitToKeyTable(grayTids)
    if grayTidsTable[opt.tid] then return opt.versionGray end

    -- 正在准备灰度，指向升级中
    local doingTids = grayDict:get("tids_doing")
    local doingTidsTable = splitToKeyTable(doingTids)
    if doingTidsTable[opt.tid] then return opt.versionDoing end

    -- 指向正常版本
    return opt.versionPrev
end

--[[
    完成灰度发布，所有商户均恢复正常访问
--]]
function _M.grayComplete(opt)
    changeAllPeersState(opt.versionPrev, "up") -- 之前版本中up全部服务器
    changeAllPeersState(opt.versionGray, "down") -- 灰度版本中down全部服务器

    -- 清除灰度TID列表共享字典
    local grayDict = ngx.shared[opt.grayDict]
    grayDict:delete("tids_gray")
    grayDict:delete("tids_doing")
end

local function showAllUpstreams()
    local us = ups.get_upstreams()
    for _, u in ipairs(us) do
        ngx.say("upstream ", u, ":")
        local srvs, err = ups.get_primary_peers(u)
        if not srvs then
            error("failed to get servers in upstream " .. u, 400, err)
            break
        end

        for _, srv in ipairs(srvs) do
            for k, v in pairs(srv) do
                if type(v) == "table" then
                    ngx.print(k, " = {", table.concat(v, ", "), "}", ", ")
                else
                    ngx.print(k, " = ", v, ", ")
                end
            end
            ngx.print("\n")
        end
    end
end

local function showGrayDict(opt)
    local grayDict = ngx.shared[opt.grayDict]

    ngx.say("tids_gray: ", grayDict:get("tids_gray"))
    ngx.say("tids_doing: ", grayDict:get("tids_doing"))
end

function _M.showStatus(opt)
    showAllUpstreams()
    showGrayDict(opt)
end

return _M
