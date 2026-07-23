local addon = _G.DrievEssentials
if not addon then return end

local UI = addon.UI
local C  = UI.colors
local W  = UI.widgets

local createCheckbox  = W.createCheckbox
local createDropdown  = W.createDropdown
local createScrollDropdown = W.createScrollDropdown
local createSideTab   = W.createSideTab
local createTab       = W.createTab
local activateTab     = W.activateTab
local selectSubTab    = W.selectSubTab
local flatButton      = W.flatButton
local makeScrollPanel = W.makeScrollPanel
local applyBackdrop   = W.applyBackdrop
local buildStepper    = W.buildStepper

local function getChatData()
    addon.db.settings.chat = addon.db.settings.chat or {}
    return addon.db.settings.chat
end

local function getDTData()
    addon.db.settings.dataTexts = addon.db.settings.dataTexts or {}
    return addon.db.settings.dataTexts
end

-- The list of assignable stats is read live from DataTexts.listProviders()
-- rather than hardcoded here, so user-created custom stats show up in the
-- per-bar assignment grid alongside the built-ins automatically.

-- ── Small shared row builders (used by the DataTexts sub-tab) ───────────────

-- [label] [-][ typable value ][+] [suffix] row. onChange fires after the value
-- is committed, in addition to set().
--
-- The value is an EditBox rather than the shared buildStepper's read-only
-- FontString, so a number can be typed straight in instead of being clicked to.
-- That matters most for the wide ranges here — nudging a bar from 40px to 600px
-- one click at a time is not a real option.
--
-- Returns (row, control); control.Refresh() re-reads the stored value, matching
-- what buildStepper returned so existing callers are unaffected.
local function addStepperRow(panel, anchorAbove, label, min, max, get, set, onChange, suffix)
    local row = CreateFrame("Frame", nil, panel)
    row:SetSize(320, 22)
    row:SetPoint("TOPLEFT", anchorAbove, "BOTTOMLEFT", 0, -8)

    local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("LEFT", 0, 0); lbl:SetWidth(130); lbl:SetJustifyH("LEFT")
    lbl:SetText(label); lbl:SetTextColor(unpack(C.textGrey))

    local minus = CreateFrame("Button", nil, row, "BackdropTemplate")
    minus:SetSize(20, 20)
    minus:SetPoint("LEFT", lbl, "RIGHT", 6, 0)
    applyBackdrop(minus, 1, C.panelDark, C.tabBorder)
    local minusLbl = minus:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    minusLbl:SetPoint("CENTER"); minusLbl:SetText("-")
    minusLbl:SetTextColor(unpack(C.textWhite))

    local boxWrap = CreateFrame("Frame", nil, row, "BackdropTemplate")
    boxWrap:SetSize(46, 20)
    boxWrap:SetPoint("LEFT", minus, "RIGHT", 4, 0)
    applyBackdrop(boxWrap, 1, C.panelDark, C.tabBorder)

    local box = CreateFrame("EditBox", nil, boxWrap)
    box:SetSize(38, 16); box:SetPoint("CENTER")
    box:SetAutoFocus(false); box:SetMaxLetters(4); box:SetNumeric(true)
    box:SetJustifyH("CENTER"); box:SetFontObject("GameFontNormalSmall")
    box:SetTextColor(unpack(C.textWhite))

    local plus = CreateFrame("Button", nil, row, "BackdropTemplate")
    plus:SetSize(20, 20)
    plus:SetPoint("LEFT", boxWrap, "RIGHT", 4, 0)
    applyBackdrop(plus, 1, C.panelDark, C.tabBorder)
    local plusLbl = plus:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    plusLbl:SetPoint("CENTER"); plusLbl:SetText("+")
    plusLbl:SetTextColor(unpack(C.textWhite))

    if suffix then
        local s = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        s:SetPoint("LEFT", plus, "RIGHT", 6, 0)
        s:SetText(suffix); s:SetTextColor(unpack(C.textDim))
    end

    -- Never overwrite the box while it has focus, or typing "12" on the way to
    -- "120" would be yanked back to the stored value mid-keystroke.
    local function refresh()
        if not box:HasFocus() then
            box:SetText(tostring(math.floor((get() or min) + 0.5)))
        end
    end

    local function commit(v)
        v = math.max(min, math.min(max, math.floor(v + 0.5)))
        set(v)
        if onChange then onChange() end
        refresh()
    end

    minus:SetScript("OnClick", function() commit((get() or min) - 1) end)
    plus:SetScript("OnClick",  function() commit((get() or min) + 1) end)
    minus:SetScript("OnEnter", function(s) s:SetBackdropBorderColor(unpack(C.red)) end)
    minus:SetScript("OnLeave", function(s) s:SetBackdropBorderColor(unpack(C.tabBorder)) end)
    plus:SetScript("OnEnter",  function(s) s:SetBackdropBorderColor(unpack(C.red)) end)
    plus:SetScript("OnLeave",  function(s) s:SetBackdropBorderColor(unpack(C.tabBorder)) end)

    box:SetScript("OnEnterPressed", function(self)
        local n = tonumber(self:GetText())
        -- Clearing focus first so refresh() inside commit isn't blocked by it.
        self:ClearFocus()
        if n then commit(n) else refresh() end
    end)
    -- Clicking away commits too, rather than quietly discarding what was typed.
    box:SetScript("OnEditFocusLost", function(self)
        local n = tonumber(self:GetText())
        if n then commit(n) else refresh() end
    end)
    box:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        refresh()
    end)
    boxWrap:SetScript("OnEnter", function(s) s:SetBackdropBorderColor(unpack(C.red)) end)
    boxWrap:SetScript("OnLeave", function(s) s:SetBackdropBorderColor(unpack(C.tabBorder)) end)

    local control = { Refresh = refresh, box = box, minus = minus, plus = plus }
    refresh()
    return row, control
end

-- A clickable color swatch opening WoW's native color picker (RGB only — this
-- addon uses a separate opacity stepper rather than the picker's own alpha
-- slider, so the two controls don't fight over the same value). Handles both
-- the modern SetupColorPickerAndShow API and the older field-based one, since
-- which is present isn't guaranteed across every Classic Era build.
local function colorSwatch(parent, getRGB, setRGB, onChange)
    local swatch = CreateFrame("Button", nil, parent, "BackdropTemplate")
    swatch:SetSize(20, 20)
    applyBackdrop(swatch, 1, { 1, 1, 1 }, C.tabBorder)

    local function refresh()
        local r, g, b = getRGB()
        swatch:SetBackdropColor(r or 1, g or 1, b or 1, 1)
    end

    swatch:SetScript("OnClick", function()
        local r, g, b = getRGB()
        local function apply()
            local nr, ng, nb = ColorPickerFrame:GetColorRGB()
            setRGB(nr, ng, nb)
            refresh()
            if onChange then onChange() end
        end
        local function cancel()
            setRGB(r, g, b)
            refresh()
            if onChange then onChange() end
        end
        if ColorPickerFrame.SetupColorPickerAndShow then
            ColorPickerFrame:SetupColorPickerAndShow({
                r = r, g = g, b = b, hasOpacity = false,
                swatchFunc = apply, cancelFunc = cancel,
            })
        else
            ColorPickerFrame.hasOpacity = false
            ColorPickerFrame.func = apply
            ColorPickerFrame.cancelFunc = cancel
            ColorPickerFrame:SetColorRGB(r, g, b)
            ColorPickerFrame:Hide() -- force OnShow to refire with the values above
            ColorPickerFrame:Show()
        end
    end)

    swatch.Refresh = refresh
    refresh()
    return swatch
end

local function addColorRow(panel, anchorAbove, label, getRGB, setRGB, onChange)
    local row = CreateFrame("Frame", nil, panel)
    row:SetSize(320, 22)
    row:SetPoint("TOPLEFT", anchorAbove, "BOTTOMLEFT", 0, -8)

    local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("LEFT", 0, 0); lbl:SetWidth(130); lbl:SetJustifyH("LEFT")
    lbl:SetText(label); lbl:SetTextColor(unpack(C.textGrey))

    local swatch = colorSwatch(row, getRGB, setRGB, onChange)
    swatch:SetPoint("LEFT", lbl, "RIGHT", 6, 0)
    return row, swatch
end

-- ── Chat sub-tab ──────────────────────────────────────────────────
-- LSM font list with a leading "Default" (= Blizzard's chat font).
local function chatFontList()
    local list = { "Default" }
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    if LSM then
        for _, name in ipairs(LSM:List("font")) do list[#list + 1] = name end
    end
    return list
end

local function buildChatSettingsPanel(parent)
    local shell, panel = makeScrollPanel(parent)

    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 14, -14)
    header:SetText("Chat")
    header:SetTextColor(unpack(C.red))

    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    desc:SetWidth(500); desc:SetJustifyH("LEFT")
    desc:SetText("Small tweaks to Blizzard's chat. Blizzard still handles chat layout, docking and tabs.")
    desc:SetTextColor(unpack(C.textGrey))

    -- The parent switch for the whole Chat module — Panels, DataTexts and
    -- Alerts all check addon.Chat.isEnabled() too, so switching this off
    -- overrides their own tabs' enable checkboxes rather than sitting
    -- alongside them as an unrelated toggle.
    local enableCB = createCheckbox(panel, "Enable Chat System", 260)
    enableCB:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -10)
    enableCB.OnChange = function(_, checked)
        getChatData().enabled = checked
        if addon.Chat then addon.Chat.refresh() end
        if addon.ChatPanels then addon.ChatPanels.refresh() end
        if addon.DataTexts then addon.DataTexts.refresh() end
        -- Re-evaluates Blizzard Edit Mode suppression for the new state too
        -- (see suppressBlizzardChatEditMode in ChatDock.lua).
        if addon.ChatDock then addon.ChatDock.refresh() end
    end

    -- One font for chat text, tab names and the DataText bars.
    local fontRow = CreateFrame("Frame", nil, panel)
    fontRow:SetSize(420, 24)
    fontRow:SetPoint("TOPLEFT", enableCB, "BOTTOMLEFT", 0, -12)

    local fontLbl = fontRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fontLbl:SetPoint("LEFT", 0, 0); fontLbl:SetWidth(50); fontLbl:SetJustifyH("LEFT")
    fontLbl:SetText("Font:"); fontLbl:SetTextColor(unpack(C.textGrey))

    local fontDD = createScrollDropdown(fontRow, 200, chatFontList, function(name)
        getChatData().font = (name ~= "Default") and name or false
        if addon.Chat      then addon.Chat.refresh() end
        if addon.DataTexts then addon.DataTexts.refresh() end
    end)
    fontDD:SetPoint("LEFT", fontLbl, "RIGHT", 6, 0)

    local fontHint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fontHint:SetPoint("TOPLEFT", fontRow, "BOTTOMLEFT", 0, -4)
    fontHint:SetWidth(460); fontHint:SetJustifyH("LEFT")
    fontHint:SetText("Font for chat message text, tab names and the DataText bars. \"Default\" keeps Blizzard's.")
    fontHint:SetTextColor(unpack(C.textDim))

    local buttonsCB = createCheckbox(panel, "Hide chat buttons", 300)
    buttonsCB:SetPoint("TOPLEFT", fontHint, "BOTTOMLEFT", 0, -10)
    buttonsCB.OnChange = function(_, checked)
        getChatData().hideButtons = checked
        if addon.Chat then addon.Chat.refresh() end
    end

    local buttonsHint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    buttonsHint:SetPoint("TOPLEFT", buttonsCB, "BOTTOMLEFT", 20, -4)
    buttonsHint:SetWidth(460); buttonsHint:SetJustifyH("LEFT")
    buttonsHint:SetText("Hides the scroll arrows, chat menu button and the voice / text-to-speech buttons around the chat. Unticking needs a /reload to bring them back.")
    buttonsHint:SetTextColor(unpack(C.textDim))

    local moveCB = createCheckbox(panel, "Allow moving chat anywhere", 300)
    moveCB:SetPoint("TOPLEFT", buttonsHint, "BOTTOMLEFT", -20, -10)
    moveCB.OnChange = function(_, checked)
        getChatData().freeMovement = checked
        if addon.Chat then addon.Chat.refresh() end
    end

    local moveHint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    moveHint:SetPoint("TOPLEFT", moveCB, "BOTTOMLEFT", 20, -4)
    moveHint:SetWidth(460); moveHint:SetJustifyH("LEFT")
    moveHint:SetText("Removes the margin Blizzard keeps around the chat, which otherwise stops it being dragged to the screen edges. Drag the chat by its tab as usual.")
    moveHint:SetTextColor(unpack(C.textDim))

    local fadeCB = createCheckbox(panel, "Remove chat hover fade", 320)
    fadeCB:SetPoint("TOPLEFT", moveHint, "BOTTOMLEFT", -20, -10)
    fadeCB.OnChange = function(_, checked)
        getChatData().noHoverFade = checked
        if addon.Chat then addon.Chat.refresh() end
    end

    local fadeHint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fadeHint:SetPoint("TOPLEFT", fadeCB, "BOTTOMLEFT", 20, -4)
    fadeHint:SetWidth(460); fadeHint:SetJustifyH("LEFT")
    fadeHint:SetText("Stops the chat background fading in when you mouse over it. Message text still fades after inactivity — that's a separate Blizzard option. Unticking needs a /reload.")
    fadeHint:SetTextColor(unpack(C.textDim))

    local tabsCB = createCheckbox(panel, "Flat, always-visible chat tabs", 320)
    tabsCB:SetPoint("TOPLEFT", fadeHint, "BOTTOMLEFT", -20, -10)
    tabsCB.OnChange = function(_, checked)
        getChatData().flatTabs = checked
        if addon.Chat then addon.Chat.refresh() end
    end

    local tabsHint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tabsHint:SetPoint("TOPLEFT", tabsCB, "BOTTOMLEFT", 20, -4)
    tabsHint:SetWidth(460); tabsHint:SetJustifyH("LEFT")
    tabsHint:SetText("Removes the raised tab graphics and the border that lights up on hover, and keeps every tab name fully legible instead of fading out. Unticking needs a /reload.")
    tabsHint:SetTextColor(unpack(C.textDim))

    local function onTabColorChange()
        if addon.Chat then addon.Chat.refresh() end
    end

    local tabColorRow, tabSwatch = addColorRow(panel, tabsHint, "Tab name color:",
        function()
            local c = getChatData().tabColor or { 0.75, 0.75, 0.80 }
            return c[1], c[2], c[3]
        end,
        function(r, g, b) getChatData().tabColor = { r, g, b } end, onTabColorChange)

    local tabSelColorRow, tabSelSwatch = addColorRow(panel, tabColorRow, "Selected tab color:",
        function()
            local c = getChatData().tabSelectedColor or { 1, 1, 1 }
            return c[1], c[2], c[3]
        end,
        function(r, g, b) getChatData().tabSelectedColor = { r, g, b } end, onTabColorChange)

    local editBoxCB = createCheckbox(panel, "Skin the chat edit box", 300)
    -- -20 steps back out of the indent the two colour rows inherit from
    -- tabsHint, so this lines up with the checkboxes above rather than with the
    -- sub-settings.
    editBoxCB:SetPoint("TOPLEFT", tabSelColorRow, "BOTTOMLEFT", -20, -12)
    editBoxCB.OnChange = function(_, checked)
        getChatData().skinEditBox = checked
        if addon.Chat then addon.Chat.refresh() end
    end

    local editBoxHint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    editBoxHint:SetPoint("TOPLEFT", editBoxCB, "BOTTOMLEFT", 20, -4)
    editBoxHint:SetWidth(460); editBoxHint:SetJustifyH("LEFT")
    editBoxHint:SetText("Replaces the box you type in with a flat themed one, its border tinted by the channel you're talking in, plus a remaining-character count. Unticking needs a /reload.")
    editBoxHint:SetTextColor(unpack(C.textDim))

    -- Message decorations.
    local msgHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    msgHeader:SetPoint("TOPLEFT", editBoxHint, "BOTTOMLEFT", -20, -18)
    msgHeader:SetText("Messages")
    msgHeader:SetTextColor(unpack(C.red))

    local arrowCB = createCheckbox(panel, "Copy arrow on each message", 320)
    arrowCB:SetPoint("TOPLEFT", msgHeader, "BOTTOMLEFT", 0, -8)
    arrowCB.OnChange = function(_, checked)
        getChatData().copyArrow = checked
        if addon.Chat then addon.Chat.refresh() end
    end

    local arrowHint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    arrowHint:SetPoint("TOPLEFT", arrowCB, "BOTTOMLEFT", 20, -4)
    arrowHint:SetWidth(460); arrowHint:SetJustifyH("LEFT")
    arrowHint:SetText("Puts a small white arrow at the start of each line. Clicking it drops that line's text into the edit box, where you can read or copy it. Only affects messages printed from then on.")
    arrowHint:SetTextColor(unpack(C.textDim))

    local copyBtnCB = createCheckbox(panel, "Copy button on the chat", 320)
    copyBtnCB:SetPoint("TOPLEFT", arrowHint, "BOTTOMLEFT", -20, -10)
    copyBtnCB.OnChange = function(_, checked)
        getChatData().copyButton = checked
        if addon.Chat then addon.Chat.refresh() end
    end

    local copyBtnHint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    copyBtnHint:SetPoint("TOPLEFT", copyBtnCB, "BOTTOMLEFT", 20, -4)
    copyBtnHint:SetWidth(460); copyBtnHint:SetJustifyH("LEFT")
    copyBtnHint:SetText("Adds a button to the chat's top-right that opens a window with the recent chat as selectable, copy-pasteable text.")
    copyBtnHint:SetTextColor(unpack(C.textDim))

    local stampCB = createCheckbox(panel, "Show timestamps", 320)
    stampCB:SetPoint("TOPLEFT", copyBtnHint, "BOTTOMLEFT", -20, -10)
    stampCB.OnChange = function(_, checked)
        getChatData().timestamps = checked
        if addon.Chat then addon.Chat.refresh() end
    end

    local stampRow = CreateFrame("Frame", nil, panel)
    stampRow:SetSize(320, 22)
    stampRow:SetPoint("TOPLEFT", stampCB, "BOTTOMLEFT", 0, -8)

    local stampLbl = stampRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    stampLbl:SetPoint("LEFT", 0, 0); stampLbl:SetWidth(130); stampLbl:SetJustifyH("LEFT")
    stampLbl:SetText("Format:"); stampLbl:SetTextColor(unpack(C.textGrey))

    local STAMP_FORMATS = {
        { value = "%H:%M:%S",    label = "15:25:46" },
        { value = "%H:%M",       label = "15:25" },
        { value = "%I:%M:%S %p", label = "03:25:46 PM" },
        { value = "%I:%M %p",    label = "03:25 PM" },
    }
    local stampDD = createDropdown(stampRow, 150, STAMP_FORMATS,
        function() return getChatData().timestampFormat or "%H:%M:%S" end,
        function(v) getChatData().timestampFormat = v end,
        function() if addon.Chat then addon.Chat.refresh() end end)
    stampDD:SetPoint("LEFT", stampLbl, "RIGHT", 6, 0)

    local stampHint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    stampHint:SetPoint("TOPLEFT", stampRow, "BOTTOMLEFT", 0, -4)
    stampHint:SetWidth(460); stampHint:SetJustifyH("LEFT")
    stampHint:SetText("Prints the time in front of each message. The copy arrow, when on, always sits to the left of the timestamp. Copying a line leaves the timestamp out.")
    stampHint:SetTextColor(unpack(C.textDim))

    local stickyCB = createCheckbox(panel, "Sticky chat", 320)
    stickyCB:SetPoint("TOPLEFT", stampHint, "BOTTOMLEFT", 0, -12)
    stickyCB.OnChange = function(_, checked)
        getChatData().stickyChat = checked
        if addon.Chat then addon.Chat.refresh() end
    end

    local stickyHint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    stickyHint:SetPoint("TOPLEFT", stickyCB, "BOTTOMLEFT", 20, -4)
    stickyHint:SetWidth(460); stickyHint:SetJustifyH("LEFT")
    stickyHint:SetText("Reopens the edit box on whatever channel you last spoke in, instead of dropping back to Say every time.")
    stickyHint:SetTextColor(unpack(C.textDim))

    local stickyWCB = createCheckbox(panel, "...including whispers", 320)
    stickyWCB:SetPoint("TOPLEFT", stickyHint, "BOTTOMLEFT", 0, -6)
    stickyWCB.OnChange = function(_, checked)
        getChatData().stickyWhispers = checked
        if addon.Chat then addon.Chat.refresh() end
    end

    local stickyWHint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    stickyWHint:SetPoint("TOPLEFT", stickyWCB, "BOTTOMLEFT", 20, -4)
    stickyWHint:SetWidth(460); stickyWHint:SetJustifyH("LEFT")
    stickyWHint:SetText("Off by default on purpose: with whispers sticky, a message meant for Say goes to whoever you last whispered.")
    stickyWHint:SetTextColor(unpack(C.textDim))

    local historyCB = createCheckbox(panel, "Remember sent messages", 320)
    historyCB:SetPoint("TOPLEFT", stickyWHint, "BOTTOMLEFT", -20, -12)
    historyCB.OnChange = function(_, checked)
        getChatData().chatHistory = checked
        if addon.Chat then addon.Chat.refresh() end
    end

    local historyHint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    historyHint:SetPoint("TOPLEFT", historyCB, "BOTTOMLEFT", 20, -4)
    historyHint:SetWidth(460); historyHint:SetJustifyH("LEFT")
    historyHint:SetText("With the edit box open, Up and Down step through messages you've sent before so you can re-send or edit them. Saved per character, and kept across sessions.")
    historyHint:SetTextColor(unpack(C.textDim))

    local historyRow, historyStepper = addStepperRow(panel, historyHint, "Messages kept:", 5, 100,
        function() return getChatData().historySize or 30 end,
        function(v) getChatData().historySize = v end,
        function() if addon.Chat then addon.Chat.refresh() end end)

    -- Edit box appearance. Kept in its own block below the toggles since it's
    -- the only part of this tab with more than a checkbox's worth of settings.
    local function style()
        local d = getChatData()
        d.editBox = d.editBox or {}
        return d.editBox
    end
    local function onStyleChange()
        if addon.Chat then addon.Chat.refresh() end
    end

    local styleHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    styleHeader:SetPoint("TOPLEFT", historyRow, "BOTTOMLEFT", -20, -18)
    styleHeader:SetText("Edit Box Appearance")
    styleHeader:SetTextColor(unpack(C.red))

    local heightRow, heightStepper = addStepperRow(panel, styleHeader, "Height:", 14, 60,
        function() return style().height or 24 end,
        function(v) style().height = v end, onStyleChange, "px")

    local customWCB = createCheckbox(panel, "Use a custom width", 300)
    customWCB:SetPoint("TOPLEFT", heightRow, "BOTTOMLEFT", 0, -8)
    customWCB.OnChange = function(_, checked)
        style().customWidth = checked
        onStyleChange()
    end

    local widthRow, widthStepper = addStepperRow(panel, customWCB, "Width:", 100, 1200,
        function() return style().width or 400 end,
        function(v) style().width = v end, onStyleChange, "px")

    local widthHint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    widthHint:SetPoint("TOPLEFT", widthRow, "BOTTOMLEFT", 0, -4)
    widthHint:SetWidth(460); widthHint:SetJustifyH("LEFT")
    widthHint:SetText("Without a custom width the box spans the chat window, as Blizzard anchors it. Turning this on needs a /reload to hand that anchoring back.")
    widthHint:SetTextColor(unpack(C.textDim))

    local borderRow, borderStepper = addStepperRow(panel, widthHint, "Border thickness:", 0, 10,
        function() return style().borderThickness or 1 end,
        function(v) style().borderThickness = v end, onStyleChange, "px")

    local bgColorRow, bgSwatch = addColorRow(panel, borderRow, "Background color:",
        function()
            local c = style().bgColor or { 0.090, 0.098, 0.165 }
            return c[1], c[2], c[3]
        end,
        function(r, g, b) style().bgColor = { r, g, b } end, onStyleChange)

    local bgOpRow, bgOpStepper = addStepperRow(panel, bgColorRow, "Background opacity:", 0, 100,
        function() return style().bgOpacity or 90 end,
        function(v) style().bgOpacity = v end, onStyleChange, "%")

    local channelCB = createCheckbox(panel, "Colour border by channel", 300)
    channelCB:SetPoint("TOPLEFT", bgOpRow, "BOTTOMLEFT", 0, -8)
    channelCB.OnChange = function(_, checked)
        style().useChannelColor = checked
        onStyleChange()
    end

    local channelHint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    channelHint:SetPoint("TOPLEFT", channelCB, "BOTTOMLEFT", 20, -4)
    channelHint:SetWidth(460); channelHint:SetJustifyH("LEFT")
    channelHint:SetText("Tints the border to match what you're typing in (Say, Party, Guild...). Turn it off to use the fixed border colour below instead.")
    channelHint:SetTextColor(unpack(C.textDim))

    local bdColorRow, bdSwatch = addColorRow(panel, channelHint, "Border color:",
        function()
            local c = style().borderColor or { 0.30, 0.31, 0.42 }
            return c[1], c[2], c[3]
        end,
        function(r, g, b) style().borderColor = { r, g, b } end, onStyleChange)

    local _, bdOpStepper = addStepperRow(panel, bdColorRow, "Border opacity:", 0, 100,
        function() return style().borderOpacity or 100 end,
        function(v) style().borderOpacity = v end, onStyleChange, "%")

    local function refreshPanel()
        local d = getChatData()
        enableCB:SetChecked(d.enabled ~= false)
        fontDD:setValue(d.font or "Default")
        buttonsCB:SetChecked(d.hideButtons ~= false)
        moveCB:SetChecked(d.freeMovement ~= false)
        fadeCB:SetChecked(d.noHoverFade ~= false)
        tabsCB:SetChecked(d.flatTabs ~= false)
        tabSwatch.Refresh(); tabSelSwatch.Refresh()
        editBoxCB:SetChecked(d.skinEditBox ~= false)

        arrowCB:SetChecked(d.copyArrow ~= false)
        copyBtnCB:SetChecked(d.copyButton ~= false)
        stampCB:SetChecked(d.timestamps or false)
        stampDD:Refresh()
        stickyCB:SetChecked(d.stickyChat ~= false)
        stickyWCB:SetChecked(d.stickyWhispers or false)
        historyCB:SetChecked(d.chatHistory ~= false)
        historyStepper.Refresh()

        customWCB:SetChecked(style().customWidth or false)
        channelCB:SetChecked(style().useChannelColor ~= false)
        heightStepper.Refresh(); widthStepper.Refresh(); borderStepper.Refresh()
        bgSwatch.Refresh(); bgOpStepper.Refresh()
        bdSwatch.Refresh(); bdOpStepper.Refresh()
    end

    shell:HookScript("OnShow", refreshPanel)
    return shell
end

-- ── Panels sub-tab ──────────────────────────────────────────────────────────
-- Purely decorative backdrops meant to sit behind the chat. They don't move,
-- resize or reparent anything Blizzard owns — see ChatPanels.lua for why that
-- separation matters.
-- Panels 1 and 2 are laid out as two side-by-side columns; xOffset shifts a
-- whole section into its column. Every row inside anchors to the one above it
-- with x=0, so offsetting only the header carries the entire column across.
local function buildPanelSection(panel, anchorAbove, index, xOffset)
    local function get()
        addon.db.settings.chatPanels = addon.db.settings.chatPanels or {}
        local d = addon.db.settings.chatPanels
        d[index] = d[index] or {}
        return d[index]
    end
    local function onChange()
        if addon.ChatPanels then addon.ChatPanels.refresh() end
    end

    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", anchorAbove, "BOTTOMLEFT", xOffset or 0, -20)
    header:SetText("Panel " .. index)
    header:SetTextColor(unpack(C.red))

    local enableCB = createCheckbox(panel, "Enable this panel", 260)
    enableCB:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -8)
    enableCB.OnChange = function(_, checked) get().enabled = checked; onChange() end

    local widthRow, widthStepper = addStepperRow(panel, enableCB, "Width:", 100, 1200,
        function() return get().width or 430 end,
        function(v) get().width = v end, onChange, "px")

    local heightRow, heightStepper = addStepperRow(panel, widthRow, "Height:", 60, 800,
        function() return get().height or 190 end,
        function(v) get().height = v end, onChange, "px")

    local borderRow, borderStepper = addStepperRow(panel, heightRow, "Border thickness:", 0, 10,
        function() return get().borderThickness or 1 end,
        function(v) get().borderThickness = v end, onChange, "px")

    local bgColorRow, bgSwatch = addColorRow(panel, borderRow, "Background color:",
        function()
            local c = get().bgColor or { 0.090, 0.098, 0.165 }
            return c[1], c[2], c[3]
        end,
        function(r, g, b) get().bgColor = { r, g, b } end, onChange)

    local bgOpRow, bgOpStepper = addStepperRow(panel, bgColorRow, "Background opacity:", 0, 100,
        function() return get().bgOpacity or 70 end,
        function(v) get().bgOpacity = v end, onChange, "%")

    local bdColorRow, bdSwatch = addColorRow(panel, bgOpRow, "Border color:",
        function()
            local c = get().borderColor or { 0.30, 0.31, 0.42 }
            return c[1], c[2], c[3]
        end,
        function(r, g, b) get().borderColor = { r, g, b } end, onChange)

    local bdOpRow, bdOpStepper = addStepperRow(panel, bdColorRow, "Border opacity:", 0, 100,
        function() return get().borderOpacity or 100 end,
        function(v) get().borderOpacity = v end, onChange, "%")

    local function refresh()
        enableCB:SetChecked(get().enabled or false)
        widthStepper.Refresh(); heightStepper.Refresh(); borderStepper.Refresh()
        bgSwatch.Refresh(); bgOpStepper.Refresh()
        bdSwatch.Refresh(); bdOpStepper.Refresh()
    end

    return bdOpRow, refresh
end

local function buildPanelsPanel(parent)
    local shell, panel = makeScrollPanel(parent)

    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 14, -14)
    header:SetText("Chat Panels")
    header:SetTextColor(unpack(C.red))

    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    desc:SetWidth(500); desc:SetJustifyH("LEFT")
    desc:SetText("Background panels to sit behind your chat. Drag a chat window by its tab and drop it onto a panel to dock it — the chat resizes to fit. Drag it off again to undock.")
    desc:SetTextColor(unpack(C.textGrey))

    local lockCB = createCheckbox(panel, "Lock chat position", 300)
    lockCB:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -10)
    lockCB.OnChange = function(_, checked)
        if addon.ChatDock then addon.ChatDock.setLocked(checked) end
    end

    local lockHint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lockHint:SetPoint("TOPLEFT", lockCB, "BOTTOMLEFT", 20, -4)
    lockHint:SetWidth(460); lockHint:SetJustifyH("LEFT")
    lockHint:SetText("Locked, the chat stays exactly where it is and can't be dragged. Unlock it to move it around or drop it onto a panel.")
    lockHint:SetTextColor(unpack(C.textDim))

    local undockBtn = flatButton(panel, "Undock all", 110, 22)
    undockBtn:SetPoint("TOPLEFT", lockHint, "BOTTOMLEFT", -20, -10)
    undockBtn:SetScript("OnClick", function()
        if addon.ChatDock then addon.ChatDock.undockAll() end
    end)

    local undockHint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    undockHint:SetPoint("TOPLEFT", undockBtn, "BOTTOMLEFT", 0, -6)
    undockHint:SetWidth(460); undockHint:SetJustifyH("LEFT")
    undockHint:SetText("Releases every docked chat window. They stay where they are — they just stop following their panel.")
    undockHint:SetTextColor(unpack(C.textDim))

    -- Both sections hang off the same top anchor; the x-offset on the second
    -- puts it in a column beside the first rather than below it.
    local _, refresh1 = buildPanelSection(panel, undockHint, 1, 0)
    local _, refresh2 = buildPanelSection(panel, undockHint, 2, 350)

    shell:HookScript("OnShow", function()
        lockCB:SetChecked(addon.ChatDock and addon.ChatDock.isLocked() or false)
        refresh1(); refresh2()
    end)
    return shell
end

-- ── Custom DataText editor popup ────────────────────────────────────────────
local editorPopup
local refreshCustomList -- set once buildDataTextsPanel builds the list; the
                         -- editor calls it after a save/delete so the list
                         -- reflects the change immediately.

local function getEditorPopup()
    if editorPopup then return editorPopup end

    local panel = CreateFrame("Frame", "DrievCustomDataTextEditor", UIParent, "BackdropTemplate")
    panel:SetSize(420, 340)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("TOOLTIP")
    applyBackdrop(panel, 2, C.panelBG, C.red)
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    panel:SetMovable(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
    panel:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    panel:Hide()

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -14)
    title:SetTextColor(unpack(C.red))
    panel.title = title

    local closeBtn = CreateFrame("Button", nil, panel)
    closeBtn:SetSize(24, 24)
    closeBtn:SetPoint("TOPRIGHT", -6, -6)
    local closeLbl = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    closeLbl:SetPoint("CENTER"); closeLbl:SetText("X"); closeLbl:SetTextColor(unpack(C.red))
    closeBtn:SetScript("OnClick", function() panel:Hide() end)

    local labelLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    labelLbl:SetPoint("TOPLEFT", 16, -46)
    labelLbl:SetText("Label:")
    labelLbl:SetTextColor(unpack(C.textWhite))

    local labelBoxWrap = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    labelBoxWrap:SetSize(280, 22)
    labelBoxWrap:SetPoint("LEFT", labelLbl, "RIGHT", 8, 0)
    applyBackdrop(labelBoxWrap, 1, C.panelDark, C.tabBorder)
    local labelBox = CreateFrame("EditBox", nil, labelBoxWrap)
    labelBox:SetSize(266, 18); labelBox:SetPoint("CENTER")
    labelBox:SetAutoFocus(false); labelBox:SetMaxLetters(40)
    labelBox:SetFontObject("GameFontNormal"); labelBox:SetTextColor(unpack(C.textWhite))
    panel.labelBox = labelBox

    local codeLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    codeLbl:SetPoint("TOPLEFT", labelLbl, "BOTTOMLEFT", 0, -16)
    codeLbl:SetText('Code (Lua, must return a string/number — e.g. return GetFramerate())')
    codeLbl:SetTextColor(unpack(C.textWhite))

    local codeBoxWrap = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    codeBoxWrap:SetPoint("TOPLEFT", codeLbl, "BOTTOMLEFT", 0, -6)
    codeBoxWrap:SetSize(388, 140)
    applyBackdrop(codeBoxWrap, 1, C.panelDark, C.tabBorder)

    local codeScroll = CreateFrame("ScrollFrame", nil, codeBoxWrap, "UIPanelScrollFrameTemplate")
    codeScroll:SetPoint("TOPLEFT", 6, -6)
    codeScroll:SetPoint("BOTTOMRIGHT", -26, 6)

    local codeBox = CreateFrame("EditBox", nil, codeScroll)
    codeBox:SetMultiLine(true)
    codeBox:SetFontObject("ChatFontNormal")
    codeBox:SetWidth(356)
    codeBox:SetAutoFocus(false)
    codeBox:SetTextColor(unpack(C.textWhite))
    codeScroll:SetScrollChild(codeBox)
    panel.codeBox = codeBox

    local pollLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pollLbl:SetPoint("TOPLEFT", codeBoxWrap, "BOTTOMLEFT", 0, -12)
    pollLbl:SetText("Refresh every:")
    pollLbl:SetTextColor(unpack(C.textGrey))

    local pollStepper = buildStepper(panel, {
        min = 0.5, max = 60, step = 0.5,
        format = function(v) return string.format("%.1f", v) end,
        get = function() return panel._pollValue or 2 end,
        set = function(v) panel._pollValue = v end,
    })
    pollStepper:SetPoint("LEFT", pollLbl, "RIGHT", 8, 0)
    local pollSuffix = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pollSuffix:SetPoint("LEFT", pollStepper.plus, "RIGHT", 4, 0)
    pollSuffix:SetText("s"); pollSuffix:SetTextColor(unpack(C.textDim))
    panel.pollStepper = pollStepper

    local errText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    errText:SetPoint("TOPLEFT", pollLbl, "BOTTOMLEFT", 0, -10)
    errText:SetWidth(388); errText:SetJustifyH("LEFT")
    errText:SetTextColor(unpack(C.red))
    panel.errText = errText

    local saveBtn = flatButton(panel, "Save", 90, 24)
    saveBtn:SetPoint("BOTTOMRIGHT", -16, 14)
    panel.saveBtn = saveBtn

    local deleteBtn = flatButton(panel, "Delete", 90, 24)
    deleteBtn:SetPoint("RIGHT", saveBtn, "LEFT", -10, 0)
    panel.deleteBtn = deleteBtn

    editorPopup = panel
    return panel
end

local function openEditor(id)
    local panel = getEditorPopup()
    local existing = id and addon.DataTexts.listCustom()[id]

    panel.title:SetText(existing and "Edit Custom DataText" or "New Custom DataText")
    panel.labelBox:SetText(existing and existing.label or "")
    panel.codeBox:SetText(existing and existing.code or 'return ""')
    panel._pollValue = existing and existing.poll or 2
    panel.pollStepper.Refresh()
    panel.errText:SetText("")
    panel.deleteBtn:SetShown(existing ~= nil)

    panel.saveBtn:SetScript("OnClick", function()
        local label = panel.labelBox:GetText()
        local code  = panel.codeBox:GetText()
        if label == "" then panel.errText:SetText("Enter a label."); return end
        local fn, err = load(code, "DataText:" .. label, "t")
        if not fn then panel.errText:SetText("Lua error: " .. tostring(err)); return end
        if existing then
            addon.DataTexts.updateCustom(id, label, code, panel._pollValue)
        else
            addon.DataTexts.addCustom(label, code, panel._pollValue)
        end
        panel:Hide()
        if refreshCustomList then refreshCustomList() end
    end)

    panel.deleteBtn:SetScript("OnClick", function()
        if not existing then return end
        UI.showConfirmPopup({
            title       = "Delete Custom DataText",
            message     = string.format('Delete "%s"?', existing.label or id),
            confirmText = "Delete",
            onConfirm   = function()
                addon.DataTexts.removeCustom(id)
                panel:Hide()
                if refreshCustomList then refreshCustomList() end
            end,
        })
    end)

    panel:Show()
end
-- ── DataTexts sub-tab ────────────────────────────────────────────────────────
-- Bar-centric: pick (or create) a bar on the left, configure that bar's look
-- and which datatexts it carries on the right. Bars are positioned through
-- the addon's Edit Mode, same as every other movable element.
local function buildDataTextsPanel(parent)
    -- Trinkets -> General style: header/enable up top, then an inner left
    -- sidebar (DataText Bars / Labels) with the content to its right. The
    -- DataText Bars section splits further into Create / Stats tabs; the Labels
    -- section into General / Blacklist / Custom Stats.
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()
    panel:Hide()

    local selectedBarID    -- which bar the config applies to
    local refreshAll       -- forward decl; bar list + config refresh together
    local refreshOrderList -- forward decl; the stat checkboxes call it on toggle

    -- ── Top header ────────────────────────────────────────────────────────────
    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 14, -14)
    header:SetText("DataTexts")
    header:SetTextColor(unpack(C.red))

    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    desc:SetWidth(560); desc:SetJustifyH("LEFT")
    desc:SetText("Create as many bars as you like, put whichever stats you want on each, and drag them anywhere via Edit Mode.")
    desc:SetTextColor(unpack(C.textGrey))

    local enableCB = createCheckbox(panel, "Enable DataText bars", 260)
    enableCB:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -10)
    enableCB.OnChange = function(_, checked)
        getDTData().enabled = checked
        if addon.DataTexts then addon.DataTexts.refresh() end
    end

    -- Every scrollable content area, so re-opening (or switching to) a tab can
    -- force a re-fit: a makeScrollPanel shown while an ancestor was hidden won't
    -- re-fire OnShow when the ancestor reappears, leaving its scroll range
    -- stale. Hide+Show re-triggers its own refit with valid geometry.
    local scrollShells = {}
    local function forceActiveRefit()
        for _, sh in ipairs(scrollShells) do
            if sh:IsVisible() then sh:Hide(); sh:Show() end
        end
    end
    local function deferRefit()
        C_Timer.After(0, forceActiveRefit)
    end

    -- ── Inner sidebar + content box ───────────────────────────────────────────
    local sideCol = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    sideCol:SetPoint("TOPLEFT", enableCB, "BOTTOMLEFT", -10, -14)
    sideCol:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 4, 4)
    sideCol:SetWidth(130)
    applyBackdrop(sideCol, 1, C.panelDark)

    local sideContent = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    sideContent:SetPoint("TOPLEFT", sideCol, "TOPRIGHT", 6, 0)
    sideContent:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 4)
    applyBackdrop(sideContent, 1, C.panelDeep)

    -- Builds a section that fills sideContent and carries its own top tab bar
    -- over a set of scroll areas. specs = { {key,label,width}, ... }. Returns
    -- the section frame (toggled by the sidebar) and a key->inner table.
    local function tabbedSection(specs)
        local section = CreateFrame("Frame", nil, sideContent)
        section:SetAllPoints(sideContent)
        section:Hide()

        local bar = CreateFrame("Frame", nil, section, "BackdropTemplate")
        bar:SetHeight(24)
        bar:SetPoint("TOPLEFT", 0, 0)
        bar:SetPoint("TOPRIGHT", 0, 0)
        applyBackdrop(bar, 1, C.panelDark)

        local sbody = CreateFrame("Frame", nil, section)
        sbody:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -2)
        sbody:SetPoint("BOTTOMRIGHT", 0, 0)

        local tabs, panels, inners = {}, {}, {}
        local prev
        for _, spec in ipairs(specs) do
            local sh, inner = makeScrollPanel(sbody)
            scrollShells[#scrollShells + 1] = sh
            panels[spec.key] = sh
            inners[spec.key] = inner

            local tab = createTab(bar, spec.label, spec.width or 90)
            tab:SetHeight(19)
            if prev then
                tab:SetPoint("LEFT", prev, "RIGHT", 4, 0)
            else
                tab:SetPoint("TOPLEFT", 3, -3)
            end
            tab:SetScript("OnClick", function()
                activateTab(tabs, panels, spec.key); deferRefit()
            end)
            tabs[spec.key] = tab
            prev = tab
        end
        section._firstKey = specs[1].key
        section.selectFirst = function() activateTab(tabs, panels, section._firstKey) end
        return section, inners
    end

    local barsSection, barsInners = tabbedSection({
        { key = "create", label = "Create", width = 90 },
        { key = "stats",  label = "Stats",  width = 90 },
    })
    local createInner = barsInners.create
    local statsInner  = barsInners.stats

    local labelsSection, labelsInners = tabbedSection({
        { key = "general",   label = "General",      width = 90 },
        { key = "blacklist", label = "Blacklist",    width = 90 },
        { key = "custom",    label = "Custom Stats", width = 110 },
    })
    local genInner  = labelsInners.general
    local blInner   = labelsInners.blacklist
    local custInner = labelsInners.custom

    -- Sidebar entries.
    local sideSections = { bars = barsSection, labels = labelsSection }
    local sideBtns = {}

    local function styleSideBtn(btn, active)
        btn.active = active
        if active then
            btn:SetBackdropColor(unpack(C.tabActive))
            btn:SetBackdropBorderColor(unpack(C.tabActiveBdr))
            btn.text:SetTextColor(unpack(C.textWhite))
        else
            btn:SetBackdropColor(unpack(C.tabIdle))
            btn:SetBackdropBorderColor(unpack(C.tabBorder))
            btn.text:SetTextColor(unpack(C.textGrey))
        end
    end

    local function showSide(key)
        for k, sec in pairs(sideSections) do sec:SetShown(k == key) end
        for k, btn in pairs(sideBtns) do styleSideBtn(btn, k == key) end
        sideSections[key].selectFirst()
        refreshAll()
        deferRefit()
    end

    local barsBtn = createSideTab(sideCol, "DataText Bars", 26)
    barsBtn.text:SetFontObject("GameFontNormalSmall")   -- matches every other inner sidebar list
    barsBtn:SetPoint("TOPLEFT",  sideCol, "TOPLEFT",   3, -3)
    barsBtn:SetPoint("TOPRIGHT", sideCol, "TOPRIGHT", -3, -3)
    barsBtn:SetScript("OnClick", function() showSide("bars") end)

    local labelsBtn = createSideTab(sideCol, "Labels", 26)
    labelsBtn.text:SetFontObject("GameFontNormalSmall")   -- matches every other inner sidebar list
    labelsBtn:SetPoint("TOPLEFT",  barsBtn, "BOTTOMLEFT",  0, -2)
    labelsBtn:SetPoint("TOPRIGHT", barsBtn, "BOTTOMRIGHT", 0, -2)
    labelsBtn:SetScript("OnClick", function() showSide("labels") end)

    sideBtns.bars, sideBtns.labels = barsBtn, labelsBtn

    -- Shared bar-selection helpers.
    local function getSelBar()
        local bars = getDTData().bars or {}
        return selectedBarID and bars[selectedBarID] or nil
    end
    local function onBarChange()
        if addon.DataTexts and selectedBarID then
            addon.DataTexts.rebuildBar(selectedBarID)
        end
    end

    -- ══ DataText Bars › Create ════════════════════════════════════════════════
    local newBarBtn = flatButton(createInner, "New Bar", 90, 22)
    newBarBtn:SetPoint("TOPLEFT", createInner, "TOPLEFT", 14, -12)
    newBarBtn:SetScript("OnClick", function()
        if not addon.DataTexts then return end
        selectedBarID = addon.DataTexts.addBar()
        refreshAll()
    end)

    local listCol = CreateFrame("Frame", nil, createInner, "BackdropTemplate")
    listCol:SetPoint("TOPLEFT", newBarBtn, "BOTTOMLEFT", 0, -12)
    listCol:SetSize(150, 210)
    applyBackdrop(listCol, 1, C.panelDark)

    local cfgAnchor = CreateFrame("Frame", nil, createInner)
    cfgAnchor:SetSize(1, 1)
    cfgAnchor:SetPoint("TOPLEFT", listCol, "TOPRIGHT", 12, 0)

    local barRows = {}
    local function makeBarRow()
        local row = createSideTab(listCol, "", 24)
        row.text:SetFontObject("GameFontNormalSmall")   -- matches every other inner sidebar list
        return row
    end

    local cfgTitle = createInner:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    cfgTitle:SetPoint("TOPLEFT", cfgAnchor, "TOPLEFT", 0, 0)
    cfgTitle:SetTextColor(unpack(C.red))

    local moveBtn = flatButton(createInner, "Move", 70, 22)
    moveBtn:SetPoint("LEFT", cfgTitle, "RIGHT", 12, 0)
    moveBtn:SetScript("OnClick", function()
        if not (addon.DataTexts and selectedBarID) then return end
        UI.EnterMoveMode({ addon.DataTexts.getBarMover(selectedBarID) })
    end)

    local delBtn = flatButton(createInner, "Delete", 70, 22)
    delBtn:SetPoint("LEFT", moveBtn, "RIGHT", 8, 0)
    delBtn:SetScript("OnClick", function()
        local cfg = getSelBar()
        if not cfg then return end
        UI.showConfirmPopup({
            title       = "Delete Bar",
            message     = string.format('Delete "%s"?', cfg.name or selectedBarID),
            confirmText = "Delete",
            onConfirm   = function()
                addon.DataTexts.removeBar(selectedBarID)
                selectedBarID = nil
                refreshAll()
            end,
        })
    end)

    local nameRow = CreateFrame("Frame", nil, createInner)
    nameRow:SetSize(320, 24)
    nameRow:SetPoint("TOPLEFT", cfgTitle, "BOTTOMLEFT", 0, -10)

    local nameLbl = nameRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameLbl:SetPoint("LEFT", 0, 0); nameLbl:SetWidth(130); nameLbl:SetJustifyH("LEFT")
    nameLbl:SetText("Bar name:"); nameLbl:SetTextColor(unpack(C.textGrey))

    local nameWrap = CreateFrame("Frame", nil, nameRow, "BackdropTemplate")
    nameWrap:SetSize(170, 22)
    nameWrap:SetPoint("LEFT", nameLbl, "RIGHT", 6, 0)
    applyBackdrop(nameWrap, 1, C.panelDark, C.tabBorder)

    local nameBox = CreateFrame("EditBox", nil, nameWrap)
    nameBox:SetSize(158, 16)
    nameBox:SetPoint("CENTER")
    nameBox:SetAutoFocus(false)
    nameBox:SetMaxLetters(32)
    nameBox:SetFontObject("GameFontNormal")
    nameBox:SetTextColor(unpack(C.textWhite))
    nameBox:SetTextInsets(4, 4, 0, 0)

    local function commitName()
        local cfg = getSelBar()
        if not cfg then return end
        local text = (nameBox:GetText() or ""):match("^%s*(.-)%s*$")
        if text == "" then
            nameBox:SetText(cfg.name or "")
            return
        end
        cfg.name = text
        cfgTitle:SetText(text)
        refreshAll()
    end

    nameBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    nameBox:SetScript("OnEscapePressed", function(self)
        local cfg = getSelBar()
        self:SetText(cfg and cfg.name or "")
        self:ClearFocus()
    end)
    nameBox:SetScript("OnEditFocusLost", commitName)

    local heightRow, heightStepper = addStepperRow(createInner, nameRow, "Bar height:", 16, 60,
        function() local c = getSelBar(); return c and c.height or 24 end,
        function(v) local c = getSelBar(); if c then c.height = v end end, onBarChange, "px")

    local paddingRow, paddingStepper = addStepperRow(createInner, heightRow, "Side padding:", 0, 200,
        function() local c = getSelBar(); return c and c.padding or 6 end,
        function(v) local c = getSelBar(); if c then c.padding = v end end, onBarChange, "px")

    local paddingHint = createInner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    paddingHint:SetPoint("TOPLEFT", paddingRow, "BOTTOMLEFT", 0, -4)
    paddingHint:SetWidth(430); paddingHint:SetJustifyH("LEFT")
    paddingHint:SetText("Inset from each end of the bar. The gap between datatexts is worked out from what's left, spread evenly — so raising this draws them together.")
    paddingHint:SetTextColor(unpack(C.textDim))

    local fixedWCB = createCheckbox(createInner, "Fixed width", 300)
    fixedWCB:SetPoint("TOPLEFT", paddingHint, "BOTTOMLEFT", 0, -10)
    fixedWCB.OnChange = function(_, checked)
        local c = getSelBar()
        if not c then return end
        c.fixedWidth = checked
        onBarChange()
    end

    local fixedWHint = createInner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fixedWHint:SetPoint("TOPLEFT", fixedWCB, "BOTTOMLEFT", 20, -4)
    fixedWHint:SetWidth(430); fixedWHint:SetJustifyH("LEFT")
    fixedWHint:SetText("Keeps the bar at a set width instead of growing to fit. Datatexts that don't fit are shortened rather than dropped, so nothing disappears without warning.")
    fixedWHint:SetTextColor(unpack(C.textDim))

    local fixedWAnchor = CreateFrame("Frame", nil, createInner)
    fixedWAnchor:SetSize(1, 1)
    fixedWAnchor:SetPoint("TOPLEFT", fixedWHint, "BOTTOMLEFT", -20, 0)

    local widthRow, widthStepper = addStepperRow(createInner, fixedWAnchor, "Width:", 40, 1200,
        function() local c = getSelBar(); return c and c.width or 300 end,
        function(v) local c = getSelBar(); if c then c.width = v end end, onBarChange, "px")

    local minWRow, minWStepper = addStepperRow(createInner, widthRow, "Minimum width:", 20, 600,
        function() local c = getSelBar(); return c and c.minWidth or 40 end,
        function(v) local c = getSelBar(); if c then c.minWidth = v end end, onBarChange, "px")

    local borderRow, borderStepper = addStepperRow(createInner, minWRow, "Border thickness:", 0, 10,
        function() local c = getSelBar(); return c and c.borderThickness or 1 end,
        function(v) local c = getSelBar(); if c then c.borderThickness = v end end, onBarChange, "px")

    local bgColorRow, bgSwatch = addColorRow(createInner, borderRow, "Background color:",
        function()
            local c = getSelBar(); local col = (c and c.bgColor) or { 0.090, 0.098, 0.165 }
            return col[1], col[2], col[3]
        end,
        function(r, g, b) local c = getSelBar(); if c then c.bgColor = { r, g, b } end end, onBarChange)

    local bgOpRow, bgOpStepper = addStepperRow(createInner, bgColorRow, "Background opacity:", 0, 100,
        function() local c = getSelBar(); return c and c.bgOpacity or 100 end,
        function(v) local c = getSelBar(); if c then c.bgOpacity = v end end, onBarChange, "%")

    local bdColorRow, bdSwatch = addColorRow(createInner, bgOpRow, "Border color:",
        function()
            local c = getSelBar(); local col = (c and c.borderColor) or { 0.30, 0.31, 0.42 }
            return col[1], col[2], col[3]
        end,
        function(r, g, b) local c = getSelBar(); if c then c.borderColor = { r, g, b } end end, onBarChange)

    local bdOpRow, bdOpStepper = addStepperRow(createInner, bdColorRow, "Border opacity:", 0, 100,
        function() local c = getSelBar(); return c and c.borderOpacity or 100 end,
        function(v) local c = getSelBar(); if c then c.borderOpacity = v end end, onBarChange, "%")

    local function refreshBarList()
        local bars = getDTData().bars or {}
        local ids = {}
        for id in pairs(bars) do ids[#ids + 1] = id end
        table.sort(ids, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)

        if selectedBarID and not bars[selectedBarID] then selectedBarID = nil end
        if not selectedBarID then selectedBarID = ids[1] end

        while #barRows < #ids do barRows[#barRows + 1] = makeBarRow() end

        local prev
        for i, id in ipairs(ids) do
            local row = barRows[i]
            row:ClearAllPoints()
            if prev then
                row:SetPoint("TOPLEFT",  prev, "BOTTOMLEFT",  0, -2)
                row:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -2)
            else
                row:SetPoint("TOPLEFT",  listCol, "TOPLEFT",   3, -3)
                row:SetPoint("TOPRIGHT", listCol, "TOPRIGHT", -3, -3)
            end
            row.text:SetText(bars[id].name or ("Bar " .. id))
            row.active = (id == selectedBarID)
            if row.active then
                row:SetBackdropColor(unpack(C.tabActive))
                row:SetBackdropBorderColor(unpack(C.tabActiveBdr))
                row.text:SetTextColor(unpack(C.textWhite))
            else
                row:SetBackdropColor(unpack(C.tabIdle))
                row:SetBackdropBorderColor(unpack(C.tabBorder))
                row.text:SetTextColor(unpack(C.textGrey))
            end
            row:SetScript("OnClick", function()
                selectedBarID = id
                refreshAll()
            end)
            row:Show()
            prev = row
        end
        for i = #ids + 1, #barRows do barRows[i]:Hide() end
    end

    -- ══ DataText Bars › Stats ═════════════════════════════════════════════════
    local textsHeader = statsInner:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    textsHeader:SetPoint("TOPLEFT", 14, -14)
    textsHeader:SetText("Stats on this bar")
    textsHeader:SetTextColor(unpack(C.red))

    local textsAnchor = CreateFrame("Frame", nil, statsInner)
    textsAnchor:SetSize(1, 1)
    textsAnchor:SetPoint("TOPLEFT", textsHeader, "BOTTOMLEFT", 0, -10)

    local textCBs = {}
    local TEXT_COL_W, TEXT_ROW_H, TEXT_PER_COL = 150, 22, 6

    local function refreshTextChecks()
        local list = (addon.DataTexts and addon.DataTexts.listProviders()) or {}
        while #textCBs < #list do
            textCBs[#textCBs + 1] = createCheckbox(statsInner, "", TEXT_COL_W - 10)
        end
        for i, entry in ipairs(list) do
            local cb = textCBs[i]
            local col = math.floor((i - 1) / TEXT_PER_COL)
            local row = (i - 1) % TEXT_PER_COL
            cb:ClearAllPoints()
            cb:SetPoint("TOPLEFT", textsAnchor, "TOPLEFT", col * TEXT_COL_W, -row * TEXT_ROW_H)
            cb.text:SetText(entry.label)
            local cfg = getSelBar()
            cb:SetChecked(cfg and (cfg.texts or {})[entry.key] == true)
            cb.OnChange = function(_, checked)
                local c = getSelBar()
                if not c then return end
                c.texts = c.texts or {}
                c.texts[entry.key] = checked or nil
                onBarChange()
                refreshOrderList()
            end
            cb:Show()
        end
        for i = #list + 1, #textCBs do textCBs[i]:Hide() end
    end

    local orderHeader = statsInner:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    orderHeader:SetPoint("TOPLEFT", textsAnchor, "TOPLEFT", 0, -(TEXT_PER_COL * TEXT_ROW_H) - 14)
    orderHeader:SetText("Order")
    orderHeader:SetTextColor(unpack(C.red))

    local orderHint = statsInner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    orderHint:SetPoint("TOPLEFT", orderHeader, "BOTTOMLEFT", 0, -4)
    orderHint:SetWidth(460); orderHint:SetJustifyH("LEFT")
    orderHint:SetText("Left to right across the bar. Use the arrows to move a stat.")
    orderHint:SetTextColor(unpack(C.textDim))

    local orderRows = {}
    local ORDER_ROW_H = 24

    local function makeOrderRow()
        local row = CreateFrame("Frame", nil, statsInner, "BackdropTemplate")
        row:SetSize(300, 22)
        applyBackdrop(row, 1, C.panelDeep, C.tabBorder)

        local idx = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        idx:SetPoint("LEFT", 8, 0); idx:SetWidth(22); idx:SetJustifyH("LEFT")
        idx:SetTextColor(unpack(C.textDim))
        row.idx = idx

        local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        name:SetPoint("LEFT", idx, "RIGHT", 2, 0)
        name:SetTextColor(unpack(C.textWhite))
        row.name = name

        row.downBtn = flatButton(row, "|cffffffff>|r", 24, 18)
        row.downBtn:SetPoint("RIGHT", -6, 0)
        row.upBtn = flatButton(row, "|cffffffff<|r", 24, 18)
        row.upBtn:SetPoint("RIGHT", row.downBtn, "LEFT", -4, 0)
        return row
    end

    refreshOrderList = function()
        local DT  = addon.DataTexts
        local cfg = getSelBar()
        if not (DT and cfg and selectedBarID) then
            for _, r in ipairs(orderRows) do r:Hide() end
            return
        end

        local order = DT.barOrder(selectedBarID)
        local labels = {}
        for _, pr in ipairs(DT.listProviders()) do labels[pr.key] = pr.label end

        while #orderRows < #order do orderRows[#orderRows + 1] = makeOrderRow() end

        for i, key in ipairs(order) do
            local row = orderRows[i]
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", orderHint, "BOTTOMLEFT", 0, -8 - (i - 1) * ORDER_ROW_H)
            row.idx:SetText(i .. ".")
            row.name:SetText(labels[key] or key)

            row.upBtn:SetScript("OnClick", function()
                if DT.moveInBar(selectedBarID, key, -1) then
                    DT.rebuildBar(selectedBarID)
                    refreshOrderList()
                end
            end)
            row.downBtn:SetScript("OnClick", function()
                if DT.moveInBar(selectedBarID, key, 1) then
                    DT.rebuildBar(selectedBarID)
                    refreshOrderList()
                end
            end)

            row.upBtn:SetEnabled(i > 1)
            row.downBtn:SetEnabled(i < #order)
            row.upBtn:SetAlpha(i > 1 and 1 or 0.4)
            row.downBtn:SetAlpha(i < #order and 1 or 0.4)
            row:Show()
        end
        for i = #order + 1, #orderRows do orderRows[i]:Hide() end
    end

    -- Shown/hidden together when a bar is (de)selected. Spans both Create and
    -- Stats tabs, since both only make sense with a bar selected.
    local cfgWidgets = {
        cfgTitle, moveBtn, delBtn, nameRow, heightRow, paddingRow, paddingHint,
        fixedWCB, fixedWHint, widthRow, minWRow, borderRow,
        bgColorRow, bgOpRow, bdColorRow, bdOpRow,
        textsHeader, orderHeader, orderHint,
    }

    -- ══ Labels › General (text prefixes) ══════════════════════════════════════
    local prefixHeader = genInner:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    prefixHeader:SetPoint("TOPLEFT", 14, -14)
    prefixHeader:SetText("Labels")
    prefixHeader:SetTextColor(unpack(C.red))

    local prefixHint = genInner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    prefixHint:SetPoint("TOPLEFT", prefixHeader, "BOTTOMLEFT", 0, -4)
    prefixHint:SetWidth(460); prefixHint:SetJustifyH("LEFT")
    prefixHint:SetText("The text shown in front of each value — change \"Stamina: \" to \"Stam: \", or clear it to show the number alone. Trailing spaces are kept.")
    prefixHint:SetTextColor(unpack(C.textGrey))

    local prefixRows = {}
    local PREFIX_ROW_H = 26

    local function makePrefixRow()
        local row = CreateFrame("Frame", nil, genInner)
        row:SetSize(430, 24)

        local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        name:SetPoint("LEFT", 0, 0); name:SetWidth(130); name:SetJustifyH("LEFT")
        name:SetTextColor(unpack(C.textGrey))
        row.name = name

        local wrap = CreateFrame("Frame", nil, row, "BackdropTemplate")
        wrap:SetSize(160, 22)
        wrap:SetPoint("LEFT", name, "RIGHT", 6, 0)
        applyBackdrop(wrap, 1, C.panelDark, C.tabBorder)
        wrap:SetScript("OnEnter", function(sf) sf:SetBackdropBorderColor(unpack(C.red)) end)
        wrap:SetScript("OnLeave", function(sf) sf:SetBackdropBorderColor(unpack(C.tabBorder)) end)

        local box = CreateFrame("EditBox", nil, wrap)
        box:SetSize(148, 16); box:SetPoint("CENTER")
        box:SetAutoFocus(false); box:SetMaxLetters(24)
        box:SetFontObject("GameFontNormalSmall")
        box:SetTextColor(unpack(C.textWhite))
        box:SetTextInsets(4, 4, 0, 0)
        row.box = box

        row.resetBtn = flatButton(row, "Default", 70, 20)
        row.resetBtn:SetPoint("LEFT", wrap, "RIGHT", 8, 0)
        return row
    end

    local function refreshPrefixRows()
        local DT = addon.DataTexts
        local list = (DT and DT.listPrefixSlots()) or {}

        while #prefixRows < #list do prefixRows[#prefixRows + 1] = makePrefixRow() end

        for i, entry in ipairs(list) do
            local row = prefixRows[i]
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", prefixHint, "BOTTOMLEFT", 0, -10 - (i - 1) * PREFIX_ROW_H)
            row.name:SetText(entry.label)

            if not row.box:HasFocus() then
                row.box:SetText(DT.getPrefix(entry.key))
            end

            local function commit(self)
                DT.setPrefix(entry.key, self:GetText() or "")
                DT.refresh()
            end
            row.box:SetScript("OnEnterPressed", function(self)
                self:ClearFocus(); commit(self)
            end)
            row.box:SetScript("OnEditFocusLost", commit)
            row.box:SetScript("OnEscapePressed", function(self)
                self:SetText(DT.getPrefix(entry.key)); self:ClearFocus()
            end)
            row.resetBtn:SetScript("OnClick", function()
                DT.resetPrefix(entry.key)
                row.box:SetText(DT.getPrefix(entry.key))
                DT.refresh()
            end)
            row:Show()
        end
        for i = #list + 1, #prefixRows do prefixRows[i]:Hide() end
    end

    -- ══ Labels › Blacklist (gold tooltip) ═════════════════════════════════════
    local goldHeader = blInner:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    goldHeader:SetPoint("TOPLEFT", 14, -14)
    goldHeader:SetText("Gold Tooltip")
    goldHeader:SetTextColor(unpack(C.red))

    local goldHint = blInner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    goldHint:SetPoint("TOPLEFT", goldHeader, "BOTTOMLEFT", 0, -4)
    goldHint:SetWidth(460); goldHint:SetJustifyH("LEFT")
    goldHint:SetText("Hovering the Gold datatext lists every character it has seen, and their total. Characters listed here are left out of both the list and the total. Either \"Name\" or \"Name - Realm\" works.")
    goldHint:SetTextColor(unpack(C.textGrey))

    local function blacklist()
        local d = getDTData()
        d.goldBlacklist = d.goldBlacklist or {}
        return d.goldBlacklist
    end

    local blWrap = CreateFrame("Frame", nil, blInner, "BackdropTemplate")
    blWrap:SetSize(200, 22)
    blWrap:SetPoint("TOPLEFT", goldHint, "BOTTOMLEFT", 0, -10)
    applyBackdrop(blWrap, 1, C.panelDark, C.tabBorder)

    local blBox = CreateFrame("EditBox", nil, blWrap)
    blBox:SetSize(188, 16); blBox:SetPoint("CENTER")
    blBox:SetAutoFocus(false); blBox:SetMaxLetters(48)
    blBox:SetFontObject("GameFontNormalSmall")
    blBox:SetTextColor(unpack(C.textWhite))
    blBox:SetTextInsets(4, 4, 0, 0)

    local blRows = {}
    local BL_ROW_H = 22
    local refreshBlacklist

    local blAddBtn = flatButton(blInner, "Add", 70, 22)
    blAddBtn:SetPoint("LEFT", blWrap, "RIGHT", 8, 0)

    local function addEntry()
        local text = (blBox:GetText() or ""):match("^%s*(.-)%s*$")
        if text == "" then return end
        local list = blacklist()
        for _, e in ipairs(list) do
            if tostring(e):lower() == text:lower() then
                blBox:SetText("")
                return
            end
        end
        list[#list + 1] = text
        blBox:SetText("")
        refreshBlacklist()
    end

    blAddBtn:SetScript("OnClick", addEntry)
    blBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); addEntry() end)
    blBox:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)

    local function makeBlRow()
        local row = CreateFrame("Frame", nil, blInner, "BackdropTemplate")
        row:SetSize(280, 20)
        applyBackdrop(row, 1, C.panelDeep, C.tabBorder)

        local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        name:SetPoint("LEFT", 8, 0)
        name:SetTextColor(unpack(C.textWhite))
        row.name = name

        row.delBtn = flatButton(row, "Remove", 70, 18)
        row.delBtn:SetPoint("RIGHT", -4, 0)
        return row
    end

    refreshBlacklist = function()
        local list = blacklist()
        while #blRows < #list do blRows[#blRows + 1] = makeBlRow() end

        for i, entry in ipairs(list) do
            local row = blRows[i]
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", blWrap, "BOTTOMLEFT", 0, -8 - (i - 1) * BL_ROW_H)
            row.name:SetText(tostring(entry))
            row.delBtn:SetScript("OnClick", function()
                table.remove(list, i)
                refreshBlacklist()
            end)
            row:Show()
        end
        for i = #list + 1, #blRows do blRows[i]:Hide() end
    end

    -- ══ Labels › Custom Stats ═════════════════════════════════════════════════
    local customHeader = custInner:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    customHeader:SetPoint("TOPLEFT", 14, -14)
    customHeader:SetText("Custom Stats")
    customHeader:SetTextColor(unpack(C.red))

    local customDesc = custInner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    customDesc:SetPoint("TOPLEFT", customHeader, "BOTTOMLEFT", 0, -4)
    customDesc:SetWidth(560); customDesc:SetJustifyH("LEFT")
    customDesc:SetText("Write a small Lua snippet that returns the text to display, then tick it on a bar's Stats list. Runs only on your own client.")
    customDesc:SetTextColor(unpack(C.textGrey))

    local newCustomBtn = flatButton(custInner, "New Custom Stat", 160, 24)
    newCustomBtn:SetPoint("TOPLEFT", customDesc, "BOTTOMLEFT", 0, -10)
    newCustomBtn:SetScript("OnClick", function() openEditor(nil) end)

    local customRows = {}
    local function makeCustomRow()
        local row = CreateFrame("Frame", nil, custInner, "BackdropTemplate")
        row:SetSize(420, 24)
        applyBackdrop(row, 1, C.panelDeep, C.tabBorder)

        local nameFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameFS:SetPoint("LEFT", 8, 0)
        nameFS:SetTextColor(unpack(C.textWhite))
        row.nameFS = nameFS

        row.editBtn = flatButton(row, "Edit", 60, 20)
        row.editBtn:SetPoint("RIGHT", -6, 0)
        row.delBtn = flatButton(row, "Delete", 64, 20)
        row.delBtn:SetPoint("RIGHT", row.editBtn, "LEFT", -6, 0)
        return row
    end

    local function refreshCustomRows()
        local custom = (addon.DataTexts and addon.DataTexts.listCustom()) or {}
        local ids = {}
        for id in pairs(custom) do ids[#ids + 1] = id end
        table.sort(ids, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)

        while #customRows < #ids do customRows[#customRows + 1] = makeCustomRow() end

        local prevRow
        for i, id in ipairs(ids) do
            local entry = custom[id]
            local row = customRows[i]
            row:ClearAllPoints()
            if prevRow then
                row:SetPoint("TOPLEFT", prevRow, "BOTTOMLEFT", 0, -6)
            else
                row:SetPoint("TOPLEFT", newCustomBtn, "BOTTOMLEFT", 0, -12)
            end
            row.nameFS:SetText(entry.label or ("Custom " .. id))
            row.editBtn:SetScript("OnClick", function() openEditor(id) end)
            row.delBtn:SetScript("OnClick", function()
                UI.showConfirmPopup({
                    title       = "Delete Custom Stat",
                    message     = string.format('Delete "%s"?', entry.label or id),
                    confirmText = "Delete",
                    onConfirm   = function()
                        addon.DataTexts.removeCustom(id)
                        refreshAll()
                    end,
                })
            end)
            row:Show()
            prevRow = row
        end
        for i = #ids + 1, #customRows do customRows[i]:Hide() end
    end

    -- ── Refresh everything ────────────────────────────────────────────────────
    refreshAll = function()
        local d = getDTData()
        enableCB:SetChecked(d.enabled ~= false)
        refreshBarList()

        local cfg = getSelBar()
        local hasBar = cfg ~= nil
        for _, wdg in ipairs(cfgWidgets) do wdg:SetShown(hasBar) end
        for _, cb in ipairs(textCBs) do cb:SetShown(hasBar) end

        if hasBar then
            local name = cfg.name or ("Bar " .. tostring(selectedBarID))
            cfgTitle:SetText(name)
            if not nameBox:HasFocus() then nameBox:SetText(name) end
            fixedWCB:SetChecked(cfg.fixedWidth or false)
            heightStepper.Refresh(); paddingStepper.Refresh()
            widthStepper.Refresh(); minWStepper.Refresh(); borderStepper.Refresh()
            bgSwatch.Refresh(); bgOpStepper.Refresh()
            bdSwatch.Refresh(); bdOpStepper.Refresh()
            refreshTextChecks()
        end
        refreshOrderList()
        refreshPrefixRows()
        refreshBlacklist()
        refreshCustomRows()
    end

    refreshCustomList = refreshAll

    showSide("bars")

    panel:HookScript("OnShow", function()
        refreshAll()
        deferRefit()
    end)
    return panel
end

-- ── Alerts sub-tab ──────────────────────────────────────────────────────────
local function buildAlertsPanel(parent)
    local shell, panel = makeScrollPanel(parent)

    local function alerts()
        addon.db.settings.alerts = addon.db.settings.alerts or {}
        return addon.db.settings.alerts
    end

    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 14, -14)
    header:SetText("Whispers")
    header:SetTextColor(unpack(C.red))

    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    desc:SetWidth(520); desc:SetJustifyH("LEFT")
    desc:SetText("Play a sound when someone whispers you. The list comes from LibSharedMedia, so any sound pack you have installed shows up here automatically.")
    desc:SetTextColor(unpack(C.textGrey))

    local enableCB = createCheckbox(panel, "Play a sound on whisper", 300)
    enableCB:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -12)
    enableCB.OnChange = function(_, checked) alerts().whisperEnabled = checked end

    local soundRow = CreateFrame("Frame", nil, panel)
    soundRow:SetSize(420, 24)
    soundRow:SetPoint("TOPLEFT", enableCB, "BOTTOMLEFT", 0, -12)

    local soundLbl = soundRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    soundLbl:SetPoint("LEFT", 0, 0); soundLbl:SetWidth(60); soundLbl:SetJustifyH("LEFT")
    soundLbl:SetText("Sound:"); soundLbl:SetTextColor(unpack(C.textGrey))

    local soundDD = createScrollDropdown(soundRow, 200,
        function() return (addon.Alerts and addon.Alerts.soundList()) or { "None" } end,
        function(v) alerts().whisperSound = v end)
    soundDD:SetPoint("LEFT", soundLbl, "RIGHT", 6, 0)

    local status = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

    local testBtn = flatButton(soundRow, "Test", 70, 22)
    testBtn:SetPoint("LEFT", soundDD, "RIGHT", 8, 0)
    testBtn:SetScript("OnClick", function()
        local name = alerts().whisperSound
        if addon.Alerts and addon.Alerts.playSound(name) then
            status:SetText("")
        else
            -- A sound can fail because it's "None", or because the file behind
            -- it doesn't exist in this client build. Either way, silence with no
            -- explanation would look like the feature is broken.
            status:SetText(name == "None"
                and "\"None\" plays nothing — pick another sound."
                or  "That sound could not be played on this client.")
        end
    end)

    status:SetPoint("TOPLEFT", soundRow, "BOTTOMLEFT", 0, -6)
    status:SetWidth(520); status:SetJustifyH("LEFT")
    status:SetTextColor(unpack(C.red))
    status:SetText("")

    local throttleRow, throttleStepper = addStepperRow(panel, status, "Minimum gap:", 0, 30,
        function() return alerts().throttle or 3 end,
        function(v) alerts().throttle = v end, nil, "sec")

    local throttleHint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    throttleHint:SetPoint("TOPLEFT", throttleRow, "BOTTOMLEFT", 0, -6)
    throttleHint:SetWidth(520); throttleHint:SetJustifyH("LEFT")
    throttleHint:SetText("How long to wait before the sound can play again. Whispers often arrive in bursts, and without a gap they stack into one long noise.")
    throttleHint:SetTextColor(unpack(C.textDim))

    local function refreshPanel()
        local d = alerts()
        enableCB:SetChecked(d.whisperEnabled or false)
        soundDD:setValue(d.whisperSound or "None")
        throttleStepper.Refresh()
        status:SetText("")
    end

    shell:HookScript("OnShow", refreshPanel)
    return shell
end

-- ── Top-level Chat tab (nested sub-tabs: Chat / Panels / DataTexts / Alerts) ─
local function buildChatShell(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()

    local subBar = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    subBar:SetHeight(26)
    subBar:SetPoint("TOPLEFT", 4, -4)
    subBar:SetPoint("TOPRIGHT", -4, -4)
    applyBackdrop(subBar, 1, C.panelDark)

    local subContent = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    subContent:SetPoint("TOPLEFT", subBar, "BOTTOMLEFT", 0, -2)
    subContent:SetPoint("BOTTOMRIGHT", -4, 4)
    applyBackdrop(subContent, 1, C.panelDeep)

    panel.subTabs, panel.subPanels = {}, {}

    local chatTab = createTab(subBar, "Chat", 80)
    chatTab:SetHeight(22); chatTab:SetPoint("LEFT", 4, 0)
    chatTab:SetScript("OnClick", function() selectSubTab(panel, "chat") end)
    panel.subTabs["chat"]   = chatTab
    panel.subPanels["chat"] = buildChatSettingsPanel(subContent)

    local panelsTab = createTab(subBar, "Panels", 80)
    panelsTab:SetHeight(22); panelsTab:SetPoint("LEFT", chatTab, "RIGHT", 4, 0)
    panelsTab:SetScript("OnClick", function() selectSubTab(panel, "panels") end)
    panel.subTabs["panels"]   = panelsTab
    panel.subPanels["panels"] = buildPanelsPanel(subContent)

    local dtTab = createTab(subBar, "DataTexts", 100)
    dtTab:SetHeight(22); dtTab:SetPoint("LEFT", panelsTab, "RIGHT", 4, 0)
    dtTab:SetScript("OnClick", function() selectSubTab(panel, "datatexts") end)
    panel.subTabs["datatexts"]   = dtTab
    panel.subPanels["datatexts"] = buildDataTextsPanel(subContent)

    local alertsTab = createTab(subBar, "Alerts", 80)
    alertsTab:SetHeight(22); alertsTab:SetPoint("LEFT", dtTab, "RIGHT", 4, 0)
    alertsTab:SetScript("OnClick", function() selectSubTab(panel, "alerts") end)
    panel.subTabs["alerts"]   = alertsTab
    panel.subPanels["alerts"] = buildAlertsPanel(subContent)

    selectSubTab(panel, "chat")
    return panel
end

UI.RegisterTab({ key = "chat", label = "Chat", order = 25, build = buildChatShell })
