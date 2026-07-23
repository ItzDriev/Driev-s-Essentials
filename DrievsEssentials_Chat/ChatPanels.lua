local addon = _G.DrievEssentials
if not addon then return end

local UI = addon.UI

-- Two standalone background panels, intended to sit behind the chat.
--
-- These are PURELY DECORATIVE. They do not touch chat frames, tabs, or
-- Blizzard's dock manager in any way — no reparenting, no anchoring, no
-- resizing of anything Blizzard owns. A previous version of this file did all
-- of that ("docking") and it repeatedly broke tab dragging, because Blizzard's
-- FloatingChatFrame code keeps running its own layout and drag math on frames
-- it still believes it owns. Docking may come back later, but it has to be
-- built as a deliberate, separate step on top of this.
--
-- So: position and size a panel to sit behind your chat, and move the chat over
-- it with Blizzard's normal tab dragging.

local WHITE = "Interface\\Buttons\\WHITE8x8"

-- Size/color mirror this addon author's own live setup (pulled from
-- SavedVariables), so both panels start dialed-in instead of at generic
-- placeholder values.
local PANEL_DEFAULTS = {
    enabled         = false,
    width           = 400,
    height          = 198,
    borderThickness = 1,
    bgColor         = { 0, 0, 0 },
    bgOpacity       = 50,
    borderColor     = { 0.30, 0.31, 0.42 },
    borderOpacity   = 100,
    -- px/py (saved position) are absent until moved; each panel then falls back
    -- to its own default corner.
}

local function copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = (type(v) == "table") and copy(v) or v end
    return out
end

-- Each panel's own live px/py — left panel sits near the bottom-left corner,
-- right panel mirrors it near the bottom-right.
local PANEL_1 = copy(PANEL_DEFAULTS)
PANEL_1.px, PANEL_1.py = 4, 27

local PANEL_2 = copy(PANEL_DEFAULTS)
PANEL_2.px, PANEL_2.py = 1203, 27

addon.RegisterDefaults("chatPanels", {
    [1] = PANEL_1,
    [2] = PANEL_2,
})

-- addon.db only exists once Core has applied the active profile at
-- PLAYER_LOGIN; Edit Mode providers and refreshes can be reached before that.
local function isReady()
    return addon.db ~= nil and addon.db.settings ~= nil
end

local function getPanel(i)
    addon.db.settings.chatPanels = addon.db.settings.chatPanels or {}
    local d = addon.db.settings.chatPanels
    d[i] = d[i] or copy(PANEL_DEFAULTS)
    return d[i]
end

local frames = {}

local function getOrCreateFrame(i)
    if frames[i] then return frames[i] end
    local f = CreateFrame("Frame", "DrievChatPanel" .. i, UIParent, "BackdropTemplate")
    -- BACKGROUND strata keeps it behind the chat text without needing to be
    -- related to the chat frame in any way.
    f:SetFrameStrata("BACKGROUND")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:Hide()
    frames[i] = f
    return f
end

local function applyPosition(i)
    local d, f = getPanel(i), getOrCreateFrame(i)
    f:ClearAllPoints()
    if d.px and d.py then
        f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", d.px, d.py)
    elseif i == 1 then
        f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 6, 6)
    else
        f:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -6, 6)
    end
end

-- "Enable Chat System" (chat.enabled) is the parent switch for this whole
-- module — a panel enabled on its own tab still shouldn't show while that's
-- off.
local function chatSystemEnabled()
    return not addon.Chat or addon.Chat.isEnabled()
end

local function applyPanel(i)
    local d = getPanel(i)
    local f = getOrCreateFrame(i)

    if not (d.enabled and chatSystemEnabled()) then
        f:Hide()
        return
    end

    f:SetSize(d.width or 430, d.height or 190)
    applyPosition(i)

    local edge = math.max(d.borderThickness or 1, 1)
    f:SetBackdrop({
        bgFile = WHITE, edgeFile = WHITE, edgeSize = edge,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    local bg = d.bgColor or { 0.090, 0.098, 0.165 }
    local bd = d.borderColor or { 0.30, 0.31, 0.42 }
    f:SetBackdropColor(bg[1], bg[2], bg[3], (d.bgOpacity or 100) / 100)
    f:SetBackdropBorderColor(bd[1], bd[2], bd[3], (d.borderOpacity or 100) / 100)
    f:Show()
end

local function refresh()
    if not isReady() then return end
    applyPanel(1)
    applyPanel(2)
    -- A panel that moved or changed size drags any chat docked to it along.
    if addon.ChatDock then addon.ChatDock.reapply() end
end

-- ── Mover interface (one per panel, same shape as TTK/RaidFrames) ────────────
local function makeMover(i)
    local mover = {}

    mover.label = "Chat Panel " .. i

    function mover.getFrame() return getOrCreateFrame(i) end

    function mover.getPosition()
        local f = getOrCreateFrame(i)
        return f:GetLeft() or 0, f:GetBottom() or 0
    end

    function mover.setPosition(x, y)
        local d = getPanel(i)
        d.px, d.py = x, y
        applyPosition(i)
        if addon.ChatDock then addon.ChatDock.reapply() end
    end

    -- reapply() re-docks every chat window currently assigned to this panel —
    -- necessary when the panel actually moved (docked chats need to follow),
    -- but ExitMoveMode calls savePosition() on every active movable
    -- regardless of whether it was touched. Without the "did it move" guard,
    -- merely opening Move Mode with this panel enabled — even to reposition
    -- something else entirely — would re-run reapply() on Lock and could
    -- overwrite a chat window's own just-finished drag with stale docked
    -- data (ChatDock.lua's movers resolve dock-vs-free the instant a drag is
    -- released specifically to guard against this, but there's no reason to
    -- fire the call needlessly either).
    function mover.savePosition()
        local f = frames[i]
        if not f then return end
        local d = getPanel(i)
        local x, y = f:GetLeft(), f:GetBottom()
        local moved = not mover._enterX or not x
            or math.abs(x - mover._enterX) > 0.5 or math.abs(y - mover._enterY) > 0.5
        d.px, d.py = x, y
        if moved and addon.ChatDock then addon.ChatDock.reapply() end
    end

    function mover.applyVisibility() applyPanel(i) end

    function mover.enterMoveMode()
        local f = getOrCreateFrame(i)
        if not getPanel(i).enabled then return end
        mover._enterX, mover._enterY = f:GetLeft(), f:GetBottom()
        f:SetFrameStrata("TOOLTIP")
        addon.ShowEditBox(f)
        f:EnableMouse(true)
        f:SetScript("OnMouseDown", function(self, button)
            if button ~= "LeftButton" then return end
            self._clickX, self._clickY = GetCursorPosition()
            self:StartMoving()
        end)
        f:SetScript("OnMouseUp", function(self, button)
            if button ~= "LeftButton" then return end
            self:StopMovingOrSizing()
            local x, y = GetCursorPosition()
            local sx, sy = self._clickX or x, self._clickY or y
            if math.abs(x - sx) < 4 and math.abs(y - sy) < 4 and addon.UI then
                addon.UI.OpenPositionEditor(mover, self)
            end
        end)
    end

    function mover.leaveMoveMode()
        local f = frames[i]
        if not f then return end
        f:SetFrameStrata("BACKGROUND")
        addon.HideEditBox(f)
        f:EnableMouse(false)
        f:SetScript("OnMouseDown", nil)
        f:SetScript("OnMouseUp", nil)
    end

    return mover
end

local movers = { [1] = makeMover(1), [2] = makeMover(2) }

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    refresh()
    f:UnregisterEvent("PLAYER_LOGIN")
end)

addon.ChatPanels = {
    refresh   = refresh,
    movers    = movers,
    -- Read by ChatDock.lua to work out which panel a dragged chat landed on.
    getFrame  = function(i) return frames[i] end,
    isEnabled = function(i) return isReady() and getPanel(i).enabled == true end,
    count     = 2,
}

-- Only enabled panels get a mover box in Edit Mode.
UI.RegisterMovableProvider(function()
    local list = {}
    if not isReady() then return list end
    for i = 1, 2 do
        if getPanel(i).enabled then list[#list + 1] = movers[i] end
    end
    return list
end)
