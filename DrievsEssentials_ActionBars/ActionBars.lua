-- Action Bars module. A from-scratch bar engine on LibActionButton-1.0 (the same
-- secure-button library Bartender4/ElvUI use). Hides Blizzard's default bars
-- (HideBlizzard.lua) and replaces them with bars exposing per-bar scale, icon
-- size, alpha, rows, growth and flyout direction, click-through and mouseover.
--
-- Five bar "kinds" share the same position/scale/alpha/edit-mode machinery and
-- differ only in how their buttons are made: action, stance, pet, micro
-- (Blizzard's micro buttons, reparented) and bag.
--
-- Deliberately does NOT copy Bartender4's source (all rights reserved, deeply
-- coupled to Ace3); it reimplements the same ideas on the open libraries.
local addon = _G.DrievEssentials
if not addon then return end

local UI     = addon.UI
local LAB    = LibStub("LibActionButton-1.0")
local KB     = LibStub("LibKeyBound-1.0", true)
-- Optional: with Masque installed, each bar registers its buttons with a per-bar
-- group so the user can skin them from Masque's own UI.
local Masque = LibStub("Masque", true)
-- LibSharedMedia (bundled by the core addon, which loads first) supplies the
-- font list for the keybind-text font picker.
local LSM = LibStub("LibSharedMedia-3.0", true)

-- Abbreviate mouse buttons as M3 / SM4 rather than B3 / SB4. LibKeyBound's
-- ToShortKey maps BUTTONn through a plain writable global read live, so this
-- needs no library edit. NOTE: LibKeyBound is shared, so other addons using this
-- copy are affected too.
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
-- Ten action bars plus stance / micro / bag. `page` is the action-page offset: a
-- bar owns slots (page-1)*12+1 .. page*12.
--
-- Each page is chosen so our "Action Bar N" shows the same abilities AND
-- keybinds as Blizzard's Edit-Mode "Action Bar N" — Blizzard's numbering doesn't
-- follow page order (its "Action Bar 2" is Bottom Left, page 6):
--   Bar 1 → page 1 (Main)          Bar 2 → page 6 (Bottom Left)
--   Bar 3 → page 5 (Bottom Right)  Bar 4 → page 3 (Right)
--   Bar 5 → page 4 (Left)          Bar 6-8 → pages 7-9 (retail extras)
-- Bars 9-10 take the two pages with no Blizzard binding (2 and 10). A bar's page
-- maps it onto its slots and, via BLIZZ_BINDING, onto Blizzard's keybinds, so
-- this one table drives the whole linkage. Only the Main bar is `paged`.
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
-- The status bars ship at half scale: they are the two widest elements here (the
-- full width of the experience/reputation bar), and at 1.0 a pair of them across
-- the bottom of the screen is the loudest thing in the UI.
BARS[#BARS + 1] = { key = "status1", label = "Status Bar 1", kind = "status", defaultEnabled = true, defaultScale = 0.5 }
BARS[#BARS + 1] = { key = "status2", label = "Status Bar 2", kind = "status", defaultEnabled = true, defaultScale = 0.5 }
for _, def in ipairs(BARS) do BAR_BY_KEY[def.key] = def end

-- Out of the box the Main bar pages with the game's own stance bars: pages 7-9
-- are the bonus-bar pages (slots 73-108) the client puts a warrior's stance, a
-- druid's form and a rogue's stealth actions on, and Bars 6, 7 and 8 own exactly
-- those pages. Indexed by bonus-bar offset, which is also why the driver spells
-- this as [bonusbar:N] and not [stance:N]: it fires only where the client itself
-- swaps the slots, leaving a form that shares the normal bar (a priest's
-- Shadowform, a shaman's Ghost Wolf) on the bar the player is looking at.
local BUILTIN_STANCE_PAGES = { BAR_PAGE[6], BAR_PAGE[7], BAR_PAGE[8] }   -- 7, 8, 9

-- Whether a stored per-stance table is just the Battle/Defensive/Berserker set
-- this used to ship to warriors — i.e. a copy of what the built-in now does on
-- its own. Used by the migration below; an absent or empty table counts, a table
-- with anything else in it (an explicit "No paging" included) does not.
local function isBuiltinPaging(t)
    if type(t) ~= "table" or next(t) == nil then return true end
    for k, v in pairs(t) do
        if BUILTIN_STANCE_PAGES[k] ~= v then return false end
    end
    for k, v in pairs(BUILTIN_STANCE_PAGES) do
        if t[k] ~= v then return false end
    end
    return true
end

-- ── Blizzard keybind linkage ─────────────────────────────────────────────────
-- Keyed by the action page a bar owns, mapping it 1:1 onto the Blizzard binding
-- set covering the same slots — what makes each bar share Blizzard's keybinds
-- for the abilities it shows:
--   page 1  → ACTIONBUTTON1-12          (main bar,     slots  1-12)
--   page 3  → MULTIACTIONBAR3BUTTON1-12 (Right,        slots 25-36)
--   page 4  → MULTIACTIONBAR4BUTTON1-12 (Left,         slots 37-48)
--   page 5  → MULTIACTIONBAR2BUTTON1-12 (Bottom Right, slots 49-60)
--   page 6  → MULTIACTIONBAR1BUTTON1-12 (Bottom Left,  slots 61-72)
--   pages 7-9 → MULTIACTIONBAR5/6/7 (retail only; pruned below when absent)
-- Pages 2 and 10 have no binding set and are bind-only through our Bindings.xml.
-- Same mapping Bartender4 uses, which carries an existing setup over untouched.
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
-- Classic Era has no MultiBar5/6/7, so drop those rather than binding names the
-- client will never report keys for.
for page = 7, 9 do
    local fmt = BLIZZ_BINDING[page]
    if fmt and not _G["BINDING_NAME_" .. fmt:format(1)] then
        BLIZZ_BINDING[page] = nil
    end
end

-- Per-bar defaults registered into core's profile. Action bars carry the full
-- knob set; the special bars omit what doesn't apply.
local function barDefault(def)
    local d = {
        enabled       = def.defaultEnabled,
        rows          = 1,
        scale         = def.defaultScale or 1.0,
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
        -- Drops the keybind string off this bar's buttons. Display only: the keys
        -- themselves keep working, which is the point — a bar you know by heart
        -- doesn't need labelling, and the text is the noisiest thing on an icon.
        d.hideKeybind = false
        if def.paged then
            -- The Main bar pages with the game's own stance bars out of the box
            -- (BUILTIN_STANCE_PAGES), so its flag OVERRIDES that with the
            -- per-stance table rather than switching the table on. Off = built-in.
            -- No `paging` default to go with it: an override starts empty, which
            -- is also how "stop this bar paging at all" is expressed.
            d.pagingOverride = false
            -- Blizzard's "Next / Previous Action Bar" keys. Only the Main bar
            -- offers it (that's the bar those keys page in Blizzard's UI), so only
            -- it carries the default. On, so a setup that already binds those keys
            -- keeps working the moment the module is switched on.
            d.pageSwap = true
            -- What those keys swap the bar to, as a raw action page. Bar 9's page
            -- by default: pages 2 and 10 are the two with no Blizzard binding
            -- (see BLIZZ_BINDING), so Bar 9 is the spare nothing else claims.
            d.swapPage = BAR_PAGE[9]
        else
            -- Every other bar has no built-in paging: its flag switches the
            -- per-stance table on, and starts off.
            d.pagingEnabled = false
        end
    end
    return d
end

do
    local defaults = {}
    for _, def in ipairs(BARS) do
        defaults[def.key] = barDefault(def)
    end
    -- Master switch, off by default so a fresh install leaves Blizzard's bars alone.
    -- Enabling takes effect immediately; disabling needs a /reload, since
    -- HideBlizzardActionBars' reparenting isn't reversed.
    defaults.enabled = false
    -- Addon-wide, not per-bar: which modifier drags an ability off a button without
    -- the on-keydown press activating it. Lives alongside the bar keys, and getData()
    -- only reads real bar keys, so this extra key is inert to it.
    defaults.dragModifier = "SHIFT"   -- SHIFT | CTRL | ALT
    -- Links our bars to Blizzard's own action-bar keybinds (see BLIZZ_BINDING): the
    -- keys bound in Escape → Key Bindings drive the matching button on our bar. On
    -- by default so an existing keybind setup keeps working.
    defaults.blizzBindings = true
    -- Blizzard's decorative border / slot art on the stance and pet buttons. Off by
    -- default (we strip it), flipped back on by the "Blizzard Art" tab.
    defaults.blizzardArt = false
    -- ── General keybind-text settings, applied to any bar whose `useGeneral` is on
    -- false → whole button reddens when out of range (Blizzard default);
    -- true  → only the keybind text reddens.
    defaults.outOfRangeHotkey = false
    -- Keybind text, as core's shared font block (Font.lua): face, size, outline,
    -- offset from the button's TOPRIGHT, and drop shadow. The defaults are
    -- LibActionButton's own classic treatment, so a profile that never touches
    -- this looks exactly as it did.
    defaults.keybindFont = addon.Font.New({
        font = "Arial Narrow", size = 13, x = -2, y = -4,
        color = { 0.75, 0.75, 0.75 },
    })
    addon.RegisterDefaults("actionBars", defaults)
end

-- Makes the block above pickable on its own in the Profiles tab's export,
-- import and copy dialogs.
if addon.RegisterProfileSection then
    addon.RegisterProfileSection({ key = "actionBars", label = "Action Bars", order = 60,
        settings = { "actionBars" } })
end

-- The face used to be a bare LSM name (or `false` for the game's own font)
-- beside flat size/offset keys. Folded into the block before the defaults are
-- merged, since the merge would otherwise replace the saved name outright.
addon.Font.MigrateBlock(function(s) return s.actionBars end, "keybindFont", {
    size = "keybindFontSize", x = "keybindOffsetX", y = "keybindOffsetY",
})

-- The Main bar's "Enable stance paging" became "Override stance paging": the bar
-- now follows the game's own stance bars out of the box, and the flag replaces
-- that with the per-stance table instead of switching the table on. The stored
-- flag means something different under the new name, so it is rewritten rather
-- than dropped — and it has to happen here, before applyDefaults, or a profile
-- that predates the change is indistinguishable from a fresh one:
--   off → the player had asked for no stance paging on this bar. Kept, as an
--         override with an empty table, which pages nowhere.
--   on  → their per-stance table becomes the override, unless it is exactly the
--         Battle/Defensive/Berserker set this used to ship to warriors. That is
--         what the built-in now does anyway, so those profiles are left on the
--         built-in instead of being pinned to a private copy of it.
addon.RegisterMigration(function(prof)
    local s = type(prof.settings) == "table" and prof.settings.actionBars or nil
    local d = type(s) == "table" and s.bar1 or nil
    if type(d) ~= "table" or d.pagingEnabled == nil then return end
    if d.pagingEnabled == false then
        d.pagingOverride, d.paging = true, {}
    else
        d.pagingOverride = not isBuiltinPaging(d.paging)
    end
    -- Safe to clear: bar1 no longer declares it, so applyDefaults can't refill it.
    d.pagingEnabled = nil
end)

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

-- ── Keybind text ─────────────────────────────────────────────────────────────
-- The shared font block (core's Font.lua). LibActionButton owns the FontString
-- and takes face/size/flags and a position through its config, so the block is
-- unpacked into that shape in buildButtonConfig; the drop shadow is the one part
-- LAB has no config for, and is applied to the string afterwards.
local KEYBIND_FONT_DEFAULT = addon.Font.New({
    font = "Arial Narrow", size = 13, x = -2, y = -4,
    color = { 0.75, 0.75, 0.75 },
})
local KEYBIND_FONT_LEGACY = {
    size = "keybindFontSize", x = "keybindOffsetX", y = "keybindOffsetY",
}

local function keybindFont()
    return addon.Font.Adopt(getGlobalData(), "keybindFont", KEYBIND_FONT_LEGACY)
end

-- Fixed cell size (px) spacing the non-action bars. Their buttons keep their
-- native art size, so these just describe the grid footprint.
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
-- Positions shown buttons in a rows×columns block anchored at the header's
-- TOPLEFT. Growth only reorders buttons within that fixed block, so the saved
-- position stays put. Action bars are resized to their icon size; the special
-- bars keep their native art size and are only positioned.
local function layoutBar(bar)
    local d    = getData(bar.def.key)
    local kind = bar.def.kind

    -- Status bars are a single reparented Blizzard container, not a grid of
    -- buttons: size the header to the container and pin the container into it.
    if kind == "status" then
        local c = bar.statusFrame
        -- Blizzard's Edit Mode scale lives on the container frame; neutralise it so our
        -- header's Scale is the only one that applies, or a previously-shrunk Blizzard
        -- bar stays tiny at our 100%.
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
        -- Blizzard-hidden buttons neither leave a gap nor get force-shown by us.
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

    -- `lines` counts along the wrap axis: rows when building horizontally, columns
    -- when vertically. `perLine` is how many buttons sit in each.
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
-- keyBoundClickButton = "Keybind" mirrors BT4: keybinds are stored as
-- `CLICK <button>:Keybind`, so a bound key triggers the ability without stealing
-- the left mouse button, which stays free for pickup/drag while unlocked.
local function buildButtonConfig(bar)
    local d = getData(bar.def.key)
    local hideHotkey = (d.hideKeybind == true)
    local cfg = {
        tooltip             = "enabled",
        showGrid            = true,   -- show empty slots so you can drag spells onto them
        colors              = { range = { 0.8, 0.1, 0.1 }, mana = { 0.5, 0.5, 1.0 } },
        hideElements        = { macro = false, hotkey = hideHotkey, equipped = false, border = false },
        keyBoundTarget      = false,
        keyBoundClickButton = "Keybind",
        -- No clickOnDown on purpose: LibActionButton registers both phases and lets the
        -- client's ActionButtonUseKeyDown CVar decide which fires, so the bars follow
        -- that CVar — the same switch the trinket buttons obey. Forcing a phase here
        -- would break it.
        flyoutDirection     = d.flyout or "UP",
        outOfRangeColoring  = "button",   -- default: whole icon reddens out of range
    }
    -- When a bar opts into the General tab, apply its keybind-text font/size/position
    -- and out-of-range colouring. LAB merges partial config against its defaults, so
    -- unspecified sub-keys stay default; with useGeneral off there's no `text` block.
    if d.useGeneral ~= false then
        local g   = getGlobalData()
        local cf  = keybindFont()
        local dx, dy = addon.Font.Offsets(cf, KEYBIND_FONT_DEFAULT)
        -- Hotkey colouring is off the table where the string is hidden: LAB shows
        -- the hidden hotkey again to draw its out-of-range dot (UpdateHotkeys
        -- leaves RANGE_INDICATOR in the string), so the bar would sprout a dot on
        -- every out-of-range button. Fall back to reddening the whole icon.
        cfg.outOfRangeColoring = (g.outOfRangeHotkey and not hideHotkey) and "hotkey" or "button"
        -- LibActionButton's own hotkey grey unless the block's colour override is
        -- ticked, so a bar that never touches this looks exactly as it did.
        local tr, tg, tb = addon.Font.ColorOr(cf, KEYBIND_FONT_DEFAULT, 0.75, 0.75, 0.75)
        cfg.text = {
            hotkey = {
                font = {
                    font  = addon.Font.Path(cf, KEYBIND_FONT_DEFAULT),
                    size  = addon.Font.Size(cf, KEYBIND_FONT_DEFAULT),
                    flags = addon.Font.Flags(cf, KEYBIND_FONT_DEFAULT),
                },
                -- LAB paints the string itself (SetVertexColor), so the block's
                -- colour goes through its config rather than being applied after.
                color = { tr, tg, tb },
                position = {
                    anchor    = "TOPRIGHT",
                    relAnchor = "TOPRIGHT",
                    offsetX   = dx,
                    offsetY   = dy,
                },
            },
        }
    end
    return cfg
end

-- The Blizzard binding command button `i` mirrors, or nil when the bar has no
-- counterpart (pages 2/10) or the link is off. Handing it to LibActionButton as
-- `keyBoundTarget` makes the button display that keybind and makes keybind mode
-- write to it, so the addon and Blizzard's panel are one setting.
local function blizzBindingFor(def, i)
    if def.kind ~= "action" then return nil end
    if not isReady() or getGlobalData().blizzBindings == false then return nil end
    local fmt = BLIZZ_BINDING[def.page]
    return fmt and fmt:format(i) or nil
end

local function applyButtonConfig(bar)
    if bar.def.kind ~= "action" then return end
    local cfg = buildButtonConfig(bar)
    -- Only where the bar opts into the General tab: with useGeneral off, cfg has
    -- no text block and the hotkey string is LAB's to style, shadow included.
    local shadowFrom = cfg.text and keybindFont() or nil
    for i, btn in ipairs(bar.buttons) do
        -- UpdateConfig deep-copies into the button's own config table, so reusing
        -- (and mutating) one table across the loop is safe — same as BT4.
        cfg.keyBoundTarget = blizzBindingFor(bar.def, i) or false
        btn:UpdateConfig(cfg)
        -- After UpdateConfig, which re-runs LAB's own SetFont on the string. That
        -- doesn't touch the shadow, so this only has to follow it, not fight it.
        if shadowFrom then
            addon.Font.ApplyShadow(btn.HotKey, shadowFrom, KEYBIND_FONT_DEFAULT)
        end
    end
end

-- ── "Next / Previous Action Bar" ─────────────────────────────────────────────
-- Blizzard's NEXTACTIONPAGE / PREVIOUSACTIONPAGE keys page the *native* main bar
-- via ChangeActionBarPage, which is no use here: that bar is parked on the hidden
-- frame, and the call is protected, so nothing an insecure handler does could
-- follow it in combat. Instead the two keys are override-bound onto a secure
-- handler of our own that drives this bar's page state directly, which works in
-- combat like the rest of the paging.
--
-- Not a 1-6 cycle: the press swaps the bar between the page it is showing (with
-- the built-in stance paging, that's Bar 6, 7 or 8) and one configured swap page,
-- then back again. Both keys do the same swap, so either one alone gets you there
-- and back.
--
-- The press only flips a mode flag — it does NOT write the page. Writing the page
-- here is what the first attempt did, and the state driver undid it moments later
-- (it re-parses and re-writes state-page on a broad set of events). The flag is
-- read by the header's own state handler, so the driver re-asserting its value
-- resolves to the swapped page as well; see POSSESS_SNIPPET. That also makes the
-- swap a mode rather than a one-shot: a stance change while swapped moves the
-- page the bar returns to, not the bar.
local PAGE_SWAP_BINDINGS = { "NEXTACTIONPAGE", "PREVIOUSACTIONPAGE" }
local PAGE_SWAP_CLICK    = "SwapPage"

local PAGE_SWAP_SNIPPET = [[
    local header = self:GetFrameRef("header")
    -- A vehicle / possess / override bar owns the buttons — leave it alone.
    if header:GetAttribute("pagelock") then return end
    if not tonumber(header:GetAttribute("swappage")) then return end

    -- state-swap runs the header's _onstate-swap handler, which re-resolves the
    -- page exactly as the state driver's own handler would. The value alternates
    -- true/false, so the write always changes the attribute and the handler
    -- always runs.
    local swapped = not header:GetAttribute("swapped")
    header:SetAttribute("swapped", swapped)
    header:SetAttribute("state-swap", swapped)
]]

-- Deliberately not Hide()n: it exists only as a binding target, and a hidden
-- button can't be clicked. 1x1, mouse-disabled and drawing nothing, so it is
-- invisible in practice.
local function getPageSwapper(bar)
    if bar.pager then return bar.pager end
    local p = CreateFrame("Button", "DrievABarPager_" .. bar.def.key, bar.header,
                          "SecureHandlerClickTemplate")
    p:SetSize(1, 1)
    p:SetPoint("TOPLEFT", bar.header, "TOPLEFT", 0, 0)
    p:EnableMouse(false)
    p:RegisterForClicks("AnyDown")   -- one swap per press, not one per press+release
    p:SetFrameRef("header", bar.header)
    p:SetAttribute("_onclick", PAGE_SWAP_SNIPPET)
    bar.pager = p
    return p
end

-- ── Blizzard keybind pass-through ────────────────────────────────────────────
-- Mirroring the key in the hotkey text isn't enough: pressing it would still run
-- Blizzard's hidden button on Blizzard's page. Override bindings on the bar's
-- header point each key at OUR button, so the press respects this bar's paging.
-- Override takes priority over the normal binding, so nothing fires twice, and
-- our own "CLICK <button>:Keybind" bindings are unaffected — a key carries one.
local function reassignActionBindings(bar)
    if bar.def.kind ~= "action" then return end
    if InCombatLockdown() then pendingRefresh = true; return end
    ClearOverrideBindings(bar.header)

    local d = getData(bar.def.key)
    if d.enabled == false then return end   -- disabled bar: leave the keys to Blizzard

    -- Next / Previous Action Bar. Its own opt-in, independent of the per-button
    -- Blizzard link below — hence bound before that early return.
    if d.pageSwap then
        local pager = getPageSwapper(bar)
        for _, cmd in ipairs(PAGE_SWAP_BINDINGS) do
            for k = 1, select("#", GetBindingKey(cmd)) do
                local key = select(k, GetBindingKey(cmd))
                if key and key ~= "" then
                    SetOverrideBindingClick(bar.header, false, key, pager:GetName(), PAGE_SWAP_CLICK)
                end
            end
        end
    end

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
-- Any action bar can switch page by stance/form. Each button is told every
-- page's slot up front (state p → slot (p-1)*12 + i) and a secure state driver
-- flips the header's state. A stance on "No paging" contributes no condition and
-- falls through to the bar's own page. Bar 1 also keeps the possess/vehicle
-- override and Blizzard's [bar:*] conditions.
--
-- Everything the bar's page depends on is resolved HERE, in the state handler,
-- including the Next/Previous Action Bar swap. That isn't a stylistic choice:
-- the state driver re-parses its conditional and re-writes state-page on a broad
-- set of events (modifier keys and cursor changes among them), so anything that
-- writes the page from outside is undone moments later. Folding the swap in
-- means every one of those re-assertions lands on the swapped page too.
local POSSESS_SNIPPET = [[
    local locked = false
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
        -- One of those bars owns the buttons: neither the swap below nor the key
        -- press itself (PAGE_SWAP_SNIPPET reads pagelock) may page away from it.
        locked = true
    end
    self:SetAttribute("pagelock", locked)
    -- What the driver itself resolved, before the swap is folded in — what the
    -- bar returns to when the swap is turned back off.
    self:SetAttribute("rawpage", newstate)
    if not locked and self:GetAttribute("swapped") then
        local swap = tonumber(self:GetAttribute("swappage"))
        if swap then newstate = swap end
    end
    self:SetAttribute("state", newstate)
    control:ChildUpdate("state", newstate)
]]

local SIMPLE_SNIPPET = [[
    self:SetAttribute("rawpage", newstate)
    if self:GetAttribute("swapped") then
        local swap = tonumber(self:GetAttribute("swappage"))
        if swap then newstate = swap end
    end
    self:SetAttribute("state", newstate)
    control:ChildUpdate("state", newstate)
]]

-- Runs on our own "swap" state, which only the key press writes. Same mechanism
-- as the _onstate-page handlers above, so it reaches the buttons the same way,
-- and it makes the same choice they do — from the driver's last raw page rather
-- than from the driver, which can't be re-run on demand. `newstate` is the new
-- swapped flag.
local SWAP_STATE_SNIPPET = [[
    local page = tonumber(self:GetAttribute("rawpage"))
                 or tonumber(self:GetAttribute("ownpage"))
    if not page then return end
    if newstate then
        local swap = tonumber(self:GetAttribute("swappage"))
        if swap then page = swap end
    end
    self:SetAttribute("state", page)
    control:ChildUpdate("state", page)
]]

-- Whether a bar's own per-stance table drives it. The Main bar's flag overrides
-- its built-in paging (off = built-in, on = the table); every other bar has no
-- built-in, so its flag switches the table on and starts off.
local function isPagingEnabled(bar)
    local d = getData(bar.def.key)
    if bar.def.paged then return d.pagingOverride and true or false end
    return d.pagingEnabled and true or false
end

-- The Main bar follows the game's own stance bars unless overridden. Every other
-- bar, and the Main bar once overridden, is fully explicit instead: a stance with
-- a page picked switches to it, one on "No paging" falls through to the default at
-- the end. That is why [bonusbar:*] lives in the built-in branch only — leaving it
-- in the explicit one is what used to make "No paging" still page.
-- The Main bar keeps [bar:*] either way so Blizzard's ACTIONPAGE keybinds work.
local function buildPagingDriver(bar)
    local d = getData(bar.def.key)
    local conds = {}

    -- Vehicle / possess / override — highest priority, essential, and independent
    -- of stance paging.
    if bar.def.paged then
        conds[#conds + 1] = "[overridebar][possessbar][shapeshift]possess"
    end

    if bar.def.paged and not d.pagingOverride then
        -- Built-in: whenever the client hands the player a bonus bar, show the
        -- bar that owns those slots (Bars 6, 7 and 8).
        for offset, page in ipairs(BUILTIN_STANCE_PAGES) do
            conds[#conds + 1] = ("[bonusbar:%d]%d"):format(offset, page)
        end
    elseif isPagingEnabled(bar) and d.paging then
        -- Only stances set to an actual page; "No paging" is stored as false/absent
        -- and contributes no condition. Stance conditions are mutually exclusive, so
        -- pairs() order doesn't matter.
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

    -- The Next/Previous Action Bar swap target, re-pushed from the config here
    -- rather than at setup because it is a setting. Cleared when unset or out of
    -- range, which parks PAGE_SWAP_SNIPPET (it returns on a missing swappage).
    -- The swap itself is dropped with it: a settings change shouldn't leave the
    -- bar parked on a page the new config doesn't produce.
    local swap = getData(bar.def.key).swapPage
    if type(swap) ~= "number" or swap < 1 or swap > 10 then swap = nil end
    bar.header:SetAttribute("swappage", swap)
    bar.header:SetAttribute("swapped", false)

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
    -- Read by the swap handlers as their fallback when nothing else is known.
    bar.header:SetAttribute("ownpage", bar.def.page)
    bar.header:SetAttribute("_onstate-page", bar.def.paged and POSSESS_SNIPPET or SIMPLE_SNIPPET)
    bar.header:SetAttribute("_onstate-swap", SWAP_STATE_SNIPPET)
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
-- Own secure buttons from StanceButtonTemplate (as BT4 does), driven by the
-- shapeshift API; Blizzard's own stance bar is parked on the hidden frame.
--
-- This hides (or, with "Blizzard Art" on, restores) the template's decorative
-- art so only the icon shows. Re-applied from updateStanceButton as well as at
-- creation, since the template repopulates these as forms change.
--   • NormalTexture is the border ring — Masque re-textures it, so we only touch
--     it when Masque is absent; its original look is captured once.
--   • SlotBackground / SlotArt are 1.15.9 additions Masque does NOT manage, so
--     they are toggled either way.
-- IconMask and Border/highlight regions are left alone: blanking IconMask makes
-- the icon invisible, and those are Masque's to skin.
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

    -- Silence the template's OnEvent so Blizzard's StanceButton logic can't re-show
    -- its border/slot art on a later ACTIONBAR_*/shapeshift event — the cause of the
    -- "Blizzard art around the stances stays visible" reports. We drive
    -- icon/cooldown/checked ourselves and casting stays on the secure OnClick, so the
    -- button needs no events. Same treatment the pet buttons get.
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
                -- Form count or bindings changed → rebuild, relayout, rebind. These touch secure
                -- frames, so they wait until out of combat.
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
-- Own secure buttons from PetActionButtonTemplate. Always 10 slots; empty ones
-- fade with SetAlpha, not Hide, which is protected in combat. Bar visibility
-- follows pet presence through a secure [pet]show;hide driver, so it works even
-- when a pet is summoned mid-combat.
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

-- Maps BONUSACTIONBUTTON1..10 onto our pet buttons via override bindings, so pet
-- keybinds set in Blizzard's UI keep working with the native bar hidden.
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
-- The micro buttons, reparented onto our header. Blizzard's ordered
-- MICRO_BUTTONS global is the authoritative set for this client, so whatever
-- exists is included without guessing per version — which is how the Guild
-- button used to go missing. The fallback covers that global being absent.
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
    -- UpdateMicroButtonsParent and its Edit Mode. Pointing that at our header — and
    -- re-asserting it if Blizzard takes them back — is what actually removes them
    -- from Blizzard's Edit Mode; a plain SetParent gets reverted.
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
-- Backpack + bag slots (+ keyring on Era), reparented onto our header. Plain
-- non-protected buttons, so nothing needs a combat guard beyond the layout one.
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
                -- 1.15.9's KeyRingButton has an OnShow handler that errors when the button is
                -- shown outside its own bar, which showing our bag header triggered. Clearing
                -- OnShow is what BT4's BagBarClassic does; click behaviour is unaffected.
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

    -- Blizzard's BagsBar is an EditMode system that re-anchors and sometimes
    -- re-parents its bag-slot buttons whenever Edit Mode changes, yanking ours back.
    -- Rather than chase Blizzard's layout call, watch the buttons and put one back
    -- next frame when it moves. A reentrancy flag stops our own calls re-triggering
    -- and a coalescing flag batches a multi-button relayout into one fix. Bag buttons
    -- are non-secure, so this is combat-safe; skipped in combat only because
    -- layoutBar touches the secure header.
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
-- Blizzard's two containers, reparented onto our movable headers.
-- StatusTrackingBarManager keeps managing their contents; we own only where they
-- sit. Like the bag bar, it re-anchors them on its own layout passes, so we watch
-- SetPoint/SetParent and put them back. Nil-checked in case a build renames them.
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
-- TOPLEFT-from-UIParent-BOTTOMLEFT, matching every other movable here. Bar 1-3
-- start centred and stacked from the bottom 40px apart; py is the height of the
-- bar's top edge above screen bottom.
local DEFAULT_STACK_Y = { bar1 = 50, bar2 = 90, bar3 = 130 }

-- Full screen width expressed in the bar's own (scaled) coordinate units — the
-- space its px offset is measured in. Matches the drag-to-centre snap math.
local function localScreenWidth(bar)
    local scale = bar.header:GetScale()
    if scale == 0 or scale == nil then scale = 1 end
    return GetScreenWidth() / scale
end

-- Default positions rely on other bars being positioned first: stance/pet read
-- Action Bar 3, and the bag bar reads the micro menu. refreshAll positions in
-- BARS order, so those always run first.
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
-- The bar sits at 0 alpha until the cursor is over it (or a flyout it spawned),
-- then rises to its configured alpha. Pure SetAlpha, never Show/Hide, so it's
-- combat-safe and never touches secure state. A 0-alpha frame still hit-tests,
-- which is what lets the hover be detected.
local MO_FADE_RATE = 4   -- alpha per second while fading (~0.25s for a full fade)
-- Below 1/255, so a difference this small can't be rendered. Used to decide the
-- bar has settled, after which the driver stops writing alpha entirely rather
-- than re-setting the same value every frame. An epsilon rather than `==`, so
-- float drift through the SetAlpha/GetAlpha round-trip can't defeat it.
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
            -- One getData per tick. It returns the live table rather than a copy, so fields
            -- read off it stay current — and this runs every frame for every mouseover bar.
            local cfg    = getData(key)
            -- cfg.mouseover is necessarily true here: the enclosing branch checked it, and
            -- any change re-runs applyMouseover, which detaches this script.
            local full   = cfg.alpha or 1
            local target = barHovered(bar) and full or 0
            local cur    = header:GetAlpha()

            -- Settled: snap off residual drift once, then do nothing on later frames.
            -- SetAlpha walks the whole child button tree, so not calling it is the point —
            -- cursor away with the bar parked at 0 is the overwhelmingly common state.
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
-- A vertical guide down the screen's centre that bars snap to while dragged,
-- hidden until something is snapped. All drag math is in the header's own
-- coordinate space, so per-bar Scale never skews where the centre is.
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
        -- Suspend mouseover fading and force full visibility while editing, or a
        -- mouseover bar sits at 0 alpha — dragging an invisible bar, with the overlay (a
        -- child of the header) invisible too.
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
-- the whole LibKeyBound button API, so keybind mode is just toggling the library.
-- Action bars only; stance/bag/micro use their native Blizzard keybinds.
local keybindActive = false
local keybindChangedCb   -- set by the settings UI to refresh its toggle button

-- LibKeyBound:IsShown() is the source of truth. This runs from our own toggle AND
-- from the library's enable/disable events — the latter catches the user closing
-- keybind mode via its own dialog (or combat auto-disabling it), which our
-- button's OnClick never sees and which left it stuck showing "ON".
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

-- This module registers no command of its own, but keybind mode is reachable by
-- one and it is the only part of the bars that is. The names are read back off
-- the globals rather than hardcoded: LibKeyBound is shared, so the copy that
-- registered them may not be ours, and listing a command nobody registered is
-- worse than listing none.
if addon.RegisterSlash then
    addon.RegisterSlash("Action Bars", function()
        if not KB then return nil end
        local cmds = {}
        local i = 1
        while _G["SLASH_LibKeyBoundSlashCOMMAND" .. i] do
            cmds[#cmds + 1] = _G["SLASH_LibKeyBoundSlashCOMMAND" .. i]
            i = i + 1
        end
        if #cmds == 0 then return nil end
        return {
            { table.concat(cmds, " | "),
              "toggle keybind mode — hover a button and press a key to bind it" },
        }
    end)
end

-- ── Drag-to-move modifier ────────────────────────────────────────────────────
-- Buttons cast on key/mouse-down, so pressing to drag would fire the ability.
-- LibActionButton's secure snippets solve this: with `buttonlock` set a button
-- only drags while the WoW PICKUPACTION modified click is held, and the on-down
-- cast is suppressed during that pickup. So lock every button and point
-- PICKUPACTION at the chosen modifier. Runtime-only (no SaveBindings), so the
-- player's saved binding is never rewritten.
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

-- Re-pushes the button config to every action button so toggling the addon-wide
-- options takes effect live. UpdateConfig sets secure attributes, so it's
-- combat-guarded.
local function applyActionButtonConfig()
    if InCombatLockdown() then pendingRefresh = true; return end
    for _, def in ipairs(BARS) do
        if def.kind == "action" then
            local b = bars[def.key]
            if b then applyButtonConfig(b) end
        end
    end
end

-- Re-derives the Blizzard-keybind overrides on every bar. Run at refresh and on
-- UPDATE_BINDINGS, which covers Key Bindings, keybind mode and binding-set swaps.
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
    -- Master switch off: leave Blizzard's bars alone entirely rather than hiding them
    -- and building ours. Turning it on later calls refreshAll() again.
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

-- Wraps a per-bar applier so the settings UI can't trigger a protected call in
-- combat — it defers a full refresh to PLAYER_REGEN_ENABLED instead. applyAlpha
-- is exempt, since SetAlpha isn't protected.
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
    -- Also re-derives the override bindings: the Next/Previous Action Bar keys
    -- are claimed (or handed back) by the same pass. refreshPagingDriver resets
    -- state-page too, so turning the option off drops any cycled page.
    applyPaging     = guarded(function(b) refreshPagingDriver(b); reassignActionBindings(b) end),
    getMover        = function(key) return bars[key] and bars[key].mover end,
    -- Turning it on runs refreshAll() immediately; turning it off just saves the
    -- flag, since a /reload is needed to restore Blizzard's bars.
    getEnabled      = function() return getGlobalData().enabled == true end,
    setEnabled      = function(v)
        v = v and true or false
        getGlobalData().enabled = v
        if v then refreshAll() end
    end,
    -- Only enabled bars get a mover box — a disabled bar is already hidden, so
    -- dragging it would move an invisible frame.
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
    -- Toggling re-pushes the button config (hotkey text switches between the
    -- Blizzard binding and our own) and rebuilds the override bindings.
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
    -- (outOfRangeHotkey, and the useGeneral opt-in itself). Setting any of them
    -- re-pushes button config to every action bar that opts in (combat-guarded).
    getGeneral = function(k) return getGlobalData()[k] end,
    setGeneral = function(k, v)
        getGlobalData()[k] = v
        applyActionButtonConfig()
    end,
    -- The keybind-text font block, handed to the settings panel to edit in place
    -- (which is why there is no setter — the panel writes into the live table and
    -- calls applyKeybindFont).
    getKeybindFont   = function() return isReady() and keybindFont() or {} end,
    applyKeybindFont = function() applyActionButtonConfig() end,
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
        addon.HookBlizzardEditMode(blizzardUnlock, blizzardLock)
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingRefresh then refreshAll() end
    elseif event == "UPDATE_BINDINGS" then
        -- The player rebound something (Key Bindings panel, keybind mode, a
        -- character/account binding-set swap) — re-point our override bindings at
        -- the new keys. LibActionButton refreshes the hotkey text on its own.
        applyActionBindings()
    end
end)
