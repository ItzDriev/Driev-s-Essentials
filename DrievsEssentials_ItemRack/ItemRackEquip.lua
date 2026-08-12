-- Item Rack module: the swap engine.
--
-- Equipping a set isn't atomic: the client moves one item per Pickup* pair,
-- refuses to move anything "locked" mid-swap, and can't touch equipment in
-- combat. So a swap is a loop doing as much as it legally can, waiting for
-- ITEM_LOCK_CHANGED to settle and running again — with anything still impossible
-- parked on the combat queue.
local addon = _G.DrievEssentials
if not addon then return end

local IR = addon.ItemRack
if not IR then return end

local PickupContainerItem      = C_Container.PickupContainerItem
local GetContainerItemInfo     = IR.GetContainerItemInfo

local DB       = IR.DB
local getData  = IR.GetData
local GetID    = IR.GetID
local SameID   = IR.SameID
local FindItem = IR.FindItem

IR.SwapList     = {}   -- [slot] = id still wanting to move in on this pass
IR.SetsWaiting  = {}   -- {{setname, equipFn}, ...} deferred until locks clear
IR.AbortSwap    = nil
IR.AbortReasons = {
    "Not enough room.",
    "Something is on the cursor.",
    "In spell targeting mode.",
    "Another swap is in progress.",
}

-- Monotonic count of moves handed to the client, only ever compared against
-- itself to answer "did that pass do anything at all?" — see the watchdog.
local moveCount = 0

-- ── Deferred sets ────────────────────────────────────────────────────────────

-- `arg` is passed back to fn as its second argument when the deferred call
-- finally runs, so a queued equip still knows it came from an event rather than
-- from the user (see IR.EquipSet).
function IR.AddSetToSetsWaiting(setname, fn, arg)
    for _, entry in ipairs(IR.SetsWaiting) do
        if entry[1] == setname and entry[2] == fn then return end
    end
    table.insert(IR.SetsWaiting, { setname, fn, arg })
    IR.WatchSwapEngine()
end

function IR.ProcessSetsWaiting()
    local entry = table.remove(IR.SetsWaiting, 1)
    if entry then entry[2](entry[1], entry[3]) end
end

-- ── Stall watchdog ───────────────────────────────────────────────────────────
-- Everything this engine defers is woken by ITEM_LOCK_CHANGED, which fires
-- because an item moved — so a pass that moved NOTHING has nothing coming to
-- wake it. Full bags, something on the cursor, an unreleased lock, a missing
-- cast-stop event: any of those parks IR.setSwapping permanently, and since
-- EquipSet queues behind exactly those states, every later swap is swallowed
-- silently. Only /deir unstick or a relog got out of it.
--
-- So deferring anything arms this too: it re-runs the lock handler's wake-ups
-- and eventually gives up loudly rather than blocking every later swap.
local WATCHDOG_TICK = 0.5

-- Retries that moved nothing before the swap is written off. A pass that manages
-- even one move resets it, so this only counts genuinely stuck attempts — and
-- ticks spent waiting on locks, a cast or combat don't count at all.
local WATCHDOG_GIVEUP = 6

local watchTimer, idleTicks = nil, 0

local function stopWatch()
    if watchTimer then watchTimer:Cancel() end
    watchTimer = nil
end

-- Drops the in-flight swap and says why, leaving the engine free for the next
-- request instead of blocked behind one that can't finish.
local function giveUpOnSwap()
    local setname = IR.setSwapping
    IR.setSwapping = nil
    wipe(IR.SwapList)
    IR.ClearPendingEquip()
    IR.Print("Gave up on \"" .. tostring(setname) .. "\". "
        .. (IR.AbortReasons[IR.AbortSwap] or "Nothing would move.")
        .. " Sets can be equipped again once that's sorted.")
    IR.AbortSwap, IR.abortReported = nil, nil
    if IR.UpdateCurrentSet then IR.UpdateCurrentSet() end
end

local function watchdogTick()
    watchTimer = nil

    -- Locks still held means the client really is mid-move — the healthy case,
    -- driven by ITEM_LOCK_CHANGED. Casting, combat and death each end on their own
    -- and have their own handler, so none of them is a stall.
    if IR.AnythingLocked() or IR.IsCasting()
        or UnitAffectingCombat("player") or IR.IsPlayerReallyDead() then
        IR.WatchSwapEngine()
        return
    end

    if IR.setSwapping then
        local before = moveCount
        IR.LockChangedDuringSetSwap()
        if moveCount > before then
            idleTicks = 0
        else
            idleTicks = idleTicks + 1
            if idleTicks >= WATCHDOG_GIVEUP and IR.setSwapping then giveUpOnSwap() end
        end
    elseif #IR.SetsWaiting > 0 then
        -- One per tick, matching the lock handler: each of these is a full
        -- EquipSet that may well hand the client more moves to settle.
        IR.ProcessSetsWaiting()
    end

    if IR.setSwapping or #IR.SetsWaiting > 0 then IR.WatchSwapEngine() end
end

-- Cheap to call from anywhere that defers work; it does nothing if a tick is
-- already pending, and stops rearming itself as soon as there's nothing parked.
function IR.WatchSwapEngine()
    if watchTimer then return end
    watchTimer = C_Timer.NewTimer(WATCHDOG_TICK, watchdogTick)
end

-- Parks a swap for another pass. The lock handler runs it when the client is
-- genuinely mid-move; the watchdog runs it when nothing is coming.
local function parkSwap(setname, fresh)
    IR.setSwapping = setname
    if fresh then idleTicks = 0 end
    IR.WatchSwapEngine()
end

-- ── Moving items ─────────────────────────────────────────────────────────────

-- fromBag/toBag with a nil slot means an equipment slot rather than a container.
-- Every abort reason here is transient, so the caller retries after the next
-- lock settle rather than reporting a hard failure.
function IR.MoveItem(fromBag, fromSlot, toBag, toSlot)
    local abort
    if CursorHasItem() then
        abort = 2
    elseif SpellIsTargeting() then
        abort = 3
    elseif (not fromSlot and IsInventoryItemLocked(fromBag))
        or (not toSlot and IsInventoryItemLocked(toBag)) then
        abort = 4
    elseif (fromSlot and select(3, GetContainerItemInfo(fromBag, fromSlot)))
        or (toSlot and select(3, GetContainerItemInfo(toBag, toSlot))) then
        abort = 4
    end
    if abort then
        IR.AbortSwap = abort
        return
    end

    if fromSlot then
        PickupContainerItem(fromBag, fromSlot)
    else
        PickupInventoryItem(fromBag)
    end
    if toSlot then
        PickupContainerItem(toBag, toSlot)
    else
        -- Dropping onto the ammo slot only works through the ranged slot on
        -- Classic; the client routes it from there.
        if toBag == INVSLOT_AMMO then toBag = INVSLOT_RANGED end
        PickupInventoryItem(toBag)
    end
    moveCount = moveCount + 1
end
local MoveItem = IR.MoveItem

-- ── Set state ────────────────────────────────────────────────────────────────

-- Slot pairs whose halves are genuinely interchangeable: what matters is both
-- rings end up worn, not which finger. Trinkets are deliberately NOT here (/use
-- 13 and /use 14 make position meaningful), nor weapons, where main/off hand is
-- a distinction the client enforces.
local INTERCHANGEABLE = { { 11, 12 } }

-- Transposes an interchangeable pair when that leaves more of the set already in
-- place, turning a two-ring shuffle into a single swap. Returns a copy; the
-- saved set is never rewritten.
local function resolveInterchangeable(equip)
    local resolved = {}
    for slot, id in pairs(equip) do resolved[slot] = id end

    for _, pair in ipairs(INTERCHANGEABLE) do
        local a, b = pair[1], pair[2]
        local wantA, wantB = resolved[a], resolved[b]
        -- Needs both halves pinned to have anything to trade against, and two
        -- different items or the orientation makes no difference anyway.
        if wantA and wantB and not SameID(wantA, wantB) then
            local wornA, wornB = GetID(a), GetID(b)
            local straight = (SameID(wantA, wornA) and 1 or 0) + (SameID(wantB, wornB) and 1 or 0)
            local crossed  = (SameID(wantA, wornB) and 1 or 0) + (SameID(wantB, wornA) and 1 or 0)
            if crossed > straight then
                resolved[a], resolved[b] = wantB, wantA
            end
        end
    end
    return resolved
end
IR.ResolveInterchangeable = resolveInterchangeable

-- exact = require the identical enchanted copy, not merely the same base item.
function IR.IsSetEquipped(setname, exact)
    local set = setname and DB().sets[setname] and DB().sets[setname].equip
    if not set then return end
    -- Same resolution the equip pass uses, or a set worn with its rings swapped
    -- over would equip to a no-op and still read as "not equipped".
    for slot, wanted in pairs(resolveInterchangeable(set)) do
        local worn = GetID(slot)
        if (exact and wanted ~= worn) or (not exact and not SameID(wanted, worn)) then
            return false
        end
    end
    return true
end

-- Number of slots a set can't currently fill: returns 1 if everything missing is
-- merely sitting in the bank, 0 if something is gone entirely, nil if the whole
-- set is on hand.
function IR.MissingItems(setname)
    local set = setname and DB().sets[setname]
    if not set then return end
    local missing
    for _, id in pairs(set.equip) do
        if id ~= 0 and IR.GetCountByID(id) == 0 then
            missing = 0
            if IR.FindInBank(id) then return 1 end
        end
    end
    return missing
end

-- ── Pending equip ────────────────────────────────────────────────────────────
-- Pickup* only ASKS the client to move an item; until the server confirms, the
-- slot still reads as holding the old one. A straightforward swap finds
-- everything on the first pass, so EquipSet goes straight to EndSetSwap and none
-- of the engine's tracking is set by the time the set button redraws — even
-- though the gear is still in flight.
--
-- So the "issued, not yet landed" window is tracked explicitly: opened when
-- moves are handed over, closed when locks settle, with a timeout so a swap
-- whose lock events never arrive can't leave it stuck.
local EQUIP_SETTLE_TIMEOUT = 3

function IR.MarkEquipIssued(setname)
    IR.pendingEquip   = setname
    IR.pendingEquipAt = GetTime()
end

-- Returns whether there was anything to clear, so callers can skip a redraw.
function IR.ClearPendingEquip()
    if not IR.pendingEquip then return false end
    IR.pendingEquip, IR.pendingEquipAt = nil, nil
    return true
end

-- Whether the engine is still working towards SOME equip: moves issued but not
-- applied, a multi-pass swap awaiting its follow-up, or something queued behind
-- locks/casting/combat. Distinguishes "gear doesn't match because we haven't
-- finished" from "gear doesn't match because you swapped a piece out yourself".
function IR.SetSwapInProgress()
    if IR.setSwapping ~= nil    then return true end
    if #IR.SetsWaiting > 0      then return true end
    if next(IR.CombatQueue) ~= nil then return true end
    if IR.pendingEquip then
        if GetTime() - (IR.pendingEquipAt or 0) < EQUIP_SETTLE_TIMEOUT then return true end
        IR.ClearPendingEquip()   -- safety net expired; treat as settled
    end
    return false
end

-- ── Equipping ────────────────────────────────────────────────────────────────

-- One pass over the swap list. Each item it manages to move is removed from the
-- list; whatever is left needs another pass once the client releases its locks.
function IR.IterateSwapList(setname)
    local set  = DB().sets[setname]
    local swap = IR.SwapList

    IR.AbortSwap = nil
    IR.ClearLockList()

    local skip
    for slot = 0, 19 do
        if skip or IR.AbortSwap then
            skip = nil
        elseif swap[slot] then
            if swap[slot] == 0 then
                -- Intentionally empty: move whatever is worn out to a bag.
                local bag, bagSlot = IR.FindSpace()
                if not bag then
                    IR.AbortSwap = 1
                    return
                end
                if set.old then set.old[slot] = GetID(slot) end
                MoveItem(slot, nil, bag, bagSlot)
                swap[slot] = nil
            else
                local inv, bag, bagSlot = FindItem(swap[slot], true)
                if bag then
                    local _, _, equipSlot = IR.GetInfoByID(swap[slot])
                    if equipSlot == "INVTYPE_2HWEAPON" and GetInventoryItemLink("player", 17) then
                        -- A two-hander needs the off hand cleared first, and both
                        -- slots recorded as "old" so unequipping restores them.
                        local freeBag, freeSlot = IR.FindSpace()
                        if not freeBag then
                            -- No room to park the off hand: leave swap[slot] for a later pass rather than
                            -- equipping the two-hander over an occupied off hand, which the client would
                            -- reject — wasting the swap and marking the slot "done" so it's never retried.
                            IR.AbortSwap = 1
                            skip = true
                        else
                            if set.old then
                                set.old[slot]     = GetID(slot)
                                set.old[slot + 1] = GetID(slot + 1)
                            end
                            MoveItem(17, nil, freeBag, freeSlot)
                            MoveItem(bag, bagSlot, 16, nil)
                            swap[slot]     = nil
                            swap[slot + 1] = nil
                            skip = true
                        end
                    else
                        if set.old then set.old[slot] = GetID(slot) end
                        MoveItem(bag, bagSlot, slot, nil)
                        swap[slot] = nil
                    end
                elseif inv == (slot + 1) and SameID(swap[slot + 1], GetID(slot)) then
                    -- The two paired slots (rings, trinkets, weapons) want to
                    -- trade places — one move does both.
                    if set.old then
                        set.old[slot]     = GetID(slot)
                        set.old[slot + 1] = GetID(slot + 1)
                    end
                    MoveItem(slot, nil, slot + 1, nil)
                    swap[slot]     = nil
                    swap[slot + 1] = nil
                    skip = true
                end
            end
        end
    end

    -- Retried passes hit the same wall the first one did, so the reason is worth
    -- saying once per stall rather than every half second until it clears.
    if IR.AbortSwap and IR.AbortSwap ~= IR.abortReported then
        IR.abortReported = IR.AbortSwap
        IR.Print("Swap stopped. " .. (IR.AbortReasons[IR.AbortSwap] or ""))
    end
end

function IR.EndSetSwap(setname)
    IR.setSwapping = nil
    IR.abortReported = nil
    if not setname then return end
    local db = DB()
    if not string.match(setname, "^~") then
        db.currentSet = setname
        IR.UpdateCurrentSet()
    elseif db.sets[setname] and db.sets[setname].oldset then
        -- An internal staging set finishing restores whichever user set it was
        -- standing in for, so the set button doesn't read "~CombatQueue".
        db.currentSet = db.sets[setname].oldset
        db.sets[setname].oldset = nil
        IR.UpdateCurrentSet()
    end
    if IR.RefreshSetEditorInv then IR.RefreshSetEditorInv() end
end

function IR.LockChangedDuringSetSwap()
    if IR.AnythingLocked() then return end
    local setname = IR.setSwapping
    IR.setSwapping = nil
    IR.IterateSwapList(setname)
    -- Two passes aren't always enough — a swap shuffling items through a bag can
    -- need three. Anything still listed is parked for another pass rather than
    -- dropped while EndSetSwap declares the set equipped with pieces still in bags.
    if next(IR.SwapList) then
        parkSwap(setname)
        return
    end
    IR.EndSetSwap(setname)
end

-- Manual escape hatch: forgets every in-flight and queued swap and rebuilds the
-- location cache. /reload can't do this — every value here is a plain Lua field
-- a reload already clears. What a reload can't touch is real client-side state
-- (an item stuck mid-move, still reported locked); this can't force that either,
-- but it stops the addon compounding it by acting on stale bookkeeping.
function IR.UnstickSwap()
    -- Said out loud before any of it is cleared: if the engine ever wedges
    -- again, what it was wedged ON is the one thing worth knowing, and it's
    -- gone the moment this function does its job.
    local stuck = {}
    if IR.setSwapping      then table.insert(stuck, "mid-swap on \"" .. IR.setSwapping .. "\"") end
    if #IR.SetsWaiting > 0 then table.insert(stuck, #IR.SetsWaiting .. " set(s) queued") end
    if next(IR.CombatQueue) then table.insert(stuck, "items on the combat queue") end
    if IR.nowCasting       then table.insert(stuck, "thinks you're casting") end
    if IR.AnythingLocked() then table.insert(stuck, "the game reports gear locked") end
    IR.Print(#stuck > 0 and ("Was: " .. table.concat(stuck, ", ") .. ".") or "Nothing was stuck.")

    stopWatch()
    IR.setSwapping   = nil
    IR.AbortSwap     = nil
    IR.abortReported = nil
    -- Cleared alongside the rest: a cast whose stop event never arrived blocks
    -- every equip through IR.IsCasting, and unsticking is the user saying the
    -- engine's idea of the world is wrong.
    IR.nowCasting    = nil
    IR.ClearPendingEquip()
    wipe(IR.SwapList)
    wipe(IR.SetsWaiting)
    wipe(IR.CombatQueue)
    IR.combatSet = nil
    IR.ClearLockList()
    IR.PopulateKnownItems()
    if IR.UpdateCombatQueue     then IR.UpdateCombatQueue()     end
    if IR.UpdateButtonLocks     then IR.UpdateButtonLocks()     end
    if IR.RefreshSetEditorInv   then IR.RefreshSetEditorInv()   end
    IR.Print("Cleared. If gear still shows locked, that's the game itself still settling — give it a moment before trying again.")
end

-- fromEvent marks a swap the events engine asked for rather than the user. Only
-- the difference matters: a set the user picked outranks whatever an event is
-- holding (see IR.NoteManualEquip).
function IR.EquipSet(setname, fromEvent)
    -- The one funnel every swap goes through, so this is where a disabled module
    -- stops equipping. Silent for event-driven swaps, which aren't the user asking.
    if not IR.RequireEnabled(fromEvent) then return end
    local db = DB()
    if not setname or not db.sets[setname] then
        IR.Print("Set \"" .. tostring(setname) .. "\" doesn't exist.")
        return
    end
    if not fromEvent and IR.NoteManualEquip then IR.NoteManualEquip(setname) end
    -- IR.setSwapping means an EARLIER EquipSet is still waiting on its second pass:
    -- the item locks it watched can clear just before the debounced handler runs
    -- LockChangedDuringSetSwap, and AnythingLocked() goes false in that gap. A
    -- second EquipSet landing there (what spamming the set button produces) would
    -- wipe() the shared SwapList out from under the first call's retries and
    -- overwrite setSwapping with its own name. Queuing means one runs at a time.
    if IR.IsCasting() or IR.setSwapping or IR.AnythingLocked() then
        IR.AddSetToSetsWaiting(setname, IR.EquipSet, fromEvent)
        return
    end

    local set  = db.sets[setname]
    local swap = IR.SwapList
    wipe(swap)
    IR.abortReported = nil   -- a fresh request gets to report its own wall

    -- In combat (or dead) this equip becomes a promise for when that clears, and any
    -- earlier promise covering the same slots must give way — the old queue was
    -- worked out against gear worn when it was made, so a slot THIS set is happy
    -- with would otherwise keep the previous set's item waiting and swap it in
    -- alongside. Slots this set says nothing about keep what they have queued.
    --
    -- Cleared before the swap list is worked out: a set matching worn gear produces
    -- an empty list and returns early, and still has to release the slots it owns.
    if (UnitAffectingCombat("player") or IR.IsPlayerReallyDead()) and next(IR.CombatQueue) then
        local alreadyQueued = IR.combatSet == setname
        IR.ClearCombatQueueForSet(set)
        -- Asking for the set that's already waiting cancels it rather than
        -- queueing it again, the same way picking a queued item a second time
        -- in a slot menu takes it back off.
        if alreadyQueued then
            IR.combatSet = nil
            IR.UpdateCombatQueue()
            return
        end
        IR.UpdateCombatQueue()
    end

    local couldntFind
    for slot, wanted in pairs(resolveInterchangeable(set.equip)) do
        if GetID(slot) ~= wanted then
            local inv, bag = FindItem(wanted)
            if not inv and not bag then
                couldntFind = (couldntFind or "Could not find: ")
                    .. "[" .. tostring(IR.GetInfoByID(wanted)) .. "] "
            elseif inv ~= slot then
                swap[slot] = wanted
            end
        end
    end
    IR.Print(couldntFind)

    if not next(swap) then
        IR.EndSetSwap(setname)
        return
    end

    if set.old then
        wipe(set.old)
        set.oldset = db.currentSet
    end

    -- Combat and death both block equipment changes outright, so everything is
    -- handed to the combat queue and re-attempted the moment that clears.
    if UnitAffectingCombat("player") or IR.IsPlayerReallyDead() then
        for slot, id in pairs(swap) do
            IR.AddToCombatQueue(slot, id)
            swap[slot] = nil
            if set.old then set.old[slot] = GetID(slot) end
        end
        -- Name the set the queue now holds, then redraw. Each AddToCombatQueue above
        -- redrew already, but all of those ran before this was updated, so the set button
        -- would show nothing until something else refreshed it.
        if next(IR.CombatQueue) then
            IR.combatSet = (set.old and setname) or set.oldset or IR.combatSet
            IR.UpdateCombatQueue()
        end
    end
    if not next(swap) then return end

    if set.showHelm ~= nil then ShowHelm(set.showHelm == 1) end
    if set.showCloak ~= nil then ShowCloak(set.showCloak == 1) end

    -- Anything still in `swap` is about to be handed to the client, so gear is in
    -- flight from here until locks settle — including across EndSetSwap, which
    -- redraws the set button before the items have arrived.
    IR.MarkEquipIssued(setname)
    IR.IterateSwapList(setname)
    if not next(swap) then
        IR.EndSetSwap(setname)
        return
    end

    -- Leftovers need a second pass; setSwapping tells the debounced
    -- ITEM_LOCK_CHANGED handler to run it once locks settle, and the watchdog to run
    -- it anyway if this pass moved nothing — since then no such event is coming.
    parkSwap(setname, true)
end

-- Restores whatever was worn before `setname` was equipped, via the internal
-- "~Unequip" staging set.
function IR.UnequipSet(setname)
    -- Silent: every user-facing route here (slash, ToggleSet, the set buttons,
    -- the editor) already says its piece, and the events engine unwinding its
    -- stack would otherwise print once per active event.
    if not IR.RequireEnabled(true) then return end
    local db  = DB()
    local set = setname and db.sets[setname]
    if not (set and set.old) then return end
    if IR.AnythingLocked() then
        IR.AddSetToSetsWaiting(setname, IR.UnequipSet)
        return
    end
    local unequip = db.sets["~Unequip"].equip
    wipe(unequip)
    for slot, id in pairs(set.old) do unequip[slot] = id end
    db.sets["~Unequip"].oldset = set.oldset
    IR.EquipSet("~Unequip")
end

function IR.ToggleSet(setname, exact)
    -- Guarded here too, not just in EquipSet: the un-equip half of the toggle
    -- reaches EquipSet only indirectly, and one message beats two.
    if not IR.RequireEnabled() then return end
    if IR.IsSetEquipped(setname, exact) then
        IR.UnequipSet(setname)
    else
        IR.EquipSet(setname)
    end
end

-- Equips one item into one slot, bypassing the set machinery. Used by the slot
-- menus, where the user picked exactly one thing.
function IR.EquipItemByID(id, slot)
    if not id then return end
    if IR.IsCasting() or UnitAffectingCombat("player") or IR.IsPlayerReallyDead() then
        IR.AddToCombatQueue(slot, id)
        return
    end
    if GetCursorInfo() or SpellIsTargeting() then return end

    if id == 0 then
        local bag, bagSlot = IR.FindSpace()
        if bag and not IsInventoryItemLocked(slot) then
            PickupInventoryItem(slot)
            PickupContainerItem(bag, bagSlot)
        else
            IR.Print("Not enough room to perform swap.")
        end
        return
    end

    local _, bag, bagSlot = FindItem(id)
    if not bag then return end
    if select(3, GetContainerItemInfo(bag, bagSlot)) or IsInventoryItemLocked(slot) then return end

    local _, _, equipSlot = IR.GetInfoByID(id)
    if equipSlot ~= "INVTYPE_2HWEAPON" or not GetInventoryItemLink("player", 17) then
        PickupContainerItem(bag, bagSlot)
        PickupInventoryItem(slot)
    else
        -- Two-hander going in with something in the off hand: park the off hand
        -- first, otherwise the client silently refuses the swap.
        local freeBag, freeSlot = IR.FindSpace()
        if freeBag then
            PickupInventoryItem(17)
            PickupContainerItem(freeBag, freeSlot)
            PickupInventoryItem(slot)
            PickupContainerItem(bag, bagSlot)
        else
            IR.Print("Not enough room to perform swap.")
        end
    end
end

-- ── Combat queue ─────────────────────────────────────────────────────────────

-- Feign Death reports as dead but can still swap, so it's excluded explicitly.
function IR.IsPlayerReallyDead()
    if UnitIsFeignDeath("player") then return false end
    return UnitIsDeadOrGhost("player")
end

-- Queueing the same item into the same slot twice is a cancel, matching how
-- ItemRack's Alt+click toggles a pending swap off again.
function IR.AddToCombatQueue(slot, id)
    if IR.CombatQueue[slot] == id then
        IR.CombatQueue[slot] = nil
    else
        IR.CombatQueue[slot] = id
    end
    -- IR.combatSet names the set the queued items came from, and is only
    -- meaningful while there's still something queued — cancelling the last
    -- item has to take it with it, or the set button would keep advertising a
    -- set that nothing is waiting to equip.
    if not next(IR.CombatQueue) then IR.combatSet = nil end
    IR.UpdateCombatQueue()
end

-- Drops whatever is queued for the slots `set` covers, leaving the rest of the
-- queue alone. Slot keys are the same either way round, so the raw equip table
-- is enough — resolveInterchangeable only ever trades ids between two slots the
-- set already names.
function IR.ClearCombatQueueForSet(set)
    for slot in pairs(set.equip or {}) do
        IR.CombatQueue[slot] = nil
    end
    if not next(IR.CombatQueue) then IR.combatSet = nil end
end

function IR.ProcessCombatQueue()
    if not IR.IsPlayerReallyDead() and next(IR.CombatQueue) then
        local db      = DB()
        local staging = db.sets["~CombatQueue"].equip
        wipe(staging)
        for slot, id in pairs(IR.CombatQueue) do
            staging[slot] = id
            IR.CombatQueue[slot] = nil
        end
        db.sets["~CombatQueue"].oldset = IR.combatSet
        -- Handed over to the staging set above, and the queue is empty now, so
        -- this stops standing for anything. Cleared before EquipSet runs, which
        -- sets it again itself if the swap ends up queued a second time.
        IR.combatSet = nil
        IR.UpdateCombatQueue()
        IR.EquipSet("~CombatQueue")
    end
end

-- ── Bank support ─────────────────────────────────────────────────────────────

function IR.GetBankedSet(setname)
    if IR.MissingItems(setname) ~= 1 or SpellIsTargeting() or GetCursorInfo() then return end
    IR.ClearLockList()
    for _, id in pairs(DB().sets[setname].equip) do
        local bag, slot = IR.FindInBank(id)
        if bag then
            local freeBag, freeSlot = IR.FindSpace()
            if not freeBag then
                IR.Print("Not enough room in bags to pull all items from '" .. setname .. "'.")
                return
            end
            PickupContainerItem(bag, slot)
            PickupContainerItem(freeBag, freeSlot)
        end
    end
end

function IR.PutBankedSet(setname)
    if SpellIsTargeting() or GetCursorInfo() then return end
    IR.ClearLockList()
    for _, id in pairs(DB().sets[setname].equip) do
        if id ~= 0 then
            local freeBag, freeSlot = IR.FindBankSpace()
            if not freeBag then
                IR.Print("Not enough room in bank to store all items from '" .. setname .. "'.")
                return
            end
            local inv, bag, slot = FindItem(id)
            if inv then
                PickupInventoryItem(inv)
            elseif bag then
                PickupContainerItem(bag, slot)
            end
            if CursorHasItem() then
                PickupContainerItem(freeBag, freeSlot)
            end
        end
    end
end

-- ── Set key bindings ─────────────────────────────────────────────────────────

-- Each bound set gets its own hidden secure button. The macro body also carries
-- explicit /equipslot lines for the weapon slots, which is the only way a set
-- can change weapons while already in combat.
local bindingRetries = 0

-- Frame names go into the binding as "CLICK <name>:LeftButton", and the client
-- splits that action string on whitespace — so a button named after a set like
-- "Tank Set" produces a binding that resolves to nothing at all. Numbering the
-- buttons instead keeps every name a single token.
local BIND_PREFIX = "DrievItemRackSetBind"

-- Slot buttons get a hidden twin rather than the binding pointing at the
-- on-screen button. A CLICK binding fires only the phase ActionButtonUseKeyDown
-- selects, so the visible button would have to follow that CVar to hear the key
-- — which would change what a MOUSE click does and make dragging a bar fire the
-- button. A hidden twin has no mouse behaviour to spoil.
local SLOT_BIND_PREFIX = "DrievItemRackSlotBind"

-- Keys handed to SetBindingClick last pass, so a set that loses its key (or is
-- deleted) can have its binding taken back off rather than left dangling.
local appliedKeys = {}

-- The binding buttons the last pass actually used, so the click phase can be
-- re-applied to exactly those.
local appliedButtons = {}

-- The phase those buttons are currently registered for, and whether a change to
-- it is still owed because combat got in the way. See ReflectBindingClickPhase.
local appliedPhase
local phasePending = false

-- Which click phase counts as the real keypress. A CLICK binding dispatches one
-- phase only — the one `ActionButtonUseKeyDown` selects, for keybinds as much as
-- mouse — so a button left on the default LeftButtonUp never hears the key when
-- that CVar is on, and the binding looks dead. Same CVar the action bars and
-- trinket buttons follow (General → Input).
local function bindingClickPhase()
    return GetCVarBool("ActionButtonUseKeyDown") and "LeftButtonDown" or "LeftButtonUp"
end

-- Called on every CVAR_UPDATE, so any addon's SetCVar lands here — bail unless
-- the phase actually moved. RegisterForClicks IS protected on these secure
-- buttons, so a CVar written mid-encounter (Particles does exactly that) would
-- otherwise blow up as ADDON_ACTION_BLOCKED. If it did flip during combat, owe
-- it until FlushBindingClickPhase runs on leaving.
function IR.ReflectBindingClickPhase()
    local phase = bindingClickPhase()
    if phase == appliedPhase then return end
    if InCombatLockdown() then
        phasePending = true
        return
    end
    phasePending = false
    appliedPhase = phase
    for _, button in ipairs(appliedButtons) do
        button:RegisterForClicks(phase)
    end
end

-- Combat-deferred half of the above, from PLAYER_REGEN_ENABLED.
function IR.FlushBindingClickPhase()
    if phasePending then IR.ReflectBindingClickPhase() end
end

local function anythingBound()
    for setname, set in pairs(DB().sets) do
        if set.key and not string.match(setname, "^~") then return true end
    end
    return next(IR.SlotKeys()) ~= nil
end

-- Is this binding action one of ours? Both kinds of hidden button count: a key
-- we applied and no longer want is only ours to take back if it still points at
-- something we own.
local function isOurBinding(action)
    return action ~= nil and action ~= ""
        and (string.find(action, BIND_PREFIX, 1, true) ~= nil
          or string.find(action, SLOT_BIND_PREFIX, 1, true) ~= nil)
end

-- The binding action a slot button's key hangs off. Public because the hotkey
-- text on the button itself reads back from it.
function IR.SlotBindingAction(id)
    return "CLICK " .. SLOT_BIND_PREFIX .. id .. ":LeftButton"
end

function IR.GetSlotBindingKey(id)
    return (GetBindingKey(IR.SlotBindingAction(id)))
end

-- Applies every key binding Item Rack owns — the sets and the slot buttons
-- alike. One pass for both because they share the stale-key bookkeeping below
-- and, more to the point, SaveBindings: two passes would rewrite the player's
-- binding file twice for one change.
function IR.SetSetBindings()
    if InCombatLockdown() then return end
    -- SaveBindings() rewrites the player's binding file, so don't touch it until the
    -- user has bound something (or we have a stale binding to clear). A disabled
    -- module wants nothing bound, so only the stale half applies — otherwise every
    -- call while off would rewrite the file to no effect.
    local enabled = IR.IsEnabled()
    if not next(appliedKeys) and not (enabled and anythingBound()) then return end

    local bindingSet = GetCurrentBindingSet()
    -- Classic doesn't ship Enum.BindingSet, so validate the value itself rather
    -- than looking it up in an enum that may not exist. A nil/0 result means the
    -- binding data isn't loaded yet and SetBindingClick would silently no-op.
    if type(bindingSet) ~= "number" or bindingSet < 1 then
        if bindingRetries > 3 then return end
        bindingRetries = bindingRetries + 1
        C_Timer.After(5, function() IR.SetSetBindings() end)
        return
    end

    local stale = appliedKeys
    appliedKeys = {}
    wipe(appliedButtons)
    -- This pass registers every set button for the current phase itself, so
    -- nothing is owed afterwards whatever a CVar flip left pending.
    appliedPhase = bindingClickPhase()
    phasePending = false

    -- A disabled module applies nothing, dropping every key it owned into `stale`
    -- and unbinding it — otherwise the slot bindings keep working (secure
    -- `type=item` clicks, so no Lua hook can refuse them) and the module isn't
    -- really off. Re-enabling runs IR.Refresh, which comes back here and rebinds.
    local sets     = enabled and DB().sets or {}
    local slotKeys = enabled and IR.SlotKeys() or {}

    local index = 0
    for setname, set in pairs(sets) do
        if set.key and not string.match(setname, "^~") then
            index = index + 1
            local buttonName = BIND_PREFIX .. index
            local button = _G[buttonName]
                or CreateFrame("Button", buttonName, nil, "SecureActionButtonTemplate")
            button:RegisterForClicks(appliedPhase)
            button:SetAttribute("type", "macro")

            -- /run rather than /deir equip so the binding honours the
            -- "toggle sets on equip" setting. %q escapes any quotes in the name.
            local macrotext = "/run DrievEssentials.ItemRack.RunSetBinding("
                .. string.format("%q", setname) .. ")\n"
            for slot = 16, 18 do
                if set.equip and set.equip[slot] then
                    local name = GetItemInfo(IR.IRStringToItemString(set.equip[slot]))
                    if name then
                        macrotext = macrotext .. "/equipslot [combat]" .. slot .. " " .. name .. "\n"
                    end
                end
            end
            button:SetAttribute("macrotext", macrotext)
            SetBindingClick(set.key, buttonName)
            appliedButtons[#appliedButtons + 1] = button
            appliedKeys[set.key] = true
            stale[set.key] = nil
        end
    end

    -- Slot buttons. Their twins are named after the slot rather than counted,
    -- since unlike sets a slot id never moves.
    for id, key in pairs(slotKeys) do
        local buttonName = SLOT_BIND_PREFIX .. id
        local button = _G[buttonName]
            or CreateFrame("Button", buttonName, nil, "SecureActionButtonTemplate")
        -- Both phases, the way LibActionButton registers its own. The binding then works
        -- whichever phase ActionButtonUseKeyDown sends (so twins never need
        -- re-registering when it flips), and where the client sends both, the release
        -- half tells the visible button the key was let go.
        button:RegisterForClicks("LeftButtonDown", "LeftButtonUp")
        -- The action itself must only ever happen once. A release click is
        -- looked up under `typerelease` rather than `type`, so pointing that at
        -- something the secure code doesn't recognise makes the release half
        -- inert — it exists purely for the visual above.
        button:SetAttribute("typerelease", "none")
        if id == IR.SET_BUTTON then
            -- Not a slot at all: the set button equips whatever set is current,
            -- and which one that is changes as you play.
            button:SetAttribute("type", "macro")
            button:SetAttribute("macrotext", "/run DrievEssentials.ItemRack.RunSetButtonBinding()")
        else
            button:SetAttribute("type", "item")
            button:SetAttribute("slot", id)
        end
        -- The visible button hears nothing about a key press landing on its
        -- twin, so tell it to show the same pushed state a mouse click gives.
        button:SetScript("PostClick", function(_, _, down)
            if IR.SlotButtonClicked then IR.SlotButtonClicked(id, down) end
        end)
        SetBindingClick(key, buttonName)
        -- Deliberately NOT added to appliedButtons: that list exists so the set
        -- binding buttons can follow ActionButtonUseKeyDown, and re-registering
        -- these for one phase is exactly what must not happen to them.
        appliedKeys[key] = true
        stale[key] = nil
    end

    -- Whatever we bound before and no longer want, but only if it's still
    -- pointing at one of our own buttons — the user may have rebound it since.
    for key in pairs(stale) do
        if isOurBinding(GetBindingAction(key)) then
            SetBinding(key, nil)
        end
    end

    SaveBindings(bindingSet)
    bindingRetries = 0
end

function IR.RunSetBinding(setname)
    if getData().equipToggle then
        IR.ToggleSet(setname)
    else
        IR.EquipSet(setname)
    end
end

-- What the set button's own key binding does: the same as left-clicking it.
function IR.RunSetButtonBinding()
    local setname = DB().currentSet
    if not setname or not DB().sets[setname] then
        IR.Print("No set is current, so there's nothing for that key to equip.")
        return
    end
    IR.RunSetBinding(setname)
end

-- Binds `key` to a slot button, or clears it with a nil key. Returns false (and
-- says why) rather than silently doing nothing when the client won't take it.
function IR.SetSlotBinding(id, key)
    if InCombatLockdown() then
        IR.Print("Key bindings can't be changed in combat.")
        return false
    end
    IR.SlotKeys()[id] = key
    IR.SetSetBindings()
    if IR.UpdateHotKeys then IR.UpdateHotKeys() end
    return true
end

-- ── Keys ─────────────────────────────────────────────────────────────────────

-- Modifier keys arrive as key events of their own. Every place that reads a
-- keypress treats them as "still waiting", so Shift+F1 is captured as one chord
-- rather than as bare Shift.
local MODIFIER_KEYS = {
    LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true,
    LALT = true, RALT = true, UNKNOWN = true,
}

function IR.IsModifierKey(key)
    return MODIFIER_KEYS[key] and true or false
end

-- A raw key plus the modifiers currently held, in the order the client itself
-- writes them (ALT-CTRL-SHIFT-KEY). One definition, because the key that gets
-- stored when binding and the key that gets matched when pressed have to agree
-- exactly or a binding silently never lights its button up.
function IR.ChordFromKey(key)
    if IsShiftKeyDown()   then key = "SHIFT-" .. key end
    if IsControlKeyDown() then key = "CTRL-"  .. key end
    if IsAltKeyDown()     then key = "ALT-"   .. key end
    return key
end

-- ── Binding conflicts ────────────────────────────────────────────────────────

-- What `key` is currently bound to: the raw binding action, plus a description
-- fit to show someone. Ours are described in the addon's own terms — the
-- action string for a set is a numbered hidden button nobody would recognise —
-- and everything else falls back to the client's binding names.
function IR.DescribeBoundKey(key)
    if not key or key == "" then return nil end
    local action = GetBindingAction(key)
    if not action or action == "" then return nil end

    local id = tonumber(string.match(action, "^CLICK " .. SLOT_BIND_PREFIX .. "(%d+):"))
    if id then return action, IR.SlotButtonLabel(id) end

    if string.find(action, BIND_PREFIX, 1, true) then
        -- Which set owns it is answered by the key, not by the button index: the
        -- hidden set buttons are renumbered on every rebuild.
        for setname, set in pairs(DB().sets) do
            if set.key == key and not string.match(setname, "^~") then
                return action, "the set \"" .. setname .. "\""
            end
        end
        return action, "another Item Rack set"
    end

    return action, _G["BINDING_NAME_" .. action] or action
end

-- Applies a binding, asking first if the key already belongs to something else
-- and naming what that is. `what` describes the thing being bound and `own` is
-- the binding action that thing already answers to, so re-pressing the key it
-- already has isn't reported as a clash with itself.
function IR.ConfirmBinding(key, what, own, apply, cancel)
    local action, desc = IR.DescribeBoundKey(key)
    if not action or action == own then
        apply()
        return
    end

    local showConfirmPopup = addon.UI and addon.UI.widgets and addon.UI.widgets.showConfirmPopup
    if not showConfirmPopup then apply() return end

    showConfirmPopup({
        title       = "Key Already Bound",
        message     = GetBindingText(key, nil, false) .. " is bound to " .. desc
                    .. ".\n\nBind it to " .. what .. " instead?",
        confirmText = "Rebind",
        onConfirm   = apply,
        onCancel    = cancel,
    })
end
