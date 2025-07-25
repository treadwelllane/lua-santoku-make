<%
  fs = require("santoku.fs")
  str = require("santoku.string")
  env = require("santoku.env")
  err = require("santoku.error")
%>

<% push(coverage) %>
require("luacov")
<% pop() push(profile) %>
require("santoku.profile")
<% pop() push(trace) %>
require("santoku.trace")
<% pop() %>

<% push(init) %>
local fs = require("santoku.fs")
local init_file = <% if showing() then
  local path = err.checknil(env.searchpath(init, fs.join(dist_dir, "lua_modules/share/lua/5.1/?.lua")))
  return str.quote(str.stripprefix(path, dist_dir .. "/"))
end %>
fs.runfile(init_file)
<% pop() %>
