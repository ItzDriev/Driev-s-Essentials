local addon = _G.DrievEssentials
if not addon then return end

local UI = addon.UI

-- Snap-to-panel docking, a position lock, and Move Mode ownership of
-- free-floating chat position.
--
-- Deliberately NOT ElvUI's model, which earlier attempts copied and which
-- repeatedly broke tab dragging. Nothing is reparented, GeneralDockManager is
-- left alone, and no layout is re-asserted every frame.
--
-- Docking acts at ONE moment: when a drag ends over a panel, position and size
-- are set to fit and handed back via FCF_SavePositionAndDimensions.
--
-- 1.15.9 made FCF_RestorePositionAndDimensions bail out unconditionally for
-- DEFAULT_CHAT_FRAME, so a dragged window silently reset to Edit Mode's layout on
-- reload. `rects` is our own record of where a window was last dropped, applied
-- in reapply() AFTER Blizzard's restore, so our data wins.

local PAD      = 5  -- gap between the panel's edge and the chat text
local TAB_ROOM = 24 -- space kept at the panel's top for the tab strip

addon.RegisterDefaults("chatDock", {
    locked = false,
    -- [chatFrameID] = panelIndex, for chats currently docked to a panel.
    docked = {},
    -- [chatFrameID] = {x, y, w, h} (BOTTOMLEFT-anchored, absolute), for
    -- free-floating chats we've positioned ourselves.
    rects = {},
    -- [panelIndex] = true once dockDefaultChat has been attempted for that
    -- panel, so re-enabling it later (after the user turned it back off)
    -- never auto-docks again - only the very first enable per profile does.
    autoDocked = {},
})

local function isReady()
    return addon.db ~= nil and addon.db.settings ~= nil
end

local function getData()
    addon.db.settings.chatDock = addon.db.settings.chatDock or {}
    local d = addon.db.settings.chatDock
    d.docked     = d.docked     or {}
    d.rects      = d.rects      or {}
    d.autoDocked = d.autoDocked or {}
    return d
end

local eachChatFrame = addon.Chat.eachFrame

-- ── Panel hit-testing ───────────────────────────────────────────────────────
local function panelRect(i)
    local CP = addon.ChatPanels
    if not (CP and CP.isEnabled(i)) then return nil end
    local p = CP.getFrame(i)
    if not (p and p:IsShown()) then return nil end
    local l, r, b, t = p:GetLeft(), p:GetRight(), p:GetBottom(), p:GetTop()
    if not (l and r and b and t) then return nil end
    return p, l, r, b, t
end

-- Which panel a chat window was dropped on, by its centre point. Centre rather
-- than any overlap: dropping a large chat that merely clips a panel's corner
-- shouldn't yank it across the screen.
local function panelUnder(cf)
    local cx, cy = cf:GetCenter()
    if not (cx and cy) then return nil end

    local CP = addon.ChatPanels
    for i = 1, (CP and CP.count or 2) do
        local _, l, r, b, t = panelRect(i)
        if l and cx >= l and cx <= r and cy >= b and cy <= t then
            return i
        end
    end
    return nil
end

-- ── Free (undocked) position ────────────────────────────────────────────────
-- Our own record of a chat window's rect, independent of Blizzard's saved
-- position — see the header for why that can't be trusted for
-- DEFAULT_CHAT_FRAME any more.
local function captureRect(cf)
    local l, b = cf:GetLeft(), cf:GetBottom()
    local w, h = cf:GetWidth(), cf:GetHeight()
    if not (l and b and w and h) then return nil end
    return { l, b, w, h }
end

-- ── Suppressing Blizzard's own repositioning ────────────────────────────────
-- Re-asserting our position after each Edit Mode reflow made the chat visibly
-- hop to Blizzard's position and back. Instead DEFAULT_CHAT_FRAME's
-- SetPoint/ClearAllPoints become no-ops for everyone — Edit Mode included —
-- except our own code, which calls the saved originals. Native tab-drag and Move
-- Mode are unaffected: StartMoving moves the anchor at the engine level.
local origSetPoint, origClearAllPoints = {}, {}

local function rawSetPoint(cf, ...)
    (origSetPoint[cf] or cf.SetPoint)(cf, ...)
end

local function rawClearAllPoints(cf)
    (origClearAllPoints[cf] or cf.ClearAllPoints)(cf)
end

local function setChatMovementSuppressed(cf, suppressed)
    if suppressed then
        if origSetPoint[cf] then return end -- already suppressed
        origSetPoint[cf]       = cf.SetPoint
        origClearAllPoints[cf] = cf.ClearAllPoints
        cf.SetPoint       = function() end
        cf.ClearAllPoints = function() end
    else
        if not origSetPoint[cf] then return end
        cf.SetPoint            = origSetPoint[cf]
        cf.ClearAllPoints      = origClearAllPoints[cf]
        origSetPoint[cf]       = nil
        origClearAllPoints[cf] = nil
    end
end

local function applyRect(cf, rect)
    if not rect then return end
    rawClearAllPoints(cf)
    rawSetPoint(cf, "BOTTOMLEFT", UIParent, "BOTTOMLEFT", rect[1], rect[2])
    cf:SetSize(rect[3], rect[4])
end

-- ── Docking ─────────────────────────────────────────────────────────────────
local function dockTo(cf, index)
    local p, l, _, b, _ = panelRect(index)
    if not p then return false end

    local w = p:GetWidth()  - PAD * 2
    local h = p:GetHeight() - PAD * 2 - TAB_ROOM
    -- A panel too small to hold a usable chat is not worth docking into; the
    -- result would be an unreadable sliver.
    if w < 80 or h < 40 then return false end

    -- Anchored to UIParent in absolute terms rather than to the panel.
    -- FCF_SavePositionAndDimensions records absolute coordinates, so a panel anchor
    -- would be converted anyway — and would mean Blizzard and we both think we own
    -- the frame's position.
    rawClearAllPoints(cf)
    rawSetPoint(cf, "BOTTOMLEFT", UIParent, "BOTTOMLEFT", l + PAD, b + PAD)
    cf:SetSize(w, h)

    if FCF_SavePositionAndDimensions then
        pcall(FCF_SavePositionAndDimensions, cf)
    end

    local d = getData()
    d.docked[cf:GetID()] = index
    -- A dock assignment always wins over a stale free rect from before it was
    -- docked, so don't leave one lying around to fight it later.
    d.rects[cf:GetID()] = nil
    return true
end

local function undock(cf)
    getData().docked[cf:GetID()] = nil
end

-- Called wherever a drag ends, regardless of who drove it (a plain native tab
-- drag, or one of our own Move Mode movers): dock if dropped on a panel,
-- otherwise remember the free rect ourselves.
local function finishDrag(cf)
    if not (isReady() and cf and cf.GetCenter) then return end
    local index = panelUnder(cf)
    if index then
        dockTo(cf, index)
        return
    end
    undock(cf)
    local rect = captureRect(cf)
    if rect then getData().rects[cf:GetID()] = rect end
end

-- Re-applies docking and remembered free positions for every tracked chat.
-- Called when a panel moves or resizes (so docked chats follow) and once after
-- login, which is what keeps a free-floating default chat where it was dropped.
local function reapply()
    if not isReady() then return end
    local d = getData()
    for id, index in pairs(d.docked) do
        local cf = _G["ChatFrame" .. id]
        if cf then
            if not dockTo(cf, index) then
                -- The panel is gone or was disabled; forget the assignment
                -- rather than leaving a dangling reference.
                d.docked[id] = nil
            end
        else
            d.docked[id] = nil
        end
    end
    for id, rect in pairs(d.rects) do
        if not d.docked[id] then
            local cf = _G["ChatFrame" .. id]
            if cf then applyRect(cf, rect) end
        end
    end

    -- Moving or resizing a chat frame moves what the combat log's filter bar
    -- hangs off, and Blizzard only re-derives that from its own dock code. This
    -- path never goes through Chat.refresh(), so it has to ask directly.
    if addon.Chat and addon.Chat.updateCombatLogPosition then
        addon.Chat.updateCombatLogPosition()
    end
end

-- ── Lock ────────────────────────────────────────────────────────────────────
-- Uses Blizzard's own lock rather than blocking drags ourselves:
-- FCFTab_OnDragStart already checks chatFrame.isLocked, so this stops the drag
-- at source instead of undoing one that already started.
local function applyLock()
    if not isReady() then return end
    -- Boolean, not 1/nil: FCF_SetLocked passes this straight to the
    -- SetChatWindowLocked C function. (It matters that "unlocked" is nil/false
    -- rather than 0 — 0 is truthy in Lua, so it would read as locked.)
    local locked = getData().locked and true or false
    eachChatFrame(function(cf)
        if FCF_SetLocked then pcall(FCF_SetLocked, cf, locked) end
    end)
end

local function setLocked(v)
    getData().locked = v and true or false
    applyLock()
end

-- ── Blizzard Edit Mode suppression ──────────────────────────────────────────
-- ChatFrame1 is a full EditModeSystemMixin system, which causes two problems:
--
-- 1. It gets its own Selection box, a second "move this" box beside ours.
--    defaultHideSelection is the flag OnEditModeEnter checks before calling
--    HighlightSystem(). (Not the reparent-off-screen trick HideBlizzard.lua
--    uses — the chat still needs to be visible.)
--
-- 2. HighlightSystem() calls SetMovable(false) and only SelectSystem() undoes
--    it, so once Edit Mode has been opened this session ChatFrame1 is left
--    permanently non-movable and our StartMoving() calls do nothing.
--
-- Both apply only while the module is enabled and are fully reversible, since
-- defaultHideSelection is re-read on every Edit Mode entry.
local function suppressBlizzardChatEditMode()
    local on = addon.Chat and addon.Chat.isEnabled()
    eachChatFrame(function(cf)
        cf.defaultHideSelection = on or nil
        if on and cf.SetMovable then cf:SetMovable(true) end
    end)
    -- Only ChatFrame1 is wired to Edit Mode's system anchor updates, so it's the
    -- only frame needing suppression — turned off again the instant the Chat module
    -- is disabled, same as the rest of this function.
    local defaultCF = DEFAULT_CHAT_FRAME or _G["ChatFrame1"]
    if defaultCF then setChatMovementSuppressed(defaultCF, on and true or false) end
end

local function refresh()
    if not isReady() then return end
    applyLock()
    reapply()
    suppressBlizzardChatEditMode()
end

-- ── Move Mode ────────────────────────────────────────────────────────────────
-- One mover per shown top-level chat window, same shape as every other movable.
-- Dragging goes onto the real ChatFrame, not a proxy: ChatFrameTemplate defines
-- no OnMouseDown/OnMouseUp of its own, so attaching and clearing those never
-- touches anything Blizzard relies on. EnableMouse is never turned off on leave
-- — it's on natively for hyperlink hover, and this addon doesn't own it.
local movers = {}

local function getOrCreateMover(id)
    if movers[id] then return movers[id] end
    local cf = _G["ChatFrame" .. id]
    if not cf then return nil end

    local mover = {}

    function mover.getFrame() return cf end

    function mover.getLabel()
        local name = GetChatWindowInfo and GetChatWindowInfo(id)
        return (name and name ~= "" and name) or ("Chat " .. id)
    end

    function mover.getPosition()
        return cf:GetLeft() or 0, cf:GetBottom() or 0
    end

    function mover.setPosition(x, y)
        rawClearAllPoints(cf)
        rawSetPoint(cf, "BOTTOMLEFT", UIParent, "BOTTOMLEFT", x, y)
    end

    -- Backstop for the position-editor's typed X/Y path. A drag is already resolved
    -- the instant it's released, specifically so another movable's savePosition()
    -- later in ExitMoveMode's loop can't call reapply() against a stale entry and
    -- yank a freshly-freed window back onto the panel.
    function mover.savePosition()
        local before = mover._enterRect
        local now = captureRect(cf)
        local moved = not before or not now
            or math.abs(now[1] - before[1]) > 0.5 or math.abs(now[2] - before[2]) > 0.5
            or math.abs(now[3] - before[3]) > 0.5 or math.abs(now[4] - before[4]) > 0.5
        if moved then
            finishDrag(cf)
        end
    end

    function mover.enterMoveMode()
        mover._enterRect  = captureRect(cf)
        mover._origStrata = cf:GetFrameStrata()
        -- The Move Mode overlay sits at DIALOG strata; without this the chat
        -- frame would render underneath its dimmed background.
        cf:SetFrameStrata("TOOLTIP")
        -- Belt-and-suspenders against EditModeSystemMixin leaving this non-movable (see
        -- suppressBlizzardChatEditMode) — cheap to re-assert, and StartMoving() below is
        -- a silent no-op without it.
        if cf.SetMovable then cf:SetMovable(true) end
        addon.ShowEditBox(cf)
        cf:SetScript("OnMouseDown", function(self, button)
            if button ~= "LeftButton" then return end
            self._clickX, self._clickY = GetCursorPosition()
            self:StartMoving()
        end)
        cf:SetScript("OnMouseUp", function(self, button)
            if button ~= "LeftButton" then return end
            self:StopMovingOrSizing()
            local x, y = GetCursorPosition()
            local sx, sy = self._clickX or x, self._clickY or y
            if math.abs(x - sx) < 4 and math.abs(y - sy) < 4 then
                -- A click, not a drag: nothing moved, so there's nothing to
                -- (re-)dock — just open the precise position editor.
                if UI then UI.OpenPositionEditor(mover, self) end
            else
                -- Resolve dock-vs-free right here, at the moment it's
                -- dropped — see the comment on savePosition for why this
                -- can't wait until Move Mode is exited.
                finishDrag(cf)
            end
        end)
    end

    function mover.leaveMoveMode()
        if mover._origStrata then cf:SetFrameStrata(mover._origStrata) end
        addon.HideEditBox(cf)
        cf:SetScript("OnMouseDown", nil)
        cf:SetScript("OnMouseUp", nil)
    end

    movers[id] = mover
    return mover
end

if UI then
    UI.RegisterMovableProvider(function()
        local list = {}
        -- With the Chat module off, this addon isn't managing chat position at
        -- all — no movers to offer, same as suppressBlizzardChatEditMode above
        -- leaving Blizzard's own Edit Mode system untouched in that case.
        if not (isReady() and addon.Chat and addon.Chat.isEnabled()) then return list end
        eachChatFrame(function(cf, i)
            if cf:IsShown() then
                local m = getOrCreateMover(i)
                if m then list[#list + 1] = m end
            end
        end)
        return list
    end)
end

-- ── Hooks ───────────────────────────────────────────────────────────────────
local function init()
    refresh()

    -- The one moment docking happens. hooksecurefunc runs after Blizzard's own drag
    -- handling, so the frame's final rect is settled. Covers a plain native tab
    -- drag, done without ever opening Move Mode.
    if FCF_StopDragging then
        hooksecurefunc("FCF_StopDragging", finishDrag)
    end
end

-- Blizzard's HighlightSystem() calls SetMovable(false) on ChatFrame1 and only
-- SelectSystem() undoes it, so once Edit Mode has been opened this session our
-- StartMoving() calls would do nothing without this. Deferred a frame because
-- Edit Mode's own handlers run in the same pass and would overwrite us.
local editModeHooked = false
local function onEditModeToggled() C_Timer.After(0, refresh) end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
-- Also PLAYER_ENTERING_WORLD (not unregistered, unlike PLAYER_LOGIN): purely a
-- retry opportunity for the Edit Mode hook below, in case EditModeManagerFrame
-- isn't loaded yet at PLAYER_LOGIN.
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        init()
        f:UnregisterEvent("PLAYER_LOGIN")
    end
    if not editModeHooked then
        editModeHooked = addon.HookBlizzardEditMode(onEditModeToggled, onEditModeToggled)
    end
end)

addon.ChatDock = {
    refresh   = refresh,
    reapply   = reapply,
    setLocked = setLocked,
    isLocked  = function() return isReady() and getData().locked or false end,
    -- Docks the default chat onto a panel when the panel is switched on, rather than
    -- waiting for a manual drag. Once per panel per profile, and only if the chat
    -- currently sits over THIS panel, so a second panel can't steal a docked window.
    dockDefaultChat = function(index)
        if not isReady() then return end
        local d = getData()
        if d.autoDocked[index] then return end
        d.autoDocked[index] = true

        local cf = DEFAULT_CHAT_FRAME or _G["ChatFrame1"]
        if cf and panelUnder(cf) == index then
            dockTo(cf, index)
        end
    end,
    undockAll = function()
        if not isReady() then return end
        local d = getData()
        wipe(d.docked)
        wipe(d.rects)
    end,
}
