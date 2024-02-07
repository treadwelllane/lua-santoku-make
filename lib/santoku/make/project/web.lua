<%
  str = require("santoku.string")
  squote = str.quote

  basexx = require("basexx")
  to_base64 = basexx.to_base64
%>

local make = require("santoku.make")

local varg = require("santoku.varg")
local tup = varg.tup
local vmap = varg.map
local reduce = varg.reduce

local fs = require("santoku.fs")
local pushd = fs.pushd
local cwd = fs.cwd
local join = fs.join
local mkdirp = fs.mkdirp
local dirname = fs.dirname
local writefile = fs.writefile
local readfile = fs.readfile
local extension = fs.extension
local absolute = fs.absolute
local exists = fs.exists
local touch = fs.touch
local files = fs.files

local validate = require("santoku.validate")
local istable = validate.istable
local isstring = validate.isstring

local sys = require("santoku.system")
local execute = sys.execute

local arr = require("santoku.array")
local amap = arr.map
local spread = arr.spread
local aincludes = arr.includes
local extend = arr.extend
local push = arr.push
local concat = arr.concat

local iter = require("santoku.iter")
local find = iter.find
local chain = iter.chain
local ivals = iter.ivals
local map = iter.map
local collect = iter.collect
local filter = iter.filter

local inherit = require("santoku.inherit")
local pushindex = inherit.pushindex

local fun = require("santoku.functional")
local bind = fun.bind

local tbl = require("santoku.table")
local get = tbl.get
local assign = tbl.assign

local tmpl = require("santoku.template")
local renderfile = tmpl.renderfile
local compile = tmpl.compile
local serialize_deps = tmpl.serialize_deps

-- local bundle = require("santoku.bundle")

local str = require("santoku.string")
local sinterp = str.interp
local stripprefix = str.stripprefix
local supper = string.upper
local sformat = string.format
local smatch = string.match
local gsub = string.gsub

local env = require("santoku.env")
local interpreter = env.interpreter

local basexx = require("basexx")
local from_base64 = basexx.from_base64

local err = require("santoku.error")
local pcall = err.pcall
local assert = err.assert
local error = err.error

local function create ()
  error("create web not yet implemented")
end

local function init (opts)

  local submake = make(opts)
  local target = submake.target
  local build = submake.build

  assert(istable(opts))
  assert(istable(opts.config))

  opts.single = opts.single and opts.single:gsub("^[^/]+/", "") or nil
  opts.skip_coverage = opts.profile or opts.skip_coverage or nil

  local function work_dir (...)
    return join(opts.dir, opts.env, ...)
  end

  local function dist_dir (...)
    return work_dir("main", "dist", ...)
  end

  local function server_dir (...)
    return work_dir("main", "server", ...)
  end

  local function server_dir_stripped (...)
    return server_dir(vmap(function (fp)
      return stripprefix(fp, "server/")
    end, ...))
  end

  local function test_dist_dir (...)
    return work_dir("test", "dist", ...)
  end

  local function test_server_dir (...)
    return work_dir("test", "server", ...)
  end

  local function test_server_dir_stripped (...)
    return test_server_dir(vmap(function (fp)
      return stripprefix(fp, "server/")
    end, ...))
  end

  local function client_dir (...)
    return work_dir("main", "client", ...)
  end

  local function test_client_dir (...)
    return work_dir("test", "client", ...)
  end

  local function dist_dir_client (...)
    return dist_dir("public", vmap(function  (fp)
      fp = stripprefix(fp, "client/assets/")
      fp = stripprefix(fp, "client/static/")
      return fp
    end, ...))
  end

  local function test_dist_dir_client (...)
    return test_dist_dir("public", vmap(function (fp)
      fp = stripprefix(fp, "client/static/")
      fp = stripprefix(fp, "client/assets/")
      return fp
    end, ...))
  end

  -- TODO: It would be nice if santoku ivals returned an empty iterator for
  -- nil instead of erroring. It would allow omitting the {} below
  local function get_action (fp)
    local ext = extension(fp)
    local match_fp = bind(smatch, fp)
    if (opts.exts and not aincludes(opts.exts, ext)) or
        find(match_fp, ivals(get(opts, "rules", "exclude") or {}))
    then
      return "ignore"
    elseif find(match_fp, ivals(get(opts, "rules", "copy") or {}))
    then
      return "copy"
    else
      return "template"
    end
  end

  -- TODO: use fs.copy
  local function add_copied_target (dest, src, extra_srcs)
    extra_srcs = extra_srcs or {}
    target({ dest }, extend({ src }, extra_srcs), function ()
      mkdirp(dirname(dest))
      writefile(dest, readfile(src))
    end)
  end

  local function add_templated_target (dest, src, env)
    local action = get_action(src, opts.config)
    if action == "copy" then
      return add_copied_target(dest, src, env)
    elseif action == "template" then
      target({ dest }, { src, opts.config_file }, function ()
        mkdirp(dirname(dest))
        local t, ds = renderfile(src, env)
        writefile(dest, t)
        writefile(dest .. ".d", serialize_deps(src, dest, ds))
      end)
    end
  end

  local function add_templated_target_base64 (dest, data, env, extra_srcs)
    extra_srcs = extra_srcs or {}
    target({ dest }, extend({ opts.config_file }, extra_srcs), function ()
      mkdirp(dirname(dest))
      local t, ds = compile(from_base64(data))(env)
      writefile(dest, t)
      writefile(dest .. ".d", serialize_deps(dest, opts.config_file, ds))
    end)
  end

  local function get_lua_version ()
    return (smatch(_VERSION, "(%d+.%d+)"))
  end

  local function get_require_paths (prefix, ...)
    local pfx = prefix and join(prefix, "lua_modules") or "lua_modules"
    local ver = get_lua_version()
    local cwd = cwd()
    return concat(reduce(function (t, n)
      return push(t, join(cwd, pfx, sformat(n, ver)))
    end, {}, ...), ";")
  end

  local function get_lua_path (prefix)
    return get_require_paths(prefix,
      "share/lua/%s/?.lua",
      "share/lua/%s/?/init.lua",
      "lib/lua/%s/?.lua",
      "lib/lua/%s/?/init.lua")
  end

  local function get_lua_cpath (prefix)
    return get_require_paths(prefix,
      "lib/lua/%s/?.so",
      "lib/lua/%s/loadall.so")
  end

  local function get_files (dir)
    if not exists(dir) then
      return {}
    end
    return collect(filter(function (fp)
      return get_action(fp) ~= "ignore"
    end, files(dir, true)))
  end

  local base_server_libs = get_files("server/lib")
  local base_server_deps = get_files("server/deps")
  local base_server_test_specs = get_files("server/test/spec")
  local base_server_rockspec = sinterp("%s#(name)-server-%s#(version).rockspec", opts.config.env)
  local base_server_makefile = "Makefile"
  local base_server_lib_makefile = "lib/Makefile"
  local base_server_nginx_cfg = "nginx.conf"
  local base_server_nginx_daemon_cfg = "nginx-daemon.conf"
  local base_server_init_test_lua = "init-test.lua"
  local base_server_init_worker_test_lua = "init-worker-test.lua"
  local base_server_luarocks_cfg = "luarocks.lua"
  local base_server_lua_modules = "lua_modules"
  local base_server_lua_modules_ok = "lua_modules.ok"
  local base_server_run_sh = "run.sh"

  local base_client_static = get_files("client/static")

  local base_env = {
    profile = opts.profile,
    skip_coverage = opts.skip_coverage,
    var = function (n)
      assert(isstring(n))
      return concat({ opts.config.env.variable_prefix, "_", n })
    end
  }

  local server_env = {
    environment = "main",
    component = "server",
    background = opts.background,
    libs = base_server_libs,
    dist_dir = absolute(dist_dir()),
    openresty_dir = absolute(opts.openresty_dir),
    lua_modules = absolute(dist_dir(base_server_lua_modules)),
    luarocks_cfg = absolute(server_dir(base_server_luarocks_cfg)),
  }

  local server_daemon_env = {
    background = true
  }

  local test_server_env = {
    environment = "test",
    component = "server",
    background = opts.background,
    libs = base_server_libs,
    dist_dir = absolute(test_dist_dir()),
    openresty_dir = absolute(opts.openresty_dir),
    luarocks_cfg = absolute(test_server_dir(base_server_luarocks_cfg)),
    luacov_config = absolute(test_server_dir("build", "default", "test", "luacov.lua")),
    lua = interpreter()[1],
    lua_path = get_lua_path(test_dist_dir()),
    lua_cpath = get_lua_cpath(test_dist_dir()),
    lua_modules = absolute(test_dist_dir(base_server_lua_modules)),
  }

  local test_server_daemon_env = {
    background = true
  }

  local client_env = {
    environment = "main",
    component = "client",
  }

  local test_client_env = {
    environment = "test",
    component = "client",
  }

  pushindex(server_env, _G)
  pushindex(server_env, base_env)
  pushindex(server_env, opts.config.env)
  pushindex(server_daemon_env, server_env)

  pushindex(test_server_env, _G)
  pushindex(test_server_env, base_env)
  pushindex(test_server_env, opts.config.env)
  pushindex(test_server_daemon_env, test_server_env)

  pushindex(client_env, _G)
  pushindex(client_env, base_env)
  pushindex(client_env, opts.config.env)

  pushindex(test_client_env, _G)
  pushindex(test_client_env, base_env)
  pushindex(test_client_env, opts.config.env)

  opts.config.env.variable_prefix =
    opts.config.env.variable_prefix or
    supper((gsub(opts.config.env.name, "%W+", "_")))

  add_templated_target_base64(server_dir(base_server_run_sh),
    <% return squote(to_base64(readfile("res/web/run.sh"))) %>, server_env) -- luacheck: ignore

  add_templated_target_base64(server_dir(base_server_nginx_cfg),
    <% return squote(to_base64(readfile("res/web/nginx.conf"))) %>, server_env, -- luacheck: ignore
    { server_dir(base_server_lua_modules_ok) })

  add_templated_target_base64(server_dir(base_server_nginx_daemon_cfg),
    <% return squote(to_base64(readfile("res/web/nginx.conf"))) %>, server_daemon_env, -- luacheck: ignore
    { server_dir(base_server_lua_modules_ok) })

  add_templated_target_base64(server_dir(base_server_rockspec),
    <% return squote(to_base64(readfile("res/web/template.rockspec"))) %>, server_env) -- luacheck: ignore

  add_templated_target_base64(server_dir(base_server_luarocks_cfg),
    <% return squote(to_base64(readfile("res/web/luarocks.lua"))) %>, server_env) -- luacheck: ignore

  add_templated_target_base64(server_dir(base_server_makefile),
    <% return squote(to_base64(readfile("res/web/luarocks.mk"))) %>, server_env) -- luacheck: ignore

  add_templated_target_base64(server_dir(base_server_lib_makefile),
    <% return squote(to_base64(readfile("res/web/lib.mk"))) %>, server_env) -- luacheck: ignore

  add_templated_target_base64(test_server_dir(base_server_run_sh),
    <% return squote(to_base64(readfile("res/web/run.sh"))) %>, test_server_env) -- luacheck: ignore

  add_templated_target_base64(test_server_dir(base_server_nginx_cfg),
    <% return squote(to_base64(readfile("res/web/nginx.conf"))) %>, test_server_env, -- luacheck: ignore
    { test_server_dir(base_server_lua_modules_ok),
      test_server_dir(base_server_init_test_lua),
      test_server_dir(base_server_init_worker_test_lua) })

  add_templated_target_base64(test_server_dir(base_server_nginx_daemon_cfg),
    <% return squote(to_base64(readfile("res/web/nginx.conf"))) %>, test_server_daemon_env, -- luacheck: ignore
    { test_server_dir(base_server_lua_modules_ok),
      test_server_dir(base_server_init_test_lua),
      test_server_dir(base_server_init_worker_test_lua) })

  add_templated_target_base64(test_server_dir(base_server_init_test_lua),
    <% return squote(to_base64(readfile("res/web/init-test.lua"))) %>, test_server_env) -- luacheck: ignore

  add_templated_target_base64(test_server_dir(base_server_init_worker_test_lua),
    <% return squote(to_base64(readfile("res/web/init-worker-test.lua"))) %>, test_server_env) -- luacheck: ignore

  add_templated_target_base64(test_server_dir(base_server_rockspec),
    <% return squote(to_base64(readfile("res/web/template.rockspec"))) %>, test_server_env) -- luacheck: ignore

  add_templated_target_base64(test_server_dir(base_server_luarocks_cfg),
    <% return squote(to_base64(readfile("res/web/luarocks.lua"))) %>, test_server_env) -- luacheck: ignore

  add_templated_target_base64(test_server_dir(base_server_makefile),
    <% return squote(to_base64(readfile("res/web/luarocks.mk"))) %>, test_server_env) -- luacheck: ignore

  add_templated_target_base64(test_server_dir(base_server_lib_makefile),
    <% return squote(to_base64(readfile("res/web/lib.mk"))) %>, test_server_env) -- luacheck: ignore

  add_copied_target(
    dist_dir(base_server_run_sh),
    server_dir(base_server_run_sh))

  add_copied_target(
    dist_dir(base_server_nginx_cfg),
    server_dir(base_server_nginx_cfg))

  add_copied_target(
    dist_dir(base_server_nginx_daemon_cfg),
    server_dir(base_server_nginx_daemon_cfg))

  add_copied_target(
    test_dist_dir(base_server_init_test_lua),
    test_server_dir(base_server_init_test_lua))

  add_copied_target(
    test_dist_dir(base_server_init_worker_test_lua),
    test_server_dir(base_server_init_worker_test_lua))

  add_copied_target(
    test_dist_dir(base_server_run_sh),
    test_server_dir(base_server_run_sh))

  add_copied_target(
    test_dist_dir(base_server_nginx_cfg),
    test_server_dir(base_server_nginx_cfg),
    { test_dist_dir(base_server_init_test_lua), test_dist_dir(base_server_init_worker_test_lua) })

  add_copied_target(
    test_dist_dir(base_server_nginx_daemon_cfg),
    test_server_dir(base_server_nginx_daemon_cfg))

  for flag in ivals({
    "profile", "skip_coverage"
  }) do
    local fp = work_dir(flag .. ".flag")
    mkdirp(dirname(fp))
    local strval = tostring(opts[flag])
    if not exists(fp) then
      writefile(fp, strval)
    else
      local val = readfile(fp)
      if val ~= strval then
        writefile(fp, strval)
      end
    end
  end

  target(
    amap({ base_server_init_test_lua, base_server_init_worker_test_lua }, test_server_dir),
    amap({ "profile.flag", "skip_coverage.flag" }, work_dir))

  for fp in ivals(base_server_libs) do
    add_templated_target(server_dir_stripped(fp), fp, server_env)
  end

  for fp in ivals(base_server_libs) do
    add_templated_target(test_server_dir_stripped(fp), fp, test_server_env)
  end

  for fp in ivals(base_server_deps) do
    add_templated_target(server_dir_stripped(fp), fp, server_env)
  end

  for fp in ivals(base_server_deps) do
    add_templated_target(test_server_dir_stripped(fp), fp, test_server_env)
  end

  for fp in ivals(base_server_test_specs) do
    add_templated_target(test_server_dir_stripped(fp), fp, test_server_env)
  end

  for fp in ivals(base_client_static) do
    add_templated_target(client_dir(fp), fp, client_env)
    add_copied_target(dist_dir_client(fp), client_dir(fp))
  end

  for fp in ivals(base_client_static) do
    add_templated_target(test_client_dir(fp), fp, test_client_env)
    add_copied_target(test_dist_dir_client(fp), test_client_dir(fp))
  end

  target(
    { server_dir(base_server_lua_modules_ok) },
    extend({ server_dir(base_server_luarocks_cfg) },
      amap(extend({}, base_server_libs, base_server_deps), server_dir_stripped)),
    function ()

      local config_file = absolute(opts.config_file)

      local config = {
        type = "lib",
        env = {
          name = opts.config.env.name .. "-server",
          version = opts.config.env.version,
          dependencies = opts.config.env.server.dependencies,
        }
      }

      pushindex(config, opts.config.env)

      return pushd(server_dir(), function ()

        require("santoku.make.project").init({
          config_file = config_file,
          luarocks_config = absolute(base_server_luarocks_cfg),
          config = config,
          single = opts.single,
          profile = opts.profile,
          skip_coverage = opts.skip_coverage,
          skip_tests = true,
        }).install()

        local post_make = get(server_env, "server", "hooks", "post_make")

        if post_make then
          post_make(server_env)
        end

        touch(base_server_lua_modules_ok)

      end)
    end)

  target(
    { test_server_dir(base_server_lua_modules_ok) },
    extend({ test_server_dir(base_server_luarocks_cfg) },
      amap(extend({}, base_server_libs, base_server_deps), test_server_dir_stripped)),
    function ()

      local config_file = absolute(opts.config_file)

      local config = {
        type = "lib",
        env = {
          name = opts.config.env.name .. "-server",
          version = opts.config.env.version,
          dependencies = extend({},
            opts.config.env.server.dependencies or {},
            get(opts.config.env.server, "test", "dependencies") or {})
        }
      }

      pushindex(config, opts.config.env)

      return pushd(test_server_dir(), function ()

        require("santoku.make.project").init({
          config_file = config_file,
          luarocks_config = absolute(base_server_luarocks_cfg),
          config = config,
          single = opts.single,
          profile = opts.profile,
          skip_coverage = opts.skip_coverage,
          skip_tests = true,
          lua = test_server_env.lua,
          lua_path = test_server_env.lua_path,
          lua_cpath = test_server_env.lua_cpath,
        }).install()

        local post_make = get(test_server_env, "server", "hooks", "post_make")

        if post_make then
          post_make(test_server_env)
        end

        touch(base_server_lua_modules_ok)

      end)
    end)

  target(
    { "build" },
    extend({
      dist_dir(base_server_run_sh),
      dist_dir(base_server_nginx_cfg),
      dist_dir(base_server_nginx_daemon_cfg),
      server_dir(base_server_lua_modules_ok) },
      amap(extend({}, base_client_static), dist_dir_client)))

  target(
    { "test-build" },
    map(extend({
      test_dist_dir(base_server_run_sh),
      test_dist_dir(base_server_nginx_cfg),
      test_dist_dir(base_server_nginx_daemon_cfg),
      test_server_dir(base_server_lua_modules_ok) },
      amap(extend({}, base_client_static))), test_dist_dir_client))

  target(
    { "start" },
    { "build" },
    function (_, _, background)
      return pushd(dist_dir(), function ()
        execute({
          "sh", "run.sh",
          env = {
            [base_env.var("BACKGROUND")] = (background or opts.background) and "1" or "0"
          },
        })
      end)
    end)

  target(
    { "test-start" },
    { "test-build" },
    function (_, _, background)
      return pushd(test_dist_dir(), function ()
        execute({
          "sh", "run.sh",
          env = {
            [base_env.var("BACKGROUND")] = (background or opts.background) and "1" or "0"
          },
        })
      end)
    end)

  target(
    { "test" },
    amap(extend({}, base_server_test_specs), test_server_dir_stripped),
    function (_, _, iterating)

      build({ "stop", "test-stop" })
      build({ "test-start" }, true)

      local config_file = absolute(opts.config_file)

      local config = {
        type = "lib",
        env = {
          name = opts.config.env.name .. "-server",
          version = opts.config.env.version,
          dependencies = opts.config.env.server.dependencies
        }
      }

      pushindex(config, opts.config.env)

      return pushd(test_server_dir(), function ()

        local lib = require("santoku.make.project").init({
          config_file = config_file,
          luarocks_config = absolute(base_server_luarocks_cfg),
          config = config,
          single = opts.single,
          profile = opts.profile,
          skip_coverage = opts.skip_coverage,
          lua = test_server_env.lua,
          lua_path = test_server_env.lua_path,
          lua_cpath = test_server_env.lua_cpath,
        })

        lib.test({ skip_check = true })

        if not iterating then
          build({ "test-stop" })
        end

        lib.check()

      end)
    end)

  target( { "iterate" }, {}, function (_, _)

    tup(function (ok, ...)

      if not ok then
        error("inotify not found", ...)
      end

    end, pcall(execute, { "sh", "-c", "type inotifywait >/dev/null 2>/dev/null" }))

    while true do

      tup(function (ok, ...)

        if not ok then
          print(...)
        end

      end, pcall(build, { "test" }, true))

      execute({
        "inotifywait", "-qr",
        "-e", "close_write", "-e", "modify",
        "-e", "move", "-e", "create", "-e", "delete",
        spread(collect(filter(function (fp)
          return exists(fp)
        end, chain(files("."), ivals({ "client", "server" })))))
      })

    end

  end)

  target({ "stop" }, {}, function ()
    return pushd(dist_dir(), function ()
      execute({ "kill", smatch(readfile("server.pid"), "%d+") })
    end)
  end)

  target({ "test-stop" }, {}, function (_, _)
    return pushd(test_dist_dir(), function ()
      execute({ "kill", smatch(readfile("server.pid"), "%d+") })
    end)
  end)

  return {

    config = opts.config,

    test = function (opts)
      opts = opts or {}
      build(assign({ "test" }, opts))
    end,

    iterate = function (opts)
      opts = opts or {}
      build(assign({ "iterate" }, opts))
    end,

    build = function (opts)
      opts = opts or {}
      build(assign({ opts.test and "test-build" or "build" }, opts))
    end,

    start = function (opts)
      opts = opts or {}
      build(assign({ opts.test and "test-start" or "start" }, opts))
    end,

    stop = function (opts)
      opts = opts or {}
      build(assign({ "stop", "test-stop" }, opts))
    end,

  }

end

return {
  init = init,
  create = create,
}
