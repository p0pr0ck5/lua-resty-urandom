use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3) + 4;

my $pwd = cwd();

our $HttpConfig = qq{
	lua_package_path "$pwd/lib/?.lua;;";
};

no_shuffle();
run_tests();

__DATA__

=== TEST 1: init with only required values
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
			local urandom = require "resty.urandom"

			local opts = {
				max_size   = 32,
				chunk_size = 8,
			}

			local ok, err = urandom.init(opts)

			ngx.say(ok)
			ngx.say(err)
		}
	}
--- request
GET /t
--- no_error_log
[error]
--- response_body
true
nil

=== TEST 2: init with optional configs
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
			local urandom = require "resty.urandom"

			local opts = {
				max_size    = 32,
				chunk_size  = 8,
				rate        = 2,
				read_size   = 2048,
				max_fill    = 4096,
				sem_timeout = 2,
			}

			local ok, err = urandom.init(opts)

			ngx.say(ok)
			ngx.say(err)
		}
	}
--- request
GET /t
--- no_error_log
[error]
--- response_body
true
nil

=== TEST 3: invalid max_size
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
			local urandom = require "resty.urandom"

			local opts = {
				max_size    = -1,
				chunk_size  = 8,
			}

			local ok, err = urandom.init(opts)

			ngx.say(ok)
			ngx.say(err)
		}
	}
--- request
GET /t
--- no_error_log
[error]
--- response_body
false
max_size must be a positive integer

=== TEST 4: invalid chunk_size (1/2)
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
			local urandom = require "resty.urandom"

			local opts = {
				max_size    = 32,
				chunk_size  = -1,
			}

			local ok, err = urandom.init(opts)

			ngx.say(ok)
			ngx.say(err)
		}
	}
--- request
GET /t
--- no_error_log
[error]
--- response_body
false
chunk_size must be a positive integer less than max_size

=== TEST 5: invalid chunk_size (2/2)
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
			local urandom = require "resty.urandom"

			local opts = {
				max_size    = 32,
				chunk_size  = 33,
			}

			local ok, err = urandom.init(opts)

			ngx.say(ok)
			ngx.say(err)
		}
	}
--- request
GET /t
--- no_error_log
[error]
--- response_body
false
chunk_size must be a positive integer less than max_size

=== TEST 6: invalid rate
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
			local urandom = require "resty.urandom"

			local opts = {
				max_size    = 32,
				chunk_size  = 8,
				rate        = 0.001,
			}

			local ok, err = urandom.init(opts)

			ngx.say(ok)
			ngx.say(err)
		}
	}
--- request
GET /t
--- no_error_log
[error]
--- response_body
false
rate must be a positive number greater than 0.01

=== TEST 7: invalid read_size
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
			local urandom = require "resty.urandom"

			local opts = {
				max_size    = 32,
				chunk_size  = 8,
				read_size   = -1,
			}

			local ok, err = urandom.init(opts)

			ngx.say(ok)
			ngx.say(err)
		}
	}
--- request
GET /t
--- no_error_log
[error]
--- response_body
false
read_size must be a positive integer

=== TEST 8: invalid max_fill (default read_size)
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
			local urandom = require "resty.urandom"

			local opts = {
				max_size    = 32,
				chunk_size  = 8,
				max_fill    = 4095,
			}

			local ok, err = urandom.init(opts)

			ngx.say(ok)
			ngx.say(err)
		}
	}
--- request
GET /t
--- no_error_log
[error]
--- response_body
false
max_fill must be a positive integer greater than read_size

=== TEST 9: invalid max_fill (custom read_size)
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
			local urandom = require "resty.urandom"

			local opts = {
				max_size    = 32,
				chunk_size  = 8,
				max_fill    = 4096,
				read_size   = 8192
			}

			local ok, err = urandom.init(opts)

			ngx.say(ok)
			ngx.say(err)
		}
	}
--- request
GET /t
--- no_error_log
[error]
--- response_body
false
max_fill must be a positive integer greater than read_size

=== TEST 10: uneven max_fill
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
			local urandom = require "resty.urandom"

			local opts = {
				max_size    = 32,
				chunk_size  = 8,
				max_fill    = 8192,
				read_size   = 4097
			}

			local ok, err = urandom.init(opts)

			ngx.say(ok)
			ngx.say(err)
		}
	}
--- request
GET /t
--- no_error_log
[error]
--- error_log
read_size not an even divisor of max_fill, reducing to 4096
--- response_body
true
nil

=== TEST 10: uneven chunk geometry
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
			local urandom = require "resty.urandom"

			local opts = {
				max_size    = 100,
				chunk_size  = 9,
			}

			local ok, err = urandom.init(opts)

			ngx.say(ok)
			ngx.say(err)
		}
	}
--- request
GET /t
--- no_error_log
[error]
--- error_log
slack space in buffer geometry, wanted 100 bytes but only getting 9 * 11 = 99
--- response_body
true
nil

=== TEST 11: initial read
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
			local urandom = require "resty.urandom"

			local opts = {
				max_size    = 256,
				chunk_size  = 8,
			}

			local ok, err = urandom.init(opts)

			ngx.say(ok)
			ngx.say(err)
		}
	}
--- request
GET /t
--- no_error_log
[error]
--- error_log
r:256
i:256
--- response_body
true
nil
