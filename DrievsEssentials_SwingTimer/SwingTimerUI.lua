-- Swing timer module: settings UI. Loads only alongside core (## Dependencies),
-- so the shared namespace and its widget toolkit always exist.
local addon = _G.DrievEssentials
if not addon then return end

local UI = addon.UI
local C  = UI.colors
local W  = UI.widgets

local applyBackdrop        = W.applyBackdrop
local attachTooltip        = W.attachTooltip
local buildFontOptions     = W.buildFontOptions
local buildStepper         = W.buildStepper
local createCheckbox       = W.createCheckbox
local createColorSwatch    = W.createColorSwatch
local createDropdown       = W.createDropdown
local createScrollDropdown = W.createScrollDropdown
local flatButton           = W.flatButton
local makeScrollPanel      = W.makeScrollPanel
local makeSubTabPanel      = W.makeSubTabPanel
local selectSubTab         = W.selectSubTab

-- Re-read live, never captured at build time, so a profile switch (which
-- repoints addon.db) is picked up on the next OnShow.
local function stData()
    addon.db.settings.swingTimer = addon.db.settings.swingTimer or {}
    return addon.db.settings.swingTimer
end

local function resetList()
    local d = stData()
    d.resetSpells = d.resetSpells or {}
    return d.resetSpells
end

-- Every change goes back through the engine's one re-derive entry point.
local function apply()
    if addon.SwingTimer then addon.SwingTimer.applyLayout() end
end

-- ── Row helpers ──────────────────────────────────────────────────────────────
-- The general panel is a stack of [label][control] rows, so the two shapes it
-- uses are built once here rather than spelled out a dozen times.
local LABEL_W = 130

local function makeRow(parent, above, dy)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(340, 22)
    row:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, dy)
    return row
end

local function rowLabel(row, text)
    local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("LEFT", 0, 0)
    lbl:SetWidth(LABEL_W)
    lbl:SetJustifyH("LEFT")
    lbl:SetText(text)
    UI.tint(lbl, C.textWhite)
    return lbl
end

local function colorRow(parent, above, dy, text, get, set, tipBody)
    local row = makeRow(parent, above, dy)
    local lbl = rowLabel(row, text)
    local sw  = createColorSwatch(row, get, set, apply, { hover = true })
    sw:SetPoint("LEFT", lbl, "RIGHT", 10, 0)
    attachTooltip(sw, text, tipBody)
    row.swatch = sw
    return row
end

local function stepperRow(parent, above, dy, text, opts)
    local row = makeRow(parent, above, dy)
    local lbl = rowLabel(row, text)
    opts.onChange  = apply
    opts.valueWidth = opts.valueWidth or 34
    local stepper = buildStepper(row, opts)
    stepper:SetPoint("LEFT", lbl, "RIGHT", 10, 0)
    if opts.suffix then
        local suf = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        suf:SetPoint("LEFT", stepper.plus, "RIGHT", 6, 0)
        suf:SetText(opts.suffix)
        UI.tint(suf, C.textDim)
    end
    row.stepper = stepper
    return row
end

-- ── Font sections ────────────────────────────────────────────────────────────
-- The timer and the hand labels are configured identically — and identically to
-- every other font in the addon, so both are the shared block from
-- UI.widgets.buildFontOptions rather than a set of controls of their own.
local FONT_DEFAULT = addon.Font.New({ size = 11 })

-- Renames the pre-block `name` key to `font` the first time each is read; see
-- addon.Font.Adopt.
local function fontData(key)
    return addon.Font.Adopt(stData(), key, { font = "name" })
end

local function sectionHeader(panel, above, dy, text)
    local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, dy)
    fs:SetText(text)
    UI.tint(fs, C.red)
    return fs
end

-- Returns the block (to anchor whatever follows) and a refresh function the
-- panel's own refresh calls.
local function fontSection(panel, above, title, key)
    local box = buildFontOptions(panel, {
        title      = title,
        defaults   = FONT_DEFAULT,
        get        = function() return fontData(key) end,
        onChange   = apply,
        labelWidth = LABEL_W,
        sizeMax    = 40,
    })
    -- The header the block draws sits above its own top edge, so the gap here is
    -- measured to that rather than to the first row.
    box:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -34)
    return box, function() box:Refresh() end
end

-- ── General ──────────────────────────────────────────────────────────────────
local function buildGeneralPanel(parent)
    local shell, panel = makeScrollPanel(parent)

    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 14, -14)
    header:SetText("Swing Timer")
    UI.tint(header, C.red)

    local enableCB = createCheckbox(panel, "Enable swing timer", 280,
        "Shows a bar per weapon hand, filling from your last swing to the next one. "
            .. "The offhand bar only appears while an offhand weapon is equipped.")
    enableCB:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -12)
    enableCB.OnChange = function(_, checked)
        stData().enabled = checked
        -- applyAll, not just applyVisibility: while the module is off it isn't
        -- listening for UNIT_ATTACK_SPEED, so a weapon swapped in the meantime
        -- would leave the offhand bar missing until the next one.
        if addon.SwingTimer then addon.SwingTimer.applyAll() end
        UI.RefreshTabDots()
    end

    local moveBtn = flatButton(panel, "Move", 80, 22)
    moveBtn:SetPoint("TOPLEFT", enableCB, "BOTTOMLEFT", 0, -10)
    moveBtn:SetScript("OnClick", function() UI.EnterMoveMode({ addon.SwingTimer }) end)

    -- ── Size ────────────────────────────────────────────────────────────────
    local sizeHeader = sectionHeader(panel, moveBtn, -22, "Size")

    local widthRow = stepperRow(panel, sizeHeader, -12, "Width:", {
        min = 60, max = 600, step = 10,
        get = function() return stData().width or 255 end,
        set = function(v) stData().width = v end,
    })

    local heightRow = stepperRow(panel, widthRow, -6, "Height:", {
        min = 6, max = 60, step = 1,
        get = function() return stData().height or 15 end,
        set = function(v) stData().height = v end,
    })

    local padRow = stepperRow(panel, heightRow, -6, "Padding:", {
        min = 0, max = 40, step = 1,
        get = function() return stData().spacing or 0 end,
        set = function(v) stData().spacing = v end,
    })
    attachTooltip(padRow.stepper, "Padding",
        "Gap between the mainhand and offhand bars. 0 puts them flush against "
            .. "each other with nothing drawn in between.")

    -- ── Text ────────────────────────────────────────────────────────────────
    local textHeader = sectionHeader(panel, padRow, -22, "Text")

    local timerCB = createCheckbox(panel, "Show time until next attack", 300,
        "Seconds remaining, on the right of each bar.")
    timerCB:SetPoint("TOPLEFT", textHeader, "BOTTOMLEFT", 0, -12)
    timerCB.OnChange = function(_, checked)
        stData().showTimer = checked
        apply()
    end

    local timerCombatCB = createCheckbox(panel, "Only show the timer in combat", 300,
        "Hides the countdown out of combat, leaving the bars themselves alone. "
            .. "Edit Mode always shows it.")
    timerCombatCB:SetPoint("TOPLEFT", timerCB, "BOTTOMLEFT", 0, -8)
    timerCombatCB.OnChange = function(_, checked)
        stData().timerCombatOnly = checked
        apply()
    end

    local timerZeroCB = createCheckbox(panel, "Hide the timer at zero", 300,
        "Blanks the countdown once it reaches 0.0 — while the swing is ready and "
            .. "there is nothing to count down to.")
    timerZeroCB:SetPoint("TOPLEFT", timerCombatCB, "BOTTOMLEFT", 0, -8)
    timerZeroCB.OnChange = function(_, checked)
        stData().timerHideZero = checked
        apply()
    end

    local labelCB = createCheckbox(panel, "Show Mainhand / Offhand labels", 300,
        "Which hand each bar belongs to, on the left of the bar.")
    labelCB:SetPoint("TOPLEFT", timerZeroCB, "BOTTOMLEFT", 0, -8)
    labelCB.OnChange = function(_, checked)
        stData().showLabel = checked
        apply()
    end

    -- Label reads the engine's constant so the two can't drift apart.
    local previewSecs = (addon.SwingTimer and addon.SwingTimer.previewSeconds) or 20
    local previewBtn = flatButton(panel, "Preview text (" .. previewSecs .. "s)", 150, 22)
    previewBtn:SetPoint("TOPLEFT", labelCB, "BOTTOMLEFT", 0, -12)
    previewBtn:SetScript("OnClick", function()
        if addon.SwingTimer then addon.SwingTimer.previewText() end
    end)
    attachTooltip(previewBtn, "Preview text",
        { "Forces both strings on for 20 seconds and treats the bars as though "
            .. "you were in combat, so the font and offset settings can be judged "
            .. "without going and finding something to hit.",
          "Overrides the three toggles above and the out-of-combat opacity. "
            .. "Clicking again restarts the 20 seconds. The swing timer has to be "
            .. "enabled for there to be anything to preview." })

    local timerFontEnd, refreshTimerFont =
        fontSection(panel, previewBtn, "Timer text", "timerFont")
    local labelFontEnd, refreshLabelFont =
        fontSection(panel, timerFontEnd, "Mainhand / Offhand text", "labelFont")

    -- ── Appearance ──────────────────────────────────────────────────────────
    local lookHeader = sectionHeader(panel, labelFontEnd, -22, "Appearance")

    local barColorRow = colorRow(panel, lookHeader, -12, "Bar color:",
        function()
            local c = stData().color or { 0, 0.118, 1 }
            return c[1], c[2], c[3]
        end,
        function(r, g, b) stData().color = { r, g, b } end,
        "Used for both bars, and for the mainhand whenever nothing is queued.")

    local texRow = makeRow(panel, barColorRow, -6)
    local texLbl = rowLabel(texRow, "Texture:")
    local texDropdown = createScrollDropdown(texRow, 170,
        function() return addon.MediaList("statusbar", { fallback = "Blizzard" }) end,
        function(name)
            stData().texture = name
            apply()
        end,
        { preview = "statusbar", tipTitle = "Bar texture",
          tipBody = "Any bar texture registered with LibSharedMedia by this or another addon." })
    texDropdown:SetPoint("LEFT", texLbl, "RIGHT", 10, 0)

    local backdropColorRow = colorRow(panel, texRow, -8, "Backdrop color:",
        function()
            local c = stData().backdropColor or { 0.04, 0.04, 0.06 }
            return c[1], c[2], c[3]
        end,
        function(r, g, b) stData().backdropColor = { r, g, b } end,
        "The fill behind both bars, seen through the empty part of each bar and "
            .. "through the padding gap between them.")

    local backdropOpRow = stepperRow(panel, backdropColorRow, -6, "Backdrop opacity:", {
        min = 0, max = 100, step = 5, suffix = "%",
        get = function() return stData().backdropOpacity or 85 end,
        set = function(v) stData().backdropOpacity = v end,
    })
    attachTooltip(backdropOpRow.stepper, "Backdrop opacity",
        "0 leaves the empty part of each bar fully transparent. This stacks with "
            .. "the combat opacity settings below rather than replacing them.")

    local outlineCB = createCheckbox(panel, "Show outline", 300,
        "A one-pixel border, drawn either around the pair or around each bar — "
            .. "see the setting below.")
    outlineCB:SetPoint("TOPLEFT", backdropOpRow, "BOTTOMLEFT", 0, -10)
    outlineCB.OnChange = function(_, checked)
        stData().outline = checked
        apply()
    end

    local outlineModeRow = makeRow(panel, outlineCB, -8)
    local outlineModeLbl = rowLabel(outlineModeRow, "Outline around:")
    local outlineModeDD = createDropdown(outlineModeRow, 170, {
            { value = "around", label = "Both bars together" },
            { value = "each",   label = "Each bar separately" },
        },
        function() return stData().outlineMode or "around" end,
        function(v) stData().outlineMode = v end,
        apply,
        "Outline around",
        "Together: one border enclosing the pair — top, sides and bottom, with "
            .. "nothing drawn between the two bars. Separately: every bar gets "
            .. "its own border, so a line sits between them.")
    outlineModeDD:SetPoint("LEFT", outlineModeLbl, "RIGHT", 10, 0)

    local outlineColorRow = colorRow(panel, outlineModeRow, -6, "Outline color:",
        function()
            local c = stData().outlineColor or { 0, 0, 0 }
            return c[1], c[2], c[3]
        end,
        function(r, g, b) stData().outlineColor = { r, g, b } end)

    local sparkCB = createCheckbox(panel, "Show spark", 300,
        "A glow that rides the leading edge of the fill as the swing charges.")
    sparkCB:SetPoint("TOPLEFT", outlineColorRow, "BOTTOMLEFT", 0, -10)
    sparkCB.OnChange = function(_, checked)
        stData().spark = checked
        apply()
    end

    local sparkRow = stepperRow(panel, sparkCB, -8, "Spark width:", {
        min = 1, max = 64, step = 1,
        get = function() return stData().sparkWidth or 2 end,
        set = function(v) stData().sparkWidth = v end,
    })

    -- ── Opacity ─────────────────────────────────────────────────────────────
    local opacityHeader = sectionHeader(panel, sparkRow, -22, "Opacity")

    local combatOpRow = stepperRow(panel, opacityHeader, -12, "In combat:", {
        min = 0, max = 100, step = 5, suffix = "%",
        get = function() return stData().opacity or 100 end,
        set = function(v) stData().opacity = v end,
    })

    local oocOpRow = stepperRow(panel, combatOpRow, -6, "Out of combat:", {
        min = 0, max = 100, step = 5, suffix = "%",
        get = function() return stData().opacityOOC or 50 end,
        set = function(v) stData().opacityOOC = v end,
    })
    attachTooltip(oocOpRow.stepper, "Out of combat opacity",
        "Lets the bars fade back when you're not fighting instead of being turned "
            .. "off. Edit Mode always shows them at full opacity so they stay draggable.")

    -- ── Queue coloring ──────────────────────────────────────────────────────
    local queueHeader = sectionHeader(panel, oocOpRow, -22, "Queue coloring")

    local queueCB = createCheckbox(panel, "Recolor while an ability is queued", 340,
        "Heroic Strike and Cleave are spent on your next mainhand swing, so while "
            .. "one is queued the bar takes its color instead of the normal one.")
    queueCB:SetPoint("TOPLEFT", queueHeader, "BOTTOMLEFT", 0, -12)
    queueCB.OnChange = function(_, checked)
        stData().queueColors = checked
        apply()
    end

    local queueBothCB = createCheckbox(panel, "Color both bars", 340,
        "On: the offhand bar follows the mainhand, so the pair changes color "
            .. "together. Off: only the mainhand recolors, since that's the swing "
            .. "the queued ability is actually spent on.")
    queueBothCB:SetPoint("TOPLEFT", queueCB, "BOTTOMLEFT", 0, -8)
    queueBothCB.OnChange = function(_, checked)
        stData().queueBothBars = checked
        apply()
    end

    local hsRow = colorRow(panel, queueBothCB, -10, "Heroic Strike:",
        function()
            local c = stData().heroicStrikeColor or { 1, 0.863, 0 }
            return c[1], c[2], c[3]
        end,
        function(r, g, b) stData().heroicStrikeColor = { r, g, b } end)

    local cleaveRow = colorRow(panel, hsRow, -6, "Cleave:",
        function()
            local c = stData().cleaveColor or { 0, 1, 0 }
            return c[1], c[2], c[3]
        end,
        function(r, g, b) stData().cleaveColor = { r, g, b } end)

    local function refreshPanel()
        local d = stData()
        enableCB:SetChecked(d.enabled or false)
        timerCB:SetChecked(d.showTimer ~= false)
        timerCombatCB:SetChecked(d.timerCombatOnly or false)
        timerZeroCB:SetChecked(d.timerHideZero or false)
        labelCB:SetChecked(d.showLabel ~= false)
        outlineCB:SetChecked(d.outline ~= false)
        sparkCB:SetChecked(d.spark ~= false)
        queueCB:SetChecked(d.queueColors ~= false)
        queueBothCB:SetChecked(d.queueBothBars ~= false)
        widthRow.stepper.Refresh()
        heightRow.stepper.Refresh()
        padRow.stepper.Refresh()
        sparkRow.stepper.Refresh()
        combatOpRow.stepper.Refresh()
        oocOpRow.stepper.Refresh()
        backdropOpRow.stepper.Refresh()
        barColorRow.swatch.Refresh()
        backdropColorRow.swatch.Refresh()
        outlineColorRow.swatch.Refresh()
        hsRow.swatch.Refresh()
        cleaveRow.swatch.Refresh()
        outlineModeDD.Refresh()
        texDropdown:setValue(d.texture or "Blizzard")
        refreshTimerFont()
        refreshLabelFont()
    end

    shell:SetScript("OnShow", refreshPanel)

    return shell
end

-- ── Reset spells ─────────────────────────────────────────────────────────────
-- C_Spell.GetSpellInfo is the 1.15 form; the global is still there on older
-- builds. Either can come back empty for an ID this client doesn't know.
local function spellName(id)
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(id)
        return info and info.name
    end
    if GetSpellInfo then return (GetSpellInfo(id)) end
    return nil
end

local RESET_LIST_DESC = {
    "Casting one of these restarts your swing timer from zero.",
    "Any other completed cast already resets the swing; this list is for the "
        .. "instants and item uses that do it too, which the combat log doesn't "
        .. "announce as a reset.",
}

local function buildResetSpellsPanel(parent)
    local shell, panel, refreshScroll = makeScrollPanel(parent)

    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 14, -14)
    header:SetText("Swing reset spells")
    UI.tint(header, C.red)

    -- A FontString has no scripts to hook, so the header's hover help goes on an
    -- invisible frame laid over it.
    local hint = CreateFrame("Frame", nil, panel)
    hint:SetPoint("TOPLEFT",     header, "TOPLEFT",     0, 0)
    hint:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 0)
    hint:EnableMouse(true)
    attachTooltip(hint, "Swing reset spells", RESET_LIST_DESC)

    local addWrap = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    addWrap:SetSize(80, 22)
    addWrap:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -12)
    applyBackdrop(addWrap, 1, C.panelDark, C.tabBorder)
    addWrap:EnableMouse(true)

    local addBox = CreateFrame("EditBox", nil, addWrap)
    addBox:SetPoint("TOPLEFT", 5, 0)
    addBox:SetPoint("BOTTOMRIGHT", -5, 0)
    addBox:SetAutoFocus(false)
    addBox:SetFontObject("GameFontNormal")
    addBox:SetMaxLetters(8)
    UI.tint(addBox, C.textWhite)
    addWrap:SetScript("OnEnter", function() UI.tintBorder(addWrap, C.red) end)
    addWrap:SetScript("OnLeave", function() UI.tintBorder(addWrap, C.tabBorder) end)
    attachTooltip(addWrap, "Spell ID", "The numeric ID of the spell or item effect, as shown on Wowhead.")

    local addBtn      = flatButton(panel, "Add", 60, 22)
    local defaultsBtn = flatButton(panel, "Restore defaults", 130, 22)
    addBtn:SetPoint("LEFT", addWrap, "RIGHT", 6, 0)
    defaultsBtn:SetPoint("LEFT", addBtn, "RIGHT", 10, 0)

    local errorText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    errorText:SetPoint("TOPLEFT", addWrap, "BOTTOMLEFT", 0, -6)
    errorText:SetText("")
    UI.tint(errorText, C.red)

    -- Rows are pooled: the list is rebuilt on every add/remove, and creating
    -- frames per rebuild would leak them for the session.
    local rows, rebuildList = {}, nil

    local function makeSpellRow()
        local row = CreateFrame("Frame", nil, panel)
        row:SetSize(340, 20)

        local id = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        id:SetPoint("LEFT", 2, 0); id:SetWidth(56); id:SetJustifyH("LEFT")
        UI.tint(id, C.textGrey)

        local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        name:SetPoint("LEFT", id, "RIGHT", 6, 0); name:SetWidth(220); name:SetJustifyH("LEFT")
        UI.tint(name, C.textWhite)

        local remove = flatButton(row, "X", 20, 18)
        remove:SetPoint("LEFT", name, "RIGHT", 6, 0)
        UI.tint(remove.label, C.red)
        remove:SetScript("OnClick", function()
            local list = resetList()
            -- A removed default is stored as false, not cleared: applyDefaults()
            -- refills nil keys at login, which would bring it straight back.
            if addon.SwingTimer and addon.SwingTimer.defaultResetSpells[row.spellID] then
                list[row.spellID] = false
            else
                list[row.spellID] = nil
            end
            rebuildList()
        end)

        row.id, row.name = id, name
        return row
    end

    function rebuildList()
        local ids = {}
        for id, on in pairs(resetList()) do
            if on and type(id) == "number" then ids[#ids + 1] = id end
        end
        table.sort(ids)

        while #rows < #ids do rows[#rows + 1] = makeSpellRow() end

        local prevRow
        for i, id in ipairs(ids) do
            local row = rows[i]
            row:ClearAllPoints()
            if prevRow then
                row:SetPoint("TOPLEFT", prevRow, "BOTTOMLEFT", 0, -2)
            else
                row:SetPoint("TOPLEFT", errorText, "BOTTOMLEFT", 0, -8)
            end
            row.spellID = id
            row.id:SetText(tostring(id))
            row.name:SetText(spellName(id) or "|cff888888(unknown to this client)|r")
            row:Show()
            prevRow = row
        end
        -- Unanchored as well as hidden: a hidden frame keeps its position, and
        -- findLowestBottom() would size the scroll area around the leftovers.
        for i = #ids + 1, #rows do
            rows[i]:Hide()
            rows[i]:ClearAllPoints()
        end
        refreshScroll()
    end

    local function addSpell()
        local id = tonumber(addBox:GetText())
        if not id or id <= 0 or id ~= math.floor(id) then
            errorText:SetText("Enter a numeric spell ID.")
            return
        end
        errorText:SetText("")
        resetList()[id] = true
        addBox:SetText("")
        addBox:ClearFocus()
        rebuildList()
    end

    addBtn:SetScript("OnClick", addSpell)
    addBox:SetScript("OnEnterPressed", addSpell)
    addBox:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)

    defaultsBtn:SetScript("OnClick", function()
        local list = resetList()
        for id in pairs(list) do list[id] = nil end
        for id, on in pairs(addon.SwingTimer and addon.SwingTimer.defaultResetSpells or {}) do
            list[id] = on
        end
        errorText:SetText("")
        rebuildList()
    end)

    shell:SetScript("OnShow", function()
        errorText:SetText("")
        rebuildList()
    end)

    return shell
end

-- ── Tab ──────────────────────────────────────────────────────────────────────
local function buildSwingTimerShell(parent)
    local panel, _, _, addSubTab = makeSubTabPanel(parent, { hidden = true })

    addSubTab("general", "General",      80,  buildGeneralPanel)
    addSubTab("reset",   "Reset Spells", 110, buildResetSpellsPanel)

    selectSubTab(panel, "general")
    return panel
end

UI.RegisterTab({ key = "swingtimer", label = "Swingtimer", order = 15,
    build = buildSwingTimerShell,
    status = function()
        local d = addon.db and addon.db.settings and addon.db.settings.swingTimer
        return d and d.enabled or false
    end })
