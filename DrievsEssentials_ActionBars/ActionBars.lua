-- Driev's Essentials — Action Bars module.
--
-- A from-scratch custom action bar engine, built on LibActionButton-1.0 (the
-- same secure-button library Bartender4/ElvUI use). It hides Blizzard's default
-- bars (see HideBlizzard.lua) and replaces them with our own bars, which — unlike
-- Blizzard's native Classic bars — expose per-bar scale, icon size, alpha, rows,
-- growth direction, flyout direction, click-through, and mouseover keybinding.
--
-- Bars come in five "kinds", all sharing the same position/scale/alpha/edit-mode
-- machinery and differing only in how their buttons are made and laid out:
--   action → 10 LibActionButton bars (Action Bar 1-10)
--   stance → the shapeshift/stance bar (secure StanceButtonTemplate buttons)
--   pet    → the pet bar (secure PetActionButtonTemplate buttons)
--   micro  → the micro menu (Blizzard's micro buttons, reparented)
--   bag    → the bag bar (backpack + bag slots, reparented)
--
-- This deliberately does NOT copy Bartender4's own source (which is
-- "All rights reserved" and deeply coupled to Ace3); it reimplements the same
-- ideas against the open libraries, in this addon's existing style.
local addon = _G.DrievEssentials
if not addon then return end

local UI     = addon.UI
local LAB    = LibStub("LibActionButton-1.0")
local KB     = LibStub("LibKeyBound-1.0", true)
-- Optional: when Masque is installed, each bar registers its buttons with a
-- per-bar Masque group so the user can skin them from Masque's own UI. Absent
-- Masque, the buttons keep their default (Blizzard) look. Declared as
-- ## OptionalDeps in the .toc.
local Masque = LibStub("Masque", true)
-- LibSharedMedia (bundled by the core addon, which loads first) supplies the
-- font list for the keybind-text font picker.
local LSM = LibStub("LibSharedMedia-3.0", true)

-- Abbreviate mouse buttons as M3 / SM4 rather than B3 / SB4 in keybind text.
-- LibKeyBound's ToShortKey (which LibActionButton's hotkey display uses) maps
-- BUTTONn through its own locale table; we retint those entries to "M". The
-- table is a plain (writable) global that ToShortKey reads live, so this needs
-- no library edit. NOTE: LibKeyBound is a shared library, so this also changes
-- the abbreviation for any other addon using this same copy of it.
if KB and KB.L then
    for i = 1, 31 do
        if KB.L["Button" .. i] then KB.L["Button" .. i] = "M" .. i end
    end
end

local InCombatLockdown = InCombatLockdown
local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max

local NUM_BUTTONS   = 12   -- WoW action bars are always 12 slots max
local DEFAULT_SIZE  = 36   -- Classic default button size (px)
local BTN_PREFIX    = "DrievABarButton"   -- distinct from BT4's BT4Button so both can coexist

-- ── Bar definitions ──────────────────────────────────────────────────────────
-- Ten action bars (Bar 1-10) plus the stance / micro-menu / bag bars. For action
-- bars `page` is the action-page offset: bar N owns slots (N-1)*12+1 .. N*12
-- (Bar 1 → 1-12 … Bar 10 → 109-120). Bar 1 follows stance/bonusbar/possess
-- paging via a secure state driver; bars 2-10 are static. Defaults enable Bar 1
-- plus bars 5 & 6 (the old Bottom Right / Bottom Left slots), and all three
-- special bars.
local NUM_BARS = 10
local BARS = {}        -- ordered list of every bar def (used by UI + refresh)
local BAR_BY_KEY = {}
for i = 1, NUM_BARS do
    BARS[i] = {
        key            = "bar" .. i,
        label          = "Action Bar " .. i,
        kind           = "action",
        page           = i,
        paged          = (i == 1),
        defaultEnabled = (i == 1 or i == 5 or i == 6),
    }
end
BARS[#BARS + 1] = { key = "stance", label = "Stance Bar", kind = "stance", defaultEnabled = true }
BARS[#BARS + 1] = { key = "pet",    label = "Pet Bar",    kind = "pet",    defaultEnabled = true }
BARS[#BARS + 1] = { key = "micro",  label = "Micro Menu", kind = "micro",  defaultEnabled = true }
BARS[#BARS + 1] = { key = "bag",    label = "Bag Bar",    kind = "bag",    defaultEnabled = true }
for _, def in ipairs(BARS) do BAR_BY_KEY[def.key] = def end

-- Per-bar defaults registered into core's profile. Action bars carry the full
-- knob set; the special bars omit the ones that don't apply (button count is
-- fixed/dynamic, icon size and flyout are action-only).
local function barDefault(def)
    local d = {
        enabled       = def.defaultEnabled,
        rows          = 1,
        scale         = 1.0,
        padding       = 4,
        alpha         = 1.0,
        orientation   = "HORIZONTAL", -- HORIZONTAL (fill →, wrap into rows) | VERTICAL (fill ↓, wrap into columns)
        growthH       = "RIGHT",  -- RIGHT | LEFT
        growthV       = "DOWN",   -- DOWN | UP
        clickThrough  = false,
        mouseover     = false,    -- only show the bar while hovered
        mouseoverFade = false,    -- smoothly fade in/out on hover instead of snapping
        -- px/py absent until first positioned; initialPosition() fills them in.
    }
    if def.kind == "action" then
        d.buttons    = NUM_BUTTONS
        d.buttonSize = DEFAULT_SIZE
        d.flyout     = "UP"      -- UP | DOWN | LEFT | RIGHT
        d.useGeneral = true      -- apply the General tab's keybind-text settings
    end
    return d
end

do
    local defaults = {}
    for _, def in ipairs(BARS) do
        defaults[def.key] = barDefault(def)
    end
    -- Master switch for the whole module — off by default, so a fresh install
    -- leaves Blizzard's own action bars untouched until explicitly turned on.
    -- Enabling takes effect immediately; disabling needs a /reload to restore
    -- Blizzard's bars, since HideBlizzardActionBars' reparenting isn't reversed
    -- (see refreshAll below and the checkbox in ActionBarsUI.lua).
    defaults.enabled = false
    -- Addon-wide (not per-bar) setting: which modifier you hold to drag an
    -- ability off a button without the on-keydown press activating it. Lives
    -- alongside the bar keys in the actionBars table; getData() only ever reads
    -- real bar keys, so this extra key is inert to it.
    defaults.dragModifier = "SHIFT"   -- SHIFT | CTRL | ALT
    -- ── General (addon-wide) keybind-text settings, applied to any action bar
    -- whose per-bar `useGeneral` is on. ──
    -- false → whole button reddens when out of range (Blizzard default);
    -- true  → only the keybind (hotkey) text reddens instead.
    defaults.outOfRangeHotkey = false
    -- Keybind-text font: false = game default; otherwise a LibSharedMedia name.
    defaults.keybindFont    = false
    defaults.keybindFontSize = 13   -- hotkey text size (LAB classic default)
    defaults.keybindOffsetX  = -2   -- hotkey text offset from the button's TOPRIGHT
    defaults.keybindOffsetY  = -4
    addon.RegisterDefaults("actionBars", defaults)
end

local function isReady()
    return addon.db ~= nil and addon.db.settings ~= nil
end

-- The addon-wide actionBars settings table (holds dragModifier + the per-bar
-- sub-tables). Distinct from getData(key), which returns one bar's sub-table.
local function getGlobalData()
    addon.db.settings.actionBars = addon.db.settings.actionBars or {}
    return addon.db.settings.actionBars
end

local function getData(key)
    local d = getGlobalData()
    if not d[key] then d[key] = barDefault(BAR_BY_KEY[key]) end
    return d[key]
end

-- Fixed cell size (px) used to space buttons for the non-action bars. Their
-- buttons keep their native art size (we don't resize them), so these just
-- describe the grid footprint.
local CELL = {
    stance = { 30, 30 },
    pet    = { 30, 30 },
    micro  = { 32, 40 },
    bag    = { 37, 37 },
}

-- ── Bar objects ──────────────────────────────────────────────────────────────
-- bars[key] = { def, header (secure), buttons = {}, overlay, mover, MasqueGroup }
local bars = {}

-- Deferred work when we hit combat lockdown (secure frames can't be shown/hidden/
-- moved/rebuilt in combat). Flushed on PLAYER_REGEN_ENABLED.
local pendingRefresh = false

-- ── Layout ───────────────────────────────────────────────────────────────────
-- Positions the shown buttons in a rows×columns block anchored at the header's
-- TOPLEFT. Growth direction only reorders buttons within that fixed block, so
-- the bar's saved position stays put regardless of growth. Works for every bar
-- kind: action bars use their square icon-size and are resized; the special bars
-- keep their native art size and only get positioned.
local function layoutBar(bar)
    local d    = getData(bar.def.key)
    local kind = bar.def.kind

    local list, cw, ch, resize, showEach
    if kind == "action" then
        local shown = min(d.buttons or NUM_BUTTONS, #bar.buttons)
        list = {}
        for i = 1, shown do list[i] = bar.buttons[i] end
        for i = shown + 1, #bar.buttons do bar.buttons[i]:Hide() end
        cw, ch, resize, showEach = d.buttonSize or DEFAULT_SIZE, d.buttonSize or DEFAULT_SIZE, true, true
    elseif kind == "micro" or kind == "bag" then
        -- Reparented Blizzard buttons: lay out only the ones currently shown, so
        -- Blizzard-hidden buttons (e.g. Store / Help / LFG when unavailable)
        -- neither leave a gap nor get force-shown by us.
        list = {}
        for _, b in ipairs(bar.buttons) do
            if b:IsShown() then list[#list + 1] = b end
        end
        local c = CELL[kind] or { DEFAULT_SIZE, DEFAULT_SIZE }
        cw, ch, resize, showEach = c[1], c[2], false, false
    else
        -- stance / pet: our own buttons, we manage their visibility.
        list = bar.buttons
        local c = CELL[kind] or { DEFAULT_SIZE, DEFAULT_SIZE }
        cw, ch, resize, showEach = c[1], c[2], false, true
    end

    local shown = #list
    if shown == 0 then
        bar.header:SetSize(cw, ch)
        return
    end

    local pad      = d.padding or 4
    local lines    = max(1, min(d.rows or 1, shown))
    local vertical = (d.orientation == "VERTICAL")

    -- `lines` counts along the wrap axis: it's rows when building horizontally
    -- (buttons fill left→right then wrap down), and columns when building
    -- vertically (buttons fill top→bottom then wrap across). `perLine` is how
    -- many buttons sit in each of those lines.
    local perLine = ceil(shown / lines)
    local numCols, numRows
    if vertical then
        numRows, numCols = perLine, ceil(shown / perLine)
    else
        numCols, numRows = perLine, ceil(shown / perLine)
    end

    bar.header:SetSize(numCols * cw + (numCols - 1) * pad,
                       numRows * ch + (numRows - 1) * pad)

    for i = 1, shown do
        local btn = list[i]
        local col, row
        if vertical then
            col, row = floor((i - 1) / perLine), (i - 1) % perLine
        else
            col, row = (i - 1) % perLine, floor((i - 1) / perLine)
        end
        if d.growthH == "LEFT" then col = numCols - 1 - col end
        if d.growthV == "UP"   then row = numRows - 1 - row end
        if resize then btn:SetSize(cw, ch) end
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", bar.header, "TOPLEFT", col * (cw + pad), -(row * (ch + pad)))
        if showEach then btn:Show() end
    end

    if bar.overlay then
        bar.overlay:ClearAllPoints()
        bar.overlay:SetAllPoints(bar.header)
    end
end

-- ── Action-button configuration ──────────────────────────────────────────────
-- The LibActionButton config table controls per-button appearance/behaviour.
-- keyBoundClickButton = "Keybind" mirrors BT4: keybinds are stored as
-- `CLICK <button>:Keybind` so a bound key triggers the ability without stealing
-- the left mouse button (which we keep for pickup/drag while unlocked).
local function buildButtonConfig(bar)
    local d = getData(bar.def.key)
    local cfg = {
        tooltip             = "enabled",
        showGrid            = true,   -- show empty slots so you can drag spells onto them
        colors              = { range = { 0.8, 0.1, 0.1 }, mana = { 0.5, 0.5, 1.0 } },
        hideElements        = { macro = false, hotkey = false, equipped = false, border = false },
        keyBoundTarget      = false,
        keyBoundClickButton = "Keybind",
        clickOnDown         = false,
        flyoutDirection     = d.flyout or "UP",
        outOfRangeColoring  = "button",   -- default: whole icon reddens out of range
    }
    -- When this bar opts into the General tab settings, apply its keybind-text
    -- font / size / position and out-of-range coloring. LAB merges partial config
    -- against its defaults, so unspecified sub-keys (flags, color, justifyH) stay
    -- default. When useGeneral is off, cfg has no `text` block → LAB defaults.
    if d.useGeneral ~= false then
        local g = getGlobalData()
        local fontPath = (g.keybindFont and LSM and LSM:Fetch("font", g.keybindFont, true)) or false
        cfg.outOfRangeColoring = g.outOfRangeHotkey and "hotkey" or "button"
        cfg.text = {
            hotkey = {
                font = { font = fontPath, size = g.keybindFontSize or 13 },
                position = {
                    anchor    = "TOPRIGHT",
                    relAnchor = "TOPRIGHT",
                    offsetX   = g.keybindOffsetX or -2,
                    offsetY   = g.keybindOffsetY or -4,
                },
            },
        }
    end
    return cfg
end

local function applyButtonConfig(bar)
    if bar.def.kind ~= "action" then return end
    local cfg = buildButtonConfig(bar)
    for _, btn in ipairs(bar.buttons) do
        btn:UpdateConfig(cfg)
    end
end

-- ── Paging ───────────────────────────────────────────────────────────────────
-- Every action bar can switch which action page it shows based on the player's
-- stance/form (configured in the "Paging" tab). Each button is told every page's
-- action slot up front (state p → slot (p-1)*12 + i) and a secure state driver
-- flips the header's state. The config maps stance index → page (or nil for "no
-- paging", which falls through to the bar's own default page). Bar 1 additionally
-- keeps Blizzard's action-bar-page + bonusbar/possess/vehicle paging *below* the
-- user's stance choices in priority, so druid/rogue forms and vehicle bars still
-- work while an explicit per-stance page always wins.
local POSSESS_SNIPPET = [[
    if newstate == "possess" then
        if HasVehicleActionBar and HasVehicleActionBar() then
            newstate = GetVehicleBarIndex()
        elseif HasOverrideActionBar and HasOverrideActionBar() then
            newstate = GetOverrideBarIndex()
        elseif HasTempShapeshiftActionBar and HasTempShapeshiftActionBar() then
            newstate = GetTempShapeshiftBarIndex()
        elseif HasBonusActionBar and HasBonusActionBar() then
            newstate = GetBonusBarIndex()
        else
            newstate = 12
        end
    end
    self:SetAttribute("state", newstate)
    control:ChildUpdate("state", newstate)
]]

local SIMPLE_SNIPPET = [[
    self:SetAttribute("state", newstate)
    control:ChildUpdate("state", newstate)
]]

-- Builds the state-driver string from the bar's per-stance paging config.
local function buildPagingDriver(bar)
    local d = getData(bar.def.key)
    local conds = {}
    -- User per-stance pages first (highest priority). Stance conditions are
    -- mutually exclusive, so pairs() order doesn't matter.
    if d.paging then
        for stanceIdx, page in pairs(d.paging) do
            if page and page >= 1 and page <= 10 then
                conds[#conds + 1] = ("[stance:%d]%d"):format(stanceIdx, page)
            end
        end
    end
    if bar.def.paged then
        conds[#conds + 1] = "[overridebar][possessbar][shapeshift]possess"
        conds[#conds + 1] = "[bar:2]2;[bar:3]3;[bar:4]4;[bar:5]5;[bar:6]6"
        conds[#conds + 1] = "[bonusbar:1]7;[bonusbar:2]8;[bonusbar:3]9;[bonusbar:4]10;[bonusbar:5]11"
    end
    conds[#conds + 1] = tostring(bar.def.page)   -- default = the bar's own page
    return table.concat(conds, ";")
end

-- (Re)registers the header's page state driver from the current config. Combat-
-- guarded (RegisterStateDriver can taint mid-combat).
local function refreshPagingDriver(bar)
    if InCombatLockdown() then return end
    UnregisterStateDriver(bar.header, "page")
    bar.header:SetAttribute("state-page", tostring(bar.def.page))
    RegisterStateDriver(bar.header, "page", buildPagingDriver(bar))
end

-- One-time paging setup: map every page's action slots onto the buttons, install
-- the state handler, and register the driver.
local function setupPaging(bar)
    for i, btn in ipairs(bar.buttons) do
        for p = 1, 14 do
            btn:SetState(p, "action", (p - 1) * NUM_BUTTONS + i)
        end
        btn:SetState(0, "action", (bar.def.page - 1) * NUM_BUTTONS + i)
    end
    bar.header:SetAttribute("_onstate-page", bar.def.paged and POSSESS_SNIPPET or SIMPLE_SNIPPET)
    refreshPagingDriver(bar)
end

local function createActionButtons(bar)
    local prefixBase = (bar.def.page - 1) * NUM_BUTTONS
    for i = 1, NUM_BUTTONS do
        if not bar.buttons[i] then
            -- Unique global name per absolute slot so keybinds map 1:1 and never
            -- collide between bars.
            local name = BTN_PREFIX .. (prefixBase + i)
            local btn  = LAB:CreateButton(prefixBase + i, name, bar.header, buildButtonConfig(bar))
            if bar.MasqueGroup then btn:AddToMasque(bar.MasqueGroup) end
            bar.buttons[i] = btn
        end
    end
end

-- ── Stance bar ───────────────────────────────────────────────────────────────
-- Own secure buttons from Blizzard's StanceButtonTemplate (the same approach
-- BT4 uses), driven by the shapeshift API. Blizzard's own stance bar is parked
-- on the hidden frame so it can't fight us.
local function updateStanceButton(btn)
    local id = btn:GetID()
    local texture, isActive, isCastable = GetShapeshiftFormInfo(id)
    if btn.icon then btn.icon:SetTexture(texture) end
    if btn.cooldown then
        local start, duration, enable = GetShapeshiftFormCooldown(id)
        CooldownFrame_Set(btn.cooldown, start, duration, enable)
    end
    btn:SetChecked(isActive and true or false)
    if btn.icon then
        if isCastable then btn.icon:SetVertexColor(1, 1, 1) else btn.icon:SetVertexColor(0.4, 0.4, 0.4) end
    end
end

local function createStanceButton(bar, id)
    local name = "DrievStanceButton" .. id
    local btn  = CreateFrame("CheckButton", name, bar.header, "StanceButtonTemplate")
    btn:SetID(id)
    btn.icon     = _G[name .. "Icon"]
    btn.cooldown = _G[name .. "Cooldown"]
    local nt = btn:GetNormalTexture()
    if nt then nt:SetTexture("") end
    -- 1.15.9 modernized templates add SlotBackground/SlotArt regions that render
    -- oversized when the button isn't Masque-skinned (see the same fix in the
    -- Trinkets module). Nil-checked no-ops if this template lacks them.
    if not bar.MasqueGroup then
        if btn.SlotBackground then btn.SlotBackground:Hide() end
        if btn.SlotArt        then btn.SlotArt:Hide()        end
    end
    if bar.MasqueGroup then
        btn.MasqueButtonData = { Button = btn }
        bar.MasqueGroup:AddButton(btn, btn.MasqueButtonData, "Action")
    end
    return btn
end

-- (Re)builds the ordered visible button list to match the current form count.
local function updateStanceButtons(bar)
    local n = GetNumShapeshiftForms() or 0
    bar._pool = bar._pool or {}
    for i = #bar._pool + 1, n do
        bar._pool[i] = createStanceButton(bar, i)
    end
    bar.buttons = {}
    for i = 1, n do
        bar.buttons[i] = bar._pool[i]
        updateStanceButton(bar._pool[i])
    end
    for i = n + 1, #bar._pool do bar._pool[i]:Hide() end
end

-- Maps the player's existing SHAPESHIFTBUTTON1..10 keybinds onto our buttons via
-- override bindings, so stance keybinds set in Blizzard's UI keep working.
local function reassignStanceBindings(bar)
    if InCombatLockdown() then return end
    ClearOverrideBindings(bar.header)
    for i, btn in ipairs(bar.buttons) do
        local cmd = ("SHAPESHIFTBUTTON%d"):format(i)
        for k = 1, select("#", GetBindingKey(cmd)) do
            local key = select(k, GetBindingKey(cmd))
            if key then SetOverrideBindingClick(bar.header, false, key, btn:GetName()) end
        end
    end
end

local function buildStanceBar(bar)
    -- Blizzard's stance bar is parked by HideBlizzardActionBars() (which always
    -- runs before this), via the same HideBase/isShownExternal-aware helper used
    -- for every other bar — a plain :Hide() here would leave it still tracked (and
    -- visible/selectable) by 1.15.9's Edit Mode.
    updateStanceButtons(bar)

    if not bar._eventFrame then
        local ef = CreateFrame("Frame")
        ef:RegisterEvent("UPDATE_SHAPESHIFT_FORMS")
        ef:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
        ef:RegisterEvent("UPDATE_SHAPESHIFT_COOLDOWN")
        ef:RegisterEvent("UPDATE_SHAPESHIFT_USABLE")
        ef:RegisterEvent("UPDATE_BINDINGS")
        ef:SetScript("OnEvent", function(_, ev)
            if InCombatLockdown() then pendingRefresh = true; return end
            if ev == "UPDATE_SHAPESHIFT_FORM" or ev == "UPDATE_SHAPESHIFT_COOLDOWN"
               or ev == "UPDATE_SHAPESHIFT_USABLE" then
                for _, b in ipairs(bar.buttons) do updateStanceButton(b) end
            else
                -- form count or bindings changed → rebuild + relayout + rebind
                updateStanceButtons(bar)
                layoutBar(bar)
                reassignStanceBindings(bar)
            end
        end)
        bar._eventFrame = ef
    end
end

-- ── Pet bar ──────────────────────────────────────────────────────────────────
-- Own secure buttons from Blizzard's PetActionButtonTemplate (the approach BT4
-- uses), driven by the pet API. Always 10 slots; empty slots are faded out with
-- SetAlpha (not Hide, which is protected in combat). The whole bar's visibility
-- follows pet presence through a secure [pet]show;hide state driver so it works
-- even when a pet is summoned mid-combat (see applyVisibility).
local function updatePetButton(btn)
    local id = btn.id
    local name, texture, isToken, isActive, autoCastAllowed, autoCastEnabled = GetPetActionInfo(id)
    if btn.icon then
        if texture then
            btn.icon:SetTexture(isToken and _G[texture] or texture)
            btn.icon:Show()
            btn.icon:SetDesaturated(not GetPetActionsUsable())
            btn:SetAlpha(1)
        else
            btn.icon:Hide()
            btn:SetAlpha(0)   -- fade empty slot (combat-safe, unlike Hide)
        end
    end
    btn:SetChecked(isActive and true or false)
    if btn.AutoCastable then btn.AutoCastable:SetShown(autoCastAllowed and true or false) end
    if btn.AutoCastShine and AutoCastShine_AutoCastStart then
        if autoCastEnabled then AutoCastShine_AutoCastStart(btn.AutoCastShine)
        else AutoCastShine_AutoCastStop(btn.AutoCastShine) end
    end
    if btn.cooldown then
        local start, duration, enable = GetPetActionCooldown(id)
        CooldownFrame_Set(btn.cooldown, start, duration, enable)
    end
end

local function createPetButton(bar, id)
    local name = "DrievPetButton" .. id
    local btn  = CreateFrame("CheckButton", name, bar.header, "PetActionButtonTemplate")
    btn:SetID(id)
    btn.id           = id
    -- The template exposes these as parentKeys, but fall back to global names in
    -- case a future client changes that.
    btn.icon         = btn.icon         or _G[name .. "Icon"]
    btn.cooldown     = btn.cooldown     or _G[name .. "Cooldown"]
    btn.AutoCastable = btn.AutoCastable or _G[name .. "AutoCastable"]
    btn.AutoCastShine= btn.AutoCastShine or _G[name .. "Shine"]
    -- We drive updates from our own event frame; silence the template's own.
    btn:UnregisterAllEvents()
    btn:SetScript("OnEvent", nil)
    -- 1.15.9 modernized templates add SlotBackground/SlotArt that render oversized
    -- without Masque (see the Trinkets module). Nil-checked no-ops if absent.
    if not bar.MasqueGroup then
        if btn.SlotBackground then btn.SlotBackground:Hide() end
        if btn.SlotArt        then btn.SlotArt:Hide()        end
    end
    -- Pick up / drop pet actions by dragging (out of combat only).
    btn:SetScript("OnDragStart", function(self)
        if not InCombatLockdown() then PickupPetAction(self.id); updatePetButton(self) end
    end)
    btn:SetScript("OnReceiveDrag", function(self)
        if not InCombatLockdown() and GetCursorInfo() == "petaction" then
            PickupPetAction(self.id); updatePetButton(self)
        end
    end)
    if bar.MasqueGroup then bar.MasqueGroup:AddButton(btn, nil, "Pet") end
    return btn
end

-- Maps the player's BONUSACTIONBUTTON1..10 keybinds onto our pet buttons via
-- override bindings, so pet keybinds set in Blizzard's UI keep working even
-- though the native pet bar is hidden.
local function reassignPetBindings(bar)
    if InCombatLockdown() then return end
    ClearOverrideBindings(bar.header)
    for i, btn in ipairs(bar.buttons) do
        local cmd = ("BONUSACTIONBUTTON%d"):format(i)
        for k = 1, select("#", GetBindingKey(cmd)) do
            local key = select(k, GetBindingKey(cmd))
            if key then SetOverrideBindingClick(bar.header, false, key, btn:GetName()) end
        end
    end
end

local function buildPetBar(bar)
    -- Blizzard's pet bar is parked by HideBlizzardActionBars() (see buildStanceBar
    -- above for why this can't be a local raw :Hide() call).
    bar.buttons = {}
    for i = 1, 10 do
        bar.buttons[i] = createPetButton(bar, i)
        updatePetButton(bar.buttons[i])
    end

    if not bar._eventFrame then
        local ef = CreateFrame("Frame")
        ef:RegisterEvent("PET_BAR_UPDATE")
        ef:RegisterEvent("PET_BAR_UPDATE_COOLDOWN")
        ef:RegisterEvent("PET_BAR_UPDATE_USABLE")
        ef:RegisterEvent("PET_UI_UPDATE")
        ef:RegisterEvent("UNIT_PET")
        ef:RegisterEvent("PLAYER_CONTROL_LOST")
        ef:RegisterEvent("PLAYER_CONTROL_GAINED")
        ef:RegisterEvent("PLAYER_TARGET_CHANGED")
        ef:RegisterEvent("UPDATE_BINDINGS")
        ef:SetScript("OnEvent", function(_, ev)
            if ev == "UPDATE_BINDINGS" then
                if not InCombatLockdown() then reassignPetBindings(bar) end
                return
            end
            for _, b in ipairs(bar.buttons) do updatePetButton(b) end
        end)
        bar._eventFrame = ef
    end
end

-- ── Micro menu ───────────────────────────────────────────────────────────────
-- The micro buttons, reparented onto our header. We take Blizzard's own ordered
-- MICRO_BUTTONS global as the authoritative set for this exact client — that
-- automatically includes whatever exists (Guilds & Communities, LFG, PvP, …)
-- without us guessing per game version, which is how the Guild button used to go
-- missing. The fallback list is only used if that global is somehow absent.
local MICRO_FALLBACK = {
    "CharacterMicroButton", "SpellbookMicroButton", "TalentMicroButton",
    "AchievementMicroButton", "QuestLogMicroButton", "GuildMicroButton",
    "SocialsMicroButton", "PVPMicroButton", "LFGMicroButton",
    "WorldMapMicroButton", "MainMenuMicroButton", "HelpMicroButton",
    "StoreMicroButton",
}

local function collectMicroButtons(bar)
    local names = _G.MICRO_BUTTONS or MICRO_FALLBACK
    bar.buttons = {}
    for _, name in ipairs(names) do
        local b = _G[name]
        if b then bar.buttons[#bar.buttons + 1] = b end
    end
end

local function buildMicroBar(bar)
    collectMicroButtons(bar)

    -- Modern Classic UI (1.15.9+) owns the micro buttons through
    -- UpdateMicroButtonsParent and its Edit Mode. Pointing that at our header —
    -- and re-asserting it if Blizzard tries to take them back — is what actually
    -- removes them (Guild included) from Blizzard's Edit Mode; a plain SetParent
    -- gets reverted the next time Blizzard re-parents. Older UI has no such
    -- function, so we reparent by hand instead.
    if _G.UpdateMicroButtonsParent then
        UpdateMicroButtonsParent(bar.header)
    else
        for _, b in ipairs(bar.buttons) do
            b:SetParent(bar.header)
            b:SetFrameLevel(bar.header:GetFrameLevel() + 1)
        end
    end

    if not bar._microHooked then
        bar._microHooked = true
        if _G.UpdateMicroButtonsParent then
            hooksecurefunc("UpdateMicroButtonsParent", function(parent)
                if parent ~= bar.header and not InCombatLockdown()
                   and getData(bar.def.key).enabled ~= false then
                    UpdateMicroButtonsParent(bar.header)
                end
            end)
        end
        -- Re-apply our layout whenever Blizzard repositions the buttons.
        if _G.UpdateMicroButtons then
            hooksecurefunc("UpdateMicroButtons", function()
                local b = bars[bar.def.key]
                if b and getData(bar.def.key).enabled ~= false and not InCombatLockdown() then
                    layoutBar(b)
                end
            end)
        end
    end
end

-- ── Bag bar ──────────────────────────────────────────────────────────────────
-- Backpack + bag slots (+ keyring on Era), reparented onto our header. These are
-- plain buttons (not protected), so nothing here needs a combat guard beyond the
-- shared layout guard.
local function buildBagBar(bar)
    bar.buttons = {}
    local order = {}
    if _G.KeyRingButton then order[#order + 1] = "KeyRingButton" end
    order[#order + 1] = "CharacterBag3Slot"
    order[#order + 1] = "CharacterBag2Slot"
    order[#order + 1] = "CharacterBag1Slot"
    order[#order + 1] = "CharacterBag0Slot"
    order[#order + 1] = "MainMenuBarBackpackButton"

    for _, name in ipairs(order) do
        local b = _G[name]
        if b then
            if name == "KeyRingButton" then
                -- 1.15.9's KeyRingButton has an OnShow handler (Blizzard's
                -- Keyring.lua) that errors when the button is shown outside its
                -- own bar. Showing our bag header (e.g. entering Edit Mode)
                -- triggered it. Clearing OnShow is exactly what BT4's
                -- BagBarClassic does; the click behaviour is unaffected.
                b:SetScript("OnShow", nil)
            end
            b:SetParent(bar.header)
            bar.buttons[#bar.buttons + 1] = b
            if bar.MasqueGroup and name ~= "KeyRingButton" and not b.DrievMasqueData then
                b.DrievMasqueData = { Button = b, Icon = _G[name .. "IconTexture"] }
                bar.MasqueGroup:AddButton(b, b.DrievMasqueData, "Item")
            end
        end
    end
end

-- ── Bar creation dispatch ────────────────────────────────────────────────────
local function createBar(def)
    if bars[def.key] then return bars[def.key] end

    local header = CreateFrame("Frame", "DrievActionBar_" .. def.key, UIParent, "SecureHandlerStateTemplate")
    header:SetMovable(true)
    header:SetFrameStrata("MEDIUM")
    header:SetSize(DEFAULT_SIZE, DEFAULT_SIZE)

    local bar = { def = def, header = header, buttons = {} }
    bars[def.key] = bar

    -- Per-bar Masque group (label = the bar name in Masque; def.key is the stable
    -- static id). Created before the buttons so creators can register each one.
    if Masque then
        bar.MasqueGroup = Masque:Group("Driev's Essentials", def.label, def.key)
    end

    local kind = def.kind
    if kind == "action" then
        createActionButtons(bar)
        setupPaging(bar)
    elseif kind == "stance" then
        buildStanceBar(bar)
    elseif kind == "pet" then
        buildPetBar(bar)
    elseif kind == "micro" then
        buildMicroBar(bar)
    elseif kind == "bag" then
        buildBagBar(bar)
    end

    return bar
end

-- ── Position ─────────────────────────────────────────────────────────────────
-- TOPLEFT-from-UIParent-BOTTOMLEFT convention, matching every other movable in
-- this addon (TTK, RaidFrames, chat panels).
local function initialPosition(bar)
    local d = getData(bar.def.key)
    if d.px and d.py then return end
    local idx = 0
    for i, def in ipairs(BARS) do if def.key == bar.def.key then idx = i - 1 end end
    d.px = (UIParent:GetWidth() / 2) - 250
    d.py = 200 + idx * (DEFAULT_SIZE + 8)
end

local function applyPosition(bar)
    if InCombatLockdown() then return end
    local d = getData(bar.def.key)
    if not (d.px and d.py) then initialPosition(bar) end
    bar.header:ClearAllPoints()
    bar.header:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", d.px, d.py)
end

local function savePosition(bar)
    local d = getData(bar.def.key)
    local x, y = bar.header:GetLeft(), bar.header:GetTop()
    if x and y then d.px, d.py = x, y end
    applyPosition(bar)
end

-- ── Appearance appliers ──────────────────────────────────────────────────────
local function applyScale(bar)
    bar.header:SetScale(getData(bar.def.key).scale or 1)
end

local function applyAlpha(bar)
    bar.header:SetAlpha(getData(bar.def.key).alpha or 1)
end

-- ── Mouseover visibility ─────────────────────────────────────────────────────
-- When enabled, the bar sits at 0 alpha until the cursor is over it (or over a
-- spell flyout it spawned), then rises to its configured alpha — optionally with
-- a smooth fade. This is pure SetAlpha (never Show/Hide), so it's combat-safe and
-- never touches the secure state. A 0-alpha frame still hit-tests, which is what
-- lets the hover be detected in the first place. `_moFrame` is a plain (non-
-- secure) driver frame that only runs its OnUpdate while mouseover is on.
local MO_FADE_RATE = 4   -- alpha per second while fading (~0.25s for a full fade)

local function barHovered(bar)
    if MouseIsOver(bar.header) then return true end
    -- A flyout (e.g. a mage teleport flyout) opened from one of this bar's
    -- buttons extends outside the header; treat hovering it as hovering the bar.
    local labFlyout = LAB and LAB.GetSpellFlyoutFrame and LAB:GetSpellFlyoutFrame()
    if labFlyout and labFlyout:IsShown() then
        local p = labFlyout:GetParent()
        if p and p:GetParent() == bar.header and MouseIsOver(labFlyout) then return true end
    end
    if SpellFlyout and SpellFlyout:IsShown() then
        local p = SpellFlyout:GetParent()
        if p and p:GetParent() == bar.header and MouseIsOver(SpellFlyout) then return true end
    end
    return false
end

local function mouseoverTarget(bar)
    local d = getData(bar.def.key)
    if not d.mouseover then return d.alpha or 1 end
    return barHovered(bar) and (d.alpha or 1) or 0
end

local function applyMouseover(bar)
    local d = getData(bar.def.key)
    if d.mouseover then
        if not bar._moFrame then bar._moFrame = CreateFrame("Frame") end
        bar._moFrame:SetScript("OnUpdate", function(_, elapsed)
            local target = mouseoverTarget(bar)
            if getData(bar.def.key).mouseoverFade then
                local cur = bar.header:GetAlpha()
                if cur < target then
                    bar.header:SetAlpha(math.min(target, cur + MO_FADE_RATE * elapsed))
                elseif cur > target then
                    bar.header:SetAlpha(math.max(target, cur - MO_FADE_RATE * elapsed))
                end
            else
                bar.header:SetAlpha(target)
            end
        end)
        -- Snap to the current target now so there's no fade-from-full flash when
        -- the option is first switched on / at login.
        bar.header:SetAlpha(mouseoverTarget(bar))
    else
        if bar._moFrame then bar._moFrame:SetScript("OnUpdate", nil) end
        bar.header:SetAlpha(d.alpha or 1)
    end
end

local function applyClickThrough(bar)
    local on = getData(bar.def.key).clickThrough and true or false
    for _, btn in ipairs(bar.buttons) do
        btn:EnableMouse(not on)
    end
end

local function applyVisibility(bar)
    if InCombatLockdown() then pendingRefresh = true; return end
    local enabled = getData(bar.def.key).enabled ~= false

    -- The pet bar's visibility follows pet presence via a secure state driver, so
    -- it can show/hide correctly when a pet is (un)summoned in combat.
    if bar.def.kind == "pet" then
        UnregisterStateDriver(bar.header, "visibility")
        if enabled then
            RegisterStateDriver(bar.header, "visibility", "[pet]show;hide")
        else
            bar.header:Hide()
        end
        return
    end

    local show = enabled
    -- A formless class (mage, warlock, …) has no stance buttons — don't show an
    -- empty stance bar box.
    if bar.def.kind == "stance" and #bar.buttons == 0 then show = false end
    bar.header:SetShown(show)
end

-- Full refresh of one bar. Button creation is one-time (in createBar); this
-- re-derives everything else from the saved config.
local function applyBar(bar)
    if InCombatLockdown() then pendingRefresh = true; return end
    local kind = bar.def.kind
    if kind == "action" then
        applyButtonConfig(bar)
        refreshPagingDriver(bar)
    elseif kind == "stance" then
        updateStanceButtons(bar)
        reassignStanceBindings(bar)
    elseif kind == "pet" then
        for _, btn in ipairs(bar.buttons) do updatePetButton(btn) end
        reassignPetBindings(bar)
    end
    layoutBar(bar)
    applyScale(bar)
    applyAlpha(bar)
    applyClickThrough(bar)
    applyPosition(bar)
    applyVisibility(bar)
    applyMouseover(bar)
    if kind == "action" then
        for _, btn in ipairs(bar.buttons) do btn:UpdateAction() end
    end
end

-- ── Move mode overlay (Bartender-style green highlight) ──────────────────────
local WHITE = "Interface\\Buttons\\WHITE8x8"

-- ── Center snap guide ────────────────────────────────────────────────────────
-- A vertical guide down the screen's horizontal centre that bars snap to while
-- being dragged in edit mode, so a bar can be centred horizontally. The line
-- stays hidden until a bar is actively snapped to it. All drag math works in the
-- header's own coordinate space so the per-bar Scale never skews where the
-- centre is (screen centre in bar-local units = GetScreenWidth()/(2*headerScale)).
local SNAP_PX = 15
local centerLine

local function getCenterLine()
    if centerLine then return centerLine end
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("TOOLTIP")
    f:SetPoint("TOP",    UIParent, "TOP",    0, 0)
    f:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 0)
    f:SetWidth(1)
    local tex = f:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints(f)
    tex:SetTexture(WHITE)
    tex:SetVertexColor(0.15, 0.85, 0.25, 0.6)
    f:Hide()
    centerLine = f
    return f
end

local function dragUpdate(bar)
    if InCombatLockdown() then
        if bar.overlay then bar.overlay:SetScript("OnUpdate", nil) end
        return
    end
    local es = bar.header:GetEffectiveScale()
    local mx, my = GetCursorPosition()
    local nx = bar._startX + (mx / es - bar._grabX)
    local ny = bar._startY + (my / es - bar._grabY)

    local centerX   = GetScreenWidth() / (2 * bar.header:GetScale())   -- bar-local units
    local barCenter = nx + bar.header:GetWidth() / 2
    if math.abs(barCenter - centerX) <= (SNAP_PX / es) then
        nx = centerX - bar.header:GetWidth() / 2
        getCenterLine():Show()
    elseif centerLine then
        centerLine:Hide()
    end

    bar.header:ClearAllPoints()
    bar.header:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", nx, ny)
    local d = getData(bar.def.key)
    d.px, d.py = nx, ny
end

local function getOrCreateOverlay(bar)
    if bar.overlay then return bar.overlay end
    local o = CreateFrame("Button", nil, bar.header, "BackdropTemplate")
    o:SetAllPoints(bar.header)
    o:SetFrameStrata("DIALOG")
    o:SetFrameLevel(bar.header:GetFrameLevel() + 10)
    o:EnableMouse(true)
    o:RegisterForDrag("LeftButton")
    o:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    o:SetBackdropColor(0.15, 0.85, 0.25, 0.35)
    o:SetBackdropBorderColor(0.15, 0.85, 0.25, 1)

    local label = o:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("CENTER")
    label:SetText(bar.def.label)
    label:SetTextColor(1, 1, 1)

    -- Manual drag (not StartMoving) so we can override X to snap to the screen
    -- centre; StartMoving would fight any SetPoint we make mid-drag.
    o:SetScript("OnDragStart", function()
        if InCombatLockdown() then return end
        bar._moving = true
        local es = bar.header:GetEffectiveScale()
        local mx, my = GetCursorPosition()
        bar._grabX, bar._grabY = mx / es, my / es
        bar._startX = bar.header:GetLeft() or getData(bar.def.key).px or 0
        bar._startY = bar.header:GetTop()  or getData(bar.def.key).py or 0
        o:SetScript("OnUpdate", function() dragUpdate(bar) end)
    end)
    o:SetScript("OnDragStop", function()
        o:SetScript("OnUpdate", nil)
        bar._moving = false
        if centerLine then centerLine:Hide() end
        savePosition(bar)
    end)
    o:SetScript("OnClick", function()
        if bar._moving then return end
        if UI and UI.OpenPositionEditor then
            UI.OpenPositionEditor(bar.mover, o)
        end
    end)
    o:Hide()
    bar.overlay = o
    return o
end

-- ── Mover interface (consumed by the addon's Edit Mode) ──────────────────────
local function makeMover(bar)
    local mover = {}
    mover.label = bar.def.label
    function mover.getFrame() return bar.header end
    function mover.applyVisibility() applyVisibility(bar) end
    function mover.enterMoveMode()
        if InCombatLockdown() then return end
        -- Suspend mouseover fading and force the bar fully visible while editing,
        -- otherwise a mouseover bar sits at 0 alpha (dragging an invisible bar,
        -- and the overlay — a child of the header — would be invisible too).
        if bar._moFrame then bar._moFrame:SetScript("OnUpdate", nil) end
        bar.header:SetAlpha(1)
        local o = getOrCreateOverlay(bar)
        o:ClearAllPoints(); o:SetAllPoints(bar.header)
        o:Show()
    end
    function mover.leaveMoveMode()
        if bar.overlay then bar.overlay:Hide() end
        applyMouseover(bar)   -- restore mouseover fading / normal alpha
    end
    function mover.savePosition() savePosition(bar) end
    function mover.getPosition()
        return bar.header:GetLeft() or 0, bar.header:GetTop() or 0
    end
    function mover.setPosition(x, y)
        local d = getData(bar.def.key)
        d.px, d.py = x, y
        applyPosition(bar)
    end
    return mover
end

-- ── Keybind (mouseover) mode ─────────────────────────────────────────────────
-- LibActionButton already calls LibKeyBound:Set(self) on OnEnter and implements
-- the whole LibKeyBound button API, so "keybind mode" is just toggling the
-- library. (Applies to the action bars; stance/bag/micro use their native
-- Blizzard keybinds.)
local keybindActive = false
local keybindChangedCb   -- set by the settings UI to refresh its toggle button

-- LibKeyBound:IsShown() is the source of truth. Sync our cached flag to it and
-- notify the UI. This runs from our own toggle AND from LibKeyBound's own
-- enable/disable events — the latter is what catches the user closing keybind
-- mode via the library's "Okay" dialog (or combat auto-disabling it), which our
-- button's OnClick never sees, leaving it stuck showing "ON".
local function syncKeybindState()
    keybindActive = (KB and KB:IsShown()) and true or false
    if keybindChangedCb then keybindChangedCb() end
end

if KB and KB.RegisterCallback then
    local owner = {}   -- CallbackHandler needs an owner; a private table is fine
    KB.RegisterCallback(owner, "LIBKEYBOUND_ENABLED",  syncKeybindState)
    KB.RegisterCallback(owner, "LIBKEYBOUND_DISABLED", syncKeybindState)
end

local function toggleKeybindMode()
    if not KB then
        print("|cfffb2c36Driev's Essentials|r: LibKeyBound is missing; keybind mode unavailable.")
        return keybindActive
    end
    if InCombatLockdown() then
        print("|cfffb2c36Driev's Essentials|r: can't change keybinds in combat.")
        return keybindActive
    end
    if KB:IsShown() then KB:Deactivate() else KB:Activate() end
    syncKeybindState()   -- reflect immediately (the events fire this too)
    return keybindActive
end

-- ── Drag-to-move modifier ────────────────────────────────────────────────────
-- Buttons cast on key/mouse-down, so pressing to drag an ability would fire it.
-- LibActionButton's secure snippets solve this: with `buttonlock` set, a button
-- can only be dragged while the WoW "PICKUPACTION" modified click is held, and
-- during that pickup the on-down cast is suppressed. So we lock every action
-- button and point PICKUPACTION at the user's chosen modifier (Shift by default).
-- Runtime-only (no SaveBindings) — re-applied every login from our own setting,
-- so we don't permanently rewrite the player's saved PICKUPACTION binding.
local VALID_DRAG_MODS = { SHIFT = true, CTRL = true, ALT = true }

local function applyDragModifier()
    if InCombatLockdown() then pendingRefresh = true; return end
    local mod = getGlobalData().dragModifier
    if not VALID_DRAG_MODS[mod] then mod = "SHIFT" end

    if SetModifiedClick and GetModifiedClick then
        if GetModifiedClick("PICKUPACTION") ~= mod then
            SetModifiedClick("PICKUPACTION", mod)
        end
    end

    for _, def in ipairs(BARS) do
        if def.kind == "action" then
            local b = bars[def.key]
            if b then
                for _, btn in ipairs(b.buttons) do
                    btn:SetAttribute("buttonlock", true)
                end
            end
        end
    end
end

-- Re-pushes the button config (which reads the addon-wide out-of-range and
-- keybind-font settings) to every action button, so toggling those options takes
-- effect live. UpdateConfig sets secure attributes, so this is combat-guarded.
local function applyActionButtonConfig()
    if InCombatLockdown() then pendingRefresh = true; return end
    for _, def in ipairs(BARS) do
        if def.kind == "action" then
            local b = bars[def.key]
            if b then applyButtonConfig(b) end
        end
    end
end

-- ── Refresh / lifecycle ──────────────────────────────────────────────────────
local function refreshAll()
    if not isReady() then return end
    -- Master switch off: leave Blizzard's own bars alone entirely rather than
    -- hiding them and building ours. Turning this on later calls refreshAll()
    -- again (see setEnabled below) to take effect without a reload.
    if not getGlobalData().enabled then return end
    if InCombatLockdown() then pendingRefresh = true; return end
    pendingRefresh = false

    addon.HideBlizzardActionBars()

    for _, def in ipairs(BARS) do
        local bar = createBar(def)
        if not bar.mover then
            bar.mover = makeMover(bar)
        end
        applyBar(bar)
    end

    applyDragModifier()
end

-- Wraps a per-bar applier so the settings UI can never trigger a protected
-- secure-frame call while in combat — it just defers a full refresh to the next
-- PLAYER_REGEN_ENABLED. applyAlpha is exempt (SetAlpha isn't protected).
local function guarded(fn)
    return function(key)
        if InCombatLockdown() then pendingRefresh = true; return end
        local b = bars[key]
        if b then fn(b) end
    end
end

addon.ActionBars = {
    bars            = BARS,
    getData         = getData,
    refresh         = refreshAll,
    applyBar        = guarded(applyBar),
    applyLayout     = guarded(layoutBar),
    applyScale      = guarded(applyScale),
    applyAlpha      = function(key) local b = bars[key]; if b then applyAlpha(b) end end,
    -- applyMouseover is combat-safe (SetScript/SetAlpha only), so it's ungated
    -- and takes effect immediately even mid-combat.
    applyMouseover  = function(key) local b = bars[key]; if b then applyMouseover(b) end end,
    applyButtonCfg  = guarded(applyButtonConfig),
    applyClickThru  = guarded(applyClickThrough),
    applyVisibility = guarded(applyVisibility),
    applyPosition   = guarded(applyPosition),
    applyPaging     = guarded(refreshPagingDriver),
    getMover        = function(key) return bars[key] and bars[key].mover end,
    -- Master switch (see the "Enable Action Bars" checkbox in ActionBarsUI.lua).
    -- Turning it on runs refreshAll() immediately; turning it off just saves
    -- the flag — a /reload is needed to restore Blizzard's bars.
    getEnabled      = function() return getGlobalData().enabled == true end,
    setEnabled      = function(v)
        v = v and true or false
        getGlobalData().enabled = v
        if v then refreshAll() end
    end,
    -- Only bars the user has enabled get a mover box in the addon's own Edit
    -- Mode — a disabled bar is already hidden (applyVisibility), so dragging
    -- it around would just move an invisible frame.
    getMovers       = function()
        local list = {}
        for _, def in ipairs(BARS) do
            local b = bars[def.key]
            if b and b.mover and getData(def.key).enabled ~= false then
                list[#list + 1] = b.mover
            end
        end
        return list
    end,
    toggleKeybindMode = toggleKeybindMode,
    isKeybindActive   = function() return keybindActive end,
    -- The settings UI registers its toggle-button refresh here so the label
    -- updates when keybind mode is closed via LibKeyBound's own dialog / combat.
    setKeybindChangedCallback = function(fn) keybindChangedCb = fn end,
    getDragModifier   = function() return getGlobalData().dragModifier or "SHIFT" end,
    setDragModifier   = function(v)
        getGlobalData().dragModifier = v
        applyDragModifier()
    end,
    -- Generic accessor for the addon-wide General-tab keybind settings
    -- (keybindFont / keybindFontSize / keybindOffsetX / keybindOffsetY /
    -- outOfRangeHotkey). Setting any of them re-pushes button config to every
    -- action bar that opts in (combat-guarded).
    getGeneral = function(k) return getGlobalData()[k] end,
    setGeneral = function(k, v)
        getGlobalData()[k] = v
        applyActionButtonConfig()
    end,
}

-- Register the bars as movers in the addon's own Edit Mode (Modules list + the
-- master "Edit Mode" button).
UI.RegisterMovableProvider(function()
    if not isReady() then return {} end
    return addon.ActionBars.getMovers()
end)

-- Blizzard Edit Mode cooperation (1.15.9+): opening Blizzard's Edit Mode shows
-- each bar's own green drag overlay; closing it saves and hides them. Self-
-- contained unlock/lock (NOT UI.EnterMoveMode, which would re-open the settings
-- window on exit), mirroring how Bartender4 toggles its overlays.
local blizzUnlocked = false

local function blizzardUnlock()
    if InCombatLockdown() or blizzUnlocked then return end
    blizzUnlocked = true
    for _, def in ipairs(BARS) do
        local b = bars[def.key]
        if b and b.mover then b.mover.enterMoveMode() end
    end
end

local function blizzardLock()
    if not blizzUnlocked then return end
    blizzUnlocked = false
    for _, def in ipairs(BARS) do
        local b = bars[def.key]
        if b and b.mover then
            b.mover.savePosition()
            b.mover.leaveMoveMode()
        end
    end
    -- Clicking a bar overlay opens the shared X/Y position editor, which isn't
    -- one of our overlays — hide it too, or it lingers on screen after Blizzard's
    -- Edit Mode closes (UI.ExitMoveMode does the same for the addon's own mode).
    if UI.positionEditor then UI.positionEditor:Hide() end
end

local function hookBlizzardEditMode()
    if not (EventRegistry and EditModeManagerFrame) then return end
    EventRegistry:RegisterCallback("EditMode.Enter", blizzardUnlock)
    EventRegistry:RegisterCallback("EditMode.Exit",  blizzardLock)
end

-- Binding names so our per-button action keybinds show up (and are nameable) in
-- the Escape → Key Bindings UI, grouped per action bar.
BINDING_HEADER_DRIEVACTIONBARS = "Driev's Essentials Action Bars"
for _, def in ipairs(BARS) do
    if def.kind == "action" then
        local base = (def.page - 1) * NUM_BUTTONS
        for i = 1, NUM_BUTTONS do
            _G[("BINDING_NAME_CLICK %s%d:Keybind"):format(BTN_PREFIX, base + i)] =
                ("%s Button %d"):format(def.label, i)
        end
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        refreshAll()
        hookBlizzardEditMode()
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingRefresh then refreshAll() end
    end
end)
