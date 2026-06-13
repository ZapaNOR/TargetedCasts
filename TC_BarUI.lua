local ADDON_NAME = ...
local M = _G[ADDON_NAME]
if not M then return end

local BU = {}
M.BarUI = BU

local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

local CreateFrame = CreateFrame
local UnitCastingInfo = UnitCastingInfo
local UnitChannelInfo = UnitChannelInfo
local GetTime = GetTime

local PREVIEW_TEXTURE   = 135846 -- Frostbolt-style placeholder
local PREVIEW_TEXTURE_2 = 135826 -- Pyroblast-ish secondary placeholder

-- Sub-pixel nudge on the container's anchor; forces non-integer screen
-- coords so 1px borders don't land on pixel boundaries (blurry at scale).
-- Stripped before persisting so reload + drag doesn't accumulate the shift.
local PIXEL_OFFSET = 0.1

local container
local barPool = {}        -- pool of bar Frames
local activeBars = {}     -- [unit] = bar in use
local liveCasts = {}      -- [unit] = { texture, spellName, durObj, channeling, spawnedAt }
local previewBar, previewBar2
local previewVisible = false

-- Forward declared because the createContainer OnUpdate closure references
-- it; in Lua a name resolves at parse time, so a `local function` defined
-- later would silently bind to a (nil) global instead of the upvalue.
local anchorBar

local function S()
  return M.DB and M:DB() or nil
end

local function safeNumber(v, fallback)
  return (type(v) == "number") and v or fallback
end

local function getIconSize()
  local s = S()
  return safeNumber(s and s.iconSize, 32)
end

local function getBarWidth()
  local s = S()
  return safeNumber(s and s.barWidth, 220)
end

local function getFgTexture()
  local s = S()
  local key = s and s.fgTexture or "Blizzard"
  if LSM and LSM.Fetch then
    local fetched = LSM:Fetch("statusbar", key, true)
    if fetched then return fetched end
  end
  return "Interface\\Buttons\\WHITE8X8"
end

local function getFontPath()
  local s = S()
  local key = s and s.fontFace or "Expressway"
  if LSM and LSM.Fetch then
    local fetched = LSM:Fetch("font", key, true)
    if fetched then return fetched end
  end
  return STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
end

local function getFontSize()
  local s = S()
  return safeNumber(s and s.fontSize, 14)
end

local function getFontOutline()
  local s = S()
  local v = s and s.fontOutline
  -- DB stores "" for "none"; SetFont wants nil for the same.
  if v == nil or v == "" then return nil end
  return v
end

local function getFontShadow()
  local s = S()
  return s and s.fontShadow == true
end

local function getFgColor()
  local s = S()
  local c = s and s.fgColor or M.Defaults.fgColor
  return c.r, c.g, c.b, c.a or 1
end

local function getBgColor()
  local s = S()
  local c = s and s.bgColor or M.Defaults.bgColor
  return c.r, c.g, c.b, c.a or 1
end

local function getGrowDirection()
  local s = S()
  return (s and s.growDirection) or "UP"
end

local function getFillMode()
  local s = S()
  return (s and s.fillMode) or "FILL"
end

local function getGap()
  local s = S()
  return safeNumber(s and s.gap, 2)
end

local function getPosition()
  local s = S()
  return (s and s.position) or M.Defaults.position
end

local function savePosition()
  if not container then return end
  local s = S()
  if not s then return end
  local point, _, _, x, y = container:GetPoint(1)
  -- Strip the render-time PIXEL_OFFSET so saved coords stay "logical".
  s.position = {
    point = point,
    x = (x or 0) - PIXEL_OFFSET,
    y = (y or 0) - PIXEL_OFFSET,
  }
  -- Sync the settings panel sliders if they're alive (AceGUI SetValue
  -- doesn't fire OnValueChanged, so no callback loop).
  local refs = M._settingsRefs
  if refs then
    if refs.posX then refs.posX:SetValue(s.position.x) end
    if refs.posY then refs.posY:SetValue(s.position.y) end
  end
end

-- Four edge textures instead of BackdropTemplate: the template does
-- `width / edgeSize` arithmetic that can taint when secret-tagged sizes
-- propagate in (see SBM cooldown manager fallout).
local function addBorder(frame)
  local function edge(point1, point2, w, h)
    local t = frame:CreateTexture(nil, "BORDER")
    t:SetColorTexture(0, 0, 0, 1)
    t:SetPoint(point1, frame, point1, 0, 0)
    if point2 then t:SetPoint(point2, frame, point2, 0, 0) end
    if w then t:SetWidth(w) end
    if h then t:SetHeight(h) end
  end
  edge("TOPLEFT", "TOPRIGHT", nil, 1)
  edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
  edge("TOPLEFT", "BOTTOMLEFT", 1, nil)
  edge("TOPRIGHT", "BOTTOMRIGHT", 1, nil)
end

local function applyBarSize(bar)
  local iconSize = getIconSize()
  local barW = getBarWidth()
  -- 1px border + icon + 1px divider + bar + 1px border = +3 width, +2 height
  bar:SetSize(iconSize + barW + 3, iconSize + 2)
  bar.icon:SetWidth(iconSize)
end

local function applyFontStyle(fs)
  fs:SetFont(getFontPath(), getFontSize(), getFontOutline())
  if getFontShadow() then
    fs:SetShadowColor(0, 0, 0, 1)
    fs:SetShadowOffset(1, -1)
  else
    fs:SetShadowColor(0, 0, 0, 0)
    fs:SetShadowOffset(0, 0)
  end
end

local function applyBarStyle(bar)
  applyFontStyle(bar.name)
  applyFontStyle(bar.timer)

  bar.bar:SetStatusBarTexture(getFgTexture())
  local fr, fg, fb, fa = getFgColor()
  bar.bar:SetStatusBarColor(fr, fg, fb, fa)

  local br, bg2, bb, ba = getBgColor()
  bar.bar.bg:SetColorTexture(br, bg2, bb, ba)
end

local function createBar(parent)
  local bar = CreateFrame("Frame", nil, parent)
  addBorder(bar)

  bar.icon = bar:CreateTexture(nil, "ARTWORK")
  bar.icon:SetPoint("TOPLEFT", bar, "TOPLEFT", 1, -1)
  bar.icon:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 1, 1)
  bar.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  bar.divider = bar:CreateTexture(nil, "BORDER")
  bar.divider:SetColorTexture(0, 0, 0, 1)
  bar.divider:SetPoint("TOPLEFT", bar.icon, "TOPRIGHT", 0, 0)
  bar.divider:SetPoint("BOTTOMLEFT", bar.icon, "BOTTOMRIGHT", 0, 0)
  bar.divider:SetWidth(1)

  bar.bar = CreateFrame("StatusBar", nil, bar)
  bar.bar:SetPoint("TOPLEFT", bar.divider, "TOPRIGHT", 0, 0)
  bar.bar:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -1, 1)
  bar.bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
  bar.bar:SetMinMaxValues(0, 1)
  bar.bar:SetValue(1)

  bar.bar.bg = bar.bar:CreateTexture(nil, "BACKGROUND")
  bar.bar.bg:SetAllPoints()

  bar.name = bar.bar:CreateFontString(nil, "OVERLAY")
  bar.name:SetPoint("LEFT", bar.bar, "LEFT", 4, 0)
  bar.name:SetPoint("RIGHT", bar.bar, "RIGHT", -40, 0)
  bar.name:SetJustifyH("LEFT")
  bar.name:SetTextColor(1, 1, 1, 1)

  bar.timer = bar.bar:CreateFontString(nil, "OVERLAY")
  bar.timer:SetPoint("RIGHT", bar.bar, "RIGHT", -4, 0)
  bar.timer:SetJustifyH("RIGHT")
  bar.timer:SetTextColor(1, 1, 1, 1)

  applyBarSize(bar)
  applyBarStyle(bar)
  bar:Hide()
  return bar
end

-- Drive the bar fill via SetTimerDuration; the secure timer reads the
-- LuaDurationObject directly so we never touch the secret-tagged values.
-- Channel direction is inverted from the user's fillMode so a cast that
-- becomes a channel travels back the way it came.
local function applyDurationToBar(bar, cast)
  if not cast or not cast.durObj then return end
  if not bar.bar.SetTimerDuration then return end
  if not (Enum and Enum.StatusBarTimerDirection) then return end
  local fillNow = (getFillMode() == "FILL")
  if cast.channeling then fillNow = not fillNow end
  local direction = fillNow
    and Enum.StatusBarTimerDirection.ElapsedTime
    or Enum.StatusBarTimerDirection.RemainingTime
  local interp = Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.Immediate
  -- Seed the bar at its starting value so a recycled pool slot doesn't
  -- flash its leftover SetValue before SetTimerDuration takes over.
  bar.bar:SetMinMaxValues(0, 1)
  bar.bar:SetValue(fillNow and 0 or 1)
  bar.bar:SetTimerDuration(cast.durObj, interp, direction)
end

-- SetFormattedText is the secret-safe equivalent of SetText(string.format).
-- Passing GetRemainingDuration() straight through avoids storing the
-- secret-tagged number in a Lua local (which would leak the tag).
local function updateBarText(bar, cast)
  if not cast or not cast.durObj or not cast.durObj.GetRemainingDuration
    or not bar.timer.SetFormattedText then
    bar.timer:SetText("")
    return
  end
  bar.timer:SetFormattedText("%.1f", cast.durObj:GetRemainingDuration())
end

local function applyContainerSize()
  if not container then return end
  container:SetSize(getIconSize() + getBarWidth() + 3, getIconSize() + 2)
end

local function applyContainerPosition()
  if not container then return end
  local pos = getPosition()
  local point = pos.point or "CENTER"
  container:ClearAllPoints()
  container:SetPoint(point, UIParent, point,
    safeNumber(pos.x, 0) + PIXEL_OFFSET,
    safeNumber(pos.y, 0) + PIXEL_OFFSET)
end

local function createContainer()
  if container then return container end
  container = CreateFrame("Frame", "TargetedCastsContainer", UIParent)
  container:SetFrameStrata("MEDIUM")
  container:SetMovable(true)
  container:SetClampedToScreen(true)
  container:EnableMouse(false)
  container:RegisterForDrag("LeftButton")
  container:SetScript("OnDragStart", function(self)
    if not previewVisible then return end
    self:StartMoving()
  end)
  container:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    savePosition()
  end)

  applyContainerSize()
  applyContainerPosition()

  -- 20Hz text tick. Bar fill is driven by SetTimerDuration in secure code,
  -- so this only updates the "X.X" countdown numbers and the preview demo.
  container:SetScript("OnUpdate", function(self, elapsed)
    self._tick = (self._tick or 0) + elapsed
    if self._tick < 0.05 then return end
    self._tick = 0

    for unit, bar in pairs(activeBars) do
      local cast = liveCasts[unit]
      if cast then updateBarText(bar, cast) end
    end

    if previewVisible and previewBar and previewBar._previewStart then
      local now = GetTime()
      local fillMode = getFillMode()

      local elapsedPreview = now - previewBar._previewStart
      if elapsedPreview > 6 then
        previewBar._previewStart = now
        elapsedPreview = 0
      end
      local remaining = 6 - elapsedPreview
      previewBar.bar:SetMinMaxValues(0, 6)
      previewBar.bar:SetValue(fillMode == "DRAIN" and remaining or elapsedPreview)
      previewBar.timer:SetFormattedText("%.1f", remaining)

      if previewBar2 and previewBar2._previewStart then
        local e2 = now - previewBar2._previewStart
        if e2 > 4.2 then
          previewBar2._previewStart = now
          e2 = 0
        end
        local r2 = 4.2 - e2
        previewBar2.bar:SetMinMaxValues(0, 4.2)
        previewBar2.bar:SetValue(fillMode == "DRAIN" and r2 or e2)
        previewBar2.timer:SetFormattedText("%.1f", r2)
      end
    end
  end)

  return container
end

local function acquireBar()
  for _, b in ipairs(barPool) do
    if not b._inUse then
      b._inUse = true
      return b
    end
  end
  local b = createBar(container)
  barPool[#barPool + 1] = b
  b._inUse = true
  return b
end

local function releaseBar(bar)
  bar._inUse = false
  bar._lastDurObj = nil
  bar.icon:SetTexture(nil)
  bar.name:SetText("")
  bar.timer:SetText("")
  -- Pre-seed with the value a fresh cast would render at, so recycling
  -- this slot doesn't flash a stale full/empty bar before SetTimerDuration
  -- takes over.
  bar.bar:SetMinMaxValues(0, 1)
  bar.bar:SetValue(getFillMode() == "DRAIN" and 1 or 0)
  bar:Hide()
end

local function ensurePreviewBars()
  if not previewBar then previewBar = createBar(container) end
  if not previewBar2 then previewBar2 = createBar(container) end
end

-- Each bar anchors to the container at a fixed slot offset (no chain
-- anchoring between bars) and is ordered by spawnedAt, so slots stay
-- stable across relayouts.
function anchorBar(bar, slotIndex, growDirection, gap)
  gap = gap or getGap()
  local barHeight = getIconSize() + 2
  local offset = slotIndex * (barHeight + gap)
  bar:ClearAllPoints()
  if growDirection == "UP" then
    bar:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, offset)
  else
    bar:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -offset)
  end
end

local function sortedLiveUnits()
  local list = {}
  for unit in pairs(liveCasts) do list[#list + 1] = unit end
  table.sort(list, function(a, b)
    local sa = liveCasts[a].spawnedAt or 0
    local sb = liveCasts[b].spawnedAt or 0
    if sa == sb then return a < b end
    return sa < sb
  end)
  return list
end

local function layoutLiveBars()
  local growDirection = getGrowDirection()
  local gap = getGap()
  local units = sortedLiveUnits()
  for i, unit in ipairs(units) do
    local bar = activeBars[unit]
    local isNew = bar == nil
    if isNew then
      bar = acquireBar()
      activeBars[unit] = bar
    end
    local cast = liveCasts[unit]
    applyBarSize(bar)
    applyBarStyle(bar)
    bar.icon:SetTexture(cast.texture or PREVIEW_TEXTURE)
    bar.name:SetText(cast.spellName or "")
    -- Re-seed the timer when the durObj changes (cast -> channel on the
    -- same unit produces a fresh object; reusing the old one would freeze
    -- the bar at its end position for the entire channel).
    if isNew or bar._lastDurObj ~= cast.durObj then
      applyDurationToBar(bar, cast)
      bar._lastDurObj = cast.durObj
    end
    anchorBar(bar, i - 1, growDirection, gap)
    bar:Show()
  end

  for unit, bar in pairs(activeBars) do
    if not liveCasts[unit] then
      activeBars[unit] = nil
      releaseBar(bar)
    end
  end
end

local function clearLiveBars()
  for unit, bar in pairs(activeBars) do
    activeBars[unit] = nil
    releaseBar(bar)
  end
end

local function showPreview()
  ensurePreviewBars()
  local growDirection = getGrowDirection()
  local gap = getGap()
  local now = GetTime()

  applyBarSize(previewBar)
  applyBarStyle(previewBar)
  previewBar.icon:SetTexture(PREVIEW_TEXTURE)
  previewBar.name:SetText("Drag to position")
  anchorBar(previewBar, 0, growDirection, gap)
  previewBar._previewStart = now
  previewBar:Show()

  applyBarSize(previewBar2)
  applyBarStyle(previewBar2)
  previewBar2.icon:SetTexture(PREVIEW_TEXTURE_2)
  previewBar2.name:SetText("Secondary cast")
  anchorBar(previewBar2, 1, growDirection, gap)
  previewBar2._previewStart = now
  previewBar2:Show()
end

local function hidePreview()
  if previewBar then
    previewBar.icon:SetTexture(nil)
    previewBar:Hide()
  end
  if previewBar2 then
    previewBar2.icon:SetTexture(nil)
    previewBar2:Hide()
  end
end

local function updateLayout()
  createContainer()
  applyContainerSize()
  applyContainerPosition()

  if next(liveCasts) ~= nil then
    hidePreview()
    container:EnableMouse(false)
    layoutLiveBars()
    container:Show()
    return
  end

  clearLiveBars()

  if previewVisible then
    container:EnableMouse(true)
    showPreview()
    container:Show()
    return
  end

  hidePreview()
  container:EnableMouse(false)
  container:Hide()
end

function BU.ShowLiveBarForCast(unit)
  local castName, displayName, texture = UnitCastingInfo(unit)
  local channeling = false
  if type(castName) == "nil" then
    castName, displayName, texture = UnitChannelInfo(unit)
    channeling = true
  end
  if type(castName) == "nil" then return end

  local durObj
  if channeling and UnitChannelDuration then
    durObj = UnitChannelDuration(unit)
  elseif UnitCastingDuration then
    durObj = UnitCastingDuration(unit)
  end

  local existing = liveCasts[unit]
  liveCasts[unit] = {
    texture = texture,
    spellName = displayName or castName,
    durObj = durObj,
    channeling = channeling,
    -- Carried across cast -> channel so the bar keeps its slot.
    spawnedAt = (existing and existing.spawnedAt) or GetTime(),
  }
  updateLayout()
end

function BU.HideLiveBarIfUnit(unit)
  if liveCasts[unit] then
    liveCasts[unit] = nil
    updateLayout()
  end
end

function BU.SetPreviewVisible(visible)
  previewVisible = visible and true or false
  updateLayout()
end

function BU.RefreshAppearance()
  if not container then return end
  applyContainerSize()
  applyContainerPosition()
  for _, b in ipairs(barPool) do
    applyBarSize(b)
    applyBarStyle(b)
  end
  if previewBar then
    applyBarSize(previewBar)
    applyBarStyle(previewBar)
  end
  if previewBar2 then
    applyBarSize(previewBar2)
    applyBarStyle(previewBar2)
  end
  if next(liveCasts) ~= nil then
    layoutLiveBars()
    -- Re-seed in-flight bars so a fillMode toggle flips their direction.
    for unit, bar in pairs(activeBars) do
      applyDurationToBar(bar, liveCasts[unit])
    end
  elseif previewVisible then
    -- Re-anchor demo bars in place; no need to recreate them.
    local growDirection = getGrowDirection()
    local gap = getGap()
    if previewBar then anchorBar(previewBar, 0, growDirection, gap) end
    if previewBar2 then anchorBar(previewBar2, 1, growDirection, gap) end
  end
end

function BU.ResetPosition()
  local s = S()
  if s then s.position = nil end
  applyContainerPosition()
end

function BU.OnZoneChange()
  -- Hard reset; PLAYER_ENTERING_WORLD doesn't always fire NAME_PLATE_REMOVED.
  wipe(liveCasts)
  updateLayout()
end

-- Show preview while Blizzard's Edit Mode is open.
local function HookEditMode()
  if not (EditModeManagerFrame and EditModeManagerFrame.EnterEditMode) then return end
  if BU._editModeHooked then return end
  hooksecurefunc(EditModeManagerFrame, "EnterEditMode", function()
    BU.SetPreviewVisible(true)
  end)
  hooksecurefunc(EditModeManagerFrame, "ExitEditMode", function()
    BU.SetPreviewVisible(false)
  end)
  BU._editModeHooked = true
end

function BU.Init()
  createContainer()
  HookEditMode()
end
