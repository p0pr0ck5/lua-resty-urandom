## Name

lua-resty-urandom - Buffered wrapper for Linux/BSD kernel space CSPRNG

## Status

This library is in active development and is production ready.

## Description

lua-resty-urandom seeks to provide efficient access to the `/dev/urandom` device. Background reads fill a per-worker buffer with psuedorandom data, retrievable as a string or table of strings.

## Installation

Install via Luarocks or OPM:

```bash
 $ luarocks install lua-resty-urandom

 $ opm install p0pr0ck5/lua-resty-urandom # assume lua_system_constants >= 0.1.2 is installed
```

## Synopsis

```lua

init_worker_by_lua_block {
	local urandom = require "resty.urandom"

	urandom.init({
		max_size   = 1024 * 1024,
		chunk_size = 128,
		rate       = .1
	})
}

[...snip...]

server {
	location /random {
		content_by_lua_block {
			local urandom = require "resty.urandom"

			local gargs  = ngx.req.get_uri_args()
			local length = gargs.length or 128

			local data, len, err = urandom.get_string(tonumber(length))

			if (err) then
				ngx.log(ngx.WARN, err)
			else
				ngx.say(data)
			end
		}
	}

	location /random-t {
		content_by_lua_block {
			local urandom = require "resty.urandom"

			local gargs = ngx.req.get_uri_args()
			local num   = gargs.num or 1

			local data, len, err = urandom.get_chunks(tonumber(num))

			if (err) then
				ngx.log(ngx.WARN, err)
			else
				for i in ipairs(data) do
					ngx.say(data[i])
				end
			end
		}
	}
}


```

## Usage

### urandom.init(opts)

Initialize the buffer geometry and fill rate with a table of options. 

* **max_size**: The total amount of psuedorandom data to store, given in bytes.
* **chunk_size**: The amount of data to store in a given "chunk", given in bytes.
* **rate**: The rate at which to fill a portion of the buffer with data from `/dev/urandom`, given in seconds. This call is passed directly to `ngx.timer.at` (so fractions of seconds are available as well).
* **read_size**: The number of bytes to read from urandom at one time.
* **max_fill**: The total number of bytes to read per invocation of the background buffer fill function. If this value is less than `read_size`, the thread will yeild before attempting to read again to meet this value.
* **lock_timeout**: Amount of time, in seconds, to wait on the worker semaphore.

The total number of chunks is calculated as floor(max_size / chunk_size), so if chunk_size is not an even divisor, the total size of the buffer will be less than the given max_size. so do your math right :p

### urandom.get_string(length)

Get a string of psuedorandom data. If `length` is greater than `chunk_size`, more than one chunk will be used to satisfy the request. If `length` is not an even divisor of `chunk_size`, a portion of an additional chunk will be used to satisfy the request, with the leftover data in the chunk discarded.

If more data is requested than is currently available in the buffer, the response will be truncated to the length of available data in the buffer.

### urandom.get_chunks(n)

Get a table of `n` number of values, each of `chunk_length` size. If more chunks are requested than are currently available in the buffer, the response will be truncated to the number of chunks available in the buffer.

## License

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program. If not, see http://www.gnu.org/licenses/

## Bugs

Please report bugs by creating a ticket with the GitHub issue tracker.
