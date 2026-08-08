-- Driev's Essentials — Item Rack module: settings tab.
--
-- Adds the "Item Rack" entry to core's settings sidebar, split into two
-- sub-tabs: General (what the module does) and Layout (how the on-screen bars
-- look, including a per-bar block for every cluster the user has spawned).
-- Because this lives in the module, disabling the addon removes the tab
-- entirely.
local addon = _G.DrievEssentials
if not addon then return end

local IR = addon.ItemRack
if not IR then return end

local UI = addon.UI
local C  = UI.colors
local W  = UI.widgets

local applyBackdrop        = W.applyBackdrop
local createCheckbox       = W.createCheckbox
local createTab            = W.createTab
local selectSubTab         = W.selectSubTab
local buildStepper         = W.buildStepper
local flatButton           = W.flatButton
local makeScrollPanel      = W.makeScrollPanel
local showConfirmPopup     = W.showConfirmPopup
local createScrollDropdown = W.createScrollDropdown

local getData = IR.GetData

local COL_W = 250   -- one column of checkboxes
local COL_X = 268   -- left edge of the second column

-- ── Small builders ───────────────────────────────────────────────────────────

-- Content inset from the sub-panel's edges. Everything in a panel chains off its
-- first element, so setting it here shifts the whole column at once.
local INSET = 14

local function sectionHeader(parent, text, anchorTo, gap)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    if anchorTo then
        fs:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -(gap or 16))
    else
        fs:SetPoint("TOPLEFT", INSET, -INSET)
    end
    fs:SetText(text)
    fs:SetTextColor(unpack(C.red))

    local rule = parent:CreateTexture(nil, "ARTWORK")
    rule:SetTexture(UI.WHITE)
    rule:SetVertexColor(unpack(C.tabBorder))
    rule:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -4)
    rule:SetSize(520, 1)
    return fs
end

-- Checkbox bound straight to one key in the module's settings block, so every
-- toggle is one line at the call site. Tracked in `checks` so the panel's OnShow
-- can re-sync all of them at once after a profile switch.
local function optionCheck(parent, checks, label, key, tooltip, onChange)
    local cb = createCheckbox(parent, label, COL_W)
    cb.settingKey = key
    cb.OnChange = function(_, checked)
        getData()[key] = checked
        if onChange then onChange(checked) end
    end
    if tooltip then
        cb:HookScript("OnEnter", function(self) IR.OnTooltip(self, label, tooltip) end)
        cb:HookScript("OnLeave", function() GameTooltip:Hide() end)
    end
    checks[#checks + 1] = cb
    return cb
end

-- Matches buildStepper's minus/plus buttons (hardcoded there at 22x22), which
-- are the tallest thing in the row.
local STEPPER_ROW_H = 22

local function labelledStepper(parent, anchorTo, gap, text, opts)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -(gap or 12))
    label:SetText(text)
    label:SetTextColor(unpack(C.textWhite))

    local stepper = buildStepper(parent, opts)
    stepper:SetPoint("LEFT", label, "RIGHT", 12, 0)

    -- A FontString's natural height is just its text line — noticeably shorter
    -- than the 22px stepper it sits beside, which SetPoint("LEFT", ..., "RIGHT")
    -- vertically centers against it. Left alone, the label's BOTTOMLEFT (what
    -- the next row anchors off) sits above the stepper's actual bottom edge, so
    -- the next row starts before this one's +/-/value boxes have cleared —
    -- their borders overlap. Fixing the label's height to match the stepper
    -- makes BOTTOMLEFT describe the whole row; FontStrings centre their text
    -- vertically by default, so the label itself doesn't move.
    label:SetHeight(STEPPER_ROW_H)

    label.stepper = stepper
    return label
end

-- ── General sub-tab ──────────────────────────────────────────────────────────

local function buildGeneralPanel(parent)
    local shell, panel = makeScrollPanel(parent)
    local checks = {}

    local enable = optionCheck(panel, checks, "Enable Item Rack", "enabled",
        "Turn the whole module on or off. With it off nothing works: no buttons, no slot menus, no set editor, no key bindings and no slash commands.",
        function()
            -- Refresh, not just ApplyEnabled: the key bindings have to be taken
            -- back when the module goes off and handed out again when it comes
            -- back on, and that's the pair that does both.
            IR.Refresh()
            UI.RefreshTabDots()
        end)
    enable:SetPoint("TOPLEFT", INSET, -INSET)

    local blurb = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    blurb:SetPoint("TOPLEFT", enable, "BOTTOMLEFT", 0, -8)
    blurb:SetWidth(520)
    blurb:SetJustifyH("LEFT")
    blurb:SetTextColor(unpack(C.textGrey))
    blurb:SetText(
        "Hover a slot on the character sheet to pop out every item that fits it — click one to swap.\n"
        .. "|cffffffffAlt+click|r a character sheet slot to spawn a movable button for it (Alt+click the button to remove it).\n"
        .. "|cffffffffAlt+click|r the character model in the middle of the sheet to spawn the equipment-set button.\n"
        .. "New buttons appear in the middle of the screen as a bar of their own.\n"
        .. "Drag a button to move its whole bar; drag one bar against another to join them. "
        .. "|cffffffffShift+drag|r pulls a single button out into a bar of its own.\n"
        .. "Drag a pop-out menu to snap it to any side of its button; |cffffffffright-click|r the menu's "
        .. "background to flip which way it grows. Each bar remembers its own menu placement.")

    local editorBtn = flatButton(panel, "Open Set Editor", 150, 24)
    editorBtn:SetPoint("TOPLEFT", blurb, "BOTTOMLEFT", 0, -10)
    -- Get out of the way: the editor is its own window, and leaving the settings
    -- panel open behind it just buries it.
    editorBtn:SetScript("OnClick", function()
        if UI.frame then UI.frame:Hide() end
        IR.ShowSetEditor()
    end)

    local resetBtn = flatButton(panel, "Reset Buttons", 150, 24)
    resetBtn:SetPoint("LEFT", editorBtn, "RIGHT", 8, 0)
    resetBtn:SetScript("OnClick", function()
        showConfirmPopup({
            title       = "Reset Buttons",
            message     = "Remove every Item Rack bar and restore the default scale, padding and lock state? Your sets are not affected.",
            confirmText = "Reset",
            onConfirm   = function()
                IR.ResetButtons()
                if UI.frame and UI.frame:IsShown() then UI.frame:Hide(); UI.frame:Show() end
            end,
        })
    end)
    resetBtn:HookScript("OnEnter", function(self)
        IR.OnTooltip(self, "Reset Buttons",
            "Removes every Item Rack bar and the buttons on them, and puts button scale, padding, "
            .. "transparency, menu scale and the lock back to their defaults.\n\n"
            .. "Your sets, their icons and their key bindings are not touched — only the on-screen "
            .. "buttons. Alt+click character sheet slots to spawn them again.")
    end)
    resetBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)

    -- Doesn't touch sets or bars — just the addon's own bookkeeping about what's
    -- mid-swap — so it needs no confirmation, unlike the destructive button
    -- beside it.
    local unstickBtn = flatButton(panel, "Unstick Swapping", 150, 24)
    unstickBtn:SetPoint("TOPLEFT", editorBtn, "BOTTOMLEFT", 0, -8)
    unstickBtn:SetScript("OnClick", function() IR.UnstickSwap() end)
    unstickBtn:HookScript("OnEnter", function(self)
        IR.OnTooltip(self, "Unstick Swapping",
            "Forgets any swap or set-equip Item Rack thinks is still in progress and rebuilds where it "
            .. "thinks your gear is. Use this if equipping sets stops doing anything, or gear stays shown "
            .. "as locked with nothing actually happening.\n\nSame as /deir unstick.")
    end)
    unstickBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)

    -- ── Sets ─────────────────────────────────────────────────────────────────
    local setsHdr = sectionHeader(panel, "Sets", unstickBtn, 18)

    local setsNote = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    setsNote:SetPoint("TOPLEFT", setsHdr, "BOTTOMLEFT", 0, -14)
    setsNote:SetWidth(520)
    setsNote:SetJustifyH("LEFT")
    setsNote:SetTextColor(unpack(C.textGrey))
    setsNote:SetText("Equipment sets belong to this character, not to the profile — a set naming gear "
        .. "another character doesn't own would be no use to them. Everything else here (bars, scale, "
        .. "padding, menus) is part of the profile. Move sets between characters with these:")

    -- Both dialogs live with the set editor (ItemRackSets.lua), which has the
    -- same pair of buttons — this tab is the second way in, not a second
    -- implementation.
    local exportBtn = flatButton(panel, "Export Sets", 150, 24)
    exportBtn:SetPoint("TOPLEFT", setsNote, "BOTTOMLEFT", 0, -10)
    exportBtn:SetScript("OnClick", function() IR.ShowExportSetsPopup() end)

    local importBtn = flatButton(panel, "Import Sets", 150, 24)
    importBtn:SetPoint("LEFT", exportBtn, "RIGHT", 8, 0)
    importBtn:SetScript("OnClick", function() IR.ShowImportSetsPopup() end)

    -- ── Character sheet ──────────────────────────────────────────────────────
    local sheetHdr = sectionHeader(panel, "Character Sheet", exportBtn, 18)

    local sheetMenus = optionCheck(panel, checks, "Slot menus on the character sheet", "characterSheetMenus",
        "Pop out a menu of everything that fits a slot when you hover it on the character sheet.")
    sheetMenus:SetPoint("TOPLEFT", sheetHdr, "BOTTOMLEFT", 0, -14)

    local menuOnShift = optionCheck(panel, checks, "Menus on Shift only", "menuOnShift",
        "Only open menus while Shift is held down.")
    menuOnShift:SetPoint("TOPLEFT", sheetMenus, "BOTTOMLEFT", 0, -6)

    local menuOnRight = optionCheck(panel, checks, "Menus on right click", "menuOnRight",
        "Open a button's menu by right clicking it rather than hovering it.",
        function() IR.ReflectMenuOnRight() end)
    menuOnRight:SetPoint("TOPLEFT", menuOnShift, "BOTTOMLEFT", 0, -6)

    local allowEmpty = optionCheck(panel, checks, "Offer an empty slot", "allowEmpty",
        "Add an \"(empty)\" choice to slot menus so a slot can be cleared.")
    allowEmpty:SetPoint("TOPLEFT", sheetMenus, "TOPLEFT", COL_X, 0)

    local hideTradables = optionCheck(panel, checks, "Hide tradable items", "hideTradables",
        "Keep items that aren't soulbound out of the menus.")
    hideTradables:SetPoint("TOPLEFT", allowEmpty, "BOTTOMLEFT", 0, -6)

    local allowHidden = optionCheck(panel, checks, "Allow hiding menu entries", "allowHidden",
        "Alt+click an item in a menu to hide it. Hold Alt as the menu opens to see hidden entries again.")
    allowHidden:SetPoint("TOPLEFT", hideTradables, "BOTTOMLEFT", 0, -6)

    local trinketMode = optionCheck(panel, checks, "Trinket menu mode", "trinketMenuMode",
        "Merge both trinket slots into one menu: left click equips the top trinket, right click the bottom one.")
    trinketMode:SetPoint("TOPLEFT", menuOnRight, "BOTTOMLEFT", 0, -6)

    local anchorOther = optionCheck(panel, checks, "Anchor to the bottom trinket", "anchorOther",
        "In trinket menu mode, dock the merged menu to the bottom trinket instead of the top one.")
    anchorOther:SetPoint("TOPLEFT", allowHidden, "BOTTOMLEFT", 0, -6)

    -- ── Swapping ─────────────────────────────────────────────────────────────
    local swapHdr = sectionHeader(panel, "Swapping", trinketMode, 18)

    local equipToggle = optionCheck(panel, checks, "Toggle sets on equip", "equipToggle",
        "Equipping a set that's already on takes it back off, restoring what it replaced.")
    equipToggle:SetPoint("TOPLEFT", swapHdr, "BOTTOMLEFT", 0, -14)

    local equipOnPick = optionCheck(panel, checks, "Equip while editing a set", "equipOnSetPick",
        "Picking an item in the set editor also equips it straight away.")
    equipOnPick:SetPoint("TOPLEFT", equipToggle, "BOTTOMLEFT", 0, -6)

    local disableAlt = optionCheck(panel, checks, "Let Alt+click pass through", "disableAltClick",
        "Stop Alt+click on a button removing it, so Alt+click can self-cast instead.",
        function() IR.ReflectAltClick() end)
    disableAlt:SetPoint("TOPLEFT", equipOnPick, "BOTTOMLEFT", 0, -6)

    -- ── Notifications & tooltips ─────────────────────────────────────────────
    local notifyHdr = sectionHeader(panel, "Notifications & Tooltips", disableAlt, 18)

    local notify = optionCheck(panel, checks, "Announce when an item is ready", "notify",
        "Tell you when an item you used comes off cooldown.")
    notify:SetPoint("TOPLEFT", notifyHdr, "BOTTOMLEFT", 0, -14)

    local notify30 = optionCheck(panel, checks, "Announce at 30 seconds", "notifyThirty",
        "Also tell you when a used item is 30 seconds from ready.")
    notify30:SetPoint("TOPLEFT", notify, "BOTTOMLEFT", 0, -6)

    local notifyChat = optionCheck(panel, checks, "Send announcements to chat", "notifyChatAlso",
        "Repeat cooldown announcements in the chat frame.")
    notifyChat:SetPoint("TOPLEFT", notify30, "BOTTOMLEFT", 0, -6)

    local setInTip = optionCheck(panel, checks, "Name sets in item tooltips", "showSetInTooltip",
        "Add a line to an item's tooltip listing the sets that use it.")
    setInTip:SetPoint("TOPLEFT", notifyChat, "BOTTOMLEFT", 0, -6)

    local showTips = optionCheck(panel, checks, "Show tooltips", "showTooltips",
        "Show item and set tooltips, including the one you're reading now.")
    showTips:SetPoint("TOPLEFT", notify, "TOPLEFT", COL_X, 0)

    local tinyTips = optionCheck(panel, checks, "Tiny tooltips", "tinyTooltips",
        "Shrink item tooltips to name, charges, durability and cooldown.")
    tinyTips:SetPoint("TOPLEFT", showTips, "BOTTOMLEFT", 0, -6)

    local followTips = optionCheck(panel, checks, "Tooltips at the pointer", "tooltipFollow",
        "Show tooltips beside the mouse rather than in their usual corner.")
    followTips:SetPoint("TOPLEFT", tinyTips, "BOTTOMLEFT", 0, -6)

    shell:HookScript("OnShow", function()
        local d = getData()
        for _, cb in ipairs(checks) do
            cb:SetChecked(d[cb.settingKey] and true or false)
        end
    end)

    return shell
end

-- ── Layout sub-tab ───────────────────────────────────────────────────────────

-- Keybind-text font picker. "Default" is the game's own number font, which is
-- stored as `false` rather than a name so it survives LibSharedMedia not being
-- around to resolve anything.
local DEFAULT_FONT = "Default"

local function hotkeyFontList()
    local list = { DEFAULT_FONT }
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    if LSM then
        for _, name in ipairs(LSM:List("font")) do list[#list + 1] = name end
    end
    return list
end

-- A clickable colour swatch opening WoW's native picker, RGB only — same shape
-- the Chat and TTK panels use, including the fallback for Classic Era builds
-- that predate SetupColorPickerAndShow.
local function colorSwatch(parent, getRGB, setRGB, onChange)
    local sw = CreateFrame("Button", nil, parent, "BackdropTemplate")
    sw:SetSize(20, 20)
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

    sw:SetScript("OnEnter", function(s) s:SetBackdropBorderColor(unpack(C.red)) end)
    sw:SetScript("OnLeave", function(s) s:SetBackdropBorderColor(unpack(C.tabBorder)) end)

    sw.Refresh = paint
    paint()
    return sw
end

-- createScrollDropdown treats its items as opaque, self-identifying strings, so
-- a bar has to be recognisable from its label alone. That used to mean pinning
-- the cluster's internal id onto the end of it ("… #3"), which showed the user a
-- number that means nothing to them. Instead the label lists every slot on the
-- bar: a slot can only be on one bar at a time, so no two labels can collide,
-- and the id stays where it belongs — out of sight. The map is rebuilt whenever
-- the list is, since bars come and go while the panel is open.
local clusterByLabel = {}

local function clusterDropdownLabel(cid)
    return IR.ClusterLabel(cid, true)
end

local function buildLayoutPanel(parent)
    local shell, panel, refreshScroll = makeScrollPanel(parent)
    local checks = {}

    -- ── Defaults for new bars ────────────────────────────────────────────────
    local defHdr = sectionHeader(panel, "Defaults For New Bars")

    local defNote = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    defNote:SetPoint("TOPLEFT", defHdr, "BOTTOMLEFT", 0, -14)
    defNote:SetWidth(520)
    defNote:SetJustifyH("LEFT")
    defNote:SetTextColor(unpack(C.textGrey))
    defNote:SetText("These apply to bars created from here on. Existing bars keep their own settings below — "
        .. "a button docked onto a bar adopts that bar's scale and padding.")

    local scaleLbl = labelledStepper(panel, defNote, 12, "Button scale", {
        min = 0.5, max = 2, step = 0.01, valueWidth = 34,
        format = function(v) return string.format("%.2f", v) end,
        get    = function() return getData().buttonScale or 1 end,
        set    = function(v) getData().buttonScale = v end,
    })

    local padLbl = labelledStepper(panel, scaleLbl, 12, "Button padding", {
        min = 0, max = 24, step = 1,
        format = function(v) return string.format("%d", v) end,
        get    = function() return getData().buttonSpacing or 4 end,
        set    = function(v) getData().buttonSpacing = v end,
    })

    local alphaLbl = labelledStepper(panel, padLbl, 12, "Transparency", {
        min = 0.1, max = 1, step = 0.01, valueWidth = 34,
        format = function(v) return string.format("%.2f", v) end,
        get    = function() return getData().buttonAlpha or 1 end,
        set    = function(v) getData().buttonAlpha = v end,
    })

    local applyAll = flatButton(panel, "Apply To All Bars", 160, 22)
    applyAll:SetPoint("TOPLEFT", alphaLbl, "BOTTOMLEFT", 0, -12)
    applyAll:SetScript("OnClick", function()
        IR.ApplyDefaultsToAllClusters()
        shell:Hide(); shell:Show()   -- cheapest way to re-sync every stepper
    end)

    -- ── Menus ────────────────────────────────────────────────────────────────
    local menuHdr = sectionHeader(panel, "Menus", applyAll, 18)

    local menuScaleLbl = labelledStepper(panel, menuHdr, 14, "Menu scale", {
        min = 0.5, max = 2, step = 0.01, valueWidth = 34,
        format = function(v) return string.format("%.2f", v) end,
        get    = function() return getData().menuScale or 0.85 end,
        set    = function(v) getData().menuScale = v end,
    })

    local menuGapLbl = labelledStepper(panel, menuScaleLbl, 8, "Menu gap", {
        min = 0, max = 40, step = 1,
        format = function(v) return string.format("%d", v) end,
        get    = function() return getData().menuGap or 2 end,
        set    = function(v) getData().menuGap = v end,
    })
    menuGapLbl:HookScript("OnEnter", function(self)
        IR.OnTooltip(self, "Menu Gap", "Space between a button and the pop-out menu it opens.")
    end)
    menuGapLbl:HookScript("OnLeave", function() GameTooltip:Hide() end)

    local iconGapLbl = labelledStepper(panel, menuGapLbl, 8, "Icon spacing", {
        min = 0, max = 20, step = 1,
        format = function(v) return string.format("%d", v) end,
        get    = function() return getData().menuIconSpacing or 4 end,
        set    = function(v) getData().menuIconSpacing = v end,
    })
    iconGapLbl:HookScript("OnEnter", function(self)
        IR.OnTooltip(self, "Icon Spacing", "Space between the icons within a pop-out menu.")
    end)
    iconGapLbl:HookScript("OnLeave", function() GameTooltip:Hide() end)

    local wrap = optionCheck(panel, checks, "Wrap menus at a fixed size", "setMenuWrap",
        "Decide yourself how many entries a menu shows before it starts a new row, instead of letting the module choose.")
    wrap:SetPoint("TOPLEFT", iconGapLbl, "BOTTOMLEFT", 0, -14)

    local wrapLbl = labelledStepper(panel, wrap, 10, "Wrap after", {
        min = 1, max = 30, step = 1,
        format = function(v) return string.format("%d", v) end,
        get    = function() return getData().setMenuWrapValue or 3 end,
        set    = function(v) getData().setMenuWrapValue = v end,
    })

    -- ── Button behaviour ─────────────────────────────────────────────────────
    -- "Lock bars" lives on the sub-tab bar now (see buildItemRackPanel), not
    -- here, so it's visible no matter which of these two sub-tabs is open.
    local behHdr = sectionHeader(panel, "Button Appearance", wrapLbl, 18)

    local hideOOC = optionCheck(panel, checks, "Hide out of combat", "hideOOC",
        "Only show the bars while you're in combat.",
        function() IR.ReflectHideOOC() end)
    hideOOC:SetPoint("TOPLEFT", behHdr, "BOTTOMLEFT", 0, -14)

    local showKeys = optionCheck(panel, checks, "Show key bindings", "showHotKeys",
        "Draw each button's key binding in its corner.\n\n"
        .. "Bind them with the |cffffffffSlot Keybinding|r button in the set editor: hover a button "
        .. "and press the key you want.",
        function() IR.UpdateHotKeys() end)
    showKeys:SetPoint("TOPLEFT", hideOOC, "BOTTOMLEFT", 0, -6)

    local cdCount = optionCheck(panel, checks, "Cooldown numbers", "cooldownCount",
        "Write the remaining cooldown over items as a number.",
        function() IR.UpdateButtonCooldowns() end)
    cdCount:SetPoint("TOPLEFT", hideOOC, "TOPLEFT", COL_X, 0)

    local largeNumbers = optionCheck(panel, checks, "Large cooldown numbers", "largeNumbers",
        "Use a bigger font for the cooldown numbers.")
    largeNumbers:SetPoint("TOPLEFT", cdCount, "BOTTOMLEFT", 0, -6)

    local cd90 = optionCheck(panel, checks, "Count seconds from 90", "cooldown90",
        "Switch from minutes to seconds at 90 seconds remaining instead of 60.")
    cd90:SetPoint("TOPLEFT", largeNumbers, "BOTTOMLEFT", 0, -6)

    -- ── Keybind text ─────────────────────────────────────────────────────────
    -- Font, size and where the key sits on the button. Same set of controls the
    -- Action Bars module offers for its own hotkey text, so the two can be made
    -- to match.
    local keyHdr = sectionHeader(panel, "Keybind Text", cd90, 18)
    -- cd90 is the last row of the RIGHT-hand column, and sectionHeader anchors to
    -- its predecessor's left edge — which would start this header (and its rule,
    -- and everything chained below it, down to "This Bar") halfway across the
    -- panel. Take cd90's depth, since it's the lowest thing above, but put the
    -- header back on the panel's own left margin.
    keyHdr:ClearAllPoints()
    keyHdr:SetPoint("TOPLEFT", cd90, "BOTTOMLEFT", -COL_X, -18)

    local fontLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fontLbl:SetPoint("TOPLEFT", keyHdr, "BOTTOMLEFT", 0, -14)
    fontLbl:SetText("Font")
    fontLbl:SetTextColor(unpack(C.textWhite))
    fontLbl:SetHeight(STEPPER_ROW_H)

    local fontDD = createScrollDropdown(panel, 170, hotkeyFontList, function(name)
        getData().hotkeyFont = name ~= DEFAULT_FONT and name or false
        IR.UpdateHotKeys()
    end, { preview = "font" })
    fontDD:SetPoint("LEFT", fontLbl, "RIGHT", 12, 0)

    local colorLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    colorLbl:SetPoint("TOPLEFT", fontLbl, "BOTTOMLEFT", 0, -10)
    colorLbl:SetText("Text colour")
    colorLbl:SetTextColor(unpack(C.textWhite))
    colorLbl:SetHeight(STEPPER_ROW_H)

    local colorSw = colorSwatch(panel,
        function()
            local c = getData().hotkeyColor
            return c and c[1] or 1, c and c[2] or 1, c and c[3] or 1
        end,
        function(r, g, b) getData().hotkeyColor = { r, g, b } end,
        function() IR.UpdateHotKeys() end)
    colorSw:SetPoint("LEFT", colorLbl, "RIGHT", 12, 0)

    local keySizeLbl = labelledStepper(panel, colorLbl, 10, "Text size", {
        min = 6, max = 30, step = 1,
        format = function(v) return string.format("%d", v) end,
        get    = function() return getData().hotkeyFontSize or 12 end,
        set    = function(v) getData().hotkeyFontSize = v; IR.UpdateHotKeys() end,
    })

    -- Offsets from the button's top-right corner, so both normally read
    -- negative — hence the wider value box.
    local keyXLbl = labelledStepper(panel, keySizeLbl, 8, "Text X offset", {
        min = -40, max = 40, step = 1, valueWidth = 32,
        format = function(v) return string.format("%d", v) end,
        get    = function() return getData().hotkeyOffsetX or -2 end,
        set    = function(v) getData().hotkeyOffsetX = v; IR.UpdateHotKeys() end,
    })

    local keyYLbl = labelledStepper(panel, keyXLbl, 8, "Text Y offset", {
        min = -40, max = 40, step = 1, valueWidth = 32,
        format = function(v) return string.format("%d", v) end,
        get    = function() return getData().hotkeyOffsetY or -2 end,
        set    = function(v) getData().hotkeyOffsetY = v; IR.UpdateHotKeys() end,
    })

    -- ── This Bar ─────────────────────────────────────────────────────────────
    -- One dropdown to pick a bar by name, one block of steppers underneath that
    -- edits whichever bar is currently picked. `selected` is this closure's own
    -- notion of which cluster that is — separate from any button/character-sheet
    -- state — so switching sub-tabs or profiles can't leave it pointing at a
    -- bar that no longer exists.
    local barsHdr = sectionHeader(panel, "This Bar", keyYLbl, 18)

    local emptyNote = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    emptyNote:SetPoint("TOPLEFT", barsHdr, "BOTTOMLEFT", 0, -14)
    emptyNote:SetWidth(520)
    emptyNote:SetJustifyH("LEFT")
    emptyNote:SetTextColor(unpack(C.textDim))
    emptyNote:SetText("No bars yet — Alt+click a slot on your character sheet to make one.")

    local selected   -- cid the block below is currently editing, or nil
    local refreshBlock   -- forward-declared: the dropdown's onChange needs it
                         -- before its full body (which reads the steppers
                         -- below) is defined

    local picker = createScrollDropdown(panel, 300, function()
        local labels = {}
        wipe(clusterByLabel)
        for _, cid in ipairs(IR.ClusterIDs()) do
            local label = clusterDropdownLabel(cid)
            clusterByLabel[label] = cid
            labels[#labels + 1] = label
        end
        return labels
    end, function(label)
        selected = clusterByLabel[label]
        refreshBlock()
    end)
    picker:SetPoint("TOPLEFT", barsHdr, "BOTTOMLEFT", 0, -14)

    local block = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    block:SetPoint("TOPLEFT", picker, "BOTTOMLEFT", 0, -10)
    block:SetSize(520, 122)
    applyBackdrop(block, 1, C.panelDark, C.tabBorder)

    local hint = block:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOPRIGHT", -10, -8)
    hint:SetTextColor(unpack(C.textDim))

    local function editorLabel(text, x, y, opts)
        local lbl = block:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("TOPLEFT", x, y)
        lbl:SetText(text)
        lbl:SetTextColor(unpack(C.textGrey))
        local st = buildStepper(block, opts)
        st:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
        return st
    end

    local scaleStep = editorLabel("Scale", 10, -34, {
        min = 0.5, max = 2, step = 0.01, valueWidth = 34,
        format = function(v) return string.format("%.2f", v) end,
        get    = function() return IR.ClusterData(selected).scale or 1 end,
        set    = function(v) IR.SetClusterScale(selected, v) end,
    })

    local spacingStep = editorLabel("Padding", 10, -62, {
        min = 0, max = 24, step = 1,
        format = function(v) return string.format("%d", v) end,
        get    = function() return IR.ClusterData(selected).spacing or 4 end,
        set    = function(v) IR.SetClusterSpacing(selected, v) end,
    })

    local alphaStep = editorLabel("Transparency", 250, -34, {
        min = 0.1, max = 1, step = 0.01, valueWidth = 34,
        format = function(v) return string.format("%.2f", v) end,
        get    = function() return IR.ClusterData(selected).alpha or 1 end,
        set    = function(v) IR.SetClusterAlpha(selected, v) end,
    })

    local resetMenu = flatButton(block, "Reset Menu Placement", 160, 22)
    resetMenu:SetPoint("TOPLEFT", 10, -90)
    resetMenu:SetScript("OnClick", function() IR.ResetMenuPosition(selected) end)
    resetMenu:HookScript("OnEnter", function(self)
        IR.OnTooltip(self, "Reset Menu Placement",
            "Put this bar's pop-out menu back above its button, growing upwards.\n\n"
            .. "Drag a menu to snap it to any side of the button; right-click the menu's background to flip which way it grows.")
    end)
    resetMenu:HookScript("OnLeave", function() GameTooltip:Hide() end)

    -- Re-syncs the dropdown label, hint text and steppers to whatever `selected`
    -- currently is — called after picking a bar, and every time the tab is
    -- (re-)shown, since bars can appear, disappear or get renumbered underneath
    -- an already-open settings window.
    function refreshBlock()
        local ids = IR.ClusterIDs()
        local stillValid = false
        for _, cid in ipairs(ids) do
            if cid == selected then stillValid = true break end
        end
        if not stillValid then selected = ids[1] end

        emptyNote:SetShown(#ids == 0)
        picker:SetShown(#ids > 0)
        block:SetShown(#ids > 0)

        if selected then
            picker:setValue(clusterDropdownLabel(selected))
            local n = #IR.ClusterMembers(selected)
            hint:SetText(n .. " button" .. (n == 1 and "" or "s"))
        end

        scaleStep.Refresh()
        spacingStep.Refresh()
        alphaStep.Refresh()
    end

    shell:HookScript("OnShow", function()
        local d = getData()
        for _, cb in ipairs(checks) do
            cb:SetChecked(d[cb.settingKey] and true or false)
        end
        scaleLbl.stepper.Refresh()
        padLbl.stepper.Refresh()
        alphaLbl.stepper.Refresh()
        menuScaleLbl.stepper.Refresh()
        menuGapLbl.stepper.Refresh()
        iconGapLbl.stepper.Refresh()
        wrapLbl.stepper.Refresh()
        keySizeLbl.stepper.Refresh()
        keyXLbl.stepper.Refresh()
        keyYLbl.stepper.Refresh()
        fontDD:setValue(d.hotkeyFont or DEFAULT_FONT)
        colorSw.Refresh()
        refreshBlock()
    end)

    return shell
end

-- ── Events sub-tab ───────────────────────────────────────────────────────────
-- One row per event this character can use: switch it on, point it at a set,
-- and decide whether the gear it displaced goes back afterwards. The event
-- definitions themselves are fixed (see ItemRackEvents.lua) — this tab only
-- ever writes the three per-event settings.

local NO_SET = "(no set)"

-- Column geometry, shared by the rows and by the header strip above them.
local EV_NAME_W  = 190
local EV_SET_X   = 200
local EV_SET_W   = 190
local EV_BACK_X  = 400
local EV_ROW_H   = 24

local function buildEventRow(parent, def)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(520, EV_ROW_H)

    local name = createCheckbox(row, def.name, EV_NAME_W)
    name:SetPoint("LEFT", 0, 0)
    name:HookScript("OnEnter", function(self)
        IR.OnTooltip(self, def.name, def.desc
            .. "\n\nPick a set on the right and this switches itself on; clear the set and it switches off.")
    end)
    name:HookScript("OnLeave", function() GameTooltip:Hide() end)

    local back = createCheckbox(row, "Put gear back", 120)
    back:SetPoint("LEFT", EV_BACK_X, 0)
    back:HookScript("OnEnter", function(self)
        IR.OnTooltip(self, "Put Gear Back",
            "When the event ends, put back whatever the set replaced.\n\n"
            .. "With this off the set simply stays on until something else takes it off — useful when "
            .. "one event's set is meant to be your new resting gear rather than a temporary swap.")
    end)
    back:HookScript("OnLeave", function() GameTooltip:Hide() end)

    local picker = createScrollDropdown(row, EV_SET_W, function()
        local items = { NO_SET }
        for _, setname in ipairs(IR.GetOrderedSetNames()) do
            items[#items + 1] = setname
        end
        return items
    end, function(label)
        IR.SetEventSet(def.name, label ~= NO_SET and label or nil)
        row.Refresh()
    end)
    picker:SetPoint("LEFT", EV_SET_X, 0)

    name.OnChange = function(_, checked)
        IR.SetEventEnabled(def.name, checked)
        row.Refresh()
    end
    back.OnChange = function(_, checked)
        IR.SetEventRevert(def.name, checked)
    end

    function row.Refresh()
        local setname = IR.GetEventSet(def.name)
        name:SetChecked(IR.IsEventEnabled(def.name))
        back:SetChecked(IR.GetEventRevert(def.name))
        picker:setValue(setname or NO_SET)
        -- An event with nothing to equip can't do anything, so its two
        -- checkboxes are dimmed until a set is chosen. They still work — this
        -- is a hint, not a lock, and the checkbox widget has no disabled state.
        local a = setname and 1 or 0.45
        name:SetAlpha(a)
        back:SetAlpha(a)
    end

    return row
end

local function buildEventsPanel(parent)
    local shell, panel, refreshScroll = makeScrollPanel(parent)

    local hdr = sectionHeader(panel, "Automatic Sets")

    local blurb = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    blurb:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, -14)
    blurb:SetWidth(520)
    blurb:SetJustifyH("LEFT")
    blurb:SetTextColor(unpack(C.textGrey))
    blurb:SetText(
        "Equip a set by itself whenever something happens — mounting up, walking into a city, sitting "
        .. "down to drink. Point an event at one of your sets and it goes on while that lasts.\n"
        .. "Events stack: mounting up in a city puts the mount set over the city set, and dismounting "
        .. "drops you back into the city set rather than into whatever you wore before either.\n"
        .. "|cffffffffEquipping a set yourself always wins|r — an event that is holding gear steps aside "
        .. "and won't take your choice back off you when it ends.")

    local master = createCheckbox(panel, "Enable events", 200)
    master:SetPoint("TOPLEFT", blurb, "BOTTOMLEFT", 0, -12)
    master:HookScript("OnEnter", function(self)
        IR.OnTooltip(self, "Enable Events",
            "The master switch for everything on this tab. Turning it off gives back any gear an event "
            .. "is currently holding and stops all of them; the rows below keep their settings.")
    end)
    master:HookScript("OnLeave", function() GameTooltip:Hide() end)

    -- Events start switched off, and the rows below happily take settings
    -- either way — which reads as "I set it up and nothing happened" unless the
    -- reason is said out loud.
    local offHint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    offHint:SetPoint("LEFT", master, "RIGHT", 8, 0)
    offHint:SetText("nothing below fires until this is on")
    offHint:SetTextColor(unpack(C.red))

    master.OnChange = function(_, checked)
        IR.SetEventsOn(checked)
        offHint:SetShown(not checked)
    end

    -- Column captions, lined up with buildEventRow's geometry.
    local setCap = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    setCap:SetPoint("TOPLEFT", master, "BOTTOMLEFT", EV_SET_X, -14)
    setCap:SetText("Set to equip")
    setCap:SetTextColor(unpack(C.textDim))

    local rowHost = CreateFrame("Frame", nil, panel)
    rowHost:SetPoint("TOPLEFT", setCap, "BOTTOMLEFT", -EV_SET_X, -6)
    rowHost:SetSize(520, 1)

    -- Rows are built on first show rather than here: the event list is
    -- class-filtered and only exists once IR.InitEvents has run at login, which
    -- may well be after the settings frame was constructed.
    local rows

    local function buildRows()
        if rows or #IR.EventList == 0 then return end
        rows = {}
        local height, classHeader = 0, nil
        for _, def in ipairs(IR.EventList) do
            -- The class-specific events are grouped under their own caption so
            -- the five everyone has aren't lost among a druid's forms.
            if def.class and not classHeader then
                classHeader = rowHost:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                classHeader:SetPoint("TOPLEFT", 0, -(height + 8))
                classHeader:SetText("Forms and stances")
                classHeader:SetTextColor(unpack(C.red))
                height = height + 8 + 16
            end

            local row = buildEventRow(rowHost, def)
            row:SetPoint("TOPLEFT", 0, -height)
            height = height + EV_ROW_H
            rows[#rows + 1] = row
        end
        rowHost:SetHeight(math.max(height, 1))
        if refreshScroll then refreshScroll() end
    end

    shell:HookScript("OnShow", function()
        buildRows()
        master:SetChecked(IR.EventsOn())
        offHint:SetShown(not IR.EventsOn())
        if rows then
            for _, row in ipairs(rows) do row.Refresh() end
        end
    end)

    return shell
end

-- ── Tab shell ────────────────────────────────────────────────────────────────

local function buildItemRackPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()
    panel:Hide()
    panel.subTabs, panel.subPanels = {}, {}

    -- Same inset and framing the Trinkets and Chat tabs use, so every module's
    -- sub-tab shell lines up rather than this one sitting flush to the edges.
    local subBar = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    subBar:SetHeight(26)
    subBar:SetPoint("TOPLEFT", 4, -4)
    subBar:SetPoint("TOPRIGHT", -4, -4)
    applyBackdrop(subBar, 1, C.panelDark)

    local subContent = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    subContent:SetPoint("TOPLEFT", subBar, "BOTTOMLEFT", 0, -2)
    subContent:SetPoint("BOTTOMRIGHT", -4, 4)
    applyBackdrop(subContent, 1, C.panelDeep)

    -- Built on first selection (see resolvePanel in core's UI.lua).
    panel.subPanels["general"] = function() return buildGeneralPanel(subContent) end
    panel.subPanels["layout"]  = function() return buildLayoutPanel(subContent)  end
    panel.subPanels["events"]  = function() return buildEventsPanel(subContent)  end

    panel.subTabs["general"] = createTab(subBar, "General", 90)
    panel.subTabs["general"]:SetHeight(22)
    panel.subTabs["general"]:SetPoint("LEFT", 4, 0)
    panel.subTabs["general"]:SetScript("OnClick", function() selectSubTab(panel, "general") end)

    panel.subTabs["layout"] = createTab(subBar, "Layout", 90)
    panel.subTabs["layout"]:SetHeight(22)
    panel.subTabs["layout"]:SetPoint("LEFT", panel.subTabs["general"], "RIGHT", 4, 0)
    panel.subTabs["layout"]:SetScript("OnClick", function() selectSubTab(panel, "layout") end)

    panel.subTabs["events"] = createTab(subBar, "Events", 90)
    panel.subTabs["events"]:SetHeight(22)
    panel.subTabs["events"]:SetPoint("LEFT", panel.subTabs["layout"], "RIGHT", 4, 0)
    panel.subTabs["events"]:SetScript("OnClick", function() selectSubTab(panel, "events") end)

    -- On the bar itself, not inside either sub-panel, so it stays visible and in
    -- the same spot no matter which of General/Layout is open — it used to live
    -- inside Layout only, easy to lose track of if you weren't on that sub-tab.
    local lockCB = createCheckbox(subBar, "Lock bars", 90)
    lockCB:SetPoint("RIGHT", -8, 0)
    lockCB:SetChecked(getData().locked and true or false)
    lockCB.OnChange = function(_, checked)
        getData().locked = checked
        IR.ReflectLock()
    end
    lockCB:HookScript("OnEnter", function(self)
        IR.OnTooltip(self, "Lock Bars",
            "Stop Item Rack's bars and menus being dragged, and hide their control buttons. Edit Mode still moves them.")
    end)
    lockCB:HookScript("OnLeave", function() GameTooltip:Hide() end)
    IR.RegisterLockCheckbox(lockCB)
    panel.lockCB = lockCB

    selectSubTab(panel, "general")
    return panel
end

UI.RegisterTab({
    key   = "itemrack",
    label = "Item Rack",
    order = 50,
    build = buildItemRackPanel,
    status = function()
        local d = addon.db and addon.db.settings and addon.db.settings.itemRack
        return d and d.enabled or false
    end,
})
