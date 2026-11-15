-- fx rack page (SYSTEM > MODS > fx): the rack in signal order with meters
-- and CPU, saved racks, and the mod's two settings.
--
--   E2        select a row
--   E3        the row's value: dry/wet of an insert, a level, a setting
--   K3        bypass an effect; load or save a rack
--   K1 + E2   move the effect within its chain
--   K1 + E3   scroll through the effects; releasing K1 loads the one shown
--   K1 + K3   open the row: an effect's params, a send's or the input's routing
--   K2        back
--
-- In an opened row E2 selects a param, E3 changes it, K3 toggles a switch
-- and K2 goes back to the rack.
--
-- The page is a second view of the same state as the params menu. It reads
-- the core's model and changes it through the core and the params, so the
-- two views, PSETs and SC stay in step. The rack itself, dry/wet and bypass
-- work with no script loaded; rows that are params need a running script.

local mods = require 'core/mods'
local core = require 'fx/lib/core'
local presets = require 'fx/lib/presets'

local Page = {}

local VISIBLE = 6
local ROW_Y, ROW_H = 17, 9
local NAME_X, VALUE_X = 24, 100
local METER_X, METER_TOP, METER_BOTTOM = 106, 12, 54
local METER_FLOOR = -48 -- dB at the bottom of a meter
local NEEDS_SCRIPT = "needs a running script"

local rows = {}
local selected = 1
local alt = false     -- K1 held
local candidate = nil -- index into choices while scrolling with K1 + E3
local choices = {}    -- false (none), then unit names
local detail = nil    -- the opened row: { title, ids, selected }
local scene = nil     -- the rack last loaded or saved here
local scene_pick = nil
local note = nil      -- a message in the title line until the next input
local modal = false   -- textentry has the screen
local open = false
local meter = { 0, 0, 0, 0 }
local cpu = { 0, 0 }

----------------------------------------------------------------------------
-- rows

local function slot_rows(chain_id)
  for _, c in ipairs(core.chains) do
    if c.id == chain_id then
      local short = c.id == "insert" and "ins" or c.id
      for i = 1, c.size do
        table.insert(rows, { kind = "slot", chain = c.id, index = i, size = c.size, label = short .. " " .. i })
      end
    end
  end
end

table.insert(rows, { kind = "param", label = "input", id = "fx_input_level",
  ids = { "fx_input_level", "fx_input_mode" } })
slot_rows("insert")
for _, s in ipairs(core.sends) do
  local prefix = "fx_send_" .. s
  local ids = { prefix .. "_level", prefix .. "_tap", prefix .. "_return", prefix .. "_dest" }
  for _, other in ipairs(core.sends) do
    if other ~= s then table.insert(ids, prefix .. "_to_" .. other) end
  end
  table.insert(rows, { kind = "param", label = "send " .. s, id = prefix .. "_level", ids = ids })
  slot_rows(s)
end
table.insert(rows, { kind = "scene", label = "rack" })
table.insert(rows, { kind = "save", label = "save rack..." })
table.insert(rows, {
  kind = "setting", label = "keep rack",
  value = function() return core.settings.persist and "on" or "off" end,
  delta = function(d) core.settings.persist = d > 0 end,
})
table.insert(rows, {
  kind = "setting", label = "fade",
  value = function() return string.format("%.2f s", core.settings.fade) end,
  delta = function(d) core.set_fade(core.settings.fade + d * 0.01) end,
})

local function find_row(label)
  for i, row in ipairs(rows) do
    if row.label == label then return i end
  end
end
selected = find_row("ins 1")

local function occupant(row)
  return row.kind == "slot" and core.rack[row.chain][row.index] or nil
end

local function label_of(name)
  return name and core.units[name].label or "-"
end

local function step(d) return d > 0 and 1 or -1 end

----------------------------------------------------------------------------
-- params, which exist only while a script runs

local function has(id)
  return core.active and params.lookup[id] ~= nil
end

local function is_switch(id)
  local p = params:lookup_param(id)
  return p.t == params.tBINARY and p.behavior == "toggle"
end

local function value_text(id)
  if not has(id) then return "-" end
  if is_switch(id) then return params:get(id) > 0 and "on" or "off" end
  return tostring(params:string(id))
end

local function change(id, d)
  if not has(id) then
    note = NEEDS_SCRIPT
  elseif is_switch(id) then
    params:set(id, d > 0 and 1 or 0)
  else
    params:delta(id, d)
  end
end

--- Open a row: the list of its params that exist and are shown.
local function open_detail(row)
  local title, ids = row.label, row.ids
  if row.kind == "slot" then
    local name = occupant(row)
    if not name then return end
    local unit = core.units[name]
    title = row.label .. " " .. unit.label
    ids = { unit.bypass_id }
    for _, id in ipairs(unit.param_ids or {}) do table.insert(ids, id) end
  end
  if not ids then return end
  local shown = {}
  for _, id in ipairs(ids) do
    if has(id) and params:visible(id) then table.insert(shown, id) end
  end
  if #shown == 0 then
    note = NEEDS_SCRIPT
  else
    detail = { title = title, ids = shown, selected = 1 }
  end
end

----------------------------------------------------------------------------
-- saved racks (scenes). A rack file holds every fx param: slots, order,
-- sends, input and each effect's own values.

local function scene_list()
  return presets.scenes()
end

local function scene_shown()
  local list = scene_list()
  return scene_pick and list[scene_pick] or scene
end

local function scene_index(list, name)
  for i, v in ipairs(list) do
    if v == name then return i end
  end
  return nil
end

local function load_scene()
  local name = scene_shown()
  if not core.active then
    note = NEEDS_SCRIPT
  elseif name and presets.load_scene(name) then
    scene, scene_pick = name, nil
    note = "loaded " .. name
  end
end

local function save_scene()
  if not core.active then
    note = NEEDS_SCRIPT
    return
  end
  modal = true
  require('textentry').enter(function(text)
    modal = false
    if text and text ~= "" then
      local name = presets.save_scene(text)
      if name then
        scene, scene_pick = name, nil
        note = "saved " .. name
        -- the scene row of the fx presets params group
        if core.refresh_scenes then core.refresh_scenes(name) end
      end
    end
    mods.menu.redraw()
  end, scene_shown() or "", "rack name")
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
      if not modal then mods.menu.redraw() end
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
  if candidate and row.kind == "slot" then
    local name = choices[candidate] or nil
    if name ~= occupant(row) then core.set_row(row.chain, row.index, name) end
  end
  candidate = nil
end

-- The menu passes a long K1 press on only after a delay, but treats K1 as
-- held from the moment it goes down. _menu.alt is that state; it is not a
-- documented interface, so the page works without it, just less promptly.
local function held()
  return alt or (_menu ~= nil and _menu.alt == true)
end

function Page.init()
  open = true
  alt, candidate, detail, scene_pick, note, modal = false, nil, nil, nil, nil, false
  build_choices()
  listen()
  osc.send(core.SC, "/fx/meter", { 1 })
end

function Page.deinit()
  open = false
  alt, candidate, detail = false, nil, nil
  osc.send(core.SC, "/fx/meter", { 0 })
  unlisten()
  core.save_settings()
end

--- Put the cursor on a row by its label. For scripts and tests.
function Page.select(label)
  selected = assert(find_row(label), "no row " .. label)
  candidate, scene_pick = nil, nil
end

local function detail_key(n, z)
  if z ~= 1 then return end
  if n == 2 then
    detail = nil
  elseif n == 3 then
    if held() then
      detail = nil
    else
      local id = detail.ids[detail.selected]
      if has(id) and is_switch(id) then params:set(id, 1 - params:get(id)) end
    end
  end
end

function Page.key(n, z)
  listen()
  note = nil
  if n == 1 then
    alt = z == 1
    if z == 0 then apply_candidate() end
  elseif detail then
    detail_key(n, z)
  elseif n == 2 and z == 1 then
    mods.menu.exit()
    return
  elseif n == 3 and z == 1 then
    local row = rows[selected]
    if held() then
      candidate = nil
      open_detail(row)
    elseif row.kind == "slot" then
      local name = occupant(row)
      if name then core.set_bypass(name, core.units[name].bypass == 0) end
    elseif row.kind == "scene" then
      load_scene()
    elseif row.kind == "save" then
      save_scene()
      return
    end
  end
  mods.menu.redraw()
end

local function list_enc(n, d)
  local row = rows[selected]
  if held() and row.kind == "slot" then
    if n == 2 and occupant(row) then
      local to = util.clamp(row.index + step(d), 1, row.size)
      if to ~= row.index then
        candidate = nil
        core.swap(row.chain, row.index, to)
        selected = selected + (to - row.index)
      end
    elseif n == 3 then
      candidate = candidate or choice_index(occupant(row))
      candidate = util.clamp(candidate + step(d), 1, #choices)
    end
  elseif n == 2 then
    candidate, scene_pick = nil, nil
    selected = util.clamp(selected + step(d), 1, #rows)
  elseif n == 3 then
    if row.kind == "setting" then
      row.delta(d)
    elseif row.kind == "param" then
      change(row.id, d)
    elseif row.kind == "scene" then
      local list = scene_list()
      if #list > 0 then
        scene_pick = util.clamp((scene_pick or scene_index(list, scene) or 0) + step(d), 1, #list)
      end
    elseif row.chain == "insert" and occupant(row) then
      local name = occupant(row)
      core.set_mix(name, core.units[name].mix + d * 0.01)
    end
  end
end

function Page.enc(n, d)
  listen()
  note = nil
  if detail then
    if n == 2 then
      detail.selected = util.clamp(detail.selected + step(d), 1, #detail.ids)
    elseif n == 3 then
      change(detail.ids[detail.selected], d)
    end
  else
    list_enc(n, d)
  end
  mods.menu.redraw()
end

----------------------------------------------------------------------------
-- drawing

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

local function window(count, cursor)
  return util.clamp(cursor - 2, 1, math.max(1, count - VISIBLE + 1))
end

local function draw_row(line, here, label, value, dim)
  local y = ROW_Y + (line - 1) * ROW_H
  screen.level(dim and (here and 6 or 2) or (here and 15 or 4))
  screen.move(0, y)
  screen.text(label)
  if value then
    screen.move(VALUE_X, y)
    screen.text_right(value)
  end
end

local function draw_slot(line, here, row)
  local y = ROW_Y + (line - 1) * ROW_H
  local name = occupant(row)
  local unit = name and core.units[name]
  local bypassed = unit and unit.bypass ~= 0
  screen.level(here and 15 or 4)
  screen.move(0, y)
  screen.text(row.label)
  local text = label_of(name)
  if here and candidate and (choices[candidate] or nil) ~= name then
    text = label_of(choices[candidate] or nil) .. " ?"
  end
  screen.level(bypassed and (here and 6 or 2) or (here and 15 or 4))
  screen.move(NAME_X, y)
  screen.text(string.sub(text, 1, 14))
  screen.move(VALUE_X, y)
  if bypassed then
    screen.text_right("byp")
  elseif unit and row.chain == "insert" then
    screen.text_right(util.round(unit.mix * 100))
  end
end

local function draw_list()
  local top = window(#rows, selected)
  for line = 1, math.min(VISIBLE, #rows) do
    local i = top + line - 1
    local row = rows[i]
    local here = i == selected
    if row.kind == "slot" then
      draw_slot(line, here, row)
    elseif row.kind == "param" then
      draw_row(line, here, row.label, value_text(row.id), not has(row.id))
    elseif row.kind == "scene" then
      local name = scene_shown()
      local pending = here and scene_pick and name ~= scene
      draw_row(line, here, row.label, (name or "-") .. (pending and " ?" or ""), not core.active)
    elseif row.kind == "save" then
      draw_row(line, here, row.label, nil, not core.active)
    else
      draw_row(line, here, row.label, row.value())
    end
  end
end

local function draw_detail()
  local top = window(#detail.ids, detail.selected)
  for line = 1, math.min(VISIBLE, #detail.ids) do
    local i = top + line - 1
    local id = detail.ids[i]
    local name = has(id) and params:lookup_param(id).name or id
    draw_row(line, i == detail.selected, string.sub(name, 1, 13), string.sub(value_text(id), 1, 9))
  end
end

function Page.redraw()
  screen.clear()
  local title, bright = "FX RACK", false
  if note then
    title, bright = note, true
  elseif detail then
    title, bright = detail.title, true
  elseif alt then
    title, bright = "E2 move E3 load K3 open", true
  end
  screen.level(bright and 15 or 4)
  screen.move(0, 7)
  screen.text(title)
  if not bright then
    screen.level(4)
    screen.move(127, 7)
    screen.text_right(string.format("cpu %d/%d%%", util.round(cpu[1]), util.round(cpu[2])))
  end
  if detail then draw_detail() else draw_list() end
  draw_meters()
  screen.update()
end

return Page
