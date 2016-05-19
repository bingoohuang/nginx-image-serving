local _M = {
    _VERSION = '0.1'
}


local gray = require("poet.gray")

function _M.showStatus(prefix)
    gray.showStatus{grayDict = prefix .. ".dict"}
end

function _M.grayDoing(prefix)
    gray.grayDoing{
        tids = ngx.var.arg_tids,
        grayDict = prefix .. ".dict"
    }
end

function _M.grayAdmin(prefix)
    gray.grayAdmin{
        tids = ngx.var.arg_tids,
        peers = ngx.var.arg_peers,
        versionPrev = prefix .. ".prev",
        versionGray = prefix .. ".gray",
        grayDict = prefix .. ".dict"
    }
end

function _M.queryGrayRoute(prefix)
    return gray.queryGrayRoute{
        tid = ngx.var.arg_tid,
        versionPrev = prefix .. ".prev",
        versionGray = prefix .. ".gray",
        versionDoing = prefix .. ".doing",
        grayDict = prefix .. ".dict"
    }
end

function _M.grayComplete(prefix)
    gray.grayComplete{
        versionPrev = prefix .. ".prev",
        versionGray = prefix .. ".gray",
        grayDict = prefix .. ".dict"
    }
end

return _M
