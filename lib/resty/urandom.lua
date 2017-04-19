local _M = {}

_M.version = "0.1"

local to_hex    = require("resty.string").to_hex
local semaphore = require("ngx.semaphore")

local timer_at = ngx.timer.at
local ngx_log  = ngx.log
local DEBUG    = ngx.DEBUG
local WARN     = ngx.WARN

local initted = false

-- buffer geometry
local chunk_size, num_chunks, max_size

-- buffer contents
local random_buf
local random_buf_count = 0

-- how often to refill the buffer
local rate

-- how much data to read from urandom
local read_size = 4096

-- ngx.semaphore instance
local sem

-- grab table.new if we can to avoid excessive table resize
local ok, new_tab = pcall(require, "table.new")
if not ok or type(new_tab) ~= "function" then
	 new_tab = function (narr, nrec) return {} end
end

-- attempt to grab a resource on the semaphore
-- because we only release one resource a time this is essentially a mutex
local function _acquire_lock()
	local ok, err = sem:wait(1)

	if not ok then
		return false
	end

	return true
end

-- release the lock
local function _release_lock()
	sem:post(1)
	return true
end


-- fill the random_buf
local function _fill_buf()
	-- if we're full, we don't need to do anything
	if random_buf_count == num_chunks then
		return true
	end

	if not _acquire_lock() then
		ngx_log(WARN, "Couldn't acquire lock!")
		return false
	end

	--[[
	there's probably some discussion to be had wrt
	opening this file handle as part of init() and
	storing it as a module member. testing tbd
	--]]
	local f = io.open("/dev/urandom", "rb")

	if not f then
		ngx_log(WARN, "Couldn't open /dev/urandom")
		_release_lock()
		return false
	end

	local chunk
	local raw_data = f:read(read_size)

	--[[
	walk raw_data in chunk_size segments, assigning each segment
	to the next slot in random_buf, and bail out once (if) we fill up
	--]]
	for i = 1, read_size, chunk_size do
		if random_buf_count == num_chunks then
			break
		end

		chunk = string.sub(raw_data, i, chunk_size + i - 1)

		if chunk:len() == chunk_size then
			random_buf_count = random_buf_count + 1
			random_buf[random_buf_count] = to_hex(chunk)
		end
	end

	f:close()

	_release_lock()

	ngx_log(DEBUG, "c:" .. random_buf_count)

	return true
end

-- repeating timer to fill the buffer
local function _periodic_fill(premature)
	if premature then
		return
	end

	_fill_buf()

	timer_at(rate, _periodic_fill)
end


--[[
get a random hex-encoded string of length number of characters

if length is greater than the total amount of available data in
the buffer, this will return as much data as is held in the buffer

if length is not an even multiple of chunk_size, an additional chunk
will be taken and split to satisfy the request
--]]
function _M.get_string(length)
	if random_buf_count == 0 then
		return nil, "Buffer pool is empty!"
	end

	if length > max_size then
		return nil, "Cannot get more than max_size (" .. max_size .. ") bytes"
	end

	local get_chunks = math.floor(length / chunk_size)
	local extra = length % chunk_size

	if extra > 0 then
		get_chunks = get_chunks + 1
	end

	if not _acquire_lock() then
		return nil, "Couldn't acquire semaphore lock"
	end

	if get_chunks > random_buf_count then
		ngx_log(WARN, "Tried to get " .. get_chunks .. " chunks but only supplying " .. random_buf_count)
		get_chunks = random_buf_count
		extra = 0
	end

	ngx_log(DEBUG, "g:" .. get_chunks)

	local res_buf = new_tab(get_chunks, 0)
	local res_buf_count = 0

	--[[
	starting at the top of the random_buf stack, retrieve get_chunks
	elements and add them to the temp buffer, then move the random_buf
	pointer down by one. we don't need to clear the "popped" random_buf
	element, as they'll be overwritten when _fill_buf() gets back here
	--]]
	for i = 1, get_chunks do
		res_buf_count = res_buf_count + 1

		--[[
		if the request length wasn't an even divisor of the chunk size,
		pop one more chunk and get a subset of its length. this means we're
		wasting (chunk_size - extra) data
		--]]
		if i == get_chunks and extra > 0 then
			ngx_log(DEBUG, "e:" .. extra)
			res_buf[res_buf_count] = string.sub(random_buf[random_buf_count], 1, extra)
		else
			res_buf[res_buf_count] = random_buf[random_buf_count]
		end

		random_buf[random_buf_count] = nil
		random_buf_count = random_buf_count - 1
	end

	_release_lock()

	ngx_log(DEBUG, "c:" .. random_buf_count)

	return table.concat(res_buf, ''), nil
end

--[[
get a table with num elements of hex-encoded strings, each the length of chunk_size

if num is greater than the number of available chunks in the buffer
this will return as much data as is held in the buffer
--]]
function _M.get_chunks(num)
	if random_buf_count == 0 then
		return nil, "Buffer pool is empty!"
	end

	if num > num_chunks then
		return nil, "Cannot get more than num_chunks (" .. max_size .. ") chunks"
	end

	if not _acquire_lock() then
		return nil, "Couldn't acquire semaphore lock"
	end

	if num > random_buf_count then
		ngx_log(WARN, "Tried to get " .. num .. " chunks but only supplying " .. random_buf_count)
		num = random_buf_count
	end

	ngx_log(DEBUG, "g:" .. num)

	local res_buf = new_tab(num, 0)
	local res_buf_count = 0

	for i = 1, num do
		res_buf_count = res_buf_count + 1
		res_buf[res_buf_count] = random_buf[random_buf_count]
		random_buf[random_buf_count] = nil
		random_buf_count = random_buf_count - 1
	end

	_release_lock()

	ngx_log(DEBUG, "c:" .. random_buf_count)

	return res_buf, nil
end

--[[
initialize the module with buffer geometry and fill rate options

the two required optons are max_size and chunk_size, given in bytes.
the total number of chunks is calculated as floor(max_size / chunk_size),
so if chunk_size is not an even divisor, the total size of the buffer will
be less than the given max_size. so do your math right :p

one optional argument, rate, determines how quickly to fill the buffer
via ngx.timer. rate is measured in seconds. once the number of filled chunks
is the largest value for the buffer's geometry, additional chunks will not
be filled, though periodic timer runs will still check and fill if needed
--]]
function _M.init(opts)
	if initted then
		return true, nil
	end

	max_size    = opts.max_size
	chunk_size  = opts.chunk_size
	rate        = opts.rate or 1

	if type(max_size) ~= "number" or max_size < 0 then
		return false, "max_size must be a positive integer"
	end

	if type(chunk_size) ~= "number" or chunk_size < 0 or max_size < chunk_size then
		return false, "chunk_size must be a positive number less than max_size"
	end

	if type(rate) ~= "number" or rate < 0 then
		return false, "rate must be a positive integer"
	end

	num_chunks = math.floor(max_size / chunk_size)
	max_size   = num_chunks * chunk_size

	ngx_log(DEBUG, "b:" .. chunk_size .. ",m:" .. max_size .. ",n:" .. num_chunks)

	--create the semaphore instance with one available resource
	sem = semaphore.new(1)

	random_buf = new_tab(num_chunks, 0)

	-- this will run as soon as we give up control of our thread
	timer_at(0, _periodic_fill)

	initted = true

	return true, nil
end

return _M
