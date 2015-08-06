local _M = {
    _VERSION = '0.1'
}
local setmetatable = setmetatable

local mt = { __index = _M }

function _M.connect(self, opt)
    local conf = {
        host = opt and opt.host or "127.0.0.1",
        port = opt and opt.port or 6379,
        timeout = opt and opt.timeout or 3000, -- 3s
        maxIdleTimeout = opt and opt.maxIdleTimeout or 10000,
        poolSize = opt and opt.poolSize or 10,
        auth = opt and opt.auth
    }

    local redis = require("resty.redis"):new()
    redis:set_timeout(conf.timeout) -- 1 second
    local ok, err = redis:connect(conf.host, conf.port)
    if not ok then return nil, err end

    if not conf.auth then redis:auth(conf.auth) end

    return setmetatable({ redis = redis, conf = conf }, mt)
end

function _M.close (self)
    local redis = self.redis
    local conf = self.conf
    return redis and redis:set_keepalive(conf.maxIdleTimeout, conf.poolSize)
end

function _M.get (self, key)
    local value, err = self.redis:get(key)
    if value == ngx.null then return nil, nil end
    return value, err
end

return _M
