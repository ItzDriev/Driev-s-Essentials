local addon = _G.DrievEssentials
if not addon then return end

local UI = addon.UI

-- Snap-to-panel docking, a position lock, and — as of 1.15.9 — Move Mode
-- ownership of free-floating chat position too.
--
-- Deliberately NOT ElvUI's model, which earlier attempts here tried to copy and
-- which repeatedly broke Blizzard's own tab dragging. Nothing is reparented,
-- GeneralDockManager is left completely alone, and no layout is re-asserted
-- every frame.
--
-- Docking acts at ONE moment: when you finish dragging a chat window, if it
-- landed over a chat panel, its position and size are set to fit that panel
-- and handed back to Blizzard through FCF_SavePositionAndDimensions.
--
-- Free (undocked) position used to be left entirely to that same Blizzard
-- call and its counterpart, FCF_RestorePositionAndDimensions. 1.15.9 broke
-- that: FCF_RestorePositionAndDimensions now unconditionally bails out for
-- DEFAULT_CHAT_FRAME ("Default chat frame is now controlled via edit mode" —
-- Blizzard's own comment), so a dragged default chat window silently resets
-- to wherever Edit Mode's layout puts it on the next reload. `rects` below is
-- this addon's own record of where a chat window was last dropped, applied
-- in reapply() AFTER Blizzard/Edit Mode's own restore has run — so our data
-- wins regardless of what Blizzard did or didn't restore. It's written both
-- by a plain native tab-drag (the FCF_StopDragging hook in init()) and by our
-- own Move Mode movers below, so either way of dragging a chat window now
-- persists across reloads.

local PAD      = 5  -- gap between the panel's edge and the chat text
local TAB_ROOM = 24 -- space kept at the panel's top for the tab strip

addon.RegisterDefaults("chatDock", {
    locked = false,
    -- [chatFrameID] = panelIndex, for chats currently docked to a panel.
    docked = {},
    -- [chatFrameID] = {x, y, w, h} (BOTTOMLEFT-anchored, absolute), for
    -- free-floating chats we've positioned ourselves.
    rects = {},
})

local function isReady()
    return addon.db ~= nil and addon.db.settings ~= nil
end

local function getData()
    addon.db.settings.chatDock = addon.db.settings.chatDock or {}
    local d = addon.db.settings.chatDock
    d.docked = d.docked or {}
    d.rects  = d.rects  or {}
    return d
end

local function eachChatFrame(fn)
    for i = 1, NUM_CHAT_WINDOWS or 10 do
        local cf = _G["ChatFrame" .. i]
        if cf then fn(cf, i) end
    end
end

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
-- position/dimensions — see the header comment for why that can't be trusted
-- for DEFAULT_CHAT_FRAME anymore.
local function captureRect(cf)
    local l, b = cf:GetLeft(), cf:GetBottom()
    local w, h = cf:GetWidth(), cf:GetHeight()
    if not (l and b and w and h) then return nil end
    return { l, b, w, h }
end

local function applyRect(cf, rect)
    if not rect then return end
    cf:ClearAllPoints()
    cf:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", rect[1], rect[2])
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

    -- Anchored to UIParent in absolute terms rather than to the panel itself.
    -- FCF_SavePositionAndDimensions records absolute coordinates, so anchoring
    -- to the panel would be silently converted anyway — and a real anchor would
    -- mean Blizzard and we both believe we own the frame's position.
    cf:ClearAllPoints()
    cf:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", l + PAD, b + PAD)
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

-- Re-applies docking and remembered free positions for every chat we're
-- tracking. Called when a panel is moved or resized (so anything docked to it
-- follows) and once after login, where it's what makes a free-floating
-- default chat window stay where it was dropped instead of resetting to
-- wherever Edit Mode's own layout put it.
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
end

-- ── Lock ────────────────────────────────────────────────────────────────────
-- Uses Blizzard's own lock rather than blocking drags ourselves: FCFTab_OnDragStart
-- already checks chatFrame.isLocked, so setting it stops the drag at source
-- instead of letting one start and then undoing it.
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

local function refresh()
    if not isReady() then return end
    applyLock()
    reapply()
end

-- ── Move Mode ────────────────────────────────────────────────────────────────
-- One mover per currently shown top-level chat window, following the same
-- shape as every other movable (getFrame/enterMoveMode/leaveMoveMode/
-- savePosition/getPosition/setPosition/getLabel — see ChatPanels.lua's
-- makeMover for the reference shape).
--
-- Dragging goes straight onto the real ChatFrame rather than a stand-in proxy:
-- ChatFrameTemplate's own script list is only OnLoad/OnEvent/OnUpdate/
-- OnHyperlinkClick/OnHyperlinkEnter/OnHyperlinkLeave — no OnMouseDown or
-- OnMouseUp — so attaching and later clearing those two scripts here never
-- touches anything Blizzard relies on (hyperlink clicking runs through the
-- separate OnHyperlinkClick script and is untouched). EnableMouse is likewise
-- never turned off on leave — it's already on natively for hyperlink hover/
-- click, and this addon doesn't own that setting.
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
        cf:ClearAllPoints()
        cf:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x, y)
    end

    -- Backstop for the position-editor's typed X/Y path (setPosition doesn't
    -- itself decide dock-vs-free — see below). A drag is already resolved the
    -- instant it's released (enterMoveMode's OnMouseUp), specifically so
    -- another movable's savePosition() running later in ExitMoveMode's loop
    -- — ChatPanels' does, unconditionally, whenever ANY panel is enabled —
    -- can't call reapply() against our still-stale docked/rects entry and
    -- yank a freshly-freed chat window straight back onto the panel before
    -- we've had a chance to update it. Only re-evaluates if the position
    -- actually differs from Move Mode entry, so this is a no-op on exit for
    -- a window that was already resolved by its own drag.
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
        -- Belt-and-suspenders against Blizzard's EditModeSystemMixin leaving
        -- this non-movable (see suppressBlizzardChatEditMode above) — cheap
        -- to re-assert on every entry, and StartMoving() below is a silent
        -- no-op without it.
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
        if not isReady() then return list end
        eachChatFrame(function(cf, i)
            if cf:IsShown() then
                local m = getOrCreateMover(i)
                if m then list[#list + 1] = m end
            end
        end)
        return list
    end)
end

-- ── Blizzard Edit Mode suppression ──────────────────────────────────────────
-- ChatFrame1/DEFAULT_CHAT_FRAME is wired up as a full EditModeSystemMixin
-- system (PrimaryChatFrameMixin:OnLoad calls EditModeSystemMixin.OnSystemLoad)
-- — the same integration the action bars and bag bar have, and it causes the
-- same two problems here:
--
-- 1. It gets its own Selection highlight box in Blizzard's native Edit Mode,
--    a second "move this" box alongside ours. defaultHideSelection is the
--    flag EditModeSystemMixin:OnEditModeEnter checks before calling
--    HighlightSystem() — setting it true skips that box entirely. (Not the
--    same mechanism used to suppress MainActionBar/BagsBar in HideBlizzard.lua
--    — those are fully hidden and reparented off-screen, which isn't an
--    option here since the chat window still needs to be visible.)
--
-- 2. HighlightSystem() is also where our own dragging broke: it calls
--    self:SetMovable(false), and only SelectSystem() (clicking the system
--    inside Blizzard's OWN Edit Mode UI) sets it back to true. If Blizzard's
--    Edit Mode was ever opened this session — even before this addon loaded —
--    ChatFrame1 is left permanently non-movable, so our StartMoving() calls
--    in the mover below silently do nothing. Setting defaultHideSelection
--    stops this from happening again; the SetMovable(true) call here undoes
--    it if it already happened earlier this session, and enterMoveMode()
--    below repeats it defensively on every entry to our own Move Mode.
local function suppressBlizzardChatEditMode()
    eachChatFrame(function(cf)
        cf.defaultHideSelection = true
        if cf.SetMovable then cf:SetMovable(true) end
    end)
end

-- ── Hooks ───────────────────────────────────────────────────────────────────
local function init()
    refresh()
    suppressBlizzardChatEditMode()

    -- The one moment docking happens. hooksecurefunc runs after Blizzard has
    -- finished its own drag handling (including any re-docking of tabs), so the
    -- frame's final rect is settled by the time we look at it. Covers a plain
    -- native tab drag, done without ever opening Move Mode.
    if FCF_StopDragging then
        hooksecurefunc("FCF_StopDragging", finishDrag)
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    init()
    -- Blizzard restores chat positions across the first frames after login, so
    -- re-assert once that has settled.
    C_Timer.After(1, refresh)
    f:UnregisterEvent("PLAYER_LOGIN")
end)

addon.ChatDock = {
    refresh   = refresh,
    reapply   = reapply,
    setLocked = setLocked,
    isLocked  = function() return isReady() and getData().locked or false end,
    undockAll = function()
        if not isReady() then return end
        local d = getData()
        wipe(d.docked)
        wipe(d.rects)
    end,
}
