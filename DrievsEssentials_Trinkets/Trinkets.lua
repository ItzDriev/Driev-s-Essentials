-- Part of the Trinkets module addon. `...` would give this addon's own private
-- table, so use core's shared namespace.
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

-- ElvUI's engine table once PLAYER_LOGIN confirms ElvUI (or ShadowElvUI) is
-- loaded. Nil otherwise, so elvuiSkinButton() is a no-op.
local elvE

-- Bakes Masque's "Blizzard Classic" skin onto the button so the default look
-- needs no Masque; Masque, if enabled for our group, reskins over these regions.
-- Item Rack bakes the same look, so it lives in core.
--
-- The Checked texture is set only on the worn buttons — on the CheckButton menu
-- buttons it leaves a stuck glow after a swap click toggles their checked state.
local styleSlotButton = addon.StyleSlotButton

-- Explicit region maps for Masque's Group:AddButton: auto-detect only reliably
-- finds Icon/Cooldown by field name, so the rest must be listed by hand or
-- Masque leaves them drawing their original textures. Defined ahead of the ElvUI
-- block, which needs them to hand buttons back when that skin is toggled off.
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

-- ── Saved data ────────────────────────────────────────────────────────────────
-- Ahead of the ElvUI block, which reads elvuiSkinEnabled — Lua locals aren't
-- visible to code written before them.

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
    -- [encounterID] = { enabled, trigger, mainTop, mainBottom, softTop, softBottom }.
    -- `trigger` picks what fires the queue (nil = DEFAULT_ENC_TRIGGER).
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
    -- Triggers didn't exist when these configs were made — every one meant "in
    -- combat", which is no longer what an absent trigger does. Stamp the old
    -- behaviour on so updating doesn't silently move someone's raid swaps.
    if not d.encTriggerMigrated then
        for _, e in pairs(d.encounters) do
            if e.trigger == nil then e.trigger = "combat" end
        end
        d.encTriggerMigrated = true
    end
    return d
end

-- The icon crop for ElvUI's flat look. E.TexCoords would normally hold it, but
-- it's only filled by E:UpdateTexCoords() inside E:Initialize() — and this build
-- never initializes on Classic Era 1.15.9, leaving it at identity and every crop
-- a silent no-op. So trust it only when it holds a crop, else compute it from
-- the same cropIcon setting (0.04 * cropIcon; default 2 → 8%).
local function getIconCrop()
    local tc = elvE and elvE.TexCoords
    if tc and (tc[1] ~= 0 or tc[2] ~= 1 or tc[3] ~= 0 or tc[4] ~= 1) then
        return tc[1], tc[2], tc[3], tc[4]
    end
    local crop = elvE and elvE.db and elvE.db.general and elvE.db.general.cropIcon
    local m = 0.04 * (tonumber(crop) or 2)
    return m, 1 - m, m, 1 - m
end

-- Frame strata / level for the two frames, set under each Layout tab. Both
-- default to MEDIUM / 0 so they sit among normal UI panels.
local STRATA_OPTS = {
    "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN",
    "FULLSCREEN_DIALOG", "TOOLTIP",
}
local DEFAULT_STRATA, DEFAULT_LEVEL = "MEDIUM", 0

local function isValidStrata(s)
    for _, v in ipairs(STRATA_OPTS) do
        if v == s then return true end
    end
    return false
end

-- Level is clamped at 0 (the client rejects negatives) and applied after the
-- strata, since changing strata re-bases a frame's level.
local function applyFrameLayer(f, strata, level)
    if not f then return end
    if not isValidStrata(strata) then strata = DEFAULT_STRATA end
    f:SetFrameStrata(strata)
    f:SetFrameLevel(math.max(0, tonumber(level) or DEFAULT_LEVEL))
end

-- Called at frame creation, on leaving Move Mode (which temporarily raises
-- them), and whenever the settings change.
local function applyFrameLayers()
    local d = getData()
    applyFrameLayer(displayFrame, d.displayStrata, d.displayLevel)
    applyFrameLayer(menuFrame,    d.menuStrata,    d.menuLevel)
end

-- Reskins one button to ElvUI's action-button look, mirroring TrinketMenu's own
-- ElvUI skin. No-ops until setElvUIEngine() has run, or if "Skin with ElvUI" is
-- off. Idempotent — called at creation and again from refreshElvUISkin() for
-- buttons built before ElvUI was detected.
local function elvuiSkinButton(btn)
    if not (elvE and btn) or btn._elvuiSkinned then return end
    if getData().elvuiSkinEnabled == false then return end
    if not btn.StripTextures or not btn.SetTemplate then return end
    btn._elvuiSkinned = true
    -- StripTextures() clears EVERY texture region including the trinket icon, so
    -- remember its texture and put it back. Without this a toggle off→on left the
    -- icon blank while the cooldown swipe stayed visible.
    local icon = btn.icon
    local savedTexture = icon and icon:GetTexture()
    -- 1.15.9's ActionButtonTemplate applies an IconMask MaskTexture to the icon. A
    -- MaskTexture IS a Texture region, so StripTextures() blanks it too — and a blank
    -- mask is alpha 0 everywhere, rendering the icon invisible whatever texture we
    -- put back. Save it first so revertElvUIButton can restore it.
    local mask = btn.IconMask
    if mask and btn._elvuiMaskTexture == nil and btn._elvuiMaskAtlas == nil then
        btn._elvuiMaskAtlas   = mask.GetAtlas and mask:GetAtlas() or nil
        btn._elvuiMaskTexture = mask:GetTexture()
    end
    btn:StripTextures()
    btn:SetTemplate()
    if btn.StyleButton then btn:StyleButton() end
    btn:SetBackdropColor(0, 0, 0, 0)
    if icon then
        -- Don't render through the template's own icon region while skinned — it carries
        -- 1.15.9 baggage (the IconMask, atlas history from StripTextures) that misrenders
        -- in ways plain textures don't. Build a virgin texture and point btn.icon at it,
        -- so every existing update path reads and writes the clean region.
        local display = btn._elvuiIcon
        if not display then
            display = btn:CreateTexture(nil, "ARTWORK", nil, -1)
            btn._elvuiIcon = display
            btn._origIcon  = icon
        end
        display:SetTexture(savedTexture)
        display:SetDesaturated(icon:IsDesaturated())
        display:SetTexCoord(getIconCrop())
        display:SetInside(btn)
        display:Show()
        icon:Hide()
        btn.icon, btn.Icon = display, display
    end
end

-- Undoes elvuiSkinButton and clears the backdrop SetTemplate() added, so
-- toggling the checkbox off reverts live instead of needing a reload.
local function revertElvUIButton(btn, size)
    if not btn or not btn._elvuiSkinned then return end
    btn._elvuiSkinned = nil
    if btn.SetBackdrop then btn:SetBackdrop(nil) end
    styleSlotButton(btn, size)
    -- Restore the IconMask elvuiSkinButton hid (and whose texture StripTextures
    -- blanked). SetTexture needs the additive wrap modes or the mask clamps wrong.
    local mask = btn.IconMask
    if mask then
        if btn._elvuiMaskAtlas then
            mask:SetAtlas(btn._elvuiMaskAtlas)
        elseif btn._elvuiMaskTexture then
            mask:SetTexture(btn._elvuiMaskTexture,
                "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        end
        mask:Show()
    end
    -- Point btn.icon back at the template's region and hide the skin's replacement.
    -- The texture/desaturation state is copied so the button shows the same trinket
    -- immediately.
    local display = btn._elvuiIcon
    local icon    = btn._origIcon or btn.icon
    if display and icon then
        icon:SetTexture(display:GetTexture())
        icon:SetDesaturated(display:IsDesaturated())
        icon:Show()
        display:Hide()
        btn.icon, btn.Icon = icon, icon
    end
    if icon then
        icon:ClearAllPoints()
        icon:SetAllPoints(btn)
        icon:SetTexCoord(0, 1, 0, 1)
    end
end

-- Applies or reverts the skin across every button already built. New buttons
-- self-skin at creation via elvuiSkinButton, which reads the same setting.
local function refreshElvUISkin()
    if not elvE then return end
    local on = getData().elvuiSkinEnabled ~= false
    -- The ElvUI skin and Masque are mutually exclusive per button: Masque reskins
    -- every region it owns right over the ElvUI template, leaving an ElvUI backdrop
    -- with a classic icon inside. So skinning removes the button from the Masque
    -- group, and reverting hands it back.
    local group = addon.Trinkets and addon.Trinkets._masqueGroup
    local function apply(btn, size, buttonData)
        if not btn then return end
        if on then
            if group and not btn._elvuiSkinned then group:RemoveButton(btn) end
            elvuiSkinButton(btn)
        else
            local wasSkinned = btn._elvuiSkinned
            revertElvUIButton(btn, size)
            if group and wasSkinned then group:AddButton(btn, buttonData(btn)) end
        end
    end
    if displayFrame then
        for which = 0, 1 do
            apply(displayFrame["t"..which], BTN_SIZE, displayButtonData)
        end
    end
    if menuFrame then
        for i = 1, MAX_MENU do
            apply(menuFrame["mb"..i], MENU_SIZE, menuButtonData)
        end
    end
end

-- Called once the PLAYER_LOGIN handler below confirms ElvUI/ShadowElvUI is
-- loaded.
local function setElvUIEngine(E)
    elvE = E
    refreshElvUISkin()
end

-- Re-asserts the crop after every icon:SetTexture(), as insurance against
-- anything resetting the region's texcoords. No-op for unskinned buttons.
local function applyElvUICrop(btn)
    if elvE and btn and btn._elvuiSkinned and btn.icon then
        btn.icon:SetTexCoord(getIconCrop())
    end
end

-- ── Bag scanning ─────────────────────────────────────────────────────────────

local baggedTrinkets  = {}
local numTrinkets     = 0
local combatQueue     = {}   -- [targetSlot] = { bag, slot, texture }
-- Preemptive ("soft") queue: [targetSlot] = { id, bag, slot, texture }. Unlike
-- combatQueue (which fires when combat ends), this waits for a GAMEPLAY
-- condition — the equipped trinket used and its buff expired — so the next one
-- can be lined up without swapping the active one out mid-effect.
local softQueue       = {}
local pendingMenuShow = false  -- true when showMenu found 0 trinkets due to unloaded item data
local itemInfoTimer   = nil    -- debounce timer for GET_ITEM_INFO_RECEIVED
-- Latched from the Alt state only when the mouse ENTERS the display+menu region
-- fresh. NOT re-latched on internal moves nor tied to the live Alt state, so
-- releasing Alt and moving onto the menu keeps them shown.
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

-- Equipping ANY on-use trinket applies a generic "just equipped" swap lockout
-- shown as a normal cooldown swipe, indistinguishable from a real on-use
-- cooldown by duration alone. So track per slot whether the equipped trinket was
-- confirmed used, reset when the equipped item changes — auto-queue must never
-- swap one away before it's had a chance to be used.
local queueUsedTracker = { [0] = { id = nil, used = false }, [1] = { id = nil, used = false } }

-- On UNIT_SPELLCAST_SUCCEEDED("player", ...): if the spell is the on-use spell
-- of whichever trinket is equipped in slot 0/1, mark that slot used.
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

-- processQueue is defined further down, after grayOutDisplaySlot/markSwappedOut/
-- updateQueueIndicators/menuSwapFreeze, which it reuses so an auto-queued swap
-- gets the same feedback as a manual click.

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

-- Keybind text styling, from core's shared font block. The defaults reproduce
-- what this drew when the font was hardcoded into the button.
local BIND_FONT_DEFAULT = addon.Font.New({
    font = "Friz Quadrata TT", size = 10, x = -2, y = -2,
})

local function applyHotkeyStyle(btn)
    local cfg = getData().bindingFont
    addon.Font.ApplyAt(btn.hotKey, cfg, BIND_FONT_DEFAULT, {
        point = "TOPRIGHT", relativeTo = btn, relativePoint = "TOPRIGHT",
        justifyH = "RIGHT",
    })
    -- White unless the block's custom colour is ticked, which is what this text
    -- has always been.
    addon.Font.ApplyColor(btn.hotKey, cfg, BIND_FONT_DEFAULT, 1, 1, 1)
end

local function updateHotkeys()
    if not displayFrame then return end
    local d = getData()
    for which = 0, 1 do
        local btn = displayFrame["t"..which]
        if btn and btn.hotKey then
            applyHotkeyStyle(btn)
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

-- [which] = true while a slot is mid-swap: its icon is still the grayed outgoing
-- trinket, and its cooldown swirl must be frozen so the incoming trinket's
-- cooldown doesn't paint over the old icon.
local swapPending = {}

-- Desaturate in place so there's no black flash while the swap resolves. Cleared
-- by updateWornIcons() once PLAYER_EQUIPMENT_CHANGED lands the new trinket.
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
                applyElvUICrop(btn)
                settled = true
            else
                -- GetInventoryItemTexture has no item-cache dependency for worn items, so the
                -- display updates the instant the equipment change fires.
                local tex = GetInventoryItemTexture("player", slot)
                if tex then
                    btn.icon:SetTexture(tex)
                    btn.icon:SetDesaturated(false)
                    applyElvUICrop(btn)
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
    -- Started AFTER the display icon/cooldown are set, never at click time, so the
    -- configured delay is measured from when the display visually settles.
    scheduleMenuRebuild()
end

-- Equipping an on-use trinket puts a ~30s swap lockout on trinkets. On the bag
-- menu that swirl is noise, so ≤30s cooldowns are filtered there — except the
-- trinket swapped OUT, exempted by ID so its equip cooldown stays visible.
local SWAP_LOCKOUT_MAX = 30
local swappedOutAt   = {}     -- [itemID] = GetTime() the item was last swapped out
-- True from the moment a swap starts until the menu rebuilds. While set,
-- updateMenuCooldowns() is skipped: the bag slots the menu buttons point at are
-- momentarily stale, so re-reading would paint a wrong timer over an icon.
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

-- The soft-queue badge sits in the opposite corner from the combat/auto-queue
-- one, with a gold border to read as "waiting, not yet firing".
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

-- While a swap is pending in combat it shows the incoming item's icon;
-- otherwise, if auto queue is enabled, the gear icon as an "armed" marker. The
-- bottom-right badge separately shows any soft-queued trinket.
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

-- If a swap's protected calls get silently blocked (combat resuming in the
-- split second around the call — ADDON_ACTION_BLOCKED raises no catchable
-- error), PLAYER_EQUIPMENT_CHANGED never fires, swapPending is never cleared,
-- and the icon freezes forever. This recovers after the timeout.
--
-- That recovery is UNCONDITIONAL. The user-facing "watchdog" toggle governs only
-- auto-RE-QUEUING the failed swap, which can misfire on a slow-but-successful one.
local SWAP_WATCHDOG_TIMEOUT = 1.0

-- [which] = a counter bumped per swap attempt. Each watchdog snapshots it as its
-- "generation" and no-ops if a newer attempt has started, so rapid repeat swaps
-- don't leave two watchdogs racing over one swapPending flag with the stale one
-- re-queueing an old trinket.
local swapGen = {}

local function attemptSwap(targetSlot, bag, slot, texture)
    -- Guard against an unrelated item already sitting on the cursor (e.g.
    -- from something outside this addon's control).
    if CursorHasItem() then return end

    local which = targetSlot - SLOT_TOP
    -- Guard against overlapping swaps on the SAME slot. The pickup pair below is
    -- only treated as an atomic bag<->equipment swap once the prior swap is
    -- confirmed, and that confirmation can lag well behind the cursor going empty.
    -- Firing another pair into the still-settling transaction is what strands the
    -- second trinket on the cursor — so key off swapPending, not CursorHasItem().
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
                -- Out of combat the swap should be possible; something transient blocked it.
                -- Retry directly rather than parking it in the combat queue, which would never
                -- flush without a combat-end event.
                attemptSwap(targetSlot, bag, slot, texture)
            end
        end
        updateQueueIndicators()
    end)
end

-- Whether slot `which`'s equipped trinket is clear to be swapped AWAY: true once
-- it's been genuinely used since being equipped and its on-use buff has expired.
-- A trinket with no on-use spell, or an empty slot, is always clear. Also
-- (re)initialises the used-tracker when the equipped item changes, so it's safe
-- as the single source of truth every tick. Shared by processQueue and
-- processSoftQueue so both obey the same "used + expired" rule.
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

-- Ported from TrinketMenu.ProcessAutoQueue, adapted to this addon's per-slot
-- { sort, stats } data. Two bugs this fixes vs. the original:
--
--   1. "Doesn't work at all" — it equipped directly at all times, including in
--      combat, where the pickup pair is silently blocked, leaving an item on the
--      cursor and the queue confused. Now it feeds the same combatQueue manual
--      clicks use, flushed by PLAYER_REGEN_ENABLED.
--
--   2. "Spam swaps" — it scanned the whole sort list every tick and jumped to
--      the first ready trinket, with nothing stopping it swapping the current
--      one out before it had been used. The equipped trinket can now only be
--      swapped out once genuinely used and its buff expired; once that gate
--      clears, the list is scanned top-down and whatever swaps in becomes the
--      new "current", subject to the same gate.
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

-- Fires a soft-queued trinket. Bags are re-scanned live for the queued item ID
-- (its position may have shifted) rather than trusting the stored one. In combat
-- it hands off to combatQueue, matching the auto-queue's behaviour.
local function processSoftQueue(which)
    local slot = SLOT_TOP + which
    local sq = softQueue[slot]
    if not sq then return end

    -- A first-stage swap is still pending for this slot. The soft-queued trinket is
    -- meant to follow THAT one, so hold until it has landed — otherwise the gate
    -- below would evaluate against the soon-to-be-replaced trinket and could fire
    -- early, clobbering the first-stage swap. Central to chain mode.
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
    -- expire. One exception — swap early — but only when ALL of: it was never used
    -- (so no buff is being thrown away mid-duration), it's on a real cooldown (> the
    -- ~30s equip lockout) so it can't be used soon, and the soft trinket is ready.
    -- That keeps the "don't stall behind a long cooldown that was already ticking"
    -- fix without firing when the trinket was just popped, or when the soft trinket
    -- shares that cooldown and swapping would gain nothing.
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

-- Push a configured boss's trinkets into the queues so the swaps happen the next
-- time combat allows. Two presets per slot: Main swaps in first (immediately out
-- of combat, else via the combat queue), Soft goes to the soft queue, firing
-- after Main has been used and expired. Main needs a bag copy and is skipped if
-- already worn; Soft may be one you currently have EQUIPPED (a common case), so
-- it's queued as long as you own it and re-equipped from bags once displaced.
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
                if UnitAffectingCombat("player") then
                    combatQueue[slot] = { id = mid, bag = bag, slot = s, texture = tex }
                else
                    -- Triggers that can fire outside combat (Encounter Start on
                    -- a boss that doesn't aggro immediately, Encounter End after
                    -- the kill) would otherwise park the swap in combatQueue,
                    -- which only flushes on PLAYER_REGEN_ENABLED — i.e. not
                    -- until the NEXT fight ends. Out of combat the equip is
                    -- legal right now, so just do it.
                    attemptSwap(slot, bag, s, tex)
                end
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

-- ── Specific Auto Queue triggers ─────────────────────────────────────────────
-- Each configured encounter picks WHEN its trinkets queue, as enc.trigger:
--
--   combat        In combat on the encounter, optionally held for the safeguard
--                 delay. The original behaviour, before triggers existed.
--   encounter     ENCOUNTER_START alone, without waiting for combat.
--   hp75/50/35/20 The boss dropping to that share of health, polled on the
--                 shared 1s ticker.
--   end           ENCOUNTER_END — kill or wipe — for swapping back afterwards.
--
-- `hp` is the fraction the threshold triggers compare against. `desc` is the
-- hover help the settings UI shows, kept here beside the code that implements
-- the behaviour so it can't quietly go stale.
local ENC_TRIGGERS = {
    {
        value = "combat",
        label = "In Combat",
        desc  = {
            "Queues once you are both inside the encounter and actually in combat — whichever of the two happens second.",
            "With the safeguard delay above switched on, both have to hold continuously for its full duration first. Dropping combat, or the encounter ending, cancels the attempt and restarts the delay from scratch.",
            "The cautious option: it swaps at the pull, but a boss that does not put the raid in combat the instant it starts will not make you swap during the run-in.",
        },
    },
    {
        value = "encounter",
        label = "Encounter Start",
        desc  = {
            "Queues the moment the encounter starts, without waiting for combat. The safeguard delay does not apply.",
            "Faster off the mark, but on a boss that leaves the raid out of combat for a few seconds this can swap a trinket during the run-in. Pick it when you want the set on before your first global.",
        },
    },
}

-- The four health thresholds differ only by their number, so build them rather
-- than paste four near-identical option tables.
for _, pct in ipairs({ 75, 50, 35, 20 }) do
    ENC_TRIGGERS[#ENC_TRIGGERS + 1] = {
        value = "hp" .. pct,
        label = "Boss at " .. pct .. "%",
        hp    = pct / 100,
        desc  = {
            "Queues the first time the boss drops to " .. pct .. "% health or below. Checked once a second, so it can land a little under the mark rather than exactly on it.",
            "Classic Era has no boss unit token, so the boss's health is read through your target, your mouseover, or its nameplate. It has to be at least one of those for the threshold to be seen at all — in practice, keep it targeted.",
            "On a multi-boss encounter (Four Horsemen, Twin Emperors, Bug Trio) the first one to reach " .. pct .. "% is what fires it.",
        },
    }
end

ENC_TRIGGERS[#ENC_TRIGGERS + 1] = {
    value = "end",
    label = "Encounter End",
    desc  = {
        "Queues when the encounter ends — on the kill or on a wipe. Nothing swaps while the fight is running.",
        "This is the one for putting a farming or utility set back on the moment the boss is down. If you are still in combat when it fires, the swap lands as soon as you drop out of it.",
    },
}

addon.TRINKET_ENC_TRIGGERS = ENC_TRIGGERS

-- What an encounter with no explicit trigger does. Stored as nil rather than
-- written out, so a boss row you never touch still prunes itself away — which
-- means changing this value changes what every untouched config does, hence the
-- one-time stamp in getData() that pins pre-existing configs to their old
-- behaviour instead of moving them.
local DEFAULT_ENC_TRIGGER = "hp75"
addon.TRINKET_ENC_TRIGGER_DEFAULT = DEFAULT_ENC_TRIGGER

-- [trigger] = health fraction, for the threshold triggers only. Doubles as the
-- "is this an HP trigger?" test everywhere below.
local TRIGGER_HP = {}
for _, t in ipairs(addon.TRINKET_ENC_TRIGGERS) do
    if t.hp then TRIGGER_HP[t.value] = t.hp end
end

local currentEncounterID   = nil
local currentEncounterName = nil   -- ENCOUNTER_START's name, for the HP triggers
local encounterQueued      = false

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
-- simultaneously for a duration before queuing. encGen is bumped on every
-- ENCOUNTER_START/END so a delayed attempt from an earlier encounter can tell
-- it's been superseded and no-op rather than fire late.
local encGen = 0

-- The config for the encounter we're currently in, or nil if there isn't one,
-- it isn't ticked, or it's a Stockades test encounter with Debug switched off.
local function activeEncounterConfig()
    if not currentEncounterID then return nil end
    if debugEncounterIDs[currentEncounterID] and not getData().debugEncounters then return nil end
    local enc = getData().encounters[currentEncounterID]
    if enc and enc.enabled then return enc end
    return nil
end

-- Classic Era has no boss1..boss5 tokens, so boss health is only readable
-- through a token we already hold. Rather than register UNIT_HEALTH (constant
-- traffic for everything in range), sample target, mouseover and anything with a
-- nameplate on the queues' existing 1s ticker.
--
-- A unit counts as the boss if its name matches ENCOUNTER_START's, or failing
-- that if it's classified worldboss — which covers multi-mob encounters whose
-- name matches no single unit. With several up, the LOWEST health wins.
local function encounterBossHealthPct()
    local lowest
    local function consider(unit)
        if not unit or not UnitExists(unit) or UnitIsDead(unit) then return end
        if not UnitCanAttack("player", unit) then return end
        if UnitName(unit) ~= currentEncounterName
           and UnitClassification(unit) ~= "worldboss" then return end
        local maxHP = UnitHealthMax(unit)
        if not maxHP or maxHP <= 0 then return end
        local pct = UnitHealth(unit) / maxHP
        if not lowest or pct < lowest then lowest = pct end
    end
    consider("target")
    consider("mouseover")
    for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
        consider(plate.namePlateUnitToken)
    end
    return lowest
end

-- Polled from the shared ticker for the hp* triggers only; every other trigger
-- is event-driven via maybeQueueEncounter.
local function tickEncounterHealth()
    if encounterQueued then return end
    local enc = activeEncounterConfig()
    if not enc then return end
    local threshold = TRIGGER_HP[enc.trigger or DEFAULT_ENC_TRIGGER]
    if not threshold then return end
    local pct = encounterBossHealthPct()
    if pct and pct <= threshold then
        queueEncounterTrinkets(enc)
        encounterQueued = true
    end
end

-- The event-driven triggers. `reason` is the event that got us here:
-- "encounter", "combat" or "end". The per-encounter latch keeps each to one
-- queue per pull.
--
-- "combat" must fire only once you're BOTH inside a configured encounter AND in
-- combat, never on ENCOUNTER_START alone — some bosses don't put the raid in
-- combat immediately, and queuing then could swap your trinket out.
local function maybeQueueEncounter(reason)
    if encounterQueued then return end
    local enc = activeEncounterConfig()
    if not enc then return end

    local trigger = enc.trigger or DEFAULT_ENC_TRIGGER
    if TRIGGER_HP[trigger] then return end   -- tickEncounterHealth owns these

    if trigger == "end" then
        if reason ~= "end" then return end
    elseif reason == "end" then
        return                               -- the fight's over, too late to matter
    elseif trigger == "combat" and not UnitAffectingCombat("player") then
        return
    end

    -- "combat" is the only trigger with two conditions that can come apart
    -- mid-window, so it's the only one the delay applies to. Holding an HP or
    -- encounter-end trigger back would make it miss the moment it exists to catch.
    local d = getData()
    if trigger == "combat" and d.encQueueDelayEnabled then
        local myGen = encGen
        local myEncounterID = currentEncounterID
        C_Timer.After(math.max(0, d.encQueueDelaySeconds or 5.0), function()
            -- Re-verify both conditions at fire time, not just when scheduled: if the
            -- encounter changed or combat dropped meanwhile, this attempt is stale.
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

-- Anchors `frame` to a side of the display using TWO independent single-axis
-- anchor points, both targeting the display FRAME's outer edges — together
-- pinning the same point one corner-to-corner SetPoint would. Since both axes
-- reference the frame, growing displayEdgePad shifts them together, so the
-- corners stay touching instead of the icons drifting out of alignment.
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

-- Docks the menu using whichever corner pair was last picked by dragging.
-- Independent of the menuAlign SETTING, which only controls which end of the row
-- trinket #1 packs to — conflating the two meant the anchor snapped to menuAlign
-- and ignored where the menu was actually dropped.
local function positionDockedMenu()
    if not displayFrame or not menuFrame then return end
    local key = getData().menuDockCorner or DEFAULT_CORNER
    local side, align = key:match("^(%a+)%-(%a+)$")
    if not side then side, align = "below", "left" end
    applyDockAnchor(menuFrame, side, align, DOCK_GAP)
end

-- Uses the CURSOR's position, not the menu's geometric centre: grabbing the menu
-- near one edge and dragging that edge close can leave the centroid far off to
-- the other side, picking the opposite corner from the one you're pointing at.
-- Normalised by the display's half-size so the menu's bulk can't skew it.
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
            -- Right edge fixed → anchor TOPRIGHT so add/remove grows leftward. Prefer the
            -- saved right edge; derive it from the last left edge plus width if missing.
            local right = d.menuPxRight or (d.menuPx + menuFrame:GetWidth())
            menuFrame:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", right, d.menuPy)
        else
            menuFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", d.menuPx, d.menuPy)
        end
    else
        positionDockedMenu()
    end
end

-- Lays out the two worn buttons from the configured padding and gap, resizes the
-- display to match, and re-docks the menu (whose position depends on both).
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

-- Rebuilds the menu swapDelay seconds after the worn icon has ALREADY updated
-- (this only runs from updateWornIcons), so the delay is measured from when the
-- display settles, not from click time. Debounced against two events for one
-- swap. Shown-state is checked when the timer FIRES, not here —
-- PLAYER_EQUIPMENT_CHANGED lands a frame or two after the click, and gating on
-- IsShown then could drop the rebuild.
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

-- Worn buttons register BOTH click phases, always. Using an inventory item is
-- protected, and the client treats only ONE phase as the valid hardware trigger
-- — whichever `ActionButtonUseKeyDown` names, for mouse and keybind alike. A
-- button on the other phase still gets its OnClick, but the protected
-- UseInventoryItem is silently rejected. Registering both puts the use on the
-- valid phase and the other no-ops. PreClick dedupes its own side effects via
-- `down`. RegisterForClicks isn't combat-protected.
local function applyClickTrigger()
    if not displayFrame then return end
    for which = 0, 1 do
        local btn = displayFrame["t"..which]
        if btn then btn:RegisterForClicks("LeftButtonDown", "LeftButtonUp") end
    end
end

-- Blocks the keybind and click from using the item while a modifier is held, via
-- WoW's secure modified-click attributes (the mechanism TrinketMenu uses).
-- <mod>-slot* = ATTRIBUTE_NOOP is resolved C-side, so it's combat-safe and
-- doesn't depend on script timing the way intercepting in PreClick would.
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

    -- Hidden trinkets (Alt+click a menu icon to toggle) sort to the end and are
    -- normally excluded. They show desaturated when showHidden is latched on by
    -- Alt-hovering the display.
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
                applyElvUICrop(mb)
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

getOrCreateMenu = function()
    if menuFrame then return menuFrame end

    local f = CreateFrame("Frame", "DrievTrinketMenu", UIParent, "BackdropTemplate")
    f:SetBackdrop({ bgFile=WHITE, edgeFile=WHITE, edgeSize=2 })
    f:SetBackdropColor(0, 0, 0, 0)
    f:SetBackdropBorderColor(0, 0, 0, 0)
    applyFrameLayer(f, getData().menuStrata, getData().menuLevel)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetScript("OnEnter", cancelMenuClose)
    f:SetScript("OnLeave", scheduleMenuClose)
    f:Hide()

    for i = 1, MAX_MENU do
        -- Inherits ActionButtonTemplate for Icon/Cooldown; styleSlotButton bakes the
        -- Blizzard Classic look on top. No Checked flash — these aren't the worn buttons.
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
            -- Being a CheckButton, clicking can leave its native checked-glow stuck on — and
            -- these buttons are pooled across rebuilds, so the glow then shows on whatever
            -- next occupies that slot. Cleared defensively on every click, matching
            -- TrinketMenu's own fix.
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

            -- Soft queue: hold the configured modifier and click to line this trinket up
            -- WITHOUT swapping now — it fires once the equipped one has been used and its
            -- buff expired. Clicking it again toggles off; a different one replaces it.
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
                -- A plain click manages the MAIN (combat) queue only: queue this trinket, or
                -- un-queue it if it's already the one queued for this slot. The soft queue is
                -- managed solely by modifier+click.
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
                -- The rebuild is scheduled from updateWornIcons() once PLAYER_EQUIPMENT_CHANGED
                -- lands, not from here — starting at click time raced network latency and could
                -- rebuild the menu before the icon updated.
                attemptSwap(targetSlot, self._bag, self._slot, self.icon:GetTexture())
                updateQueueIndicators()
            end
        end)

        elvuiSkinButton(mb)
        f["mb"..i] = mb
    end

    menuFrame = f

    -- Register with Masque if already initialised. ElvUI-skinned buttons stay out of
    -- the group, since Masque would reskin over the ElvUI template.
    if addon.Trinkets and addon.Trinkets._masqueGroup then
        for i = 1, MAX_MENU do
            local mb = f["mb"..i]
            if not mb._elvuiSkinned then
                addon.Trinkets._masqueGroup:AddButton(mb, menuButtonData(mb))
            end
        end
    end

    return f
end

-- ── Display frame ─────────────────────────────────────────────────────────────

-- Swaps the two worn trinkets between slots 13 and 14 via the standard cursor
-- dance: pick up top, pick up bottom (which drops top into 14), drop bottom into
-- 13. Both slots must be filled. The cursor is cleared afterwards so a partial
-- failure can't leave a trinket stuck on it.
local function swapWornTrinkets()
    -- PickupInventoryItem is protected in combat and errors from this non-secure
    -- handler while locked down, so this manual swap is out-of-combat only.
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

-- Suppress the secure "use item" action for the soft-queue and slot-swap
-- modifiers, so <modifier>+click does the special action instead of firing the
-- trinket. "none" is untouched.
--
-- It can't be a static attribute: a keybind press arrives as an ordinary
-- LeftButton click on the same button, so a static shift-type1 would blank the
-- use for a shift-held KEYBIND too. Armed per click from a restricted snippet
-- that can tell the two apart via IsUnderMouse() and can SetAttribute mid-combat.
local SECURE_ARM_MODS = [[
    -- Runs before the secure use resolves. Blanks the item action for the configured
    -- modifiers only when the click came from the mouse (or keybinds are opted in).
    if self:GetAttribute("de_kbmods") or self:IsUnderMouse() then
        local s = self:GetAttribute("de_softmod")
        local w = self:GetAttribute("de_swapmod")
        if s and s ~= "none" then
            self:SetAttribute(s .. "-type1", "macro")
            self:SetAttribute(s .. "-macrotext1", "")
        end
        if w and w ~= "none" then
            self:SetAttribute(w .. "-type1", "macro")
            self:SetAttribute(w .. "-macrotext1", "")
        end
    end
]]

-- Wrapped onto PostClick, not onto PreClick's tail: PreClick's post-body would
-- run before the secure action resolves and un-blank it again.
local SECURE_DISARM_MODS = [[
    local s = self:GetAttribute("de_softmod")
    local w = self:GetAttribute("de_swapmod")
    if s and s ~= "none" then
        self:SetAttribute(s .. "-type1", nil)
        self:SetAttribute(s .. "-macrotext1", nil)
    end
    if w and w ~= "none" then
        self:SetAttribute(w .. "-type1", nil)
        self:SetAttribute(w .. "-macrotext1", nil)
    end
]]

local function applySoftQueueMod()
    if not displayFrame or InCombatLockdown() then return end
    local d = getData()
    for which = 0, 1 do
        local btn = displayFrame["t"..which]
        if btn then
            btn:SetAttribute("de_softmod", d.softQueueMod or "shift")
            btn:SetAttribute("de_swapmod", d.swapMod or "ctrl")
            btn:SetAttribute("de_kbmods",  d.modKeybindActions or false)
            -- Clear anything a previous build (or an interrupted click) left
            -- armed, so no modifier stays blanked behind our back.
            for _, m in ipairs({ "shift", "ctrl", "alt" }) do
                btn:SetAttribute(m .. "-type1", nil)
                btn:SetAttribute(m .. "-macrotext1", nil)
            end
        end
    end
end

local function getOrCreateDisplay()
    if displayFrame then return displayFrame end
    -- The worn buttons are SecureActionButtonTemplate, and creating a secure frame
    -- (plus the SetAttribute calls below) is blocked in combat. Bail so a /reload
    -- mid-fight doesn't error; PLAYER_REGEN_ENABLED soft-loads it after. Callers
    -- must tolerate a nil return.
    if InCombatLockdown() then return nil end

    local f = CreateFrame("Frame", "DrievTrinketDisplay", UIParent, "BackdropTemplate")
    -- BTN_PAD pixels of invisible draggable area around the two buttons
    f:SetSize(BTN_SIZE * 2 + BTN_GAP + BTN_PAD * 2, BTN_SIZE + BTN_PAD * 2)
    -- Just under the middle of the screen, where the eye already is during a
    -- fight. Kept as an offset from CENTER rather than the absolute px/py the
    -- drag handler stores, so the starting spot is the same on any resolution.
    f:SetPoint("CENTER", UIParent, "CENTER", -5, -23)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    applyFrameLayer(f, getData().displayStrata, getData().displayLevel)
    f:SetBackdrop({ bgFile=WHITE, edgeFile=WHITE, edgeSize=2 })
    f:SetBackdropColor(0, 0, 0, 0)
    f:SetBackdropBorderColor(0, 0, 0, 0)
    f:EnableMouse(true)
    -- Fallback: the buttons open the menu on their own OnEnter, but a hover over the
    -- display frame itself should too. Forces a fresh buildMenu() unconditionally —
    -- menuFrame may not exist yet, or may hold stale content from before item data
    -- was cached — so hovering self-heals the menu.
    f:SetScript("OnEnter", function()
        cancelMenuClose()
        getOrCreateMenu()
        -- Latch hidden-trinket reveal from the Alt state, but only on a fresh entry into
        -- the region, so it survives releasing Alt and heading to the menu.
        if not mouseInRegion then showHidden = IsAltKeyDown() end
        mouseInRegion = true
        -- Unconditional, regardless of alwaysShow: if the menu ended up empty at login
        -- (bag data not cached, so buildMenu() found 0 trinkets and never called Show),
        -- hovering must be able to self-heal it.
        showMenu()
    end)
    f:SetScript("OnLeave", scheduleMenuClose)

    for which = 0, 1 do
        local slot = SLOT_TOP + which
        -- Inherits ActionButtonTemplate for Icon/Cooldown; styleSlotButton bakes the
        -- Blizzard Classic look on top and the Checked flash is set below.
        -- SecureActionButtonTemplate is mixed in so a secure click can use the item.
        local btn = CreateFrame("CheckButton", "DrievTrinketBtn"..which, f,
            "ActionButtonTemplate,SecureActionButtonTemplate")
        btn:SetSize(BTN_SIZE, BTN_SIZE)
        btn:SetPoint("TOPLEFT", f, "TOPLEFT",
            BTN_PAD + which * (BTN_SIZE + BTN_GAP), -BTN_PAD)
        btn:SetAttribute("type", "item")
        btn:SetAttribute("slot", slot)
        -- Register both click phases; the CVar decides which one actually fires
        -- the protected use. See applyClickTrigger for the full reasoning.
        btn:RegisterForClicks("LeftButtonDown", "LeftButtonUp")

        styleSlotButton(btn, BTN_SIZE)

        local icon = btn.icon
        icon:SetAllPoints(btn)
        btn.Icon = icon     -- Masque

        local cd = btn.cooldown
        cd:SetDrawBling(false)
        cd:SetSwipeColor(0, 0, 0, 0.8)   -- matches TrinketMenu's cooldown swipe
        btn.Cooldown = cd   -- Masque

        -- Click-feedback flash, driven manually via SetChecked in PostClick. The
        -- SetChecked(false) there before re-showing avoids the native glow sticking
        -- after a secure item click.
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
            -- Cancel any pending hide and restart the 0.5s countdown, so spamming the button
            -- keeps the flash solid rather than flickering between clicks.
            if self.checkedTimer then self.checkedTimer:Cancel() end
            self.checkedTimer = C_Timer.NewTimer(0.5, function()
                self.checkedTimer = nil
                self:SetChecked(false)
            end)
        end)

        -- <modifier>+MOUSE-click does a special action instead of firing the trinket
        -- (the secure use is blanked for that click by SECURE_ARM_MODS):
        --   • swap modifier   → swap the top/bottom slot trinkets
        --   • soft-queue mod  → soft-queue this slot's worn trinket (toggle)
        -- Swap is checked first, so it wins if both are held.
        btn:SetScript("PreClick", function(self, _, down)
            -- The button registers both phases, so PreClick fires twice per press. These
            -- side effects must run once, so act on the down phase only; `down == false` is
            -- the up event. A nil `down` from a legacy path still runs.
            if down == false then return end
            local d = getData()

            -- Mouse only, unless opted in: the keybind is a CLICK binding on this very
            -- button, so a modifier held while pressing is indistinguishable from a
            -- modifier+click except by cursor position. Same test the secure snippet uses.
            if not (d.modKeybindActions or self:IsMouseOver()) then return end

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

        -- Arm/disarm the modifier suppression around each click. Wrapped after
        -- both scripts are set, since SecureHandlerWrapScript captures whatever
        -- handler is installed at wrap time — a later SetScript on either would
        -- drop the wrapper. The button doubles as its own snippet header, so
        -- `self` inside the snippets is this button.
        SecureHandlerWrapScript(btn, "PreClick",  btn, SECURE_ARM_MODS)
        SecureHandlerWrapScript(btn, "PostClick", btn, SECURE_DISARM_MODS)

        -- Keybind text. Created bare and styled by applyHotkeyStyle, which is
        -- the one place the font block is read — so the button and a later
        -- settings change take the same path.
        btn.hotKey = btn:CreateFontString(nil, "OVERLAY")
        applyHotkeyStyle(btn)

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

-- Masque is a shared LibStub library: ANY addon embedding it makes
-- LibStub("Masque") available and keeps applying whichever skin was last chosen
-- for a group name. Registration is unconditional — the buttons already carry
-- the baked Blizzard Classic look, so a user who doesn't want skinning disables
-- our group in Masque's own options.
local function initMasque()
    local MSQ = LibStub and LibStub("Masque", true)
    if not MSQ then return end
    if addon.Trinkets and addon.Trinkets._masqueGroup then return end
    local group = MSQ:Group("Driev's Essentials", "Trinkets")
    -- Buttons currently wearing the ElvUI skin stay OUT of the Masque group:
    -- Masque would immediately reskin its regions over the ElvUI template
    -- (see refreshElvUISkin, which also moves buttons in/out of the group
    -- when the "Skin with ElvUI" toggle changes).
    -- Register display buttons (display frame created before initMasque is called)
    if displayFrame then
        for which = 0, 1 do
            local btn = displayFrame["t"..which]
            if not btn._elvuiSkinned then
                group:AddButton(btn, displayButtonData(btn))
            end
        end
    end
    -- Force-create menu frame and register its buttons
    local m = getOrCreateMenu()
    for i = 1, MAX_MENU do
        local mb = m["mb"..i]
        if not mb._elvuiSkinned then
            group:AddButton(mb, menuButtonData(mb))
        end
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
    -- Frames are only created once, so a profile switch has to re-assert the
    -- new profile's strata/level on the existing ones.
    applyFrameLayers()
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

    -- Dragging a docked menu around the display picks the snap corner (shown live by
    -- a corner marker) and re-docks on release; undocked it free-floats. A plain
    -- click opens the X/Y editor instead, and committing a position there
    -- force-undocks, since a docked spot is derived rather than a free x/y.
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
            -- StopMovingOrSizing() above replaced the docked menu's multi-point anchor with
            -- a single raw one even though it barely moved, so restore the dock anchor
            -- before (maybe) opening the editor — a plain click mustn't silently undock.
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
    -- Move Mode raises both frames above everything so their edit boxes stay
    -- grabbable; restore whatever the user configured (see applyFrameLayers).
    applyFrameLayer(f, getData().displayStrata, getData().displayLevel)
    addon.HideEditBox(f)
    f:SetScript("OnMouseDown", nil)
    f:SetScript("OnMouseUp",   nil)
    f:SetScript("OnUpdate",    nil)

    hideDockIndicator()
    if menuFrame then
        applyFrameLayer(menuFrame, getData().menuStrata, getData().menuLevel)
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
        -- Native ElvUI skin support. ShadowElvUI is a fork keeping ElvUI's engine API
        -- but renaming the global, hence the fallback. The engine table only exists once
        -- the addon has loaded, so its presence IS the load check — which avoids
        -- IsAddOnLoaded, removed as a global in Classic Era 1.15.9.
        local engine = ElvUI or ShadowElvUI
        if type(engine) == "table" then
            setElvUIEngine((unpack(engine)))
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        applyVisibility()   -- creates the frame, applies scale + saved position
        populateQueueSorts()
        -- Only register Masque once the display exists: if init ran mid-combat the
        -- display is deferred, and initMasque would create its group with no buttons and
        -- then refuse to re-run.
        if displayFrame then initMasque() end
        -- Pre-warm item info for bag trinkets so first hover doesn't stall
        C_Timer.After(0.5, scanBags)
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        -- Updates the icon/cooldown instantly and schedules the (debounced,
        -- user-configured-delay) bag-menu rebuild itself — see updateWornIcons().
        updateWornIcons()
        -- If a slot's queued trinket is now the one worn there, the entry is fulfilled —
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
        -- arg1 = encounterID, arg2 = encounterName. The name is kept for the HP
        -- triggers, which have no boss unit token on Classic Era.
        currentEncounterID   = arg1
        currentEncounterName = arg2
        encounterQueued      = false
        encGen = encGen + 1
        maybeQueueEncounter("encounter")
    elseif event == "ENCOUNTER_END" then
        -- Give the Encounter End trigger its shot while the encounter is still
        -- the current one, then tear the state down.
        maybeQueueEncounter("end")
        currentEncounterID   = nil
        currentEncounterName = nil
        encounterQueued      = false
        encGen = encGen + 1
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Entered combat: if we're mid-encounter with a config, queue now.
        maybeQueueEncounter("combat")
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
        -- Left combat: invalidate any in-flight safeguard delay, so a brief combat drop
        -- restarts the full duration rather than letting a stale timer fire when combat
        -- merely resumes.
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
            -- Combat can resume during this delay. The pickup calls are protected and throw
            -- ADDON_ACTION_BLOCKED in lockdown, so re-queue rather than fire blind.
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

-- A once-per-second poll, so a ticker rather than an OnUpdate firing ~60x a
-- second just to add up `elapsed` and return early.
C_Timer.NewTicker(1.0, function()
    processSoftQueue(0)
    processSoftQueue(1)
    processQueue(0)
    processQueue(1)
    tickEncounterHealth()
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
    applyFrameLayers   = applyFrameLayers,
    STRATA_OPTS        = STRATA_OPTS,
    -- Read by UI.EnterMoveMode to skip a disabled module — with the display hidden
    -- its edit box would float over nothing.
    isEnabled          = function() return getData().enabled and true or false end,
}

