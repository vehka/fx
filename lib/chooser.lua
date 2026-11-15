-- A params-menu row that is scrolled with E3 and applied with K3.
--
-- The stock menu applies an option param on every encoder step. For choices
-- that load or move an effect that is wrong: scrolling past an entry would
-- load it. The menu does call a trigger param's set() on K3 and passes E3 to
-- any non-binary param's delta(), so a Chooser presents itself as a trigger:
-- delta() only moves the candidate, set() applies it.
--
-- A trigger row shows no value, so the choice is part of the row's name:
--
--   insert 1: delay        applied
--   insert 1: grains ?     scrolled to, not applied yet; K3 applies
--
-- Like any trigger it is not saved in PSETs and cannot be MIDI-mapped.

local Chooser = {}
Chooser.__index = Chooser

local tTRIGGER = 6

--- @param id param id
-- @param label left part of the row name
-- @param options list of display strings
-- @param on_apply function(index), called when K3 applies a changed choice
function Chooser.new(id, label, options, on_apply)
  local o = setmetatable({}, Chooser)
  o.t = tTRIGGER
  o.id = id
  o.label = label
  o.options = options
  o.count = #options
  o.current = 1   -- what is applied
  o.selected = 1  -- what the row shows
  o.on_apply = on_apply
  o.action = function() end
  o.allow_pmap = false
  o:rename()
  return o
end

function Chooser:pending()
  return self.selected ~= self.current
end

function Chooser:rename()
  self.name = self.label .. ": " .. self.options[self.selected] .. (self:pending() and " ?" or "")
end

--- E3: move the candidate. Nothing is applied.
function Chooser:delta(d)
  if d == 0 then return end
  local step = d > 0 and 1 or -1
  self.selected = math.max(1, math.min(self.count, self.selected + step))
  self:rename()
end

--- K3: apply the candidate.
function Chooser:set()
  if self:pending() then self.on_apply(self.selected) end
  -- the owner calls show() from on_apply; if it refused, fall back
  self:rename()
end

--- Make the row show what is actually applied.
function Chooser:show(index)
  self.current = index
  self.selected = index
  self:rename()
end

--- Move the candidate to an option by its text. For scripts and tests.
function Chooser:choose(text)
  for i, v in ipairs(self.options) do
    if v == text then
      self.selected = i
      self:rename()
      return true
    end
  end
  return false
end

function Chooser:get() return nil end
function Chooser:string() return self.options[self.selected] end
function Chooser:set_default() end
function Chooser:bang() end

return Chooser
