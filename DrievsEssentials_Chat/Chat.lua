local addon = _G.DrievEssentials
if not addon then return end

-- Minimal chat tweaks. Deliberately small: this does NOT reparent chat frames,
-- take over Blizzard's dock manager, or draw panels behind the chat. Every one
-- of those fought Blizzard's own FloatingChatFrame code and broke tab dragging.
-- Blizzard keeps full ownership of chat layout, docking and positioning here.
--
-- Two things only:
--   1. Hide the button clutter down the left of the chat.
--   2. Let the chat be dragged anywhere on screen, including right to the edges.

addon.RegisterDefaults("chat", {
    enabled      = true,
    hideButtons  = true, -- scroll arrows, chat menu, voice/text-to-speech
    freeMovement = true, -- allow dragging the chat to the screen edges
    skinEditBox  = true, -- flat themed box with channel-coloured border
    editBox = {
        bgColor         = { 0.090, 0.098, 0.165 },
        bgOpacity       = 90,
        borderColor     = { 0.30, 0.31, 0.42 },
        borderOpacity   = 100,
        borderThickness = 1,
        -- When on, the border follows the channel being typed into and the
        -- fixed borderColor above is ignored.
        useChannelColor = true,
        height          = 24,
        -- Width is opt-in: leaving it off keeps Blizzard's own anchoring, where
        -- the box spans the full width of the chat frame.
        customWidth     = false,
        width           = 400,
    },
    copyArrow       = true,        -- clickable arrow at the start of each line
    copyButton      = true,        -- top-right button opening a copyable chat-log window
    timestamps      = false,       -- [15:25:46] in front of each message
    timestampFormat = "%H:%M:%S",
    noHoverFade     = true,        -- kill the chat's fade-in-on-mouseover
    flatTabs        = true,        -- flat tabs, names always legible
    stickyChat      = true,        -- reopen the edit box on the last channel used
    stickyWhispers  = false,       -- ...including whispers (off: they don't stick)
    -- Tab name colours. Blizzard's default is NORMAL_FONT_COLOR yellow for both
    -- states, which makes the selected tab hard to pick out at a glance.
    tabColor         = { 0.75, 0.75, 0.80 },
    tabSelectedColor = { 1.00, 1.00, 1.00 },
    chatHistory      = true, -- Up/Down through what you've sent before
    historySize      = 30,
    -- One font for everything chat-related: message text, tab names and the
    -- DataText bars. false / "Default" leaves Blizzard's font; otherwise a
    -- LibSharedMedia font name.
    font             = false,
})

-- addon.db only exists once Core has applied the active profile at
-- PLAYER_LOGIN, and some of what we hook runs earlier than that during initial
-- UI load, so every entry point checks this rather than indexing a nil profile.
local function isReady()
    return addon.db ~= nil and addon.db.settings ~= nil
end

local function getData()
    addon.db.settings.chat = addon.db.settings.chat or {}
    return addon.db.settings.chat
end

-- ── Font ─────────────────────────────────────────────────────────────────────
-- One configurable font for chat message text and tab names (DataTexts.lua reads
-- the same setting for its bars). Only the face is changed; each element keeps
-- its own size and flags, so Blizzard's per-window chat font size is preserved.
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

-- The chosen font's file path, or nil when set to Default (leave Blizzard's).
local function chatFontPath()
    local d = getData()
    if d.font and d.font ~= "Default" and LSM then
        return LSM:Fetch("font", d.font, true)   -- nil if the font isn't found
    end
    return nil
end

-- Face to fall back to when no override is set. ChatFontNormal is the game's own
-- chat font (Friz Quadrata), so re-applying it when set to Default is a no-op —
-- which is why we can apply unconditionally without tracking prior state.
local function defaultChatFace()
    return (ChatFontNormal and select(1, ChatFontNormal:GetFont())) or STANDARD_TEXT_FONT
end

local function applyChatFont(cf)
    if not cf.GetFont then return end
    local _, size, flags = cf:GetFont()
    if not size then return end   -- font not initialised yet
    cf:SetFont(chatFontPath() or defaultChatFace(), size, flags)
end

local function applyTabFont(cf)
    local name  = cf:GetName()
    local tab   = name and _G[name .. "Tab"]
    local label = tab and (tab.Text or _G[name .. "TabText"])
    if not label then return end
    local _, size, flags = label:GetFont()
    if not size then return end
    label:SetFont(chatFontPath() or defaultChatFace(), size, flags)
end

local function eachChatFrame(fn)
    for i = 1, NUM_CHAT_WINDOWS or 10 do
        local cf = _G["ChatFrame" .. i]
        if cf then fn(cf, i) end
    end
end

-- ── Free movement ───────────────────────────────────────────────────────────
-- Blizzard gives every chat frame clamp insets that hold it well inside
-- UIParent — that reserved margin is why the chat can't be dragged near the
-- screen edge and appears to stick some distance off the bottom. Zeroing the
-- insets and turning clamping off removes the invisible wall. (Same pair of
-- calls ElvUI makes in its own StyleChat.)
--
-- Blizzard re-applies its insets whenever it restores a chat frame's saved
-- position, so this has to be re-asserted rather than done once at load.
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
-- Hiding these is not enough on its own: Blizzard re-Shows several of them on
-- its own schedule (tab selection, dock updates, voice state changes). Pointing
-- Show at Hide is what makes it stick, and is what ElvUI's Kill() does too.
--
-- NOTE: this is one-way within a session. Unticking the option restores normal
-- behaviour only after a /reload — there's no way to un-neuter Show once the
-- original method reference is gone.
local killed = {}
local function kill(obj)
    if not obj or killed[obj] then return end
    killed[obj] = true
    if obj.Hide then
        obj.Show = obj.Hide
        obj:Hide()
    end
end

-- The scroll arrows and chat menu button live inside each frame's buttonFrame.
-- Blizzard's code still positions that container, so rather than hiding it (and
-- risking taint or errors in code that expects it laid out) it gets parked far
-- off-screen with clipping — ElvUI's PositionButtonFrame trick.
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
-- Blizzard's chat edit box is drawn by three border textures
-- (EditBoxLeft/Mid/Right) and has NO backdrop of its own — so it cannot simply
-- be recoloured. The textures have to go, and something has to be created to
-- draw the new border. ElvUI does the same in StyleChat.
--
-- The backdrop is a SIBLING frame anchored over the edit box rather than a
-- backdrop on the edit box itself: Blizzard's edit box doesn't reliably inherit
-- BackdropTemplate, so it may have no SetBackdrop method at all, and a child
-- frame would draw over the typed text instead of behind it.

local WHITE          = "Interface\\Buttons\\WHITE8x8"
-- RGB only; opacity is a separate setting applied at draw time.
local EDITBOX_BG     = { 0.090, 0.098, 0.165 }
local EDITBOX_BORDER = { 0.30, 0.31, 0.42 }

-- The edit box must draw above the DataText bars, which sit at MEDIUM (see
-- getOrCreateBarFrame in DataTexts.lua). Blizzard gives the edit box no strata
-- of its own — it inherits roughly MEDIUM from the chat frame, so the two end
-- up in the same layer and their order is arbitrary. HIGH is one step up:
-- enough to win reliably, without climbing into DIALOG where it would also
-- cover popups and menus.
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

-- ONLY the right inset belongs to us. Blizzard sets the LEFT inset dynamically
-- in ChatEdit_UpdateHeader to clear the channel header, and "Say:", "Party:"
-- and "To Playername:" are all different widths — capturing it once and
-- reapplying a stale value is what left typed text starting at the far left,
-- underneath the header.
local function applyTextInsets(eb)
    local l, r, t, b = eb:GetTextInsets()
    -- Strip our previous reservation before re-adding it. This runs from a
    -- ChatEdit_UpdateHeader hook, so without this the inset compounds on every
    -- channel switch (the bug in ElvUI's own version, which does insetRight+30).
    if reserved[eb] and math.abs(r - reserved[eb]) < 0.5 then
        r = r - COUNT_WIDTH
    end
    local newRight = r + COUNT_WIDTH
    eb:SetTextInsets(l, newRight, t, b)
    reserved[eb] = newRight
end

-- Raises the edit box clear of the DataText bars, and keeps its backdrop
-- immediately beneath it. Re-asserted on every style pass rather than set once,
-- because Blizzard reassigns the edit box's frame level when it re-anchors it
-- (chatStyle changes, dock updates), which would leave the backdrop on top of
-- the text it is supposed to sit behind.
local function applyLayering(eb, bd)
    eb:SetFrameStrata(EDITBOX_STRATA)
    -- Guarantee headroom for the backdrop: at level 0 there is nothing below to
    -- put it on, and same-level siblings fall back to creation order — where
    -- the backdrop, created second, would win.
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

    -- The chat font applies to the typed text too, independent of the edit-box
    -- skin (applyChatFont is generic — the edit box is a FontInstance like the
    -- chat frame). Preserves the box's own size/flags. The channel prompt
    -- ("Say:", "Party:", …) is a separate header FontString, and Blizzard rewrites
    -- it on every channel switch — this hook fires from ChatEdit_UpdateHeader, so
    -- re-applying it here keeps the prompt in the chosen font too.
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

    -- Channel tinting takes precedence over the fixed border colour when on,
    -- since that's the ElvUI look; turning it off hands control back to the
    -- colour picker.
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
    -- height is always free to set. A custom WIDTH means dropping the right
    -- anchor, so it's opt-in and re-asserted here rather than done once.
    eb:SetHeight(s.height or 24)
    if s.customWidth then
        local cf = eb:GetParent()
        eb:ClearAllPoints()
        eb:SetPoint("TOPLEFT", cf, "BOTTOMLEFT", 0, -1)
        eb:SetWidth(s.width or 400)
    end

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
-- Blizzard fades the chat frame's backdrop in on mouseover and back out on
-- leave (FloatingChatFrame_OnEnter -> FCF_FadeInChatFrame). Rather than fight
-- the animation, remove what it animates: with the background texture gone and
-- the button container already parked off-screen, there is nothing left for the
-- fade to act on.
--
-- Message text fading after inactivity is a SEPARATE Blizzard feature
-- (SetFading / shouldFadeAfterInactivity) and is deliberately left alone.
local fadeStripped = {}
local function removeChatFade(cf)
    if fadeStripped[cf] then return end
    fadeStripped[cf] = true

    kill(cf.Background)

    -- The background is only half of it: the chat frame's border is a
    -- nine-slice of separate textures (ChatFrame1TopLeftTexture,
    -- ...LeftTexture, ...BottomTexture and so on) which fade in alongside it,
    -- and that border is what was still appearing on hover.
    --
    -- Swept by region type rather than by name, because which pieces exist
    -- varies by client build. ONLY Texture regions are touched — the chat's
    -- messages are FontStrings and must survive. This is what ElvUI's
    -- StripTextures(true) does to the same frame.
    for i = 1, cf:GetNumRegions() do
        local r = select(i, cf:GetRegions())
        if r and r.GetObjectType and r:GetObjectType() == "Texture" then
            kill(r)
        end
    end
end

-- Every texture making up a chat tab. Blizzard exposes them as fields on the
-- tab, which is more reliable than guessing global names, but the globals are
-- swept too since which fields exist varies by client build.
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

-- Alpha and name colour together, since both are things Blizzard recomputes in
-- the same places and both have to be re-asserted afterwards.
--
-- Blizzard derives tab alpha from exactly these two fields, and ships
-- noMouseAlpha = 0 — which is why the names disappear entirely when the mouse
-- is away. Setting both to 1 keeps the tabs permanently legible while still
-- going through Blizzard's own alpha handling, so there is nothing to poll.
-- (An earlier attempt re-asserted alpha from a 0.2s timer; that lag was visible
-- as a flicker.) Kept separate from the texture pass because this runs from
-- FCFTab_UpdateAlpha, which fires on every mouseover.
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

-- Light-weight re-assert for Blizzard's own tab alpha/colour updates.
local function reassertTabs()
    if not isReady() then return end
    local d = getData()
    if d.enabled == false or d.flatTabs == false then return end
    eachChatFrame(applyTabAppearance)
end

-- ── Edit box history ────────────────────────────────────────────────────────
-- Up/Down through what you've sent before, from an open edit box.
--
-- Stored in its own PER-CHARACTER SavedVariable rather than in the addon
-- profile. Chat history includes whispers, and profiles are account-wide and
-- copyable, so keeping it out of them stops one character's private messages
-- surfacing on another.
--
-- Navigation is done by hand rather than via EditBox:SetAltArrowKeyMode, which
-- is supposed to hand Up/Down to Blizzard's own history but has been broken for
-- years — ElvUI works around it the same way, crediting Prat.

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

    -- Secure commands are kept out entirely: replaying one from an addon-driven
    -- path is blocked by the client anyway, so remembering it only gets in the
    -- way of the lines you actually want.
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
-- arrow keys unless Alt is held (they go to the game and turn your character
-- instead), so the OnKeyDown hook below would never see them. Blizzard drives
-- that flag from the "Arrow Keys in Chat" interface option, so it has to be
-- forced rather than left to whatever the setting happens to be.
--
-- Re-asserted on every refresh because Blizzard reapplies it when that option
-- changes and when it re-anchors the edit box.
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
-- Blizzard already has the machinery: on Enter, ChatEdit_OnEnterPressed copies
-- the current chat type into the edit box's "stickyType" attribute, but only if
-- ChatTypeInfo[type].sticky == 1 — and Blizzard ships that flag set for some
-- types and clear for others. Reopening the box reads stickyType back. So
-- making every channel stick is a matter of setting the flags, not hooking
-- anything, and it's fully reversible.
--
-- Whispers are held out by default, and deliberately so: with them sticky, a
-- message meant for /say goes to whoever you last whispered. That's the classic
-- way to leak something private, so it's opt-in.
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

-- ── Message decorations: copy arrow and timestamps ──────────────────────────
-- Both are prepended to the message text itself rather than drawn as separate
-- frames. For the arrow that's ElvUI's approach and it matters: chat lines are
-- recycled FontStrings owned by a ScrollingMessageFrame, so anything anchored
-- per-line would need rebuilding on every new message and re-positioning on
-- every scroll. Embedded in the text, both simply travel with their line.
--
-- Order is arrow, then timestamp, then message. That falls out of applying the
-- timestamp FIRST and prepending the arrow after it, so the arrow always ends
-- up leftmost.

-- Blizzard's own chat expand arrow: a clean white triangle pointing right, at
-- the message. Inline texture escapes can't be vertex-coloured, so the texture
-- has to be white already — which rules out the gold Buttons\Arrow-* set.
local ARROW_TEX    = "Interface\\ChatFrame\\ChatFrameExpandArrow"
local ARROW_SIZE   = 12
local LINK_PREFIX  = "dcpl" -- deliberately not ElvUI's "cpl", so both can coexist
local STAMP_COLOR  = "|cff8f8f8f"

local function stripEscapes(s)
    if not s then return "" end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", "")
    s = s:gsub("|r", "")
    s = s:gsub("|H.-|h(.-)|h", "%1") -- links collapse to their visible label
    s = s:gsub("|T.-|t", "")          -- inline textures (including our arrow)
    s = s:gsub("|A.-|a", "")
    return s
end

-- Same as stripEscapes but leaves |c..|r colour codes alone. EditBoxes render
-- those the same way chat frames do, so the copy window can show each line in
-- its real chat colour. Links and textures still collapse — a raw |H..|h blob
-- or an inline icon isn't meaningful once copied out as plain text.
local function stripEscapesKeepColor(s)
    if not s then return "" end
    s = s:gsub("|H.-|h(.-)|h", "%1")
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

-- Resolves the clicked arrow back to its own line and loads that line's text
-- into the edit box. The line index comes from the frame's own hit-testing
-- rather than from the link, because a message's index shifts as new lines
-- arrive.
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
    if ChatFrame_OpenChat then ChatFrame_OpenChat(msg) end
end

-- ── Copy window ──────────────────────────────────────────────────────────────
-- A small button in each chat frame's top-right opens a movable window showing
-- that frame's recent history as selectable, copy-pasteable plain text. History
-- is captured per frame from the AddMessage hook (a capped, session-only ring
-- buffer — not persisted), so nothing is stored on disk.
local MAX_COPY_LOG = 500

local function pushCopyLog(cf, msg)
    local log = cf.__drievCopyLog
    if not log then log = {}; cf.__drievCopyLog = log end
    log[#log + 1] = msg
    if #log > MAX_COPY_LOG then table.remove(log, 1) end
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
    eb:SetScript("OnEscapePressed", function() f:Hide() end)
    scroll:SetScrollChild(eb)

    f.editBox, f.scroll = eb, scroll
    f:Hide()
    copyWindow = f
    return f
end

local function openCopyWindow(cf)
    local f = getCopyWindow()
    local log = cf and cf.__drievCopyLog
    local lines = {}
    if log then
        for _, m in ipairs(log) do
            -- Links collapse to their label and textures drop, but colour codes
            -- stay so the window reads in the same colours as the chat itself.
            local clean = stripEscapesKeepColor(m)
            if clean ~= "" then lines[#lines + 1] = clean end
        end
    end
    f.editBox:SetText(table.concat(lines, "\n"))
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
            -- Skip blanks, and never decorate a line twice (chat history
            -- replays re-add lines that already carry an arrow).
            if d.enabled ~= false
               and not msg:match("^%s*$")
               and not msg:find("|H" .. LINK_PREFIX .. ":", 1, true) then

                -- Capture the raw line (pre-decoration) for the copy window.
                if d.copyButton ~= false then pushCopyLog(self, msg) end

                if d.timestamps then
                    msg = string.format("%s[%s]|r %s",
                        STAMP_COLOR, date(d.timestampFormat or "%H:%M:%S"), msg)
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
-- Intercept only our own prefix; everything else (items, quests, achievements)
-- passes straight through untouched.
local hookedItemRef = false
local function hookItemRef()
    if hookedItemRef or not ItemRefTooltip then return end
    hookedItemRef = true

    local original = ItemRefTooltip.SetHyperlink
    function ItemRefTooltip:SetHyperlink(data, ...)
        if type(data) == "string" and data:sub(1, #LINK_PREFIX + 1) == LINK_PREFIX .. ":" then
            copyLineAtCursor(data)
            -- Blizzard's SetItemRef shows the tooltip frame before dispatching
            -- an unrecognised link type; without this an empty tooltip is left
            -- hanging on screen after every copy.
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

    eachChatFrame(function(cf, i)
        if on and d.hideButtons ~= false then
            hideButtonFrame(cf)
        end
        if on and d.noHoverFade ~= false then
            removeChatFade(cf)
        end
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

        if on and d.copyButton ~= false then
            ensureCopyButton(cf):Show()
        elseif cf.__drievCopyBtn then
            cf.__drievCopyBtn:Hide()
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
end

local function init()
    hookItemRef()
    refresh()

    eachChatFrame(function(cf, i)
        hookAddMessage(cf)
        local eb = cf.editBox or _G["ChatFrame" .. i .. "EditBox"]
        if eb then
            -- Live remaining-character count while typing.
            eb:HookScript("OnTextChanged", updateCharCount)
            hookHistory(eb)

            -- Blizzard rewrites the edit box header on every channel switch
            -- (Say -> Party -> Guild...), which is exactly when the border
            -- needs recolouring. Since the chat editbox refactor, this is a
            -- method on the editbox itself (ChatFrameEditBoxMixin:UpdateHeader),
            -- not the old global ChatEdit_UpdateHeader function — hook it per
            -- editbox or the border silently stops following channel changes.
            if eb.UpdateHeader then
                hooksecurefunc(eb, "UpdateHeader", styleEditBox)
            end
        end
    end)

    -- Kept for clients that still expose the old global (pre-mixin) function.
    if ChatEdit_UpdateHeader then
        hooksecurefunc("ChatEdit_UpdateHeader", styleEditBox)
    end

    -- Blizzard restores each chat frame's saved position and its clamp insets
    -- on login and whenever windows are re-laid-out; re-assert afterwards or
    -- the movement limits quietly come back.
    if FCF_RestorePositionAndDimensions then
        hooksecurefunc("FCF_RestorePositionAndDimensions", refresh)
    end
    if FCF_DockUpdate then
        hooksecurefunc("FCF_DockUpdate", refresh)
    end
    -- Blizzard re-anchors the button container whenever it decides which side
    -- of the chat the buttons belong on — which drags it back on screen. This
    -- is why the scroll arrows reappeared at seemingly random moments and then
    -- vanished again the next time something triggered a refresh. ElvUI hooks
    -- the same function for the same reason.
    if FCF_SetButtonSide then
        hooksecurefunc("FCF_SetButtonSide", refresh)
    end
    if FCF_UpdateButtonSide then
        hooksecurefunc("FCF_UpdateButtonSide", refresh)
    end
    -- Blizzard recomputes tab alpha and name colour through these, so re-assert
    -- afterwards or the names fade out again on the next mouseover and revert
    -- to Blizzard's yellow. These fire far more often than the hooks above,
    -- hence the tab-only path rather than a full refresh.
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
    -- Newly created windows (players can add extra chat tabs) start with
    -- Blizzard's defaults and need the same treatment, including their own
    -- AddMessage replacement.
    if FCF_OpenTemporaryWindow then
        hooksecurefunc("FCF_OpenTemporaryWindow", function()
            eachChatFrame(hookAddMessage)
            refresh()
        end)
    end
    -- Blizzard re-sets a chat window's font (default face + new size) when its
    -- font size is changed from the chat options, which would drop our override.
    -- Re-assert afterwards.
    if FCF_SetChatWindowFontSize then
        hooksecurefunc("FCF_SetChatWindowFontSize", function() refresh() end)
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("UPDATE_FLOATING_CHAT_WINDOWS")
f:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        init()
        f:UnregisterEvent("PLAYER_LOGIN")
    else
        refresh()
    end
end)

addon.Chat = { refresh = refresh, getFontPath = chatFontPath }
