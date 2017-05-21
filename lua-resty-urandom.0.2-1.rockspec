package = "lua-resty-urandom"
version = "0.2"
source = {
   url = "git://github.com/p0pr0ck5/lua-resty-urandom",
   tag = "0.2"
}
description = {
   summary = "Buffered wrapper for Linux/BSD kernel space CSPRNG Edit",
   homepage = "https://github.com/p0pr0ck5/lua-resty-urandom",
   license = "GNU GPLv3",
   maintainer = "Robert Paprocki <robert@cryptobells.com>"
}
dependencies = {
   "lua >= 5.1",
}
build = {
   type = "make",
   modules = {
      ["resty.urandom"] = "lib/resty/urandom.lua",
   }
}
