-- fx: send and insert effects rack for any script. See docs/DESIGN.md.

local mods = require 'core/mods'
local core = require 'fx/lib/core'

local mod_name = mods.this_name or "fx"

-- '~' sorts after letters: run after other mods' hooks, so the fx params land
-- at the end of the params menu and v1 plugins have finished their own setup.
local hook_name = "~" .. mod_name

mods.hook.register("system_post_startup", hook_name, function()
  core.load_settings()
  core.ensure()
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

-- the rack page, with the mod's settings as its last rows
mods.menu.register(mod_name, require 'fx/lib/page')

return core
