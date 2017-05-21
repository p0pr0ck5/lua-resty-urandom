use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 4);

my $pwd = cwd();

our $HttpConfig = qq{
	lua_package_path "$pwd/lib/?.lua;;";

	init_worker_by_lua_block {
		local urandom = require "resty.urandom"

		local opts = {
			max_size   = 32,
			chunk_size = 8,
		}

		local ok, err = urandom.init(opts)
		if not ok then
			ngx.log(ngx.ERR, err)
		end
	}
};

no_shuffle();
run_tests();

__DATA__

=== TEST 1: get_string
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
			local urandom = require "resty.urandom"

			local str, len, err = urandom.get_string(16)

			ngx.say(urandom.random_buf_idx())
		}
	}
--- request
GET /t
--- no_error_log
[error]
--- error_log
g:2
l:16
i:16
--- response_body
16

=== TEST 2: get_string max buf
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
			local urandom = require "resty.urandom"

			local str, len, err = urandom.get_string(32)

			ngx.say(urandom.random_buf_idx())
		}
	}
--- request
GET /t
--- no_error_log
[error]
--- error_log
g:4
l:32
i:0
--- response_body
0

=== TEST 3: buffer overreach
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
			local urandom = require "resty.urandom"

			local str, len, err = urandom.get_string(33)

			ngx.say(err)
		}
	}
--- request
GET /t
--- no_error_log
[error]
--- error_log
--- response_body
Cannot get more than 32 bytes

=== TEST 4: buffer empty
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
			local urandom = require "resty.urandom"

			local str, len, err = urandom.get_string(32)
			local str, len, err = urandom.get_string(32)

			ngx.say(err)
		}
	}
--- request
GET /t
--- no_error_log
[error]
--- error_log
--- response_body
Buffer pool is empty!

=== TEST 5: reduced len
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
			local urandom = require "resty.urandom"

			local str, len, err = urandom.get_string(16)
			local t, len, err = urandom.get_string(32)

			ngx.say(len)
		}
	}
--- request
GET /t
--- no_error_log
[error]
--- error_log
--- response_body
16


=== TEST 6: slack space
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
			local urandom = require "resty.urandom"

			-- 17 bytes = 3 chunks
			local str, len, err = urandom.get_string(17)

			ngx.say(len)
			ngx.say(urandom.random_buf_idx())
		}
	}
--- request
GET /t
--- no_error_log
[error]
--- error_log
--- response_body
17
8
