use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3) + 3;

my $pwd = cwd();

our $HttpConfig = qq{
	lua_package_path "$pwd/lib/?.lua;;";

	init_worker_by_lua_block {
		local urandom = require "resty.urandom"

		local opts = {
			max_size   = 96,
			chunk_size = 8,
			rate       = 0.01,
			max_fill   = 32,
			read_size  = 32,
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

=== TEST 1: check read_size
--- http_config eval: $::HttpConfig
--- config
    location /t {
        access_by_lua_block {
			local urandom = require "resty.urandom"

			local str, len, err = urandom.get_string(96)

			local t = { urandom.random_buf_idx() }

			ngx.sleep(.1)

			t[2] = urandom.random_buf_idx()

			ngx.say(table.concat(t, "\n"))
		}
	}
--- request
GET /t
--- no_error_log
[error]
--- error_log
i:32
i:64
i:96
--- response_body
0
96

