-- fx core: unit registry, rack model, params and the OSC link to FxRack.
-- The rack model here is the source of truth; SuperCollider executes it.
-- See docs/DESIGN.md.

local Chooser = require 'fx/lib/chooser'

local Core = {}

Core.SC = { "localhost", 57120 }

Core.chains = {
  { id = "insert", label = "insert", size = 4, prefix = "fx_ins_" },
  { id = "a",      label = "send a", size = 2, prefix = "fx_a_" },
  { id = "b",      label = "send b", size = 2, prefix = "fx_b_" },
}
Core.sends = { "a", "b" }

-- the v1 per-unit slot option, kept for PSET compatibility
Core.slot_options = { "none", "send a", "send b", "insert" }
Core.slot_chain = { false, "a", "b", "insert" }
Core.chain_slot = { a = 2, b = 3, insert = 4 }

Core.units = {}      -- name -> unit
Core.names = {}      -- registration order, sorted when params are built
Core.rack = {}       -- chain id -> index -> unit name
Core.live = {}       -- param id -> last value, survives script changes
Core.ids = {}        -- fx param ids of the running script, in menu order
Core.is_fx_id = {}
Core.active = false  -- true while the running script has fx params
Core.pset_file = nil -- PSET the script read during init
Core.settings = { persist = true, fade = 0.05, instances = {} } -- instances: unit name -> copies
Core.mods = 4          -- modulation buses, as FxRack.numMods
Core.max_instances = 4
Core.softcut = false   -- softcut is patched through the rack
Core.requested = nil   -- the rack the running script asked for in init
Core.enabled = false   -- set by mod.lua: the mod is loaded, not just installed

local chain_by_id = {}
for _, c in ipairs(Core.chains) do
  chain_by_id[c.id] = c
  Core.rack[c.id] = {}
end

local function send(path, args)
  osc.send(Core.SC, path, args or {})
end

----------------------------------------------------------------------------
-- settings

local function settings_path()
  return _path.data .. "fx/settings.data"
end

function Core.load_settings()
  local t = tab.load(settings_path())
  if type(t) == "table" then
    for k, v in pairs(t) do
      if Core.settings[k] ~= nil and type(v) == type(Core.settings[k]) then
        Core.settings[k] = v
      end
    end
  end
end

function Core.save_settings()
  util.make_dir(_path.data .. "fx")
  tab.save(Core.settings, settings_path())
end

function Core.set_fade(seconds)
  Core.settings.fade = util.clamp(seconds, 0.01, 2)
  send("/fx/fade", { Core.settings.fade })
end

----------------------------------------------------------------------------
-- registry

function Core.register(unit)
  assert(type(unit.name) == "string", "fx: unit needs a name")
  if Core.units[unit.name] == nil then
    table.insert(Core.names, unit.name)
  end
  unit.label = unit.label or unit.name:gsub("^fx_", "")
  unit.param_ids = {}
  unit.param_key = {} -- the plugin's own name of a param -> param id
  unit.mix = 1     -- dry/wet and bypass as SC has them; they outlive the params
  unit.bypass = 0
  Core.units[unit.name] = unit
  return unit
end

function Core.unregister(name)
  if not Core.units[name] then return end
  Core.place(name, nil)
  Core.units[name] = nil
  for i, v in ipairs(Core.names) do
    if v == name then table.remove(Core.names, i) break end
  end
end

--- How many instances of a unit the rack offers: the user's choice, else
-- what the plugin declared, else one. v1 plugins have one.
function Core.instances(name)
  local unit = Core.units[name]
  if not unit or unit.legacy or unit.base then return 1 end
  local n = tonumber(Core.settings.instances[name]) or tonumber(unit.instances) or 1
  return util.clamp(math.floor(n), 1, Core.max_instances)
end

--- Make the copies match Core.instances. A copy is a unit of its own named
-- <name>_<n>, with the same params under ids of its own; SC makes its side
-- when the name is first used. Params of a new copy exist from the next
-- script start.
function Core.apply_instances()
  local names = {}
  for _, name in ipairs(Core.names) do table.insert(names, name) end
  for _, name in ipairs(names) do
    local unit = Core.units[name]
    if unit and not unit.base then
      local want = Core.instances(name)
      for i = 2, Core.max_instances do
        local copy = name .. "_" .. i
        local existing = Core.units[copy]
        if existing and existing.base ~= name then
          -- a plugin of its own that happens to have this name
        elseif i <= want then
          if not existing then
            existing = Core.register{ name = copy, base = name, instance = i,
              label = unit.label .. " " .. i, title = (unit.title or unit.label) .. " " .. i,
              plugin_dir = unit.plugin_dir }
          end
          existing.params = unit.params
        elseif existing then
          Core.unregister(copy)
        end
      end
    end
  end
end

function Core.set_instances(name, n)
  local unit = Core.units[name]
  if not unit or unit.legacy or unit.base then return end
  Core.settings.instances[name] = util.clamp(n, 1, Core.max_instances)
  Core.apply_instances()
end

--- Units that are a single .sc file have no Lua: sclang writes what it knows
-- of every native unit to a file when it starts (FxUnit.writeUnits), and
-- those no mod registered are taken from there. A Lua registration wins.
function Core.load_units_file()
  local chunk = loadfile(_path.data .. "fx/units.lua", "t", {})
  local ok, list = pcall(chunk or error)
  if ok and type(list) == "table" then
    for _, d in ipairs(list) do
      if type(d) == "table" and type(d.name) == "string" then
        local unit = Core.units[d.name] or Core.register{ name = d.name, auto = true }
        if unit.auto then
          unit.title = d.title
          unit.instances = d.instances
          unit.params = {}
          for _, p in ipairs(d.params or {}) do
            table.insert(unit.params, {
              id = p.id, name = p.name or p.id,
              spec = controlspec.new(p.min, p.max, p.warp, p.step, p.default, p.units ~= "" and p.units or nil),
            })
          end
        end
      end
    end
  end
  Core.apply_instances()
end

----------------------------------------------------------------------------
-- rack model

function Core.locate(name)
  for _, c in ipairs(Core.chains) do
    for i = 1, c.size do
      if Core.rack[c.id][i] == name then return c.id, i end
    end
  end
  return nil
end

local function first_free(chain_id)
  local c = chain_by_id[chain_id]
  for i = 1, c.size do
    if Core.rack[chain_id][i] == nil then return i end
  end
  return nil
end

local function snapshot()
  local s = {}
  for _, c in ipairs(Core.chains) do
    s[c.id] = {}
    for i = 1, c.size do s[c.id][i] = Core.rack[c.id][i] end
  end
  return s
end

-- send the slots that differ from `before`, then mirror the model in params
local function commit(before)
  for _, c in ipairs(Core.chains) do
    for i = 1, c.size do
      local now = Core.rack[c.id][i]
      if now ~= before[c.id][i] then
        send("/fx/slot", { c.id, i, now or "none" })
      end
    end
  end
  Core.sync_params()
end

--- Put a unit at chain/index, or take it out of the rack with chain = nil.
-- An occupant moves to the first free slot of the chain, or out if it is
-- full; with `replace` it always leaves the rack.
function Core.place(name, chain_id, index, replace)
  if not Core.units[name] then return end
  local before = snapshot()
  local old_chain, old_index = Core.locate(name)
  if old_chain == chain_id and old_index == index then return end
  if old_chain then Core.rack[old_chain][old_index] = nil end
  if chain_id then
    local occupant = Core.rack[chain_id][index]
    Core.rack[chain_id][index] = name
    if occupant and not replace then
      local free = first_free(chain_id)
      if free then Core.rack[chain_id][free] = occupant end
    end
  end
  commit(before)
end

--- A rack row was applied by hand. The row's occupant leaves the rack; a
-- unit that is loaded elsewhere moves here.
function Core.set_row(chain_id, index, name)
  if name == nil then
    local occupant = Core.rack[chain_id][index]
    if occupant then Core.place(occupant, nil) else Core.sync_params() end
  else
    Core.place(name, chain_id, index, true)
    Core.sync_params()
  end
end

--- Put a unit in the first free slot of a chain, or the last slot if the
-- chain is full. A PSET's position param then moves it to its exact slot.
function Core.place_in_chain(name, chain_id)
  local old_chain = Core.locate(name)
  if old_chain == chain_id then return end
  if chain_id == nil then
    Core.place(name, nil)
    return
  end
  Core.place(name, chain_id, first_free(chain_id) or chain_by_id[chain_id].size)
end

--- Exchange two slots of a chain; either may be empty. This is a reorder:
-- nothing leaves the rack.
function Core.swap(chain_id, i, j)
  local slots = Core.rack[chain_id]
  if i == j or slots[i] == slots[j] then return end
  local before = snapshot()
  slots[i], slots[j] = slots[j], slots[i]
  commit(before)
end

function Core.clear_rack()
  for _, c in ipairs(Core.chains) do Core.rack[c.id] = {} end
  send("/fx/clear")
end

local function rack_is_empty()
  for _, c in ipairs(Core.chains) do
    if next(Core.rack[c.id]) ~= nil then return false end
  end
  return true
end

--- Send the whole model. Idempotent on the SC side.
function Core.push_rack()
  for _, c in ipairs(Core.chains) do
    for i = 1, c.size do
      send("/fx/slot", { c.id, i, Core.rack[c.id][i] or "none" })
    end
  end
end

function Core.set(name, key, value)
  send("/fx/set", { name, key, value })
end

-- Set a unit's dry/wet or bypass from outside the params menu. With a script
-- running the param does the work, so menu, PSET and SC stay in step;
-- without one the model and SC are set, and the next script's param follows.
local function set_unit_value(name, key, id, value)
  local unit = Core.units[name]
  if not unit then return end
  if Core.active and id and params.lookup[id] then
    params:set(id, value)
  else
    unit[key] = value
    if id then Core.live[id] = value end
    Core.set(name, key, value)
  end
end

function Core.set_mix(name, value)
  set_unit_value(name, "mix", Core.units[name] and Core.units[name].mix_id, util.clamp(value, 0, 1))
end

function Core.set_bypass(name, on)
  set_unit_value(name, "bypass", Core.units[name] and Core.units[name].bypass_id, on and 1 or 0)
end

----------------------------------------------------------------------------
-- params

local function option_index(list, value)
  for i, v in ipairs(list) do
    if v == value then return i end
  end
  return 1
end

local function quiet_set(id, value)
  if params.lookup[id] == nil then return end
  params:set(id, value, true)
  Core.live[id] = params:get(id)
end

--- Register an fx param: its action also records the live value. Params
-- given a unit are what that unit's presets save.
function Core.bind(id, action, unit)
  if not Core.is_fx_id[id] then
    Core.is_fx_id[id] = true
    table.insert(Core.ids, id)
    if unit then table.insert(unit.param_ids, id) end
  end
  params:set_action(id, function(value)
    Core.live[id] = value
    if action then action(value) end
  end)
end

local function chooser(id)
  local index = params.lookup[id]
  return index and params.params[index] or nil
end

--- Make the rack rows, the per-unit slot/position params and mix visibility
-- reflect the model, without firing actions. Unapplied choices are dropped.
function Core.sync_params()
  if not Core.active then return end
  local rebuild = false
  for _, c in ipairs(Core.chains) do
    for i = 1, c.size do
      local name = Core.rack[c.id][i]
      local row = chooser(c.prefix .. i)
      if row then row:show(name and option_index(Core.view_names, name) or 1) end
    end
  end
  for _, name in ipairs(Core.names) do
    local unit = Core.units[name]
    local chain_id, index = Core.locate(name)
    local slot = chain_id and Core.chain_slot[chain_id] or 1
    if unit.slot_id then
      quiet_set(unit.slot_id, slot)
      local row = chooser(unit.slot_id .. "_pick")
      if row then row:show(slot) end
    end
    -- a unit outside the rack has no position: it takes the first free slot
    -- when it comes back, unless a PSET says otherwise
    unit.pos = index or 0
    quiet_set("fx_pos_" .. name, unit.pos)
    if unit.mix_id and params.lookup[unit.mix_id] then
      local want_visible = chain_id == "insert"
      if params:visible(unit.mix_id) ~= want_visible then
        if want_visible then params:show(unit.mix_id) else params:hide(unit.mix_id) end
        rebuild = true
      end
    end
  end
  if rebuild then _menu.rebuild_params() end
end

local function display_mix(param)
  local percent = util.round(param:get() * 100, 1)
  return (100 - percent) .. "/" .. percent
end

--- The slot row and the dry/wet control every unit has. Exactly two params,
-- as in v1, so plugin group sizes stay correct. The row is a Chooser (E3
-- scrolls, K3 applies); the saved value keeps the v1 id and lives hidden in
-- the fx rack group, see add_rack_params.
function Core.add_slot_params(unit, slot_id, slot_name, mix_id)
  unit.params_added = true
  unit.slot_id = slot_id
  unit.mix_id = mix_id
  params:add{ param = Chooser.new(slot_id .. "_pick", slot_name, Core.slot_options, function(value)
    params:set(slot_id, value)
    Core.sync_params()
  end) }
  params:add_control(mix_id, "dry/wet", controlspec.new(0, 1, 'lin', 0, 1), display_mix)
  Core.bind(mix_id, function(value)
    unit.mix = value
    Core.set(unit.name, "mix", value)
  end, unit)
  params:hide(mix_id)
end

local function add_native_param(unit, p)
  local id = "fx_" .. unit.name .. "_" .. p.id
  if p.param_id then id = unit.base and (p.param_id .. "_" .. unit.instance) or p.param_id end
  unit.param_key[p.id] = id
  local kind = p.type or "control"
  local name = p.name or p.id
  if kind == "control" then
    params:add_control(id, name, p.spec or p.controlspec, p.formatter)
  elseif kind == "taper" then
    params:add_taper(id, name, p.min, p.max, p.default, p.k, p.units)
  elseif kind == "number" then
    params:add_number(id, name, p.min, p.max, p.default, p.formatter)
  elseif kind == "option" then
    params:add_option(id, name, p.options, p.default or 1)
  elseif kind == "binary" then
    params:add_binary(id, name, p.behavior or "toggle", p.default or 0)
  else
    error("fx: unknown param type " .. tostring(kind))
  end
  Core.bind(id, function(value) Core.set(unit.name, p.id, value) end, unit)
end

local function add_bypass_param(unit, id, name)
  unit.bypass_id = id
  params:add_binary(id, name, "toggle", 0)
  Core.bind(id, function(value)
    unit.bypass = value
    Core.set(unit.name, "bypass", value)
  end)
end

local function add_native_unit(unit)
  local list = unit.params
  if type(list) == "function" then list = list() end
  list = list or {}
  local prefix = "fx_" .. unit.name
  params:add_group(prefix, unit.title or unit.label, #list + 3)
  Core.add_slot_params(unit, prefix .. "_slot", "slot", prefix .. "_mix")
  add_bypass_param(unit, prefix .. "_bypass", "bypass")
  for _, p in ipairs(list) do add_native_param(unit, p) end
end

local function add_rack_params()
  local slots = 0
  for _, c in ipairs(Core.chains) do slots = slots + c.size end
  local with_slot, without_bypass = 0, 0
  for _, name in ipairs(Core.names) do
    if Core.units[name].slot_id then with_slot = with_slot + 1 end
    if not Core.units[name].bypass_id then without_bypass = without_bypass + 1 end
  end
  params:add_group("fx_rack", "fx rack", slots + #Core.names + with_slot + without_bypass)

  Core.view_names = { "none" }
  local labels = { "none" }
  for _, name in ipairs(Core.names) do
    table.insert(Core.view_names, name)
    table.insert(labels, Core.units[name].label)
  end

  -- rows for editing the rack: E3 scrolls, K3 applies. Not saved; slot +
  -- position per unit are, so a PSET does not depend on what is installed.
  for _, c in ipairs(Core.chains) do
    for i = 1, c.size do
      params:add{ param = Chooser.new(c.prefix .. i, c.label .. " " .. i, labels, function(value)
        local name = Core.view_names[value]
        if name == "none" then name = nil end
        Core.set_row(c.id, i, name)
      end) }
    end
  end

  -- v1 plugin groups have a fixed size, so their bypass lives here
  for _, name in ipairs(Core.names) do
    local unit = Core.units[name]
    if not unit.bypass_id then
      add_bypass_param(unit, "fx_bypass_" .. name, unit.label .. " bypass")
    end
  end

  for _, name in ipairs(Core.names) do
    local unit = Core.units[name]
    -- the saved slot of each unit, under its v1 id
    if unit.slot_id then
      params:add_option(unit.slot_id, name .. " slot", Core.slot_options, 1)
      Core.bind(unit.slot_id, function(value)
        Core.place_in_chain(name, Core.slot_chain[value] or nil)
      end)
      params:hide(unit.slot_id)
    end
    local id = "fx_pos_" .. name
    params:add_number(id, name .. " position", 0, 16, 0)
    Core.bind(id, function(value)
      unit.pos = value
      local chain_id, index = Core.locate(name)
      if chain_id and value >= 1 and value <= chain_by_id[chain_id].size and value ~= index then
        Core.place(name, chain_id, value)
      end
    end)
    params:hide(id)
  end
end

----------------------------------------------------------------------------
-- softcut as a source. Normally softcut's outputs go to crone's mixer and
-- never pass SuperCollider. With the routing functions of norns 3.x they can
-- be patched to the server's third and fourth input instead, where FxRack
-- adds them to the main bus. Without those functions (2.x) there is no
-- softcut param and nothing here runs.

local CUT_ROUTES = {
  -- softcut output, its default destination, the rack's input
  { "softcut:output_1", "crone:input_3", "SuperCollider:in_3" },
  { "softcut:output_2", "crone:input_4", "SuperCollider:in_4" },
}

-- With softcut in the rack, SuperCollider's output contains softcut, and
-- crone feeds that output to softcut's input at the engine-to-softcut level
-- (audio.level_eng_cut, "input engine" under LEVELS): softcut would record
-- itself. So while softcut is in the rack that level is held at 0 in crone
-- and applied instead to a tap of the engine alone, which FxRack puts on the
-- server's outputs 3 and 4 and these routes bring to softcut's input.
local FEED_ROUTES = {
  { "SuperCollider:out_3", "softcut:input_1" },
  { "SuperCollider:out_4", "softcut:input_2" },
}

function Core.softcut_available()
  return audio ~= nil and audio.port_connect ~= nil and audio.port_disconnect ~= nil
end

local function has_port(list, name)
  if not list then return true end
  for _, port in ipairs(list() or {}) do
    if port == name then return true end
  end
  return false
end

local function route_softcut(on)
  for _, r in ipairs(CUT_ROUTES) do
    if on then
      audio.port_disconnect(r[1], r[2])
      audio.port_connect(r[1], r[3])
    else
      audio.port_disconnect(r[1], r[3])
      audio.port_connect(r[1], r[2])
    end
  end
  for _, r in ipairs(FEED_ROUTES) do
    if on then audio.port_connect(r[1], r[2]) else audio.port_disconnect(r[1], r[2]) end
  end
end

-- the engine-to-softcut level last asked for, by a script or the LEVELS menu
local function eng_cut_level()
  if Core.eng_cut then return Core.eng_cut end
  local db = norns and norns.state and norns.state.mix and norns.state.mix.cut_input_eng
  return util.dbamp(db or 0)
end

--- Put the mod between callers of audio.level_eng_cut and crone. Core has no
-- way to read that level back, and every caller, the LEVELS param included,
-- goes through this function. With softcut out of the rack the call passes
-- straight through.
function Core.wrap_eng_cut()
  if Core.eng_cut_original or not Core.softcut_available() or not audio.level_eng_cut then return end
  Core.eng_cut_original = audio.level_eng_cut
  audio.level_eng_cut = function(value)
    Core.eng_cut = value
    if Core.softcut then
      send("/fx/cutfeed", { value })
    else
      Core.eng_cut_original(value)
    end
  end
end

function Core.set_softcut(on)
  if not Core.softcut_available() then return end
  on = on and true or false
  -- without the feed softcut would record itself, so it is all or nothing
  if on and not (Core.eng_cut_original and has_port(audio.input_ports, CUT_ROUTES[1][3])
      and has_port(audio.output_ports, FEED_ROUTES[1][1])) then
    print("fx: SuperCollider has no ports for softcut; restart norns with fx enabled")
    on = false
  end
  if on ~= Core.softcut then
    local level = eng_cut_level()
    Core.softcut = on
    if on then
      -- close the path through crone before softcut arrives in the rack
      Core.eng_cut_original(0)
      send("/fx/cutfeed", { level })
      route_softcut(true)
    else
      route_softcut(false)
      send("/fx/cutfeed", { 0 })
      Core.eng_cut_original(level)
    end
  end
  send("/fx/softcut", { on and 1 or 0 })
end

--- For the audio_post_restore_default_routing hook: core has just put every
-- route back to its default, which it does when a script ends.
function Core.restore_routing()
  if Core.softcut and Core.softcut_available() then route_softcut(true) end
end

local function add_input_params()
  local with_softcut = Core.softcut_available()
  params:add_group("fx_input", "fx input", with_softcut and 3 or 2)
  params:add_control("fx_input_level", "input level", controlspec.new(0, 1, 'lin', 0, 0))
  Core.bind("fx_input_level", function(v) send("/fx/input", { "level", v }) end)
  params:add_option("fx_input_mode", "input mode", { "stereo", "mono" }, 1)
  Core.bind("fx_input_mode", function(v) send("/fx/input", { "mono", v - 1 }) end)
  if with_softcut then
    params:add_option("fx_softcut", "softcut", { "to output", "through rack" }, 1)
    Core.bind("fx_softcut", function(v) Core.set_softcut(v == 2) end)
  end
end

-- The sidechain (key) signal and the modulation buses, which any effect may
-- read; see FxRack.key and FxRack.mod. The softcut source comes last so the
-- other choices keep their numbers where it is missing.
local function add_control_params()
  local sources = { "off", "rack input", "audio in", "send a", "send b" }
  if Core.softcut_available() then table.insert(sources, "softcut") end
  params:add_group("fx_control", "fx sidechain + mod", 2 + Core.mods)
  params:add_option("fx_key_source", "sidechain", sources, 1)
  Core.bind("fx_key_source", function(v) send("/fx/key", { "src", v - 1 }) end)
  params:add_control("fx_key_gain", "sc gain", controlspec.new(0, 8, 'lin', 0, 1))
  Core.bind("fx_key_gain", function(v) send("/fx/key", { "gain", v }) end)
  for i = 1, Core.mods do
    params:add_control("fx_mod_" .. i, "mod " .. i, controlspec.new(0, 1, 'lin', 0, 0))
    Core.bind("fx_mod_" .. i, function(v) send("/fx/mod", { i, v }) end)
  end
end

local function add_send_params()
  params:add_group("fx_sends", "fx sends", #Core.sends * (3 + #Core.sends))
  for _, s in ipairs(Core.sends) do
    local prefix = "fx_send_" .. s
    params:add_control(prefix .. "_level", s .. " send level", controlspec.new(0, 1, 'lin', 0, 0))
    Core.bind(prefix .. "_level", function(v) send("/fx/send", { s, "level", v }) end)
    params:add_option(prefix .. "_tap", s .. " send tap", { "pre insert", "post insert" }, 1)
    Core.bind(prefix .. "_tap", function(v) send("/fx/send", { s, "tap", v - 1 }) end)
    params:add_control(prefix .. "_return", s .. " return level", controlspec.new(0, 1, 'lin', 0, 1))
    Core.bind(prefix .. "_return", function(v) send("/fx/send", { s, "ret", v }) end)
    params:add_option(prefix .. "_dest", s .. " return to", { "pre insert", "post insert" }, 2)
    Core.bind(prefix .. "_dest", function(v) send("/fx/send", { s, "dest", v - 1 }) end)
    -- the send's chain output into the other sends; both ways is a feedback loop
    for _, other in ipairs(Core.sends) do
      if other ~= s then
        local id = prefix .. "_to_" .. other
        params:add_control(id, s .. " to send " .. other, controlspec.new(0, 1, 'lin', 0, 0))
        Core.bind(id, function(v) send("/fx/xsend", { s, other, v }) end)
      end
    end
  end
end

-- replace the choices of an unsaved option param, optionally selecting one
local function set_options(id, list, select)
  local p = params:lookup_param(id)
  if #list == 0 then list = { "-" } end
  p.options = list
  p.count = #list
  p.selected = util.clamp(p.selected, 1, p.count)
  if select then
    for i, v in ipairs(list) do
      if v == select then p.selected = i end
    end
  end
end

local function ask_name(heading, callback)
  local textentry = require 'textentry'
  textentry.enter(function(text)
    if text and text ~= "" then callback(text) end
  end, "", heading)
end

local function add_preset_params()
  local presets = require 'fx/lib/presets'
  local labels = {}
  for _, name in ipairs(Core.names) do table.insert(labels, Core.units[name].label) end
  local has_units = #labels > 0
  if not has_units then labels = { "-" } end

  local function unit() return Core.units[Core.names[params:get("fx_preset_unit")]] end
  local function preset() return params:string("fx_preset_name") end
  local function refresh_presets(select)
    set_options("fx_preset_name", has_units and presets.list(unit()) or {}, select)
  end
  local function scene() return params:string("fx_scene_name") end
  local function refresh_scenes(select)
    set_options("fx_scene_name", presets.scenes(), select)
  end
  local function trigger(id, name, action)
    params:add_trigger(id, name)
    params:set_action(id, action)
  end
  local function unsaved_option(id, name)
    params:add_option(id, name, { "-" }, 1)
    params:lookup_param(id).save = false
  end

  params:add_group("fx_presets", "fx presets", 15)

  params:add_separator("fx_preset_sep", "effect presets")
  unsaved_option("fx_preset_unit", "effect")
  set_options("fx_preset_unit", labels)
  params:set_action("fx_preset_unit", function() refresh_presets() end)
  unsaved_option("fx_preset_name", "preset")
  trigger("fx_preset_load", "load", function()
    if has_units and preset() ~= "-" then presets.load(unit(), preset()) end
  end)
  trigger("fx_preset_save", "save", function()
    if not has_units then return end
    if preset() == "-" then
      ask_name("preset name", function(text) refresh_presets(presets.save(unit(), text)) end)
    else
      refresh_presets(presets.save(unit(), preset()))
    end
  end)
  trigger("fx_preset_save_as", "save as...", function()
    if not has_units then return end
    ask_name("preset name", function(text) refresh_presets(presets.save(unit(), text)) end)
  end)
  trigger("fx_preset_save_default", "save as default", function()
    if has_units then refresh_presets(presets.save(unit(), presets.DEFAULT)) end
  end)
  trigger("fx_preset_delete", "delete", function()
    if has_units and preset() ~= "-" then
      presets.delete(unit(), preset())
      refresh_presets()
    end
  end)

  params:add_separator("fx_scene_sep", "rack scenes")
  unsaved_option("fx_scene_name", "scene")
  trigger("fx_scene_load", "load", function()
    if scene() ~= "-" then presets.load_scene(scene()) end
  end)
  trigger("fx_scene_save", "save", function()
    if scene() == "-" then
      ask_name("scene name", function(text) refresh_scenes(presets.save_scene(text)) end)
    else
      refresh_scenes(presets.save_scene(scene()))
    end
  end)
  trigger("fx_scene_save_as", "save as...", function()
    ask_name("scene name", function(text) refresh_scenes(presets.save_scene(text)) end)
  end)
  trigger("fx_scene_save_default", "save as default rack", function()
    refresh_scenes(presets.save_scene(presets.DEFAULT))
  end)
  trigger("fx_scene_delete", "delete", function()
    if scene() ~= "-" then
      presets.delete_scene(scene())
      refresh_scenes()
    end
  end)

  refresh_presets()
  refresh_scenes()
  -- for the rack page, which saves scenes too
  Core.refresh_scenes = refresh_scenes
end

function Core.add_params()
  table.sort(Core.names)
  params:add_separator("fx_mod", "fx")
  -- units first: the rack group needs every unit's slot id
  for _, name in ipairs(Core.names) do
    local unit = Core.units[name]
    local ok, err = true, nil
    if unit.params_added then
      -- a v1 plugin that adds its params from its own script_post_init hook
    elseif unit.legacy then
      ok, err = pcall(unit.legacy.add_params, unit.legacy)
    else
      ok, err = pcall(add_native_unit, unit)
    end
    if not ok then print("fx: adding params for " .. name .. " failed: " .. tostring(err)) end
  end
  add_rack_params()
  add_input_params()
  add_send_params()
  add_control_params()
  add_preset_params()
  Core.active = true
end

----------------------------------------------------------------------------
-- restoring values

--- Read "id": value lines, setting the params whose id is in `accept`.
-- `rename` maps an id in the file to the id to set. Returns how many were set.
function Core.read_file(filename, accept, silent, rename)
  local fd = io.open(filename, "r")
  if not fd then return 0 end
  io.close(fd)
  local count = 0
  for line in io.lines(filename) do
    local id, value = string.match(line, "(\".-\")%s*:%s*(.*)")
    if id and value then
      id = id:gsub('^"', ''):gsub('"$', '')
      if rename then id = rename[id] or id end
      local index = params.lookup[id]
      local number = tonumber(value)
      if accept[id] and index and number then
        local p = params.params[index]
        if not (p.t == params.tBINARY and p.behavior == "trigger") then
          params:set(id, number, silent)
          count = count + 1
        end
      end
    end
  end
  return count
end

local function bang_fx_params()
  for _, id in ipairs(Core.ids) do
    local p = params:lookup_param(id)
    if not (p.t == params.tBINARY and p.behavior == "trigger") then p:bang() end
  end
end

----------------------------------------------------------------------------
-- a rack requested by the script

-- the unit of that name, or a copy of it, that this request has not used yet
local function free_instance(wanted, used)
  if type(wanted) ~= "string" then return nil end
  if Core.units[wanted] and not used[wanted] then return wanted end
  for i = 2, Core.max_instances do
    local copy = Core.units[wanted .. "_" .. i]
    if copy and copy.base == wanted and not used[copy.name] then return copy.name end
  end
  return nil
end

local function set_unit_param(unit, key, value)
  local id = unit.param_key[key]
  if key == "mix" then id = unit.mix_id elseif key == "bypass" then id = unit.bypass_id end
  id = id or (Core.is_fx_id[key] and key)
  if id and params.lookup[id] then params:set(id, value) end
end

--- Build the rack a script asked for; see Fx.request for the format. Needs
-- the fx params. A rack that is not empty is left alone unless the request
-- says `replace`. Returns whether it was applied.
function Core.apply_request(spec)
  if type(spec) == "string" then
    return require('fx/lib/presets').load_scene(spec)
  elseif type(spec) ~= "table" then
    return false
  end
  if not rack_is_empty() then
    if not spec.replace then return false end
    local names = {}
    for _, name in ipairs(Core.names) do table.insert(names, name) end
    for _, name in ipairs(names) do Core.place(name, nil) end
  end
  local used = {}
  for _, c in ipairs(Core.chains) do
    local list = spec[c.id]
    if type(list) == "string" then list = { list } end
    for i, entry in ipairs(list or {}) do
      if i > c.size then break end
      local wanted = type(entry) == "table" and entry[1] or entry
      local name = free_instance(wanted, used)
      if name then
        used[name] = true
        Core.place(name, c.id, i, true)
        if type(entry) == "table" then
          for key, value in pairs(entry) do
            if key ~= 1 then set_unit_param(Core.units[name], key, value) end
          end
        end
      else
        print("fx: requested effect " .. tostring(wanted) .. " is not available")
      end
    end
  end
  for id, value in pairs(spec.params or {}) do
    if Core.is_fx_id[id] and params.lookup[id] then params:set(id, value) end
  end
  Core.sync_params()
  return true
end

--- Called by a script through Fx.request: during init the request waits for
-- the fx params, later it is applied at once.
function Core.request(spec)
  if not Core.enabled then return false end
  if Core.active then return Core.apply_request(spec) end
  Core.requested = spec
  return true
end

--- Give the new script's fx params their values and make SC match.
-- Precedence: the live rack (persist on) > fx values in the PSET the script
-- read > the rack the script requested > the default scene > each unit's
-- default preset > built-in defaults. A request also fills an empty live
-- rack, and replaces one if it says so.
function Core.restore()
  local presets = require 'fx/lib/presets'
  presets.apply_defaults()
  -- the rack may have been set up on the rack page before any script ran
  local have_live = Core.settings.persist and (next(Core.live) ~= nil or not rack_is_empty())
  if have_live then
    -- station mode: the rack kept running; params take the live values
    for _, id in ipairs(Core.ids) do
      local value = Core.live[id]
      if value ~= nil then params:set(id, value, true) end
    end
    -- the model wins over anything stale in the live values: it may have
    -- been edited on the rack page while no script, and so no param, existed
    for _, name in ipairs(Core.names) do
      local unit = Core.units[name]
      if unit.mix_id and params.lookup[unit.mix_id] then params:set(unit.mix_id, unit.mix, true) end
      if unit.bypass_id and params.lookup[unit.bypass_id] then params:set(unit.bypass_id, unit.bypass, true) end
    end
    Core.sync_params()
    if Core.requested then Core.apply_request(Core.requested) end
  else
    local found = 0
    if Core.pset_file then found = Core.read_file(Core.pset_file, Core.is_fx_id) end
    if found == 0 then
      if not (Core.requested and Core.apply_request(Core.requested)) then
        presets.load_scene(presets.DEFAULT)
      end
    end
  end
  Core.requested = nil
  Core.push_rack()
  bang_fx_params()
  Core.sync_params()
  _menu.rebuild_params()
end

----------------------------------------------------------------------------
-- script lifecycle, called from the mod hooks

local function pset_filename(filename)
  filename = filename or norns.state.pset_last
  if type(filename) == "number" then
    return norns.state.data .. norns.state.shortname .. "-" .. string.format("%02d", filename) .. ".pset"
  end
  return filename
end

function Core.ensure()
  send("/fx/ensure")
  send("/fx/fade", { Core.settings.fade })
  Core.send_tempo(true)
end

----------------------------------------------------------------------------
-- tempo: SC keeps the norns clock's tempo on a control bus (FxRack.tempo)

function Core.send_tempo(force)
  if not (clock and clock.get_tempo) then return end
  local bpm = clock.get_tempo()
  if bpm and (force or bpm ~= Core.tempo) then
    Core.tempo = bpm
    send("/fx/tempo", { bpm })
  end
end

--- Follow tempo changes from any clock source. Core cancels every clock
-- when a script ends, after the cleanup hook, so this is started again at
-- each script start; with no script loaded the tempo is not followed.
function Core.watch_tempo()
  if not (clock and clock.run) then return end
  if Core.tempo_clock then return end
  Core.tempo_clock = clock.run(function()
    while true do
      Core.send_tempo()
      clock.sleep(0.5)
    end
  end)
end

function Core.pre_init()
  Core.ensure()
  Core.pset_file = nil
  Core.requested = nil
  Core.load_units_file()
  -- per-script param bookkeeping; reset here, before any plugin adds params
  Core.ids = {}
  Core.is_fx_id = {}
  for _, name in ipairs(Core.names) do
    local unit = Core.units[name]
    unit.slot_id, unit.mix_id, unit.bypass_id, unit.params_added = nil, nil, nil, false
    unit.param_ids = {}
    unit.param_key = {}
  end
  -- note which PSET the script reads in init; its fx values are applied once
  -- the fx params exist. Instance override, removed again in post_init.
  local class_read = getmetatable(params).__index.read
  rawset(params, "read", function(self, filename, silent)
    Core.pset_file = pset_filename(filename)
    return class_read(self, filename, silent)
  end)
end

function Core.post_init()
  rawset(params, "read", nil)
  -- the engine is loaded by now: get behind anything it put at the tail
  send("/fx/tail")
  Core.add_params()
  Core.restore()
  Core.watch_tempo()
end

function Core.post_cleanup()
  rawset(params, "read", nil)
  Core.active = false
  Core.refresh_scenes = nil
  Core.pset_file = nil
  Core.requested = nil
  Core.tempo_clock = nil -- core cancels it after this hook
  if not Core.settings.persist then
    Core.set_softcut(false)
    Core.clear_rack()
    Core.live = {}
    for _, name in ipairs(Core.names) do
      local unit = Core.units[name]
      unit.pos = nil
      if unit.mix ~= 1 then unit.mix = 1; Core.set(name, "mix", 1) end
      if unit.bypass ~= 0 then unit.bypass = 0; Core.set(name, "bypass", 0) end
    end
  end
end

return Core
