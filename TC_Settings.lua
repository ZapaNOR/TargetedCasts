local ADDON_NAME = ...
local M = _G[ADDON_NAME]
if not M then return end

local AG = LibStub and LibStub("AceGUI-3.0", true)
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
local isGUIOpen = false

M._settingsCategoryName = "Targeted Casts"

-- Sound category labels for keys that need relabeling; others fall through
-- to the raw CooldownViewerSoundData key (Animals, Devices, Impacts, etc.).
local soundCategoryKeyToText = {
  War2 = "Warcraft II",
  War3 = "Warcraft III",
}

local function lookupSoundText(soundEnum)
  if not soundEnum or type(CooldownViewerSoundData) ~= "table" then return "" end
  for _, category in pairs(CooldownViewerSoundData) do
    if type(category) == "table" then
      for _, entry in pairs(category) do
        if type(entry) == "table" and entry.soundEnum == soundEnum then
          return entry.text or ""
        end
      end
    end
  end
  if CooldownViewerSound and soundEnum == CooldownViewerSound.TextToSpeech then
    return "Text To Speech"
  end
  return ""
end

local function setupSoundDropdown(dropdown, getValue, setValue)
  dropdown:SetSelectionText(function()
    return lookupSoundText(getValue()) or ""
  end)

  dropdown:SetupMenu(function(_, rootDescription)
    rootDescription:SetTag("TARGETEDCASTS_SOUND")

    local function addSoundButton(description, label, soundEnum)
      description:CreateButton(label, function() setValue(soundEnum) end)
        :AddInitializer(function(button)
          if not (MenuTemplates and MenuTemplates.AttachUtilityButton) then return end
          local playBtn = MenuTemplates.AttachUtilityButton(button)
          if playBtn.Texture then playBtn.Texture:Hide() end
          if CooldownViewerAlert_SetupTypeButton and Enum and Enum.CooldownViewerAlertType then
            CooldownViewerAlert_SetupTypeButton(playBtn, Enum.CooldownViewerAlertType.Sound)
          end
          MenuTemplates.SetUtilityButtonTooltipText(playBtn, "Play sample")
          if MenuVariants and MenuVariants.GearButtonAnchor then
            MenuTemplates.SetUtilityButtonAnchor(playBtn, MenuVariants.GearButtonAnchor, button)
          end
          MenuTemplates.SetUtilityButtonClickHandler(playBtn, function()
            local kit = M.Detection.GetSoundKitFor(soundEnum)
            if kit then PlaySound(kit, (M:DB() and M:DB().soundChannel) or "Master") end
          end)
        end)
    end

    if type(CooldownViewerSoundData) ~= "table" then
      rootDescription:CreateTitle("Blizzard_CooldownViewer not loaded")
      return
    end

    for key, category in pairs(CooldownViewerSoundData) do
      if type(category) == "table" then
        local label = soundCategoryKeyToText[key] or key
        local nested = rootDescription:CreateButton(label, nop, -1)
        for _, entry in pairs(category) do
          if type(entry) == "table" and entry.soundEnum and entry.text then
            addSoundButton(nested, entry.text, entry.soundEnum)
          end
        end
      end
    end
  end)
end

-- =========================
-- Color picker (deferred-commit)
-- =========================
local function ensureColorPickerCloseHook()
  if M._tcColorPickerCloseHooked then return end
  local pickerFrame = _G.ColorPickerFrame
  if not (pickerFrame and type(pickerFrame.HookScript) == "function") then return end
  local function flushPending()
    local commit = M._tcPendingColorCommit
    M._tcPendingColorCommit = nil
    if type(commit) == "function" then commit() end
  end
  pickerFrame:HookScript("OnHide", function()
    if C_Timer and type(C_Timer.After) == "function" then
      C_Timer.After(0, flushPending)
    else
      flushPending()
    end
  end)
  M._tcColorPickerCloseHooked = true
end

local function addColorPicker(container, label, getValue, setValue, hasAlpha)
  local cp = AG:Create("ColorPicker")
  cp:SetLabel(label)
  cp:SetHasAlpha(hasAlpha and true or false)
  local r, g, b, a = getValue()
  cp:SetColor(r, g, b, a or 1)
  ensureColorPickerCloseHook()
  cp:SetRelativeWidth(0.45)
  local pendingR, pendingG, pendingB, pendingA, hasPending
  local function commitPending()
    if not hasPending then return end
    hasPending = false
    setValue(pendingR, pendingG, pendingB, pendingA)
  end
  cp:SetCallback("OnValueChanged", function(_, _, nr, ng, nb, na)
    pendingR, pendingG, pendingB, pendingA = nr, ng, nb, na
    hasPending = true
    local pickerFrame = _G.ColorPickerFrame
    if pickerFrame and pickerFrame:IsShown() then
      M._tcPendingColorCommit = commitPending
    else
      if M._tcPendingColorCommit == commitPending then
        M._tcPendingColorCommit = nil
      end
      commitPending()
    end
  end)
  cp:SetCallback("OnValueConfirmed", function(_, _, nr, ng, nb, na)
    pendingR, pendingG, pendingB, pendingA = nr, ng, nb, na
    hasPending = true
    if M._tcPendingColorCommit == commitPending then
      M._tcPendingColorCommit = nil
    end
    commitPending()
  end)
  container:AddChild(cp)
  return cp
end

-- =========================
-- Main settings panel
-- =========================
local function refresh()
  M.BarUI.RefreshAppearance()
end

local function makeGroup(container, title)
  local g = AG:Create("InlineGroup")
  g:SetTitle(title)
  g:SetLayout("Flow")
  g:SetFullWidth(true)
  container:AddChild(g)
  return g
end

local function buildSettings(container)
  local db = M:DB()

  -- =========================
  -- General
  -- =========================
  local generalGroup = makeGroup(container, "General")

  local enableBox = AG:Create("CheckBox")
  enableBox:SetLabel("Enable Targeted Cast Bars")
  enableBox:SetValue(db.enabled ~= false)
  enableBox:SetFullWidth(true)
  enableBox:SetCallback("OnValueChanged", function(_, _, value)
    db.enabled = value and true or false
    M.Detection.UpdateActive()
  end)
  generalGroup:AddChild(enableBox)

  local ambiguousBox = AG:Create("CheckBox")
  ambiguousBox:SetLabel("Alert on ambiguous matches")
  ambiguousBox:SetValue(db.alertOnAmbiguous and true or false)
  ambiguousBox:SetFullWidth(true)
  ambiguousBox:SetCallback("OnValueChanged", function(_, _, value)
    db.alertOnAmbiguous = value and true or false
  end)
  generalGroup:AddChild(ambiguousBox)

  -- =========================
  -- Sound Alert
  -- =========================
  local soundGroup = makeGroup(container, "Sound Alert")

  local soundEnabledBox = AG:Create("CheckBox")
  soundEnabledBox:SetLabel("Play sound alert")
  soundEnabledBox:SetValue(db.soundEnabled ~= false)
  soundEnabledBox:SetFullWidth(true)
  soundEnabledBox:SetCallback("OnValueChanged", function(_, _, value)
    db.soundEnabled = value and true or false
  end)
  soundGroup:AddChild(soundEnabledBox)

  local soundHost = AG:Create("SimpleGroup")
  soundHost.noAutoHeight = true
  soundHost:SetFullWidth(true)
  soundHost:SetHeight(35)
  soundGroup:AddChild(soundHost)

  local dropdown = CreateFrame("DropdownButton", nil, soundHost.frame, "WowStyle1DropdownTemplate")
  dropdown:SetSize(280, 25)
  dropdown:SetPoint("LEFT", soundHost.frame, "LEFT", 6, 0)
  setupSoundDropdown(dropdown,
    function() return db.soundEnum end,
    function(value)
      db.soundEnum = value
      M.Detection.PreviewCurrentSound()
    end
  )

  local previewBtn = CreateFrame("Button", nil, soundHost.frame, "UIPanelButtonTemplate")
  previewBtn:SetSize(90, 22)
  previewBtn:SetPoint("LEFT", dropdown, "RIGHT", 8, 0)
  previewBtn:SetText("Preview")
  previewBtn:SetScript("OnClick", function() M.Detection.PreviewCurrentSound() end)

  local channelDropdown = AG:Create("Dropdown")
  channelDropdown:SetLabel("Sound Channel")
  channelDropdown:SetList({
    Master   = "Master",
    SFX      = "Sound Effects",
    Music    = "Music",
    Ambience = "Ambience",
    Dialog   = "Dialog",
  }, { "Master", "SFX", "Music", "Ambience", "Dialog" })
  channelDropdown:SetValue(db.soundChannel or "Master")
  channelDropdown:SetFullWidth(true)
  channelDropdown:SetCallback("OnValueChanged", function(_, _, value)
    db.soundChannel = value
    M.Detection.PreviewCurrentSound()
  end)
  soundGroup:AddChild(channelDropdown)

  -- =========================
  -- Bar (colors, texture, width, height)
  -- =========================
  local barGroup = makeGroup(container, "Bar")

  addColorPicker(barGroup, "Foreground",
    function()
      local c = db.fgColor
      return c.r, c.g, c.b, c.a
    end,
    function(r, g, b, a)
      db.fgColor.r, db.fgColor.g, db.fgColor.b, db.fgColor.a = r, g, b, a or 1
      refresh()
    end,
    false
  )

  addColorPicker(barGroup, "Background",
    function()
      local c = db.bgColor
      return c.r, c.g, c.b, c.a
    end,
    function(r, g, b, a)
      db.bgColor.r, db.bgColor.g, db.bgColor.b, db.bgColor.a = r, g, b, a or 1
      refresh()
    end,
    true
  )

  if LSM and AG.WidgetRegistry and AG.WidgetRegistry["LSM30_Statusbar"] then
    local texDropdown = AG:Create("LSM30_Statusbar")
    texDropdown:SetLabel("Bar Texture")
    texDropdown:SetList(LSM:HashTable("statusbar"))
    texDropdown:SetValue(db.fgTexture)
    texDropdown:SetFullWidth(true)
    texDropdown:SetCallback("OnValueChanged", function(widget, _, value)
      db.fgTexture = value
      -- The LSM30_Statusbar widget fires OnValueChanged but doesn't update
      -- its own preview swatch — we have to call SetValue back into it.
      widget:SetValue(value)
      refresh()
    end)
    barGroup:AddChild(texDropdown)
  else
    local texInput = AG:Create("EditBox")
    texInput:SetLabel("Bar Texture (LibSharedMedia key)")
    texInput:SetText(db.fgTexture or "")
    texInput:SetFullWidth(true)
    texInput:SetCallback("OnEnterPressed", function(_, _, value)
      db.fgTexture = value
      refresh()
    end)
    barGroup:AddChild(texInput)
  end

  local barHeight = AG:Create("Slider")
  barHeight:SetLabel("Bar Height")
  barHeight:SetSliderValues(16, 64, 1)
  barHeight:SetValue(tonumber(db.iconSize) or 24)
  barHeight:SetRelativeWidth(0.5)
  barHeight:SetCallback("OnValueChanged", function(_, _, value)
    db.iconSize = math.floor(tonumber(value) or 24)
    refresh()
  end)
  barGroup:AddChild(barHeight)

  local barWidth = AG:Create("Slider")
  barWidth:SetLabel("Bar Width")
  barWidth:SetSliderValues(100, 400, 5)
  barWidth:SetValue(tonumber(db.barWidth) or 230)
  barWidth:SetRelativeWidth(0.5)
  barWidth:SetCallback("OnValueChanged", function(_, _, value)
    db.barWidth = math.floor(tonumber(value) or 230)
    refresh()
  end)
  barGroup:AddChild(barWidth)

  -- =========================
  -- Text
  -- =========================
  local textGroup = makeGroup(container, "Text")

  if LSM and AG.WidgetRegistry and AG.WidgetRegistry["LSM30_Font"] then
    local fontDropdown = AG:Create("LSM30_Font")
    fontDropdown:SetLabel("Font")
    fontDropdown:SetList(LSM:HashTable("font"))
    fontDropdown:SetValue(db.fontFace)
    fontDropdown:SetRelativeWidth(0.5)
    fontDropdown:SetCallback("OnValueChanged", function(widget, _, value)
      db.fontFace = value
      widget:SetValue(value)
      refresh()
    end)
    textGroup:AddChild(fontDropdown)
  else
    local fontInput = AG:Create("EditBox")
    fontInput:SetLabel("Font (LibSharedMedia key)")
    fontInput:SetText(db.fontFace or "")
    fontInput:SetRelativeWidth(0.5)
    fontInput:SetCallback("OnEnterPressed", function(_, _, value)
      db.fontFace = value
      refresh()
    end)
    textGroup:AddChild(fontInput)
  end

  local fontSize = AG:Create("Slider")
  fontSize:SetLabel("Font Size")
  fontSize:SetSliderValues(8, 32, 1)
  fontSize:SetValue(tonumber(db.fontSize) or 14)
  fontSize:SetRelativeWidth(0.5)
  fontSize:SetCallback("OnValueChanged", function(_, _, value)
    db.fontSize = math.floor(tonumber(value) or 14)
    refresh()
  end)
  textGroup:AddChild(fontSize)

  local outline = AG:Create("Dropdown")
  outline:SetLabel("Outline")
  outline:SetList({
    [""]              = "None",
    ["OUTLINE"]       = "Outline",
    ["OUTLINE, SLUG"] = "Outline (Slug)",
    ["THICKOUTLINE"]  = "Thick Outline",
    ["MONOCHROME"]    = "Monochrome",
  }, { "", "OUTLINE", "OUTLINE, SLUG", "THICKOUTLINE", "MONOCHROME" })
  outline:SetValue(db.fontOutline or "OUTLINE, SLUG")
  outline:SetRelativeWidth(0.5)
  outline:SetCallback("OnValueChanged", function(_, _, value)
    db.fontOutline = value
    refresh()
  end)
  textGroup:AddChild(outline)

  local shadow = AG:Create("CheckBox")
  shadow:SetLabel("Shadow")
  shadow:SetValue(db.fontShadow == true)
  shadow:SetRelativeWidth(0.5)
  shadow:SetCallback("OnValueChanged", function(_, _, value)
    db.fontShadow = value and true or false
    refresh()
  end)
  textGroup:AddChild(shadow)

  -- =========================
  -- Layout (grow direction, bar direction, gap)
  -- =========================
  local layoutGroup = makeGroup(container, "Layout")

  local growDir = AG:Create("Dropdown")
  growDir:SetLabel("Grow Direction (when multiple casts)")
  growDir:SetList({ DOWN = "Down", UP = "Up" }, { "DOWN", "UP" })
  growDir:SetValue(db.growDirection or "UP")
  growDir:SetRelativeWidth(0.5)
  growDir:SetCallback("OnValueChanged", function(_, _, value)
    db.growDirection = value
    refresh()
  end)
  layoutGroup:AddChild(growDir)

  local fillMode = AG:Create("Dropdown")
  fillMode:SetLabel("Bar Direction")
  fillMode:SetList({ FILL = "Fill", DRAIN = "Drain" }, { "FILL", "DRAIN" })
  fillMode:SetValue(db.fillMode or "FILL")
  fillMode:SetRelativeWidth(0.5)
  fillMode:SetCallback("OnValueChanged", function(_, _, value)
    db.fillMode = value
    refresh()
  end)
  layoutGroup:AddChild(fillMode)

  local gapSlider = AG:Create("Slider")
  gapSlider:SetLabel("Gap Between Bars")
  gapSlider:SetSliderValues(-1, 20, 1)
  gapSlider:SetValue(tonumber(db.gap) or -1)
  gapSlider:SetFullWidth(true)
  gapSlider:SetCallback("OnValueChanged", function(_, _, value)
    db.gap = math.floor(tonumber(value) or -1)
    refresh()
  end)
  layoutGroup:AddChild(gapSlider)

  -- =========================
  -- Position
  -- =========================
  local positionGroup = makeGroup(container, "Position")

  local posX = AG:Create("Slider")
  posX:SetLabel("Position X")
  posX:SetSliderValues(-2000, 2000, 1)
  posX:SetValue(tonumber(db.position and db.position.x) or 0)
  posX:SetRelativeWidth(0.5)
  posX:SetCallback("OnValueChanged", function(_, _, value)
    db.position = db.position or {}
    db.position.x = math.floor(tonumber(value) or 0)
    refresh()
  end)
  positionGroup:AddChild(posX)

  local posY = AG:Create("Slider")
  posY:SetLabel("Position Y")
  posY:SetSliderValues(-2000, 2000, 1)
  posY:SetValue(tonumber(db.position and db.position.y) or 0)
  posY:SetRelativeWidth(0.5)
  posY:SetCallback("OnValueChanged", function(_, _, value)
    db.position = db.position or {}
    db.position.y = math.floor(tonumber(value) or 0)
    refresh()
  end)
  positionGroup:AddChild(posY)

  -- BarUI pushes drag positions back through these refs. AceGUI Slider's
  -- SetValue doesn't fire OnValueChanged, so no callback loop.
  M._settingsRefs = M._settingsRefs or {}
  M._settingsRefs.posX = posX
  M._settingsRefs.posY = posY

  local resetPosBtn = AG:Create("Button")
  resetPosBtn:SetText("Reset Position")
  resetPosBtn:SetFullWidth(true)
  resetPosBtn:SetCallback("OnClick", function()
    M.BarUI.ResetPosition()
    posX:SetValue(0)
    posY:SetValue(0)
  end)
  positionGroup:AddChild(resetPosBtn)
end

-- =========================
-- Window + slash
-- =========================
function M:OpenSettings()
  if not AG then
    print("|cFF9CDF95Targeted|rCasts: AceGUI-3.0 failed to load (broken install?).")
    return
  end

  M.BarUI.SetPreviewVisible(true)

  local frame = self._settingsWindow
  if frame then
    frame:Show()
    if frame.Raise then frame:Raise() end
    return
  end

  self:CreateSettingsWindow()
end

function M:CreateSettingsWindow()
  if isGUIOpen and self._settingsWindow then return self._settingsWindow end
  isGUIOpen = false
  if not AG then return end

  self:EnsureDefaults()
  isGUIOpen = true

  local frame = AG:Create("Frame")
  frame:SetTitle("Targeted Casts")
  frame:SetLayout("Fill")
  frame:SetWidth(520)
  frame:SetHeight(720)
  frame:EnableResize(false)
  frame:SetCallback("OnClose", function(widget)
    AG:Release(widget)
    isGUIOpen = false
    M._settingsWindow = nil
    M._settingsRefs = nil
    M.BarUI.SetPreviewVisible(false)
  end)
  frame.frame:SetClampedToScreen(true)
  frame.frame:SetFrameStrata("DIALOG")

  self._settingsWindow = frame

  local scroll = AG:Create("ScrollFrame")
  scroll:SetLayout("Flow")
  scroll:SetFullWidth(true)
  scroll:SetFullHeight(true)
  frame:AddChild(scroll)

  buildSettings(scroll)

  -- Force layout + scrollbar fixup; LayoutFinished doesn't always fire on
  -- the first open, leaving overflowing content unscrollable otherwise.
  scroll:DoLayout()
  if scroll.FixScroll then scroll:FixScroll() end

  return frame
end

function M:CreateSettingsPanel()
  if not (Settings and Settings.RegisterCanvasLayoutCategory) then return end

  local panel = CreateFrame("Frame")
  panel.name = M._settingsCategoryName

  local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText("Targeted Casts")

  local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
  desc:SetWidth(520)
  desc:SetJustifyH("LEFT")
  desc:SetText("Settings open in a separate window. Use the button below or type /tc.")

  local btn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  btn:SetSize(200, 24)
  btn:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -12)
  btn:SetText("Open Settings")
  btn:SetScript("OnClick", function() M:OpenSettings() end)

  local category = Settings.RegisterCanvasLayoutCategory(panel, M._settingsCategoryName)
  Settings.RegisterAddOnCategory(category)
end
