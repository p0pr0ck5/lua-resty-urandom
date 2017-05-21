use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 4) - 1;

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

=== TEST 1: get_chunks
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
			local urandom = require "resty.urandom"

			local t, len, err = urandom.get_chunks(2)

			ngx.say(len)
			ngx.say(urandom.random_buf_idx())
		}
	}
--- request
GET /t
--- no_error_log
[error]
--- error_log
g:2
i:16
--- response_body
2
16

=== TEST 2: get_chunks max
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
			local urandom = require "resty.urandom"

			local t, len, err = urandom.get_chunks(4)

			ngx.say(len)
			ngx.say(urandom.random_buf_idx())
		}
	}
--- request
GET /t
--- no_error_log
[error]
--- error_log
g:4
i:0
--- response_body
4
0

=== TEST 3: get_chunks buffer overreach
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
			local urandom = require "resty.urandom"

			local t, len, err = urandom.get_chunks(5)

			ngx.say(err)
		}
	}
--- request
GET /t
--- no_error_log
[error]
--- response_body
Cannot get more than 4 chunks

=== TEST 4: buffer empty
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
			local urandom = require "resty.urandom"

			local str, len, err = urandom.get_string(32)
			local t, len, err = urandom.get_chunks(4)

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

=== TEST 5: reduced chunks
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
			local urandom = require "resty.urandom"

			local str, len, err = urandom.get_string(16)
			local t, len, err = urandom.get_chunks(4)

			ngx.say(len)
		}
	}
--- request
GET /t
--- no_error_log
[error]
--- error_log
--- response_body
2
