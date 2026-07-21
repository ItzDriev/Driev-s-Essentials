-- Part of the Trinkets module addon. `...` would hand us this addon's OWN
-- private table, so reach for core's shared namespace instead — the .toc's
-- ## Dependencies guarantees core has already loaded and set this global.
local addon = _G.DrievEssentials
if not addon then return end

-- Registers hotkey slots in Escape → Key Bindings → Driev's Essentials.
BINDING_HEADER_DRIEVESSENTIALS = "Driev's Essentials"
_G["BINDING_NAME_CLICK DrievTrinketBtn0:LeftButton"] = "Use Top Trinket"
_G["BINDING_NAME_CLICK DrievTrinketBtn1:LeftButton"] = "Use Bottom Trinket"

local SLOT_TOP  = 13
local SLOT_BOT  = 14
local BTN_SIZE  = 40    -- worn trinket button (matches MENU_SIZE so equal scale = equal size)
local BTN_GAP   = 2     -- default gap between the two display buttons
local BTN_PAD   = 6     -- default outer padding around display buttons for easier dragging
local MENU_SIZE = 40    -- bag-menu button
local MENU_PAD  = 6     -- padding + gap for bag-menu buttons
local MAX_MENU  = 30
local WHITE     = "Interface\\Buttons\\WHITE8x8"

local getOrCreateMenu, buildMenu, showMenu, menuFrame, displayFrame
local cancelMenuClose, scheduleMenuClose, positionMenu, scheduleMenuRebuild

-- Set to ElvUI's engine table once the PLAYER_LOGIN handler below confirms
-- ElvUI (or ShadowElvUI) is loaded — see setElvUIEngine(). Left nil otherwise,
-- so elvuiSkinButton() below is a no-op and every worn/menu button keeps its
-- baked Blizzard Classic look.
local elvE

-- Bakes Masque's "Blizzard Classic" skin (Masque/Skins/Blizzard_Classic.lua)
-- directly onto the button, so the default look matches the classic action
-- button style with no Masque required. Masque, if installed and enabled for
-- our group, simply reskins over these standard regions; if its group is
-- disabled (or Masque isn't present), this baked look shows. Every size is
-- from that skin, relative to its 36px reference icon, so it scales with the
-- button: Normal 66/36 (offset 0.5,-0.5), Pushed 38/36, Highlight fills the
-- button (additive). Applied to the state textures explicitly rather than
-- trusting ActionButtonTemplate's own defaults. (The Checked texture is set
-- only on the worn buttons — see getOrCreateDisplay — since it's their
-- click-feedback flash; putting it on the CheckButton menu buttons would
-- leave a stuck glow after a swap click toggles their checked state.)
local ICON_REF     = 36
local NORMAL_RATIO = 66 / ICON_REF
local PUSHED_RATIO = 38 / ICON_REF

local function styleSlotButton(btn, size)
    btn:SetNormalTexture("Interface\\Buttons\\UI-Quickslot2")
    local nt = btn:GetNormalTexture()
    if nt then
        nt:ClearAllPoints()
        local w = size * NORMAL_RATIO
        nt:SetSize(w, w)
        nt:SetPoint("CENTER", btn, "CENTER", 0.5, -0.5)
    end

    btn:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
    local pt = btn:GetPushedTexture()
    if pt then
        pt:ClearAllPoints()
        local w = size * PUSHED_RATIO
        pt:SetSize(w, w)
        pt:SetPoint("CENTER", btn, "CENTER", 0, 0)
    end

    btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    local ht = btn:GetHighlightTexture()
    if ht then ht:ClearAllPoints(); ht:SetAllPoints(btn) end
end

-- ── Saved data ────────────────────────────────────────────────────────────────
-- Moved ahead of the ElvUI skin block below (which needs it to read the
-- elvuiSkinEnabled toggle) — Lua locals aren't visible to code written before
-- them.

local function getData()
    addon.db.settings.trinkets = addon.db.settings.trinkets or {}
    local d = addon.db.settings.trinkets
    if not d.queue then
        d.queue = {
            [0] = { enabled = false, sort = {}, stats = {} },
            [1] = { enabled = false, sort = {}, stats = {} },
        }
    end
    if not d.menuOrder then d.menuOrder = {} end
    if not d.hidden then d.hidden = {} end   -- [itemID] = true → hidden from the bag menu
    -- [encounterID] = { enabled, mainTop, mainBottom, softTop, softBottom } —
    -- per-boss trinkets auto-queued once you're in combat on that encounter.
    if not d.encounters then d.encounters = {} end
    -- One-time migration of the pre-2-set beta layout (top/bottom → main slots).
    -- Flag lives in the profile so each profile migrates once, independently.
    if not d.encMigrated then
        for _, e in pairs(d.encounters) do
            if e.top ~= nil then e.mainTop = e.mainTop or e.top; e.top = nil end
            if e.bottom ~= nil then e.mainBottom = e.mainBottom or e.bottom; e.bottom = nil end
        end
        d.encMigrated = true
    end
    return d
end

-- Reskins one worn/menu trinket button to match ElvUI's action-button look
-- (used by TrinketMenu.lua's own native ElvUI skin, which this mirrors):
-- swap the baked Blizzard Classic Normal/Pushed/Highlight textures for
-- ElvUI's flat bordered button template, then crop+inset the icon the way
-- ElvUI crops every actionbar icon. No-ops until setElvUIEngine() has run, or
-- if the user has unchecked "Skin with ElvUI" (elvuiSkinEnabled, default on).
-- Idempotent (guarded by _elvuiSkinned) since it's called both at button
-- creation and again from refreshElvUISkin() to catch buttons already built
-- before ElvUI was detected.
local function elvuiSkinButton(btn)
    if not (elvE and btn) or btn._elvuiSkinned then return end
    if getData().elvuiSkinEnabled == false then return end
    if not btn.StripTextures or not btn.SetTemplate then return end
    btn._elvuiSkinned = true
    -- StripTextures() clears EVERY texture region on the button, the trinket
    -- icon included, so remember its texture and put it straight back. Without
    -- this the icon only reappeared when something else happened to refresh it
    -- (which is why a toggle off→on left the icon blank while the cooldown
    -- swipe — a separate Cooldown frame — stayed visible).
    local icon = btn.icon
    local savedTexture = icon and icon:GetTexture()
    btn:StripTextures()
    btn:SetTemplate()
    if btn.StyleButton then btn:StyleButton() end
    btn:SetBackdropColor(0, 0, 0, 0)
    if icon then
        if savedTexture then icon:SetTexture(savedTexture) end
        icon:SetTexCoord(unpack(elvE.TexCoords))
        icon:SetInside()
    end
end

-- Undoes elvuiSkinButton: restores the baked Blizzard Classic look (the same
-- styleSlotButton() call used at button creation) and clears the backdrop
-- SetTemplate() added, so toggling the checkbox off reverts live instead of
-- needing a reload.
local function revertElvUIButton(btn, size)
    if not btn or not btn._elvuiSkinned then return end
    btn._elvuiSkinned = nil
    if btn.SetBackdrop then btn:SetBackdrop(nil) end
    styleSlotButton(btn, size)
    local icon = btn.icon
    if icon then
        icon:ClearAllPoints()
        icon:SetAllPoints(btn)
        icon:SetTexCoord(0, 1, 0, 1)
    end
end

-- Applies or reverts the skin across every worn/menu button already built
-- (both frames are created once and memoized — see getOrCreateDisplay/
-- getOrCreateMenu), based on the current elvuiSkinEnabled setting. New
-- buttons self-skin at creation time via elvuiSkinButton, which reads the
-- same setting. Called once ElvUI is confirmed loaded, and again whenever the
-- checkbox is toggled.
local function refreshElvUISkin()
    if not elvE then return end
    local on = getData().elvuiSkinEnabled ~= false
    if displayFrame then
        for which = 0, 1 do
            local btn = displayFrame["t"..which]
            if on then elvuiSkinButton(btn) else revertElvUIButton(btn, BTN_SIZE) end
        end
    end
    if menuFrame then
        for i = 1, MAX_MENU do
            local mb = menuFrame["mb"..i]
            if on then elvuiSkinButton(mb) else revertElvUIButton(mb, MENU_SIZE) end
        end
    end
end

-- Called once the PLAYER_LOGIN handler below confirms ElvUI/ShadowElvUI is
-- loaded.
local function setElvUIEngine(E)
    elvE = E
    refreshElvUISkin()
end

-- ── Bag scanning ─────────────────────────────────────────────────────────────

local baggedTrinkets  = {}
local numTrinkets     = 0
local combatQueue     = {}   -- [targetSlot] = { bag, slot, texture }
-- Preemptive ("soft") queue: [targetSlot] = { id, bag, slot, texture }. Unlike
-- combatQueue (which fires the moment combat ends), a soft-queued trinket waits
-- for a GAMEPLAY condition — the currently-equipped trinket must have been used
-- and its on-use buff expired (see isSwapGateOpen/processSoftQueue) — so you can
-- line up the next trinket without it swapping the active one out mid-effect.
-- Runtime-only, same lifetime as combatQueue (not persisted across relog).
local softQueue       = {}
local pendingMenuShow = false  -- true when showMenu found 0 trinkets due to unloaded item data
local itemInfoTimer   = nil    -- debounce timer for GET_ITEM_INFO_RECEIVED
-- Whether hidden trinkets are currently revealed. Latched from the Alt state
-- only when the mouse ENTERS the display+menu region fresh (see mouseInRegion):
-- hovering the display with Alt held reveals them, without Alt hides them. It
-- is NOT re-latched on internal moves (button↔frame, display→menu) nor tied to
-- the live Alt state, so releasing Alt and moving onto the menu keeps them shown.
local showHidden      = false
local mouseInRegion   = false  -- mouse currently over the display or bag menu

local function scanBags()
    local d      = getData()
    local hidden = d.hidden or {}

    local found = {}
    for bag = 0, 4 do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local link = C_Container.GetContainerItemLink(bag, slot)
            if link then
                local id = link:match("item:(%d+)")
                if id then
                    local name, _, _, _, _, _, _, _, equipSlot, tex = GetItemInfo(id)
                    if equipSlot == "INVTYPE_TRINKET" then
                        tinsert(found, { id=id, bag=bag, slot=slot,
                                         name=name or "", texture=tex,
                                         hidden = hidden[id] and true or false })
                    end
                end
            end
        end
    end

    -- Base ordering within a visibility group: menu order (if enabled) or bag
    -- position, matching the previous behaviour.
    local omap
    if d.menuOrderEnabled then
        omap = {}
        for i, id in ipairs(d.menuOrder or {}) do omap[id] = i end
    end
    local function baseLess(a, b)
        if omap then
            local ai = omap[a.id] or 9999
            local bi = omap[b.id] or 9999
            if ai ~= bi then return ai < bi end
            return a.name < b.name
        end
        if a.bag ~= b.bag then return a.bag < b.bag end
        return a.slot < b.slot
    end
    -- Hidden trinkets always sort AFTER visible ones.
    table.sort(found, function(a, b)
        if a.hidden ~= b.hidden then return b.hidden end   -- non-hidden first
        return baseLess(a, b)
    end)

    baggedTrinkets = found
    numTrinkets    = math.min(#found, MAX_MENU)
end

-- Adds newly discovered bag/equipped trinkets to d.menuOrder.
local function populateMenuOrder()
    local d     = getData()
    local order = d.menuOrder or {}
    local oset  = {}
    for _, id in ipairs(order) do oset[id] = true end

    for _, t in ipairs(baggedTrinkets) do
        if not oset[t.id] then tinsert(order, t.id); oset[t.id] = true end
    end
    for which = 0, 1 do
        local link = GetInventoryItemLink("player", SLOT_TOP + which)
        if link then
            local id = link:match("item:(%d+)")
            if id and not oset[id] then tinsert(order, id); oset[id] = true end
        end
    end
    d.menuOrder = order
end

local function ensureInQueueSort(id)
    local d = getData()
    for which = 0, 1 do
        local list  = d.queue[which].sort
        local found = false
        for _, sid in ipairs(list) do
            if sid == id then found = true; break end
        end
        if not found then tinsert(list, id) end
    end
end

local function populateQueueSorts()
    scanBags()
    for _, t in ipairs(baggedTrinkets) do ensureInQueueSort(t.id) end
    for which = 0, 1 do
        local link = GetInventoryItemLink("player", SLOT_TOP + which)
        if link then
            local id = link:match("item:(%d+)")
            if id then ensureInQueueSort(id) end
        end
    end
    populateMenuOrder()
end

-- ── Auto queue ───────────────────────────────────────────────────────────────

local function itemCooldownRemaining(id)
    local fn = (C_Container and C_Container.GetItemCooldown) or GetItemCooldown
    if not fn then return 0 end
    local start, duration = fn(tonumber(id) or id)
    if not start or start == 0 then return 0 end
    return math.max(0, duration - (GetTime() - start))
end

local function trinketNearReady(id)
    return itemCooldownRemaining(id) <= 30
end

-- Whether the on-use buff from THIS trinket is still active on the player.
-- Classic has no AuraUtil.FindAuraByName, so scan HELPFUL auras by name.
local function itemBuffActive(id)
    local buffName = GetItemSpell(tonumber(id) or id)
    if not buffName then return false end
    for i = 1, 40 do
        local name = UnitAura("player", i, "HELPFUL")
        if not name then break end
        if name == buffName then return true end
    end
    return false
end

-- Equipping ANY on-use trinket applies a generic "just equipped" swap lockout,
-- shown as a normal cooldown swipe, regardless of whether the trinket was
-- ever actually clicked — indistinguishable from a real on-use cooldown by
-- duration alone (some real trinket cooldowns are themselves under 30s).
-- Tracks, per slot, whether the currently-equipped trinket has been confirmed
-- used since it was equipped (via markTrinketUsed, hooked to the player's
-- UNIT_SPELLCAST_SUCCEEDED below); reset whenever the equipped item changes.
-- Auto-queue must never swap a trinket away before it's had a chance to be
-- used at all.
local queueUsedTracker = { [0] = { id = nil, used = false }, [1] = { id = nil, used = false } }

-- Called on UNIT_SPELLCAST_SUCCEEDED("player", ...). If the spell that just
-- succeeded is the on-use spell of whichever trinket is currently equipped in
-- slot 0/1, marks that slot's trinket as genuinely used.
local function markTrinketUsed(spellName)
    if not spellName then return end
    for which = 0, 1 do
        local link      = GetInventoryItemLink("player", SLOT_TOP + which)
        local currentID = link and link:match("item:(%d+)")
        if currentID and GetItemSpell(currentID) == spellName then
            local tracker = queueUsedTracker[which]
            tracker.id, tracker.used = currentID, true
        end
    end
end

-- processQueue is defined further down (after grayOutDisplaySlot/
-- markSwappedOut/updateQueueIndicators/menuSwapFreeze, which it reuses so an
-- auto-queued swap gets the exact same combat-queueing and visual feedback as
-- a manual click) — see below the bag-menu button setup.

-- ── Notify ───────────────────────────────────────────────────────────────────

local watchedCooldowns = {}

local function tickNotify()
    local d = getData()
    if not d.notify then wipe(watchedCooldowns); return end
    for which = 0, 1 do
        local slot = SLOT_TOP + which
        local link = GetInventoryItemLink("player", slot)
        local id   = link and link:match("item:(%d+)")
        if id then
            local start = GetInventoryItemCooldown("player", slot)
            if start and start > 0 then
                watchedCooldowns[id] = true
            elseif watchedCooldowns[id] then
                local name = GetItemInfo(tonumber(id) or id)
                if name then
                    print("|cfffb2c36Driev's Essentials:|r " .. name .. " is ready!")
                end
                watchedCooldowns[id] = nil
            end
        end
    end
end

-- ── Keybind display ───────────────────────────────────────────────────────────

-- Hard safety cap so keybind text never spills outside the icon, regardless of
-- whether the user's abbreviation option is on. Applied to the final string.
local MAX_BIND_CHARS = 5

local function formatKeybind(key, truncate)
    if not key or key == "" then return "" end
    -- Non-truncated: use WoW's human-readable name as-is, but still hard-cap the
    -- length so verbose names (e.g. "MOUSEWHEELUP") don't overflow the button.
    if not truncate then
        return (GetBindingText(key, "KEY_") or key):sub(1, MAX_BIND_CHARS)
    end

    -- Truncated: work on the raw binding key (always uppercase WoW internal
    -- format from GetBindingKey, e.g. "CTRL-H", "NUMPADPLUS", "BUTTON4").
    local k = key

    -- Strip modifier prefixes and collect abbreviations.
    local mods = ""
    if k:find("CTRL%-")  then mods = mods .. "C"; k = k:gsub("CTRL%-",  "") end
    if k:find("ALT%-")   then mods = mods .. "A"; k = k:gsub("ALT%-",   "") end
    if k:find("SHIFT%-") then mods = mods .. "S"; k = k:gsub("SHIFT%-", "") end

    -- Numpad
    k = k:gsub("^NUMPADPLUS$",     "NP+")
    k = k:gsub("^NUMPADMINUS$",    "NP-")
    k = k:gsub("^NUMPADMULTIPLY$", "NP*")
    k = k:gsub("^NUMPADDIVIDE$",   "NP/")
    k = k:gsub("^NUMPADDECIMAL$",  "NP.")
    k = k:gsub("^NUMPAD(%d+)$",    "NP%1")

    -- Mouse buttons (BUTTON1 = Left, BUTTON2 = Right, BUTTON3 = Middle, 4+ = side)
    k = k:gsub("^BUTTON(%d+)$",    "M%1")
    k = k:gsub("^MOUSEWHEELUP$",   "MWU")
    k = k:gsub("^MOUSEWHEELDOWN$", "MWD")

    -- Misc verbose keys
    k = k:gsub("^BACKSPACE$", "Bs")
    k = k:gsub("^DELETE$",    "Del")
    k = k:gsub("^INSERT$",    "Ins")
    k = k:gsub("^HOME$",      "Hm")
    k = k:gsub("^PAGEUP$",    "PU")
    k = k:gsub("^PAGEDOWN$",  "PD")
    k = k:gsub("^SPACE$",     "Spc")
    k = k:gsub("^TAB$",       "Tab")

    return (mods .. k):sub(1, MAX_BIND_CHARS)
end

local function updateHotkeys()
    if not displayFrame then return end
    local d = getData()
    for which = 0, 1 do
        local btn = displayFrame["t"..which]
        if btn and btn.hotKey then
            if d.showBindings ~= false then
                local key  = GetBindingKey("CLICK DrievTrinketBtn"..which..":LeftButton")
                btn.hotKey:SetText(formatKeybind(key, d.truncateBindings ~= false))
            else
                btn.hotKey:SetText("")
            end
        end
    end
end

-- ── Icon / cooldown helpers ───────────────────────────────────────────────────

-- [which] = true while a slot is mid-swap: its icon is still the grayed
-- outgoing trinket and its cooldown swirl must be frozen so the incoming
-- trinket's cooldown doesn't paint over the old icon before it updates.
local swapPending = {}

-- Desaturate the worn-icon in place (keeps the old texture visible, just
-- grayed) so there's no black flash while the swap resolves. Cleared by
-- updateWornIcons() once PLAYER_EQUIPMENT_CHANGED lands the new trinket.
local function grayOutDisplaySlot(slot)
    if not displayFrame then return end
    local which = slot - SLOT_TOP
    swapPending[which] = true
    local btn = displayFrame["t"..which]
    if btn and btn.icon then btn.icon:SetDesaturated(true) end
end

-- Cooldown swirls only — safe to run on ACTIONBAR_UPDATE_COOLDOWN. Slots
-- mid-swap are skipped so the incoming cooldown doesn't appear before its icon.
local function updateWornCooldowns()
    if not displayFrame then return end
    if getData().showCooldowns == false then return end
    for which = 0, 1 do
        if not swapPending[which] then
            local btn = displayFrame["t"..which]
            if btn and btn.cooldown then
                local start, duration, enable = GetInventoryItemCooldown("player", SLOT_TOP + which)
                CooldownFrame_Set(btn.cooldown, start, duration, enable)
            end
        end
    end
end

local function updateWornIcons()
    if not displayFrame then return end
    local d = getData()
    for which = 0, 1 do
        local btn = displayFrame["t"..which]
        if btn and btn.icon then
            local slot = SLOT_TOP + which
            local link = GetInventoryItemLink("player", slot)
            local settled = false
            if not link then
                -- Slot genuinely empty: clear it.
                btn.icon:SetTexture("")
                btn.icon:SetDesaturated(false)
                settled = true
            else
                -- GetInventoryItemTexture is available immediately for worn
                -- items (no item-cache dependency), so the display updates the
                -- instant the equipment change fires.
                local tex = GetInventoryItemTexture("player", slot)
                if tex then
                    btn.icon:SetTexture(tex)
                    btn.icon:SetDesaturated(false)
                    settled = true
                end
                -- If tex is nil (data not cached yet) keep the current grayed
                -- icon and leave the swap pending; a later event refreshes it.
            end
            -- Only touch the cooldown once the icon has settled, so the swirl
            -- and the icon always update together (never one before the other).
            if settled then
                swapPending[which] = nil
                if d.showCooldowns ~= false then
                    local start, duration, enable = GetInventoryItemCooldown("player", slot)
                    CooldownFrame_Set(btn.cooldown, start, duration, enable)
                end
            end
        end
    end
    -- Bag-menu rebuild timer starts here, i.e. AFTER the display icon/cooldown
    -- above have already been set — never at click time — so the configured
    -- delay is measured from when the display visually settles.
    scheduleMenuRebuild()
end

-- Equipping an on-use trinket puts a ~30s "swap lockout" cooldown on trinkets.
-- On the bag menu that swirl is unwanted noise for the trinket you're swapping
-- IN (its cooldown belongs on the display slot, and it's leaving the menu
-- anyway) and for uninvolved trinkets — so we filter ≤30s cooldowns there.
-- BUT the trinket you swap OUT should keep its equip cooldown visible in the
-- menu, so the item just swapped out is exempted from the filter by ID.
local SWAP_LOCKOUT_MAX = 30
local swappedOutAt   = {}     -- [itemID] = GetTime() the item was last swapped out
-- True from the moment a swap is initiated until the menu rebuilds. While set,
-- updateMenuCooldowns() is skipped: during the swap the bag slots the menu
-- buttons point at are momentarily stale (the swapped-out trinket lands in the
-- clicked trinket's old slot), so re-reading them would repaint a wrong/30s
-- timer over an existing icon. Menu timers must only change on the rebuild.
local menuSwapFreeze = false

-- Records a trinket (by ID) as freshly swapped out of an equipment slot so its
-- equip cooldown stays visible on the bag menu.
local function markSwappedOut(slot)
    local link = GetInventoryItemLink("player", slot)
    local id   = link and link:match("item:(%d+)")
    if id then swappedOutAt[id] = GetTime() end
end

-- Draws a bag-menu cooldown, filtering the swap-lockout swirl except on the
-- trinket that was itself just swapped out.
local function setMenuCooldown(mb, start, duration, enable)
    if duration and duration > 0 and duration <= SWAP_LOCKOUT_MAX then
        local out = mb._id and swappedOutAt[mb._id]
        if out and (GetTime() - out) <= SWAP_LOCKOUT_MAX + 2 then
            CooldownFrame_Set(mb.cooldown, start, duration, enable)
        else
            CooldownFrame_Set(mb.cooldown, 0, 0, 0)
        end
    else
        CooldownFrame_Set(mb.cooldown, start, duration, enable)
    end
end

local function updateMenuCooldowns()
    if menuSwapFreeze then return end
    if not menuFrame or not menuFrame:IsShown() then return end
    if getData().showCooldowns == false then return end
    for i = 1, numTrinkets do
        local mb = menuFrame["mb"..i]
        if mb then
            local t = baggedTrinkets[i]
            if t then
                local start, duration, enable = C_Container.GetContainerItemCooldown(t.bag, t.slot)
                setMenuCooldown(mb, start, duration, enable)
            end
        end
    end
end

-- ITEM_SPELL_CHARGES may use positional format specifiers (e.g. "%1$d"); strip
-- them down to a plain "%d" so the string works as a Lua find pattern.
local CHARGES_PATTERN = ITEM_SPELL_CHARGES and gsub(ITEM_SPELL_CHARGES, "%%%d%$d", "%%d") or nil

-- Tiny Tooltip: collapse a shown trinket tooltip down to just its name, charge
-- count and cooldown line (mirrors TrinketMenu's "Tiny Tooltips" option).
local function shrinkTooltip()
    if not GameTooltip:IsShown() then return end
    local nameFS = _G["GameTooltipTextLeft1"]
    if not nameFS then return end
    local r, g, b = nameFS:GetTextColor()
    local name    = nameFS:GetText()
    local charge, cooldown
    for i = 2, GameTooltip:NumLines() do
        local line = _G["GameTooltipTextLeft"..i]
        if line and line:IsVisible() then
            local text = line:GetText() or ""
            if COOLDOWN_REMAINING and text:find(COOLDOWN_REMAINING) then
                cooldown = text
            elseif CHARGES_PATTERN and text:find(CHARGES_PATTERN) then
                charge = text
            end
        end
    end
    GameTooltip:ClearLines()
    GameTooltip:AddLine(name, r, g, b)
    if charge   then GameTooltip:AddLine(charge,   1, 1, 1) end
    if cooldown then GameTooltip:AddLine(cooldown, 1, 1, 1) end
    GameTooltip:Show()
end

-- ── Combat queue indicators ──────────────────────────────────────────────────

local IND_SIZE = 15   -- queue-indicator badge size (slightly smaller than the icon)

local function getOrCreateQueueIndicator(which)
    if not displayFrame then return nil end
    local btn = displayFrame["t"..which]
    if not btn then return nil end
    if btn._queueInd then return btn._queueInd end
    local f = CreateFrame("Frame", nil, btn)
    f:SetSize(IND_SIZE, IND_SIZE)
    f:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, -1)
    f:SetFrameStrata("HIGH")
    local ico = f:CreateTexture(nil, "ARTWORK")
    ico:SetAllPoints(f)
    ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.icon = ico
    f:Hide()
    btn._queueInd = f
    return f
end

-- The preemptive/soft-queue badge sits in the opposite (bottom-right) corner so
-- it's distinguishable at a glance from the combat/auto-queue badge (top-left),
-- and carries a gold border to read as "waiting, not yet firing".
local function getOrCreateSoftIndicator(which)
    if not displayFrame then return nil end
    local btn = displayFrame["t"..which]
    if not btn then return nil end
    if btn._softInd then return btn._softInd end
    local f = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    f:SetSize(IND_SIZE, IND_SIZE)
    f:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
    f:SetFrameStrata("HIGH")
    f:SetBackdrop({ edgeFile = WHITE, edgeSize = 1.5 })
    f:SetBackdropBorderColor(1, 0.82, 0, 1)
    local ico = f:CreateTexture(nil, "ARTWORK")
    ico:SetPoint("TOPLEFT", f, "TOPLEFT", 1.5, -1.5)
    ico:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1.5, 1.5)
    ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.icon = ico
    f:Hide()
    btn._softInd = f
    return f
end

-- Same inset used by TrinketMenu: while a swap is actually pending in combat
-- it shows the incoming item's icon; otherwise, if this slot's auto queue is
-- simply enabled, it shows TrinketMenu's own gear icon as an "armed" marker.
-- The bottom-right badge separately shows any preemptive/soft-queued trinket.
local function updateQueueIndicators()
    local d = getData()
    for which = 0, 1 do
        local slot = SLOT_TOP + which
        local f = getOrCreateQueueIndicator(which)
        if f then
            local q = combatQueue[slot]
            if q then
                f.icon:SetTexture(q.texture or "")
                f:Show()
            elseif d.queue[which] and d.queue[which].enabled then
                f.icon:SetTexture("Interface\\AddOns\\Driev's Essentials\\Textures\\Gear")
                f:Show()
            else
                f:Hide()
            end
        end
        local sf = getOrCreateSoftIndicator(which)
        if sf then
            local sq = softQueue[slot]
            if sq then
                sf.icon:SetTexture(sq.texture or "")
                sf:Show()
            else
                sf:Hide()
            end
        end
    end
end

-- If a swap's protected calls get silently blocked (e.g. combat resumes in
-- the split-second around the call — ADDON_ACTION_BLOCKED doesn't raise a
-- catchable Lua error), PLAYER_EQUIPMENT_CHANGED never fires for that slot,
-- swapPending is never cleared by updateWornIcons(), and the icon/cooldown
-- freeze forever with nothing else the addon can key off of. After the timeout
-- this recovers: un-gray the frozen icon and unfreeze the menu so the slot is
-- usable again. Undoing that stuck state is UNCONDITIONAL — it's a pure bug fix
-- with no downside. The user-facing "watchdog" toggle only governs the extra
-- step of auto-RE-QUEUING the failed swap for retry (which can misfire on a
-- slow-but-successful swap), so that part alone is gated behind the setting.
local SWAP_WATCHDOG_TIMEOUT = 1.0

-- [which] = a counter bumped every time a swap is attempted on that slot.
-- Each attempt's watchdog closure snapshots the counter as its "generation";
-- if a newer attempt has since started on the same slot before the watchdog
-- fires, the watchdog is stale and must no-op instead of acting on outdated
-- bag/slot data — otherwise rapid repeat swaps on one slot can leave two
-- watchdogs racing over a single shared swapPending flag, and the stale one
-- can re-queue an old, no-longer-wanted trinket that nothing else can clear.
local swapGen = {}

local function attemptSwap(targetSlot, bag, slot, texture)
    -- Guard against an unrelated item already sitting on the cursor (e.g.
    -- from something outside this addon's control).
    if CursorHasItem() then return end

    local which = targetSlot - SLOT_TOP
    -- Guard against overlapping swap attempts on the SAME slot (e.g. two
    -- fast clicks on different trinkets for the same slot). The pickup pair
    -- below is only treated as an atomic bag<->equipment swap by the client
    -- once the prior attempt's swap has actually been confirmed — and that
    -- confirmation (PLAYER_EQUIPMENT_CHANGED, tracked via swapPending) can
    -- lag well behind the cursor itself going back to empty. Firing another
    -- PickupContainerItem/PickupInventoryItem pair into that still-settling
    -- transaction is what strands the second trinket on the cursor, so key
    -- the guard off swapPending rather than CursorHasItem() alone.
    if swapPending[which] then return end

    grayOutDisplaySlot(targetSlot)
    markSwappedOut(targetSlot)
    menuSwapFreeze = true
    C_Container.PickupContainerItem(bag, slot)
    PickupInventoryItem(targetSlot)

    swapGen[which] = (swapGen[which] or 0) + 1
    local myGen = swapGen[which]
    C_Timer.After(SWAP_WATCHDOG_TIMEOUT, function()
        if swapGen[which] ~= myGen then return end  -- superseded by a newer attempt
        if not swapPending[which] then return end   -- swap resolved normally

        -- Always recover the stuck grayed/frozen state so the slot is usable.
        swapPending[which] = nil
        local btn = displayFrame and displayFrame["t"..which]
        if btn and btn.icon then btn.icon:SetDesaturated(false) end
        menuSwapFreeze = false

        -- Only auto-recover-and-retry the failed swap when the watchdog is on.
        if getData().swapWatchdog ~= false then
            if UnitAffectingCombat("player") then
                -- In combat the swap can't happen now — park it in the combat
                -- queue to flush on combat end.
                combatQueue[targetSlot] = combatQueue[targetSlot]
                    or { bag = bag, slot = slot, texture = texture }
            else
                -- Out of combat the swap should be possible; something transient
                -- (e.g. a brief CC that had already dropped combat) blocked it.
                -- Retry directly rather than parking it in the combat queue,
                -- which would never flush without a combat-end event and would
                -- leave the indicator stuck. attemptSwap's own watchdog keeps
                -- retrying until it lands.
                attemptSwap(targetSlot, bag, slot, texture)
            end
        end
        updateQueueIndicators()
    end)
end

-- Whether slot `which`'s currently-equipped trinket is clear to be swapped
-- AWAY: true once it's been genuinely used since being equipped and its on-use
-- buff (if any) has expired. A trinket with no on-use spell, or an empty slot,
-- is always clear. Also (re)initialises the used-tracker when the equipped item
-- changes, so this is safe to call as the single source of truth every tick.
-- Shared by both the auto-queue (processQueue) and the preemptive/soft-queue
-- (processSoftQueue) so the two obey the exact same "used + expired" rule.
local function isSwapGateOpen(which)
    local slot      = SLOT_TOP + which
    local link      = GetInventoryItemLink("player", slot)
    local currentID = link and link:match("item:(%d+)")

    local tracker = queueUsedTracker[which]
    if tracker.id ~= currentID then
        tracker.id, tracker.used = currentID, false
    end

    if not currentID then return true end
    -- Trinkets with no on-use spell (purely passive) have nothing to "use".
    if GetItemSpell(tonumber(currentID) or currentID) == nil then return true end
    if not tracker.used then return false end          -- never used yet
    if itemBuffActive(currentID) then return false end  -- its on-use buff still running
    return true
end

-- Ported from TrinketMenu's TrinketMenu.ProcessAutoQueue, adapted to this
-- addon's simpler per-slot { sort, stats } data (no Stop-marker/profile
-- system). Two bugs this fixes vs. the original version:
--
--   1. "Doesn't work at all" — the old version tried to equip directly at
--      all times, including in combat. Equipping via PickupContainerItem +
--      PickupInventoryItem is silently blocked mid-combat, leaving an item
--      stuck on the cursor and the whole auto-queue in a confused state from
--      then on. Now it feeds the SAME combatQueue used by manual clicks and
--      lets PLAYER_REGEN_ENABLED flush it once combat ends.
--
--   2. "Spam swaps between trinkets" — the old version scanned the ENTIRE
--      sort list every tick and jumped to the first ready+owned trinket, with
--      nothing stopping it from swapping the current one out before it had
--      even been used. Oscillation is now prevented up front: the currently-
--      equipped trinket can only be swapped OUT once it's been genuinely used
--      (see queueUsedTracker/markTrinketUsed) and, if it grants a buff, that
--      buff has expired — a trinket that was never clicked, or whose buff is
--      still running, is never touched. Once that gate clears, the whole sort
--      list is scanned top-down for the first ready+owned replacement, since
--      whatever gets swapped in becomes the new "current" and is subject to
--      the exact same gate before it can be swapped away again.
local function processQueue(which)
    local d = getData()
    local q = d.queue[which]
    if not q or not q.enabled then return end

    local slot = SLOT_TOP + which
    -- A manual preemptive queue on this slot takes precedence over the
    -- automatic sort-list queue — don't fight the player's explicit choice.
    if softQueue[slot] then return end
    if IsInventoryItemLocked(slot) then return end
    -- Don't fight the player: skip this tick if they're mid-drag, targeting a
    -- ground/unit-targeted spell, or casting/channelling — equipping now
    -- could cancel any of those.
    if CursorHasItem() or SpellIsTargeting() then return end
    if CastingInfo() or ChannelInfo() then return end

    local link      = GetInventoryItemLink("player", slot)
    local currentID = link and link:match("item:(%d+)")

    -- Pinned trinkets are never auto-swapped out.
    if currentID then
        local curStats = q.stats and q.stats[currentID]
        if curStats and curStats.keep then return end
    end
    -- Gate: current trinket must have been used and its on-use buff expired.
    if not isSwapGateOpen(which) then return end

    for i = 1, #q.sort do
        local id = q.sort[i]
        if id and id ~= currentID then
            local stats = q.stats and q.stats[id]
            local numID = tonumber(id) or id
            local _, _, _, _, _, _, _, _, _, tex = GetItemInfo(numID)
            -- Priority-flagged candidates can be pre-staged even while still
            -- on their own cooldown; everything else must be near-ready.
            if tex and (trinketNearReady(id) or (stats and stats.priority)) and GetItemCount(numID) > 0 then
                    for bag = 0, 4 do
                        for s = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
                            local bl = C_Container.GetContainerItemLink(bag, s)
                            local bid = bl and bl:match("item:(%d+)")
                            if bid == id then
                                local info = C_Container.GetContainerItemInfo(bag, s)
                                if info and not info.isLocked then
                                    if UnitAffectingCombat("player") then
                                        combatQueue[slot] = { id = id, bag = bag, slot = s, texture = tex }
                                        updateQueueIndicators()
                                    else
                                        attemptSwap(slot, bag, s, tex)
                                    end
                                    return
                                end
                            end
                        end
                    end
                end
            end
        end
    end

-- Whether the player owns trinket `id` at all — worn in either trinket slot or
-- sitting in bags. GetItemCount alone misses equipped copies.
local function ownsTrinket(id)
    if GetItemCount(tonumber(id) or id) > 0 then return true end
    for which = 0, 1 do
        local link = GetInventoryItemLink("player", SLOT_TOP + which)
        if link and link:match("item:(%d+)") == id then return true end
    end
    return false
end

-- Fires a preemptively (soft) queued trinket. Bags are re-scanned live for the
-- queued item ID (its bag/slot may have shifted since it was queued) rather than
-- trusting the stored position. In combat it hands off to combatQueue (fires on
-- the next combat end via attemptSwap), matching the auto-queue's own behaviour.
local function processSoftQueue(which)
    local slot = SLOT_TOP + which
    local sq = softQueue[slot]
    if not sq then return end

    -- A first-stage swap is still pending for this slot (queued for combat end,
    -- or its swap in flight). The soft-queued trinket is meant to follow THAT
    -- one, so hold until it has actually landed — otherwise the gate below would
    -- evaluate against the wrong (soon-to-be-replaced) equipped trinket and this
    -- could fire early, clobbering the first-stage swap. Central to chain mode.
    if combatQueue[slot] then return end
    if swapPending[which] then return end

    -- Dropped only if the trinket is genuinely gone (neither worn nor in bags).
    -- A soft-queued trinket that's currently EQUIPPED is intentionally kept — it
    -- may be displaced (by a main queue or a manual swap) and then re-equipped.
    if not ownsTrinket(sq.id) then
        softQueue[slot] = nil
        updateQueueIndicators()
        return
    end

    if IsInventoryItemLocked(slot) then return end
    if CursorHasItem() or SpellIsTargeting() then return end
    if CastingInfo() or ChannelInfo() then return end

    -- Normally wait for the equipped trinket to have been used and its buff to
    -- have expired. There's ONE exception — swap early — but only when ALL of:
    --   * it was never used (so we're not throwing away a buff mid-duration),
    --   * it's stuck on a real cooldown (> the ~30s equip lockout) so it can't
    --     be used any time soon, and
    --   * the soft trinket is itself ready to go.
    -- This keeps the "don't stall behind a trinket whose long on-use cooldown
    -- was already ticking when equipped" fix, while NOT firing when the trinket
    -- was just popped (buff still running), nor when the soft trinket shares
    -- that cooldown (e.g. a Diamond Flask-style shared trinket cooldown), where
    -- swapping to it would gain nothing.
    if not isSwapGateOpen(which) then
        local curLink = GetInventoryItemLink("player", slot)
        local curID   = curLink and curLink:match("item:(%d+)")
        local neverUsed  = not queueUsedTracker[which].used
        local mainStuck  = curID and neverUsed and not trinketNearReady(curID)
        if not (mainStuck and trinketNearReady(sq.id)) then return end
    end

    for bag = 0, 4 do
        for s = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local bl  = C_Container.GetContainerItemLink(bag, s)
            local bid = bl and bl:match("item:(%d+)")
            if bid == sq.id then
                local info = C_Container.GetContainerItemInfo(bag, s)
                if info and not info.isLocked then
                    softQueue[slot] = nil
                    if UnitAffectingCombat("player") then
                        combatQueue[slot] = { id = sq.id, bag = bag, slot = s, texture = sq.texture }
                    else
                        attemptSwap(slot, bag, s, sq.texture)
                    end
                    updateQueueIndicators()
                    return
                end
            end
        end
    end

    -- Gate is open (we'd swap now) but the trinket isn't in bags. If it's already
    -- worn here, the soft queue is satisfied/redundant (e.g. the same trinket was
    -- also main-queued) — clear it so its icon doesn't linger.
    local curLink = GetInventoryItemLink("player", slot)
    if curLink and curLink:match("item:(%d+)") == sq.id then
        softQueue[slot] = nil
        updateQueueIndicators()
    end
end

-- Locate a trinket by item ID in the player's bags. Returns bag, slot (or nil).
local function findBagTrinket(id)
    for bag = 0, 4 do
        for s = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local bl = C_Container.GetContainerItemLink(bag, s)
            if bl and bl:match("item:(%d+)") == id then
                return bag, s
            end
        end
    end
end

-- Push a configured boss's chosen trinkets into the queues so the swaps happen
-- the next time combat allows. Two presets per slot: the Main trinket goes to
-- the combat queue (fires first), the Soft trinket to the soft queue (fires
-- after the Main one has been used and its effect expired — same chaining as a
-- manual soft queue). Main needs a bag copy and is skipped if already worn; the
-- Soft trinket may be one you currently have EQUIPPED (a common case: engage
-- with X/Y on, main-queue a/b, soft-queue X/Y back), so it's queued as long as
-- you own it — processSoftQueue re-equips it from bags once it's displaced.
local function queueEncounterTrinkets(enc)
    if not enc then return end
    local changed = false
    for which = 0, 1 do
        local slot      = SLOT_TOP + which
        local link      = GetInventoryItemLink("player", slot)
        local currentID = link and link:match("item:(%d+)")

        -- Explicit if/else (not `a and b or c`) so a nil top field can't fall
        -- through to the bottom field and queue a trinket into the wrong slot.
        local mid, sid
        if which == 0 then mid, sid = enc.mainTop, enc.softTop
                      else mid, sid = enc.mainBottom, enc.softBottom end

        if mid and currentID ~= mid then
            local bag, s = findBagTrinket(mid)
            if bag then
                local _, _, _, _, _, _, _, _, _, tex = GetItemInfo(tonumber(mid) or mid)
                combatQueue[slot] = { id = mid, bag = bag, slot = s, texture = tex }
                changed = true
            end
        end

        -- Skip a Soft trinket identical to this slot's Main (it'd be redundant).
        if sid and sid ~= mid and ownsTrinket(sid) then
            local _, _, _, _, _, _, _, _, _, tex = GetItemInfo(tonumber(sid) or sid)
            softQueue[slot] = { id = sid, texture = tex }
            changed = true
        end
    end
    if changed then updateQueueIndicators() end
end

-- Specific Auto Queue must only fire once you're BOTH inside a configured
-- encounter AND actually in combat — never on ENCOUNTER_START alone. Some
-- bosses don't put the raid in combat immediately, so queuing at encounter
-- start could swap your equipped trinket out during that pre-combat window.
-- Gating on real combat means the swap is only lined up once you're fighting.
-- Called from both ENCOUNTER_START and PLAYER_REGEN_DISABLED (whichever makes
-- both conditions true second); the per-encounter latch keeps it to one queue.
local currentEncounterID = nil
local encounterQueued    = false

-- Encounter ids belonging to the "debug" raid (The Stockades). These only
-- auto-queue when the Debug module is explicitly enabled, so they can't fire
-- by accident just from running the dungeon.
local debugEncounterIDs = {}
for _, raid in ipairs(addon.RAIDS or {}) do
    if raid.key == "debug" then
        for _, boss in ipairs(raid.bosses) do
            if boss.id then debugEncounterIDs[boss.id] = true end
        end
    end
end

-- Safeguard delay: optionally require encounter-start + in-combat to hold
-- simultaneously for a configured duration before queuing, rather than firing
-- the instant both first line up. encGen is bumped on every ENCOUNTER_START/END
-- so a delayed attempt started for an earlier encounter can recognise it's been
-- superseded (encounter ended/changed) and quietly no-op instead of firing late.
local encGen = 0

local function maybeQueueEncounter()
    if encounterQueued then return end
    if not currentEncounterID then return end
    if not UnitAffectingCombat("player") then return end
    if debugEncounterIDs[currentEncounterID] and not getData().debugEncounters then return end
    local enc = getData().encounters[currentEncounterID]
    if not (enc and enc.enabled) then return end

    local d = getData()
    if d.encQueueDelayEnabled then
        local myGen = encGen
        local myEncounterID = currentEncounterID
        C_Timer.After(math.max(0, d.encQueueDelaySeconds or 5.0), function()
            -- Re-verify both conditions still hold at fire time (not just when
            -- scheduled) — if the encounter ended/changed or combat dropped in
            -- the meantime, this attempt is stale and must not fire late.
            if encGen ~= myGen then return end
            if encounterQueued then return end
            if currentEncounterID ~= myEncounterID then return end
            if not UnitAffectingCombat("player") then return end
            queueEncounterTrinkets(enc)
            encounterQueued = true
        end)
        return
    end

    queueEncounterTrinkets(enc)
    encounterQueued = true
end

-- ── Menu positioning ─────────────────────────────────────────────────────────

local DOCK_GAP = 2   -- gap between the display frame and the docked bag menu
local DEFAULT_CORNER = "below-left"

-- Anchors `frame` (the bag menu, or the small drag-preview indicator) to a
-- side/corner of the display using TWO independent single-axis anchor points
-- that both target the display FRAME's own outer edges — together they pin
-- the exact same point a single corner-to-corner SetPoint would, so the bag
-- menu's nearest corner touches the display's nearest corner exactly, the
-- same as any two frames snapped edge-to-edge. Since both axes reference the
-- display frame, growing displayEdgePad (which grows the frame outward from
-- its centre) shifts BOTH axes together — the two frames' corners stay
-- touching, they just spread apart as a unit, instead of the icons drifting
-- out of alignment with the frame's own edge.
local function applyDockAnchor(frame, side, align, gap)
    if not displayFrame then return end
    frame:ClearAllPoints()
    if side == "below" then
        frame:SetPoint("TOP", displayFrame, "BOTTOM", 0, -gap)
        if align == "right" then
            frame:SetPoint("RIGHT", displayFrame, "RIGHT", 0, 0)
        else
            frame:SetPoint("LEFT", displayFrame, "LEFT", 0, 0)
        end
    elseif side == "above" then
        frame:SetPoint("BOTTOM", displayFrame, "TOP", 0, gap)
        if align == "right" then
            frame:SetPoint("RIGHT", displayFrame, "RIGHT", 0, 0)
        else
            frame:SetPoint("LEFT", displayFrame, "LEFT", 0, 0)
        end
    elseif side == "left" then
        frame:SetPoint("RIGHT", displayFrame, "LEFT", -gap, 0)
        if align == "bottom" then
            frame:SetPoint("BOTTOM", displayFrame, "BOTTOM", 0, 0)
        else
            frame:SetPoint("TOP", displayFrame, "TOP", 0, 0)
        end
    else -- right
        frame:SetPoint("LEFT", displayFrame, "RIGHT", gap, 0)
        if align == "bottom" then
            frame:SetPoint("BOTTOM", displayFrame, "BOTTOM", 0, 0)
        else
            frame:SetPoint("TOP", displayFrame, "TOP", 0, 0)
        end
    end
end

-- Docks the bag menu against the display, using whichever corner pair was
-- last picked (by dragging, see computeDockCorner below). This is entirely
-- independent of the menuAlign SETTING (the Alignment dropdown) — that only
-- controls which end of the row/column trinket #1 packs to in buildMenu(),
-- not which physical corner the frame is anchored at. Conflating the two
-- used to mean the anchor always snapped to whatever menuAlign happened to
-- be, ignoring where the menu was actually dropped.
local function positionDockedMenu()
    if not displayFrame or not menuFrame then return end
    local key = getData().menuDockCorner or DEFAULT_CORNER
    local side, align = key:match("^(%a+)%-(%a+)$")
    if not side then side, align = "below", "left" end
    applyDockAnchor(menuFrame, side, align, DOCK_GAP)
end

-- Determines which side/corner of the display the bag menu is currently
-- closest to touching. Uses the CURSOR's position (where you're actually
-- hovering/dragging the menu from), not the menu frame's geometric centre —
-- if you grab the menu near one edge and drag that edge close to the
-- display, the menu's centroid can still sit far off to the other side
-- (especially since the menu is often much wider than the tiny 2-icon
-- display), picking the opposite corner from the one you're pointing at.
-- The cursor position is compared against the DISPLAY's centre, normalized
-- by the display's own half-size, so the menu's own bulk can't skew which
-- side/corner is picked either.
local function computeDockCorner()
    if not displayFrame then return DEFAULT_CORNER end
    local dcx, dcy = displayFrame:GetCenter()
    if not dcx then return DEFAULT_CORNER end
    local ds = displayFrame:GetEffectiveScale()
    dcx, dcy = dcx * ds, dcy * ds

    local cx, cy = GetCursorPosition()   -- already raw screen pixels, same units as dcx/dcy above

    local dw = displayFrame:GetWidth()  * ds
    local dh = displayFrame:GetHeight() * ds
    local dx, dy = cx - dcx, cy - dcy
    local nx = dx / math.max(dw / 2, 1)
    local ny = dy / math.max(dh / 2, 1)

    local side, align
    if math.abs(nx) > math.abs(ny) then
        side  = nx > 0 and "right" or "left"
        align = dy >= 0 and "top" or "bottom"
    else
        side  = dy > 0 and "above" or "below"   -- screen y grows upward
        align = dx >= 0 and "right" or "left"
    end
    return side .. "-" .. align
end

-- Small bright square shown on the display, live while drag-docking, marking
-- exactly which corner the bag menu will snap to on release.
local dockIndicator
local function showDockIndicator(key)
    if not displayFrame then return end
    local side, align = key:match("^(%a+)%-(%a+)$")
    if not side then side, align = "below", "left" end
    if not dockIndicator then
        local t = displayFrame:CreateTexture(nil, "OVERLAY")
        t:SetTexture(WHITE)
        t:SetVertexColor(0.984, 0.173, 0.212, 0.9)
        t:SetSize(10, 10)
        dockIndicator = t
    end
    applyDockAnchor(dockIndicator, side, align, 0)
    dockIndicator:Show()
end
local function hideDockIndicator()
    if dockIndicator then dockIndicator:Hide() end
end

positionMenu = function()
    if not menuFrame then return end
    local d = getData()
    if d.menuDocked ~= false then
        positionDockedMenu()
    elseif d.menuPx and d.menuPy then
        menuFrame:ClearAllPoints()
        if d.menuAlign == "right" then
            -- Right edge fixed → anchor TOPRIGHT so add/remove grows leftward.
            -- Prefer the saved right edge; if it's missing (e.g. alignment was
            -- switched without re-dragging) derive it from the last left edge
            -- plus the current width.
            local right = d.menuPxRight or (d.menuPx + menuFrame:GetWidth())
            menuFrame:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", right, d.menuPy)
        else
            menuFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", d.menuPx, d.menuPy)
        end
    else
        positionDockedMenu()
    end
end

-- Lays out the two worn-trinket buttons using the configurable edge padding and
-- gap, resizes the display frame to match, and re-docks the menu (its position
-- depends on the display size / padding).
local function layoutDisplay()
    if not displayFrame then return end
    local d   = getData()
    local gap = d.displayButtonGap or BTN_GAP
    local pad = d.displayEdgePad   or BTN_PAD
    displayFrame:SetSize(BTN_SIZE * 2 + gap + pad * 2, BTN_SIZE + pad * 2)
    for which = 0, 1 do
        local btn = displayFrame["t"..which]
        if btn then
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", displayFrame, "TOPLEFT",
                pad + which * (BTN_SIZE + gap), -pad)
        end
    end
    if menuFrame and menuFrame:IsShown() and getData().menuDocked ~= false then
        positionDockedMenu()
    end
end

-- ── Bag menu ─────────────────────────────────────────────────────────────────

local menuCloseTimer

cancelMenuClose = function()
    if menuCloseTimer then menuCloseTimer:Cancel(); menuCloseTimer = nil end
end

scheduleMenuClose = function()
    -- Always schedule (even for alwaysShow) so the region-exit check below runs
    -- and clears mouseInRegion; only the actual Hide is skipped for alwaysShow.
    cancelMenuClose()
    menuCloseTimer = C_Timer.NewTimer(0.3, function()
        menuCloseTimer = nil
        if not displayFrame or not menuFrame then return end
        if MouseIsOver(displayFrame) or MouseIsOver(menuFrame) then return end
        -- Mouse has truly left the display + bag menu region.
        mouseInRegion   = false
        pendingMenuShow = false
        if not getData().alwaysShow then menuFrame:Hide() end
    end)
end

-- Rebuilds the bag menu getData().swapDelay seconds after the worn icon has
-- ALREADY updated (this is only ever called from inside updateWornIcons(),
-- right after the new texture lands) — so the delay is measured from the
-- point the display visually settles, never from click time. Debounced so
-- PLAYER_EQUIPMENT_CHANGED and UNIT_INVENTORY_CHANGED firing for the same
-- swap don't queue up two rebuilds.
--
-- The menu's shown-state is checked only when the timer FIRES, never here:
-- PLAYER_EQUIPMENT_CHANGED arrives a frame or two after the click, and gating
-- the scheduling on IsShown at that moment could drop the rebuild entirely.
local menuRebuildTimer
scheduleMenuRebuild = function()
    if menuRebuildTimer then menuRebuildTimer:Cancel() end
    local delay = getData().swapDelay or 1.0
    menuRebuildTimer = C_Timer.NewTimer(delay, function()
        menuRebuildTimer = nil
        if menuFrame and menuFrame:IsShown() then buildMenu() end
    end)
end

local function applyScale()
    if not menuFrame then return end
    menuFrame:SetScale(getData().menuScale or 1.0)
end

local function applyDisplayScale()
    if not displayFrame then return end
    displayFrame:SetScale(getData().displayScale or 1.0)
end

-- Switches whether the worn-trinket buttons fire their bound "use item"
-- keybind on key-down (default, matches standard action-bar feel) or
-- key-up. Safe to call any time; RegisterForClicks isn't combat-protected.
local function applyClickTrigger()
    if not displayFrame then return end
    local mode = getData().triggerOnKeyUp and "LeftButtonUp" or "LeftButtonDown"
    for which = 0, 1 do
        local btn = displayFrame["t"..which]
        if btn then btn:RegisterForClicks(mode) end
    end
end

-- Blocks a trinket's keybind (and mouse click) from using the item while a
-- given modifier is held, via WoW's own secure modified-click attribute
-- system — the same mechanism TrinketMenu itself uses (its
-- alt-slot*/shift-slot* = ATTRIBUTE_NOOP calls). Setting <mod>-slot* to
-- ATTRIBUTE_NOOP tells the secure click header to do nothing whenever that
-- modifier is held, entirely declaratively — resolved C-side with no Lua
-- involved in the decision, so it's combat-safe and doesn't depend on script
-- timing the way trying to intercept the click in PreClick would.
local function applyModifierBlockers()
    if not displayFrame then return end
    local d = getData()
    for which = 0, 1 do
        local btn = displayFrame["t"..which]
        if btn then
            local slot = SLOT_TOP + which
            btn:SetAttribute("ctrl-slot*",  d.blockModCtrl  and ATTRIBUTE_NOOP or slot)
            btn:SetAttribute("alt-slot*",   d.blockModAlt   and ATTRIBUTE_NOOP or slot)
            btn:SetAttribute("shift-slot*", d.blockModShift and ATTRIBUTE_NOOP or slot)
        end
    end
end

buildMenu = function()
    if not menuFrame then return end
    menuSwapFreeze = false   -- rebuild = swap resolved; menu cooldowns may sync again
    scanBags()
    local d         = getData()
    local perLine   = math.max(1, math.min(10, d.menuPerLine or d.menuColumns or 4))
    local horiz     = (d.menuOrientation or "horizontal") ~= "vertical"
    local edgePad   = d.menuEdgePad   or MENU_PAD
    local buttonGap = d.menuButtonGap or MENU_PAD
    -- Right alignment: anchor from the frame's TOPRIGHT and grow columns
    -- leftward, so column 0 (the 1st trinket in menu order) sits at the right.
    local rightAlign = (d.menuAlign == "right")

    -- Hidden trinkets (Alt+click a bag-menu icon to toggle) are sorted to the
    -- end and normally excluded. They're revealed — shown desaturated, always
    -- after the visible ones — when showHidden is latched on by Alt-hovering
    -- the display (see the display OnEnter handlers).
    local displayCount = numTrinkets
    if not showHidden then
        displayCount = 0
        for i = 1, numTrinkets do
            if baggedTrinkets[i].hidden then break end   -- hidden are contiguous at the end
            displayCount = displayCount + 1
        end
    end

    for i = 1, MAX_MENU do
        local mb = menuFrame["mb"..i]
        if mb then
            if i <= displayCount then
                local col, row
                if horiz then
                    col = (i - 1) % perLine
                    row = math.floor((i - 1) / perLine)
                else
                    row = (i - 1) % perLine
                    col = math.floor((i - 1) / perLine)
                end
                mb:ClearAllPoints()
                if rightAlign then
                    mb:SetPoint("TOPRIGHT", menuFrame, "TOPRIGHT",
                        -(edgePad + col * (MENU_SIZE + buttonGap)),
                        -(edgePad + row * (MENU_SIZE + buttonGap)))
                else
                    mb:SetPoint("TOPLEFT", menuFrame, "TOPLEFT",
                        edgePad + col * (MENU_SIZE + buttonGap),
                        -(edgePad + row * (MENU_SIZE + buttonGap)))
                end
                local t = baggedTrinkets[i]
                mb.icon:SetTexture(t.texture or "")
                mb.icon:SetDesaturated(t.hidden)
                mb._bag  = t.bag
                mb._slot = t.slot
                mb._name = t.name
                mb._id   = t.id
                local start, duration, enable = C_Container.GetContainerItemCooldown(t.bag, t.slot)
                setMenuCooldown(mb, start, duration, enable)
                mb:Show()
            else
                mb:Hide()
            end
        end
    end

    local numCols, numRows
    if horiz then
        numCols = math.max(1, math.min(displayCount, perLine))
        numRows = (displayCount > 0) and math.ceil(displayCount / perLine) or 1
    else
        numRows = math.max(1, math.min(displayCount, perLine))
        numCols = (displayCount > 0) and math.ceil(displayCount / perLine) or 1
    end
    local w = numCols * MENU_SIZE + math.max(0, numCols-1) * buttonGap + edgePad * 2
    local h = numRows * MENU_SIZE + math.max(0, numRows-1) * buttonGap + edgePad * 2
    menuFrame:SetSize(w, h)
    applyScale()
    -- Nothing to show (e.g. every bag trinket is hidden and Alt isn't held) —
    -- don't leave an empty box floating. Alt-hover re-shows via showMenu().
    if displayCount == 0 then menuFrame:Hide() end
end

showMenu = function()
    if not displayFrame or not displayFrame:IsShown() then return end
    local m = getOrCreateMenu()
    buildMenu()
    if numTrinkets == 0 then
        pendingMenuShow = true   -- retry once item data has loaded
        return
    end
    pendingMenuShow = false
    positionMenu()
    m:Show()
end

-- Explicit region maps handed to Masque's Group:AddButton(button, ButtonData).
-- Masque's auto-detect (no ButtonData) only reliably finds a plain Button's
-- Icon/Cooldown by conventional field name — Normal/Pushed/Highlight/Checked
-- need to be listed by hand, otherwise Masque skins the icon/cooldown but
-- leaves those other layers (including the checked flash) drawing with their
-- original un-recolored textures instead of the active Masque skin's colours.
local function menuButtonData(mb)
    return {
        Icon      = mb.icon,
        Cooldown  = mb.cooldown,
        Normal    = mb:GetNormalTexture(),
        Pushed    = mb:GetPushedTexture(),
        Highlight = mb:GetHighlightTexture(),
    }
end

local function displayButtonData(btn)
    return {
        Icon      = btn.icon,
        Cooldown  = btn.cooldown,
        Normal    = btn:GetNormalTexture(),
        Pushed    = btn:GetPushedTexture(),
        Highlight = btn:GetHighlightTexture(),
        Checked   = btn:GetCheckedTexture(),
    }
end

getOrCreateMenu = function()
    if menuFrame then return menuFrame end

    local f = CreateFrame("Frame", "DrievTrinketMenu", UIParent, "BackdropTemplate")
    f:SetBackdrop({ bgFile=WHITE, edgeFile=WHITE, edgeSize=2 })
    f:SetBackdropColor(0, 0, 0, 0)
    f:SetBackdropBorderColor(0, 0, 0, 0)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetScript("OnEnter", cancelMenuClose)
    f:SetScript("OnLeave", scheduleMenuClose)
    f:Hide()

    for i = 1, MAX_MENU do
        -- Inherits ActionButtonTemplate (like TrinketMenu's own menu buttons)
        -- for Icon/Cooldown; styleSlotButton bakes the Blizzard Classic
        -- Normal/Pushed/Highlight look on top. No Checked flash here — these
        -- aren't the worn buttons (see styleSlotButton's note).
        local mb = CreateFrame("CheckButton", nil, f, "ActionButtonTemplate")
        mb:SetSize(MENU_SIZE, MENU_SIZE)
        mb:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        mb:Hide()

        styleSlotButton(mb, MENU_SIZE)

        local icon = mb.icon
        icon:SetAllPoints(mb)
        mb.Icon = icon   -- Masque

        local cd = mb.cooldown
        cd:SetDrawBling(false)
        cd:SetSwipeColor(0, 0, 0, 0.8)   -- matches TrinketMenu's cooldown swipe
        mb.Cooldown = cd    -- Masque

        mb:SetScript("OnEnter", function(self)
            cancelMenuClose()
            if getData().showTooltips ~= false then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetBagItem(self._bag, self._slot)
                GameTooltip:Show()
                if getData().tinyTooltips then shrinkTooltip() end
            end
        end)
        mb:SetScript("OnLeave", function()
            GameTooltip:Hide()
            scheduleMenuClose()
        end)
        mb:SetScript("OnClick", function(self, btn)
            -- Being a CheckButton (via ActionButtonTemplate), clicking it can
            -- leave its native checked-glow stuck on — and since these 30
            -- buttons are pooled/reused across buildMenu() rebuilds, a stuck
            -- glow then shows up on whatever item next occupies that slot
            -- position. Clear it defensively on every click, matching
            -- TrinketMenu's own MenuTrinket_OnClick fix for the same issue.
            self:SetChecked(false)

            -- Alt+click toggles whether this trinket is hidden from the bag menu.
            if IsAltKeyDown() and self._id then
                local hidden = getData().hidden
                hidden[self._id] = (not hidden[self._id]) or nil
                buildMenu()   -- reflect the toggle using the current reveal latch
                return
            end
            local rightIsTop = getData().reverseClickSlots
            local targetSlot
            if btn == "RightButton" then
                targetSlot = rightIsTop and SLOT_TOP or SLOT_BOT
            else
                targetSlot = rightIsTop and SLOT_BOT or SLOT_TOP
            end

            -- Preemptive (soft) queue: hold the configured modifier and click to
            -- line this trinket up WITHOUT swapping now — it fires later, once the
            -- currently-equipped trinket has been used and its buff has expired
            -- (see processSoftQueue). Clicking the same trinket again toggles it
            -- off; clicking a different one replaces the pending entry.
            local mod = getData().softQueueMod or "shift"
            local modHeld = (mod == "shift" and IsShiftKeyDown())
                         or (mod == "ctrl"  and IsControlKeyDown())
            if modHeld and self._id and self._bag and self._slot then
                if softQueue[targetSlot] and softQueue[targetSlot].id == self._id then
                    softQueue[targetSlot] = nil
                else
                    softQueue[targetSlot] = {
                        id      = self._id,
                        bag     = self._bag,
                        slot    = self._slot,
                        texture = self.icon:GetTexture(),
                    }
                end
                updateQueueIndicators()
                return
            end

            if UnitAffectingCombat("player") then
                -- A plain click manages the MAIN (combat) queue only: queue this
                -- trinket, or UN-queue it if it's the one already queued for this
                -- slot (click again to toggle off). The soft queue is left
                -- untouched — it's managed solely by modifier+click.
                if combatQueue[targetSlot] and combatQueue[targetSlot].id == self._id then
                    combatQueue[targetSlot] = nil
                else
                    combatQueue[targetSlot] = {
                        id      = self._id,
                        bag     = self._bag,
                        slot    = self._slot,
                        texture = self.icon:GetTexture(),
                    }
                end
                updateQueueIndicators()
                return
            end
            if self._bag and self._slot then
                -- The bag-menu rebuild is scheduled from updateWornIcons() once
                -- PLAYER_EQUIPMENT_CHANGED actually lands the new trinket, not
                -- from here — starting it at click time raced against network
                -- latency and could rebuild the menu before the icon updated.
                attemptSwap(targetSlot, self._bag, self._slot, self.icon:GetTexture())
                updateQueueIndicators()
            end
        end)

        elvuiSkinButton(mb)
        f["mb"..i] = mb
    end

    menuFrame = f

    -- Register with Masque if already initialised (e.g. when menu is first opened
    -- after PLAYER_ENTERING_WORLD).
    if addon.Trinkets and addon.Trinkets._masqueGroup then
        for i = 1, MAX_MENU do
            addon.Trinkets._masqueGroup:AddButton(f["mb"..i], menuButtonData(f["mb"..i]))
        end
    end

    return f
end

-- ── Display frame ─────────────────────────────────────────────────────────────

-- Swaps the two worn trinkets between the top and bottom slots (13 <-> 14),
-- triggered by holding the configured swap modifier and clicking a worn trinket
-- (see the PreClick in getOrCreateDisplay). Both slots must be filled. Uses the
-- standard pick-up/place cursor dance: pick up top (13 empties), pick up bottom
-- (drops top into 14, picks up bottom), drop bottom into 13. The cursor is
-- cleared afterwards so a partial failure can't leave a trinket stuck on it.
local function swapWornTrinkets()
    -- PickupInventoryItem is protected in combat and errors if called from this
    -- non-secure handler while locked down, so this manual swap is out-of-combat
    -- only. (In-combat swapping goes through the secure auto-queue instead.)
    if InCombatLockdown() then return end
    if not (GetInventoryItemLink("player", SLOT_TOP) and GetInventoryItemLink("player", SLOT_BOT)) then
        return
    end
    ClearCursor()
    PickupInventoryItem(SLOT_TOP)
    PickupInventoryItem(SLOT_BOT)
    PickupInventoryItem(SLOT_TOP)
    ClearCursor()
end

-- Suppress the secure "use item" action for the configured soft-queue and
-- slot-swap modifiers on the two worn buttons, so <modifier>+click does the
-- special action (handled in the PreClick below) instead of firing the
-- trinket's on-use. A modifier set to "none" is left untouched, so holding it
-- just fires the trinket normally. Secure SetAttribute is combat-protected, so
-- this only applies out of combat; a change made during combat lands once
-- combat ends.
local function applySoftQueueMod()
    if not displayFrame or InCombatLockdown() then return end
    local d       = getData()
    local softMod = d.softQueueMod or "shift"
    local swapMod = d.swapMod or "ctrl"
    for which = 0, 1 do
        local btn = displayFrame["t"..which]
        if btn then
            for _, m in ipairs({ "shift", "ctrl", "alt" }) do
                if m == softMod or m == swapMod then
                    btn:SetAttribute(m .. "-type1", "macro")
                    btn:SetAttribute(m .. "-macrotext1", "")
                else
                    btn:SetAttribute(m .. "-type1", nil)
                    btn:SetAttribute(m .. "-macrotext1", nil)
                end
            end
        end
    end
end

local function getOrCreateDisplay()
    if displayFrame then return displayFrame end
    -- The worn buttons use SecureActionButtonTemplate; creating a secure frame
    -- (and the SetAttribute calls below) is blocked in combat. Bail so a login
    -- or /reload mid-fight doesn't error — PLAYER_REGEN_ENABLED soft-loads it
    -- once combat ends. Callers must tolerate a nil return.
    if InCombatLockdown() then return nil end

    local f = CreateFrame("Frame", "DrievTrinketDisplay", UIParent, "BackdropTemplate")
    -- BTN_PAD pixels of invisible draggable area around the two buttons
    f:SetSize(BTN_SIZE * 2 + BTN_GAP + BTN_PAD * 2, BTN_SIZE + BTN_PAD * 2)
    f:SetPoint("CENTER", UIParent, "CENTER", 200, 0)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("MEDIUM")
    f:SetBackdrop({ bgFile=WHITE, edgeFile=WHITE, edgeSize=2 })
    f:SetBackdropColor(0, 0, 0, 0)
    f:SetBackdropBorderColor(0, 0, 0, 0)
    f:EnableMouse(true)
    -- Fallback: the two buttons already open the menu on their own OnEnter,
    -- but any hover over the display frame itself (its padding margin, or a
    -- gap between the buttons) should reliably open the menu too — not just
    -- cancel the pending close. Also force a fresh buildMenu() unconditionally
    -- (menuFrame may not exist yet, or may be showing stale/empty content from
    -- before item data was cached at login) so hovering always self-heals the
    -- bag menu instead of possibly leaving it stuck showing nothing.
    f:SetScript("OnEnter", function()
        cancelMenuClose()
        getOrCreateMenu()
        -- Latch hidden-trinket reveal from the Alt state, but only on a fresh
        -- entry into the region — not on internal button↔frame moves, so it
        -- survives releasing Alt and heading to the menu.
        if not mouseInRegion then showHidden = IsAltKeyDown() end
        mouseInRegion = true
        -- Unconditional, regardless of alwaysShow: if the menu somehow ended
        -- up empty/hidden at login (e.g. bag item data wasn't cached yet, so
        -- the initial buildMenu() found 0 trinkets and never called Show()),
        -- hovering must still be able to self-heal it — not silently rebuild
        -- without ever displaying anything.
        showMenu()
    end)
    f:SetScript("OnLeave", scheduleMenuClose)

    for which = 0, 1 do
        local slot = SLOT_TOP + which
        -- Inherits ActionButtonTemplate (like TrinketMenu's own trinket
        -- buttons) for its Icon/Cooldown regions; styleSlotButton then bakes
        -- the Blizzard Classic Normal/Pushed/Highlight look on top, and the
        -- Checked flash is set just below. SecureActionButtonTemplate is mixed
        -- in so the worn buttons can use/equip items via a secure click.
        local btn = CreateFrame("CheckButton", "DrievTrinketBtn"..which, f,
            "ActionButtonTemplate,SecureActionButtonTemplate")
        btn:SetSize(BTN_SIZE, BTN_SIZE)
        btn:SetPoint("TOPLEFT", f, "TOPLEFT",
            BTN_PAD + which * (BTN_SIZE + BTN_GAP), -BTN_PAD)
        btn:SetAttribute("type", "item")
        btn:SetAttribute("slot", slot)
        btn:RegisterForClicks(getData().triggerOnKeyUp and "LeftButtonUp" or "LeftButtonDown")

        styleSlotButton(btn, BTN_SIZE)

        local icon = btn.icon
        icon:SetAllPoints(btn)
        btn.Icon = icon     -- Masque

        local cd = btn.cooldown
        cd:SetDrawBling(false)
        cd:SetSwipeColor(0, 0, 0, 0.8)   -- matches TrinketMenu's cooldown swipe
        btn.Cooldown = cd   -- Masque

        -- Click-feedback flash: the Blizzard Classic checked texture, full
        -- button size, additive. Driven manually via SetChecked in PostClick
        -- (see below); the SetChecked(false) there before re-showing avoids the
        -- native checked-glow sticking after a secure item click.
        btn:SetCheckedTexture("Interface\\Buttons\\CheckButtonHilight")
        local ct = btn:GetCheckedTexture()
        if ct then
            ct:SetBlendMode("ADD")
            ct:ClearAllPoints()
            ct:SetAllPoints(btn)
        end
        btn.Checked = ct   -- Masque

        btn:SetScript("PostClick", function(self)
            self:SetChecked(false)
            self:SetChecked(true)
            -- Cancel any pending hide from a previous click and restart the
            -- 0.5s countdown, so spamming the button keeps the checked flash
            -- solidly visible instead of flickering off between clicks —
            -- it only fades 0.5s after the LAST click.
            if self.checkedTimer then self.checkedTimer:Cancel() end
            self.checkedTimer = C_Timer.NewTimer(0.5, function()
                self.checkedTimer = nil
                self:SetChecked(false)
            end)
        end)

        -- <modifier>+click does a special action instead of firing the trinket
        -- (the secure use for these modifiers is suppressed by applySoftQueueMod):
        --   • swap modifier   → swap the top/bottom slot trinkets
        --   • soft-queue mod  → soft-queue the worn trinket in this slot (toggle)
        -- A modifier set to "none" matches nothing here, so it just fires the
        -- trinket. The swap modifier is checked first so it wins if somehow both
        -- happen to be held.
        btn:SetScript("PreClick", function()
            local d = getData()

            local swapMod  = d.swapMod or "ctrl"
            local swapHeld = (swapMod == "shift" and IsShiftKeyDown())
                          or (swapMod == "ctrl"  and IsControlKeyDown())
            if swapHeld then
                swapWornTrinkets()
                return
            end

            local mod  = d.softQueueMod or "shift"
            local held = (mod == "shift" and IsShiftKeyDown())
                      or (mod == "ctrl"  and IsControlKeyDown())
            if not held then return end
            local s    = SLOT_TOP + which
            local link = GetInventoryItemLink("player", s)
            local id   = link and link:match("item:(%d+)")
            if not id then return end
            if softQueue[s] and softQueue[s].id == id then
                softQueue[s] = nil
            else
                softQueue[s] = { id = id, texture = GetInventoryItemTexture("player", s) }
            end
            updateQueueIndicators()
        end)

        -- Keybind text anchored to top-right of the icon
        local hk = btn:CreateFontString(nil, "OVERLAY")
        hk:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
        hk:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -2, -2)
        hk:SetJustifyH("RIGHT")
        hk:SetTextColor(1, 1, 1, 1)
        btn.hotKey = hk

        btn:SetScript("OnEnter", function()
            cancelMenuClose()
            -- Latch only on a fresh entry into the region (see the frame OnEnter).
            if not mouseInRegion then showHidden = IsAltKeyDown() end
            mouseInRegion = true
            showMenu()
        end)
        btn:SetScript("OnLeave", scheduleMenuClose)

        elvuiSkinButton(btn)
        f["t"..which] = btn
    end

    f:Hide()
    displayFrame = f
    applyModifierBlockers()
    applySoftQueueMod()
    layoutDisplay()   -- apply configured edge padding / button gap
    return f
end

-- ── Masque integration ────────────────────────────────────────────────────────

-- Masque is a shared LibStub library: ANY addon that happens to embed it
-- (not just the standalone "Masque" addon) makes LibStub("Masque") available
-- and keeps applying whatever skin was last chosen for a given group name.
-- Registration is unconditional: the buttons already carry the baked-in
-- Blizzard Classic look (see styleSlotButton), so there's no in-addon toggle
-- to gate this — a user who doesn't want Masque skinning just disables our
-- group in Masque's own options, which reverts to that baked look.
local function initMasque()
    local MSQ = LibStub and LibStub("Masque", true)
    if not MSQ then return end
    if addon.Trinkets and addon.Trinkets._masqueGroup then return end
    local group = MSQ:Group("Driev's Essentials", "Trinkets")
    -- Register display buttons (display frame created before initMasque is called)
    if displayFrame then
        for which = 0, 1 do
            local btn = displayFrame["t"..which]
            group:AddButton(btn, displayButtonData(btn))
        end
    end
    -- Force-create menu frame and register its buttons
    local m = getOrCreateMenu()
    for i = 1, MAX_MENU do
        local mb = m["mb"..i]
        group:AddButton(mb, menuButtonData(mb))
    end
    addon.Trinkets._masqueGroup = group
end

-- ── Move-mode interface ───────────────────────────────────────────────────────

local function applyPosition()
    -- Must use getOrCreateDisplay(), not the bare displayFrame upvalue: on the
    -- first PLAYER_ENTERING_WORLD the frame hasn't been built yet, so reading
    -- displayFrame directly would be nil and the saved position lost.
    local f = getOrCreateDisplay()
    if not f then return end
    local d = getData()
    if d.px and d.py then
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", d.px, d.py)
    end
end

local function applyVisibility()
    local f = getOrCreateDisplay()
    if not f then return end   -- deferred: display can't be built in combat yet
    local d = getData()
    if not d.enabled then
        f:Hide()
        if menuFrame then menuFrame:Hide() end
        return
    end
    updateWornIcons()
    updateHotkeys()
    layoutDisplay()
    updateQueueIndicators()
    -- Scale before position so the GetCenter()/SetPoint() round-trip is
    -- evaluated at the same scale it was saved at.
    applyDisplayScale()
    applyPosition()
    f:Show()
    if d.alwaysShow then
        local m = getOrCreateMenu()
        buildMenu()
        positionMenu()
        if numTrinkets > 0 then m:Show() end
    else
        if menuFrame and menuFrame:IsShown() then
            if not MouseIsOver(f) and not MouseIsOver(menuFrame) then
                menuFrame:Hide()
            end
        end
    end
end

-- getPosition/setPosition for the BAG MENU itself, so it can have its own
-- click-to-open precise X/Y editor (see enterMoveMode below). Uses TOPLEFT,
-- matching the menuPx/menuPy convention already used for undocked positioning.
local function getMenuPosition()
    if not menuFrame then return 0, 0 end
    local x, y = menuFrame:GetLeft(), menuFrame:GetTop()
    return x or 0, y or 0
end

local function setMenuPosition(x, y)
    if not menuFrame then return end
    -- A docked menu's spot is derived from the display, not a free x/y —
    -- committing an explicit coordinate here means the user wants it placed
    -- exactly there, so force-undock it.
    local d = getData()
    d.menuDocked = false
    menuFrame:ClearAllPoints()
    menuFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
    d.menuPx, d.menuPy, d.menuPxRight = x, y, x + menuFrame:GetWidth()
end

local menuMovable = { getPosition = getMenuPosition, setPosition = setMenuPosition }

-- Move-mode is driven directly off OnMouseDown/OnMouseUp instead of
-- RegisterForDrag/OnDragStart, so movement starts the instant the mouse goes
-- down instead of waiting on WoW's native drag-recognition threshold. The
-- same pair also does click-vs-drag detection (net movement < 4px = a click,
-- not a drag) to open the precise X/Y position editor.
local function enterMoveMode()
    local f = getOrCreateDisplay()
    if not f then return end
    f:SetFrameStrata("TOOLTIP")
    addon.ShowEditBox(f)
    f:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        self._clickX, self._clickY = GetCursorPosition()
        self:StartMoving()
        self:SetScript("OnUpdate", function()
            local d = getData()
            if d.menuDocked ~= false and menuFrame and menuFrame:IsShown() then
                positionDockedMenu()
            end
        end)
    end)
    f:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        self:StopMovingOrSizing()
        self:SetScript("OnUpdate", nil)
        local x, y = GetCursorPosition()
        local sx, sy = self._clickX or x, self._clickY or y
        if math.abs(x - sx) < 4 and math.abs(y - sy) < 4 and addon.UI then
            addon.UI.OpenPositionEditor(addon.Trinkets, self)
        end
    end)

    local m = getOrCreateMenu()
    buildMenu()
    positionMenu()
    m:SetFrameStrata("TOOLTIP")
    if numTrinkets > 0 then m:Show(); addon.ShowEditBox(m) end

    -- The bag menu is always movable in edit mode. When docked, dragging it
    -- around the display picks the snap corner (shown live by a highlighted
    -- corner marker) and re-docks on release; when undocked it free-floats
    -- and saves its spot. A plain click (no drag) opens the precise X/Y
    -- position editor instead — committing a position there force-undocks
    -- the menu, since a docked menu's spot is derived, not a free x/y.
    m:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        self._clickX, self._clickY = GetCursorPosition()
        self:StartMoving()
        if getData().menuDocked ~= false then
            self:SetScript("OnUpdate", function()
                showDockIndicator(computeDockCorner())
            end)
        end
    end)
    m:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        self:StopMovingOrSizing()
        self:SetScript("OnUpdate", nil)
        hideDockIndicator()

        local x, y = GetCursorPosition()
        local sx, sy = self._clickX or x, self._clickY or y
        local dd = getData()

        if math.abs(x - sx) < 4 and math.abs(y - sy) < 4 then
            -- Click: StopMovingOrSizing() above replaced the docked menu's
            -- multi-point anchor with a single raw one even though it barely
            -- moved — restore the proper dock anchor before (maybe) opening
            -- the editor, so a plain click can't silently undock it.
            if dd.menuDocked ~= false then positionDockedMenu() end
            if addon.UI then addon.UI.OpenPositionEditor(menuMovable, self) end
            return
        end

        if dd.menuDocked ~= false then
            -- Dragging only ever picks a dock CORNER (fully independent of
            -- the menuAlign setting — see positionDockedMenu).
            dd.menuDockCorner = computeDockCorner()
            positionDockedMenu()
        else
            local l, t, r = self:GetLeft(), self:GetTop(), self:GetRight()
            if l and t then dd.menuPx, dd.menuPy, dd.menuPxRight = l, t, r end
        end
    end)
end

local function leaveMoveMode()
    local f = displayFrame
    if not f then return end
    f:SetFrameStrata("MEDIUM")
    addon.HideEditBox(f)
    f:SetScript("OnMouseDown", nil)
    f:SetScript("OnMouseUp",   nil)
    f:SetScript("OnUpdate",    nil)

    hideDockIndicator()
    if menuFrame then
        menuFrame:SetFrameStrata("DIALOG")
        addon.HideEditBox(menuFrame)
        menuFrame:SetScript("OnMouseDown", nil)
        menuFrame:SetScript("OnMouseUp",   nil)
        menuFrame:SetScript("OnUpdate",    nil)
        if not getData().alwaysShow then menuFrame:Hide() end
    end
end

local function savePosition()
    local f = displayFrame
    if not f then return end
    local x, y = f:GetCenter()
    if x and y then
        local d = getData(); d.px, d.py = x, y
    end
end

local function getPosition()
    local f = getOrCreateDisplay()
    if not f then return 0, 0 end
    local x, y = f:GetCenter()
    return x or 0, y or 0
end

local function setPosition(x, y)
    local f = getOrCreateDisplay()
    if not f then return end
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
    local d = getData(); d.px, d.py = x, y
    if d.menuDocked ~= false and menuFrame and menuFrame:IsShown() then
        positionDockedMenu()
    end
end

-- ── Events + periodic tick ───────────────────────────────────────────────────

local tickElapsed = 0

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
eventFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")
eventFrame:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("UPDATE_BINDINGS")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
eventFrame:RegisterEvent("ENCOUNTER_START")
eventFrame:RegisterEvent("ENCOUNTER_END")
eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
    if event == "PLAYER_LOGIN" then
        -- Native ElvUI skin support for the worn Display Menu buttons and the
        -- pop-out Bag Menu grid (see elvuiSkinButton/refreshElvUISkin above).
        -- ShadowElvUI is a fork that keeps ElvUI's engine API intact but
        -- renames the global from ElvUI to ShadowElvUI, so both the load
        -- check and the engine unpack need an explicit fallback or
        -- ShadowElvUI users silently get no skin.
        if IsAddOnLoaded("ElvUI") or IsAddOnLoaded("ShadowElvUI") then
            local engine = ElvUI or ShadowElvUI
            if engine then
                setElvUIEngine((unpack(engine)))
            end
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        applyVisibility()   -- creates the frame, applies scale + saved position
        populateQueueSorts()
        -- Only register Masque once the display actually exists — if init ran
        -- mid-combat the display is deferred, and initMasque would otherwise
        -- create its group with no buttons and then refuse to re-run later.
        if displayFrame then initMasque() end
        -- Pre-warm item info for bag trinkets so first hover doesn't stall
        C_Timer.After(0.5, scanBags)
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        -- Updates the icon/cooldown instantly and schedules the (debounced,
        -- user-configured-delay) bag-menu rebuild itself — see updateWornIcons().
        updateWornIcons()
        -- If a slot's queued trinket is now the one worn there (e.g. it landed,
        -- or you equipped it yourself), the combat-queue entry is fulfilled —
        -- clear it so its indicator can't linger.
        local cleared = false
        for which = 0, 1 do
            local q = combatQueue[SLOT_TOP + which]
            if q and q.id then
                local link = GetInventoryItemLink("player", SLOT_TOP + which)
                if link and link:match("item:(%d+)") == q.id then
                    combatQueue[SLOT_TOP + which] = nil
                    cleared = true
                end
            end
        end
        if cleared then updateQueueIndicators() end
        C_Timer.After(0.3, populateQueueSorts)
    elseif event == "UNIT_INVENTORY_CHANGED" then
        if arg1 == "player" then
            updateWornIcons()
        end
    elseif event == "ACTIONBAR_UPDATE_COOLDOWN" then
        updateWornCooldowns()
        updateMenuCooldowns()
    elseif event == "UPDATE_BINDINGS" then
        updateHotkeys()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- arg1 = unit, arg3 = spellID. Confirms a trinket's on-use spell
        -- actually went off, as opposed to just having been equipped.
        if arg1 == "player" and arg3 then
            local name = GetSpellInfo(arg3)
            if name then markTrinketUsed(name) end
        end
    elseif event == "ENCOUNTER_START" then
        -- arg1 = encounterID. Record it, but only actually queue once we're also
        -- in combat (see maybeQueueEncounter) — not on encounter start alone.
        currentEncounterID = arg1
        encounterQueued    = false
        encGen = encGen + 1
        maybeQueueEncounter()
    elseif event == "ENCOUNTER_END" then
        currentEncounterID = nil
        encounterQueued    = false
        encGen = encGen + 1
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Entered combat: if we're mid-encounter with a config, queue now.
        maybeQueueEncounter()
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        -- Debounce: item data loads in bursts, wait for the burst to settle
        if itemInfoTimer then itemInfoTimer:Cancel() end
        itemInfoTimer = C_Timer.NewTimer(0.1, function()
            itemInfoTimer = nil
            if pendingMenuShow and displayFrame and displayFrame:IsShown()
               and MouseIsOver(displayFrame) then
                showMenu()
            elseif menuFrame and menuFrame:IsShown() then
                buildMenu()
            end
        end)
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Left combat: invalidate any in-flight Specific Auto Queue safeguard
        -- delay (see maybeQueueEncounter) so a brief combat drop mid-delay
        -- forces the full duration to restart on the next PLAYER_REGEN_DISABLED,
        -- rather than letting a stale timer fire once combat merely resumes.
        encGen = encGen + 1
        -- Soft-load: if init happened mid-combat (login/reload during a fight),
        -- the secure display couldn't be built then — build it now, out of combat.
        if not displayFrame then
            applyVisibility()
            populateQueueSorts()
            initMasque()
        end
        local queued = combatQueue
        combatQueue = {}
        updateQueueIndicators()
        C_Timer.After(0.1, function()
            -- Combat can resume during this delay (e.g. a brief regen gap
            -- mid-fight). PickupContainerItem/PickupInventoryItem are
            -- protected and throw ADDON_ACTION_BLOCKED if called while back
            -- in combat lockdown, so re-queue instead of firing blind.
            if InCombatLockdown() then
                for targetSlot, q in pairs(queued) do
                    combatQueue[targetSlot] = combatQueue[targetSlot] or q
                end
                updateQueueIndicators()
                return
            end
            -- Equipping fires PLAYER_EQUIPMENT_CHANGED per slot, which handles
            -- the icon update and bag-menu rebuild scheduling itself.
            for targetSlot, q in pairs(queued) do
                if q.bag and q.slot then
                    attemptSwap(targetSlot, q.bag, q.slot, q.texture)
                end
            end
        end)
    end
end)

eventFrame:SetScript("OnUpdate", function(_, elapsed)
    tickElapsed = tickElapsed + elapsed
    if tickElapsed < 1.0 then return end
    tickElapsed = 0
    processSoftQueue(0)
    processSoftQueue(1)
    processQueue(0)
    processQueue(1)
    tickNotify()
end)

-- ── Exports ──────────────────────────────────────────────────────────────────

addon.Trinkets = {
    getFrame           = getOrCreateDisplay,
    enterMoveMode      = enterMoveMode,
    leaveMoveMode      = leaveMoveMode,
    savePosition       = savePosition,
    applyVisibility    = applyVisibility,
    getPosition        = getPosition,
    setPosition        = setPosition,
    getData            = getData,
    scanBags           = scanBags,
    buildMenu          = buildMenu,
    applyScale         = applyScale,
    applyDisplayScale  = applyDisplayScale,
    applyClickTrigger  = applyClickTrigger,
    applyModifierBlockers = applyModifierBlockers,
    applySoftQueueMod  = applySoftQueueMod,
    layoutDisplay      = layoutDisplay,
    positionMenu       = positionMenu,
    populateQueueSorts = populateQueueSorts,
    populateMenuOrder  = populateMenuOrder,
    updateHotkeys      = updateHotkeys,
    updateQueueIndicators = updateQueueIndicators,
    refreshElvUISkin   = refreshElvUISkin,
}
