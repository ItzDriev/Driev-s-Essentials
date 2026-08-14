local addonName, addon = ...

-- ── Aura duration engine ─────────────────────────────────────────────────────
-- Classic Era hands out `duration` and `expirationTime` only for auras the
-- player applied. Every debuff a raidmate put on the boss and every buff a mob
-- is running comes back with a duration of zero, which is why an aura strip
-- that trusts the client draws a bare icon with no swipe for most of what is
-- actually on a target.
--
-- This rebuilds the missing numbers from the combat log: watch every aura
-- application in range, look the spell up in a table of 1.12 durations, and
-- keep a per-GUID record of when it started. A reader asks for a spell on a
-- unit and gets back the pair the client would not give it.
--
-- It is a reconstruction, and where it can be wrong is worth knowing up front:
--
--   - An aura applied before the unit came into combat log range has no start
--     time here, so it reports nothing rather than something wrong. Walking up
--     to a mob mid-fight will not retroactively produce timers.
--   - Talent- and set-bonus-scaled durations are exact only for our own casts;
--     for anyone else the untalented value is used.
--   - Nothing here outranks the client. A real duration from the API always
--     wins and this only fills in the zeroes — see D.GetDuration's callers.
--
-- The spell rules live in Spells.lua (players) and NPCSpells.lua (creatures),
-- the crowd-control brackets in DiminishingReturns.lua. Those three files are
-- data transcribed from LibClassicDurations by d87, which worked all of this
-- out first. The engine below is ours, so what it does with that data — when
-- it runs, what it exposes, how DR is applied — is ours to change.

-- Era-only by construction. Guarded rather than assumed so that a client which
-- has real durations never pays for a combat log scan it does not need; every
-- consumer already has to cope with the module being absent.
if WOW_PROJECT_ID and WOW_PROJECT_CLASSIC and WOW_PROJECT_ID ~= WOW_PROJECT_CLASSIC then
    return
end

local D = {}
addon.Durations = D

-- ── Tables ───────────────────────────────────────────────────────────────────
-- guids[dstGUID][spellID] is one application record:
--
--   { duration, startTime, auraType, comboPoints, drMultiplier }
--
-- ...unless the spell stacks per caster, in which case that slot holds
-- `{ applications = { [srcGUID] = record } }` instead. Two warlocks' Corruption
-- on one target are two timers, and collapsing them would make both wrong.
-- An array rather than a keyed table on purpose: there is one of these per aura
-- per unit in range, and they are written on every application in a raid pull.
D.guids   = {}
D.spells  = {}   -- spellID -> opts, filled by Spells.lua
D.npcSpells = {} -- spellID -> duration, replaced wholesale by NPCSpells.lua

-- Filled by DiminishingReturns.lua; declared here so the engine reads a table
-- rather than a nil when that file is absent or fails to load.
D.drCategory      = {}
D.drPvECategories = {}

-- Highest-rank ID for a spell name. The combat log has carried real spell IDs
-- on aura events for years, but SPELL_MISSED still arrives without one, and
-- name is all we have to work back from.
D.spellNameToID = {}

-- Auras that no aura event ever announces: Sunder's stack refresh, Winter's
-- Chill from a Frostbolt landing, Ignite's tick extension. Keyed by the name of
-- the spell whose damage or cast event implies the refresh. Spells.lua fills it.
D.indirectRefreshSpells = {}

local guids       = D.guids
local spells      = D.spells
local spellNameToID = D.spellNameToID

local DRInfo          = {}   -- dstGUID -> category -> { level, expires }
local buffCache       = {}   -- dstGUID -> synthesized enemy buff list
local buffCacheValid  = {}   -- dstGUID -> timestamp the cache goes stale at
local nameplateUnitMap = {}  -- dstGUID -> "nameplateN", for firing at readers
local castLog         = {}   -- srcGUID -> { spellID, timestamp }, for castFilter
local guidAccessTimes = {}   -- dstGUID -> time(), drives the purge
local npcSpellNameToID = {}  -- built in slices after login, see below

local INFINITY        = math.huge
local PURGE_INTERVAL  = 900
local PURGE_THRESHOLD = 1800
local BUFF_CACHE_TTL  = 40

-- The combat log fires more than anything else in the game; every one of these
-- is looked up on the hot path.
local bit_band   = bit.band
local GetTime    = GetTime
local UnitGUID   = UnitGUID
local time       = time
local tinsert    = table.insert
local CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo

local OBJECT_TYPE_PLAYER       = COMBATLOG_OBJECT_TYPE_PLAYER
local OBJECT_CONTROL_PLAYER    = COMBATLOG_OBJECT_CONTROL_PLAYER
local OBJECT_REACTION_FRIENDLY = COMBATLOG_OBJECT_REACTION_FRIENDLY
local OBJECT_AFFILIATION_MINE  = COMBATLOG_OBJECT_AFFILIATION_MINE

local _, playerClass = UnitClass("player")
local playerGUID = UnitGUID("player")

-- Classic Era still has the globals, but prefer C_Spell where the client has
-- it, matching Data.SpellInfo in the nameplate module.
local spellName, spellTexture
if C_Spell and C_Spell.GetSpellInfo then
    spellName = function(id)
        local info = C_Spell.GetSpellInfo(id)
        return info and info.name
    end
else
    spellName = function(id) return (GetSpellInfo(id)) end
end
if C_Spell and C_Spell.GetSpellTexture then
    spellTexture = function(id) return C_Spell.GetSpellTexture(id) end
else
    spellTexture = function(id) return GetSpellTexture(id) end
end
D.SpellName = spellName

local f = CreateFrame("Frame")
D.frame = f
f:SetScript("OnEvent", function(self, event, ...)
    return self[event](self, event, ...)
end)

-- ── Building the spell table ─────────────────────────────────────────────────

-- Called as `Spell(id, opts)` from the data files. `id` is one ID or a list of
-- ranks sharing one rule; the last entry is treated as the highest rank, which
-- is what a name has to resolve to when the log gives us no ID.
function D.AddAura(id, opts)
    if not opts then return end

    local lastRankID = id
    if type(id) == "table" then
        lastRankID = id[#id]
    end

    local name = spellName(lastRankID)
    -- A spell the client does not know (wrong locale, wrong client) is skipped
    -- rather than stored under a nil name, which would poison the name lookup.
    if not name then return end
    spellNameToID[name] = lastRankID

    if type(id) == "table" then
        for _, spellID in ipairs(id) do
            spells[spellID] = opts
        end
    else
        spells[id] = opts
    end
end

-- Rank of the first of these talent spells the PLAYER knows, 0 for none. Only
-- ever true for our own casts — nothing in Classic reports another player's
-- talents — which is why the duration functions branch on isSrcPlayer before
-- using it.
function D.Talent(...)
    for i = 1, 5 do
        local spellID = select(i, ...)
        if not spellID then break end
        if IsPlayerSpell(spellID) then return i end
    end
    return 0
end

-- Names for the NPC table, built in slices well after login. It is several
-- thousand GetSpellInfo calls for a table that only matters when the log hands
-- us a spell name with no ID, so it must not sit in the login frame.
local npcScanCursor
local function buildNPCSpellNames()
    local dataTable = D.npcSpells
    local counter = 0
    local id = next(dataTable, npcScanCursor)
    while id and counter < 300 do
        local name = spellName(id)
        if name then npcSpellNameToID[name] = id end
        counter = counter + 1
        npcScanCursor = id
        id = next(dataTable, npcScanCursor)
    end
    if id then C_Timer.After(1, buildNPCSpellNames) end
end

local function lastRankIDForName(name)
    return spellNameToID[name] or npcSpellNameToID[name]
end
D.LastRankIDForName = lastRankIDForName

-- ── Item set bonuses ─────────────────────────────────────────────────────────
-- Three durations in 1.12 change with a set bonus (Renew with Oracle 5pc,
-- Rejuvenation with Stormrage 8pc, Psychic Scream with the priest PvP 3pc), so
-- the engine has to know what the player is wearing. Only the player's own
-- gear is knowable, which is fine: those branches are all behind isSrcPlayer.

local itemSets = {}

function D:TrackItemSet(setname, itemArray)
    local set = itemSets[setname]
    if not set then
        set = { items = {}, bonuses = {} }
        itemSets[setname] = set
        for _, itemID in ipairs(itemArray) do
            set.items[itemID] = true
        end
    end
end

function D:RegisterSetBonusCallback(setname, pieces, onEquip, onRemove)
    local set = itemSets[setname]
    if not set then return end
    set.bonuses[pieces] = { equipped = false, on = onEquip, off = onRemove }
end

function D:IsSetBonusActive(setname, pieces)
    local set = itemSets[setname]
    if not set then return false end
    local bonus = set.bonuses[pieces]
    return (bonus and bonus.equipped) or false
end

local function refreshSetBonuses()
    for _, set in pairs(itemSets) do
        local equipped = 0
        -- 1..17 excludes the ranged slot, which no tracked set uses.
        for slot = 1, 17 do
            local itemID = GetInventoryItemID("player", slot)
            if itemID and set.items[itemID] then equipped = equipped + 1 end
        end
        for pieces, bonus in pairs(set.bonuses) do
            local active = equipped >= pieces
            if active ~= bonus.equipped then
                bonus.equipped = active
                local handler = active and bonus.on or bonus.off
                if handler then handler() end
            end
        end
    end
end

-- ── Diminishing returns ──────────────────────────────────────────────────────
-- Two crowd-control spells in the same bracket cut each other down: full, half,
-- quarter, immune, and the bracket clears ~18s after the last one ends.
--
-- The level is counted when a CC is REMOVED or REFRESHED, not when it lands,
-- because that is the moment the next one in the bracket becomes weaker. The
-- combat log hands us those events in order, so by the time an application is
-- recorded the bracket already reflects everything before it.

local DR_RESET      = 18.4
local DR_MULTIPLIER = { 0.5, 0.25, 0 }

local function addDRLevel(dstGUID, category)
    local guidTable = DRInfo[dstGUID]
    if not guidTable then
        guidTable = {}
        DRInfo[dstGUID] = guidTable
    end

    local catTable = guidTable[category]
    if not catTable then
        catTable = { level = 0, expires = 0 }
        guidTable[category] = catTable
    end

    local now = GetTime()
    -- Past immune, or the window lapsed: the ladder starts over.
    if (catTable.expires or 0) <= now or catTable.level >= 3 then
        catTable.level = 0
    end
    catTable.level   = catTable.level + 1
    catTable.expires = now + DR_RESET
end

-- The multiplier an aura landing *right now* would be cut by.
local function currentDRMul(dstGUID, spellID)
    local category = D.drCategory[spellID]
    if not category then return 1 end

    local guidTable = DRInfo[dstGUID]
    if not guidTable then return 1 end
    local catTable = guidTable[category]
    if not catTable then return 1 end
    if (catTable.expires or 0) <= GetTime() then return 1 end

    return DR_MULTIPLIER[catTable.level] or 1
end
D.GetDRMultiplier = currentDRMul

local function countDR(eventType, dstGUID, dstFlags, spellID, auraType)
    if auraType ~= "DEBUFF" then return end
    if eventType ~= "SPELL_AURA_REMOVED" and eventType ~= "SPELL_AURA_REFRESH" then return end

    local category = D.drCategory[spellID]
    if not category then return end

    -- DR is a PvP rule with two exceptions: stuns and Kidney Shot diminish on
    -- creatures too. Everything else lands at full duration on a mob every time.
    local isDstPlayer = bit_band(dstFlags, OBJECT_TYPE_PLAYER) > 0
    if not isDstPlayer and not D.drPvECategories[category] then return end

    addDRLevel(dstGUID, category)
end

-- ── Combo points ─────────────────────────────────────────────────────────────
-- Rupture and Kidney Shot scale with the combo points spent, and the points are
-- already gone by the time the aura event arrives — so keep the previous value
-- and use whichever of the two is larger.

local cpWas, cpNow = 0, 0
local function currentCP()
    if not cpNow then return GetComboPoints("player", "target") end
    return cpWas > cpNow and cpWas or cpNow
end

function f:UNIT_POWER_UPDATE(event, unit, ptype)
    if ptype == "COMBO_POINTS" then
        cpWas = cpNow
        cpNow = GetComboPoints(unit, "target")
    end
end
function f:PLAYER_TARGET_CHANGED(event)
    return self:UNIT_POWER_UPDATE(event, "player", "COMBO_POINTS")
end

-- ── Application records ──────────────────────────────────────────────────────

-- A duration may be a function of rank, caster and combo points; resolve it at
-- the moment of application so the record holds a number.
local function resolveDuration(duration, spellID, srcGUID, comboPoints)
    if type(duration) == "function" then
        return duration(spellID, srcGUID == playerGUID, comboPoints)
    end
    return duration
end

-- Records are filed under the HIGHEST-RANK id of the spell's name, never the id
-- the event happened to carry. Classic's combat log is inconsistent about which
-- it gives for aura events — zero on some builds, the real rank on others — and
-- a store keyed on whatever arrived would silently stop matching a reader that
-- looked the aura up by the rank it saw. One name, one record, either way.
--
-- The rank-specific id still travels alongside as `spellID`, because that is
-- what the duration rules branch on.
local function storeKeyFor(name, spellID)
    return lastRankIDForName(name) or spellID
end

local function getRecord(srcGUID, dstGUID, key)
    local guidTable = guids[dstGUID]
    if not guidTable then return end

    local spellTable = guidTable[key]
    if not spellTable then return end

    if spellTable.applications then
        return spellTable.applications[srcGUID]
    end
    return spellTable
end

-- Spells.lua's Ignite handling reaches for the live record; it deals in a
-- single-rank id, which is its own store key.
function D:GetSpellTable(srcGUID, dstGUID, spellID)
    return getRecord(srcGUID, dstGUID, storeKeyFor(spellName(spellID), spellID))
end

-- Push the start time forward without touching the stored duration — what an
-- indirect refresh (a Sunder re-application, a Frostbolt landing) amounts to.
local function refreshRecord(srcGUID, dstGUID, key, overrideTime)
    local record = getRecord(srcGUID, dstGUID, key)
    if not record then return end

    local oldStartTime = record[2]
    record[2] = overrideTime or GetTime()
    return true, oldStartTime
end

local function clearRecord(guidTable, srcGUID, key, isStacking)
    local spellTable = guidTable[key]
    if not spellTable then return end
    if isStacking then
        if spellTable.applications then
            spellTable.applications[srcGUID] = nil
        end
    else
        guidTable[key] = nil
    end
end

-- How long an aura lasts at the moment it lands: the rank/talent/combo-point
-- rule resolved to a number, with the PvP cap swapped in for a player-
-- controlled target. Diminishing returns are NOT folded in here — setRecord
-- keeps that as a separate factor so it can be reported on its own.
--
-- Returns nil when the rule says the duration is unknowable, which callers must
-- pass on as "no timer" rather than substituting a guess.
local function resolveApplied(spellID, srcGUID, opts, dstIsPlayerControlled)
    local comboPoints
    if srcGUID == playerGUID and playerClass == "ROGUE" then
        comboPoints = currentCP()
    end

    local duration = opts.duration
    -- A 50s Polymorph is 20s on another player, before DR touches it.
    if opts.pvpduration and dstIsPlayerControlled then
        duration = opts.pvpduration
    end

    return resolveDuration(duration, spellID, srcGUID, comboPoints), comboPoints
end

-- The same answer for a caller reading the combat log itself, which already
-- knows the aura just landed and only needs its length. Order-independent by
-- construction: it consults the spell rules rather than this engine's records,
-- so it does not matter whether our own handler ran first.
function D.GetAppliedDuration(spellID, name, srcGUID, dstGUID, dstIsPlayerControlled)
    if not spellID then return end

    local opts = spells[spellID]
    if not opts then
        -- Creature spells carry no rules beyond the number itself.
        local npcDuration = D.npcSpells[spellID]
        if npcDuration then return npcDuration end
        -- One more try by name: the log may have handed us a rank id we have no
        -- entry for while the name still resolves to one we do.
        local key = name and lastRankIDForName(name)
        opts = key and spells[key]
        if not opts then return end
        spellID = key
    end

    local duration = resolveApplied(spellID, srcGUID, opts, dstIsPlayerControlled)
    if not duration or duration == INFINITY then return end

    return duration * currentDRMul(dstGUID, spellID)
end

local function setRecord(srcGUID, dstGUID, dstFlags, spellID, key, opts, auraType, doRemove)
    if not opts or not key then return end

    local guidTable = guids[dstGUID]
    if not guidTable then
        guidTable = {}
        guids[dstGUID] = guidTable
    end

    local isStacking = opts.stacking

    if doRemove then
        return clearRecord(guidTable, srcGUID, key, isStacking)
    end

    -- Resolve before allocating: a duration function is allowed to return nil
    -- for "we cannot know this" — an unspecced mage's Winter's Chill, a priest
    -- without Shadow Weaving — and storing that would produce a timer that
    -- never moves instead of no timer at all.
    local duration, comboPoints = resolveApplied(
        spellID, srcGUID, opts, bit_band(dstFlags, OBJECT_CONTROL_PLAYER) > 0)

    if not duration then
        return clearRecord(guidTable, srcGUID, key, isStacking)
    end

    local spellTable = guidTable[key]
    if not spellTable then
        spellTable = {}
        guidTable[key] = spellTable
        if isStacking then spellTable.applications = {} end
    end

    local record
    if isStacking then
        record = spellTable.applications[srcGUID]
        if not record then
            record = {}
            spellTable.applications[srcGUID] = record
        end
    else
        record = spellTable
    end

    record[1] = duration
    record[2] = GetTime()
    record[3] = auraType
    record[4] = comboPoints
    -- DR is snapshotted here rather than applied when the timer is read: the
    -- bracket was already advanced by the removal that preceded this landing,
    -- and a bracket that lapses while a long CC is still ticking must not make
    -- the running timer jump back up to full.
    record[5] = currentDRMul(dstGUID, spellID)

    guidAccessTimes[dstGUID] = time()
end

-- ── Indirect refreshes ───────────────────────────────────────────────────────
-- Some auras are extended by an event that never mentions them: Sunder Armor's
-- stack timer resets on the cast, Winter's Chill on a Frostbolt landing, Fire
-- Vulnerability on a Scorch. Spells.lua describes those as a table keyed by the
-- *triggering* spell's name.

-- Weak values: a rollback entry is only interesting for the half second after
-- it is written, and nothing else keeps these alive.
local rollbackTable = setmetatable({}, { __mode = "v" })
local lastResistSpellID, lastResistTime = nil, 0

local function procIndirectRefresh(eventType, name, srcGUID, srcFlags, dstGUID, dstFlags, isCrit)
    local targetSpells = D.indirectRefreshSpells[name]
    if not targetSpells then return end

    for targetSpellID, refresh in pairs(targetSpells) do
        if refresh.events[eventType] then
            local targetKey = storeKeyFor(spellName(targetSpellID), targetSpellID)
            local condition = refresh.condition
            if condition then
                local isMine = bit_band(srcFlags, OBJECT_AFFILIATION_MINE) == OBJECT_AFFILIATION_MINE
                if not condition(isMine, isCrit) then return end
            end

            -- A spell that just resisted did not refresh anything, but the
            -- damage event can still arrive first.
            if refresh.targetResistCheck then
                if lastResistSpellID == targetSpellID and GetTime() - lastResistTime < 0.4 then
                    return
                end
            end

            if refresh.applyAura then
                local opts = spells[targetSpellID]
                if opts then
                    setRecord(srcGUID, dstGUID, dstFlags, targetSpellID, targetKey, opts, "DEBUFF")
                end
            elseif refresh.customAction then
                refresh.customAction(srcGUID, dstGUID, targetSpellID)
            else
                local _, oldStartTime = refreshRecord(srcGUID, dstGUID, targetKey)
                -- A miss arrives after the swing that implied the refresh, so
                -- keep what the timer was in case we have to put it back.
                if refresh.rollbackMisses and oldStartTime then
                    local bySource = rollbackTable[srcGUID]
                    if not bySource then
                        bySource = {}
                        rollbackTable[srcGUID] = bySource
                    end
                    local byTarget = bySource[dstGUID]
                    if not byTarget then
                        byTarget = {}
                        bySource[dstGUID] = byTarget
                    end
                    byTarget[targetSpellID] = { GetTime(), oldStartTime }
                end
            end
        end
    end
end

-- ── Ignite ───────────────────────────────────────────────────────────────────
-- Ignite is its own case: a crit rolls the remaining damage into a fresh 4s,
-- but only if it has ticked since the last extension. Tracking it means
-- watching the ticks, which no generic rule in the table can express.

local igniteName = spellName(12654)
local igniteOpts = { duration = 4 }

local function igniteHandler(eventType, srcGUID, dstGUID, dstFlags, auraType)
    if eventType == "SPELL_AURA_APPLIED" then
        setRecord(srcGUID, dstGUID, dstFlags, 12654, 12654, igniteOpts, auraType)
        local record = getRecord(srcGUID, dstGUID, 12654)
        -- Treat the application itself as an extension so the first tick is
        -- not counted twice.
        if record then record.tickExtended = true end
    elseif eventType == "SPELL_PERIODIC_DAMAGE" then
        local record = getRecord(srcGUID, dstGUID, 12654)
        if record then record.tickExtended = false end
    elseif eventType == "SPELL_AURA_REMOVED" then
        setRecord(srcGUID, dstGUID, dstFlags, 12654, 12654, igniteOpts, auraType, true)
    end
end

-- ── Combat log ───────────────────────────────────────────────────────────────

local castFilterSnapshot

-- A cast is "current" for a source if it was the last thing they cast and it
-- was within the window. Long raid buffs are only believed when we saw the
-- cast, so this is what separates a real Fortitude from the AURA_APPLIED the
-- client fires the moment a player with an hour-old one walks into range.
local function isCastCurrent(srcGUID, spellID, now, window)
    local entry = castLog[srcGUID]
    if not entry then return false end
    return entry[1] == spellID and (now - entry[2] < window)
end

function f:COMBAT_LOG_EVENT_UNFILTERED()
    return self:HandleCombatLog(CombatLogGetCurrentEventInfo())
end

function f:HandleCombatLog(...)
    local timestamp, eventType, hideCaster,
          srcGUID, srcName, srcFlags, srcFlags2,
          dstGUID, dstName, dstFlags, dstFlags2,
          spellID, name, spellSchool, auraType, _, _, _, _, _, isCrit = ...

    procIndirectRefresh(eventType, name, srcGUID, srcFlags, dstGUID, dstFlags, isCrit)

    if name == igniteName then
        igniteHandler(eventType, srcGUID, dstGUID, dstFlags, auraType)
    end

    if eventType == "SPELL_MISSED"
       and bit_band(srcFlags, OBJECT_AFFILIATION_MINE) == OBJECT_AFFILIATION_MINE then
        local missType = auraType -- the miss type rides in the aura-type slot
        if missType ~= "ABSORB" and missType ~= "BLOCK" then
            -- Sunder's timer was already pushed forward by the cast; a miss
            -- means it never landed, so put the old start time back.
            --
            -- The entry has to be found by iterating. indirectRefreshSpells
            -- maps a trigger name to a TABLE of target spells and the target's
            -- id is that table's key; the redundant `targetSpellID` field is
            -- left unset on several entries — Sunder's among them — so reaching
            -- for it instead of the key is how a rollback quietly never fires.
            local targetSpells = D.indirectRefreshSpells[name]
            local bySource = targetSpells and rollbackTable[srcGUID]
            local byTarget = bySource and bySource[dstGUID]
            if byTarget then
                for targetSpellID, refresh in pairs(targetSpells) do
                    local snapshot = refresh.rollbackMisses and byTarget[targetSpellID]
                    if snapshot and GetTime() - snapshot[1] < 0.5 then
                        refreshRecord(srcGUID, dstGUID,
                            storeKeyFor(spellName(targetSpellID), targetSpellID),
                            snapshot[2])
                    end
                end
            end

            local resistID = lastRankIDForName(name)
            if not resistID then return end
            lastResistSpellID = resistID
            lastResistTime    = GetTime()
        end
    end

    if auraType == "BUFF" or auraType == "DEBUFF" or eventType == "SPELL_CAST_SUCCESS" then
        if spellID == 0 then
            -- No ID on the event: treat it as the highest rank of that name,
            -- which is what the rules are keyed on anyway. Rank-specific
            -- durations become max-rank guesses here, and there is nothing
            -- better available — the event simply does not say which rank.
            spellID = lastRankIDForName(name)
            if not spellID then return end
        end
        local key = storeKeyFor(name, spellID)

        countDR(eventType, dstGUID, dstFlags, spellID, auraType)

        local opts = spells[spellID]
        if not opts then
            local npcDuration = D.npcSpells[spellID]
            if npcDuration then opts = { duration = npcDuration } end
        end

        if opts then
            local castEventPass
            if opts.castFilter then
                -- Buff events arrive as: APPLIED on the caster (if self or
                -- raid-wide), then CAST_SUCCESS, then APPLIED on everyone
                -- else. So the first APPLIED is held back, the cast event
                -- releases it, and the rest are let through behind it.
                local now = GetTime()
                castEventPass = isCastCurrent(srcGUID, spellID, now, 0.8)

                if not castEventPass
                   and (eventType == "SPELL_AURA_REFRESH" or eventType == "SPELL_AURA_APPLIED") then
                    castFilterSnapshot = { timestamp, eventType, hideCaster,
                        srcGUID, srcName, srcFlags, srcFlags2,
                        dstGUID, dstName, dstFlags, dstFlags2,
                        spellID, name, spellSchool, auraType }
                    return
                end

                if eventType == "SPELL_CAST_SUCCESS" then
                    castLog[srcGUID] = { spellID, now }
                    guidAccessTimes[srcGUID] = time()
                    if castFilterSnapshot then
                        local snapshot = castFilterSnapshot
                        castFilterSnapshot = nil
                        self:HandleCombatLog(unpack(snapshot))
                    end
                end
            end

            local isDstFriendly = bit_band(dstFlags, OBJECT_REACTION_FRIENDLY) > 0
            local isEnemyBuff   = not isDstFriendly and auraType == "BUFF"

            if eventType == "SPELL_AURA_REFRESH"
               or eventType == "SPELL_AURA_APPLIED"
               or eventType == "SPELL_AURA_APPLIED_DOSE" then
                -- The cast filter is ignored for enemies: we will never see an
                -- enemy's cast for a buff they put up out of range, and an
                -- enemy buff with a rough timer beats no enemy buff at all.
                if not opts.castFilter or castEventPass or isEnemyBuff then
                    setRecord(srcGUID, dstGUID, dstFlags, spellID, key, opts, auraType)
                end
            elseif eventType == "SPELL_AURA_REMOVED" then
                setRecord(srcGUID, dstGUID, dstFlags, spellID, key, opts, auraType, true)
            end

            if D.enemyBuffs and isEnemyBuff then
                buffCacheValid[dstGUID] = nil
                local unit = nameplateUnitMap[dstGUID]
                if dstGUID == UnitGUID("target") then
                    addon.callbacks:Fire("DURATIONS_UNIT_BUFF", "target")
                end
                if unit then
                    addon.callbacks:Fire("DURATIONS_UNIT_BUFF", unit)
                end
            end
        end
    end

    if eventType == "UNIT_DIED" then
        -- A hunter feigning death fires UNIT_DIED and keeps every aura. Only
        -- drop a hunter's record when they are an enemy (whose feign we cannot
        -- check) or when the group confirms they are not feigning.
        if select(2, GetPlayerInfoByGUID(dstGUID)) == "HUNTER" then
            local isDstFriendly = bit_band(dstFlags, OBJECT_REACTION_FRIENDLY) > 0
            if not isDstFriendly or D.IsFriendlyFeigning(dstGUID) then return end
        end

        guids[dstGUID]           = nil
        buffCache[dstGUID]       = nil
        buffCacheValid[dstGUID]  = nil
        guidAccessTimes[dstGUID] = nil
        DRInfo[dstGUID]          = nil

        if D.enemyBuffs and bit_band(dstFlags, OBJECT_REACTION_FRIENDLY) == 0 then
            local unit = nameplateUnitMap[dstGUID]
            if unit then addon.callbacks:Fire("DURATIONS_UNIT_BUFF", unit) end
        end
        nameplateUnitMap[dstGUID] = nil
    end
end

function D.IsFriendlyFeigning(guid)
    if IsInRaid() then
        for i = 1, MAX_RAID_MEMBERS do
            local unit = "raid" .. i
            if UnitGUID(unit) == guid then return UnitIsFeignDeath(unit) end
        end
    elseif IsInGroup() then
        for i = 1, MAX_PARTY_MEMBERS do
            local unit = "party" .. i
            if UnitGUID(unit) == guid then return UnitIsFeignDeath(unit) end
        end
    end
    return false
end

-- ── Reading a timer back ─────────────────────────────────────────────────────

local function auraTime(dstGUID, name, spellID, srcGUID, isStacking, npcDuration)
    local guidTable = guids[dstGUID]
    if not guidTable then return end

    local spellTable = guidTable[storeKeyFor(name, spellID)]
    if not spellTable then return end

    -- A player spell and an NPC spell can share a name. Player spells that
    -- stack keep per-source records, NPC entries never do — so a per-source
    -- table here means this is the player's version, not the creature's.
    if npcDuration and spellTable.applications then return end

    local record
    if isStacking then
        if not spellTable.applications then return end
        if srcGUID then
            record = spellTable.applications[srcGUID]
        else
            -- No caster asked for: any application is better than none.
            record = select(2, next(spellTable.applications))
        end
    else
        record = spellTable
    end
    if not record then return end

    local duration  = npcDuration or record[1]
    local startTime = record[2]
    if not duration or not startTime then return end
    if duration == INFINITY then return end

    duration = duration * (record[5] or 1)
    local expirationTime = startTime + duration
    if GetTime() > expirationTime then return end

    return duration, expirationTime
end

-- Improved Blizzard's slow shares the name "Chilled" with Frost Armor's, and
-- the two have different durations. Spells.lua parks the Imp Blizzard ranks
-- under a name of its own; route those IDs to it.
if playerClass == "MAGE" then
    local plainAuraTime = auraTime
    local chilled = spellName(12486)
    auraTime = function(dstGUID, name, spellID, ...)
        if name == chilled
           and (spellID == 12484 or spellID == 12485 or spellID == 12486) then
            name = "ImpBlizzard"
        end
        return plainAuraTime(dstGUID, name, spellID, ...)
    end
end

-- Duration and expiration for a spell on a unit, or nothing when this engine
-- has no basis for an answer. Callers must treat a real duration from the
-- client as authoritative and only come here for the zeroes.
function D.GetDuration(unit, spellID, casterUnit, name)
    if not spellID then return end

    local opts = spells[spellID]
    local isStacking, npcDuration
    if opts then
        isStacking = opts.stacking
    else
        npcDuration = D.npcSpells[spellID]
        if not npcDuration then return end
    end

    local dstGUID = UnitGUID(unit)
    if not dstGUID then return end
    local srcGUID = casterUnit and UnitGUID(casterUnit)

    return auraTime(dstGUID, name or spellName(spellID), spellID, srcGUID, isStacking, npcDuration)
end

-- Same answer as D.GetDuration for a caller that only has a GUID — the combat
-- log path, where there is no unit token to hand.
function D.GetDurationByGUID(dstGUID, spellID, srcGUID, name)
    if not spellID or not dstGUID then return end

    local opts = spells[spellID]
    local isStacking, npcDuration
    if opts then
        isStacking = opts.stacking
    else
        npcDuration = D.npcSpells[spellID]
        if not npcDuration then return end
    end

    return auraTime(dstGUID, name or spellName(spellID), spellID, srcGUID, isStacking, npcDuration)
end

-- What a spell browser needs to print in a Duration column: how long this aura
-- typically lasts, whether that length varies, and whether it is permanent.
--
-- Nothing to do with a live aura — this asks the RULES, not the records, so it
-- answers for a spell nobody has cast. A varying duration is resolved as though
-- someone else cast it (no talents of ours, five combo points), which is the
-- number that holds for most of what shows up on an enemy.
--
-- Returns: seconds (nil when unknowable), varies, permanent.
function D.DescribeDuration(spellID)
    if not spellID then return nil, false, false end

    local opts = spells[spellID]
    if not opts then
        local npcDuration = D.npcSpells[spellID]
        if npcDuration and npcDuration > 0 then return npcDuration, false, false end
        return nil, false, false
    end

    local duration = opts.duration
    if duration == nil then return nil, false, false end
    if duration == INFINITY then return nil, false, true end

    if type(duration) == "function" then
        -- pcall: these read talents and set bonuses, and a browser asking about
        -- someone else's class must not be able to error a settings panel.
        local ok, seconds = pcall(duration, spellID, false, 5)
        if not ok or type(seconds) ~= "number" then return nil, true, false end
        if seconds == INFINITY then return nil, true, true end
        return seconds, true, false
    end

    return duration, false, false
end

-- ── Enemy buffs ──────────────────────────────────────────────────────────────
-- The client will not list buffs on a hostile unit at all. Everything the
-- combat log saw land on them is all there is, so synthesize a list from the
-- records. Off until a consumer asks for it — see D.EnableEnemyBuffs.

local function regenerateBuffList(dstGUID)
    local list = {}
    local guidTable = guids[dstGUID]

    if guidTable then
        for spellID, spellTable in pairs(guidTable) do
            local opts = spells[spellID]
            local records
            if spellTable.applications then
                records = spellTable.applications
            else
                records = { [false] = spellTable }
            end
            for srcGUID, record in pairs(records) do
                if record[3] == "BUFF" then
                    local duration, expires = auraTime(
                        dstGUID, spellName(spellID), spellID,
                        srcGUID or nil, opts and opts.stacking)
                    if duration then
                        tinsert(list, {
                            spellName(spellID), spellTexture(spellID), 0,
                            duration, expires, spellID, opts and opts.buffType,
                        })
                    end
                end
            end
        end
    end

    buffCache[dstGUID]      = list
    buffCacheValid[dstGUID] = GetTime() + BUFF_CACHE_TTL
end

-- Same shape the nameplate module's readAura returns, so a caller can fall
-- straight through to it: name, icon, count, duration, expires, spellID, and
-- the dispel school on the end.
function D.EnemyBuff(unit, index)
    if not D.enemyBuffs then return nil end
    local dstGUID = UnitGUID(unit)
    if not dstGUID then return nil end

    local validUntil = buffCacheValid[dstGUID]
    if not validUntil or validUntil < GetTime() then
        regenerateBuffList(dstGUID)
    end

    local list = buffCache[dstGUID]
    local entry = list and list[index]
    if not entry then return nil end
    return entry[1], entry[2], entry[3], entry[4], entry[5], entry[6], entry[7]
end

function D.EnableEnemyBuffs(enabled)
    enabled = enabled and true or false
    if D.enemyBuffs == enabled then return end
    D.enemyBuffs = enabled
    if enabled then
        f:RegisterEvent("NAME_PLATE_UNIT_ADDED")
        f:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
    else
        f:UnregisterEvent("NAME_PLATE_UNIT_ADDED")
        f:UnregisterEvent("NAME_PLATE_UNIT_REMOVED")
        wipe(nameplateUnitMap)
        wipe(buffCache)
        wipe(buffCacheValid)
    end
end

function f:NAME_PLATE_UNIT_ADDED(event, unit)
    local guid = UnitGUID(unit)
    if guid then nameplateUnitMap[guid] = unit end
end
function f:NAME_PLATE_UNIT_REMOVED(event, unit)
    local guid = UnitGUID(unit)
    if guid then nameplateUnitMap[guid] = nil end
end

-- ── Registration ─────────────────────────────────────────────────────────────
-- The combat log handler is the expensive part of this file, so it only runs
-- while somebody is actually reading timers. Consumers register by name and the
-- scan stops again when the last one leaves.

local consumers = {}

function D.Register(token)
    if consumers[token] then return end
    consumers[token] = true
    f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    if playerClass == "ROGUE" then
        f:RegisterEvent("PLAYER_TARGET_CHANGED")
        f:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
    end
end

function D.Unregister(token)
    if not consumers[token] then return end
    consumers[token] = nil
    if next(consumers) then return end

    f:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    if playerClass == "ROGUE" then
        f:UnregisterEvent("PLAYER_TARGET_CHANGED")
        f:UnregisterEvent("UNIT_POWER_UPDATE")
    end
    wipe(guids)
    wipe(guidAccessTimes)
    wipe(DRInfo)
    wipe(buffCache)
    wipe(buffCacheValid)
    wipe(castLog)
end

-- ── Housekeeping ─────────────────────────────────────────────────────────────
-- Records are keyed by GUID and nothing tells us a mob we saw an hour ago is
-- gone for good, so anything untouched for half an hour is dropped.

local function purge()
    local now = time()
    local dead = {}
    for guid, lastAccess in pairs(guidAccessTimes) do
        if lastAccess + PURGE_THRESHOLD < now then
            guids[guid]            = nil
            nameplateUnitMap[guid] = nil
            buffCacheValid[guid]   = nil
            buffCache[guid]        = nil
            DRInfo[guid]           = nil
            castLog[guid]          = nil
            tinsert(dead, guid)
        end
    end
    for _, guid in ipairs(dead) do
        guidAccessTimes[guid] = nil
    end
end
C_Timer.NewTicker(PURGE_INTERVAL, purge)

f:RegisterEvent("PLAYER_LOGIN")
function f:PLAYER_LOGIN()
    playerGUID = UnitGUID("player")
    self:UnregisterEvent("PLAYER_LOGIN")

    if next(itemSets) then
        self:RegisterUnitEvent("UNIT_INVENTORY_CHANGED", "player")
        refreshSetBonuses()
    end

    -- Well clear of the login rush; nothing needs this table until the combat
    -- log hands us a spell name with no ID.
    C_Timer.After(10, buildNPCSpellNames)
end

function f:UNIT_INVENTORY_CHANGED()
    refreshSetBonuses()
end

-- ── Diagnostics ──────────────────────────────────────────────────────────────
-- This engine is a guess about state we cannot see directly, so being able to
-- ask it what it thinks is on a unit is the only way to tell a wrong timer from
-- a missing spell rule.

local function dumpUnit(unit)
    local dstGUID = UnitGUID(unit)
    if not dstGUID then
        print("|cfffb2c36Durations|r: no unit for '" .. tostring(unit) .. "'.")
        return
    end

    local guidTable = guids[dstGUID]
    if not guidTable or not next(guidTable) then
        print("|cfffb2c36Durations|r: nothing tracked on " .. (UnitName(unit) or unit) .. ".")
        return
    end

    print(("|cfffb2c36Durations|r: tracked on %s"):format(UnitName(unit) or unit))
    local now = GetTime()
    for spellID, spellTable in pairs(guidTable) do
        local records = spellTable.applications or { [false] = spellTable }
        for srcGUID, record in pairs(records) do
            local duration = (record[1] or 0) * (record[5] or 1)
            local remaining = (record[2] or 0) + duration - now
            print(("   %s (%d)  %.1f / %.0fs  %s%s"):format(
                spellName(spellID) or "?", spellID,
                remaining, duration,
                record[3] or "?",
                (record[5] and record[5] ~= 1) and (" DR x" .. record[5]) or ""))
        end
    end
end

local function dumpDR(unit)
    local dstGUID = UnitGUID(unit)
    local guidTable = dstGUID and DRInfo[dstGUID]
    if not guidTable or not next(guidTable) then
        print("|cfffb2c36Durations|r: no DR brackets on that unit.")
        return
    end
    local now = GetTime()
    print("|cfffb2c36Durations|r: DR brackets")
    for category, catTable in pairs(guidTable) do
        local left = (catTable.expires or 0) - now
        print(("   %s  level %d  %s"):format(
            category, catTable.level or 0,
            left > 0 and ("%.1fs left"):format(left) or "expired"))
    end
end

SLASH_DRIEVDURATIONS1 = "/dedur"
SLASH_DRIEVDURATIONS2 = "/drievdurations"
SlashCmdList["DRIEVDURATIONS"] = function(msg)
    local cmd = (msg or ""):lower():match("^%s*(%S*)")

    if cmd == "unit" or cmd == "target" then
        dumpUnit("target")
    elseif cmd == "dr" then
        dumpDR("target")
    elseif cmd == "status" then
        local tracked, records = 0, 0
        for _, guidTable in pairs(guids) do
            tracked = tracked + 1
            for _ in pairs(guidTable) do records = records + 1 end
        end
        local names = {}
        for token in pairs(consumers) do tinsert(names, token) end
        local ruleCount = 0
        for _ in pairs(spells) do ruleCount = ruleCount + 1 end
        print(("|cfffb2c36Durations|r: %d player rules, %d units tracked, %d auras")
            :format(ruleCount, tracked, records))
        print(("   scanning: %s | enemy buffs: %s")
            :format(#names > 0 and table.concat(names, ", ") or "no (idle)",
                    D.enemyBuffs and "on" or "off"))
    else
        print("|cfffb2c36Driev's Essentials|r — aura durations:")
        print("   |cffdddddd/dedur status|r — rule count, what is being tracked, who is asking")
        print("   |cffdddddd/dedur unit|r — every aura this engine thinks is on your target")
        print("   |cffdddddd/dedur dr|r — diminishing returns brackets on your target")
    end
end

if addon.RegisterSlash then
    addon.RegisterSlash("Aura durations", {
        { "/dedur status", "rule count, tracked units, registered readers" },
        { "/dedur unit",   "every aura the duration engine has on your target" },
        { "/dedur dr",     "diminishing returns brackets on your target" },
    })
end
