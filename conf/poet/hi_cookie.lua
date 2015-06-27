local _M = {
    _VERSION = '0.1'
}

function _M.set(self, opt)
    local conf = {
        key = opt and opt.key or "hi",
        value = opt and opt.value or "dummy",
        domain = opt and opt.domain or nil,
        path = opt and opt.path or nil,
        expires = opt and opt.expires or nil
    }
    local cookies = ngx.header.Set_Cookie
    if not cookies then cookies = {} end
    if type(cookies) ~= "table" then cookies = {cookies} end

    local cookie = conf.key .. "=" .. conf.value .. ";"
    if conf.domain then cookie = cookie .. " domain=" .. conf.domain .. ";" end
    if conf.path then cookie = cookie .. " path=" .. conf.path .. ";" end
    if conf.expires then cookie = cookie .. " expires=" .. conf.expires .. ";" end

    table.insert(cookies, cookie)
    ngx.header.Set_Cookie = cookies
end

return _M
