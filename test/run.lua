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
norns.state.mix = { cut_input_eng = -6 }
_norns = {
  execute = function(cmd)
    local p = io.popen(cmd .. " 2>/dev/null")
    local out = p:read("*a")
    p:close()
    return out
  end,
}
_menu = {
  rebuilds = 0,
  rebuild_params = function() _menu.rebuilds = _menu.rebuilds + 1 end,
  binarystates = { on = {}, triggered = {} },
}
util = require 'util'
tab = require 'tabutil'
controlspec = require 'core/controlspec'
paramset = require 'core/paramset'
params = paramset.new()

local sent = {}
osc = { send = function(to, path, args) table.insert(sent, { path = path, args = args or {} }) end }

-- the routing functions of norns 3.x; routes records what was asked for
local routes = {}
local crone_eng_cut = {} -- the levels that reached crone
local crone_cut = {}     -- the same for crone's softcut fader
audio = {
  ports = { "SuperCollider:in_1", "SuperCollider:in_2", "SuperCollider:in_3", "SuperCollider:in_4" },
  input_ports = function() return audio.ports end,
  output_ports = function() return { "SuperCollider:out_1", "SuperCollider:out_2", "SuperCollider:out_3", "SuperCollider:out_4" } end,
  level_eng_cut = function(value) table.insert(crone_eng_cut, value) end,
  level_cut = function(value) table.insert(crone_cut, value) end,
  port_connect = function(from, to) table.insert(routes, "+ " .. from .. " " .. to) return true end,
  port_disconnect = function(from, to) table.insert(routes, "- " .. from .. " " .. to) return true end,
}

-- a clock whose coroutines the test steps by hand
local tempo, clocks = 120, {}
clock = {
  get_tempo = function() return tempo end,
  run = function(f)
    local co = coroutine.create(f)
    table.insert(clocks, co)
    coroutine.resume(co)
    return #clocks
  end,
  sleep = function() coroutine.yield() end,
}

local hooks = {}
local page, redraws, exits = nil, 0, 0
package.preload['core/mods'] = function()
  return {
    this_name = "fx",
    hook = { register = function(which, name, fn) hooks[which] = hooks[which] or {}; hooks[which][name] = fn end },
    menu = {
      register = function(_, m) page = m end,
      redraw = function() redraws = redraws + 1 end,
      exit = function() exits = exits + 1 end,
    },
  }
end
-- drawing calls do nothing
screen = setmetatable({}, { __index = function() return function() end end })

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
check("the rack is moved behind the engine once the script is up", #messages("/fx/tail") == 1)
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

-- the rack page -------------------------------------------------------------
-- The cursor starts on ins 1; page.select(label) puts it on a row.
local function near(a, b) return math.abs(a - b) < 0.001 end
stop_script()
core.settings.persist = true
start_script() -- the default scene: echo in insert 1
local script_osc = {}
osc.event = function(path) table.insert(script_osc, path) end
local script_handler = osc.event
sent = {}
page.init()
check("opening the page starts the meters", has("/fx/meter", "1"))
page.key(3, 1)
check("K3 bypasses the selected effect through its param",
  params:get("fx_echo_bypass") == 1 and has("/fx/set", "echo bypass 1") and core.units.echo.bypass == 1)
page.key(3, 1)
check("and again un-bypasses", params:get("fx_echo_bypass") == 0 and core.units.echo.bypass == 0)
page.enc(3, -5)
check("E3 sets the dry/wet of an insert", near(params:get("fx_echo_mix"), 0.95) and near(core.units.echo.mix, 0.95))
page.enc(2, 1)
check("E2 moves the cursor one row", pcall(page.redraw))
sent = {}
page.key(1, 1)
page.enc(3, 1) -- none -> distortion; the choices are sorted by label
check("K1 + E3 scrolls without loading", #messages("/fx/slot") == 0 and core.rack.insert[2] == nil)
page.key(1, 0)
check("releasing K1 loads the effect shown",
  core.rack.insert[2] == "fx_distortion" and has("/fx/slot", "insert 2 fx_distortion") and params:string("fx_ins_2") == "distortion")
page.key(1, 1)
page.enc(2, -1)
page.key(1, 0)
check("K1 + E2 moves the effect and swaps with its neighbour",
  core.rack.insert[1] == "fx_distortion" and core.rack.insert[2] == "echo"
  and params:get("fx_pos_echo") == 2 and params:get("fx_pos_fx_distortion") == 1)
page.key(1, 1)
page.enc(2, -1)
page.key(1, 0)
check("a move stops at the end of the chain", core.rack.insert[1] == "fx_distortion")
page.key(3, 1) -- the cursor followed the move
check("a v1 unit has a bypass too",
  params:get("fx_bypass_fx_distortion") == 1 and has("/fx/set", "fx_distortion bypass 1"))
page.key(3, 1)
redraws = 0
osc.event("/fx/meter", { 0.5, 0, 0.1, 1.2, 17, 24 })
osc.event("/something/else", {})
check("a meter message redraws the page and is not passed to the script", redraws == 1 and #script_osc == 1)
check("other OSC still reaches the script", script_osc[1] == "/something/else")
check("the page draws", pcall(page.redraw))
for _ = 1, 30 do page.enc(2, 1) end
page.enc(3, 1)
check("the settings are the last rows", near(core.settings.fade, 0.06))
page.enc(3, -1)

-- input and send rows, and opening a row with K1 + K3
page.select("send a")
page.enc(3, 1)
check("E3 on a send row sets its level", params:get("fx_send_a_level") > 0 and #messages("/fx/send") > 0)
params:set("fx_send_a_level", 0)
page.key(1, 1) page.key(3, 1) page.key(1, 0)
page.enc(2, 1) -- the second row of the send: tap
page.enc(3, 1)
check("K1 + K3 opens a send's routing", params:get("fx_send_a_tap") == 2)
params:set("fx_send_a_tap", 1)
exits = 0
page.key(2, 1)
check("K2 closes the opened row, not the page", exits == 0)
page.select("ins 2") -- echo
page.key(1, 1) page.key(3, 1) page.key(1, 0)
check("opening does not bypass", params:get("fx_echo_bypass") == 0)
page.key(3, 1) -- the first row is bypass
check("an opened effect starts with its bypass, toggled with K3", params:get("fx_echo_bypass") == 1)
page.key(3, 1)
page.enc(2, 1) page.enc(2, 1) -- past dry/wet to time
local time_before = params:get("fx_echo_time")
page.enc(3, 5)
check("and lists its params for E3", params:get("fx_echo_time") > time_before and pcall(page.redraw))
params:set("fx_echo_time", time_before)
page.key(2, 1)
page.select("a 1")
page.key(1, 1) page.key(3, 1) page.key(1, 0)
page.key(2, 1)
check("opening an empty slot does nothing", exits == 1)

-- racks are saved and loaded from the page
page.select("save rack...")
typed = "from page"
page.key(3, 1)
check("a rack is saved with every fx param", (function()
  local f = io.open(presets.scene_path("from page") or "", "r")
  local text = f and f:read("*a") or ""
  if f then f:close() end
  return text:find('"fx_echo_time"', 1, true) and text:find('"fx_pos_echo"', 1, true)
    and text:find('"fx_send_a_level"', 1, true) and text:find('"fx_bypass_fx_distortion"', 1, true)
end)())
check("and the fx presets group lists it", params:string("fx_scene_name") == "from page")
params:set("fx_echo_time", 1.25)
core.set_row("insert", 1, nil)
page.select("rack")
page.key(3, 1)
check("K3 on the rack row loads the rack shown",
  core.rack.insert[1] == "fx_distortion" and near(params:get("fx_echo_time"), time_before))
for _ = 1, 10 do page.enc(3, -1) end -- the first rack in the list: default
core.set_row("insert", 1, nil)
check("E3 picks a rack without loading it", core.rack.insert[1] == nil)
page.key(3, 1)
check("and K3 loads that one: the default rack has only echo",
  core.rack.insert[1] == "echo" and core.locate("fx_distortion") == nil)
page.enc(3, 1) -- the next: from page
page.key(3, 1)
check("the saved rack comes back", core.rack.insert[1] == "fx_distortion" and core.rack.insert[2] == "echo")
page.select("ins 1")
sent = {}
page.deinit()
check("closing the page stops the meters and gives osc.event back",
  has("/fx/meter", "0") and osc.event == script_handler)
osc.event = nil

-- with no script loaded the page edits the model and SC directly
stop_script()
sent = {}
page.init()
page.select("ins 2") -- echo
page.enc(3, -10)
page.key(3, 1)
check("without a script dry/wet and bypass go straight to SC",
  near(core.units.echo.mix, 0.85) and core.units.echo.bypass == 1 and has("/fx/set", "echo bypass 1")
  and #messages("/fx/set") == 2)
page.enc(2, 1) -- ins 3
page.key(1, 1)
for _ = 1, 20 do page.enc(3, 1) end -- the last choice: res
page.key(1, 0)
check("and effects can be loaded", core.rack.insert[3] == "fx_res" and has("/fx/slot", "insert 3 fx_res"))
sent = {}
page.select("send a")
page.enc(3, 1)
page.key(1, 1) page.key(3, 1) page.key(1, 0)
page.select("ins 2")
page.key(1, 1) page.key(3, 1) page.key(1, 0)
page.select("rack")
page.key(3, 1)
page.select("save rack...")
typed = "no script"
page.key(3, 1)
check("rows that are params do nothing without a script",
  #sent == 0 and presets.scene_path("no script") == nil and pcall(page.redraw))
page.deinit()
start_script(script_init) -- reads PSET 1; the live rack wins
check("the next script's params take up what the page did",
  core.rack.insert[1] == "fx_distortion" and core.rack.insert[2] == "echo" and core.rack.insert[3] == "fx_res"
  and params:get("fx_res_slot") == 4 and params:get("fx_pos_fx_res") == 3
  and params:get("fx_echo_bypass") == 1 and near(params:get("fx_echo_mix"), 0.85))
check("and SC is told the same", has("/fx/set", "echo bypass 1") and has("/fx/slot", "insert 3 fx_res"))

-- a rack built on the page before any script ran
stop_script()
core.clear_rack()
core.live = {}
page.init()
page.select("ins 1")
page.key(1, 1)
page.enc(3, 2) -- one step per detent: distortion
page.key(1, 0)
page.deinit()
start_script(script_init)
check("a rack set up before the first script survives its start",
  core.rack.insert[1] == "fx_distortion" and params:get("fx_distortion_slot") == 4 and core.rack.insert[2] == nil)

core.settings.persist = false
stop_script()
check("persist off resets dry/wet and bypass at cleanup",
  core.units.echo.bypass == 0 and core.units.echo.mix == 1 and has("/fx/set", "echo bypass 0"))

-- step 6 ---------------------------------------------------------------------
-- softcut as a source
start_script(script_init)
check("there is a softcut param when core has the routing functions",
  params.lookup["fx_softcut"] ~= nil and params:get("fx_softcut") == 1 and #routes == 0)
audio.level_eng_cut(0.8)
check("with softcut out of the rack the engine-to-softcut level goes to crone as ever",
  crone_eng_cut[#crone_eng_cut] == 0.8 and #messages("/fx/cutfeed") == 0)
params:set("fx_softcut", 2)
check("through rack: softcut is patched to SuperCollider instead of crone",
  table.concat(routes, "|") == "- softcut:output_1 crone:input_3|+ softcut:output_1 SuperCollider:in_3"
    .. "|- softcut:output_2 crone:input_4|+ softcut:output_2 SuperCollider:in_4"
    .. "|+ SuperCollider:out_3 softcut:input_1|+ SuperCollider:out_4 softcut:input_2"
  and has("/fx/softcut", "1.0"))
check("crone's engine-to-softcut path is closed and the dry feed takes its level",
  crone_eng_cut[#crone_eng_cut] == 0 and has("/fx/cutfeed", "0.8"))
local crone_calls = #crone_eng_cut
audio.level_eng_cut(0.3)
check("a level set meanwhile goes to the feed, not to crone",
  #crone_eng_cut == crone_calls and has("/fx/cutfeed", "0.3"))
audio.level_cut(0.5)
check("crone's softcut fader sets the rack's softcut input too",
  crone_cut[#crone_cut] == 0.5 and messages("/fx/softcut")[#messages("/fx/softcut")] == "0.5")
routes = {}
run_hook("audio_post_restore_default_routing")
check("and patched again after core restored the default routes",
  #routes == 6 and routes[2] == "+ softcut:output_1 SuperCollider:in_3" and routes[5] == "+ SuperCollider:out_3 softcut:input_1")
routes = {}
stop_script()
check("persist off puts softcut back at cleanup",
  routes[1] == "- softcut:output_1 SuperCollider:in_3" and routes[2] == "+ softcut:output_1 crone:input_3"
  and routes[5] == "- SuperCollider:out_3 softcut:input_1"
  and core.softcut == false and has("/fx/softcut", "0"))
check("and hands the last level back to crone", crone_eng_cut[#crone_eng_cut] == 0.3 and has("/fx/cutfeed", "0"))
routes = {}
run_hook("audio_post_restore_default_routing")
check("and the hook then leaves the defaults alone", #routes == 0)
local cut_msgs = #messages("/fx/softcut")
audio.level_cut(0.25)
check("out of the rack the softcut fader goes to crone alone",
  crone_cut[#crone_cut] == 0.25 and #messages("/fx/softcut") == cut_msgs)

audio.ports = { "SuperCollider:in_1", "SuperCollider:in_2" }
start_script(script_init)
params:set("fx_softcut", 2)
check("nothing is repatched when SuperCollider has no inputs for it",
  #routes == 0 and core.softcut == false and crone_eng_cut[#crone_eng_cut] == 0.3)
stop_script()
audio.ports[3], audio.ports[4] = "SuperCollider:in_3", "SuperCollider:in_4"

-- an older norns: no routing functions
local port_connect = audio.port_connect
audio.port_connect = nil
start_script(script_init)
check("without audio.port_connect there is no softcut param and the rest is there",
  params.lookup["fx_softcut"] == nil and params.lookup["fx_input_level"] ~= nil
  and #params:lookup_param("fx_key_source").options == 5)
core.set_softcut(true)
audio.level_eng_cut(0.5)
check("and softcut routing is skipped", #routes == 0 and core.softcut == false and not has("/fx/softcut", "1")
  and crone_eng_cut[#crone_eng_cut] == 0.5)
stop_script()
audio.port_connect = port_connect

-- sidechain, modulation buses, tempo
start_script(script_init)
check("the sidechain can be softcut where it can be routed",
  params:lookup_param("fx_key_source").options[6] == "softcut" and has("/fx/key", "src 0"))
params:set("fx_key_source", 3)
params:set("fx_mod_2", 0.5)
check("sidechain source and mod values go to SC", has("/fx/key", "src 2") and has("/fx/mod", "2 0.5"))
check("the tempo is sent when a script starts", has("/fx/tempo", "120"))
sent = {}
coroutine.resume(clocks[#clocks])
check("and not again while it stays the same", #messages("/fx/tempo") == 0)
tempo = 90
coroutine.resume(clocks[#clocks])
check("a tempo change is followed", has("/fx/tempo", "90"))
stop_script()

-- units from single .sc files: sclang writes this file
os.execute("mkdir -p " .. tmp .. "/data/fx")
do
  local f = io.open(tmp .. "/data/fx/units.lua", "w")
  f:write([[return {
  { name = "echo", title = "echo", instances = 1, params = { { id = "wrong", min = 0, max = 1, warp = "lin", step = 0.0, default = 0, units = "" } } },
  { name = "shimmer", title = "Shimmer", instances = 2, params = { { id = "size", min = 0.1, max = 10, warp = "exp", step = 0.0, default = 2, units = "s" }, { id = "mix2", min = 0, max = 1, warp = "lin", step = 0.0, default = 0.5, units = "" } } },
}
]])
  f:close()
end
start_script(script_init)
check("a unit known only from the units file gets params from its specs",
  core.units.shimmer ~= nil and near(params:get("fx_shimmer_size"), 2) and params.lookup["fx_shimmer_mix2"] ~= nil
  and params:lookup_param("fx_shimmer_size").controlspec.maxval == 10 and has("/fx/set", "shimmer size 2.0"))
check("a unit registered from Lua keeps its Lua params",
  params.lookup["fx_echo_wrong"] == nil and params.lookup["fx_echo_mode"] ~= nil)

-- multiple instances
check("a declared second instance is a unit with params of its own",
  core.units.shimmer_2 ~= nil and core.units.shimmer_2.label == "shimmer 2"
  and params.lookup["fx_shimmer_2_size"] ~= nil and core.units.shimmer_3 == nil)
sent = {}
core.clear_rack()
params:set("fx_shimmer_slot", 4)
params:set("fx_shimmer_2_slot", 4)
params:set("fx_shimmer_2_size", 5)
check("both instances can be in the rack, each with its own values",
  core.rack.insert[1] == "shimmer" and core.rack.insert[2] == "shimmer_2"
  and has("/fx/slot", "insert 2 shimmer_2") and has("/fx/set", "shimmer_2 size 5.0")
  and near(params:get("fx_shimmer_size"), 2))
presets.save(core.units.shimmer_2, "big")
check("a copy saves its presets as its base's",
  presets.path(core.units.shimmer, "big") ~= nil
  and io.open(presets.path(core.units.shimmer, "big")):read("*a"):find('"fx_shimmer_size": 5', 1, true) ~= nil)
presets.load(core.units.shimmer, "big")
params:set("fx_shimmer_2_size", 1)
presets.load(core.units.shimmer_2, "big")
check("and either instance loads them", near(params:get("fx_shimmer_size"), 5) and near(params:get("fx_shimmer_2_size"), 5))

core.set_instances("fx_distortion", 2)
check("v1 plugins have one instance", core.units.fx_distortion_2 == nil and core.instances("fx_distortion") == 1)
-- on the page: the last row of an opened effect
page.init()
core.place("echo", "insert", 3)
page.select("ins 3")
page.key(1, 1) page.key(3, 1) page.key(1, 0)
for _ = 1, 10 do page.enc(2, 1) end
page.enc(3, 1)
check("the page's copies row adds an instance, placeable at once",
  core.instances("echo") == 2 and core.units.echo_2 ~= nil and pcall(page.redraw))
page.key(2, 1)
page.select("ins 4")
page.key(1, 1)
for _ = 1, 30 do page.enc(3, 1) end
for _ = 1, 30 do page.enc(3, -1) end
page.enc(3, 1) page.enc(3, 1) page.enc(3, 1) -- none, distortion, echo, echo 2
page.key(1, 0)
check("it is among the page's effects", core.rack.insert[4] == "echo_2" and has("/fx/slot", "insert 4 echo_2"))
page.deinit()
check("the number of copies is saved with the settings",
  (tab.load(tmp .. "/data/fx/settings.data").instances or {}).echo == 2)
stop_script()
start_script(script_init)
check("and its params exist from the next script start", params.lookup["fx_echo_2_time"] ~= nil)
core.place("echo_2", "insert", 1)
core.set_instances("echo", 1)
check("removing a copy takes it out of the rack", core.units.echo_2 == nil and core.rack.insert[1] == nil)
core.set_instances("echo", 2)
stop_script()

-- a rack requested by the script (no PSET is read here)
local function requesting(spec)
  return function()
    params:add_number("script_param", "script param", 0, 10, 3)
    check_request = fx.request(spec)
  end
end
start_script(requesting{
  insert = { "echo", { "echo", time = 1, mix = 0.5 }, "nosuch", "shimmer" },
  a = "fx_distortion",
  params = { fx_send_a_level = 0.3, script_param = 9 },
})
check("a requested rack is built when nothing else claims the rack",
  check_request == true and core.rack.insert[1] == "echo" and core.rack.insert[2] == "echo_2"
  and core.rack.insert[3] == nil and core.rack.insert[4] == "shimmer" and core.rack.a[1] == "fx_distortion"
  and has("/fx/slot", "insert 2 echo_2"))
check("with the values it names",
  near(params:get("fx_echo_2_time"), 1) and near(params:get("fx_echo_2_mix"), 0.5) and near(params:get("fx_send_a_level"), 0.3)
  and params:get("script_param") == 3 and has("/fx/set", "echo_2 time 1.0"))
check("at run time a request leaves a rack in use alone", fx.request{ insert = { "fx_res" } } == false
  and core.rack.insert[1] == "echo")
check("unless it says replace", fx.request{ b = { "fx_res" }, replace = true } == true
  and core.rack.insert[1] == nil and core.rack.b[1] == "fx_res")
check("an unknown saved rack is not applied", fx.request("no such rack") == false)
core.settings.persist = true
stop_script()
start_script(requesting{ insert = { "echo" } })
check("a kept rack wins over a request", core.rack.insert[1] == nil and core.rack.b[1] == "fx_res")
stop_script()
start_script(requesting{ insert = { "echo" }, replace = true })
check("but not over one that replaces", core.rack.insert[1] == "echo" and core.rack.b[1] == nil)
stop_script()
start_script(script_init)
check("a request does not outlive its script", core.requested == nil and core.rack.insert[1] == "echo")
core.settings.persist = false
stop_script()

os.execute("rm -rf " .. tmp)
quiet_print(failures == 0 and ("PASS (" .. count .. " checks)") or ("FAILED: " .. failures .. " of " .. count))
os.exit(failures == 0 and 0 or 1)
