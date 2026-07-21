local addonName, addon = ...

-- ─────────────────────────────────────────────────────────────────────────────
--  Driev's Essentials — State manager
--
--  Problem: WoW's instance/group API returns garbage for ~0.5–1 s after every
--  zone transition, reload, or login.  Any code that calls IsInInstance() /
--  GetInstanceInfo() during that window gets false data.
--
--  Solution: a settle gate.
--    • On each zone event we mark ready=false and arm a timer.
--    • The timer fires after SETTLE_DELAY seconds.  We snapshot the API *then*,
--      store the values, set ready=true, and notify all registered modules.
--    • Public accessors return nil / false when not ready.
--    • A debug logger writes timestamped entries into SavedVariables so you can
--      see exactly what the API returned after every transition — across sessions.
-- ─────────────────────────────────────────────────────────────────────────────

local State = {}
addon.State = State

-- ── tunables ──────────────────────────────────────────────────────────────────
local SETTLE_DELAY = 0.8   -- seconds to wait after a zone event before trusting the API
local MAX_LOG      = 300   -- rolling cap on persisted log entries

-- ── debug log ─────────────────────────────────────────────────────────────────
-- Stored under DrievSettingsDB.debug so it survives /reload and relog.

local function debugDB()
    if not DrievSettingsDB then return nil end
    DrievSettingsDB.debug = DrievSettingsDB.debug or { enabled = false, log = {} }
    return DrievSettingsDB.debug
end

local function dbg(msg)
    local d = debugDB()
    if not d or not d.enabled then return end
    local entry = format("|cffaaaaaa[%.2f]|r %s", GetTime(), msg)
    tinsert(d.log, entry)
    if #d.log > MAX_LOG then tremove(d.log, 1) end
end

function State.isDebugEnabled()
    local d = debugDB()
    return d and d.enabled or false
end

function State.setDebug(v)
    local d = debugDB()
    if not d then
        print("|cfffb2c36DE:|r SavedVariables not ready yet — try again after login.")
        return
    end
    d.enabled = v and true or false
    if v then
        dbg("debug logging enabled")
        print("|cfffb2c36Driev's Essentials|r debug |cff00ff00ENABLED|r — use /de debug print to dump the log.")
    else
        print("|cfffb2c36Driev's Essentials|r debug |cffff6666DISABLED|r.")
    end
end

function State.clearLog()
    local d = debugDB()
    if not d then return end
    d.log = {}
    print("|cfffb2c36Driev's Essentials|r debug log cleared.")
end

function State.printLog()
    local d = debugDB()
    if not d or #d.log == 0 then
        print("|cfffb2c36Driev's Essentials|r debug log is empty.")
        return
    end
    print(format("|cfffb2c36Driev's Essentials|r — debug log (%d / %d entries):", #d.log, MAX_LOG))
    for _, line in ipairs(d.log) do
        print(line)
    end
end

-- ── internal state ────────────────────────────────────────────────────────────
local ready        = false
local instanceType = nil   -- "none" | "party" | "raid" | "arena" | "pvp" | nil-if-not-ready
local instanceName = nil
local inCombat     = false

-- ── settle timer (frame OnUpdate — no C_Timer dependency) ─────────────────────
-- Pushing validateAt forward on repeated events means the last event in a burst
-- wins: we always wait SETTLE_DELAY from the *most recent* trigger.
local validateAt = 0

local function scheduleValidate(reason)
    ready       = false
    validateAt  = GetTime() + SETTLE_DELAY
    dbg(format("SETTLE ARMED (+%.1fs) [%s]", SETTLE_DELAY, reason or "?"))
end

local timerFrame = CreateFrame("Frame")
timerFrame:SetScript("OnUpdate", function()
    if validateAt == 0 or GetTime() < validateAt then return end
    validateAt = 0

    -- Snapshot the API now that it should be stable.
    local inInst, iType = IsInInstance()
    local iName         = GetInstanceInfo()
    local zone          = GetRealZoneText() or GetZoneText() or "?"
    local isRaid        = IsInRaid()
    local isGroup       = IsInGroup()
    local numMembers    = GetNumGroupMembers and GetNumGroupMembers() or 0

    dbg(format("SNAPSHOT: inInst=%s iType=%s iName=%s zone=%s IsInRaid=%s IsInGroup=%s members=%d",
        tostring(inInst), tostring(iType), tostring(iName), tostring(zone),
        tostring(isRaid), tostring(isGroup), numMembers))

    instanceType = iType or "none"
    instanceName = iName or ""
    ready        = true

    dbg(format("READY  instanceType=|cff00ff00%s|r  instanceName=%s", instanceType, instanceName))

    -- Notify modules — each module can expose an onStateReady hook.
    if addon.Raid      and addon.Raid.onStateReady      then addon.Raid.onStateReady()      end
    if addon.Particles and addon.Particles.onStateReady then addon.Particles.onStateReady() end
    if addon.TTK       and addon.TTK.onStateReady       then addon.TTK.onStateReady()       end
end)

-- ── event handler ─────────────────────────────────────────────────────────────
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        -- Args (isInitialLogin, isReloadingUi) present in 1.14+; log either way.
        local a1, a2 = ...
        dbg(format("PLAYER_ENTERING_WORLD  isLogin=%s  isReload=%s", tostring(a1), tostring(a2)))
        scheduleValidate("PLAYER_ENTERING_WORLD")

    elseif event == "ZONE_CHANGED_NEW_AREA" then
        dbg("ZONE_CHANGED_NEW_AREA")
        scheduleValidate("ZONE_CHANGED_NEW_AREA")

    elseif event == "GROUP_ROSTER_UPDATE" then
        if ready then
            -- Group composition changed while we were stable.
            -- The instance type hasn't changed, but raid membership might have.
            -- Re-settle briefly so instanceType / membership are re-snapshotted.
            dbg("GROUP_ROSTER_UPDATE (was ready) -> re-settling")
            scheduleValidate("GROUP_ROSTER_UPDATE")
        else
            dbg("GROUP_ROSTER_UPDATE (not ready) -> ignored")
        end

    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        dbg("PLAYER_REGEN_DISABLED -> inCombat=true")

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        dbg("PLAYER_REGEN_ENABLED -> inCombat=false")
    end
end)

-- ── public API ────────────────────────────────────────────────────────────────

--- Returns true once the API has settled after the last zone event.
function State.isReady()          return ready end

--- True only when ready AND the instance type is "raid".
function State.isInRaidInstance() return ready and instanceType == "raid" end

--- True when inside any instanced content (party, raid, arena, pvp).
function State.isInInstance()
    return ready and instanceType ~= nil and instanceType ~= "none"
end

--- The validated instance type string, or nil when not ready.
function State.getInstanceType()  return ready and instanceType or nil end

--- The validated instance name string, or nil when not ready.
function State.getInstanceName()  return ready and instanceName or nil end

--- Combat state is tracked independently — no settle gate needed here.
function State.isInCombat()       return inCombat end
