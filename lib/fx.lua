-- fx plugin API.
--
-- v2, declarative:
--
--   local fx = require 'fx/lib/fx'
--   fx.register{
--     name = "mydelay",            -- matches FxUnit.register(\mydelay, ...)
--     title = "My Delay",
--     params = {
--       { id = "time", name = "time", spec = controlspec.new(0.01, 2, 'exp', 0, 0.3, 's') },
--       { id = "mode", type = "option", options = { "clean", "tape" } },
--     },
--   }
--
-- `params` may also be a function returning that list, called when a script
-- starts. Param IDs are fx_<name>_<id> unless `param_id` is given.
-- `instances = 2` offers two copies of the effect; the second is the unit
-- <name>_2 with params fx_<name>_2_<id>. The user can change the number.
--
-- A unit whose SuperCollider side declares specs needs no Lua at all; see
-- FxUnit.sc.
--
-- v1 plugins (fx:new{subpath=...}, :add_params(), :install()) keep working.

local core = require 'fx/lib/core'

local Fx = {}

-- the plugin's directory, from the file that called the registering function;
-- factory presets are looked up under it
local function caller_dir()
  local here = debug.getinfo(1, "S").source
  for level = 2, 8 do
    local info = debug.getinfo(level, "S")
    if not info then break end
    if info.source ~= here then
      local dir = info.source:match("^@(.*)/lib/[^/]+%.lua$")
      if dir then return dir end
    end
  end
  return nil
end

Fx.slot_symbols = { "none", "sendA", "sendB", "insert" }

--- Register a v2 unit.
function Fx.register(def)
  def.plugin_dir = def.plugin_dir or caller_dir()
  return core.register(def)
end

--- Ask for a rack from a script's init. Nothing is required of the user:
--
--   local ok, fx = pcall(require, 'fx/lib/fx')
--   if ok then
--     fx.request{
--       insert = { "mydelay", { "drive", mix = 0.4, gain = 2 } },
--       a = { "reverb" },
--       params = { fx_send_a_level = 0.3 },
--     }
--   end
--
-- Each chain (insert, a, b) is a list of effects in slot order: a name, or a
-- table of the name and values for its dry/wet (`mix`), `bypass` and own
-- params. Naming an effect twice uses a second copy if there is one. `params`
-- sets any fx param by id. A string instead of a table names a saved rack.
--
-- It is a request: the fx values of the PSET the script loads win, and so
-- does a rack the user already has running (with "keep rack" on), unless the
-- table has `replace = true`. Effects that are not installed are skipped.
-- Returns false when the mod is not enabled or the request was not applied.
function Fx.request(spec)
  return core.request(spec)
end

----------------------------------------------------------------------------
-- v1 API

function Fx:new(o)
  o = o or {}
  setmetatable(o, self)
  self.__index = self
  if type(o.subpath) == "string" then
    o.unit = core.register{ name = o.subpath:gsub("^/", ""), legacy = o, plugin_dir = caller_dir() }
  end
  return o
end

-- v1 plugins call this from script_pre_init to wrap the script's init. The
-- mod now adds every registered unit's params itself at script_post_init.
function Fx:install() end

function Fx:add_params() end

local function bind(self, id, key)
  local name = self.unit.name
  self.unit.param_key[key] = id
  core.bind(id, function(value) core.set(name, key, value) end, self.unit)
end

function Fx:add_control(id, name, key, spec, formatter)
  params:add_control(id, name, spec, formatter)
  bind(self, id, key)
end

function Fx:add_taper(id, name, key, min, max, default, k, units)
  params:add_taper(id, name, min, max, default, k, units)
  bind(self, id, key)
end

function Fx:add_option(id, name, key, options, default)
  params:add_option(id, name, options, default)
  bind(self, id, key)
end

function Fx:add_binary(id, name, key, behavior, default)
  params:add_binary(id, name, behavior, default)
  bind(self, id, key)
end

function Fx:add_slot(id, name)
  core.add_slot_params(self.unit, id, name, id .. "_drywet")
end

return Fx
