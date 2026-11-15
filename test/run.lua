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
_norns = {
  execute = function(cmd)
    local p = io.popen(cmd .. " 2>/dev/null")
    local out = p:read("*a")
    p:close()
    return out
  end,
}
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

-- textentry answers with whatever the test queued
local typed
package.preload['textentry'] = function()
  return { enter = function(callback) callback(typed) end }
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

local function trigger(id) params:lookup_param(id):bang() end

-- what the params menu does: E3 steps call delta, K3 calls params:set
local function row(id) return params:lookup_param(id) end
local function turn(id, steps)
  for _ = 1, math.abs(steps) do row(id):delta(steps > 0 and 1 or -1) end
end
local function press(id) params:set(id) end
local function pick(id, text)
  assert(row(id):choose(text), "no option " .. text)
  press(id)
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
-- pretend the plugin ships a factory preset
Dist.unit.plugin_dir = tmp .. "/code/fx_distortion"
os.execute("mkdir -p " .. tmp .. "/code/fx_distortion/presets/fx_distortion")
do
  local f = io.open(tmp .. "/code/fx_distortion/presets/fx_distortion/crunch.fxp", "w")
  f:write('-- fx preset: fx_distortion\n"fx_distortion_drive": 0.9\n"fx_distortion_mode": 2\n"fx_echo_time": 1.5\n')
  f:close()
end
function Dist:add_params()
  params:add_group("fx_distortion", "FX Distortion", 4)
  Dist:add_slot("fx_distortion_slot", "slot")
  Dist:add_control("fx_distortion_drive", "drive", "drive", controlspec.new(0, 1, 'lin', 0, 0.5))
  Dist:add_option("fx_distortion_mode", "mode", "mode", { "soft", "hard" }, 1)
end
mods.hook.register("script_pre_init", "distortion mod pre init", function() Dist:install() end)

-- a v1 plugin that adds its own params from script_post_init, uses separators
-- and sends one param over its own OSC path, as fx_resonator and fx_grains do
local Res = fx:new{ subpath = "/fx_res" }
function Res:add_params()
  params:add_separator("fx_res", "fx res")
  Res:add_slot("fx_res_slot", "slot")
  Res:add_control("fx_res_damping", "damping", "damping", controlspec.new(0, 1, 'lin', 0, 0.7))
  params:add_option("fx_res_model", "model", { "modal", "string" }, 1)
  params:set_action("fx_res_model", function(m)
    osc.send({ "localhost", 57120 }, self.subpath .. "/set", { "model", m - 1 })
  end)
end
mods.hook.register("script_post_init", "fx res post init", function() Res:add_params() end)

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
check("a v1 plugin adding its own params is not added twice",
  params.lookup["fx_res_slot"] and params:get("fx_res_damping") == 0.7 and core.units.fx_res.slot_id == "fx_res_slot")
params:set("fx_res_slot", 4)
check("and its slot works", core.rack.insert[1] == "fx_res" and has("/fx/slot", "insert 1 fx_res"))
params:set("fx_res_slot", 1)
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

-- rack rows: E3 scrolls, K3 applies
sent = {}
turn("fx_ins_2", 3)
check("scrolling a row loads nothing", #messages("/fx/slot") == 0 and core.rack.insert[2] == nil)
check("an unapplied choice is marked", row("fx_ins_2").name == "insert 2: res ?")
check("applied rows are not marked", row("fx_ins_1").name == "insert 1: distortion")
press("fx_ins_2")
check("K3 loads the choice on that row only",
  core.rack.insert[2] == "fx_res" and core.rack.insert[1] == "fx_distortion" and #messages("/fx/slot") == 1
  and row("fx_ins_2").name == "insert 2: res")
sent = {}
pick("fx_ins_2", "echo")
check("applying another unit unloads the previous one, it does not move to another row",
  core.rack.insert[2] == "echo" and core.locate("fx_res") == nil and core.rack.insert[3] == nil
  and params:get("fx_res_slot") == 1)
pick("fx_ins_3", "distortion")
check("applying a unit that is loaded elsewhere moves it",
  core.rack.insert[3] == "fx_distortion" and core.rack.insert[1] == nil and row("fx_ins_1").name == "insert 1: none")
turn("fx_ins_1", 2)
pick("fx_ins_2", "none")
check("none empties the row", core.rack.insert[2] == nil and core.locate("echo") == nil)
check("a rack change drops unapplied choices on other rows", row("fx_ins_1").name == "insert 1: none")
pick("fx_ins_3", "none")
check("every insert can go back to none", core.rack.insert[1] == nil and core.rack.insert[2] == nil
  and core.rack.insert[3] == nil and core.rack.insert[4] == nil)
check("unit slot params follow the rows", params:get("fx_distortion_slot") == 1 and params:get("fx_res_slot") == 1)

-- the slot row in each effect's own group works the same way
sent = {}
turn("fx_echo_slot_pick", 3)
check("scrolling an effect's slot loads nothing",
  #messages("/fx/slot") == 0 and row("fx_echo_slot_pick").name == "slot: insert ?" and params:get("fx_echo_slot") == 1)
turn("fx_echo_slot_pick", -1)
press("fx_echo_slot_pick")
check("K3 applies the slot", core.rack.b[1] == "echo" and row("fx_echo_slot_pick").name == "slot: send b"
  and params:get("fx_echo_slot") == 3 and row("fx_b_1").name == "send b 1: echo")
pick("fx_echo_slot_pick", "none")
check("slot none unloads", core.locate("echo") == nil)
params:set("fx_distortion_slot", 4)
params:set("fx_echo_slot", 4)
pick("fx_echo_slot_pick", "send a")
check("moving a unit to another chain takes that chain's first free slot", core.rack.a[1] == "echo")
row("fx_ins_2"):delta(2)
check("a fast encoder turn moves several steps", row("fx_ins_2").selected == 3)
row("fx_ins_2"):delta(-0.05)
check("a fine step counts as one", row("fx_ins_2").selected == 2)
row("fx_ins_2"):delta(-9)
check("and it stops at the ends", row("fx_ins_2").selected == 1)
pick("fx_echo_slot_pick", "none")
pick("fx_distortion_slot_pick", "none")
check("choosers are not saved and not mappable", row("fx_ins_1").t == params.tTRIGGER and row("fx_ins_1").allow_pmap == false)

-- unit slot params: these do move things, PSET restore depends on it
params:set("fx_echo_slot", 4)
params:set("fx_distortion_slot", 4)
check("slot = insert takes the first free slot", core.rack.insert[1] == "echo" and core.rack.insert[2] == "fx_distortion")
params:set("fx_pos_echo", 2)
check("a position swaps with the occupant", core.rack.insert[1] == "fx_distortion" and core.rack.insert[2] == "echo")
params:set("fx_pos_echo", 1)
check("unit slot param follows", params:get("fx_echo_slot") == 4)

sent = {}
params:set("fx_echo_slot", 2)
check("slot = send a places in send a 1", has("/fx/slot", "a 1 echo"))
params:set("fx_echo_slot", 4)
check("back to insert takes the first free slot",
  core.rack.insert[1] == "echo" and core.rack.insert[2] == "fx_distortion")

params:set("fx_distortion_drive", 0.8)
params:set("fx_echo_mode", 2)
params:set("fx_send_a_level", 0.4)
params:set("fx_send_a_dest", 1)
check("send params reach SC", has("/fx/send", "a level 0.4") and has("/fx/send", "a dest 0"))
params:set("fx_send_a_to_b", 0.3)
params:set("fx_send_b_to_a", 0.2)
check("send-to-send levels reach SC", has("/fx/xsend", "a b 0.3") and has("/fx/xsend", "b a 0.2"))
params:set("fx_input_level", 0.6)
params:set("fx_input_mode", 2)
check("input params reach SC", has("/fx/input", "level 0.6") and has("/fx/input", "mono 1"))
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
check("routing restored and sent to SC", params:get("fx_send_a_to_b") == 0.3 and params:get("fx_input_mode") == 2
  and has("/fx/xsend", "a b 0.3") and has("/fx/input", "level 0.6") and has("/fx/input", "mono 1"))

stop_script()
start_script(function() params:add_number("script_param", "script param", 0, 10, 3) end)
check("a script that reads no PSET starts with an empty rack", core.rack.insert[1] == nil and params:get("fx_distortion_drive") == 0.5)
check("and with the input and send-to-send levels at zero",
  params:get("fx_input_level") == 0 and params:get("fx_send_b_to_a") == 0 and has("/fx/input", "level 0") and has("/fx/xsend", "b a 0"))

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

-- presets ---------------------------------------------------------------------
stop_script()
start_script()
local presets = require 'fx/lib/presets'
os.execute("mkdir -p " .. tmp .. "/code/plug/lib")
do
  local f = io.open(tmp .. "/code/plug/lib/mod.lua", "w")
  f:write("local unit = require('fx/lib/fx').register{ name = 'plug', params = {} }\nreturn unit")
  f:close()
end
check("plugin directory is found from the registering file", require('plug/lib/mod').plugin_dir == tmp .. "/code/plug")
check("factory preset is listed", params:string("fx_preset_name") == "-" and (function()
  params:set("fx_preset_unit", 2) -- echo, fx_distortion, filler1..4 sorted: echo, filler1.., fx_distortion
  for i, name in ipairs(core.names) do
    if name == "fx_distortion" then params:set("fx_preset_unit", i) end
  end
  return params:string("fx_preset_name") == "crunch"
end)())
params:set("fx_echo_time", 0.3)
sent = {}
trigger("fx_preset_load")
check("loading a preset sets the unit's params and reaches SC",
  params:get("fx_distortion_drive") == 0.9 and params:get("fx_distortion_mode") == 2 and has("/fx/set", "fx_distortion drive 0.9"))
check("a preset cannot touch another unit's params", math.abs(params:get("fx_echo_time") - 0.3) < 0.001)

params:set("fx_distortion_drive", 0.33)
params:set("fx_distortion_slot", 4)
params:set("fx_distortion_slot_drywet", 0.6)
typed = "my/../preset"
trigger("fx_preset_save_as")
check("save as writes a user preset with a safe file name",
  util.file_exists(_path.data .. "fx/presets/fx_distortion/my_.._preset.fxp") and params:string("fx_preset_name") == "my_.._preset")
local text = io.open(_path.data .. "fx/presets/fx_distortion/my_.._preset.fxp"):read("*a")
check("preset holds the unit's params and dry/wet but not its slot",
  text:find('"fx_distortion_drive": 0.33', 1, true) and text:find('"fx_distortion_slot_drywet": 0.6', 1, true)
  and not text:find('fx_distortion_slot"', 1, true))
params:set("fx_distortion_drive", 0.1)
trigger("fx_preset_save_default")
check("default is listed first", presets.list(core.units.fx_distortion)[1] == "default")
check("factory presets cannot be deleted", presets.delete(core.units.fx_distortion, "crunch") == false)
params:set("fx_preset_name", 3)
trigger("fx_preset_delete")
check("delete removes the selected user preset", #presets.list(core.units.fx_distortion) == 2)

-- scenes --------------------------------------------------------------------
params:set("fx_echo_slot", 2)
params:set("fx_send_a_level", 0.7)
typed = "wide"
trigger("fx_scene_save")
check("scene saved and selected", params:string("fx_scene_name") == "wide")
params:set("fx_echo_slot", 1)
params:set("fx_filler1_slot", 4)
params:set("fx_send_a_level", 0)
params:set("fx_distortion_drive", 0.99)
trigger("fx_scene_load")
check("scene restores rack, sends and values",
  core.rack.a[1] == "echo" and core.locate("filler1") == nil and params:get("fx_send_a_level") == 0.7
  and params:get("fx_distortion_drive") == 0.1)
check("scene load puts the insert back first", core.rack.insert[1] == "fx_distortion")

-- a unit installed after the scene was saved leaves the rack on load
fx.register{ name = "newcomer", params = {} }
stop_script()
start_script()
params:set("fx_newcomer_slot", 4)
for i, name in ipairs(presets.scenes()) do
  if name == "wide" then params:set("fx_scene_name", i) end
end
trigger("fx_scene_load")
check("units the scene does not mention leave the rack", core.locate("newcomer") == nil)

-- defaults at script start --------------------------------------------------
stop_script()
start_script()
check("unit default preset replaces the built-in default", params:get("fx_distortion_drive") == 0.1)
check("without a default scene the rack starts empty", core.rack.insert[1] == nil)
check("the default is sent to SC", has("/fx/set", "fx_distortion drive 0.1"))

params:set("fx_echo_slot", 4)
params:set("fx_distortion_drive", 0.45)
trigger("fx_scene_save_default")
stop_script()
start_script()
check("default scene applies to a script with no fx state",
  core.rack.insert[1] == "echo" and params:get("fx_distortion_drive") == 0.45 and has("/fx/slot", "insert 1 echo"))

stop_script()
start_script(function()
  params:add_number("script_param", "script param", 0, 10, 3)
  params:read(1)
end)
check("fx values in the script's PSET win over the default scene",
  params:get("fx_distortion_drive") == 0.8 and core.rack.insert[2] == "fx_distortion")

os.execute("rm -rf " .. tmp)
quiet_print(failures == 0 and ("PASS (" .. count .. " checks)") or ("FAILED: " .. failures .. " of " .. count))
os.exit(failures == 0 and 0 or 1)
