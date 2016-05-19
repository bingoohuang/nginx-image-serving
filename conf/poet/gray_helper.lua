local _M = {
    _VERSION = '0.1'
}

local gray = require("poet.gray")

-- 提供按照前缀命名约定的辅助小函数
-- 命名约定如下：
-- 1. lua共享内存命名 [prefix].dict
-- 2. 老版本upstream命名 [prefix].prev
-- 3. 新版本upstream命名 [prefix].gray
-- 4. 升级页upstream命名 [prefix].doing

local function dictName(prefix) return prefix .. ".dict" end
local function prevName(prefix) return prefix .. ".prev" end
local function grayName(prefix) return prefix .. ".gray" end
local function doingName(prefix) return prefix .. ".doing" end

function _M.showStatus(prefix)
    gray.showStatus{grayDict = dictName(prefix)}
end

function _M.grayDoing(prefix)
    gray.grayDoing{
        tids = ngx.var.arg_tids,
        grayDict = dictName(prefix)
    }
end

function _M.grayAdmin(prefix)
    gray.grayAdmin{
        tids = ngx.var.arg_tids,
        peers = ngx.var.arg_peers,
        versionPrev = prevName(prefix),
        versionGray = grayName(prefix),
        grayDict = dictName(prefix)
    }
end

function _M.queryGrayRoute(prefix)
    return gray.queryGrayRoute{
        tid = ngx.var.arg_tid,
        versionPrev = prevName(prefix),
        versionGray = grayName(prefix),
        versionDoing = doingName(prefix),
        grayDict = dictName(prefix)
    }
end

function _M.grayComplete(prefix)
    gray.grayComplete{
        versionPrev = prevName(prefix),
        versionGray = grayName(prefix),
        grayDict = dictName(prefix)
    }
end

return _M
