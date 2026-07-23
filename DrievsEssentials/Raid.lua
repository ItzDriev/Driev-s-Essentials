local addonName, addon = ...

local NAMES_CVARS = {
    "UnitNameFriendlyPlayerName",
    "UnitNameFriendlyPetName",
    "UnitNameFriendlyGuardianName",
    "UnitNameFriendlyTotemName",
}

local function raidSettings()
    return addon.db and addon.db.settings and addon.db.settings.raid
end

-- All instance checks go through the State gate.
-- Returns false when the API hasn't settled yet (safe default: no CVars applied).
local function effectiveRaidLike()
    local S = addon.State
    if not S or not S.isReady() then return false end
    if S.isInRaidInstance() then return true end
    local s = raidSettings()
    if s and s.enabled and s.debug and S.getInstanceType() == "party" then return true end
    return false
end

-- SetCVar is a protected function — it throws ADDON_ACTION_BLOCKED when called
-- during combat lockdown.  We store a pending flag and retry on PLAYER_REGEN_ENABLED.
local pendingApply = false

-- Master switch off by default (see UI.lua's "Enable Raid Settings" checkbox).
-- Rather than early-returning, apply() always runs and simply treats the
-- sub-settings as off when the master is off — that way flipping the master
-- switch off mid-raid resets the CVars immediately instead of leaving names/
-- bubbles hidden until the raid is left (which is when revert() would
-- otherwise be the only thing to undo them).
local function apply()
    if InCombatLockdown() then
        pendingApply = true
        return
    end
    pendingApply = false
    local s = raidSettings()
    if not s then return end
    local disableNames   = s.enabled and s.disableNames
    local disableBubbles = s.enabled and s.disableChatBubbles
    local nameVal = disableNames and 0 or 1
    for _, cvar in ipairs(NAMES_CVARS) do SetCVar(cvar, nameVal) end
    SetCVar("chatBubbles", disableBubbles and 0 or 1)
end

local function revert()
    if InCombatLockdown() then
        pendingApply = true
        return
    end
    pendingApply = false
    local s = raidSettings()
    if not s then return end
    if s.enabled and s.disableNames then
        for _, cvar in ipairs(NAMES_CVARS) do SetCVar(cvar, 1) end
    end
    if s.enabled and s.disableChatBubbles then
        SetCVar("chatBubbles", 1)
    end
end

local function refresh()
    if effectiveRaidLike() then apply() else revert() end
end

-- Retry deferred CVars once combat ends.
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_ENABLED" and pendingApply then
        refresh()
    end
end)

-- No zone/group event handling here — State.lua owns that and calls
-- onStateReady once the API has settled after each transition.
addon.Raid = {
    refresh      = refresh,
    onStateReady = refresh,
}
