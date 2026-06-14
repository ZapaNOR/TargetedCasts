local ADDON_NAME = ...
local M = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = M

M.Defaults = {
  enabled = true,
  alertOnAmbiguous = false,
  soundEnabled = true,
  soundEnum = 13, -- CooldownViewerSound.DevicesBikeHorn
  soundChannel = "Master",
  iconSize = 24,
  barWidth = 230,
  fgColor = { r = 0.875, g = 0.184, b = 0.224, a = 1.0 }, -- #DF2F39
  bgColor = { r = 0.000, g = 0.000, b = 0.000, a = 0.70 },
  fgTexture = "Dragonflight", -- LibSharedMedia statusbar key
  fontFace = "Expressway",    -- LibSharedMedia font key
  fontSize = 14,
  fontOutline = "OUTLINE, SLUG", -- "" | "OUTLINE" | "OUTLINE, SLUG" | "THICKOUTLINE" | "MONOCHROME"
  fontShadow = false,
  fillMode = "FILL",          -- "FILL" or "DRAIN"
  growDirection = "UP",       -- "UP" or "DOWN"
  gap = -1,                   -- -1 makes adjacent borders share one pixel
  position = { point = "CENTER", x = 0, y = 0 },
}

-- Migration from the pre-rename SavedVariables global. Once CastOnMeDB has
-- been written at least once, TargetedCastsDB stays nil and this is a no-op.
local function MigrateLegacyDB()
  if CastOnMeDB or type(TargetedCastsDB) ~= "table" then return end
  CastOnMeDB = TargetedCastsDB
  TargetedCastsDB = nil
end

function M:EnsureDefaults()
  MigrateLegacyDB()
  CastOnMeDB = CastOnMeDB or {}
  local db = CastOnMeDB
  local function fill(target, defaults)
    for key, default in pairs(defaults) do
      if type(default) == "table" then
        if type(target[key]) ~= "table" then target[key] = {} end
        fill(target[key], default)
      elseif target[key] == nil then
        target[key] = default
      end
    end
  end
  fill(db, M.Defaults)
end

function M:DB()
  return CastOnMeDB
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGIN" then
    M:EnsureDefaults()
    -- CooldownViewerSoundData lives in Blizzard_CooldownViewer; load it so
    -- the sound dropdown can populate.
    if C_AddOns and C_AddOns.LoadAddOn then
      C_AddOns.LoadAddOn("Blizzard_CooldownViewer")
    end
    M.Detection.Init()
    M.BarUI.Init()
    M:CreateSettingsPanel()
  end
end)

SLASH_CASTONME1 = "/com"
SLASH_CASTONME2 = "/castonme"
SlashCmdList["CASTONME"] = function()
  if M.OpenSettings then M:OpenSettings() end
end
