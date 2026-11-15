-- fx: send and insert effects rack for any script. See docs/DESIGN.md.

local mods = require 'core/mods'
local core = require 'fx/lib/core'

local mod_name = mods.this_name or "fx"

-- '~' sorts after letters: run after other mods' hooks, so the fx params land
-- at the end of the params menu and v1 plugins have finished their own setup.
local hook_name = "~" .. mod_name

mods.hook.register("system_post_startup", hook_name, function()
  core.load_settings()
  core.load_units_file()
  core.ensure()
  core.watch_tempo()
end)

mods.hook.register("script_pre_init", hook_name, function()
  core.pre_init()
end)

mods.hook.register("script_post_init", hook_name, function()
  core.post_init()
end)

mods.hook.register("script_post_cleanup", hook_name, function()
  core.post_cleanup()
end)

-- norns 3.x only: core resets the JACK routes when a script ends, and softcut
-- may be patched through the rack. Older versions have neither the routing
-- functions nor this hook, and softcut stays out of the rack there.
if core.softcut_available() then
  core.wrap_eng_cut()
  pcall(mods.hook.register, "audio_post_restore_default_routing", hook_name, function()
    core.restore_routing()
  end)
end

core.enabled = true

-- the rack page, with the mod's settings as its last rows
mods.menu.register(mod_name, require 'fx/lib/page')

return core
