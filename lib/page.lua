-- fx rack page (SYSTEM > MODS > fx): the slots in signal order, bypass,
-- dry/wet, meters and CPU, then the mod's two settings.
--
--   E2        select a row
--   E3        dry/wet of an insert; the value of a setting
--   K3        bypass
--   K1 + E2   move the effect within its chain
--   K1 + E3   scroll through the effects; releasing K1 loads the one shown
--   K2        back
--
-- Everything goes through the core, so the params menu, PSETs and the live
-- state stay in step, and the page works with no script loaded.

local mods = require 'core/mods'
local core = require 'fx/lib/core'

local Page = {}

local VISIBLE = 6
local ROW_Y, ROW_H = 17, 9
local VALUE_X = 100
local METER_X, METER_TOP, METER_BOTTOM = 106, 12, 54
local METER_FLOOR = -48 -- dB at the bottom of a meter

local rows = {}       -- slot rows, then setting rows
local selected = 1
local alt = false     -- K1 held
local candidate = nil -- index into choices while scrolling with K1 + E3
local choices = {}    -- false (none), then unit names
local open = false
local meter = { 0, 0, 0, 0 }
local cpu = { 0, 0 }

for _, c in ipairs(core.chains) do
  local short = c.id == "insert" and "ins" or c.id
  for i = 1, c.size do
    table.insert(rows, { chain = c.id, index = i, size = c.size, label = short .. " " .. i })
  end
end
table.insert(rows, {
  label = "keep rack",
  value = function() return core.settings.persist and "on" or "off" end,
  delta = function(d) core.settings.persist = d > 0 end,
})
table.insert(rows, {
  label = "fade",
  value = function() return string.format("%.2f s", core.settings.fade) end,
  delta = function(d) core.set_fade(core.settings.fade + d * 0.01) end,
})

local function occupant(row)
  return row.chain and core.rack[row.chain][row.index] or nil
end

local function label_of(name)
  return name and core.units[name].label or "-"
end

----------------------------------------------------------------------------
-- meters: SC sends /fx/meter while the page is open, and each message
-- redraws the page, so there is no timer of our own.

local previous -- the script's osc.event, if it has one

local function on_osc(path, args, from)
  if path == "/fx/meter" then
    if open then
      for i = 1, 4 do meter[i] = tonumber(args[i]) or 0 end
      cpu[1], cpu[2] = tonumber(args[5]) or 0, tonumber(args[6]) or 0
      mods.menu.redraw()
    end
  elseif previous then
    previous(path, args, from)
  end
end

-- osc.event is one slot that belongs to the script: chain what is there, and
-- look again on every input in case a script was started meanwhile.
local function listen()
  if osc.event ~= on_osc then
    previous = osc.event
    osc.event = on_osc
  end
end

local function unlisten()
  if osc.event == on_osc then
    osc.event = previous
    previous = nil
  end
end

----------------------------------------------------------------------------
-- menu callbacks

local function build_choices()
  choices = { false }
  local names = {}
  for _, name in ipairs(core.names) do table.insert(names, name) end
  table.sort(names, function(a, b) return core.units[a].label < core.units[b].label end)
  for _, name in ipairs(names) do table.insert(choices, name) end
end

local function choice_index(name)
  for i, v in ipairs(choices) do
    if v == (name or false) then return i end
  end
  return 1
end

local function apply_candidate()
  local row = rows[selected]
  if candidate and row.chain then
    local name = choices[candidate] or nil
    if name ~= occupant(row) then core.set_row(row.chain, row.index, name) end
  end
  candidate = nil
end

function Page.init()
  open = true
  alt = false
  candidate = nil
  build_choices()
  listen()
  osc.send(core.SC, "/fx/meter", { 1 })
end

function Page.deinit()
  open = false
  alt = false
  candidate = nil
  osc.send(core.SC, "/fx/meter", { 0 })
  unlisten()
  core.save_settings()
end

function Page.key(n, z)
  listen()
  local row = rows[selected]
  if n == 1 then
    alt = z == 1
    if z == 0 then apply_candidate() end
  elseif n == 2 and z == 1 then
    mods.menu.exit()
    return
  elseif n == 3 and z == 1 and not alt then
    local name = occupant(row)
    if name then core.set_bypass(name, core.units[name].bypass == 0) end
  end
  mods.menu.redraw()
end

function Page.enc(n, d)
  listen()
  local row = rows[selected]
  -- The menu passes a long K1 press on only after a delay, but treats K1 as
  -- held from the moment it goes down. _menu.alt is that state; it is not a
  -- documented interface, so the page works without it, just less promptly.
  local held = alt or (_menu ~= nil and _menu.alt == true)
  if held and row.chain then
    if n == 2 and occupant(row) then
      local to = util.clamp(row.index + (d > 0 and 1 or -1), 1, row.size)
      if to ~= row.index then
        candidate = nil
        core.swap(row.chain, row.index, to)
        selected = selected + (to - row.index)
      end
    elseif n == 3 then
      candidate = candidate or choice_index(occupant(row))
      candidate = util.clamp(candidate + (d > 0 and 1 or -1), 1, #choices)
    end
  elseif n == 2 then
    candidate = nil
    selected = util.clamp(selected + (d > 0 and 1 or -1), 1, #rows)
  elseif n == 3 then
    if row.delta then
      row.delta(d)
    elseif row.chain == "insert" and occupant(row) then
      local name = occupant(row)
      core.set_mix(name, core.units[name].mix + d * 0.01)
    end
  end
  mods.menu.redraw()
end

local function draw_meters()
  local height = METER_BOTTOM - METER_TOP
  for i = 1, 4 do
    local x = METER_X + (i - 1) * 6
    local amp = meter[i]
    local db = amp > 0 and 20 * math.log(amp, 10) or METER_FLOOR
    local h = util.round(util.clamp((db - METER_FLOOR) / -METER_FLOOR, 0, 1) * height)
    screen.level(1)
    screen.rect(x, METER_TOP, 3, height)
    screen.fill()
    if h > 0 then
      screen.level(amp >= 1 and 15 or 6)
      screen.rect(x, METER_BOTTOM - h, 3, h)
      screen.fill()
    end
    screen.level(3)
    screen.move(x + 2, 62)
    screen.text_center(({ "i", "a", "b", "o" })[i])
  end
end

function Page.redraw()
  screen.clear()
  screen.level(alt and 15 or 4)
  screen.move(0, 7)
  screen.text(alt and "E2 move  E3 load" or "FX RACK")
  screen.level(4)
  screen.move(127, 7)
  screen.text_right(string.format("cpu %d/%d%%", util.round(cpu[1]), util.round(cpu[2])))

  local top = util.clamp(selected - 2, 1, #rows - VISIBLE + 1)
  for line = 1, VISIBLE do
    local i = top + line - 1
    local row = rows[i]
    local y = ROW_Y + (line - 1) * ROW_H
    local here = i == selected
    local name = occupant(row)
    local unit = name and core.units[name]
    local bypassed = unit and unit.bypass ~= 0
    screen.level(here and 15 or 4)
    screen.move(0, y)
    screen.text(row.label)
    if row.chain then
      local text = label_of(name)
      if here and candidate and (choices[candidate] or nil) ~= name then
        text = label_of(choices[candidate] or nil) .. " ?"
      end
      screen.level(bypassed and (here and 6 or 2) or (here and 15 or 4))
      screen.move(24, y)
      screen.text(string.sub(text, 1, 14))
      screen.move(VALUE_X, y)
      if bypassed then
        screen.text_right("byp")
      elseif unit and row.chain == "insert" then
        screen.text_right(util.round(unit.mix * 100))
      end
    else
      screen.move(VALUE_X, y)
      screen.text_right(row.value())
    end
  end

  draw_meters()
  screen.update()
end

return Page
