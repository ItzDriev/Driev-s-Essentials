local addon = _G.DrievEssentials
if not addon then return end

local UI = addon.UI
local C  = UI.colors
local W  = UI.widgets

local buildFontOptions = W.buildFontOptions
local createCheckbox  = W.createCheckbox
local colorSwatch     = W.createColorSwatch
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
local attachTooltip   = W.attachTooltip

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

-- The [label] half of a settings row, shared by both row builders below.
local function labelledRow(panel, anchorAbove, label, indent)
    local row = CreateFrame("Frame", nil, panel)
    row:SetSize(320, 22)
    row:SetPoint("TOPLEFT", anchorAbove, "BOTTOMLEFT", indent or 0, -8)

    local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("LEFT", 0, 0); lbl:SetWidth(130); lbl:SetJustifyH("LEFT")
    lbl:SetText(label); UI.tint(lbl, C.textGrey)
    return row, lbl
end

-- [label] [-][ typable value ][+] [suffix]. An EditBox rather than buildStepper's
-- read-only value, since nudging a bar from 40px to 600px one click at a time
-- isn't realistic. `indent` marks the row as a sub-setting of the control above;
-- `desc` is hover help, attached to all three parts. Returns (row, control),
-- control.Refresh() re-reading the stored value.
local function addStepperRow(panel, anchorAbove, label, min, max, get, set, onChange, suffix, indent, desc)
    local row, lbl = labelledRow(panel, anchorAbove, label, indent)

    local minus = CreateFrame("Button", nil, row, "BackdropTemplate")
    minus:SetSize(20, 20)
    minus:SetPoint("LEFT", lbl, "RIGHT", 6, 0)
    applyBackdrop(minus, 1, C.panelDark, C.tabBorder)
    local minusLbl = minus:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    minusLbl:SetPoint("CENTER"); minusLbl:SetText("-")
    UI.tint(minusLbl, C.textWhite)

    local boxWrap = CreateFrame("Frame", nil, row, "BackdropTemplate")
    boxWrap:SetSize(46, 20)
    boxWrap:SetPoint("LEFT", minus, "RIGHT", 4, 0)
    applyBackdrop(boxWrap, 1, C.panelDark, C.tabBorder)

    local box = CreateFrame("EditBox", nil, boxWrap)
    box:SetSize(38, 16); box:SetPoint("CENTER")
    -- Not SetNumeric(true): that flag allows only digits 0-9 and silently strips the
    -- "-" from negative values (even ones set via SetText), which breaks the X/Y
    -- offset rows. tonumber() on commit already rejects non-numbers.
    box:SetAutoFocus(false); box:SetMaxLetters(5)
    box:SetJustifyH("CENTER"); box:SetFontObject("GameFontNormalSmall")
    UI.tint(box, C.textWhite)

    local plus = CreateFrame("Button", nil, row, "BackdropTemplate")
    plus:SetSize(20, 20)
    plus:SetPoint("LEFT", boxWrap, "RIGHT", 4, 0)
    applyBackdrop(plus, 1, C.panelDark, C.tabBorder)
    local plusLbl = plus:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    plusLbl:SetPoint("CENTER"); plusLbl:SetText("+")
    UI.tint(plusLbl, C.textWhite)

    if suffix then
        local s = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        s:SetPoint("LEFT", plus, "RIGHT", 6, 0)
        s:SetText(suffix); UI.tint(s, C.textDim)
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
    minus:SetScript("OnEnter", function(s) UI.tintBorder(s, C.red) end)
    minus:SetScript("OnLeave", function(s) UI.tintBorder(s, C.tabBorder) end)
    plus:SetScript("OnEnter",  function(s) UI.tintBorder(s, C.red) end)
    plus:SetScript("OnLeave",  function(s) UI.tintBorder(s, C.tabBorder) end)

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
    boxWrap:SetScript("OnEnter", function(s) UI.tintBorder(s, C.red) end)
    boxWrap:SetScript("OnLeave", function(s) UI.tintBorder(s, C.tabBorder) end)

    if desc then
        for _, part in ipairs({ minus, plus, boxWrap }) do
            attachTooltip(part, label:gsub(":%s*$", ""), desc)
        end
    end

    local control = { Refresh = refresh, box = box, minus = minus, plus = plus }
    refresh()
    return row, control
end

-- `indent` steps the row in from the control it hangs under, marking it as a
-- sub-setting of that control rather than one more entry in the same column.
local function addColorRow(panel, anchorAbove, label, getRGB, setRGB, onChange, indent)
    local row, lbl = labelledRow(panel, anchorAbove, label, indent)

    local swatch = colorSwatch(row, getRGB, setRGB, onChange)
    swatch:SetPoint("LEFT", lbl, "RIGHT", 6, 0)
    return row, swatch
end

-- ── Chat sub-tab ──────────────────────────────────────────────────
-- One font block for chat text, tab names and the DataText bars. Two of its
-- settings mean "leave it alone" here, because these strings belong to Blizzard:
-- the face "Default", and size 0 — shown as "Auto", which is what keeps
-- Blizzard's per-window chat font size working.
local CHAT_FONT_DEFAULT = addon.Font.New({ font = "Default", size = 0, outline = "NONE" })

local function buildChatSettingsPanel(parent)
    local shell, panel = makeScrollPanel(parent)

    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 14, -14)
    header:SetText("Chat")
    UI.tint(header, C.red)

    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    desc:SetWidth(500); desc:SetJustifyH("LEFT")
    desc:SetText("Small tweaks to Blizzard's chat. Blizzard still handles chat layout, docking and tabs.")
    UI.tint(desc, C.textGrey)

    -- Parent switch for the whole Chat module — Panels, DataTexts and Alerts all
    -- check addon.Chat.isEnabled(), so this overrides their own enable checkboxes
    -- rather than sitting alongside them.
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
        UI.RefreshTabDots()
    end

    -- One font block for chat text, tab names and the DataText bars, and the one
    -- place in the addon where part of the block is left out: a chat frame lays
    -- out its own lines, so there is nothing to nudge, and every line already
    -- carries its channel's colour, which the tab colours below sit alongside.
    local fontBox = buildFontOptions(panel, {
        defaults   = CHAT_FONT_DEFAULT,
        lead       = "Default",
        autoSize   = true,
        skip       = { x = true, y = true, color = true },
        labelWidth = 110,
        get        = function() return addon.Font.Adopt(getChatData(), "font") end,
        onChange   = function()
            if addon.Chat      then addon.Chat.refresh() end
            if addon.DataTexts then addon.DataTexts.refresh() end
        end,
        fontDesc = "Font for chat message text, tab names and the DataText bars. "
            .. "\"Default\" keeps whatever face each of them already had.",
    })
    fontBox:SetPoint("TOPLEFT", enableCB, "BOTTOMLEFT", 0, -12)

    local buttonsCB = createCheckbox(panel, "Hide chat buttons", 300,
        "Hides the scroll arrows, chat menu button and the voice / text-to-speech buttons around the chat. Unticking needs a /reload to bring them back.")
    buttonsCB:SetPoint("TOPLEFT", fontBox, "BOTTOMLEFT", 0, -10)
    buttonsCB.OnChange = function(_, checked)
        getChatData().hideButtons = checked
        if addon.Chat then addon.Chat.refresh() end
    end

    local moveCB = createCheckbox(panel, "Allow moving chat anywhere", 300,
        "Removes the margin Blizzard keeps around the chat, which otherwise stops it being dragged to the screen edges. Drag the chat by its tab as usual.")
    moveCB:SetPoint("TOPLEFT", buttonsCB, "BOTTOMLEFT", 0, -6)
    moveCB.OnChange = function(_, checked)
        getChatData().freeMovement = checked
        if addon.Chat then addon.Chat.refresh() end
    end

    local fadeCB = createCheckbox(panel, "Remove chat hover fade", 320,
        "Stops the chat background fading in when you mouse over it. Unticking needs a /reload.")
    fadeCB:SetPoint("TOPLEFT", moveCB, "BOTTOMLEFT", 0, -6)
    fadeCB.OnChange = function(_, checked)
        getChatData().noHoverFade = checked
        if addon.Chat then addon.Chat.refresh() end
    end

    local textFadeCB = createCheckbox(panel, "Keep chat text visible", 320,
        "Stops chat messages fading out after a couple of minutes of nothing happening, so the backlog stays readable without scrolling or hovering.")
    textFadeCB:SetPoint("TOPLEFT", fadeCB, "BOTTOMLEFT", 0, -6)
    textFadeCB.OnChange = function(_, checked)
        getChatData().noTextFade = checked
        if addon.Chat then addon.Chat.refresh() end
    end

    local tabsCB = createCheckbox(panel, "Flat, always-visible chat tabs", 320,
        "Removes the raised tab graphics and the border that lights up on hover, and keeps every tab name fully legible instead of fading out. Unticking needs a /reload.")
    tabsCB:SetPoint("TOPLEFT", textFadeCB, "BOTTOMLEFT", 0, -6)
    tabsCB.OnChange = function(_, checked)
        getChatData().flatTabs = checked
        if addon.Chat then addon.Chat.refresh() end
    end

    local function onTabColorChange()
        if addon.Chat then addon.Chat.refresh() end
    end

    local tabColorRow, tabSwatch = addColorRow(panel, tabsCB, "Tab name color:",
        function()
            local c = getChatData().tabColor or { 0.75, 0.75, 0.80 }
            return c[1], c[2], c[3]
        end,
        function(r, g, b) getChatData().tabColor = { r, g, b } end, onTabColorChange, 20)

    local tabSelColorRow, tabSelSwatch = addColorRow(panel, tabColorRow, "Selected tab color:",
        function()
            local c = getChatData().tabSelectedColor or { 1, 1, 1 }
            return c[1], c[2], c[3]
        end,
        function(r, g, b) getChatData().tabSelectedColor = { r, g, b } end, onTabColorChange)

    local editBoxCB = createCheckbox(panel, "Skin the chat edit box", 300,
        "Replaces the box you type in with a flat themed one, its border tinted by the channel you're talking in, plus a remaining-character count. Unticking needs a /reload.")
    -- -20 steps back out of the indent the two colour rows carry, so this lines
    -- up with the checkboxes above rather than with the sub-settings.
    editBoxCB:SetPoint("TOPLEFT", tabSelColorRow, "BOTTOMLEFT", -20, -12)
    editBoxCB.OnChange = function(_, checked)
        getChatData().skinEditBox = checked
        if addon.Chat then addon.Chat.refresh() end
    end

    -- Blizzard's chatStyle CVar rather than a setting of our own. It's stored
    -- per WoW account instead of in the profile, so it's the usual explanation
    -- for the edit box behaving differently on two accounts sharing a profile.
    local chatStyleRow = CreateFrame("Frame", nil, panel)
    chatStyleRow:SetSize(420, 24)
    chatStyleRow:SetPoint("TOPLEFT", editBoxCB, "BOTTOMLEFT", 0, -12)

    local chatStyleLbl = chatStyleRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    chatStyleLbl:SetPoint("LEFT", 0, 0); chatStyleLbl:SetWidth(130); chatStyleLbl:SetJustifyH("LEFT")
    chatStyleLbl:SetText("Edit box behaviour:"); UI.tint(chatStyleLbl, C.textGrey)

    local CHAT_STYLES = {
        { value = "classic", label = "Classic" },
        { value = "im",      label = "Instant Messenger" },
    }
    local chatStyleDD = createDropdown(chatStyleRow, 170, CHAT_STYLES,
        function() return getChatData().chatStyle or "classic" end,
        function(v) getChatData().chatStyle = v end,
        function() if addon.Chat then addon.Chat.refresh() end end,
        "Edit box behaviour",
        "Classic opens the edit box when you press Enter and hides it again once you're done. Instant Messenger leaves it on screen permanently. This is Blizzard's own chatStyle option (Interface > Social), which is saved per WoW account and not in your profile — if the edit box is stuck visible on one character but not another, this is why.")
    chatStyleDD:SetPoint("LEFT", chatStyleLbl, "RIGHT", 6, 0)

    -- Message decorations.
    local msgHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    msgHeader:SetPoint("TOPLEFT", chatStyleRow, "BOTTOMLEFT", 0, -18)
    msgHeader:SetText("Messages")
    UI.tint(msgHeader, C.red)

    local arrowCB = createCheckbox(panel, "Copy arrow on each message", 320,
        "Puts a small white arrow at the start of each line. Clicking it drops that line's text into the edit box, where you can read or copy it. Only affects messages printed from then on.")
    arrowCB:SetPoint("TOPLEFT", msgHeader, "BOTTOMLEFT", 0, -8)
    arrowCB.OnChange = function(_, checked)
        getChatData().copyArrow = checked
        if addon.Chat then addon.Chat.refresh() end
    end

    local copyBtnCB = createCheckbox(panel, "Copy button on the chat", 320,
        "Adds a button to the chat's top-right that opens a window with the recent chat as selectable, copy-pasteable text.")
    copyBtnCB:SetPoint("TOPLEFT", arrowCB, "BOTTOMLEFT", 0, -6)
    copyBtnCB.OnChange = function(_, checked)
        getChatData().copyButton = checked
        if addon.Chat then addon.Chat.refresh() end
    end

    local bottomBtnCB = createCheckbox(panel, "Jump-to-newest button on the chat", 320,
        "Sits just below the copy button and scrolls a scrolled-back chat frame straight back to the newest message. Blizzard's own version of this lives in the button column that \"Hide chat buttons\" removes.")
    bottomBtnCB:SetPoint("TOPLEFT", copyBtnCB, "BOTTOMLEFT", 0, -6)
    bottomBtnCB.OnChange = function(_, checked)
        getChatData().scrollBottomButton = checked
        if addon.Chat then addon.Chat.refresh() end
    end

    local linkifyCB = createCheckbox(panel, "Detect links in messages", 320,
        "Outlines any http(s) link as [link] and colours it. Clicking it drops the plain URL into the edit box, where you can read or copy it. Only affects messages printed from then on.")
    linkifyCB:SetPoint("TOPLEFT", bottomBtnCB, "BOTTOMLEFT", 0, -6)
    linkifyCB.OnChange = function(_, checked)
        getChatData().linkifyURLs = checked
        if addon.Chat then addon.Chat.refresh() end
    end

    local stampCB = createCheckbox(panel, "Show timestamps", 320,
        "Prints the time in front of each message. The copy arrow, when on, always sits to the left of the timestamp. Copying a line leaves the timestamp out.")
    stampCB:SetPoint("TOPLEFT", linkifyCB, "BOTTOMLEFT", 0, -6)
    stampCB.OnChange = function(_, checked)
        getChatData().timestamps = checked
        if addon.Chat then addon.Chat.refresh() end
    end

    local stampRow = CreateFrame("Frame", nil, panel)
    stampRow:SetSize(320, 22)
    stampRow:SetPoint("TOPLEFT", stampCB, "BOTTOMLEFT", 20, -8)

    local stampLbl = stampRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    stampLbl:SetPoint("LEFT", 0, 0); stampLbl:SetWidth(130); stampLbl:SetJustifyH("LEFT")
    stampLbl:SetText("Format:"); UI.tint(stampLbl, C.textGrey)

    local STAMP_FORMATS = {
        { value = "%H:%M:%S",    label = "15:25:46" },
        { value = "%H:%M",       label = "15:25" },
        { value = "%I:%M:%S %p", label = "03:25:46 PM" },
        { value = "%I:%M %p",    label = "03:25 PM" },
    }
    local stampDD = createDropdown(stampRow, 150, STAMP_FORMATS,
        function() return getChatData().timestampFormat or "%H:%M:%S" end,
        function(v) getChatData().timestampFormat = v end,
        function() if addon.Chat then addon.Chat.refresh() end end,
        "Timestamp format",
        "Each option is written the way it will appear in front of a message.")
    stampDD:SetPoint("LEFT", stampLbl, "RIGHT", 6, 0)

    local stampWidthCB = createCheckbox(panel, "Equal-width timestamps", 320,
        "Off by default. Pads timestamps with spaces so they always take up the same width, even though some digits render narrower than others in most fonts. Only affects messages printed from then on.")
    stampWidthCB:SetPoint("TOPLEFT", stampRow, "BOTTOMLEFT", 0, -8)
    stampWidthCB.OnChange = function(_, checked)
        getChatData().timestampEqualWidth = checked
        if addon.Chat then addon.Chat.refresh() end
    end

    local stickyCB = createCheckbox(panel, "Sticky chat", 320,
        "Reopens the edit box on whatever channel you last spoke in, instead of dropping back to Say every time.")
    stickyCB:SetPoint("TOPLEFT", stampWidthCB, "BOTTOMLEFT", -20, -12)
    stickyCB.OnChange = function(_, checked)
        getChatData().stickyChat = checked
        if addon.Chat then addon.Chat.refresh() end
    end

    local stickyWCB = createCheckbox(panel, "...including whispers", 320,
        "Off by default on purpose: with whispers sticky, a message meant for Say goes to whoever you last whispered.")
    stickyWCB:SetPoint("TOPLEFT", stickyCB, "BOTTOMLEFT", 0, -6)
    stickyWCB.OnChange = function(_, checked)
        getChatData().stickyWhispers = checked
        if addon.Chat then addon.Chat.refresh() end
    end

    local historyCB = createCheckbox(panel, "Remember sent messages", 320,
        "With the edit box open, Up and Down step through messages you've sent before so you can re-send or edit them. Saved per character, and kept across sessions.")
    historyCB:SetPoint("TOPLEFT", stickyWCB, "BOTTOMLEFT", 0, -12)
    historyCB.OnChange = function(_, checked)
        getChatData().chatHistory = checked
        if addon.Chat then addon.Chat.refresh() end
    end

    local historyRow, historyStepper = addStepperRow(panel, historyCB, "Messages kept:", 5, 100,
        function() return getChatData().historySize or 30 end,
        function(v) getChatData().historySize = v end,
        function() if addon.Chat then addon.Chat.refresh() end end, nil, 20)

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
    UI.tint(styleHeader, C.red)

    local heightRow, heightStepper = addStepperRow(panel, styleHeader, "Height:", 14, 60,
        function() return style().height or 24 end,
        function(v) style().height = v end, onStyleChange, "px")

    local borderRow, borderStepper = addStepperRow(panel, heightRow, "Border thickness:", 0, 10,
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

    local channelCB = createCheckbox(panel, "Colour border by channel", 300,
        "Tints the border to match what you're typing in (Say, Party, Guild...). Turn it off to use the fixed border colour below instead.")
    channelCB:SetPoint("TOPLEFT", bgOpRow, "BOTTOMLEFT", 0, -8)
    channelCB.OnChange = function(_, checked)
        style().useChannelColor = checked
        onStyleChange()
    end

    local bdColorRow, bdSwatch = addColorRow(panel, channelCB, "Border color:",
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
        fontBox:Refresh()
        buttonsCB:SetChecked(d.hideButtons ~= false)
        moveCB:SetChecked(d.freeMovement ~= false)
        fadeCB:SetChecked(d.noHoverFade ~= false)
        textFadeCB:SetChecked(d.noTextFade ~= false)
        tabsCB:SetChecked(d.flatTabs ~= false)
        tabSwatch.Refresh(); tabSelSwatch.Refresh()
        editBoxCB:SetChecked(d.skinEditBox ~= false)
        chatStyleDD:Refresh()

        arrowCB:SetChecked(d.copyArrow ~= false)
        copyBtnCB:SetChecked(d.copyButton ~= false)
        bottomBtnCB:SetChecked(d.scrollBottomButton ~= false)
        linkifyCB:SetChecked(d.linkifyURLs ~= false)
        stampCB:SetChecked(d.timestamps or false)
        stampDD:Refresh()
        stampWidthCB:SetChecked(d.timestampEqualWidth or false)
        stickyCB:SetChecked(d.stickyChat ~= false)
        stickyWCB:SetChecked(d.stickyWhispers or false)
        historyCB:SetChecked(d.chatHistory ~= false)
        historyStepper.Refresh()

        channelCB:SetChecked(style().useChannelColor ~= false)
        heightStepper.Refresh(); borderStepper.Refresh()
        bgSwatch.Refresh(); bgOpStepper.Refresh()
        bdSwatch.Refresh(); bdOpStepper.Refresh()
    end

    shell:HookScript("OnShow", refreshPanel)
    return shell
end

-- ── Panels sub-tab ──────────────────────────────────────────────────────────
-- Purely decorative backdrops behind the chat. They move, resize and reparent
-- nothing Blizzard owns — see ChatPanels.lua for why that separation matters.

-- The dock dropdown's options are "Name (#id)" strings — both the id AND the
-- name are shown because bar names aren't guaranteed unique, but the id (the
-- actual stored value) alone would be meaningless to pick from.
local function barDockOptions()
    local list = { "None" }
    if addon.DataTexts then
        for id, cfg in pairs(addon.DataTexts.listBars()) do
            list[#list + 1] = string.format("%s (#%s)", cfg.name or ("Bar " .. id), id)
        end
    end
    return list
end

local function barIDFromOption(opt)
    return opt and opt:match("%(#(%S+)%)$")
end

local function barOptionForID(id)
    local cfg = id and addon.DataTexts and addon.DataTexts.listBars()[id]
    return cfg and string.format("%s (#%s)", cfg.name or ("Bar " .. id), id) or "None"
end

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
    UI.tint(header, C.red)

    local enableCB = createCheckbox(panel, "Enable this panel", 260)
    enableCB:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -8)
    enableCB.OnChange = function(_, checked)
        get().enabled = checked
        onChange()
        -- Snap the chat onto a panel the moment it's switched on, rather than
        -- leaving the user to drag it there themselves.
        if checked and addon.ChatDock then addon.ChatDock.dockDefaultChat(index) end
    end

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

    -- Auto-dock to a DataText bar: the panel's position tracks the bar
    -- directly (see ChatPanels.lua's dockBarFrame), offset by the two
    -- steppers below.
    local dockHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dockHeader:SetPoint("TOPLEFT", bdOpRow, "BOTTOMLEFT", 0, -14)
    dockHeader:SetText("Dock to bar:")
    UI.tint(dockHeader, C.textGrey)

    local dockDD = createScrollDropdown(panel, 200, barDockOptions, function(opt)
        get().dockBarID = barIDFromOption(opt)
        onChange()
    end, {
        tipTitle = "Dock to bar",
        tipBody  = "Docked, the panel follows that bar instead of its own saved position.",
    })
    dockDD:SetPoint("LEFT", dockHeader, "RIGHT", 6, 0)

    local offXRow, offXStepper = addStepperRow(panel, dockHeader, "X offset:", -500, 500,
        function() return get().dockOffsetX or 0 end,
        function(v) get().dockOffsetX = v end, onChange, "px")

    local offYRow, offYStepper = addStepperRow(panel, offXRow, "Y offset:", -500, 500,
        function() return get().dockOffsetY or 0 end,
        function(v) get().dockOffsetY = v end, onChange, "px")

    local matchWidthCB = createCheckbox(panel, "Match bar width", 260)
    matchWidthCB:SetPoint("TOPLEFT", offYRow, "BOTTOMLEFT", 0, -8)
    matchWidthCB.OnChange = function(_, checked)
        get().dockMatchWidth = checked
        onChange()
    end

    local function refresh()
        enableCB:SetChecked(get().enabled or false)
        widthStepper.Refresh(); heightStepper.Refresh(); borderStepper.Refresh()
        bgSwatch.Refresh(); bgOpStepper.Refresh()
        bdSwatch.Refresh(); bdOpStepper.Refresh()
        dockDD:setValue(barOptionForID(get().dockBarID))
        offXStepper.Refresh(); offYStepper.Refresh()
        matchWidthCB:SetChecked(get().dockMatchWidth or false)
    end

    return matchWidthCB, refresh
end

local function buildPanelsPanel(parent)
    local shell, panel = makeScrollPanel(parent)

    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 14, -14)
    header:SetText("Chat Panels")
    UI.tint(header, C.red)

    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    desc:SetWidth(500); desc:SetJustifyH("LEFT")
    desc:SetText("Background panels to sit behind your chat. Drag a chat window by its tab and drop it onto a panel to dock it — the chat resizes to fit. Drag it off again to undock.")
    UI.tint(desc, C.textGrey)

    local lockCB = createCheckbox(panel, "Lock chat position", 300,
        "Locked, the chat stays exactly where it is and can't be dragged. Unlock it to move it around or drop it onto a panel.")
    lockCB:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -10)
    lockCB.OnChange = function(_, checked)
        if addon.ChatDock then addon.ChatDock.setLocked(checked) end
    end

    local undockBtn = flatButton(panel, "Undock all", 110, 22)
    undockBtn:SetPoint("TOPLEFT", lockCB, "BOTTOMLEFT", 0, -10)
    undockBtn:SetScript("OnClick", function()
        if addon.ChatDock then addon.ChatDock.undockAll() end
    end)
    attachTooltip(undockBtn, "Undock all",
        "Releases every docked chat window. They stay where they are — they just stop following their panel.")

    -- Both sections hang off the same top anchor; the x-offset on the second
    -- puts it in a column beside the first rather than below it.
    local _, refresh1 = buildPanelSection(panel, undockBtn, 1, 0)
    local _, refresh2 = buildPanelSection(panel, undockBtn, 2, 350)

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
    UI.tint(title, C.red)
    panel.title = title

    local closeBtn = CreateFrame("Button", nil, panel)
    closeBtn:SetSize(24, 24)
    closeBtn:SetPoint("TOPRIGHT", -6, -6)
    local closeLbl = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    closeLbl:SetPoint("CENTER"); closeLbl:SetText("X"); UI.tint(closeLbl, C.red)
    closeBtn:SetScript("OnClick", function() panel:Hide() end)

    local labelLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    labelLbl:SetPoint("TOPLEFT", 16, -46)
    labelLbl:SetText("Label:")
    UI.tint(labelLbl, C.textWhite)

    local labelBoxWrap = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    labelBoxWrap:SetSize(280, 22)
    labelBoxWrap:SetPoint("LEFT", labelLbl, "RIGHT", 8, 0)
    applyBackdrop(labelBoxWrap, 1, C.panelDark, C.tabBorder)
    local labelBox = CreateFrame("EditBox", nil, labelBoxWrap)
    labelBox:SetSize(266, 18); labelBox:SetPoint("CENTER")
    labelBox:SetAutoFocus(false); labelBox:SetMaxLetters(40)
    labelBox:SetFontObject("GameFontNormal"); UI.tint(labelBox, C.textWhite)
    panel.labelBox = labelBox

    local codeLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    codeLbl:SetPoint("TOPLEFT", labelLbl, "BOTTOMLEFT", 0, -16)
    codeLbl:SetText('Code (Lua, must return a string/number — e.g. return GetFramerate())')
    UI.tint(codeLbl, C.textWhite)

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
    UI.tint(codeBox, C.textWhite)
    codeScroll:SetScrollChild(codeBox)
    panel.codeBox = codeBox

    local pollLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pollLbl:SetPoint("TOPLEFT", codeBoxWrap, "BOTTOMLEFT", 0, -12)
    pollLbl:SetText("Refresh every:")
    UI.tint(pollLbl, C.textGrey)

    local pollStepper = buildStepper(panel, {
        min = 0.5, max = 60, step = 0.5,
        format = function(v) return string.format("%.1f", v) end,
        get = function() return panel._pollValue or 2 end,
        set = function(v) panel._pollValue = v end,
    })
    pollStepper:SetPoint("LEFT", pollLbl, "RIGHT", 8, 0)
    local pollSuffix = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pollSuffix:SetPoint("LEFT", pollStepper.plus, "RIGHT", 4, 0)
    pollSuffix:SetText("s"); UI.tint(pollSuffix, C.textDim)
    panel.pollStepper = pollStepper

    local errText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    errText:SetPoint("TOPLEFT", pollLbl, "BOTTOMLEFT", 0, -10)
    errText:SetWidth(388); errText:SetJustifyH("LEFT")
    UI.tint(errText, C.red)
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
        local fn, err = addon.DataTexts.compileCode(code, "DataText:" .. label)
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
-- Bar-centric: pick or create a bar on the left, configure its look and contents
-- on the right. Bars are positioned through the addon's Edit Mode.
local function buildDataTextsPanel(parent)
    -- Header/enable up top, then an inner left sidebar (DataText Bars / Labels) with
    -- content to its right, same as Trinkets → General.
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
    UI.tint(header, C.red)

    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    desc:SetWidth(560); desc:SetJustifyH("LEFT")
    desc:SetText("Create as many bars as you like, put whichever stats you want on each, and drag them anywhere via Edit Mode.")
    UI.tint(desc, C.textGrey)

    local enableCB = createCheckbox(panel, "Enable DataText bars", 260)
    enableCB:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -10)
    enableCB.OnChange = function(_, checked)
        getDTData().enabled = checked
        if addon.DataTexts then addon.DataTexts.refresh() end
    end

    -- Every scrollable content area, so re-opening a tab can force a re-fit: a
    -- makeScrollPanel shown while an ancestor was hidden won't re-fire OnShow when
    -- the ancestor reappears, leaving its scroll range stale. Hide+Show refits.
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
            UI.tintBg(btn, C.tabActive)
            UI.tintBorder(btn, C.tabActiveBdr)
            UI.tint(btn.text, C.textWhite)
        else
            UI.tintBg(btn, C.tabIdle)
            UI.tintBorder(btn, C.tabBorder)
            UI.tint(btn.text, C.textGrey)
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
    UI.tint(cfgTitle, C.red)

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
    nameLbl:SetText("Bar name:"); UI.tint(nameLbl, C.textGrey)

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
    UI.tint(nameBox, C.textWhite)
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

    local enableBarCB = createCheckbox(createInner, "Enable this bar", 300)
    enableBarCB:SetPoint("TOPLEFT", nameRow, "BOTTOMLEFT", 0, -10)
    enableBarCB.OnChange = function(_, checked)
        local c = getSelBar()
        if not c then return end
        c.enabled = checked
        onBarChange()
    end

    local heightRow, heightStepper = addStepperRow(createInner, enableBarCB, "Bar height:", 16, 60,
        function() local c = getSelBar(); return c and c.height or 24 end,
        function(v) local c = getSelBar(); if c then c.height = v end end, onBarChange, "px")

    local paddingRow, paddingStepper = addStepperRow(createInner, heightRow, "Side padding:", 0, 200,
        function() local c = getSelBar(); return c and c.padding or 6 end,
        function(v) local c = getSelBar(); if c then c.padding = v end end, onBarChange, "px", nil,
        "Inset from each end of the bar. The gap between datatexts is worked out from what's left, spread evenly — so raising this draws them together.")

    local fixedWCB = createCheckbox(createInner, "Fixed width", 300,
        "Keeps the bar at a set width instead of growing to fit. Datatexts that don't fit are shortened rather than dropped, so nothing disappears without warning.")
    fixedWCB:SetPoint("TOPLEFT", paddingRow, "BOTTOMLEFT", 0, -10)
    fixedWCB.OnChange = function(_, checked)
        local c = getSelBar()
        if not c then return end
        c.fixedWidth = checked
        onBarChange()
    end

    local fixedWAnchor = CreateFrame("Frame", nil, createInner)
    fixedWAnchor:SetSize(1, 1)
    fixedWAnchor:SetPoint("TOPLEFT", fixedWCB, "BOTTOMLEFT", 0, -4)

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
                UI.tintBg(row, C.tabActive)
                UI.tintBorder(row, C.tabActiveBdr)
                UI.tint(row.text, C.textWhite)
            else
                UI.tintBg(row, C.tabIdle)
                UI.tintBorder(row, C.tabBorder)
                UI.tint(row.text, C.textGrey)
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
    UI.tint(textsHeader, C.red)

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
    UI.tint(orderHeader, C.red)

    local orderHint = statsInner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    orderHint:SetPoint("TOPLEFT", orderHeader, "BOTTOMLEFT", 0, -4)
    orderHint:SetWidth(460); orderHint:SetJustifyH("LEFT")
    orderHint:SetText("Left to right across the bar. Use the arrows to move a stat.")
    UI.tint(orderHint, C.textDim)

    local orderRows = {}
    local ORDER_ROW_H = 24

    local function makeOrderRow()
        local row = CreateFrame("Frame", nil, statsInner, "BackdropTemplate")
        row:SetSize(300, 22)
        applyBackdrop(row, 1, C.panelDeep, C.tabBorder)

        local idx = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        idx:SetPoint("LEFT", 8, 0); idx:SetWidth(22); idx:SetJustifyH("LEFT")
        UI.tint(idx, C.textDim)
        row.idx = idx

        local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        name:SetPoint("LEFT", idx, "RIGHT", 2, 0)
        UI.tint(name, C.textWhite)
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
        cfgTitle, moveBtn, delBtn, nameRow, enableBarCB, heightRow, paddingRow,
        fixedWCB, widthRow, minWRow, borderRow,
        bgColorRow, bgOpRow, bdColorRow, bdOpRow,
        textsHeader, orderHeader, orderHint,
    }

    -- ══ Labels › General (stat value color) ═══════════════════════════════════
    local valueColorHeader = genInner:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    valueColorHeader:SetPoint("TOPLEFT", 14, -14)
    valueColorHeader:SetText("Stat Value Color")
    UI.tint(valueColorHeader, C.red)

    local valueColorRow, valueColorSwatch = addColorRow(genInner, valueColorHeader, "Value color:",
        function()
            local c = getDTData().valueColor or { 1.00, 0.15, 0.15 }
            return c[1], c[2], c[3]
        end,
        function(r, g, b) getDTData().valueColor = { r, g, b } end,
        function() if addon.DataTexts then addon.DataTexts.refresh() end end)
    attachTooltip(valueColorSwatch, "Value color",
        "Colours just the value on every stat, never its label - except FPS/Latency, Durability and Gold, which already colour themselves.")

    -- ══ Labels › General (text prefixes) ══════════════════════════════════════
    local prefixHeader = genInner:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    prefixHeader:SetPoint("TOPLEFT", valueColorRow, "BOTTOMLEFT", 0, -18)
    prefixHeader:SetText("Labels")
    UI.tint(prefixHeader, C.red)

    local prefixHint = genInner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    prefixHint:SetPoint("TOPLEFT", prefixHeader, "BOTTOMLEFT", 0, -4)
    prefixHint:SetWidth(460); prefixHint:SetJustifyH("LEFT")
    prefixHint:SetText("The text shown in front of each value — change \"Stamina: \" to \"Stam: \", or clear it to show the number alone. Trailing spaces are kept.")
    UI.tint(prefixHint, C.textGrey)

    local prefixRows = {}
    local PREFIX_ROW_H = 26

    local function makePrefixRow()
        local row = CreateFrame("Frame", nil, genInner)
        row:SetSize(430, 24)

        local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        name:SetPoint("LEFT", 0, 0); name:SetWidth(130); name:SetJustifyH("LEFT")
        UI.tint(name, C.textGrey)
        row.name = name

        local wrap = CreateFrame("Frame", nil, row, "BackdropTemplate")
        wrap:SetSize(160, 22)
        wrap:SetPoint("LEFT", name, "RIGHT", 6, 0)
        applyBackdrop(wrap, 1, C.panelDark, C.tabBorder)
        wrap:SetScript("OnEnter", function(sf) UI.tintBorder(sf, C.red) end)
        wrap:SetScript("OnLeave", function(sf) UI.tintBorder(sf, C.tabBorder) end)

        local box = CreateFrame("EditBox", nil, wrap)
        box:SetSize(148, 16); box:SetPoint("CENTER")
        box:SetAutoFocus(false); box:SetMaxLetters(24)
        box:SetFontObject("GameFontNormalSmall")
        UI.tint(box, C.textWhite)
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
    UI.tint(goldHeader, C.red)

    local goldHint = blInner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    goldHint:SetPoint("TOPLEFT", goldHeader, "BOTTOMLEFT", 0, -4)
    goldHint:SetWidth(460); goldHint:SetJustifyH("LEFT")
    goldHint:SetText("Hovering the Gold datatext lists every character it has seen, and their total. Characters listed here are left out of both the list and the total. Either \"Name\" or \"Name - Realm\" works.")
    UI.tint(goldHint, C.textGrey)

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
    UI.tint(blBox, C.textWhite)
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
        UI.tint(name, C.textWhite)
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
    UI.tint(customHeader, C.red)

    local customDesc = custInner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    customDesc:SetPoint("TOPLEFT", customHeader, "BOTTOMLEFT", 0, -4)
    customDesc:SetWidth(560); customDesc:SetJustifyH("LEFT")
    customDesc:SetText("Write a small Lua snippet that returns the text to display, then tick it on a bar's Stats list. Runs only on your own client.")
    UI.tint(customDesc, C.textGrey)

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
        UI.tint(nameFS, C.textWhite)
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
            enableBarCB:SetChecked(cfg.enabled ~= false)
            fixedWCB:SetChecked(cfg.fixedWidth or false)
            heightStepper.Refresh(); paddingStepper.Refresh()
            widthStepper.Refresh(); minWStepper.Refresh(); borderStepper.Refresh()
            bgSwatch.Refresh(); bgOpStepper.Refresh()
            bdSwatch.Refresh(); bdOpStepper.Refresh()
            refreshTextChecks()
        end
        refreshOrderList()
        valueColorSwatch.Refresh()
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

-- ── Shared bits for the Chat Windows / Channels sub-tabs ────────────────────
-- Both tabs are about pushing one character's chat setup onto every other, so
-- they share the same "act now" affordances: a status line under the buttons and
-- a grid of tick boxes.

-- A themed single-line text box. The blacklist row below does this inline, but
-- these two tabs need five of them, so it's worth a factory.
local function makeEditBox(parent, w, maxLetters)
    local wrap = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    wrap:SetSize(w, 22)
    applyBackdrop(wrap, 1, C.panelDark, C.tabBorder)
    wrap:SetScript("OnEnter", function(s) UI.tintBorder(s, C.red) end)
    wrap:SetScript("OnLeave", function(s) UI.tintBorder(s, C.tabBorder) end)

    local box = CreateFrame("EditBox", nil, wrap)
    box:SetSize(w - 12, 16); box:SetPoint("CENTER")
    box:SetAutoFocus(false); box:SetMaxLetters(maxLetters or 48)
    box:SetFontObject("GameFontNormalSmall")
    box:SetTextInsets(4, 4, 0, 0)
    UI.tint(box, C.textWhite)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    wrap.box = box
    return wrap, box
end

-- Re-fitting the scroll child twice: the grids below resize during a refresh, and
-- a frame's GetBottom() can still report its old position on the frame that
-- changed, which measures the panel short. The deferred pass reads the settled
-- layout — the same two-pass shape makeScrollPanel uses for its own OnShow.
local function deferredRefit(refit)
    return function()
        refit()
        C_Timer.After(0, refit)
    end
end

-- A pooled grid of checkboxes laid out in columns. The item list is handed in on
-- every refresh rather than at build time, because the channel grids are driven
-- by whatever channels exist right now, which changes while the panel is open.
--
-- The grid resizes itself to the rows it ended up with, so anything anchored
-- below it moves with the content instead of overlapping or leaving a hole.
local function makeCheckGrid(parent, cols, colW, rowH)
    local grid = CreateFrame("Frame", nil, parent)
    grid:SetSize(cols * colW, 1)

    local pool = {}
    -- items = { { key, label, desc }, … }; isChecked(key) -> boolean.
    function grid.setItems(items, isChecked)
        while #pool < #items do
            local cb = createCheckbox(grid, "", colW - 6)
            cb.text:SetFontObject("GameFontNormalSmall")
            pool[#pool + 1] = cb
        end

        for i, item in ipairs(items) do
            local cb  = pool[i]
            local col = (i - 1) % cols
            local row = math.floor((i - 1) / cols)
            cb:ClearAllPoints()
            cb:SetPoint("TOPLEFT", grid, "TOPLEFT", col * colW, -row * rowH)
            cb.text:SetText(item.label)
            cb:SetChecked(isChecked(item.key) and true or false)
            cb.OnChange = function(_, checked)
                if grid.OnToggle then grid.OnToggle(item.key, checked) end
            end
            cb:Show()
        end
        for i = #items + 1, #pool do pool[i]:Hide() end

        grid:SetHeight(math.max(1, math.ceil(#items / cols) * rowH))
    end

    return grid
end

-- ── Chat Windows sub-tab ────────────────────────────────────────────────────
local function buildChatWindowsPanel(parent)
    local shell, panel, rawRefit = makeScrollPanel(parent)
    local refit = deferredRefit(rawRefit)

    local CW = function() return addon.ChatWindows end
    local selected = 1

    local function windows()
        local mod = CW()
        return (mod and mod.list()) or {}
    end
    local function selectedCfg() return windows()[selected] end

    local refreshAll   -- forward declaration; the row handlers call it

    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 14, -14)
    header:SetText("Chat Windows")
    UI.tint(header, C.red)

    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    desc:SetWidth(620); desc:SetJustifyH("LEFT")
    desc:SetText("WoW saves your chat windows per character, so every alt starts with just General and the Combat Log. The list below lives in your profile, and at login each character's tabs are reconciled against it — missing windows created, the rest renamed and refilled — so they all end up with the same tabs showing the same things. Closing windows the list doesn't mention is opt-in below. The first two are WoW's own and can't be removed, only renamed.")
    UI.tint(desc, C.textGrey)

    local enableCB = createCheckbox(panel, "Build these chat windows on login", 320,
        "A few seconds after you log in, this character's tabs are reconciled against the list below: missing windows are created, and the rest are renamed and refilled to match.")
    enableCB:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -12)
    enableCB.OnChange = function(_, checked)
        addon.db.settings.chatWindows = addon.db.settings.chatWindows or {}
        addon.db.settings.chatWindows.enabled = checked
    end

    local closeCB = createCheckbox(panel, "Close windows that aren't on the list", 320,
        "Makes the reconciliation work both ways, so a character with leftover tabs from an older layout ends up matching the list exactly. Off by default, since it's the half that destroys something: leave it off and windows are only ever added. The first two are WoW's own and are never closed, and neither are open whisper tabs.")
    closeCB:SetPoint("TOPLEFT", enableCB, "BOTTOMLEFT", 0, -6)
    closeCB.OnChange = function(_, checked)
        addon.db.settings.chatWindows = addon.db.settings.chatWindows or {}
        addon.db.settings.chatWindows.closeExtra = checked
    end

    local status = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

    local applyBtn = flatButton(panel, "Apply Now", 100, 22)
    applyBtn:SetPoint("TOPLEFT", closeCB, "BOTTOMLEFT", 0, -12)
    attachTooltip(applyBtn, "Apply Now",
        "Runs the same pass that happens at login against this character, without waiting for a reload.")
    applyBtn:SetScript("OnClick", function()
        local mod = CW()
        if not mod then return end
        if not mod.isEnabled() then
            status:SetText("Tick the box above (and \"Enable Chat System\" on the Chat tab) first.")
            return
        end
        local unplaced, closed = mod.apply()
        unplaced, closed = unplaced or 0, closed or 0
        if unplaced > 0 then
            -- WoW allows ten windows and no more; saying so beats a list entry
            -- that silently never appears.
            status:SetText(("Applied — but %d window%s couldn't be created; every chat window slot is in use.")
                :format(unplaced, unplaced == 1 and "" or "s"))
        elseif closed > 0 then
            status:SetText(("Applied — %d window%s closed to match the list.")
                :format(closed, closed == 1 and " was" or "s were"))
        else
            status:SetText("Applied to this character.")
        end
        refreshAll()
    end)

    local captureBtn = flatButton(panel, "Capture This Character", 170, 22)
    captureBtn:SetPoint("LEFT", applyBtn, "RIGHT", 8, 0)
    attachTooltip(captureBtn, "Capture This Character",
        "Replaces the list below with the chat windows this character already has, so a setup you built by hand can be pushed to everyone else. Temporary whisper tabs are skipped.")
    captureBtn:SetScript("OnClick", function()
        local mod = CW()
        if not mod then return end
        UI.showConfirmPopup({
            title       = "Capture Chat Windows",
            message     = "Replace the list below with this character's current chat windows?",
            confirmText = "Capture",
            onConfirm   = function()
                local n = mod.captureCurrent()
                selected = 1
                status:SetText(("Captured %d window%s."):format(n, n == 1 and "" or "s"))
                refreshAll()
            end,
        })
    end)

    status:SetPoint("TOPLEFT", applyBtn, "BOTTOMLEFT", 0, -6)
    status:SetWidth(620); status:SetJustifyH("LEFT")
    UI.tint(status, C.red)

    -- Every edit on this tab lands on the live window as it's made, so nothing
    -- here needs Apply Now. Changes arrive in bursts though — someone ticking six
    -- message types in a row — and each one would otherwise drive a full rewrite
    -- of the window's lists plus a restyle of every chat frame, so a burst is
    -- coalesced into one pass. Pending windows are tracked by index rather than a
    -- single flag: switching window mid-burst must not drop the earlier edit.
    local livePending, liveQueued = {}, false
    local function liveApply()
        local mod = CW()
        if not mod then return end
        if not mod.isEnabled() then
            status:SetText("Saved to the list — tick the box above for changes to reach the chat window.")
            return
        end

        livePending[selected] = true
        if liveQueued then return end
        liveQueued = true
        C_Timer.After(0.25, function()
            liveQueued = false
            local todo = livePending
            livePending = {}
            for index in pairs(todo) do mod.applyOne(index) end

            -- A ticked channel only reaches a window this character has actually
            -- joined. Naming the ones that didn't take beats leaving the box
            -- ticked and the window silent with no explanation.
            local cfg = selectedCfg()
            local wanted = cfg and cfg.channels
            if wanted and #wanted > 0 then
                local live, missing = mod.liveChannels(selected), {}
                for _, name in ipairs(wanted) do
                    if not live[name:lower()] then missing[#missing + 1] = name end
                end
                status:SetText(#missing > 0
                    and ("Not receiving yet: " .. table.concat(missing, ", ")
                         .. " — add them on the Channels tab so this character joins them.")
                    or "")
            end

            -- A toggle can create a window that didn't exist yet, which clears
            -- its "(new)" marker.
            refreshAll()
        end)
    end

    -- ── Window list ─────────────────────────────────────────────────────────
    local newBtn = flatButton(panel, "New Window", 110, 22)
    newBtn:SetPoint("TOPLEFT", status, "BOTTOMLEFT", 0, -10)
    newBtn:SetScript("OnClick", function()
        local mod = CW()
        if not mod then return end
        local index, err = mod.addWindow()
        if not index then status:SetText(err or "") return end
        selected = index

        -- Opened on the spot rather than at the next login: a "New Window" button
        -- that adds a row and nothing else reads as broken.
        if not mod.isEnabled() then
            status:SetText("Added to the list — tick the box above for it to be created in game.")
        elseif not mod.applyOne(index) then
            status:SetText("Added to the list, but every chat window slot is already in use.")
        else
            status:SetText("")
        end
        refreshAll()
    end)

    local listCol = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    listCol:SetPoint("TOPLEFT", newBtn, "BOTTOMLEFT", 0, -8)
    -- Tall enough for all ten windows WoW allows, so the box never has to scroll.
    listCol:SetSize(170, 3 + 10 * 26 + 3)
    applyBackdrop(listCol, 1, C.panelDark)

    local cfgAnchor = CreateFrame("Frame", nil, panel)
    cfgAnchor:SetSize(1, 1)
    cfgAnchor:SetPoint("TOPLEFT", listCol, "TOPRIGHT", 14, 0)

    local listRows = {}
    local function makeListRow()
        local row = createSideTab(listCol, "", 24)
        row.text:SetFontObject("GameFontNormalSmall")
        return row
    end

    -- ── Selected window ─────────────────────────────────────────────────────
    local nameRow = CreateFrame("Frame", nil, panel)
    nameRow:SetSize(420, 24)
    nameRow:SetPoint("TOPLEFT", cfgAnchor, "TOPLEFT", 0, 0)

    local nameLbl = nameRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameLbl:SetPoint("LEFT", 0, 0); nameLbl:SetWidth(90); nameLbl:SetJustifyH("LEFT")
    nameLbl:SetText("Window name:"); UI.tint(nameLbl, C.textGrey)

    local nameWrap, nameBox = makeEditBox(nameRow, 170, 32)
    nameWrap:SetPoint("LEFT", nameLbl, "RIGHT", 6, 0)

    local function commitName()
        local cfg, mod = selectedCfg(), CW()
        if not (cfg and mod) then return end
        local text = (nameBox:GetText() or ""):match("^%s*(.-)%s*$")
        -- An empty box is a mis-edit rather than a request for a nameless tab.
        if text == "" or text == cfg.name then
            nameBox:SetText(cfg.name or "")
            return
        end
        if not mod.renameWindow(selected, text) and not mod.isEnabled() then
            -- Renaming is the one edit here with an immediate, visible effect, so
            -- it's worth saying when the module being off is what swallowed it.
            status:SetText("Renamed on the list — tick the box above for it to reach the chat tab.")
        end
        refreshAll()
    end
    nameBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    nameBox:SetScript("OnEditFocusLost", commitName)

    -- Reordering swaps which window an entry drives, so the two tabs trade names
    -- and contents on the spot. Both have to be pushed to the client, not just
    -- the one that moved.
    local function moveSelected(delta)
        local mod = CW()
        if not (mod and mod.moveWindow(selected, delta)) then return end
        local from, to = selected, selected + delta
        selected = to
        mod.applyOne(to)
        mod.applyOne(from)
        status:SetText("")
        refreshAll()
    end

    local upBtn = flatButton(nameRow, "^", 22, 22, "GameFontNormalSmall")
    upBtn:SetPoint("LEFT", nameWrap, "RIGHT", 8, 0)
    attachTooltip(upBtn, "Move Up",
        "Moves this window one place earlier in the list, swapping it with the one above. The first two are WoW's own and always lead, so nothing moves past them.")
    upBtn:SetScript("OnClick", function() moveSelected(-1) end)

    local downBtn = flatButton(nameRow, "v", 22, 22, "GameFontNormalSmall")
    downBtn:SetPoint("LEFT", upBtn, "RIGHT", 2, 0)
    attachTooltip(downBtn, "Move Down",
        "Moves this window one place later in the list, swapping it with the one below.")
    downBtn:SetScript("OnClick", function() moveSelected(1) end)

    local delBtn = flatButton(nameRow, "Delete", 70, 22)
    delBtn:SetPoint("LEFT", downBtn, "RIGHT", 8, 0)
    attachTooltip(delBtn, "Delete",
        "Drops this window from the list and closes it on this character. Other characters keep theirs until they next log in, and only if \"Close windows that aren't on the list\" is ticked.")
    delBtn:SetScript("OnClick", function()
        local cfg = selectedCfg()
        local mod = CW()
        if not (cfg and mod) then return end
        UI.showConfirmPopup({
            title       = "Delete Window",
            message     = ('Delete "%s"? It closes here straight away.')
                :format(cfg.name or ("Chat " .. selected)),
            confirmText = "Delete",
            onConfirm   = function()
                -- Closed before the entry is dropped: windows pair with entries by
                -- position, so removing it first would close the next one along.
                mod.closeOne(selected)
                mod.removeWindow(selected)
                selected = 1
                status:SetText("")
                refreshAll()
            end,
        })
    end)

    -- Stands in for the whole configuration block on the Combat Log, which has
    -- nothing to configure. A bare panel with the name box and nothing under it
    -- would read as something failing to load.
    local fixedNote = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fixedNote:SetPoint("TOPLEFT", nameRow, "BOTTOMLEFT", 0, -14)
    fixedNote:SetWidth(520); fixedNote:SetJustifyH("LEFT")
    fixedNote:SetText("What the Combat Log shows is driven by WoW's own combat log filters, not by message types or channels, so there's nothing else to set here. Renaming it applies to every character on this profile.")
    UI.tint(fixedNote, C.textGrey)
    fixedNote:Hide()

    local typesHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    typesHeader:SetPoint("TOPLEFT", nameRow, "BOTTOMLEFT", 0, -14)
    typesHeader:SetText("Message Types")
    UI.tint(typesHeader, C.red)

    -- One grid per section, chained top to bottom. Sections come from
    -- ChatWindows.sections(), which has already dropped anything this client
    -- build doesn't know about.
    local sectionUI = {}
    local anchor = typesHeader
    for _, sec in ipairs((CW() and CW().sections()) or {}) do
        local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -8)
        title:SetText(sec.title)
        UI.tint(title, C.textWhite)

        local grid = makeCheckGrid(panel, 3, 160, 20)
        grid:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
        grid.OnToggle = function(key, checked)
            local cfg = selectedCfg()
            if not cfg then return end
            cfg.groups = cfg.groups or {}
            cfg.groups[key] = checked or nil
            liveApply()
        end

        local items = {}
        for _, g in ipairs(sec.groups) do
            items[#items + 1] = { key = g.key, label = g.label }
        end
        sectionUI[#sectionUI + 1] = { grid = grid, items = items }
        anchor = grid
    end

    local chanHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    chanHeader:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -16)
    chanHeader:SetText("Channels")
    UI.tint(chanHeader, C.red)

    local chanDesc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    chanDesc:SetPoint("TOPLEFT", chanHeader, "BOTTOMLEFT", 0, -4)
    chanDesc:SetWidth(480); chanDesc:SetJustifyH("LEFT")
    chanDesc:SetText("Everything on the Channels tab, plus whatever this character is currently in.")
    UI.tint(chanDesc, C.textGrey)

    local chanGrid = makeCheckGrid(panel, 3, 160, 20)
    chanGrid:SetPoint("TOPLEFT", chanDesc, "BOTTOMLEFT", 0, -6)
    chanGrid.OnToggle = function(key, checked)
        local cfg = selectedCfg()
        if not cfg then return end
        cfg.channels = cfg.channels or {}
        for i, name in ipairs(cfg.channels) do
            if name:lower() == key:lower() then
                if not checked then
                    table.remove(cfg.channels, i)
                    liveApply()
                end
                return
            end
        end
        if checked then
            cfg.channels[#cfg.channels + 1] = key
            liveApply()
        end
    end

    -- Every channel we can offer this window: the shared roster, plus anything
    -- already assigned to the window that isn't on it (a capture from another
    -- realm, say), so ticking a box can never silently drop an entry.
    local function channelItems(cfg)
        local items, seen = {}, {}
        local function add(name)
            if name and name ~= "" and not seen[name:lower()] then
                seen[name:lower()] = true
                items[#items + 1] = { key = name, label = name }
            end
        end
        for _, name in ipairs((addon.ChatChannels and addon.ChatChannels.knownChannels()) or {}) do
            add(name)
        end
        for _, name in ipairs((cfg and cfg.channels) or {}) do add(name) end
        return items
    end

    refreshAll = function()
        local d = addon.db and addon.db.settings and addon.db.settings.chatWindows or {}
        enableCB:SetChecked(d.enabled or false)
        closeCB:SetChecked(d.closeExtra or false)

        local list = windows()
        if selected > #list then selected = #list end
        if selected < 1 then selected = 1 end

        -- Entries past the windows this character actually has are ones the login
        -- pass will create, which is the whole point of the tab on a fresh alt.
        local mod = CW()
        local have = (mod and mod.frameCount()) or 0

        while #listRows < #list do listRows[#listRows + 1] = makeListRow() end
        for i, cfg in ipairs(list) do
            local row = listRows[i]
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT",  listCol, "TOPLEFT",   3, -3 - (i - 1) * 26)
            row:SetPoint("TOPRIGHT", listCol, "TOPRIGHT", -3, -3 - (i - 1) * 26)
            -- The index is the window's position in the tab strip, and the one
            -- thing that makes an unnamed row identifiable, so it's always shown.
            row.text:SetText(("%d. %s%s"):format(i, cfg.name or "",
                i <= have and "" or "  |cff888888(new)|r"))
            row.active = (i == selected)
            if row.active then
                UI.tintBg(row, C.tabActive); UI.tintBorder(row, C.tabActiveBdr)
                UI.tint(row.text, C.textWhite)
            else
                UI.tintBg(row, C.tabIdle); UI.tintBorder(row, C.tabBorder)
                UI.tint(row.text, C.textGrey)
            end
            row:SetScript("OnClick", function() selected = i; refreshAll() end)
            row:Show()
        end
        for i = #list + 1, #listRows do listRows[i]:Hide() end

        local cfg = selectedCfg()
        local has = cfg ~= nil
        -- The Combat Log is rename-only: its contents come from WoW's combat log
        -- filters, so message types and channels would be controls that do nothing.
        local renameOnly = has and cfg.combatLog or false
        local configurable = has and not renameOnly

        nameRow:SetShown(has)
        fixedNote:SetShown(renameOnly)
        typesHeader:SetShown(configurable)
        chanHeader:SetShown(configurable)
        chanDesc:SetShown(configurable)

        -- The main window and the Combat Log exist on every character whether or
        -- not this list mentions them, so there's nothing a removal — or a
        -- reorder around them — could mean.
        local movable = has and mod and not mod.isPermanent(selected)
        delBtn:SetShown(movable or false)
        upBtn:SetShown((movable and not mod.isPermanent(selected - 1)) or false)
        downBtn:SetShown((movable and selected < #list) or false)

        if not nameBox:HasFocus() then nameBox:SetText(has and (cfg.name or "") or "") end

        for _, s in ipairs(sectionUI) do
            s.grid:SetShown(configurable)
            if configurable then
                s.grid.setItems(s.items, function(key) return cfg.groups and cfg.groups[key] end)
            end
        end

        chanGrid:SetShown(configurable)
        if configurable then
            local assigned = {}
            for _, name in ipairs(cfg.channels or {}) do assigned[name:lower()] = true end
            chanGrid.setItems(channelItems(cfg), function(key) return assigned[key:lower()] end)
        end

        refit()
    end

    shell:HookScript("OnShow", function()
        status:SetText("")
        refreshAll()
    end)
    return shell
end

-- ── Channels sub-tab ────────────────────────────────────────────────────────
local function buildChannelsPanel(parent)
    local shell, panel, rawRefit = makeScrollPanel(parent)
    local refit = deferredRefit(rawRefit)

    local CC = function() return addon.ChatChannels end
    local refreshAll

    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 14, -14)
    header:SetText("Channels")
    UI.tint(header, C.red)

    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    desc:SetWidth(620); desc:SetJustifyH("LEFT")
    desc:SetText("Channels every character on this profile should be in. They're joined a few seconds after login if you aren't in them already, and land in your main chat window unless the Chat Windows tab assigns them somewhere else. WoW hands out channel numbers (/1, /2, ...) in join order, which differs per character because the client joins your zone channels before we get a look in — so pin the ones you care about to a fixed number below.")
    UI.tint(desc, C.textGrey)

    local enableCB = createCheckbox(panel, "Join these channels on login", 320,
        "Joins anything on the list you aren't already in, then applies the numbers and colours below. Removing an entry never leaves a channel for you — use /leave for that.")
    enableCB:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -12)
    enableCB.OnChange = function(_, checked)
        addon.db.settings.chatChannels = addon.db.settings.chatChannels or {}
        addon.db.settings.chatChannels.enabled = checked
    end

    local autoCB = createCheckbox(panel, "Add channels I join automatically", 320,
        "Watches for channels this character is in that aren't on the list yet and adds them, so joining something once on one character puts it on every other. Channels you Remove by hand stay off the list even while you're still in them.")
    autoCB:SetPoint("TOPLEFT", enableCB, "BOTTOMLEFT", 0, -6)
    autoCB.OnChange = function(_, checked)
        addon.db.settings.chatChannels = addon.db.settings.chatChannels or {}
        addon.db.settings.chatChannels.autoAdd = checked
        -- Ticking it should populate the list there and then, not at next login.
        if checked and addon.ChatChannels then addon.ChatChannels.settle() end
        refreshAll()
    end

    local status = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

    -- ── Add row ─────────────────────────────────────────────────────────────
    local addRow = CreateFrame("Frame", nil, panel)
    addRow:SetSize(600, 24)
    addRow:SetPoint("TOPLEFT", autoCB, "BOTTOMLEFT", 0, -14)

    local nameLbl = addRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameLbl:SetPoint("LEFT", 0, 0); nameLbl:SetWidth(55); nameLbl:SetJustifyH("LEFT")
    nameLbl:SetText("Channel:"); UI.tint(nameLbl, C.textGrey)

    local nameWrap, nameBox = makeEditBox(addRow, 160, 48)
    nameWrap:SetPoint("LEFT", nameLbl, "RIGHT", 6, 0)

    local passLbl = addRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    passLbl:SetPoint("LEFT", nameWrap, "RIGHT", 12, 0)
    passLbl:SetWidth(65); passLbl:SetJustifyH("LEFT")
    passLbl:SetText("Password:"); UI.tint(passLbl, C.textGrey)

    local passWrap, passBox = makeEditBox(addRow, 110, 32)
    passWrap:SetPoint("LEFT", passLbl, "RIGHT", 6, 0)
    attachTooltip(passWrap, "Password", "Only needed for private channels. Leave empty otherwise.")

    local addBtn = flatButton(addRow, "Add", 70, 22)
    addBtn:SetPoint("LEFT", passWrap, "RIGHT", 8, 0)

    local function addEntry()
        local mod = CC()
        if not mod then return end
        local entry, err = mod.addChannel(nameBox:GetText(), passBox:GetText())
        if not entry then
            status:SetText(err or "")
            return
        end
        nameBox:SetText(""); passBox:SetText("")
        status:SetText("")
        -- Joins it straight away when the module is on, so the list and what
        -- you're actually in don't disagree until the next login.
        mod.apply()
        refreshAll()
    end

    addBtn:SetScript("OnClick", addEntry)
    nameBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); addEntry() end)
    passBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); addEntry() end)

    local joinBtn = flatButton(panel, "Join Now", 100, 22)
    joinBtn:SetPoint("TOPLEFT", addRow, "BOTTOMLEFT", 0, -10)
    attachTooltip(joinBtn, "Join Now",
        "Runs the same pass that happens at login against this character, without waiting for a reload.")
    joinBtn:SetScript("OnClick", function()
        local mod = CC()
        if not mod then return end
        if not mod.isEnabled() then
            status:SetText("Tick the box above (and \"Enable Chat System\" on the Chat tab) first.")
            return
        end
        mod.apply()
        status:SetText("Joining — channel numbers and colours settle after a few seconds.")
        refreshAll()
    end)

    local captureBtn = flatButton(panel, "Capture This Character", 170, 22)
    captureBtn:SetPoint("LEFT", joinBtn, "RIGHT", 8, 0)
    attachTooltip(captureBtn, "Capture This Character",
        "Adds every channel this character is currently in that isn't already listed, keeping their present colours. Nothing already on the list is touched, and unlike the automatic pass this also brings back anything you removed by hand.")
    captureBtn:SetScript("OnClick", function()
        local mod = CC()
        if not mod then return end
        local n = mod.captureCurrent()
        status:SetText(n == 0
            and "Nothing new — the list already covers every channel you're in."
            or ("Added %d channel%s."):format(n, n == 1 and "" or "s"))
        refreshAll()
    end)

    status:SetPoint("TOPLEFT", joinBtn, "BOTTOMLEFT", 0, -8)
    status:SetWidth(620); status:SetJustifyH("LEFT")
    UI.tint(status, C.red)

    -- ── Channel rows ────────────────────────────────────────────────────────
    local ROW_H = 24
    local rows = {}

    local function makeRow()
        local row = CreateFrame("Frame", nil, panel, "BackdropTemplate")
        row:SetSize(640, 22)
        applyBackdrop(row, 1, C.panelDeep, C.tabBorder)

        local num = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        num:SetPoint("LEFT", 8, 0); num:SetWidth(22); num:SetJustifyH("LEFT")
        UI.tint(num, C.textDim)
        row.num = num

        local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        name:SetPoint("LEFT", num, "RIGHT", 4, 0); name:SetWidth(150); name:SetJustifyH("LEFT")
        UI.tint(name, C.textWhite)
        row.name = name

        -- The number to pin this channel to. Empty means "wherever join order puts
        -- it", which is the right answer for most channels and the only answer on a
        -- character that isn't in enough channels to reach the pinned slot.
        local slash = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        slash:SetPoint("LEFT", name, "RIGHT", 2, 0); slash:SetWidth(10); slash:SetJustifyH("RIGHT")
        slash:SetText("/"); UI.tint(slash, C.textDim)

        local wantWrap, wantBox = makeEditBox(row, 34, 2)
        wantWrap:SetHeight(18)
        wantBox:SetHeight(14)
        wantWrap:SetPoint("LEFT", slash, "RIGHT", 2, 0)
        attachTooltip(wantWrap, "Channel number",
            "Pins this channel to a fixed number on every character, by reordering the channel list the way WoW's own chat settings do. Leave it empty to let join order decide.")
        row.wantBox = wantBox

        local function storedWant()
            return (row.entry and row.entry.number) and tostring(row.entry.number) or ""
        end
        wantBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        wantBox:SetScript("OnEditFocusLost", function()
            local mod = CC()
            if not (mod and row.index) then return end
            local text = (wantBox:GetText() or ""):match("^%s*(.-)%s*$")
            mod.setNumber(row.index, text ~= "" and text or nil)
            -- Reorder now rather than at the next login, so the result — or the
            -- reason it can't happen yet — is visible immediately.
            mod.settle()
            refreshAll()
        end)
        wantBox:SetScript("OnEscapePressed", function(self)
            -- Restore before dropping focus: OnEditFocusLost commits, so escaping
            -- has to put the stored value back or it would save the half-typed one.
            self:SetText(storedWant())
            self:ClearFocus()
        end)

        -- Where the channel actually sits right now. Without it there's no way to
        -- tell a typo'd name from one that simply hasn't been joined yet, or to see
        -- that a pinned number hasn't taken effect.
        local state = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        state:SetPoint("LEFT", wantWrap, "RIGHT", 8, 0); state:SetWidth(84); state:SetJustifyH("LEFT")
        UI.tint(state, C.textDim)
        row.state = state

        row.colorCB = createCheckbox(row, "Colour", 70)
        row.colorCB:SetPoint("LEFT", state, "RIGHT", 6, 0)
        attachTooltip(row.colorCB, "Colour",
            "Recolours this channel's messages. Left off, WoW's own colour for the channel number is kept.")

        -- Rows are pooled and show a different entry after a move or a delete, so
        -- the swatch reads row.entry live rather than closing over one entry.
        row.swatch = colorSwatch(row,
            function()
                local c = (row.entry and row.entry.color) or { 1, 1, 1 }
                return c[1] or 1, c[2] or 1, c[3] or 1
            end,
            function(r, g, b)
                if row.entry then row.entry.color = { r, g, b } end
            end,
            function()
                -- Picking a colour is the whole intent, so it ticks the box for you
                -- rather than being quietly ignored.
                if row.entry then row.entry.useColor = true end
                row.colorCB:SetChecked(true)
                if addon.ChatChannels then addon.ChatChannels.applyColors() end
            end,
            { size = 16, hover = true })
        row.swatch:SetPoint("LEFT", row.colorCB, "RIGHT", 2, 0)

        row.upBtn = flatButton(row, "^", 20, 18, "GameFontNormalSmall")
        row.upBtn:SetPoint("LEFT", row.swatch, "RIGHT", 10, 0)
        attachTooltip(row.upBtn, "Move Up", "Joined earlier, so it takes a lower channel number.")

        row.downBtn = flatButton(row, "v", 20, 18, "GameFontNormalSmall")
        row.downBtn:SetPoint("LEFT", row.upBtn, "RIGHT", 2, 0)
        attachTooltip(row.downBtn, "Move Down", "Joined later, so it takes a higher channel number.")

        row.delBtn = flatButton(row, "Remove", 70, 18)
        row.delBtn:SetPoint("LEFT", row.downBtn, "RIGHT", 10, 0)

        return row
    end

    local emptyText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    emptyText:SetPoint("TOPLEFT", status, "BOTTOMLEFT", 0, -10)
    emptyText:SetWidth(600); emptyText:SetJustifyH("LEFT")
    emptyText:SetText("No channels listed yet. Type one above, or hit Capture This Character to pull in the ones you're already in.")
    UI.tint(emptyText, C.textDim)

    refreshAll = function()
        local d = addon.db and addon.db.settings and addon.db.settings.chatChannels or {}
        enableCB:SetChecked(d.enabled or false)
        autoCB:SetChecked(d.autoAdd ~= false)

        local mod = CC()
        local list = (mod and mod.list()) or {}
        emptyText:SetShown(#list == 0)

        local reorderable = not mod or mod.canReorder()

        while #rows < #list do rows[#rows + 1] = makeRow() end

        for i, entry in ipairs(list) do
            local row = rows[i]
            row.entry = entry
            row.index = i
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", status, "BOTTOMLEFT", 0, -10 - (i - 1) * ROW_H)
            row.num:SetText(i .. ".")
            row.name:SetText(entry.name or "")

            if not row.wantBox:HasFocus() then
                row.wantBox:SetText(entry.number and tostring(entry.number) or "")
            end
            row.wantBox:EnableMouse(reorderable)
            UI.tint(row.wantBox, reorderable and C.textWhite or C.textDim)

            local id = mod and mod.channelIndex(entry.name) or 0
            -- Calling out a pin that hasn't landed, rather than showing the number
            -- and leaving it looking like it worked.
            local pending = entry.number and id > 0 and id ~= entry.number
            row.state:SetText(id > 0 and ((pending and "now /" or "is /") .. id) or "not joined")
            UI.tint(row.state, (id > 0 and not pending) and C.textGrey or C.textDim)

            row.colorCB:SetChecked(entry.useColor and true or false)
            row.colorCB.OnChange = function(_, checked)
                entry.useColor = checked or nil
                if mod then mod.applyColors() end
            end
            row.swatch.Refresh()

            row.delBtn:SetScript("OnClick", function()
                if not mod then return end
                mod.removeChannel(i)
                refreshAll()
            end)
            row.upBtn:SetScript("OnClick", function()
                if mod and mod.moveChannel(i, -1) then refreshAll() end
            end)
            row.downBtn:SetScript("OnClick", function()
                if mod and mod.moveChannel(i, 1) then refreshAll() end
            end)

            row:Show()
        end
        for i = #list + 1, #rows do rows[i]:Hide() end

        refit()
    end

    shell:HookScript("OnShow", function()
        status:SetText("")
        refreshAll()
    end)
    return shell
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
    UI.tint(header, C.red)

    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    desc:SetWidth(520); desc:SetJustifyH("LEFT")
    desc:SetText("Play a sound when someone whispers you. The list comes from LibSharedMedia, so any sound pack you have installed shows up here automatically.")
    UI.tint(desc, C.textGrey)

    local enableCB = createCheckbox(panel, "Play a sound on whisper", 300)
    enableCB:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -12)
    enableCB.OnChange = function(_, checked) alerts().whisperEnabled = checked end

    local soundRow = CreateFrame("Frame", nil, panel)
    soundRow:SetSize(420, 24)
    soundRow:SetPoint("TOPLEFT", enableCB, "BOTTOMLEFT", 0, -12)

    local soundLbl = soundRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    soundLbl:SetPoint("LEFT", 0, 0); soundLbl:SetWidth(60); soundLbl:SetJustifyH("LEFT")
    soundLbl:SetText("Sound:"); UI.tint(soundLbl, C.textGrey)

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
    UI.tint(status, C.red)
    status:SetText("")

    local _, throttleStepper = addStepperRow(panel, status, "Minimum gap:", 0, 30,
        function() return alerts().throttle or 3 end,
        function(v) alerts().throttle = v end, nil, "sec", nil,
        "How long to wait before the sound can play again. Whispers often arrive in bursts, and without a gap they stack into one long noise.")

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

-- ── Top-level Chat tab (nested sub-tabs) ────────────────────────────────────
local function buildChatShell(parent)
    local panel, _, _, addSubTab = W.makeSubTabPanel(parent)

    addSubTab("chat",      "Chat",          80,  buildChatSettingsPanel)
    addSubTab("windows",   "Chat Windows",  110, buildChatWindowsPanel)
    addSubTab("channels",  "Channels",      90,  buildChannelsPanel)
    addSubTab("panels",    "Panels",        80,  buildPanelsPanel)
    addSubTab("datatexts", "DataTexts",     100, buildDataTextsPanel)
    addSubTab("alerts",    "Alerts",        80,  buildAlertsPanel)

    selectSubTab(panel, "chat")
    return panel
end

UI.RegisterTab({ key = "chat", label = "Chat", order = 70, build = buildChatShell,
    status = function()
        local d = addon.db and addon.db.settings and addon.db.settings.chat
        return d and d.enabled or false
    end })
