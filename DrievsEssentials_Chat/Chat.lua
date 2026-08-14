local addon = _G.DrievEssentials
if not addon then return end

-- Minimal chat tweaks. Deliberately small: nothing here reparents chat frames,
-- takes over Blizzard's dock manager or draws panels behind the chat — each
-- fought FloatingChatFrame and broke tab dragging.

-- The sentinel the font picker offers for "leave whatever face this element
-- already had". Not a LibSharedMedia name, so it can never collide with a real
-- one — which is the whole reason it's spelled out rather than stored as nil.
local FONT_DEFAULT_NAME = "Default"

-- Defaults mirror the author's own long-running setup, so first enabling the
-- module starts dialed-in rather than bare. `enabled` is the exception.
addon.RegisterDefaults("chat", {
    enabled      = false, -- module stays off until the user opts in
    hideButtons  = true, -- scroll arrows, chat menu, voice/text-to-speech
    freeMovement = true, -- allow dragging the chat to the screen edges
    skinEditBox  = true, -- flat themed box with channel-coloured border
    editBox = {
        bgColor         = { 0.039, 0.039, 0.039 },
        bgOpacity       = 100,
        borderColor     = { 0.30, 0.31, 0.42 },
        borderOpacity   = 100,
        borderThickness = 1,
        -- When on, the border follows the channel being typed into and the
        -- fixed borderColor above is ignored.
        useChannelColor = true,
        height          = 24,
    },
    -- Blizzard's chatStyle CVar: "classic" opens the edit box on Enter and closes it
    -- again, "im" leaves it up. Defaulted here because it's NOT profile data — it
    -- lives in the client's per-account config, which is why two accounts on one
    -- profile can disagree.
    chatStyle = "classic",
    copyArrow       = true,        -- clickable arrow at the start of each line
    copyButton      = true,        -- top-right button opening a copyable chat-log window
    -- Blizzard's own version lives in the button frame hideButtons strips off, so
    -- this puts it back somewhere out of the way.
    scrollBottomButton = true,
    linkifyURLs     = true,        -- outline http(s) links and make them clickable-to-copy
    timestamps      = true,        -- [15:25:46] in front of each message
    timestampFormat = "%H:%M:%S",
    -- Proportional fonts don't give every digit the same advance width, so two
    -- timestamps with different digits render a pixel or two apart. Off by default.
    timestampEqualWidth = false,
    noHoverFade     = true,        -- kill the chat's fade-in-on-mouseover
    noTextFade      = true,        -- keep message text on screen instead of fading after inactivity
    flatTabs        = true,        -- flat tabs, names always legible
    stickyChat      = true,        -- reopen the edit box on the last channel used
    stickyWhispers  = true,        -- ...including whispers
    -- Tab name colours. Blizzard's default is NORMAL_FONT_COLOR yellow for both
    -- states, which makes the selected tab hard to pick out at a glance.
    tabColor         = { 0.75, 0.75, 0.80 },
    tabSelectedColor = { 1.00, 1.00, 1.00 },
    chatHistory      = true, -- Up/Down through what you've sent before
    historySize      = 30,
    -- One font for message text, tab names and the DataText bars, as core's
    -- shared font block (Font.lua). Two of its settings mean something slightly
    -- different here, because these strings are not ours to place:
    --   font "Default" — leave whatever face the element already had
    --   size 0         — leave whatever size it already had, which is what keeps
    --                    Blizzard's per-window chat font size working
    -- The X/Y offsets and the text colour are left out of the panel entirely: a
    -- chat frame lays out its own lines, and each line already carries its
    -- channel's colour. See ChatUI.lua.
    font = addon.Font.New({ font = "Expressway", size = 0, outline = "NONE" }),
})

-- The face used to be stored on its own as an LSM name, or as `false` for "leave
-- Blizzard's". Folded into the block before the defaults are merged, since the
-- merge starts a fresh table wherever a saved value isn't one — and an empty
-- block would then be filled with the shipped face, quietly switching the font
-- of anyone who had chosen not to have one. See Font.lua.
addon.RegisterMigration(function(prof)
    local settings = prof.settings
    local d = type(settings) == "table" and settings.chat or nil
    if type(d) ~= "table" then return end
    if d.font == false then d.font = FONT_DEFAULT_NAME end
    addon.Font.Adopt(d, "font")
end)

-- addon.db only exists once Core has applied the active profile at
-- PLAYER_LOGIN, and some of what we hook runs earlier during UI load.
local function isReady()
    return addon.db ~= nil and addon.db.settings ~= nil
end

local function getData()
    addon.db.settings.chat = addon.db.settings.chat or {}
    return addon.db.settings.chat
end

-- ── Font ─────────────────────────────────────────────────────────────────────
-- One font block for chat text and tab names (DataTexts.lua reads the same
-- setting). Unlike everywhere else in the addon these strings belong to Blizzard,
-- so two of the block's settings carry a "leave it alone" value: the face
-- "Default", and size 0 — which is what keeps Blizzard's per-window chat font
-- size working, since one value here would otherwise flatten all ten windows.
local CHAT_FONT_DEFAULT = addon.Font.New({
    font = FONT_DEFAULT_NAME, size = 0, outline = "NONE",
})

local function chatFont()
    return addon.Font.Adopt(getData(), "font")
end

-- The chosen font's file path, or nil when set to Default (leave Blizzard's).
local function chatFontPath()
    local name = addon.Font.Name(chatFont(), CHAT_FONT_DEFAULT)
    if not name or name == FONT_DEFAULT_NAME then return nil end
    return addon.FetchMedia("font", name)   -- nil if the font isn't installed
end

-- ChatFontNormal is the game's own chat font, so re-applying it when set to
-- Default is a no-op — which is why this can apply unconditionally without
-- tracking prior state.
local function defaultChatFace()
    return (ChatFontNormal and select(1, ChatFontNormal:GetFont())) or STANDARD_TEXT_FONT
end

-- The block's size, or the size the element already had where it is left at 0.
local function chatFontSize(own)
    local size = addon.Font.Size(chatFont(), CHAT_FONT_DEFAULT)
    return (size and size > 0) and size or own
end

-- Face, size, flags and drop shadow, applied to one FontInstance — a chat frame,
-- a tab label and a DataText segment are all one, so the callers differ only in
-- what they have to go and find first. `ownFace` is what the "Default" face means
-- for that element; chat's own strings answer for themselves through
-- defaultChatFace, and DataTexts passes its segment font's.
local function styleFontInstance(obj, ownFace)
    if not (obj and obj.GetFont) then return end
    local _, size = obj:GetFont()
    if not size then return end   -- font not initialised yet
    obj:SetFont(chatFontPath() or ownFace or defaultChatFace(),
        chatFontSize(size), addon.Font.Flags(chatFont(), CHAT_FONT_DEFAULT))
    addon.Font.ApplyShadow(obj, chatFont(), CHAT_FONT_DEFAULT)
end

local applyChatFont = styleFontInstance

local function applyTabFont(cf)
    local name  = cf:GetName()
    local tab   = name and _G[name .. "Tab"]
    local label = tab and (tab.Text or _G[name .. "TabText"])
    styleFontInstance(label)
end

local function eachChatFrame(fn)
    for i = 1, NUM_CHAT_WINDOWS or 10 do
        local cf = _G["ChatFrame" .. i]
        if cf then fn(cf, i) end
    end
end

-- ── Free movement ───────────────────────────────────────────────────────────
-- Blizzard's clamp insets hold every chat frame well inside UIParent, which is
-- why it can't reach the screen edge. Zeroing them removes the wall (the same
-- pair ElvUI's StyleChat makes). Blizzard re-applies them whenever it restores a
-- saved position, so this must be re-asserted rather than done once.
local function applyFreeMovement(cf)
    if cf.SetClampRectInsets then cf:SetClampRectInsets(0, 0, 0, 0) end
    if cf.SetClampedToScreen then cf:SetClampedToScreen(false) end
end

-- Restores Blizzard's default margin. The exact stock insets aren't readable
-- back once overwritten, so this uses Blizzard's own defaults for a chat frame.
local function restoreClamping(cf)
    if cf.SetClampRectInsets then cf:SetClampRectInsets(0, 0, 0, -25) end
    if cf.SetClampedToScreen then cf:SetClampedToScreen(true) end
end

-- ── Button clutter ──────────────────────────────────────────────────────────
-- Hiding isn't enough: Blizzard re-Shows several of these on its own schedule.
-- Pointing Show at Hide is what makes it stick, as ElvUI's Kill() does. One-way
-- within a session — unticking restores normal behaviour only after a /reload,
-- since the original method reference is gone.
local killed = {}
local function kill(obj)
    if not obj or killed[obj] then return end
    killed[obj] = true
    if obj.Hide then
        obj.Show = obj.Hide
        obj:Hide()
    end
end

-- Blizzard's code still positions the buttonFrame container, so rather than
-- hiding it (and risking taint or errors in code expecting it laid out) it's
-- parked far off-screen with clipping — ElvUI's PositionButtonFrame trick.
local function hideButtonFrame(cf)
    local bf = cf.buttonFrame or _G[cf:GetName() .. "ButtonFrame"]
    if not bf then return end
    bf:ClearAllPoints()
    bf:SetPoint("TOP", cf, "BOTTOM", 0, -90000)
    if bf.SetClipsChildren then bf:SetClipsChildren(true) end
end

-- Shared buttons that sit beside the chat rather than inside any one frame.
-- QuickJoinToastButton is the yellow figure with the group count on it.
local sharedHidden = false
local function hideSharedButtons()
    if sharedHidden then return end
    sharedHidden = true
    kill(_G.ChatFrameMenuButton)
    kill(_G.ChatFrameChannelButton)
    kill(_G.TextToSpeechButton)
    kill(_G.ChatFrameToggleVoiceDeafenButton)
    kill(_G.ChatFrameToggleVoiceMuteButton)
    kill(_G.QuickJoinToastButton)
end

-- ── Edit box skin ───────────────────────────────────────────────────────────
-- Blizzard's edit box is drawn by three border textures with NO backdrop, so it
-- can't be recoloured — the textures go and a new border is created. The
-- backdrop is a SIBLING anchored over the box, not on it: the edit box doesn't
-- reliably inherit BackdropTemplate, and a child would draw over typed text.

local WHITE          = "Interface\\Buttons\\WHITE8x8"
-- RGB only; opacity is a separate setting applied at draw time.
local EDITBOX_BG     = { 0.090, 0.098, 0.165 }
local EDITBOX_BORDER = { 0.30, 0.31, 0.42 }

-- Must draw above the DataText bars at MEDIUM. Blizzard gives it no strata of
-- its own — it inherits roughly MEDIUM from the chat frame, so their order is
-- arbitrary. HIGH wins reliably without climbing into DIALOG, where it would
-- also cover popups and menus.
local EDITBOX_STRATA = "HIGH"
local MAX_CHAT_CHARS = 255 -- Blizzard's per-message cap
local COUNT_WIDTH    = 40  -- room reserved at the right for the counter

local skins      = {} -- eb -> backdrop frame
local charCounts = {} -- eb -> FontString
local reserved   = {} -- eb -> the right inset we last set, to avoid compounding

local function editBoxStyle()
    local d = getData()
    d.editBox = d.editBox or {}
    return d.editBox
end

-- ONLY the right inset is ours. Blizzard sets the LEFT one dynamically in
-- ChatEdit_UpdateHeader to clear the channel header, and "Say:"/"To Playername:"
-- differ in width — capturing it once and reapplying a stale value is what left
-- typed text starting underneath the header.
local function applyTextInsets(eb)
    local l, r, t, b = eb:GetTextInsets()
    -- Strip our previous reservation before re-adding it. This runs from a
    -- ChatEdit_UpdateHeader hook, so without it the inset compounds on every channel
    -- switch (the bug in ElvUI's own version, which does insetRight+30).
    if reserved[eb] and math.abs(r - reserved[eb]) < 0.5 then
        r = r - COUNT_WIDTH
    end
    local newRight = r + COUNT_WIDTH
    eb:SetTextInsets(l, newRight, t, b)
    reserved[eb] = newRight
end

-- Raises the edit box clear of the DataText bars, keeping its backdrop just
-- beneath. Re-asserted on every style pass, because Blizzard reassigns the frame
-- level when it re-anchors the box.
local function applyLayering(eb, bd)
    eb:SetFrameStrata(EDITBOX_STRATA)
    -- Guarantee headroom for the backdrop: at level 0 there's nothing below to put
    -- it on, and same-level siblings fall back to creation order — where the
    -- backdrop, created second, would win.
    if eb:GetFrameLevel() < 2 then eb:SetFrameLevel(2) end

    if bd then
        bd:SetFrameStrata(EDITBOX_STRATA)
        bd:SetFrameLevel(eb:GetFrameLevel() - 1)
    end
end

local function ensureSkin(eb)
    if skins[eb] then return skins[eb] end

    local bd = CreateFrame("Frame", nil, eb:GetParent(), "BackdropTemplate")
    bd:SetAllPoints(eb)
    bd:SetBackdrop({
        bgFile = WHITE, edgeFile = WHITE, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    bd:SetShown(eb:IsShown())
    applyLayering(eb, bd)

    -- The edit box is shown/hidden constantly (Enter to open, Escape to close),
    -- so the backdrop has to follow it rather than being positioned once.
    eb:HookScript("OnShow", function() bd:Show() end)
    eb:HookScript("OnHide", function() bd:Hide() end)

    skins[eb] = bd
    return bd
end

local function ensureCharCount(eb)
    if charCounts[eb] then return charCounts[eb] end
    local fs = eb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPRIGHT",    eb, "TOPRIGHT",    -5, 0)
    fs:SetPoint("BOTTOMRIGHT", eb, "BOTTOMRIGHT", -5, 0)
    fs:SetJustifyH("CENTER")
    fs:SetWidth(COUNT_WIDTH)
    fs:SetTextColor(0.75, 0.75, 0.75)
    charCounts[eb] = fs
    return fs
end

local function updateCharCount(eb)
    local fs = charCounts[eb]
    if not fs then return end
    if not (isReady() and getData().enabled ~= false and getData().skinEditBox ~= false) then
        fs:SetText("")
        return
    end
    local len = strlenutf8(eb:GetText() or "")
    -- Blank rather than "255" on an empty box, matching ElvUI.
    fs:SetText(len > 0 and (MAX_CHAT_CHARS - len) or "")
end

-- Border colour follows the channel being typed into: Say white, Party blue,
-- Guild green, and so on. This is the coloured outline in ElvUI's look.
local function channelColor(eb)
    local chatType = eb.GetAttribute and eb:GetAttribute("chatType")
    if not (chatType and _G.ChatTypeInfo) then return nil end

    local info = _G.ChatTypeInfo[chatType]
    if chatType == "CHANNEL" then
        local target = eb:GetAttribute("channelTarget")
        local index  = target and GetChannelName(target)
        -- Index 0 means "no such channel" — fall through to the plain border.
        if index and index > 0 then
            info = _G.ChatTypeInfo["CHANNEL" .. index] or info
        end
    end
    if info and info.r then return info.r, info.g, info.b end
    return nil
end

local function styleEditBox(eb)
    if not eb or not isReady() then return end

    local d = getData()
    if d.enabled == false then return end

    -- The chat font applies to typed text too (the edit box is a FontInstance). The
    -- channel prompt is a separate header FontString Blizzard rewrites on every
    -- channel switch, and this hook fires from ChatEdit_UpdateHeader.
    applyChatFont(eb)
    local header = eb.header or (eb:GetName() and _G[eb:GetName() .. "Header"])
    if header then applyChatFont(header) end

    -- Layering is about the edit box itself clearing the DataText bars, so it
    -- applies whether or not the skin is switched on.
    applyLayering(eb, skins[eb])

    if d.skinEditBox == false then
        if skins[eb] then skins[eb]:Hide() end
        updateCharCount(eb)
        return
    end

    local s  = editBoxStyle()
    local bd = ensureSkin(eb)
    bd:SetShown(eb:IsShown())
    applyLayering(eb, bd)

    -- Rebuilding the backdrop is only needed when the border thickness changes;
    -- this runs from a channel-switch hook, so skip the work otherwise.
    local edge = math.max(s.borderThickness or 1, 1)
    if bd.__edge ~= edge then
        bd:SetBackdrop({
            bgFile = WHITE, edgeFile = WHITE, edgeSize = edge,
            insets = { left = edge, right = edge, top = edge, bottom = edge },
        })
        bd.__edge = edge
    end

    local bg = s.bgColor or EDITBOX_BG
    bd:SetBackdropColor(bg[1], bg[2], bg[3], (s.bgOpacity or 90) / 100)

    -- Channel tinting takes precedence over the fixed border colour when on, since
    -- that's the ElvUI look; turning it off hands control back to the picker.
    local r, g, b
    if s.useChannelColor ~= false then
        r, g, b = channelColor(eb)
    end
    if r then
        bd:SetBackdropBorderColor(r, g, b, (s.borderOpacity or 100) / 100)
    else
        local bc = s.borderColor or EDITBOX_BORDER
        bd:SetBackdropBorderColor(bc[1], bc[2], bc[3], (s.borderOpacity or 100) / 100)
    end

    -- Blizzard anchors the edit box TOPLEFT+TOPRIGHT to the chat frame, so its
    -- height is always free to set; width is left to that anchoring.
    eb:SetHeight(s.height or 24)

    applyTextInsets(eb)
    ensureCharCount(eb)
    updateCharCount(eb)
end

-- Blizzard's default border textures. Killing them is one-way for the session,
-- same as the button clutter above.
local function killEditBoxTextures(cf)
    local name = cf:GetName()
    kill(_G[name .. "EditBoxLeft"])
    kill(_G[name .. "EditBoxMid"])
    kill(_G[name .. "EditBoxRight"])
end

-- ── Hover fade removal ──────────────────────────────────────────────────────
-- Blizzard fades the chat backdrop in on mouseover. Rather than fight the
-- animation, remove what it animates: with the background gone and the button
-- container parked off-screen there's nothing left to act on. (Message text
-- fading after inactivity is separate — see applyTextFade.)
local fadeStripped = {}
local function removeChatFade(cf)
    if fadeStripped[cf] then return end
    fadeStripped[cf] = true

    kill(cf.Background)

    -- The background is only half of it: the border is a nine-slice of separate
    -- textures that fade in alongside it. Swept by region TYPE rather than name,
    -- since which pieces exist varies by build. Only Texture regions are touched —
    -- the messages are FontStrings and must survive.
    for i = 1, cf:GetNumRegions() do
        local r = select(i, cf:GetRegions())
        if r and r.GetObjectType and r:GetObjectType() == "Texture" then
            kill(r)
        end
    end
end

-- ── Message text fade ───────────────────────────────────────────────────────
-- A chat frame is a ScrollingMessageFrame, which fades lines out after
-- timeVisible seconds. SetFading(false) keeps the backlog on screen.
--
-- Making it stick is the hard part: Blizzard re-applies a window's settings on
-- login, /reload, temporary-window open and re-layout, any of which sets fading
-- back to true. So the frame's own SetFading is wrapped, and the answer stays
-- false whoever calls it.
local fadeHooked = {}
local function applyTextFade(cf)
    if not cf.SetFading then return end

    local function suppressing()
        if not isReady() then return false end
        local d = getData()
        return d.enabled ~= false and d.noTextFade ~= false
    end

    if not fadeHooked[cf] then
        fadeHooked[cf] = true

        -- Whatever the frame was doing before we touched it, so unticking the
        -- setting restores that rather than assuming Blizzard's default.
        local prev = cf.GetFading and cf:GetFading()
        if prev == nil then prev = true end
        cf.__drievFadeDefault = prev

        local orig = cf.SetFading
        cf.SetFading = function(self, fading, ...)
            if suppressing() then fading = false end
            return orig(self, fading, ...)
        end
    end

    -- Both branches go through the wrapper, which is harmless: it only ever
    -- forces false, and that's exactly what the first branch is asking for.
    if suppressing() then
        cf:SetFading(false)
    else
        cf:SetFading(cf.__drievFadeDefault)
    end
end

-- Blizzard exposes tab textures as fields, more reliable than guessing global
-- names, but the globals are swept too since which fields exist varies by build.
local TAB_TEX_FIELDS = {
    "leftTexture",          "middleTexture",          "rightTexture",
    "leftSelectedTexture",  "middleSelectedTexture",  "rightSelectedTexture",
    "leftHighlightTexture", "middleHighlightTexture", "rightHighlightTexture",
    "glow",
}
local TAB_STATES = { "", "Selected", "Active", "Highlight" }
local TAB_PARTS  = { "Left", "Middle", "Right" }

-- Textures only need clearing once — they don't come back.
local strippedTabs = {}
local function stripTabTextures(tab, name)
    if strippedTabs[tab] then return end
    strippedTabs[tab] = true

    -- Clearing the Highlight textures is what removes the border/background
    -- lighting up under the cursor; clearing the rest leaves a flat label.
    for _, field in ipairs(TAB_TEX_FIELDS) do
        local tex = tab[field]
        if tex and tex.SetTexture then tex:SetTexture(nil) end
    end
    for _, state in ipairs(TAB_STATES) do
        for _, part in ipairs(TAB_PARTS) do
            local tex = _G[name .. "Tab" .. state .. part]
            if tex and tex.SetTexture then tex:SetTexture(nil) end
        end
    end
end

-- An undocked window has no selection concept of its own, so it counts as
-- selected — it's the only thing in its "dock".
local function tabIsSelected(cf)
    if not cf.isDocked then return true end
    local dm = _G.GeneralDockManager
    return dm ~= nil and dm.selected == cf
end

-- Alpha and name colour together, since Blizzard recomputes both in the same
-- places. It derives tab alpha from exactly these two fields and ships
-- noMouseAlpha = 0, which is why names vanish when the mouse is away; setting
-- both to 1 keeps tabs legible through Blizzard's own handling, so there's
-- nothing to poll. Separate from the texture pass, since this runs from
-- FCFTab_UpdateAlpha on every mouseover.
local function applyTabAppearance(cf)
    local name = cf:GetName()
    local tab  = name and _G[name .. "Tab"]
    if not tab then return end

    tab.noMouseAlpha   = 1
    tab.mouseOverAlpha = 1
    tab:SetAlpha(1)

    local label = tab.Text or _G[name .. "TabText"]
    if label then
        local d = getData()
        local c = tabIsSelected(cf)
            and (d.tabSelectedColor or { 1, 1, 1 })
            or  (d.tabColor or { 0.75, 0.75, 0.80 })
        label:SetTextColor(c[1], c[2], c[3])
    end
end

local function flattenTab(cf)
    local name = cf:GetName()
    local tab  = name and _G[name .. "Tab"]
    if not tab then return end
    stripTabTextures(tab, name)
    applyTabAppearance(cf)
end

-- ── Combat log filter bar ───────────────────────────────────────────────────
-- The "My Actions" / "What happened to me" bar is Blizzard's
-- CombatLogQuickButtonFrame_Custom, and where it belongs depends on whether the
-- combat log is docked: under the dock's tab strip if it is, above the window if
-- it isn't. Blizzard only recomputes that from inside its own dock code, so
-- anything else that reflows the dock — rebuilding the window layout, renaming a
-- window, re-anchoring a docked chat — can leave it resolved against a stale
-- anchor and stranded over the log instead of above it.
--
-- Blizzard's own function is called rather than positioning the bar ourselves:
-- it's the one place that knows which of the two anchorings is right just now,
-- and hard-coding either would be wrong half the time.
local fixingCombatLog = false
local function updateCombatLogPosition()
    -- Re-entrancy guard: this runs from refresh(), which is itself hooked to
    -- FCF_DockUpdate, and Blizzard's function pokes the dock.
    if fixingCombatLog then return end
    if not (FCF_UpdateCombatLogPosition and _G.CombatLogQuickButtonFrame_Custom) then return end
    fixingCombatLog = true
    pcall(FCF_UpdateCombatLogPosition)
    fixingCombatLog = false
end

-- Light-weight re-assert for Blizzard's own tab alpha/colour updates.
local function reassertTabs()
    if not isReady() then return end
    local d = getData()
    if d.enabled == false or d.flatTabs == false then return end
    eachChatFrame(applyTabAppearance)
end

-- ── Edit box history ────────────────────────────────────────────────────────
-- Up/Down through what you've sent. Stored in its own PER-CHARACTER
-- SavedVariable, not the profile: history includes whispers, and profiles are
-- account-wide and copyable.
--
-- Navigation is by hand rather than SetAltArrowKeyMode, which is meant to hand
-- Up/Down to Blizzard's history but has been broken for years — ElvUI works
-- around it the same way, crediting Prat.

local function historyLines()
    DrievChatHistoryDB = DrievChatHistoryDB or {}
    DrievChatHistoryDB.lines = DrievChatHistoryDB.lines or {}
    return DrievChatHistoryDB.lines
end

local function historyEnabled()
    if not isReady() then return false end
    local d = getData()
    return d.enabled ~= false and d.chatHistory ~= false
end

local function recordHistory(line)
    if not historyEnabled() then return end

    line = line and strtrim(line)
    if not line or line == "" then return end

    -- Secure commands are kept out: replaying one from an addon-driven path is
    -- blocked by the client anyway, so remembering it only gets in the way.
    local cmd = line:match("^/%w+")
    if cmd and IsSecureCmd and IsSecureCmd(cmd) then return end

    local lines = historyLines()
    -- A repeat moves to the front rather than stacking duplicates.
    for i, text in ipairs(lines) do
        if text == line then
            table.remove(lines, i)
            break
        end
    end
    table.insert(lines, line)

    local cap = getData().historySize or 30
    while #lines > cap do table.remove(lines, 1) end
end

-- Index 0 means "not browsing"; 1 is the most recent line, counting backwards.
local function navigateHistory(eb, key)
    if not historyEnabled() then return end

    local lines = historyLines()
    if #lines == 0 then return end

    local idx = eb.__drievHistoryIndex or 0
    if key == "UP" then
        idx = math.min(idx + 1, #lines)
    elseif key == "DOWN" then
        idx = idx - 1
        if idx < 1 then
            -- Stepping past the newest entry returns to an empty box, so you
            -- can get back to typing fresh without clearing it by hand.
            eb.__drievHistoryIndex = 0
            eb:SetText("")
            return
        end
    else
        return
    end

    eb.__drievHistoryIndex = idx
    eb:SetText(lines[#lines - (idx - 1)] or "")
end

-- Plain Up/Down, no Alt. SetAltArrowKeyMode(true) makes the edit box IGNORE the
-- arrow keys unless Alt is held, so the OnKeyDown hook would never see them.
-- Blizzard drives that flag from the "Arrow Keys in Chat" option, so it must be
-- forced and re-asserted on every refresh.
local function forceArrowKeys(eb)
    if eb.SetAltArrowKeyMode then eb:SetAltArrowKeyMode(false) end
end

local hookedHistory = {}
local function hookHistory(eb)
    if not eb or hookedHistory[eb] then return end
    hookedHistory[eb] = true

    -- Blizzard routes every sent line through AddHistoryLine, which makes it
    -- the one capture point that catches slash commands and plain chat alike.
    hooksecurefunc(eb, "AddHistoryLine", function(_, line) recordHistory(line) end)
    forceArrowKeys(eb)
    eb:HookScript("OnKeyDown", navigateHistory)
    -- Start each new visit to the edit box at the bottom of the history.
    eb:HookScript("OnEditFocusGained", function(self) self.__drievHistoryIndex = 0 end)
    eb:HookScript("OnEditFocusLost",   function(self) self.__drievHistoryIndex = 0 end)
end

-- ── Sticky chat ─────────────────────────────────────────────────────────────
-- Blizzard already has the machinery: ChatEdit_OnEnterPressed copies the current
-- chat type into the box's stickyType attribute, but only when
-- ChatTypeInfo[type].sticky == 1, and Blizzard ships that set for some types and
-- clear for others. So making every channel stick is just setting flags — no
-- hooks, fully reversible.
--
-- Whispers are held out by default: with them sticky, a message meant for /say
-- goes to whoever you last whispered.
local WHISPER_TYPES = { WHISPER = true, BN_WHISPER = true }

-- Blizzard's own flags, captured before we touch them so turning the option
-- back off restores the stock behaviour exactly rather than a guess at it.
local originalSticky
local function captureSticky()
    if originalSticky or not _G.ChatTypeInfo then return end
    originalSticky = {}
    for chatType, info in pairs(_G.ChatTypeInfo) do
        originalSticky[chatType] = info.sticky
    end
end

local function applySticky()
    if not _G.ChatTypeInfo then return end
    captureSticky()

    local d = getData()
    local on = d.enabled ~= false and d.stickyChat ~= false

    for chatType, info in pairs(_G.ChatTypeInfo) do
        if not on then
            info.sticky = originalSticky[chatType] or 0
        elseif WHISPER_TYPES[chatType] and not d.stickyWhispers then
            info.sticky = 0
        else
            info.sticky = 1
        end
    end
end

-- ── Chat style ──────────────────────────────────────────────────────────────
-- Blizzard's chatStyle CVar as a normal setting. "classic" opens the edit box on
-- Enter and hides it on send/Escape; "im" hands it to
-- ChatEdit_SetLastActiveWindow and leaves it up for good.
--
-- Stored per WoW account (config-cache.wtf), not in the profile. Only written
-- while the module is on, and left alone when off — the pre-existing value isn't
-- recorded anywhere, so there's nothing to restore.
local pendingStyle = false

local function applyChatStyle()
    local d = getData()
    if d.enabled == false then return end

    local want = (d.chatStyle == "im") and "im" or "classic"
    -- refresh() runs off half a dozen Blizzard hooks; skipping the write when
    -- the CVar already agrees keeps this free in the common case.
    if GetCVar("chatStyle") == want then return end

    -- SetCVar throws ADDON_ACTION_BLOCKED during combat lockdown; retry once
    -- combat drops, same as Raid.lua does with its CVars.
    if InCombatLockdown() then
        pendingStyle = true
        return
    end
    pendingStyle = false
    SetCVar("chatStyle", want)

    -- The CVar only decides what happens the next time a box is opened or
    -- closed, so whatever is on screen right now has to be dealt with here or
    -- switching appears to do nothing until the next /reload.
    local eb = (ChatEdit_GetLastActiveWindow and ChatEdit_GetLastActiveWindow())
            or (_G.ChatFrame1 and (_G.ChatFrame1.editBox or _G.ChatFrame1EditBox))
    if not eb then return end

    if want == "im" then
        eb:Show()
        -- A box shown without being activated has no channel prompt on it;
        -- this fills it in, and re-tints our border through the same hook.
        if eb.UpdateHeader then eb:UpdateHeader()
        elseif ChatEdit_UpdateHeader then ChatEdit_UpdateHeader(eb) end
    elseif not eb:HasFocus() then
        -- Mid-message, leave it alone: Enter or Escape closes it from here on.
        eb:Hide()
    end
end

-- ── Message decorations: copy arrow and timestamps ──────────────────────────
-- Both are prepended to the message text rather than drawn as separate frames.
-- Chat lines are recycled FontStrings owned by a ScrollingMessageFrame, so
-- anything anchored per-line would need rebuilding on every message and
-- repositioning on every scroll; embedded, they travel with their line.
--
-- Order is arrow, timestamp, message — which falls out of applying the timestamp
-- first and prepending the arrow after it.

-- Blizzard's own chat expand arrow: a clean white triangle pointing right, at
-- the message. Inline texture escapes can't be vertex-coloured, so the texture
-- has to be white already — which rules out the gold Buttons\Arrow-* set.
local ARROW_TEX    = "Interface\\ChatFrame\\ChatFrameExpandArrow"
local ARROW_SIZE   = 12
local LINK_PREFIX  = "dcpl" -- deliberately not ElvUI's "cpl", so both can coexist
local STAMP_COLOR  = "|cff8f8f8f"
-- Separate prefix from LINK_PREFIX above: that one carries a chatID (a
-- position to look a line up from later), this one carries the URL itself
-- directly, since there's nothing else to look up.
local URL_LINK_PREFIX = "dcurl"
local URL_COLOR       = "|cff66bbff"

local function stripEscapes(s)
    if not s then return "" end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", "")
    s = s:gsub("|r", "")
    s = s:gsub("|H.-|h(.-)|h", "%1") -- links collapse to their visible label
    s = s:gsub("|T.-|t", "")          -- inline textures (including our arrow)
    s = s:gsub("|A.-|a", "")
    return s
end

-- For the copy window: colour codes are kept (EditBoxes render |c..|r like chat
-- frames) and, unlike stripEscapes, hyperlinks are left INTACT rather than
-- collapsed to their label — the copy window's edit box has hyperlinks enabled,
-- so native links and this addon's URL links stay clickable there.
local function stripForCopyWindow(s)
    if not s then return "" end
    -- Battle.net presence names are an opaque token that can't be rendered or
    -- clicked meaningfully outside their own frame.
    s = s:gsub("|K.-|k", "")
    -- The arrow icon only means something anchored to a specific chat line;
    -- floating alone in this window it's just noise.
    s = s:gsub("|T.-|t", "")
    s = s:gsub("|A.-|a", "")
    return s
end

-- Drops a leading timestamp we added, so copying a line doesn't carry it into
-- the edit box. Permissive enough to cover 24h, 12h and AM/PM formats.
local function stripTimestamp(s)
    return (s:gsub("^%s*%[[%d:%s]+[AaPpMm%.]*%]%s*", ""))
end

-- Battle.net presence names arrive as opaque |K...|k tokens that can't be
-- turned back into plain text, so those lines aren't copyable.
local function messageIsProtected(msg)
    return msg and msg:find("|K", 1, true) ~= nil
end

-- ── Plain-URL detection ─────────────────────────────────────────────────────
-- Chat doesn't linkify raw URLs. Each one found is wrapped as a custom hyperlink
-- type — the same interception as the copy arrow, just a different prefix — so
-- it reads as "[url]" and clicking copies the bare URL into the edit box.
local URL_PATTERN = "https?://[%w%-%._~:/?#%[%]@!$&'()*+,;=%%]+"

local function linkifyURLs(msg)
    return (msg:gsub(URL_PATTERN, function(url)
        -- A trailing period/comma almost always belongs to the sentence, not the URL —
        -- left attached it'd be treated as part of the link and copied along with it.
        local core, trail = url:match("^(.-)([%.,;:!?]*)$")
        return string.format("|H%s:%s|h%s[%s]|r|h%s", URL_LINK_PREFIX, core, URL_COLOR, core, trail)
    end))
end

-- ── Equal-width timestamps ──────────────────────────────────────────────────
-- A chat line is one FontString with one font, so the timestamp can't use a
-- separate monospaced one. Instead measure its pixel width against the widest
-- that format can render (using whichever digit is widest in the font) and pad
-- the difference with spaces.
local measureFS
local function measurer()
    if not measureFS then
        measureFS = UIParent:CreateFontString(nil, "OVERLAY")
        measureFS:Hide()
    end
    return measureFS
end

-- Cached per "facePath:size", since that's everything GetStringWidth depends
-- on here (flags don't affect advance width the way size does).
local widestDigitCache = {}
local function widestDigit(face, size)
    local key = face .. ":" .. size
    local cached = widestDigitCache[key]
    if cached then return cached end

    local fs = measurer()
    fs:SetFont(face, size, "")
    local best, bestW = "0", 0
    for d = 0, 9 do
        fs:SetText(tostring(d))
        local w = fs:GetStringWidth() or 0
        if w > bestW then best, bestW = tostring(d), w end
    end
    widestDigitCache[key] = best
    return best
end

local function measureWidth(face, size, text)
    local fs = measurer()
    fs:SetFont(face, size, "")
    fs:SetText(text)
    return fs:GetStringWidth() or 0
end

-- Target width per "format:facePath:size" — the widest this format can render,
-- built by substituting every digit with the widest available.
local stampTargetCache = {}
local function stampTarget(format, face, size)
    local key = format .. "|" .. face .. ":" .. size
    local cached = stampTargetCache[key]
    if cached then return cached end

    local widest = widestDigit(face, size)
    local worstCase = (date(format):gsub("%d", widest))
    local target = measureWidth(face, size, worstCase)
    stampTargetCache[key] = target
    return target
end

-- Pads with trailing spaces measured in the same font. Whole spaces only, so
-- this narrows the jitter to under a space's width rather than eliminating it —
-- the best available without per-glyph textures.
local function padStamp(cf, format, text)
    local face, size = cf:GetFont()
    if not (face and size) then return text end

    local target = stampTarget(format, face, size)
    local actual = measureWidth(face, size, text)
    local diff   = target - actual
    if diff <= 0 then return text end

    local spaceW = measureWidth(face, size, " ")
    if spaceW <= 0 then return text end

    local n = math.floor(diff / spaceW)
    if n <= 0 then return text end
    return text .. string.rep(" ", n)
end

-- Drops text into the edit box and selects it, so Ctrl+C copies with no extra
-- click. `cf` is whichever frame ChatFrame_OpenChat actually opens, replicated
-- here so the right EditBox is found afterwards.
local function openChatWithText(text, cf)
    if not ChatFrame_OpenChat then return end
    ChatFrame_OpenChat(text, cf)
    local target = cf or SELECTED_CHAT_FRAME or DEFAULT_CHAT_FRAME
    local eb = target and target.editBox
    if not eb then return end
    -- Deferred a frame: ChatFrame_OpenChat's own SetFocus() (and the rest of the
    -- hyperlink-click chain) can still reset the cursor if HighlightText() runs
    -- immediately.
    C_Timer.After(0, function() eb:HighlightText() end)
end

-- The line index comes from the frame's own hit-testing rather than from the
-- link, because a message's index shifts as new lines arrive.
local function copyLineAtCursor(data)
    local chatID = tonumber(data:match("^" .. LINK_PREFIX .. ":(%d+)"))
    local cf = chatID and _G["ChatFrame" .. chatID]
    if not (cf and cf.FindCharacterAndLineIndexAtCoordinate) then return end

    local cx, cy = GetCursorPosition()
    local scale = cf:GetEffectiveScale() or 1
    local _, index = cf:FindCharacterAndLineIndexAtCoordinate(cx / scale, cy / scale)
    if not index then return end

    local line = cf.visibleLines and cf.visibleLines[index]
    local msg = line and line.messageInfo and line.messageInfo.message
    if not msg or messageIsProtected(msg) then return end

    msg = stripTimestamp(stripEscapes(msg))
    if msg == "" then return end
    openChatWithText(msg)
end

-- ── Copy window ──────────────────────────────────────────────────────────────
-- A button in each chat frame's top-right opens a movable window of that frame's
-- recent history as selectable plain text. Captured from the AddMessage hook
-- into a capped, session-only ring buffer — nothing is stored on disk.
local MAX_COPY_LOG = 500
-- How far the buffer may overshoot before compacting. table.remove(log, 1)
-- shifts all 500 entries every call, and this runs for every line of chat
-- forever; overshooting amortises it to one shift per COPY_LOG_SLACK messages.
local COPY_LOG_SLACK = 100

local function pushCopyLog(cf, msg)
    local log = cf.__drievCopyLog
    if not log then log = {}; cf.__drievCopyLog = log end
    local n = #log + 1
    log[n] = msg
    if n > MAX_COPY_LOG + COPY_LOG_SLACK then
        -- Keep the newest MAX_COPY_LOG entries, discard the oldest.
        local drop = n - MAX_COPY_LOG
        for i = 1, MAX_COPY_LOG do log[i] = log[i + drop] end
        for i = MAX_COPY_LOG + 1, n do log[i] = nil end
    end
end

local copyWindow
local function getCopyWindow()
    if copyWindow then return copyWindow end

    local f = CreateFrame("Frame", "DrievChatCopyWindow", UIParent, "BackdropTemplate")
    f:SetSize(560, 400)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile = WHITE, edgeFile = WHITE, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    f:SetBackdropColor(0.055, 0.062, 0.115, 0.97)
    f:SetBackdropBorderColor(0.30, 0.31, 0.42, 1)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("Copy Chat")
    title:SetTextColor(0.984, 0.173, 0.212)

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("LEFT", title, "RIGHT", 10, 0)
    hint:SetText("Ctrl+A to select all, Ctrl+C to copy")
    hint:SetTextColor(0.50, 0.50, 0.55)

    local close = CreateFrame("Button", nil, f)
    close:SetSize(20, 20)
    close:SetPoint("TOPRIGHT", -6, -6)
    local cl = close:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    cl:SetPoint("CENTER"); cl:SetText("X"); cl:SetTextColor(0.984, 0.173, 0.212)
    close:SetScript("OnEnter", function() cl:SetTextColor(1, 1, 1) end)
    close:SetScript("OnLeave", function() cl:SetTextColor(0.984, 0.173, 0.212) end)
    close:SetScript("OnClick", function() f:Hide() end)

    local scroll = CreateFrame("ScrollFrame", "DrievChatCopyScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -34)
    scroll:SetPoint("BOTTOMRIGHT", -30, 10)

    local eb = CreateFrame("EditBox", nil, scroll)
    eb:SetMultiLine(true)
    eb:SetMaxLetters(0)          -- unlimited
    eb:SetAutoFocus(false)
    eb:SetFontObject("ChatFontNormal")
    eb:SetWidth(520)
    eb:EnableMouse(true)
    -- Lets a click on a |H..|h hyperlink route through the normal SetItemRef
    -- dispatch instead of just moving the cursor. Guarded — a newer API.
    if eb.SetHyperlinksEnabled then eb:SetHyperlinksEnabled(true) end
    eb:SetScript("OnEscapePressed", function() f:Hide() end)
    scroll:SetScrollChild(eb)

    f.editBox, f.scroll = eb, scroll
    f:Hide()
    copyWindow = f
    return f
end

-- WoW's EditBox has an undocumented ceiling on how much text SetText can render;
-- past it the box comes up blank rather than truncating. MAX_COPY_LOG caps line
-- COUNT, but 500 lines of long links can still pass it — which is what made the
-- window "sometimes just be empty". Trim from the oldest end.
local MAX_COPY_CHARS = 8000

local function openCopyWindow(cf)
    local f = getCopyWindow()
    local log = cf and cf.__drievCopyLog
    -- pushCopyLog captures the raw, pre-decoration line, so URLs still need
    -- linkifying here. Native hyperlinks are already part of that raw text.
    local doLinkify = not isReady() or getData().linkifyURLs ~= false
    local lines = {}
    if log then
        for _, m in ipairs(log) do
            local clean = doLinkify and linkifyURLs(m) or m
            clean = stripForCopyWindow(clean)
            if clean ~= "" then lines[#lines + 1] = clean end
        end
    end

    local text = table.concat(lines, "\n")
    if #text > MAX_COPY_CHARS then
        text = text:sub(#text - MAX_COPY_CHARS + 1)
        -- The cut almost certainly landed mid-line; drop the leftover fragment so the
        -- window opens on a clean line.
        local firstNL = text:find("\n")
        if firstNL then text = text:sub(firstNL + 1) end
    end

    f.editBox:SetText(text)
    f:Show()
    f:Raise()
    -- Scroll to the newest lines and pre-select everything, so Ctrl+C grabs the
    -- whole log immediately. Deferred a frame so the scroll range is computed.
    C_Timer.After(0, function()
        if f.scroll and f.scroll.SetVerticalScroll then
            f.scroll:SetVerticalScroll(f.scroll:GetVerticalScrollRange() or 0)
        end
        f.editBox:SetFocus()
        f.editBox:HighlightText()
    end)
end

local function ensureCopyButton(cf)
    if cf.__drievCopyBtn then return cf.__drievCopyBtn end
    local btn = CreateFrame("Button", nil, cf)
    btn:SetSize(18, 18)
    btn:SetPoint("TOPRIGHT", cf, "TOPRIGHT", -2, 0)
    btn:SetFrameLevel(cf:GetFrameLevel() + 10)
    btn:SetNormalTexture("Interface\\Buttons\\UI-GuildButton-PublicNote-Up")
    btn:SetHighlightTexture("Interface\\Buttons\\UI-GuildButton-PublicNote-Up", "ADD")
    btn:SetScript("OnClick", function() openCopyWindow(cf) end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Copy chat")
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    cf.__drievCopyBtn = btn
    return btn
end

-- Jump-to-present. Blizzard ships this in the button frame hideButtonFrame
-- strips, so by default the only way back down is the wheel. ScrollToBottom is a
-- ScrollingMessageFrame method; the pcall covers a client that renamed it, where
-- a dead button beats a Lua error on every click.
local function ensureScrollBottomButton(cf)
    if cf.__drievBottomBtn then return cf.__drievBottomBtn end
    local btn = CreateFrame("Button", nil, cf)
    btn:SetSize(18, 18)
    btn:SetFrameLevel(cf:GetFrameLevel() + 10)
    btn:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
    btn:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Down")
    btn:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up", "ADD")
    btn:SetScript("OnClick", function()
        if cf.ScrollToBottom then pcall(cf.ScrollToBottom, cf) end
    end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Jump to the newest messages")
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    cf.__drievBottomBtn = btn
    return btn
end

-- Re-anchored on every refresh rather than at creation: it sits under the copy
-- button, which is itself optional — with that off this would float below a gap.
local function anchorScrollBottomButton(cf, btn, belowCopy)
    btn:ClearAllPoints()
    if belowCopy then
        btn:SetPoint("TOPRIGHT", cf.__drievCopyBtn, "BOTTOMRIGHT", 0, -2)
    else
        btn:SetPoint("TOPRIGHT", cf, "TOPRIGHT", -2, 0)
    end
end

-- AddMessage is REPLACED rather than hooksecurefunc'd, because the whole point
-- is to rewrite the message argument before Blizzard renders it.
local hookedAddMessage = {}
local function hookAddMessage(cf)
    if not cf or hookedAddMessage[cf] then return end
    hookedAddMessage[cf] = true

    local original = cf.AddMessage
    cf.AddMessage = function(self, msg, ...)
        if type(msg) == "string" and isReady() then
            local d = getData()
            -- Skip blanks, and never decorate a line twice: history replays re-add lines
            -- that already carry an arrow and/or a linkified URL.
            if d.enabled ~= false
               and not msg:match("^%s*$")
               and not msg:find("|H" .. LINK_PREFIX .. ":", 1, true)
               and not msg:find("|H" .. URL_LINK_PREFIX .. ":", 1, true) then

                -- Capture the raw line (pre-decoration) for the copy window.
                if d.copyButton ~= false then pushCopyLog(self, msg) end

                if d.linkifyURLs ~= false then
                    msg = linkifyURLs(msg)
                end

                if d.timestamps then
                    local format = d.timestampFormat or "%H:%M:%S"
                    local stamp  = date(format)
                    local pad    = ""
                    if d.timestampEqualWidth then
                        local padded = padStamp(self, format, stamp)
                        pad = padded:sub(#stamp + 1)
                    end
                    msg = string.format("%s[%s]|r%s %s", STAMP_COLOR, stamp, pad, msg)
                end
                -- Prepended last, so it sits left of the timestamp.
                if d.copyArrow ~= false then
                    msg = string.format("|H%s:%d|h|T%s:%d|t|h %s",
                        LINK_PREFIX, self:GetID(), ARROW_TEX, ARROW_SIZE, msg)
                end
            end
        end
        return original(self, msg, ...)
    end
end

-- Clicking any chat hyperlink routes through ItemRefTooltip:SetHyperlink.
-- Intercept only our own prefixes; everything else passes straight through.
local hookedItemRef = false
local function hookItemRef()
    if hookedItemRef or not ItemRefTooltip then return end
    hookedItemRef = true

    local original = ItemRefTooltip.SetHyperlink
    function ItemRefTooltip:SetHyperlink(data, ...)
        if type(data) == "string" and data:sub(1, #LINK_PREFIX + 1) == LINK_PREFIX .. ":" then
            copyLineAtCursor(data)
            -- Blizzard's SetItemRef shows the tooltip frame before dispatching an
            -- unrecognised link type, so without this an empty tooltip is left on screen.
            self:Hide()
            return
        end
        if type(data) == "string" and data:sub(1, #URL_LINK_PREFIX + 1) == URL_LINK_PREFIX .. ":" then
            -- The URL is embedded in the link data, so this is a prefix strip rather than
            -- the cursor/line lookup the copy arrow needs.
            local url = data:sub(#URL_LINK_PREFIX + 2)
            if url ~= "" then openChatWithText(url) end
            self:Hide()
            return
        end
        return original(self, data, ...)
    end
end

-- ── Apply ───────────────────────────────────────────────────────────────────
local function refresh()
    if not isReady() then return end
    local d = getData()
    local on = d.enabled ~= false

    if on and d.hideButtons ~= false then
        hideSharedButtons()
    end
    applySticky()
    applyChatStyle()

    eachChatFrame(function(cf, i)
        if on and d.hideButtons ~= false then
            hideButtonFrame(cf)
        end
        if on and d.noHoverFade ~= false then
            removeChatFade(cf)
        end
        -- Handles both directions itself (the setting is reversible without a
        -- /reload, unlike the texture stripping above), so it isn't gated here.
        applyTextFade(cf)
        if on and d.flatTabs ~= false then
            flattenTab(cf)
        end
        if on and d.freeMovement ~= false then
            applyFreeMovement(cf)
        else
            restoreClamping(cf)
        end

        if on then
            applyChatFont(cf)   -- message text
            applyTabFont(cf)    -- tab name
        end

        local showCopy = on and d.copyButton ~= false
        if showCopy then
            ensureCopyButton(cf):Show()
        elseif cf.__drievCopyBtn then
            cf.__drievCopyBtn:Hide()
        end

        if on and d.scrollBottomButton ~= false then
            local bottomBtn = ensureScrollBottomButton(cf)
            anchorScrollBottomButton(cf, bottomBtn, showCopy)
            bottomBtn:Show()
        elseif cf.__drievBottomBtn then
            cf.__drievBottomBtn:Hide()
        end

        local eb = cf.editBox or _G["ChatFrame" .. i .. "EditBox"]
        if eb then
            if on and d.skinEditBox ~= false then
                killEditBoxTextures(cf)
            end
            if on and d.chatHistory ~= false then
                forceArrowKeys(eb)
            end
            styleEditBox(eb)
        end
    end)

    -- Last: the loop above can restyle tabs and re-anchor frames, both of which
    -- move what the filter bar hangs off.
    updateCombatLogPosition()
end

-- Every per-frame hook, in one place so a window created later (ChatWindows.lua
-- builds them from the profile well after login) gets the same treatment as the
-- ones that existed at PLAYER_LOGIN. Idempotent: hookAddMessage guards itself and
-- hookedEditBox guards the rest, so calling it twice on a frame is a no-op.
local hookedEditBox = {}
local function hookFrame(cf, i)
    if not cf then return end
    hookAddMessage(cf)

    local eb = cf.editBox or _G["ChatFrame" .. (i or cf:GetID()) .. "EditBox"]
    if not eb or hookedEditBox[eb] then return end
    hookedEditBox[eb] = true

    -- Live remaining-character count while typing.
    eb:HookScript("OnTextChanged", updateCharCount)
    hookHistory(eb)

    -- Blizzard rewrites the header on every channel switch, which is exactly when
    -- the border needs recolouring. Since the editbox refactor this is a method on
    -- the editbox, not the old global — hook it per editbox or the border stops
    -- following channel changes.
    if eb.UpdateHeader then
        hooksecurefunc(eb, "UpdateHeader", styleEditBox)
    end
end

local function init()
    hookItemRef()
    refresh()

    eachChatFrame(hookFrame)

    -- Kept for clients that still expose the old global (pre-mixin) function.
    if ChatEdit_UpdateHeader then
        hooksecurefunc("ChatEdit_UpdateHeader", styleEditBox)
    end

    -- Blizzard restores each frame's saved position AND its clamp insets on login
    -- and on re-layout; re-assert afterwards or the movement limits come back.
    if FCF_RestorePositionAndDimensions then
        hooksecurefunc("FCF_RestorePositionAndDimensions", refresh)
    end
    if FCF_DockUpdate then
        hooksecurefunc("FCF_DockUpdate", refresh)
    end
    -- Blizzard re-anchors the button container whenever it decides which side of the
    -- chat the buttons belong on, which is why the scroll arrows reappeared at
    -- random moments. ElvUI hooks this for the same reason.
    if FCF_SetButtonSide then
        hooksecurefunc("FCF_SetButtonSide", refresh)
    end
    if FCF_UpdateButtonSide then
        hooksecurefunc("FCF_UpdateButtonSide", refresh)
    end
    -- Blizzard recomputes tab alpha and name colour through these, so re-assert or
    -- the names fade out on the next mouseover. They fire far more often than the
    -- hooks above, hence the tab-only path rather than a full refresh.
    if FCFTab_UpdateAlpha then
        hooksecurefunc("FCFTab_UpdateAlpha", reassertTabs)
    end
    if FCFTab_UpdateColors then
        hooksecurefunc("FCFTab_UpdateColors", reassertTabs)
    end
    -- Switching tabs changes which one counts as selected, and therefore which
    -- colour each should be wearing.
    if FCF_SelectDockFrame then
        hooksecurefunc("FCF_SelectDockFrame", reassertTabs)
    end
    -- Newly created windows start with Blizzard's defaults and need the same
    -- treatment, including their own AddMessage replacement.
    if FCF_OpenTemporaryWindow then
        hooksecurefunc("FCF_OpenTemporaryWindow", function()
            eachChatFrame(hookFrame)
            refresh()
        end)
    end
    -- Blizzard re-sets a window's font (default face + new size) when its size is
    -- changed from the chat options, which would drop our override.
    if FCF_SetChatWindowFontSize then
        hooksecurefunc("FCF_SetChatWindowFontSize", function() refresh() end)
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("UPDATE_FLOATING_CHAT_WINDOWS")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        init()
        f:UnregisterEvent("PLAYER_LOGIN")
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Only the CVar can be deferred; the rest of refresh() already ran.
        if pendingStyle then applyChatStyle() end
    else
        refresh()
    end
end)

-- The master switch for the whole Chat module (Panels/DataTexts/Alerts all
-- check this too, so switching it off hides/mutes everything regardless of
-- each feature's own enabled flag — see ChatUI.lua's "Enable Chat System").
local function isEnabled()
    return isReady() and getData().enabled ~= false
end

addon.Chat = {
    refresh     = refresh,
    getFontPath = chatFontPath,
    -- Applies the shared chat font block to any FontInstance. DataTexts styles
    -- its segments through this rather than reading the setting itself, so the
    -- bars, the chat text and the tab names can't end up styled by two sets of
    -- rules that drift apart.
    styleText   = styleFontInstance,
    isEnabled   = isEnabled,
    eachFrame   = eachChatFrame,
    -- For windows that didn't exist at PLAYER_LOGIN — see hookFrame.
    hookFrame   = hookFrame,
    -- For anything that moves a chat frame without going through refresh().
    updateCombatLogPosition = updateCombatLogPosition,
}
