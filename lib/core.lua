-- fx core: unit registry, rack model, params and the OSC link to FxRack.
-- The rack model here is the source of truth; SuperCollider executes it.
-- See docs/DESIGN.md.

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
Core.settings = { persist = true, fade = 0.05 }

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
  Core.units[unit.name] = unit
  return unit
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
-- An occupant moves to the first free slot of the chain, or out if it is full.
function Core.place(name, chain_id, index)
  local before = snapshot()
  local old_chain, old_index = Core.locate(name)
  if old_chain == chain_id and old_index == index then return end
  if old_chain then Core.rack[old_chain][old_index] = nil end
  if chain_id then
    local occupant = Core.rack[chain_id][index]
    Core.rack[chain_id][index] = name
    if occupant then
      local free = first_free(chain_id)
      if free then Core.rack[chain_id][free] = occupant end
    end
  end
  commit(before)
end

--- Put a unit somewhere in a chain: its remembered position, else the first
-- free slot, else the last slot.
function Core.place_in_chain(name, chain_id)
  local old_chain = Core.locate(name)
  if old_chain == chain_id then return end
  if chain_id == nil then
    Core.place(name, nil)
    return
  end
  local c = chain_by_id[chain_id]
  local unit = Core.units[name]
  local want = unit and unit.pos or 0
  local index
  if want >= 1 and want <= c.size then
    index = want
  else
    index = first_free(chain_id) or c.size
  end
  Core.place(name, chain_id, index)
end

function Core.clear_rack()
  for _, c in ipairs(Core.chains) do Core.rack[c.id] = {} end
  send("/fx/clear")
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

--- Register an fx param: its action also records the live value.
function Core.bind(id, action)
  if not Core.is_fx_id[id] then
    Core.is_fx_id[id] = true
    table.insert(Core.ids, id)
  end
  params:set_action(id, function(value)
    Core.live[id] = value
    if action then action(value) end
  end)
end

--- Make the rack view, the per-unit slot/position params and mix visibility
-- reflect the model, without firing actions.
function Core.sync_params()
  if not Core.active then return end
  local rebuild = false
  for _, c in ipairs(Core.chains) do
    for i = 1, c.size do
      local name = Core.rack[c.id][i]
      quiet_set(c.prefix .. i, name and option_index(Core.view_names, name) or 1)
    end
  end
  for _, name in ipairs(Core.names) do
    local unit = Core.units[name]
    local chain_id, index = Core.locate(name)
    if unit.slot_id then
      quiet_set(unit.slot_id, chain_id and Core.chain_slot[chain_id] or 1)
    end
    if chain_id then
      unit.pos = index
      quiet_set("fx_pos_" .. name, index)
    end
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

--- The slot option and the dry/wet control every unit has. Exactly two
-- params, as in v1, so plugin group sizes stay correct.
function Core.add_slot_params(unit, slot_id, slot_name, mix_id)
  unit.slot_id = slot_id
  unit.mix_id = mix_id
  params:add_option(slot_id, slot_name, Core.slot_options, 1)
  Core.bind(slot_id, function(value)
    Core.place_in_chain(unit.name, Core.slot_chain[value] or nil)
  end)
  params:add_control(mix_id, "dry/wet", controlspec.new(0, 1, 'lin', 0, 1), display_mix)
  Core.bind(mix_id, function(value) Core.set(unit.name, "mix", value) end)
  params:hide(mix_id)
end

local function add_native_param(unit, p)
  local id = p.param_id or ("fx_" .. unit.name .. "_" .. p.id)
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
  Core.bind(id, function(value) Core.set(unit.name, p.id, value) end)
end

local function add_native_unit(unit)
  local list = unit.params
  if type(list) == "function" then list = list() end
  list = list or {}
  local prefix = "fx_" .. unit.name
  params:add_group(prefix, unit.title or unit.label, #list + 3)
  Core.add_slot_params(unit, prefix .. "_slot", "slot", prefix .. "_mix")
  params:add_binary(prefix .. "_bypass", "bypass", "toggle", 0)
  Core.bind(prefix .. "_bypass", function(value) Core.set(unit.name, "bypass", value) end)
  for _, p in ipairs(list) do add_native_param(unit, p) end
end

local function add_rack_params()
  local slots = 0
  for _, c in ipairs(Core.chains) do slots = slots + c.size end
  params:add_group("fx_rack", "fx rack", slots + #Core.names)

  Core.view_names = { "none" }
  local labels = { "none" }
  for _, name in ipairs(Core.names) do
    table.insert(Core.view_names, name)
    table.insert(labels, Core.units[name].label)
  end

  -- a view of the model for editing order; the option list depends on what is
  -- installed, so it is not saved. Slot + position per unit are saved instead.
  for _, c in ipairs(Core.chains) do
    for i = 1, c.size do
      local id = c.prefix .. i
      params:add_option(id, c.label .. " " .. i, labels, 1)
      params:lookup_param(id).save = false
      params:set_action(id, function(value)
        local name = Core.view_names[value]
        if name == nil or name == "none" then
          local occupant = Core.rack[c.id][i]
          if occupant then Core.place(occupant, nil) end
        else
          Core.place(name, c.id, i)
        end
      end)
    end
  end

  for _, name in ipairs(Core.names) do
    local id = "fx_pos_" .. name
    local unit = Core.units[name]
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

local function add_send_params()
  params:add_group("fx_sends", "fx sends", #Core.sends * 4)
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
  end
end

function Core.add_params()
  Core.ids = {}
  Core.is_fx_id = {}
  table.sort(Core.names)
  params:add_separator("fx_mod", "fx")
  add_rack_params()
  add_send_params()
  for _, name in ipairs(Core.names) do
    local unit = Core.units[name]
    unit.slot_id, unit.mix_id = nil, nil
    local ok, err
    if unit.legacy then
      ok, err = pcall(unit.legacy.add_params, unit.legacy)
    else
      ok, err = pcall(add_native_unit, unit)
    end
    if not ok then print("fx: adding params for " .. name .. " failed: " .. tostring(err)) end
  end
  Core.active = true
end

----------------------------------------------------------------------------
-- restoring values

-- read only the fx params from a PSET file, running their actions
local function read_fx_params(filename)
  local fd = io.open(filename, "r")
  if not fd then return false end
  io.close(fd)
  for line in io.lines(filename) do
    local id, value = string.match(line, "(\".-\")%s*:%s*(.*)")
    if id and value then
      id = id:gsub('^"', ''):gsub('"$', '')
      local index = params.lookup[id]
      local number = tonumber(value)
      if Core.is_fx_id[id] and index and number then
        local p = params.params[index]
        if not (p.t == params.tBINARY and p.behavior == "trigger") then
          params:set(id, number)
        end
      end
    end
  end
  return true
end

local function bang_fx_params()
  for _, id in ipairs(Core.ids) do
    local p = params:lookup_param(id)
    if not (p.t == params.tBINARY and p.behavior == "trigger") then p:bang() end
  end
end

--- Give the new script's fx params their values and make SC match.
function Core.restore()
  local have_live = Core.settings.persist and next(Core.live) ~= nil
  if have_live then
    -- station mode: the rack kept running; params take the live values
    for _, id in ipairs(Core.ids) do
      local value = Core.live[id]
      if value ~= nil then params:set(id, value, true) end
    end
  elseif Core.pset_file then
    read_fx_params(Core.pset_file)
  end
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
end

function Core.pre_init()
  Core.ensure()
  Core.pset_file = nil
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
  Core.add_params()
  Core.restore()
end

function Core.post_cleanup()
  rawset(params, "read", nil)
  Core.active = false
  Core.pset_file = nil
  if not Core.settings.persist then
    Core.clear_rack()
    Core.live = {}
    for _, name in ipairs(Core.names) do Core.units[name].pos = nil end
  end
end

return Core
