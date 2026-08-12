-- Item Rack module: core engine. A faithful port of Gello's ItemRack (Classic
-- 4.23) onto this addon's namespace/settings/profile conventions. `...` would
-- give this addon's own private table, so use core's shared namespace instead.
local addon = _G.DrievEssentials
if not addon then return end

local IR = {}
addon.ItemRack = IR

local _   -- scratch for the many multi-return item APIs below

-- ── Client API shims ─────────────────────────────────────────────────────────
-- Classic Era 1.15 moved the container functions into C_Container and dropped
-- the globals. Bind once here so the rest of the file reads like the original.
local GetContainerNumSlots      = C_Container.GetContainerNumSlots
local GetContainerItemLink      = C_Container.GetContainerItemLink
local GetContainerItemCooldown  = C_Container.GetContainerItemCooldown
local ContainerIDToInventoryID  = C_Container.ContainerIDToInventoryID
local GetItemCooldown           = C_Container.GetItemCooldown or _G.GetItemCooldown

-- Only the third return (isLocked) is ever needed from the info table, but keep
-- the original multi-return shape so ported call sites are unchanged.
local function GetContainerItemInfo(bag, slot)
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if not info then return end
    return info.iconFileID, info.stackCount, info.isLocked, info.quality,
           info.isReadable, info.hasLoot, info.hyperlink, info.isFiltered,
           info.hasNoValue, info.itemID, info.isBound
end

IR.GetContainerItemInfo = GetContainerItemInfo

-- ── Settings ─────────────────────────────────────────────────────────────────
-- Behavioural toggles AND the bar layout live in the DE profile, so a switch
-- carries the whole look. The sets stay per-character in DrievItemRackDB — gear
-- is character-specific, and a set naming items a character doesn't own is worse
-- than useless. Sets move via Export/Import.
addon.RegisterDefaults("itemRack", {
    enabled             = false,

    -- layout (see IR.Layout)
    buttons             = {},   -- [0-20] = { cluster, DockTo, Side }
    clusters            = {},   -- [clusterID] = { px, py, scale, spacing, alpha, ... }
    nextCluster         = 1,
    slotKeys            = {},   -- [button id] = key bound to it (see IR.SlotKeys)

    -- menus
    characterSheetMenus = true,   -- pop a slot menu when hovering the character sheet
    menuOnShift         = false,  -- only open menus while Shift is held
    menuOnRight         = false,  -- open button menus with right-click instead of hover
    allowEmpty          = true,   -- offer "(empty)" as a menu choice
    hideTradables       = false,  -- hide non-soulbound gear from menus
    allowHidden         = true,   -- Alt+click a menu entry to hide it
    trinketMenuMode     = false,  -- merge both trinket menus (left=top, right=bottom)
    anchorOther         = false,  -- in trinket menu mode, dock to the bottom trinket
    menuScale           = 0.85,   -- menu scale relative to the button it docks to
    menuGap             = 2,      -- px between a button and its pop-out menu
    menuIconSpacing     = 4,      -- px between icons within a pop-out menu
    setMenuWrap         = false,  -- user-defined wrap point for menus
    setMenuWrapValue    = 3,
    setListOpen         = true,   -- set editor's slide-out set list starts open

    -- movable buttons
    locked              = false,  -- buttons can't be dragged / borders hidden
    buttonSpacing       = 4,
    buttonAlpha         = 1,
    buttonScale         = 1,
    hideOOC             = false,
    showHotKeys         = true,   -- draw each button's key in its corner
    -- `hotkeyFont` false means the game's own number font; anything else is a
    -- LibSharedMedia name. Offsets are from the button's top-right corner, and the
    -- size matches the Action Bars module so the two read as one UI.
    hotkeyFont          = false,
    hotkeyFontSize      = 13,
    hotkeyOffsetX       = -2,
    hotkeyOffsetY       = -2,
    hotkeyColor         = { 1, 1, 1 },
    cooldownCount       = false,
    largeNumbers        = false,
    cooldown90          = false,

    -- behaviour
    equipToggle         = false,  -- equipping an already-worn set unequips it
    equipOnSetPick      = false,  -- picking an item in the set editor equips it too
    -- Opening the set editor off the set button, opt-in per mouse button. Left
    -- only applies when there's no set to equip; right is dead while menuOnRight
    -- has claimed that click for the set menu.
    setEditorOnLeft     = false,
    setEditorOnRight    = false,
    notify              = true,   -- announce when a used item comes off cooldown
    notifyThirty        = false,
    notifyChatAlso      = false,
    showTooltips        = true,
    tinyTooltips        = false,
    tooltipFollow       = false,
    showSetInTooltip    = true,
    disableAltClick     = false,  -- let Alt+click fall through (self-cast) on buttons
})

-- Stand-in returned before core has picked an active profile at PLAYER_LOGIN.
-- Every value reads as nil, i.e. "off", which is the right answer for a module
-- whose settings aren't loaded yet; nothing writes settings before login.
local notReadyYet = {}

function IR.GetData()
    local db = addon.db
    if not (db and db.settings) then return notReadyYet end
    db.settings.itemRack = db.settings.itemRack or {}
    return db.settings.itemRack
end
local getData = IR.GetData

function IR.IsEnabled()
    return getData().enabled and true or false
end

-- Gate for every entry point reachable without the module's buttons: slash
-- commands, the set editor, the equip API (also published as macro globals) and
-- the set keybindings. `silent` suppresses the chat line for internal callers.
function IR.RequireEnabled(silent)
    if IR.IsEnabled() then return true end
    if not silent then
        IR.Print("Item Rack is turned off. Enable it on the Item Rack tab in /driev.")
        -- Turning the module off still leaves its addon loaded, which is a real
        -- distinction to anyone running another gear manager alongside it: the
        -- checkbox stops this module doing anything, but only unticking the addon
        -- itself gets it fully out of the way. Worth saying here, because "I
        -- turned it off and something still isn't right" is exactly the moment
        -- someone reads this line.
        IR.Print("Having issues with another gear addon? This one can be switched off completely "
            .. "under |cffffffffEsc → AddOns → Driev's Essentials - Item Rack|r (needs a reload).")
    end
    return false
end

-- ── Per-character saved data ─────────────────────────────────────────────────
-- Lazy init so a first-ever login can't error. Only gear-shaped data lives here;
-- the bar layout is profile data — see IR.Layout.
function IR.DB()
    DrievItemRackDB = DrievItemRackDB or {}
    local db = DrievItemRackDB
    db.sets      = db.sets      or {}   -- [setname] = { equip = {[slot]=id}, icon, old, ... }
    db.hidden    = db.hidden    or {}   -- array of item ids / set names hidden in menus
    db.itemsUsed = db.itemsUsed or {}   -- [baseID] = counter, drives cooldown notifications
    db.setOrder  = db.setOrder  or {}   -- array of set names, the user's own display order
    return db
end
local DB = IR.DB

-- The one place set display order is decided, so a drag in the side list moves
-- the set everywhere at once.
--
-- db.setOrder is the user's arrangement, but is reconciled against db.sets on
-- every read rather than kept in sync at each mutation site, so imports or a
-- hand-edited SavedVariables can't desync it. New sets land at the end.
function IR.GetOrderedSetNames()
    local db      = DB()
    local seen    = {}
    local ordered = {}

    for _, name in ipairs(db.setOrder) do
        -- "^~" sets are internal scratch entries (~Unequip, ~CombatQueue).
        if db.sets[name] and not seen[name] and not string.match(name, "^~") then
            seen[name] = true
            ordered[#ordered + 1] = name
        end
    end

    local extra = {}
    for name in pairs(db.sets) do
        if not seen[name] and not string.match(name, "^~") then
            extra[#extra + 1] = name
        end
    end
    table.sort(extra)
    for _, name in ipairs(extra) do ordered[#ordered + 1] = name end

    -- Write the reconciled list back so the stored order stays a faithful record
    -- of what is actually on screen.
    db.setOrder = ordered
    return ordered
end

-- Persists a reordered list. Copied rather than stored by reference so a caller
-- reusing its working table can't mutate the DB behind our back.
function IR.SetSetOrder(list)
    local db = DB()
    local out = {}
    for _, name in ipairs(list) do
        if db.sets[name] and not string.match(name, "^~") then out[#out + 1] = name end
    end
    db.setOrder = out
end

-- ── Layout (profile) ─────────────────────────────────────────────────────────
-- Buttons are grouped into CLUSTERS: one cluster is one bar of docked buttons,
-- owning the position, scale and padding for everything in it. A button record
-- names its cluster and (unless it's the head) which button it hangs off — never
-- a raw screen position, which lives on the cluster.

-- Detached stand-in for calls that land before core has picked a profile, so
-- they read as "no bars" instead of erroring. Never written back anywhere.
local emptyLayout = { buttons = {}, clusters = {}, nextCluster = 1 }

function IR.Layout()
    local d = getData()
    if d == notReadyYet then return emptyLayout end
    d.buttons     = d.buttons     or {}
    d.clusters    = d.clusters    or {}
    d.nextCluster = d.nextCluster or 1
    return d
end
local Layout = IR.Layout

-- Slot key bindings belong with the bars, not the character: a binding names a
-- SLOT, which means the same thing on every character sharing the profile. (A
-- set's key is the opposite — it names gear only one character owns.)
--
-- The client persists bindings only as an action string pointing at a frame, so
-- we keep our own record and re-assert it.
local emptySlotKeys = {}

function IR.SlotKeys()
    local d = getData()
    if d == notReadyYet then return emptySlotKeys end
    d.slotKeys = d.slotKeys or {}
    return d.slotKeys
end

-- The layout used to live in the per-character DB. Hand it over once, but only
-- to a profile with no bars of its own — several characters can share one, and
-- the first to log in shouldn't overwrite a layout another already put there.
function IR.MigrateLayoutToProfile()
    DrievItemRackDB = DrievItemRackDB or {}
    local old = DrievItemRackDB
    if old.buttons and next(old.buttons) then
        local layout = Layout()
        if not next(layout.buttons) then
            layout.buttons     = old.buttons
            layout.clusters    = old.clusters or {}
            layout.nextCluster = old.nextCluster or 1
        end
    end
    old.buttons, old.clusters, old.nextCluster = nil, nil, nil
end

-- Slot keys used to live in the per-character DB. Hand them over, filling only
-- slots the profile hasn't already claimed, so the second character to log in
-- adds to what's there rather than overwriting it.
function IR.MigrateSlotKeys()
    DrievItemRackDB = DrievItemRackDB or {}
    local old = DrievItemRackDB.slotKeys
    if not old then return end
    local keys = IR.SlotKeys()
    if keys ~= emptySlotKeys then
        for id, key in pairs(old) do
            if keys[id] == nil then keys[id] = key end
        end
        DrievItemRackDB.slotKeys = nil
    end
end

-- Keybind text used to default to off, and core writes every default into a
-- profile when it's created — so a profile made before the default changed still
-- has the old `false` and would never see the new one. Flip it once, remembering
-- that we did so a later deliberate "off" sticks.
function IR.MigrateHotKeyDefault()
    local d = getData()
    if d == notReadyYet or d.hotKeyDefaultApplied then return end
    d.hotKeyDefaultApplied = true
    d.showHotKeys = true
end

-- Pre-cluster button records stored their own Left/Top and dock chain. Rebuild
-- those chains into clusters once, so an existing bar survives the upgrade
-- instead of scattering to screen centre.
function IR.MigrateClusters()
    local layout = Layout()
    local legacy = {}
    for id, data in pairs(layout.buttons) do
        if data.cluster == nil then legacy[id] = data end
    end
    if not next(legacy) then return end

    -- Walk each button up its DockTo chain to find the head that owns a position;
    -- every button sharing a head becomes one cluster.
    local clusterOfHead = {}
    for id, data in pairs(legacy) do
        local head, guard = id, 0
        while layout.buttons[head] and layout.buttons[head].DockTo and guard < 32 do
            head = layout.buttons[head].DockTo
            guard = guard + 1
        end
        local cid = clusterOfHead[head]
        if not cid then
            cid = layout.nextCluster
            layout.nextCluster = cid + 1
            clusterOfHead[head] = cid
            local headData = layout.buttons[head] or {}
            layout.clusters[cid] = {
                px      = headData.Left,
                py      = headData.Top,
                scale   = getData().buttonScale   or 1,
                spacing = getData().buttonSpacing or 4,
                alpha   = getData().buttonAlpha   or 1,
            }
        end
        data.cluster = cid
        data.Left, data.Top = nil, nil
    end
end

-- ── Constants ────────────────────────────────────────────────────────────────

-- The INVTYPE_* flags decide which items a slot's menu offers; `other` names the
-- paired slot (rings/trinkets/weapons) so a 2H swap or a ring shuffle can reason
-- about both at once.
IR.SlotInfo = {
    [0]  = { name = "AmmoSlot",          real = "Ammo",        INVTYPE_AMMO = true },
    [1]  = { name = "HeadSlot",          real = "Head",        INVTYPE_HEAD = true },
    [2]  = { name = "NeckSlot",          real = "Neck",        INVTYPE_NECK = true },
    [3]  = { name = "ShoulderSlot",      real = "Shoulder",    INVTYPE_SHOULDER = true },
    [4]  = { name = "ShirtSlot",         real = "Shirt",       INVTYPE_BODY = true },
    [5]  = { name = "ChestSlot",         real = "Chest",       INVTYPE_CHEST = true, INVTYPE_ROBE = true },
    [6]  = { name = "WaistSlot",         real = "Waist",       INVTYPE_WAIST = true },
    [7]  = { name = "LegsSlot",          real = "Legs",        INVTYPE_LEGS = true },
    [8]  = { name = "FeetSlot",          real = "Feet",        INVTYPE_FEET = true },
    [9]  = { name = "WristSlot",         real = "Wrist",       INVTYPE_WRIST = true },
    [10] = { name = "HandsSlot",         real = "Hands",       INVTYPE_HAND = true },
    [11] = { name = "Finger0Slot",       real = "Top Finger",  INVTYPE_FINGER = true, other = 12 },
    [12] = { name = "Finger1Slot",       real = "Bottom Finger", INVTYPE_FINGER = true, other = 11 },
    [13] = { name = "Trinket0Slot",      real = "Top Trinket", INVTYPE_TRINKET = true, other = 14 },
    [14] = { name = "Trinket1Slot",      real = "Bottom Trinket", INVTYPE_TRINKET = true, other = 13 },
    [15] = { name = "BackSlot",          real = "Cloak",       INVTYPE_CLOAK = true },
    [16] = { name = "MainHandSlot",      real = "Main hand",   INVTYPE_WEAPONMAINHAND = true, INVTYPE_2HWEAPON = true, INVTYPE_WEAPON = true, other = 17 },
    [17] = { name = "SecondaryHandSlot", real = "Off hand",    INVTYPE_WEAPON = true, INVTYPE_WEAPONOFFHAND = true, INVTYPE_SHIELD = true, INVTYPE_HOLDABLE = true, other = 16 },
    [18] = { name = "RangedSlot",        real = "Ranged",      INVTYPE_RANGED = true, INVTYPE_RANGEDRIGHT = true, INVTYPE_THROWN = true, INVTYPE_RELIC = true },
    [19] = { name = "TabardSlot",        real = "Tabard",      INVTYPE_TABARD = true },
}
local SlotInfo = IR.SlotInfo

-- Button id 20 is the "current set" button rather than an inventory slot.
IR.SET_BUTTON = 20

IR.BankSlots = { -1, 5, 6, 7, 8, 9, 10 }

-- Names ItemRack reserves for its own bookkeeping; the user can't save over them.
IR.SetnameBlacklist = {
    [_G.CUSTOM or "Custom"] = true,
    ["~CombatQueue"] = true,
    ["~Unequip"]     = true,
}

IR.DEFAULT_SET_ICON = "Interface\\Icons\\INV_Misc_Gear_01"

IR.BankOpen    = nil
IR.CombatQueue = {}   -- [slot] = id waiting to swap in once combat ends
IR.LockList    = {}   -- [-2..11][index] = true, one swap claim per item location
IR.KnownItems  = {}   -- [itemRackID] = packed location, rebuilt whenever locks settle
for i = -2, 11 do IR.LockList[i] = {} end

function IR.Print(msg)
    if msg then
        DEFAULT_CHAT_FRAME:AddMessage("|cfffb2c36Item Rack:|r " .. msg)
    end
end

-- ── Season of Discovery runes ────────────────────────────────────────────────
-- Two items can share an itemID and differ only by the rune engraved on them,
-- so the rune id is appended to our item string to keep them distinguishable.
local AppendRuneID
if C_Engraving and C_Engraving.IsEngravingEnabled and C_Engraving.IsEngravingEnabled() then
    AppendRuneID = function(bag, slot)
        local info
        if slot then
            if not C_Engraving.IsInventorySlotEngravable(bag, slot) then return "" end
            info = C_Engraving.GetRuneForInventorySlot(bag, slot)
        else
            if not C_Engraving.IsEquipmentSlotEngravable(bag) then return "" end
            info = C_Engraving.GetRuneForEquipmentSlot(bag)
        end
        return ":runeid:" .. tostring(info and info.skillLineAbilityID or 0)
    end
end

-- ── Item identity ────────────────────────────────────────────────────────────
-- An "IR string" is the itemString minus its "item:" prefix, e.g.
-- "19019:2564:0:0:0:0:0:0:60:0". It carries enchant/suffix data, so two copies
-- of one base item with different enchants stay distinguishable — the whole
-- reason sets don't just store itemIDs.
local PAT_REGULAR_TO_IR   = "item:(.-)\124h"
local PAT_BASEID_FROM_IR  = "^(%-?%d+)"
local PAT_BASEID_FROM_REG = "item:(%-?%d+)"

-- itemLink/itemString -> IR string, or (baseid=true) IR string -> base itemID,
-- or (baseid and regular both true) itemLink -> base itemID. Returns 0 on a
-- pattern miss so callers can compare against 0 for "nothing here".
function IR.GetIRString(input, baseid, regular)
    local pattern = baseid
        and (regular and PAT_BASEID_FROM_REG or PAT_BASEID_FROM_IR)
        or PAT_REGULAR_TO_IR
    return string.match(input or "", pattern) or 0
end
local GetIRString = IR.GetIRString

-- Every itemString embeds the player's level at the time it was captured, so a
-- set saved at level 58 would never string-match the same item at 60 without
-- this rewrite of the level/spec fields.
function IR.UpdateIRString(id)
    return (string.gsub(id or "", "^(" .. strrep("%d+:", 8) .. ")%d+:%d+",
        "%1" .. UnitLevel("player") .. ":" .. "0"))
end
local UpdateIRString = IR.UpdateIRString

function IR.IRStringToItemString(id)
    return "item:" .. (id or "")
end
local IRStringToItemString = IR.IRStringToItemString

-- bag,nil = an equipped inventory slot; bag,slot = a container slot.
function IR.GetID(bag, slot)
    local itemLink
    if slot then
        itemLink = GetContainerItemLink(bag, slot)
    elseif bag == INVSLOT_AMMO then
        -- The ammo slot's link API misreports on Classic; go via the item id.
        local id = GetInventoryItemID("player", bag)
        if id then _, itemLink = GetItemInfo(id) end
    else
        itemLink = GetInventoryItemLink("player", bag)
    end
    local base = GetIRString(itemLink)
    if AppendRuneID then
        local suffix = AppendRuneID(bag, slot)
        if suffix ~= "" then return base .. suffix end
    end
    return base
end
local GetID = IR.GetID

-- Loose match: same base item, ignoring enchants/gems/suffix.
function IR.SameID(id1, id2)
    return GetIRString(id1, true) == GetIRString(id2, true)
end
local SameID = IR.SameID

function IR.GetInfoByID(id)
    if not id or id == 0 then
        return "(empty)", "Interface\\Icons\\INV_Misc_QuestionMark", nil, 0
    end
    local name, _, quality, _, _, _, _, _, equip, texture =
        GetItemInfo(IRStringToItemString(UpdateIRString(id)))
    return name, texture, equip, quality
end
local GetInfoByID = IR.GetInfoByID

function IR.GetCountByID(id)
    return tonumber(GetItemCount(GetIRString(id, true))) or 0
end
local GetCountByID = IR.GetCountByID

-- Icon for a slot button: the worn item's texture, or the slot's empty art.
-- Slot 20 is the set button, which shows the current set's chosen icon.
function IR.GetTextureBySlot(slot)
    if slot == IR.SET_BUTTON then
        local db = DB()
        local set = db.currentSet and db.sets[db.currentSet]
        return (set and set.icon) or IR.DEFAULT_SET_ICON
    end
    local texture = GetInventoryItemTexture("player", slot)
    if texture then return texture end
    local _, empty = GetInventorySlotInfo(SlotInfo[slot].name)
    return empty
end

-- ── Item location ────────────────────────────────────────────────────────────

local GetItemFamily = _G.GetItemFamily or (C_Item and C_Item.GetItemFamily)

-- Quivers and ammo pouches can't hold gear, so they're skipped when searching
-- for an item or for free space. An empty bag slot reports no family at all;
-- treat that as valid since it has zero slots to iterate anyway.
function IR.ValidBag(bagid)
    if bagid == 0 or bagid == -1 then return true end
    local invID  = ContainerIDToInventoryID(bagid)
    local baseID = GetIRString(GetInventoryItemLink("player", invID), true, true)
    return (GetItemFamily(baseID) or 0) == 0
end
local ValidBag = IR.ValidBag

-- Cache of which location holds this exact IR string, rebuilt when item locks
-- settle. One integer covers both kinds: a worn slot as -(slot+1) (the +1 keeps
-- slot 0, ammo, negative), a bag position as bag*100+slot.
function IR.PopulateKnownItems()
    local known = IR.KnownItems
    wipe(known)
    for i = 0, 19 do
        local id = GetID(i)
        if id ~= 0 then known[id] = -(i + 1) end
    end
    for bag = 0, 4 do
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            local id = GetID(bag, slot)
            if id ~= 0 and IsEquippableItem(GetIRString(id, true)) then
                known[id] = bag * 100 + slot
            end
        end
    end
end

-- Returns inv,bag,slot. inv set = worn; bag+slot set = in a container; all nil =
-- not found. Exact IR-string matches win; a base-id match is the fallback, so a
-- set still equips something sane when the exact enchanted copy is gone.
function IR.FindItem(id, lock)
    local locklist = IR.LockList
    id = UpdateIRString(id)

    local known = IR.KnownItems[id]
    if known then
        if known < 0 then
            local inv = -known - 1
            if id == GetID(inv) and (not lock or not locklist[-2][inv]) then
                if lock then locklist[-2][inv] = true end
                return inv
            end
        else
            local bag, slot = math.floor(known / 100), known % 100
            if slot > 0 and id == GetID(bag, slot) and (not lock or not locklist[bag][slot]) then
                if lock then locklist[bag][slot] = true end
                return nil, bag, slot
            end
        end
    end

    for bag = 4, 0, -1 do
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            if id == GetID(bag, slot) and (not lock or not locklist[bag][slot]) then
                if lock then locklist[bag][slot] = true end
                return nil, bag, slot
            end
        end
    end
    for i = 0, 19 do
        if id == GetID(i) and (not lock or not locklist[-2][i]) then
            if lock then locklist[-2][i] = true end
            return i
        end
    end
    for bag = 4, 0, -1 do
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            if SameID(id, GetID(bag, slot)) and (not lock or not locklist[bag][slot]) then
                if lock then locklist[bag][slot] = true end
                return nil, bag, slot
            end
        end
    end
    for i = 0, 19 do
        if SameID(id, GetID(i)) and (not lock or not locklist[-2][i]) then
            if lock then locklist[-2][i] = true end
            return i
        end
    end
end
local FindItem = IR.FindItem

-- Bank contents are only readable while the bank frame is open, so every caller
-- has to tolerate a nil result even when the item really is banked.
function IR.FindInBank(id, lock)
    if not IR.BankOpen then return end
    local locklist = IR.LockList
    id = UpdateIRString(id)
    for _, bag in ipairs(IR.BankSlots) do
        if ValidBag(bag) then
            for slot = 1, (GetContainerNumSlots(bag) or 0) do
                if id == GetID(bag, slot) and (not lock or not locklist[bag][slot]) then
                    if lock then locklist[bag][slot] = true end
                    return bag, slot
                end
            end
        end
    end
    for _, bag in ipairs(IR.BankSlots) do
        if ValidBag(bag) then
            for slot = 1, (GetContainerNumSlots(bag) or 0) do
                if SameID(id, GetID(bag, slot)) and (not lock or not locklist[bag][slot]) then
                    if lock then locklist[bag][slot] = true end
                    return bag, slot
                end
            end
        end
    end
end
local FindInBank = IR.FindInBank

function IR.FindSpace()
    for bag = 4, 0, -1 do
        if ValidBag(bag) then
            for slot = 1, (GetContainerNumSlots(bag) or 0) do
                if not GetContainerItemLink(bag, slot) and not IR.LockList[bag][slot] then
                    IR.LockList[bag][slot] = true
                    return bag, slot
                end
            end
        end
    end
end

function IR.FindBankSpace()
    if not IR.BankOpen then return end
    for _, bag in ipairs(IR.BankSlots) do
        if ValidBag(bag) then
            for slot = 1, (GetContainerNumSlots(bag) or 0) do
                if not GetContainerItemLink(bag, slot) and not IR.LockList[bag][slot] then
                    IR.LockList[bag][slot] = true
                    return bag, slot
                end
            end
        end
    end
end

function IR.ClearLockList()
    for i = -2, 11 do wipe(IR.LockList[i]) end
    if IR.locksHaveChanged then
        IR.locksHaveChanged = nil
        IR.PopulateKnownItems()
    end
end

function IR.AnythingLocked()
    for i = 1, 19 do
        if IsInventoryItemLocked(i) then return true end
    end
    for bag = 0, 4 do
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            if select(3, GetContainerItemInfo(bag, slot)) then return true end
        end
    end
end

-- ── Hidden scanning tooltip ──────────────────────────────────────────────────
-- Deciding whether an item is wearable means reading its tooltip for red
-- requirement-failed lines — there's no API for it. Scanning uses a private
-- tooltip so the visible GameTooltip is never disturbed.

local scanTip = CreateFrame("GameTooltip", "DrievItemRackScanTooltip", nil, "GameTooltipTemplate")
scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
IR.scanTooltip = scanTip

-- Real values are derived from the localised templates at PLAYER_LOGIN; these
-- placeholders only exist so a call before then can't pass nil to string.find.
local DURABILITY_PATTERN, REQUIRES_PATTERN = "\1", "\1"

local function isRedLine(which)
    local line = _G["DrievItemRackScanTooltipText" .. which]
    if not line then return false end
    local r, g, b = line:GetTextColor()
    return r > 0.9 and g < 0.2 and b < 0.2
end

-- Durability and "Requires <skill>" lines are red on plenty of perfectly
-- wearable items, so they're excluded before a red line is taken as a veto.
function IR.PlayerCanWear(invslot, bag, slot)
    local i = 1
    while _G["DrievItemRackScanTooltipTextLeft" .. i] do
        -- ClearLines leaves colours behind, so blank them by hand first.
        _G["DrievItemRackScanTooltipTextLeft" .. i]:SetTextColor(0, 0, 0)
        _G["DrievItemRackScanTooltipTextRight" .. i]:SetTextColor(0, 0, 0)
        i = i + 1
    end
    scanTip:SetBagItem(bag, slot)

    for line = 2, scanTip:NumLines() do
        local txt = _G["DrievItemRackScanTooltipTextLeft" .. line]:GetText() or ""
        if (isRedLine("Left" .. line) or isRedLine("Right" .. line))
            and not string.find(txt, DURABILITY_PATTERN, 1, false)
            and not string.match(txt, REQUIRES_PATTERN) then
            return false
        end
    end

    local _, _, itemType = GetInfoByID(GetID(bag, slot))
    if itemType == "INVTYPE_WEAPON" and invslot == 17 and not IR.canWearOneHandOffHand then
        return false
    end
    return true
end

function IR.IsSoulbound(bag, slot)
    scanTip:SetBagItem(bag, slot)
    for i = 2, 5 do
        local line = _G["DrievItemRackScanTooltipTextLeft" .. i]
        local text = line and line:GetText()
        if text == ITEM_SOULBOUND or text == ITEM_BIND_QUEST or text == ITEM_CONJURED then
            return true
        end
    end
end

-- ── Hidden menu entries ──────────────────────────────────────────────────────

function IR.IsHidden(id)
    local hidden = DB().hidden
    for i = 1, #hidden do
        if hidden[i] == id then return true end
    end
end

function IR.ToggleHidden(id)
    if not id then return end
    local hidden = DB().hidden
    for i = 1, #hidden do
        if hidden[i] == id then table.remove(hidden, i) return end
    end
    table.insert(hidden, id)
end

-- ── Cooldown notification ────────────────────────────────────────────────────

local function notify(msg)
    PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN)
    if SHOW_COMBAT_TEXT == "1" and CombatText_AddMessage then
        CombatText_AddMessage(msg, CombatText_StandardScroll, 0.2, 0.7, 0.9)
    else
        UIErrorsFrame:AddMessage(msg, 0.2, 0.7, 0.9, 1, UIERRORS_HOLD_TIME)
    end
    if getData().notifyChatAlso then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33b2e5" .. msg)
    end
end

-- Records that an item was used so the ticker below can announce its cooldown.
-- Hooked onto UseInventoryItem globally, so it has to respect the module toggle
-- itself rather than relying on a caller that only exists when enabled.
function IR.ReflectItemUse(slot)
    if not getData().enabled then return end
    if IR.FlashButton then IR.FlashButton(slot) end
    -- Keyed by numeric itemID: C_Container.GetItemCooldown is a typed API and
    -- won't take the string GetIRString hands back.
    local baseID = tonumber(GetIRString(GetInventoryItemLink("player", slot), true, true))
    if baseID and baseID > 0 then
        DB().itemsUsed[baseID] = 1
    end
end

-- Tracks each used item through three phases: three seconds of "wait and see"
-- (the global cooldown is indistinguishable from a real one at first), then a
-- tag for how long the real cooldown turned out to be, then the announcement.
local function cooldownTick()
    local d  = getData()
    local db = DB()
    for id, stage in pairs(db.itemsUsed) do
        local start, duration = GetItemCooldown(id)
        if start then
            if stage < 3 then
                db.itemsUsed[id] = stage + 1
            else
                local remain = duration - (GetTime() - start)
                if start > 0 and db.itemsUsed[id] < 5 then
                    -- First real cooldown seen: tag it for a 30-second warning
                    -- as well, or just the ready announcement if it's shorter.
                    if remain > 29 then
                        db.itemsUsed[id] = 30
                    elseif remain > 5 then
                        db.itemsUsed[id] = 5
                    end
                end
                if db.itemsUsed[id] == 30 and start > 0 and remain < 30 then
                    if d.notifyThirty then
                        local name = GetItemInfo(id)
                        if name then notify(name .. " ready soon!") end
                    end
                    db.itemsUsed[id] = 5
                elseif db.itemsUsed[id] == 5 and start == 0 then
                    if d.notify then
                        local name = GetItemInfo(id)
                        if name then notify(name .. " ready!") end
                    end
                end
                if start == 0 then db.itemsUsed[id] = nil end
            end
        end
    end
    if d.cooldownCount then
        if IR.WriteButtonCooldowns then IR.WriteButtonCooldowns() end
        if IR.WriteMenuCooldowns   then IR.WriteMenuCooldowns()   end
    end
end

-- ── Debounce helper ──────────────────────────────────────────────────────────
-- ITEM_LOCK_CHANGED fires in bursts during a swap, and the work has to run once
-- after the burst ends, so each event pushes the deadline forward.
local function makeDebounce(delay, fn)
    local deadline, frame = 0, CreateFrame("Frame")
    frame:Hide()
    frame:SetScript("OnUpdate", function(self)
        if GetTime() < deadline then return end
        self:Hide()
        fn()
    end)
    return function()
        deadline = GetTime() + delay
        frame:Show()
    end
end

-- ── Tooltips ─────────────────────────────────────────────────────────────────

function IR.AnchorTooltip(owner)
    local d = getData()
    if IR.menuDockedTo and string.match(IR.menuDockedTo, "^Character") then
        GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    elseif d.tooltipFollow then
        local left = owner.GetLeft and owner:GetLeft()
        GameTooltip:SetOwner(owner, (left and left < 400) and "ANCHOR_RIGHT" or "ANCHOR_LEFT")
    else
        GameTooltip_SetDefaultAnchor(GameTooltip, owner)
    end
end

-- Condenses an item tooltip down to name / charges / durability / cooldown.
function IR.ShrinkTooltip(owner)
    if not getData().tinyTooltips then return end
    local r, g, b = GameTooltipTextLeft1:GetTextColor()
    local name = GameTooltipTextLeft1:GetText()
    local charge, durability, cooldown
    for i = 2, GameTooltip:NumLines() do
        local fs = _G["GameTooltipTextLeft" .. i]
        if fs and fs:IsVisible() then
            local line = fs:GetText() or ""
            if string.find(line, DURABILITY_PATTERN, 1, false) then durability = line end
            if string.match(line, COOLDOWN_REMAINING) then cooldown = line end
            for _, pattern in ipairs(IR.chargesPatterns or {}) do
                if string.find(line, pattern) then charge = line end
            end
        end
    end
    IR.AnchorTooltip(owner)
    GameTooltip:AddLine(name, r, g, b)
    if charge     then GameTooltip:AddLine(charge, 1, 1, 1)     end
    if durability then GameTooltip:AddLine(durability, 1, 1, 1) end
    if cooldown   then GameTooltip:AddLine(cooldown, 1, 1, 1)   end
end

-- Tooltip for a whole set: every slot it covers, greyed when the item is on
-- hand, blue when it's only in the bank, red when it can't be found at all.
function IR.SetTooltip(owner, setname)
    local db  = DB()
    local set = setname and db.sets[setname] and db.sets[setname].equip
    if not set then return end
    IR.AnchorTooltip(owner)
    GameTooltip:AddLine(setname)
    if not getData().tinyTooltips then
        for i = 0, 19 do
            if set[i] then
                local itemName = GetInfoByID(set[i])
                if itemName then
                    local color = "FFAAAAAA"
                    if itemName ~= "(empty)" and GetCountByID(set[i]) == 0 then
                        color = FindInBank(set[i]) and "FF4C80FF" or "FFFF1111"
                    end
                    GameTooltip:AddLine("|cFFFFFFFF" .. SlotInfo[i].real .. ": |c" .. color .. itemName)
                end
            end
        end
    end
    GameTooltip:Show()
end

-- Live tooltip that refreshes once a second so a ticking cooldown updates in
-- place; it stops refreshing the moment the item has no cooldown left to show.
local tooltipTicker

-- Stops the refresh WITHOUT hiding what's on screen: the pointer is still over
-- the item, so the tooltip stays up and only the once-a-second redraw stops.
-- Hiding is OnLeave's job, via IR.ClearTooltip.
local function stopTooltipTicker()
    if tooltipTicker then tooltipTicker:Cancel(); tooltipTicker = nil end
end

local function tooltipUpdate()
    if not IR.tooltipType then return end
    local cooldown
    IR.AnchorTooltip(IR.tooltipOwner)
    if IR.tooltipType == "BAG" then
        GameTooltip:SetBagItem(IR.tooltipBag, IR.tooltipSlot)
        cooldown = GetContainerItemCooldown(IR.tooltipBag, IR.tooltipSlot)
    else
        GameTooltip:SetInventoryItem("player", IR.tooltipSlot)
        cooldown = GetInventoryItemCooldown("player", IR.tooltipSlot)
    end
    IR.ShrinkTooltip(IR.tooltipOwner)
    if IR.tooltipType == "INVENTORY" and IR.tooltipQueued then
        GameTooltip:AddLine("Queued: " .. IR.tooltipQueued)
    end
    GameTooltip:Show()
    -- Nothing counting down, so stop redrawing — but leave the tooltip alone. This
    -- used to call IR.ClearTooltip(), which hides it too, so every item without a
    -- cooldown had its tooltip shown and hidden on the same frame. Worn items dodged
    -- it via IR.IDTooltip's non-ticking path, which is why some pop-out menu entries
    -- had tooltips and others silently didn't.
    local ticking = (cooldown or 0) ~= 0
    if not ticking then stopTooltipTicker() end
    return ticking
end

local function startTooltipTicker()
    -- The first draw also reports whether there's a cooldown worth following;
    -- a plain piece of gear is drawn once and left alone rather than pointlessly
    -- rebuilt every second for as long as the pointer rests on it.
    local ticking = tooltipUpdate()
    stopTooltipTicker()
    if ticking then
        tooltipTicker = C_Timer.NewTicker(1, tooltipUpdate)
    end
end

function IR.InventoryTooltip(owner, slot)
    if not getData().showTooltips then return end
    if slot == IR.SET_BUTTON then
        IR.SetTooltip(owner, DB().currentSet)
        return
    end
    IR.tooltipOwner  = owner
    IR.tooltipType   = "INVENTORY"
    IR.tooltipSlot   = slot
    IR.tooltipQueued = IR.CombatQueue[slot] and GetInfoByID(IR.CombatQueue[slot]) or nil
    startTooltipTicker()
end

-- Tooltip for an item known only by its IR string — used by menus and the set
-- editor, where the item may be worn, bagged, banked or missing entirely.
function IR.IDTooltip(owner, id)
    if not getData().showTooltips then return end
    IR.AnchorTooltip(owner)
    local inv, bag, slot = FindItem(id)
    if inv then
        GameTooltip:SetInventoryItem("player", inv)
    elseif bag then
        GameTooltip:SetBagItem(bag, slot)
    else
        local bBag, bSlot = FindInBank(id)
        local link
        if bBag then
            link = GetContainerItemLink(bBag, bSlot)
        else
            link = IRStringToItemString(UpdateIRString(id))
        end
        GameTooltip:SetHyperlink(link)
    end
    IR.ShrinkTooltip(owner)
    GameTooltip:Show()
end

function IR.MenuItemTooltip(owner, entry)
    if not getData().showTooltips then return end
    if IR.menuOpen == IR.SET_BUTTON then
        IR.SetTooltip(owner, entry)
        return
    end
    local _, bag, slot = FindItem(entry)
    if bag and slot then
        IR.tooltipOwner  = owner
        IR.tooltipType   = "BAG"
        IR.tooltipBag    = bag
        IR.tooltipSlot   = slot
        IR.tooltipQueued = nil
        startTooltipTicker()
    else
        IR.IDTooltip(owner, entry)
    end
end

function IR.ClearTooltip()
    GameTooltip:Hide()
    if tooltipTicker then tooltipTicker:Cancel(); tooltipTicker = nil end
    IR.tooltipType = nil
end

-- Simple explanatory tooltip for the module's own control buttons.
function IR.OnTooltip(owner, line1, line2)
    if not getData().showTooltips or not line1 then return end
    IR.AnchorTooltip(owner)
    GameTooltip:AddLine(line1)
    if line2 then GameTooltip:AddLine(line2, 0.8, 0.8, 0.8, 1) end
    GameTooltip:Show()
end

-- ── "Which sets use this item" tooltip line ──────────────────────────────────

local setsHavingItem = {}
local function listSetsHavingItem(tooltip, id, exact)
    -- The tooltip hooks go in at login whatever the module's state, so this has
    -- to answer for itself: a disabled module annotating every item tooltip with
    -- its sets is the addon still talking with its mouth shut — and doubly wrong
    -- next to the original ItemRack, which is adding the same lines itself.
    if not IR.IsEnabled() then return end
    if not getData().showSetInTooltip then return end
    if not id or id == 0 then return end
    for name, set in pairs(DB().sets) do
        if not string.match(name, "^~") then
            for _, item in pairs(set.equip or {}) do
                if exact then
                    if UpdateIRString(item) == id then setsHavingItem[name] = true end
                elseif SameID(item, id) then
                    setsHavingItem[name] = true
                end
            end
        end
    end
    local any
    for name in pairs(setsHavingItem) do
        tooltip:AddDoubleLine("Set: ", name, 0, 0.6, 1, 0, 0.6, 1)
        setsHavingItem[name] = nil
        any = true
    end
    if any then tooltip:Show() end
end

-- ── Class specifics ──────────────────────────────────────────────────────────

local function updateClassSpecificStuff()
    local _, class = UnitClass("player")
    IR.canWearOneHandOffHand = (class == "WARRIOR" or class == "ROGUE" or class == "HUNTER")
end

-- ── Set export / import ──────────────────────────────────────────────────────
-- Sets belong to the character, so carrying a build to an alt goes through a
-- copy-pasteable string. Core's shared codec does the work; the prefix is ours,
-- so a profile string pasted into the set box is refused rather than
-- half-applied.
local SETS_PREFIX = "DrievItemRackSets1:"

-- `old`/`oldset` are live swap bookkeeping for THIS character, so they're
-- rebuilt empty rather than shipped. Values are type-checked because the same
-- helper reads pasted strings, which are just text someone else typed.
local function sanitiseSet(set)
    local out = { equip = {} }
    for slot, id in pairs(set.equip or {}) do
        if type(slot) == "number" and (type(id) == "string" or type(id) == "number") then
            out.equip[slot] = id
        end
    end
    -- An icon is a texture path on older clients and a bare file ID on newer ones.
    -- Accepting only strings quietly dropped every file-ID icon on the way out, so
    -- those sets arrived wearing the default gear icon. File IDs are the client's
    -- own, so they carry fine.
    local iconType = type(set.icon)
    if iconType == "string" or iconType == "number" then out.icon = set.icon end
    if type(set.key) == "string" then out.key = set.key end
    if type(set.showHelm)  == "number" then out.showHelm  = set.showHelm  end
    if type(set.showCloak) == "number" then out.showCloak = set.showCloak end
    return out
end

-- Returns the string plus how many sets it holds, or nil + an error. `names` is
-- an optional list to include; without it every set on the character goes in.
function IR.ExportSets(names)
    local wanted
    if names then
        wanted = {}
        for k, v in pairs(names) do
            -- Accepts both { "A", "B" } and { A = true, B = true } so callers
            -- can hand over whichever shape they already have.
            if type(v) == "string" then wanted[v] = true elseif v then wanted[k] = true end
        end
    end

    local payload, count = { sets = {} }, 0
    for name, set in pairs(DB().sets) do
        if not string.match(name, "^~") and (not wanted or wanted[name]) then
            payload.sets[name] = sanitiseSet(set)
            count = count + 1
        end
    end
    if count == 0 then
        return nil, wanted and "No sets were selected to export."
            or "This character has no sets to export."
    end
    local str, err = addon.EncodeTable(SETS_PREFIX, payload)
    if not str then return nil, err end
    return str, count
end

-- Decodes an import string without touching the DB, so the UI can ask about name
-- clashes before anything is overwritten. Returns { name = sanitised set } for
-- names this character will accept, plus which of them already exist here.
function IR.ReadSetsString(str)
    local data, err = addon.DecodeTable(SETS_PREFIX, str)
    if not data then return nil, err end
    if type(data.sets) ~= "table" then return nil, "That string doesn't contain any sets." end

    local db, incoming, conflicts, any = DB(), {}, {}, false
    for name, set in pairs(data.sets) do
        if type(name) == "string" and type(set) == "table"
            and not string.match(name, "^~") and not IR.SetnameBlacklist[name] then
            incoming[name] = sanitiseSet(set)
            any = true
            if db.sets[name] then conflicts[#conflicts + 1] = name end
        end
    end
    if not any then return nil, "That string doesn't contain any usable sets." end

    table.sort(conflicts)
    return incoming, conflicts
end

-- Adds `incoming` to this character's sets. Existing sets are left alone unless
-- their name is in `overwrite`, so an import adds rather than replaces. Returns
-- how many were added and how many overwritten.
function IR.ApplySetsImport(incoming, overwrite)
    local allow = {}
    if overwrite then
        for k, v in pairs(overwrite) do
            if type(v) == "string" then allow[v] = true elseif v then allow[k] = true end
        end
    end

    local db, added, replaced = DB(), 0, 0
    for name, set in pairs(incoming) do
        local exists = db.sets[name] ~= nil
        if not exists or allow[name] then
            -- `old` is this character's own live-swap bookkeeping for the set —
            -- what it displaced last time it was equipped HERE — so an incoming
            -- set (and a replaced one) starts with a clean slate rather than
            -- inheriting a record of gear that was never swapped out.
            set.old = {}
            db.sets[name] = set
            if exists then replaced = replaced + 1 else added = added + 1 end
        end
    end
    if added + replaced == 0 then return 0, 0 end

    IR.SetSetBindings()
    if IR.UpdateCurrentSet then IR.UpdateCurrentSet() end
    return added, replaced
end

-- ── Import from the original ItemRack ────────────────────────────────────────
-- The original addon keeps this character's sets in ItemRackUser.Sets, which is
-- a plain global for as long as its addon is loaded — hence the one condition
-- attached to this: both addons have to be enabled at the same time. There's no
-- file to read otherwise, since another addon's SavedVariables are only ever
-- loaded into memory by the addon that owns them.
--
-- The set format is the one this module was ported from and hasn't drifted:
-- equip[slot] holds an IR string (an itemString minus its "item:" prefix), or 0
-- for a deliberately empty slot, alongside an icon and an optional key. Only the
-- helm/cloak flags are spelled differently — upstream capitalises them.
--
-- Returns the same shape IR.ReadSetsString does — { name = set } plus the names
-- that already exist here — so the whole import path downstream is shared.
function IR.ReadOriginalSets()
    local user = _G.ItemRackUser
    if type(user) ~= "table" or type(user.Sets) ~= "table" then
        return nil, "Couldn't find the original ItemRack. Both addons have to be enabled at the "
            .. "same time for this — its sets are only readable while it's loaded."
    end

    local db, incoming, conflicts, any = DB(), {}, {}, false
    for name, set in pairs(user.Sets) do
        if type(name) == "string" and type(set) == "table"
            and not string.match(name, "^~") and not IR.SetnameBlacklist[name] then
            local out = sanitiseSet(set)
            if type(set.ShowHelm)  == "number" then out.showHelm  = set.ShowHelm  end
            if type(set.ShowCloak) == "number" then out.showCloak = set.ShowCloak end
            -- A set naming no gear at all is upstream bookkeeping, not something
            -- the user built.
            if next(out.equip) then
                incoming[name] = out
                any = true
                if db.sets[name] then conflicts[#conflicts + 1] = name end
            end
        end
    end
    if not any then
        return nil, "The original ItemRack is loaded, but has no sets saved on this character."
    end

    table.sort(conflicts)
    return incoming, conflicts
end

-- ── Slash command ────────────────────────────────────────────────────────────

local function slashHandler(arg)
    if not IR.RequireEnabled() then return end
    arg = arg or ""
    local setname = arg:match("^equip%s+(.+)$")
    if setname then IR.EquipSet(setname) return end

    local toggleArg = arg:match("^toggle%s+(.+)$")
    if toggleArg then
        local a, b = toggleArg:match("^(.+),%s*(.+)$")
        if a then
            if IR.IsSetEquipped(a) then IR.EquipSet(b) else IR.EquipSet(a) end
        else
            IR.ToggleSet(toggleArg)
        end
        return
    end

    arg = arg:lower()
    if arg == "sets" or arg == "" then
        IR.ToggleSetEditor()
    elseif arg == "lock" then
        getData().locked = true
        IR.ReflectLock()
    elseif arg == "unlock" then
        getData().locked = false
        IR.ReflectLock()
    elseif arg == "reset" then
        IR.ResetButtons()
    elseif arg == "unstick" then
        IR.UnstickSwap()
    else
        IR.Print("/deir            : open the set editor")
        IR.Print("/deir equip <set>: equip a set")
        IR.Print("/deir toggle <set>[, other set]")
        IR.Print("/deir lock | unlock | reset | unstick")
    end
end

-- /deir and /drievitemrack name this addon, so they're ours outright.
SLASH_DRIEVITEMRACK1 = "/deir"
SLASH_DRIEVITEMRACK2 = "/drievitemrack"
SlashCmdList["DRIEVITEMRACK"] = slashHandler

-- The short forms are convenience aliases other addons may already own — the
-- original ItemRack owns /itemrack — and taking one out from under its owner is
-- worse than going without: the chat system keeps ONE handler per command, so
-- "/itemrack equip Threat" landed HERE instead of on the addon the user meant.
-- With this module turned off that answers "Item Rack is turned off" and stops,
-- which reads as the original addon having broken for no reason. So each alias
-- is only claimed if nothing else has registered it.
local ALIASES = { "/itemrack", "/rack", "/sets", "/ir" }

local function commandIsTaken(cmd)
    cmd = cmd:upper()
    for name in pairs(SlashCmdList) do
        if name ~= "DRIEVITEMRACK" then
            local i = 1
            while _G["SLASH_" .. name .. i] do
                if string.upper(_G["SLASH_" .. name .. i]) == cmd then return true end
                i = i + 1
            end
        end
    end
end

-- Called a frame after PLAYER_LOGIN, which is the earliest every other addon has
-- had its say: the original ItemRack registers /itemrack from its OWN
-- PLAYER_LOGIN handler, and ours may well run first. Indices have to stay
-- contiguous from 1 — the chat system stops reading at the first gap — so the
-- aliases that survive are numbered as they're kept, after the two above.
function IR.ClaimSlashAliases()
    local index = 2
    for _, cmd in ipairs(ALIASES) do
        if not commandIsTaken(cmd) then
            index = index + 1
            _G["SLASH_DRIEVITEMRACK" .. index] = cmd
        end
    end
end

-- ── Event plumbing ───────────────────────────────────────────────────────────

local locksChanged = makeDebounce(0.2, function()
    if IR.UpdateButtonLocks then IR.UpdateButtonLocks() end
    if IR.setSwapping then
        IR.LockChangedDuringSetSwap()
    elseif IR.MenuIsVisible and IR.MenuIsVisible() and IR.BankOpen and not IR.AnythingLocked() then
        IR.HideMenu()
        IR.BuildMenu()
    elseif IR.SetsWaiting and #IR.SetsWaiting > 0 and not IR.AnythingLocked() then
        IR.ProcessSetsWaiting()
    end
    -- Locks having settled is what "the client finished applying our moves"
    -- looks like, so that closes the in-flight window opened by EquipSet.
    -- Checked last: the branches above can hand the client MORE moves, which
    -- re-locks the items and means the swap is still very much in flight.
    if not IR.AnythingLocked() and IR.ClearPendingEquip and IR.ClearPendingEquip() then
        if IR.UpdateCurrentSet then IR.UpdateCurrentSet() end
    end
end)

-- A swap fired mid-cast is silently eaten by the client, so anything queued
-- during a cast waits for the cast to finish before it's retried.
local delayedQueue = makeDebounce(0.1, function()
    if IR.inCombat or IR.IsCasting() then return end
    IR.ProcessCombatQueue()
end)

local handlers = {}

function handlers.PLAYER_LOGIN()
    -- Core picks the active profile in its own PLAYER_LOGIN handler. It loads
    -- (and so registers) first, so it normally runs first — but if anything ever
    -- changes that, retry next frame rather than reading settings from nothing
    -- and silently concluding the module is disabled.
    if not (addon.db and addon.db.settings) then
        C_Timer.After(0, handlers.PLAYER_LOGIN)
        return
    end
    IR.loggedIn = true

    updateClassSpecificStuff()

    DURABILITY_PATTERN = string.match(DURABILITY_TEMPLATE, "(.+) .+/.+") or "Durability"
    REQUIRES_PATTERN   = string.gsub(ITEM_MIN_SKILL, "%%.", ".+")

    -- ITEM_SPELL_CHARGES is a plural-form template ("|4Charge:Charges;"), so it
    -- gets split into one plain pattern per form before it's usable for matching.
    local patterns = {}
    local function split(str)
        local start, stop, single, plural = str:find("\1244(.-):(.-);")
        if start then
            split(str:sub(1, start - 1) .. single .. str:sub(stop + 1))
            split(str:sub(1, start - 1) .. plural .. str:sub(stop + 1))
        else
            table.insert(patterns, (str:gsub("%%d", "%%d+")))
        end
    end
    split(ITEM_SPELL_CHARGES)
    table.insert(patterns, ITEM_SPELL_CHARGES_NONE)
    IR.chargesPatterns = patterns

    -- The internal sets ItemRack uses to stage a partial or reverted swap. They
    -- live in the same table as user sets and are filtered out of every menu by
    -- their "~" prefix.
    local db = DB()
    db.sets["~Unequip"]     = { equip = {} }
    db.sets["~CombatQueue"] = { equip = {} }

    IR.MigrateLayoutToProfile()
    IR.MigrateClusters()
    IR.MigrateSlotKeys()
    IR.MigrateHotKeyDefault()
    IR.PopulateKnownItems()

    hooksecurefunc("UseInventoryItem", function(slot) IR.ReflectItemUse(slot) end)
    hooksecurefunc(GameTooltip, "SetBagItem", function(tooltip, bag, slot)
        listSetsHavingItem(tooltip, GetID(bag, slot), true)
    end)
    hooksecurefunc(GameTooltip, "SetInventoryItem", function(tooltip, _, invSlot)
        listSetsHavingItem(tooltip, GetID(invSlot), true)
    end)
    hooksecurefunc(GameTooltip, "SetHyperlink", function(tooltip, link)
        listSetsHavingItem(tooltip, link:match("item:(.+)"))
    end)

    if IR.InitButtons then IR.InitButtons() end
    C_Timer.NewTicker(1, cooldownTick)
    IR.SetSetBindings()
    -- After InitButtons: the first event pass can equip a set, which redraws
    -- the set button.
    if IR.InitEvents then IR.InitEvents() end

    -- ── Legacy macro/script compatibility ────────────────────────────────────
    -- The original ItemRack exposed a global `ItemRack` table plus bare
    -- EquipSet/ToggleSet/UnequipSet/IsSetEquipped globals for macros. Anyone
    -- migrating has macros written against those, so install them — unless the real
    -- ItemRack addon is loaded, in which case its own globals must win.
    -- Next frame, not now: every other addon's PLAYER_LOGIN handler has run by
    -- then, so what's already registered is finally the whole picture.
    C_Timer.After(0, IR.ClaimSlashAliases)

    if not (_G.ItemRack and _G.ItemRack.EquipSet) then
        _G.ItemRack = _G.ItemRack or {}
        _G.ItemRack.EquipSet       = IR.EquipSet
        _G.ItemRack.ToggleSet      = IR.ToggleSet
        _G.ItemRack.UnequipSet     = IR.UnequipSet
        _G.ItemRack.IsSetEquipped  = IR.IsSetEquipped
    end
    if not _G.EquipSet      then _G.EquipSet      = IR.EquipSet      end
    if not _G.ToggleSet     then _G.ToggleSet     = IR.ToggleSet     end
    if not _G.UnequipSet    then _G.UnequipSet    = IR.UnequipSet    end
    if not _G.IsSetEquipped then _G.IsSetEquipped = IR.IsSetEquipped end
end

function handlers.UNIT_INVENTORY_CHANGED(unit)
    if unit ~= "player" then return end
    if IR.UpdateButtons then IR.UpdateButtons() end
    if IR.MenuIsVisible and IR.MenuIsVisible() then IR.BuildMenu() end
    if IR.RefreshSetEditorInv then IR.RefreshSetEditorInv() end
end

function handlers.ITEM_LOCK_CHANGED()
    IR.locksHaveChanged = true
    locksChanged()
end

function handlers.ACTIONBAR_UPDATE_COOLDOWN()
    if IR.UpdateButtonCooldowns then IR.UpdateButtonCooldowns() end
end

function handlers.UPDATE_BINDINGS()
    if IR.UpdateHotKeys then IR.UpdateHotKeys() end
end

function handlers.PLAYER_REGEN_DISABLED()
    local wasInCombat = IR.inCombat
    IR.inCombat = true
    if wasInCombat or not IR.ReflectHideOOC then return end

    -- Only the real start of a fight gets here. Zoning while already in combat
    -- (walking into an instance mid-pull) re-fires this event with the lockdown
    -- up since the pull began and no grace window left, so the Show() calls
    -- inside are refused one per button — nine buttons, nine
    -- ADDON_ACTION_BLOCKED reports. There's nothing to do in that case either:
    -- the buttons were already put in their in-combat state when combat actually
    -- started, and frames keep their visibility across a zone.
    --
    -- The flag marks the window the client does allow, so ReflectHideOOC can
    -- tell this caller apart from the ones that have to wait for the fight to
    -- end.
    IR.regenGrace = true
    IR.ReflectHideOOC()
    IR.regenGrace = nil
end

local function leftCombatOrDeath()
    IR.inCombat = InCombatLockdown()
    if IR.FlushBindingClickPhase then IR.FlushBindingClickPhase() end
    if IR.FlushPendingApply then IR.FlushPendingApply() end
    -- Ahead of the casting check: what's on screen has nothing to do with a cast
    -- being in progress, and the early return below would otherwise leave the
    -- buttons in their in-combat state whenever a fight ends mid-cast.
    if IR.ReflectHideOOC then IR.ReflectHideOOC() end
    if IR.IsCasting() then return end
    IR.ProcessCombatQueue()
end
handlers.PLAYER_REGEN_ENABLED = leftCombatOrDeath
handlers.PLAYER_UNGHOST       = leftCombatOrDeath
handlers.PLAYER_ALIVE         = leftCombatOrDeath

function handlers.BANKFRAME_OPENED() IR.BankOpen = true end
function handlers.BANKFRAME_CLOSED()
    IR.BankOpen = nil
    if IR.HideMenu then IR.HideMenu() end
end

-- IR.nowCasting is set by UNIT_SPELLCAST_START and cleared by whichever stop
-- event follows — a pairing the client does NOT guarantee. A cast finishing
-- across a loading screen leaves the flag stuck on, which was quietly fatal: the
-- swap engine queues every equip behind it, so macros, keybindings, the set
-- button and the menu all silently did nothing until a relog. Ask the client
-- instead, and drop the flag as soon as it disagrees.
function IR.IsCasting()
    if not IR.nowCasting then return false end
    if CastingInfo() or ChannelInfo() then return true end
    IR.nowCasting = nil
    return false
end

function handlers.UNIT_SPELLCAST_START(unit)
    if unit == "player" and (CastingInfo() or ChannelInfo()) then
        IR.nowCasting = true
    end
end

-- A cast that SUCCEEDED may itself be what dropped the player into combat, so
-- that one case defers through the debounce instead of swapping immediately.
local function castingStopped(unit, succeeded)
    if unit ~= "player" or not IR.nowCasting then return end
    IR.nowCasting = nil
    if not succeeded and not IR.inCombat then
        IR.ProcessCombatQueue()
    else
        delayedQueue()
    end
end
handlers.UNIT_SPELLCAST_STOP        = function(unit) castingStopped(unit, false) end
handlers.UNIT_SPELLCAST_SUCCEEDED   = function(unit) castingStopped(unit, true)  end
handlers.UNIT_SPELLCAST_INTERRUPTED = function(unit) castingStopped(unit, false) end
handlers.UNIT_SPELLCAST_FAILED      = function(unit) castingStopped(unit, false) end

function handlers.CHARACTER_POINTS_CHANGED() updateClassSpecificStuff() end

-- Key bindings for sets are re-asserted a few seconds after entering the world:
-- SetBindingClick before the binding set is loaded silently does nothing.
function handlers.PLAYER_ENTERING_WORLD(isLogin, isReload)
    if isLogin or isReload then
        C_Timer.After(15, function() IR.SetSetBindings() end)
    end
end

-- Set bindings fire on the click phase ActionButtonUseKeyDown selects, so the
-- hidden binding buttons have to follow it the moment it changes. The event's
-- name argument has been spelled several ways across client versions, so just
-- re-apply unconditionally — it's a loop over a handful of buttons at most.
function handlers.CVAR_UPDATE()
    if IR.ReflectBindingClickPhase then IR.ReflectBindingClickPhase() end
end

local events = CreateFrame("Frame")
for event in pairs(handlers) do events:RegisterEvent(event) end
events:SetScript("OnEvent", function(_, event, ...)
    -- Plenty of these (UPDATE_BINDINGS, ITEM_LOCK_CHANGED, UNIT_INVENTORY_CHANGED,
    -- ACTIONBAR_UPDATE_COOLDOWN) fire while the UI is still loading, before core
    -- has picked a profile and before this module has built anything. Ignore
    -- everything until our own PLAYER_LOGIN handler has run.
    if event ~= "PLAYER_LOGIN" and not IR.loggedIn then return end
    handlers[event](...)
end)
