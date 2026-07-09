local addonName, addon = ...

local function updatePosition(button)
    local angle  = math.rad(addon.db.minimap.angle or 225)
    local radius = 80
    local x = math.cos(angle) * radius
    local y = math.sin(angle) * radius
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function onDragUpdate(self)
    local mx, my   = Minimap:GetCenter()
    local px, py   = GetCursorPosition()
    local scale    = Minimap:GetEffectiveScale()
    px, py = px / scale, py / scale
    addon.db.minimap.angle = math.deg(math.atan2(py - my, px - mx))
    updatePosition(self)
end

function addon.CreateMinimapButton()
    if addon.minimapButton then return addon.minimapButton end

    local button = CreateFrame("Button", "DrievSettingsMinimapButton", Minimap)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:SetSize(31, 31)
    button:RegisterForClicks("AnyUp")
    button:RegisterForDrag("LeftButton")
    button:SetMovable(true)

    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Gear_01")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 1)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    button.icon = icon

    -- Red ring tint over the standard tracking border for the dark/red theme.
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(54, 54)
    border:SetPoint("TOPLEFT", 0, 0)
    border:SetVertexColor(0.984, 0.173, 0.212)

    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    button:SetScript("OnClick", function(_, btnKey)
        if btnKey == "RightButton" or btnKey == "LeftButton" then
            addon.ToggleUI()
        end
    end)

    button:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", onDragUpdate)
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cfffb2c36Driev's|r |cffffffffEssentials|r")
        GameTooltip:AddLine("|cffaaaaaaClick:|r Open settings", 1, 1, 1)
        GameTooltip:AddLine("|cffaaaaaaDrag:|r Move button", 1, 1, 1)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)

    updatePosition(button)
    if addon.db.minimap.hide then button:Hide() end
    addon.minimapButton = button
    return button
end

-- Re-applies position/visibility from current settings (e.g. after a profile
-- switch changes the saved angle or hide state).
local function refresh()
    local button = addon.minimapButton
    if not button then return end
    updatePosition(button)
    if addon.db.minimap.hide then button:Hide() else button:Show() end
end

addon.Minimap = { refresh = refresh }
