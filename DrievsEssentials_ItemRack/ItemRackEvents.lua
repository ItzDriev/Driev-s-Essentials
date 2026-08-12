-- Item Rack module: events (automatic set swapping). An event pairs a condition
-- ("mounted", "in a city") with a set: while the condition holds the set is
-- worn, and when it ends whatever it displaced goes back on.
--
-- Gello's ItemRack model: conditions are polled or driven off a few client
-- events, and everything that fires is recorded on a STACK, because conditions
-- overlap — mounting in a city layers the mount set over the city set and must
-- land back in it on dismount. That falls out of the swap engine for free, since
-- EquipSet records what it displaced and UnequipSet puts it back. So push =
-- EquipSet, pop = UnequipSet, and the stack is only bookkeeping.
--
-- Not ported: upstream's script-event type (arbitrary Lua via loadstring).
local addon = _G.DrievEssentials
if not addon then return end

local IR = addon.ItemRack
if not IR then return end

local DB = IR.DB

-- ── Event definitions ────────────────────────────────────────────────────────
-- Three condition types:
--   buff   : an aura by name, or `anyMount` for any mount at all
--   zone   : a zone/subzone name, or an instance type (pvp, arena, raid, party)
--   stance : a shapeshift/stance form, by index or form name
--
-- `revert` defaults "put the old gear back when the condition ends". `class`
-- limits an event to one class. Order here is the settings tab's order.
local CITY = {
    ["Stormwind City"] = true,
    ["Ironforge"]      = true,
    ["Darnassus"]      = true,
    ["Orgrimmar"]      = true,
    ["Thunder Bluff"]  = true,
    ["Undercity"]      = true,
}

-- The named battlegrounds cover the world-map case; the instance types catch
-- anything the client itself flags as PvP, so a battleground this list has
-- never heard of still counts.
local PVP_ZONES = {
    ["Alterac Valley"] = true,
    ["Arathi Basin"]   = true,
    ["Warsong Gulch"]  = true,
}
local PVP_INSTANCES = { pvp = true, arena = true }

IR.EventDefs = {
    {
        name   = "Mounted",
        type   = "buff",
        anyMount = true,
        revert = true,
        desc   = "While you are on any mount. Taxi flights don't count — the game "
              .. "won't let you change gear on one anyway.",
    },
    {
        name   = "City",
        type   = "zone",
        zones  = CITY,
        revert = true,
        desc   = "While you are in Stormwind, Ironforge, Darnassus, Orgrimmar, "
              .. "Thunder Bluff or Undercity.",
    },
    {
        name   = "Drinking",
        type   = "buff",
        buff   = "Drink",
        revert = true,
        desc   = "While the Drink buff is on you. Handy for a spirit set that only "
              .. "goes on between pulls.",
    },
    {
        name   = "Nefarian's Lair",
        type   = "zone",
        zones  = { ["Nefarian's Lair"] = true },
        revert = true,
        desc   = "While you are in Nefarian's room in Blackwing Lair. Matches the "
              .. "subzone, so it fires on the way in rather than at the instance door.",
    },
    {
        name   = "PVP",
        type   = "zone",
        zones  = PVP_ZONES,
        instances = PVP_INSTANCES,
        revert = true,
        desc   = "While you are inside a battleground or arena.",
    },

    { name = "Warrior Battle Stance",    class = "WARRIOR", type = "stance", stance = 1,
      desc = "While you are in Battle Stance." },
    { name = "Warrior Defensive Stance", class = "WARRIOR", type = "stance", stance = 2,
      desc = "While you are in Defensive Stance." },
    { name = "Warrior Berserker Stance", class = "WARRIOR", type = "stance", stance = 3,
      desc = "While you are in Berserker Stance." },

    { name = "Druid Humanoid",     class = "DRUID", type = "stance", stance = 0,
      desc = "While you are in no form at all." },
    { name = "Druid Bear",         class = "DRUID", type = "stance", stance = 1, revert = true,
      desc = "While you are in Bear or Dire Bear Form." },
    { name = "Druid Aquatic",      class = "DRUID", type = "stance", stance = 2, revert = true,
      desc = "While you are in Aquatic Form." },
    { name = "Druid Cat",          class = "DRUID", type = "stance", stance = 3, revert = true,
      desc = "While you are in Cat Form." },
    { name = "Druid Travel",       class = "DRUID", type = "stance", stance = 4, revert = true,
      desc = "While you are in Travel Form." },
    { name = "Druid Moonkin",      class = "DRUID", type = "stance", stance = "Moonkin Form", revert = true,
      desc = "While you are in Moonkin Form." },

    { name = "Rogue Stealth",      class = "ROGUE",  type = "stance", stance = 1, revert = true,
      desc = "While you are stealthed." },
    { name = "Priest Shadowform",  class = "PRIEST", type = "stance", stance = 1, revert = true,
      desc = "While you are in Shadowform." },
    { name = "Shaman Ghost Wolf",  class = "SHAMAN", type = "stance", stance = 1, revert = true,
      desc = "While you are in Ghost Wolf form." },
    { name = "Mage Evocation",     class = "MAGE",   type = "buff", buff = "Evocation", revert = true,
      desc = "While you are channelling Evocation." },
}

IR.EventByName = {}
for _, def in ipairs(IR.EventDefs) do IR.EventByName[def.name] = def end

-- Filled by IR.BuildEventList at login: the definitions this character can
-- actually use. Empty until then so anything that runs early reads as "no
-- events" rather than erroring.
IR.EventList = {}

function IR.BuildEventList()
    local _, class = UnitClass("player")
    local list = {}
    for _, def in ipairs(IR.EventDefs) do
        if not def.class or def.class == class then
            list[#list + 1] = def
        end
    end
    IR.EventList = list
    return list
end

-- ── Saved state ──────────────────────────────────────────────────────────────
-- Events live in the per-character DB next to the sets, not in the profile: an
-- event points at a set, and sets are already per-character. A profile shared by
-- two characters would otherwise name gear one of them has never owned.
function IR.EventsData()
    local db = DB()
    db.events = db.events or {}
    local e = db.events
    -- Off until asked for: events move gear on their own, which is the last
    -- thing someone who hasn't set one up wants happening to them.
    if e.on == nil then e.on = false end
    e.enabled = e.enabled or {}   -- [event name] = true
    e.set     = e.set     or {}   -- [event name] = set to equip
    e.revert  = e.revert  or {}   -- [event name] = true/false, overriding def.revert
    return e
end
local EventsData = IR.EventsData

function IR.EventsOn()
    return EventsData().on and true or false
end

function IR.IsEventEnabled(name)
    return EventsData().enabled[name] and true or false
end

function IR.GetEventSet(name)
    local setname = EventsData().set[name]
    -- A set can be deleted while an event still names it; treat that as unset
    -- rather than handing a dead name to the swap engine.
    if setname and DB().sets[setname] then return setname end
end

function IR.GetEventRevert(name)
    local override = EventsData().revert[name]
    if override ~= nil then return override end
    local def = IR.EventByName[name]
    return def and def.revert and true or false
end

-- ── Runtime state ────────────────────────────────────────────────────────────
-- state[event name] exists exactly while that event's condition holds, so the
-- table's presence IS the "active" flag. Its fields qualify what happens on end:
--   noRestore  : the set was already worn, so nothing was displaced
--   overridden : the user equipped a set by hand, so this event lost its claim
local state = {}

-- Bottom-to-top order of events currently holding gear.
IR.EventStack = {}

local function removeFromStack(name)
    for i = #IR.EventStack, 1, -1 do
        if IR.EventStack[i] == name then table.remove(IR.EventStack, i) end
    end
end

-- ── Conditions ───────────────────────────────────────────────────────────────

-- Stances are stored by index or by form name; names have to be resolved
-- against the forms the character actually knows, since the index shifts as
-- forms are learned.
local function stanceNumber(stance)
    if tonumber(stance) then return tonumber(stance) end
    for i = 1, GetNumShapeshiftForms() do
        if stance == select(2, GetShapeshiftFormInfo(i)) then return i end
    end
end

local function conditionMet(def)
    if def.type == "buff" then
        if def.anyMount then
            -- A taxi is "mounted" as far as IsMounted is concerned, and gear
            -- can't be changed on one, so it doesn't count.
            return IsMounted() and not UnitOnTaxi("player") and true or false
        end
        return def.buff and AuraUtil.FindAuraByName(def.buff, "player") and true or false

    elseif def.type == "zone" then
        local zone, sub = GetRealZoneText(), GetSubZoneText()
        local _, instanceType = IsInInstance()
        if def.zones then
            if zone and def.zones[zone] then return true end
            if sub and sub ~= "" and def.zones[sub] then return true end
        end
        if def.instances and instanceType and def.instances[instanceType] then return true end
        return false

    elseif def.type == "stance" then
        return stanceNumber(def.stance) == GetShapeshiftForm()
    end
    return false
end

-- ── Push / pop ───────────────────────────────────────────────────────────────

-- Whether equipping this set would move anything. Deliberately the same exact-id
-- comparison EquipSet makes (not IsSetEquipped's looser match), because it's
-- asking EquipSet's own question: would it find an empty swap list?
--
-- It matters because EquipSet only wipes a set's `old` table when it has moves
-- to make, so equipping an already-worn set leaves `old` holding the LAST swap's
-- record — which an event must not later "restore".
local function alreadyWearing(setname)
    local set = DB().sets[setname]
    if not set or not set.equip then return false end
    for slot, wanted in pairs(IR.ResolveInterchangeable(set.equip)) do
        if IR.GetID(slot) ~= wanted then return false end
    end
    return true
end

local function pushEvent(name)
    local st = state[name] or {}
    state[name] = st
    local setname = IR.GetEventSet(name)
    if not setname then return end

    removeFromStack(name)
    if alreadyWearing(setname) then
        st.noRestore = true
        return
    end
    st.noRestore = nil
    IR.EventStack[#IR.EventStack + 1] = name
    IR.EquipSet(setname, true)
end

local function popEvent(name)
    removeFromStack(name)
    local st = state[name]
    if st and (st.noRestore or st.overridden) then return end
    local setname = IR.GetEventSet(name)
    if setname then IR.UnequipSet(setname) end
end

-- The condition stopped holding (or the event was switched off): give the gear
-- back if this event is set to revert, and forget it either way.
local function deactivate(name)
    local st = state[name]
    if not st then return end
    if IR.GetEventRevert(name) then
        popEvent(name)
    else
        removeFromStack(name)
    end
    state[name] = nil
end

local function unwindAll()
    for i = #IR.EventStack, 1, -1 do
        deactivate(IR.EventStack[i])
    end
    for name in pairs(state) do deactivate(name) end
end

-- Called by EquipSet whenever the user equips a set themselves. Their choice
-- outranks any event, so every active event gives up its claim: it stays active
-- (so it won't immediately re-equip) but is marked overridden, meaning it
-- quietly steps aside when its condition ends instead of restoring stale gear.
function IR.NoteManualEquip(setname)
    if not setname or string.match(setname, "^~") then return end
    if #IR.EventStack == 0 then return end
    for _, name in ipairs(IR.EventStack) do
        if state[name] then state[name].overridden = true end
    end
    wipe(IR.EventStack)
end

-- ── Processing ───────────────────────────────────────────────────────────────

local function eventsUsable()
    if not IR.loggedIn then return false end
    if not IR.IsEnabled() then return false end
    if not IR.EventsOn() then return false end
    -- Right after a loading screen the bags aren't populated yet, so nothing
    -- can be found to equip and every set would read as "items missing".
    local slots = C_Container.GetContainerNumSlots(0)
    return slots and slots > 0
end

-- Re-derives every enabled event from the live conditions and applies the
-- difference. Cheap and idempotent — calling it more often than necessary
-- costs a few comparisons and changes nothing.
function IR.RunEvents()
    if not eventsUsable() then return end

    local toEquip, toUnequip

    for _, def in ipairs(IR.EventList) do
        local name = def.name
        if IR.IsEventEnabled(name) and IR.GetEventSet(name) then
            local met = conditionMet(def)
            if met and not state[name] then
                state[name] = {}
                toEquip = toEquip or {}
                toEquip[#toEquip + 1] = name
            elseif not met and state[name] then
                toUnequip = toUnequip or {}
                toUnequip[#toUnequip + 1] = name
            end
        elseif state[name] then
            -- Switched off (or its set was deleted) while it was holding gear.
            toUnequip = toUnequip or {}
            toUnequip[#toUnequip + 1] = name
        end
    end

    -- Everything that ended goes first: an event both losing one set and gaining
    -- another in the same pass must give the old gear back before the new set
    -- records what it displaced, or the two records overlap.
    --
    -- Topmost first, so a stack unwinds the way it was built.
    if toUnequip then
        local wanted = {}
        for _, name in ipairs(toUnequip) do wanted[name] = true end
        for i = #IR.EventStack, 1, -1 do
            local name = IR.EventStack[i]
            if wanted[name] then
                wanted[name] = nil
                deactivate(name)
            end
        end
        -- Anything left was holding no gear of its own (see noRestore), so its
        -- order among the rest doesn't matter.
        for _, name in ipairs(toUnequip) do
            if wanted[name] then deactivate(name) end
        end
    end
    if toEquip then
        for _, name in ipairs(toEquip) do pushEvent(name) end
    end
end

-- One coalesced pass per burst of triggers. UNIT_AURA in particular fires
-- several times over a mount-up, and running once at the end of that is both
-- cheaper and more accurate than running on each.
local pending
local function schedule(delay)
    if pending then return end
    pending = true
    C_Timer.After(delay or 0.2, function()
        pending = nil
        IR.RunEvents()
    end)
end

-- ── Triggers ─────────────────────────────────────────────────────────────────

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "UNIT_AURA" and arg1 ~= "player" then return end
    if event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED_INDOORS"
        or event == "ZONE_CHANGED" or event == "PLAYER_ENTERING_WORLD" then
        -- Zone and instance info settle late off a loading screen — GetRealZoneText can
        -- still be the zone just left. Look once promptly and once more when it has
        -- certainly caught up; the second pass no-ops if the first got it right.
        schedule(0.4)
        C_Timer.After(2, IR.RunEvents)
        return
    end
    schedule(0.2)
end)

-- IsMounted doesn't change in step with the mount aura (and a taxi never has
-- one at all), so mount events are polled rather than driven off UNIT_AURA.
-- Only runs while an event that cares about mounts is switched on.
local mountTicker, lastMounted

local function mountPoll()
    local mounted = IsMounted() and not UnitOnTaxi("player") and true or false
    if mounted ~= lastMounted then
        lastMounted = mounted
        IR.RunEvents()
    end
end

local function stopMountTicker()
    if mountTicker then mountTicker:Cancel() end
    mountTicker, lastMounted = nil, nil
end

-- Re-reads which triggers are needed and re-subscribes to exactly those. Called
-- at login and after anything that changes the event settings.
function IR.ReflectEvents()
    frame:UnregisterAllEvents()
    stopMountTicker()

    if not (IR.loggedIn and IR.IsEnabled() and IR.EventsOn()) then
        -- Whatever is worn stays worn; this only stops reacting to conditions.
        return
    end

    local needMount
    for _, def in ipairs(IR.EventList) do
        if IR.IsEventEnabled(def.name) then
            if def.type == "buff" then
                frame:RegisterEvent("UNIT_AURA")
                if def.anyMount then needMount = true end
            elseif def.type == "zone" then
                frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
                frame:RegisterEvent("ZONE_CHANGED_INDOORS")
                frame:RegisterEvent("ZONE_CHANGED")
                frame:RegisterEvent("PLAYER_ENTERING_WORLD")
            elseif def.type == "stance" then
                frame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
            end
        end
    end

    if needMount then
        lastMounted = IsMounted() and not UnitOnTaxi("player") and true or false
        mountTicker = C_Timer.NewTicker(0.5, mountPoll)
    end

    IR.RunEvents()
end

-- ── Settings writes ──────────────────────────────────────────────────────────
-- All of these unwind first and re-derive after, so turning something off hands
-- the gear back rather than leaving an event's set stranded on the character.

function IR.SetEventsOn(on)
    local data = EventsData()
    data.on = on and true or false
    if not data.on then unwindAll() end
    IR.ReflectEvents()
end

function IR.SetEventEnabled(name, enabled)
    EventsData().enabled[name] = enabled and true or nil
    if not enabled then deactivate(name) end
    IR.ReflectEvents()
end

function IR.SetEventSet(name, setname)
    local data = EventsData()
    if setname == data.set[name] then return end
    -- The old set is still on the character; give it back before the event
    -- starts pointing somewhere else, or it can never be restored.
    deactivate(name)
    data.set[name] = setname
    -- Picking a set is the whole point of the row, so it turns the event on;
    -- clearing it turns the event off, since it now has nothing to equip.
    data.enabled[name] = setname and true or nil
    IR.ReflectEvents()
end

function IR.SetEventRevert(name, revert)
    EventsData().revert[name] = revert and true or false
    IR.ReflectEvents()
end

-- A deleted set can't be equipped or restored, so any event naming it is left
-- pointing at nothing. Called from IR.DeleteSet.
function IR.ForgetSetInEvents(setname)
    local data = EventsData()
    local changed
    for name, assigned in pairs(data.set) do
        if assigned == setname then
            deactivate(name)
            data.set[name]     = nil
            data.enabled[name] = nil
            changed = true
        end
    end
    if changed then IR.ReflectEvents() end
end

-- ── Init ─────────────────────────────────────────────────────────────────────

function IR.InitEvents()
    IR.BuildEventList()

    -- Drop settings for events that no longer exist, and for sets that have
    -- been deleted or imported over, so the tab can't offer a dead row.
    local data = EventsData()
    for name in pairs(data.enabled) do
        if not IR.EventByName[name] then data.enabled[name] = nil end
    end
    for name, setname in pairs(data.set) do
        if not IR.EventByName[name] or not DB().sets[setname] then
            data.set[name]     = nil
            data.enabled[name] = nil
        end
    end
    for name in pairs(data.revert) do
        if not IR.EventByName[name] then data.revert[name] = nil end
    end

    -- Conditions already holding at login (logged out mounted, or in a city) are
    -- picked up by the first pass. Nothing is displaced if the set is already on,
    -- so logging in inside a city doesn't shuffle correct gear.
    IR.ReflectEvents()

    -- That first pass usually lands before the bags are readable, in which case it
    -- did nothing (see eventsUsable) — and a condition already true at login has no
    -- client event coming. So look again once the world has settled, and once more
    -- for a slow load.
    C_Timer.After(2, IR.RunEvents)
    C_Timer.After(6, IR.RunEvents)
end
