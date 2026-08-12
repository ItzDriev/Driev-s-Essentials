local addonName, addon = ...

-- ElvUI-flavoured tooltip skin. Recolors Blizzard's existing backdrop rather
-- than replacing its textures, so the master toggle cleanly restores the stock
-- look. Unit tooltips are rewritten into ElvUI's compact style: class-coloured
-- name, difficulty-coloured "<level> <race> <class>" line, green guild line,
-- health text on the bar, class/reaction border and health-bar outline. Plus
-- optional realm stripping, cursor-follow anchor and a movable Edit Mode anchor.
-- Not a full port — aura tooltips, inspect caching and ilvl lines are out.

-- addon.db only exists once Core has applied the active profile at
-- PLAYER_LOGIN. The hooks below are attached to Blizzard frames that can be
-- shown before that, so guard rather than index a nil profile.
local function isReady()
    return addon.db ~= nil and addon.db.settings ~= nil
end

local function getData()
    addon.db.settings.tooltip = addon.db.settings.tooltip or {}
    return addon.db.settings.tooltip
end

-- The frames this skin touches. ItemRefTooltip/ShoppingTooltips are item
-- comparisons (Shift-click links, comparing gear) — no unit content, so only
-- the backdrop recolor applies to them, never the unit-specific hooks below.
local SKINNED_FRAMES = { "GameTooltip", "ItemRefTooltip", "ShoppingTooltip1", "ShoppingTooltip2" }

local SKIN_BORDER = { 0.30, 0.31, 0.42, 1 }   -- matches UI.lua's C.tabBorder
local SKIN_BG     = { 0.090, 0.098, 0.165, 1 } -- matches UI.lua's C.panelDark

local REACTION_COLORS = {
    [1] = { 0.85, 0.20, 0.20 }, [2] = { 0.85, 0.20, 0.20 }, -- hated/hostile
    [3] = { 0.85, 0.20, 0.20 },                              -- unfriendly
    [4] = { 0.90, 0.85, 0.10 },                              -- neutral
    [5] = { 0.30, 0.85, 0.35 }, [6] = { 0.30, 0.85, 0.35 },   -- friendly/honored
    [7] = { 0.30, 0.85, 0.35 }, [8] = { 0.30, 0.85, 0.35 },   -- revered/exalted
}

-- Blizzard's own stock colors, captured the first time we touch each frame
-- (before we ever recolor it) so disabling the skin restores the exact
-- original look instead of a guessed approximation.
local originalColors = {}

-- Border colour when no class/reaction tint applies: items, spells, objects, and
-- units with no colour of their own. Same setting the fixed-border override
-- uses, so there's one colour to pick; the override only changes WHEN it applies.
local function restingBorder()
    local c = getData().borderColor or SKIN_BORDER
    return c[1], c[2], c[3], 1
end

local function backgroundColor()
    local d = getData()
    local c = d.bgColor or SKIN_BG
    return c[1], c[2], c[3], (d.bgOpacity or 100) / 100
end

-- Border color for the unit currently shown, or nil to leave the resting border.
local function unitBorderColor(unit)
    if UnitIsPlayer(unit) then
        local _, class = UnitClass(unit)
        local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
        if color then return color.r, color.g, color.b end
        return nil
    end
    local reaction = UnitReaction(unit, "player")
    local c = reaction and REACTION_COLORS[reaction]
    if c then return c[1], c[2], c[3] end
    return nil
end

-- The border colour a tooltip should have right now. Unit tooltips get the
-- class/reaction tint when colouring is on and the override off; everything else
-- gets the resting border. Both the OnShow skin and the unit post-call go
-- through this, so they can't disagree — previously each stamped its own and
-- whichever fired last won, which is what made the class border intermittent.
local function frameBorderColor(tt)
    local d = getData()
    if tt == GameTooltip and d.colorByUnit ~= false and not d.customBorder then
        local _, unit = tt:GetUnit()
        if unit then
            local r, g, b = unitBorderColor(unit)
            if r then return r, g, b, 1 end
        end
    end
    return restingBorder()
end

-- Applies (or with the master toggle off, restores) the backdrop recolor. Only
-- touches SetBackdropColor/SetBackdropBorderColor, never SetBackdrop, so
-- Blizzard's own template and insets stay intact and trivially revertible.
local function styleFrame(tt)
    if not isReady() then return end
    if not (tt and tt.SetBackdropColor and tt.GetBackdropColor) then return end

    local saved = originalColors[tt]
    if not saved then
        saved = { bg = { tt:GetBackdropColor() }, border = { tt:GetBackdropBorderColor() } }
        originalColors[tt] = saved
    end

    if getData().enabled == false then
        tt:SetBackdropColor(unpack(saved.bg))
        tt:SetBackdropBorderColor(unpack(saved.border))
        return
    end
    tt:SetBackdropColor(backgroundColor())
    tt:SetBackdropBorderColor(frameBorderColor(tt))
end

-- ── Health bar outline ──────────────────────────────────────────────────────
-- GameTooltipStatusBar is a bare texture with no frame, so there's nothing to
-- recolour — the outline has to be created. A sibling anchored around the bar
-- rather than a child, so the bar's texture can't draw over it.
local healthBorder
local function ensureHealthBorder()
    if healthBorder then return healthBorder end
    local bar = _G.GameTooltipStatusBar
    if not bar then return nil end

    local f = CreateFrame("Frame", nil, bar:GetParent(), "BackdropTemplate")
    f:SetPoint("TOPLEFT",     bar, "TOPLEFT",     -1,  1)
    f:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT",  1, -1)
    f:SetFrameLevel(math.max(bar:GetFrameLevel() - 1, 0))
    f:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,
    })
    f:Hide()

    -- The bar is shown and hidden per tooltip; the outline has to follow it or
    -- it would linger over item tooltips that have no health bar at all.
    bar:HookScript("OnShow", function() if f.__wanted then f:Show() end end)
    bar:HookScript("OnHide", function() f:Hide() end)

    healthBorder = f
    return f
end

local function styleHealthBorder(r, g, b)
    local d = getData()
    local f = ensureHealthBorder()
    if not f then return end

    local bar = _G.GameTooltipStatusBar
    local want = d.enabled ~= false and d.healthBorder ~= false and r ~= nil
    f.__wanted = want

    if not want then
        f:Hide()
        return
    end
    f:SetBackdropBorderColor(r, g, b, 1)
    f:SetShown(bar and bar:IsShown())
end

-- ── ElvUI-style unit reformatting ────────────────────────────────────────────
-- Blizzard's "Level 60 Human Mage (Player)" becomes a coloured "60 Human Mage",
-- with name and guild tinted. Existing FontStrings are rewritten rather than the
-- tooltip cleared and rebuilt, so lines other addons appended survive.

-- Blizzard's localized "Level" word, lowercased, so the level line can be found
-- regardless of client language. TOOLTIP_UNIT_LEVEL is "Level %s"; strip the
-- format bits down to the bare word.
local LEVEL_WORD = (TOOLTIP_UNIT_LEVEL or "Level %s"):gsub("%s?%%s%s?%-?", ""):lower()
local GREEN_HEX  = "00ff10"    -- ElvUI's guild green
local TAPPED     = { 0.6, 0.6, 0.6 }

local AFK_TAG = " |cffFFFFFF[|r|cffFF9900" .. (AFK or "AFK") .. "|r|cffFFFFFF]|r"
local DND_TAG = " |cffFFFFFF[|r|cffFF3333" .. (DND or "DND") .. "|r|cffFFFFFF]|r"

local function hex(r, g, b)
    return string.format("%02x%02x%02x", r * 255, g * 255, b * 255)
end

-- ElvUI uses GetCreatureDifficultyColor here (available on Classic Era); it
-- gives the proper red/orange/yellow/green/grey scale relative to the player,
-- including the trivial-level grey. Guarded with a plain-grey fallback.
local function levelDiffColor(level)
    if level and level > 0 and GetCreatureDifficultyColor then
        local ok, c = pcall(GetCreatureDifficultyColor, level)
        if ok and c then return c.r, c.g, c.b end
    end
    return 0.8, 0.8, 0.8
end

-- Class colour table for a player unit, reaction colour for anything else,
-- greyed if the mob is tap-denied (looted by someone else).
local function unitColor(unit)
    if UnitIsPlayer(unit) then
        local _, class = UnitClass(unit)
        local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
        if c then return c.r, c.g, c.b end
        return 1, 1, 1
    end
    if UnitIsTapDenied and UnitIsTapDenied(unit) then
        return TAPPED[1], TAPPED[2], TAPPED[3]
    end
    local reaction = UnitReaction(unit, "player")
    local c = reaction and _G.FACTION_BAR_COLORS and _G.FACTION_BAR_COLORS[reaction]
    if c then return c.r, c.g, c.b end
    return 0.8, 0.8, 0.8
end

-- Finds the first left-hand line whose text satisfies `pred`, returning the
-- FontString and its index. Starts at line 2 by default since line 1 is the
-- name.
local function findLine(tt, pred, from)
    local base = tt:GetName()
    if not base then return nil end
    for i = (from or 2), tt:NumLines() do
        local fs = _G[base .. "TextLeft" .. i]
        local text = fs and fs:GetText()
        if text and pred(text) then return fs, i end
    end
    return nil
end

local function isLevelLine(text)
    return text:lower():find(LEVEL_WORD, 1, true) ~= nil
end

-- Insert a left-hand line carrying `text` at position `idx`, pushing idx..n down
-- one. GameTooltip only grows via AddLine (append), so append a blank and copy
-- each line's text + colour up a slot. Needed because this client adds no guild
-- line of its own — there's nothing to rewrite, so we build one.
local function insertLineAt(tt, idx, text)
    local base = tt:GetName()
    if not base then return end
    local n = tt:NumLines()
    tt:AddLine(" ")   -- grow by one slot at the bottom
    for i = n + 1, idx + 1, -1 do
        local dst, src = _G[base .. "TextLeft" .. i], _G[base .. "TextLeft" .. (i - 1)]
        if dst and src then
            dst:SetText(src:GetText())
            dst:SetTextColor(src:GetTextColor())
            dst:Show()
        end
    end
    local target = _G[base .. "TextLeft" .. idx]
    if target then target:SetText(text); target:Show() end
end

-- Classification suffix for a mob (Rare / Elite / Boss ...), mirroring ElvUI.
local CLASSIFICATION = {
    rare      = " Rare",
    elite     = " Elite",
    rareelite = " Rare Elite",
    worldboss = " Boss",
}

local function reformatUnit(tt, unit)
    local nameFS = _G[(tt:GetName() or "") .. "TextLeft1"]
    local cr, cg, cb = unitColor(unit)

    if UnitIsPlayer(unit) then
        local localeClass = UnitClass(unit)
        local name, realm = UnitName(unit)

        -- Whole name line rebuilt with a colour code (not SetTextColor) so the
        -- AFK/DND tag can carry its own colours alongside the class-coloured
        -- name. Realm appended only when NOT hiding it.
        local away = (UnitIsAFK(unit) and AFK_TAG) or (UnitIsDND(unit) and DND_TAG) or ""
        local display = name or (UNKNOWN or "Unknown")
        if realm and realm ~= "" and not getData().hideRealm then
            display = display .. "-" .. realm
        end
        if nameFS then
            nameFS:SetFormattedText("|cff%s%s%s|r", hex(cr, cg, cb), display, away)
        end

        -- Guild line: green name, rank in brackets after it, matching ElvUI's
        -- guildRanks. Both parts independently toggleable. This client adds only name +
        -- level, so with no existing line to rewrite we insert one under the name.
        local guild, rank = GetGuildInfo(unit)
        local td = getData()
        if guild and td.showGuild ~= false then
            local text
            if td.showGuildRank ~= false and rank and rank ~= "" then
                text = string.format("<|cff%s%s|r> [|cff%s%s|r]", GREEN_HEX, guild, GREEN_HEX, rank)
            else
                text = string.format("<|cff%s%s|r>", GREEN_HEX, guild)
            end
            local gFS = findLine(tt, function(t) return t:find(guild, 1, true) end)
            if gFS then
                gFS:SetText(text)
            else
                insertLineAt(tt, 2, text)   -- right under the name
            end
        elseif guild then
            -- showGuild off: blank any guild line the client did add.
            local gFS = findLine(tt, function(t) return t:find(guild, 1, true) end)
            if gFS then gFS:SetText(""); gFS:Hide() end
        end

        -- Level line → "60 Gnome Warlock": difficulty-coloured level, race,
        -- class in class colour. Drops "Level " and "(Player)".
        local levelFS = findLine(tt, isLevelLine)
        if levelFS then
            local level = UnitLevel(unit)
            local race  = UnitRace(unit) or ""
            local lr, lg, lb = levelDiffColor(level)
            local line = string.format("|cff%s%s|r %s",
                hex(lr, lg, lb), (level and level > 0) and level or "??", race)
            if localeClass then
                line = line .. string.format(" |cff%s%s|r", hex(cr, cg, cb), localeClass)
            end
            levelFS:SetText(line)
        end
    else
        -- NPC name recoloured by reaction.
        local name = UnitName(unit)
        if nameFS and name then
            nameFS:SetFormattedText("|cff%s%s|r", hex(cr, cg, cb), name)
        end

        -- Level line → "<level><classification> <creatureType> (PvP)".
        local levelFS, levelIdx = findLine(tt, isLevelLine)
        if levelFS then
            local level = UnitLevel(unit)
            local lr, lg, lb = levelDiffColor(level)
            local classStr = CLASSIFICATION[UnitClassification(unit)] or ""
            local creatureType = UnitCreatureType(unit) or ""
            local pvpFlag = (UnitIsPVP(unit) and _G.PVP) and (" (" .. _G.PVP .. ")") or ""
            levelFS:SetFormattedText("|cff%s%s|r%s %s%s",
                hex(lr, lg, lb), (level and level > 0) and level or "??",
                classStr, creatureType, pvpFlag)

            -- Blizzard sometimes puts the creature type on its own line below;
            -- with it now on the level line, hide the duplicate.
            local base = tt:GetName()
            local nextFS = levelIdx and base and _G[base .. "TextLeft" .. (levelIdx + 1)]
            if nextFS and nextFS:GetText() == creatureType and creatureType ~= "" then
                nextFS:SetText("")
                nextFS:Hide()
            end
        end
    end
end

-- ── Health text on the status bar ────────────────────────────────────────────
-- ElvUI shows the health as centred text on the bar itself (short values, e.g.
-- "12.3k / 12.3k", or "Dead"), rather than as an extra line under the tooltip.
local function shortValue(v)
    v = v or 0
    if v >= 1e6 then return string.format("%.1fm", v / 1e6) end
    if v >= 1e3 then return string.format("%.1fk", v / 1e3) end
    return tostring(v)
end

local healthText
local function ensureHealthText()
    if healthText then return healthText end
    local bar = _G.GameTooltipStatusBar
    if not bar then return nil end
    local fs = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("CENTER", bar, "CENTER", 0, 0)
    fs:SetTextColor(1, 1, 1)
    healthText = fs
    return fs
end

local function updateHealthText(unit)
    local d = getData()
    local fs = ensureHealthText()
    if not fs then return end

    if not (d.enabled ~= false and d.showHealth) then fs:SetText(""); return end
    if not (unit and UnitExists(unit)) then fs:SetText(""); return end

    if UnitIsDeadOrGhost(unit) then
        fs:SetText(DEAD or "Dead")
        return
    end
    local cur, max = UnitHealth(unit), UnitHealthMax(unit)
    if not (max and max > 0) then fs:SetText(""); return end
    fs:SetText(shortValue(cur) .. " / " .. shortValue(max))
end

local function onTooltipSetUnit(tt)
    if not isReady() then return end
    local d = getData()
    if d.enabled == false then return end

    local _, unit = tt:GetUnit()
    if not unit then return end

    -- The frame border goes through the shared decision so it always agrees with the
    -- OnShow skin. The health-bar outline stays unit-coloured regardless — that's
    -- the whole point of it.
    if tt.SetBackdropBorderColor then
        tt:SetBackdropBorderColor(frameBorderColor(tt))
    end
    local ur, ug, ub = unitBorderColor(unit)
    styleHealthBorder(ur, ug, ub)

    reformatUnit(tt, unit)
    updateHealthText(unit)

    -- Widen the tooltip so the on-bar health text can't overflow a short
    -- tooltip (a low-level mob with a one-word name). ElvUI does the same via
    -- SetMinimumWidth in its OnTooltipSetUnit.
    if healthText and tt.SetMinimumWidth then
        local w = healthText:GetStringWidth()
        if w and w > 0 then tt:SetMinimumWidth(w + 12) end
    end

    tt:Show() -- re-flow to fit the rewritten lines
end

-- ── Movable anchor ──────────────────────────────────────────────────────────
-- A placeholder frame the tooltip parks against. It exists only to be dragged in
-- Edit Mode; the tooltip anchors its BOTTOMRIGHT to it, matching where
-- Blizzard's default anchor sits.
local anchorFrame
local function getAnchor()
    if anchorFrame then return anchorFrame end
    local f = CreateFrame("Frame", "DrievTooltipAnchor", UIParent)
    f:SetSize(130, 32)
    f:SetClampedToScreen(true)
    f:SetMovable(true)

    local d = isReady() and getData() or nil
    if d and d.anchorX and d.anchorY then
        f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", d.anchorX, d.anchorY)
    else
        -- Roughly where Blizzard parks the tooltip by default, so switching the
        -- option on doesn't move it somewhere surprising.
        f:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -100, 180)
    end

    local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER")
    label:SetText("Tooltip")
    label:SetTextColor(0.75, 0.75, 0.80)
    f.label = label

    -- Hidden until Edit Mode shows it. Otherwise the useAnchor hook, which uses this
    -- purely as an anchor point, would leave it and its label visible during play.
    -- Anchoring to a hidden frame still works. TTK and RaidFrames do the same.
    f:Hide()

    anchorFrame = f
    return f
end

local function applyAnchorPosition()
    local d, f = getData(), getAnchor()
    if not (d.anchorX and d.anchorY) then return end
    f:ClearAllPoints()
    f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", d.anchorX, d.anchorY)
end

-- The mover interface UI.EnterMoveMode expects, same shape as TTK's.
local mover = {}

function mover.getFrame() return getAnchor() end

function mover.getPosition()
    local f = getAnchor()
    return f:GetLeft() or 0, f:GetBottom() or 0
end

function mover.setPosition(x, y)
    local d = getData()
    d.anchorX, d.anchorY = x, y
    applyAnchorPosition()
end

function mover.savePosition()
    local f = anchorFrame
    if not f then return end
    local d = getData()
    d.anchorX, d.anchorY = f:GetLeft(), f:GetBottom()
end

-- The anchor is invisible outside Edit Mode: it's a positioning handle, not
-- something to look at while playing.
function mover.applyVisibility()
    local f = getAnchor()
    f:Hide()
end

function mover.enterMoveMode()
    local f = getAnchor()
    f:Show()
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
    local f = anchorFrame
    if not f then return end
    addon.HideEditBox(f)
    f:EnableMouse(false)
    f:SetScript("OnMouseDown", nil)
    f:SetScript("OnMouseUp", nil)
    f:Hide()
end

local function init()
    for _, name in ipairs(SKINNED_FRAMES) do
        local tt = _G[name]
        if tt then
            tt:HookScript("OnShow", styleFrame)
        end
    end
    -- Unit reformatting. The 1.14.4 / 10.0.2 rework retired the OnTooltipSetUnit
    -- script — HookScript on it never fires on modern Classic Era, so all of
    -- reformatUnit silently did nothing. The replacement is a TooltipDataProcessor
    -- post-call; fall back to the old script only on clients predating it.
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
       and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tt)
            -- Fires for every unit tooltip; we only own GameTooltip (health text /
            -- outline are tied to GameTooltipStatusBar).
            if tt == GameTooltip then onTooltipSetUnit(tt) end
        end)
    elseif GameTooltip then
        GameTooltip:HookScript("OnTooltipSetUnit", onTooltipSetUnit)
    end

    -- Health regenerates while the tooltip is open, so the on-bar text has to
    -- follow the bar's value rather than only being set once at mouseover.
    local bar = _G.GameTooltipStatusBar
    if bar then
        bar:HookScript("OnValueChanged", function()
            if not isReady() then return end
            local _, unit = GameTooltip:GetUnit()
            updateHealthText(unit)
        end)
    end

    -- GameTooltip_SetDefaultAnchor is what nearly every stock tooltip call routes
    -- through, so hooking it covers cursor-anchor behaviour addon-wide rather than
    -- only for manually-owned tooltips.
    if GameTooltip_SetDefaultAnchor then
        hooksecurefunc("GameTooltip_SetDefaultAnchor", function(tt, parent)
            if not isReady() then return end
            local d = getData()
            if d.enabled == false then return end

            if d.anchorCursor then
                tt:SetOwner(parent or UIParent, "ANCHOR_CURSOR")
            elseif d.useAnchor then
                -- ANCHOR_NONE hands placement entirely to us; the tooltip's
                -- bottom-right meets the anchor, which is how Blizzard's own
                -- default anchor is oriented.
                tt:SetOwner(parent or UIParent, "ANCHOR_NONE")
                tt:ClearAllPoints()
                tt:SetPoint("BOTTOMRIGHT", getAnchor(), "BOTTOMRIGHT", 0, 0)
            end
        end)
    end
end

-- Re-styles the tooltip if one happens to be open right now, so toggling a
-- checkbox in the settings window previews instantly instead of waiting for
-- the next mouseover.
local function refresh()
    if not isReady() then return end
    if GameTooltip and GameTooltip:IsShown() then
        styleFrame(GameTooltip)
    end
    -- Switching profiles can bring a different saved anchor position with it.
    if anchorFrame then applyAnchorPosition() end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    init()
    f:UnregisterEvent("PLAYER_LOGIN")
end)

addon.Tooltip = {
    refresh         = refresh,
    -- Mover interface, collected by UI.EnterMoveMode via UI.movableNames.
    getFrame        = mover.getFrame,
    getPosition     = mover.getPosition,
    setPosition     = mover.setPosition,
    savePosition    = mover.savePosition,
    applyVisibility = mover.applyVisibility,
    enterMoveMode   = mover.enterMoveMode,
    leaveMoveMode   = mover.leaveMoveMode,
    -- Read by UI.EnterMoveMode to skip a disabled module in Edit Mode — the
    -- anchor only matters when "Park it on the movable anchor" is enabled;
    -- with cursor-anchor or Blizzard's default anchor in use it does nothing.
    isEnabled       = function() return isReady() and getData().useAnchor and true or false end,
}
