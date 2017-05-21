local _M = {}

_M.version = "0.2"

local ffi       = require("ffi")
local to_hex    = require("resty.string").to_hex
local semaphore = require("ngx.semaphore")
local sys       = require("lua_system_constants")

local dbg_cfg  = ngx.config.debug
local tbl_cat  = table.concat
local ffi_copy = ffi.copy
local ffi_str  = ffi.string
local ceil     = math.ceil
local floor    = math.floor
local max      = math.max
local min      = math.min
local fmt      = string.format
local sub      = string.sub
local tonumber = tonumber
local timer_at = ngx.timer.at
local ngx_log  = ngx.log
local yield    = coroutine.yield
local DEBUG    = ngx.DEBUG
local WARN     = ngx.WARN

ffi.cdef[[
int open(const char * filename, int flags);
size_t read(int fd, void * buf, size_t count);
int close(int fd);
char *strerror(int errnum);
]]

local O_RDONLY = sys.O_RDONLY()

-- buffer geometry
local chunk_size, num_chunks, max_size

-- buffer fill options
local rate, read_size, max_fill

-- buffer contents
local random_buf
local random_buf_idx = 0

-- ngx.semaphore instance
local sem, sem_timeout

-- grab table.new if we can to avoid excessive table resize
local new_tab
do
	local ok
	ok, new_tab = pcall(require, "table.new")
	if not ok or type(new_tab) ~= "function" then
		 new_tab = function (narr, nrec) return {} end
	end
end

local function dbg(...)
	if dbg_cfg then ngx_log(DEBUG, ...) end
end

-- attempt to grab a resource on the semaphore
-- because we only release one resource a time this is essentially a mutex
local function acquire_lock()
	local ok, err = sem:wait(sem_timeout)

	if not ok then
		return false
	end

	return true
end

-- release the lock
local function release_lock()
	sem:post(1)
	return true
end


-- fill the random_buf
local function fill_buf()
	-- if we're full, we don't need to do anything
	if random_buf_idx >= max_size then
		return true
	end

	if not acquire_lock() then
		ngx_log(WARN, "Couldn't acquire lock!")
		return false
	end

	-- open up urandom
	fd = ffi.C.open("/dev/urandom", O_RDONLY)
	if fd < 0 then
		ngx_log(WARN, "Error opening urandom fd: " ..
			ffi_str(ffi.C.strerror(ffi.errno())))

		release_lock()

		return false
	end

	local did_read = 0

	while did_read < max_fill and random_buf_idx < max_size do
		local res = ffi.C.read(fd, random_buf + random_buf_idx,
			min(read_size, min(max_size - random_buf_idx, max_fill - did_read)))

		res = tonumber(res)

		if res <= 0 then
			ngx_log(WARN, "Error reading from urandom fd: " ..
				ffi_str(ffi.C.strerror(ffi.errno())))

			release_lock()

			return false
		end

		did_read       = did_read + res
		random_buf_idx = random_buf_idx + res

		dbg("r:", res)
		dbg("i:", random_buf_idx)

		yield()
	end

	if ffi.C.close(fd) ~= 0 then
		ngx_log(WARN, "Error closing urandom fd: " ..
			ffi_str(ffi.C.strerror(ffi.errno())))
	end

	release_lock()

	return true
end

-- repeating timer to fill the buffer
local function periodic_fill(premature)
	if premature then
		return
	end

	fill_buf()

	timer_at(rate, periodic_fill)
end


--[[
get a random binary string of length number of bytes

if length is greater than the total amount of available data in
the buffer, this will return as much data as is held in the buffer

if length is not an even multiple of chunk_size, an additional chunk
will be taken and split to satisfy the request
--]]
function _M.get_string(length)
	if random_buf_idx == 0 then
		return nil, nil, "Buffer pool is empty!"
	end

	if length > max_size then
		return nil, nil, "Cannot get more than " .. max_size .. " bytes"
	end

	if not acquire_lock() then
		return nil, nil, "Couldn't acquire semaphore lock"
	end

	-- move the idx back no more chunks than either the number of chunks
	-- required to satisfy the request, or the number of chunks available
	local get_chunks = min(ceil(length / chunk_size),
		random_buf_idx / chunk_size)

	-- return either the number of bytes requested, or the remaining
	-- bytes in the buffer
	length = min(length, random_buf_idx)

	dbg("g:", get_chunks)
	dbg("l:", length)

	random_buf_idx = random_buf_idx - (get_chunks * chunk_size)
	local res_buf  = ffi_str(random_buf + random_buf_idx, length)

	release_lock()

	dbg("i:", random_buf_idx)

	return res_buf, length
end

--[[
get a table with num elements of binary strings, each the length of chunk_size

if num is greater than the number of available chunks in the buffer
this will return as much data as is held in the buffer
--]]
function _M.get_chunks(num)
	if random_buf_idx == 0 then
		return nil, nil, "Buffer pool is empty!"
	end

	if num > num_chunks then
		return nil, nil, "Cannot get more than " .. num_chunks .. " chunks"
	end

	if not acquire_lock() then
		return nil, nil, "Couldn't acquire semaphore lock"
	end

	num = min(num, random_buf_idx / chunk_size)

	dbg("g:", num)

	local res_buf = new_tab(num, 0)
	local res_buf_count = 0

	for i = 1, num do
		res_buf_count  = res_buf_count + 1
		random_buf_idx = random_buf_idx - chunk_size

		res_buf[res_buf_count] = ffi_str(random_buf + random_buf_idx, chunk_size)
	end

	release_lock()

	dbg("i:", random_buf_idx)

	return res_buf, num
end

--[[
read wrappers around buffer geometry and stats
--]]

function _M.chunk_size()
	return chunk_size
end

function _M.num_chunks()
	return num_chunks
end

function _M.max_size()
	return max_size
end

function _M.random_buf_idx()
	return random_buf_idx
end

--[[
initialize the module with buffer geometry and fill rate options

the two required optons are max_size and chunk_size, given in bytes.
the total number of chunks is calculated as floor(max_size / chunk_size),
so if chunk_size is not an even divisor, the total size of the buffer will
be less than the given max_size. so do your math right :p

three optional arguments determine how quickly to fill the buffer via ngx.timer
the first, rate, is measured in seconds, and defines the delay param for
ngx.timer. the last two, max_fill and read_size, define how many total bytes to
read into the buffer during one invocation of fill_buf(), and how many bytes
to read from /dev/urandom via read() before yielding the thread, respectively

one final optional argument, lock_timeout, defines the timeout threshold to
acquire the semaphore resource

once the number of filled chunks is the largest value for the buffer's geometry,
additional chunks will not be filled, though periodic timer runs will still
check and fill if needed.
--]]
function _M.init(opts)
	max_size    = opts.max_size
	chunk_size  = opts.chunk_size
	rate        = opts.rate or 1
	read_size   = opts.read_size or 4096
	max_fill    = opts.max_fill or read_size
	sem_timeout = opts.lock_timeout or 1

	if type(max_size) ~= "number" or max_size < 0 then
		return false, "max_size must be a positive integer"
	end

	if type(chunk_size) ~= "number" or chunk_size < 0 or max_size < chunk_size then
		return false, "chunk_size must be a positive integer less than max_size"
	end

	if type(rate) ~= "number" or rate < 0.01 then
		return false, "rate must be a positive number greater than 0.01"
	end

	if type(read_size) ~= "number" or read_size < 0 then
		return false, "read_size must be a positive integer"
	end

	if type(max_fill) ~= "number" or max_fill < 0 or max_fill < read_size then
		return false, "max_fill must be a positive integer greater than read_size"
	end

	if max_fill % read_size ~= 0 then
		read_size = max_fill / ceil(max_fill / read_size)
		ngx_log(WARN, fmt("read_size not an even divisor of max_fill, reducing to %d",
			read_size))
	end

	num_chunks = floor(max_size / chunk_size)
	if max_size ~= chunk_size * num_chunks then
		ngx_log(WARN, fmt("slack space in buffer geometry, wanted %d bytes " ..
			"but only getting %d * %d = %d", max_size, chunk_size, num_chunks,
			chunk_size * num_chunks))
	end
	max_size = num_chunks * chunk_size

	dbg("b:", chunk_size, ",m:", max_size, ",n:", num_chunks)

	--create the semaphore instance with one available resource
	sem = semaphore.new(1)

	-- allocate the buffer, based on our normalized geometry
	random_buf = ffi.new(ffi.typeof("char[?]"), max_size)

	-- prefill the whole buffer (mind the code duplication)
	fd = ffi.C.open("/dev/urandom", O_RDONLY)
	if fd < 0 then
		ngx_log(WARN, "Error opening urandom fd: " ..
			ffi_str(ffi.C.strerror(ffi.errno())))

		return false
	end

	local res = ffi.C.read(fd, random_buf, max_size)
	res = tonumber(res)

	dbg("r:", res)
	random_buf_idx = random_buf_idx + tonumber(res)
	dbg("i:", random_buf_idx)

	if ffi.C.close(fd) ~= 0 then
		ngx_log(WARN, "Error closing urandom fd: " ..
			ffi_str(ffi.C.strerror(ffi.errno())))
	end

	-- we prefilled the buffer, so wait a while before checking again
	timer_at(rate, periodic_fill)

	return true, nil
end

return _M
