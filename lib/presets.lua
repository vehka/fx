-- fx presets: per-unit presets and whole-rack scenes, stored as "id": value
-- lines like a PSET.
--
--   dust/data/fx/presets/<unit>/<name>.fxp   user presets
--   <plugin>/presets/<unit>/<name>.fxp       factory presets, read-only
--   dust/data/fx/scenes/<name>.fxs           rack scenes
--
-- The preset or scene named "default" is applied when a script starts; see
-- Core.restore for the order of precedence.

local core = require 'fx/lib/core'

local Presets = {}

Presets.DEFAULT = "default"

local function root() return _path.data .. "fx/" end

local function clean(name)
  name = tostring(name or ""):gsub("[/\\]", "_"):gsub("^%.+", ""):gsub("^%s+", ""):gsub("%s+$", "")
  return name
end

local function exists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

-- names (without extension) of the files with the given extension
local function names_in(dir, ext, into)
  if not util.file_exists(dir) then return end
  for _, file in ipairs(util.scandir(dir)) do
    local name = file:match("^(.+)%." .. ext .. "$")
    if name then into[name] = true end
  end
end

local function sorted(set)
  local list = {}
  for name in pairs(set) do table.insert(list, name) end
  table.sort(list, function(a, b)
    -- default first, then alphabetical
    if a == Presets.DEFAULT or b == Presets.DEFAULT then return a == Presets.DEFAULT and b ~= a end
    return a:lower() < b:lower()
  end)
  return list
end

local function write(path, header, ids)
  local fd = io.open(path, "w+")
  if not fd then
    print("fx: cannot write " .. path)
    return false
  end
  fd:write("-- " .. header .. "\n")
  for _, id in ipairs(ids) do
    if params.lookup[id] then
      fd:write(string.format("%q: %s\n", id, tostring(params:get(id))))
    end
  end
  fd:close()
  return true
end

----------------------------------------------------------------------------
-- unit presets

local function user_dir(unit) return root() .. "presets/" .. unit.name .. "/" end

local function factory_dir(unit)
  return unit.plugin_dir and (unit.plugin_dir .. "/presets/" .. unit.name .. "/") or nil
end

function Presets.list(unit)
  local set = {}
  names_in(user_dir(unit), "fxp", set)
  if factory_dir(unit) then names_in(factory_dir(unit), "fxp", set) end
  return sorted(set)
end

--- Path of a preset: the user's file wins over a factory one of the same name.
function Presets.path(unit, name)
  local user = user_dir(unit) .. name .. ".fxp"
  if exists(user) then return user end
  local dir = factory_dir(unit)
  if dir and exists(dir .. name .. ".fxp") then return dir .. name .. ".fxp" end
  return nil
end

function Presets.is_user(unit, name)
  return exists(user_dir(unit) .. name .. ".fxp")
end

function Presets.save(unit, name)
  name = clean(name)
  if name == "" then return nil end
  util.make_dir(user_dir(unit))
  if write(user_dir(unit) .. name .. ".fxp", "fx preset: " .. unit.name, unit.param_ids or {}) then
    return name
  end
  return nil
end

function Presets.load(unit, name, silent)
  local path = Presets.path(unit, name)
  if not path then return false end
  local accept = {}
  for _, id in ipairs(unit.param_ids or {}) do accept[id] = true end
  core.read_file(path, accept, silent)
  return true
end

function Presets.delete(unit, name)
  local path = user_dir(unit) .. clean(name) .. ".fxp"
  if exists(path) then os.remove(path) return true end
  return false
end

--- Apply every unit's default preset without running actions.
function Presets.apply_defaults()
  for _, name in ipairs(core.names) do
    Presets.load(core.units[name], Presets.DEFAULT, true)
  end
end

----------------------------------------------------------------------------
-- rack scenes

local function scene_dir() return root() .. "scenes/" end

function Presets.scenes()
  local set = {}
  names_in(scene_dir(), "fxs", set)
  return sorted(set)
end

function Presets.scene_path(name)
  local path = scene_dir() .. name .. ".fxs"
  return exists(path) and path or nil
end

function Presets.save_scene(name)
  name = clean(name)
  if name == "" then return nil end
  util.make_dir(scene_dir())
  if write(scene_dir() .. name .. ".fxs", "fx scene", core.ids) then return name end
  return nil
end

--- Load a scene. Units the scene does not mention leave the rack, so the
-- result does not depend on what was loaded before.
function Presets.load_scene(name)
  local path = Presets.scene_path(name)
  if not path then return false end
  local mentioned = {}
  for line in io.lines(path) do
    local id = line:match('^"(.-)"%s*:')
    if id then mentioned[id] = true end
  end
  for _, unit_name in ipairs(core.names) do
    local unit = core.units[unit_name]
    if unit.slot_id and not mentioned[unit.slot_id] then core.place(unit_name, nil) end
  end
  core.read_file(path, core.is_fx_id, false)
  return true
end

function Presets.delete_scene(name)
  local path = scene_dir() .. clean(name) .. ".fxs"
  if exists(path) then os.remove(path) return true end
  return false
end

return Presets
