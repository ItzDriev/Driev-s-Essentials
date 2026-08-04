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
-- bars `page` is the action-page offset: a bar owns slots (page-1)*12+1 .. page*12.
--
-- The page each bar owns is chosen so the addon's "Action Bar N" shows the same
-- abilities AND the same keybinds as Blizzard's Edit-Mode "Action Bar N" — because
-- Blizzard's bar numbering does NOT follow the action-page order (its "Action Bar
-- 2" is the Bottom-Left bar, which is action page 6, and so on):
--   Bar 1 → page 1 (Main)          Bar 2 → page 6 (Bottom Left)
--   Bar 3 → page 5 (Bottom Right)  Bar 4 → page 3 (Right)
--   Bar 5 → page 4 (Left)          Bar 6 → page 7 (Action Bar 6 / MultiBar5)
--   Bar 7 → page 8 (Action Bar 7)  Bar 8 → page 9 (Action Bar 8)
-- Bars 6-8 map to Blizzard's extra bars (retail only; their bindings are pruned
-- below on clients that lack them). Bars 9-10 take the two pages with no Blizzard
-- binding — page 2 (the Main bar's 2nd page) and page 10 — so every Blizzard-bound
-- bar still lines up 1:1 with ours. A bar's page is what maps it onto its action
-- slots and, via BLIZZ_BINDING (keyed by page), onto Blizzard's own keybinds, so
-- this one table drives the whole linkage. The Main bar (page 1) is the only one
-- flagged `paged`, so it gets the possess/vehicle override and the manual page
-- arrows; explicit per-stance paging (Paging tab) applies on top. The rest are
-- static. Defaults enable Bar 1-3 (Main + Bottom Left + Bottom Right — the classic
-- default look) plus the three special bars.
local NUM_BARS = 10
local BAR_PAGE  = { 1, 6, 5, 3, 4, 7, 8, 9, 2, 10 }
local BARS = {}        -- ordered list of every bar def (used by UI + refresh)
local BAR_BY_KEY = {}
for i = 1, NUM_BARS do
    BARS[i] = {
        key            = "bar" .. i,
        label          = "Action Bar " .. i,
        kind           = "action",
        page           = BAR_PAGE[i],
        paged          = (BAR_PAGE[i] == 1),   -- the Main bar (page 1) follows paging
        defaultEnabled = (i <= 3),
    }
end
BARS[#BARS + 1] = { key = "stance", label = "Stance Bar", kind = "stance", defaultEnabled = true }
BARS[#BARS + 1] = { key = "pet",    label = "Pet Bar",    kind = "pet",    defaultEnabled = true }
BARS[#BARS + 1] = { key = "micro",  label = "Micro Menu", kind = "micro",  defaultEnabled = true }
BARS[#BARS + 1] = { key = "bag",    label = "Bag Bar",    kind = "bag",    defaultEnabled = true }
BARS[#BARS + 1] = { key = "status1", label = "Status Bar 1", kind = "status", defaultEnabled = true }
BARS[#BARS + 1] = { key = "status2", label = "Status Bar 2", kind = "status", defaultEnabled = true }
for _, def in ipairs(BARS) do BAR_BY_KEY[def.key] = def end

-- ── Blizzard keybind linkage ─────────────────────────────────────────────────
-- Every action slot Blizzard's own UI can bind lives on one of its bars, and each
-- of those bars owns a fixed block of action slots. Keyed by the action page a bar
-- owns (see BAR_PAGE above), this maps that page 1:1 onto the Blizzard binding set
-- covering the same slots — which is what makes each of our bars share Blizzard's
-- keybinds for the very abilities it shows:
--   page 1  → ACTIONBUTTON1-12          (main bar,        slots   1-12)
--   page 3  → MULTIACTIONBAR3BUTTON1-12 (Right,           slots  25-36)
--   page 4  → MULTIACTIONBAR4BUTTON1-12 (Right 2 / Left,  slots  37-48)
--   page 5  → MULTIACTIONBAR2BUTTON1-12 (Bottom Right,    slots  49-60)
--   page 6  → MULTIACTIONBAR1BUTTON1-12 (Bottom Left,     slots  61-72)
--   pages 7-9 → MULTIACTIONBAR5/6/7 (retail only; pruned below when absent)
-- Page 2 (slots 13-24) is the main bar's second page and has no binding set, and
-- page 10 has none either — those bars are bind-only through our own bindings
-- (see Bindings.xml). This is the same mapping Bartender4 uses, which is what
-- makes a Bartender/Blizzard user's existing keybinds carry over untouched.
local BLIZZ_BINDING = {
    [1] = "ACTIONBUTTON%d",
    [3] = "MULTIACTIONBAR3BUTTON%d",
    [4] = "MULTIACTIONBAR4BUTTON%d",
    [5] = "MULTIACTIONBAR2BUTTON%d",
    [6] = "MULTIACTIONBAR1BUTTON%d",
    [7] = "MULTIACTIONBAR5BUTTON%d",
    [8] = "MULTIACTIONBAR6BUTTON%d",
    [9] = "MULTIACTIONBAR7BUTTON%d",
}
-- Classic Era has no MultiBar5/6/7; their binding commands don't exist there, so
-- drop them rather than binding names the client will never report keys for. The
-- five bars that exist on every client are kept unconditionally.
for page = 7, 9 do
    local fmt = BLIZZ_BINDING[page]
    if fmt and not _G["BINDING_NAME_" .. fmt:format(1)] then
        BLIZZ_BINDING[page] = nil
    end
end

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
        -- Stance paging is on only for the Main bar out of the box; every other
        -- bar starts with it off (toggle in the Paging tab).
        d.pagingEnabled = (def.paged == true)
        -- Warrior Main bar ships with a sensible default: Battle → Bar 6's page,
        -- Defensive → Bar 7's page, Berserker → Bar 8's page (stance indices 1/2/3).
        -- Stored as the real action pages those bars own, matching the "Page N"
        -- dropdown. Other classes start unconfigured (every stance = own page) —
        -- their stance indices don't map to Battle/Defensive/Berserker.
        if def.paged and select(2, UnitClass("player")) == "WARRIOR" then
            d.paging = { [1] = BAR_PAGE[6], [2] = BAR_PAGE[7], [3] = BAR_PAGE[8] }
        end
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
    -- Link our action bars to Blizzard's own action-bar keybinds (see
    -- BLIZZ_BINDING above): the keys bound to ACTIONBUTTONn / MULTIACTIONBARnBUTTONn
    -- in Escape → Key Bindings drive the matching button on our bar, and our
    -- hotkey text shows them. On by default so an existing keybind setup keeps
    -- working the moment the module is enabled.
    defaults.blizzBindings = true
    -- Show Blizzard's decorative border / slot art on the stance & pet buttons.
    -- Off by default (we strip it for a clean look); the "Blizzard Art" tab flips
    -- it back on for players who prefer the stock button frames.
    defaults.blizzardArt = false
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

    -- Status bars are a single reparented Blizzard container, not a grid of
    -- buttons: size the header to the container and pin the container into it.
    if kind == "status" then
        local c = bar.statusFrame
        -- Blizzard's own Edit Mode scale lives on the container frame; neutralise
        -- it so our header's Scale setting is the only scale that applies (else a
        -- previously-shrunk Blizzard bar stays tiny at our 100%).
        if c then c:SetScale(1) end
        local w, h = 200, 12
        if c then w = c:GetWidth() or 0; h = c:GetHeight() or 0 end
        if w < 1 then w = 200 end
        if h < 1 then h = 12 end
        bar.header:SetSize(w, h)
        if c then
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", bar.header, "TOPLEFT", 0, 0)
        end
        if bar.overlay then
            bar.overlay:ClearAllPoints()
            bar.overlay:SetAllPoints(bar.header)
        end
        return
    end

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
        -- No clickOnDown here on purpose: LibActionButton registers every button
        -- for both the down and up phase and lets the client's
        -- ActionButtonUseKeyDown CVar decide which one fires, so the bars follow
        -- that CVar (toggled under General → Input) — the same single switch the
        -- trinket buttons obey. Forcing a phase here would break that.
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

-- The Blizzard binding command that button `i` of this bar mirrors, or nil when
-- the bar has no Blizzard counterpart (pages 2/10) or the link is switched off.
-- Handing this to LibActionButton as `keyBoundTarget` makes the button *display*
-- the Blizzard keybind and makes keybind mode write to it (LAB's SetKey), so the
-- addon and Blizzard's Key Bindings panel stay one and the same setting.
local function blizzBindingFor(def, i)
    if def.kind ~= "action" then return nil end
    if not isReady() or getGlobalData().blizzBindings == false then return nil end
    local fmt = BLIZZ_BINDING[def.page]
    return fmt and fmt:format(i) or nil
end

local function applyButtonConfig(bar)
    if bar.def.kind ~= "action" then return end
    local cfg = buildButtonConfig(bar)
    for i, btn in ipairs(bar.buttons) do
        -- UpdateConfig deep-copies into the button's own config table, so reusing
        -- (and mutating) one table across the loop is safe — same as BT4.
        cfg.keyBoundTarget = blizzBindingFor(bar.def, i) or false
        btn:UpdateConfig(cfg)
    end
end

-- ── Blizzard keybind pass-through ────────────────────────────────────────────
-- Mirroring the key in the hotkey text isn't enough: pressing it would still run
-- Blizzard's (hidden) button on Blizzard's own page. Override bindings on the
-- bar's header point each of those keys at *our* button instead, so the press
-- respects this bar's paging and settings. Same mechanism the stance/pet bars
-- already use for SHAPESHIFT/BONUSACTION bindings, and it takes priority over the
-- normal binding, so nothing fires twice.
-- NOTE: our own "CLICK <button>:Keybind" bindings (Bindings.xml) are unaffected —
-- a key can only carry one binding, so the two can never both claim it.
local function reassignActionBindings(bar)
    if bar.def.kind ~= "action" then return end
    if InCombatLockdown() then pendingRefresh = true; return end
    ClearOverrideBindings(bar.header)

    local d = getData(bar.def.key)
    if d.enabled == false then return end   -- disabled bar: leave the keys to Blizzard
    local fmt = BLIZZ_BINDING[bar.def.page]
    if not fmt or getGlobalData().blizzBindings == false then return end

    -- Only the buttons the bar actually shows; a hidden button shouldn't swallow
    -- the key (layoutBar hides everything past d.buttons).
    for i = 1, min(d.buttons or NUM_BUTTONS, #bar.buttons) do
        local btn, cmd = bar.buttons[i], fmt:format(i)
        for k = 1, select("#", GetBindingKey(cmd)) do
            local key = select(k, GetBindingKey(cmd))
            if key and key ~= "" then
                SetOverrideBindingClick(bar.header, false, key, btn:GetName(), "Keybind")
            end
        end
    end
end

-- ── Paging ───────────────────────────────────────────────────────────────────
-- Every action bar can switch which action page it shows based on the player's
-- stance/form (configured in the "Paging" tab, gated by that bar's "Enable stance
-- paging"). Each button is told every page's action slot up front (state p → slot
-- (p-1)*12 + i) and a secure state driver flips the header's state. The config
-- maps stance index → page; a stance set to "No paging" contributes no condition
-- and so falls through to the bar's own page. Bar 1 additionally keeps the
-- possess/vehicle override and Blizzard's action-bar-page conditions ([bar:*],
-- the ACTIONPAGE keybinds) — but NOT [bonusbar:*] auto-paging, so "No paging"
-- reliably means own page (see buildPagingDriver).
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

-- Whether stance paging is active for a bar. Defaults to the paged (Main) bar
-- only; every other bar is off until switched on in the Paging tab.
local function isPagingEnabled(bar)
    local v = getData(bar.def.key).pagingEnabled
    if v == nil then v = bar.def.paged end
    return v and true or false
end

-- Builds the state-driver string from the bar's per-stance paging config.
--
-- Paging is now fully explicit: when enabled, each stance that has a page picked
-- switches to it; a stance left on "No paging" gets no condition and so falls
-- through to the bar's own page (the default at the end). We deliberately do NOT
-- add Blizzard's [bonusbar:*] auto-paging any more — that was what made "No
-- paging" still page. The possess/vehicle override stays (you must get the
-- vehicle bar), and the Main bar keeps its [bar:*] conditions so Blizzard's own
-- action-bar-page changes (e.g. the ACTIONPAGE1-6 keybinds) still page it.
local function buildPagingDriver(bar)
    local d = getData(bar.def.key)
    local conds = {}

    -- Vehicle / possess / override — highest priority, essential, and independent
    -- of stance paging.
    if bar.def.paged then
        conds[#conds + 1] = "[overridebar][possessbar][shapeshift]possess"
    end

    -- Per-stance pages (only the ones set to an actual page; "No paging" is stored
    -- as false / absent and intentionally contributes no condition). Stance
    -- conditions are mutually exclusive, so pairs() order doesn't matter.
    if isPagingEnabled(bar) and d.paging then
        for stanceIdx, page in pairs(d.paging) do
            if type(page) == "number" and page >= 1 and page <= 10 then
                conds[#conds + 1] = ("[stance:%d]%d"):format(stanceIdx, page)
            end
        end
    end

    -- Blizzard action-bar-page paging (Main bar), driven by the ACTIONPAGE1-6
    -- keybinds. Only true when the player has actively changed page, so it never
    -- fights a stance.
    if bar.def.paged then
        conds[#conds + 1] = "[bar:2]2;[bar:3]3;[bar:4]4;[bar:5]5;[bar:6]6"
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
    local cfg = buildButtonConfig(bar)
    for i = 1, NUM_BUTTONS do
        if not bar.buttons[i] then
            -- Unique global name per absolute slot so keybinds map 1:1 and never
            -- collide between bars.
            local name = BTN_PREFIX .. (prefixBase + i)
            cfg.keyBoundTarget = blizzBindingFor(bar.def, i) or false
            local btn  = LAB:CreateButton(prefixBase + i, name, bar.header, cfg)
            if bar.MasqueGroup then btn:AddToMasque(bar.MasqueGroup) end
            bar.buttons[i] = btn
        end
    end
end

-- ── Stance bar ───────────────────────────────────────────────────────────────
-- Own secure buttons from Blizzard's StanceButtonTemplate (the same approach
-- BT4 uses), driven by the shapeshift API. Blizzard's own stance bar is parked
-- on the hidden frame so it can't fight us.
-- Hides (or, when the "Blizzard Art" option is on, restores) Blizzard's decorative
-- art on a StanceButtonTemplate button so by default only the icon (plus our
-- checked/highlight) shows. Re-applied from updateStanceButton as well as at
-- creation, since the template can re-populate these as forms change.
--   • NormalTexture is the border ring — Masque re-textures it when skinning, so
--     we only touch it ourselves when Masque is absent. Its original look is
--     captured once so it can be put back if the option is turned on.
--   • SlotBackground / SlotArt are 1.15.9 template additions Masque does NOT
--     manage, so they are toggled either way.
-- IconMask and any Border/highlight regions are deliberately left alone: blanking
-- the IconMask makes the icon itself invisible, and those are Masque's to skin.
local function stripStanceArt(btn)
    local show = isReady() and getGlobalData().blizzardArt == true
    local nt = btn:GetNormalTexture()
    if nt and btn._artCap == nil then   -- remember the border's stock look once
        btn._artCap = { atlas = nt.GetAtlas and nt:GetAtlas() or nil, tex = nt:GetTexture() }
    end
    if show then
        if nt and not btn._masque then
            local cap = btn._artCap
            if cap and cap.atlas then nt:SetAtlas(cap.atlas)
            elseif cap and cap.tex then nt:SetTexture(cap.tex) end
            nt:SetAlpha(1); nt:Show()
        end
        if btn.SlotBackground then btn.SlotBackground:Show() end
        if btn.SlotArt        then btn.SlotArt:Show()        end
    else
        if nt and not btn._masque then nt:SetTexture(nil); nt:SetAlpha(0); nt:Hide() end
        if btn.SlotBackground then btn.SlotBackground:Hide() end
        if btn.SlotArt        then btn.SlotArt:Hide()        end
    end
end

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
    stripStanceArt(btn)   -- keep Blizzard art suppressed across form changes
end

local function createStanceButton(bar, id)
    local name = "DrievStanceButton" .. id
    local btn  = CreateFrame("CheckButton", name, bar.header, "StanceButtonTemplate")
    btn:SetID(id)
    btn.icon     = _G[name .. "Icon"]
    btn.cooldown = _G[name .. "Cooldown"]

    -- Silence the template's own OnEvent (and unregister its events) so Blizzard's
    -- StanceButton logic can't re-show its border/slot art on a later ACTIONBAR_* /
    -- shapeshift event — the cause of the "Blizzard art around the stances stays
    -- visible" reports. We drive icon/cooldown/checked ourselves (updateStanceButton
    -- via bar._eventFrame) and casting stays on the secure OnClick, so the button
    -- needs no events of its own. Same treatment the pet buttons already get.
    btn:UnregisterAllEvents()
    btn:SetScript("OnEvent", nil)

    btn._masque = bar.MasqueGroup and true or false
    if bar.MasqueGroup then
        btn.MasqueButtonData = { Button = btn }
        bar.MasqueGroup:AddButton(btn, btn.MasqueButtonData, "Action")
    end
    stripStanceArt(btn)
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
            if ev == "UPDATE_SHAPESHIFT_FORM" or ev == "UPDATE_SHAPESHIFT_COOLDOWN"
               or ev == "UPDATE_SHAPESHIFT_USABLE" then
                -- Pure visual refresh (checked highlight, icon, cooldown). None of
                -- these are protected, so they MUST run in combat too — otherwise
                -- shifting form mid-combat leaves the highlight stuck on the stance
                -- you just left until combat ends. (Blizzard's own stance bar
                -- likewise updates its checked state in combat.)
                for _, b in ipairs(bar.buttons) do updateStanceButton(b) end
            else
                -- Form count or bindings changed → rebuild + relayout + rebind.
                -- These touch secure frames (create/hide buttons, SetPoint,
                -- override bindings), so they have to wait until out of combat.
                if InCombatLockdown() then pendingRefresh = true; return end
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
-- Toggles Blizzard's slot art on a pet button per the "Blizzard Art" option
-- (hidden by default). Masque-skinned buttons are left to Masque.
local function stripPetArt(btn)
    if btn._masque then return end
    local show = isReady() and getGlobalData().blizzardArt == true
    if btn.SlotBackground then btn.SlotBackground:SetShown(show) end
    if btn.SlotArt        then btn.SlotArt:SetShown(show) end
end

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
    stripPetArt(btn)   -- keep the art state in sync across pet changes
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
    btn._masque = bar.MasqueGroup and true or false
    -- 1.15.9 modernized templates add SlotBackground/SlotArt that render oversized
    -- without Masque (see the Trinkets module); hidden unless "Blizzard Art" is on.
    stripPetArt(btn)
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

    -- Blizzard's BagsBar is an EditMode system that re-anchors — and sometimes
    -- re-parents — its bag-slot buttons whenever Edit Mode changes or the bar
    -- refreshes. That yanks our reparented buttons back toward the (hidden)
    -- BagsBar, so our bag bar appears to "snap away" and stops following our
    -- mover. Rather than chase Blizzard's specific layout call, we watch the
    -- buttons themselves: when one is moved/reparented out from under us, put it
    -- back on the next frame. A reentrancy flag stops our own SetParent/SetPoint
    -- from re-triggering, and a coalescing flag batches Blizzard's multi-button
    -- relayout into a single fix. Bag buttons are plain (non-secure) frames, so
    -- this is combat-safe; skipped in combat only because layoutBar touches the
    -- (secure) header. Same idea as the micro menu's UpdateMicroButtonsParent hook.
    if not bar._bagHooked then
        bar._bagHooked = true
        local reasserting, scheduled = false, false
        local function reassert()
            reasserting = true
            for _, b in ipairs(bar.buttons) do b:SetParent(bar.header) end
            layoutBar(bar)
            reasserting = false
        end
        local function schedule()
            if reasserting or scheduled then return end
            if getData(bar.def.key).enabled == false then return end
            scheduled = true
            C_Timer.After(0, function()
                scheduled = false
                if getData(bar.def.key).enabled ~= false and not InCombatLockdown() then
                    reassert()
                end
            end)
        end
        for _, b in ipairs(bar.buttons) do
            hooksecurefunc(b, "SetPoint",  schedule)
            hooksecurefunc(b, "SetParent", schedule)
        end
    end
end

-- ── Status bars (XP / reputation tracking) ───────────────────────────────────
-- The two Blizzard status-tracking-bar containers, reparented onto our own movable
-- headers. StatusTrackingBarManager keeps managing their contents (XP/rep values,
-- which one is shown), we just own where they sit. Like the bag bar, the manager
-- re-anchors them on its own layout passes, so we watch each container's
-- SetPoint/SetParent and put it back. Nil-checked in case a client build names
-- these frames differently — then the bar simply stays empty.
local STATUS_CONTAINER = {
    status1 = "MainStatusTrackingBarContainer",
    status2 = "SecondaryStatusTrackingBarContainer",
}

local function buildStatusBar(bar)
    local c = _G[STATUS_CONTAINER[bar.def.key] or ""]
    if not c then return end
    bar.statusFrame = c
    c:SetParent(bar.header)
    c:SetScale(1)   -- drop Blizzard's Edit Mode scale; our header owns scale now
    c:ClearAllPoints()
    c:SetPoint("TOPLEFT", bar.header, "TOPLEFT", 0, 0)

    if not bar._statusHooked then
        bar._statusHooked = true
        local reasserting, scheduled = false, false
        local function reassert()
            reasserting = true
            c:SetParent(bar.header)
            layoutBar(bar)   -- re-pins the container + resizes the header
            reasserting = false
        end
        local function schedule()
            if reasserting or scheduled then return end
            if getData(bar.def.key).enabled == false then return end
            scheduled = true
            C_Timer.After(0, function()
                scheduled = false
                if getData(bar.def.key).enabled ~= false and not InCombatLockdown() then
                    reassert()
                end
            end)
        end
        hooksecurefunc(c, "SetPoint",  schedule)
        hooksecurefunc(c, "SetParent", schedule)
        hooksecurefunc(c, "SetScale",  schedule)   -- Blizzard re-applying its scale
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
    elseif kind == "status" then
        buildStatusBar(bar)
    end

    return bar
end

-- ── Position ─────────────────────────────────────────────────────────────────
-- TOPLEFT-from-UIParent-BOTTOMLEFT convention, matching every other movable in
-- this addon (TTK, RaidFrames, chat panels).
--
-- Out-of-the-box the three default bars (Bar 1-3) sit horizontally centred and
-- stacked up from the bottom of the screen, 40px apart — py is the height (in
-- bar-local units) of the bar's top edge above the screen bottom.
local DEFAULT_STACK_Y = { bar1 = 50, bar2 = 90, bar3 = 130 }

-- Full screen width expressed in the bar's own (scaled) coordinate units — the
-- space its px offset is measured in. Matches the drag-to-centre snap math.
local function localScreenWidth(bar)
    local scale = bar.header:GetScale()
    if scale == 0 or scale == nil then scale = 1 end
    return GetScreenWidth() / scale
end

-- Default positions rely on other bars already being positioned: stance/pet read
-- Action Bar 3, and the bag bar reads the micro menu. refreshAll positions bars in
-- BARS order (bar1-10, then stance, pet, micro, bag), so those always run first.
local function initialPosition(bar)
    local d = getData(bar.def.key)
    if d.px and d.py then return end
    local key = bar.def.key

    local stackY = DEFAULT_STACK_Y[key]
    if stackY then
        -- Centre horizontally, then sit at the configured height from the bottom.
        d.px = localScreenWidth(bar) / 2 - bar.header:GetWidth() / 2
        d.py = stackY
        return
    end

    -- Stance bar: just above the left end of Action Bar 3.
    if key == "stance" then
        local b3 = getData("bar3")
        d.px = b3.px or (localScreenWidth(bar) / 2 - bar.header:GetWidth() / 2)
        d.py = (b3.py or DEFAULT_STACK_Y.bar3) + 6 + bar.header:GetHeight()
        return
    end

    -- Pet bar: the same spot as the stance bar (few classes ever show both).
    if key == "pet" then
        local s = getData("stance")
        d.px = s.px or (getData("bar3").px or (localScreenWidth(bar) / 2 - bar.header:GetWidth() / 2))
        d.py = s.py or (DEFAULT_STACK_Y.bar3 + 6 + bar.header:GetHeight())
        return
    end

    -- Micro menu + bag bar: stacked in the bottom-right corner, both right-aligned,
    -- with the micro menu on the bottom and the bag bar directly above it.
    if key == "micro" or key == "bag" then
        local margin, gap = 20, 8
        d.px = localScreenWidth(bar) - margin - bar.header:GetWidth()
        if key == "micro" then
            d.py = margin + bar.header:GetHeight()
        else
            local m = getData("micro")
            local microTop = m.py or (margin + bar.header:GetHeight())
            d.py = microTop + gap + bar.header:GetHeight()
        end
        return
    end

    -- Status bars: centred, stacked just above the very bottom of the screen
    -- (Status Bar 1 lowest, Status Bar 2 above it).
    if key == "status1" or key == "status2" then
        d.px = localScreenWidth(bar) / 2 - bar.header:GetWidth() / 2
        d.py = (key == "status1") and 16 or (16 + bar.header:GetHeight() + 4)
        return
    end

    -- Every other bar: stagger down from a fixed point so they don't overlap.
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
-- Below 1/255, so a difference this small can't be rendered. Used to decide the
-- bar has finished settling on its target, after which the driver stops writing
-- alpha entirely (see applyMouseover) instead of re-setting the same value every
-- frame. Comparing with an epsilon rather than `==` keeps that from being
-- defeated by float drift through the SetAlpha/GetAlpha round-trip.
local ALPHA_EPSILON = 0.003

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
        local header = bar.header
        local key    = bar.def.key
        bar._moFrame:SetScript("OnUpdate", function(_, elapsed)
            -- One getData per tick, not two. It returns the live settings table
            -- rather than a copy, so reading fields off it stays current without
            -- re-looking it up — and this runs every frame for every mouseover
            -- bar, of which there can be a dozen or more.
            local cfg    = getData(key)
            -- cfg.mouseover is necessarily true here: the enclosing branch
            -- checked it, and any change to it re-runs applyMouseover, which
            -- detaches this script.
            local full   = cfg.alpha or 1
            local target = barHovered(bar) and full or 0
            local cur    = header:GetAlpha()

            -- Settled: snap off any residual drift once, then do nothing on
            -- every subsequent frame. SetAlpha walks the whole child button
            -- tree, so not calling it is the entire point — the steady state
            -- (cursor away, bar parked at 0) is the overwhelmingly common one.
            if math.abs(cur - target) < ALPHA_EPSILON then
                if cur ~= target then header:SetAlpha(target) end
                return
            end

            if cfg.mouseoverFade then
                if cur < target then
                    header:SetAlpha(math.min(target, cur + MO_FADE_RATE * elapsed))
                else
                    header:SetAlpha(math.max(target, cur - MO_FADE_RATE * elapsed))
                end
            else
                header:SetAlpha(target)
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
        reassignActionBindings(bar)
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

-- Re-derives the Blizzard-keybind override bindings on every action bar. Run at
-- refresh time and whenever the game reports a binding change (UPDATE_BINDINGS),
-- which covers Escape → Key Bindings, keybind mode, and binding-set swaps.
local function applyActionBindings()
    if InCombatLockdown() then pendingRefresh = true; return end
    for _, def in ipairs(BARS) do
        if def.kind == "action" then
            local b = bars[def.key]
            if b then reassignActionBindings(b) end
        end
    end
end

-- Button art (stance + pet) — the blizzardArt toggle.
local function applyButtonArt()
    local s = bars["stance"]
    if s then for _, b in ipairs(s._pool or s.buttons) do stripStanceArt(b) end end
    local p = bars["pet"]
    if p then for _, b in ipairs(p.buttons) do stripPetArt(b) end end
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
    applyScale      = guarded(applyScale),
    applyAlpha      = function(key) local b = bars[key]; if b then applyAlpha(b) end end,
    -- applyMouseover is combat-safe (SetScript/SetAlpha only), so it's ungated
    -- and takes effect immediately even mid-combat.
    applyMouseover  = function(key) local b = bars[key]; if b then applyMouseover(b) end end,
    applyButtonCfg  = guarded(applyButtonConfig),
    applyClickThru  = guarded(applyClickThrough),
    -- A disabled bar hands its Blizzard keys back to Blizzard, so toggling a bar
    -- re-derives the overrides as well.
    applyVisibility = guarded(function(b) applyVisibility(b); reassignActionBindings(b) end),
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
    -- Blizzard keybind link (General tab). Toggling it re-pushes the button config
    -- (hotkey text switches between the Blizzard binding and our own) and rebuilds
    -- the override bindings.
    getBlizzBindings = function() return getGlobalData().blizzBindings ~= false end,
    setBlizzBindings = function(v)
        getGlobalData().blizzBindings = v and true or false
        applyActionButtonConfig()
        applyActionBindings()
    end,
    -- "Blizzard Art" tab: stock border/slot art on the Stance and Pet buttons.
    getBlizzardArt = function() return getGlobalData().blizzardArt == true end,
    setBlizzardArt = function(v)
        getGlobalData().blizzardArt = v and true or false
        applyButtonArt()
    end,
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

-- Display names for the bindings declared in Bindings.xml (the XML is what makes
-- them exist in the Escape → Key Bindings UI at all; these globals are only the
-- labels). BINDING_HEADER_DRIEVACTIONBARS names both the left-hand category tab
-- (via each binding's category="BINDING_HEADER_DRIEVACTIONBARS") and the section
-- header, so our bindings get their own tab instead of landing under "Other".
BINDING_HEADER_DRIEVACTIONBARS = "|cfffb2c36Driev's|r ActionBars"
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
eventFrame:RegisterEvent("UPDATE_BINDINGS")
eventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        refreshAll()
        hookBlizzardEditMode()
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingRefresh then refreshAll() end
    elseif event == "UPDATE_BINDINGS" then
        -- The player rebound something (Key Bindings panel, keybind mode, a
        -- character/account binding-set swap) — re-point our override bindings at
        -- the new keys. LibActionButton refreshes the hotkey text on its own.
        applyActionBindings()
    end
end)
