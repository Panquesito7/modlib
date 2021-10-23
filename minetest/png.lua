local signature = "\137\80\78\71\13\10\26\10"

local assert, char, ipairs, insert, concat, abs, floor = assert, string.char, ipairs, table.insert, table.concat, math.abs, math.floor

-- TODO move to modlib.bit eventually
local bit_xor = bit.xor or function(a, b)
	local res = 0
	local bit = 1
	for _ = 1, 32 do
		if a % 2 ~= b % 2 then
			res = res + bit
		end
		a = floor(a / 2)
		b = floor(b / 2)
		bit = bit * 2
	end
	return res
end

local crc_table = {}
for i = 0, 255 do
	local c = i
	for _ = 0, 7 do
		if c % 2 > 0 then
			c = bit_xor(0xEDB88320, floor(c / 2))
		else
			c = floor(c / 2)
		end
	end
	crc_table[i] = c
end

local function update_crc(crc, text)
	for i = 1, #text do
		crc = bit_xor(crc_table[bit_xor(crc % 0x100, text:byte(i))], floor(crc / 0x100))
	end
	return crc
end


local color_types = {
	[0] = {
		color = "grayscale"
	},
	[2] = {
		color = "truecolor"
	},
	[3] = {
		color = "palette",
		depth = 8
	},
	[4] = {
		color = "grayscale",
		alpha = true
	},
	[6] = {
		color = "truecolor",
		alpha = true
	}
}
local set = modlib.table.set
local allowed_bit_depths = {
	[0] = set{1, 2, 4, 8, 16},
	[2] = set{8, 16},
	[3] = set{1, 2, 4, 8},
	[4] = set{8, 16},
	[6] = set{8, 16}
}
local samples = {
	grayscale = 1,
	palette = 1,
	truecolor = 3
}

(...).decode_png = function(stream)
	local chunk_crc
	local function read(n)
		local text = stream:read(n)
		assert(#text == n)
		if chunk_crc then
			chunk_crc = update_crc(chunk_crc, text)
		end
		return text
	end
	local function byte()
		return read(1):byte()
	end
	local function _uint()
		return 0x1000000 * byte() + 0x10000 * byte() + 0x100 * byte() + byte()
	end
	local function uint()
		local val = _uint()
		assert(val < 2^31, "uint out of range")
		return val
	end
	local function check_crc()
		local crc = chunk_crc
		chunk_crc = nil
		if _uint() ~= bit_xor(crc, 0xFFFFFFFF) then
			error("CRC mismatch", 2)
		end
	end

	assert(read(8) == signature, "PNG signature expected")

	local IHDR_len = uint()
	assert(IHDR_len == 13, "invalid IHDR length")
	chunk_crc = 0xFFFFFFFF
	assert(read(4) == "IHDR", "IHDR chunk expected")
	local width = uint()
	assert(width > 0)
	local height = uint()
	assert(height > 0)
	local bit_depth = byte()
	local color_type_number = byte()
	local color_type = assert(color_types[color_type_number], "invalid color type")
	if color_type.color ~= "palette" then
		color_type.depth = bit_depth
	end
	assert(allowed_bit_depths[color_type_number][bit_depth], "disallowed bit depth for color type")
	local compression_method = byte()
	assert(compression_method == 0, "unsupported compression method")
	local filter_method = byte()
	assert(filter_method == 0, "unsupported filter method")
	local interlace_method = byte()
	assert(interlace_method <= 1, "unsupported interlace method")
	local adam7 = interlace_method == 1
	assert(not adam7, "adam7 interlacing not supported yet")
	check_crc() -- IHDR CRC

	local palette
	local alpha
	local source_gamma
	local idat_content = {}
	local idat_allowed = true
	local iend
	repeat
		local chunk_length = uint()
		chunk_crc = 0xFFFFFFFF
		local chunk_type = read(4)
		if chunk_type == "IDAT" then
			assert(idat_allowed, "no chunks inbetween IDAT chunks allowed")
			if color_type.color == "palette" then
				assert(palette, "PLTE chunk expected")
			end
			insert(idat_content, read(chunk_length))
		else
			if next(idat_content) then
				-- Non-IDAT chunk, no IDAT chunks allowed anymore
				idat_allowed = false
			end
			if chunk_type == "PLTE" then
				assert(color_type.color ~= "grayscale")
				assert(not palette, "double PLTE chunk")
				assert(idat_allowed, "PLTE after IDAT chunks")
				palette = {}
				local entries = chunk_length / 3
				assert(entries % 1 == 0 and entries >= 1 and entries <= 2^bit_depth, "invalid PLTE chunk length")
				for i = 1, entries do
					palette[i] = 0x10000 * byte() + 0x100 * byte() + byte() -- RGB
				end
			elseif chunk_type == "tRNS" then
				assert(not color_type.alpha, "unexpected tRNS chunk")
				assert(idat_allowed, "tRNS after IDAT chunks")
				if color_type.color == "palette" then
					assert(palette, "PLTE chunk expected")
					alpha = {}
					for i = 1, chunk_length do
						alpha[i] = byte()
					end
				elseif color_type.color == "grayscale" then
					assert(chunk_length == 2)
					alpha = 0x100 * byte() + byte()
				else
					assert(color_type.color == "truecolor")
					assert(chunk_length == 6)
					alpha = ((((byte() * 0x100 + byte()) * 0x100 + byte()) * 0x100 + byte()) * 0x100 + byte()) * 0x100 + byte() -- 16-bit RGB
				end
			elseif chunk_type == "gAMA" then
				assert(not palette, "gAMA after PLTE chunk")
				assert(idat_allowed, "gAMA after IDAT chunks")
				assert(chunk_length == 4)
				source_gamma = uint() / 1e5
			elseif chunk_type == "IEND" then
				iend = true
			else
				-- Check whether the fifth bit of the first byte is set (upper vs. lowercase ASCII)
				local ancillary = floor(chunk_type:byte(1) % (2^6)) >= 2^5
				if not ancillary then
					error(("unsupported critical chunk: %q"):format(chunk_type))
				end
				read(chunk_length)
			end
		end
		check_crc()
	until iend
	assert(next(idat_content), "no IDAT chunk")
	idat_content = minetest.decompress(concat(idat_content), "deflate")
	--[[
		For memory efficiency, we try to pack everything in a single number:
		Grayscale/lightness: AY
		Palette: ARGB
		Truecolor (8-bit): ARGB
		Truecolor (16-bit): RGB + A
			(64 bits required, packing non-mantissa bits isn't practical) => separate table with alpha values
	]]
	local data = {}
	local alpha_data = {}
	local bits_per_pixel = (samples[color_type.color] + (color_type.alpha and 1 or 0)) * bit_depth
	local bytes_per_pixel = math.ceil(bits_per_pixel / 8)
	local scanline_bytecount = math.ceil(width * bits_per_pixel / 8)
	local previous_scanline
	for y = 0, height - 1 do
		local idat_base_index = y * (scanline_bytecount + 1) + 1
		local filtering = idat_content:byte(idat_base_index)
		local scanline = {}
		for i = 1, scanline_bytecount do
			local val = idat_content:byte(idat_base_index + i)
			local left = scanline[i - bytes_per_pixel] or 0
			local up = previous_scanline and previous_scanline[i] or 0
			local left_up = previous_scanline and previous_scanline[i - bytes_per_pixel] or 0
			-- Undo lossless filter
			if filtering == 0 then -- None
				scanline[i] = val
			elseif filtering == 1 then -- Sub
				scanline[i] = (left + val) % 0x100
			elseif filtering == 2 then -- Up
				scanline[i] = (up + val) % 0x100
			elseif filtering == 3 then -- Average
				scanline[i] = (floor((left + up) / 2) + val) % 0x100
			elseif filtering == 4 then -- Paeth
				local p = left + up - left_up
				local p_left = abs(p - left)
				local p_up = abs(p - up)
				local p_left_up = abs(p - left_up)
				local p_res
				if p_left <= p_up and p_left <= p_left_up then
					p_res = left
				elseif p_up <= p_left_up then
					p_res = up
				else
					p_res = left_up
				end
				scanline[i] = (p_res + val) % 0x100
			else
				error("invalid filtering method: " .. filtering)
			end
			assert(scanline[i] >= 0 and scanline[i] <= 255 and scanline[i] % 1 == 0)
		end
		local bit = 0
		local function sample()
			local byte_idx = 1 + floor(bit / 8)
			bit = bit + bit_depth
			local byte = scanline[byte_idx]
			if bit_depth == 16 then
				return byte * 0x100 + scanline[byte_idx + 1]
			end
			if bit_depth == 8 then
				return byte
			end
			assert(bit_depth == 1 or bit_depth == 2 or bit_depth == 4)
			local low = 2^(-bit % 8)
			return floor(byte / low) % (2^bit_depth)
		end
		for x = 0, width - 1 do
			local data_index = y * width + x + 1
			if color_type.color == "palette" then
				local palette_index = sample()
				local rgb = assert(palette[palette_index + 1], "palette index out of range")
				-- Index alpha table if available
				local a = alpha and alpha[palette_index + 1] or 255
				data[data_index] = a * 0x1000000 + rgb
			elseif color_type.color == "grayscale" then
				local Y = sample()
				local a = 2^bit_depth - 1
				if color_type.alpha then
					a = sample()
				elseif alpha == Y then
					a = 0 -- Convert grayscale to transparency
				end
				data[data_index] = a * (2^bit_depth) + Y
			else
				assert(color_type.color == "truecolor")
				local r, g, b = sample(), sample(), sample()
				local rgb16 = r * 0x100000000 + g * 0x10000 + b
				local a = 2^bit_depth - 1
				if color_type.alpha then
					a = sample()
				elseif alpha == rgb16 then
					a = 0 -- Convert color to transparency
				end
				if bit_depth == 8 then
					data[data_index] = a * 0x1000000 + r * 0x10000 + g * 0x100 + b
				else
					assert(bit_depth == 16)
					-- Pack only RGB in data, alpha goes in a different table
					-- 3 * 16 = 48 bytes can still be held accurately by the double mantissa
					data[data_index] = rgb16
					alpha_data[data_index] = a
				end
			end
		end
		-- Each byte of the scanline must have been read from
		assert(bit >= #scanline * 8 - 7)
		previous_scanline = scanline
	end
	return {
		width = width,
		height = height,
		color_type = color_type,
		source_gamma = source_gamma,
		data = data,
		alpha_data = next(alpha_data) and alpha_data
	}
end

local function rescale_depth(sample, source, target)
	if source == target then
		return sample
	end
	return floor((sample / (2^source - 1) * (2^target - 1)) + 0.5)
end
-- In-place lossy (if bit depth = 16) conversion to ARGB8
(...).convert_png_to_argb8 = function(png)
	local color, alpha, depth = png.color_type.color, png.color_type.alpha, png.color_type.depth
	if color == "palette" or (color == "truecolor" and depth == 8) then
		return
	end
	for index, value in pairs(png.data) do
		if color == "grayscale" then
			local a, Y = rescale_depth(floor(value / (2^depth)), depth, 8), rescale_depth(floor(value % (2^depth)), depth, 8)
			png.data[index] = a * 0x1000000 + Y * 0x10000 + Y * 0x100 + Y -- R = G = B = Y
		else
			assert(color == "truecolor" and depth == 16)
			local r = rescale_depth(floor(value / 0x100000000), depth, 8)
			local g = rescale_depth(floor(value / 0x10000) % 0x10000, depth, 8)
			local b = rescale_depth(value % 0x10000, depth, 8)
			local a = 0xFF
			if alpha then
				a = rescale_depth(png.alpha_data[index], depth, 8)
			end
			png.data[index] = a * 0x1000000 + r * 0x10000 + g * 0x100 + b
		end
	end
	png.alpha_data = nil
end

local function encode_png(width, height, data, compression, raw_write)
	local write = raw_write
	local function byte(value)
		write(char(value))
	end
	local function _uint(value)
		local div = 0x1000000
		for _ = 1, 4 do
			byte(floor(value / div) % 0x100)
			div = div / 0x100
		end
	end
	local function uint(value)
		assert(value < 2^31)
		_uint(value)
	end
	local chunk_content
	local function chunk_write(text)
		insert(chunk_content, text)
	end
	local function chunk(type)
		chunk_content = {}
		write = chunk_write
		write(type)
	end
	local function end_chunk()
		write = raw_write
		local chunk_len = 0
		for i = 2, #chunk_content do
			chunk_len = chunk_len + #chunk_content[i]
		end
		uint(chunk_len)
		write(concat(chunk_content))
		local chunk_crc = 0xFFFFFFFF
		for _, text in ipairs(chunk_content) do
			chunk_crc = update_crc(chunk_crc, text)
		end
		_uint(bit_xor(chunk_crc, 0xFFFFFFFF))
	end
	-- Signature
	write(signature)
	chunk"IHDR"
	uint(width)
	uint(height)
	-- Always use bit depth 8
	byte(8)
	-- Always use color type "truecolor with alpha"
	byte(6)
	-- Compression method: deflate
	byte(0)
	-- Filter method: PNG filters
	byte(0)
	-- No interlace
	byte(0)
	end_chunk()
	chunk"IDAT"
	local data_rope = {}
	for y = 0, height - 1 do
		local base_index = y * width
		insert(data_rope, "\0")
		for x = 1, width do
			local colorspec = modlib.minetest.colorspec.from_any(data[base_index + x])
			insert(data_rope, char(colorspec.r, colorspec.g, colorspec.b, colorspec.a))
		end
	end
	write(minetest.compress(type(data) == "string" and data or concat(data_rope), "deflate", compression))
	end_chunk()
	chunk"IEND"
	end_chunk()
end

(...).encode_png = minetest.encode_png or function(width, height, data, compression)
	local rope = {}
	encode_png(width, height, data, compression or 9, function(text)
		insert(rope, text)
	end)
	return concat(rope)
end