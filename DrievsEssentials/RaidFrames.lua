local addonName, addon = ...

-- Manages position/scale of Blizzard's CompactRaidFrameContainer. That frame is
-- protected and self-manages its child layout, so we never drag it — we drag a
-- lightweight proxy anchor and, on lock, apply its final top-left point and size
-- (as a scale) via SetPoint/SetScale, the only calls that touch the real frame.

local FALLBACK_W, FALLBACK_H = 180, 320
local MIN_SCALE, MAX_SCALE = 0.5, 2.0

local function getData()
    addon.db.settings.raidFrames = addon.db.settings.raidFrames or {
        enabled = false,
        scale   = 1,
    }
    return addon.db.settings.raidFrames
end

local function getContainer()
    return CompactRaidFrameContainer
end

-- The container is sized for its maximum possible layout, not the current
-- roster, so its own GetWidth()/GetHeight() massively overstates the visible
-- area. Walk its shown descendants instead and take the tightest bounding box.
-- These local-position getters are scale-invariant, so the result is consistent
-- regardless of any scale already applied.
local function visibleBounds(container)
    local left, right, top, bottom

    local function scan(f)
        if not f:IsShown() then return end
        local l, r, t, b = f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom()
        if l and r and t and b and r > l and t > b then
            left   = left   and math.min(left, l)   or l
            right  = right  and math.max(right, r)  or r
            top    = top    and math.max(top, t)    or t
            bottom = bottom and math.min(bottom, b)  or b
        end
        for _, kid in ipairs({ f:GetChildren() }) do scan(kid) end
    end

    for _, kid in ipairs({ container:GetChildren() }) do scan(kid) end

    if left and right and top and bottom then
        return left, right, top, bottom
    end
    return nil
end

local function baseSize()
    local f = getContainer()
    if f then
        local l, r, t, b = visibleBounds(f)
        if l then return r - l, t - b end
        local w, h = f:GetWidth(), f:GetHeight()
        if w and w > 0 and h and h > 0 then return w, h end
    end
    return FALLBACK_W, FALLBACK_H
end

-- The container hosts secure unit buttons, so SetPoint/SetScale are protected
-- and blocked during combat lockdown. Guarded at the lowest level so every
-- caller is covered without its own check.
--
-- GetLeft()/GetTop()/SetPoint offsets are in the queried frame's own
-- effective-scale units, not screen pixels — so a raw px/py captured from a
-- scale-1 proxy needs this correction once the container has a custom scale.
local function applyPosition()
    local f = getContainer()
    if not f or InCombatLockdown() then return end
    local s = getData()
    if s.px and s.py then
        f:ClearAllPoints()
        local uiScale = UIParent:GetEffectiveScale()
        local fScale  = f:GetEffectiveScale()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", s.px * uiScale / fScale, s.py * uiScale / fScale)
    end
end

local function applyScale()
    local f = getContainer()
    if not f or InCombatLockdown() then return end
    f:SetScale(getData().scale or 1)
end

-- Retried on PLAYER_REGEN_ENABLED if combat blocked the last attempt —
-- same deferred-apply pattern as Raid.lua.
local pendingApply = false

local function applyAll()
    if not getData().enabled then return end
    if InCombatLockdown() then
        pendingApply = true
        return
    end
    pendingApply = false
    -- Scale first: applyPosition's effective-scale correction reads the
    -- container's *current* scale, so it must already be up to date.
    applyScale()
    applyPosition()
end

-- ── move-mode proxy ──────────────────────────────────────────────────────
local proxy

-- Base (scale-1) size captured once on entering move mode and reused for the
-- session. Blizzard's Edit Mode can change what's visible in the container while
-- open, so re-measuring on exit could disagree with entry — which turned
-- straight into scale drift compounding on every Edit Mode open/close.
local moveBaseW, moveBaseH

-- Resizes/repositions the proxy to the raid frames' current tight bounding box.
-- Used on first entry and via "Snap to Frames", since the roster can change.
local function snapToContainer()
    local f = proxy
    if not f then return end
    local container = getContainer()
    if not container then return end

    local l, t, r, b = nil, nil, nil, nil
    local vl, vr, vt, vb = visibleBounds(container)
    if vl then
        l, r, t, b = vl, vr, vt, vb
    else
        l, r, t, b = container:GetLeft(), container:GetRight(), container:GetTop(), container:GetBottom()
    end
    if not (l and r and t and b) then return end

    local ratio = container:GetEffectiveScale() / UIParent:GetEffectiveScale()
    f:ClearAllPoints()
    f:SetSize(math.max((r - l) * ratio, 40), math.max((t - b) * ratio, 30))
    f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l * ratio, t * ratio)
end

local function getOrCreateProxy()
    if proxy then return proxy end

    local f = CreateFrame("Frame", "DrievRaidFrameAnchor", UIParent, "BackdropTemplate")
    f:SetSize(FALLBACK_W, FALLBACK_H)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    -- Own backdrop stays transparent; the visible edit box is the shared
    -- overlay from addon.ShowEditBox (styled by the Move UI sliders).
    f:Hide()

    local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    label:SetPoint("CENTER")
    label:SetText("Raid Frames")
    label:SetTextColor(1, 1, 1)

    local snapBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    snapBtn:SetSize(120, 20)
    snapBtn:SetPoint("TOP", label, "BOTTOM", 0, -8)
    snapBtn:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    snapBtn:SetBackdropColor(0.090, 0.098, 0.165, 1)
    snapBtn:SetBackdropBorderColor(0.300, 0.310, 0.420, 1)
    local snapLabel = snapBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    snapLabel:SetPoint("CENTER")
    snapLabel:SetText("Snap to Frames")
    snapLabel:SetTextColor(1, 1, 1)
    snapBtn:SetScript("OnEnter", function() snapBtn:SetBackdropBorderColor(0.984, 0.173, 0.212, 1) end)
    snapBtn:SetScript("OnLeave", function() snapBtn:SetBackdropBorderColor(0.300, 0.310, 0.420, 1) end)
    snapBtn:SetScript("OnClick", function() snapToContainer() end)

    -- Resize handle at the bottom-right; the box is anchored TOPLEFT, so growing
    -- keeps that corner fixed. Driven by hand rather than StartSizing so width and
    -- height stay locked to the raid frames' aspect ratio — diagonal cursor movement
    -- maps to one uniform scale factor, not two independent axes.
    local resizeAspectW, resizeAspectH

    local function onResizeUpdate()
        local left = f:GetLeft()
        local top  = f:GetTop()
        if not left or not top then return end

        local scale = UIParent:GetEffectiveScale()
        local x, y  = GetCursorPosition()
        x, y = x / scale, y / scale

        local dx = math.max(x - left, 0)
        local dy = math.max(top - y, 0)
        local factor = ((dx / resizeAspectW) + (dy / resizeAspectH)) / 2
        factor = math.max(MIN_SCALE, math.min(MAX_SCALE, factor))

        f:SetSize(resizeAspectW * factor, resizeAspectH * factor)

        -- Live preview: apply the in-progress scale to the real frames too, so the
        -- result is visible while dragging rather than only after Lock.
        getData().scale = factor
        applyScale()
        applyPosition()
    end

    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -2, 2)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        if not moveBaseW then moveBaseW, moveBaseH = baseSize() end
        resizeAspectW, resizeAspectH = moveBaseW, moveBaseH
        grip:SetScript("OnUpdate", onResizeUpdate)
    end)
    grip:SetScript("OnMouseUp", function(_, button)
        if button ~= "LeftButton" then return end
        grip:SetScript("OnUpdate", nil)
    end)

    proxy = f
    return f
end

local function enterMoveMode()
    local f = getOrCreateProxy()
    local s = getData()
    moveBaseW, moveBaseH = baseSize()

    if s.px and s.py then
        local scale = s.scale or 1
        f:ClearAllPoints()
        f:SetSize(moveBaseW * scale, moveBaseH * scale)
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", s.px, s.py)
    else
        -- First-time use: snap to wherever the real raid frames currently
        -- are instead of defaulting to screen center.
        f:ClearAllPoints()
        f:SetSize(FALLBACK_W, FALLBACK_H)
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        snapToContainer()
    end

    f:Show()
    addon.ShowEditBox(f)
    f:EnableMouse(true)
    -- Driven off OnMouseDown/OnMouseUp rather than OnDragStart, so movement starts
    -- instantly. The same pair does click-vs-drag detection (net move < 4px = click)
    -- to open the X/Y position editor.
    f:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        self._clickX, self._clickY = GetCursorPosition()
        self:StartMoving()
        -- Live preview: push the proxy's position to the real raid frames
        -- every frame while dragging, not just once on release.
        self:SetScript("OnUpdate", function(box)
            local left, top = box:GetLeft(), box:GetTop()
            if not left or not top then return end
            local data = getData()
            data.px, data.py = left, top
            applyPosition()
        end)
    end)
    f:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        self:StopMovingOrSizing()
        self:SetScript("OnUpdate", nil)
        local x, y = GetCursorPosition()
        local sx, sy = self._clickX or x, self._clickY or y
        if math.abs(x - sx) < 4 and math.abs(y - sy) < 4 and addon.UI then
            addon.UI.OpenPositionEditor(addon.RaidFrames, self)
        end
    end)
end

local function leaveMoveMode()
    if not proxy then return end
    addon.HideEditBox(proxy)
    proxy:EnableMouse(false)
    proxy:SetScript("OnMouseDown", nil)
    proxy:SetScript("OnMouseUp",   nil)
    proxy:SetScript("OnUpdate",    nil)
    proxy:Hide()
    moveBaseW, moveBaseH = nil, nil
end

-- For the position-editor popup: read/write the proxy (TOPLEFT convention) and
-- live-apply to the real frames, same as the drag preview.
local function getPosition()
    if not proxy then return 0, 0 end
    return proxy:GetLeft() or 0, proxy:GetTop() or 0
end

local function setPosition(x, y)
    if not proxy then return end
    proxy:ClearAllPoints()
    proxy:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)

    local s = getData()
    s.px, s.py = x, y
    applyPosition()
end

local function savePosition()
    if not proxy then return end
    local s = getData()

    local x, y = proxy:GetLeft(), proxy:GetTop()
    if x and y then
        s.px, s.py = x, y
    end

    local bw, bh = moveBaseW, moveBaseH
    if not bw then bw, bh = baseSize() end
    local w, h = proxy:GetSize()
    local scale = ((w / bw) + (h / bh)) / 2
    s.scale = math.max(MIN_SCALE, math.min(MAX_SCALE, scale))

    applyScale()
    applyPosition()
end

-- Lets the UI set a precise scale (e.g. a typed percentage). Returns the clamped
-- value actually applied, so the caller can reflect clamping back into its input.
local function setScale(value)
    value = math.max(MIN_SCALE, math.min(MAX_SCALE, value))
    getData().scale = value
    applyAll()
    return value
end

-- ── Blizzard Edit Mode cooperation (1.15.9+) ─────────────────────────────────
-- Opening Blizzard's Edit Mode shows our move anchor (only while the Raid Frame
-- Manager is on, i.e. when WE own the position) so it drags alongside everything
-- else; closing saves and hides. Mirrors the action bars' hook so the two move
-- systems don't fight. Self-contained, NOT UI.EnterMoveMode, which would re-open
-- the settings window on exit.
local blizzUnlocked = false

local function blizzardUnlock()
    if InCombatLockdown() or blizzUnlocked then return end
    if not (addon.db and addon.db.settings) then return end
    -- Manager off → we don't reposition the raid frames, so leave them to
    -- Blizzard's own Edit Mode rather than showing a proxy that moves nothing.
    if getData().enabled == false then return end
    blizzUnlocked = true
    enterMoveMode()
end

local function blizzardLock()
    if not blizzUnlocked then return end
    blizzUnlocked = false
    savePosition()
    leaveMoveMode()
    -- The proxy's click opens the shared X/Y position editor; hide it too or it
    -- lingers after Edit Mode closes (same fix the action bars needed).
    if addon.UI and addon.UI.positionEditor then addon.UI.positionEditor:Hide() end
end

local editModeHooked = false
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_ENABLED" then
        if pendingApply then applyAll() end
    else
        applyAll()
    end
    -- Register the Edit Mode callbacks once. Every event here is a retry
    -- opportunity, and the flag only latches on a hook that actually took.
    if not editModeHooked then
        editModeHooked = addon.HookBlizzardEditMode(blizzardUnlock, blizzardLock)
    end
end)

addon.RaidFrames = {
    -- The settings panel edits this table directly, so it reads it from here
    -- rather than keeping its own copy of the same defaults.
    getData          = getData,
    getFrame         = getOrCreateProxy,
    enterMoveMode    = enterMoveMode,
    leaveMoveMode    = leaveMoveMode,
    savePosition     = savePosition,
    applyAll         = applyAll,
    setScale         = setScale,
    minScale         = MIN_SCALE,
    maxScale         = MAX_SCALE,
    getPosition      = getPosition,
    setPosition      = setPosition,
    -- Read by UI.EnterMoveMode to skip a disabled module — with the manager off we
    -- don't own the frames' position, so the proxy would move nothing.
    isEnabled        = function() return getData().enabled ~= false end,
}
