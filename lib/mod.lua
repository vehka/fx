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

----------------------------------------------------------------------------
-- settings page

local menu = {}
local row = 1

function menu.init() end

function menu.deinit()
  core.save_settings()
end

function menu.key(n, z)
  if n == 2 and z == 1 then mods.menu.exit() end
end

function menu.enc(n, d)
  if n == 2 then
    row = util.clamp(row + d, 1, 2)
  elseif n == 3 then
    if row == 1 then
      core.settings.persist = d > 0
    else
      core.set_fade(core.settings.fade + d * 0.01)
    end
  end
  mods.menu.redraw()
end

function menu.redraw()
  screen.clear()
  screen.level(15)
  screen.move(0, 10)
  screen.text("fx")
  local rows = {
    { "keep rack across scripts", core.settings.persist and "on" or "off" },
    { "fade time", string.format("%.2f s", core.settings.fade) },
  }
  for i, r in ipairs(rows) do
    screen.level(i == row and 15 or 4)
    screen.move(0, 20 + i * 10)
    screen.text(r[1])
    screen.move(127, 20 + i * 10)
    screen.text_right(r[2])
  end
  screen.level(4)
  screen.move(0, 62)
  screen.text("E2 select  E3 change  K2 back")
  screen.update()
end

mods.menu.register(mod_name, menu)

return core
