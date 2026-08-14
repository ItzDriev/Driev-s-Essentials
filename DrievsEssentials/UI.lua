local addonName, addon = ...

local UI = {}
addon.UI = UI

-- Palette from hex bg #24263A, accent #fb2c36. Other shades are variants of the
-- bg, so the hierarchy holds without introducing unrelated hues.
local C = {
    panelBG       = { 0.141, 0.149, 0.227, 0.97 }, -- #24263A
    panelDark     = { 0.090, 0.098, 0.165, 1    },
    panelDeep     = { 0.055, 0.062, 0.115, 1    },
    red           = { 0.984, 0.173, 0.212, 1    }, -- #fb2c36
    tabIdle       = { 0.180, 0.190, 0.280, 1    },
    tabHover      = { 0.270, 0.290, 0.400, 1    },
    tabActive     = { 0.984, 0.173, 0.212, 1    },
    tabBorder     = { 0.300, 0.310, 0.420, 1    },
    tabActiveBdr  = { 1.000, 0.400, 0.450, 1    },
    checkBg       = { 0.080, 0.090, 0.150, 1    },
    checkBorder   = { 0.400, 0.420, 0.550, 1    },
    textWhite     = { 1.0, 1.0, 1.0 },
    textGrey      = { 0.75, 0.75, 0.80 },
    textDim       = { 0.50, 0.50, 0.55 },
    statusOn      = { 0.30, 0.85, 0.35, 1 },  -- enabled/on indicator dots
    statusOff     = { 0.45, 0.45, 0.50, 1 },  -- disabled/off indicator dots
}

-- ── Recolouring ─────────────────────────────────────────────────────────────
-- Every entry above is a live table shared by reference with each module addon,
-- so recolouring edits them IN PLACE and anything holding a reference picks the
-- new value up for free.
--
-- What that misses is anything already painted, so the tint helpers record which
-- palette entry each object was last painted from. ApplyPalette repaints only
-- objects still showing the old value, leaving anything since recoloured by
-- other means (a class-tinted bar, a hidden border) alone.
local PALETTE_DEFAULT = {}   -- key -> the shipped colour, for "reset"
local PALETTE_KEY     = {}   -- live colour table -> key, for the repaint check
for key, live in pairs(C) do
    PALETTE_DEFAULT[key] = { live[1], live[2], live[3], live[4] }
    PALETTE_KEY[live]    = key
end

-- Display order and labels for the colour picker, grouped so the entries someone
-- actually wants to change come first.
UI.paletteOrder = {
    { key = "red",          label = "Accent"            },
    { key = "panelBG",      label = "Window"            },
    { key = "panelDark",    label = "Sidebar / top bar" },
    { key = "panelDeep",    label = "Content area"      },
    { key = "textWhite",    label = "Text"              },
    { key = "textGrey",     label = "Text: label"       },
    { key = "textDim",      label = "Text: hint"        },
    { key = "tabIdle",      label = "Tab"               },
    { key = "tabHover",     label = "Tab: hover"        },
    { key = "tabActive",    label = "Tab: active"       },
    { key = "tabBorder",    label = "Border"            },
    { key = "tabActiveBdr", label = "Border: active"    },
    { key = "checkBg",      label = "Checkbox"          },
    { key = "checkBorder",  label = "Checkbox border"   },
    { key = "statusOn",     label = "Status: on"        },
    { key = "statusOff",    label = "Status: off"       },
}

-- Pulls a colour a third of the way to white. The active-tab border is a lighter
-- tint of the accent everywhere, so presets and themes derive it rather than
-- carrying a second value that can drift out of step.
local function lighten(v) return v + (1 - v) * 0.35 end

-- Accent-only presets. The neutral shades are hand-tuned against each other, so
-- a preset swaps just the three entries carrying the hue.
UI.palettePresets = {
    { name = "Crimson", rgb = { 0.984, 0.173, 0.212 } },  -- shipped default
    { name = "Azure",   rgb = { 0.204, 0.545, 0.965 } },
    { name = "Violet",  rgb = { 0.639, 0.396, 0.980 } },
    { name = "Jade",    rgb = { 0.184, 0.769, 0.518 } },
    { name = "Amber",   rgb = { 0.976, 0.639, 0.153 } },
    { name = "Steel",   rgb = { 0.545, 0.596, 0.702 } },
}

-- Full-palette themes, where the accent presets above only re-hue. Built from
-- two neutral ramps crossed with two accents rather than written out four times.
-- Each ramp keeps the shipped ordering — panelBG lightest, panelDeep darkest —
-- so the hierarchy survives a theme change.
local VOID_RAMP = {
    bg          = { 0.031, 0.031, 0.043 },
    dark        = { 0.016, 0.016, 0.024 },
    deep        = { 0.004, 0.004, 0.008 },
    tabIdle     = { 0.055, 0.055, 0.071 },
    tabHover    = { 0.118, 0.118, 0.149 },
    border      = { 0.157, 0.157, 0.196 },
    checkBg     = { 0.027, 0.027, 0.039 },
    checkBorder = { 0.220, 0.220, 0.263 },
    text        = { 1.000, 1.000, 1.000 },
    textGrey    = { 0.720, 0.720, 0.755 },
    textDim     = { 0.440, 0.440, 0.480 },
}

local BLACK_RAMP = {
    bg          = { 0.078, 0.078, 0.102 },
    dark        = { 0.047, 0.047, 0.063 },
    deep        = { 0.024, 0.024, 0.031 },
    tabIdle     = { 0.106, 0.106, 0.133 },
    tabHover    = { 0.176, 0.176, 0.216 },
    border      = { 0.216, 0.216, 0.263 },
    checkBg     = { 0.063, 0.063, 0.082 },
    checkBorder = { 0.286, 0.286, 0.337 },
    text        = { 1.000, 1.000, 1.000 },
    textGrey    = { 0.750, 0.750, 0.780 },
    textDim     = { 0.470, 0.470, 0.510 },
}

local DARK_RAMP = {
    bg          = { 0.141, 0.141, 0.173 },
    dark        = { 0.098, 0.098, 0.125 },
    deep        = { 0.063, 0.063, 0.082 },
    tabIdle     = { 0.180, 0.180, 0.220 },
    tabHover    = { 0.259, 0.259, 0.310 },
    border      = { 0.310, 0.310, 0.365 },
    checkBg     = { 0.110, 0.110, 0.137 },
    checkBorder = { 0.384, 0.384, 0.439 },
    text        = { 1.000, 1.000, 1.000 },
    textGrey    = { 0.780, 0.780, 0.810 },
    textDim     = { 0.520, 0.520, 0.560 },
}

local ACCENT_RED   = { 0.984, 0.173, 0.212 }
local ACCENT_AZURE = { 0.204, 0.545, 0.965 }

local function buildTheme(name, ramp, accent)
    return {
        name   = name,
        colors = {
            panelBG      = ramp.bg,
            panelDark    = ramp.dark,
            panelDeep    = ramp.deep,
            tabIdle      = ramp.tabIdle,
            tabHover     = ramp.tabHover,
            tabBorder    = ramp.border,
            checkBg      = ramp.checkBg,
            checkBorder  = ramp.checkBorder,
            textWhite    = ramp.text,
            textGrey     = ramp.textGrey,
            textDim      = ramp.textDim,
            red          = accent,
            tabActive    = accent,
            tabActiveBdr = { lighten(accent[1]), lighten(accent[2]), lighten(accent[3]) },
            statusOn     = { 0.30, 0.85, 0.35 },
            statusOff    = { 0.45, 0.45, 0.50 },
        },
    }
end

-- Ordered darkest to lightest within each accent, and laid out three to a row
-- by the popup below, so each row is one accent's ramp read left to right.
UI.themePresets = {
    buildTheme("Void Red",    VOID_RAMP,  ACCENT_RED),
    buildTheme("Black Red",   BLACK_RAMP, ACCENT_RED),
    buildTheme("Dark Red",    DARK_RAMP,  ACCENT_RED),
    buildTheme("Void Azure",  VOID_RAMP,  ACCENT_AZURE),
    buildTheme("Black Azure", BLACK_RAMP, ACCENT_AZURE),
    buildTheme("Dark Azure",  DARK_RAMP,  ACCENT_AZURE),
}

local tinted = {}   -- every object a tint helper has painted, in paint order

local function record(obj, field, color)
    -- One-off colours (the white backing of a swatch, a 0-alpha border) aren't
    -- palette entries and must never be repainted.
    if not PALETTE_KEY[color] then return end
    if not obj.deTinted then
        obj.deTinted = true
        tinted[#tinted + 1] = obj
    end
    obj[field] = color
end

function UI.tint(obj, color)
    record(obj, "deTintText", color)
    obj:SetTextColor(unpack(color))
end

function UI.tintBg(frame, color)
    record(frame, "deTintBg", color)
    frame:SetBackdropColor(unpack(color))
end

function UI.tintBorder(frame, color)
    record(frame, "deTintBorder", color)
    frame:SetBackdropBorderColor(unpack(color))
end

function UI.tintTexture(tex, color)
    record(tex, "deTintVertex", color)
    tex:SetVertexColor(unpack(color))
end

-- Colour components are floats the client rounds on the way in and out, so an
-- exact == against what we set is unreliable; a tolerance under one 8-bit step is.
local function sameColor(color, r, g, b, a)
    if not color then return false end
    local function near(x, y) return math.abs((x or 0) - (y or 0)) < 0.004 end
    if not (near(color[1], r) and near(color[2], g) and near(color[3], b)) then return false end
    -- A 3-component entry never set an alpha, so it can't disagree about one.
    return color[4] == nil or near(color[4], a)
end

-- `old` maps key -> the colour each entry held before ApplyPalette overwrote it.
local function repaint(old)
    for i = 1, #tinted do
        local o = tinted[i]

        local c = o.deTintText
        if c and o.GetTextColor and sameColor(old[PALETTE_KEY[c]], o:GetTextColor()) then
            o:SetTextColor(unpack(c))
        end

        c = o.deTintBg
        if c and o.GetBackdropColor and sameColor(old[PALETTE_KEY[c]], o:GetBackdropColor()) then
            o:SetBackdropColor(unpack(c))
        end

        c = o.deTintBorder
        if c and o.GetBackdropBorderColor and sameColor(old[PALETTE_KEY[c]], o:GetBackdropBorderColor()) then
            o:SetBackdropBorderColor(unpack(c))
        end

        c = o.deTintVertex
        if c and o.GetVertexColor and sameColor(old[PALETTE_KEY[c]], o:GetVertexColor()) then
            o:SetVertexColor(unpack(c))
        end
    end
end

local function savedColors()
    local s = addon.db and addon.db.settings
    return s and s.uiColors
end

-- Re-derives the palette from the active profile (falling back to the shipped
-- colour) and repaints what's on screen. Called on login, after a profile
-- switch, and after every swatch edit.
function UI.ApplyPalette()
    local saved = savedColors()
    local old   = {}
    for key, live in pairs(C) do
        old[key] = { live[1], live[2], live[3], live[4] }
        local src = (saved and saved[key]) or PALETTE_DEFAULT[key]
        for i = 1, 4 do live[i] = src[i] end
    end
    repaint(old)
end

-- `a` is optional; omitted, the entry keeps the transparency it already has.
function UI.SetPaletteColor(key, r, g, b, a)
    local def  = PALETTE_DEFAULT[key]
    local live = C[key]
    local s    = addon.db and addon.db.settings
    if not (def and s) then return end
    s.uiColors = s.uiColors or {}
    s.uiColors[key] = { r, g, b, a or live[4] or def[4] or 1 }
    UI.ApplyPalette()
end

function UI.ResetPaletteColor(key)
    local s = addon.db and addon.db.settings
    if not (s and s.uiColors) then return end
    s.uiColors[key] = nil
    UI.ApplyPalette()
end

function UI.ResetPalette()
    local s = addon.db and addon.db.settings
    if not s then return end
    s.uiColors = {}
    UI.ApplyPalette()
end

-- The accent shows up as three entries — itself, the active tab fill and the
-- active border (a lighter tint) — so a preset sets all three from one hue.
function UI.ApplyPalettePreset(rgb)
    local s = addon.db and addon.db.settings
    if not s then return end
    s.uiColors = s.uiColors or {}
    local r, g, b = rgb[1], rgb[2], rgb[3]
    -- Hue only: whatever transparency each of the three is carrying survives a
    -- preset, so picking a new accent doesn't quietly undo an opacity setting.
    s.uiColors.red          = { r, g, b, C.red[4] or 1 }
    s.uiColors.tabActive    = { r, g, b, C.tabActive[4] or 1 }
    s.uiColors.tabActiveBdr = { lighten(r), lighten(g), lighten(b), C.tabActiveBdr[4] or 1 }
    UI.ApplyPalette()
end

-- A theme replaces the whole override set rather than layering: otherwise a
-- colour changed by hand under an earlier theme would survive and nothing would
-- match its preview. Alpha is the exception — themes carry RGB only.
function UI.ApplyTheme(theme)
    local s = addon.db and addon.db.settings
    if not (s and theme and theme.colors) then return end
    s.uiColors = {}
    for key, rgb in pairs(theme.colors) do
        local live = C[key]
        if live then
            s.uiColors[key] = { rgb[1], rgb[2], rgb[3], live[4] or PALETTE_DEFAULT[key][4] }
        end
    end
    UI.ApplyPalette()
end

function UI.GetPaletteColor(key)
    local c = C[key] or PALETTE_DEFAULT[key]
    if not c then return 1, 1, 1, 1 end
    return c[1], c[2], c[3], c[4] or 1
end

-- The three shades the window is built from, sharing one "window opacity"
-- control rather than dialling the same alpha into three entries by hand.
local WINDOW_SHADES = { "panelBG", "panelDark", "panelDeep" }

function UI.GetWindowOpacity()
    return math.floor((C.panelBG[4] or 1) * 100 + 0.5)
end

function UI.SetWindowOpacity(pct)
    local s = addon.db and addon.db.settings
    if not s then return end
    -- Floored well clear of zero: a fully transparent window is still there, still
    -- on top and still swallowing clicks, with nothing on screen to say so.
    -- Per-entry alpha can go to 0; the window itself can't.
    local a = math.max(0.1, math.min(1, (pct or 100) / 100))
    s.uiColors = s.uiColors or {}
    for _, key in ipairs(WINDOW_SHADES) do
        local c = C[key]
        s.uiColors[key] = { c[1], c[2], c[3], a }
    end
    UI.ApplyPalette()
end

local WHITE = "Interface\\Buttons\\WHITE8x8"

-- Insets matching edgeSize pull the background in from the frame's edge, so the
-- border frames it cleanly instead of drawing flush against a full-bleed one.
local function applyBackdrop(frame, edgeSize, bg, border)
    edgeSize = edgeSize or 1
    frame:SetBackdrop({
        bgFile   = WHITE,
        edgeFile = WHITE,
        edgeSize = edgeSize,
        insets   = { left = edgeSize, right = edgeSize, top = edgeSize, bottom = edgeSize },
    })
    -- Through the tint helpers so a later recolour can repaint them; both are no-ops
    -- for the one-off colours some callers pass instead of a palette entry.
    UI.tintBg(frame, bg)
    UI.tintBorder(frame, border or { 0, 0, 0, 0 })
end

-- Hover help, so a setting's explanation lives in a tooltip rather than as grey
-- body text. `body` takes a string or a list of paragraphs, and an empty one
-- attaches nothing — which is what lets the widget factories pass an optional
-- `desc` straight through without every caller guarding it.
--
-- HookScript, not SetScript: widgets set their own OnEnter/OnLeave for the hover
-- highlight, and replacing those would trade the border glow for the tooltip.
local function attachTooltip(widget, title, body)
    if not widget then return end
    local lines = type(body) == "table" and body or { body }
    local hasBody = false
    for _, para in ipairs(lines) do
        if para and para ~= "" then hasBody = true; break end
    end
    if not hasBody then return end

    widget:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local titled = title and title ~= ""
        if titled then GameTooltip:AddLine(title, 1, 1, 1) end
        for _, para in ipairs(lines) do
            if para and para ~= "" then
                if titled then GameTooltip:AddLine(" ") end
                GameTooltip:AddLine(para, 0.75, 0.75, 0.75, true)
            end
        end
        GameTooltip:Show()
    end)
    widget:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

-- Reusable tab button. OnClick is attached by the caller so the same factory
-- works for top-level and sub-tabs.
local function createTab(parent, label, width)
    local tab = CreateFrame("Button", nil, parent, "BackdropTemplate")
    tab:SetSize(width or 110, 24)
    applyBackdrop(tab, 1, C.tabIdle, C.tabBorder)

    local text = tab:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("CENTER")
    text:SetText(label)
    UI.tint(text, C.textGrey)
    tab.text = text

    tab:SetScript("OnEnter", function(self)
        if not self.active then UI.tintBg(self, C.tabHover) end
    end)
    tab:SetScript("OnLeave", function(self)
        if not self.active then UI.tintBg(self, C.tabIdle) end
    end)
    return tab
end

-- Tall, full-width, left-aligned tab for a vertical sidebar. Caller anchors it
-- and wires OnClick; shares tab.text + backdrop so activateTab() drives its look.
local function createSideTab(parent, label, height)
    local tab = CreateFrame("Button", nil, parent, "BackdropTemplate")
    tab:SetHeight(height or 28)
    applyBackdrop(tab, 1, C.tabIdle, C.tabBorder)

    local text = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    text:SetPoint("LEFT", 14, 0)
    text:SetText(label)
    UI.tint(text, C.textGrey)
    tab.text = text

    tab:SetScript("OnEnter", function(self)
        if not self.active then UI.tintBg(self, C.tabHover) end
    end)
    tab:SetScript("OnLeave", function(self)
        if not self.active then UI.tintBg(self, C.tabIdle) end
    end)
    return tab
end

-- Flat action button: dark backdrop, centred white label, red hover border.
-- `.label` is exposed for buttons that recolour or relabel it.
local function flatButton(parent, text, w, h, font)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(w or 80, h or 22)
    applyBackdrop(btn, 1, C.panelDark, C.tabBorder)
    local label = btn:CreateFontString(nil, "OVERLAY", font or "GameFontNormal")
    label:SetPoint("CENTER")
    label:SetText(text or "")
    UI.tint(label, C.textWhite)
    btn.label = label
    btn:SetScript("OnEnter", function(self) UI.tintBorder(self, C.red) end)
    btn:SetScript("OnLeave", function(self) UI.tintBorder(self, C.tabBorder) end)
    return btn
end

-- The red "X" in a popup's top-right. `inset` is how far in it sits — the popups
-- use 8, the position editor 6, which is all that differs between them.
local function closeButton(panel, inset)
    local btn = CreateFrame("Button", nil, panel)
    btn:SetSize(18, 18)
    btn:SetPoint("TOPRIGHT", -(inset or 8), -(inset or 8))
    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("CENTER"); label:SetText("X"); UI.tint(label, C.red)
    btn:SetScript("OnEnter", function() UI.tint(label, C.textWhite) end)
    btn:SetScript("OnLeave", function() UI.tint(label, C.red) end)
    btn:SetScript("OnClick", function() panel:Hide() end)
    return btn
end

-- A themed [-] [value] [+] stepper. +/- adjust opts.get()/set() by opts.step;
-- the box also takes typing (Enter commits, Escape reverts). Either path clamps
-- to [min, max], re-renders through opts.format, then runs opts.onChange(v).
-- Returns the minus button as the layout handle, with `.value`/`.plus` for
-- anchoring a suffix and `.Refresh()`. opts.get must always return a number.
local function buildStepper(parent, opts)
    local step = opts.step or 1
    local fmt  = opts.format or tostring
    local gap  = opts.gap or 6

    local minus = CreateFrame("Button", nil, parent, "BackdropTemplate")
    minus:SetSize(22, 22)
    applyBackdrop(minus, 1, C.panelDark, C.tabBorder)
    local ml = minus:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ml:SetPoint("CENTER"); ml:SetText("-"); UI.tint(ml, C.textWhite)

    -- Bordered like every other numeric input here, so it reads as something you can
    -- click into rather than a plain label.
    local value = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    value:SetPoint("LEFT", minus, "RIGHT", gap, 0)
    value:SetSize(opts.valueWidth or 24, 20)
    applyBackdrop(value, 1, C.panelDark, C.tabBorder)
    value:SetAutoFocus(false)
    value:SetJustifyH("CENTER")
    value:SetFontObject(opts.valueFont or "GameFontNormal")
    UI.tint(value, opts.valueColor or C.textWhite)
    value:SetTextInsets(2, 2, 0, 0)
    value:SetMaxLetters(10)

    local plus = CreateFrame("Button", nil, parent, "BackdropTemplate")
    plus:SetSize(22, 22)
    plus:SetPoint("LEFT", value, "RIGHT", gap, 0)
    applyBackdrop(plus, 1, C.panelDark, C.tabBorder)
    local pl = plus:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pl:SetPoint("CENTER"); pl:SetText("+"); UI.tint(pl, C.textWhite)

    -- Re-reads the stored value unless the user is mid-edit, or a background refresh
    -- would yank the cursor out of what they're typing.
    local function refresh()
        if not value:HasFocus() then value:SetText(fmt(opts.get())) end
    end
    local function commit(v)
        v = math.min(opts.max, math.max(opts.min, v))
        v = math.floor(v * 1000 + 0.5) / 1000   -- kill float drift on fractional steps
        opts.set(v)
        refresh()
        if opts.onChange then opts.onChange(v) end
    end
    local function adjust(delta) commit(opts.get() + delta) end
    minus:SetScript("OnClick", function() adjust(-step) end)
    plus:SetScript("OnClick",  function() adjust(step) end)
    minus:SetScript("OnEnter", function() UI.tintBorder(minus, C.red) end)
    minus:SetScript("OnLeave", function() UI.tintBorder(minus, C.tabBorder) end)
    plus:SetScript("OnEnter",  function() UI.tintBorder(plus, C.red) end)
    plus:SetScript("OnLeave",  function() UI.tintBorder(plus, C.tabBorder) end)

    -- Invalid text (empty, non-numeric) just reverts to the current value rather
    -- than erroring or silently zeroing the setting.
    local function commitBox()
        local n = tonumber(value:GetText())
        if n then commit(n) else refresh() end
        value:ClearFocus()
    end
    value:SetScript("OnEnterPressed",   commitBox)
    value:SetScript("OnEditFocusLost",  commitBox)
    value:SetScript("OnEscapePressed",  function() refresh(); value:ClearFocus() end)
    value:SetScript("OnEditFocusGained", function() value:HighlightText() end)
    value:SetScript("OnEnter", function() if not value:HasFocus() then UI.tintBorder(value, C.red) end end)
    value:SetScript("OnLeave", function() if not value:HasFocus() then UI.tintBorder(value, C.tabBorder) end end)

    minus.plus, minus.value, minus.Refresh = plus, value, refresh
    refresh()
    return minus
end

-- Generic tab/panel switcher for top-level tabs and sub-tabs alike.
--
-- A panels[key] entry is either a finished frame or a builder function. Builders
-- run on first activation and cache back, so a tab nobody opens costs nothing.
-- Building every panel up front is tens of thousands of frames in one call,
-- which trips Blizzard's "script ran too long" watchdog on a slow machine.
local function resolvePanel(panels, key)
    local panel = panels[key]
    if type(panel) == "function" then
        panel = panel()
        panels[key] = panel
    end
    return panel
end

local function activateTab(tabs, panels, key)
    for k, tab in pairs(tabs) do
        local active = (k == key)
        tab.active = active
        if active then
            UI.tintBg(tab, C.tabActive)
            UI.tintBorder(tab, C.tabActiveBdr)
            UI.tint(tab.text, C.textWhite)
        else
            UI.tintBg(tab, C.tabIdle)
            UI.tintBorder(tab, C.tabBorder)
            UI.tint(tab.text, C.textGrey)
        end
    end
    -- Resolve before the loop: hiding the others must not force them to build.
    local target = resolvePanel(panels, key)
    for k, panel in pairs(panels) do
        if k ~= key and type(panel) ~= "function" then panel:Hide() end
    end
    if target then target:Show() end
end

local function selectTab(frame, key)
    frame.activeTab = key
    activateTab(frame.tabs, frame.panels, key)
end

local function selectSubTab(parent, key)
    parent.activeSubTab = key
    activateTab(parent.subTabs, parent.subPanels, key)
end

-- The standard sub-tab shell: a row of tabs over a content area, used by every
-- module tab with sub-tabs so insets and framing match.
--
--   opts.barHeight — for a module laying its tabs out differently (default 26)
--   opts.hidden    — start hidden, for tabs built before first selection
--
-- Returns the panel, its tab bar (modules sometimes park a control there), the
-- frame sub-panels parent to, and addSubTab(key, label, width, panel).
--
-- Prefer passing `panel` as a BUILDER FUNCTION taking the content frame, so it's
-- built on first open — building every sub-tab up front trips the watchdog. An
-- already-built frame is accepted for panels a module must construct in place.
local function makeSubTabPanel(parent, opts)
    opts = opts or {}
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()
    if opts.hidden then panel:Hide() end

    local subBar = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    subBar:SetHeight(opts.barHeight or 26)
    subBar:SetPoint("TOPLEFT", 4, -4)
    subBar:SetPoint("TOPRIGHT", -4, -4)
    applyBackdrop(subBar, 1, C.panelDark)

    local subContent = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    subContent:SetPoint("TOPLEFT", subBar, "BOTTOMLEFT", 0, -2)
    subContent:SetPoint("BOTTOMRIGHT", -4, 4)
    applyBackdrop(subContent, 1, C.panelDeep)

    panel.subTabs, panel.subPanels = {}, {}

    local previous
    local function addSubTab(key, label, width, builder)
        local tab = createTab(subBar, label, width)
        tab:SetHeight(22)
        if previous then
            tab:SetPoint("LEFT", previous, "RIGHT", 4, 0)
        else
            tab:SetPoint("LEFT", 4, 0)
        end
        tab:SetScript("OnClick", function() selectSubTab(panel, key) end)
        panel.subTabs[key]   = tab
        panel.subPanels[key] = type(builder) == "function"
            and function() return builder(subContent) end
            or builder
        previous = tab
        return tab
    end

    return panel, subBar, subContent, addSubTab
end

-- ── Scrollable panels ────────────────────────────────────────────────────────
-- Themed, draggable scrollbar for an existing ScrollFrame. `trackParent` is what
-- the track's right edge anchors to. Returns an `update()` to call whenever the
-- scroll child's content height changes.
local SCROLLBAR_W = 10
-- Keeps a scrollbar track clear of the window's resize grip. Only outer panels
-- reaching that corner opt in via `bottomInset`.
local SCROLLBAR_BOTTOM_CLEARANCE = 16

local function attachScrollTrack(scroll, trackParent, bottomInset)
    local track = CreateFrame("Frame", nil, trackParent, "BackdropTemplate")
    track:SetWidth(SCROLLBAR_W)
    track:SetPoint("TOPRIGHT",    trackParent, "TOPRIGHT",    -1, -1)
    track:SetPoint("BOTTOMRIGHT", trackParent, "BOTTOMRIGHT", -1,  bottomInset or 1)
    applyBackdrop(track, 1, C.panelDeep, C.tabBorder)

    local thumb = CreateFrame("Button", nil, track, "BackdropTemplate")
    thumb:SetWidth(SCROLLBAR_W - 2)
    applyBackdrop(thumb, 1, C.tabIdle, C.tabBorder)
    thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 1, 0)

    -- Track is always visible rather than hidden on maxScroll<=0:
    -- GetVerticalScrollRange() isn't reliable until the frame is laid out, so hiding
    -- on it produced a track that silently never appeared.
    local function update()
        track:Show()
        local trackH = track:GetHeight()
        if trackH <= 0 then return end
        -- GetVerticalScrollRange() can return a stale value until the scroll-child rect
        -- is explicitly recomputed — the real fix for the thumb reading wrong until the
        -- user scrolls once.
        if scroll.UpdateScrollChildRect then scroll:UpdateScrollChildRect() end
        local maxScroll = scroll:GetVerticalScrollRange()
        if maxScroll <= 0 then
            if scroll:GetVerticalScroll() ~= 0 then scroll:SetVerticalScroll(0) end
            thumb:SetHeight(trackH)
            thumb:ClearAllPoints()
            thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 1, 0)
            return
        end
        local visibleH = scroll:GetHeight()
        local thumbH   = math.max(16, trackH * visibleH / (visibleH + maxScroll))
        local cur      = scroll:GetVerticalScroll()
        -- Shrinking the window while scrolled near the bottom leaves the offset past the
        -- new range; without reclamping, frac exceeds 1 and the thumb is pushed off the
        -- track, flickering on every resize tick.
        if cur > maxScroll then
            cur = maxScroll
            scroll:SetVerticalScroll(cur)
        elseif cur < 0 then
            cur = 0
            scroll:SetVerticalScroll(cur)
        end
        local frac = cur / maxScroll
        thumb:SetHeight(thumbH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 1, -(frac * (trackH - thumbH)))
    end

    local isDragging, dragStartY, dragStartScroll = false, 0, 0
    thumb:EnableMouse(true)
    thumb:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then
            isDragging      = true
            dragStartY      = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
            dragStartScroll = scroll:GetVerticalScroll()
        end
    end)
    thumb:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then isDragging = false end
    end)
    thumb:SetScript("OnUpdate", function()
        if not isDragging then return end
        local curY      = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
        local delta      = dragStartY - curY
        local trackH     = track:GetHeight()
        local thumbH     = thumb:GetHeight()
        local maxScroll  = scroll:GetVerticalScrollRange()
        if trackH > thumbH and maxScroll > 0 then
            scroll:SetVerticalScroll(math.max(0, math.min(
                dragStartScroll + delta * maxScroll / (trackH - thumbH),
                maxScroll
            )))
            update()
        end
    end)
    thumb:SetScript("OnEnter", function(self) UI.tintBg(self, C.tabHover) end)
    thumb:SetScript("OnLeave", function(self) UI.tintBg(self, C.tabIdle)  end)

    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(_, d)
        local maxScroll = scroll:GetVerticalScrollRange()
        scroll:SetVerticalScroll(math.max(0, math.min(scroll:GetVerticalScroll() - d * 30, maxScroll)))
        update()
    end)

    return track, update
end

-- Recursively finds the lowest bottom edge among a frame's descendants — child
-- frames AND directly-drawn regions, since a checkbox row's label is a region on
-- the row, not on `inner`. A fixed height taller than the content makes
-- GetVerticalScrollRange() always report room to scroll.
local function findLowestBottom(frame, bottom)
    for _, child in ipairs({ frame:GetChildren() }) do
        local cb = child:GetBottom()
        if cb and (not bottom or cb < bottom) then bottom = cb end
        -- Don't descend into a nested ScrollFrame: it clips its own taller child, so only
        -- its visible bottom edge counts — otherwise the outer panel grows to fit the
        -- inner content and scrolls into empty space.
        if child:GetObjectType() ~= "ScrollFrame" then
            bottom = findLowestBottom(child, bottom)
        end
    end
    for _, region in ipairs({ frame:GetRegions() }) do
        if region.GetBottom then
            local rb = region:GetBottom()
            if rb and (not bottom or rb < bottom) then bottom = rb end
        end
    end
    return bottom
end

-- Floored at the scroll frame's visible height, so a short panel never becomes
-- "scrollable" into empty space.
local function fitInnerHeight(inner, scroll)
    local top = inner:GetTop()
    if not top then return end
    local bottom = findLowestBottom(inner, nil)
    local visibleH = scroll:GetHeight() or 0
    local contentH = bottom and math.max(1, top - bottom + 20) or visibleH
    inner:SetHeight(math.max(contentH, visibleH))
end

-- Wraps a tab's content in a scrollable area. Returns (shell, inner): `shell`
-- behaves exactly like the old flat panel (anchor it, SetShown it, hang an
-- OnShow off it), and `inner` is what the widgets are created on.
local function makeScrollPanel(parent, innerHeight)
    local shell = CreateFrame("Frame", nil, parent)
    shell:SetAllPoints()
    shell:Hide()

    local scroll = CreateFrame("ScrollFrame", nil, shell)
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", -(SCROLLBAR_W + 6), 0)

    local inner = CreateFrame("Frame", nil, scroll)
    inner:SetHeight(innerHeight or 1600)
    scroll:SetScrollChild(inner)

    local _, update = attachScrollTrack(scroll, shell, SCROLLBAR_BOTTOM_CLEARANCE)

    -- fitInnerHeight resizes `inner`, re-triggering its OnSizeChanged below — that
    -- handler only calls update(), never fitInnerHeight, so this can't recurse.
    local function refreshScroll()
        fitInnerHeight(inner, scroll)
        update()
    end

    scroll:SetScript("OnSizeChanged", function(self, w)
        inner:SetWidth(w)
        refreshScroll()
    end)
    inner:SetScript("OnSizeChanged", update)
    -- GetVerticalScrollRange() isn't reliable until the frame is visible, so the
    -- first pass (from OnSizeChanged, which can fire while still hidden) can
    -- under-report. HookScript rather than SetScript, so the caller's own OnShow
    -- refresh isn't clobbered. GetTop()/GetBottom() can ALSO be stale on the very
    -- frame a panel is first shown, settling one frame later — which is why
    -- scrolling appeared to "fix" it — so a second pass is deferred via C_Timer.
    shell:HookScript("OnShow", function()
        refreshScroll()
        C_Timer.After(0, refreshScroll)
    end)

    -- Third return value lets a caller re-fit the scroll child after adding
    -- or removing rows while the panel is already shown (rebuilding a list
    -- doesn't fire OnShow/OnSizeChanged on its own).
    return shell, inner, refreshScroll
end

-- Custom dark/red themed checkbox. The whole row is clickable. `desc` is
-- optional hover help (string or list of paragraphs) shown under the label in a
-- tooltip, so an explanation never has to be laid out as body text in the panel.
local function createCheckbox(parent, label, width, desc)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(width or 200, 20)

    local box = CreateFrame("Frame", nil, row, "BackdropTemplate")
    box:SetSize(14, 14)
    box:SetPoint("LEFT", 0, 0)
    applyBackdrop(box, 1, C.checkBg, C.checkBorder)

    local fill = box:CreateTexture(nil, "ARTWORK")
    fill:SetTexture(WHITE)
    fill:SetPoint("TOPLEFT", 2, -2)
    fill:SetPoint("BOTTOMRIGHT", -2, 2)
    UI.tintTexture(fill, C.red)
    fill:Hide()

    local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("LEFT", box, "RIGHT", 6, 0)
    text:SetText(label)
    UI.tint(text, C.textWhite)

    row.box, row.fill, row.text = box, fill, text
    row.checked = false

    function row:SetChecked(v)
        self.checked = v and true or false
        if self.checked then fill:Show() else fill:Hide() end
    end
    function row:GetChecked() return self.checked end

    row:SetScript("OnEnter", function() UI.tintBorder(box, C.red) end)
    row:SetScript("OnLeave", function() UI.tintBorder(box, C.checkBorder) end)
    row:SetScript("OnClick", function(self)
        self:SetChecked(not self.checked)
        if self.OnChange then self:OnChange(self.checked) end
    end)
    attachTooltip(row, label, desc)
    return row
end

-- A clickable colour swatch opening WoW's native picker, RGB only — every panel
-- keeps opacity on its own stepper, so the two never fight over one value.
-- Handles both the modern SetupColorPickerAndShow API and the older field-based
-- one, since which exists varies across Classic Era builds. :Refresh() re-reads.
--
-- opts.size — square edge length (default 20)
-- opts.hover — highlight the border red under the cursor
local function createColorSwatch(parent, getRGB, setRGB, onChange, opts)
    opts = opts or {}
    local sw = CreateFrame("Button", nil, parent, "BackdropTemplate")
    sw:SetSize(opts.size or 20, opts.size or 20)
    applyBackdrop(sw, 1, { 1, 1, 1 }, C.tabBorder)

    local function paint()
        local r, g, b = getRGB()
        sw:SetBackdropColor(r or 1, g or 1, b or 1, 1)
    end

    sw:SetScript("OnClick", function()
        local r, g, b = getRGB()
        local function apply()
            local nr, ng, nb = ColorPickerFrame:GetColorRGB()
            setRGB(nr, ng, nb); paint(); if onChange then onChange() end
        end
        local function cancel()
            setRGB(r, g, b); paint(); if onChange then onChange() end
        end
        if ColorPickerFrame.SetupColorPickerAndShow then
            ColorPickerFrame:SetupColorPickerAndShow({
                r = r, g = g, b = b, hasOpacity = false,
                swatchFunc = apply, cancelFunc = cancel,
            })
        else
            ColorPickerFrame.hasOpacity = false
            ColorPickerFrame.func       = apply
            ColorPickerFrame.cancelFunc = cancel
            ColorPickerFrame:SetColorRGB(r, g, b)
            ColorPickerFrame:Hide() -- force OnShow to refire with these values
            ColorPickerFrame:Show()
        end
    end)

    if opts.hover then
        sw:SetScript("OnEnter", function(s) UI.tintBorder(s, C.red) end)
        sw:SetScript("OnLeave", function(s) UI.tintBorder(s, C.tabBorder) end)
    end

    sw.Refresh = paint
    paint()
    return sw
end

-- Compact themed dropdown. options = array of { value, label }. The pop-out list
-- is parented to UIParent (so the settings scroll frame can't clip it) at DIALOG
-- strata, with a full-screen catcher behind it to close on an outside click; it
-- also closes if the dropdown is hidden. :Refresh() re-reads the value.
-- tipTitle/tipBody are hover help — unlike a checkbox, a dropdown has no label
-- of its own, so the title must be passed in.
local function createDropdown(parent, width, options, getVal, setVal, onSelect, tipTitle, tipBody)
    local dd = CreateFrame("Button", nil, parent, "BackdropTemplate")
    dd:SetSize(width, 22)
    applyBackdrop(dd, 1, C.panelDark, C.tabBorder)

    local text = dd:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", 8, 0)
    UI.tint(text, C.textWhite)

    local arrow = dd:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
    arrow:SetSize(16, 16)
    arrow:SetPoint("RIGHT", -4, -1)

    local catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("DIALOG")
    catcher:Hide()

    local menu = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    menu:SetFrameStrata("DIALOG")
    menu:SetFrameLevel(catcher:GetFrameLevel() + 10)
    menu:SetPoint("TOPLEFT",  dd, "BOTTOMLEFT",  0, -2)
    menu:SetPoint("TOPRIGHT", dd, "BOTTOMRIGHT", 0, -2)
    menu:SetHeight(#options * 22 + 2)
    applyBackdrop(menu, 1, C.panelBG, C.tabBorder)
    menu:Hide()

    local function labelFor(val)
        for _, o in ipairs(options) do if o.value == val then return o.label end end
        return options[1] and options[1].label or ""
    end
    local function refresh() text:SetText(labelFor(getVal())) end
    local function close() menu:Hide(); catcher:Hide() end

    for i, o in ipairs(options) do
        local item = CreateFrame("Button", nil, menu, "BackdropTemplate")
        item:SetPoint("TOPLEFT", menu, "TOPLEFT", 1, -1 - (i - 1) * 22)
        item:SetPoint("RIGHT",   menu, "RIGHT",  -1, 0)
        item:SetHeight(22)
        applyBackdrop(item, 1, C.panelDark, { 0, 0, 0, 0 })
        local il = item:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        il:SetPoint("LEFT", 8, 0); il:SetText(o.label); UI.tint(il, C.textWhite)
        item:SetScript("OnEnter", function() UI.tintBg(item, C.tabHover) end)
        item:SetScript("OnLeave", function() UI.tintBg(item, C.panelDark) end)
        item:SetScript("OnClick", function()
            setVal(o.value); refresh(); close()
            if onSelect then onSelect(o.value) end
        end)
    end

    dd:SetScript("OnClick", function()
        if menu:IsShown() then close() else menu:Show(); catcher:Show() end
    end)
    dd:SetScript("OnEnter", function() UI.tintBorder(dd, C.red) end)
    dd:SetScript("OnLeave", function() UI.tintBorder(dd, C.tabBorder) end)
    dd:SetScript("OnHide", close)
    catcher:SetScript("OnClick", close)
    attachTooltip(dd, tipTitle, tipBody)

    dd.Refresh = refresh
    refresh()
    return dd
end


local function raidData()
    addon.db.settings.raid = addon.db.settings.raid or {}
    return addon.db.settings.raid
end

local function buildRaidSettingsPanel(parent)
    local shell, panel = makeScrollPanel(parent)

    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 14, -14)
    header:SetText("Raid Settings")
    UI.tint(header, C.red)

    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    desc:SetText("Applied automatically when entering a raid instance and reverted on leaving.")
    UI.tint(desc, C.textGrey)

    local enableCheck = createCheckbox(panel, "Enable Raid Settings", 260)
    enableCheck:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -14)
    enableCheck.OnChange = function(_, checked)
        raidData().enabled = checked
        if addon.Raid then addon.Raid.refresh() end
    end

    local namesCheck = createCheckbox(panel, "Disable Names in Raid", 260,
        "Hides friendly player, pet, guardian, and totem names.")
    namesCheck:SetPoint("TOPLEFT", enableCheck, "BOTTOMLEFT", 0, -18)
    namesCheck.OnChange = function(_, checked)
        raidData().disableNames = checked
        if addon.Raid then addon.Raid.refresh() end
    end

    local bubblesCheck = createCheckbox(panel, "Disable Chat Bubbles in Raid", 260)
    bubblesCheck:SetPoint("TOPLEFT", namesCheck, "BOTTOMLEFT", 0, -18)
    bubblesCheck.OnChange = function(_, checked)
        raidData().disableChatBubbles = checked
        if addon.Raid then addon.Raid.refresh() end
    end

    local debugLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    debugLabel:SetPoint("TOPLEFT", bubblesCheck, "BOTTOMLEFT", 0, -22)
    debugLabel:SetText("Debug")
    UI.tint(debugLabel, C.textDim)

    local debugCheck = createCheckbox(panel, "Treat Stockades as Raid", 260,
        "Use the Stockades to test raid settings without entering a real raid.")
    debugCheck:SetPoint("TOPLEFT", debugLabel, "BOTTOMLEFT", 0, -6)
    debugCheck.OnChange = function(_, checked)
        raidData().debug = checked
        if addon.Raid then addon.Raid.refresh() end
    end

    local function refreshPanel()
        local d = raidData()
        enableCheck:SetChecked(d.enabled or false)
        namesCheck:SetChecked(d.disableNames or false)
        bubblesCheck:SetChecked(d.disableChatBubbles or false)
        debugCheck:SetChecked(d.debug or false)
    end
    shell:SetScript("OnShow", refreshPanel)

    return shell
end

local raidFramesData = addon.RaidFrames.getData

local function buildRaidFramesPanel(parent)
    local shell, panel = makeScrollPanel(parent)

    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 14, -14)
    header:SetText("Raid Frame Manager")
    UI.tint(header, C.red)

    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    desc:SetText("Reposition and resize the default raid frames. Drag the box to move it, drag its corner to resize.")
    UI.tint(desc, C.textGrey)

    local enableCB = createCheckbox(panel, "Enable Raid Frame Manager", 280)
    enableCB:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -14)
    enableCB.OnChange = function(_, checked)
        raidFramesData().enabled = checked
        if addon.RaidFrames then addon.RaidFrames.applyAll() end
        UI.RefreshTabDots()
    end

    local moveBtn = flatButton(panel, "Move / Resize", 140, 22)
    moveBtn:SetPoint("TOPLEFT", enableCB, "BOTTOMLEFT", 0, -14)
    moveBtn:SetScript("OnClick", function() UI.EnterMoveMode({ addon.RaidFrames }) end)

    local scaleText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    scaleText:SetPoint("LEFT", moveBtn, "RIGHT", 14, 0)
    scaleText:SetText("Scale:")
    UI.tint(scaleText, C.textWhite)

    local scaleBoxWrap = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    scaleBoxWrap:SetSize(50, 22)
    scaleBoxWrap:SetPoint("LEFT", scaleText, "RIGHT", 8, 0)
    applyBackdrop(scaleBoxWrap, 1, C.panelDark, C.tabBorder)

    local scaleBox = CreateFrame("EditBox", nil, scaleBoxWrap)
    scaleBox:SetSize(40, 18)
    scaleBox:SetPoint("CENTER")
    scaleBox:SetAutoFocus(false)
    scaleBox:SetMaxLetters(6)
    scaleBox:SetJustifyH("CENTER")
    scaleBox:SetFontObject("GameFontNormal")
    UI.tint(scaleBox, C.textWhite)

    local scalePctLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    scalePctLabel:SetPoint("LEFT", scaleBoxWrap, "RIGHT", 4, 0)
    scalePctLabel:SetText("%")
    UI.tint(scalePctLabel, C.textWhite)

    local minPct = addon.RaidFrames and math.floor(addon.RaidFrames.minScale * 100) or 50
    local maxPct = addon.RaidFrames and math.floor(addon.RaidFrames.maxScale * 100) or 200

    local scaleRangeNote = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    scaleRangeNote:SetPoint("LEFT", scalePctLabel, "RIGHT", 8, 0)
    scaleRangeNote:SetText(string.format("(%d - %d)", minPct, maxPct))
    UI.tint(scaleRangeNote, C.textDim)

    local function displayScale()
        local d = raidFramesData()
        scaleBox:SetText(tostring(math.floor((d.scale or 1) * 100 + 0.5)))
    end

    local function commitScale()
        local num = tonumber(scaleBox:GetText())
        if num and addon.RaidFrames then
            local applied = addon.RaidFrames.setScale(num / 100)
            scaleBox:SetText(tostring(math.floor(applied * 100 + 0.5)))
        else
            displayScale()
        end
        scaleBox:ClearFocus()
    end

    scaleBoxWrap:SetScript("OnEnter", function() UI.tintBorder(scaleBoxWrap, C.red) end)
    scaleBoxWrap:SetScript("OnLeave", function() UI.tintBorder(scaleBoxWrap, C.tabBorder) end)
    scaleBox:SetScript("OnEnterPressed", commitScale)
    scaleBox:SetScript("OnEditFocusLost", commitScale)
    scaleBox:SetScript("OnEscapePressed", function()
        displayScale()
        scaleBox:ClearFocus()
    end)

    local function refreshPanel()
        local d = raidFramesData()
        enableCB:SetChecked(d.enabled or false)
        if not scaleBox:HasFocus() then
            displayScale()
        end
    end

    shell:SetScript("OnShow", refreshPanel)

    return shell
end

-- Wraps the Raid settings and Raid Frames panels under one top-level "Raid" tab
-- with its own sub-tab bar (General / Raid Frames), mirroring the Particles and
-- Trinkets tabs' sub-tab layout.
local function buildRaidTabPanel(parent)
    local panel, _, _, addSubTab = makeSubTabPanel(parent, { hidden = true })

    addSubTab("general",    "General",     80,  buildRaidSettingsPanel)
    addSubTab("raidframes", "Raid Frames", 110, buildRaidFramesPanel)

    selectSubTab(panel, "general")
    return panel
end

-- ── Media previews for createScrollDropdown ─────────────────────────────────
-- A list of font or texture NAMES tells you nothing about what you're picking,
-- so each row is drawn as a sample of itself. LSM is looked up per call rather
-- than cached, since a media pack can register more after this file loads.
local PREVIEW_FONT_SIZE = 12
-- Bar textures are near-white by design, so they're tinted down to keep the
-- white row label legible on top of them.
local PREVIEW_BAR_TINT  = { 0.33, 0.35, 0.48, 1 }

local fetchMedia = addon.FetchMedia

-- Falls back to `fallbackObject` when the font isn't installed any more, or the
-- client rejects the file — SetFont returns false there, and a FontString with an
-- invalid font renders nothing. Non-LSM entries ("Default") land here too, which
-- is right: they ARE the fallback.
local function applyFontPreview(label, name, fallbackObject)
    local path = fetchMedia("font", name)
    if path and label:SetFont(path, PREVIEW_FONT_SIZE, "") ~= false then return end
    label:SetFontObject(fallbackObject)
end

local function applyBarPreview(texture, name)
    local path = fetchMedia("statusbar", name)
    texture:SetTexture(path or WHITE)
    texture:SetVertexColor(unpack(PREVIEW_BAR_TINT))
    texture:SetShown(path ~= nil)
end

-- Scrollable dropdown anchoring cleanly beneath (or above) its button.
-- getItems() is called once on first open; onChange(name) fires on selection.
--
-- opts.preview makes it a media picker showing what it offers: "font" draws
-- every row in the named font, "statusbar" draws the bar texture behind the
-- name. opts.tipTitle/tipBody attach hover help to the closed button.
local function createScrollDropdown(parent, width, getItems, onChange, opts)
    local ITEM_H    = 20
    local MAX_VIS   = 8
    local SB_W      = 10          -- scrollbar track width
    local W         = width or 160
    local CONTENT_W = W - SB_W - 3  -- scroll frame / row width

    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(W, 22)
    applyBackdrop(btn, 1, C.panelDark, C.tabBorder)

    local btnText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    btnText:SetPoint("LEFT", 6, 0)
    btnText:SetPoint("RIGHT", -18, 0)
    btnText:SetJustifyH("LEFT")
    UI.tint(btnText, C.textWhite)

    local arrowText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    arrowText:SetPoint("RIGHT", -5, 0)
    arrowText:SetText("v")
    UI.tint(arrowText, C.textDim)

    -- ARTWORK (not BACKGROUND) so the sample sits above the button's backdrop
    -- fill but still below the OVERLAY label. Inset by the backdrop's 1px edge
    -- so the border stays a border.
    local preview = opts and opts.preview
    -- Resting colour for an unselected row. Bar-preview rows sit ON a texture,
    -- where the usual dim grey stops being readable.
    local IDLE_COLOR = (preview == "statusbar") and C.textWhite or C.textGrey
    local btnPreview
    if preview == "statusbar" then
        btnPreview = btn:CreateTexture(nil, "ARTWORK")
        btnPreview:SetPoint("TOPLEFT", 1, -1)
        btnPreview:SetPoint("BOTTOMRIGHT", -16, 1)   -- clear of the arrow
        btnText:SetShadowOffset(1, -1)
        btnText:SetShadowColor(0, 0, 0, 1)
    end

    -- Re-samples the closed button for whatever is currently selected. Called
    -- from both places the button's text can change (a row click, and setValue).
    local function applyButtonPreview(name)
        if preview == "font" then
            applyFontPreview(btnText, name, "GameFontNormal")
            -- applyFontPreview's fallback path goes through SetFontObject, which
            -- also drops the button's white text back to the font object's own
            -- colour. Re-assert it either way rather than only on that branch.
            UI.tint(btnText, C.textWhite)
        elseif btnPreview then
            applyBarPreview(btnPreview, name)
        end
    end

    btn._value = nil
    btn._rows  = {}
    btn._count = 0

    -- Popup parented to UIParent so it is never clipped by the settings frame.
    local popup = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    popup:SetWidth(W)
    popup:SetFrameStrata("TOOLTIP")
    applyBackdrop(popup, 1, C.panelDark, C.tabBorder)
    popup:Hide()

    local sf = CreateFrame("ScrollFrame", nil, popup)
    sf:SetPoint("TOPLEFT", popup, "TOPLEFT", 1, -1)
    sf:SetWidth(CONTENT_W)

    local sc = CreateFrame("Frame", nil, sf)
    sc:SetWidth(CONTENT_W)
    sc:SetHeight(1)
    sf:SetScrollChild(sc)

    -- Scrollbar track — hidden when all items fit without scrolling.
    local track = CreateFrame("Frame", nil, popup, "BackdropTemplate")
    track:SetWidth(SB_W)
    track:SetPoint("TOPRIGHT",    popup, "TOPRIGHT",    -1, -1)
    track:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -1,  1)
    applyBackdrop(track, 1, C.panelDeep, C.tabBorder)
    track:Hide()

    -- Scrollbar thumb (draggable).
    local thumb = CreateFrame("Button", nil, track, "BackdropTemplate")
    thumb:SetWidth(SB_W - 2)
    applyBackdrop(thumb, 1, C.tabIdle, C.tabBorder)
    thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 1, 0)  -- placeholder; overwritten by updateThumb

    -- The one definition of how far this list scrolls. A ScrollFrame does NOT clamp
    -- SetVerticalScroll, so every caller goes through setScroll — the wheel handler
    -- used to clamp only the top, walking rows past the bottom while the thumb slid
    -- out of its track.
    local function maxScroll()
        return math.max(0, (btn._count - MAX_VIS) * ITEM_H)
    end

    local function updateThumb()
        local n = btn._count
        if n <= MAX_VIS then track:Hide(); return end
        track:Show()
        local trackH = track:GetHeight()
        if trackH <= 0 then return end
        local thumbH = math.max(16, trackH * MAX_VIS / n)
        local maxS   = maxScroll()
        local cur    = sf:GetVerticalScroll()
        local frac   = maxS > 0 and (cur / maxS) or 0
        -- Clamped as well as clamping the scroll itself: the list can shrink under an
        -- offset that was valid for the longer one (media lists are rebuilt on every
        -- open), and the thumb mustn't be what notices.
        frac = math.max(0, math.min(1, frac))
        thumb:SetHeight(thumbH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 1, -(frac * (trackH - thumbH)))
    end

    local function setScroll(v)
        sf:SetVerticalScroll(math.max(0, math.min(v, maxScroll())))
        updateThumb()
    end

    -- Thumb drag logic.
    local isDragging     = false
    local dragStartY     = 0
    local dragStartScroll = 0

    thumb:EnableMouse(true)
    thumb:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then
            isDragging    = true
            dragStartY    = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
            dragStartScroll = sf:GetVerticalScroll()
        end
    end)
    thumb:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then isDragging = false end
    end)
    thumb:SetScript("OnUpdate", function()
        if not isDragging then return end
        local curY   = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
        local delta  = dragStartY - curY
        local trackH = track:GetHeight()
        local thumbH = thumb:GetHeight()
        if trackH > thumbH then
            setScroll(dragStartScroll + delta * maxScroll() / (trackH - thumbH))
        end
    end)
    thumb:SetScript("OnEnter", function(self) UI.tintBg(self, C.tabHover) end)
    thumb:SetScript("OnLeave", function(self) UI.tintBg(self, C.tabIdle)  end)

    popup:EnableMouseWheel(true)
    popup:SetScript("OnMouseWheel", function(_, d)
        setScroll(sf:GetVerticalScroll() - d * ITEM_H * 2)
    end)

    -- Full-screen catcher closes popup when clicking outside. It swallows right
    -- clicks too (blocking mouse-turn), so let those close it as well.
    local catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints()
    catcher:SetFrameStrata("FULLSCREEN_DIALOG")
    catcher:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    catcher:Hide()

    local function close()
        popup:Hide()
        catcher:Hide()
    end
    catcher:SetScript("OnClick", close)

    -- The popup and catcher live on UIParent, so they survive the owning window
    -- hiding. OnHide fires on descendants when an ancestor hides, so this tears the
    -- popup down with its panel — otherwise the catcher stays up and eats every
    -- click on the world.
    btn:SetScript("OnHide", close)

    local function refreshColors()
        for _, row in ipairs(btn._rows) do
            row.lbl:SetTextColor(unpack(
                row._name == btn._value and C.red or IDLE_COLOR
            ))
        end
    end

    -- (Re)populates the row pool from getItems() on every open, so the list stays
    -- current when its source changes. Rows are pooled and reused; surplus is
    -- hidden. btn._count is the number of live items, since the pool may be larger.
    local function populate()
        local items = getItems()
        for i, name in ipairs(items) do
            local row = btn._rows[i]
            if not row then
                row = CreateFrame("Button", nil, sc)
                row:SetSize(CONTENT_W, ITEM_H)
                row:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -(i - 1) * ITEM_H)

                if preview == "statusbar" then
                    row.bg = row:CreateTexture(nil, "BACKGROUND")
                    row.bg:SetPoint("TOPLEFT", 0, -1)
                    row.bg:SetPoint("BOTTOMRIGHT", 0, 1)
                end

                local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                lbl:SetPoint("LEFT", 4, 0)
                lbl:SetPoint("RIGHT", -4, 0)
                lbl:SetJustifyH("LEFT")
                if row.bg then
                    lbl:SetShadowOffset(1, -1)
                    lbl:SetShadowColor(0, 0, 0, 1)
                end
                row.lbl = lbl

                row:SetScript("OnEnter", function(self)
                    UI.tint(self.lbl, C.textWhite)
                end)
                row:SetScript("OnLeave", function(self)
                    self.lbl:SetTextColor(unpack(
                        self._name == btn._value and C.red or IDLE_COLOR
                    ))
                end)
                row:SetScript("OnClick", function(self)
                    btn._value = self._name
                    btnText:SetText(self._name)
                    applyButtonPreview(self._name)
                    refreshColors()
                    close()
                    if onChange then onChange(self._name) end
                end)

                btn._rows[i] = row
            end
            row._name = name
            row.lbl:SetText(name)
            -- Before SetTextColor, not after: the font fallback inside
            -- applyFontPreview goes through SetFontObject, which resets the
            -- colour to whatever that font object carries.
            if preview == "font" then
                applyFontPreview(row.lbl, name, "GameFontNormalSmall")
            elseif row.bg then
                applyBarPreview(row.bg, name)
            end
            row.lbl:SetTextColor(unpack(name == btn._value and C.red or IDLE_COLOR))
            row:Show()
        end
        for i = #items + 1, #btn._rows do btn._rows[i]:Hide() end
        btn._count = #items
        sc:SetHeight(math.max(#items * ITEM_H, 1))
    end

    btn:SetScript("OnClick", function()
        if popup:IsShown() then close(); return end

        populate()

        local visH = math.min(btn._count, MAX_VIS) * ITEM_H
        popup:SetHeight(visH + 2)
        sf:SetHeight(visH)

        local left   = btn:GetLeft()   or 0
        local bottom = btn:GetBottom() or 0
        local top_   = btn:GetTop()    or 0
        popup:ClearAllPoints()
        if bottom - (visH + 2) < 0 then
            popup:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left, top_)
        else
            popup:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, bottom)
        end

        popup:Show()
        catcher:Show()
        -- Reset first: the popup keeps its scroll offset between openings, and a list
        -- that has since got shorter would open scrolled past its own end.
        setScroll(0)

        -- Scroll so the selected item is centred in the visible window.
        if btn._value then
            for i = 1, btn._count do
                if btn._rows[i]._name == btn._value then
                    setScroll((i - 1) * ITEM_H - math.floor(MAX_VIS / 2) * ITEM_H)
                    break
                end
            end
        end
    end)

    btn:SetScript("OnEnter", function(self) UI.tintBorder(self, C.red) end)
    btn:SetScript("OnLeave", function(self) UI.tintBorder(self, C.tabBorder) end)
    if opts then attachTooltip(btn, opts.tipTitle, opts.tipBody) end

    function btn:setValue(v)
        self._value = v
        btnText:SetText(v or "")
        applyButtonPreview(v)
        refreshColors()
    end

    return btn
end

-- ── The font block ───────────────────────────────────────────────────────────
-- Every configurable font in the addon is edited through this one control set,
-- in this one order: Font, Font size, Outline, Custom color, X offset, Y offset,
-- Shadow colour, Shadow X, Shadow Y. Font.lua defines what it writes; this
-- defines what
-- it looks like. A module that grows a new piece of text gets the whole set by
-- calling this, rather than shipping whichever three settings it thought of.
--
--   opts.get       — returns the live block to edit (created on demand by the
--                    caller, usually addon.Font.Block(d, "someFont")). Called
--                    per read, never captured, so a profile switch is picked up.
--   opts.defaults  — this element's defaults, from addon.Font.New{...}
--   opts.onChange  — re-apply hook, run after every edit
--   opts.title     — optional section header above the rows
--   opts.skip      — { x = true, y = true, color = true, ... } for the rare
--                    target that physically can't honour a control. Chat is the
--                    one that uses it: a chat frame lays out its own lines, so
--                    there is nothing to nudge, and every line already carries
--                    its channel's colour. Left out entirely rather than shown
--                    doing nothing.
--   opts.autoSize  — allows size 0, shown as "Auto", meaning "leave whatever
--                    size the element already had" — for the same kind of
--                    target, where a size exists but isn't ours to invent.
--   opts.sizeMin / opts.sizeMax — narrower limits where a font drives layout.
--   opts.labelWidth / opts.controlWidth / opts.width — layout, all optional.
--
-- Returns a container frame sized to its rows (anchor it like any widget) with
-- :Refresh() to re-read every control.
local FONT_ROW_H  = 22
local FONT_ROW_GAP = 6

local function buildFontOptions(parent, opts)
    local Font = addon.Font
    local def  = opts.defaults or Font.DEFAULTS
    local skip = opts.skip or {}

    local labelW   = opts.labelWidth   or 130
    local controlW = opts.controlWidth or 170
    local width    = opts.width        or (labelW + controlW + 20)

    local box = CreateFrame("Frame", nil, parent)
    box:SetWidth(width)

    local refreshers = {}
    local last, height = nil, 0

    -- Rows stack inside the container, so the caller anchors one frame and the
    -- block's own height is whatever its rows came to — a skipped control costs
    -- no gap.
    local function addRow(labelText)
        local row = CreateFrame("Frame", nil, box)
        row:SetSize(width, FONT_ROW_H)
        if last then
            row:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -FONT_ROW_GAP)
            height = height + FONT_ROW_GAP + FONT_ROW_H
        else
            row:SetPoint("TOPLEFT", box, "TOPLEFT", 0, 0)
            height = height + FONT_ROW_H
        end
        box:SetHeight(height)
        last = row

        local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("LEFT", 0, 0)
        lbl:SetWidth(labelW)
        lbl:SetJustifyH("LEFT")
        lbl:SetText(labelText)
        UI.tint(lbl, C.textWhite)
        row.lbl = lbl
        return row
    end

    -- get/set are written against the block, so each control stays one line and
    -- none of them has to remember where the block came from.
    local function field(key)
        return function() return opts.get()[key] end,
               function(v) opts.get()[key] = v end
    end

    local function stepperRow(labelText, key, min, max, fallback, desc)
        if skip[key] then return end
        local row = addRow(labelText)
        local get, set = field(key)
        local st = buildStepper(row, {
            min = min, max = max, step = 1, valueWidth = 42,
            get = function() return tonumber(get()) or fallback end,
            set = set,
            format = opts.autoSize and key == "size"
                and function(v) return v == 0 and "Auto" or tostring(v) end
                or nil,
            onChange = opts.onChange,
        })
        st:SetPoint("LEFT", row.lbl, "RIGHT", 10, 0)
        attachTooltip(st,      labelText, desc)
        attachTooltip(st.plus, labelText, desc)
        refreshers[#refreshers + 1] = st.Refresh
        return row
    end

    if opts.title then
        local hdr = box:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        hdr:SetPoint("BOTTOMLEFT", box, "TOPLEFT", 0, 6)
        hdr:SetText(opts.title)
        UI.tint(hdr, C.red)
        box.header = hdr
    end

    -- 1. Font
    if not skip.font then
        local row = addRow("Font:")
        local get, set = field("font")
        local dd = createScrollDropdown(row, controlW,
            -- opts.lead pins a non-LSM entry to the front of the list, for the
            -- targets whose face isn't ours to invent — chat's "Default" means
            -- "leave whatever the element already had".
            function()
                return addon.MediaList("font",
                    { lead = opts.lead, fallback = def.font or Font.DEFAULT_NAME })
            end,
            function(name) set(name); if opts.onChange then opts.onChange() end end,
            { preview = "font", tipTitle = "Font",
              tipBody = opts.fontDesc
                  or "Any font registered with LibSharedMedia by this or another addon." })
        dd:SetPoint("LEFT", row.lbl, "RIGHT", 10, 0)
        refreshers[#refreshers + 1] = function()
            dd:setValue(get() or def.font or Font.DEFAULT_NAME)
        end
    end

    -- 2. Font size
    stepperRow("Font size:", "size",
        opts.autoSize and 0 or (opts.sizeMin or Font.SIZE_MIN),
        opts.sizeMax or Font.SIZE_MAX,
        def.size or Font.DEFAULTS.size,
        opts.autoSize
            and "Height of the text. \"Auto\" (below the lowest size) leaves whatever size the element already had."
            or  "Height of the text.")

    -- 3. Outline
    if not skip.outline then
        local row = addRow("Outline:")
        local get, set = field("outline")
        local dd = createDropdown(row, controlW, Font.OUTLINES,
            function() return get() or def.outline or "OUTLINE" end,
            set, opts.onChange, "Outline",
            "Border drawn around each letter, which is what keeps small text "
                .. "readable over a bright texture or the game world.")
        dd:SetPoint("LEFT", row.lbl, "RIGHT", 10, 0)
        refreshers[#refreshers + 1] = dd.Refresh
    end

    -- 4. Colour — an override, so the row is a tick box and a swatch rather than
    -- a swatch alone. Unticked, the text keeps whatever colour it would have had,
    -- and the swatch still holds the colour you left it on for next time.
    if not skip.color then
        local desc = opts.colorDesc
            or "Paints the text this colour. Left unticked it keeps whatever "
                .. "colour it already had."
        local row = addRow("")
        row.lbl:Hide()   -- the tick box carries the label on this row

        local cb = createCheckbox(row, "Custom color", labelW, desc)
        cb:SetPoint("LEFT", 0, 0)

        local sw = createColorSwatch(row,
            function() return Font.Color(opts.get(), def) end,
            function(r, g, b) opts.get().color = { r, g, b } end,
            opts.onChange, { hover = true })
        sw:SetPoint("LEFT", cb, "RIGHT", 10, 0)
        attachTooltip(sw, "Custom color", desc)

        cb.OnChange = function(_, checked)
            opts.get().colorEnabled = checked
            if opts.onChange then opts.onChange() end
        end
        refreshers[#refreshers + 1] = function()
            cb:SetChecked(Font.ColorEnabled(opts.get(), def))
            sw.Refresh()
        end
    end

    -- 5/6. X and Y offset
    local OFF = Font.OFFSET_RANGE
    stepperRow("X offset:", "x", -OFF, OFF, def.x or 0,
        "Nudges the text sideways from where it normally sits. Positive is right.")
    stepperRow("Y offset:", "y", -OFF, OFF, def.y or 0,
        "Nudges the text up or down from where it normally sits. Positive is up.")

    -- 7. Shadow colour
    if not skip.shadowColor then
        local row = addRow("Shadow color:")
        local sw = createColorSwatch(row,
            function()
                local c = opts.get().shadowColor or def.shadowColor or { 0, 0, 0 }
                return c[1] or 0, c[2] or 0, c[3] or 0
            end,
            function(r, g, b) opts.get().shadowColor = { r, g, b } end,
            opts.onChange, { hover = true })
        sw:SetPoint("LEFT", row.lbl, "RIGHT", 10, 0)
        attachTooltip(sw, "Shadow color",
            "Only visible once one of the shadow offsets below is non-zero — at no "
                .. "offset the shadow sits directly behind the text and is drawn as "
                .. "nothing at all.")
        refreshers[#refreshers + 1] = sw.Refresh
    end

    -- 8/9. Shadow X and Y
    local SH = Font.SHADOW_RANGE
    stepperRow("Shadow X:", "shadowX", -SH, SH, def.shadowX or 0,
        "How far the drop shadow sits to the side of the text. Zero on both axes means no shadow.")
    stepperRow("Shadow Y:", "shadowY", -SH, SH, def.shadowY or 0,
        "How far the drop shadow sits above or below the text. Zero on both axes means no shadow.")

    function box:Refresh()
        for _, fn in ipairs(refreshers) do fn() end
    end

    return box
end

-- Input / Minimap — the odds and ends that don't belong to a module.
local function buildGeneralSettingsPanel(parent)
    local shell, panel = makeScrollPanel(parent)

    -- ── Input section ──────────────────────────────────────────────────────
    -- Drives Blizzard's ActionButtonUseKeyDown CVar, which decides whether a
    -- keybind/click fires on press or release. The action bars and trinket buttons
    -- register both phases and follow it, so this is the single switch for their
    -- feel. The CVar is its own persistent store, so nothing is kept in the DB.
    local inputHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    inputHeader:SetPoint("TOPLEFT", 14, -14)
    inputHeader:SetText("Input")
    UI.tint(inputHeader, C.red)

    local keyDownCB = createCheckbox(panel, "Use abilities on key down (uncheck for key up)", 360,
        "Applies to this addon's action bars and trinket buttons. On: abilities fire the instant a key is pressed; off: on release. This is Blizzard's ActionButtonUseKeyDown setting, so it also affects the default action bars.")
    keyDownCB:SetPoint("TOPLEFT", inputHeader, "BOTTOMLEFT", 0, -10)
    keyDownCB.OnChange = function(self, checked)
        -- SetCVar for this key is blocked in combat; bounce the box back to the
        -- real value and tell the user rather than silently no-opping.
        if InCombatLockdown() then
            print("|cfffb2c36Driev's|r |cffffffffEssentials|r: can't change key up/down while in combat — try again afterwards.")
            self:SetChecked(GetCVarBool("ActionButtonUseKeyDown"))
            return
        end
        SetCVar("ActionButtonUseKeyDown", checked and "1" or "0")
    end

    -- ── Minimap section ───────────────────────────────────────────────────────
    local minimapHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    minimapHeader:SetPoint("TOPLEFT", keyDownCB, "BOTTOMLEFT", 0, -24)
    minimapHeader:SetText("Minimap")
    UI.tint(minimapHeader, C.red)

    local minimapHideCB = createCheckbox(panel, "Disable minimap button", 260)
    minimapHideCB:SetPoint("TOPLEFT", minimapHeader, "BOTTOMLEFT", 0, -10)
    minimapHideCB.OnChange = function(_, checked)
        addon.db.minimap.hide = checked
        if addon.minimapButton then
            if checked then addon.minimapButton:Hide()
            else             addon.minimapButton:Show() end
        end
    end

    local function refreshPanel()
        keyDownCB:SetChecked(GetCVarBool("ActionButtonUseKeyDown"))
        minimapHideCB:SetChecked(addon.db.minimap.hide or false)
    end

    shell:SetScript("OnShow", refreshPanel)

    return shell
end

local function buildTTKPanel(parent)
    local shell, panel = makeScrollPanel(parent)

    local function getTTKData()
        addon.db.settings.ttk = addon.db.settings.ttk or {
            enabled  = false,
            bossOnly = false,
        }
        return addon.db.settings.ttk
    end

    local TTK_FONT_DEFAULT = addon.Font.New({ size = 24 })

    local ttkHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    ttkHeader:SetPoint("TOPLEFT", 14, -14)
    ttkHeader:SetText("Time To Kill")
    UI.tint(ttkHeader, C.red)

    -- Enable checkbox
    local enableCB = createCheckbox(panel, "Enable Time To Kill", 260)
    enableCB:SetPoint("TOPLEFT", ttkHeader, "BOTTOMLEFT", 0, -14)
    enableCB.OnChange = function(_, checked)
        getTTKData().enabled = checked
        if addon.TTK then addon.TTK.applyVisibility() end
    end

    -- Move button
    local moveBtn = flatButton(panel, "Move", 80, 22)
    moveBtn:SetPoint("TOPLEFT", enableCB, "BOTTOMLEFT", 0, -10)
    moveBtn:SetScript("OnClick", function() UI.EnterMoveMode({ addon.TTK }) end)

    -- Boss-only checkbox
    local bossOnlyCB = createCheckbox(panel, "Only show during boss fights", 260)
    bossOnlyCB:SetPoint("TOPLEFT", moveBtn, "BOTTOMLEFT", 0, -10)
    bossOnlyCB.OnChange = function(_, checked)
        getTTKData().bossOnly = checked
    end

    -- The shared font block: same eight controls, same order, as every other
    -- configurable text in the addon.
    local fontBox = buildFontOptions(panel, {
        title    = "Font",
        defaults = TTK_FONT_DEFAULT,
        get      = function()
            return addon.Font.Adopt(getTTKData(), "font",
                { font = "fontName", size = "fontSize" })
        end,
        onChange = function() if addon.TTK then addon.TTK.applyFont() end end,
    })
    fontBox:SetPoint("TOPLEFT", bossOnlyCB, "BOTTOMLEFT", 0, -34)

    local function refreshPanel()
        local d  = getTTKData()
        enableCB:SetChecked(d.enabled or false)
        bossOnlyCB:SetChecked(d.bossOnly or false)
        fontBox:Refresh()
    end

    shell:SetScript("OnShow", refreshPanel)

    return shell
end

local function buildTooltipPanel(parent)
    local shell, panel = makeScrollPanel(parent)

    local function getTooltipData()
        addon.db.settings.tooltip = addon.db.settings.tooltip or {}
        return addon.db.settings.tooltip
    end

    local ttHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    ttHeader:SetPoint("TOPLEFT", 14, -14)
    ttHeader:SetText("Tooltip")
    UI.tint(ttHeader, C.red)

    local ttDesc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ttDesc:SetPoint("TOPLEFT", ttHeader, "BOTTOMLEFT", 0, -4)
    ttDesc:SetWidth(420); ttDesc:SetJustifyH("LEFT")
    ttDesc:SetText("Restyles the game tooltip (item/unit/etc.) to match this addon's theme.")
    UI.tint(ttDesc, C.textGrey)

    local ttEnableCB = createCheckbox(panel, "Enable custom tooltip skin", 300)
    ttEnableCB:SetPoint("TOPLEFT", ttDesc, "BOTTOMLEFT", 0, -10)
    ttEnableCB.OnChange = function(_, checked)
        getTooltipData().enabled = checked
        if addon.Tooltip then addon.Tooltip.refresh() end
    end

    local ttColorCB = createCheckbox(panel, "Color border by class (players) / reaction (NPCs)", 340)
    ttColorCB:SetPoint("TOPLEFT", ttEnableCB, "BOTTOMLEFT", 0, -6)
    ttColorCB.OnChange = function(_, checked)
        getTooltipData().colorByUnit = checked
    end

    local ttHealthCB = createCheckbox(panel, "Show health value on unit tooltips", 340)
    ttHealthCB:SetPoint("TOPLEFT", ttColorCB, "BOTTOMLEFT", 0, -6)
    ttHealthCB.OnChange = function(_, checked)
        getTooltipData().showHealth = checked
    end

    local ttRealmCB = createCheckbox(panel, "Hide realm name", 300)
    ttRealmCB:SetPoint("TOPLEFT", ttHealthCB, "BOTTOMLEFT", 0, -6)
    ttRealmCB.OnChange = function(_, checked)
        getTooltipData().hideRealm = checked
    end

    -- Rank only appears when the guild name is also shown (and the player is in a
    -- guild); both default on.
    local ttGuildCB = createCheckbox(panel, "Show guild name on unit tooltips", 340)
    ttGuildCB:SetPoint("TOPLEFT", ttRealmCB, "BOTTOMLEFT", 0, -6)
    ttGuildCB.OnChange = function(_, checked)
        getTooltipData().showGuild = checked
    end

    local ttGuildRankCB = createCheckbox(panel, "Show guild rank on unit tooltips", 340)
    ttGuildRankCB:SetPoint("TOPLEFT", ttGuildCB, "BOTTOMLEFT", 0, -6)
    ttGuildRankCB.OnChange = function(_, checked)
        getTooltipData().showGuildRank = checked
    end

    local ttHealthBorderCB = createCheckbox(panel, "Class-color the health bar outline", 340)
    ttHealthBorderCB:SetPoint("TOPLEFT", ttGuildRankCB, "BOTTOMLEFT", 0, -6)
    ttHealthBorderCB.OnChange = function(_, checked)
        getTooltipData().healthBorder = checked
    end

    local ttCursorCB = createCheckbox(panel, "Anchor tooltip to cursor", 300)
    ttCursorCB:SetPoint("TOPLEFT", ttHealthBorderCB, "BOTTOMLEFT", 0, -6)
    ttCursorCB.OnChange = function(_, checked)
        getTooltipData().anchorCursor = checked
    end

    local ttAnchorCB = createCheckbox(panel, "Use a movable tooltip anchor", 340,
        "Parks the tooltip on a handle you can drag in Edit Mode. Cursor anchoring wins if both are ticked.")
    ttAnchorCB:SetPoint("TOPLEFT", ttCursorCB, "BOTTOMLEFT", 0, -6)
    ttAnchorCB.OnChange = function(_, checked)
        getTooltipData().useAnchor = checked
    end

    local function ttChanged()
        if addon.Tooltip then addon.Tooltip.refresh() end
    end

    -- One colour serves two roles: the fallback when there's no class/reaction tint,
    -- and what the override below uses when switched on. Two separate colours could
    -- disagree for no good reason.
    local ttBorderRow = CreateFrame("Frame", nil, panel)
    ttBorderRow:SetSize(320, 22)
    ttBorderRow:SetPoint("TOPLEFT", ttAnchorCB, "BOTTOMLEFT", 0, -12)
    local ttBorderLbl = ttBorderRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ttBorderLbl:SetPoint("LEFT", 0, 0); ttBorderLbl:SetWidth(150); ttBorderLbl:SetJustifyH("LEFT")
    ttBorderLbl:SetText("Default border color:"); UI.tint(ttBorderLbl, C.textGrey)
    local ttBorderSwatch = createColorSwatch(ttBorderRow,
        function()
            local c = getTooltipData().borderColor or { 0.30, 0.31, 0.42 }
            return c[1], c[2], c[3]
        end,
        function(r, g, b) getTooltipData().borderColor = { r, g, b } end, ttChanged)
    ttBorderSwatch:SetPoint("LEFT", ttBorderLbl, "RIGHT", 6, 0)
    attachTooltip(ttBorderSwatch, "Default border color",
        "Used whenever there is no class or reaction color to apply — items, spells, objects and the like.")

    local ttCustomBorderCB = createCheckbox(panel, "Use it for units too, ignoring class colors", 360)
    ttCustomBorderCB:SetPoint("TOPLEFT", ttBorderRow, "BOTTOMLEFT", 0, -10)
    ttCustomBorderCB.OnChange = function(_, checked)
        getTooltipData().customBorder = checked
        ttChanged()
    end

    local ttBgRow = CreateFrame("Frame", nil, panel)
    ttBgRow:SetSize(320, 22)
    ttBgRow:SetPoint("TOPLEFT", ttCustomBorderCB, "BOTTOMLEFT", 0, -10)
    local ttBgLbl = ttBgRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ttBgLbl:SetPoint("LEFT", 0, 0); ttBgLbl:SetWidth(150); ttBgLbl:SetJustifyH("LEFT")
    ttBgLbl:SetText("Background color:"); UI.tint(ttBgLbl, C.textGrey)
    local ttBgSwatch = createColorSwatch(ttBgRow,
        function()
            local c = getTooltipData().bgColor or { 0.090, 0.098, 0.165 }
            return c[1], c[2], c[3]
        end,
        function(r, g, b) getTooltipData().bgColor = { r, g, b } end, ttChanged)
    ttBgSwatch:SetPoint("LEFT", ttBgLbl, "RIGHT", 6, 0)

    local ttOpRow = CreateFrame("Frame", nil, panel)
    ttOpRow:SetSize(320, 22)
    ttOpRow:SetPoint("TOPLEFT", ttBgRow, "BOTTOMLEFT", 0, -8)
    local ttOpLbl = ttOpRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ttOpLbl:SetPoint("LEFT", 0, 0); ttOpLbl:SetWidth(150); ttOpLbl:SetJustifyH("LEFT")
    ttOpLbl:SetText("Background opacity:"); UI.tint(ttOpLbl, C.textGrey)
    local ttOpStepper = buildStepper(ttOpRow, {
        min = 0, max = 100, step = 5,
        get = function() return getTooltipData().bgOpacity or 100 end,
        set = function(v) getTooltipData().bgOpacity = v end,
        onChange = ttChanged,
    })
    ttOpStepper:SetPoint("LEFT", ttOpLbl, "RIGHT", 6, 0)
    local ttOpSuffix = ttOpRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ttOpSuffix:SetPoint("LEFT", ttOpStepper.plus, "RIGHT", 6, 0)
    ttOpSuffix:SetText("%"); UI.tint(ttOpSuffix, C.textDim)

    local function refreshPanel()
        local td = getTooltipData()
        ttEnableCB:SetChecked(td.enabled ~= false)
        ttColorCB:SetChecked(td.colorByUnit ~= false)
        ttHealthCB:SetChecked(td.showHealth ~= false)
        ttRealmCB:SetChecked(td.hideRealm or false)
        ttGuildCB:SetChecked(td.showGuild ~= false)
        ttGuildRankCB:SetChecked(td.showGuildRank ~= false)
        ttHealthBorderCB:SetChecked(td.healthBorder ~= false)
        ttCursorCB:SetChecked(td.anchorCursor or false)
        ttAnchorCB:SetChecked(td.useAnchor or false)
        ttCustomBorderCB:SetChecked(td.customBorder or false)
        ttBorderSwatch.Refresh(); ttBgSwatch.Refresh(); ttOpStepper.Refresh()
    end

    shell:SetScript("OnShow", refreshPanel)

    return shell
end

-- The top-level "General" tab: a sub-tab bar over the three panels above,
-- matching how the Raid, Particles and Trinkets tabs are laid out.
local function buildGeneralTabPanel(parent)
    local panel, _, _, addSubTab = makeSubTabPanel(parent, { hidden = true })

    addSubTab("general", "General", 80, buildGeneralSettingsPanel)
    addSubTab("ttk",     "TTK",     70, buildTTKPanel)
    addSubTab("tooltip", "Tooltip", 90, buildTooltipPanel)

    selectSubTab(panel, "general")
    return panel
end


-- Themed horizontal slider for the Move UI bar and the window's UI Scale slider:
-- [label] [track] [box]. opts = { label, min, max, get, set, suffix }; the row
-- exposes :Refresh(). Defined ahead of createMainFrame(), which needs it as a
-- local upvalue.
local EDIT_SLIDER_TRACK_W = 110

local function buildEditSlider(parent, opts)
    local mn, mx = opts.min, opts.max
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(244, 22)

    local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("LEFT", row, "LEFT", 0, 0)
    label:SetWidth(opts.labelWidth or 58); label:SetJustifyH("LEFT")
    label:SetText(opts.label)
    UI.tint(label, C.textWhite)

    local track = CreateFrame("Frame", nil, row, "BackdropTemplate")
    track:SetSize(EDIT_SLIDER_TRACK_W, 8)
    track:SetPoint("LEFT", label, "RIGHT", 6, 0)
    applyBackdrop(track, 1, C.panelDark, C.tabBorder)
    track:EnableMouse(true)

    local fill = track:CreateTexture(nil, "ARTWORK")
    fill:SetTexture(WHITE)
    UI.tintTexture(fill, C.red)
    fill:SetPoint("TOPLEFT", track, "TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMLEFT", track, "BOTTOMLEFT", 1, 1)
    fill:SetWidth(1)

    local thumb = CreateFrame("Button", nil, track, "BackdropTemplate")
    thumb:SetSize(14, 14)
    applyBackdrop(thumb, 1, C.tabIdle, C.tabBorder)
    thumb:SetPoint("CENTER", track, "LEFT", 0, 0)

    local boxWrap = CreateFrame("Frame", nil, row, "BackdropTemplate")
    boxWrap:SetSize(40, 20)
    boxWrap:SetPoint("LEFT", track, "RIGHT", 10, 0)
    applyBackdrop(boxWrap, 1, C.panelDark, C.tabBorder)

    local box = CreateFrame("EditBox", nil, boxWrap)
    box:SetSize(32, 16); box:SetPoint("CENTER")
    box:SetAutoFocus(false); box:SetMaxLetters(3)
    box:SetJustifyH("CENTER"); box:SetFontObject("GameFontNormal")
    UI.tint(box, C.textWhite)

    if opts.suffix then
        local suf = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        suf:SetPoint("LEFT", boxWrap, "RIGHT", 3, 0)
        suf:SetText(opts.suffix); UI.tint(suf, C.textGrey)
    end

    local value    = mn
    local dragging  = false

    local function setVisual(v)
        local frac = (v - mn) / (mx - mn)
        frac = math.max(0, math.min(1, frac))
        fill:SetWidth(math.max(frac * (EDIT_SLIDER_TRACK_W - 2), 1))
        thumb:ClearAllPoints()
        thumb:SetPoint("CENTER", track, "LEFT", frac * EDIT_SLIDER_TRACK_W, 0)
    end

    local function setValue(v, skipSet)
        v = math.floor(math.max(mn, math.min(mx, v)) + 0.5)
        value = v
        setVisual(v)
        if not box:HasFocus() then box:SetText(tostring(v)) end
        if not skipSet and opts.set then opts.set(v) end
    end

    local function valFromCursor()
        local left = track:GetLeft()
        if not left then return value end
        -- track:GetLeft() is in the track's OWN effective-scale space, so the cursor
        -- position must be divided by that scale, NOT UIParent's. They're equal on an
        -- unscaled parent, which is why this was fine for the Move UI bar — but the
        -- Scale slider lives inside a frame we SetScale() ourselves.
        local x = GetCursorPosition() / track:GetEffectiveScale()
        local frac = math.max(0, math.min(1, (x - left) / EDIT_SLIDER_TRACK_W))
        return mn + frac * (mx - mn)
    end

    -- opts.deferSet: for a slider whose set() rescales one of its own ancestors (UI
    -- Scale rescales the window it lives in), calling set every OnUpdate tick is
    -- self-referential — rescaling mid-drag shifts track:GetLeft() under the cursor,
    -- throwing off the next valFromCursor() and spiralling. Deferring the real set()
    -- to drag end keeps the track's geometry stable.
    thumb:SetScript("OnMouseDown", function(_, b)
        if b ~= "LeftButton" then return end
        dragging = true
        thumb:SetScript("OnUpdate", function() setValue(valFromCursor(), opts.deferSet) end)
    end)
    thumb:SetScript("OnMouseUp", function(_, b)
        if b ~= "LeftButton" then return end
        dragging = false
        thumb:SetScript("OnUpdate", nil)
        UI.tintBorder(thumb, C.tabBorder)
        if opts.deferSet and opts.set then opts.set(value) end
    end)
    thumb:SetScript("OnEnter", function() UI.tintBorder(thumb, C.red) end)
    thumb:SetScript("OnLeave", function() if not dragging then UI.tintBorder(thumb, C.tabBorder) end end)

    track:SetScript("OnMouseDown", function(_, b) if b == "LeftButton" then setValue(valFromCursor()) end end)
    track:EnableMouseWheel(true)
    track:SetScript("OnMouseWheel", function(_, delta) setValue(value + delta) end)

    local function commit()
        local n = tonumber(box:GetText())
        if n then setValue(n) else box:SetText(tostring(value)) end
        box:ClearFocus()
    end
    box:SetScript("OnEnterPressed", commit)
    box:SetScript("OnEditFocusLost", commit)
    box:SetScript("OnEscapePressed", function() box:SetText(tostring(value)); box:ClearFocus() end)
    boxWrap:SetScript("OnEnter", function() UI.tintBorder(boxWrap, C.red) end)
    boxWrap:SetScript("OnLeave", function() UI.tintBorder(boxWrap, C.tabBorder) end)

    function row:Refresh() setValue((opts.get and opts.get()) or mn, true) end

    row:Refresh()
    return row
end

-- Compact [label] [-] [box] [+] [px] stepper for the top bar's window
-- width/height. Returns a row frame exposing :Refresh(), e.g. after a
-- corner-drag resize.
local function buildSizeStepper(parent, opts)
    local mn, mx, step = opts.min, opts.max, opts.step or 10
    local function cur() return (opts.get and opts.get()) or mn end

    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(130, 22)

    local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("LEFT", 0, 0)
    label:SetWidth(12); label:SetJustifyH("LEFT")
    label:SetText(opts.label)
    UI.tint(label, C.textWhite)

    local minus = CreateFrame("Button", nil, row, "BackdropTemplate")
    minus:SetSize(20, 20)
    minus:SetPoint("LEFT", label, "RIGHT", 6, 0)
    applyBackdrop(minus, 1, C.panelDark, C.tabBorder)
    local minusLbl = minus:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    minusLbl:SetPoint("CENTER"); minusLbl:SetText("-"); UI.tint(minusLbl, C.textWhite)

    local boxWrap = CreateFrame("Frame", nil, row, "BackdropTemplate")
    boxWrap:SetSize(46, 20)
    boxWrap:SetPoint("LEFT", minus, "RIGHT", 4, 0)
    applyBackdrop(boxWrap, 1, C.panelDark, C.tabBorder)

    local box = CreateFrame("EditBox", nil, boxWrap)
    box:SetSize(38, 16); box:SetPoint("CENTER")
    -- Not SetNumeric(true): that flag allows only digits 0-9 and silently strips the
    -- "-" from negative values (even ones set via SetText), breaking any stepper
    -- whose range dips below 0. tonumber() on commit already rejects non-numbers.
    box:SetAutoFocus(false); box:SetMaxLetters(5)
    box:SetJustifyH("CENTER"); box:SetFontObject("GameFontNormalSmall")
    UI.tint(box, C.textWhite)

    local plus = CreateFrame("Button", nil, row, "BackdropTemplate")
    plus:SetSize(20, 20)
    plus:SetPoint("LEFT", boxWrap, "RIGHT", 4, 0)
    applyBackdrop(plus, 1, C.panelDark, C.tabBorder)
    local plusLbl = plus:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    plusLbl:SetPoint("CENTER"); plusLbl:SetText("+"); UI.tint(plusLbl, C.textWhite)

    local suffix = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    suffix:SetPoint("LEFT", plus, "RIGHT", 4, 0)
    suffix:SetText("px"); UI.tint(suffix, C.textGrey)

    local function refresh()
        if not box:HasFocus() then box:SetText(tostring(math.floor(cur() + 0.5))) end
    end
    local function commit(v)
        v = math.max(mn, math.min(mx, math.floor(v + 0.5)))
        if opts.set then opts.set(v) end
        refresh()
    end

    minus:SetScript("OnClick", function() commit(cur() - step) end)
    plus:SetScript("OnClick",  function() commit(cur() + step) end)
    minus:SetScript("OnEnter", function() UI.tintBorder(minus, C.red) end)
    minus:SetScript("OnLeave", function() UI.tintBorder(minus, C.tabBorder) end)
    plus:SetScript("OnEnter",  function() UI.tintBorder(plus, C.red) end)
    plus:SetScript("OnLeave",  function() UI.tintBorder(plus, C.tabBorder) end)

    box:SetScript("OnEnterPressed", function()
        local n = tonumber(box:GetText())
        if n then commit(n) else refresh() end
        box:ClearFocus()
    end)
    box:SetScript("OnEditFocusLost", refresh)
    box:SetScript("OnEscapePressed", function() refresh(); box:ClearFocus() end)
    boxWrap:SetScript("OnEnter", function() UI.tintBorder(boxWrap, C.red) end)
    boxWrap:SetScript("OnLeave", function() UI.tintBorder(boxWrap, C.tabBorder) end)

    row.Refresh = refresh
    refresh()
    return row
end

-- ── Colours popup ───────────────────────────────────────────────────────────
-- Three levels, coarse to fine: whole-palette themes, accent presets that re-hue
-- whatever is on, then one swatch per entry with its own opacity, plus window
-- opacity and a reset. A floating window rather than a settings tab because it
-- recolours the settings window itself, so it must stay readable while what's
-- underneath changes — and it's themed from the palette it edits, so the swatch
-- grid doubles as the preview.

local SWATCH_ROWS  = 8    -- per column; UI.paletteOrder fills them top-down
local SWATCH_ROW_H = 24
local SWATCH_COL_W = 190
-- Anchored at a fixed offset from the top rather than chained off the element
-- before it: the hint wraps to two lines, and a chain would let a re-worded or
-- localised one push the grid into the footer.
local SWATCH_TOP   = 156
local SWATCH_OPAC  = 36   -- the window-opacity row, between grid and footer

-- Theme buttons: two rows of three, indented past the "Theme:" label.
local THEME_BTN_W, THEME_BTN_H = 76, 20
local THEME_PER_ROW = 3
local THEME_X       = 68
local SWATCH_FOOT  = 46

-- Blizzard has shipped two colour-picker APIs and they disagree about alpha. The
-- modern one returns the real value from GetColorAlpha(); the pre-10.2.5 one
-- kept 1 - alpha, so that path is inverted in both directions.
local function pickerAlpha()
    if ColorPickerFrame.GetColorAlpha then return ColorPickerFrame:GetColorAlpha() end
    local slider = _G.OpacitySliderFrame
    if slider and slider.GetValue then return 1 - slider:GetValue() end
    return 1
end

local function getColorsPopup()
    if UI.colorsPopup then return UI.colorsPopup end

    local panel = CreateFrame("Frame", "DrievColorsPopup", UIParent, "BackdropTemplate")
    -- DIALOG, not the TOOLTIP the other floating panels use: it must sit above the
    -- settings window (HIGH) but below ColorPickerFrame (FULLSCREEN_DIALOG), which
    -- every swatch opens on top of it.
    panel:SetFrameStrata("DIALOG")
    applyBackdrop(panel, 2, C.panelBG, C.red)
    panel:EnableMouse(true)
    panel:SetMovable(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
    panel:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
    panel:Hide()

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("Colors")
    UI.tint(title, C.red)

    closeButton(panel)

    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOPLEFT", 14, -38)
    hint:SetWidth(SWATCH_COL_W * 2 - 14); hint:SetJustifyH("LEFT")
    hint:SetText("Click a swatch to pick a color and its opacity, right-click it for that entry's default. Saved with the active profile.")
    UI.tint(hint, C.textDim)

    local swatches = {}

    -- Refresh is the panel's rather than the swatch loop's, because a theme moves
    -- the window-opacity readout too.
    local themeLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    themeLbl:SetPoint("TOPLEFT", 14, -78)
    themeLbl:SetText("Theme:")
    UI.tint(themeLbl, C.textGrey)

    -- Three to a row, which puts one accent's ramp on each row and keeps the popup
    -- as wide as its two swatch columns rather than six buttons in a line.
    for i, theme in ipairs(UI.themePresets) do
        local col = (i - 1) % THEME_PER_ROW
        local row = math.floor((i - 1) / THEME_PER_ROW)
        local btn = flatButton(panel, theme.name, THEME_BTN_W, THEME_BTN_H, "GameFontNormalSmall")
        btn:SetPoint("TOPLEFT", panel, "TOPLEFT",
            THEME_X + col * (THEME_BTN_W + 5),
            -74 - row * (THEME_BTN_H + 4))
        btn:SetScript("OnClick", function()
            UI.ApplyTheme(theme)
            panel:Refresh()
        end)
    end

    -- One click sets the accent and the two entries that shadow it, without touching
    -- the neutral shades — so it re-hues the current theme rather than replacing it.
    local presetLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    presetLbl:SetPoint("TOPLEFT", 14, -132)
    presetLbl:SetText("Accent:")
    UI.tint(presetLbl, C.textGrey)

    local prevPreset
    for _, preset in ipairs(UI.palettePresets) do
        local btn = CreateFrame("Button", nil, panel, "BackdropTemplate")
        btn:SetSize(16, 16)
        applyBackdrop(btn, 1, preset.rgb, C.tabBorder)
        if prevPreset then
            btn:SetPoint("LEFT", prevPreset, "RIGHT", 5, 0)
        else
            btn:SetPoint("LEFT", presetLbl, "RIGHT", 8, 0)
        end
        btn:SetScript("OnEnter", function(self)
            UI.tintBorder(self, C.textWhite)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(preset.name)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function(self)
            UI.tintBorder(self, C.tabBorder)
            GameTooltip:Hide()
        end)
        btn:SetScript("OnClick", function()
            UI.ApplyPalettePreset(preset.rgb)
            for _, sw in ipairs(swatches) do sw.Refresh() end
        end)
        prevPreset = btn
    end

    -- Left-click opens the native picker (live-previewing as you drag, opacity
    -- included); right-click restores that entry's shipped colour.
    local function paletteSwatch(key, labelText)
        local sw = CreateFrame("Button", nil, panel, "BackdropTemplate")
        sw:SetSize(18, 18)
        -- Border only, no backdrop fill: the colour is a texture instead, so it
        -- can be drawn *over* the two-tone backing below and show its alpha.
        applyBackdrop(sw, 1, { 0, 0, 0, 0 }, C.tabBorder)
        sw:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        -- Half dark, half light: a colour below full alpha reads as a visible split down
        -- the middle, which is the only way a flat swatch can show transparency.
        local backDark = sw:CreateTexture(nil, "BACKGROUND")
        backDark:SetColorTexture(0.13, 0.13, 0.16, 1)
        backDark:SetPoint("TOPLEFT", 1, -1)
        backDark:SetPoint("BOTTOMRIGHT", sw, "BOTTOM", 0, 1)

        local backLight = sw:CreateTexture(nil, "BACKGROUND")
        backLight:SetColorTexture(0.78, 0.78, 0.82, 1)
        backLight:SetPoint("TOPLEFT", sw, "TOP", 0, -1)
        backLight:SetPoint("BOTTOMRIGHT", -1, 1)

        local fill = sw:CreateTexture(nil, "ARTWORK")
        fill:SetPoint("TOPLEFT", 1, -1)
        fill:SetPoint("BOTTOMRIGHT", -1, 1)

        local function paint()
            local r, g, b, a = UI.GetPaletteColor(key)
            fill:SetColorTexture(r, g, b, a)
            -- The percentage only earns its place once there's something to
            -- say; at full opacity it would be noise on all sixteen rows.
            if sw.rowLabel then
                if a < 0.995 then
                    sw.rowLabel:SetText(labelText .. "  " .. math.floor(a * 100 + 0.5) .. "%")
                else
                    sw.rowLabel:SetText(labelText)
                end
            end
        end

        sw:SetScript("OnClick", function(_, button)
            if button == "RightButton" then
                UI.ResetPaletteColor(key)
                for _, s in ipairs(swatches) do s.Refresh() end
                if panel.opacityStepper then panel.opacityStepper.Refresh() end
                return
            end
            local r, g, b, a = UI.GetPaletteColor(key)
            -- The stored override as it was before the picker opened (nil if this entry was
            -- still on its default). Restoring that exact value on cancel keeps "never
            -- touched" different from "set back to the default by hand", which is what lets
            -- a future change to the shipped palette still reach this entry.
            local s    = addon.db and addon.db.settings
            local prev = s and s.uiColors and s.uiColors[key]
            local function refreshAll()
                for _, sw2 in ipairs(swatches) do sw2.Refresh() end
                if panel.opacityStepper then panel.opacityStepper.Refresh() end
            end
            local function apply()
                local nr, ng, nb = ColorPickerFrame:GetColorRGB()
                UI.SetPaletteColor(key, nr, ng, nb, pickerAlpha())
                refreshAll()
            end
            local function cancel()
                if s then
                    s.uiColors = s.uiColors or {}
                    s.uiColors[key] = prev
                    UI.ApplyPalette()
                end
                refreshAll()
            end
            if ColorPickerFrame.SetupColorPickerAndShow then
                ColorPickerFrame:SetupColorPickerAndShow({
                    r = r, g = g, b = b, opacity = a, hasOpacity = true,
                    swatchFunc = apply, opacityFunc = apply, cancelFunc = cancel,
                })
            else
                ColorPickerFrame.hasOpacity  = true
                -- Inverted on this path: see pickerAlpha above.
                ColorPickerFrame.opacity     = 1 - a
                ColorPickerFrame.func        = apply
                ColorPickerFrame.opacityFunc = apply
                ColorPickerFrame.cancelFunc  = cancel
                ColorPickerFrame:SetColorRGB(r, g, b)
                ColorPickerFrame:Hide() -- force OnShow to refire with these values
                ColorPickerFrame:Show()
            end
        end)

        sw.Refresh = paint
        paint()
        return sw
    end

    for i, entry in ipairs(UI.paletteOrder) do
        local col = math.floor((i - 1) / SWATCH_ROWS)
        local row = (i - 1) % SWATCH_ROWS
        local sw  = paletteSwatch(entry.key, entry.label)
        sw:SetPoint("TOPLEFT", panel, "TOPLEFT",
            14 + col * SWATCH_COL_W, -SWATCH_TOP - row * SWATCH_ROW_H)

        local lbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("LEFT", sw, "RIGHT", 8, 0)
        lbl:SetWidth(SWATCH_COL_W - 34); lbl:SetJustifyH("LEFT")
        lbl:SetText(entry.label)
        UI.tint(lbl, C.textGrey)

        -- Handed to the swatch so its paint can append the opacity percentage.
        sw.rowLabel = lbl
        sw.Refresh()

        swatches[#swatches + 1] = sw
    end

    -- One control for the three background shades at once, since doing it entry by
    -- entry means keeping three alphas in step by hand.
    local opacityLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    opacityLbl:SetPoint("TOPLEFT", 14, -(SWATCH_TOP + SWATCH_ROWS * SWATCH_ROW_H + 8))
    opacityLbl:SetText("Window opacity:")
    UI.tint(opacityLbl, C.textGrey)

    local opacityStepper = buildStepper(panel, {
        min = 10, max = 100, step = 5,
        get = function() return UI.GetWindowOpacity() end,
        set = function(v) UI.SetWindowOpacity(v) end,
        onChange = function()
            for _, sw in ipairs(swatches) do sw.Refresh() end
        end,
    })
    opacityStepper:SetPoint("LEFT", opacityLbl, "RIGHT", 8, 0)
    panel.opacityStepper = opacityStepper

    local opacitySuffix = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    opacitySuffix:SetPoint("LEFT", opacityStepper.plus, "RIGHT", 6, 0)
    opacitySuffix:SetText("%")
    UI.tint(opacitySuffix, C.textDim)

    local resetBtn = flatButton(panel, "Reset all", 90, 22)
    resetBtn:SetPoint("BOTTOMLEFT", 14, 12)
    resetBtn:SetScript("OnClick", function()
        -- UI.showConfirmPopup rather than the local: the dialog is defined
        -- further down the file and a plain local isn't visible from up here.
        UI.showConfirmPopup({
            title       = "Reset colors",
            message     = "Put every color back to the addon default?",
            confirmText = "Reset",
            onConfirm   = function()
                UI.ResetPalette()
                panel:Refresh()
            end,
        })
    end)

    local doneBtn = flatButton(panel, "Done", 90, 22)
    doneBtn:SetPoint("BOTTOMRIGHT", -14, 12)
    doneBtn:SetScript("OnClick", function() panel:Hide() end)

    panel:SetSize(SWATCH_COL_W * 2 + 28,
        SWATCH_TOP + SWATCH_ROWS * SWATCH_ROW_H + SWATCH_OPAC + SWATCH_FOOT)
    -- Same relaxed clamp as the settings window it anchors to — a strictly clamped
    -- popup would visibly snap away from that anchor near the right edge. Applied
    -- here rather than with the other frame setup, since the insets derive from size.
    addon.ApplyOffscreenClamp(panel, true, true)

    function panel:Refresh()
        for _, sw in ipairs(swatches) do sw.Refresh() end
        opacityStepper.Refresh()
    end

    tinsert(UISpecialFrames, "DrievColorsPopup")
    UI.colorsPopup = panel
    return panel
end

local SIDEBAR_W = 150
local MIN_WIN_W, MIN_WIN_H = 760, 420
local MAX_WIN_W, MAX_WIN_H = 1800, 1200

local function createMainFrame()
    local f = CreateFrame("Frame", "DrievSettingsFrame", UIParent, "BackdropTemplate")
    -- Wider than before to make room for the nav sidebar while keeping the content
    -- area roughly the width the panels were designed against. Used until the resize
    -- grip persists something else.
    local savedW = addon.db and addon.db.settings and addon.db.settings.settingsWinW
    local savedH = addon.db and addon.db.settings and addon.db.settings.settingsWinH
    f:SetSize(savedW or 1000, savedH or 560)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:SetResizable(true)
    if f.SetResizeBounds then
        f:SetResizeBounds(MIN_WIN_W, MIN_WIN_H, MAX_WIN_W, MAX_WIN_H)
    elseif f.SetMinResize then
        f:SetMinResize(MIN_WIN_W, MIN_WIN_H)
        if f.SetMaxResize then f:SetMaxResize(MAX_WIN_W, MAX_WIN_H) end
    end
    -- Draggable most of the way off screen, keeping a strip of the top bar to grab
    -- it back by. Re-applied on every size change, since the insets derive from the
    -- window's dimensions.
    addon.ApplyOffscreenClamp(f, true, true)
    f:HookScript("OnSizeChanged", function(self)
        addon.ApplyOffscreenClamp(self, true, true)
    end)
    f:EnableMouse(true)
    f:SetScale(addon.GetUIScale())
    applyBackdrop(f, 2, C.panelBG, C.red)
    f:Hide()

    -- Full-height left sidebar: brand header at the top, vertical nav below.
    -- Draggable (grabbing anywhere not on a nav button moves the window).
    local sidebar = CreateFrame("Frame", nil, f, "BackdropTemplate")
    -- +2 so the sidebar covers what was a 2px gutter down its right edge, rather
    -- than the window backdrop showing through as a slit.
    sidebar:SetWidth(SIDEBAR_W + 2)
    sidebar:SetPoint("TOPLEFT", 2, -2)
    sidebar:SetPoint("BOTTOMLEFT", 2, 2)
    applyBackdrop(sidebar, 1, C.panelDark)
    sidebar:EnableMouse(true)
    sidebar:RegisterForDrag("LeftButton")
    sidebar:SetScript("OnMouseDown", function() f:StartMoving() end)
    sidebar:SetScript("OnMouseUp",   function() f:StopMovingOrSizing() end)

    -- Centred rather than left-aligned: anchoring by TOP centres each string on its
    -- own width, so the version line sits under the middle of the title rather than
    -- under its first letter.
    local title = sidebar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", sidebar, "TOP", 0, -12)
    title:SetText("|cfffb2c36Driev's|r |cffffffffEssentials|r")

    local version = sidebar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    version:SetPoint("TOP", title, "BOTTOM", 0, -3)
    version:SetText("|cffaaaaaav" .. addon.version .. "|r")

    -- Top bar spanning only the content area (right of the sidebar). Holds the
    -- Edit Mode + close buttons; also draggable.
    local topBar = CreateFrame("Frame", nil, f, "BackdropTemplate")
    -- 40 rather than 34: the extra height lets the content box sit 2px below the top
    -- bar while still lining each panel's tab bar up with the first nav button.
    topBar:SetHeight(40)
    topBar:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 0, 0)
    topBar:SetPoint("TOPRIGHT", -2, -2)
    applyBackdrop(topBar, 1, C.panelDark)
    topBar:EnableMouse(true)
    topBar:RegisterForDrag("LeftButton")
    topBar:SetScript("OnMouseDown", function() f:StartMoving() end)
    topBar:SetScript("OnMouseUp",   function() f:StopMovingOrSizing() end)

    local close = CreateFrame("Button", nil, topBar)
    close:SetSize(26, 26)
    close:SetPoint("RIGHT", -6, 0)
    local closeLabel = close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    closeLabel:SetPoint("CENTER")
    closeLabel:SetText("X")
    UI.tint(closeLabel, C.red)
    close:SetScript("OnEnter", function() UI.tint(closeLabel, C.textWhite) end)
    close:SetScript("OnLeave", function() UI.tint(closeLabel, C.red) end)
    close:SetScript("OnClick", function() f:Hide() end)

    local moveUIBtn = flatButton(topBar, "Edit Mode", 90, 22)
    moveUIBtn:SetPoint("RIGHT", close, "LEFT", -6, 0)
    moveUIBtn:SetScript("OnClick", function() UI.EnterMoveMode() end)

    local scaleSlider = buildEditSlider(topBar, {
        label = "Scale", labelWidth = 36, min = 50, max = 150, suffix = "%", deferSet = true,
        get = function() return math.floor(addon.GetUIScale() * 100 + 0.5) end,
        set = function(v) addon.SetUIScale(v / 100) end,
    })
    scaleSlider:SetPoint("RIGHT", moveUIBtn, "LEFT", -14, 0)

    -- These write the same saved settingsWinW/H the resize grip persists (and are
    -- refreshed from it), so typed size and corner-drag stay in sync.
    local heightStepper = buildSizeStepper(topBar, {
        label = "H", min = MIN_WIN_H, max = MAX_WIN_H, step = 10,
        get = function() return math.floor(f:GetHeight() + 0.5) end,
        set = function(v)
            f:SetHeight(v)
            if addon.db and addon.db.settings then addon.db.settings.settingsWinH = v end
        end,
    })
    heightStepper:SetPoint("RIGHT", scaleSlider, "LEFT", -16, 0)

    local widthStepper = buildSizeStepper(topBar, {
        label = "W", min = MIN_WIN_W, max = MAX_WIN_W, step = 10,
        get = function() return math.floor(f:GetWidth() + 0.5) end,
        set = function(v)
            f:SetWidth(v)
            if addon.db and addon.db.settings then addon.db.settings.settingsWinW = v end
        end,
    })
    widthStepper:SetPoint("RIGHT", heightStepper, "LEFT", -10, 0)

    -- Anchored to the settings window rather than parented to it, so it stays put
    -- and readable while the window it is recolouring redraws underneath.
    local colorsBtn = flatButton(topBar, "Colors", 70, 22)
    colorsBtn:SetPoint("RIGHT", widthStepper, "LEFT", -14, 0)
    colorsBtn:SetScript("OnClick", function()
        local popup = getColorsPopup()
        if popup:IsShown() then
            popup:Hide()
        else
            popup:SetScale(addon.GetUIScale())
            popup:ClearAllPoints()
            popup:SetPoint("TOPLEFT", f, "TOPRIGHT", 8, 0)
            popup:Refresh()
            popup:Show()
        end
    end)
    f:HookScript("OnHide", function()
        if UI.colorsPopup then UI.colorsPopup:Hide() end
    end)

    local content = CreateFrame("Frame", nil, f, "BackdropTemplate")
    -- 2px gap below the top bar. The tab bars still line up with the sidebar nav
    -- because the top bar is 6px taller than its contents need.
    content:SetPoint("TOPLEFT", topBar, "BOTTOMLEFT", 0, -2)
    content:SetPoint("BOTTOMRIGHT", -2, 2)
    applyBackdrop(content, 1, C.panelDeep)

    -- Resize grip, bottom-right. Leaves the window's edges alone and just
    -- starts/stops a native resize; every panel re-anchors off `content`, and
    -- attachScrollTrack's bottom clearance keeps this off a tab's scrollbar.
    local sizer = CreateFrame("Button", nil, f)
    sizer:SetSize(16, 16)
    sizer:SetPoint("BOTTOMRIGHT", -3, 3)
    sizer:SetFrameLevel(f:GetFrameLevel() + 10)
    local grip = sizer:CreateTexture(nil, "OVERLAY")
    grip:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetAllPoints()
    sizer:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then f:StartSizing("BOTTOMRIGHT") end
    end)
    sizer:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        if addon.db and addon.db.settings then
            addon.db.settings.settingsWinW = f:GetWidth()
            addon.db.settings.settingsWinH = f:GetHeight()
        end
        widthStepper:Refresh()
        heightStepper:Refresh()
    end)

    f.topBar  = topBar
    f.sidebar = sidebar
    f.content = content
    f.tabs    = {}
    f.panels  = {}
    f.tabDots = {}   -- key -> status dot texture, for tabs that registered a status()

    tinsert(UISpecialFrames, "DrievSettingsFrame")
    return f
end

-- ── Profile export/import popup ─────────────────────────────────────────────
-- One shared floating window for both showing an export string (pre-selected for
-- Ctrl+C) and pasting an import string. Same floating-panel style as
-- getPositionEditor.

local function getTextPopup()
    if UI.textPopup then return UI.textPopup end

    local panel = CreateFrame("Frame", "DrievTextPopup", UIParent, "BackdropTemplate")
    panel:SetSize(460, 400)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("TOOLTIP")
    applyBackdrop(panel, 2, C.panelBG, C.red)
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    panel:SetMovable(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
    panel:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
    panel:Hide()

    -- Every element is a fixed size anchored via single-point TOP/BOTTOM chains
    -- centred on the previous one, rather than TOPLEFT+TOPRIGHT pairs relative to
    -- the variable-width title — otherwise the popup's width would shift with how
    -- long the title happens to be.
    local CONTENT_W = 420

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", panel, "TOP", 0, -12)
    title:SetWidth(CONTENT_W)
    title:SetJustifyH("CENTER")
    UI.tint(title, C.red)
    panel.title = title

    closeButton(panel)

    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOP", title, "BOTTOM", 0, -8)
    hint:SetWidth(CONTENT_W)
    hint:SetJustifyH("CENTER")
    UI.tint(hint, C.textGrey)
    panel.hint = hint

    -- Import-only: profile name to import into. Hidden for Export, where the
    -- popup instead re-anchors scrollWrap straight under the hint text.
    local nameRow = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    nameRow:SetSize(220, 24)
    nameRow:SetPoint("TOP", hint, "BOTTOM", 0, -10)
    applyBackdrop(nameRow, 1, C.panelDark, C.tabBorder)

    local nameEdit = CreateFrame("EditBox", nil, nameRow)
    nameEdit:SetSize(206, 18)
    nameEdit:SetPoint("CENTER")
    nameEdit:SetAutoFocus(false)
    nameEdit:SetMaxLetters(32)
    nameEdit:SetFontObject("GameFontNormal")
    UI.tint(nameEdit, C.textWhite)
    nameEdit:SetTextInsets(4, 4, 0, 0)
    nameEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    panel.nameRow, panel.nameEdit = nameRow, nameEdit

    nameEdit:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        panel.box:SetFocus()
    end)

    local SB_W = 10   -- scrollbar track width, matches the font-picker dropdown

    local scrollWrap = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    scrollWrap:SetSize(CONTENT_W, 190)
    scrollWrap:SetPoint("TOP", hint, "BOTTOM", 0, -10)
    applyBackdrop(scrollWrap, 1, C.panelDark, C.tabBorder)
    panel.scrollWrap = scrollWrap

    -- Plain ScrollFrame (no template): the scrollbar below is hand-built to match
    -- the themed track/thumb used elsewhere rather than Blizzard's default.
    local scroll = CreateFrame("ScrollFrame", nil, scrollWrap)
    scroll:SetPoint("TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", -(SB_W + 8), 6)

    local box = CreateFrame("EditBox", nil, scroll)
    box:SetMultiLine(true)
    box:SetAutoFocus(false)
    box:SetFontObject("ChatFontNormal")
    UI.tint(box, C.textWhite)
    box:SetWidth(CONTENT_W - SB_W - 40)
    box:SetHeight(500)
    box:EnableMouse(true)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(box)
    panel.box = box

    local track = CreateFrame("Frame", nil, scrollWrap, "BackdropTemplate")
    track:SetWidth(SB_W)
    track:SetPoint("TOPRIGHT",    scrollWrap, "TOPRIGHT",    -1, -1)
    track:SetPoint("BOTTOMRIGHT", scrollWrap, "BOTTOMRIGHT", -1,  1)
    applyBackdrop(track, 1, C.panelDeep, C.tabBorder)

    local thumb = CreateFrame("Button", nil, track, "BackdropTemplate")
    thumb:SetWidth(SB_W - 2)
    applyBackdrop(thumb, 1, C.tabIdle, C.tabBorder)
    thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 1, 0)

    local function updateThumb()
        local maxScroll = scroll:GetVerticalScrollRange()
        local visibleH  = scroll:GetHeight()
        if maxScroll <= 0 then track:Hide(); return end
        track:Show()
        local trackH = track:GetHeight()
        if trackH <= 0 then return end
        local thumbH = math.max(16, trackH * visibleH / (visibleH + maxScroll))
        local cur    = scroll:GetVerticalScroll()
        local frac   = maxScroll > 0 and (cur / maxScroll) or 0
        thumb:SetHeight(thumbH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 1, -(frac * (trackH - thumbH)))
    end
    panel.updateThumb = updateThumb
    box:SetScript("OnTextChanged", updateThumb)
    box:SetScript("OnCursorChanged", updateThumb)

    local isDragging, dragStartY, dragStartScroll = false, 0, 0
    thumb:EnableMouse(true)
    thumb:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then
            isDragging      = true
            dragStartY      = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
            dragStartScroll = scroll:GetVerticalScroll()
        end
    end)
    thumb:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then isDragging = false end
    end)
    thumb:SetScript("OnUpdate", function()
        if not isDragging then return end
        local curY      = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
        local delta      = dragStartY - curY
        local trackH     = track:GetHeight()
        local thumbH     = thumb:GetHeight()
        local maxScroll  = scroll:GetVerticalScrollRange()
        if trackH > thumbH and maxScroll > 0 then
            scroll:SetVerticalScroll(math.max(0, math.min(
                dragStartScroll + delta * maxScroll / (trackH - thumbH),
                maxScroll
            )))
            updateThumb()
        end
    end)
    thumb:SetScript("OnEnter", function(self) UI.tintBg(self, C.tabHover) end)
    thumb:SetScript("OnLeave", function(self) UI.tintBg(self, C.tabIdle)  end)

    scrollWrap:EnableMouseWheel(true)
    scrollWrap:SetScript("OnMouseWheel", function(_, d)
        local maxScroll = scroll:GetVerticalScrollRange()
        scroll:SetVerticalScroll(math.max(0, math.min(scroll:GetVerticalScroll() - d * 20, maxScroll)))
        updateThumb()
    end)

    -- The visible area is much shorter than the box itself, so clicking blank space
    -- below short text still needs to focus it — forward those clicks explicitly.
    scrollWrap:EnableMouse(true)
    scrollWrap:SetScript("OnMouseDown", function() box:SetFocus() end)
    scroll:EnableMouse(true)
    scroll:SetScript("OnMouseDown", function() box:SetFocus() end)

    local errText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    errText:SetPoint("TOP", scrollWrap, "BOTTOM", 0, -8)
    errText:SetWidth(CONTENT_W)
    errText:SetJustifyH("CENTER")
    UI.tint(errText, C.red)
    panel.errText = errText

    local actionBtn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    actionBtn:SetSize(120, 24)
    actionBtn:SetPoint("BOTTOM", panel, "BOTTOM", 0, 14)
    applyBackdrop(actionBtn, 1, C.panelDark, C.tabBorder)
    local actionLbl = actionBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    actionLbl:SetPoint("CENTER"); UI.tint(actionLbl, C.textWhite)
    actionBtn:SetScript("OnEnter", function() UI.tintBorder(actionBtn, C.red) end)
    actionBtn:SetScript("OnLeave", function() UI.tintBorder(actionBtn, C.tabBorder) end)
    panel.actionBtn, panel.actionLbl = actionBtn, actionLbl

    UI.textPopup = panel
    return panel
end

-- The one big-text-box dialog, driven entirely by its caller so it covers both
-- directions: showing a string to copy and taking one to paste. Exposed to
-- modules via UI.widgets (Item Rack exports its sets with it).
--
-- opts = {
--   title, hint, text, error,   -- what to display
--   showName, name,             -- show (and prefill) the name row
--   actionText,                 -- label on the bottom button
--   selectAll,                  -- focus and pre-select the box, for exports
--   onAction(name, text)        -- true to close, or nil + message to stay open
-- }
local function showTextPopup(opts)
    local panel = getTextPopup()
    panel.title:SetText(opts.title or "")
    panel.hint:SetText(opts.hint or "")
    panel.errText:SetText(opts.error or "")
    panel.box:SetText(opts.text or "")
    panel.nameEdit:SetText(opts.name or "")
    panel.actionLbl:SetText(opts.actionText or "Close")
    panel.actionBtn:SetScript("OnClick", function()
        if not opts.onAction then panel:Hide() return end
        local ok, err = opts.onAction(panel.nameEdit:GetText(), panel.box:GetText())
        if ok then
            panel:Hide()
        else
            panel.errText:SetText(err or "That didn't work.")
        end
    end)

    -- Without the name row the box takes its place, so the dialog doesn't open
    -- with a gap where it would have been.
    panel.nameRow:SetShown(opts.showName and true or false)
    panel.scrollWrap:ClearAllPoints()
    panel.scrollWrap:SetPoint("TOP", opts.showName and panel.nameRow or panel.hint, "BOTTOM", 0, -10)

    panel:Show()
    if opts.showName then
        panel.nameEdit:SetFocus()
    elseif opts.selectAll then
        panel.box:SetFocus()
        panel.box:HighlightText()
    end
    panel.updateThumb()
end
UI.showTextPopup = showTextPopup

-- ── Themed confirmation popup ────────────────────────────────────────────────
-- Same floating-panel look as getTextPopup (draggable TOOLTIP-strata
-- BackdropTemplate frame), but for a yes/no prompt instead of text entry.

local function getConfirmPopup()
    if UI.confirmPopup then return UI.confirmPopup end

    local panel = CreateFrame("Frame", "DrievConfirmPopup", UIParent, "BackdropTemplate")
    panel:SetSize(360, 150)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("TOOLTIP")
    applyBackdrop(panel, 2, C.panelBG, C.red)
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    panel:SetMovable(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
    panel:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
    panel:Hide()

    local CONTENT_W = 320

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", panel, "TOP", 0, -14)
    title:SetWidth(CONTENT_W)
    title:SetJustifyH("CENTER")
    UI.tint(title, C.red)
    panel.title = title

    local message = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    message:SetPoint("TOP", title, "BOTTOM", 0, -16)
    message:SetWidth(CONTENT_W)
    message:SetJustifyH("CENTER")
    UI.tint(message, C.textWhite)
    panel.message = message

    local cancelBtn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    cancelBtn:SetSize(120, 24)
    cancelBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOM", 6, 16)
    applyBackdrop(cancelBtn, 1, C.panelDark, C.tabBorder)
    local cancelLbl = cancelBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    cancelLbl:SetPoint("CENTER"); cancelLbl:SetText("Cancel"); UI.tint(cancelLbl, C.textWhite)
    cancelBtn:SetScript("OnEnter", function() UI.tintBorder(cancelBtn, C.red) end)
    cancelBtn:SetScript("OnLeave", function() UI.tintBorder(cancelBtn, C.tabBorder) end)
    cancelBtn:SetScript("OnClick", function() panel:Hide() end)
    panel.cancelBtn = cancelBtn

    -- One place for "dismissed without confirming", so it covers the Cancel
    -- button and anything else that hides the dialog alike.
    panel:SetScript("OnHide", function(self)
        local onCancel = self.onCancel
        self.onCancel = nil
        if onCancel then onCancel() end
    end)

    local confirmBtn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    confirmBtn:SetSize(120, 24)
    confirmBtn:SetPoint("BOTTOMRIGHT", panel, "BOTTOM", -6, 16)
    applyBackdrop(confirmBtn, 1, C.panelDark, C.tabBorder)
    local confirmLbl = confirmBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    confirmLbl:SetPoint("CENTER"); UI.tint(confirmLbl, C.textWhite)
    confirmBtn:SetScript("OnEnter", function() UI.tintBorder(confirmBtn, C.red) end)
    confirmBtn:SetScript("OnLeave", function() UI.tintBorder(confirmBtn, C.tabBorder) end)
    panel.confirmBtn, panel.confirmLbl = confirmBtn, confirmLbl

    UI.confirmPopup = panel
    return panel
end

-- opts = { title, message, confirmText, onConfirm, onCancel }
-- onCancel fires however the dialog is dismissed without confirming, so a
-- caller that suspended something while it asked (Item Rack's key-binding mode)
-- always gets control back.
local function showConfirmPopup(opts)
    local panel = getConfirmPopup()
    panel.title:SetText(opts.title or "Confirm")
    panel.message:SetText(opts.message or "")
    panel.confirmLbl:SetText(opts.confirmText or "Confirm")
    panel.confirmBtn:SetScript("OnClick", function()
        panel.onCancel = nil   -- consumed: OnHide below must not also fire it
        panel:Hide()
        if opts.onConfirm then opts.onConfirm() end
    end)
    panel.onCancel = opts.onCancel
    panel:Show()
end
-- Exposed for module addons (Trinkets uses it for the modifier-conflict prompt)
-- and for any panel defined above this point — a plain local isn't visible to
-- code written before its definition.
UI.showConfirmPopup = showConfirmPopup

-- ── Themed check-list popup ──────────────────────────────────────────────────
-- Same floating-panel look as the dialogs above, but the body is a scrollable
-- list of tickable rows. Item Rack uses it to choose which sets to export, and
-- to decide set by set which incoming sets may overwrite one of the same name.
-- Rows are pooled and re-labelled per call, so reopening never leaks frames.

local LIST_ROW_H = 22

local function getListPopup()
    if UI.listPopup then return UI.listPopup end

    local panel = CreateFrame("Frame", "DrievListPopup", UIParent, "BackdropTemplate")
    panel:SetSize(400, 440)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("TOOLTIP")
    applyBackdrop(panel, 2, C.panelBG, C.red)
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    panel:SetMovable(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
    panel:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
    panel:Hide()

    local CONTENT_W = 360

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", panel, "TOP", 0, -12)
    title:SetWidth(CONTENT_W)
    title:SetJustifyH("CENTER")
    UI.tint(title, C.red)
    panel.title = title

    closeButton(panel)

    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOP", title, "BOTTOM", 0, -8)
    hint:SetWidth(CONTENT_W)
    hint:SetJustifyH("CENTER")
    UI.tint(hint, C.textGrey)
    panel.hint = hint

    -- Hung off the hint rather than a fixed offset from the top: the hint is a
    -- fixed-width FontString, so it grows a line at a time with the caller's
    -- text, and the list has to start below whatever height that came to.
    -- Its BOTTOMLEFT is the left edge of the centred CONTENT_W block, which is
    -- exactly where the list wants to be.
    local listWrap = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    listWrap:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -32)
    listWrap:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -20, 66)
    applyBackdrop(listWrap, 1, C.panelDark, C.tabBorder)
    panel.listWrap = listWrap

    -- Select-all / none sit above the list rather than beside the action
    -- buttons: they change the list, so they read as part of it. Anchored off
    -- the list itself so the whole block moves with one anchor change.
    local allBtn = flatButton(panel, "Select All", 90, 20, "GameFontNormalSmall")
    allBtn:SetPoint("BOTTOMLEFT", listWrap, "TOPLEFT", 0, 6)
    panel.allBtn = allBtn

    local noneBtn = flatButton(panel, "Select None", 90, 20, "GameFontNormalSmall")
    noneBtn:SetPoint("LEFT", allBtn, "RIGHT", 8, 0)
    panel.noneBtn = noneBtn

    local countText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countText:SetPoint("BOTTOMRIGHT", listWrap, "TOPRIGHT", -2, 9)
    UI.tint(countText, C.textGrey)
    panel.countText = countText

    local scroll = CreateFrame("ScrollFrame", nil, listWrap)
    scroll:SetPoint("TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", -(SCROLLBAR_W + 8), 6)

    local inner = CreateFrame("Frame", nil, scroll)
    inner:SetSize(CONTENT_W - SCROLLBAR_W - 20, 1)
    scroll:SetScrollChild(inner)
    panel.scroll, panel.inner = scroll, inner

    local _, updateTrack = attachScrollTrack(scroll, listWrap)
    panel.updateTrack = updateTrack
    scroll:SetScript("OnSizeChanged", function(self, w)
        inner:SetWidth(w)
        updateTrack()
    end)

    local emptyText = inner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    emptyText:SetPoint("TOPLEFT", 4, -8)
    emptyText:SetWidth(CONTENT_W - SCROLLBAR_W - 28)
    emptyText:SetJustifyH("LEFT")
    UI.tint(emptyText, C.textDim)
    emptyText:Hide()
    panel.emptyText = emptyText

    local errText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    errText:SetPoint("BOTTOM", panel, "BOTTOM", 0, 46)
    errText:SetWidth(CONTENT_W)
    errText:SetJustifyH("CENTER")
    UI.tint(errText, C.red)
    panel.errText = errText

    -- Two buttons side by side when the caller wants a secondary action
    -- ("Export All"), one centred when it doesn't — repositioned per call.
    local actionBtn = flatButton(panel, "", 150, 24)
    panel.actionBtn = actionBtn

    local altBtn = flatButton(panel, "", 150, 24)
    panel.altBtn = altBtn

    panel.rows = {}

    -- One place for "dismissed without acting", mirroring the confirm popup so
    -- a caller mid-flow (Item Rack's import, which asks about conflicts before
    -- writing anything) always learns the user backed out.
    panel:SetScript("OnHide", function(self)
        local onCancel = self.onCancel
        self.onCancel = nil
        if onCancel then onCancel() end
    end)

    UI.listPopup = panel
    return panel
end

-- Builds/reuses row `index`, pointed at items[index].
local function listPopupRow(panel, index)
    local row = panel.rows[index]
    if row then return row end

    row = CreateFrame("Button", nil, panel.inner)
    row:SetHeight(LIST_ROW_H)
    row:SetPoint("TOPLEFT",  panel.inner, "TOPLEFT",  2, -((index - 1) * LIST_ROW_H))
    row:SetPoint("TOPRIGHT", panel.inner, "TOPRIGHT", -2, -((index - 1) * LIST_ROW_H))

    local hl = row:CreateTexture(nil, "BACKGROUND")
    hl:SetAllPoints()
    hl:SetTexture(WHITE)
    UI.tintTexture(hl, C.tabHover)
    hl:SetAlpha(0.35)
    hl:Hide()

    local box = CreateFrame("Frame", nil, row, "BackdropTemplate")
    box:SetSize(14, 14)
    box:SetPoint("LEFT", 4, 0)
    applyBackdrop(box, 1, C.checkBg, C.checkBorder)

    local fill = box:CreateTexture(nil, "ARTWORK")
    fill:SetTexture(WHITE)
    fill:SetPoint("TOPLEFT", 2, -2)
    fill:SetPoint("BOTTOMRIGHT", -2, 2)
    UI.tintTexture(fill, C.red)
    fill:Hide()

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", box, "RIGHT", 6, 0)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    icon:Hide()

    local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("LEFT", box, "RIGHT", 6, 0)
    text:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    text:SetJustifyH("LEFT")
    UI.tint(text, C.textWhite)

    row.box, row.fill, row.icon, row.text = box, fill, icon, text

    row:SetScript("OnEnter", function(self)
        hl:Show()
        UI.tintBorder(box, C.red)
    end)
    row:SetScript("OnLeave", function()
        hl:Hide()
        UI.tintBorder(box, C.checkBorder)
    end)
    row:SetScript("OnClick", function(self)
        if not self.item then return end
        self.item.checked = not self.item.checked
        self:Reflect()
        panel.refreshCount()
    end)

    function row:Reflect()
        if self.item and self.item.checked then fill:Show() else fill:Hide() end
    end

    panel.rows[index] = row
    return row
end

-- opts = {
--   title, hint, emptyText,
--   items = { { key, label, icon, checked }, ... },   -- `key` defaults to label
--   actionText, onAction(keys, items)  -- true closes, nil + message stays open
--   altText,    onAlt()                -- optional second button
--   onCancel,                          -- fires on dismissal without acting
-- }
-- Item `checked` flags are mutated in place, so a caller holding `items` can
-- read the final state itself.
local function showCheckListPopup(opts)
    local panel = getListPopup()
    local items = opts.items or {}

    -- One shared panel, so a second caller arriving while it's open would
    -- otherwise take it over and strand the first one's onCancel. Hiding first
    -- lets that fire and the previous flow unwind properly.
    if panel:IsShown() then panel:Hide() end

    panel.title:SetText(opts.title or "")
    panel.hint:SetText(opts.hint or "")
    panel.errText:SetText(opts.error or "")

    local function refreshCount()
        local n = 0
        for _, item in ipairs(items) do if item.checked then n = n + 1 end end
        panel.countText:SetText(n .. " / " .. #items)
    end
    panel.refreshCount = refreshCount

    for i, item in ipairs(items) do
        local row = listPopupRow(panel, i)
        row.item = item
        row.text:SetText(item.label or tostring(item.key))
        -- Re-anchored (not just re-textured) per call: the same pooled row can
        -- serve an icon-less list next time, and the label must close the gap.
        row.text:ClearAllPoints()
        row.text:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        if item.icon then
            row.icon:SetTexture(item.icon)
            row.icon:Show()
            row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        else
            row.icon:Hide()
            row.text:SetPoint("LEFT", row.box, "RIGHT", 6, 0)
        end
        row:Reflect()
        row:Show()
    end
    for i = #items + 1, #panel.rows do
        panel.rows[i].item = nil
        panel.rows[i]:Hide()
    end

    panel.emptyText:SetText(opts.emptyText or "Nothing to show.")
    panel.emptyText:SetShown(#items == 0)
    -- Scroll child height must reflect only the rows in use, or the list
    -- scrolls down into blank space left by a previous, longer call. The
    -- offset resets with it: a dialog should open at the top of its list, not
    -- wherever the last one was left scrolled to.
    panel.inner:SetHeight(math.max(1, #items * LIST_ROW_H))
    panel.scroll:SetVerticalScroll(0)
    panel.updateTrack()

    local function setAll(v)
        for _, item in ipairs(items) do item.checked = v end
        for _, row in ipairs(panel.rows) do if row.item then row:Reflect() end end
        refreshCount()
    end
    panel.allBtn:SetScript("OnClick",  function() setAll(true)  end)
    panel.noneBtn:SetScript("OnClick", function() setAll(false) end)
    refreshCount()

    local function selectedKeys()
        local keys = {}
        for _, item in ipairs(items) do
            if item.checked then keys[#keys + 1] = item.key or item.label end
        end
        return keys
    end

    panel.actionBtn.label:SetText(opts.actionText or "OK")
    panel.actionBtn:SetScript("OnClick", function()
        if not opts.onAction then panel:Hide() return end
        local ok, err = opts.onAction(selectedKeys(), items)
        if ok then
            panel.onCancel = nil   -- consumed: acting isn't cancelling
            panel:Hide()
        else
            panel.errText:SetText(err or "That didn't work.")
        end
    end)

    panel.actionBtn:ClearAllPoints()
    panel.altBtn:ClearAllPoints()
    if opts.altText then
        panel.altBtn.label:SetText(opts.altText)
        panel.altBtn:SetPoint("BOTTOMRIGHT", panel, "BOTTOM", -6, 14)
        panel.actionBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOM", 6, 14)
        panel.altBtn:SetScript("OnClick", function()
            if not opts.onAlt then panel:Hide() return end
            local ok, err = opts.onAlt(items)
            if ok then
                panel.onCancel = nil
                panel:Hide()
            else
                panel.errText:SetText(err or "That didn't work.")
            end
        end)
        panel.altBtn:Show()
    else
        panel.actionBtn:SetPoint("BOTTOM", panel, "BOTTOM", 0, 14)
        panel.altBtn:Hide()
    end

    panel.onCancel = opts.onCancel
    panel:Show()
    panel.updateTrack()
end
UI.showCheckListPopup = showCheckListPopup

-- ── Profile export / import flows ────────────────────────────────────────────
-- Every one of them is "pick some modules, then do the thing", so they all open
-- the same check-list popup over core's section registry. Defined here rather
-- than beside getTextPopup() because they need showCheckListPopup above.

-- Rows for the module picker, everything ticked. `filter` (a list of section
-- keys) narrows it to what an import string actually carries — offering a
-- module the string says nothing about would reset it to defaults.
local function profileSectionItems(filter)
    local allow
    if filter then
        allow = {}
        for _, key in ipairs(filter) do allow[key] = true end
    end
    local items = {}
    for _, sec in ipairs(addon.GetProfileSections()) do
        if not allow or allow[sec.key] then
            items[#items + 1] = { key = sec.key, label = sec.label, checked = true }
        end
    end
    return items
end

-- nil when every module is ticked: the core calls all take "nil = the whole
-- profile", which keeps a full export byte-identical to what earlier versions
-- produced and a full copy a straight profile replacement.
local function selectionOrAll(keys, items)
    if #keys >= #items then return nil end
    return keys
end

local function showExportString(profileName, only)
    local exportStr, err = addon.ExportProfile(profileName, only)
    showTextPopup({
        title      = "Export Profile: " .. profileName,
        hint       = "Copy this string (Ctrl+A, Ctrl+C) and share it with someone else.",
        text       = exportStr or "",
        error      = exportStr and "" or (err or "Could not export this profile."),
        actionText = "Close",
        selectAll  = true,
    })
end

local function showExportPopup(profileName)
    local items = profileSectionItems()
    showCheckListPopup({
        title      = "Export Profile: " .. profileName,
        hint       = "Choose what to include. Leave everything ticked to export the whole profile.",
        items      = items,
        emptyText  = "No modules are loaded.",
        actionText = "Export",
        onAction   = function(keys)
            if #keys == 0 then return nil, "Tick at least one module to export." end
            showExportString(profileName, selectionOrAll(keys, items))
            return true
        end,
    })
end

-- Import as a NEW profile: whatever the string doesn't carry arrives as
-- defaults, so there's nothing to pick.
local function showImportPopup(onImported)
    showTextPopup({
        title      = "Import Profile",
        hint       = "Enter a name for the new profile, paste a string exported from Driev's Essentials below, then click Import.",
        showName   = true,
        actionText = "Import",
        onAction   = function(name, text)
            local profName, err = addon.ImportProfile(name, text)
            if not profName then return nil, err or "Import failed." end
            if onImported then onImported(profName) end
            return true
        end,
    })
end

-- Import into an EXISTING profile: the string is decoded first so the picker can
-- list what it actually holds, and only ticked modules are replaced.
local function showImportIntoPopup(profileName, onImported)
    showTextPopup({
        title      = "Import Into: " .. profileName,
        hint       = "Paste a string exported from Driev's Essentials below, then choose which modules to bring in.",
        actionText = "Continue",
        onAction   = function(_, text)
            local data, sections, err = addon.ReadProfileString(text)
            if not data then return nil, err or "Import failed." end

            local items = profileSectionItems(sections)
            if #items == 0 then
                return nil, "That string doesn't carry any module this install knows about."
            end

            showCheckListPopup({
                title      = "Import Into: " .. profileName,
                hint       = string.format('Ticked modules replace what "%s" has now. Everything else in it is left alone.', profileName),
                items      = items,
                actionText = "Import",
                onAction   = function(keys)
                    if #keys == 0 then return nil, "Tick at least one module to import." end
                    local ok, impErr = addon.ImportProfileSections(profileName, data, keys)
                    if not ok then return nil, impErr or "Import failed." end
                    if onImported then onImported(profileName) end
                    return true
                end,
            })
            return true
        end,
    })
end

-- ── Profiles tab ─────────────────────────────────────────────────────────────

local function buildProfilesPanel(parent)
    local shell, panel = makeScrollPanel(parent)

    -- Forward-declared so the Copy Profile section's button (built before the
    -- Existing Profiles list) can re-run it after a copy.
    local refreshProfiles

    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 14, -14)
    header:SetText("Profiles")
    UI.tint(header, C.red)

    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    desc:SetWidth(560); desc:SetJustifyH("LEFT")
    desc:SetText("Every setting and saved position belongs to a profile. Switch profiles to use a different setup on this character — handy for separate configs per character or class.")
    UI.tint(desc, C.textGrey)

    -- ── Create new profile ────────────────────────────────────────────────
    local newHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    newHeader:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -20)
    newHeader:SetText("New Profile")
    UI.tint(newHeader, C.red)

    local nameBoxWrap = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    nameBoxWrap:SetSize(220, 24)
    nameBoxWrap:SetPoint("TOPLEFT", newHeader, "BOTTOMLEFT", 0, -10)
    applyBackdrop(nameBoxWrap, 1, C.panelDark, C.tabBorder)

    local nameBox = CreateFrame("EditBox", nil, nameBoxWrap)
    nameBox:SetSize(206, 18)
    nameBox:SetPoint("CENTER")
    nameBox:SetAutoFocus(false)
    nameBox:SetMaxLetters(32)
    nameBox:SetFontObject("GameFontNormal")
    UI.tint(nameBox, C.textWhite)
    nameBox:SetTextInsets(4, 4, 0, 0)

    local createBtn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    createBtn:SetSize(90, 24)
    createBtn:SetPoint("LEFT", nameBoxWrap, "RIGHT", 8, 0)
    applyBackdrop(createBtn, 1, C.panelDark, C.tabBorder)
    local createLbl = createBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    createLbl:SetPoint("CENTER"); createLbl:SetText("Create"); UI.tint(createLbl, C.textWhite)
    createBtn:SetScript("OnEnter", function() UI.tintBorder(createBtn, C.red) end)
    createBtn:SetScript("OnLeave", function() UI.tintBorder(createBtn, C.tabBorder) end)

    local importBtn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    importBtn:SetSize(120, 24)
    importBtn:SetPoint("LEFT", createBtn, "RIGHT", 8, 0)
    applyBackdrop(importBtn, 1, C.panelDark, C.tabBorder)
    local importLbl = importBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    importLbl:SetPoint("CENTER"); importLbl:SetText("Import Profile"); UI.tint(importLbl, C.textWhite)
    importBtn:SetScript("OnEnter", function() UI.tintBorder(importBtn, C.red) end)
    importBtn:SetScript("OnLeave", function() UI.tintBorder(importBtn, C.tabBorder) end)

    local errText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    errText:SetPoint("TOPLEFT", nameBoxWrap, "BOTTOMLEFT", 0, -6)
    UI.tint(errText, C.red)
    errText:SetText("")

    -- ── Copy profile ──────────────────────────────────────────────────────
    -- Pick a source and destination, then Copy (with a confirm prompt) to overwrite
    -- the destination with the source's settings.
    local copyHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    copyHeader:SetPoint("TOPLEFT", errText, "BOTTOMLEFT", 0, -20)
    copyHeader:SetText("Copy Profile")
    UI.tint(copyHeader, C.red)

    local copyDesc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    copyDesc:SetPoint("TOPLEFT", copyHeader, "BOTTOMLEFT", 0, -4)
    copyDesc:SetWidth(560); copyDesc:SetJustifyH("LEFT")
    copyDesc:SetText("Overwrite one profile's settings with a copy of another's — either all of it, or just the modules you pick.")
    UI.tint(copyDesc, C.textGrey)

    local copyFrom, copyTo

    local fromLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fromLbl:SetPoint("TOPLEFT", copyDesc, "BOTTOMLEFT", 0, -12)
    fromLbl:SetText("From:")
    UI.tint(fromLbl, C.textGrey)

    local fromDD = createScrollDropdown(panel, 150,
        function() return addon.GetProfileList() end,
        function(v) copyFrom = v end)
    fromDD:SetPoint("LEFT", fromLbl, "RIGHT", 6, 0)

    local toLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    toLbl:SetPoint("LEFT", fromDD, "RIGHT", 14, 0)
    toLbl:SetText("To:")
    UI.tint(toLbl, C.textGrey)

    local toDD = createScrollDropdown(panel, 150,
        function() return addon.GetProfileList() end,
        function(v) copyTo = v end)
    toDD:SetPoint("LEFT", toLbl, "RIGHT", 6, 0)

    local copyErr = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    copyErr:SetPoint("TOPLEFT", fromLbl, "BOTTOMLEFT", 0, -12)
    UI.tint(copyErr, C.red)
    copyErr:SetText("")

    local copyBtn = flatButton(panel, "Copy", 80, 22)
    copyBtn:SetPoint("LEFT", toDD, "RIGHT", 14, 0)
    copyBtn:SetScript("OnClick", function()
        copyErr:SetText("")
        if not (copyFrom and copyTo) then
            copyErr:SetText("Select a profile in both dropdowns.")
            return
        end
        if copyFrom == copyTo then
            copyErr:SetText("Pick two different profiles.")
            return
        end
        -- The picker doubles as the confirmation: it names both profiles and
        -- lists exactly what is about to be overwritten, which a yes/no prompt
        -- can't. Leaving everything ticked is the old whole-profile copy.
        local items = profileSectionItems()
        showCheckListPopup({
            title      = "Copy Profile",
            hint       = string.format('Copy from "%s" into "%s". Ticked modules overwrite "%s"\'s settings.', copyFrom, copyTo, copyTo),
            items      = items,
            emptyText  = "No modules are loaded.",
            actionText = "Copy",
            onAction   = function(keys)
                if #keys == 0 then return nil, "Tick at least one module to copy." end
                local ok, err = addon.CopyProfile(copyFrom, copyTo, selectionOrAll(keys, items))
                if not ok then return nil, err or "Could not copy profile." end
                refreshProfiles()
                return true
            end,
        })
    end)

    -- ── List of existing profiles ─────────────────────────────────────────
    local listHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    listHeader:SetPoint("TOPLEFT", copyErr, "BOTTOMLEFT", 0, -20)
    listHeader:SetText("Existing Profiles")
    UI.tint(listHeader, C.red)

    local listDesc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    listDesc:SetPoint("TOPLEFT", listHeader, "BOTTOMLEFT", 0, -4)
    listDesc:SetWidth(560); listDesc:SetJustifyH("LEFT")
    listDesc:SetText("The one marked active is what this character uses. Export writes a string for the whole profile or just the modules you pick; Import brings modules out of a string into that profile, leaving the rest of it untouched.")
    UI.tint(listDesc, C.textGrey)

    local rows = {}
    local ROW_W, ROW_H = 540, 26

    local function makeRow()
        local row = CreateFrame("Frame", nil, panel, "BackdropTemplate")
        row:SetSize(ROW_W, ROW_H)
        applyBackdrop(row, 1, C.panelDeep, C.tabBorder)

        -- Bounded and left-aligned rather than sized to its text: four buttons
        -- share this row now, and a 32-character profile name would otherwise
        -- push the "(active)" tag straight under them.
        local nameFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameFS:SetPoint("LEFT", 8, 0)
        nameFS:SetWidth(140)
        nameFS:SetJustifyH("LEFT")
        if nameFS.SetWordWrap then nameFS:SetWordWrap(false) end
        UI.tint(nameFS, C.textWhite)
        row.nameFS = nameFS

        local activeFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        activeFS:SetPoint("LEFT", nameFS, "RIGHT", 8, 0)
        activeFS:SetText("(active)")
        UI.tint(activeFS, C.red)
        row.activeFS = activeFS

        local deleteBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
        deleteBtn:SetSize(70, 20)
        deleteBtn:SetPoint("RIGHT", -6, 0)
        applyBackdrop(deleteBtn, 1, C.panelDark, C.tabBorder)
        local deleteLbl = deleteBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        deleteLbl:SetPoint("CENTER"); deleteLbl:SetText("Delete")
        deleteBtn:SetScript("OnEnter", function() if row.canDelete then UI.tintBorder(deleteBtn, C.red) end end)
        deleteBtn:SetScript("OnLeave", function() UI.tintBorder(deleteBtn, C.tabBorder) end)
        row.deleteBtn, row.deleteLbl = deleteBtn, deleteLbl

        local switchBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
        switchBtn:SetSize(90, 20)
        switchBtn:SetPoint("RIGHT", deleteBtn, "LEFT", -6, 0)
        applyBackdrop(switchBtn, 1, C.panelDark, C.tabBorder)
        local switchLbl = switchBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        switchLbl:SetPoint("CENTER"); switchLbl:SetText("Use"); UI.tint(switchLbl, C.textWhite)
        switchBtn:SetScript("OnEnter", function() UI.tintBorder(switchBtn, C.red) end)
        switchBtn:SetScript("OnLeave", function() UI.tintBorder(switchBtn, C.tabBorder) end)
        row.switchBtn = switchBtn

        local exportBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
        exportBtn:SetSize(70, 20)
        exportBtn:SetPoint("RIGHT", switchBtn, "LEFT", -6, 0)
        applyBackdrop(exportBtn, 1, C.panelDark, C.tabBorder)
        local exportLbl = exportBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        exportLbl:SetPoint("CENTER"); exportLbl:SetText("Export"); UI.tint(exportLbl, C.textWhite)
        exportBtn:SetScript("OnEnter", function() UI.tintBorder(exportBtn, C.red) end)
        exportBtn:SetScript("OnLeave", function() UI.tintBorder(exportBtn, C.tabBorder) end)
        row.exportBtn = exportBtn

        -- Per row rather than one button at the top: this import merges INTO an
        -- existing profile, so which one it lands in has to be unambiguous.
        local importRowBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
        importRowBtn:SetSize(70, 20)
        importRowBtn:SetPoint("RIGHT", exportBtn, "LEFT", -6, 0)
        applyBackdrop(importRowBtn, 1, C.panelDark, C.tabBorder)
        local importRowLbl = importRowBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        importRowLbl:SetPoint("CENTER"); importRowLbl:SetText("Import"); UI.tint(importRowLbl, C.textWhite)
        importRowBtn:SetScript("OnEnter", function() UI.tintBorder(importRowBtn, C.red) end)
        importRowBtn:SetScript("OnLeave", function() UI.tintBorder(importRowBtn, C.tabBorder) end)
        row.importBtn = importRowBtn

        return row
    end

    refreshProfiles = function()
        errText:SetText("")
        copyErr:SetText("")
        nameBox:SetText("")
        local list   = addon.GetProfileList and addon.GetProfileList() or {}
        local active = addon.GetActiveProfileName and addon.GetActiveProfileName() or "Default"

        -- Drop any copy selection whose profile no longer exists, and re-sync
        -- the dropdown labels (their lists repopulate live when opened).
        local exists = {}
        for _, n in ipairs(list) do exists[n] = true end
        if copyFrom and not exists[copyFrom] then copyFrom = nil end
        if copyTo   and not exists[copyTo]   then copyTo   = nil end
        fromDD:setValue(copyFrom)
        toDD:setValue(copyTo)

        while #rows < #list do
            rows[#rows + 1] = makeRow()
        end

        local prevRow
        for i, profName in ipairs(list) do
            local row = rows[i]
            row:ClearAllPoints()
            if prevRow then
                row:SetPoint("TOPLEFT", prevRow, "BOTTOMLEFT", 0, -6)
            else
                row:SetPoint("TOPLEFT", listDesc, "BOTTOMLEFT", 0, -10)
            end
            row.nameFS:SetText(profName)

            local isActive = (profName == active)
            row.activeFS:SetShown(isActive)
            row.switchBtn:SetShown(not isActive)
            row.switchBtn:SetScript("OnClick", function() addon.SetActiveProfile(profName) end)
            row.exportBtn:SetScript("OnClick", function() showExportPopup(profName) end)
            row.importBtn:SetScript("OnClick", function()
                showImportIntoPopup(profName, refreshProfiles)
            end)

            row.canDelete = (profName ~= "Default") and not isActive
            row.deleteBtn:SetEnabled(row.canDelete)
            if row.canDelete then
                UI.tint(row.deleteLbl, C.textWhite)
            else
                UI.tint(row.deleteLbl, C.textDim)
            end
            UI.tintBorder(row.deleteBtn, C.tabBorder)
            if row.canDelete then
                row.deleteBtn:SetScript("OnClick", function()
                    showConfirmPopup({
                        title       = "Delete Profile",
                        message     = string.format('Are you sure you want to delete the "%s" profile?', profName),
                        confirmText = "Delete",
                        onConfirm   = function()
                            addon.DeleteProfile(profName)
                            refreshProfiles()
                        end,
                    })
                end)
            else
                row.deleteBtn:SetScript("OnClick", nil)
            end

            row:Show()
            prevRow = row
        end
        for i = #list + 1, #rows do
            rows[i]:Hide()
        end
    end

    createBtn:SetScript("OnClick", function()
        local name, err = addon.CreateProfile(nameBox:GetText())
        if not name then
            errText:SetText(err or "Could not create profile.")
            return
        end
        addon.SetActiveProfile(name)
        refreshProfiles()
    end)
    importBtn:SetScript("OnClick", function()
        showImportPopup(function(importedName)
            addon.SetActiveProfile(importedName)
            refreshProfiles()
        end)
    end)
    nameBox:SetScript("OnEnterPressed", function(self)
        createBtn:GetScript("OnClick")(createBtn)
        self:ClearFocus()
    end)
    nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    shell:SetScript("OnShow", refreshProfiles)
    return shell
end

-- ── Nav tab registry ─────────────────────────────────────────────────────────
-- Every sidebar tab registers here rather than GetFrame hardcoding a list, so a
-- module addon contributes its own via UI.RegisterTab at load time.
--   def = { key, label, order, build = function(parent) -> panel, status = fn }
-- `order` sorts top→down. `status` is optional: with it the nav button gets a
-- green/grey enabled dot.
UI.tabRegistry = {}

-- Names of addon.X tables exposing the movable interface (TTK.lua is the
-- reference shape), included whenever UI.EnterMoveMode() runs with no explicit
-- list. A module calls UI.RegisterMovable("Name") rather than core knowing it.
UI.movableNames = { "TTK", "RaidFrames", "Trinkets", "Tooltip" }

-- Display names for the Modules list in Edit Mode. Keyed by the addon.X name;
-- anything missing falls back to the key itself. A module addon adds its own
-- entry here alongside its UI.RegisterMovable call.
UI.movableLabels = {
    TTK        = "Time to Kill",
    RaidFrames = "Raid Frames",
    Trinkets   = "Trinket Menu",
    Tooltip    = "Tooltip Anchor",
}

-- Runtime-created movables (DataText bars, chat panels) supply their own
-- getLabel, since their names are user-editable and there's no fixed addon.X key.
function UI.MovableLabel(m)
    if type(m.getLabel) == "function" then
        local ok, text = pcall(m.getLabel)
        if ok and text then return text end
    end
    if m.label then return m.label end
    for _, name in ipairs(UI.movableNames) do
        if addon[name] == m then return UI.movableLabels[name] or name end
    end
    return "Element"
end

function UI.RegisterMovable(name)
    if not name then return end
    for _, n in ipairs(UI.movableNames) do
        if n == name then return end -- already registered
    end
    UI.movableNames[#UI.movableNames + 1] = name
end

-- For movables that aren't a fixed addon.X table — things the user creates at
-- runtime. A provider returns a list, and is called fresh every time Edit Mode
-- opens, so new objects are picked up without re-registering.
UI.movableProviders = {}

function UI.RegisterMovableProvider(fn)
    if type(fn) ~= "function" then return end
    UI.movableProviders[#UI.movableProviders + 1] = fn
end

function UI.RegisterTab(def)
    if not (def and def.key and def.build) then return end
    def.order = def.order or 100
    def._seq  = #UI.tabRegistry + 1
    UI.tabRegistry[#UI.tabRegistry + 1] = def
end

local function sortedTabs()
    local list = {}
    for _, def in ipairs(UI.tabRegistry) do list[#list + 1] = def end
    table.sort(list, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a._seq < b._seq
    end)
    return list
end

function UI.GetFrame()
    if UI.frame then return UI.frame end

    local f = createMainFrame()

    -- Vertical sidebar nav, built from whatever tabs registered. Buttons stack
    -- top→down, full sidebar width.
    local defs = sortedTabs()
    local prevNav
    for _, def in ipairs(defs) do
        local tab = createSideTab(f.sidebar, def.label or def.key)
        if prevNav then
            tab:SetPoint("TOPLEFT",  prevNav, "BOTTOMLEFT",  0, -2)
            tab:SetPoint("TOPRIGHT", prevNav, "BOTTOMRIGHT", 0, -2)
        else
            -- Start below the sidebar brand header (title + version).
            tab:SetPoint("TOPLEFT",  f.sidebar, "TOPLEFT",   3, -48)
            tab:SetPoint("TOPRIGHT", f.sidebar, "TOPRIGHT", -3, -48)
        end
        tab:SetScript("OnClick", function() selectTab(f, def.key) end)

        -- Right-aligned status dot. The label gets a matching right bound so a long name
        -- truncates instead of running under it.
        if def.status then
            local dot = tab:CreateTexture(nil, "OVERLAY")
            dot:SetTexture(WHITE)
            dot:SetSize(8, 8)
            dot:SetPoint("RIGHT", -10, 0)
            tab.text:SetPoint("RIGHT", dot, "LEFT", -6, 0)
            tab.text:SetJustifyH("LEFT")
            f.tabDots[def.key] = dot
        end

        f.tabs[def.key] = tab
        prevNav = tab
    end

    -- Deferred: each panel is built by activateTab on first selection, so opening
    -- the window pays only for the tab it lands on.
    for _, def in ipairs(defs) do
        f.panels[def.key] = function() return def.build(f.content) end
    end

    if defs[1] then selectTab(f, defs[1].key) end

    UI.frame = f
    -- Dots reflect saved state, so re-sync every time the window opens (profile
    -- switches, or a toggle flipped from a slash command).
    f:HookScript("OnShow", UI.RefreshTabDots)
    UI.RefreshTabDots()
    return f
end

-- Re-read every registered tab's status() and recolour its sidebar dot. Called
-- on window open, and by the module panels whenever their master toggle flips.
function UI.RefreshTabDots()
    local f = UI.frame
    if not f then return end
    for _, def in ipairs(UI.tabRegistry) do
        local dot = f.tabDots[def.key]
        if dot and def.status then
            local ok, on = pcall(def.status)
            dot:SetVertexColor(unpack((ok and on) and C.statusOn or C.statusOff))
        end
    end
end

-- Core's own tabs. Module addons register theirs from their own files, so they
-- slot into the gaps and disappear when those addons are disabled:
--
--   10 General · 15 Swingtimer · 20 Particles · 30 Raid · 40 Trinkets
--   50 Item Rack · 60 Action Bars · 65 Nameplates · 70 Chat · 90 Profiles
--
-- Spaced out rather than 1..9 so a module can be slipped between two later.
UI.RegisterTab({ key = "general",   label = "General",   order = 10, build = buildGeneralTabPanel })
UI.RegisterTab({ key = "raid",      label = "Raid",      order = 30, build = buildRaidTabPanel,
    -- Raid Frames is the one toggleable module on this tab.
    status = function()
        local d = addon.db and addon.db.settings and addon.db.settings.raidFrames
        return d and d.enabled or false
    end })
UI.RegisterTab({ key = "profiles",  label = "Profiles",  order = 90, build = buildProfilesPanel })

function addon.ToggleUI()
    local f = UI.GetFrame()
    if f:IsShown() then f:Hide() else f:Show() end
end

-- Opened by clicking (not dragging) a movable in edit mode: precise X/Y entry
-- plus a 1-unit nudge pad. Works against any movable exposing
-- getPosition()/setPosition(x, y).
local function getPositionEditor()
    if UI.positionEditor then return UI.positionEditor end

    local panel = CreateFrame("Frame", "DrievPositionEditor", UIParent, "BackdropTemplate")
    panel:SetSize(200, 130)
    panel:SetFrameStrata("TOOLTIP")
    applyBackdrop(panel, 2, C.panelBG, C.red)
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    panel:SetMovable(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
    panel:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
    panel:Hide()

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", panel, "TOP", 0, -8)
    title:SetText("Position")
    UI.tint(title, C.textWhite)

    closeButton(panel, 6)

    local function makeBox(parent)
        local wrap = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        wrap:SetSize(50, 22)
        applyBackdrop(wrap, 1, C.panelDark, C.tabBorder)
        wrap:SetScript("OnEnter", function() UI.tintBorder(wrap, C.red) end)
        wrap:SetScript("OnLeave", function() UI.tintBorder(wrap, C.tabBorder) end)

        local box = CreateFrame("EditBox", nil, wrap)
        box:SetSize(42, 18)
        box:SetPoint("CENTER")
        box:SetAutoFocus(false)
        box:SetJustifyH("CENTER")
        box:SetMaxLetters(7)
        box:SetFontObject("GameFontNormal")
        UI.tint(box, C.textWhite)
        return wrap, box
    end

    local function makeArrow(glyph)
        local btn = CreateFrame("Button", nil, panel, "BackdropTemplate")
        btn:SetSize(20, 20)
        applyBackdrop(btn, 1, C.panelDark, C.tabBorder)
        local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("CENTER")
        lbl:SetText(glyph)
        UI.tint(lbl, C.textWhite)
        btn:SetScript("OnEnter", function() UI.tintBorder(btn, C.red) end)
        btn:SetScript("OnLeave", function() UI.tintBorder(btn, C.tabBorder) end)
        return btn
    end

    -- Invisible reference frame the boxes sit on, so the four arrows anchor to its
    -- edges and end up symmetrical around the whole X/Y pair rather than one box.
    local row = CreateFrame("Frame", nil, panel)
    row:SetSize(140, 22)
    row:SetPoint("TOP", title, "BOTTOM", 0, -34)

    local xLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    xLabel:SetPoint("LEFT", row, "LEFT", 0, 0)
    xLabel:SetText("X:")
    UI.tint(xLabel, C.textWhite)

    local xBoxWrap, xBox = makeBox(panel)
    xBoxWrap:SetPoint("LEFT", xLabel, "RIGHT", 4, 0)

    local yLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    yLabel:SetPoint("LEFT", xBoxWrap, "RIGHT", 12, 0)
    yLabel:SetText("Y:")
    UI.tint(yLabel, C.textWhite)

    local yBoxWrap, yBox = makeBox(panel)
    yBoxWrap:SetPoint("LEFT", yLabel, "RIGHT", 4, 0)

    local leftBtn = makeArrow("<")
    leftBtn:SetPoint("RIGHT", row, "LEFT", -8, 0)
    local rightBtn = makeArrow(">")
    rightBtn:SetPoint("LEFT", row, "RIGHT", 8, 0)
    local upBtn = makeArrow("^")
    upBtn:SetPoint("BOTTOM", row, "TOP", 0, 6)
    local downBtn = makeArrow("v")
    downBtn:SetPoint("TOP", row, "BOTTOM", 0, -6)

    local target

    local function refresh()
        if not target then return end
        local x, y = target.getPosition()
        if not xBox:HasFocus() then xBox:SetText(tostring(math.floor(x + 0.5))) end
        if not yBox:HasFocus() then yBox:SetText(tostring(math.floor(y + 0.5))) end
    end

    local function commit()
        if not target then return end
        local x = tonumber(xBox:GetText())
        local y = tonumber(yBox:GetText())
        if x and y then target.setPosition(x, y) end
        refresh()
    end

    local function nudge(dx, dy)
        if not target then return end
        local x, y = target.getPosition()
        target.setPosition(x + dx, y + dy)
        refresh()
    end

    for _, box in ipairs({ xBox, yBox }) do
        box:SetScript("OnEnterPressed", function(self) commit(); self:ClearFocus() end)
        box:SetScript("OnEditFocusLost", commit)
        box:SetScript("OnEscapePressed", function(self) refresh(); self:ClearFocus() end)
    end

    leftBtn:SetScript("OnClick",  function() nudge(-1, 0) end)
    rightBtn:SetScript("OnClick", function() nudge(1, 0) end)
    upBtn:SetScript("OnClick",    function() nudge(0, 1) end)
    downBtn:SetScript("OnClick",  function() nudge(0, -1) end)

    function panel:SetTarget(movable)
        target = movable
        refresh()
    end

    UI.positionEditor = panel
    return panel
end

function UI.OpenPositionEditor(movable, anchorFrame)
    local editor = getPositionEditor()
    editor:SetTarget(movable)
    editor:ClearAllPoints()
    if anchorFrame then
        editor:SetPoint("BOTTOMLEFT", anchorFrame, "TOPRIGHT", 8, 8)
    else
        editor:SetPoint("CENTER", UIParent, "CENTER", 0, 150)
    end
    editor:Show()
end

-- SetAlpha multiplies on top of each texture's baked-in vertex alpha (0.55 for
-- the dim, 0.07 per grid line), so 100% reproduces the original look and 0%
-- fades everything out uniformly.
function UI.RefreshMoveOverlay()
    local overlay = UI.moveOverlay
    if not overlay then return end
    if not addon.GetMoveBgEnabled() then
        overlay:Hide()
        return
    end
    if UI.activeMovables then overlay:Show() end
    local mult = addon.GetMoveBgOpacity() / 100
    if overlay.bg then overlay.bg:SetAlpha(mult) end
    for _, line in ipairs(overlay.gridLines or {}) do
        line:SetAlpha(mult)
    end
end

-- Pushes "Allow dragging off screen" onto every element in Edit Mode. Frames are
-- sized by their own modules, so insets are re-derived on every entry.
--
-- Deliberately not reverted on exit: an element left mostly off screen keeps its
-- insets, so nothing yanks it back when the client next re-clamps.
function UI.RefreshMovableClamps()
    local allowed = addon.GetEditOffscreen()
    for _, m in ipairs(UI.activeMovables or {}) do
        local f = m.getFrame and m.getFrame()
        -- Only elements that clamp themselves have anything to relax. One that was never
        -- clamped can already be dragged anywhere, and clamping it here to then loosen
        -- it would leave it MORE restricted than it is today.
        if f and f.IsClampedToScreen and f:IsClampedToScreen() then
            addon.ApplyOffscreenClamp(f, allowed)
        end
    end
end

function UI.EnterMoveMode(movables)
    if not movables then
        -- Collect by name rather than building { addon.TTK, ... } directly: a module can
        -- be disabled, and a nil inside a table constructor silently truncates it for
        -- ipairs. A movable can also opt out via isEnabled().
        movables = {}
        for _, name in ipairs(UI.movableNames) do
            local m = addon[name]
            if m and (type(m.isEnabled) ~= "function" or m.isEnabled()) then
                movables[#movables + 1] = m
            end
        end
        -- Runtime-created movables (DataText bars, chat docks) — see
        -- UI.RegisterMovableProvider.
        for _, provider in ipairs(UI.movableProviders) do
            local ok, list = pcall(provider)
            if ok and type(list) == "table" then
                for _, m in ipairs(list) do
                    if m and m.getFrame then movables[#movables + 1] = m end
                end
            end
        end
    end
    UI.activeMovables = movables

    if UI.frame then UI.frame:Hide() end

    -- Each movable's enterMoveMode() wires up its own OnMouseDown/OnMouseUp, so this
    -- loop just shows the frame and hands off. Parked state is persisted per label
    -- via addon.SetEditParked.
    for _, m in ipairs(movables) do
        local parked = addon.IsEditParked(UI.MovableLabel(m))
        m.__editEnabled = not parked
        local f = m.getFrame()
        if f then f:Show() end
        if parked then
            m.leaveMoveMode()
        else
            m.enterMoveMode()
        end
    end

    if not UI.moveOverlay then
        local overlay = CreateFrame("Frame", "DrievMoveOverlay", UIParent)
        overlay:SetAllPoints(UIParent)
        overlay:SetFrameStrata("DIALOG")
        -- Click-through: the grid is purely visual, so the mouse stays disabled and
        -- camera rotation still works while editing. The draggable boxes and lock bar
        -- sit on top with their own handling.
        overlay:EnableMouse(false)

        local bg = overlay:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(WHITE)
        bg:SetVertexColor(0, 0, 0, 0.55)
        overlay.bg = bg

        local W    = UIParent:GetWidth()
        local H    = UIParent:GetHeight()
        local step = 50
        overlay.gridLines = {}
        for i = 0, math.ceil(W / step) do
            local line = overlay:CreateTexture(nil, "ARTWORK")
            line:SetTexture(WHITE)
            line:SetVertexColor(1, 1, 1, 0.07)
            line:SetPoint("TOPLEFT", overlay, "TOPLEFT", i * step, 0)
            line:SetSize(1, H)
            table.insert(overlay.gridLines, line)
        end
        for i = 0, math.ceil(H / step) do
            local line = overlay:CreateTexture(nil, "ARTWORK")
            line:SetTexture(WHITE)
            line:SetVertexColor(1, 1, 1, 0.07)
            line:SetPoint("TOPLEFT", overlay, "TOPLEFT", 0, -(i * step))
            line:SetSize(W, 1)
            table.insert(overlay.gridLines, line)
        end

        UI.moveOverlay = overlay
    end
    UI.RefreshMoveOverlay()

    if not UI.lockBar then
        local bar = CreateFrame("Frame", "DrievLockBar", UIParent, "BackdropTemplate")
        bar:SetSize(280, 400)
        bar:SetFrameStrata("TOOLTIP")
        applyBackdrop(bar, 2, C.panelBG, C.red)

        -- Draggable, and it remembers where it was left: with the grid covering the
        -- screen this box can easily sit on top of what you're trying to position.
        bar:SetClampedToScreen(true)
        bar:EnableMouse(true)
        bar:SetMovable(true)
        bar:RegisterForDrag("LeftButton")
        bar:SetScript("OnDragStart", function(self) self:StartMoving() end)
        bar:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            if addon.db and addon.db.settings then
                addon.db.settings.editBarX = self:GetLeft()
                addon.db.settings.editBarY = self:GetBottom()
            end
        end)

        local hint = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hint:SetPoint("TOP", bar, "TOP", 0, -7)
        hint:SetText("Drag this box to move it")
        UI.tint(hint, C.textGrey)

        -- Tabs
        bar.tabs, bar.panels = {}, {}

        local settingsTab = createTab(bar, "Settings", 122)
        settingsTab:SetHeight(20)
        settingsTab:SetPoint("TOPLEFT", bar, "TOPLEFT", 8, -24)

        local modulesTab = createTab(bar, "Modules", 122)
        modulesTab:SetHeight(20)
        modulesTab:SetPoint("LEFT", settingsTab, "RIGHT", 4, 0)

        local function makeBarPanel()
            local p = CreateFrame("Frame", nil, bar)
            p:SetPoint("TOPLEFT", settingsTab, "BOTTOMLEFT", 0, -10)
            p:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -8, 42)
            p:Hide()
            return p
        end

        local settingsPanel = makeBarPanel()

        -- The Modules list grows with however many movables exist (14 action bars
        -- alone), easily taller than the fixed lock bar, so it scrolls — unlike the
        -- Settings tab's fixed set of sliders.
        local modulesHost = makeBarPanel()
        modulesHost:Show()
        local modulesShell, modulesPanel, refreshModulesScroll = makeScrollPanel(modulesHost)

        bar.tabs.settings   = settingsTab
        bar.tabs.modules    = modulesTab
        bar.panels.settings = settingsPanel
        bar.panels.modules  = modulesShell

        settingsTab:SetScript("OnClick", function() activateTab(bar.tabs, bar.panels, "settings") end)
        modulesTab:SetScript("OnClick",  function() activateTab(bar.tabs, bar.panels, "modules")  end)

        -- Settings tab
        local boxHeader = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        boxHeader:SetPoint("TOP", settingsPanel, "TOP", 0, -2)
        boxHeader:SetText("Edit Box")
        UI.tint(boxHeader, C.red)

        local opacity = buildEditSlider(settingsPanel, {
            label = "Opacity", min = 0, max = 100, suffix = "%",
            get = function() return math.floor(addon.GetEditAlpha() * 100 + 0.5) end,
            set = function(v) addon.SetEditAlpha(v / 100) end,
        })
        opacity:SetPoint("TOP", boxHeader, "BOTTOM", 0, -8)

        local padding = buildEditSlider(settingsPanel, {
            label = "Padding", min = 0, max = 40, suffix = "px",
            get = function() return addon.GetEditPad() end,
            set = function(v) addon.SetEditPad(v) end,
        })
        padding:SetPoint("TOP", opacity, "BOTTOM", 0, -6)

        local border = buildEditSlider(settingsPanel, {
            label = "Border", min = 1, max = 10, suffix = "px",
            get = function() return addon.GetEditBorder() end,
            set = function(v) addon.SetEditBorder(v) end,
        })
        border:SetPoint("TOP", padding, "BOTTOM", 0, -6)

        UI.editSliders = { opacity, padding, border }

        local bgHeader = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        bgHeader:SetPoint("TOP", border, "BOTTOM", 0, -16)
        bgHeader:SetText("Background")
        UI.tint(bgHeader, C.red)

        local bgOpacity = buildEditSlider(settingsPanel, {
            label = "Opacity", min = 0, max = 100, suffix = "%",
            get = function() return addon.GetMoveBgOpacity() end,
            set = function(v) addon.SetMoveBgOpacity(v) end,
        })
        bgOpacity:SetPoint("TOP", bgHeader, "BOTTOM", 0, -8)
        UI.bgOpacitySlider = bgOpacity

        local bgToggleBtn = CreateFrame("Button", nil, settingsPanel, "BackdropTemplate")
        bgToggleBtn:SetSize(200, 22)
        bgToggleBtn:SetPoint("TOP", bgOpacity, "BOTTOM", 0, -10)
        applyBackdrop(bgToggleBtn, 1, C.panelDark, C.tabBorder)
        local bgToggleLabel = bgToggleBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        bgToggleLabel:SetPoint("CENTER")
        bgToggleBtn:SetScript("OnEnter", function() UI.tintBorder(bgToggleBtn, C.red) end)
        bgToggleBtn:SetScript("OnLeave", function() UI.tintBorder(bgToggleBtn, C.tabBorder) end)
        local function refreshBgToggle()
            local on = addon.GetMoveBgEnabled()
            bgToggleLabel:SetText(on and "Grid & Background: ON" or "Grid & Background: OFF")
            bgToggleLabel:SetTextColor(unpack(on and C.textWhite or C.textGrey))
        end
        bgToggleBtn:SetScript("OnClick", function()
            addon.SetMoveBgEnabled(not addon.GetMoveBgEnabled())
            refreshBgToggle()
        end)
        UI.refreshBgToggle = refreshBgToggle

        local moveHeader = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        moveHeader:SetPoint("TOP", bgToggleBtn, "BOTTOM", 0, -16)
        moveHeader:SetText("Movement")
        UI.tint(moveHeader, C.red)

        local offscreenCb = createCheckbox(settingsPanel, "Allow dragging off screen", 220)
        offscreenCb:SetPoint("TOP", moveHeader, "BOTTOM", 0, -8)
        offscreenCb.OnChange = function(_, checked) addon.SetEditOffscreen(checked) end
        UI.offscreenCheckbox = offscreenCb

        -- Modules tab
        local modHint = modulesPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        modHint:SetPoint("TOPLEFT", modulesPanel, "TOPLEFT", 4, -2)
        modHint:SetWidth(250); modHint:SetJustifyH("LEFT")
        modHint:SetText("Untick an element to park it, so you can reach whatever sits underneath it.")
        UI.tint(modHint, C.textGrey)

        local modRows = {}

        -- Rebuilt on every entry to Edit Mode: which elements exist changes with
        -- what the user has created and which module addons are enabled.
        local function refreshModuleList()
            local list = UI.activeMovables or {}

            while #modRows < #list do
                modRows[#modRows + 1] = createCheckbox(modulesPanel, "", 220)
            end

            for i, m in ipairs(list) do
                local cb = modRows[i]
                cb:ClearAllPoints()
                cb:SetPoint("TOPLEFT", modHint, "BOTTOMLEFT", 0, -8 - (i - 1) * 22)
                cb.text:SetText(UI.MovableLabel(m))
                cb:SetChecked(m.__editEnabled ~= false)
                cb.OnChange = function(_, checked)
                    m.__editEnabled = checked
                    -- Persisted so a parked element stays parked next time
                    -- Edit Mode opens instead of resetting to movable.
                    addon.SetEditParked(UI.MovableLabel(m), not checked)
                    if checked then
                        local f = m.getFrame()
                        if f then f:Show() end
                        m.enterMoveMode()
                    else
                        -- leaveMoveMode clears the element's mouse handlers and hides its edit box,
                        -- which is what stops it intercepting clicks meant for what's beneath.
                        m.leaveMoveMode()
                    end
                end
                cb:Show()
            end
            for i = #list + 1, #modRows do modRows[i]:Hide() end
            if refreshModulesScroll then refreshModulesScroll() end
        end
        UI.RefreshModuleList = refreshModuleList

        -- Lock
        local lockBtn = CreateFrame("Button", nil, bar, "BackdropTemplate")
        lockBtn:SetSize(120, 22)
        lockBtn:SetPoint("BOTTOM", bar, "BOTTOM", 0, 10)
        applyBackdrop(lockBtn, 1, C.panelDark, C.tabBorder)
        local lockLabel = lockBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lockLabel:SetPoint("CENTER")
        lockLabel:SetText("Lock")
        UI.tint(lockLabel, C.red)
        lockBtn:SetScript("OnEnter", function() UI.tint(lockLabel, C.textWhite) end)
        lockBtn:SetScript("OnLeave", function() UI.tint(lockLabel, C.red) end)
        lockBtn:SetScript("OnClick", function() UI.ExitMoveMode() end)

        activateTab(bar.tabs, bar.panels, "settings")
        UI.lockBar = bar
    end

    -- Applied on every entry rather than at creation: the saved coordinates live in
    -- addon.db, which may not have loaded when the frame was first built.
    UI.lockBar:ClearAllPoints()
    local bx = addon.db and addon.db.settings and addon.db.settings.editBarX
    local by = addon.db and addon.db.settings and addon.db.settings.editBarY
    if bx and by then
        UI.lockBar:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", bx, by)
    else
        UI.lockBar:SetPoint("TOP", UIParent, "TOP", 0, -8)
    end
    if UI.editSliders then
        for _, s in ipairs(UI.editSliders) do s:Refresh() end
    end
    if UI.bgOpacitySlider then UI.bgOpacitySlider:Refresh() end
    if UI.refreshBgToggle then UI.refreshBgToggle() end
    if UI.offscreenCheckbox then UI.offscreenCheckbox:SetChecked(addon.GetEditOffscreen()) end
    UI.RefreshMovableClamps()
    if UI.RefreshModuleList then UI.RefreshModuleList() end
    UI.lockBar:Show()
end

function UI.ExitMoveMode()
    for _, m in ipairs(UI.activeMovables or {}) do
        -- m.leaveMoveMode() below clears its own OnMouseDown/OnMouseUp.
        m.savePosition()
        m.leaveMoveMode()
        if m.applyVisibility then m.applyVisibility() end
    end
    UI.activeMovables = nil

    if UI.moveOverlay then UI.moveOverlay:Hide() end
    if UI.lockBar then UI.lockBar:Hide() end
    if UI.positionEditor then UI.positionEditor:Hide() end

    UI.GetFrame():Show()
end

-- ── Shared widget toolkit ────────────────────────────────────────────────────
-- Everything above is file-local, invisible to a separate addon. A module addon
-- builds its tab with these so its panels look identical to core's:
--     local UI = _G.DrievEssentials.UI
--     local w, C = UI.widgets, UI.colors
-- Declared at the very end so every helper it references is defined.
--
-- Paint with UI.tint / tintBg / tintBorder / tintTexture rather than
-- SetTextColor(unpack(C.x)): same result, but it records the palette entry so
-- the colour picker can repaint later.
UI.colors  = C
UI.WHITE   = WHITE
UI.widgets = {
    -- backdrops / buttons
    applyBackdrop       = applyBackdrop,
    attachTooltip       = attachTooltip,
    flatButton          = flatButton,
    createTab           = createTab,
    createSideTab       = createSideTab,
    -- tab/panel switching
    activateTab         = activateTab,
    selectTab           = selectTab,
    selectSubTab        = selectSubTab,
    makeSubTabPanel     = makeSubTabPanel,
    -- scrolling
    attachScrollTrack   = attachScrollTrack,
    fitInnerHeight      = fitInnerHeight,
    makeScrollPanel     = makeScrollPanel,
    scrollbarWidth      = SCROLLBAR_W,
    -- inputs
    createCheckbox      = createCheckbox,
    createColorSwatch   = createColorSwatch,
    createDropdown      = createDropdown,
    createScrollDropdown= createScrollDropdown,
    buildStepper        = buildStepper,
    buildEditSlider     = buildEditSlider,
    buildSizeStepper    = buildSizeStepper,
    buildFontOptions    = buildFontOptions,
    -- dialogs
    showConfirmPopup    = showConfirmPopup,
    showTextPopup       = showTextPopup,
    showCheckListPopup  = showCheckListPopup,
}
