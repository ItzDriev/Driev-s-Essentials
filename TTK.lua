local addonName, addon = ...

-- Mirrors aura_env from the original WeakAura; persists across UNIT_HEALTH events.
local env = {}
local inBossFight = false

local function ttkSettings()
    return addon.db and addon.db.settings and addon.db.settings.ttk
end

-- Cached after first check — addon load state doesn't change mid-session,
-- and this is queried on every UNIT_HEALTH tick during combat.
local weakAurasLoaded
local function isWeakAurasLoaded()
    if weakAurasLoaded == nil then
        if C_AddOns and C_AddOns.IsAddOnLoaded then
            weakAurasLoaded = C_AddOns.IsAddOnLoaded("WeakAuras") and true or false
        elseif IsAddOnLoaded then
            weakAurasLoaded = IsAddOnLoaded("WeakAuras") and true or false
        else
            weakAurasLoaded = false
        end
    end
    return weakAurasLoaded
end

local ttkFrame

local function getOrCreate()
    if ttkFrame then return ttkFrame end

    local f = CreateFrame("Frame", "DrievTTKFrame", UIParent, "BackdropTemplate")
    f:SetSize(160, 40)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")
    f:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 2,
    })
    -- Transparent outside edit mode — only visible while repositioning.
    f:SetBackdropColor(0.141, 0.149, 0.227, 0)
    f:SetBackdropBorderColor(0.984, 0.173, 0.212, 0)

    local text = f:CreateFontString(nil, "OVERLAY")
    text:SetAllPoints()
    text:SetJustifyH("CENTER")
    text:SetJustifyV("MIDDLE")
    text:SetFont("Fonts\\FRIZQT__.TTF", 24, "OUTLINE")
    text:SetText("")
    f.text = text

    f:Hide()
    ttkFrame = f
    return f
end

local function applyFont()
    local f = getOrCreate()
    local s = ttkSettings()
    local name = (s and s.fontName) or "Friz Quadrata TT"
    local size = (s and s.fontSize) or 24
    local LSM  = LibStub and LibStub("LibSharedMedia-3.0", true)
    local path = (LSM and LSM:Fetch("font", name)) or "Fonts\\FRIZQT__.TTF"
    f.text:SetFont(path, size, "OUTLINE")

    -- Size the frame (and therefore the edit-mode box, since the text fills
    -- it via SetAllPoints) to fit this font. Measured against a worst-case
    -- sample ("00:00") rather than whatever text happens to be showing
    -- right now, so it doesn't shrink to nothing while no target is
    -- tracked — the live text is restored immediately after measuring.
    local current = f.text:GetText()
    f.text:SetText("00:00")
    local w, h = f.text:GetStringWidth(), f.text:GetStringHeight()
    f.text:SetText(current or "")
    f:SetSize(math.max(w, 1) + 16, math.max(h, 1) + 10)
end

local function applyPosition()
    local f = getOrCreate()
    local s = ttkSettings()
    if s and s.px and s.py then
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", s.px, s.py)
    end
end

local function applyVisibility()
    local f = getOrCreate()
    local s = ttkSettings()
    if not s or not s.enabled then
        f:Hide()
        return
    end
    if s.bossOnly then
        f:SetShown(inBossFight)
    else
        f:Show()
    end
end

local function savePosition()
    local f = getOrCreate()
    local s = ttkSettings()
    if not s then return end
    local x, y = f:GetCenter()
    s.px, s.py = x, y
end

-- For the position-editor popup: read/write the live frame directly (same
-- CENTER/BOTTOMLEFT convention as applyPosition/savePosition) so typed
-- values and nudges are visible immediately, with Lock persisting whatever
-- the frame ends up at via the normal savePosition() path.
local function getPosition()
    local x, y = getOrCreate():GetCenter()
    return x or 0, y or 0
end

local function setPosition(x, y)
    local f = getOrCreate()
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
end

local function enterMoveMode()
    local f = getOrCreate()
    f.text:SetText("13:37")

    local w, h = f.text:GetStringWidth(), f.text:GetStringHeight()
    f:SetSize(math.max(w, 1) + 16, math.max(h, 1) + 10)

    f:SetFrameStrata("TOOLTIP")
    addon.ShowEditBox(f)
    f:EnableMouse(true)
    -- Move-mode is driven directly off OnMouseDown/OnMouseUp instead of
    -- RegisterForDrag/OnDragStart, so movement starts the instant the mouse
    -- goes down instead of waiting on WoW's native drag-recognition threshold.
    -- The same pair also does click-vs-drag detection (net movement < 4px =
    -- a click, not a drag) to open the precise X/Y position editor.
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
            addon.UI.OpenPositionEditor(addon.TTK, self)
        end
    end)
end

local function leaveMoveMode()
    local f = getOrCreate()
    f.text:SetText("")
    f:StopMovingOrSizing()
    f:SetFrameStrata("HIGH")
    addon.HideEditBox(f)
    f:EnableMouse(false)
    f:SetScript("OnMouseDown", nil)
    f:SetScript("OnMouseUp",   nil)
    applyFont()
end

-- TTK calculation — exact logic from the original WeakAura, translated to
-- event-driven Lua. env mirrors aura_env; both are module-level and persist
-- between calls. The WA code declared `local oldhealth` inside the function
-- (always nil, so the if-block always ran); here we simply run on each event.
local function updateTTK()
    local s = ttkSettings()
    if not s or not s.enabled then return end
    if s.bossOnly and not inBossFight then return end

    local health = UnitHealth("target")
    local time   = GetTime()
    local text   = ""

    if health == UnitHealthMax("target") then
        env.health0, env.time0, env.mhealth, env.mtime = nil, nil, nil, nil
        text = ""
        getOrCreate().text:SetText(text)
        return
    end

    if not env.health0 then
        env.health0, env.time0 = health, time
        env.mhealth, env.mtime = health, time
        getOrCreate().text:SetText("")
        return
    end

    env.mhealth = (env.mhealth + health) * 0.5
    env.mtime   = (env.mtime   + time)   * 0.5

    if env.mhealth >= env.health0 then
        text = ""
        env.health0, env.time0, env.mhealth, env.mtime = nil, nil, nil, nil
    else
        local ttk = health * (env.time0 - env.mtime) / (env.mhealth - env.health0)
        if isWeakAurasLoaded() and WeakAuras and WeakAuras.ScanEvents then
            WeakAuras.ScanEvents("TTK_UPDATE", ttk)
        end
        -- Non-WeakAuras path: anyone can listen via
        -- DrievEssentials.RegisterCallback(self, "TTK_UPDATE", function(event, ttk) ... end)
        if addon.callbacks then
            addon.callbacks:Fire("TTK_UPDATE", ttk)
        end
        if ttk <= 60 then
            text = format("00:%0.2d", ttk)
        else
            text = format("%d:%0.2d", ttk / 60, ttk % 60)
        end
    end

    getOrCreate().text:SetText(text)
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("UNIT_HEALTH")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("ENCOUNTER_START")
eventFrame:RegisterEvent("ENCOUNTER_END")
eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        applyFont()
        applyPosition()
        applyVisibility()
        env.health0, env.time0, env.mhealth, env.mtime = nil, nil, nil, nil

    elseif event == "UNIT_HEALTH" then
        local unit = ...
        if unit == "target" then updateTTK() end

    elseif event == "PLAYER_TARGET_CHANGED" then
        env.health0, env.time0, env.mhealth, env.mtime = nil, nil, nil, nil
        getOrCreate().text:SetText("")

    elseif event == "ENCOUNTER_START" then
        inBossFight = true
        applyVisibility()
        env.health0, env.time0, env.mhealth, env.mtime = nil, nil, nil, nil

    elseif event == "ENCOUNTER_END" then
        inBossFight = false
        applyVisibility()
        env.health0, env.time0, env.mhealth, env.mtime = nil, nil, nil, nil
        getOrCreate().text:SetText("")
    end
end)

addon.TTK = {
    getFrame         = getOrCreate,
    applyFont        = applyFont,
    applyPosition    = applyPosition,
    applyVisibility  = applyVisibility,
    savePosition     = savePosition,
    enterMoveMode    = enterMoveMode,
    leaveMoveMode    = leaveMoveMode,
    getPosition      = getPosition,
    setPosition      = setPosition,
}
