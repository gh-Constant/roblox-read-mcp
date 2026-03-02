local Crypto = {}

local MOD32 = 2 ^ 32

local bxor = bit32.bxor
local band = bit32.band
local bor = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift
local rrotate = bit32.rrotate

local K = {
	0x428A2F98,
	0x71374491,
	0xB5C0FBCF,
	0xE9B5DBA5,
	0x3956C25B,
	0x59F111F1,
	0x923F82A4,
	0xAB1C5ED5,
	0xD807AA98,
	0x12835B01,
	0x243185BE,
	0x550C7DC3,
	0x72BE5D74,
	0x80DEB1FE,
	0x9BDC06A7,
	0xC19BF174,
	0xE49B69C1,
	0xEFBE4786,
	0x0FC19DC6,
	0x240CA1CC,
	0x2DE92C6F,
	0x4A7484AA,
	0x5CB0A9DC,
	0x76F988DA,
	0x983E5152,
	0xA831C66D,
	0xB00327C8,
	0xBF597FC7,
	0xC6E00BF3,
	0xD5A79147,
	0x06CA6351,
	0x14292967,
	0x27B70A85,
	0x2E1B2138,
	0x4D2C6DFC,
	0x53380D13,
	0x650A7354,
	0x766A0ABB,
	0x81C2C92E,
	0x92722C85,
	0xA2BFE8A1,
	0xA81A664B,
	0xC24B8B70,
	0xC76C51A3,
	0xD192E819,
	0xD6990624,
	0xF40E3585,
	0x106AA070,
	0x19A4C116,
	0x1E376C08,
	0x2748774C,
	0x34B0BCB5,
	0x391C0CB3,
	0x4ED8AA4A,
	0x5B9CCA4F,
	0x682E6FF3,
	0x748F82EE,
	0x78A5636F,
	0x84C87814,
	0x8CC70208,
	0x90BEFFFA,
	0xA4506CEB,
	0xBEF9A3F7,
	0xC67178F2,
}

local function add32(...)
	local sum = 0
	for _, value in ipairs({ ... }) do
		sum = (sum + value) % MOD32
	end
	return sum
end

local function toBytes(input: string): { number }
	local bytes = table.create(#input)
	for index = 1, #input do
		bytes[index] = string.byte(input, index)
	end
	return bytes
end

local function bytesToString(bytes: { number }): string
	local chars = table.create(#bytes)
	for index, byte in ipairs(bytes) do
		chars[index] = string.char(byte)
	end
	return table.concat(chars)
end

local function bytesToHex(bytes: { number }): string
	local out = table.create(#bytes)
	for index, byte in ipairs(bytes) do
		out[index] = string.format("%02x", byte)
	end
	return table.concat(out)
end

local function appendLength(bytes: { number }, bitLengthHigh: number, bitLengthLow: number)
	for shiftBits = 24, 0, -8 do
		table.insert(bytes, band(rshift(bitLengthHigh, shiftBits), 0xFF))
	end
	for shiftBits = 24, 0, -8 do
		table.insert(bytes, band(rshift(bitLengthLow, shiftBits), 0xFF))
	end
end

local function sigma0(x: number): number
	return bxor(rrotate(x, 7), rrotate(x, 18), rshift(x, 3))
end

local function sigma1(x: number): number
	return bxor(rrotate(x, 17), rrotate(x, 19), rshift(x, 10))
end

local function Sigma0(x: number): number
	return bxor(rrotate(x, 2), rrotate(x, 13), rrotate(x, 22))
end

local function Sigma1(x: number): number
	return bxor(rrotate(x, 6), rrotate(x, 11), rrotate(x, 25))
end

local function choice(x: number, y: number, z: number): number
	return bxor(band(x, y), band(bit32.bnot(x), z))
end

local function majority(x: number, y: number, z: number): number
	return bxor(band(x, y), band(x, z), band(y, z))
end

local function sha256Binary(input: string): string
	local h0 = 0x6A09E667
	local h1 = 0xBB67AE85
	local h2 = 0x3C6EF372
	local h3 = 0xA54FF53A
	local h4 = 0x510E527F
	local h5 = 0x9B05688C
	local h6 = 0x1F83D9AB
	local h7 = 0x5BE0CD19

	local bytes = toBytes(input)
	local inputBits = #bytes * 8
	local bitLengthHigh = math.floor(inputBits / MOD32)
	local bitLengthLow = inputBits % MOD32

	table.insert(bytes, 0x80)
	while (#bytes % 64) ~= 56 do
		table.insert(bytes, 0)
	end

	appendLength(bytes, bitLengthHigh, bitLengthLow)

	local w = table.create(64, 0)
	for chunkStart = 1, #bytes, 64 do
		for i = 1, 16 do
			local byteIndex = chunkStart + ((i - 1) * 4)
			w[i] = bor(
				lshift(bytes[byteIndex], 24),
				lshift(bytes[byteIndex + 1], 16),
				lshift(bytes[byteIndex + 2], 8),
				bytes[byteIndex + 3]
			)
		end

		for i = 17, 64 do
			w[i] = add32(sigma1(w[i - 2]), w[i - 7], sigma0(w[i - 15]), w[i - 16])
		end

		local a = h0
		local b = h1
		local c = h2
		local d = h3
		local e = h4
		local f = h5
		local g = h6
		local h = h7

		for i = 1, 64 do
			local t1 = add32(h, Sigma1(e), choice(e, f, g), K[i], w[i])
			local t2 = add32(Sigma0(a), majority(a, b, c))
			h = g
			g = f
			f = e
			e = add32(d, t1)
			d = c
			c = b
			b = a
			a = add32(t1, t2)
		end

		h0 = add32(h0, a)
		h1 = add32(h1, b)
		h2 = add32(h2, c)
		h3 = add32(h3, d)
		h4 = add32(h4, e)
		h5 = add32(h5, f)
		h6 = add32(h6, g)
		h7 = add32(h7, h)
	end

	local digestBytes = {
		band(rshift(h0, 24), 0xFF),
		band(rshift(h0, 16), 0xFF),
		band(rshift(h0, 8), 0xFF),
		band(h0, 0xFF),
		band(rshift(h1, 24), 0xFF),
		band(rshift(h1, 16), 0xFF),
		band(rshift(h1, 8), 0xFF),
		band(h1, 0xFF),
		band(rshift(h2, 24), 0xFF),
		band(rshift(h2, 16), 0xFF),
		band(rshift(h2, 8), 0xFF),
		band(h2, 0xFF),
		band(rshift(h3, 24), 0xFF),
		band(rshift(h3, 16), 0xFF),
		band(rshift(h3, 8), 0xFF),
		band(h3, 0xFF),
		band(rshift(h4, 24), 0xFF),
		band(rshift(h4, 16), 0xFF),
		band(rshift(h4, 8), 0xFF),
		band(h4, 0xFF),
		band(rshift(h5, 24), 0xFF),
		band(rshift(h5, 16), 0xFF),
		band(rshift(h5, 8), 0xFF),
		band(h5, 0xFF),
		band(rshift(h6, 24), 0xFF),
		band(rshift(h6, 16), 0xFF),
		band(rshift(h6, 8), 0xFF),
		band(h6, 0xFF),
		band(rshift(h7, 24), 0xFF),
		band(rshift(h7, 16), 0xFF),
		band(rshift(h7, 8), 0xFF),
		band(h7, 0xFF),
	}

	return bytesToString(digestBytes)
end

function Crypto.sha256Hex(input: string): string
	return bytesToHex(toBytes(sha256Binary(input)))
end

function Crypto.hmacSha256Hex(key: string, message: string): string
	local blockSize = 64
	local normalizedKey = key

	if #normalizedKey > blockSize then
		normalizedKey = sha256Binary(normalizedKey)
	end

	if #normalizedKey < blockSize then
		normalizedKey = normalizedKey .. string.rep("\0", blockSize - #normalizedKey)
	end

	local keyBytes = toBytes(normalizedKey)
	local oPad = table.create(blockSize)
	local iPad = table.create(blockSize)

	for i = 1, blockSize do
		oPad[i] = string.char(bxor(keyBytes[i], 0x5C))
		iPad[i] = string.char(bxor(keyBytes[i], 0x36))
	end

	local inner = sha256Binary(table.concat(iPad) .. message)
	local digest = sha256Binary(table.concat(oPad) .. inner)

	return bytesToHex(toBytes(digest))
end

return Crypto
