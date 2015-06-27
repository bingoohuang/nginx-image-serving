local _M = {
    _VERSION = '0.1'
}

local function setHeaders (tid, tcode)
    ngx.req.set_header("tid", tid)
    ngx.req.set_header("tcode", tcode)
end

--[[
    opt could contains:
        prevWord        : for tcode identifaction previous word in url,
                          default "tcode", like /abc/tcode/T013323/index.
        host            : redis host, default "127.0.0.1".
        port            : redis port, default 6379.
        timeout         : redis connect timeout, default 3s.
        maxIdleTimeout  : redis keep_alive timeout, default 10s.
        poolSize        : redis connect pool size, default 10.
        auth            : redis auth, default nil.

        key             : AES encrypt key, default "AKeyForAES-256-CBC".
        salt            : AES encrypt salt, default "HI_SALT".
        round           : AES encrypt round, default 5.
--]]
_M.tcode = function(opt)
    -- http://wiki.nginx.org/HttpCoreModule#.24host
    -- for lua Patterns, refer to http://www.lua.org/pil/20.2.html
    local tcode = opt.useSubDomain && string.match(ngx.var.host, "^(%w+)%.[%w%-]+%.%w+$")
    local domain = tcode and ("www" ~= tcode)
    tcode = tcode or string.match(ngx.var.uri, "^/(%w+)$")
    local prevWord = opt and opt.prevWord or "tcode"
    tcode = tcode or string.match(ngx.var.uri, "/" .. prevWord .. "/(%w+)")

    if tcode then
        local hi_redis = require("hi_redis"):connect(opt)
        local tid, err = hi_redis:get("tcode:" .. tcode)
        hi_redis:close()

        if not err then
            ngx.log(ngx.STDERR, err)
            ngx.exit(500)
        end

        if not tid then ngx.exit(404) return end

        setHeaders(tid, tcode)

        if not domain then
            local hi_aes = require("hi_aes"):new(opt)
            require("hi_cookie"):set {
                key = "easyhi_tcode", path = "/",
                value = hi_aes:encrypt(tid .. "^" .. tcode)
            }
        end

        return tid
    else
        local encrptedTid = ngx.var.cookie_easyhi_tcode
        if not encrptedTid then ngx.exit(404) return end

        local hi_aes = require("hi_aes"):new(opt)
        local tidAndTcode = hi_aes:decrypt(encrptedTid)
        local tid, tcode = string.match(tidAndTcode, "(%w+)^(%w+)")

        setHeaders(tid, tcode)

        return tid
    end
end

return _M
