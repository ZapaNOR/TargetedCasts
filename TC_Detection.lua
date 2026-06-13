-- Credit: the technique of identifying a hostile cast's target by fingerprinting
-- attributes (class/role/race/sex) that aren't wrapped as secret values, then
-- matching against the cached roster, originates from EllesmereUI's
-- EUI_RF_TargetedSpells module. Our implementation is narrower (only answers
-- "is the target me?" rather than disambiguating among all raid members) but
-- the core idea, the resolve-delay timing, and the secret-value handling
-- pattern are all derived from that addon's approach.

local ADDON_NAME = ...
local M = _G[ADDON_NAME]
if not M then return end

local D = {}
M.Detection = D

local CreateFrame   = CreateFrame
local C_Timer       = C_Timer
local UnitClass     = UnitClass
local UnitRace      = UnitRace
local UnitSex       = UnitSex
local UnitGroupRolesAssigned = UnitGroupRolesAssigned
local UnitCastingInfo = UnitCastingInfo
local UnitChannelInfo = UnitChannelInfo
local UnitCanAttack = UnitCanAttack
local UnitExists    = UnitExists
local IsInRaid      = IsInRaid
local PlaySound     = PlaySound
local ipairs        = ipairs
local pairs         = pairs
local type          = type
local wipe          = wipe
local issecret      = issecretvalue or function() return false end

local RESOLVE_DELAY_1 = 0.10
local RESOLVE_DELAY_2 = 0.25
local RETARGET_DELAY_1 = 0.05
local RETARGET_DELAY_2 = 0.20

local ROSTER_UNITS = { "player", "party1", "party2", "party3", "party4" }
local RAID_UNITS = {}
for i = 1, 40 do RAID_UNITS[i] = "raid" .. i end
local function RosterUnits()
  return IsInRaid() and RAID_UNITS or ROSTER_UNITS
end

-- Player fingerprint, refreshed on roster / role events.
local pClass, pRole, pRace, pSex

local function RefreshPlayerFingerprint()
  local _, c = UnitClass("player")
  pClass = (type(c) == "string") and c or nil
  local r = UnitGroupRolesAssigned("player")
  pRole = (type(r) == "string" and r ~= "NONE") and r or nil
  local _, rr = UnitRace("player")
  pRace = (type(rr) == "string") and rr or nil
  local sx = UnitSex("player")
  pSex = (type(sx) == "number") and sx or nil
end

-- Other roster members' fingerprints. If anyone shares ours, a cast we
-- match positively could actually be targeting them — flag as ambiguous.
local roster = {}

local function RefreshRoster()
  wipe(roster)
  for _, u in ipairs(RosterUnits()) do
    if u ~= "player" and UnitExists(u) then
      local _, c = UnitClass(u)
      local r = UnitGroupRolesAssigned(u)
      local _, rr = UnitRace(u)
      local sx = UnitSex(u)
      roster[#roster + 1] = {
        class = type(c) == "string" and c or nil,
        role  = type(r) == "string" and r ~= "NONE" and r or nil,
        race  = type(rr) == "string" and rr or nil,
        sex   = type(sx) == "number" and sx or nil,
      }
    end
  end
end

local function PlayerFingerprintIsAmbiguous()
  if not pClass then return true end
  for _, e in ipairs(roster) do
    if e.class == pClass
      and (pRole == nil or e.role == nil or e.role == pRole)
      and (pRace == nil or e.race == nil or e.race == pRace)
      and (pSex  == nil or e.sex  == nil or e.sex  == pSex)
    then
      return true
    end
  end
  return false
end

-- Returns "yes" | "no" | "ambiguous" | "unknown".
local function IsCastTargetingPlayer(caster)
  if PlayerIsSpellTarget then
    local r = PlayerIsSpellTarget(caster)
    if not issecret(r) then
      if r == true then return "yes" end
      if r == false then return "no" end
    end
  end

  if not pClass then return "unknown" end

  local tgt = caster .. "target"
  if not UnitExists(tgt) then return "no" end

  local _, c = UnitClass(tgt)
  if issecret(c) or type(c) ~= "string" then return "unknown" end
  if c ~= pClass then return "no" end

  if pRole then
    local r = UnitGroupRolesAssigned(tgt)
    if not issecret(r) and type(r) == "string" and r ~= "NONE" and r ~= pRole then
      return "no"
    end
  end
  if pRace then
    local _, rr = UnitRace(tgt)
    if not issecret(rr) and type(rr) == "string" and rr ~= pRace then
      return "no"
    end
  end
  if pSex then
    local sx = UnitSex(tgt)
    if not issecret(sx) and type(sx) == "number" and sx ~= pSex then
      return "no"
    end
  end

  if PlayerFingerprintIsAmbiguous() then return "ambiguous" end
  return "yes"
end

-- Per-nameplate cast state. `gen` bumps on each cast start / retarget so
-- delayed Resolve calls from a previous generation can be discarded.
-- `soundPlayed` keeps the sound from re-firing within one generation.
local active = {}

local function Settings()
  return M.DB and M:DB() or nil
end

local function ApplyAlert(unit)
  local s = Settings()
  if not s or s.enabled == false then return end

  local entry = active[unit]
  if not entry or not entry.soundPlayed then
    if s.soundEnabled ~= false then
      local soundKit = D.GetSoundKitFor(s.soundEnum)
      if soundKit then PlaySound(soundKit, s.soundChannel or "Master") end
    end
    if entry then entry.soundPlayed = true end
  end

  M.BarUI.ShowLiveBarForCast(unit)
end

local function HideForUnit(unit)
  M.BarUI.HideLiveBarIfUnit(unit)
end

local function Resolve(unit, generation)
  local entry = active[unit]
  if not entry or entry.gen ~= generation then return end

  local castName = UnitCastingInfo(unit)
  if type(castName) == "nil" then castName = UnitChannelInfo(unit) end
  if type(castName) == "nil" then return end

  if UnitShouldDisplaySpellTargetName then
    local sd = UnitShouldDisplaySpellTargetName(unit)
    if not issecret(sd) and sd == false then return end
  end

  local verdict = IsCastTargetingPlayer(unit)
  if verdict == "yes" then
    ApplyAlert(unit)
  elseif verdict == "ambiguous" then
    local s = Settings()
    if s and s.alertOnAmbiguous then
      ApplyAlert(unit)
    else
      HideForUnit(unit)
    end
  elseif verdict == "no" then
    HideForUnit(unit)
  end
end

local function OnCastStart(unit)
  local hostile = UnitCanAttack("player", unit)
  if not issecret(hostile) and hostile ~= true then return end

  local gen = ((active[unit] and active[unit].gen) or 0) + 1
  active[unit] = { gen = gen, soundPlayed = false }

  C_Timer.After(RESOLVE_DELAY_1, function() Resolve(unit, gen) end)
  C_Timer.After(RESOLVE_DELAY_2, function() Resolve(unit, gen) end)
end

local function OnRetarget(unit)
  local entry = active[unit]
  if not entry then return end
  entry.gen = entry.gen + 1
  entry.soundPlayed = false
  local gen = entry.gen
  C_Timer.After(RETARGET_DELAY_1, function() Resolve(unit, gen) end)
  C_Timer.After(RETARGET_DELAY_2, function() Resolve(unit, gen) end)
end

local function OnCastEnd(unit)
  active[unit] = nil
  HideForUnit(unit)
end

local function OnNameplateAdded(unit)
  local castName = UnitCastingInfo(unit)
  if type(castName) == "nil" then castName = UnitChannelInfo(unit) end
  if type(castName) ~= "nil" then
    OnCastStart(unit)
  end
end

-- =========================
-- Sound data
-- =========================
local soundEnumToKit

local function BuildSoundMap()
  if soundEnumToKit then return end
  soundEnumToKit = {}
  if type(CooldownViewerSoundData) ~= "table" then return end
  local function walk(t)
    for _, v in pairs(t) do
      if type(v) == "table" then
        if v.soundEnum and v.soundKitID then
          soundEnumToKit[v.soundEnum] = v.soundKitID
        else
          walk(v)
        end
      end
    end
  end
  walk(CooldownViewerSoundData)
end

function D.GetSoundKitFor(soundEnum)
  BuildSoundMap()
  if not soundEnum or not soundEnumToKit then return nil end
  return soundEnumToKit[soundEnum]
end

function D.PreviewCurrentSound()
  local s = Settings()
  if not s then return end
  local kit = D.GetSoundKitFor(s.soundEnum)
  if kit then PlaySound(kit, s.soundChannel or "Master") end
end

-- =========================
-- Event wiring
-- =========================
local ev = CreateFrame("Frame")
local castEventsOn = false

local CAST_EVENTS = {
  "UNIT_SPELLCAST_START",
  "UNIT_SPELLCAST_CHANNEL_START",
  "UNIT_SPELLCAST_STOP",
  "UNIT_SPELLCAST_CHANNEL_STOP",
  "UNIT_SPELLCAST_INTERRUPTED",
  "UNIT_TARGET",
  "NAME_PLATE_UNIT_ADDED",
  "NAME_PLATE_UNIT_REMOVED",
}

local function ShouldBeActive()
  local s = Settings()
  return s and s.enabled ~= false
end

function D.UpdateActive()
  local want = ShouldBeActive()
  if want and not castEventsOn then
    for _, e in ipairs(CAST_EVENTS) do ev:RegisterEvent(e) end
    castEventsOn = true
    RefreshPlayerFingerprint()
    RefreshRoster()
  elseif not want and castEventsOn then
    for _, e in ipairs(CAST_EVENTS) do ev:UnregisterEvent(e) end
    castEventsOn = false
    wipe(active)
  end
end

ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:RegisterEvent("PLAYER_ROLES_ASSIGNED")

ev:SetScript("OnEvent", function(_, event, unit)
  if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
    RefreshPlayerFingerprint()
    RefreshRoster()
    D.UpdateActive()
    M.BarUI.OnZoneChange()
    return
  end
  if event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ROLES_ASSIGNED" then
    RefreshPlayerFingerprint()
    RefreshRoster()
    return
  end

  if type(unit) ~= "string" or not unit:match("^nameplate%d+$") then return end

  if event == "NAME_PLATE_UNIT_ADDED" then
    OnNameplateAdded(unit)
  elseif event == "NAME_PLATE_UNIT_REMOVED" then
    active[unit] = nil
    HideForUnit(unit)
  elseif event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" then
    OnCastStart(unit)
  elseif event == "UNIT_TARGET" then
    OnRetarget(unit)
  else
    OnCastEnd(unit)
  end
end)

function D.Init()
  D.UpdateActive()
end
