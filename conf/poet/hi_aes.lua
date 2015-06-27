local _M = {
    _VERSION = '0.1'
}
local setmetatable = setmetatable

local mt = { __index = _M }

local aes = require("resty.aes")

function _M.new(self, opt)
    local conf = {
        key = opt and opt.key or "easyhi_key_for_AES-256-CBC",
        salt = opt and opt.salt or "easyhi_SALT",
        round = opt and opt.round or 5
    }

    local encryptor = aes:new(conf.key, conf.salt,
        aes.cipher(256, "cbc"), aes.hash.sha512, conf.round)

    return setmetatable({ encryptor = encryptor }, mt)
end

function _M.encrypt (self, text)
    return ngx.encode_base64(self.encryptor:encrypt(text))
end

function _M.decrypt (self, text)
    return self.encryptor:decrypt(ngx.decode_base64(text))
end

return _M
