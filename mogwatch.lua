-- MogWatch Windower Addon
--
-- Sends live player and party status from Windower to a MogWatch companion
-- viewer (desktop app now, Android planned) over a small binary UDP/TCP
-- protocol, with an optional paired/encrypted mode for non-loopback use.
--
-- MogWatch started as a Windower-side rebuild of the ideas in the Ashita
-- addon VanaDeck (https://github.com/Zensenshi/Vanadeck), but is its own
-- project from here: the wire protocol below is MogWatch's own, not
-- VanaDeck's, so it will not talk to the VanaDeck app or vice versa.
--
-- STATUS (read this before reporting a "missing feature"):
--   Implemented:  pairing/encryption handshake, binary status protocol,
--                 player vitals/position/buffs, party member vitals,
--                 receiving chat/macro text from a viewer and typing it in.
--   Not yet built: target frame, cast bar, npc/mob map layer, macro book
--                 display + remote macro execution, in-game chat log
--                 relay, exp tracking, ctrl+arrow subtarget paging.
--   Each of these needs its own Windower packet/memory work (see the
--   comments near build_status() below for exactly where to extend this
--   file).
--
-- Usage:
--   //mogwatch                  -- show current bridge target/state
--   //mogwatch host <address>   -- set the app's IP (loopback needs no pairing)
--   //mogwatch port <number>    -- set the bridge port (must match the app)
--   //mogwatch pair <code>      -- pair using the code shown in the app
--   //mogwatch unpair           -- clear pairing
--   //mogwatch chatdebug        -- toggle a hex dump of captured chat lines
--                                  to the console, for diagnosing garbled
--                                  text (system-message color markup, etc.)
--   //mogwatch buffdebug        -- toggle console logging of raw buff-timer
--                                  packet values (off by default -- this is
--                                  only useful if a timer ever looks wrong)
--   //mogwatch chatmode <N> on|off -- show/hide a chat mode number in the
--                                  relay -- only player chat, Unity, and
--                                  confirmed system modes are shown by
--                                  default (see chat_channel_modes)
--   //mogwatch chatmode          -- list currently shown chat modes
--   //mogwatch chatname <N> <label> -- label a chat mode with its real
--                                  channel name (e.g. "Linkshell"), once
--                                  you've identified it -- shown in the
--                                  viewer instead of "Mode N"
--   //mogwatch chatname          -- list currently assigned labels
--   //mogwatch buffinfo <id>     -- dump all real fields of a res.buffs
--                                  entry (e.g. buffinfo 2 for Poison) --
--                                  for fixing the buff/debuff classification
--   //mogwatch commandtest       -- force a fresh command-channel connect
--                                  attempt with guaranteed console output --
--                                  useful if Counter tab buttons say
--                                  "not connected" and the reason isn't
--                                  obvious from the normal one-time log line
--   //mogwatch commanddebug      -- toggle detailed logging of every stage
--                                  of receiving/executing a command sent
--                                  from the viewer (raw bytes in, line
--                                  extracted, chat.input result) -- for
--                                  diagnosing "nothing happens when I
--                                  click a Counter tab button"

_addon.name = 'MogWatch'
_addon.author = 'MogWatch contributors (Windower port)'
_addon.version = '0.1.0'
_addon.commands = {'mogwatch', 'counter', 'cnt'}

local function create_text_encoding_converter()
    local ffiOk, ffi = pcall(require, 'ffi')
    if not ffiOk then
        return nil
    end

    pcall(ffi.cdef, [[
        int MultiByteToWideChar(unsigned int CodePage, unsigned int dwFlags, const char* lpMultiByteStr, int cbMultiByte, wchar_t* lpWideCharStr, int cchWideChar);
        int WideCharToMultiByte(unsigned int CodePage, unsigned int dwFlags, const wchar_t* lpWideCharStr, int cchWideChar, char* lpMultiByteStr, int cbMultiByte, const char* lpDefaultChar, int* lpUsedDefaultChar);
    ]])

    local code_page = {
        utf8 = 65001,
        shiftjis = 932,
    }

    local function convert_string(input, codepage_from, codepage_to)
        if type(input) ~= 'string' or input == '' then
            return input
        end

        local ok, converted = pcall(function()
            local input_buffer = ffi.new('char[?]', #input + 1)
            ffi.copy(input_buffer, input)

            local wide_length = ffi.C.MultiByteToWideChar(codepage_from, 0, input_buffer, -1, nil, 0)
            if wide_length <= 0 then
                return input
            end

            local wide_buffer = ffi.new('wchar_t[?]', wide_length)
            if ffi.C.MultiByteToWideChar(codepage_from, 0, input_buffer, -1, wide_buffer, wide_length) <= 0 then
                return input
            end

            local output_length = ffi.C.WideCharToMultiByte(codepage_to, 0, wide_buffer, -1, nil, 0, nil, nil)
            if output_length <= 0 then
                return input
            end

            local output_buffer = ffi.new('char[?]', output_length)
            if ffi.C.WideCharToMultiByte(codepage_to, 0, wide_buffer, -1, output_buffer, output_length, nil, nil) <= 0 then
                return input
            end

            return ffi.string(output_buffer)
        end)

        if ok and type(converted) == 'string' then
            return converted
        end

        return input
    end

    return {
        shiftjis_to_utf8 = function(input)
            return convert_string(input, code_page.shiftjis, code_page.utf8)
        end,
        utf8_to_shiftjis = function(input)
            return convert_string(input, code_page.utf8, code_page.shiftjis)
        end,
    }
end

local text_encoding = nil

local function is_valid_utf8(input)
    if type(input) ~= 'string' then
        return false
    end

    local index = 1
    local length = #input
    while index <= length do
        local byte = input:byte(index)
        local extra = 0
        local min_codepoint = 0
        local codepoint = 0

        if byte <= 0x7F then
            index = index + 1
        elseif byte >= 0xC2 and byte <= 0xDF then
            extra = 1
            min_codepoint = 0x80
            codepoint = byte - 0xC0
        elseif byte >= 0xE0 and byte <= 0xEF then
            extra = 2
            min_codepoint = 0x800
            codepoint = byte - 0xE0
        elseif byte >= 0xF0 and byte <= 0xF4 then
            extra = 3
            min_codepoint = 0x10000
            codepoint = byte - 0xF0
        else
            return false
        end

        if extra > 0 then
            if index + extra > length then
                return false
            end

            for offset = 1, extra do
                local continuation = input:byte(index + offset)
                if continuation < 0x80 or continuation > 0xBF then
                    return false
                end
                codepoint = (codepoint * 0x40) + (continuation - 0x80)
            end

            if codepoint < min_codepoint or codepoint > 0x10FFFF or
                (codepoint >= 0xD800 and codepoint <= 0xDFFF) then
                return false
            end
            index = index + extra + 1
        end
    end

    return true
end

local function shiftjis_to_utf8_if_needed(input)
    if type(input) ~= 'string' or input == '' then
        return input
    end
    if is_valid_utf8(input) then
        return input
    end
    if text_encoding then
        return text_encoding.shiftjis_to_utf8(input)
    end
    return input
end

local function create_json_encoder()
    local ok, json = pcall(require, 'json')
    if ok and json and json.encode then
        return json
    end

    ok, json = pcall(require, 'cjson')
    if ok and json and json.encode then
        return json
    end

    local function escape_string(value)
        return '"' .. tostring(value):gsub('[%z\1-\31\\"]', function(c)
            local escapes = {
                ['\\'] = '\\\\',
                ['"'] = '\\"',
                ['\b'] = '\\b',
                ['\f'] = '\\f',
                ['\n'] = '\\n',
                ['\r'] = '\\r',
                ['\t'] = '\\t',
            }
            return escapes[c] or string.format('\\u%04x', c:byte())
        end) .. '"'
    end

    local encode
    encode = function(value)
        local valueType = type(value)
        if valueType == 'nil' then
            return 'null'
        end
        if valueType == 'boolean' then
            return tostring(value)
        end
        if valueType == 'number' then
            return tostring(value)
        end
        if valueType == 'string' then
            return escape_string(value)
        end
        if valueType == 'table' then
            local isArray = true
            local count = 0
            for key, _ in pairs(value) do
                count = count + 1
                if type(key) ~= 'number' then
                    isArray = false
                end
            end

            local parts = {}
            if isArray then
                for index = 1, count do
                    table.insert(parts, encode(value[index]))
                end
                return '[' .. table.concat(parts, ',') .. ']'
            end

            for key, item in pairs(value) do
                table.insert(parts, escape_string(key) .. ':' .. encode(item))
            end
            return '{' .. table.concat(parts, ',') .. '}'
        end

        return 'null'
    end

    return { encode = encode }
end

local protocol_magic = 'MOG'
local protocol_version = 1
local protocol_header_size = 10
local protocol_max_payload_size = 1024 * 1024
local protocol_type_status = 1
local protocol_type_command = 2
local protocol_type_hello = 3
local ashita_command_mode_typed = (type(CommandMode) == 'table' and CommandMode.Typed) or 1
local ashita_command_mode_macro = (type(CommandMode) == 'table' and CommandMode.Macro) or 2
local protocol_value_null = 0
local protocol_value_false = 1
local protocol_value_true = 2
local protocol_value_positive_int = 3
local protocol_value_negative_int = 4
local protocol_value_float = 5
local protocol_value_string = 6
local protocol_value_list = 7
local protocol_value_map = 8

local function protocol_encode_varuint(value)
    value = math.floor(tonumber(value) or 0)
    if value < 0 then
        value = 0
    end

    local bytes = {}
    repeat
        local byte = value % 128
        value = math.floor(value / 128)
        if value > 0 then
            byte = byte + 128
        end
        bytes[#bytes + 1] = string.char(byte)
    until value == 0
    return table.concat(bytes)
end

local function protocol_encode_string_payload(value)
    value = tostring(value or '')
    return protocol_encode_varuint(#value) .. value
end

local function protocol_is_array(value)
    local count = 0
    local maxIndex = 0
    for key, _ in pairs(value) do
        if type(key) ~= 'number' or key < 1 or key ~= math.floor(key) then
            return false, 0
        end
        count = count + 1
        if key > maxIndex then
            maxIndex = key
        end
    end
    return count == maxIndex, maxIndex
end

local protocol_encode_value
protocol_encode_value = function(value)
    local valueType = type(value)
    if valueType == 'nil' then
        return string.char(protocol_value_null)
    end
    if valueType == 'boolean' then
        return string.char(value and protocol_value_true or protocol_value_false)
    end
    if valueType == 'number' then
        if value == math.floor(value) then
            if value < 0 then
                return string.char(protocol_value_negative_int) .. protocol_encode_varuint(-value)
            end
            return string.char(protocol_value_positive_int) .. protocol_encode_varuint(value)
        end
        return string.char(protocol_value_float) .. protocol_encode_string_payload(tostring(value))
    end
    if valueType == 'string' then
        return string.char(protocol_value_string) .. protocol_encode_string_payload(value)
    end
    if valueType == 'table' then
        local isArray, length = protocol_is_array(value)
        local parts = {}
        if isArray then
            parts[#parts + 1] = string.char(protocol_value_list)
            parts[#parts + 1] = protocol_encode_varuint(length)
            for index = 1, length do
                parts[#parts + 1] = protocol_encode_value(value[index])
            end
            return table.concat(parts)
        end

        local count = 0
        for _, _ in pairs(value) do
            count = count + 1
        end
        parts[#parts + 1] = string.char(protocol_value_map)
        parts[#parts + 1] = protocol_encode_varuint(count)
        for key, item in pairs(value) do
            parts[#parts + 1] = protocol_encode_string_payload(tostring(key))
            parts[#parts + 1] = protocol_encode_value(item)
        end
        return table.concat(parts)
    end

    return string.char(protocol_value_null)
end

local function protocol_encode_uint32_be(value)
    value = math.floor(tonumber(value) or 0)
    local b1 = math.floor(value / 16777216) % 256
    local b2 = math.floor(value / 65536) % 256
    local b3 = math.floor(value / 256) % 256
    local b4 = value % 256
    return string.char(b1, b2, b3, b4)
end

local function protocol_decode_uint32_be(data, index)
    local b1, b2, b3, b4 = data:byte(index, index + 3)
    if not b4 then
        return nil
    end
    return ((b1 * 256 + b2) * 256 + b3) * 256 + b4
end

local function protocol_encode_frame(messageType, payload)
    local encodedPayload = protocol_encode_value(payload)
    local payloadLength = #encodedPayload
    if payloadLength > protocol_max_payload_size then
        return nil, 'payload too large'
    end

    return table.concat({
        protocol_magic,
        string.char(protocol_version, messageType, 0),
        protocol_encode_uint32_be(payloadLength),
        encodedPayload,
    })
end

local function protocol_decode_varuint(data, index, limit)
    local value = 0
    local multiplier = 1
    while index <= limit do
        local byte = data:byte(index)
        value = value + (byte % 128) * multiplier
        index = index + 1
        if byte < 128 then
            return value, index
        end
        multiplier = multiplier * 128
        if multiplier > 9007199254740991 then
            return nil, index, 'varuint too large'
        end
    end
    return nil, index, 'truncated varuint'
end

local function protocol_decode_string_payload(data, index, limit)
    local length, nextIndex, err = protocol_decode_varuint(data, index, limit)
    if not length then
        return nil, nextIndex, err
    end
    local endIndex = nextIndex + length - 1
    if endIndex > limit then
        return nil, nextIndex, 'truncated string'
    end
    return data:sub(nextIndex, endIndex), endIndex + 1
end

local protocol_decode_value
protocol_decode_value = function(data, index, limit)
    if index > limit then
        return nil, index, 'truncated value'
    end

    local valueType = data:byte(index)
    index = index + 1
    if valueType == protocol_value_null then
        return nil, index
    end
    if valueType == protocol_value_false then
        return false, index
    end
    if valueType == protocol_value_true then
        return true, index
    end
    if valueType == protocol_value_positive_int then
        return protocol_decode_varuint(data, index, limit)
    end
    if valueType == protocol_value_negative_int then
        local value, nextIndex, err = protocol_decode_varuint(data, index, limit)
        if not value then
            return nil, nextIndex, err
        end
        return -value, nextIndex
    end
    if valueType == protocol_value_float then
        local value, nextIndex, err = protocol_decode_string_payload(data, index, limit)
        if not value then
            return nil, nextIndex, err
        end
        return tonumber(value), nextIndex
    end
    if valueType == protocol_value_string then
        return protocol_decode_string_payload(data, index, limit)
    end
    if valueType == protocol_value_list then
        local length, nextIndex, err = protocol_decode_varuint(data, index, limit)
        if not length then
            return nil, nextIndex, err
        end

        local values = {}
        index = nextIndex
        for itemIndex = 1, length do
            local item
            item, index, err = protocol_decode_value(data, index, limit)
            if err then
                return nil, index, err
            end
            values[itemIndex] = item
        end
        return values, index
    end
    if valueType == protocol_value_map then
        local length, nextIndex, err = protocol_decode_varuint(data, index, limit)
        if not length then
            return nil, nextIndex, err
        end

        local values = {}
        index = nextIndex
        for _ = 1, length do
            local key
            key, index, err = protocol_decode_string_payload(data, index, limit)
            if err then
                return nil, index, err
            end
            local item
            item, index, err = protocol_decode_value(data, index, limit)
            if err then
                return nil, index, err
            end
            values[key] = item
        end
        return values, index
    end

    return nil, index, 'unknown value type'
end

local function protocol_decode_frame(data)
    if #data < protocol_header_size or data:sub(1, #protocol_magic) ~= protocol_magic then
        return nil, 'invalid frame'
    end

    local version = data:byte(4)
    if version ~= protocol_version then
        return nil, 'unsupported version'
    end

    local messageType = data:byte(5)
    local payloadLength = protocol_decode_uint32_be(data, 7)
    if not payloadLength or payloadLength > protocol_max_payload_size then
        return nil, 'invalid payload length'
    end
    if #data ~= protocol_header_size + payloadLength then
        return nil, 'frame length mismatch'
    end

    local payload, nextIndex, err = protocol_decode_value(data, protocol_header_size + 1, #data)
    if err then
        return nil, err
    end
    if nextIndex ~= #data + 1 then
        return nil, 'trailing payload bytes'
    end

    return {
        version = version,
        messageType = messageType,
        payload = payload,
    }
end

local function protocol_buffer_has_magic_prefix(buffer)
    if #buffer == 0 then
        return false
    end
    local length = math.min(#buffer, #protocol_magic)
    return buffer:sub(1, length) == protocol_magic:sub(1, length)
end

local bridge = (function()

local crypto = {}

local crypto_bit_ok, crypto_bit = pcall(require, 'bit')
if not crypto_bit_ok then
    crypto_bit = bit
end


if crypto_bit and crypto_bit.band then
    local band, bxor, bor, bnot = crypto_bit.band, crypto_bit.bxor, crypto_bit.bor, crypto_bit.bnot
    local rshift, lshift = crypto_bit.rshift, crypto_bit.lshift
    local ror, tobit = crypto_bit.ror, crypto_bit.tobit

    local sha256_k = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
        0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
        0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
        0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
        0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    }

    local function be32(value)
        return string.char(
            band(rshift(value, 24), 0xFF),
            band(rshift(value, 16), 0xFF),
            band(rshift(value, 8), 0xFF),
            band(value, 0xFF)
        )
    end

    -- The length field is 64 bits and can exceed what the bit ops handle, so
    -- it is built with arithmetic rather than shifts.
    local function be64(value)
        local bytes = {}
        for index = 8, 1, -1 do
            bytes[index] = string.char(value % 256)
            value = math.floor(value / 256)
        end
        return table.concat(bytes)
    end

    function crypto.sha256(message)
        local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
        local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

        local bitLength = #message * 8
        local padded = message .. '\128'
        local remainder = #padded % 64
        local padLength = (remainder <= 56) and (56 - remainder) or (120 - remainder)
        padded = padded .. string.rep('\0', padLength) .. be64(bitLength)

        local w = {}
        for chunk = 1, #padded, 64 do
            for index = 1, 16 do
                local offset = chunk + (index - 1) * 4
                local b1, b2, b3, b4 = padded:byte(offset, offset + 3)
                w[index] = bor(lshift(b1, 24), lshift(b2, 16), lshift(b3, 8), b4)
            end
            for index = 17, 64 do
                local x, y = w[index - 15], w[index - 2]
                local s0 = bxor(ror(x, 7), ror(x, 18), rshift(x, 3))
                local s1 = bxor(ror(y, 17), ror(y, 19), rshift(y, 10))
                w[index] = tobit(w[index - 16] + s0 + w[index - 7] + s1)
            end

            local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
            for index = 1, 64 do
                local s1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
                local ch = bxor(band(e, f), band(bnot(e), g))
                local temp1 = tobit(h + s1 + ch + sha256_k[index] + w[index])
                local s0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
                local maj = bxor(band(a, b), band(a, c), band(b, c))
                local temp2 = tobit(s0 + maj)

                h = g
                g = f
                f = e
                e = tobit(d + temp1)
                d = c
                c = b
                b = a
                a = tobit(temp1 + temp2)
            end

            h0 = tobit(h0 + a)
            h1 = tobit(h1 + b)
            h2 = tobit(h2 + c)
            h3 = tobit(h3 + d)
            h4 = tobit(h4 + e)
            h5 = tobit(h5 + f)
            h6 = tobit(h6 + g)
            h7 = tobit(h7 + h)
        end

        return be32(h0) .. be32(h1) .. be32(h2) .. be32(h3)
            .. be32(h4) .. be32(h5) .. be32(h6) .. be32(h7)
    end

    function crypto.hmac_sha256(key, message)
        if #key > 64 then
            key = crypto.sha256(key)
        end
        key = key .. string.rep('\0', 64 - #key)

        local outer, inner = {}, {}
        for index = 1, 64 do
            local byte = key:byte(index)
            outer[index] = string.char(bxor(byte, 0x5C))
            inner[index] = string.char(bxor(byte, 0x36))
        end

        return crypto.sha256(
            table.concat(outer) .. crypto.sha256(table.concat(inner) .. message))
    end

    function crypto.hkdf_sha256(ikm, salt, info, length)
        if salt == nil or #salt == 0 then
            salt = string.rep('\0', 32)
        end
        info = info or ''

        local prk = crypto.hmac_sha256(salt, ikm)
        local okm, block, counter = '', '', 1
        while #okm < length do
            block = crypto.hmac_sha256(prk, block .. info .. string.char(counter))
            okm = okm .. block
            counter = counter + 1
        end
        return okm:sub(1, length)
    end

    -- Compares without an early return so a rejected proof leaks nothing about
    -- how many leading bytes were right.
    function crypto.constant_time_equals(a, b)
        if type(a) ~= 'string' or type(b) ~= 'string' or #a ~= #b then
            return false
        end
        local difference = 0
        for index = 1, #a do
            difference = bor(difference, bxor(a:byte(index), b:byte(index)))
        end
        return difference == 0
    end
end

function crypto.to_hex(value)
    return (value:gsub('.', function(character)
        return string.format('%02x', character:byte())
    end))
end

function crypto.from_hex(value)
    if type(value) ~= 'string' or #value % 2 ~= 0 or value:find('[^0-9a-fA-F]') then
        return nil
    end
    return (value:gsub('%x%x', function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

-- Crockford base32 without I, L, O and U, matching the app's pairing screen.
local pairing_alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
local pairing_code_length = 20

function crypto.normalize_pairing_code(code)
    if type(code) ~= 'string' then
        return nil
    end

    local normalized = {}
    for index = 1, #code do
        local character = code:sub(index, index):upper()
        if character ~= ' ' and character ~= '-' and character ~= '_' then
            if character == 'O' then
                character = '0'
            elseif character == 'I' or character == 'L' then
                character = '1'
            end
            if not pairing_alphabet:find(character, 1, true) then
                return nil
            end
            normalized[#normalized + 1] = character
        end
    end

    if #normalized ~= pairing_code_length then
        return nil
    end
    return table.concat(normalized)
end

function crypto.secret_from_pairing_code(code)
    local normalized = crypto.normalize_pairing_code(code)
    if not normalized or not crypto.hkdf_sha256 then
        return nil
    end
    return crypto.hkdf_sha256(
        normalized, 'mogwatch-pair-v1', 'mogwatch-bridge-secret', 32)
end

-- ChaCha20 (RFC 8439) with the block counter starting at zero, matching the
-- app's stream cipher.
--
-- ChaCha20 rather than AES because neither side has AES hardware it can reach:
-- the app runs pure Dart on the phone, and this runs pure Lua. It also means
-- the bridge no longer depends on any platform crypto library, so it behaves
-- the same under Wine and Proton as it does on Windows.
if crypto.sha256 then
    local band, bxor, bor = crypto_bit.band, crypto_bit.bxor, crypto_bit.bor
    local lshift, rshift, rol = crypto_bit.lshift, crypto_bit.rshift, crypto_bit.rol
    local tobit = crypto_bit.tobit
    local byte, char, concat = string.byte, string.char, table.concat

    local function le32(data, index)
        local b1, b2, b3, b4 = byte(data, index, index + 3)
        return bor(b1, lshift(b2, 8), lshift(b3, 16), lshift(b4, 24))
    end

    local block_words = {}

    local function chacha20_block(key, counter, nonce)
        local x0, x1, x2, x3 = 0x61707865, 0x3320646e, 0x79622d32, 0x6b206574
        local x4, x5, x6, x7 = le32(key, 1), le32(key, 5), le32(key, 9), le32(key, 13)
        local x8, x9, x10, x11 = le32(key, 17), le32(key, 21), le32(key, 25), le32(key, 29)
        local x12 = tobit(counter)
        local x13, x14, x15 = le32(nonce, 1), le32(nonce, 5), le32(nonce, 9)

        local s0, s1, s2, s3 = x0, x1, x2, x3
        local s4, s5, s6, s7 = x4, x5, x6, x7
        local s8, s9, s10, s11 = x8, x9, x10, x11
        local s12, s13, s14, s15 = x12, x13, x14, x15

        for _ = 1, 10 do
            x0 = tobit(x0 + x4); x12 = rol(bxor(x12, x0), 16)
            x8 = tobit(x8 + x12); x4 = rol(bxor(x4, x8), 12)
            x0 = tobit(x0 + x4); x12 = rol(bxor(x12, x0), 8)
            x8 = tobit(x8 + x12); x4 = rol(bxor(x4, x8), 7)

            x1 = tobit(x1 + x5); x13 = rol(bxor(x13, x1), 16)
            x9 = tobit(x9 + x13); x5 = rol(bxor(x5, x9), 12)
            x1 = tobit(x1 + x5); x13 = rol(bxor(x13, x1), 8)
            x9 = tobit(x9 + x13); x5 = rol(bxor(x5, x9), 7)

            x2 = tobit(x2 + x6); x14 = rol(bxor(x14, x2), 16)
            x10 = tobit(x10 + x14); x6 = rol(bxor(x6, x10), 12)
            x2 = tobit(x2 + x6); x14 = rol(bxor(x14, x2), 8)
            x10 = tobit(x10 + x14); x6 = rol(bxor(x6, x10), 7)

            x3 = tobit(x3 + x7); x15 = rol(bxor(x15, x3), 16)
            x11 = tobit(x11 + x15); x7 = rol(bxor(x7, x11), 12)
            x3 = tobit(x3 + x7); x15 = rol(bxor(x15, x3), 8)
            x11 = tobit(x11 + x15); x7 = rol(bxor(x7, x11), 7)

            x0 = tobit(x0 + x5); x15 = rol(bxor(x15, x0), 16)
            x10 = tobit(x10 + x15); x5 = rol(bxor(x5, x10), 12)
            x0 = tobit(x0 + x5); x15 = rol(bxor(x15, x0), 8)
            x10 = tobit(x10 + x15); x5 = rol(bxor(x5, x10), 7)

            x1 = tobit(x1 + x6); x12 = rol(bxor(x12, x1), 16)
            x11 = tobit(x11 + x12); x6 = rol(bxor(x6, x11), 12)
            x1 = tobit(x1 + x6); x12 = rol(bxor(x12, x1), 8)
            x11 = tobit(x11 + x12); x6 = rol(bxor(x6, x11), 7)

            x2 = tobit(x2 + x7); x13 = rol(bxor(x13, x2), 16)
            x8 = tobit(x8 + x13); x7 = rol(bxor(x7, x8), 12)
            x2 = tobit(x2 + x7); x13 = rol(bxor(x13, x2), 8)
            x8 = tobit(x8 + x13); x7 = rol(bxor(x7, x8), 7)

            x3 = tobit(x3 + x4); x14 = rol(bxor(x14, x3), 16)
            x9 = tobit(x9 + x14); x4 = rol(bxor(x4, x9), 12)
            x3 = tobit(x3 + x4); x14 = rol(bxor(x14, x3), 8)
            x9 = tobit(x9 + x14); x4 = rol(bxor(x4, x9), 7)
        end

        block_words[1] = tobit(x0 + s0); block_words[2] = tobit(x1 + s1)
        block_words[3] = tobit(x2 + s2); block_words[4] = tobit(x3 + s3)
        block_words[5] = tobit(x4 + s4); block_words[6] = tobit(x5 + s5)
        block_words[7] = tobit(x6 + s6); block_words[8] = tobit(x7 + s7)
        block_words[9] = tobit(x8 + s8); block_words[10] = tobit(x9 + s9)
        block_words[11] = tobit(x10 + s10); block_words[12] = tobit(x11 + s11)
        block_words[13] = tobit(x12 + s12); block_words[14] = tobit(x13 + s13)
        block_words[15] = tobit(x14 + s14); block_words[16] = tobit(x15 + s15)
        return block_words
    end

    function crypto.chacha20(key, counter, nonce, message)
        local pieces = {}
        local out = {}
        local length = #message
        local offset = 0
        local blockIndex = counter

        while offset < length do
            local words = chacha20_block(key, blockIndex, nonce)
            local remaining = length - offset
            local chunk = remaining < 64 and remaining or 64

            for wordIndex = 1, 16 do
                local base = (wordIndex - 1) * 4
                if base >= chunk then
                    break
                end
                local word = words[wordIndex]
                local last = chunk - base
                if last > 4 then
                    last = 4
                end
                for lane = 1, last do
                    out[base + lane] = char(bxor(
                        byte(message, offset + base + lane),
                        band(rshift(word, (lane - 1) * 8), 0xFF)))
                end
            end

            pieces[#pieces + 1] = concat(out, '', 1, chunk)
            offset = offset + chunk
            blockIndex = blockIndex + 1
        end

        return concat(pieces)
    end

    -- Encrypt-then-MAC, matching the app: ChaCha20 for confidentiality, then
    -- HMAC-SHA256 truncated to 16 bytes over the associated data and the
    -- ciphertext.
    function crypto.seal(encryptionKey, macKey, nonce, aad, plaintext)
        local ciphertext = crypto.chacha20(encryptionKey, 0, nonce, plaintext)
        local tag = crypto.hmac_sha256(macKey, aad .. ciphertext):sub(1, 16)
        return ciphertext .. tag
    end

    -- Verifies before decrypting, and returns nil on any mismatch.
    function crypto.open(encryptionKey, macKey, nonce, aad, ciphertext)
        if #ciphertext < 16 then
            return nil
        end

        local body = ciphertext:sub(1, #ciphertext - 16)
        local tag = ciphertext:sub(#ciphertext - 15)
        local expected = crypto.hmac_sha256(macKey, aad .. body):sub(1, 16)
        if not crypto.constant_time_equals(tag, expected) then
            return nil
        end

        return crypto.chacha20(encryptionKey, 0, nonce, body)
    end
end

-- Random bytes for the handshake nonce.
--
-- Both Windows entry points are tried because neither is guaranteed: this has
-- to work under Wine and Proton as well as native Windows.
--
-- There is deliberately no software fallback. A guessable nonce here would not
-- make the session key guessable -- the key is derived from both nonces and
-- the app's is always cryptographically random -- but it would let a recorded
-- app handshake be replayed back at the addon. A replay that lands on a
-- repeated nonce reproduces the earlier session's keys, and two recordings
-- under one ChaCha20 keystream expose both. Refusing to pair is the safe
-- failure; loopback does not use this path at all.
local random_source = (function()
    local ffiOk, ffi = pcall(require, 'ffi')
    if ffiOk and ffi then
        pcall(ffi.cdef, [[
            long BCryptGenRandom(void* hAlgorithm, unsigned char* pbBuffer, unsigned long cbBuffer, unsigned long dwFlags);
            int SystemFunction036(void* RandomBuffer, unsigned long RandomBufferLength);
        ]])

        -- Each probe checks the call's result, not merely that it returned.
        -- A build that exports the symbol but fails the call -- which is the
        -- shape a partial Wine or Proton implementation takes -- would
        -- otherwise capture the chain here and stop everything below from ever
        -- being tried, leaving no source at all and refusing to pair.
        local bcryptOk, bcrypt = pcall(ffi.load, 'bcrypt')
        if bcryptOk and bcrypt then
            local probe = ffi.new('unsigned char[?]', 8)
            -- 2 = BCRYPT_USE_SYSTEM_PREFERRED_RNG, so no provider handle is
            -- needed. 0 is STATUS_SUCCESS; anything else is a failure.
            local called, status = pcall(function()
                return bcrypt.BCryptGenRandom(nil, probe, 8, 2)
            end)
            if called and status == 0 then
                return function(length)
                    local buffer = ffi.new('unsigned char[?]', length)
                    if bcrypt.BCryptGenRandom(nil, buffer, length, 2) ~= 0 then
                        return nil
                    end
                    return ffi.string(buffer, length)
                end
            end
        end

        local advapiOk, advapi = pcall(ffi.load, 'advapi32')
        if advapiOk and advapi then
            local probe = ffi.new('unsigned char[?]', 8)
            -- RtlGenRandom reports the opposite way round: non-zero is success.
            local called, ok = pcall(function()
                return advapi.SystemFunction036(probe, 8)
            end)
            if called and ok ~= 0 then
                return function(length)
                    local buffer = ffi.new('unsigned char[?]', length)
                    if advapi.SystemFunction036(buffer, length) == 0 then
                        return nil
                    end
                    return ffi.string(buffer, length)
                end
            end
        end
    end

    -- Not present on native Windows, but it is a real kernel source wherever
    -- it does exist: some Wine and Proton layouts expose the host's, and it is
    -- what the addon test harness runs against. Unlike the removed fallback,
    -- this is not a guess at entropy.
    local urandomOk, urandom = pcall(io.open, '/dev/urandom', 'rb')
    if urandomOk and urandom then
        return function(length)
            local bytes = urandom:read(length)
            if bytes and #bytes == length then
                return bytes
            end
            return nil
        end
    end

    return nil
end)()

function crypto.random_bytes(length)
    if not random_source then
        return nil
    end
    local bytes = random_source(length)
    if bytes and #bytes == length then
        return bytes
    end
    return nil
end

function crypto.has_secure_random()
    return random_source ~= nil
end

function crypto.is_available()
    return crypto.chacha20 ~= nil
        and crypto.hkdf_sha256 ~= nil
        and random_source ~= nil
end

function crypto.unavailable_reason()
    if not crypto.hkdf_sha256 or not crypto.chacha20 then
        return 'LuaJIT bit library unavailable'
    end
    if not random_source then
        return 'no system random number generator; bcrypt and advapi32 are '
            .. 'both unreachable, so a paired connection cannot be made '
            .. 'safely. Use a loopback host (Winlator, or USB with '
            .. '`adb reverse`) instead'
    end
    return 'unknown'
end

local protocol_type_auth_challenge = 4
local protocol_type_auth_response = 5
local protocol_type_sealed = 6

-- The 10-byte header. A sealed frame authenticates it alongside the
-- ciphertext, so a tampered length or type fails the tag.
local function sealed_header(payloadLength)
    return table.concat({
        protocol_magic,
        string.char(protocol_version, protocol_type_sealed, 0),
        protocol_encode_uint32_be(payloadLength),
    })
end

return {
    crypto = crypto,
    type_auth_challenge = protocol_type_auth_challenge,
    type_auth_response = protocol_type_auth_response,
    type_sealed = protocol_type_sealed,
    sealed_header = sealed_header,
}

end)()

-- How a receive error should be treated.
--
-- The transports report three different situations through one channel, and
-- telling them apart is what keeps the link alive:
--
--   'retry'  nothing to read yet. The ordinary case on a non-blocking socket,
--            reached once per frame, and it must leave the connection alone.
--   'closed' a clean hangup: the app exited, or the phone slept.
--   'failed' a dead socket -- a reset, or an adapter that went away.
--
-- The last one has to clear `client`. connect_client() returns early while a
-- connection is held, so a dead socket left in place stops status for good
-- with nothing said until the addon is reloaded by hand.
--
-- Hung off `bridge` rather than declared as a local: the chunk is at Lua's
-- 200-local ceiling, and one more fails to load with an error that does not
-- point at the cause.
bridge.classify_receive_error = function(err)
    if err == nil or err == 'timeout' or err == 'wantread' then
        return 'retry'
    end
    if err == 'closed' then
        return 'closed'
    end
    return 'failed'
end
local function create_socket_transport()
    local ok, socket = pcall(require, 'socket')
    if ok and socket and socket.tcp then
        return socket, 'LuaSocket'
    end

    local ffiOk, ffi = pcall(require, 'ffi')
    if not ffiOk then
        return nil, 'LuaJIT FFI unavailable'
    end

    local cdefOk, cdefErr = pcall(ffi.cdef, [[
        typedef unsigned short u_short;
        typedef unsigned long u_long;
        typedef uintptr_t SOCKET;

        typedef struct WSAData {
            unsigned short wVersion;
            unsigned short wHighVersion;
            char szDescription[257];
            char szSystemStatus[129];
            unsigned short iMaxSockets;
            unsigned short iMaxUdpDg;
            char* lpVendorInfo;
        } WSADATA;

        struct in_addr {
            unsigned long s_addr;
        };

        struct sockaddr {
            unsigned short sa_family;
            char sa_data[14];
        };

        struct sockaddr_in {
            short sin_family;
            unsigned short sin_port;
            struct in_addr sin_addr;
            char sin_zero[8];
        };

        int WSAStartup(unsigned short wVersionRequested, WSADATA* lpWSAData);
        int WSACleanup(void);
        SOCKET socket(int af, int type, int protocol);
        int connect(SOCKET s, const struct sockaddr* name, int namelen);
        int ioctlsocket(SOCKET s, long cmd, u_long* argp);
        int recv(SOCKET s, char* buf, int len, int flags);
        int send(SOCKET s, const char* buf, int len, int flags);
        int closesocket(SOCKET s);
        unsigned short htons(unsigned short hostshort);
        unsigned long inet_addr(const char* cp);
        int WSAGetLastError(void);
    ]])
    if not cdefOk and not tostring(cdefErr):find('redefine') then
        return nil, 'WinSock definitions failed: ' .. tostring(cdefErr)
    end

    local loadOk, ws2 = pcall(ffi.load, 'Ws2_32')
    if not loadOk then
        return nil, 'WinSock library load failed: ' .. tostring(ws2)
    end

    local wsaData = ffi.new('WSADATA[1]')
    if ws2.WSAStartup(0x0202, wsaData) ~= 0 then
        return nil, 'WinSock startup failed'
    end

    local transport = {}
    transport.tcp = function()
        local rawSocket = nil
        local receiveBuffer = ''
        local wrapper = {}

        wrapper.settimeout = function() end

        wrapper.connect = function(_, address, targetPort)
            rawSocket = ws2.socket(2, 1, 6)
            if rawSocket == ffi.cast('SOCKET', -1) then
                return nil, 'socket failed: ' .. tostring(ws2.WSAGetLastError())
            end

            local sockaddr = ffi.new('struct sockaddr_in')
            sockaddr.sin_family = 2
            sockaddr.sin_port = ws2.htons(targetPort)
            sockaddr.sin_addr.s_addr = ws2.inet_addr(address)

            local result = ws2.connect(rawSocket, ffi.cast('const struct sockaddr*', sockaddr), ffi.sizeof(sockaddr))
            if result ~= 0 then
                local err = ws2.WSAGetLastError()
                ws2.closesocket(rawSocket)
                rawSocket = nil
                return nil, 'connect failed: ' .. tostring(err)
            end

            local nonblocking = ffi.new('u_long[1]', 1)
            ws2.ioctlsocket(rawSocket, 0x8004667E, nonblocking)

            return true
        end

        -- Returns LuaSocket's convention: the byte count on success, or
        -- nil plus a reason plus how much did go out. Reporting the partial
        -- count matters on a non-blocking socket: a large status frame will
        -- fill the send buffer part way through, and a caller that assumed
        -- nothing was written would resend those bytes and desynchronise the
        -- stream.
        wrapper.send = function(_, payload)
            if rawSocket == nil then
                return nil, 'not connected', 0
            end

            local total = 0
            local length = #payload
            while total < length do
                local chunk = payload:sub(total + 1)
                local sent = ws2.send(rawSocket, chunk, #chunk, 0)
                if sent < 0 then
                    local code = ws2.WSAGetLastError()
                    -- WSAEWOULDBLOCK: the buffer is full, not a failure. The
                    -- caller retries with what is left on the next tick.
                    if code == 10035 then
                        return nil, 'timeout', total
                    end
                    return nil, 'send failed: ' .. tostring(code), total
                end
                if sent == 0 then
                    return nil, 'send failed: connection closed', total
                end
                total = total + sent
            end

            return total
        end

        wrapper.receive = function(_, pattern)
            if rawSocket == nil then
                return nil, 'not connected'
            end

            if type(pattern) == 'number' then
                if #receiveBuffer > 0 then
                    local chunk = receiveBuffer:sub(1, pattern)
                    receiveBuffer = receiveBuffer:sub(#chunk + 1)
                    return chunk
                end

                local bufferLength = math.min(math.max(pattern, 1), 4096)
                local buffer = ffi.new('char[?]', bufferLength)
                local received = ws2.recv(rawSocket, buffer, bufferLength, 0)
                if received > 0 then
                    return ffi.string(buffer, received)
                end
                if received == 0 then
                    return nil, 'closed'
                end

                local err = ws2.WSAGetLastError()
                if err == 10035 then
                    return nil, 'timeout', ''
                end

                return nil, 'receive failed: ' .. tostring(err)
            end

            local newline = receiveBuffer:find('\n', 1, true)
            if newline then
                local line = receiveBuffer:sub(1, newline - 1):gsub('\r$', '')
                receiveBuffer = receiveBuffer:sub(newline + 1)
                return line
            end

            local buffer = ffi.new('char[4096]')
            local received = ws2.recv(rawSocket, buffer, 4096, 0)
            if received > 0 then
                receiveBuffer = receiveBuffer .. ffi.string(buffer, received)
                newline = receiveBuffer:find('\n', 1, true)
                if newline then
                    local line = receiveBuffer:sub(1, newline - 1):gsub('\r$', '')
                    receiveBuffer = receiveBuffer:sub(newline + 1)
                    return line
                end
                return nil, 'timeout'
            end
            if received == 0 then
                return nil, 'closed'
            end

            local err = ws2.WSAGetLastError()
            if err == 10035 then
                return nil, 'timeout'
            end

            return nil, 'receive failed: ' .. tostring(err)
        end

        wrapper.close = function()
            if rawSocket ~= nil then
                ws2.closesocket(rawSocket)
                rawSocket = nil
            end
        end

        return wrapper
    end

    transport.udp = function()
        local rawSocket = nil
        local wrapper = {}

        wrapper.settimeout = function() end

        wrapper.setpeername = function(_, address, targetPort)
            rawSocket = ws2.socket(2, 2, 17)
            if rawSocket == ffi.cast('SOCKET', -1) then
                return nil, 'socket failed: ' .. tostring(ws2.WSAGetLastError())
            end

            local sockaddr = ffi.new('struct sockaddr_in')
            sockaddr.sin_family = 2
            sockaddr.sin_port = ws2.htons(targetPort)
            sockaddr.sin_addr.s_addr = ws2.inet_addr(address)

            local result = ws2.connect(rawSocket, ffi.cast('const struct sockaddr*', sockaddr), ffi.sizeof(sockaddr))
            if result ~= 0 then
                local err = ws2.WSAGetLastError()
                ws2.closesocket(rawSocket)
                rawSocket = nil
                return nil, 'udp peer failed: ' .. tostring(err)
            end

            return true
        end

        wrapper.send = function(_, payload)
            if rawSocket == nil then
                return nil, 'not connected'
            end

            local sent = ws2.send(rawSocket, payload, #payload, 0)
            if sent < 0 then
                return nil, 'udp send failed: ' .. tostring(ws2.WSAGetLastError())
            end

            return sent
        end

        wrapper.close = function()
            if rawSocket ~= nil then
                ws2.closesocket(rawSocket)
                rawSocket = nil
            end
        end

        return wrapper
    end

    return transport, 'WinSock FFI'
end

-- ---------------------------------------------------------------------------
-- Transport + settings setup
-- ---------------------------------------------------------------------------

local json = create_json_encoder()
text_encoding = create_text_encoding_converter()
local socket, socket_source = create_socket_transport()

local res_ok, res = pcall(require, 'resources')
if not res_ok then
    res = nil
end

local config_ok, config = pcall(require, 'config')
if not config_ok then
    config = nil
end

local client = nil
local command_debug_enabled = false
local status_client = nil
local last_send = 0
local send_interval = 0.2
local full_status_interval = 1.0
local last_full_status = 0
local max_udp_payload_size = 60000

local default_host = '127.0.0.1'
local default_port = 8080

local default_settings = {
    host = default_host,
    port = default_port,
    pair = '',
    -- The chat relay only shows modes listed here -- this is the actual
    -- gate for what appears at all. Defaults to real player-to-player chat
    -- channels (Say/Shout/Yell/Tell/Party/Linkshell/Emote), Unity, and
    -- mode 135 (the one "System" mode explicitly confirmed as fine) --
    -- everything else stays hidden, including NPC conversations, general
    -- "Message" (likely battle/combat text), and any other unidentified
    -- mode, even if it's labeled below for reference.
    -- Toggle with //mogwatch chatmode <N> on|off.
    chat_channel_modes = {
        [1] = true, [2] = true, [3] = true, [4] = true, [5] = true,
        [6] = true, [7] = true, [9] = true, [10] = true, [11] = true,
        [12] = true, [13] = true, [14] = true, [135] = true, [211] = true,
        [212] = true,
    },
    -- Display labels for chat mode numbers -- used whenever a mode is
    -- shown (per chat_channel_modes above), and also kept for modes that
    -- are deliberately NOT shown by default (System, NPC, Message) in case
    -- you ever want to opt one back in with //mogwatch chatmode <N> on.
    -- Pre-filled with Windower's font-color category table plus modes
    -- confirmed directly against real observed chat. Add more with
    -- //mogwatch chatname <N> <label> as you identify them.
    chat_mode_names = {
        [1] = 'Say',
        [2] = 'Shout',
        [3] = 'Yell',
        [4] = 'Tell',
        [5] = 'Party',
        [6] = 'Linkshell',
        [7] = 'Emote',
        [9] = 'Say',
        [10] = 'Shout',
        [11] = 'Yell',
        [12] = 'Tell',
        [13] = 'Party',
        [14] = 'Linkshell',
        [17] = 'Message',
        [135] = 'System',
        [142] = 'NPC',
        [211] = 'Unity',
        [212] = 'Unity',
    },
}

local settings = config and config.load(default_settings) or default_settings

local host = (type(settings.host) == 'string' and #settings.host > 0)
    and settings.host or default_host
local port = tonumber(settings.port) or default_port
if port < 1 or port > 65535 then
    port = default_port
end

local was_connected = false
local last_command_connect_attempt = 0
local command_connect_interval = 1.0

local max_command_length = 512
local max_commands_per_frame = 20
local max_command_buffer_size = 65536
local command_receive_buffer = ''

local last_sent_light_payload = nil

-- Chat relay: lines captured since the last status frame, cleared once
-- read by build_status. incoming/outgoing text events already hand us
-- UTF-8 text (Windower converts from Shift-JIS before these fire), so no
-- extra encoding work is needed here.
local chat_buffer = {}
local chat_buffer_max = 50
local chat_debug_enabled = false
local buff_debug_enabled = false

if config and settings.pair and settings.pair ~= '' then
    bridge.set_pairing_code(settings.pair)
end
;(function()

bridge.pairing_code = nil
bridge.secret = nil
bridge.session = nil

local bridge_auth_context = 'mogwatch-auth-v1'
local bridge_session_info = 'mogwatch-session-v2'
local bridge_nonce_length = 16
local bridge_counter_length = 8
local bridge_tag_length = 16
local bridge_direction_app_to_addon = 1
local bridge_direction_addon_to_app = 2

function bridge.is_loopback_host(address)
    if type(address) ~= 'string' then
        return false
    end
    return address == 'localhost' or address:sub(1, 4) == '127.'
end

-- Loopback is only reachable from this machine, so it keeps the original
-- plaintext bridge (Winlator, or a USB cable set up with `adb reverse`).
-- Anything else is reachable from the network and must be paired.
function bridge.secure_required(address)
    return not bridge.is_loopback_host(address)
end

function bridge.set_pairing_code(code)
    if code == nil or code == '' then
        bridge.pairing_code = nil
        bridge.secret = nil
        return true
    end

    local normalized = bridge.crypto.normalize_pairing_code(code)
    if not normalized then
        return false, 'a pairing code is 20 letters and digits'
    end

    local secret = bridge.crypto.secret_from_pairing_code(normalized)
    if not secret then
        return false, 'crypto unavailable: ' .. bridge.crypto.unavailable_reason()
    end

    bridge.pairing_code = normalized
    bridge.secret = secret
    return true
end

local function bridge_encode_counter(value)
    local bytes = {}
    for index = bridge_counter_length, 1, -1 do
        bytes[index] = string.char(value % 256)
        value = math.floor(value / 256)
    end
    return table.concat(bytes)
end

local function bridge_decode_counter(data)
    local value = 0
    for index = 1, bridge_counter_length do
        value = value * 256 + data:byte(index)
    end
    return value
end

-- The stream nonce is direction || counter, so the two directions can never
-- reuse a nonce under one session key.
local function bridge_stream_nonce(direction, counterBytes)
    return protocol_encode_uint32_be(direction) .. counterBytes
end

-- What the tag covers: the frame header and the counter. The counter picks the
-- keystream, so leaving it out would let it be altered without invalidating
-- the tag.
local function bridge_associated_data(header, counterBytes)
    return header .. counterBytes
end

local function bridge_proof(role, appNonceHex, addonNonceHex)
    -- Each side signs the peer's nonce first, so the two proofs are distinct
    -- messages and neither can be reflected back as the other.
    local message
    if role == 'app' then
        message = bridge_auth_context .. '|app|' .. addonNonceHex .. '|' .. appNonceHex
    else
        message = bridge_auth_context .. '|addon|' .. appNonceHex .. '|' .. addonNonceHex
    end
    return bridge.crypto.hmac_sha256(bridge.secret, message)
end

function bridge.reset_session()
    bridge.session = nil
    bridge.out_buffer = ''
end

-- Returns the challenge frame to send, or nil plus a reason the bridge cannot
-- come up secured.
function bridge.begin_session()
    bridge.reset_session()

    if not bridge.crypto.is_available() then
        return nil, 'encryption unavailable (' .. bridge.crypto.unavailable_reason() .. ')'
    end
    if not bridge.secret then
        return nil, 'no pairing code set. Use //mogwatch pair <code>'
    end

    local nonce = bridge.crypto.random_bytes(bridge_nonce_length)
    if not nonce then
        return nil, 'could not generate a random nonce'
    end

    bridge.session = {
        addon_nonce = bridge.crypto.to_hex(nonce),
        app_nonce = nil,
        send = nil,
        receive = nil,
        authenticated = false,
        send_counter = 0,
        last_received_counter = -1,
    }

    return protocol_encode_frame(bridge.type_auth_challenge, {
        protocol = 'mogwatch',
        version = protocol_version,
        role = 'addon',
        nonce = bridge.session.addon_nonce,
    })
end

-- Four keys, not two: each direction gets its own encryption and MAC key.
-- Sharing a MAC key between directions would let a frame be reflected back at
-- its sender and still authenticate, since the header and counter it covers
-- are identical either way.
local function bridge_direction_keys(salt, direction)
    local material = bridge.crypto.hkdf_sha256(
        bridge.secret, salt, bridge_session_info .. '|' .. direction, 64)
    return { encryption = material:sub(1, 32), mac = material:sub(33, 64) }
end

local function bridge_derive_session_key()
    local session = bridge.session
    local salt = bridge.crypto.from_hex(session.app_nonce)
        .. bridge.crypto.from_hex(session.addon_nonce)

    local appToAddon = bridge_direction_keys(salt, 'app-to-addon')
    local addonToApp = bridge_direction_keys(salt, 'addon-to-app')
    if not appToAddon or not addonToApp then
        return false
    end

    session.send = addonToApp
    session.receive = appToAddon
    return true
end

local function bridge_handle_challenge(frame)
    local session = bridge.session
    if not session or session.app_nonce then
        return nil, nil, 'unexpected challenge'
    end

    local payload = frame.payload
    if type(payload) ~= 'table' or payload.role ~= 'app' then
        return nil, nil, 'unexpected peer role'
    end

    local nonce = payload.nonce
    if type(nonce) ~= 'string' then
        return nil, nil, 'missing nonce'
    end
    local nonceBytes = bridge.crypto.from_hex(nonce)
    if not nonceBytes or #nonceBytes ~= bridge_nonce_length then
        return nil, nil, 'malformed nonce'
    end

    session.app_nonce = nonce
    if not bridge_derive_session_key() then
        return nil, nil, 'could not derive the session key'
    end

    -- The app proves itself first, and nothing it sent is acted on until this
    -- check passes.
    local expected = bridge_proof('app', session.app_nonce, session.addon_nonce)
    local provided = bridge.crypto.from_hex(payload.proof or '')
    if not provided or not bridge.crypto.constant_time_equals(provided, expected) then
        return nil, nil, 'the app failed to prove the pairing code'
    end

    session.authenticated = true
    local reply = protocol_encode_frame(bridge.type_auth_response, {
        proof = bridge.crypto.to_hex(
            bridge_proof('addon', session.app_nonce, session.addon_nonce)),
    })
    return reply, nil, nil
end

-- Wraps a complete plaintext frame in a sealed frame.
function bridge.seal_frame(innerFrame)
    local session = bridge.session
    if not session or not session.authenticated or not session.send then
        return nil
    end

    local counter = session.send_counter
    session.send_counter = counter + 1
    local counterBytes = bridge_encode_counter(counter)

    local payloadLength = bridge_counter_length + #innerFrame + bridge_tag_length
    local header = bridge.sealed_header(payloadLength)
    local ok, sealed = pcall(bridge.crypto.seal,
        session.send.encryption,
        session.send.mac,
        bridge_stream_nonce(bridge_direction_addon_to_app, counterBytes),
        bridge_associated_data(header, counterBytes),
        innerFrame)
    if not ok or not sealed then
        return nil
    end

    return header .. counterBytes .. sealed
end

local function bridge_open_frame(payload)
    local session = bridge.session
    if not session or not session.authenticated or not session.receive then
        return nil, 'not authenticated'
    end
    if #payload < bridge_counter_length + bridge_tag_length then
        return nil, 'sealed frame is truncated'
    end

    local counterBytes = payload:sub(1, bridge_counter_length)
    local counter = bridge_decode_counter(counterBytes)
    -- Strictly increasing: a captured frame cannot be replayed, and a
    -- reordered one is dropped rather than applied out of order.
    if counter <= session.last_received_counter then
        return nil, 'replayed frame'
    end

    local header = bridge.sealed_header(#payload)
    local plaintext = bridge.crypto.open(
        session.receive.encryption,
        session.receive.mac,
        bridge_stream_nonce(bridge_direction_app_to_addon, counterBytes),
        bridge_associated_data(header, counterBytes),
        payload:sub(bridge_counter_length + 1))
    if not plaintext then
        return nil, 'frame failed authentication'
    end

    session.last_received_counter = counter
    local inner = protocol_decode_frame(plaintext)
    if not inner or inner.messageType == bridge.type_sealed then
        return nil, 'malformed inner frame'
    end
    return inner, nil
end

-- Feeds one received frame to the session.
--
-- Returns (reply, inner, err). A non-nil err means the peer is not who it
-- claims to be and the caller must drop the connection; nothing from a failed
-- frame is ever executed.
function bridge.process_frame(messageType, frameData)
    local ok, reply, inner, err = pcall(bridge.process_frame_unguarded,
        messageType, frameData)
    if not ok then
        return nil, nil, 'frame handling failed: ' .. tostring(reply)
    end
    return reply, inner, err
end

function bridge.process_frame_unguarded(messageType, frameData)
    local session = bridge.session
    if not session then
        return nil, nil, 'no session'
    end

    if not session.authenticated then
        if messageType ~= bridge.type_auth_challenge then
            return nil, nil, 'traffic before the handshake finished'
        end
        local frame = protocol_decode_frame(frameData)
        if not frame then
            return nil, nil, 'malformed challenge'
        end
        return bridge_handle_challenge(frame)
    end

    if messageType ~= bridge.type_sealed then
        return nil, nil, 'unsealed frame on a paired connection'
    end

    local inner, err = bridge_open_frame(frameData:sub(protocol_header_size + 1))
    if not inner then
        return nil, nil, err
    end
    return nil, inner, nil
end

function bridge.is_authenticated()
    return bridge.session ~= nil and bridge.session.authenticated
end

-- Sealed frames have to reach the app whole and in order: a partial write
-- would desynchronise the stream and the app would drop the link. A
-- non-blocking socket can accept less than it is given, so anything unsent is
-- held here and flushed on the next tick.
bridge.out_buffer = ''

-- A full status frame with entity data runs to tens of kilobytes, so the
-- outbound buffer is sized well above one frame while still bounding how far
-- behind a stalled app may put us.
bridge.max_out_buffer = 262144

-- Frame ceiling for the sealed TCP path, comfortably inside max_out_buffer so
-- a single full frame never trips the backpressure check on its own.
bridge.max_tcp_payload = 131072

function bridge.flush_send(sock, limit)
    if bridge.out_buffer == '' then
        return true
    end
    if not sock then
        return false, 'not connected'
    end

    local pending = bridge.out_buffer
    -- A raising socket must not abort the frame callback: Ashita unloads an
    -- addon whose event handler errors, and losing the bridge is a better
    -- outcome than losing the addon mid-fight.
    local called, sent, err, partial = pcall(sock.send, sock, pending)
    if not called then
        return false, 'send failed: ' .. tostring(sent)
    end
    local count = tonumber(sent) or tonumber(partial) or 0
    if count > 0 then
        bridge.out_buffer = pending:sub(count + 1)
    end

    if not sent then
        -- A socket that is merely full is not an error; retry next tick.
        if err == 'timeout' or err == 'wantwrite' then
            if limit and #bridge.out_buffer > limit then
                return false, 'the app stopped reading'
            end
            return true
        end
        return false, err or 'send failed'
    end
    return true
end

function bridge.queue_send(sock, data, limit)
    if limit and (#bridge.out_buffer + #data) > limit then
        return false, 'the app stopped reading'
    end
    bridge.out_buffer = bridge.out_buffer .. data
    return bridge.flush_send(sock, limit)
end

end)()

-- ---------------------------------------------------------------------------
-- Connection management (mirrors the Ashita addon's bridge lifecycle)
-- ---------------------------------------------------------------------------

local function close_connection()
    if client then
        pcall(function() client:close() end)
        client = nil
    end
    command_receive_buffer = ''
    bridge.reset_session()
end

function bridge.reset_sent_state()
    last_sent_light_payload = nil
    -- Force the next frame to be a full one rather than waiting out the
    -- interval, so a reconnecting app gets fresh data immediately.
    last_full_status = 0
end

local function close_status_client()
    if status_client then
        pcall(function() status_client:close() end)
        status_client = nil
    end
    bridge.reset_sent_state()
end

local function save_bridge_settings()
    if not config then
        return
    end
    settings.host = host
    settings.port = port
    settings.pair = bridge.pairing_code or ''
    pcall(function() settings:save() end)
end

local function apply_bridge_target(new_host, new_port)
    local previous_host = host
    host = new_host or host
    port = new_port or port
    save_bridge_settings()
    close_connection()
    close_status_client()
    was_connected = false

    if new_host and new_host ~= previous_host and bridge.secure_required(new_host) then
        if not bridge.secret then
            print('MogWatch addon: this is a network address and needs pairing. '
                .. 'Run //mogwatch pair <code> with the code from the app.')
        end
    end
end

local function connect_status_client()
    if status_client then
        return true
    end
    -- Status rides the authenticated TCP session on a network bridge. UDP is
    -- connectionless and unauthenticated, so it stays on loopback only.
    if bridge.secure_required(host) then
        return false
    end
    if not socket or not socket.udp then
        return false
    end

    local s = socket.udp()
    if not s then
        return false
    end

    if s.settimeout then
        pcall(function() s:settimeout(0) end)
    end

    local ok = nil
    if s.setpeername then
        ok = s:setpeername(host, port)
    end
    if not ok then
        pcall(function() s:close() end)
        return false
    end

    status_client = s
    return true
end

local function send_protocol_hello()
    if not client or not client.send then
        return
    end

    local frame = protocol_encode_frame(protocol_type_hello, {
        protocol = 'mogwatch',
        version = protocol_version,
    })
    if frame then
        pcall(function() client:send(frame) end)
    end
end

local last_connect_diag = nil
local function report_connect_diag(msg)
    if msg ~= last_connect_diag then
        last_connect_diag = msg
        print('MogWatch addon: ' .. msg)
    end
end

local function connect_client()
    if client then
        return true
    end
    if not socket then
        report_connect_diag('command channel: socket library not available at all.')
        return false
    end
    if not socket.tcp then
        report_connect_diag('command channel: socket.tcp is not available in this environment '
            .. '(only UDP may be supported here).')
        return false
    end

    local now = os.clock()
    if (now - last_command_connect_attempt) < command_connect_interval then
        return false
    end
    last_command_connect_attempt = now

    local s = socket.tcp()
    if not s then
        report_connect_diag('command channel: socket.tcp() returned nil.')
        return false
    end

    -- 50ms was likely too aggressive for a connect() call to be reliable
    -- under real conditions (this exact path had never actually been
    -- tested against a real listening peer before) -- 1 second gives a
    -- loopback connection plenty of margin while still not hanging the
    -- game noticeably if nothing's listening.
    s:settimeout(1.0)
    local ok, err = s:connect(host, port)
    if not ok then
        report_connect_diag(('command channel: connect to %s:%d failed: %s')
            :format(host, port, tostring(err)))
        pcall(function() s:close() end)
        return false
    end

    s:settimeout(0)
    client = s
    command_receive_buffer = ''

    if bridge.secure_required(host) then
        local challenge, err = bridge.begin_session()
        if not challenge then
            if bridge.last_error ~= err then
                bridge.last_error = err
                print(('MogWatch addon: cannot pair with %s:%d: %s.'):format(host, port, err))
            end
            close_connection()
            return false
        end
        local sent = bridge.queue_send(s, challenge, bridge.max_out_buffer)
        if not sent then
            close_connection()
            return false
        end
        bridge.last_error = nil
        return true
    end

    send_protocol_hello()
    if not was_connected then
        print(('MogWatch addon: connected to app on %s:%d.'):format(host, port))
        was_connected = true
    end
    return true
end

-- Runs text typed/composed in the app exactly as if the player had typed it
-- into the FFXI chat box: slash commands, tells, party chat, macros bound to
-- text, all of it. This is simpler than the Ashita addon's approach (which
-- has to simulate key presses for macro-bar execution) because Windower can
-- hand a line straight to the chat input.
local function queue_game_command(command)
    if type(command) ~= 'string' then
        return
    end

    command = command:gsub('^%s+', ''):gsub('%s+$', '')
    if command == '' or #command > max_command_length then
        return
    end

    if command_debug_enabled then
        print('MogWatch CMDDEBUG: about to chat.input: ' .. command)
    end

    if text_encoding then
        command = text_encoding.utf8_to_shiftjis(command)
    end

    local ok, err = pcall(function() windower.chat.input(command) end)
    if not ok then
        print('MogWatch addon: chat.input failed for command "' .. command .. '": ' .. tostring(err))
    elseif command_debug_enabled then
        print('MogWatch CMDDEBUG: chat.input call completed without error.')
    end
end
local function queue_protocol_command_payload(payload)
    local queued = 0
    if type(payload) == 'string' then
        queue_game_command(payload)
        return 1
    end
    if type(payload) ~= 'table' then
        return 0
    end

    for index = 1, #payload do
        if type(payload[index]) == 'string' then
            queue_game_command(payload[index])
            queued = queued + 1
            if queued >= max_commands_per_frame then
                return queued
            end
        end
    end
    return queued
end

-- Drops the link and says why. On a paired bridge every failure here means
-- the peer is not the app we paired with, so nothing from the frame runs.
-- Ashita unloads an addon whose event handler raises. Nothing the bridge does
-- is worth that, so its two entry points run under this: report the error once
-- and drop the connection, then let the normal retry bring it back.
function bridge.guard_tick(label, fn)
    local ok, err = pcall(fn)
    if ok then
        return
    end

    local text = tostring(err)
    if bridge.last_tick_error ~= text then
        bridge.last_tick_error = text
        print(('MogWatch addon: bridge error in %s: %s'):format(label, text))
        print('MogWatch addon: the connection was dropped and will retry. '
            .. 'Please report this message.')
    end
    was_connected = false
    pcall(close_connection)
end

local function reject_connection(reason)
    -- The addon retries every second, so an unchanging cause would otherwise
    -- fill the console once a second and read like the addon malfunctioning.
    if bridge.last_reject_reason ~= reason then
        bridge.last_reject_reason = reason
        print(('MogWatch addon: dropped the connection to %s:%d (%s).')
            :format(host, port, reason))
        if reason:find('prove the pairing code', 1, true) then
            print('MogWatch addon: the code here does not match the app. '
                .. 'Re-enter it with //mogwatch pair <code from the app>.')
        end
    end
    was_connected = false
    close_connection()
end
local function process_command_receive_buffer()
    local processed = 0
    local secure = bridge.secure_required(host)

    while processed < max_commands_per_frame and #command_receive_buffer > 0 do
        if not protocol_buffer_has_magic_prefix(command_receive_buffer) then
            if secure then
                reject_connection('plaintext data on a paired link')
                return processed
            end

            local newline = command_receive_buffer:find('\n', 1, true)
            if not newline then
                if #command_receive_buffer > max_command_buffer_size then
                    command_receive_buffer = ''
                end
                return processed
            end

            local line = command_receive_buffer:sub(1, newline - 1):gsub('\r$', '')
            command_receive_buffer = command_receive_buffer:sub(newline + 1)
            if command_debug_enabled then
                print('MogWatch CMDDEBUG: extracted plain-text line: "' .. line .. '"')
            end
            queue_game_command(line)
            processed = processed + 1
        else
            if #command_receive_buffer < protocol_header_size then
                return processed
            end

            local frameVersion = command_receive_buffer:byte(4)
            local messageType = command_receive_buffer:byte(5)
            local knownType = messageType == protocol_type_status
                or messageType == protocol_type_command
                or messageType == protocol_type_hello
                or messageType == bridge.type_auth_challenge
                or messageType == bridge.type_auth_response
                or messageType == bridge.type_sealed

            if frameVersion ~= protocol_version or not knownType then
                if secure then
                    reject_connection('unsupported frame')
                    return processed
                end

                local newline = command_receive_buffer:find('\n', 1, true)
                if not newline then
                    return processed
                end

                local line = command_receive_buffer:sub(1, newline - 1):gsub('\r$', '')
                command_receive_buffer = command_receive_buffer:sub(newline + 1)
                queue_game_command(line)
                processed = processed + 1
            else
                local payloadLength = protocol_decode_uint32_be(command_receive_buffer, 7)
                if not payloadLength or payloadLength > protocol_max_payload_size then
                    if secure then
                        reject_connection('impossible frame length')
                    else
                        command_receive_buffer = ''
                    end
                    return processed
                end

                local frameLength = protocol_header_size + payloadLength
                if #command_receive_buffer < frameLength then
                    return processed
                end

                local frameData = command_receive_buffer:sub(1, frameLength)
                command_receive_buffer = command_receive_buffer:sub(frameLength + 1)

                if secure then
                    local wasAuthenticated = bridge.is_authenticated()
                    local reply, inner, err = bridge.process_frame(messageType, frameData)
                    if err then
                        reject_connection(err)
                        return processed
                    end
                    if reply and client then
                        local sent, sendErr = bridge.queue_send(
                            client, reply, bridge.max_out_buffer)
                        if not sent then
                            reject_connection(sendErr or 'send failed')
                            return processed
                        end
                    end
                    if not wasAuthenticated and bridge.is_authenticated() then
                        bridge.last_reject_reason = nil
                        bridge.last_tick_error = nil
                        bridge.reset_sent_state()
                        if not was_connected then
                            print(('MogWatch addon: paired with app on %s:%d (encrypted).')
                                :format(host, port))
                            was_connected = true
                        end
                    end
                    if inner and inner.messageType == protocol_type_command then
                        processed = processed + queue_protocol_command_payload(inner.payload)
                    end
                else
                    local frame = protocol_decode_frame(frameData)
                    if frame and frame.messageType == protocol_type_command then
                        processed = processed + queue_protocol_command_payload(frame.payload)
                    end
                end
            end
        end
    end
    return processed
end

local function receive_commands()
    if not client then
        connect_client()
    end
    if not client or not client.receive then
        return
    end

    if client and bridge.secure_required(host) and bridge.out_buffer ~= '' then
        local flushed, flushErr = bridge.flush_send(client, bridge.max_out_buffer)
        if not flushed then
            reject_connection(flushErr or 'send failed')
            return
        end
    end

    -- Processing can drop the connection: a frame that fails to authenticate
    -- closes it and clears `client`. Every call below therefore re-checks it
    -- before touching the socket again.
    local processed = process_command_receive_buffer()
    if not client or processed >= max_commands_per_frame then
        return
    end

    for _ = 1, max_commands_per_frame do
        if not client then
            return
        end

        local chunk, err, partial = client:receive(4096)
        local data = chunk
        if (not data or data == '') and type(partial) == 'string' and #partial > 0 then
            data = partial
        end

        if command_debug_enabled and data and #data > 0 then
            print(('MogWatch CMDDEBUG: received %d raw bytes: %s'):format(#data, data))
        end

        if data and #data > 0 then
            command_receive_buffer = command_receive_buffer .. data
            if #command_receive_buffer > max_command_buffer_size then
                command_receive_buffer = ''
                return
            end
            processed = processed + process_command_receive_buffer()
            if not client or processed >= max_commands_per_frame then
                return
            end
        else
            local disposition = bridge.classify_receive_error(err)
            if disposition == 'closed' then
                -- A clean hangup is ordinary, so it reconnects without comment.
                was_connected = false
                close_connection()
            elseif disposition == 'failed' then
                reject_connection(err)
            end
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- Game state -> status payload
--
-- This is the Windower replacement for the Ashita addon's build_status(),
-- build_party_member(), and build_active_buffs(). It intentionally covers a
-- smaller surface than the original (see the notes at the top of this file):
-- player vitals/position/buffs and party member vitals. Extend here.
-- ---------------------------------------------------------------------------

local function get_job_name(id)
    id = tonumber(id) or 0
    if id <= 0 or not res then
        return ''
    end
    local job = res.jobs[id]
    if not job then
        return ''
    end
    return job.english_short or job.name or ''
end

local function get_zone_name(id)
    id = tonumber(id) or 0
    if not res then
        return ''
    end
    local zone = res.zones[id]
    if not zone then
        return ''
    end
    return zone.name or zone.english or ''
end

local function get_buff_name(id)
    id = tonumber(id) or 0
    if id <= 0 or not res then
        return nil
    end
    local buff = res.buffs[id]
    if not buff then
        return nil
    end
    return buff.name or buff.english
end

-- ASSUMPTION, not fully verified: Windower's res.buffs entries are
-- expected to carry a 'type' field distinguishing "Buff" from "Debuff"
-- (a pattern seen elsewhere in Windower's resource tables), so that's
-- what this checks first. If real testing shows harmful/beneficial
-- effects coming out on the wrong side, this is the first thing to
-- re-examine -- defaults to "not a debuff" whenever the field isn't
-- present or doesn't match, so worst case something lands in the wrong
-- section rather than anything breaking.
-- Confirmed (not guessed) that Windower's res.buffs entries carry NO
-- buff/debuff classification field at all: a live diagnostic dump of
-- candidate field names (type, negative, harmful, flags, category, etc.)
-- against a real buff came back with only name/english/enl populated,
-- nothing else. So this classifies by matching the effect's NAME instead
-- of its ID -- deliberately, since an ID-based list already turned out to
-- be wrong once this session (buff ID 2 is Sleep, not Poison, as
-- assumed). This list is manually curated from general FFXI knowledge,
-- not verified against a single authoritative source, so it may be
-- incomplete or have mistakes -- if something shows up on the wrong side
-- after real testing, add/remove its name here.
-- Sourced from bg-wiki's "Category:Status Effects" / "Negative Status
-- Effects" listing (the user linked bg-wiki directly) -- these are the
-- real, official FFXI debuff category names, not names I recalled from
-- memory. A few specific spell/effect instance names are kept alongside
-- the general categories (e.g. "Dia III" alongside "Dia") since res.buffs
-- may use the specific instance name rather than the general one.
local KNOWN_DEBUFF_NAMES = {
    ['accuracy down'] = true, ['addle'] = true, ['amnesia'] = true,
    ['attack down'] = true, ['attribute down'] = true, ['bane'] = true,
    ['bind'] = true, ['bound'] = true, ['bio'] = true, ['bio ii'] = true,
    ['bio iii'] = true, ['blind'] = true, ['blindness'] = true,
    ['bust'] = true, ['chainbound'] = true, ['charm'] = true,
    ['charm ii'] = true, ['curse'] = true, ['curse ii'] = true,
    ['haunt'] = true, ['daze'] = true, ['debilitation'] = true,
    ['defense down'] = true, ['dia'] = true, ['dia ii'] = true,
    ['dia iii'] = true, ['disease'] = true, ['plague'] = true,
    ['doom'] = true, ['encumberance'] = true, ['encumberment'] = true,
    ['shock'] = true, ['rasp'] = true, ['choke'] = true, ['frost'] = true,
    ['burn'] = true, ['drown'] = true, ['evasion down'] = true,
    ['flash'] = true, ['gradual petrification'] = true,
    ['petrification'] = true, ['petrify'] = true, ['helix'] = true,
    ['impairment'] = true, ['level restriction'] = true,
    ['magic accuracy down'] = true, ['magic evasion down'] = true,
    ['magic attack down'] = true, ['magic defense down'] = true,
    ['max hp down'] = true, ['max mp down'] = true, ['max tp down'] = true,
    ['medicated'] = true, ['muddle'] = true, ['mute'] = true,
    ['silence'] = true, ['obliviscence'] = true, ['overload'] = true,
    ['paralysis'] = true, ['paralyze'] = true, ['poison'] = true,
    ['taint'] = true, ['sleep'] = true, ['sleepga'] = true,
    ['sleepga ii'] = true, ['nightmare'] = true, ['slow'] = true,
    ['stun'] = true, ['terror'] = true, ['weakness'] = true,
    ['weight'] = true, ['gravity'] = true,
    -- Specific spell/JA names not literally listed as a bg-wiki category,
    -- but well-established debuffs in FFXI common knowledge, kept from
    -- the earlier version of this list:
    ['requiem'] = true, ['elegy'] = true, ['threnody'] = true,
    ['lullaby'] = true, ['dispel'] = true, ['break'] = true,
    ['kaustra'] = true, ['yawn'] = true, ['old age'] = true,
    ['sandstorm'] = true, ['klimaform'] = true, ['galeforce'] = true,
    ['omerta'] = true, ['frazzle'] = true, ['distract'] = true,
    ['confusion'] = true, ['intimidate'] = true, ['flood'] = true,
}

local function is_debuff(id)
    id = tonumber(id) or 0
    if id <= 0 or not res then
        return false
    end
    local buff = res.buffs[id]
    if not buff then
        return false
    end
    local name = buff.name or buff.english or buff.enl
    if type(name) ~= 'string' then
        return false
    end
    return KNOWN_DEBUFF_NAMES[name:lower()] == true
end

-- --- Buff timers: packet 0x063 (MISCDATA), sub-type 0x09 (StatusIcons) ----
--
-- Verified against LandSandBoat's actual packet source
-- (0x063_miscdata_status_icons.h/.cpp), not guessed. Layout, confirmed:
--   offset 0-3   : standard FFXI packet header (id + size)
--   offset 4-5   : sub-type (uint16 LE) -- 0x09 for StatusIcons
--   offset 6-7   : unknown06 (uint16 LE) -- unused
--   offset 8-71  : icons[32]      (uint16 LE each) -- 0x00FF = empty slot
--   offset 72-199: timestamps[32] (uint32 LE each), index-matched to icons
--
-- Timer conversion, derived (not guessed) from LandSandBoat's actual
-- earth_time.h / timer.h source:
--
--   earth_time::vanadiel_timestamp() = floor(current_UTC_unix_time) -
--                                       1009810800   (a fixed custom epoch,
--                                       despite the name this is NOT scaled
--                                       to Vana'diel's 25x clock -- it's
--                                       plain real seconds)
--
--   packet raw value = (60 * (seconds_remaining + vanadiel_timestamp()))
--                       deliberately wrapped into a uint32 (mod 2^32)
--
-- To invert: compute what the packet WOULD read right at the instant a
-- buff expires (seconds_remaining = 0) using our own current time, then
-- the difference between that and the actual raw value -- taken modulo
-- 2^32 to correctly unwrap the overflow -- divided by 60, is the real
-- seconds remaining. (2^32/60 is ~827 days, far beyond any real buff
-- duration, so this unwrapping is unambiguous.)
local VANADIEL_EPOCH_UNIX = 1009810800
local MOD32 = 4294967296 -- 2^32

local function seconds_remaining_from_raw(raw_timestamp)
    if not raw_timestamp then
        return nil
    end
    local k = os.time() - VANADIEL_EPOCH_UNIX
    local expected_at_zero = (60 * k) % MOD32
    local diff = (raw_timestamp - expected_at_zero) % MOD32
    return diff / 60
end

local status_icon_timestamps = {}   -- icon id -> last seen raw timestamp
local status_icon_diag_seen = {}    -- icon id -> value already printed (avoid spam)

local function read_u16_le(data, offset0)
    local b1, b2 = data:byte(offset0 + 1, offset0 + 2)
    if not b1 or not b2 then
        return nil
    end
    return b1 + b2 * 256
end

local function read_u32_le(data, offset0)
    local b1, b2, b3, b4 = data:byte(offset0 + 1, offset0 + 4)
    if not b1 or not b2 or not b3 or not b4 then
        return nil
    end
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

windower.register_event('incoming chunk', function(id, data)
    if id ~= 0x063 or #data < 8 then
        return
    end
    local sub_type = read_u16_le(data, 4)
    if sub_type ~= 0x09 or #data < 4 + 196 then
        return
    end

    for i = 0, 31 do
        local icon = read_u16_le(data, 8 + i * 2)
        if icon and icon ~= 0x00FF and icon ~= 0 then
            local timestamp = read_u32_le(data, 72 + i * 4)
            if buff_debug_enabled and timestamp and status_icon_diag_seen[icon] ~= timestamp then
                local remaining = seconds_remaining_from_raw(timestamp)
                print(('MogWatch DIAG: buff icon %d -- raw=%.0f  =>  '
                    .. 'computed remaining=%.0fs (watch that this counts '
                    .. 'down at ~1/sec and hits ~0 right as the buff wears off)')
                    :format(icon, timestamp, remaining))
                status_icon_diag_seen[icon] = timestamp
            end
            status_icon_timestamps[icon] = timestamp
        end
    end
end)

-- --- Party member buffs and job info --------------------------------------
--
-- Confirmed against XivParty (Tylas11/XivParty on GitHub, a real, actively
-- used Windower party addon, 52 stars) -- its source directly answers both
-- of these, so this isn't guessed:
--
-- Party member job/subjob comes from packets 0xDD (party member update)
-- and 0xDF (char update), parsed with Windower's OWN named-field packet
-- parser (the `packets` library already knows these fields' byte layout,
-- so no manual offsets needed here).
--
-- Party member buffs come from packet 0x076, credited in XivParty's source
-- to "Kenshi, PartyBuffs" for the packet itself and "Byrth, GearSwap" for
-- the specific bit-unpacking trick (buff IDs are 10 bits each, split
-- across two separate byte regions to pack efficiently) -- reproduced
-- here as-is from that verified, production source, not derived by me.
-- Explicitly does NOT include the main player's own buffs (that's what
-- packet 0x063 above is for) -- only up to 5 other party members.
local ok_packets, packets = pcall(require, 'packets')
if not ok_packets then
    packets = nil
end

local party_id_by_name = {}   -- name -> entity id, learned from 0xDD
local party_job_by_id = {}    -- id -> {mainJobId, mainJobLvl, subJobId, subJobLvl}
local party_buffs_by_id = {}  -- id -> array of up to 32 buff ids (may contain nils)

local function apply_job_packet(packet)
    if not packet then
        return
    end
    local name = packet['Name']
    local id = packet['ID']
    local main_job = packet['Main job']
    local main_job_lvl = packet['Main job level']
    local sub_job = packet['Sub job']
    local sub_job_lvl = packet['Sub job level']
    if not id or id <= 0 then
        return
    end
    if name and name ~= '' then
        party_id_by_name[name] = id
    end
    -- "These can contain NON 0 / NON 0 when the party member is out of
    -- zone; seem to always get NON 0 / NON 0 if the character has no SJ"
    -- -- direct quote from XivParty's own source comment on this same
    -- data, kept here since it's a real caveat worth knowing about.
    if main_job and main_job_lvl and sub_job and sub_job_lvl and main_job_lvl > 0 then
        party_job_by_id[id] = {
            mainJobId = main_job, mainJobLvl = main_job_lvl,
            subJobId = sub_job, subJobLvl = sub_job_lvl,
        }
    end
end

windower.register_event('incoming chunk', function(id, original)
    if not packets then
        return
    end

    if id == 0xDD or id == 0xDF then
        local ok, packet = pcall(packets.parse, 'incoming', original)
        if ok and packet then
            apply_job_packet(packet)
        end
        return
    end

    if id == 0x076 then
        for k = 0, 4 do
            local ok, player_id = pcall(function() return original:unpack('I', k * 48 + 5) end)
            if ok and player_id and player_id ~= 0 then
                local buffs_list = {}
                for i = 1, 32 do
                    local b1 = original:byte(k * 48 + 5 + 16 + i - 1)
                    local b2 = original:byte(k * 48 + 5 + 8 + math.floor((i - 1) / 4))
                    if b1 and b2 then
                        local buff = b1 + 256 * (math.floor(b2 / 4 ^ ((i - 1) % 4)) % 4)
                        if buff ~= 255 then
                            buffs_list[i] = buff
                        end
                    end
                end
                party_buffs_by_id[player_id] = buffs_list
            end
        end
    end
end)

-- Builds the same {id, name, ...} shape as build_active_buffs, for a party
-- member identified by entity id (from party_id_by_name / mob.id).
local function build_party_member_buffs(id)
    local activeBuffs = {}
    local buffs = id and party_buffs_by_id[id]
    if not buffs then
        return activeBuffs
    end
    for i = 1, 32 do
        local buffId = buffs[i]
        if buffId and buffId > 0 and buffId < 255 then
            local buff = { id = buffId, harmful = is_debuff(buffId) }
            local name = get_buff_name(buffId)
            if name then
                buff.name = name
            end
            table.insert(activeBuffs, buff)
        end
    end
    return activeBuffs
end

-- windower.ffxi.get_player().buffs is a flat array of active buff/status
-- IDs (255 or a repeated/blank slot marks "no buff" depending on client
-- state) -- the same ID space as the packet's icon IDs above (both use 255
-- as the "empty" sentinel), so they're matched directly by id.
local function build_active_buffs(player)
    local activeBuffs = {}
    if not player or type(player.buffs) ~= 'table' then
        return activeBuffs
    end

    for _, buffId in ipairs(player.buffs) do
        buffId = tonumber(buffId) or 0
        if buffId > 0 and buffId < 255 then
            local buff = { id = buffId, harmful = is_debuff(buffId) }
            local name = get_buff_name(buffId)
            if name then
                buff.name = name
            end
            local rawTimestamp = status_icon_timestamps[buffId]
            if rawTimestamp then
                local remaining = seconds_remaining_from_raw(rawTimestamp)
                if remaining and remaining >= 0 and remaining < 24 * 3600 then
                    -- Sanity-bounded: anything absurdly large would mean
                    -- something about the unwrap assumption broke (e.g. a
                    -- buff that genuinely lasts over a day, or a server
                    -- clock far out of sync), rather than silently show a
                    -- nonsense countdown.
                    buff.secondsRemaining = math.floor(remaining)
                end
            end
            table.insert(activeBuffs, buff)
        end
    end

    return activeBuffs
end

-- FFXI's horizontal ground plane is X/Z; Y is vertical height/elevation.
-- (This trips people up because it's not X/Y -- worth calling out explicitly
-- since the map view below depends on getting this right.)
local function build_party_member(party_entry)
    if type(party_entry) ~= 'table' or type(party_entry.name) ~= 'string'
        or party_entry.name == '' then
        return nil
    end

    local mob = party_entry.mob
    local locationX, locationZ, elevation, heading = nil, nil, nil, nil
    if mob then
        locationX = mob.x
        locationZ = mob.z
        elevation = mob.y
        heading = mob.heading
    end

    local currentHp = tonumber(party_entry.hp) or 0
    local currentMp = tonumber(party_entry.mp) or 0
    local hpp = tonumber(party_entry.hpp) or 0
    local mpp = tonumber(party_entry.mpp) or 0
    local tp = tonumber(party_entry.tp) or 0

    -- windower.ffxi.get_party() itself has no job/buff fields for other
    -- members (confirmed absent, not just unverified). Job comes from
    -- packets 0xDD/0xDF, buffs from packet 0x076 -- both tracked above,
    -- matched here by entity id (from the packets themselves, or from
    -- party_entry.mob.id when the member is in the same zone).
    local id = (mob and mob.id) or party_id_by_name[party_entry.name]
    local job, subjob = '', ''
    if id then
        local job_info = party_job_by_id[id]
        if job_info then
            job = get_job_name(job_info.mainJobId)
            subjob = get_job_name(job_info.subJobId)
        end
    end

    return {
        name = party_entry.name,
        job = job,
        subjob = subjob,
        location = get_zone_name(party_entry.zone),
        zoneId = tonumber(party_entry.zone) or 0,
        locationX = locationX,
        locationZ = locationZ,
        elevation = elevation,
        heading = heading,
        currentHp = currentHp,
        hpp = hpp,
        maxHp = hpp > 0 and math.floor(currentHp * 100 / hpp) or currentHp,
        currentMp = currentMp,
        maxMp = mpp > 0 and math.floor(currentMp * 100 / mpp) or currentMp,
        tp = tp,
        activeBuffs = build_party_member_buffs(id),
    }
end

-- Current target frame. 't' is Windower's alias for "current target", same
-- as what /ma, /ja, etc. would act on. Returns nil when nothing is targeted.
-- Distance is computed from raw X/Z coordinates rather than trusting
-- mob.distance, since that field's exact units aren't something I could
-- confirm from documentation -- computing it ourselves from positions we
-- already have removes the ambiguity.
local function build_target(player_x, player_z)
    local mob = windower.ffxi.get_mob_by_target('t')
    if not mob or not mob.name or mob.name == '' then
        return nil
    end

    local distance = nil
    if player_x and player_z and mob.x and mob.z then
        local dx = mob.x - player_x
        local dz = mob.z - player_z
        distance = math.sqrt(dx * dx + dz * dz)
    end

    return {
        name = mob.name,
        hpp = mob.hpp or 0,
        distance = distance,
        isNpc = mob.is_npc and true or false,
        locationX = mob.x,
        locationZ = mob.z,
        elevation = mob.y,
    }
end

-- Simple NPC/mob list for the viewer's NPC panel: everything nearby that
-- Windower currently considers a valid, relevant entity. get_mob_array()
-- also returns a lot of far-away/inactive entries, so this filters down to
-- things actually worth showing and caps the list length to keep frames
-- small. No map involvement -- this is a plain list, sorted by distance.
local npc_list_max_range = 50
local npc_list_max_count = 15

local function build_nearby_npcs(player_x, player_z)
    if not player_x or not player_z then
        return {}
    end

    local mobs = windower.ffxi.get_mob_array()
    if not mobs then
        return {}
    end

    local candidates = {}
    for _, mob in pairs(mobs) do
        if mob.valid_target and mob.name and mob.name ~= '' and mob.x and mob.z then
            local dx = mob.x - player_x
            local dz = mob.z - player_z
            local distance = math.sqrt(dx * dx + dz * dz)
            if distance <= npc_list_max_range then
                table.insert(candidates, {
                    name = mob.name,
                    distance = distance,
                    hpp = mob.hpp,
                    isNpc = mob.is_npc and true or false,
                })
            end
        end
    end

    table.sort(candidates, function(a, b) return a.distance < b.distance end)

    local result = {}
    for i = 1, math.min(#candidates, npc_list_max_count) do
        result[i] = candidates[i]
    end
    return result
end

-- Forward declaration: build_counter_status (Counter integration) is
-- defined much further down, alongside the rest of Counter's ported
-- state/functions, but build_status() below needs to call it on every
-- status frame.
local build_counter_status

local function build_status()
    if not windower.ffxi.get_info().logged_in then
        return nil
    end

    local player = windower.ffxi.get_player()
    if not player or not player.name or player.name == '' then
        return nil
    end

    local info = windower.ffxi.get_info()
    local zoneName = get_zone_name(info.zone)
    local vitals = player.vitals or {}

    local selfMob = windower.ffxi.get_mob_by_target('me')
    local playerX, playerZ, elevation, playerHeading = nil, nil, nil, nil
    if selfMob then
        playerX = selfMob.x
        playerZ = selfMob.z
        elevation = selfMob.y
        playerHeading = selfMob.heading
    end

    local activeBuffs = build_active_buffs(player)

    local playerData = {
        name = player.name,
        job = get_job_name(player.main_job_id),
        subjob = get_job_name(player.sub_job_id),
        level = player.main_job_level or 0,
        currentHp = vitals.hp or 0,
        maxHp = vitals.max_hp or 0,
        currentMp = vitals.mp or 0,
        maxMp = vitals.max_mp or 0,
        hpp = vitals.hpp,
        mpp = vitals.mpp,
        tp = vitals.tp or 0,
        activeBuffs = activeBuffs,
        location = zoneName,
        zoneId = info.zone or 0,
        locationX = playerX,
        locationZ = playerZ,
        elevation = elevation,
        heading = playerHeading,
        entityReady = true,
    }

    local counter_ok, counter_data = pcall(build_counter_status)
    if not counter_ok then
        counter_data = nil
    end

    local status = {
        player = playerData,
        partyMembers = { playerData },
        target = build_target(playerX, playerZ),
        npcs = build_nearby_npcs(playerX, playerZ),
        counter = counter_data,
        chat = chat_buffer,
        level = playerData.level,
        zone = zoneName,
        zoneId = playerData.zoneId,
    }
    chat_buffer = {}

    local party = windower.ffxi.get_party()
    if party then
        for idx = 1, 5 do
            local memberData = build_party_member(party['p' .. idx])
            if memberData then
                status.partyMembers[#status.partyMembers + 1] = memberData
            end
        end
    end

    return status
end

local function send_status()
    local now = os.clock()
    local secure = bridge.secure_required(host)

    if secure then
        if not client or not bridge.is_authenticated() then
            return
        end
    else
        if not connect_status_client() then
            return
        end
    end

    local payload = build_status()
    if not payload then
        return
    end

    local encoded = protocol_encode_frame(protocol_type_status, payload)
    if not encoded and json then
        encoded = json.encode(payload)
    end
    if not encoded then
        return
    end

    -- Byte-identical frames carry no new state; skip the send so a quiet
    -- zone doesn't spam the link.
    if encoded == last_sent_light_payload then
        return
    end

    if secure then
        local sealed = bridge.seal_frame(encoded)
        if not sealed then
            reject_connection('could not encrypt a status frame')
            return
        end
        local sent, sendErr = bridge.queue_send(client, sealed, bridge.max_out_buffer)
        if not sent then
            reject_connection(sendErr or 'send failed')
            return
        end
    else
        local ok = status_client:send(encoded)
        if not ok then
            close_status_client()
            return
        end
    end

    last_sent_light_payload = encoded
    last_full_status = now
end

-- ---------------------------------------------------------------------------
-- Commands and lifecycle events
-- ---------------------------------------------------------------------------


-- ============================================================
-- Counter integration: item/gil/personal-drop tracking, merged
-- in directly (originally a separate addon, counter.lua, by
-- wisdomcheese4). Its own native on-screen display and mouse
-- handling were removed -- MogWatch's Counter tab replaced that
-- entirely, reading state via build_counter_status() below,
-- called from build_status() and sent out with every regular
-- status frame. Session-clock tracking was removed per request.
-- Everything else (detection, categorization, sets, settings
-- persistence, auto-add toggles, focus, quiet mode) is untouched
-- from the original, working addon.
-- ============================================================

local files = require('files')
local res = require('resources')

-- This used to redraw Counter's own native on-screen display. That
-- display is gone now -- MogWatch's Counter tab replaced it, reading
-- state fresh on its own schedule (see build_counter_status() further
-- down, called from mogwatch.lua's regular status loop). Every call site
-- below still correctly mutates state before calling this; only the
-- drawing step is now a no-op, so nothing needed to change at each of the
-- ~45 call sites individually.
local function update_display() end

-- Initialize variables
local tracked_items = {}
local item_counts = {}
local saved_sets = {}
local debug_mode = false
local debug_all = false
local player_name = nil

-- Settings are stored per-character once we know who's logged in (falls
-- back to a shared file before that, or if the name can't be determined).
-- This is computed fresh each time rather than cached in a variable so it
-- automatically starts pointing at the right file the moment player_name
-- becomes known.
local function get_settings_filename()
    if player_name then
        return 'data/settings-' .. player_name:lower() .. '.lua'
    end
    return 'data/settings.lua'
end

-- Separate categories for items
local usable_items = {}
local ammo_items = {}
local key_items = {}
local personal_items = {}
local personal_counts = {}

-- Snapshot of lifetime counts taken once, the first time each item is
-- seen this session (addon load until reload/relog) -- lets each item show
-- "gained this session [lifetime total]" rather than just one number. This
-- is the original addon's actual session-tracking purpose (confirmed from
-- its own source comments); only the visible session clock/timer was
-- removed earlier, not this per-item count pairing. Bundled into one table
-- (rather than several separate locals) since Lua caps a single chunk at
-- 200 top-level locals, and this whole merged file is close to that limit.
local session_baselines = { drop = {}, personal = {} }

-- Separate auto-add settings for each category
local auto_add_drop = false
local auto_add_personal = true  -- Personal drops are auto-tracked by default
local auto_add_gil = true  -- Gil is always auto-tracked
local auto_add_usable = true  -- Usable items are auto-tracked by default

-- Suppresses automatic drop/steal/mug/obtain chat announcements when true
-- (commands typed by the user still get their normal confirmation messages)
local quiet_mode = false

-- Remembered window position, so it survives a //lua reload
local window_x = nil
local window_y = nil

-- The currently "focused" item, pinned to the top of the display
local focus_item_name = nil
local focus_item_category = nil

-- Color tracking for recently dropped items
local item_drop_times = {}  -- Tracks when each item was last obtained
local GREEN_DURATION = 5    -- Seconds to stay green
local RED_DURATION = 5      -- Seconds to stay red for decrements

-- Tables for personal drops
local personal_drop_times = {}
local usable_drop_times = {}
local ammo_drop_times = {}
local key_drop_times = {}

-- New table to track recent increments
local recent_increments = {}  -- Stores {amount = X, time = os.time()} for each item

-- Cache for inventory counts
local inventory_cache = {}
local last_inventory_check = 0
local INVENTORY_CHECK_INTERVAL = 1  -- Check inventory every 1 second

-- Track previous inventory counts for decrease detection
local previous_inventory_counts = {}

-- Create a mapping of full names to short names
local full_to_short_map = {}
local short_to_full_map = {}

-- Track last equipped ammo
local last_equipped_ammo = nil

-- Define bright orange color code for Counter messages
-- Using additive color method: start with base color 123, add RGB values
local COUNTER_COLOR = 123 + (255 * 256 * 256 * 256) + (128 * 256 * 256) + (0 * 256)

-- Forward declarations: remove_item and reset_item are defined further
-- down (they're used by //counter remove/reset), but the item context
-- menu built near update_display needs to call them too.
local remove_item
local reset_item

-- Forward declaration: save_settings is defined further down, but several
-- functions above it need to call it when their state changes.
local save_settings

-- Forward declaration: build_name_mappings also now builds a name->resource
-- cache (see below) that is_ammo_item/is_usable_item need, but it's
-- defined after them since it was originally a "mappings only" helper.
local build_name_mappings

-- Cache of item name (short or full/name_log) -> resource entry and id,
-- built once by build_name_mappings() instead of being re-scanned from
-- res.items (several thousand entries) on every lookup.
local item_by_name = {}
local item_id_by_name = {}
local name_cache_built = false

local function get_player_name()
    local player = windower.ffxi.get_player()
    if player then
        player_name = player.name
        return true
    end
    return false
end

-- Normalize item name for consistent storage
local function normalize_item_name(item_name)
    -- Capitalize first letter of each word
    return item_name:gsub("(%a)([%w_']*)", function(first, rest)
        return first:upper() .. rest:lower()
    end)
end

-- Convert short name to full name if mapping exists
local function get_full_name(item_name)
    -- First check if we have a direct mapping
    local full_name = short_to_full_map[item_name]
    if full_name then
        return full_name
    end
    
    -- Check normalized version
    local normalized = normalize_item_name(item_name)
    full_name = short_to_full_map[normalized]
    if full_name then
        return full_name
    end
    
    -- Return original if no mapping found
    return item_name
end

-- Get short name for display
local function get_display_name(full_name)
    -- Check if we have a mapping to short name
    local short_name = full_to_short_map[full_name]
    if short_name then
        return short_name
    end
    
    -- Check normalized version
    local normalized = normalize_item_name(full_name)
    short_name = full_to_short_map[normalized]
    if short_name then
        return short_name
    end
    
    -- Return original if no mapping
    return full_name
end

-- Check equipped ammo and update tracking
local function check_equipped_ammo()
    local equipment = windower.ffxi.get_items().equipment
    if equipment and equipment.ammo and equipment.ammo > 0 then
        local item = windower.ffxi.get_items(equipment.ammo_bag, equipment.ammo)
        if item and item.id > 0 then
            local item_resource = res.items[item.id]
            if item_resource then
                -- Check if it's stackable ammo
                if item_resource.stack and item_resource.stack > 1 then
                    local full_name = item_resource.name_log or item_resource.name
                    
                    -- If this is different ammo than before, clear old ammo tracking
                    if last_equipped_ammo and last_equipped_ammo ~= full_name then
                        ammo_items = {}
                        ammo_drop_times = {}
                    end
                    
                    -- Track the new ammo
                    ammo_items[full_name] = true
                    last_equipped_ammo = full_name
                    return true
                end
            end
        end
    end
    
    -- No ammo equipped, clear ammo tracking if we had something before
    if last_equipped_ammo then
        ammo_items = {}
        ammo_drop_times = {}
        last_equipped_ammo = nil
    end
    
    return false
end

-- Check if item is ammo
local function is_ammo_item(item_name)
    build_name_mappings()
    local item = item_by_name[item_name]
    if not item then
        return false
    end

    -- Check if it's ammo (type 10)
    if item.type == 10 then
        return true
    end

    -- Check for ranged items that are consumable (like shurikens)
    if item.type == 11 and item.stack and item.stack > 1 then
        return true
    end

    return false
end

-- Expanded list of known usable item IDs. Built once as a module-level
-- constant instead of being re-created inside is_usable_item on every call.
local USABLE_ITEM_IDS = {
    -- Medicines
    [4146] = true, -- Panacea
    [4148] = true, -- Antidote
    [4150] = true, -- Eye Drops
    [4151] = true, -- Echo Drops
    [4154] = true, -- Holy Water
    [4155] = true, -- Remedy
    [4157] = true, -- Poison Potion
    [4164] = true, -- Prism Powder
    [4165] = true, -- Silent Oil
    [5419] = true, -- Electuary
    [5328] = true, -- Hi-Elixir
    [5411] = true, -- Elixir

    -- Ethers and Potions
    [4128] = true, -- Ether
    [4129] = true, -- Ether +1
    [4130] = true, -- Ether +2
    [4131] = true, -- Ether +3
    [4144] = true, -- Hi-Ether
    [4145] = true, -- Hi-Ether +1
    [4112] = true, -- Potion
    [4113] = true, -- Potion +1
    [4114] = true, -- Potion +2
    [4115] = true, -- Potion +3
    [4116] = true, -- Hi-Potion
    [4117] = true, -- Hi-Potion +1
    [4118] = true, -- Hi-Potion +2
    [4119] = true, -- Hi-Potion +3
    [4120] = true, -- X-Potion
    [4121] = true, -- X-Potion +1
    [4122] = true, -- X-Potion +2
    [4123] = true, -- X-Potion +3

    -- Tools
    [5869] = true, -- Ram Mantle
    [5314] = true, -- Toolbag (Shihei)
    [5315] = true, -- Toolbag (Uchitake)
    [5316] = true, -- Toolbag (Tsurara)
    [5317] = true, -- Toolbag (Kawahori-Ogi)
    [5318] = true, -- Toolbag (Makibishi)
    [5319] = true, -- Toolbag (Hiraishin)
    [5734] = true, -- Toolbag (Sanjaku-Tenugui)

    -- Other consumables
    [4172] = true, -- Reraiser
    [5685] = true, -- Rabbit's Foot
    [5686] = true, -- Cheer
}

-- Check if item is usable (items that show as yellow in inventory)
local function is_usable_item(item_name)
    build_name_mappings()
    local item = item_by_name[item_name]
    if not item then
        return false
    end
    local id = item_id_by_name[item_name]

    -- Check if it's food (has a food effect) - type 7
    if item.type == 7 then
        return true
    end

    -- Check for items with yellow inventory color
    -- Yellow items typically have specific flags
    if item.flags then
        local flag_value = item.flags
        -- Handle case where flags might be a table
        if type(flag_value) == "table" then
            if flag_value[1] then
                flag_value = flag_value[1]
            else
                flag_value = nil
            end
        end

        if flag_value and type(flag_value) == "number" then
            -- Flag 0x200 (512) indicates usable items
            -- Flag 0x400 (1024) indicates some consumables
            -- Flag 0x800 (2048) indicates other usables
            if bit.band(flag_value, 0x200) > 0 or
               bit.band(flag_value, 0x400) > 0 or
               bit.band(flag_value, 0x800) > 0 then
                -- Additional check - make sure it's not equipment
                if item.type ~= 4 and item.type ~= 5 and item.type ~= 6 then
                    return true
                end
            end
        end
    end

    -- Check for specific item types that are always usable
    -- Type 1 is general items, type 2 is usable items
    if item.type == 1 or item.type == 2 then
        -- Check if it has a "use delay" which indicates it's usable
        if item.cast_delay and item.cast_delay > 0 then
            return true
        end

        -- Check if item has a recast delay (another indicator)
        if item.recast_delay and item.recast_delay > 0 then
            return true
        end

        -- Check for items that can be "used" based on their category
        -- Category 57 is often usable items
        if item.category and item.category == 57 then
            return true
        end
    end

    if USABLE_ITEM_IDS[id] then
        return true
    end

    return false
end

-- Build name mappings from resources, plus a name->resource cache used by
-- is_ammo_item/is_usable_item. This used to re-scan the entire res.items
-- table (several thousand entries) on every call - now it only does that
-- scan once per addon load and every other call is a no-op.
function build_name_mappings()
    if name_cache_built then
        return
    end

    full_to_short_map = {}
    short_to_full_map = {}
    item_by_name = {}
    item_id_by_name = {}

    for id, item in pairs(res.items) do
        if item.name then
            item_by_name[item.name] = item
            item_id_by_name[item.name] = id
        end
        if item.name_log then
            item_by_name[item.name_log] = item
            item_id_by_name[item.name_log] = id
        end

        if item.name and item.name_log and item.name ~= item.name_log then
            -- name = short name (in inventory)
            -- name_log = full name (in drop messages)
            full_to_short_map[item.name_log] = item.name
            short_to_full_map[item.name] = item.name_log

            -- Also store normalized versions
            local full_normalized = normalize_item_name(item.name_log)
            local short_normalized = normalize_item_name(item.name)
            full_to_short_map[full_normalized] = item.name
            short_to_full_map[short_normalized] = item.name_log
        end
    end

    -- Add some common manual mappings that might not be in resources
    full_to_short_map["One Hundred Byne Bill"] = "100 Byne Bill"
    short_to_full_map["100 Byne Bill"] = "One Hundred Byne Bill"

    full_to_short_map["One Byne Bill"] = "1 Byne Bill"
    short_to_full_map["1 Byne Bill"] = "One Byne Bill"

    full_to_short_map["Ten Thousand Byne Bill"] = "10000 Byne Bill"
    short_to_full_map["10000 Byne Bill"] = "Ten Thousand Byne Bill"

    full_to_short_map["Lungo-Nango Jadeshell"] = "L. Jadeshell"
    short_to_full_map["L. Jadeshell"] = "Lungo-Nango Jadeshell"

    name_cache_built = true
end

-- Get total count of item across all inventory types
local function get_inventory_count(item_name)
    -- Return cached value if recent
    local current_time = os.time()
    if current_time - last_inventory_check < INVENTORY_CHECK_INTERVAL then
        return inventory_cache[item_name] or 0
    end
    
    -- Save previous counts before updating
    previous_inventory_counts = {}
    for k, v in pairs(inventory_cache) do
        previous_inventory_counts[k] = v
    end
    
    -- Update cache and mappings
    last_inventory_check = current_time
    inventory_cache = {}
    build_name_mappings()
    
    -- Check equipped ammo while we're updating inventory
    check_equipped_ammo()
    
    -- All bag IDs to check
    local bags = {
        0,  -- Inventory
        1,  -- Safe
        2,  -- Storage
        3,  -- Temporary
        4,  -- Locker
        5,  -- Satchel
        6,  -- Sack
        7,  -- Case
        8,  -- Wardrobe
        9,  -- Safe 2
        10, -- Wardrobe 2
        11, -- Wardrobe 3
        12, -- Wardrobe 4
        13, -- Wardrobe 5
        14, -- Wardrobe 6
        15, -- Wardrobe 7
        16, -- Wardrobe 8
    }
    
    -- Count all items across all bags
    for _, bag_id in ipairs(bags) do
        local bag = windower.ffxi.get_items(bag_id)
        if bag and bag.enabled then
            for i = 1, bag.max do
                local item = bag[i]
                if item and item.id and item.id > 0 and item.count > 0 then
                    local item_resource = res.items[item.id]
                    if item_resource then
                        local short_name = item_resource.name
                        local full_name = item_resource.name_log or short_name
                        
                        -- Add to count
                        inventory_cache[full_name] = (inventory_cache[full_name] or 0) + item.count
                        
                        -- Also store under normalized full name
                        local full_normalized = normalize_item_name(full_name)
                        if full_normalized ~= full_name then
                            inventory_cache[full_normalized] = inventory_cache[full_name]
                        end
                    end
                end
            end
        end
    end
    
    -- Check for decreases and track them
    for item_name, current_count in pairs(inventory_cache) do
        local prev_count = previous_inventory_counts[item_name] or 0
        if current_count < prev_count then
            local decrease = prev_count - current_count
            recent_increments[item_name] = {amount = -decrease, time = os.time()}
        end
    end
    
    -- Check for items that were in inventory but are now gone
    for item_name, prev_count in pairs(previous_inventory_counts) do
        if not inventory_cache[item_name] and prev_count > 0 then
            recent_increments[item_name] = {amount = -prev_count, time = os.time()}
        end
    end
    
    return inventory_cache[item_name] or 0
end

-- Save settings to file
function save_settings()
    local data = 'return {\n'
    data = data .. '    tracked_items = {\n'
    for item, _ in pairs(tracked_items) do
        data = data .. '        ["' .. item:gsub('"', '\\"') .. '"] = true,\n'
    end
    data = data .. '    },\n'
    data = data .. '    item_counts = {\n'
    for item, count in pairs(item_counts) do
        data = data .. '        ["' .. item:gsub('"', '\\"') .. '"] = ' .. count .. ',\n'
    end
    data = data .. '    },\n'
    data = data .. '    usable_items = {\n'
    for item, _ in pairs(usable_items) do
        data = data .. '        ["' .. item:gsub('"', '\\"') .. '"] = true,\n'
    end
    data = data .. '    },\n'
    data = data .. '    key_items = {\n'
    for item, _ in pairs(key_items) do
        data = data .. '        ["' .. item:gsub('"', '\\"') .. '"] = true,\n'
    end
    data = data .. '    },\n'
    data = data .. '    personal_items = {\n'
    for item, _ in pairs(personal_items) do
        data = data .. '        ["' .. item:gsub('"', '\\"') .. '"] = true,\n'
    end
    data = data .. '    },\n'
    data = data .. '    personal_counts = {\n'
    for item, count in pairs(personal_counts) do
        data = data .. '        ["' .. item:gsub('"', '\\"') .. '"] = ' .. count .. ',\n'
    end
    data = data .. '    },\n'
    data = data .. '    saved_sets = {\n'
    for set_name, set_data in pairs(saved_sets) do
        data = data .. '        ["' .. set_name:gsub('"', '\\"') .. '"] = {\n'
        for _, category in ipairs({'drop', 'personal', 'usable'}) do
            data = data .. '            ' .. category .. ' = {\n'
            for item, _ in pairs(set_data[category] or {}) do
                data = data .. '                ["' .. item:gsub('"', '\\"') .. '"] = true,\n'
            end
            data = data .. '            },\n'
        end
        data = data .. '        },\n'
    end
    data = data .. '    },\n'
    data = data .. '    auto_add_drop = ' .. tostring(auto_add_drop) .. ',\n'
    data = data .. '    auto_add_gil = ' .. tostring(auto_add_gil) .. ',\n'
    data = data .. '    auto_add_personal = ' .. tostring(auto_add_personal) .. ',\n'
    data = data .. '    auto_add_usable = ' .. tostring(auto_add_usable) .. ',\n'
    data = data .. '    quiet_mode = ' .. tostring(quiet_mode) .. ',\n'
    data = data .. '    window_x = ' .. tostring(window_x) .. ',\n'
    data = data .. '    window_y = ' .. tostring(window_y) .. ',\n'
    data = data .. '    focus_item_name = ' .. (focus_item_name and ('"' .. focus_item_name:gsub('"', '\\"') .. '"') or 'nil') .. ',\n'
    data = data .. '    focus_item_category = ' .. (focus_item_category and ('"' .. focus_item_category .. '"') or 'nil') .. '\n'
    data = data .. '}'

    local file = files.new(get_settings_filename())
    file:write(data)
end

-- Load settings from file. Tries the per-character file first; if that
-- doesn't exist yet but the old shared file does, it migrates from the
-- shared file once (so upgrading doesn't look like losing your data).
-- Pass silent=true to suppress the migration chat message (used when
-- re-loading after the player's name becomes known post-login).
local function load_settings(silent)
    local filename = get_settings_filename()
    local file = files.new(filename)
    local used_legacy = false

    if not file:exists() and player_name then
        local legacy = files.new('data/settings.lua')
        if legacy:exists() then
            filename = 'data/settings.lua'
            file = legacy
            used_legacy = true
        end
    end

    if file:exists() then
        local loaded = loadfile(windower.addon_path .. filename)
        if loaded then
            local success, data = pcall(loaded)
            if success and data then
                tracked_items = data.tracked_items or {}
                item_counts = data.item_counts or {}
                usable_items = data.usable_items or {}
                -- Don't load ammo_items from file since we auto-detect equipped ammo
                key_items = data.key_items or {}
                personal_items = data.personal_items or data.obtained_items or {}
                personal_counts = data.personal_counts or data.obtained_counts or {}
                saved_sets = data.saved_sets or {}
                -- Migrate old flat-format sets ({item = true, ...}) to the
                -- new {drop = {...}, personal = {...}, usable = {...}}
                -- structure. A set from before this update won't have any
                -- of those three sub-tables, so treat its entries as drops.
                for existing_set_name, set_data in pairs(saved_sets) do
                    if not (set_data.drop or set_data.personal or set_data.usable) then
                        saved_sets[existing_set_name] = {drop = set_data, personal = {}, usable = {}}
                    end
                end
                -- Load auto-add settings, maintaining backward compatibility
                if data.auto_add ~= nil then
                    -- Old single auto_add setting - apply to drops only
                    auto_add_drop = data.auto_add
                else
                    -- New separate settings
                    auto_add_drop = data.auto_add_drop or false
                    auto_add_gil = data.auto_add_gil ~= false  -- Default true
                    auto_add_personal = data.auto_add_personal or data.auto_add_obtain or true
                    auto_add_usable = data.auto_add_usable ~= false  -- Default true
                end
                quiet_mode = data.quiet_mode or false
                window_x = data.window_x
                window_y = data.window_y
                focus_item_name = data.focus_item_name
                focus_item_category = data.focus_item_category

                -- Convert any short names to full names in tracked items
                build_name_mappings()
                local items_to_convert = {}
                for item_name, _ in pairs(tracked_items) do
                    local full_name = get_full_name(item_name)
                    if full_name ~= item_name then
                        items_to_convert[item_name] = full_name
                    end
                end

                -- Convert tracked items
                for short_name, full_name in pairs(items_to_convert) do
                    tracked_items[short_name] = nil
                    tracked_items[full_name] = true

                    -- Also move counts
                    if item_counts[short_name] then
                        item_counts[full_name] = (item_counts[full_name] or 0) + item_counts[short_name]
                        item_counts[short_name] = nil
                    end
                end

                -- Do the same for personal items
                items_to_convert = {}
                for item_name, _ in pairs(personal_items) do
                    local full_name = get_full_name(item_name)
                    if full_name ~= item_name then
                        items_to_convert[item_name] = full_name
                    end
                end

                for short_name, full_name in pairs(items_to_convert) do
                    personal_items[short_name] = nil
                    personal_items[full_name] = true

                    if personal_counts[short_name] then
                        personal_counts[full_name] = (personal_counts[full_name] or 0) + personal_counts[short_name]
                        personal_counts[short_name] = nil
                    end
                end

                -- Re-check all usable items with the improved criteria
                local items_to_move = {}
                for item_name, _ in pairs(usable_items) do
                    if not is_usable_item(item_name) then
                        items_to_move[item_name] = true
                    end
                end

                -- Move misclassified items to tracked_items
                for item_name, _ in pairs(items_to_move) do
                    usable_items[item_name] = nil
                    tracked_items[item_name] = true
                    if not item_counts[item_name] then
                        item_counts[item_name] = 0
                    end
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Moved "' .. item_name .. '" from usable to regular tracking (not directly usable).')
                end

                if used_legacy and player_name and not silent then
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Migrated shared settings to a per-character file for ' .. player_name .. '.')
                    save_settings()
                end

                return true
            end
        end
    end
    return false
end

-- Sort items alphabetically
local function sort_items_alphabetically(item_list)
    table.sort(item_list, function(a, b)
        local display_a = get_display_name(a)
        local display_b = get_display_name(b)
        return display_a:lower() < display_b:lower()
    end)
    return item_list
end

-- Snapshots all tracked state into a plain table for MogWatch. Item sets
-- (tracked_items, usable_items, etc) are Lua tables used as sets (item
-- name -> true) -- converted to arrays here since that's what the wire
-- protocol's encoder expects for list-shaped data, and what's actually
-- convenient to iterate on the receiving (Python) side.
local function set_to_sorted_array(item_set)
    local out = {}
    for item_name in pairs(item_set) do
        table.insert(out, item_name)
    end
    table.sort(out)
    return out
end

function build_counter_status()
    local function gain(baseline_table, item_name, current_value)
        local baseline = baseline_table[item_name]
        if baseline == nil then
            -- Not in the load-time snapshot, so this item is genuinely new
            -- this session -- its whole current value is the session gain,
            -- not zero (see the detailed note above the snapshot code for
            -- why this distinction matters).
            baseline = 0
            baseline_table[item_name] = 0
        end
        return current_value - baseline
    end

    local drop_list = {}
    for _, item_name in ipairs(set_to_sorted_array(tracked_items)) do
        local inv_count = get_inventory_count(item_name)
        table.insert(drop_list, {
            name = item_name,
            displayName = get_display_name(item_name),
            count = inv_count,
            sessionCount = gain(session_baselines.drop, item_name, inv_count),
        })
    end

    local personal_list = {}
    for _, item_name in ipairs(set_to_sorted_array(personal_items)) do
        local inv_count = get_inventory_count(item_name)
        table.insert(personal_list, {
            name = item_name,
            displayName = get_display_name(item_name),
            count = inv_count,
            sessionCount = gain(session_baselines.personal, item_name, inv_count),
        })
    end

    local usable_list = {}
    for _, item_name in ipairs(set_to_sorted_array(usable_items)) do
        table.insert(usable_list, {
            name = item_name,
            displayName = get_display_name(item_name),
            inventoryCount = get_inventory_count(item_name),
        })
    end

    local ammo_list = {}
    for _, item_name in ipairs(set_to_sorted_array(ammo_items)) do
        table.insert(ammo_list, {
            name = item_name,
            displayName = get_display_name(item_name),
            inventoryCount = get_inventory_count(item_name),
        })
    end

    local key_list = {}
    for _, item_name in ipairs(set_to_sorted_array(key_items)) do
        table.insert(key_list, {
            name = item_name,
            displayName = item_name:gsub('^Key Item:%s*', ''),
        })
    end

    local set_names = {}
    for set_name in pairs(saved_sets) do
        table.insert(set_names, set_name)
    end
    table.sort(set_names)

    return {
        playerName = player_name or '',
        gil = item_counts['Gil'] or 0,
        dropItems = drop_list,
        personalItems = personal_list,
        usableItems = usable_list,
        ammoItems = ammo_list,
        keyItems = key_list,
        savedSets = set_names,
        autoAddDrop = auto_add_drop,
        autoAddPersonal = auto_add_personal,
        autoAddUsable = auto_add_usable,
        autoAddGil = auto_add_gil,
        quietMode = quiet_mode,
        focusItemName = focus_item_name or '',
    }
end

-- Track recent increment
local function track_increment(item_name, amount)
    if recent_increments[item_name] then
        -- If there's already a recent increment, add to it
        local current_time = os.time()
        if current_time - recent_increments[item_name].time <= GREEN_DURATION then
            recent_increments[item_name].amount = recent_increments[item_name].amount + amount
            recent_increments[item_name].time = current_time
        else
            recent_increments[item_name] = {amount = amount, time = current_time}
        end
    else
        recent_increments[item_name] = {amount = amount, time = os.time()}
    end

    -- Focus item alert: every drop/obtain/steal/mug path funnels through
    -- here, so this is the one place that needs to know about it, rather
    -- than adding a check at each individual detection site.
    if amount > 0 and focus_item_name == item_name then
        windower.add_to_chat(COUNTER_COLOR, '\\cs(255,215,0)*** FOCUS ITEM: ' .. item_name .. ' (+' .. amount .. ')! ***\\cr')
    end
end

-- Determine which category an item belongs to
local function get_item_category(item_name)
    if usable_items[item_name] then
        return "usable"
    elseif ammo_items[item_name] then
        return "ammo"
    elseif tracked_items[item_name] then
        return "drop"
    elseif personal_items[item_name] then
        return "personal"
    elseif key_items[item_name] then
        return "key"
    end
    return nil
end

-- Add item to tracking list
local function add_item(item_name)
    if not item_name or item_name == '' then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Please specify an item name.')
        return
    end
    
    -- Check if trying to add gil
    if item_name:lower() == 'gil' then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Gil is automatically tracked and cannot be manually added.')
        return
    end
    
    -- Build mappings if needed
    build_name_mappings()
    
    -- Normalize the item name
    item_name = normalize_item_name(item_name)
    
    -- Convert to full name if it's a short name
    local full_name = get_full_name(item_name)
    
    -- Check if item is already tracked anywhere
    if tracked_items[full_name] or usable_items[full_name] or ammo_items[full_name] or personal_items[full_name] or key_items[full_name] then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: "' .. full_name .. '" is already being tracked.')
        return
    end
    
    -- Don't allow manual adding of ammo - it's auto-detected from equipped
    if is_ammo_item(full_name) then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Ammo is automatically tracked when equipped. Cannot manually add.')
        return
    end
    
    -- Determine category based on item type
    if is_usable_item(full_name) then
        -- Add to usable items
        usable_items[full_name] = true
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Now tracking "' .. full_name .. '" as a usable item.')
    else
        -- Add to regular tracked items. Baselined at whatever's currently
        -- in inventory (not reduced by 1, unlike the auto-add-on-drop
        -- path) -- nothing was just dropped here, so the session gain
        -- should start at 0 and only reflect actual future drops.
        tracked_items[full_name] = true
        item_counts[full_name] = 0
        session_baselines.drop[full_name] = get_inventory_count(full_name)
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Now tracking "' .. full_name .. '".')
    end
    
    save_settings()
    update_display()
end

-- Remove item from tracking list
function remove_item(item_name)
    if not item_name or item_name == '' then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Please specify an item name.')
        return
    end
    
    -- Check if trying to remove gil
    if item_name:lower() == 'gil' then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Gil cannot be manually removed.')
        return
    end
    
    -- Build mappings if needed
    build_name_mappings()
    
    -- Normalize the item name
    item_name = normalize_item_name(item_name)
    
    -- Convert to full name if it's a short name
    local full_name = get_full_name(item_name)
    
    -- Check all categories
    if tracked_items[full_name] then
        tracked_items[full_name] = nil
        item_counts[full_name] = nil
        item_drop_times[full_name] = nil
        recent_increments[full_name] = nil
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Stopped tracking "' .. full_name .. '".')
        save_settings()
        update_display()
    elseif usable_items[full_name] then
        usable_items[full_name] = nil
        usable_drop_times[full_name] = nil
        recent_increments[full_name] = nil
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Stopped tracking usable item "' .. full_name .. '".')
        save_settings()
        update_display()
    elseif ammo_items[full_name] then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Cannot manually remove equipped ammo. Unequip it to stop tracking.')
    elseif personal_items[full_name] then
        personal_items[full_name] = nil
        personal_counts[full_name] = nil
        personal_drop_times[full_name] = nil
        recent_increments[full_name] = nil
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Stopped tracking personal item "' .. full_name .. '".')
        save_settings()
        update_display()
    elseif key_items[full_name] then
        key_items[full_name] = nil
        key_drop_times[full_name] = nil
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Stopped tracking key item "' .. full_name .. '".')
        save_settings()
        update_display()
    else
        windower.add_to_chat(COUNTER_COLOR, 'Counter: "' .. full_name .. '" is not being tracked.')
    end
end

-- Reset count for a specific item
function reset_item(item_name)
    if not item_name or item_name == '' then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Please specify an item name.')
        return
    end
    
    -- Check if trying to reset gil
    if item_name:lower() == 'gil' then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Use "//cnt gil reset" to reset gil.')
        return
    end
    
    -- Build mappings if needed
    build_name_mappings()
    
    -- Normalize the item name
    item_name = normalize_item_name(item_name)
    
    -- Convert to full name if it's a short name
    local full_name = get_full_name(item_name)
    
    if tracked_items[full_name] then
        item_counts[full_name] = 0
        item_drop_times[full_name] = nil
        recent_increments[full_name] = nil
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Reset count for "' .. full_name .. '" to 0.')
        save_settings()
        update_display()
    elseif personal_items[full_name] then
        personal_counts[full_name] = 0
        personal_drop_times[full_name] = nil
        recent_increments[full_name] = nil
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Reset count for personal item "' .. full_name .. '" to 0.')
        save_settings()
        update_display()
    else
        windower.add_to_chat(COUNTER_COLOR, 'Counter: "' .. full_name .. '" is not being tracked with a counter.')
    end
end

-- List all tracked items
local function list_items()
    windower.add_to_chat(COUNTER_COLOR, 'Counter: Currently tracking:')
    
    -- Show usable items
    if next(usable_items) then
        windower.add_to_chat(COUNTER_COLOR, '  Usable Items:')
        local sorted_usable = {}
        for item_name, _ in pairs(usable_items) do
            table.insert(sorted_usable, item_name)
        end
        sorted_usable = sort_items_alphabetically(sorted_usable)
        
        for i, item_name in ipairs(sorted_usable) do
            local inv_count = get_inventory_count(item_name)
            windower.add_to_chat(COUNTER_COLOR, string.format('    %d. %s (Inventory: %d)', i, item_name, inv_count))
        end
    end
    
    -- Show ammo
    if next(ammo_items) then
        windower.add_to_chat(COUNTER_COLOR, '  Equipped Ammo:')
        local sorted_ammo = {}
        for item_name, _ in pairs(ammo_items) do
            table.insert(sorted_ammo, item_name)
        end
        sorted_ammo = sort_items_alphabetically(sorted_ammo)
        
        for i, item_name in ipairs(sorted_ammo) do
            local inv_count = get_inventory_count(item_name)
            windower.add_to_chat(COUNTER_COLOR, string.format('    %d. %s (Inventory: %d)', i, item_name, inv_count))
        end
    end
    
    -- Show dropped items
    if next(tracked_items) then
        windower.add_to_chat(COUNTER_COLOR, '  Item Drops:')
        local sorted_drops = {}
        for item_name, _ in pairs(tracked_items) do
            table.insert(sorted_drops, item_name)
        end
        sorted_drops = sort_items_alphabetically(sorted_drops)
        
        for i, item_name in ipairs(sorted_drops) do
            local item_count = item_counts[item_name] or 0
            local inv_count = get_inventory_count(item_name)
            windower.add_to_chat(COUNTER_COLOR, string.format('    %d. %s (Count: %d, Inventory: %d)', i, item_name, item_count, inv_count))
        end
    end
    
    -- Show personal drops
    if next(personal_items) then
        windower.add_to_chat(COUNTER_COLOR, '  Personal Drops:')
        local sorted_personal = {}
        for item_name, _ in pairs(personal_items) do
            table.insert(sorted_personal, item_name)
        end
        sorted_personal = sort_items_alphabetically(sorted_personal)
        
        for i, item_name in ipairs(sorted_personal) do
            local item_count = personal_counts[item_name] or 0
            local inv_count = get_inventory_count(item_name)
            windower.add_to_chat(COUNTER_COLOR, string.format('    %d. %s (Count: %d, Inventory: %d)', i, item_name, item_count, inv_count))
        end
    end
    
    -- Show gil
    local gil = item_counts["Gil"] or 0
    if gil > 0 then
        windower.add_to_chat(COUNTER_COLOR, '  Gil: ' .. gil)
    end
    
    -- Show key items
    if next(key_items) then
        windower.add_to_chat(COUNTER_COLOR, '  Key Items:')
        local sorted_keys = {}
        for item_name, _ in pairs(key_items) do
            table.insert(sorted_keys, item_name)
        end
        sorted_keys = sort_items_alphabetically(sorted_keys)
        
        for i, item_name in ipairs(sorted_keys) do
            local display_name = item_name:gsub("^Key Item:%s*", "")
            windower.add_to_chat(COUNTER_COLOR, string.format('    %d. %s', i, display_name))
        end
    end
end

-- Save current tracked items as a set
-- Sets store three categories together: Item Drops, Personal Drops, and
-- Usable Items, so a single "farming loadout" can include more than just
-- what enemies drop.
local function save_set(set_name)
    if not set_name or set_name == '' then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Please specify a set name.')
        return
    end

    local drop_snapshot, personal_snapshot, usable_snapshot = {}, {}, {}
    local count = 0
    for item in pairs(tracked_items) do
        drop_snapshot[item] = true
        count = count + 1
    end
    for item in pairs(personal_items) do
        personal_snapshot[item] = true
        count = count + 1
    end
    for item in pairs(usable_items) do
        usable_snapshot[item] = true
        count = count + 1
    end

    if count == 0 then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: No items to save. Add items before creating a set.')
        return
    end

    saved_sets[set_name] = {drop = drop_snapshot, personal = personal_snapshot, usable = usable_snapshot}

    windower.add_to_chat(COUNTER_COLOR, 'Counter: Saved set "' .. set_name .. '" with ' .. count .. ' items (drops/personal/usable).')
    save_settings()
end

-- Load a saved set. Item Drops are replaced (matching the original
-- behavior, so switching farming spots doesn't accumulate old targets).
-- Personal Drops and Usable Items are merged in additively instead of
-- replacing, since those categories are often auto-populated and a set
-- shouldn't wipe tracking that has nothing to do with it.
local function load_set(set_name)
    if not set_name or set_name == '' then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Please specify a set name.')
        return
    end

    local set_data = saved_sets[set_name]
    if not set_data then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Set "' .. set_name .. '" not found.')
        return
    end

    tracked_items = {}
    item_drop_times = {}
    recent_increments = {}

    local count = 0
    for item in pairs(set_data.drop or {}) do
        tracked_items[item] = true
        if not item_counts[item] then
            item_counts[item] = 0
        end
        count = count + 1
    end
    for item in pairs(set_data.personal or {}) do
        if not personal_items[item] then
            personal_items[item] = true
            if not personal_counts[item] then
                personal_counts[item] = 0
            end
            count = count + 1
        end
    end
    for item in pairs(set_data.usable or {}) do
        if not usable_items[item] then
            usable_items[item] = true
            count = count + 1
        end
    end

    windower.add_to_chat(COUNTER_COLOR, 'Counter: Loaded set "' .. set_name .. '" (' .. count .. ' items - drops replaced, personal/usable merged in).')
    save_settings()
    update_display()
end

-- List all saved sets
local function list_sets()
    windower.add_to_chat(COUNTER_COLOR, 'Counter: Saved sets:')
    
    -- Create a sorted list of set names
    local sorted_sets = {}
    for set_name, _ in pairs(saved_sets) do
        table.insert(sorted_sets, set_name)
    end
    table.sort(sorted_sets)
    
    if #sorted_sets > 0 then
        for i, set_name in ipairs(sorted_sets) do
            local set_data = saved_sets[set_name]
            local drop_count, personal_count, usable_count = 0, 0, 0
            for _ in pairs(set_data.drop or {}) do drop_count = drop_count + 1 end
            for _ in pairs(set_data.personal or {}) do personal_count = personal_count + 1 end
            for _ in pairs(set_data.usable or {}) do usable_count = usable_count + 1 end
            windower.add_to_chat(COUNTER_COLOR, '  ' .. i .. '. ' .. set_name .. ' (drops: ' .. drop_count .. ', personal: ' .. personal_count .. ', usable: ' .. usable_count .. ')')
        end
    else
        windower.add_to_chat(COUNTER_COLOR, '  No saved sets.')
    end
end

-- Delete a saved set
local function delete_set(set_name)
    if not set_name or set_name == '' then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Please specify a set name.')
        return
    end
    
    if saved_sets[set_name] then
        saved_sets[set_name] = nil
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Deleted set "' .. set_name .. '".')
        save_settings()
    else
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Set "' .. set_name .. '" not found.')
    end
end

-- Strip FFXI text formatting codes
local function strip_format(text)
    -- Remove auto-translate brackets and other formatting
    text = text:gsub(string.char(0xEF)..string.char(0x27), '')
    text = text:gsub(string.char(0xEF)..string.char(0x28), '')
    
    -- Remove color codes and other formatting codes
    text = text:gsub(string.char(0x1F)..'[%z\1-\255]', '')
    text = text:gsub(string.char(0x1E)..'[%z\1-\255]', '')
    text = text:gsub(string.char(0x7F)..'[%z\1-\255]', '')
    
    -- Remove any other control characters
    text = text:gsub('%c', '')
	    return text
end

-- Parse text for item drops
local function set_auto_add(category, value)
    local label
    if category == 'drop' then auto_add_drop = value; label = 'drops'
    elseif category == 'usable' then auto_add_usable = value; label = 'usable items'
    elseif category == 'gil' then auto_add_gil = value; label = 'gil'
    elseif category == 'personal' then auto_add_personal = value; label = 'personal drops'
    elseif category == 'quiet' then
        quiet_mode = value
        local color = value and '\\cs(0,255,0)' or '\\cs(255,0,0)'
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Quiet mode is now ' .. color .. (value and 'ON' or 'OFF') .. '\\cr.')
        save_settings()
        update_display()
        return
    else return
    end
    local color = value and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for ' .. label .. ' is now ' .. color .. (value and 'ON' or 'OFF') .. '\\cr.')
    save_settings()
    update_display()
end

-- Only prints when quiet mode is off. Used for automatic drop/steal/mug/
-- obtain detection messages; commands the user types always get their
-- normal confirmation via windower.add_to_chat directly, quiet mode or not.
local function announce(msg)
    if not quiet_mode then
        windower.add_to_chat(COUNTER_COLOR, msg)
    end
end

local function check_for_drops(message, mode)
    -- Skip our own messages and debug messages
    if message:find("^Counter:") or message:find("^DEBUG ALL:") or message:find("^Counter DEBUG:") then
        return
    end
    
    -- Try to get player name if we don't have it yet
    if not player_name then
        get_player_name()
    end
    
    -- Debug all messages if enabled
    if debug_all then
        windower.add_to_chat(COUNTER_COLOR, string.format('DEBUG ALL: Mode=%d, Message=%s', mode, message))
    end
    
    -- Strip formatting for all messages
    local clean_message = strip_format(message)
    local lower_message = clean_message:lower()

    -- More flexible Steal detection - look for "steal" and item pattern
    -- Uses word-boundary frontiers so this only matches the standalone word
    -- "steal"/"steals", not substrings like "stealthy".
    if lower_message:find("%f[%a]steals?%f[%A]") and auto_add_personal then
        -- Try various patterns that might contain steal
        local item_name = nil
        
        -- Look for parentheses first (most reliable for item names)
        item_name = clean_message:match("%(([^%)]+)%)")
        
        if not item_name then
            -- Pattern: "steal <item> from"
            item_name = clean_message:match("[Ss]teals?%s+(.-)%s+from")
        end
        
        if not item_name then
            -- Pattern: Looking for text between "steal" and a mob name pattern
            local steal_part = clean_message:match("[Ss]teal%s+(.+)")
            if steal_part then
                -- Try to identify where the mob name starts (usually contains hyphens or specific patterns)
                item_name = steal_part:match("^(.-)%s+%w+%-?%w*$")
                if not item_name then
                    -- If no mob pattern found, just take the first few words
                    item_name = steal_part:match("^([%w%s]+)")
                end
            end
        end
        
        if item_name then
            -- Clean up the item name
            item_name = item_name:gsub("[%.!%?]+$", ""):gsub("^%s+", ""):gsub("%s+$", "")
            
            -- Skip if empty or if it's the player name
            if item_name ~= "" and item_name ~= player_name then
                item_name = normalize_item_name(item_name)
                
                if debug_mode then
                    windower.add_to_chat(COUNTER_COLOR, string.format('Counter DEBUG: Steal detected: "%s"', item_name))
                end
                
                -- Check if it's a usable item
                if auto_add_usable and is_usable_item(item_name) then
                    if not usable_items[item_name] then
                        usable_items[item_name] = true
                    end
                    usable_drop_times[item_name] = os.time()
                    track_increment(item_name, 1)
                    announce('Counter: Stole usable item - ' .. item_name .. '!')
                else
                    -- Add to personal drops
                    if not personal_items[item_name] then
                        personal_items[item_name] = true
                    end
                    
                    personal_counts[item_name] = (personal_counts[item_name] or 0) + 1
                    personal_drop_times[item_name] = os.time()
                    track_increment(item_name, 1)
                    announce('Counter: Steal - ' .. item_name .. '! Total: ' .. personal_counts[item_name])
                end
                
                save_settings()
                update_display()
                return
            end
        end
    end
    
    -- More flexible Mug detection - look for "mug" and gil amount
    -- Uses word-boundary frontiers so "smug"/"mugwort"/etc. don't false-trigger
    -- (plain string.find("smug", "mug") would otherwise match).
    if lower_message:find("%f[%a]mugs?%f[%A]") and auto_add_gil then
        -- Try to find gil amount near "mug"
        local gil_amount = nil
        
        -- Pattern 1: number followed by gil
        gil_amount = clean_message:match("(%d[%d,]*) gil")
        if not gil_amount then
            -- Pattern 2: gil followed by number
            gil_amount = clean_message:match("gil%s*:%s*(%d[%d,]*)")
        end
        if not gil_amount then
            -- Pattern 3: just a number near mug
            gil_amount = clean_message:match("[Mm]ug%s*:?%s*(%d[%d,]*)")
        end
        
        if gil_amount then
            -- Remove commas from gil amount
            local clean_gil = gil_amount:gsub(",", "")
            gil_amount = tonumber(clean_gil)
            
            if gil_amount and gil_amount > 0 then
                if debug_mode then
                    windower.add_to_chat(COUNTER_COLOR, string.format('Counter DEBUG: Mug detected: %d gil', gil_amount))
                end
                
                item_counts["Gil"] = (item_counts["Gil"] or 0) + gil_amount
                item_drop_times["Gil"] = os.time()
                track_increment("Gil", gil_amount)
                announce('Counter: Mugged ' .. gil_amount .. ' gil! Total: ' .. item_counts["Gil"])
                save_settings()
                update_display()
                return
            end
        end
    end
    
    -- Check for "You obtain (x) <item>" pattern
    local obtain_count, obtain_item = clean_message:match("^You obtain (%d+) (.+)%.$")
    if not obtain_count then
        obtain_count, obtain_item = clean_message:match("^You obtain (%d+) (.+)$")
    end
    
    if obtain_count and obtain_item and auto_add_personal then
        local count = tonumber(obtain_count)
        if count then
            local item_name = normalize_item_name(obtain_item)
            
            if debug_mode then
                windower.add_to_chat(COUNTER_COLOR, string.format('Counter DEBUG: You obtain %d %s', count, item_name))
            end
            
            -- Check if it's a usable item
            if auto_add_usable and is_usable_item(item_name) then
                if not usable_items[item_name] then
                    usable_items[item_name] = true
                end
                usable_drop_times[item_name] = os.time()
                track_increment(item_name, count)
                announce('Counter: Obtained ' .. count .. ' usable item - ' .. item_name .. '!')
            else
                -- Add to personal drops
                if not personal_items[item_name] then
                    personal_items[item_name] = true
                end
                
                personal_counts[item_name] = (personal_counts[item_name] or 0) + count
                personal_drop_times[item_name] = os.time()
                track_increment(item_name, count)
                announce('Counter: Obtained ' .. count .. ' ' .. item_name .. '! Total: ' .. personal_counts[item_name])
            end
            
            save_settings()
            update_display()
            return
        end
    end
    
    -- Check for "Obtained:" items (from chests/NPCs) - handle various formats
    if auto_add_personal then
        local obtained_item = nil
        
        -- Try different patterns
        obtained_item = clean_message:match("^Obtained:%s*(.+)$")
        if not obtained_item then
            obtained_item = clean_message:match("^You obtained:%s*(.+)$")
        end
        if not obtained_item then
            obtained_item = clean_message:match("^Obtained%s+(.+)$")
        end
        
        if obtained_item then
            -- Clean up the item name
            obtained_item = obtained_item:gsub("%.+$", "")
            obtained_item = obtained_item:gsub("!+$", "")
            obtained_item = obtained_item:gsub("^%s+", "")
            obtained_item = obtained_item:gsub("%s+$", "")
            
            -- Skip if it's empty or just punctuation
            if obtained_item == "" or obtained_item:match("^[%.!%s]+$") then
                return
            end
            
            local item_name = normalize_item_name(obtained_item)
            
            if debug_mode and not message:find("^Counter:") then
                windower.add_to_chat(COUNTER_COLOR, string.format('Counter DEBUG: Found personal drop: "%s" -> "%s"', obtained_item, item_name))
            end
            
            -- Check if it's a key item
            if item_name:find("^Key Item:") then
                if not key_items[item_name] then
                    key_items[item_name] = true
                    key_drop_times[item_name] = os.time()
                    announce('Counter: Key item obtained - ' .. item_name:gsub("^Key Item:%s*", "") .. '!')
                end
            -- Check if it's a usable item
            elseif auto_add_usable and is_usable_item(item_name) then
                if not usable_items[item_name] then
                    usable_items[item_name] = true
                    usable_drop_times[item_name] = os.time()
                    track_increment(item_name, 1)
                    announce('Counter: Usable item obtained - ' .. item_name .. '!')
                end
            else
                -- Regular personal item
                if not personal_items[item_name] then
                    personal_items[item_name] = true
                end
                
                personal_counts[item_name] = (personal_counts[item_name] or 0) + 1
                personal_drop_times[item_name] = os.time()
                track_increment(item_name, 1)
                announce('Counter: Personal drop - ' .. item_name .. '! Total: ' .. personal_counts[item_name])
            end
            
            save_settings()
            update_display()
            return
        end
    end
    
    -- Special handling for mode 127 (drops)
    if mode == 127 then
        if debug_mode then
            windower.add_to_chat(COUNTER_COLOR, string.format('Counter DEBUG: Mode 127 detected!'))
            windower.add_to_chat(COUNTER_COLOR, string.format('Counter DEBUG: Cleaned message: "%s"', clean_message))
            if player_name then
                windower.add_to_chat(COUNTER_COLOR, string.format('Counter DEBUG: Tracking drops for: %s', player_name))
            end
        end
        
        -- Check if this is an obtain message
        if clean_message:lower():find("obtain") then
            -- Check for gil first
            local gil_amount = nil
            local player = nil
            
            -- Try different gil patterns
            player, gil_amount = clean_message:match("^(%w+) obtains? ([%d,]+) gil%.?$")
            if not player then
                gil_amount = clean_message:match("^You obtain ([%d,]+) gil%.?$")
                player = player_name
            end
            
            if gil_amount and player then
                -- Only count if it's our character's drops and auto-add gil is on
                if player_name and player == player_name and auto_add_gil then
                    -- Remove commas from gil amount
                    local clean_gil = gil_amount:gsub(",", "")
                    -- Convert to number without passing the count from gsub
                    gil_amount = tonumber(clean_gil)
                    if gil_amount then
                        item_counts["Gil"] = (item_counts["Gil"] or 0) + gil_amount
                        item_drop_times["Gil"] = os.time()
                        track_increment("Gil", gil_amount)
                        announce('Counter: Gained ' .. gil_amount .. ' gil! Total: ' .. item_counts["Gil"])
                        save_settings()
                        update_display()
                    end
                end
                return
            end
            
            -- Try to extract player name and item
            local item_match = nil
            player, item_match = clean_message:match("^(%w+) obtains? an? (.+)%.$")
            if not player then
                player, item_match = clean_message:match("^(%w+) obtains? (.+)%.$")
            end
            if not player then
                player, item_match = clean_message:match("^(%w+) obtains? an? (.+)$")
            end
            if not player then
                player, item_match = clean_message:match("^(%w+) obtains? (.+)$")
            end
            
            if player and item_match then
                -- Only count if it's our character's drops
                if player_name and player ~= player_name then
                    if debug_mode then
                        windower.add_to_chat(COUNTER_COLOR, string.format('Counter DEBUG: Drop by %s ignored (not %s)', player, player_name))
                    end
                    return
                end
                
                -- Remove any trailing punctuation or whitespace
                item_match = item_match:gsub("[%.!%?]+$", ""):gsub("^%s+", ""):gsub("%s+$", "")
                
                -- Normalize the item name
                local normalized_item = normalize_item_name(item_match)
                
                if debug_mode then
                    windower.add_to_chat(COUNTER_COLOR, string.format('Counter DEBUG: Found - Player: "%s", Item: "%s" -> "%s"', player, item_match, normalized_item))
                end
                
                -- Check if it's a usable item and auto-add is on
                if auto_add_usable and is_usable_item(normalized_item) and not usable_items[normalized_item] then
                    usable_items[normalized_item] = true
                    usable_drop_times[normalized_item] = os.time()
                    track_increment(normalized_item, 1)
                    announce('Counter: Auto-added "' .. normalized_item .. '" to usable items.')
                    save_settings()
                    update_display()
                    return
                end
                
                -- Auto-add functionality for drops
                if auto_add_drop and not tracked_items[normalized_item] and not usable_items[normalized_item] and not ammo_items[normalized_item] then
                    -- Snapshot the session baseline BEFORE this item is
                    -- marked as tracked, so this one drop (not any
                    -- inventory the player already had) is what shows as
                    -- the session gain. Confirmed this matters: a report
                    -- showed an item auto-added mid-session starting its
                    -- session count at the player's full current
                    -- inventory total instead of just the new drop.
                    -- Deliberately computed as (current inventory - 1)
                    -- rather than reading the cache directly -- the
                    -- inventory cache's 1-second refresh could race with
                    -- this chat-triggered detection either way, so
                    -- explicitly accounting for this one drop is more
                    -- reliable than hoping the cache hasn't updated yet.
                    session_baselines.drop[normalized_item] = math.max(0, get_inventory_count(normalized_item) - 1)
                    -- Check if it's ammo - ammo dropped from enemies goes to item drops with auto-add
                    if is_ammo_item(normalized_item) then
                        tracked_items[normalized_item] = true
                        item_counts[normalized_item] = 0
                        announce('Counter: Auto-added ammo "' .. normalized_item .. '" to item drops.')
                    else
                        tracked_items[normalized_item] = true
                        item_counts[normalized_item] = 0
                        announce('Counter: Auto-added "' .. normalized_item .. '" to tracking list.')
                    end
                end
                
                -- Check if we're tracking this item
                if tracked_items[normalized_item] then
                    item_counts[normalized_item] = (item_counts[normalized_item] or 0) + 1
                    item_drop_times[normalized_item] = os.time()  -- Record drop time for color
                    track_increment(normalized_item, 1)
                    announce('Counter: ' .. normalized_item .. ' dropped! Total: ' .. item_counts[normalized_item])
                    save_settings()
                    update_display()
                elseif usable_items[normalized_item] then
                    usable_drop_times[normalized_item] = os.time()
                    track_increment(normalized_item, 1)
                    announce('Counter: Usable item ' .. normalized_item .. ' dropped!')
                    save_settings()
                    update_display()
                elseif ammo_items[normalized_item] then
                    ammo_drop_times[normalized_item] = os.time()
                    track_increment(normalized_item, 1)
                    announce('Counter: Ammo ' .. normalized_item .. ' dropped!')
                    save_settings()
                    update_display()
                else
                    if debug_mode then
                        windower.add_to_chat(COUNTER_COLOR, 'Counter DEBUG: Item "' .. normalized_item .. '" not in tracking list')
                        windower.add_to_chat(COUNTER_COLOR, 'Counter DEBUG: Tracked items:')
                        for tracked, _ in pairs(tracked_items) do
                            windower.add_to_chat(COUNTER_COLOR, '  - "' .. tracked .. '"')
                        end
                    end
                end
            elseif debug_mode then
                windower.add_to_chat(COUNTER_COLOR, 'Counter DEBUG: Failed to parse obtain message')
            end
        end
    end
end

-- Timer to update display colors
windower.register_event('time change', function()
    -- Check if any items need color updates
    local needs_update = false
    local current_time = os.time()
    
    for item_name, drop_time in pairs(item_drop_times) do
        if current_time - drop_time > GREEN_DURATION then
            needs_update = true
            break
        end
    end
    
    for item_name, drop_time in pairs(personal_drop_times) do
        if current_time - drop_time > GREEN_DURATION then
            needs_update = true
            break
        end
    end
    
    for item_name, drop_time in pairs(usable_drop_times) do
        if current_time - drop_time > GREEN_DURATION then
            needs_update = true
            break
        end
    end
    
    for item_name, drop_time in pairs(ammo_drop_times) do
        if current_time - drop_time > GREEN_DURATION then
            needs_update = true
            break
        end
    end
    
    for item_name, drop_time in pairs(key_drop_times) do
        if current_time - drop_time > GREEN_DURATION then
            needs_update = true
            break
        end
    end
    
    for item_name, increment_data in pairs(recent_increments) do
        if current_time - increment_data.time > RED_DURATION then
            needs_update = true
            break
        end
    end
    
    -- Also update if inventory might have changed
    if current_time - last_inventory_check >= INVENTORY_CHECK_INTERVAL then
        needs_update = true
    end
    
    if needs_update then
        update_display()
    end
end)

-- Register for incoming text event
windower.register_event('incoming text', function(original, modified, original_mode, modified_mode)
    check_for_drops(original, original_mode)
end)

-- Register for login event to get player name
windower.register_event('login', function()
    -- Delay slightly to ensure player data is available
    windower.send_command('@wait 1; lua i counter get_player_name')
end)

-- Register for equipment change event to update ammo tracking
windower.register_event('status change', function()
    -- Check equipped ammo whenever status changes
    check_equipped_ammo()
    update_display()
end)

-- Also check ammo on job change
windower.register_event('job change', function()
    check_equipped_ammo()
    update_display()
end)

-- Command handler
local function handle_counter_command(...)
    local args = {...}
    local command = args[1]
    
    if command then
        command = command:lower()
        table.remove(args, 1)
        
        if command == 'get_player_name' then
            -- Internal command to get player name after login
            local had_name = player_name ~= nil
            get_player_name()
            if player_name then
                windower.add_to_chat(COUNTER_COLOR, 'Counter: Now tracking drops for ' .. player_name)
                if not had_name then
                    -- We loaded before the character was known and used the
                    -- shared fallback file; now that we know who this is,
                    -- switch to (and possibly migrate into) their own file.
                    load_settings(true)
                end
                update_display()
            end
        elseif command == 'auto' then
            local category = args[1]
            local setting = args[2]
            
            if category then
                category = category:lower()
                
                if category == 'drop' then
                    if setting then
                        setting = setting:lower()
                        if setting == 'on' then
                            auto_add_drop = true
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for drops is now \\cs(0,255,0)ON\\cr.')
                        elseif setting == 'off' then
                            auto_add_drop = false
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for drops is now \\cs(255,0,0)OFF\\cr.')
                        else
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Use "//counter auto drop on" or "//counter auto drop off".')
                        end
                        save_settings()
                        update_display()
                    else
                        local color = auto_add_drop and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for drops is currently ' .. color .. (auto_add_drop and 'ON' or 'OFF') .. '\\cr')
                    end
                    
                elseif category == 'usable' then
                    if setting then
                        setting = setting:lower()
                        if setting == 'on' then
                            auto_add_usable = true
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for usable items is now \\cs(0,255,0)ON\\cr.')
                        elseif setting == 'off' then
                            auto_add_usable = false
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for usable items is now \\cs(255,0,0)OFF\\cr.')
                        else
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Use "//counter auto usable on" or "//counter auto usable off".')
                        end
                        save_settings()
                        update_display()
                    else
                        local color = auto_add_usable and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for usable items is currently ' .. color .. (auto_add_usable and 'ON' or 'OFF') .. '\\cr')
                    end
                    
                elseif category == 'gil' then
                    if setting then
                        setting = setting:lower()
                        if setting == 'on' then
                            auto_add_gil = true
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for gil is now \\cs(0,255,0)ON\\cr.')
                        elseif setting == 'off' then
                            auto_add_gil = false
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for gil is now \\cs(255,0,0)OFF\\cr.')
                        else
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Use "//counter auto gil on" or "//counter auto gil off".')
                        end
                        save_settings()
                        update_display()
                    else
                        local color = auto_add_gil and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for gil is currently ' .. color .. (auto_add_gil and 'ON' or 'OFF') .. '\\cr')
                    end
                    
                elseif category == 'personal' or category == 'obtain' then  -- Support both for backward compatibility
                    if setting then
                        setting = setting:lower()
                        if setting == 'on' then
                            auto_add_personal = true
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for personal drops is now \\cs(0,255,0)ON\\cr.')
                        elseif setting == 'off' then
                            auto_add_personal = false
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for personal drops is now \\cs(255,0,0)OFF\\cr.')
                        else
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Use "//counter auto personal on" or "//counter auto personal off".')
                        end
                        save_settings()
                        update_display()
                    else
                        local color = auto_add_personal and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for personal drops is currently ' .. color .. (auto_add_personal and 'ON' or 'OFF') .. '\\cr')
                    end
                    
                elseif category == 'all' then
                    if setting then
                        setting = setting:lower()
                        if setting == 'on' then
                            auto_add_drop = true
                            auto_add_gil = true
                            auto_add_personal = true
                            auto_add_usable = true
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for all categories is now \\cs(0,255,0)ON\\cr.')
                        elseif setting == 'off' then
                            auto_add_drop = false
                            auto_add_gil = false
                            auto_add_personal = false
                            auto_add_usable = false
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for all categories is now \\cs(255,0,0)OFF\\cr.')
                        else
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Use "//counter auto all on" or "//counter auto all off".')
                        end
                        save_settings()
                        update_display()
                    else
                        windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add status:')
                        local drop_color = auto_add_drop and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        local usable_color = auto_add_usable and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        local personal_color = auto_add_personal and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        local gil_color = auto_add_gil and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        windower.add_to_chat(COUNTER_COLOR, '  Drops: ' .. drop_color .. (auto_add_drop and 'ON' or 'OFF') .. '\\cr')
                        windower.add_to_chat(COUNTER_COLOR, '  Usable: ' .. usable_color .. (auto_add_usable and 'ON' or 'OFF') .. '\\cr')
                        windower.add_to_chat(COUNTER_COLOR, '  Personal: ' .. personal_color .. (auto_add_personal and 'ON' or 'OFF') .. '\\cr')
                        windower.add_to_chat(COUNTER_COLOR, '  Gil: ' .. gil_color .. (auto_add_gil and 'ON' or 'OFF') .. '\\cr')
                    end
                    
                else
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Valid auto categories: drop, usable, gil, personal, all')
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Example: "//counter auto drop on" or "//counter auto all off"')
                end
            else
                windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add status:')
                local drop_color = auto_add_drop and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                local usable_color = auto_add_usable and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                local personal_color = auto_add_personal and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                local gil_color = auto_add_gil and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                windower.add_to_chat(COUNTER_COLOR, '  Drops: ' .. drop_color .. (auto_add_drop and 'ON' or 'OFF') .. '\\cr')
                windower.add_to_chat(COUNTER_COLOR, '  Usable: ' .. usable_color .. (auto_add_usable and 'ON' or 'OFF') .. '\\cr')
                windower.add_to_chat(COUNTER_COLOR, '  Personal: ' .. personal_color .. (auto_add_personal and 'ON' or 'OFF') .. '\\cr')
                windower.add_to_chat(COUNTER_COLOR, '  Gil: ' .. gil_color .. (auto_add_gil and 'ON' or 'OFF') .. '\\cr')
                windower.add_to_chat(COUNTER_COLOR, 'Counter: Use "//counter auto <category> on/off" where category is: drop, usable, gil, personal, or all')
            end
        elseif command == 'ammo' then
            -- For ammo, just show what's currently equipped
            windower.add_to_chat(COUNTER_COLOR, 'Counter: Equipped Ammo:')
            if next(ammo_items) then
                for item_name, _ in pairs(ammo_items) do
                    local inv_count = get_inventory_count(item_name)
                    windower.add_to_chat(COUNTER_COLOR, string.format('  %s (Inventory: %d)', item_name, inv_count))
                end
            else
                windower.add_to_chat(COUNTER_COLOR, '  No ammo currently equipped.')
            end
            windower.add_to_chat(COUNTER_COLOR, 'Counter: Ammo is automatically tracked when equipped.')
        elseif command == 'gil' then
            local subcmd = args[1]
            if subcmd then
                subcmd = subcmd:lower()
                if subcmd == 'reset' then
                    item_counts["Gil"] = 0
                    item_drop_times["Gil"] = nil
                    recent_increments["Gil"] = nil
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Gil reset to 0.')
                    save_settings()
                    update_display()
                elseif subcmd == 'clear' then
                    item_counts["Gil"] = 0
                    item_drop_times["Gil"] = nil
                    recent_increments["Gil"] = nil
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Gil cleared.')
                    save_settings()
                    update_display()
                else
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Unknown gil command. Use "reset" or "clear".')
                end
            else
                local gil = item_counts["Gil"] or 0
                windower.add_to_chat(COUNTER_COLOR, 'Counter: Gil obtained: ' .. gil)
            end
        elseif command == 'use' then
            local subcmd = args[1]
            if subcmd then
                subcmd = subcmd:lower()
                if subcmd == 'clear' then
                    -- Clear increments for the items being removed BEFORE
                    -- wiping usable_items, otherwise this check is always
                    -- false and recent_increments never gets cleaned up.
                    for item, _ in pairs(usable_items) do
                        recent_increments[item] = nil
                    end
                    usable_items = {}
                    usable_drop_times = {}
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Usable items list cleared.')
                    save_settings()
                    update_display()
                elseif subcmd == 'list' then
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Usable Items:')
                    local sorted = {}
                    for item_name, _ in pairs(usable_items) do
                        table.insert(sorted, item_name)
                    end
                    sorted = sort_items_alphabetically(sorted)
                    if #sorted > 0 then
                        for i, item_name in ipairs(sorted) do
                            local inv_count = get_inventory_count(item_name)
                            windower.add_to_chat(COUNTER_COLOR, string.format('  %d. %s (Inventory: %d)', i, item_name, inv_count))
                        end
                    else
                        windower.add_to_chat(COUNTER_COLOR, '  No usable items tracked.')
                    end
                else
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Unknown use command. Use "clear" or "list".')
                end
            else
                -- Show usable list
                windower.add_to_chat(COUNTER_COLOR, 'Counter: Usable Items:')
                local sorted = {}
                for item_name, _ in pairs(usable_items) do
                    table.insert(sorted, item_name)
                end
                sorted = sort_items_alphabetically(sorted)
                if #sorted > 0 then
                    for i, item_name in ipairs(sorted) do
                        local inv_count = get_inventory_count(item_name)
                        windower.add_to_chat(COUNTER_COLOR, string.format('  %d. %s (Inventory: %d)', i, item_name, inv_count))
                    end
                else
                    windower.add_to_chat(COUNTER_COLOR, '  No usable items tracked.')
                end
            end
        elseif command == 'key' then
            local subcmd = args[1]
            if subcmd then
                subcmd = subcmd:lower()
                if subcmd == 'clear' then
                    key_items = {}
                    key_drop_times = {}
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Key items list cleared.')
                    save_settings()
                    update_display()
                elseif subcmd == 'list' then
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Key Items:')
                    local sorted = {}
                    for item_name, _ in pairs(key_items) do
                        table.insert(sorted, item_name)
                    end
                    sorted = sort_items_alphabetically(sorted)
                    if #sorted > 0 then
                        for i, item_name in ipairs(sorted) do
                            local display_name = item_name:gsub("^Key Item:%s*", "")
                            windower.add_to_chat(COUNTER_COLOR, string.format('  %d. %s', i, display_name))
                        end
                    else
                        windower.add_to_chat(COUNTER_COLOR, '  No key items tracked.')
                    end
                else
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Unknown key command. Use "clear" or "list".')
                end
            else
                -- Show key list
                windower.add_to_chat(COUNTER_COLOR, 'Counter: Key Items:')
                local sorted = {}
                for item_name, _ in pairs(key_items) do
                    table.insert(sorted, item_name)
                end
                sorted = sort_items_alphabetically(sorted)
                if #sorted > 0 then
                    for i, item_name in ipairs(sorted) do
                        local display_name = item_name:gsub("^Key Item:%s*", "")
                        windower.add_to_chat(COUNTER_COLOR, string.format('  %d. %s', i, display_name))
                    end
                else
                    windower.add_to_chat(COUNTER_COLOR, '  No key items tracked.')
                end
            end
        elseif command == 'drop' then
            local subcmd = args[1]
            if subcmd then
                subcmd = subcmd:lower()
                if subcmd == 'reset' then
                    for item in pairs(tracked_items) do
                        item_counts[item] = 0
                        item_drop_times[item] = nil
                        recent_increments[item] = nil
                    end
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: All dropped item counts reset to 0.')
                    save_settings()
                    update_display()
                elseif subcmd == 'clear' then
                    -- First clear the counts and timers
                    for item in pairs(tracked_items) do
                        item_counts[item] = nil
                        item_drop_times[item] = nil
                        recent_increments[item] = nil
                    end
                    -- Then clear the tracked items
                    tracked_items = {}
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Dropped items list cleared.')
                    save_settings()
                    update_display()
                elseif subcmd == 'list' then
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Item Drops:')
                    local sorted = {}
                    for item_name, _ in pairs(tracked_items) do
                        table.insert(sorted, item_name)
                    end
                    sorted = sort_items_alphabetically(sorted)
                    if #sorted > 0 then
                        for i, item_name in ipairs(sorted) do
                            local count = item_counts[item_name] or 0
                            local inv_count = get_inventory_count(item_name)
                            windower.add_to_chat(COUNTER_COLOR, string.format('  %d. %s: %d (Inventory: %d)', i, item_name, count, inv_count))
                        end
                    else
                        windower.add_to_chat(COUNTER_COLOR, '  No items tracked.')
                    end
                else
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Unknown drop command. Use "reset", "clear", or "list".')
                end
            else
                -- Show drop list
                windower.add_to_chat(COUNTER_COLOR, 'Counter: Item Drops:')
                local sorted = {}
                for item_name, _ in pairs(tracked_items) do
                    table.insert(sorted, item_name)
                end
                sorted = sort_items_alphabetically(sorted)
                if #sorted > 0 then
                    for i, item_name in ipairs(sorted) do
                        local count = item_counts[item_name] or 0
                        local inv_count = get_inventory_count(item_name)
                        windower.add_to_chat(COUNTER_COLOR, string.format('  %d. %s: %d (Inventory: %d)', i, item_name, count, inv_count))
                    end
                else
                    windower.add_to_chat(COUNTER_COLOR, '  No items tracked.')
                end
            end
        elseif command == 'personal' or command == 'obtain' then  -- Support both commands
            local subcmd = args[1]
            if subcmd then
                subcmd = subcmd:lower()
                if subcmd == 'reset' then
                    for item in pairs(personal_items) do
                        personal_counts[item] = 0
                        personal_drop_times[item] = nil
                        recent_increments[item] = nil
                    end
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: All personal drop counts reset to 0.')
                    save_settings()
                    update_display()
                elseif subcmd == 'clear' then
                    -- Clear increments for the items being removed BEFORE
                    -- wiping personal_items, otherwise this check is always
                    -- false and recent_increments never gets cleaned up.
                    for item, _ in pairs(personal_items) do
                        recent_increments[item] = nil
                    end
                    personal_items = {}
                    personal_counts = {}
                    personal_drop_times = {}
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Personal drops list cleared.')
                    save_settings()
                    update_display()
                elseif subcmd == 'list' then
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Personal Drops:')
                    local sorted = {}
                    for item_name, _ in pairs(personal_items) do
                        table.insert(sorted, item_name)
                    end
                    sorted = sort_items_alphabetically(sorted)
                    if #sorted > 0 then
                        for i, item_name in ipairs(sorted) do
                            local count = personal_counts[item_name] or 0
                            local inv_count = get_inventory_count(item_name)
                            windower.add_to_chat(COUNTER_COLOR, string.format('  %d. %s: %d (Inventory: %d)', i, item_name, count, inv_count))
                        end
                    else
                        windower.add_to_chat(COUNTER_COLOR, '  No personal drops.')
                    end
                else
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Unknown personal command. Use "reset", "clear", or "list".')
                end
            else
                -- Show personal list
                windower.add_to_chat(COUNTER_COLOR, 'Counter: Personal Drops:')
                local sorted = {}
                for item_name, _ in pairs(personal_items) do
                    table.insert(sorted, item_name)
                end
                sorted = sort_items_alphabetically(sorted)
                if #sorted > 0 then
                    for i, item_name in ipairs(sorted) do
                        local count = personal_counts[item_name] or 0
                        local inv_count = get_inventory_count(item_name)
                        windower.add_to_chat(COUNTER_COLOR, string.format('  %d. %s: %d (Inventory: %d)', i, item_name, count, inv_count))
                    end
                else
                    windower.add_to_chat(COUNTER_COLOR, '  No personal drops.')
                end
            end
        elseif command == 'add' then
            local full_arg = table.concat(args, ' ')
            if full_arg:find(',') then
                -- Batch add: "//counter add ItemA, ItemB, ItemC"
                for item_name in full_arg:gmatch('([^,]+)') do
                    item_name = item_name:gsub('^%s+', ''):gsub('%s+$', '')
                    if item_name ~= '' then
                        add_item(item_name)
                    end
                end
            else
                add_item(full_arg)
            end
        elseif command == 'remove' then
            local item_name = table.concat(args, ' ')
            remove_item(item_name)
        elseif command == 'list' then
            list_items()
        elseif command == 'clear' then
            -- Clear everything
            tracked_items = {}
            item_counts = {["Gil"] = 0}
            item_drop_times = {}
            personal_items = {}
            personal_counts = {}
            personal_drop_times = {}
            usable_items = {}
            usable_drop_times = {}
            -- Don't clear ammo_items as they're auto-detected from equipment
            key_items = {}
            key_drop_times = {}
            recent_increments = {}
            windower.add_to_chat(COUNTER_COLOR, 'Counter: All lists cleared.')
            save_settings()
            update_display()
        elseif command == 'reset' then
            -- Handle both old (reset all) and new (reset specific) functionality
            local item_name = table.concat(args, ' ')
            if item_name == '' then
                -- No item specified, reset all
                item_counts["Gil"] = 0
                item_drop_times["Gil"] = nil
                recent_increments["Gil"] = nil
                for item in pairs(tracked_items) do
                    item_counts[item] = 0
                    item_drop_times[item] = nil
                    recent_increments[item] = nil
                end
                for item in pairs(personal_items) do
                    personal_counts[item] = 0
                    personal_drop_times[item] = nil
                    recent_increments[item] = nil
                end
                windower.add_to_chat(COUNTER_COLOR, 'Counter: All counters reset to 0.')
            else
                -- Reset specific item
                reset_item(item_name)
            end
            save_settings()
            update_display()
        elseif command == 'resetitem' then
            -- Alternative command specifically for resetting single items
            local item_name = table.concat(args, ' ')
            reset_item(item_name)
        elseif command == 'addset' then
            local set_name = table.concat(args, ' ')
            save_set(set_name)
        elseif command == 'set' then
            local set_name = table.concat(args, ' ')
            load_set(set_name)
        elseif command == 'listsets' then
            list_sets()
        elseif command == 'deleteset' then
            local set_name = table.concat(args, ' ')
            delete_set(set_name)
        elseif command == 'quiet' then
            set_auto_add('quiet', not quiet_mode)
        elseif command == 'focus' then
            local item_name = table.concat(args, ' ')
            if item_name == '' then
                if focus_item_name then
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Currently focused on "' .. focus_item_name .. '". Use "//counter unfocus" to clear it.')
                else
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: No item is currently focused. Usage: //counter focus <item name>')
                end
            else
                build_name_mappings()
                item_name = normalize_item_name(item_name)
                local full_name = get_full_name(item_name)
                local category = nil
                if tracked_items[full_name] then category = 'drop'
                elseif personal_items[full_name] then category = 'personal'
                elseif usable_items[full_name] then category = 'usable'
                elseif key_items[full_name] then category = 'key'
                end
                if category then
                    focus_item_name = full_name
                    focus_item_category = category
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: "' .. full_name .. '" is now focused.')
                    save_settings()
                    update_display()
                else
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: "' .. full_name .. '" is not being tracked, so it can\'t be focused.')
                end
            end
        elseif command == 'unfocus' then
            focus_item_name = nil
            focus_item_category = nil
            windower.add_to_chat(COUNTER_COLOR, 'Counter: Focus cleared.')
            save_settings()
            update_display()
        elseif command == 'export' then
            local lines_out = {}
            table.insert(lines_out, 'Counter export for ' .. (player_name or 'unknown') .. ' - ' .. os.date('%Y-%m-%d %H:%M:%S'))
            table.insert(lines_out, string.rep('=', 50))
            table.insert(lines_out, '')
            table.insert(lines_out, 'Gil (lifetime): ' .. (item_counts["Gil"] or 0))
            table.insert(lines_out, '')

            local function dump_section(title, items, counts)
                local names = {}
                for item_name, _ in pairs(items) do
                    table.insert(names, item_name)
                end
                if #names == 0 then return end
                table.insert(lines_out, title .. ':')
                names = sort_items_alphabetically(names)
                for _, item_name in ipairs(names) do
                    local count = counts and (counts[item_name] or 0) or nil
                    local line = '  ' .. item_name
                    if count then
                        line = line .. ': ' .. count
                    end
                    table.insert(lines_out, line)
                end
                table.insert(lines_out, '')
            end

            dump_section('Item Drops', tracked_items, item_counts)
            dump_section('Personal Drops', personal_items, personal_counts)
            dump_section('Usable Items', usable_items, nil)
            dump_section('Key Items', key_items, nil)

            local export_file = files.new('data/export-' .. (player_name or 'shared') .. '.txt')
            export_file:write(table.concat(lines_out, '\n'))
            windower.add_to_chat(COUNTER_COLOR, 'Counter: Exported to Windower/addons/Counter/data/export-' .. (player_name or 'shared') .. '.txt')
        elseif command == 'debug' then
            debug_mode = not debug_mode
            debug_all = false
            windower.add_to_chat(COUNTER_COLOR, 'Counter: Debug mode ' .. (debug_mode and 'ON' or 'OFF'))
        elseif command == 'debugall' then
            debug_all = not debug_all
            debug_mode = false
            windower.add_to_chat(COUNTER_COLOR, 'Counter: Debug ALL mode ' .. (debug_all and 'ON - showing all messages' or 'OFF'))
        elseif command == 'testpersonal' or command == 'testobtain' then  -- Support both
            -- Test command to manually add a personal drop
            local item_name = table.concat(args, ' ')
            if item_name ~= '' then
                item_name = normalize_item_name(item_name)
                personal_items[item_name] = true
                personal_counts[item_name] = (personal_counts[item_name] or 0) + 1
                personal_drop_times[item_name] = os.time()
                track_increment(item_name, 1)
                windower.add_to_chat(COUNTER_COLOR, 'Counter: TEST - Added personal drop ' .. item_name .. '. Total: ' .. personal_counts[item_name])
                save_settings()
                update_display()
            end
        elseif command == 'testgil' then
            -- Test command to manually add gil
            local amount = tonumber(args[1])
            if amount then
                item_counts["Gil"] = (item_counts["Gil"] or 0) + amount
                item_drop_times["Gil"] = os.time()
                track_increment("Gil", amount)
                windower.add_to_chat(COUNTER_COLOR, 'Counter: TEST - Added ' .. amount .. ' gil. Total: ' .. item_counts["Gil"])
                save_settings()
                update_display()
            else
                windower.add_to_chat(COUNTER_COLOR, 'Counter: TEST - Please specify an amount: //cnt testgil 100')
            end
        elseif command == 'test' then
            -- Test increment for debugging
            local item_name = table.concat(args, ' ')
            if item_name ~= '' then
                -- Build mappings if needed
                build_name_mappings()
                
                item_name = normalize_item_name(item_name)
                
                -- Convert to full name if it's a short name
                local full_name = get_full_name(item_name)
                
                if tracked_items[full_name] then
                    item_counts[full_name] = (item_counts[full_name] or 0) + 1
                    item_drop_times[full_name] = os.time()  -- Mark as recently dropped for color
                    track_increment(full_name, 1)
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: TEST - Incremented ' .. full_name .. ' to ' .. item_counts[full_name])
                    save_settings()
                    update_display()
                else
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: TEST - Item "' .. full_name .. '" not tracked')
                end
            end
        elseif command == 'show' or command == 'hide' then
            windower.add_to_chat(COUNTER_COLOR,
                'Counter: no longer has its own on-screen display -- open the Counter tab '
                .. 'in the MogWatch viewer instead.')
        elseif command == 'help' then
            windower.add_to_chat(COUNTER_COLOR, '=== Counter Commands ===')
            windower.add_to_chat(COUNTER_COLOR, '  //counter add <item name> - Add item to tracking (auto-categorized)')
            windower.add_to_chat(COUNTER_COLOR, '  //counter add ItemA, ItemB, ItemC - Add multiple items at once')
            windower.add_to_chat(COUNTER_COLOR, '  //counter remove <item name> - Remove item from tracking')
            windower.add_to_chat(COUNTER_COLOR, '  //counter list - List all tracked items in chat')
            windower.add_to_chat(COUNTER_COLOR, '  //counter clear - Clear all lists')
            windower.add_to_chat(COUNTER_COLOR, '  //counter reset - Reset all counters to 0')
            windower.add_to_chat(COUNTER_COLOR, '  //counter reset <item name> - Reset specific item counter to 0')
            windower.add_to_chat(COUNTER_COLOR, '  //counter resetitem <item name> - Reset specific item counter to 0')
            windower.add_to_chat(COUNTER_COLOR, '  //counter auto - Show auto-add status for all categories')
            windower.add_to_chat(COUNTER_COLOR, '  //counter auto drop on/off - Toggle auto-add for drops')
            windower.add_to_chat(COUNTER_COLOR, '  //counter auto usable on/off - Toggle auto-add for usable items')
            windower.add_to_chat(COUNTER_COLOR, '  //counter auto gil on/off - Toggle auto-add for gil')
            windower.add_to_chat(COUNTER_COLOR, '  //counter auto personal on/off - Toggle auto-add for personal drops')
            windower.add_to_chat(COUNTER_COLOR, '  //counter auto all on/off - Toggle auto-add for all categories')
            windower.add_to_chat(COUNTER_COLOR, '  //counter gil - Show gil total')
            windower.add_to_chat(COUNTER_COLOR, '  //counter gil reset/clear - Reset/clear gil')
            windower.add_to_chat(COUNTER_COLOR, '  //counter use - Show usable items')
            windower.add_to_chat(COUNTER_COLOR, '  //counter use clear/list - Manage usable items')
            windower.add_to_chat(COUNTER_COLOR, '  //counter ammo - Show equipped ammo')
            windower.add_to_chat(COUNTER_COLOR, '  //counter drop - Show dropped items')
            windower.add_to_chat(COUNTER_COLOR, '  //counter drop reset/clear/list - Manage dropped items')
            windower.add_to_chat(COUNTER_COLOR, '  //counter personal - Show personal drops')
            windower.add_to_chat(COUNTER_COLOR, '  //counter personal reset/clear/list - Manage personal drops')
            windower.add_to_chat(COUNTER_COLOR, '  //counter key - Show key items')
            windower.add_to_chat(COUNTER_COLOR, '  //counter key clear/list - Manage key items')
            windower.add_to_chat(COUNTER_COLOR, '  //counter addset <name> - Save current drops/personal/usable as a set')
            windower.add_to_chat(COUNTER_COLOR, '  //counter set <name> - Load a set (replaces drops, merges personal/usable)')
            windower.add_to_chat(COUNTER_COLOR, '  //counter listsets - List all saved sets')
            windower.add_to_chat(COUNTER_COLOR, '  //counter deleteset <name> - Delete a saved set')
            windower.add_to_chat(COUNTER_COLOR, '  //counter quiet - Toggle quiet mode (suppresses automatic drop chat spam)')
            windower.add_to_chat(COUNTER_COLOR, '  //counter focus <item name> - Pin an item at the top of the display')
            windower.add_to_chat(COUNTER_COLOR, '  //counter unfocus - Clear the focused item')
            windower.add_to_chat(COUNTER_COLOR, '  //counter export - Write a summary to a text file in the addon\'s data folder')
            windower.add_to_chat(COUNTER_COLOR, '  //counter debug - Toggle debug mode for obtain messages')
            windower.add_to_chat(COUNTER_COLOR, '  //counter debugall - Show ALL chat messages (warning: spammy!)')
            windower.add_to_chat(COUNTER_COLOR, '  //counter test <item name> - Manually increment counter')
            windower.add_to_chat(COUNTER_COLOR, '  //counter testpersonal <item name> - Test personal drop')
            windower.add_to_chat(COUNTER_COLOR, '  //counter testgil <amount> - Test gil addition')
            windower.add_to_chat(COUNTER_COLOR, '  //counter show - Show the display window')
            windower.add_to_chat(COUNTER_COLOR, '  //counter hide - Hide the display window')
            windower.add_to_chat(COUNTER_COLOR, '  //counter help - Show this help message')
            windower.add_to_chat(COUNTER_COLOR, '  Note: You can also use //cnt instead of //counter')
            windower.add_to_chat(COUNTER_COLOR, '  Note: Usable items appear in magenta, ammo in yellow, key items in blue')
            windower.add_to_chat(COUNTER_COLOR, '  Note: Items are sorted alphabetically within each category')
            windower.add_to_chat(COUNTER_COLOR, '  Note: Ammo is automatically tracked when equipped')
            windower.add_to_chat(COUNTER_COLOR, '  Note: Steal and Mug actions are automatically tracked')
            windower.add_to_chat(COUNTER_COLOR, '  Note: Click any toggle row to flip it, or click an item for a menu of actions')
            windower.add_to_chat(COUNTER_COLOR, '  Note: Right-click an item to remove it instantly, skipping the menu')
        else
            windower.add_to_chat(COUNTER_COLOR, 'Counter: Unknown command "' .. command .. '". Use //counter help for commands.')
        end
    else
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Use //counter help for commands.')
    end
end

windower.register_event('addon command', function(...)
    local args = {...}
    local sub = args[1] and args[1]:lower() or nil

    if sub == 'port' then
        local new_port = tonumber(args[2])
        if new_port and new_port >= 1 and new_port <= 65535 and new_port == math.floor(new_port) then
            apply_bridge_target(nil, new_port)
            print(('MogWatch addon: bridge port set to %d.'):format(port))
        else
            print('MogWatch addon: invalid port. Usage: //mogwatch port <1-65535>')
        end
        return
    end

    if sub == 'host' then
        local new_host = args[2]
        if type(new_host) == 'string' and #new_host > 0 then
            apply_bridge_target(new_host, nil)
            print(('MogWatch addon: bridge host set to %s.'):format(host))
        else
            print('MogWatch addon: invalid host. Usage: //mogwatch host <address>')
        end
        return
    end

    if sub == 'pair' then
        local code = table.concat(args, '', 2)
        local ok, err = bridge.set_pairing_code(code)
        if ok then
            bridge.last_reject_reason = nil
            save_bridge_settings()
            close_connection()
            was_connected = false
            print('MogWatch addon: pairing code accepted.')
        else
            print(('MogWatch addon: %s. Usage: //mogwatch pair <code from the app>'):format(err))
        end
        return
    end

    if sub == 'unpair' then
        bridge.set_pairing_code(nil)
        save_bridge_settings()
        close_connection()
        was_connected = false
        print('MogWatch addon: pairing cleared.')
        return
    end

    if sub == 'chatdebug' then
        chat_debug_enabled = not chat_debug_enabled
        print(('MogWatch addon: chat debug %s. %s'):format(
            chat_debug_enabled and 'ON' or 'OFF',
            chat_debug_enabled and 'Trigger the problem message (e.g. let a '
                .. 'buff wear off, or synthesize an item) and check the '
                .. 'console for a hex dump.' or ''))
        return
    end

    if sub == 'buffdebug' then
        buff_debug_enabled = not buff_debug_enabled
        print(('MogWatch addon: buff timer debug %s.'):format(
            buff_debug_enabled and 'ON' or 'OFF'))
        return
    end

    if sub == 'chatmode' then
        local mode_num = tonumber(args[2])
        local action = args[3] and args[3]:lower()
        if not mode_num or (action ~= 'on' and action ~= 'off') then
            print('MogWatch addon: usage: //mogwatch chatmode <number> on|off')
            print('  The chat relay only shows modes explicitly turned "on" '
                .. 'here -- everything else stays muted, labeled or not. '
                .. 'Use //mogwatch chatname to give a mode a readable label.')
            local shown = {}
            for m, v in pairs(settings.chat_channel_modes or {}) do
                if v then
                    table.insert(shown, m)
                end
            end
            table.sort(shown)
            print('MogWatch addon: currently shown modes: '
                .. (#shown > 0 and table.concat(shown, ', ') or '(none)'))
            return
        end
        settings.chat_channel_modes = settings.chat_channel_modes or {}
        if action == 'on' then
            settings.chat_channel_modes[mode_num] = true
            print(('MogWatch addon: mode %d will show in chat relay.'):format(mode_num))
        else
            settings.chat_channel_modes[mode_num] = nil
            print(('MogWatch addon: mode %d hidden from chat relay.'):format(mode_num))
        end
        if config then
            pcall(function() settings:save() end)
        end
        return
    end

    if sub == 'chatname' then
        local mode_num = tonumber(args[2])
        if not mode_num then
            print('MogWatch addon: usage: //mogwatch chatname <number> <label>')
            print('  //mogwatch chatname <number> clear   -- remove a label')
            print('  Example: //mogwatch chatname 211 Linkshell')
            settings.chat_mode_names = settings.chat_mode_names or {}
            local any = false
            for m, label in pairs(settings.chat_mode_names) do
                print(('  mode %d -> %s'):format(m, label))
                any = true
            end
            if not any then
                print('  (no labels set yet)')
            end
            return
        end
        settings.chat_mode_names = settings.chat_mode_names or {}
        local label = table.concat(args, ' ', 3)
        if label == '' or label:lower() == 'clear' then
            settings.chat_mode_names[mode_num] = nil
            print(('MogWatch addon: cleared label for mode %d.'):format(mode_num))
        else
            settings.chat_mode_names[mode_num] = label
            print(('MogWatch addon: mode %d will now show as "%s".'):format(mode_num, label))
        end
        if config then
            pcall(function() settings:save() end)
        end
        return
    end

    if sub == 'commandtest' then
        print('MogWatch addon: forcing a fresh command-channel connection attempt...')
        if client then
            print('MogWatch addon: command channel already connected.')
            return
        end
        last_command_connect_attempt = 0
        last_connect_diag = nil
        local connected = connect_client()
        if connected then
            print('MogWatch addon: command channel connected successfully.')
        else
            print('MogWatch addon: command channel still not connected -- see the '
                .. '"command channel:" diagnostic line above (or check the viewer '
                .. 'is actually running and its status bar shows no error).')
        end
        return
    end

    if sub == 'commanddebug' then
        command_debug_enabled = not command_debug_enabled
        print(('MogWatch addon: command channel debug %s.'):format(
            command_debug_enabled and 'ON' or 'OFF'))
        return
    end

    if sub == 'buffinfo' then
        local buff_id = tonumber(args[2])
        if not buff_id then
            print('MogWatch addon: usage: //mogwatch buffinfo <id>  (e.g. //mogwatch buffinfo 2 for Poison)')
            return
        end
        if not res then
            print('MogWatch addon: resources library not available.')
            return
        end
        local buff = res.buffs[buff_id]
        if not buff then
            print(('MogWatch addon: no res.buffs entry for id %d.'):format(buff_id))
            return
        end
        -- pairs() doesn't work here -- Windower's resource tables are
        -- metatable-backed (confirmed: an earlier attempt at dumping via
        -- pairs() produced zero output despite the table being non-nil),
        -- so this checks specific candidate field names directly instead,
        -- which works correctly through a metatable's __index.
        print(('MogWatch BUFFINFO: res.buffs[%d] (%s) -- candidate fields:')
            :format(buff_id, tostring(buff.name or buff.english or '?')))
        local candidates = {
            'name', 'english', 'enl', 'ens', 'type', 'negative', 'harmful',
            'debuff', 'category', 'flag', 'flags', 'kind', 'group',
            'beneficial', 'positive', 'sub_type', 'status_type',
        }
        for _, field in ipairs(candidates) do
            local ok, value = pcall(function() return buff[field] end)
            if ok and value ~= nil then
                print(('  %s = %s (%s)'):format(field, tostring(value), type(value)))
            end
        end
        return
    end

    if sub == nil then
        local state
        if bridge.secure_required(host) then
            state = bridge.is_authenticated() and 'paired and encrypted'
                or (bridge.secret and 'waiting to pair' or 'NOT PAIRED')
        else
            state = 'same device, unencrypted'
        end
        print(('MogWatch addon: bridge target is %s:%d (%s).'):format(host, port, state))
        print('MogWatch addon: usage: //mogwatch host <address> | port <number> | pair <code> | unpair')
        return
    end

    -- Not one of MogWatch's own subcommands -- try Counter's command set
    -- instead (this is what makes //counter and //cnt work: since this is
    -- now one merged addon, ALL registered prefixes route here with the
    -- same argument structure, so whichever set actually recognizes the
    -- first word handles it). Counter's own handler has its own complete
    -- "unknown command" fallback if neither set matches.
    handle_counter_command(...)
end)

-- FFXI system messages wrap highlighted words (item/buff/player names) in
-- an inline color-markup sequence: an introducer byte, then one parameter
-- byte (which color), repeated to end the highlight. Confirmed directly
-- from real captured messages (not guessed): 0x1E for the buff wear-off
-- case ("[\30\247Khalisar\30\1]" -> "[Khalisar]"), and separately 0x7F for
-- a player-name tag case ("[1]\60\127\252Claiomh\127\251\62" ->
-- "[1]<Claiomh>"). Both strip cleanly as introducer + 1 parameter byte.
local function strip_color_markup(text)
    return (text:gsub('[\30\127].', ''))
end

-- Windower normally converts all chat text from Shift-JIS to UTF-8 before
-- these events fire, but that confirmed 0x7F case also showed a run of
-- completely unconverted Shift-JIS slipping through raw (each "0x82 xx"
-- pair is one Japanese character in the Shift-JIS encoding). A naive
-- "does this look like valid UTF-8" check isn't good enough here: it can
-- get fooled when two unrelated Shift-JIS bytes happen to land in a
-- pattern that coincidentally passes as a valid UTF-8 sequence (verified
-- this actually happened -- 0x82 0xC9 0x82 decoded as "invalid, invalid,
-- looks-valid" and kept two garbage bytes). Instead, this actively
-- recognizes real Shift-JIS lead/trail byte pairs and converts them
-- properly with Windower's own windower.from_shift_jis(), rather than
-- just pattern-matching and hoping.
local function is_sjis_lead(b)
    return (b >= 0x81 and b <= 0x9F) or (b >= 0xE0 and b <= 0xFC)
end

local function is_sjis_trail(b)
    return (b >= 0x40 and b <= 0x7E) or (b >= 0x80 and b <= 0xFC)
end

local function sanitize_ffxi_text(text)
    local out = {}
    local i = 1
    local n = #text
    while i <= n do
        local b1 = text:byte(i)

        if b1 < 0x80 then
            table.insert(out, text:sub(i, i))
            i = i + 1
        else
            -- Try a real UTF-8 multi-byte sequence first (text Windower
            -- already converted correctly shouldn't be re-interpreted).
            local seq_len = nil
            if b1 >= 0xC2 and b1 <= 0xDF then
                seq_len = 2
            elseif b1 >= 0xE0 and b1 <= 0xEF then
                seq_len = 3
            elseif b1 >= 0xF0 and b1 <= 0xF4 then
                seq_len = 4
            end
            local utf8_valid = false
            if seq_len and (i + seq_len - 1) <= n then
                utf8_valid = true
                for j = 1, seq_len - 1 do
                    local cb = text:byte(i + j)
                    if not cb or cb < 0x80 or cb > 0xBF then
                        utf8_valid = false
                        break
                    end
                end
            end

            if utf8_valid then
                table.insert(out, text:sub(i, i + seq_len - 1))
                i = i + seq_len
            elseif is_sjis_lead(b1) and i + 1 <= n and is_sjis_trail(text:byte(i + 1)) then
                -- A real Shift-JIS character pair -- decode it properly
                -- instead of guessing.
                local ok, converted = pcall(windower.from_shift_jis, text:sub(i, i + 1))
                if ok and converted and #converted > 0 then
                    table.insert(out, converted)
                end
                i = i + 2
            else
                -- Neither valid UTF-8 nor a recognizable Shift-JIS pair --
                -- there's no correct text to recover, so drop just this
                -- one byte rather than leave it in as noise.
                i = i + 1
            end
        end
    end
    return table.concat(out)
end

local function push_chat_line(mode, text, outgoing)
    if not text or text == '' then
        return
    end
    local label = not outgoing and settings.chat_mode_names and settings.chat_mode_names[mode] or nil
    if not outgoing and mode then
        -- Allow-list: only modes explicitly marked true in
        -- chat_channel_modes show up. A label alone (chat_mode_names)
        -- isn't enough -- that's just display text for modes that ARE
        -- shown, kept around for modes that aren't (System, NPC, Message)
        -- in case you want to opt one back in later.
        local allowed = settings.chat_channel_modes and settings.chat_channel_modes[mode]
        if not allowed then
            if chat_debug_enabled then
                print(('MogWatch CHATDEBUG: filtered out mode %d (%s)'):format(
                    mode, label and 'labeled but not in chat_channel_modes' or 'not identified'))
            end
            return
        end
    end
    if chat_debug_enabled then
        local hex_before = text:gsub('.', function(c) return ('%02X '):format(c:byte()) end)
        print('MogWatch CHATDEBUG raw bytes (before conversion): ' .. hex_before)
    end
    -- Auto-translate phrases (the ones players insert via Tab in the chat
    -- box) are encoded as special formatting that has no meaning to any
    -- normal font -- this converts them to plain readable text instead of
    -- showing up as garbage symbols downstream.
    local ok, converted = pcall(windower.convert_auto_trans, text)
    if ok and converted then
        text = converted
    end
    text = strip_color_markup(text)
    text = sanitize_ffxi_text(text)
    if chat_debug_enabled then
        local hex_after = text:gsub('.', function(c) return ('%02X '):format(c:byte()) end)
        print('MogWatch CHATDEBUG raw bytes (after conversion):  ' .. hex_after)
        print('MogWatch CHATDEBUG text: ' .. text)
    end
    table.insert(chat_buffer, { mode = mode, text = text, outgoing = outgoing or false, label = label })
    while #chat_buffer > chat_buffer_max do
        table.remove(chat_buffer, 1)
    end
end

-- Windower already converts chat text from Shift-JIS to UTF-8 before these
-- fire, so no extra encoding handling is needed here.
windower.register_event('incoming text', function(original, modified, original_mode, modified_mode, block)
    if block then
        return
    end
    push_chat_line(modified_mode or original_mode, modified or original, false)
end)

-- Outgoing text isn't captured: the server echoes your own message back
-- through the normal incoming channel anyway (e.g. typing /s hey shows up
-- as "Say: Khalisar : hey"), so relaying it a second time on the way out
-- was just showing the same thing twice as a redundant "You: ..." line.

-- Counter's original top-level load-time statements (get player name,
-- load saved settings, report what was restored, check equipped ammo),
-- unchanged from the original addon.

-- Try to get player name on load (before loading settings, so we pick the
-- right per-character file immediately if the character is already known)
get_player_name()
if player_name then
    windower.add_to_chat(COUNTER_COLOR, 'Counter: Tracking drops for ' .. player_name)
end

-- Load settings on startup
if load_settings() then
    local count = 0
    for _ in pairs(tracked_items) do
        count = count + 1
    end
    if count > 0 then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Loaded ' .. count .. ' tracked items from previous session.')
    end
    
    local usable_count = 0
    for _ in pairs(usable_items) do
        usable_count = usable_count + 1
    end
    if usable_count > 0 then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Loaded ' .. usable_count .. ' usable items from previous session.')
    end
    
    local personal_count = 0
    for _ in pairs(personal_items) do
        personal_count = personal_count + 1
    end
    if personal_count > 0 then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Loaded ' .. personal_count .. ' personal drops from previous session.')
    end
    
    local key_count = 0
    for _ in pairs(key_items) do
        key_count = key_count + 1
    end
    if key_count > 0 then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Loaded ' .. key_count .. ' key items from previous session.')
    end
    
    local gil = item_counts["Gil"] or 0
    if gil > 0 then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Loaded gil total: ' .. gil)
    end
    
    -- Show auto-add status with colors
    windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add status:')
    local drop_color = auto_add_drop and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    local usable_color = auto_add_usable and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    local personal_color = auto_add_personal and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    local gil_color = auto_add_gil and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    windower.add_to_chat(COUNTER_COLOR, '  Drops: ' .. drop_color .. (auto_add_drop and 'ON' or 'OFF') .. '\\cr')
    windower.add_to_chat(COUNTER_COLOR, '  Usable: ' .. usable_color .. (auto_add_usable and 'ON' or 'OFF') .. '\\cr')
    windower.add_to_chat(COUNTER_COLOR, '  Personal: ' .. personal_color .. (auto_add_personal and 'ON' or 'OFF') .. '\\cr')
    windower.add_to_chat(COUNTER_COLOR, '  Gil: ' .. gil_color .. (auto_add_gil and 'ON' or 'OFF') .. '\\cr')
end

-- Session baselines for every item that existed BEFORE this session
-- started (i.e. loaded from the settings file above) need to be snapshot
-- right here, once, before any new-this-session change can occur. Without
-- this, an item's baseline would only ever get established the first time
-- build_counter_status() happens to look at it -- but a genuinely NEW
-- item only ever appears in tracked_items at the same moment its count
-- becomes 1, so that lazy approach could never tell "existed already"
-- apart from "just got its first drop", making the first drop of any new
-- item invisible to the session counter (confirmed: this is exactly what
-- was observed -- brand new items showed session count 0 instead of 1).
-- Snapshots live inventory counts specifically (not the item_counts/
-- personal_counts event tallies) -- confirmed against the real original
-- source that the bracketed "total" was always meant to be live
-- inventory, not a cumulative drop-detection tally.
for item_name in pairs(tracked_items) do
    session_baselines.drop[item_name] = get_inventory_count(item_name)
end
for item_name in pairs(personal_items) do
    session_baselines.personal[item_name] = get_inventory_count(item_name)
end

-- Check for equipped ammo on load
check_equipped_ammo()

-- Initialize display
update_display()

windower.add_to_chat(COUNTER_COLOR, 'Counter v1.1.1 loaded successfully! Use //counter help for commands.')windower.register_event('load', function()
    if not socket then
        print(('MogWatch addon: socket transport unavailable (%s).'):format(socket_source or 'unknown error'))
        return
    end
    if not socket.udp then
        print(('MogWatch addon: UDP status transport unavailable (%s).'):format(socket_source or 'unknown error'))
    else
        print(('MogWatch addon: sending binary UDP status to %s:%d using %s.'):format(host, port, socket_source or 'socket'))
    end
    if not res then
        print('MogWatch addon: the Windower "resources" library did not load; '
            .. 'job/buff/zone names will be blank.')
    end
    last_send = os.clock()
end)

windower.register_event('unload', function()
    was_connected = false
    close_connection()
    close_status_client()
end)

windower.register_event('prerender', function()
    local now = os.clock()
    bridge.guard_tick('receive', receive_commands)
    if (now - last_send) >= send_interval then
        bridge.guard_tick('send', send_status)
        last_send = now
    end
end)
