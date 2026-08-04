-- Part of the Particles module addon. `...` would hand us this addon's OWN
-- private table, so reach for core's shared namespace instead — the .toc's
-- ## Dependencies guarantees core has already loaded and set this global.
local addon = _G.DrievEssentials
if not addon then return end

-- Backend port of the user's particle WeakAura.
--
-- Density values mirror the original WeakAura:
--   outside raid -> 3 (normal)
--   inside  raid -> 0 (off, for FPS)
--   managed encounter -> 3 (force on so mechanics are visible)
-- Linger durations keep particles ON for N seconds after an encounter ends
-- (covers Viscidus slime puddle, Ouro residue, etc.). Every boss has a linger
-- toggle + duration in Particles → Raids; the bosses that used to be hardcoded
-- here carry their old timer as the `linger` default in core's Raids.lua.

local OUTSIDE_DENSITY = 3
local RAID_DENSITY    = 0

local function settings()
    return addon.db and addon.db.settings and addon.db.settings.particles
end

local function getEncounterDensity()
    local s = settings()
    return (s and s.general and s.general.encounterDensity) or 3
end

-- Master switch for the whole module (General tab), independent of the
-- per-class filter below — off by default, same as every other module's
-- master toggle, so a fresh install does nothing until explicitly turned on.
local function isModuleEnabled()
    local s = settings()
    return s and s.enabled == true
end

local function isClassEnabled()
    if not isModuleEnabled() then return false end
    local s = settings()
    local classes = s and s.classes
    if not classes then return false end
    local _, classToken = UnitClass("player")
    return classes[classToken] == true
end

-- encounterID -> { raidKey, name, linger }, built lazily on first event so file
-- load stays cheap and we tolerate Raids.lua being reloaded. `linger` is the
-- built-in default (nil for bosses that never lingered), used only until the
-- profile has per-boss linger data of its own.
local encounterIndex
local function getEncounterIndex()
    if encounterIndex then return encounterIndex end
    encounterIndex = {}
    for _, raid in ipairs(addon.RAIDS or {}) do
        for _, boss in ipairs(raid.bosses) do
            if boss.id then
                encounterIndex[boss.id] = { raidKey = raid.key, name = boss.name, linger = boss.linger }
            end
        end
    end
    return encounterIndex
end

local function isDebugOn()
    local s = settings()
    return s and s.debug and s.debug.enabled or false
end

local function dprint(msg)
    if isDebugOn() then
        DEFAULT_CHAT_FRAME:AddMessage("|cfffb2c36[DE]|r " .. msg)
    end
end

local function isInRaid()
    local inInstance, instanceType = IsInInstance()
    return inInstance and instanceType == "raid"
end

-- When Debug is on AND we're in a 5-man, behave as if in a raid for baseline
-- purposes so Stockades visibly exercises the off/on transition.
local function effectiveRaidLike()
    if isInRaid() then return true end
    if isDebugOn() then
        local _, instanceType = IsInInstance()
        if instanceType == "party" then return true end
    end
    return false
end

local function setBaseline()
    if not isClassEnabled() then return end
    local d = effectiveRaidLike() and RAID_DENSITY or OUTSIDE_DENSITY
    SetCVar("graphicsParticleDensity", d)
    dprint("baseline density = " .. d)
end

-- Returns (managed, info). `info` is the entry from encounterIndex (or nil)
-- so callers can log the boss name for unmanaged encounters too.
local function checkManaged(encounterID)
    local info = getEncounterIndex()[encounterID]
    if not info then return false, nil end
    local s = settings()
    if not s then return false, info end
    local r = s[info.raidKey]
    if not r or not r.enabled then return false, info end
    return r.bosses and r.bosses[info.name] == true, info
end

-- Seconds to keep particles on after this encounter ends, or nil for none.
-- A profile that predates the per-boss linger settings has no `linger` table
-- for the raid, so it falls back to the boss's built-in default; once the UI
-- has seeded that table the user's choice is authoritative (an unticked boss
-- means no linger, even if it has a built-in default).
local function getLingerSeconds(encounterID)
    local info = getEncounterIndex()[encounterID]
    if not info then return nil end
    local s = settings()
    local raidData = s and s[info.raidKey]
    local secs
    if raidData and raidData.linger then
        if not raidData.linger[info.name] then return nil end
        secs = raidData.lingerSecs and tonumber(raidData.lingerSecs[info.name]) or info.linger
    else
        secs = info.linger
    end
    if secs and secs > 0 then return secs end
    return nil
end

local state = { currentEncounterID = nil, lingerTimer = nil }

local function cancelLinger()
    if state.lingerTimer then
        state.lingerTimer:Cancel()
        state.lingerTimer = nil
    end
end

local function onEncounterStart(encounterID, encounterName)
    local managed, info = checkManaged(encounterID)
    local displayName = (info and info.name) or encounterName or "?"
    dprint(string.format("ENCOUNTER_START id=%s name=%s%s",
        tostring(encounterID), tostring(displayName),
        managed and "" or " — not managed"))
    if not managed or not isClassEnabled() then return end
    state.currentEncounterID = encounterID
    cancelLinger()
    local d = getEncounterDensity()
    SetCVar("graphicsParticleDensity", d)
    dprint("  -> density " .. d)
end

local function onEncounterEnd(encounterID, encounterName)
    dprint(string.format("ENCOUNTER_END id=%s name=%s",
        tostring(encounterID), tostring(encounterName or "?")))
    if state.currentEncounterID ~= encounterID then return end
    state.currentEncounterID = nil

    local linger = getLingerSeconds(encounterID)
    if linger then
        dprint("  -> linger " .. linger .. "s, then baseline")
        state.lingerTimer = C_Timer.NewTimer(linger, function()
            state.lingerTimer = nil
            setBaseline()
        end)
    else
        setBaseline()
    end
end

local function onRegenEnabled()
    -- Safety reset on leaving combat — but only if we're not mid-encounter
    -- (e.g. Kel'Thuzad phase transitions) and not currently lingering.
    if state.currentEncounterID then return end
    if state.lingerTimer then return end
    setBaseline()
end

local function onEnteringWorld()
    state.currentEncounterID = nil
    cancelLinger()
    setBaseline()
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("ENCOUNTER_START")
frame:RegisterEvent("ENCOUNTER_END")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ENCOUNTER_START" then
        onEncounterStart(...)
    elseif event == "ENCOUNTER_END" then
        onEncounterEnd(...)
    elseif event == "PLAYER_REGEN_ENABLED" then
        onRegenEnabled()
    elseif event == "PLAYER_ENTERING_WORLD" then
        onEnteringWorld()
    end
    -- PLAYER_REGEN_DISABLED is registered to match the original WA event
    -- list but requires no action — combat-start state is fully handled by
    -- ENCOUNTER_START.
end)

-- Re-applies the baseline particle density from current settings (e.g. after
-- a profile switch changes which class is enabled). No-op mid-encounter or
-- mid-linger, same as the existing PLAYER_REGEN_ENABLED safety check.
local function refresh()
    if state.currentEncounterID then return end
    if state.lingerTimer then return end
    setBaseline()
end

addon.Particles = { state = state, refresh = refresh } -- state exposed for inspection if needed
