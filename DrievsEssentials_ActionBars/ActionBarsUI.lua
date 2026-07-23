-- Driev's Essentials — Action Bars module: settings UI.
--
-- Layout: a left sidebar lists Action Bar 1-10; the selected bar's panel has its
-- own top tab bar — General / Visibility / Position — each holding the relevant
-- knobs. A global Keybind Mode toggle sits in the header above the sidebar.
-- Built entirely on core's shared widget toolkit.
local addon = _G.DrievEssentials
if not addon then return end

local UI = addon.UI
local C  = UI.colors
local W  = UI.widgets

local applyBackdrop       = W.applyBackdrop
local createCheckbox      = W.createCheckbox
local createDropdown      = W.createDropdown
local createScrollDropdown= W.createScrollDropdown
local createTab           = W.createTab
local createSideTab       = W.createSideTab
local activateTab         = W.activateTab
local buildStepper        = W.buildStepper
local flatButton          = W.flatButton
local makeScrollPanel     = W.makeScrollPanel

local AB = function() return addon.ActionBars end

-- Re-apply everything for one bar after a settings change. applyBar is combat-
-- guarded internally, so callers never have to check.
local function apply(key)
    if AB() then AB().applyBar(key) end
end

-- ── Form helper ──────────────────────────────────────────────────────────────
-- Stacks controls top-to-bottom on a panel and tracks a list of refreshers so
-- the panel can re-read stored values on show. Each adder anchors under the
-- previous control automatically.
local function makeForm(panel)
    local prev
    local refreshers = {}

    local function place(w)
        if prev then
            w:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -14)
        else
            w:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, -14)
        end
    end

    local F = { refreshers = refreshers }

    function F.check(text, getf, setf)
        local cb = createCheckbox(panel, text, 240)
        place(cb)
        cb.OnChange = function(_, checked) setf(checked) end
        refreshers[#refreshers + 1] = function() cb:SetChecked(getf()) end
        prev = cb
        return cb
    end

    function F.stepper(text, opts)
        local lbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        place(lbl)
        lbl:SetText(text); lbl:SetTextColor(unpack(C.textWhite))
        lbl:SetWidth(120); lbl:SetJustifyH("LEFT")
        local st = buildStepper(panel, opts)
        st:SetPoint("LEFT", lbl, "RIGHT", 6, 0)
        refreshers[#refreshers + 1] = function() st.Refresh() end
        prev = lbl
        return st, lbl   -- lbl returned so callers can relabel it (e.g. Rows↔Columns)
    end

    -- A blank full-width row placed in the stacking flow; builder(rowFrame) fills
    -- it with custom widgets. Used for the horizontal/vertical build toggle.
    function F.customRow(height, builder)
        local r = CreateFrame("Frame", nil, panel)
        r:SetHeight(height or 22)
        place(r)
        r:SetPoint("RIGHT", panel, "RIGHT", -14, 0)
        prev = r
        if builder then builder(r) end
        return r
    end

    -- Like F.stepper, but the value is an editable number box (type a value and
    -- press Enter) with [-]/[+] adjusting by opts.step. opts.suffix (e.g. "%") is
    -- drawn as a static label after the box. get() returns / set(v) takes a
    -- plain number, clamped to [opts.min, opts.max].
    function F.editStepper(text, opts)
        local step = opts.step or 1
        local minv, maxv = opts.min or 0, opts.max or 100

        local lbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        place(lbl)
        lbl:SetText(text); lbl:SetTextColor(unpack(C.textWhite))
        lbl:SetWidth(120); lbl:SetJustifyH("LEFT")

        local minus = CreateFrame("Button", nil, panel, "BackdropTemplate")
        minus:SetSize(22, 22); minus:SetPoint("LEFT", lbl, "RIGHT", 6, 0)
        applyBackdrop(minus, 1, C.panelDark, C.tabBorder)
        local ml = minus:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        ml:SetPoint("CENTER"); ml:SetText("-"); ml:SetTextColor(unpack(C.textWhite))

        local wrap = CreateFrame("Frame", nil, panel, "BackdropTemplate")
        wrap:SetSize(46, 22); wrap:SetPoint("LEFT", minus, "RIGHT", 6, 0)
        applyBackdrop(wrap, 1, C.panelDark, C.tabBorder)
        local box = CreateFrame("EditBox", nil, wrap)
        box:SetSize(38, 18); box:SetPoint("CENTER")
        box:SetAutoFocus(false); box:SetNumeric(true); box:SetMaxLetters(4)
        box:SetJustifyH("CENTER"); box:SetFontObject("GameFontNormal")
        box:SetTextColor(unpack(C.textWhite))

        local suffix = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        suffix:SetPoint("LEFT", wrap, "RIGHT", 3, 0)
        suffix:SetText(opts.suffix or ""); suffix:SetTextColor(unpack(C.textGrey))

        local plus = CreateFrame("Button", nil, panel, "BackdropTemplate")
        plus:SetSize(22, 22); plus:SetPoint("LEFT", suffix, "RIGHT", 6, 0)
        applyBackdrop(plus, 1, C.panelDark, C.tabBorder)
        local pl = plus:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        pl:SetPoint("CENTER"); pl:SetText("+"); pl:SetTextColor(unpack(C.textWhite))

        local function display()
            if not box:HasFocus() then box:SetText(tostring(opts.get())) end
        end
        local function commit(v)
            v = math.max(minv, math.min(maxv, math.floor(v + 0.5)))
            opts.set(v)
            display()
            if opts.onChange then opts.onChange(v) end
        end
        local function commitBox(self)
            local n = tonumber(self:GetText())
            if n then commit(n) else display() end
        end

        minus:SetScript("OnClick", function() commit(opts.get() - step) end)
        plus:SetScript("OnClick",  function() commit(opts.get() + step) end)
        minus:SetScript("OnEnter", function() minus:SetBackdropBorderColor(unpack(C.red)) end)
        minus:SetScript("OnLeave", function() minus:SetBackdropBorderColor(unpack(C.tabBorder)) end)
        plus:SetScript("OnEnter",  function() plus:SetBackdropBorderColor(unpack(C.red)) end)
        plus:SetScript("OnLeave",  function() plus:SetBackdropBorderColor(unpack(C.tabBorder)) end)
        box:SetScript("OnEnterPressed",    function(self) commitBox(self); self:ClearFocus() end)
        box:SetScript("OnEditFocusLost",   function(self) commitBox(self); wrap:SetBackdropBorderColor(unpack(C.tabBorder)) end)
        box:SetScript("OnEditFocusGained", function() wrap:SetBackdropBorderColor(unpack(C.red)) end)
        box:SetScript("OnEscapePressed",   function(self) display(); self:ClearFocus() end)

        refreshers[#refreshers + 1] = display
        prev = lbl
        display()
        return box
    end

    function F.dropdown(text, options, getf, setf, onChange)
        local lbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        place(lbl)
        lbl:SetText(text); lbl:SetTextColor(unpack(C.textWhite))
        lbl:SetWidth(120); lbl:SetJustifyH("LEFT")
        local dd = createDropdown(panel, 130, options, getf, setf, onChange)
        dd:SetPoint("LEFT", lbl, "RIGHT", 6, 0)
        refreshers[#refreshers + 1] = function() dd.Refresh() end
        prev = lbl
        return dd
    end

    function F.button(text, width, onClick)
        local b = flatButton(panel, text, width or 100, 22)
        place(b)
        b:SetScript("OnClick", onClick)
        prev = b
        return b
    end

    function F.text(str, color)
        local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        place(fs)
        fs:SetWidth(320); fs:SetJustifyH("LEFT")
        fs:SetText(str)
        fs:SetTextColor(unpack(color or C.textGrey))
        prev = fs
        return fs
    end

    function F.refresh()
        for _, r in ipairs(refreshers) do r() end
    end

    return F
end

-- Attaches the form's refresh to the scroll shell's OnShow so values are current
-- every time the panel is displayed.
local function onShowRefresh(shell, form)
    shell:SetScript("OnShow", form.refresh)
end

-- ── General tab: layout / appearance knobs ───────────────────────────────────
-- Action bars get the full knob set; the special bars (stance/micro/bag) drop
-- the ones that don't apply — button count is fixed or dynamic, and icon size /
-- flyout direction are action-button-only.
local function buildGeneralPanel(parent, def)
    local shell, panel = makeScrollPanel(parent)
    local key = def.key
    local isAction = (def.kind == "action")
    local function data() return AB().getData(key) end
    local F = makeForm(panel)

    F.check("Enabled", function() return data().enabled ~= false end, function(c)
        data().enabled = c
        if AB() then AB().applyVisibility(key) end
    end)

    if isAction then
        F.stepper("Buttons", {
            min = 1, max = 12,
            get = function() return data().buttons or 12 end,
            set = function(v) data().buttons = v end,
            onChange = function() apply(key) end,
        })
    end

    -- Build orientation. Horizontal fills left→right then wraps into rows;
    -- vertical fills top→bottom then wraps into columns. The two buttons toggle
    -- it directly, and the count stepper below relabels Rows↔Columns to match.
    local hBtn, vBtn, rowsLabel
    local function refreshOrientation()
        local vert = (data().orientation == "VERTICAL")
        hBtn.label:SetTextColor(unpack(vert and C.textWhite or C.red))
        vBtn.label:SetTextColor(unpack(vert and C.red or C.textWhite))
        if rowsLabel then rowsLabel:SetText(vert and "Columns" or "Rows") end
    end
    local function setOrientation(o)
        data().orientation = o
        refreshOrientation()
        if AB() then AB().applyBar(key) end
    end
    F.customRow(22, function(r)
        local lbl = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("LEFT", 0, 0)
        lbl:SetWidth(48); lbl:SetJustifyH("LEFT")
        lbl:SetText("Build:"); lbl:SetTextColor(unpack(C.textWhite))

        hBtn = flatButton(r, "Horizontal", 84, 20)
        hBtn:SetPoint("LEFT", lbl, "RIGHT", 6, 0)
        hBtn:SetScript("OnClick", function() setOrientation("HORIZONTAL") end)

        vBtn = flatButton(r, "Vertical", 84, 20)
        vBtn:SetPoint("LEFT", hBtn, "RIGHT", 6, 0)
        vBtn:SetScript("OnClick", function() setOrientation("VERTICAL") end)
    end)

    local _, rlbl = F.stepper("Rows", {
        min = 1, max = 12,
        get = function() return data().rows or 1 end,
        set = function(v) data().rows = v end,
        onChange = function() apply(key) end,
    })
    rowsLabel = rlbl

    if isAction then
        F.stepper("Icon Size", {
            min = 20, max = 64,
            get = function() return data().buttonSize or 36 end,
            set = function(v) data().buttonSize = v end,
            onChange = function() apply(key) end,
        })
    end
    F.stepper("Padding", {
        min = 0, max = 20,
        get = function() return data().padding or 4 end,
        set = function(v) data().padding = v end,
        onChange = function() apply(key) end,
    })
    F.editStepper("Scale", {
        min = 50, max = 200, step = 1, suffix = "%",
        get = function() return math.floor((data().scale or 1) * 100 + 0.5) end,
        set = function(v) data().scale = v / 100 end,
        onChange = function() if AB() then AB().applyScale(key) end end,
    })

    -- Grow direction (moved here from the Position tab), just above Flyout.
    F.dropdown("Grow Horizontal",
        { { value = "RIGHT", label = "Right" }, { value = "LEFT", label = "Left" } },
        function() return data().growthH end,
        function(v) data().growthH = v end,
        function() apply(key) end)
    F.dropdown("Grow Vertical",
        { { value = "DOWN", label = "Down" }, { value = "UP", label = "Up" } },
        function() return data().growthV end,
        function(v) data().growthV = v end,
        function() apply(key) end)

    if isAction then
        F.dropdown("Flyout Direction",
            { { value = "UP", label = "Up" }, { value = "DOWN", label = "Down" },
              { value = "LEFT", label = "Left" }, { value = "RIGHT", label = "Right" } },
            function() return data().flyout end,
            function(v) data().flyout = v end,
            function() if AB() then AB().applyButtonCfg(key) end end)

        -- Opt this bar into the keybind-text styling configured on the General tab.
        F.check("Use General settings (keybind text)",
            function() return data().useGeneral ~= false end,
            function(c)
                data().useGeneral = c
                if AB() then AB().applyButtonCfg(key) end
            end)
    end

    refreshOrientation()   -- initial button highlight + Rows/Columns label
    shell:SetScript("OnShow", function()
        F.refresh()
        refreshOrientation()
    end)
    return shell
end

-- ── Visibility tab: alpha / click-through ────────────────────────────────────
local function buildVisibilityPanel(parent, def)
    local shell, panel = makeScrollPanel(parent)
    local key = def.key
    local function data() return AB().getData(key) end
    local F = makeForm(panel)

    F.check("Enabled", function() return data().enabled ~= false end, function(c)
        data().enabled = c
        if AB() then AB().applyVisibility(key) end
    end)

    F.stepper("Alpha", {
        min = 0, max = 100, step = 5, format = function(v) return v .. "%" end, valueWidth = 40,
        get = function() return math.floor((data().alpha or 1) * 100 + 0.5) end,
        set = function(v) data().alpha = v / 100 end,
        onChange = function() if AB() then AB().applyAlpha(key) end end,
    })

    F.check("Click-through (ignore mouse)",
        function() return data().clickThrough and true or false end,
        function(c)
            data().clickThrough = c
            if AB() then AB().applyClickThru(key) end
        end)

    F.check("Show on mouseover only",
        function() return data().mouseover and true or false end,
        function(c)
            data().mouseover = c
            if AB() then AB().applyMouseover(key) end
        end)

    F.check("Smooth fade on mouseover",
        function() return data().mouseoverFade and true or false end,
        function(c)
            data().mouseoverFade = c
            if AB() then AB().applyMouseover(key) end
        end)

    onShowRefresh(shell, F)
    return shell
end

-- ── Position tab: move / growth / X-Y ────────────────────────────────────────
local function buildPositionPanel(parent, def)
    local shell, panel = makeScrollPanel(parent)
    local key = def.key
    local function data() return AB().getData(key) end
    local F = makeForm(panel)

    F.button("Move / Drag", 120, function()
        local m = AB() and AB().getMover(key)
        if m then UI.EnterMoveMode({ m }) end
    end)

    F.stepper("X", {
        min = -2000, max = 4000, step = 5, valueWidth = 52,
        get = function() return math.floor((data().px or 0) + 0.5) end,
        set = function(v) data().px = v end,
        onChange = function() if AB() then AB().applyPosition(key) end end,
    })
    F.stepper("Y", {
        min = -2000, max = 4000, step = 5, valueWidth = 52,
        get = function() return math.floor((data().py or 0) + 0.5) end,
        set = function(v) data().py = v end,
        onChange = function() if AB() then AB().applyPosition(key) end end,
    })

    onShowRefresh(shell, F)
    return shell
end

-- ── Paging tab (action bars only): per-stance action-page switching ──────────
-- Warriors are hardcoded to their three stances (so all three show even before
-- Defensive/Berserker are learned, matching how the player thinks about them);
-- other stance/form classes are read live from the shapeshift API.
local function getStanceList()
    local _, class = UnitClass("player")
    if class == "WARRIOR" then
        return {
            { index = 1, name = "Battle Stance" },
            { index = 2, name = "Defensive Stance" },
            { index = 3, name = "Berserker Stance" },
        }
    end
    local list = {}
    for i = 1, (GetNumShapeshiftForms() or 0) do
        local _, _, _, spellID = GetShapeshiftFormInfo(i)
        local name = (spellID and GetSpellInfo(spellID)) or ("Form " .. i)
        list[#list + 1] = { index = i, name = name }
    end
    return list
end

local function buildPagingPanel(parent, def)
    local shell, panel = makeScrollPanel(parent)
    local key = def.key
    local function data()
        local d = AB().getData(key)
        d.paging = d.paging or {}
        return d
    end
    local F = makeForm(panel)

    F.text("Switch this bar to a different action page while in a stance. " ..
           "\"No Paging\" keeps this bar's own abilities and macros.")

    local stances = getStanceList()
    if #stances == 0 then
        F.text("This character has no stances or forms.", C.textDim)
        onShowRefresh(shell, F)
        return shell
    end

    local pageOptions = { { value = false, label = "No Paging" } }
    for p = 1, 10 do pageOptions[#pageOptions + 1] = { value = p, label = "Page " .. p } end

    for _, st in ipairs(stances) do
        F.dropdown(st.name, pageOptions,
            function() return data().paging[st.index] or false end,
            function(v) data().paging[st.index] = v or nil end,   -- false → nil (removes)
            function() if AB() then AB().applyPaging(key) end end)
    end

    onShowRefresh(shell, F)
    return shell
end

-- ── One bar's panel (General / Visibility / Position [/ Paging] top tabs) ─────
local function buildBarPanel(parent, def)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints()
    frame:Hide()

    local tabBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    tabBar:SetHeight(24)
    tabBar:SetPoint("TOPLEFT", 2, -2)
    tabBar:SetPoint("TOPRIGHT", -2, -2)
    applyBackdrop(tabBar, 1, C.panelDark)

    local subContent = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    subContent:SetPoint("TOPLEFT", tabBar, "BOTTOMLEFT", 0, -2)
    subContent:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
    applyBackdrop(subContent, 1, C.panelDeep)

    local tabs, panels = {}, {}
    local function select(key) activateTab(tabs, panels, key) end

    local defs = {
        { key = "general",    label = "General",    build = buildGeneralPanel },
        { key = "visibility", label = "Visibility", build = buildVisibilityPanel },
        { key = "position",   label = "Position",   build = buildPositionPanel },
    }
    -- Paging (per-stance action-page switching) only makes sense for action bars.
    if def.kind == "action" then
        defs[#defs + 1] = { key = "paging", label = "Paging", build = buildPagingPanel }
    end
    local prevTab
    for _, t in ipairs(defs) do
        local tab = createTab(tabBar, t.label, 80)
        tab:SetHeight(20)
        if prevTab then
            tab:SetPoint("LEFT", prevTab, "RIGHT", 4, 0)
        else
            tab:SetPoint("LEFT", 4, 0)
        end
        tab:SetScript("OnClick", function() select(t.key) end)
        tabs[t.key]   = tab
        panels[t.key] = t.build(subContent, def)
        prevTab = tab
    end

    select("general")
    return frame
end

-- LSM font list with a leading "Default" (= game default hotkey font).
local function getFontList()
    local list = { "Default" }
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    if LSM then
        for _, name in ipairs(LSM:List("font")) do list[#list + 1] = name end
    end
    return list
end

-- ── Top-level "General" tab: addon-wide keybind-text settings ────────────────
-- These apply to any action bar whose per-bar "Use General settings" box is on.
local function buildGlobalPanel(parent)
    local shell, panel = makeScrollPanel(parent)
    local function g(k)      return AB() and AB().getGeneral(k) end
    local function setg(k, v) if AB() then AB().setGeneral(k, v) end end
    local F = makeForm(panel)

    F.text("Keybind (hotkey) text styling. Turn it on per bar with each bar's " ..
           "\"Use General settings\" checkbox (in that bar's General tab).")

    -- Font — scrolling dropdown, since the LibSharedMedia list can be long.
    local fontDD
    F.customRow(24, function(r)
        local lbl = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("LEFT", 0, 0); lbl:SetWidth(90); lbl:SetJustifyH("LEFT")
        lbl:SetText("Font"); lbl:SetTextColor(unpack(C.textWhite))
        fontDD = createScrollDropdown(r, 150, getFontList, function(name)
            setg("keybindFont", name ~= "Default" and name or nil)
        end)
        fontDD:SetPoint("LEFT", lbl, "RIGHT", 6, 0)
    end)

    F.editStepper("Font size", {
        min = 6, max = 30, step = 1,
        get = function() return g("keybindFontSize") or 13 end,
        set = function(v) setg("keybindFontSize", v) end,
    })
    -- X/Y are offsets from the button's top-right corner and can be negative, so
    -- they use the click stepper (the edit box is numeric-only / no minus sign).
    F.stepper("Text X offset", {
        min = -40, max = 40,
        get = function() return g("keybindOffsetX") or -2 end,
        set = function(v) setg("keybindOffsetX", v) end,
    })
    F.stepper("Text Y offset", {
        min = -40, max = 40,
        get = function() return g("keybindOffsetY") or -4 end,
        set = function(v) setg("keybindOffsetY", v) end,
    })
    F.check("Out of range: tint keybind text only",
        function() return g("outOfRangeHotkey") and true or false end,
        function(c) setg("outOfRangeHotkey", c) end)

    shell:SetScript("OnShow", function()
        F.refresh()
        if fontDD then fontDD:setValue(g("keybindFont") or "Default") end
    end)
    if fontDD then fontDD:setValue(g("keybindFont") or "Default") end
    return shell
end

-- ── Top-level Action Bars tab (sidebar: General + each bar) ──────────────────
local function buildActionBarsTab(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()
    panel:Hide()

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 8, -8)
    title:SetText("Action Bars")
    title:SetTextColor(unpack(C.red))

    local enableCB = createCheckbox(panel, "Enable Action Bars", 260)
    enableCB:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    enableCB.OnChange = function(_, checked)
        if AB() then AB().setEnabled(checked) end
    end

    local enableHint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    enableHint:SetPoint("TOPLEFT", enableCB, "BOTTOMLEFT", 20, -3)
    enableHint:SetText("Replaces Blizzard's bars with this addon's own. Enabling is instant; disabling needs a /reload.")
    enableHint:SetTextColor(unpack(C.textDim))

    local keybindBtn = flatButton(panel, "Keybind Mode: OFF", 170, 22)
    keybindBtn:SetPoint("TOPRIGHT", -8, -6)
    local function refreshKeybindBtn()
        local on = AB() and AB().isKeybindActive()
        keybindBtn.label:SetText(on and "Keybind Mode: ON" or "Keybind Mode: OFF")
        keybindBtn.label:SetTextColor(unpack(on and C.red or C.textWhite))
    end
    keybindBtn:SetScript("OnClick", function()
        if AB() then AB().toggleKeybindMode() end
        refreshKeybindBtn()
    end)
    -- Keep the label in sync when keybind mode is ended outside this button —
    -- e.g. LibKeyBound's own "Okay" dialog, or combat auto-disabling it.
    if AB() and AB().setKeybindChangedCallback then
        AB().setKeybindChangedCallback(refreshKeybindBtn)
    end

    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOPRIGHT", keybindBtn, "BOTTOMRIGHT", 0, -3)
    hint:SetText("Hover a button, press a key to bind")
    hint:SetTextColor(unpack(C.textDim))

    -- Drag-to-move modifier: hold this to drag an ability off a button without
    -- the on-keydown press casting it.
    local dragLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dragLabel:SetPoint("TOPLEFT", enableHint, "BOTTOMLEFT", -20, -12)
    dragLabel:SetText("Drag modifier:")
    dragLabel:SetTextColor(unpack(C.textWhite))

    local dragDD = createDropdown(panel, 110,
        { { value = "SHIFT", label = "Shift" },
          { value = "CTRL",  label = "Ctrl"  },
          { value = "ALT",   label = "Alt"   } },
        function() return AB() and AB().getDragModifier() or "SHIFT" end,
        function(v) if AB() then AB().setDragModifier(v) end end,
        nil)
    dragDD:SetPoint("LEFT", dragLabel, "RIGHT", 8, 0)

    local dragHint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dragHint:SetPoint("TOPLEFT", dragLabel, "BOTTOMLEFT", 0, -3)
    dragHint:SetText("Hold to drag an ability without activating it.")
    dragHint:SetTextColor(unpack(C.textDim))

    -- Sidebar: a "General" entry first, then each bar. With ten action bars
    -- plus stance/pet/micro/bag, this list easily runs taller than the fixed
    -- box (or the whole window, once resized smaller) — scrollable, and the
    -- inner list is re-fit whenever the panel is shown or the window resizes
    -- (see makeScrollPanel/attachScrollTrack in core's UI.lua).
    local sidebarHost = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    sidebarHost:SetWidth(132)
    sidebarHost:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -118)
    sidebarHost:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 4, 4)
    applyBackdrop(sidebarHost, 1, C.panelDark)

    -- makeScrollPanel's shell starts hidden (every other caller hands it to a
    -- tab-switcher that explicitly shows it) — this sidebar isn't a switched
    -- tab, it's a permanent fixture, so show it once here.
    local sidebarShell, sidebar, refreshSidebarScroll = makeScrollPanel(sidebarHost)
    sidebarShell:Show()

    local content = CreateFrame("Frame", nil, panel)
    content:SetPoint("TOPLEFT", sidebarHost, "TOPRIGHT", 4, 0)
    content:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 4)

    panel.barTabs   = {}
    panel.barPanels = {}
    local function selectBar(key)
        panel.activeBar = key
        activateTab(panel.barTabs, panel.barPanels, key)
    end

    -- Nav entries: the General panel plus every bar def.
    local nav = { { key = "general", label = "General", general = true } }
    for _, def in ipairs(AB().bars) do nav[#nav + 1] = def end

    local prevNav
    for _, ndef in ipairs(nav) do
        local tab = createSideTab(sidebar, ndef.label, 24)
        -- Smaller than createSideTab's default (GameFontNormalLarge) — this
        -- list runs to 15 entries in a narrow, now-scrollable column, and
        -- names like "Action Bar 10" crowd the space at the larger size.
        tab.text:SetFontObject("GameFontNormalSmall")
        if prevNav then
            tab:SetPoint("TOPLEFT",  prevNav, "BOTTOMLEFT",  0, -2)
            tab:SetPoint("TOPRIGHT", prevNav, "BOTTOMRIGHT", 0, -2)
        else
            tab:SetPoint("TOPLEFT",  sidebar, "TOPLEFT",   3, -6)
            tab:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", -3, -6)
        end
        tab:SetScript("OnClick", function() selectBar(ndef.key) end)
        panel.barTabs[ndef.key] = tab
        if ndef.general then
            panel.barPanels[ndef.key] = buildGlobalPanel(content)
        else
            panel.barPanels[ndef.key] = buildBarPanel(content, ndef)
        end
        prevNav = tab
    end
    refreshSidebarScroll()

    selectBar("general")
    panel:SetScript("OnShow", function()
        enableCB:SetChecked(AB() and AB().getEnabled())
        refreshKeybindBtn()
        dragDD.Refresh()   -- re-read the saved modifier (e.g. after a profile switch)
        refreshSidebarScroll()
    end)

    return panel
end

UI.RegisterTab({ key = "actionbars", label = "Action Bars", order = 35, build = buildActionBarsTab })
