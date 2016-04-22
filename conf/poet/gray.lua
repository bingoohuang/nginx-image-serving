local _M = {
    _VERSION = '0.1'
}

local function error(msg, httpCode, err)
    ngx.status = httpCode
    ngx.say(msg, err or "")
    ngx.log(ngx.ERR, msg)
    ngx.exit(httpCode)
end

local upstream = require "ngx.upstream"

local function switchPeersState(upstreamName, grayPeers, foundDownValue)
    local peers, err = upstream.get_primary_peers(upstreamName)
    if not peers then
        error("failed to get peers in upstream " .. upstreamName, 400, err)
    end

    for _, peer in ipairs(peers) do
        local found = string.find(grayPeers, peer.name .. ",") ~= nil
        upstream.set_peer_down(upstreamName, false, peer.id, foundDownValue == found)
        ngx.say("set ", upstreamName, "'s ", peer.name, " to ",
            (foundDownValue == found) and "down" or "up")
    end
end

--[[
    设定需要灰度的商户路由指向升级中
    opt.grayDic: 用来存储当前灰度的TID列表的Nginx共享内存的名称
    opt.tids, 以英文逗号分隔的需要灰度的TID列表
--]]
function _M.grayDoing(opt)
    local doingTids = opt.tids .. ","

    local grayDictName = opt.grayDict or "gray"
    local grayDict = ngx.shared[grayDictName]

    grayDict:set("tids_doing", doingTids)
end

--[[
    设定需要灰度的商户及灰度路由指向
    opt.grayDic: 用来存储当前灰度的TID列表的Nginx共享内存的名称
    opt.tids, 以英文逗号分隔的需要灰度的TID列表
    opt.peers, 以英文逗号分隔的需要灰度的服务器
--]]
function _M.grayAdmin(opt)
    local grayDictName = opt.grayDict or "gray"
    local grayDict = ngx.shared[grayDictName]

    local grayTids = opt.tids .. ","
    local grayPeers = opt.peers .. ","

    grayDict:set("tids_gray", grayTids)
    grayDict:delete("tids_doing")

    -- 之前版本中down灰度服务器,up非灰度服务器
    local versionPrev = opt.versionPrev or "version.prev"
    switchPeersState(versionPrev, grayPeers, true)
    -- 灰度版本中up灰度服务器，down非灰度服务器
    local versionGray = opt.versionGray or "version.gray"
    switchPeersState(versionGray, grayPeers, false)
end

--[[
    查询灰度路由，返回upstream名字
    opt.grayDic: 用来存储当前灰度的TID列表的Nginx共享内存的名称
    opt.tid, 商户的TID列表
--]]
function _M.queryGrayRoute(opt)
    local versionPrev = opt.versionPrev or "version.prev"
    local versionGray = opt.versionGray or "version.gray"
    local versionDoing = opt.versionDoing or "version.doing"

    local grayDictName = opt.grayDict or "gray"
    local grayDict = ngx.shared[grayDictName]
    local grayTids = grayDict:get("tids_gray")
    local doingTids = grayTids or grayDict:get("tids_doing")

    local tid = opt.tid

    -- 已经设置灰度，指向灰度
    if grayTids and string.find(grayTids, tid .. ",") then
        return versionGray
    end

    -- 正在准备灰度，指向升级中
    if doingTids and string.find(doingTids, tid .. ",") then
        return versionDoing
    end

    -- 指向正常版本
    return versionPrev
end

--[[
    完成灰度发布，所有商户均恢复正常访问
--]]
function _M.grayComplete(opt)
    local grayDictName = opt.grayDict or "gray"
    local grayDict = ngx.shared[grayDictName]

    -- 之前版本中up全部服务器
    local versionPrev = opt.versionPrev or "version.prev"
    switchPeersState(versionPrev, "", true)
    -- 灰度版本中down全部服务器
    local versionGray = opt.versionGray or "version.gray"
    switchPeersState(versionGray, "", false)

    -- 清除灰度TID列表共享字典
    grayDict:delete("tids_gray")
    grayDict:delete("tids_doing")
end

function _M.showUpstreams()
    local us = upstream.get_upstreams()
    for _, u in ipairs(us) do
        ngx.say("upstream ", u, ":")
        local srvs, err = upstream.get_primary_peers(u)
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

return _M
