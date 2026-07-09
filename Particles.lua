local addonName, addon = ...

-- Backend port of the user's particle WeakAura.
--
-- Density values mirror the original WeakAura:
--   outside raid -> 3 (normal)
--   inside  raid -> 0 (off, for FPS)
--   managed encounter -> 3 (force on so mechanics are visible)
-- Linger durations keep particles ON for N seconds after the listed encounters
-- end (covers Viscidus slime puddle, Ouro residue, etc.). Linger list is
-- backend-only by design — not exposed in the UI.

local OUTSIDE_DENSITY = 3
local RAID_DENSITY    = 0

local function settings()
    return addon.db and addon.db.settings and addon.db.settings.particles
end

local function getEncounterDensity()
    local s = settings()
    return (s and s.general and s.general.encounterDensity) or 3
end

local function isClassEnabled()
    local s = settings()
    local classes = s and s.classes
    if not classes then return false end
    local _, classToken = UnitClass("player")
    return classes[classToken] == true
end

local LINGER = {
    [713]  = 15, -- Viscidus
    [716]  = 30, -- Ouro
    [1119] = 10, -- Sapphiron
    [2756] = 10, -- Targorr the Dread
    [2757] = 10, -- Kam Deepfury
    [2758] = 10, -- Hamhock
    [2759] = 10, -- Dextren Ward
    [2760] = 10, -- Bazil Thredd
}

-- encounterID -> { raidKey, name }, built lazily on first event so file load
-- stays cheap and we tolerate Raids.lua being reloaded.
local encounterIndex
local function getEncounterIndex()
    if encounterIndex then return encounterIndex end
    encounterIndex = {}
    for _, raid in ipairs(addon.RAIDS or {}) do
        for _, boss in ipairs(raid.bosses) do
            if boss.id then
                encounterIndex[boss.id] = { raidKey = raid.key, name = boss.name }
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

    local linger = LINGER[encounterID]
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
