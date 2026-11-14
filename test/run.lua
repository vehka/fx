-- Runs the Lua core against the real norns paramset with stubbed OSC.
--
--   lua5.3 test/run.lua [path to norns/lua]
--
-- Must be run from the repository root.

local norns_lua = arg[1] or os.getenv("NORNS_LUA") or (os.getenv("HOME") .. "/git/norns/lua")
local tmp = os.tmpname()
os.remove(tmp)
os.execute("mkdir -p " .. tmp .. "/code " .. tmp .. "/data/script")
-- make `require 'fx/lib/...'` resolve to this checkout
local pwd = io.popen("pwd"):read("*l")
os.execute("ln -s '" .. pwd .. "' " .. tmp .. "/code/fx")

package.path = norns_lua .. "/?.lua;" .. norns_lua .. "/lib/?.lua;" .. tmp .. "/code/?.lua;" .. package.path

-- just enough of matron for paramset and the core
_path = { data = tmp .. "/data/" }
norns = {
  state = { data = tmp .. "/data/script/", shortname = "script", pset_last = 1 },
  pmap = { data = {} },
}
_norns = {}
_menu = { rebuilds = 0, rebuild_params = function() _menu.rebuilds = _menu.rebuilds + 1 end }
util = require 'util'
tab = require 'tabutil'
controlspec = require 'core/controlspec'
paramset = require 'core/paramset'
params = paramset.new()

local sent = {}
osc = { send = function(to, path, args) table.insert(sent, { path = path, args = args or {} }) end }

local hooks = {}
package.preload['core/mods'] = function()
  return {
    this_name = "fx",
    hook = { register = function(which, name, fn) hooks[which] = hooks[which] or {}; hooks[which][name] = fn end },
    menu = { register = function() end, redraw = function() end, exit = function() end },
  }
end

local quiet_print = print
print = function() end -- paramset is chatty

----------------------------------------------------------------------------

local failures, count = 0, 0
local function check(label, cond)
  count = count + 1
  if not cond then failures = failures + 1 end
  quiet_print((cond and "  ok   " or "  FAIL ") .. label)
end

local function messages(path)
  local out = {}
  for _, m in ipairs(sent) do
    if m.path == path then table.insert(out, table.concat(m.args, " ")) end
  end
  return out
end

local function has(path, text)
  for _, m in ipairs(messages(path)) do
    if m == text then return true end
  end
  return false
end

local function run_hook(which)
  local names = {}
  for name in pairs(hooks[which] or {}) do table.insert(names, name) end
  table.sort(names)
  for _, name in ipairs(names) do hooks[which][name]() end
end

-- one script run: script_init stands in for the script's init()
local function start_script(script_init)
  sent = {}
  run_hook("script_pre_init")
  if script_init then script_init() end
  run_hook("script_post_init")
end

local function stop_script()
  sent = {}
  run_hook("script_post_cleanup")
  params:clear()
end

----------------------------------------------------------------------------
-- plugins: one written against the v1 API, one against v2

local core = require 'fx/lib/mod'
local fx = require 'fx/lib/fx'
local mods = require 'core/mods'

local Dist = fx:new{ subpath = "/fx_distortion" }
function Dist:add_params()
  params:add_group("fx_distortion", "FX Distortion", 4)
  Dist:add_slot("fx_distortion_slot", "slot")
  Dist:add_control("fx_distortion_drive", "drive", "drive", controlspec.new(0, 1, 'lin', 0, 0.5))
  Dist:add_option("fx_distortion_mode", "mode", "mode", { "soft", "hard" }, 1)
end
mods.hook.register("script_pre_init", "distortion mod pre init", function() Dist:install() end)

fx.register{
  name = "echo",
  title = "Echo",
  params = function()
    return {
      { id = "time", spec = controlspec.new(0.01, 2, 'exp', 0, 0.3, 's') },
      { id = "mode", type = "option", options = { "clean", "tape" } },
    }
  end,
}

local function script_init()
  params:add_number("script_param", "script param", 0, 10, 3)
  params:default()
end

quiet_print("fx lua test")
core.settings.persist = false

-- first run -----------------------------------------------------------------
start_script(script_init)
check("ensure is sent before init", sent[1] and sent[1].path == "/fx/ensure")
check("v1 plugin params exist with their v1 ids",
  params.lookup["fx_distortion_slot"] and params.lookup["fx_distortion_slot_drywet"] and params.lookup["fx_distortion_drive"])
check("v2 unit params exist", params.lookup["fx_echo_slot"] and params.lookup["fx_echo_time"] and params.lookup["fx_echo_bypass"])
check("fx params come after the script's own", params.lookup["script_param"] < params.lookup["fx_rack"])
check("params.read override is removed", rawget(params, "read") == nil)
check("dry/wet hidden while the unit is not an insert", not params:visible("fx_distortion_slot_drywet"))
check("defaults are sent to SC", has("/fx/set", "fx_distortion drive 0.5") and has("/fx/set", "echo time 0.3"))

sent = {}
params:set("fx_distortion_slot", 4)
check("slot = insert places the unit in insert 1", has("/fx/slot", "insert 1 fx_distortion"))
check("rack view follows", params:string("fx_ins_1") == "distortion")
check("position is recorded", params:get("fx_pos_fx_distortion") == 1)
check("dry/wet shown for an insert", params:visible("fx_distortion_slot_drywet"))

sent = {}
params:set("fx_ins_1", 3) -- options: none, echo, distortion -> sorted names: echo, fx_distortion
check("view option order is none, echo, distortion", params:string("fx_ins_1") == "distortion")
params:set("fx_ins_1", 2)
check("placing echo on insert 1 moves distortion to insert 2",
  has("/fx/slot", "insert 1 echo") and has("/fx/slot", "insert 2 fx_distortion"))
check("unit slot param follows the view", params:get("fx_echo_slot") == 4)
check("positions follow", params:get("fx_pos_echo") == 1 and params:get("fx_pos_fx_distortion") == 2)

sent = {}
params:set("fx_ins_1", 1)
check("view = none removes the unit", has("/fx/slot", "insert 1 none") and params:get("fx_echo_slot") == 1)
params:set("fx_echo_slot", 2)
check("slot = send a places in send a", has("/fx/slot", "a 1 echo"))
params:set("fx_echo_slot", 4)
check("back to insert returns to the remembered position",
  core.rack.insert[1] == "echo" and core.rack.insert[2] == "fx_distortion")

params:set("fx_distortion_drive", 0.8)
params:set("fx_echo_mode", 2)
params:set("fx_send_a_level", 0.4)
params:set("fx_send_a_dest", 1)
check("send params reach SC", has("/fx/send", "a level 0.4") and has("/fx/send", "a dest 0"))
params:write(1)
local pset = io.open(norns.state.data .. "script-01.pset"):read("*a")
check("PSET holds slot and position", pset:find('"fx_echo_slot": 4', 1, true) and pset:find('"fx_pos_echo": 1', 1, true))
check("PSET does not hold the rack view", not pset:find("fx_ins_1", 1, true))

-- persist off: rack cleared, restored from the PSET the script reads ---------
stop_script()
check("persist off clears the rack at cleanup", #messages("/fx/clear") == 1)
start_script(function()
  params:add_number("script_param", "script param", 0, 10, 3)
  params:read(1)
end)
check("values restored from the script's PSET", params:get("fx_distortion_drive") == 0.8 and params:get("fx_echo_mode") == 2)
check("rack order restored", core.rack.insert[1] == "echo" and core.rack.insert[2] == "fx_distortion")
check("restored rack is sent to SC", has("/fx/slot", "insert 1 echo") and has("/fx/slot", "insert 2 fx_distortion"))
check("restored values are sent to SC", has("/fx/set", "fx_distortion drive 0.8") and has("/fx/send", "a level 0.4"))
check("view restored", params:string("fx_ins_2") == "distortion")

stop_script()
start_script(function() params:add_number("script_param", "script param", 0, 10, 3) end)
check("a script that reads no PSET starts with an empty rack", core.rack.insert[1] == nil and params:get("fx_distortion_drive") == 0.5)

-- persist on: the rack survives script changes -------------------------------
core.settings.persist = true
params:set("fx_distortion_slot", 4)
params:set("fx_echo_slot", 3)
params:set("fx_distortion_drive", 0.25)
stop_script()
check("persist on does not clear the rack", #messages("/fx/clear") == 0)
start_script(script_init) -- this script reads PSET 1, live state wins
check("live values win over the PSET", params:get("fx_distortion_drive") == 0.25)
check("rack kept", core.rack.insert[1] == "fx_distortion" and core.rack.b[1] == "echo")
check("params mirror the kept rack", params:get("fx_distortion_slot") == 4 and params:get("fx_echo_slot") == 3
  and params:string("fx_b_1") == "echo")
check("loading a PSET from the menu still applies fx values", (function()
  params:read(1)
  return params:get("fx_distortion_drive") == 0.8 and core.rack.insert[1] == "echo" and core.rack.insert[2] == "fx_distortion"
    and core.rack.b[1] == nil
end)())

-- a full chain ----------------------------------------------------------------
stop_script()
core.settings.persist = false
run_hook("script_post_cleanup")
for i = 1, 4 do fx.register{ name = "filler" .. i, params = {} } end
start_script()
for i = 1, 4 do params:set("fx_filler" .. i .. "_slot", 4) end
params:set("fx_echo_slot", 4)
check("a fifth insert takes the last slot and the occupant leaves the rack",
  core.rack.insert[4] == "echo" and core.locate("filler4") == nil and params:get("fx_filler4_slot") == 1)

os.execute("rm -rf " .. tmp)
quiet_print(failures == 0 and ("PASS (" .. count .. " checks)") or ("FAILED: " .. failures .. " of " .. count))
os.exit(failures == 0 and 0 or 1)
