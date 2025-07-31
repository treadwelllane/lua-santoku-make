#!/bin/sh

<%
  str = require("santoku.string")
  it = require("santoku.iter")
  arr = require("santoku.array")
%>

set -e

cd "$(dirname $0)"

<% return arr.concat(it.collect(it.map(function (k, v)
  return str.interp("export %1=%2", { k, str.quote(tostring(v)) })
end, it.pairs(run_env_vars or {}))), "\n") %>

<% push(environment == "test") %>
export LUACOV_CONFIG="<% return luacov_config %>"
<% pop() %>

<% return arr.concat(it.collect(it.map(function (env)
  return ". " .. env
end, it.filter(function (env)
  return not str.isempty(env)
end, it.ivals(run_env_scripts or {})))), "\n") %>

mkdir -p logs
touch logs/access.log logs/error.log
ln -sf /dev/stdout logs/stdout

exec openresty -p "$PWD" -c nginx-daemon.conf
