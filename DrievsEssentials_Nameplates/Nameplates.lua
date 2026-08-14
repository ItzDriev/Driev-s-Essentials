-- Nameplates module: the engine. Blizzard's plate frame is hidden and ours is
-- parented to the same base plate, so the base keeps doing the secure job of
-- positioning and click-targeting while everything drawn on it is ours.
local addon = _G.DrievEssentials
if not addon then return end

local Data = addon.NameplatesData
if not Data then return end

local NP = {}
addon.Nameplates = NP

local LSM   = LibStub and LibStub("LibSharedMedia-3.0", true)
local WHITE = "Interface\\Buttons\\WHITE8x8"

-- Aura duration reconstruction (core addon). Absent on a client that reports
-- real durations, so every use of it is guarded.
local Durations = addon.Durations

local function cfg()
    return addon.db and addon.db.settings and addon.db.settings.nameplates
end

local function isEnabled()
    local d = cfg()
    return (d and d.enabled == true) and true or false
end

-- ── Shared media ─────────────────────────────────────────────────────────────
-- Fetch's noDefault returns nil for uninstalled media rather than substituting
-- something unrelated, hence the explicit Blizzard fallbacks.
local function barTexture(name)
    return (LSM and name and LSM:Fetch("statusbar", name, true))
        or "Interface\\TargetingFrame\\UI-StatusBar"
end

-- ── Fonts ────────────────────────────────────────────────────────────────────
-- Every string on a plate is styled from core's shared font block (Font.lua):
-- face, size, outline, offset and drop shadow. The general block is the baseline
-- for all of them; a per-element block sits IN FRONT of it and only overrides
-- what it actually sets, which is why an element that was only ever given a
-- typeface still follows the general size and outline.
local FONT_DEFAULT = addon.Font.New({ font = "Expressway", size = 9 })

-- The keys each block used before it was a block. General kept a bare face name
-- beside fontSize/fontOutline; the per-element ones were the face alone, which
-- Adopt handles without a map.
local GENERAL_LEGACY = { size = "fontSize", outline = "fontOutline" }
local TOT_LEGACY     = { size = "totSize", outline = "totOutline", x = "totX", y = "totY" }

local function generalFont(g)
    return addon.Font.Adopt(g, "font", GENERAL_LEGACY)
end

-- The FLAG decides, not whether a font is picked, so unticking returns to the
-- general font instead of keeping whatever the picker was last left on. nil means
-- "nothing of its own", which is what Font.Apply reads as "use the fallback".
local function elementFont(g, key, legacy)
    if not g[key .. "Enabled"] then return nil end
    return addon.Font.Adopt(g, key, legacy)
end

-- Target of target is the exception: its size, outline, offset and shadow are its
-- own whether or not its tick box is on — that box has only ever governed the
-- face. Handed back through one reused scratch table, since this runs per plate.
local totScratch = {}

local function totFont(g)
    local blk = addon.Font.Adopt(g, "totFont", TOT_LEGACY)
    wipe(totScratch)
    for k, v in pairs(blk) do totScratch[k] = v end
    -- nil, not the stored face: Font.Apply then falls through to the general
    -- block, which is what "doesn't use its own font" means.
    if not g.totFontEnabled then totScratch.font = nil end
    return totScratch
end

-- ── Small helpers ────────────────────────────────────────────────────────────
local function pct(v, fallback)
    return (tonumber(v) or fallback or 100) / 100
end

-- The interface scale. Everything a plate draws is sized against this rather
-- than WorldFrame's fixed scale of 1 — see the note in updateStyle.
local function uiScale()
    local s = UIParent and UIParent:GetEffectiveScale()
    return (s and s > 0) and s or 1
end

local function rgb(t, r, g, b)
    if type(t) == "table" then return t[1] or r or 1, t[2] or g or 1, t[3] or b or 1 end
    return r or 1, g or 1, b or 1
end

local function shortNum(v)
    v = v or 0
    if v >= 1000000 then return string.format("%.1fm", v / 1000000) end
    if v >= 1000    then return string.format("%.1fk", v / 1000) end
    return tostring(math.floor(v))
end

-- GUIDs look like "Creature-0-3777-533-15170-16142-000136DF91"; the sixth field
-- is the NPC (creature template) ID. Players have no such ID, hence the nil.
local function npcIDFromGUID(guid)
    if not guid then return nil end
    local kind, _, _, _, _, id = strsplit("-", guid)
    if kind == "Creature" or kind == "Vehicle" or kind == "Pet" then
        return tonumber(id)
    end
    return nil
end

-- Friendly units reuse the matching enemy group's layout.
local function unitKind(unit)
    local player = UnitIsPlayer(unit)
    local hostile = UnitCanAttack("player", unit)
    if player then return hostile and "enemyPlayer" or "friendlyPlayer" end
    return hostile and "enemyNPC" or "friendlyNPC"
end

local function groupFor(d, kind)
    if kind == "enemyPlayer" or kind == "friendlyPlayer" then return d.enemyPlayer end
    return d.enemyNPC
end

-- ── Blizzard's own plate ─────────────────────────────────────────────────────
-- Blizzard re-shows plate.UnitFrame whenever it reassigns a unit, so a one-off
-- Hide() doesn't hold. The OnShow hook is installed once per plate and gated on
-- a flag, which is what lets the module be switched off without a /reload.
local function setBlizzardShown(base, show)
    local uf = base and base.UnitFrame
    if not uf then return end
    uf.drievForceHide = not show
    if not uf.drievHooked then
        uf.drievHooked = true
        uf:HookScript("OnShow", function(self)
            if self.drievForceHide then self:Hide() end
        end)
    end
    if show then uf:Show() else uf:Hide() end
end

-- ── Pixel-snapped borders ────────────────────────────────────────────────────
-- A backdrop's edgeFile is one tiled art file whose sides and corners each round
-- to physical pixels independently. Plates are scaled (camera + our own
-- settings), so that rounding differs per side and the ring wobbles in
-- thickness. Four flat textures each snapped to whole pixels can't. PixelUtil is
-- absent on older clients, hence the passthrough fallbacks.
local pxSetPoint = (PixelUtil and PixelUtil.SetPoint)
    or function(region, ...) region:SetPoint(...) end
local pxSetWidth = (PixelUtil and PixelUtil.SetWidth)
    or function(region, w) region:SetWidth(w) end
local pxSetHeight = (PixelUtil and PixelUtil.SetHeight)
    or function(region, h) region:SetHeight(h) end

local BORDER_SIDES = { "top", "bottom", "left", "right" }

local function createBorder(parent, subLayer)
    local border = {}
    for _, side in ipairs(BORDER_SIDES) do
        local tex = parent:CreateTexture(nil, "OVERLAY", nil, subLayer)
        tex:SetTexture(WHITE)
        border[side] = tex
    end
    return border
end

local function setBorderShown(border, shown)
    for _, side in ipairs(BORDER_SIDES) do
        border[side]:SetShown(shown and true or false)
    end
end

local function paintBorder(border, r, g, b, a)
    for _, side in ipairs(BORDER_SIDES) do
        border[side]:SetVertexColor(r, g, b, a or 1)
    end
end

-- Edges sit OUTSIDE `target`, pushed a further `inset` out so rings can stack
-- without either knowing the other's thickness. All four snap with the same size
-- against the same effective scale, so they round to the same pixel count.
-- `size` doubles as the minimum-pixel floor, so a scaled-down plate can't round
-- its border away to nothing.
--
-- CORNERS: only the side strips measure against `target`; top and bottom span
-- between the sides' outer edges, so corners close by construction. Arithmetic
-- fails here — Round(size + inset) ~= Round(inset) + Round(size).
local function layoutBorder(border, target, size, inset)
    inset = inset or 0

    border.left:ClearAllPoints()
    pxSetPoint(border.left, "TOPRIGHT",    target, "TOPLEFT",    -inset,  inset)
    pxSetPoint(border.left, "BOTTOMRIGHT", target, "BOTTOMLEFT", -inset, -inset)
    pxSetWidth(border.left, size, size)

    border.right:ClearAllPoints()
    pxSetPoint(border.right, "TOPLEFT",    target, "TOPRIGHT",    inset,  inset)
    pxSetPoint(border.right, "BOTTOMLEFT", target, "BOTTOMRIGHT", inset, -inset)
    pxSetWidth(border.right, size, size)

    -- Plain SetPoint, not the snapping one: these offsets are zero, so there is
    -- nothing here to round and nothing that can drift off the sides.
    border.top:ClearAllPoints()
    border.top:SetPoint("BOTTOMLEFT",  border.left,  "TOPLEFT",  0, 0)
    border.top:SetPoint("BOTTOMRIGHT", border.right, "TOPRIGHT", 0, 0)
    pxSetHeight(border.top, size, size)

    border.bottom:ClearAllPoints()
    border.bottom:SetPoint("TOPLEFT",  border.left,  "BOTTOMLEFT",  0, 0)
    border.bottom:SetPoint("TOPRIGHT", border.right, "BOTTOMRIGHT", 0, 0)
    pxSetHeight(border.bottom, size, size)
end

-- ── Plate construction ───────────────────────────────────────────────────────
local plates = {}   -- [blizzard base plate] = our frame
local active = {}   -- [unit token]          = our frame
-- [unit GUID] = our frame. The combat log identifies units by GUID only, so an
-- aura event has no way back to a plate without this.
local byGUID = {}

-- ── Aura rows ────────────────────────────────────────────────────────────────
-- One row per aura kind, sized to fit however many icons show; the growth
-- setting picks which edge pins to the bar.
local function createAuraRow(f)
    local row = CreateFrame("Frame", nil, f)
    row:SetSize(1, 1)
    row.icons = {}
    row.shown = 0
    row:Hide()
    return row
end

-- Icons are built on demand and pooled on the row, so a mob wearing eight
-- tracked debuffs costs eight frames once, not once per pull.
local function auraIcon(row, index)
    local b = row.icons[index]
    if b then return b end

    b = CreateFrame("Frame", nil, row)
    b:Hide()

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints(b)
    -- The standard icon-art crop, same as the cast and quest icons: 64x64 files
    -- with a border baked in that everything else trims off the same way.
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- Four flat, pixel-snapped textures rather than a backdrop edge, for exactly
    -- the reason spelled out above createBorder: these sit on a scaled frame.
    b.border = createBorder(b, 5)

    b.cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    b.cd:SetAllPoints(b)
    b.cd:SetDrawEdge(false)
    -- The swipe is the point, its numbers aren't: this module draws the timer itself
    -- so it follows the font settings, and so OmniCC doesn't stack a second one.
    if b.cd.SetHideCountdownNumbers then b.cd:SetHideCountdownNumbers(true) end

    -- Text on its own frame above the cooldown, so a nearly-expired aura's swipe
    -- doesn't darken its own numbers into nothing.
    local text = CreateFrame("Frame", nil, b)
    text:SetAllPoints(b)
    b.textLayer = text

    b.count = text:CreateFontString(nil, "OVERLAY")
    b.count:SetPoint("TOPRIGHT", b, "TOPRIGHT", 1, 1)
    b.count:SetJustifyH("RIGHT")

    -- Inside the icon rather than under it: the two rows stack, and a timer
    -- hanging below the debuff row would land on the health bar.
    b.timer = text:CreateFontString(nil, "OVERLAY")
    b.timer:SetPoint("BOTTOM", b, "BOTTOM", 0, 0)
    b.timer:SetJustifyH("CENTER")

    local lvl = row:GetFrameLevel() or 0
    b:SetFrameLevel(lvl + 1)
    b.cd:SetFrameLevel(lvl + 2)
    text:SetFrameLevel(lvl + 3)

    row.icons[index] = b
    return b
end

-- Every piece carries an EXPLICIT frame level, so raising the target's plate
-- must move the whole stack — bumping only `f` leaves its health bar at the old
-- absolute level, under the frames we were clearing.
local function setPlateLevel(f, level)
    f:SetFrameLevel(level)
    f.health:SetFrameLevel(level + 1)
    f.deco:SetFrameLevel(level + 2)
    f.overlay:SetFrameLevel(level + 3)
    f.cast:SetFrameLevel(level + 1)
    f.castOverlay:SetFrameLevel(level + 3)
    -- With the cast bar: both are bars drawn outside the plate's own rect.
    if f.totBar then f.totBar:SetFrameLevel(level + 1) end
    -- One above the overlay it sits on, so the coloured copy of the name lands
    -- over the spent one rather than under it.
    if f.totClip then f.totClip:SetFrameLevel(level + 4) end
    -- Child frame levels are absolute, not inherited, so re-levelling must walk the
    -- pooled aura icons too.
    if f.iconRows then
        for _, row in ipairs(f.iconRows) do
            row:SetFrameLevel(level + 4)
            for _, b in ipairs(row.icons) do
                b:SetFrameLevel(level + 5)
                b.cd:SetFrameLevel(level + 6)
                b.textLayer:SetFrameLevel(level + 7)
            end
        end
    end
    -- Above every one of them: see buildPlate. This is the top of the plate.
    if f.indLayer then f.indLayer:SetFrameLevel(level + 8) end
end

local function buildPlate(base)
    local f = CreateFrame("Frame", nil, base)
    f:SetPoint("CENTER", base, "CENTER", 0, 0)
    f:SetSize(124, 12)
    f:Hide()

    local lvl = (base:GetFrameLevel() or 0) + 1

    local health = CreateFrame("StatusBar", nil, f)
    health:SetAllPoints(f)
    health:SetMinMaxValues(0, 1)
    health:SetValue(1)
    f.health = health

    local hbg = health:CreateTexture(nil, "BACKGROUND")
    hbg:SetAllPoints(health)
    hbg:SetTexture(WHITE)
    f.healthBG = hbg

    -- ARTWORK sub-layer 3 sits over the bar's fill but under the overlay's text. ADD
    -- blend lightens whatever colour the bar is rather than washing it grey.
    local hover = health:CreateTexture(nil, "ARTWORK", nil, 3)
    hover:SetAllPoints(health)
    hover:SetTexture(WHITE)
    hover:SetBlendMode("ADD")
    hover:SetVertexColor(1, 1, 1)
    hover:Hide()
    f.hover = hover

    -- Borders live here, not on `f`: `f` gets scaled, so a border parented to it
    -- would fatten when the plate is targeted. This frame counter-scales to undo
    -- `f`'s scale, pinning its effective scale to the base plate's. Children anchor
    -- to the bars, which resolves in screen space across the difference.
    local deco = CreateFrame("Frame", nil, f)
    deco:SetPoint("CENTER", f, "CENTER", 0, 0)
    deco:SetSize(1, 1)
    f.deco = deco

    -- Health outline (sub-layer 5) and the target ring just outside it (6).
    f.border = createBorder(deco, 5)

    -- Text on its own frame above the bar: FontStrings drawn directly on `f` would
    -- sit UNDER the health bar's textures, since the bar is a child at a higher level.
    local overlay = CreateFrame("Frame", nil, f)
    overlay:SetAllPoints(f)
    f.overlay = overlay

    f.name = overlay:CreateFontString(nil, "OVERLAY")
    f.name:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 0, 3)
    f.name:SetJustifyH("LEFT")

    f.level = overlay:CreateFontString(nil, "OVERLAY")
    f.level:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", 0, 3)
    f.level:SetJustifyH("RIGHT")

    f.healthText = overlay:CreateFontString(nil, "OVERLAY")
    f.healthText:SetPoint("RIGHT", health, "RIGHT", -2, 0)
    f.healthText:SetJustifyH("RIGHT")

    -- Deliberately given NO width: a FontString without one is exactly as wide as
    -- its text, so pinning its right edge makes a longer name grow leftwards.
    -- Anchored in updateStyle, which knows whether a cast bar is below.
    f.totText = overlay:CreateFontString(nil, "OVERLAY")
    f.totText:SetJustifyH("RIGHT")
    f.totText:Hide()

    -- Draining-name mode draws the name TWICE: this one underneath in the spent
    -- colour, and a coloured copy inside a frame cut to the health fraction. A
    -- FontString has no SetTexCoord, so clipping the frame is the only way to end
    -- the colour mid-letter. SetClipsChildren is checked, not assumed — without it
    -- the copy draws whole and the mode silently does nothing.
    local totClip = CreateFrame("Frame", nil, overlay)
    if totClip.SetClipsChildren then
        totClip:SetClipsChildren(true)
        f.totCanClip = true
    end
    totClip:Hide()
    f.totClip = totClip

    -- No width and anchored by its LEFT: the string runs off the clip's right
    -- edge and gets cut there, which is what makes the spend read right to left.
    f.totFill = totClip:CreateFontString(nil, "OVERLAY")
    f.totFill:SetJustifyH("LEFT")
    f.totFill:SetPoint("TOPLEFT", totClip, "TOPLEFT", 0, 0)

    -- A child of `f` rather than the overlay, so setPlateLevel owns its depth.
    -- Fractional min/max, set once: the bar's width is the NAME's width, which
    -- changes per unit, so the value must be a fraction of a fixed range.
    local totBar = CreateFrame("StatusBar", nil, f)
    totBar:SetMinMaxValues(0, 1)
    totBar:SetValue(1)
    totBar:Hide()
    f.totBar = totBar

    f.totBarBG = totBar:CreateTexture(nil, "BACKGROUND")
    f.totBarBG:SetAllPoints(totBar)
    f.totBarBG:SetTexture(WHITE)

    -- Target highlight: a second ring immediately outside the health bar's own
    -- outline, so it reads as an outline rather than tinting the bar itself.
    f.glow = createBorder(deco, 6)
    setBorderShown(f.glow, false)

    -- Sub-layer 6 puts these over the name and health text. Built here and hidden
    -- when unused — the frame is pooled, so picking up a marked mob must never have
    -- to create anything.
    f.raidIcon = overlay:CreateTexture(nil, "OVERLAY", nil, 6)
    f.raidIcon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
    f.raidIcon:Hide()

    f.questIcon = overlay:CreateTexture(nil, "OVERLAY", nil, 6)
    -- Standard icon-art crop: these are 64x64 icons with a border baked in that
    -- everything else in the game trims off the same way.
    f.questIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.questIcon:Hide()

    -- These four don't change while the plate is on the unit, so they're worked out
    -- on handover rather than on the tick. Each keeps its own crop: faction art and
    -- classification atlases crop differently from a spell icon.
    f.factionIcon = overlay:CreateTexture(nil, "OVERLAY", nil, 6)
    f.factionIcon:Hide()

    f.eliteIcon = overlay:CreateTexture(nil, "OVERLAY", nil, 6)
    f.eliteIcon:Hide()

    f.rareIcon = overlay:CreateTexture(nil, "OVERLAY", nil, 6)
    f.rareIcon:Hide()

    f.petIcon = overlay:CreateTexture(nil, "OVERLAY", nil, 6)
    f.petIcon:Hide()

    -- Its own frame rather than `overlay`: this is the one thing drawn OUTSIDE the
    -- health bar, so it overlaps the aura rows and edge icons, which sit at higher
    -- levels than the overlay. Anchored to `f`, covering the same rect.
    local indLayer = CreateFrame("Frame", nil, f)
    indLayer:SetAllPoints(f)
    f.indLayer = indLayer

    -- Six textures built either way: a preset draws EITHER four corners OR two
    -- sides, and the unused set is hidden — switching preset never rebuilds frames.
    f.indCorners, f.indSides = {}, {}
    for i = 1, 4 do
        local t = indLayer:CreateTexture(nil, "OVERLAY", nil, 7)
        t:Hide()
        f.indCorners[i] = t
    end
    for i = 1, 2 do
        local t = indLayer:CreateTexture(nil, "OVERLAY", nil, 7)
        t:Hide()
        f.indSides[i] = t
    end

    -- ── Cast bar ─────────────────────────────────────────────────────────────
    local cast = CreateFrame("StatusBar", nil, f)
    cast:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -3)
    cast:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", 0, -3)
    cast:SetHeight(10)
    cast:SetMinMaxValues(0, 1)
    cast:Hide()
    f.cast = cast

    local cbg = cast:CreateTexture(nil, "BACKGROUND")
    cbg:SetAllPoints(cast)
    cbg:SetTexture(WHITE)
    f.castBG = cbg

    local castOverlay = CreateFrame("Frame", nil, cast)
    castOverlay:SetAllPoints(cast)
    f.castOverlay = castOverlay

    -- On `deco`, not castOverlay, for the same reason as the health outline: the
    -- cast bar is inside the scaled plate and its border must not scale with it.
    f.castBorder = createBorder(deco, 5)

    f.castIcon = castOverlay:CreateTexture(nil, "ARTWORK")
    f.castIcon:SetPoint("RIGHT", cast, "LEFT", -3, 0)
    f.castIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    f.castName = castOverlay:CreateFontString(nil, "OVERLAY")
    f.castName:SetPoint("LEFT", cast, "LEFT", 3, 0)
    f.castName:SetJustifyH("LEFT")

    f.castTime = castOverlay:CreateFontString(nil, "OVERLAY")
    f.castTime:SetPoint("RIGHT", cast, "RIGHT", -3, 0)
    f.castTime:SetJustifyH("RIGHT")

    -- ── Aura rows ────────────────────────────────────────────────────────────
    -- Built empty and anchored per-update, since both the anchor point and the
    -- strip's width depend on how many auras are showing.
    f.auraRows = {
        buffs   = createAuraRow(f),
        debuffs = createAuraRow(f),
    }

    -- Same kind of row, different feed and a corner of its own: boss mod timers
    -- go off the health bar's top left, clear of the two above.
    f.bossRow = createAuraRow(f)

    -- The special buff frames, keyed by frame id and built on demand — there are
    -- none until something is ticked onto one, and a plate that never meets a
    -- tracked aura never pays for them.
    f.specialRows = {}

    -- Every icon row, for passes that don't care which feed a row is on (frame
    -- levels, clearing on handover, ticking countdowns). Keyed rows above for those
    -- that do. Special frames append themselves as they're built.
    f.iconRows = { f.auraRows.buffs, f.auraRows.debuffs, f.bossRow }

    f.baseLevel = lvl
    setPlateLevel(f, lvl)
    return f
end

local function getPlate(base)
    local f = plates[base]
    if not f then
        f = buildPlate(base)
        plates[base] = f
    end
    return f
end

-- Split out of updateStyle because layoutBorder's pixel snapping resolves
-- against the plate's effective scale AT CALL TIME, so a rescale makes the
-- snapped sizes stale. `f.borderScale` records what they last snapped against.
local function layoutPlateBorders(f)
    local d = cfg()
    if not d then return end
    local g   = d.general
    local tgt = d.target or {}

    local pr, pg, pb = rgb(g.borderColor, 0, 0, 0)
    local bs = math.max(0, math.floor((tonumber(g.borderSize) or 1) + 0.5))

    -- Name-only plates have no bar to outline, and a ring drawn round the empty
    -- space where one would have been is worse than no ring at all.
    f.borderOn = bs > 0 and not f.nameOnly
    if f.borderOn then
        layoutBorder(f.border, f.health, bs, 0)
        paintBorder(f.border, pr, pg, pb, 1)
        setBorderShown(f.border, true)
        layoutBorder(f.castBorder, f.cast, bs, 0)
        paintBorder(f.castBorder, pr, pg, pb, 1)
    else
        setBorderShown(f.border, false)
    end
    -- The cast outline follows the cast BAR's visibility, not just the setting:
    -- it lives on `deco` now, which is always shown, so nothing hides it for us.
    setBorderShown(f.castBorder, f.borderOn and f.cast:IsShown())

    -- The target ring is pushed out by the health outline's thickness, so the two
    -- sit flush as inner black / outer white rather than smearing into one band.
    local hs = math.max(1, math.floor((tonumber(tgt.highlightSize) or 2) + 0.5))
    local hr, hg, hb = rgb(tgt.highlightColor, 1, 1, 1)
    layoutBorder(f.glow, f.health, hs, bs)
    paintBorder(f.glow, hr, hg, hb, 1)

    -- Tracked on `deco`, the frame the snapping resolved against. Reading it off `f`
    -- would see the target-scale animation and re-snap every frame of it.
    f.borderScale = f.deco:GetEffectiveScale()
end

-- Hiding the cast bar must take its outline with it: those textures are on
-- `deco`, which is always shown, so without this the outline was left floating
-- between casts.
local function showCast(f, shown)
    shown = shown and true or false
    f.cast:SetShown(shown)
    setBorderShown(f.castBorder, shown and f.borderOn)
end

-- Counter-scales the border frame so outlines keep the same on-screen thickness.
-- `f.decoScale` is where the borders should end up, so the counter-scale lands
-- there instead of on 1.
local function setPlateScale(f, scale)
    if not (scale and scale > 0) then scale = 1 end
    f.curScale = scale
    f:SetScale(scale)
    f.deco:SetScale((f.decoScale or 1) / scale)
end

-- Anchored by the icon's CENTRE to a point on the bar, so "LEFT, x = -10" means
-- "ten out from the left edge" whatever the icon's size. Up here because
-- updateStyle places them and runs long before that section.
local function layoutIcon(tex, anchorTo, opt)
    opt = opt or {}
    local size = math.max(4, tonumber(opt.size) or 14)
    tex:SetSize(size, size)
    tex:ClearAllPoints()
    tex:SetPoint("CENTER", anchorTo, opt.anchor or "LEFT",
        tonumber(opt.x) or 0, tonumber(opt.y) or 0)
end

local function iconOpts(d, key)
    local ic = d and d.icons
    return ic and ic[key] or nil
end

-- Not always the placement that was picked: a name-only plate has no bar, so an
-- edge placement would hang the name off a rect nobody can see. Those centre.
-- Shared by updateStyle and updateName so the two can't disagree.
local function namePlacementFor(f, grp)
    if f.nameOnly then return Data.NamePlacement("innerCenter") end
    return Data.NamePlacement(grp.namePlacement)
end

-- ── Styling (geometry, media, fonts) ─────────────────────────────────────────
-- Re-derived wholesale from settings rather than patched incrementally, so a
-- settings change and a fresh plate take the same path.
local function updateStyle(f)
    local d = cfg()
    if not (d and f.unit) then return end
    local g   = d.general
    local tgt = d.target or {}
    local grp = f.group

    -- Recomputed here rather than cached at attach: flagging for PvP changes the
    -- answer mid-session.
    local nameOnly = grp.nameOnlyWhenSafe and UnitIsPlayer(f.unit)
        and not UnitCanAttack("player", f.unit) and true or false
    f.nameOnly = nameOnly
    -- The general block is the fallback behind every per-element one below, so a
    -- setting an element doesn't carry comes from here.
    local base = generalFont(g)

    local w = (tonumber(grp.width)  or 124)
    local h = (tonumber(grp.height) or 12)
    f:SetSize(w, h)

    -- Plate bases hang off WorldFrame, not UIParent, so nothing on them is touched
    -- by the interface scale. Folding UIParent's effective scale in puts plates in
    -- the same space as the rest of the UI, so one border unit is one physical
    -- pixel. Without it, at WorldFrame's scale of 1 one UI unit is ~1.9 physical
    -- pixels at 1440p and borders could only snap to 2px, 4px, 6px.
    local ui = uiScale()
    local scale = ui * pct(g.scale, 100) * pct(grp.scale, 100)
    if f.isTarget and tgt.enabled then scale = scale * pct(tgt.scale, 115) end
    if scale <= 0 then scale = 1 end
    f.decoScale = ui

    -- Only the goal is set; the driver eases towards it (SCALE_RATE). `curScale` is
    -- nil for a plate that just picked up a unit, and that case DOES snap — a plate
    -- should appear at its size, not animate in from the last occupant's.
    f.targetScale = scale
    if not f.curScale then setPlateScale(f, scale) end

    f.health:SetStatusBarTexture(barTexture(g.texture))
    local br, bg_, bb = rgb(g.bgColor, 0.08, 0.08, 0.10)
    f.healthBG:SetVertexColor(br, bg_, bb, pct(g.bgAlpha, 80))

    f.hover:SetAlpha(pct(g.hoverAlpha, 25))
    if g.hoverHighlight == false then
        f.hover:Hide()
    end
    -- Cleared, not set: the OnUpdate hover check owns this, and a stale answer from
    -- the previous occupant would stop it noticing the change.
    f.hovered = nil

    -- The group's own size still wins where it is set: it is a per-unit-type
    -- answer, and the font block is the shared one behind it.
    local nameCfg  = elementFont(g, "nameFont")
    local levelCfg = elementFont(g, "levelFont")
    local healthCfg = elementFont(g, "healthFont")
    local nameSize = tonumber(grp.nameSize) or addon.Font.Size(nameCfg, base)
    -- A name-only plate gets its own size: the one above was picked to share a bar
    -- with the level and health text, neither of which is on screen here.
    if nameOnly then nameSize = tonumber(grp.nameOnlySize) or nameSize end
    local nameDX, nameDY = addon.Font.Apply(f.name, nameCfg, base, nameSize)
    f.name:SetShown(grp.showName ~= false)

    -- Re-anchored from scratch, since the placements use different anchor points.
    -- Against the health bar rather than `f`, so inner placements land on the bar —
    -- the two share a rect today, but only the bar is guaranteed to.
    local place = namePlacementFor(f, grp)
    f.name:ClearAllPoints()
    f.name:SetPoint(place.point, f.health, place.rel,
        place.dx + (tonumber(grp.nameX) or 0) + nameDX,
        place.dy + (tonumber(grp.nameY) or 0) + nameDY)
    f.name:SetJustifyH(place.justify)
    -- Re-anchored rather than left on its creation point, so the level's own font
    -- offsets aren't a pair of controls that quietly do nothing.
    local levelDX, levelDY = addon.Font.Apply(f.level, levelCfg, base, nameSize)
    f.level:ClearAllPoints()
    f.level:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", levelDX, 3 + levelDY)
    f.level:SetShown(not nameOnly and grp.showLevel ~= false)
    local healthDX, healthDY = addon.Font.Apply(f.healthText, healthCfg, base)
    -- Health text, and the two cast strings below, are the plate's text that
    -- nothing recolours as the fight goes on, so their block colour is applied
    -- here with the rest of the styling. The name and the level are done in
    -- updateName instead, where a class or difficulty colour may claim them.
    addon.Font.ApplyColor(f.healthText, healthCfg, base, 1, 1, 1)
    f.healthText:SetShown(not nameOnly and grp.showHealthText ~= false and grp.healthFormat ~= "none")

    -- The bar carries its background, fill and hover highlight as children, so one
    -- call takes the lot. It keeps its geometry while hidden, which is what lets the
    -- name stay anchored to it.
    f.health:SetShown(not nameOnly)

    -- Re-anchored from scratch, since switching between the three anchors must drop
    -- the previous one. The 2px inset keeps text off the bar's outline.
    local hAnchor = grp.healthTextAnchor or "RIGHT"
    if hAnchor ~= "LEFT" and hAnchor ~= "CENTER" then hAnchor = "RIGHT" end
    local hEdge = (hAnchor == "LEFT" and 2) or (hAnchor == "RIGHT" and -2) or 0
    f.healthText:ClearAllPoints()
    f.healthText:SetPoint(hAnchor, f.health, hAnchor,
        hEdge + (tonumber(grp.healthTextX) or 0) + healthDX,
        (tonumber(grp.healthTextY) or 0) + healthDY)
    f.healthText:SetJustifyH(hAnchor)

    layoutIcon(f.raidIcon,    f.health, iconOpts(d, "raidMarker"))
    layoutIcon(f.questIcon,   f.health, iconOpts(d, "quest"))
    layoutIcon(f.factionIcon, f.health, iconOpts(d, "faction"))
    layoutIcon(f.eliteIcon,   f.health, iconOpts(d, "elite"))
    layoutIcon(f.rareIcon,    f.health, iconOpts(d, "rare"))
    layoutIcon(f.petIcon,     f.health, iconOpts(d, "pet"))

    -- Cast bar
    local ch = math.max(1, tonumber(grp.castHeight) or 10)
    local co = tonumber(grp.castOffset) or 3
    f.cast:ClearAllPoints()
    f.cast:SetPoint("TOPLEFT",  f, "BOTTOMLEFT",  0, -co)
    f.cast:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", 0, -co)
    f.cast:SetHeight(ch)
    f.cast:SetStatusBarTexture(barTexture(g.castTexture))
    f.castBG:SetVertexColor(br, bg_, bb, pct(g.bgAlpha, 80))
    f.castIcon:SetSize(ch, ch)
    f.castIcon:SetShown(grp.castShowIcon ~= false)
    -- Sized to the cast bar rather than from the block: this text has to fit a bar
    -- whose height is its own setting. Everything else about it is the general
    -- font's, offsets included — both strings are anchored at creation, so those
    -- are folded back in here.
    local castSize = math.max(6, ch - 2)
    local castDX, castDY = addon.Font.Apply(f.castName, nil, base, castSize)
    addon.Font.ApplyColor(f.castName, nil, base, 1, 1, 1)
    f.castName:ClearAllPoints()
    f.castName:SetPoint("LEFT", f.cast, "LEFT", 3 + castDX, castDY)
    f.castName:SetShown(grp.castShowName ~= false)
    addon.Font.Apply(f.castTime, nil, base, castSize)
    addon.Font.ApplyColor(f.castTime, nil, base, 1, 1, 1)
    f.castTime:ClearAllPoints()
    f.castTime:SetPoint("RIGHT", f.cast, "RIGHT", -3 + castDX, castDY)
    f.castTime:SetShown(grp.castShowTimer ~= false)

    -- Its own size, outline, offset and shadow rather than the shared ones: this
    -- line is over the world, not on a bar, so what it takes to stay readable is a
    -- different question. Its tick box governs the FACE alone, which is all it has
    -- ever meant — the rest was never inherited.
    local totCfg  = totFont(g)
    local totSize = math.max(6, addon.Font.Size(totCfg, base))
    local totDX, totDY = addon.Font.Apply(f.totText, totCfg, base, totSize)

    -- The end NEAREST the corner is anchored, so the name runs inwards and the
    -- corner never moves however long it is. Hung off the cast bar rather than the
    -- health bar: the cast bar's rect is reserved whether casting or not, so
    -- anchoring above it would mean text a cast slides out from under. Both bars
    -- keep their geometry while hidden. The block's offsets move that corner
    -- rather than the text, so it keeps growing the same way wherever you put it.
    local totRight = (g.totAnchor or "bottomRight") ~= "bottomLeft"
    f.totText:ClearAllPoints()
    f.totText:SetPoint(totRight and "TOPRIGHT" or "TOPLEFT",
        (grp.showCastBar ~= false) and f.cast or f.health,
        totRight and "BOTTOMRIGHT" or "BOTTOMLEFT",
        totDX, -2 + totDY)
    -- Nothing rides on this while the FontString has no width, but it's what the
    -- field means — something later giving it one shouldn't right-align a left-hung
    -- name.
    f.totText:SetJustifyH(totRight and "RIGHT" or "LEFT")
    -- Opacity is relative to the plate's, so a faded plate fades this too.
    f.totText:SetAlpha(pct(g.totAlpha, 100))
    -- The coloured copy must be the same text, font and size, or the two wouldn't
    -- line up letter for letter. The alpha goes on the clip frame, since the copy is
    -- its region.
    addon.Font.Apply(f.totFill, totCfg, base, totSize)
    f.totClip:SetAlpha(pct(g.totAlpha, 100))

    -- Height and art only. Its width and its anchor both depend on how wide the
    -- NAME came out, which is a different answer for every unit it reports, so
    -- those are done in updateTargetOfTarget where the name is known.
    f.totBar:SetHeight(math.max(1, tonumber(g.totBarHeight) or 4))
    f.totBar:SetStatusBarTexture(barTexture(g.totBarTexture))
    f.totBarBG:SetVertexColor(br, bg_, bb, pct(g.bgAlpha, 80))

    -- Last: the rings anchor to the health and cast bars, and their pixel
    -- snapping resolves against the scale set above, so both have to be final.
    layoutPlateBorders(f)
end

-- ── Coloring ────────────────────────────────────────────────────────────────
-- Whether the mob is currently swinging at a raid member flagged Main Tank.
--
-- Read off the mob's own target rather than by walking the raid and comparing
-- threat: the client won't give a DPS everyone else's threat numbers, but who
-- the mob is hitting is right there. Assignments only exist in a raid, so this
-- is false throughout solo and party play.
local function mainTankHasAggro(unit)
    if not GetPartyAssignment then return false end
    local target = unit .. "target"
    if not UnitExists(target) then return false end
    -- Your own aggro is the caller's business and has already been handled;
    -- being the main tank yourself must not paint your own pulls as safe.
    if UnitIsUnit(target, "player") then return false end
    return GetPartyAssignment("MAINTANK", target) and true or false
end

-- "Fighting me" rather than "in combat": a mob brawling with another player
-- across the room is in combat, and it is neither yours to hold threat on nor
-- worth a plate in the foreground. Used by both the threat colouring below and
-- the bystander dim.
--
-- UnitThreatSituation answers directly where live, but Classic Era returns nil
-- for anything the player isn't on the threat table of — indistinguishable from
-- "no threat API". Hence the fallback: who is it actually swinging at.
local function engagedWithPlayer(unit)
    if not UnitAffectingCombat(unit) then return false end

    if UnitThreatSituation and UnitThreatSituation("player", unit) ~= nil then
        return true
    end

    local target = unit .. "target"
    if not UnitExists(target) then return false end
    if UnitIsUnit(target, "player") or UnitIsUnit(target, "pet") then return true end
    -- Group members count: in a dungeon the pack on the tank is the fight,
    -- whoever it happens to be hitting this second.
    if UnitPlayerOrPetInParty and UnitPlayerOrPetInParty(target) then return true end
    if UnitPlayerOrPetInRaid  and UnitPlayerOrPetInRaid(target)  then return true end
    return false
end

-- Returns (color, alarm, warning). A nil color means threat colouring doesn't
-- apply to this unit at all. The two flags are threat sorted into the tiers the
-- NPC colour overrides key off:
--
--   alarm   — DPS/healer with aggro on you, or a tank who has lost it entirely.
--   warning — DPS/healer climbing the list, or a tank losing grip on it.
--
-- Both modes map onto the same tiers deliberately. They used to be reported for
-- DPS/healer mode only, which meant that in tank mode threat could never take
-- over a custom NPC colour at all.
local function threatColor(d, unit)
    local t = d.threat
    if not (t and t.enabled) then return nil, false, false end
    if not UnitCanAttack("player", unit) then return nil, false, false end
    -- Players have no threat table, and the "is it hitting me?" fallback below
    -- would paint every enemy player permanently red. They keep their class or
    -- reaction color instead.
    if UnitIsPlayer(unit) then return nil, false, false end
    -- Engaged with YOU, not merely in combat. A mob fighting somebody else has a
    -- threat table you are not on, so every tier below would report the bottom of
    -- it — which is how a hostile mob brawling across the room came out wearing
    -- the reassuring "not on me" green instead of saying what it is. Nil here
    -- hands it back to the reaction colour: red for hostile, yellow for neutral.
    if t.combatOnly and not engagedWithPlayer(unit) then return nil, false, false end

    local status = UnitThreatSituation and UnitThreatSituation("player", unit)
    if status == nil then
        -- Classic Era hands back nil for anything the player isn't on the threat
        -- table of, and on builds without the threat API at all. "Is it hitting
        -- me?" is the one thing still answerable either way.
        status = UnitIsUnit(unit .. "target", "player") and 3 or 0
    end

    local c = t.colors
    if t.tankMode then
        -- "Losing threat" is tank mode's warning tier: the same place in the
        -- ladder as a DPS climbing it, so the override that keys off `gaining`
        -- treats it the same way.
        if status >= 3 then return c.tankSecure, false, false end
        if status >= 1 then return c.tankLosing, false, true end
        return c.tankLost, true, false
    end
    if status >= 2 then return c.aggro, true, false end
    if status == 1 then return c.gaining, false, true end

    -- Off you, and parked on the person whose job it is — a different kind of fine
    -- from "off you and nobody knows where it went". Checked last, so nothing about
    -- your own threat is ever hidden by someone else's.
    if mainTankHasAggro(unit) then return c.mainTank, false, false end
    return c.noThreat, false, false
end

-- Reused rather than allocated per call: this runs for every plate ten times a
-- second, and the result is consumed immediately by the caller.
local classScratch = { 1, 1, 1 }

-- nil for anything without a class — NPCs, and players the client hasn't
-- resolved yet. Callers fall back rather than painting them white.
local function classColorFor(unit)
    local _, class = UnitClass(unit)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if not c then return nil end
    classScratch[1], classScratch[2], classScratch[3] = c.r, c.g, c.b
    return classScratch
end

local function reactionColor(d, unit, kind)
    local t = d.threat
    if kind == "enemyPlayer" or kind == "friendlyPlayer" then
        if d.enemyPlayer.classColor then
            local cc = classColorFor(unit)
            if cc then return cc end
        end
    end
    if UnitIsTapDenied and UnitIsTapDenied(unit) then return t.reaction.tapped end
    local r = UnitReaction("player", unit) or 4
    if r <= 3 then return t.reaction.hostile end
    if r == 4 then return t.reaction.neutral end
    return t.reaction.friendly
end

local function updateColor(f)
    local d = cfg()
    if not (d and f.unit) then return end

    local npcColor = Data.GetNpcColor(f.npcID)
    local tc, alarm, warning = threatColor(d, f.unit)

    local chosen
    if tc and npcColor then
        -- Both apply. The NPC colour is the user's deliberate tag, so it wins by
        -- default; threat only takes over when asked, and (with overrideOnlyOnAggro)
        -- only once the state is worth shouting about. overrideOnGaining widens that
        -- from "it has turned on me" to "it's about to".
        local t = d.threat
        local loud = alarm or (t.overrideOnGaining and warning)
        if t.overrideNpcColors and ((not t.overrideOnlyOnAggro) or loud) then
            chosen = tc
        else
            chosen = npcColor
        end
    else
        chosen = tc or npcColor or reactionColor(d, f.unit, f.kind)
    end

    f.health:SetStatusBarColor(rgb(chosen, 0.85, 0.16, 0.16))
end

-- ── Per-plate updates ────────────────────────────────────────────────────────
local function updateHealth(f)
    local unit = f.unit
    if not unit then return end
    local max = UnitHealthMax(unit) or 0
    local cur = UnitHealth(unit) or 0
    if max <= 0 then max = 1 end
    f.health:SetMinMaxValues(0, max)
    f.health:SetValue(math.min(cur, max))

    local grp = f.group
    if grp.showHealthText == false or grp.healthFormat == "none" then
        f.healthText:SetText("")
        return
    end
    local percent = math.floor(cur / max * 100 + 0.5)
    -- Falls back rather than erroring on an unknown value: a profile imported
    -- from a build that had a format this one doesn't should show SOMETHING.
    local fmt = Data.HEALTH_FORMAT_BY_VALUE[grp.healthFormat or "percent"]
        or Data.HEALTH_FORMAT_BY_VALUE.percent
    f.healthText:SetText(fmt.build(shortNum(cur), percent, shortNum(max)))
end

-- The client returns -1 for a unit whose level it won't state — the skull — once
-- the unit is more than this many levels above the player. So the lowest it can
-- actually be is the first level past the cut-off, shown with a "+" to say it's
-- a floor. The gap is the game's long-standing 10 and nothing exposes it.
local SKULL_LEVEL_GAP = 10

local function levelText(unit)
    local level = UnitLevel(unit)
    if level and level > 0 then return tostring(level) end

    local playerLevel = UnitLevel("player") or 0
    if playerLevel > 0 then
        return (playerLevel + SKULL_LEVEL_GAP + 1) .. "+"
    end
    -- Only reachable before the player's own level is known, which is a frame
    -- or two at login rather than a state worth inventing a number for.
    return "??"
end

local function updateName(f)
    local unit = f.unit
    if not unit then return end
    local grp = f.group
    -- For the two colour fallbacks below. Nothing here needs it when the dynamic
    -- colour applies, so it's fetched once rather than per branch.
    local g = (cfg() or {}).general

    if grp.showName ~= false then
        local name = Data.GetNpcName(f.npcID) or UnitName(unit) or ""
        local limit = tonumber(grp.truncateName) or 0
        if limit > 0 and #name > limit then name = name:sub(1, limit) .. ".." end
        f.name:SetText(name)

        -- How much room the name gets depends on where it is: sharing the strip above
        -- the bar means leaving room for the level text; on the bar it's bounded by the
        -- bar; below it has the whole width.
        local place = namePlacementFor(f, grp)
        local reserve = 0
        if place.row == "above" and grp.showLevel ~= false then
            reserve = 28
        elseif place.row == "inner" then
            reserve = 6
        end
        f.name:SetWidth(math.max(10, (f:GetWidth() or 0) - reserve))

        -- Class colour wins where it applies; the font block's colour is what the
        -- name falls back to, which is where the white this used to force went.
        local cc = grp.classColorName and UnitIsPlayer(unit) and classColorFor(unit)
        if cc then
            f.name:SetTextColor(cc[1], cc[2], cc[3])
        elseif g then
            addon.Font.ApplyColor(f.name, elementFont(g, "nameFont"), generalFont(g), 1, 1, 1)
        end
    end

    if grp.showLevel ~= false then
        local level = UnitLevel(unit)
        f.level:SetText(levelText(unit))
        -- Same shape as the name: the level's own difficulty colour is the point of
        -- this text, so it wins, and the block's colour covers everything it can't
        -- answer for (a ?? mob has no difficulty colour).
        local c = (level and level > 0) and GetQuestDifficultyColor
            and GetQuestDifficultyColor(level) or nil
        if c then
            f.level:SetTextColor(c.r, c.g, c.b)
        elseif g then
            addon.Font.ApplyColor(f.level, elementFont(g, "levelFont"), generalFont(g), 0.9, 0.9, 0.9)
        end
    end
end

-- ── Target of target ─────────────────────────────────────────────────────────
-- Polled on the slow tick, not event-driven: there is no event for "the mob
-- changed target" (UNIT_TARGET doesn't fire for nameplate tokens). Two API calls
-- per plate at 10Hz, skipped entirely when off.
--
-- Test mode uses an expiry timestamp rather than a flag plus timer, so the poll
-- tick already running is all that's needed to end it.
local TOT_TEST_SECONDS = 20
local totTestUntil = 0

-- Two straight fades meeting at half, shared by the name and the bar. The MIDDLE
-- colour is its own setting rather than derived: a straight green-to-red blend
-- spends its centre in a muddy olive. Setting it to the halfway blend of the
-- ends gives the plain single fade back.
local function healthRamp(g, frac)
    local r1, g1, b1, r2, g2, b2, t
    if frac >= 0.5 then
        r1, g1, b1 = rgb(g.totRampMid,  1, 1, 0)
        r2, g2, b2 = rgb(g.totRampFull, 0, 1, 0)
        t = (frac - 0.5) * 2
    else
        r1, g1, b1 = rgb(g.totRampEmpty, 1, 0, 0)
        r2, g2, b2 = rgb(g.totRampMid,   1, 1, 0)
        t = frac * 2
    end
    return r1 + (r2 - r1) * t, g1 + (g2 - g1) * t, b1 + (b2 - b1) * t
end

local function updateTargetOfTarget(f)
    local d = cfg()
    local g = d and d.general
    local now = GetTime()
    local testing = now < totTestUntil

    -- Name-only plates get nothing even under test: the corner it hangs off belongs
    -- to a bar that isn't on screen. Test mode does override the enable switch.
    if not (g and f.unit) or f.nameOnly or not (g.totEnabled or testing) then
        f.totText:Hide()
        f.totBar:Hide()
        return
    end

    -- The token is only built when there is something to build it for, so the
    -- whole feature costs one table lookup per plate per tick while it is off.
    local tot, name
    if testing then
        name = "testmode"
    else
        tot  = f.unit .. "target"
        name = UnitExists(tot) and UnitName(tot) or nil
    end
    if not name or name == "" then
        f.totText:Hide()
        f.totClip:Hide()
        f.totBar:Hide()
        return
    end

    f.totText:SetText(name)
    local lineH = f.totText:GetStringHeight() or 0

    -- Read once for both the name and the bar; skipped when nothing will use it.
    --
    -- Classic Era reports health for units outside your group on a 0-100 scale, not
    -- real hit points, so nothing here shows a number. Clamped, because a heal in
    -- the same frame as the read can put current above maximum.
    local mode = g.totColorMode or "class"
    -- Without the clipping API there is nothing to drain, so that mode becomes
    -- the plain health colour rather than a setting that does nothing.
    if mode == "drain" and not f.totCanClip then mode = "health" end

    local frac
    if mode == "health" or mode == "drain" or g.totBarEnabled or testing then
        if testing then
            frac = (totTestUntil - now) / TOT_TEST_SECONDS
        else
            local maxHP = UnitHealthMax(tot) or 0
            frac = maxHP > 0 and ((UnitHealth(tot) or 0) / maxHP) or 0
        end
        if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    end

    -- One of them, never a blend. Class colour is only asked for in class mode and
    -- only a player has one, so anything else falls through to the custom colour.
    -- The bar takes what the name landed on unless it has a ramp of its own.
    --
    -- Drain mode reports the SPENT colour here, since that's what the name
    -- underneath wears.
    local cc = (mode == "class") and tot and UnitIsPlayer(tot) and classColorFor(tot)
    local cr, cg, cb
    if mode == "health" and frac then
        cr, cg, cb = healthRamp(g, frac)
    elseif mode == "drain" then
        -- Dim rather than invisible by default — the name still has to be readable.
        cr, cg, cb = rgb(g.totSpentColor, 0.35, 0.35, 0.35)
    elseif cc then
        cr, cg, cb = cc[1], cc[2], cc[3]
    else
        cr, cg, cb = rgb(g.totColor, 0.80, 0.80, 0.80)
    end
    f.totText:SetTextColor(cr, cg, cb)
    f.totText:Show()

    -- The coloured copy, cut to the health left. Pinned to the base name's own top
    -- left corner rather than the plate, so it lands on it whichever corner the name
    -- hangs from; the width says how much is still coloured.
    if mode == "drain" and frac then
        local clip = f.totClip
        f.totFill:SetText(name)
        f.totFill:SetTextColor(healthRamp(g, frac))
        clip:ClearAllPoints()
        clip:SetPoint("TOPLEFT", f.totText, "TOPLEFT", 0, 0)
        clip:SetSize(math.max(1, (f.totText:GetStringWidth() or 0) * frac),
            math.max(1, lineH))
        clip:Show()
    else
        f.totClip:Hide()
    end

    local bar = f.totBar
    if not (g.totBarEnabled or testing) then
        bar:Hide()
        return
    end

    -- Zero means "as wide as the name", so this is redone per tick rather than in
    -- updateStyle: GetStringWidth only answers once the text is set, and the name is
    -- a different width for every unit.
    local w = tonumber(g.totBarWidth) or 0
    if w <= 0 then w = f.totText:GetStringWidth() or 0 end
    bar:SetWidth(math.max(1, w))

    -- Anchored to the same plate corner the NAME is, not to the name itself: each
    -- has its own nudge pair, and hung off the text every move of the name dragged
    -- the bar along. Outer edge to outer edge, so a bar matching the name lines up
    -- and a fixed-width one still ends at the corner.
    local x = tonumber(g.totBarX) or 0
    local y = tonumber(g.totBarY) or 0
    local right = (g.totAnchor or "bottomRight") ~= "bottomLeft"
    local into  = (f.group and f.group.showCastBar ~= false) and f.cast or f.health
    bar:ClearAllPoints()
    if g.totBarPlacement == "above" then
        -- Bottom edge where the name's top is, i.e. between the plate and the
        -- name — the 2px the name is dropped by is the gap it leaves behind.
        bar:SetPoint(right and "BOTTOMRIGHT" or "BOTTOMLEFT", into,
            right and "BOTTOMRIGHT" or "BOTTOMLEFT", x, y)
    else
        -- Top edge 2px under the name's bottom: the name's own 2px drop, its
        -- height, and the gap again.
        bar:SetPoint(right and "TOPRIGHT" or "TOPLEFT", into,
            right and "BOTTOMRIGHT" or "BOTTOMLEFT", x, -(4 + lineH) + y)
    end

    -- Read above, where the name may already have wanted it.
    bar:SetValue(frac or 0)

    if g.totBarGradient ~= false and frac then
        bar:SetStatusBarColor(healthRamp(g, frac))
    else
        bar:SetStatusBarColor(cr, cg, cb)
    end
    bar:Show()
end

-- ── Icons ────────────────────────────────────────────────────────────────────
-- One table rather than a local apiece, for the same reason `Boss` below is:
-- this file is one Lua chunk, chunks get 200 locals, and it has been over.
local Icons = {}

-- All are placed against the health bar, so a name-only plate gets none — each
-- entry point checks `f.nameOnly`. `preview` is switched on by the settings UI
-- while the Icons tab is open; one flag for the lot, since they share the tab.
Icons.preview = false

-- The standard icon-art crop: 64x64 files with a border baked in that everything
-- else in the game trims off the same way.
Icons.CROP = { 0.08, 0.92, 0.08, 0.92 }

-- Something that differs per plate and holds still while the plate is up, so a
-- preview can vary itself without keeping state to reset on recycle. The unit
-- token is exactly that.
function Icons.seed(f)
    return tonumber(string.match(f.unit or "", "%d+")) or 1
end

-- The eight raid markers are one 4x2 sheet, indexed left to right, top row first
-- — the layout SetRaidTargetIconTexture walks.
function Icons.raidCoords(index)
    local i = index - 1
    local l = (i % 4) * 0.25
    local t = math.floor(i / 4) * 0.25
    return l, l + 0.25, t, t + 0.25
end

function Icons.updateRaid(f)
    local opt = iconOpts(cfg(), "raidMarker")
    if f.nameOnly or not (opt and opt.enabled ~= false and f.unit) then
        f.raidIcon:Hide()
        return
    end

    -- Behind the enable check, not ahead of it: unticking the box still has to mean
    -- the icon is gone. A different marker per plate, since the eight are one sheet.
    local index
    if Icons.preview then
        index = ((Icons.seed(f) - 1) % 8) + 1
    else
        index = GetRaidTargetIndex and GetRaidTargetIndex(f.unit) or nil
    end
    if not index then
        f.raidIcon:Hide()
        return
    end
    f.raidIcon:SetTexCoord(Icons.raidCoords(index))
    f.raidIcon:Show()
end

-- The classification icons are atlases the client draws its own nameplates with.
-- An atlas a build lacks draws nothing rather than failing, so each carries a
-- fallback file. The faction pair crops at 0.65625, where the art stops.
Icons.ART = {
    factionAlliance = { file = "Interface\\TargetingFrame\\UI-PVP-Alliance",
                        crop = { 0, 0.65625, 0, 0.65625 } },
    factionHorde    = { file = "Interface\\TargetingFrame\\UI-PVP-Horde",
                        crop = { 0, 0.65625, 0, 0.65625 } },
    elite           = { atlas = "nameplates-icon-elite-gold",
                        file  = "Interface\\Icons\\INV_Misc_Head_Dragon_01" },
    rare            = { atlas = "nameplates-icon-elite-silver",
                        file  = "Interface\\Icons\\INV_Misc_Head_Dragon_01",
                        desaturate = true },
    pet             = { file = "Interface\\Icons\\Ability_Hunter_BeastCall" },
}

function Icons.setArt(tex, art)
    -- Worked out on first use and kept: whether this build has the atlas is a fact
    -- about the client, and asking costs a table per call.
    if art.useAtlas == nil then
        art.useAtlas = (art.atlas and C_Texture and C_Texture.GetAtlasInfo
            and C_Texture.GetAtlasInfo(art.atlas)) and true or false
    end

    if art.useAtlas then
        -- false: an atlas carries its own size and this one must not use it —
        -- the size on screen is the Size setting, applied by layoutIcon.
        tex:SetAtlas(art.atlas, false)
        -- The atlas pair is already gold and silver; `desaturate` is only how
        -- one fallback file stands in for both.
        tex:SetDesaturated(false)
    else
        tex:SetTexture(art.file)
        tex:SetTexCoord(unpack(art.crop or Icons.CROP))
        tex:SetDesaturated(art.desaturate and true or false)
    end
end

function Icons.apply(tex, d, key, art)
    local opt = iconOpts(d, key)
    if not (opt and opt.enabled ~= false and art) then
        tex:Hide()
        return
    end
    Icons.setArt(tex, art)
    tex:Show()
end

-- The four markers that say what the unit IS. On handover rather than the tick,
-- since none of them changes while a plate is on a unit.
function Icons.updateUnit(f)
    local d    = cfg()
    local unit = f.unit
    if f.nameOnly or not (d and unit) then
        f.factionIcon:Hide()
        f.eliteIcon:Hide()
        f.rareIcon:Hide()
        f.petIcon:Hide()
        return
    end

    local art = Icons.ART
    local faction, elite, rare, pet
    if Icons.preview then
        -- Every marker on every plate: standing somewhere with an elite, a rare, a pet
        -- and both factions in view at once isn't something you can arrange.
        faction = (Icons.seed(f) % 2 == 0) and art.factionHorde or art.factionAlliance
        elite, rare, pet = art.elite, art.rare, art.pet
    else
        -- Nil for anything neutral or unaligned, which is most mobs.
        local group = UnitFactionGroup and UnitFactionGroup(unit)
        faction = (group == "Alliance" and art.factionAlliance)
            or (group == "Horde" and art.factionHorde)
            or nil

        -- A rare elite is both and wears both — two independent switches, so picking one
        -- would answer a question the settings didn't ask.
        local class = (UnitClassification and UnitClassification(unit)) or "normal"
        elite = (class == "elite" or class == "rareelite" or class == "worldboss")
            and art.elite or nil
        rare  = (class == "rare" or class == "rareelite")
            and art.rare or nil

        -- Player-controlled and not a player: that is what separates the
        -- hunter's boar from the boar stood next to it.
        pet = (UnitPlayerControlled and UnitPlayerControlled(unit)
            and not UnitIsPlayer(unit)) and art.pet or nil
    end

    Icons.apply(f.factionIcon, d, "faction", faction)
    Icons.apply(f.eliteIcon,   d, "elite",   elite)
    Icons.apply(f.rareIcon,    d, "rare",    rare)
    Icons.apply(f.petIcon,     d, "pet",     pet)
end

-- ── Aura tracking ────────────────────────────────────────────────────────────
-- Two whitelisted strips above the health bar. Driven by UNIT_AURA rather than
-- polled — a raid pull fires it dozens of times a second across every plate — so
-- it only marks the plate dirty and the poll tick scans at most once per 0.1s.
local AURA_FILTER   = { buffs = "HELPFUL", debuffs = "HARMFUL" }
local AURA_KINDS    = { "buffs", "debuffs" }
-- Classic Era's aura list is capped at 40; the loop breaks on the first empty
-- slot anyway, so this is only the guard against an API that never returns nil.
local MAX_AURA_SCAN = 40
-- What an aura the client can't hand out an icon for is drawn as.
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"

-- One reader for both aura APIs: C_UnitAuras on current builds, UnitAura on
-- Classic Era. Same flat tuple either way, plus the caster where the client
-- names one — a DoT two people are running needs it to tell the timers apart.
local function clientAura(unit, index, filter)
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        local a = C_UnitAuras.GetAuraDataByIndex(unit, index, filter)
        if not a then return nil end
        return a.name, a.icon, a.applications, a.duration, a.expirationTime, a.spellId, a.sourceUnit
    end
    if not UnitAura then return nil end
    local name, icon, count, _, duration, expires, caster, _, _, spellID = UnitAura(unit, index, filter)
    if not name then return nil end
    return name, icon, count, duration, expires, spellID, caster
end

-- Classic Era fills duration and expirationTime in only for auras the PLAYER
-- applied. Everything else — the rest of the raid's debuffs on the boss, a
-- mob's own buffs — arrives zeroed, which drawAuraIcon correctly renders as an
-- icon with no swipe and no countdown.
--
-- addon.Durations reconstructs those from the combat log, so ask it for the
-- ones the client left blank and never for the ones it answered: a real
-- duration from the API is the truth and this is a reconstruction.
local function readAura(unit, index, filter)
    local name, icon, count, duration, expires, spellID, caster = clientAura(unit, index, filter)
    if not name then return nil end

    if Durations and spellID and ((tonumber(duration) or 0) <= 0 or (tonumber(expires) or 0) <= 0) then
        local d, e = Durations.GetDuration(unit, spellID, caster, name)
        if d then duration, expires = d, e end
    end

    return name, icon, count, duration, expires, spellID
end

-- Coarse at the top, precise at the bottom: "1.4" where "23m" would do is
-- unreadable at nameplate size.
local function auraTimeText(remaining)
    if remaining >= 3600 then return string.format("%dh", math.floor(remaining / 3600 + 0.5)) end
    if remaining >= 60   then return string.format("%dm", math.floor(remaining / 60   + 0.5)) end
    if remaining >= 10   then return string.format("%d",  math.floor(remaining)) end
    return string.format("%.1f", remaining)
end

local function hideAuraRow(row)
    row.shown = 0
    row:Hide()
    for _, b in ipairs(row.icons) do
        b.expires, b.duration = nil, nil
        b:Hide()
    end
end

-- Everything an icon is drawn from, resolved once per row rather than once per
-- icon. Reused rather than rebuilt each time: this runs per plate per tick.
local auraStyle = {}

-- `pin` names the point on the health bar the row hangs off, for rows with a
-- corner of their own. Passed rather than read off `o` because it's a fact about
-- which strip this is — and the style table is reused, so a value left behind
-- would move the next row.
--
-- `special` marks a special buff frame, which is the one caller whose growth can
-- run vertically and whose own attach point is worked out rather than derived
-- from the growth alone. Both fields are written on every call for the reason
-- above: a leftover rowPoint would re-anchor the next row through here.
local function readAuraStyle(o, g, pin, special)
    local st = auraStyle
    st.pin     = pin
    st.size    = math.max(4, tonumber(o.size) or 20)
    st.spacing = math.max(0, tonumber(o.spacing) or 2)
    st.max     = math.max(1, math.min(20, tonumber(o.max) or 8))
    if special then
        st.growth   = Data.SpecialGrowth(o.growth)
        st.vertical = Data.SPECIAL_VERTICAL[st.growth] and true or false
        st.rowPoint = Data.SpecialRowPoint(pin, st.growth)
    else
        st.growth   = Data.AuraGrowth(o.growth)
        st.vertical = false
        st.rowPoint = nil
    end
    st.step    = st.size + st.spacing

    -- Icon text takes the general font block, sized by the row's own timer size —
    -- these strings are centred on an icon, so the block's offsets are left out of
    -- it (they place the plate's own text, not what is drawn on an aura).
    st.font     = generalFont(g)
    st.textSize = math.max(6, tonumber(o.timerSize) or 9)
    st.showTime = o.showTimer ~= false
    st.showQty  = o.showStacks ~= false

    st.borderSize = math.max(0, math.floor((tonumber(o.borderSize) or 1) + 0.5))
    st.br, st.bg, st.bb = rgb(o.borderColor, 0, 0, 0)

    st.x = tonumber(o.x) or 0
    st.y = tonumber(o.y) or 0
    return st
end

-- One icon, from a real aura or a made-up preview one. Shared deliberately: the
-- preview is only worth anything drawn by the same code as the real thing, since
-- a second copy would drift and start lying.
local function drawAuraIcon(row, index, st, icon, count, duration, expires, now)
    local b = auraIcon(row, index)

    b:SetSize(st.size, st.size)
    b:ClearAllPoints()
    -- The first icon pins to the growth edge and the rest queue behind it, so the
    -- one you look at first never moves. Centred is the exception by definition,
    -- and falls into the "from the near edge" branch of its axis — the ROW is
    -- what's centred, and finishAuraRow sizes it to exactly these icons.
    if st.vertical then
        if st.growth == "up" then
            b:SetPoint("BOTTOM", row, "BOTTOM", 0, (index - 1) * st.step)
        else
            b:SetPoint("TOP", row, "TOP", 0, -(index - 1) * st.step)
        end
    elseif st.growth == "left" then
        b:SetPoint("RIGHT", row, "RIGHT", -(index - 1) * st.step, 0)
    else
        b:SetPoint("LEFT", row, "LEFT", (index - 1) * st.step, 0)
    end

    b.icon:SetTexture(icon or QUESTION_MARK)

    if st.borderSize > 0 then
        layoutBorder(b.border, b, st.borderSize, 0)
        paintBorder(b.border, st.br, st.bg, st.bb, 1)
        setBorderShown(b.border, true)
    else
        setBorderShown(b.border, false)
    end

    duration = tonumber(duration) or 0
    expires  = tonumber(expires)  or 0
    if duration > 0 and expires > 0 then
        b.cd:SetCooldown(expires - duration, duration)
        b.cd:Show()
        b.duration, b.expires = duration, expires
    else
        -- Permanent auras (and anything the client won't give a duration for)
        -- get no swipe and no timer rather than a full one that never moves.
        b.cd:SetCooldown(0, 0)
        b.cd:Hide()
        b.duration, b.expires = nil, nil
    end

    b.timerOn = st.showTime and b.expires and true or false
    addon.Font.Apply(b.timer, st.font, FONT_DEFAULT, st.textSize)
    addon.Font.ApplyColor(b.timer, st.font, FONT_DEFAULT, 1, 1, 1)
    b.timer:SetShown(b.timerOn)
    if b.timerOn then b.timer:SetText(auraTimeText(math.max(0, b.expires - now))) end

    count = tonumber(count) or 0
    addon.Font.Apply(b.count, st.font, FONT_DEFAULT, st.textSize)
    addon.Font.ApplyColor(b.count, st.font, FONT_DEFAULT, 1, 1, 1)
    b.count:SetShown(st.showQty and count > 1)
    if count > 1 then b.count:SetFormattedText("%d", count) end

    b:Show()
    return b
end

-- Sizes the row to exactly the icons on it and pins it to the growth edge — see
-- createAuraRow for why fitting it makes "centred" free.
local function finishAuraRow(f, row, shown, st)
    if shown == 0 then
        hideAuraRow(row)
        return
    end

    for i = shown + 1, #row.icons do
        local b = row.icons[i]
        b.expires, b.duration = nil, nil
        b:Hide()
    end

    row.shown = shown
    -- Sized to exactly its icons along whichever axis they run, which is what
    -- makes "centred" free: centring the row centres what is on it.
    local span = shown * st.size + (shown - 1) * st.spacing
    if st.vertical then
        row:SetSize(st.size, span)
    else
        row:SetSize(span, st.size)
    end
    row:ClearAllPoints()

    -- Anchored to the health bar, not `f`: on a name-only plate the bar is hidden
    -- but still positioned, so the strip lands where it always does.
    local mine, theirs
    if st.growth == "right" then
        mine, theirs = "BOTTOMLEFT", "TOPLEFT"
    elseif st.growth == "left" then
        mine, theirs = "BOTTOMRIGHT", "TOPRIGHT"
    else
        mine, theirs = "BOTTOM", "TOP"
    end

    -- A row pinned to a corner keeps that corner whichever way it grows. The boss
    -- mod strip is the one that does — growing leftwards would otherwise send "off
    -- the top left" to the far end of the plate.
    --
    -- A special buff frame brings both halves with it: it can hang off any of the
    -- eight points and run in any of six directions, so which of its own corners
    -- meets the bar is worked out from the pair rather than from the growth.
    row:SetPoint(st.rowPoint or mine, f.health, st.pin or theirs, st.x, st.y)
    row:Show()
end

-- A by-name entry has no ID or art of its own, so it learns from the auras it
-- matches. Only name entries: an ID entry already knows its only ID. Free in the
-- steady state (one table lookup after the first), which is what lets it sit in
-- the scan loop.
local function learnAura(entry, spellID, icon)
    if not (entry and spellID) or entry.id then return end
    if Data.NoteAuraSeen(entry, spellID, icon) and NP.onAuraLearned then
        NP.onAuraLearned()
    end
end

-- ── Learned catalogue ────────────────────────────────────────────────────────
-- Walks every aura a plate wears, not just whitelisted ones, so the settings
-- panel can offer a list of things actually met.
--
-- Deliberately NOT on the 0.1s tick: a full scan is forty reads per filter per
-- plate. Three seconds a plate turns twenty thousand reads a minute into a few
-- hundred, and misses nothing lasting longer than a global cooldown.
local LEARN_INTERVAL = 3

local function learnFromPlate(f, now)
    if not f.unit then return end
    if f.learnAt and now < f.learnAt then return end
    -- Staggered, not aligned: without the jitter every plate that appeared in
    -- the same pull would come due on the same frame for the rest of the fight.
    f.learnAt = now + LEARN_INTERVAL + math.random() * 0.5

    -- Resolved once for the plate rather than per aura: what is wearing them
    -- doesn't change between slot 1 and slot 40.
    local isPlayer = UnitIsPlayer(f.unit) and true or false
    local unitName = (not isPlayer) and UnitName(f.unit) or nil

    local touched = false
    for _, which in ipairs(AURA_KINDS) do
        local filter = AURA_FILTER[which]
        for i = 1, MAX_AURA_SCAN do
            local name, icon, _, _, _, spellID = readAura(f.unit, i, filter)
            if not name then break end
            if Data.NoteLearnedAura(which, spellID, name, icon, isPlayer, unitName) then
                touched = true
            end
        end
    end
    if touched and NP.onAuraLearned then NP.onAuraLearned() end
end

-- ── Inferred auras ───────────────────────────────────────────────────────────
-- Classic Era won't report a hostile player's buffs: the aura API answers for
-- your target, mouseover and group and nothing else, which is why a whitelisted
-- Battle Shout never shows on an enemy plate.
--
-- The events do carry it: UNIT_SPELLCAST_SUCCEEDED against their nameplate unit,
-- and SPELL_AURA_APPLIED/_REFRESH/_REMOVED by GUID in the combat log. Neither
-- has a duration and both go quiet out of range, so this is a record of what was
-- last seen and always loses to a real aura.
local AURA_SUBEVENTS = {
    SPELL_AURA_APPLIED      = "apply",
    SPELL_AURA_REFRESH      = "apply",
    SPELL_AURA_APPLIED_DOSE = "apply",
    SPELL_AURA_REMOVED_DOSE = "apply",
    SPELL_AURA_REMOVED      = "drop",
    SPELL_AURA_BROKEN       = "drop",
    SPELL_AURA_BROKEN_SPELL = "drop",
}

local AURA_TYPE_ROW = { BUFF = "buffs", DEBUFF = "debuffs" }

-- With no duration to expire on, an inferred aura rides until the log says it's
-- gone — which needs the unit in range. Five minutes is the backstop.
local INFER_TTL = 300
-- How often the store is walked for records nothing is looking at any more.
local INFER_SWEEP = 10

-- [destGUID] = { [lowercased spell name] = record }. Keyed on name, not ID, so
-- ranks collapse into one icon and a real and an inferred Battle Shout don't
-- both draw.
local inferred = {}
local inferredGUIDs = 0
local sinceInferSweep = 0

-- The combat log deals only in GUIDs — no unit token, so no UnitIsPlayer — but
-- player GUIDs are the only ones beginning "Player". Hostility doesn't come into
-- it, since friendly units share the enemy block.
local function unitKeyForGUID(guid)
    if type(guid) ~= "string" then return nil end
    return guid:sub(1, 6) == "Player" and "enemyPlayer" or "enemyNPC"
end

-- The filter that keeps the store to a handful of records: almost everything the
-- combat log shouts about is rejected here.
local function trackedEntry(unitKey, which, spellID, name)
    local lookup = Data.AuraLookup(unitKey, which)
    if lookup.count == 0 then return nil end
    return (spellID and lookup.byID[spellID])
        or (name and lookup.byName[name:lower()])
        or nil
end

-- UNIT_AURA normally marks a plate stale, and for these units it never comes. So
-- every change to the store nudges the plate itself, or an enemy's buff would
-- appear (and linger) only on an unrelated rescan.
local function markInferredDirty(guid)
    local f = guid and byGUID[guid]
    if f then f.auraDirty = true end
end

local function forgetInferred(guid, name)
    local bag = guid and inferred[guid]
    if not bag then return end
    if name then
        if bag[name:lower()] == nil then return end
        bag[name:lower()] = nil
        markInferredDirty(guid)
        if next(bag) ~= nil then return end
    else
        markInferredDirty(guid)
    end
    inferred[guid] = nil
    inferredGUIDs = inferredGUIDs - 1
end

local function rememberInferred(guid, which, spellID, name, icon, count, srcGUID)
    if not (guid and name) then return end
    local unitKey = unitKeyForGUID(guid)
    if not unitKey then return end
    local entry = trackedEntry(unitKey, which, spellID, name)
    if not entry then return end

    local bag = inferred[guid]
    if not bag then
        bag = {}
        inferred[guid] = bag
        inferredGUIDs = inferredGUIDs + 1
    end

    local key = name:lower()
    local rec = bag[key]
    if not rec then
        rec = {}
        bag[key] = rec
    end

    rec.which   = which
    rec.spellID = spellID
    rec.name    = name
    -- The combat log carries no icon, so it's resolved once and kept on the record —
    -- the same aura re-applies constantly in a fight.
    if icon then
        rec.icon = icon
    elseif not rec.icon then
        rec.icon = select(2, Data.SpellInfo(spellID or name))
    end

    -- Reaches further than the scan: the combat log names a spell whether or not the
    -- client would resolve that name, and whether or not the unit is readable.
    learnAura(entry, spellID, rec.icon)

    count = tonumber(count) or 0
    rec.count = count > 1 and count or 1

    local dur = tonumber(entry.duration)
    -- A duration typed on the whitelist entry always wins — it is the override
    -- for anything the tables get wrong or never had. Failing that, ask the
    -- duration engine what this spell lasts: it is reading the same event we
    -- are, so "just applied" is exactly the case it answers best.
    if not (dur and dur > 0) and Durations then
        dur = Durations.GetAppliedDuration(spellID, name, srcGUID, guid,
                                           unitKey == "enemyPlayer")
    end
    rec.duration = (dur and dur > 0) and dur or nil
    rec.applied  = GetTime()
    rec.expires  = rec.applied + (rec.duration or INFER_TTL)
    -- A number from either source earns the swipe and countdown; with neither,
    -- the icon rides untimed rather than counting down from an invention.
    rec.timed    = rec.duration and true or false

    markInferredDirty(guid)
end

local function wipeInferred()
    if inferredGUIDs == 0 then return end
    for guid in pairs(inferred) do markInferredDirty(guid) end
    wipe(inferred)
    inferredGUIDs = 0
end

-- Records outlive the plate that showed them (the unit walks away and comes
-- back), so nothing else prunes them.
local function sweepInferred(elapsed)
    if inferredGUIDs == 0 then return end
    sinceInferSweep = sinceInferSweep + elapsed
    if sinceInferSweep < INFER_SWEEP then return end
    sinceInferSweep = 0

    local now = GetTime()
    for guid, bag in pairs(inferred) do
        local live, pruned = false, false
        for key, rec in pairs(bag) do
            if now >= rec.expires then bag[key] = nil; pruned = true else live = true end
        end
        if pruned then markInferredDirty(guid) end
        if not live then
            inferred[guid] = nil
            inferredGUIDs = inferredGUIDs - 1
        end
    end
end

local function onCombatLogAura()
    local _, sub, _, srcGUID, _, _, _, destGUID, destName, _, _, spellID, spellName, _, auraType, amount =
        CombatLogGetCurrentEventInfo()

    -- A corpse keeps none of its buffs, and the same GUID can be resurrected
    -- into a plate that would otherwise inherit them.
    if sub == "UNIT_DIED" or sub == "PARTY_KILL" then
        forgetInferred(destGUID)
        return
    end

    -- One hash lookup rejects everything that isn't an aura event, which in a
    -- raid pull is the overwhelming majority of what arrives here.
    local action = AURA_SUBEVENTS[sub]
    if not (action and spellName) then return end

    -- Removal doesn't consult auraType, and mustn't: SPELL_AURA_BROKEN_SPELL carries
    -- the breaking spell in the middle, pushing its auraType two slots past where
    -- the others keep it, and reading the wrong slot would leave the icon up. The
    -- name is in the same place in all of them.
    if action == "drop" then
        forgetInferred(destGUID, spellName)
        return
    end

    local which = AURA_TYPE_ROW[auraType]
    if not which then return end

    -- Free catalogue entries: this handler has already decoded the event, and it
    -- reaches auras the plate scan can't read at all.
    local d = cfg()
    if d and d.auras and d.auras.enabled ~= false and d.auras.learn ~= false then
        -- The GUID is the only thing here that says which kind of unit this was;
        -- destName is the NPC's name, and irrelevant for a player, who is
        -- recorded as the category rather than by name.
        local isPlayer = unitKeyForGUID(destGUID) == "enemyPlayer"
        if Data.NoteLearnedAura(which, spellID, spellName, nil,
                                isPlayer, (not isPlayer) and destName or nil)
           and NP.onAuraLearned then
            NP.onAuraLearned()
        end
    end

    rememberInferred(destGUID, which, spellID, spellName, nil, amount, srcGUID)
end

-- A cast that landed, on a unit the client will name. The aura is ASSUMED to be
-- the spell itself on its caster — true of exactly the self buffs this exists
-- for (Battle Shout, Bloodrage) and false of anything aimed elsewhere, which is
-- why the whitelist gates it.
--
-- Kept alongside the combat log rather than replaced by it because it reaches
-- further: the log needs the caster in range, this only needs their plate.
local function onCastSucceeded(unit, spellID)
    if not (unit and spellID) then return end
    if not UnitCanAttack("player", unit) then return end
    local guid = UnitGUID(unit)
    if not guid then return end
    local name, icon = Data.SpellInfo(spellID)
    if not name then return end
    -- The aura is assumed to be the spell on its own caster, so the caster GUID
    -- is the unit's — which is what makes talent-scaled durations resolvable
    -- when the cast happens to be ours.
    rememberInferred(guid, "buffs", spellID, name, icon, nil, guid)
end

-- Sorted before drawing so the strip doesn't reshuffle every scan — pairs() has
-- no order, and an icon swapping places twice a second is worse than no icon.
-- Oldest first, so a new aura joins the end rather than shoving the others along.
local inferScratch = {}

-- `wantBar` is the special buff frame being filled, or nil for the row above the
-- health bar. The record itself doesn't carry one — the assignment lives on the
-- whitelist entry and can be changed while the record is still riding — so it's
-- resolved back through the lookup here. An entry that has since been removed
-- from the whitelist resolves to nothing and is dropped, which is right: the
-- record only exists because it was tracked.
local function collectInferred(f, which, seen, now, lookup, wantBar)
    wipe(inferScratch)
    local bag = f.guid and inferred[f.guid]
    if not bag then return inferScratch end

    for key, rec in pairs(bag) do
        if now >= rec.expires then
            bag[key] = nil
        elseif rec.which == which and not seen[key] then
            local entry = (rec.spellID and lookup.byID[rec.spellID]) or lookup.byName[key]
            if entry and lookup.barFor[entry] == wantBar then
                inferScratch[#inferScratch + 1] = rec
            end
        end
    end
    table.sort(inferScratch, function(a, b) return a.applied < b.applied end)
    return inferScratch
end

-- ── Preview ──────────────────────────────────────────────────────────────────
-- Switched on by the settings UI while an aura tab is open, drawn on every plate
-- on screen. Sizing, spacing and nudges can't be judged from their numbers, and
-- without this you could only judge them by whitelisting something and finding a
-- mob wearing it — no help when the whitelist is empty, i.e. where everyone
-- starts.
--
-- Both rows at once, since they stack and seeing them together is the only way
-- to judge whether the Nudge Y values keep them clear. One unit type, because
-- that's the tab you're looking at.
local auraPreviewUnit = nil

-- Stand-in art for an empty whitelist. Two sets so a debuff row previews as
-- something that looks like a debuff.
local PREVIEW_ART = {
    buffs = {
        "Interface\\Icons\\Spell_Holy_PowerWordShield",
        "Interface\\Icons\\Spell_Holy_Renew",
        "Interface\\Icons\\Ability_Warrior_BattleShout",
        "Interface\\Icons\\Spell_Nature_Regeneration",
        "Interface\\Icons\\Spell_Magic_MageArmor",
    },
    debuffs = {
        "Interface\\Icons\\Spell_Shadow_ShadowWordPain",
        "Interface\\Icons\\Spell_Fire_Immolation",
        "Interface\\Icons\\Ability_Gouge",
        "Interface\\Icons\\Spell_Nature_Corrosivebreath",
        "Interface\\Icons\\Spell_Frost_FrostShock",
    },
}

-- Resolved off the whitelist once per refresh rather than per plate: it is the
-- same answer for every plate on screen, and resolving a spell ID to its icon
-- is a client lookup per entry.
local previewArtCache = {}

local function previewArt(unitKey, which)
    local byUnit = previewArtCache[unitKey]
    if not byUnit then
        byUnit = {}
        previewArtCache[unitKey] = byUnit
    end
    if byUnit[which] then return byUnit[which] end

    local out = {}
    for _, item in ipairs(Data.SortedAuras(unitKey, which)) do
        if item.entry.enabled ~= false then
            local _, icon = Data.AuraDisplay(item.entry)
            out[#out + 1] = icon or QUESTION_MARK
        end
    end
    -- The user's own spells when they have any, stock art when they don't —
    -- previewing the real icons is worth more than previewing a stranger's, and
    -- an empty list still has to show something.
    if #out == 0 then out = PREVIEW_ART[which] or PREVIEW_ART.debuffs end

    byUnit[which] = out
    return out
end

-- Deliberately uneven, so the swipes don't sweep as one block.
local PREVIEW_DURATIONS = { 20, 30, 45, 12 }

-- Filled to the icon cap rather than to some smaller sample: the width of a
-- FULL row is the thing the numbers don't tell you, and it is what decides
-- whether the strip overhangs the plate.
local function drawAuraPreview(f, row, unitKey, which, st, now)
    local art = previewArt(unitKey, which)
    for i = 1, st.max do
        local icon     = art[((i - 1) % #art) + 1]
        local duration = PREVIEW_DURATIONS[((i - 1) % #PREVIEW_DURATIONS) + 1]
        -- Looped off the clock and offset per icon, so the swipes and the
        -- countdowns keep moving out of step with each other for as long as the
        -- tab is open instead of freezing at zero a few seconds in.
        local left     = duration - ((now + i * 7) % duration)
        local count    = (i % 3 == 0) and (i + 1) or 1
        drawAuraIcon(row, i, st, icon, count, duration, now + left, now)
    end
    finishAuraRow(f, row, st.max, st)
end

-- Which whitelist names have already made it onto the row this pass, so the
-- inferred pass can't draw a second copy of something the unit really is
-- wearing. Reused rather than rebuilt: this runs per plate per tick.
local auraSeen = {}

local function updateAuraRow(f, which)
    local row = f.auraRows and f.auraRows[which]
    if not row then return end

    local d = cfg()
    local a = d and d.auras
    -- The row's settings are per unit type as well as per kind — four
    -- independent blocks — so which one applies is decided by the plate.
    local uKey = f.kind and Data.AURA_UNIT_FOR_KIND[f.kind]
    local u    = uKey and a and a.units and a.units[uKey]
    local o    = u and u[which]
    if not (f.unit and a and a.enabled ~= false and o and o.enabled ~= false) then
        hideAuraRow(row)
        return
    end

    local st  = readAuraStyle(o, d.general)
    local now = GetTime()

    -- Ahead of the whitelist check below, not behind it: the preview is showing
    -- what the settings WOULD draw rather than what this unit happens to be
    -- wearing, and an empty whitelist is exactly when that is worth seeing.
    if auraPreviewUnit == uKey then
        drawAuraPreview(f, row, uKey, which, st, now)
        return
    end

    -- Nothing whitelisted means nothing to draw, and the scan below would walk every
    -- aura on the unit to discover that. Checked first, so with every list empty
    -- (the shipped state) this costs one table lookup per plate per tick. Nothing
    -- can have been inferred either — the store is fed through the same whitelist.
    --
    -- `main` rather than `count`: an entry ticked onto a special buff frame is
    -- drawn there INSTEAD, so a list every one of whose entries has been moved
    -- leaves this row with nothing to do.
    local lookup = Data.AuraLookup(uKey, which)
    if lookup.main == 0 then
        hideAuraRow(row)
        return
    end

    -- "Only mine" is a filter flag rather than a check on the caster afterwards:
    -- the game does the matching, and a scan that discards most of what it reads
    -- would still have paid to read it.
    local filter = AURA_FILTER[which]
    if o.onlyMine then filter = filter .. "|PLAYER" end

    local shown = 0
    wipe(auraSeen)
    for i = 1, MAX_AURA_SCAN do
        local name, icon, count, duration, expires, spellID = readAura(f.unit, i, filter)
        if not name then break end

        local key = name:lower()
        local hit = (spellID and lookup.byID[spellID]) or lookup.byName[key]
        if hit then
            -- The one moment a by-name entry can be told what it matches: the
            -- name that found it and the ID and art that came with it are all
            -- in hand right here, and nowhere else. Done for an entry bound to a
            -- special frame too — it is the same entry, and the frame's own pass
            -- has no better claim on teaching it.
            learnAura(hit, spellID, icon)
            if lookup.barFor[hit] == nil then
                shown = shown + 1
                -- Marked seen only where it was drawn, so the inferred pass for
                -- the frame it went to can still fill it in over there.
                auraSeen[key] = true
                drawAuraIcon(row, shown, st, icon, count, duration, expires, now)
                if shown >= st.max then break end
            end
        end
    end

    -- Then whatever the unit wouldn't own up to, filled in from the events. Strictly
    -- second: a real aura carries the true duration and stack count and an inferred
    -- one carries neither, so the real one wins.
    --
    -- Skipped entirely under "only ones I applied" — the events say who cast what,
    -- but the store doesn't keep it, and quietly showing someone else's aura under a
    -- filter that promises otherwise is worse than showing none.
    if shown < st.max and u.fromEvents and not o.onlyMine then
        for _, rec in ipairs(collectInferred(f, which, auraSeen, now, lookup, nil)) do
            shown = shown + 1
            drawAuraIcon(row, shown, st, rec.icon, rec.count,
                rec.timed and rec.duration or 0,
                rec.timed and rec.expires  or 0, now)
            if shown >= st.max then break end
        end
    end

    finishAuraRow(f, row, shown, st)
end

-- ── Special buff frames ──────────────────────────────────────────────────────
-- The same icons, drawn somewhere else. A frame takes whichever entries of the
-- unit type's two whitelists have been ticked onto it, from both at once — an
-- aura that earned its own frame is one you stopped caring which list it came
-- off — and the rows above the health bar skip exactly those.
--
-- Built per plate on demand and never destroyed: the set of frames changes only
-- when the settings do, and a handful of empty rows costs a hidden frame each.
--
-- ONE file-scope local for the whole feature, like Boss and Icons above it: this
-- chunk is close enough to Lua 5.1's cap of 200 locals that a feature spending
-- six of them on itself is a feature that stops the file loading.
local Special = {
    -- Which sweep of Special.updateRows a row last drew on. See the sweep itself
    -- for why it's a stamp rather than a set of what drew.
    pass = 0,
}

-- Keyed by frame id alone, so the two unit types' frames of the same id share
-- one row on a recycled plate. Deliberate: a plate holds one unit type at a
-- time, and every draw re-anchors, re-sizes and re-fills the row from scratch,
-- so there is nothing of the previous occupant's frame left in it.
function Special.row(f, id)
    local row = f.specialRows[id]
    if row then return row end

    row = createAuraRow(f)
    f.specialRows[id] = row
    f.iconRows[#f.iconRows + 1] = row
    -- Frame levels are absolute and this row missed the pass that set them, so
    -- the plate re-derives the lot — which now includes this one.
    setPlateLevel(f, f:GetFrameLevel() or 0)
    return row
end

-- Preview art for a frame, off both whitelists at once rather than one. A frame
-- needs the preview more than the rows above the bar do: it is placed against a
-- plate's outline, and until something is drawn on it there is nothing to place.
--
-- Cached beside the two kinds, keyed by frame id: the ids are numbers and the
-- kinds are strings, so neither can collide with the other.
function Special.previewArt(unitKey, bar)
    local byUnit = previewArtCache[unitKey]
    if not byUnit then
        byUnit = {}
        previewArtCache[unitKey] = byUnit
    end
    if byUnit[bar.id] then return byUnit[bar.id] end

    local out = {}
    for _, which in ipairs(AURA_KINDS) do
        for _, item in ipairs(Data.SortedAuras(unitKey, which)) do
            if item.entry.enabled ~= false and item.entry.bar == bar.id then
                local _, icon = Data.AuraDisplay(item.entry)
                out[#out + 1] = icon or QUESTION_MARK
            end
        end
    end
    if #out == 0 then out = PREVIEW_ART.buffs end

    byUnit[bar.id] = out
    return out
end

function Special.drawPreview(f, row, unitKey, bar, st, now)
    local art = Special.previewArt(unitKey, bar)
    for i = 1, st.max do
        local icon     = art[((i - 1) % #art) + 1]
        local duration = PREVIEW_DURATIONS[((i - 1) % #PREVIEW_DURATIONS) + 1]
        local left     = duration - ((now + i * 5) % duration)
        drawAuraIcon(row, i, st, icon, (i % 3 == 0) and (i + 1) or 1,
            duration, now + left, now)
    end
    finishAuraRow(f, row, st.max, st)
end

function Special.updateRow(f, bar, uKey, u, d, now)
    local row = Special.row(f, bar.id)

    local st = readAuraStyle(bar, d.general, Data.SpecialAnchor(bar.anchor), true)

    if auraPreviewUnit == uKey then
        Special.drawPreview(f, row, uKey, bar, st, now)
        return row
    end

    local shown = 0
    for _, which in ipairs(AURA_KINDS) do
        local lookup = Data.AuraLookup(uKey, which)
        -- Nothing of this kind bound to this frame is the common case for at
        -- least one of the two, and it costs one lookup to skip a forty-slot scan.
        if (lookup.bars[bar.id] or 0) > 0 and shown < st.max then
            local filter = AURA_FILTER[which]
            if bar.onlyMine then filter = filter .. "|PLAYER" end

            wipe(auraSeen)
            for i = 1, MAX_AURA_SCAN do
                local name, icon, count, duration, expires, spellID = readAura(f.unit, i, filter)
                if not name then break end

                local key = name:lower()
                local hit = (spellID and lookup.byID[spellID]) or lookup.byName[key]
                if hit and lookup.barFor[hit] == bar.id then
                    shown = shown + 1
                    auraSeen[key] = true
                    learnAura(hit, spellID, icon)
                    drawAuraIcon(row, shown, st, icon, count, duration, expires, now)
                    if shown >= st.max then break end
                end
            end

            -- Inferred auras land on the frame their entry was moved to, under
            -- the same two conditions the row above the bar applies them: the
            -- unit type has to be working them out at all, and "only mine" turns
            -- them off because the store doesn't keep who cast what.
            --
            -- Everything else about a frame is read off the FRAME, never off the
            -- row the entry came from. Whether events are consulted is the one
            -- exception, and it isn't a preference — it's whether this unit type
            -- has anything worked out from events to offer.
            if shown < st.max and u.fromEvents and not bar.onlyMine then
                for _, rec in ipairs(collectInferred(f, which, auraSeen, now, lookup, bar.id)) do
                    shown = shown + 1
                    drawAuraIcon(row, shown, st, rec.icon, rec.count,
                        rec.timed and rec.duration or 0,
                        rec.timed and rec.expires  or 0, now)
                    if shown >= st.max then break end
                end
            end
        end
    end

    finishAuraRow(f, row, shown, st)
    return row
end

function Special.updateRows(f)
    local rows = f.specialRows
    if not rows then return end

    local d = cfg()
    local a = d and d.auras
    local uKey = f.kind and Data.AURA_UNIT_FOR_KIND[f.kind]
    local u    = uKey and a and a.units and a.units[uKey]
    local live = (f.unit and a and a.enabled ~= false and u) and true or false

    local now = live and GetTime() or 0
    -- Stamped rather than collected into a set of what drew: this runs per plate
    -- per tick, and a table built to be thrown away every time is the kind of
    -- garbage a raid pull multiplies by forty.
    Special.pass = Special.pass + 1
    if live then
        for _, bar in ipairs(Data.SpecialBars(uKey)) do
            if bar.enabled ~= false then
                Special.updateRow(f, bar, uKey, u, d, now).pass = Special.pass
            end
        end
    end

    -- Everything that didn't draw is put away: switched off, deleted, or built
    -- for the unit type this plate no longer holds. Plates are recycled, so the
    -- frames it filled for a player are still on it when an NPC takes it over.
    for _, row in pairs(rows) do
        if row.pass ~= Special.pass and (row.shown or 0) > 0 then hideAuraRow(row) end
    end
end

local function updateAuras(f)
    if not f.auraRows then return end
    f.auraDirty = nil
    for _, which in ipairs(AURA_KINDS) do updateAuraRow(f, which) end
    Special.updateRows(f)
end

-- Ticks the timer text on whatever is showing, without re-scanning. An expired
-- aura marks the plate for a rescan: UNIT_AURA normally covers that, but a unit
-- whose auras expire while the event is missed (out of range, or a plate that
-- appeared mid-fight) would wear a dead icon. Split out so the boss mod row gets
-- the same countdown free. Returns whether anything ran out, since which flag
-- that sets depends on the row's feed — a boss timer ending must not send the
-- aura scan round again.
local function tickRowTimers(row, now)
    local dead = false
    for i = 1, row.shown or 0 do
        local b = row.icons[i]
        local expires = b and b.expires
        if expires then
            local left = expires - now
            if left <= 0 then
                dead = true
            elseif b.timerOn then
                b.timer:SetText(auraTimeText(left))
            end
        end
    end
    return dead
end

local function advanceAuraTimers(f)
    if not f.auraRows then return end
    local now = GetTime()
    for _, row in pairs(f.auraRows) do
        if tickRowTimers(row, now) then f.auraDirty = true end
    end
    -- Special frames are fed by the same scan as the rows above the bar, so an
    -- icon running out on one means the same thing: rescan the plate.
    if f.specialRows then
        for _, row in pairs(f.specialRows) do
            if tickRowTimers(row, now) then f.auraDirty = true end
        end
    end
    if f.bossRow and tickRowTimers(f.bossRow, now) then f.bossDirty = true end
end

-- ── Boss mod timers ──────────────────────────────────────────────────────────
-- Nothing here is a boss mod. DBM and BigWigs work out what the fight is doing;
-- all this does is take the bars they announce and, where they name the unit a
-- bar is about, draw it as an icon on that unit's plate. Neither installed means
-- one `if` on login and nothing afterwards.
--
-- Both are supported because either can be the one running: DBM through its
-- timer callbacks, BigWigs through the nameplate-bar messages it fires for
-- exactly this purpose.

-- Everything below hangs off one table rather than a local apiece: Lua 5.1 caps
-- a chunk at 200 locals and this file sits close enough to that ceiling that one
-- feature's worth is the difference between loading and not.
local Boss = {
    -- [guid] = { [key] = record }, a record being what one bar needs to be drawn.
    bars     = {},
    -- [key] = guid. DBM's stop callback names the bar and nothing else, so
    -- without this there'd be no way back to the plate holding it.
    owner    = {},
    guids    = 0,

    -- Hooked once and left hooked. Unregistering would be tidier, but DBM's and
    -- BigWigs' unregister APIs have both moved between versions, and a handler that
    -- returns immediately on a switched-off setting costs nothing measurable.
    hooked   = { dbm = false, bigwigs = false },
    -- BigWigs registers messages against a table, AceEvent-style.
    listener = {},

    -- Soonest first: on a plate wearing two of these, the one about to land is
    -- what the first slot is worth spending on.
    scratch  = {},

    -- Switched on by the settings UI while the Boss mods tab is open. On every
    -- plate, not one unit type's: a boss mod timer belongs to whatever the encounter
    -- says it does.
    preview  = false,

    -- A bar whose stop never arrived — the mob died out of range, the boss mod
    -- was reloaded mid-pull — would otherwise sit at zero forever.
    SWEEP      = 2,
    sinceSweep = 0,
}

-- Namespaced per boss mod: the two number their bars independently and there is
-- no reason their ids can't collide.
local function dbmKey(id)  return "dbm\0" .. tostring(id)  end
local function bwKey(text) return "bw\0"  .. tostring(text) end

function Boss.dirty(guid)
    local f = guid and byGUID[guid]
    if f then f.bossDirty = true end
end

function Boss.forget(guid)
    local bag = guid and Boss.bars[guid]
    if not bag then return end
    for key in pairs(bag) do Boss.owner[key] = nil end
    Boss.bars[guid] = nil
    Boss.guids = Boss.guids - 1
    Boss.dirty(guid)
end

function Boss.drop(key)
    local guid = Boss.owner[key]
    if not guid then return end
    Boss.owner[key] = nil

    local bag = Boss.bars[guid]
    if not (bag and bag[key]) then return end
    bag[key] = nil
    Boss.dirty(guid)

    if next(bag) == nil then
        Boss.bars[guid] = nil
        Boss.guids = Boss.guids - 1
    end
end

-- Everything a boss mod must have told us for a bar to be drawable. A bar with
-- no GUID is about the encounter rather than a mob, so there's no plate for it.
function Boss.start(guid, key, icon, duration)
    duration = tonumber(duration) or 0
    if not (type(guid) == "string" and guid ~= "" and duration > 0) then return end

    local bag = Boss.bars[guid]
    if not bag then
        bag = {}
        Boss.bars[guid] = bag
        Boss.guids = Boss.guids + 1
    end

    -- Rebound rather than replaced, so a bar that restarts keeps its place in
    -- the row instead of the strip reshuffling under it.
    local rec = bag[key]
    if not rec then
        rec = {}
        bag[key] = rec
    end
    rec.icon     = icon
    rec.duration = duration
    rec.expires  = GetTime() + duration

    Boss.owner[key] = guid
    Boss.dirty(guid)
end

function Boss.wipe()
    if Boss.guids == 0 then return end
    for guid in pairs(Boss.bars) do Boss.dirty(guid) end
    wipe(Boss.bars)
    wipe(Boss.owner)
    Boss.guids = 0
end

-- Cheap when the store is empty, which is every moment outside a raid.
function Boss.sweep(elapsed)
    if Boss.guids == 0 then return end
    Boss.sinceSweep = Boss.sinceSweep + elapsed
    if Boss.sinceSweep < Boss.SWEEP then return end
    Boss.sinceSweep = 0

    local now = GetTime()
    for guid, bag in pairs(Boss.bars) do
        local live, pruned = false, false
        for key, rec in pairs(bag) do
            if now >= rec.expires then
                bag[key] = nil
                Boss.owner[key] = nil
                pruned = true
            else
                live = true
            end
        end
        if pruned then Boss.dirty(guid) end
        if not live then
            Boss.bars[guid] = nil
            Boss.guids = Boss.guids - 1
        end
    end
end

-- Read per callback rather than cached: these fire a handful of times a pull,
-- and a stale answer would mean a switch that only takes effect next reload.
function Boss.on(which)
    local d = cfg()
    local o = d and d.bossMods
    if not (isEnabled() and o and o.enabled ~= false) then return false end
    return o[which] ~= false
end

function Boss.hookDBM()
    if Boss.hooked.dbm then return end
    local dbm = _G.DBM
    if not (dbm and dbm.RegisterCallback) then return end
    Boss.hooked.dbm = true

    -- The GUID is the last argument and only newer DBM builds send it. Without one
    -- the bar isn't about a unit, and Boss.start drops it.
    local ok = pcall(dbm.RegisterCallback, dbm, "DBM_TimerStart",
        function(_, id, _, timer, icon, _, _, _, _, _, _, _, guid)
            if not Boss.on("dbm") then return end
            Boss.start(guid, dbmKey(id), icon, timer)
        end)
    if not ok then
        Boss.hooked.dbm = false
        return
    end

    pcall(dbm.RegisterCallback, dbm, "DBM_TimerStop", function(_, id)
        Boss.drop(dbmKey(id))
    end)

    -- Bars get extended mid-fight (a cast pushed back, a phase change). Without
    -- this the icon would keep counting down to a time that has moved.
    pcall(dbm.RegisterCallback, dbm, "DBM_TimerUpdate", function(_, id, elapsed, total)
        local key  = dbmKey(id)
        local guid = Boss.owner[key]
        local rec  = guid and Boss.bars[guid] and Boss.bars[guid][key]
        if not rec then return end
        total   = tonumber(total)   or rec.duration
        elapsed = tonumber(elapsed) or 0
        rec.duration = total
        rec.expires  = GetTime() + math.max(0, total - elapsed)
        Boss.dirty(guid)
    end)
end

function Boss.hookBigWigs()
    if Boss.hooked.bigwigs then return end
    local loader = _G.BigWigsLoader
    if not (loader and loader.RegisterMessage) then return end
    Boss.hooked.bigwigs = true

    -- The nameplate messages specifically, not BigWigs_StartBar: an ordinary bar
    -- carries no GUID. A build without the nameplate feature never fires these.
    local ok = pcall(loader.RegisterMessage, Boss.listener, "BigWigs_StartNameplateBar",
        function(_, _, _, text, time, icon, guid)
            if not Boss.on("bigwigs") then return end
            Boss.start(guid, bwKey(text), icon, time)
        end)
    if not ok then
        Boss.hooked.bigwigs = false
        return
    end

    pcall(loader.RegisterMessage, Boss.listener, "BigWigs_StopNameplateBar",
        function(_, _, text)
            Boss.drop(bwKey(text))
        end)

    -- The whole unit at once, which is what BigWigs sends when a mob dies.
    pcall(loader.RegisterMessage, Boss.listener, "BigWigs_StopNameplateBars",
        function(_, _, guid)
            Boss.forget(guid)
        end)
end

-- Boss.on already answers "and is the whole feature on", so there is nothing to
-- check ahead of these.
function Boss.sync()
    if Boss.on("dbm")     then Boss.hookDBM()     end
    if Boss.on("bigwigs") then Boss.hookBigWigs() end
end

-- Stand-in art for the preview.
Boss.PREVIEW_ART = {
    "Interface\\Icons\\Ability_Warrior_ShieldWall",
    "Interface\\Icons\\Spell_Shadow_AntiMagicShell",
    "Interface\\Icons\\Spell_Fire_SelfDestruct",
    "Interface\\Icons\\Ability_Creature_Cursed_02",
}

-- Deliberately uneven, so the swipes don't sweep as one block.
Boss.PREVIEW_DURATIONS = { 18, 27, 11, 40 }

function Boss.drawPreview(f, row, st, now)
    for i = 1, st.max do
        local icon     = Boss.PREVIEW_ART[((i - 1) % #Boss.PREVIEW_ART) + 1]
        local duration = Boss.PREVIEW_DURATIONS[((i - 1) % #Boss.PREVIEW_DURATIONS) + 1]
        -- Looped off the clock and offset per icon, so countdowns keep moving out of
        -- step rather than freezing at zero. An icon reaching zero marks the plate,
        -- bringing the row back here with fresh offsets.
        local left     = duration - ((now + i * 5) % duration)
        drawAuraIcon(row, i, st, icon, nil, duration, now + left, now)
    end
    finishAuraRow(f, row, st.max, st)
end

function Boss.updateRow(f)
    local row = f.bossRow
    if not row then return end
    f.bossDirty = nil

    local d = cfg()
    local o = d and d.bossMods
    if not (f.unit and o and o.enabled ~= false) then
        hideAuraRow(row)
        return
    end

    local st  = readAuraStyle(o, d.general, "TOPLEFT")
    local now = GetTime()

    -- Ahead of the store, like the aura preview sits ahead of the whitelist: it
    -- shows what the settings WOULD draw, and "no timer running" is exactly when
    -- that's worth seeing.
    if Boss.preview then
        Boss.drawPreview(f, row, st, now)
        return
    end

    local bag = f.guid and Boss.bars[f.guid]
    if not bag then
        hideAuraRow(row)
        return
    end

    local list = Boss.scratch
    wipe(list)
    for _, rec in pairs(bag) do
        if rec.expires > now then list[#list + 1] = rec end
    end
    table.sort(list, function(a, b) return a.expires < b.expires end)

    local shown = 0
    for _, rec in ipairs(list) do
        shown = shown + 1
        drawAuraIcon(row, shown, st, rec.icon, nil, rec.duration, rec.expires, now)
        if shown >= st.max then break end
    end
    finishAuraRow(f, row, shown, st)
end

-- ── Quest objectives ─────────────────────────────────────────────────────────
-- No unit API says "this mob counts towards a quest", so it comes off the unit
-- tooltip: a line carrying an "x/y" counter means this unit feeds an objective.
--
-- WHICH icon needs the objective's kind, and the tooltip only has the player's
-- language. So C_QuestLog classifies it — its objective text is the same string
-- the tooltip prints minus the progress tail, and stripping that off both makes
-- them comparable.
local QUEST_ICON = {
    monster = "Interface\\Icons\\INV_Sword_04",       -- kill it
    item    = "Interface\\Icons\\INV_Misc_Bag_08",    -- it drops something
}

local questTypes = {}          -- [stripped objective text] = "monster" | "item" | …
local questTypesStale = true

-- Text off a protected API can come back as a secret value that survives being
-- stored then throws the moment anything matches against it. Everything read
-- from the tooltip and quest log goes through here.
local function safeText(v)
    if issecretvalue and issecretvalue(v) then return nil end
    return type(v) == "string" and v or nil
end

local function objectiveKey(text)
    if not text or text == "" then return nil end
    local key = text:gsub("%s*:?%s*%d+%s*/%s*%d+%s*$", "")
    key = key:gsub("^%s+", ""):gsub("%s+$", "")
    return key ~= "" and key:lower() or nil
end

local function rebuildQuestTypes()
    questTypesStale = false
    wipe(questTypes)
    local log = C_QuestLog
    if not (log and log.GetNumQuestLogEntries and log.GetInfo and log.GetQuestObjectives) then
        return
    end
    for i = 1, (log.GetNumQuestLogEntries() or 0) do
        local info = log.GetInfo(i)
        if info and not info.isHeader and info.questID then
            local ok, objectives = pcall(log.GetQuestObjectives, info.questID)
            if ok and objectives then
                for _, obj in ipairs(objectives) do
                    local key = objectiveKey(safeText(obj.text))
                    if key then questTypes[key] = obj.type or "monster" end
                end
            end
        end
    end
end

-- Owned by this module rather than borrowed: driving the shared GameTooltip
-- would fight whatever is actually under the cursor.
local scanTip

-- Returns a kind, or false for "checked, not part of anything". Never nil, so
-- callers can cache it and still tell it from "not looked at yet".
local function scanQuestKind(unit)
    if not unit or not UnitExists(unit) or UnitIsPlayer(unit) then return false end

    if not scanTip then
        scanTip = CreateFrame("GameTooltip", "DrievNameplatesScanTip", nil, "GameTooltipTemplate")
    end
    scanTip:SetOwner(UIParent, "ANCHOR_NONE")
    scanTip:ClearLines()
    scanTip:SetUnit(unit)

    if questTypesStale then rebuildQuestTypes() end

    local name = safeText(UnitName(unit))
    name = name and name:lower() or nil

    local found = false
    -- From 2: line 1 is the unit's name, which can't be an objective and could
    -- match one by coincidence.
    for i = 2, scanTip:NumLines() do
        local line = _G["DrievNameplatesScanTipTextLeft" .. i]
        local text = line and safeText(line:GetText())
        if text and text:find("%d+%s*/%s*%d+") then
            local key = objectiveKey(text)
            local kind = key and questTypes[key]
            if not kind then
                -- Not in the log under that wording (a locale phrasing the tooltip differently).
                -- A line naming the mob itself is something to kill; anything else it drops.
                kind = (name and text:lower():find(name, 1, true)) and "monster" or "item"
            end
            -- A kill objective wins outright: it's the reason to attack the
            -- thing, where a drop is a side effect of having done so.
            if kind == "monster" then return "monster" end
            found = kind
        end
    end
    return found
end

-- Re-checked on a timer, not once on attach: a plate can appear before the
-- client has its tooltip data, and accepting a quest mid-pull has to light up
-- mobs already on screen.
local QUEST_RESCAN = 2

function Icons.updateQuest(f, force)
    local opt = iconOpts(cfg(), "quest")
    if f.nameOnly or not (opt and opt.enabled ~= false and f.unit) then
        f.questIcon:Hide()
        return
    end

    -- Ahead of the scan and its timestamp: the preview says nothing about this unit,
    -- so it must not leave a "checked just now" behind. Alternated per plate so both
    -- arts are on screen together.
    if Icons.preview then
        f.questIcon:SetTexture((Icons.seed(f) % 2 == 0) and QUEST_ICON.item or QUEST_ICON.monster)
        f.questIcon:Show()
        return
    end

    local now = GetTime()
    if force or not f.questCheckedAt or (now - f.questCheckedAt) >= QUEST_RESCAN then
        f.questCheckedAt = now
        f.questKind = scanQuestKind(f.unit)
    end

    local path = f.questKind and (QUEST_ICON[f.questKind] or QUEST_ICON.monster)
    if not path then
        f.questIcon:Hide()
        return
    end
    f.questIcon:SetTexture(path)
    f.questIcon:Show()
end

-- ── Mouseover highlight ──────────────────────────────────────────────────────
-- Keyed off the "mouseover" unit token, NOT a cursor-in-rect test: our frame is
-- parented to Blizzard's plate base, a restricted frame, where every
-- position-measurement API is blocked — IsMouseOver() throws "Can't measure
-- restricted regions" every frame it's polled.
--
-- The token also goes live when you point at the unit's 3D model, which is a
-- fair trade. Run every frame rather than the slow tick (a highlight trailing
-- 100ms reads as broken), so it does nothing unless the shown state changes.
-- `hasMouseover` is resolved once by the caller.
local function updateHover(f, hasMouseover)
    local hovered = (hasMouseover and f.unit and UnitIsUnit(f.unit, "mouseover")) and true or false
    if hovered == f.hovered then return end
    f.hovered = hovered
    f.hover:SetShown(hovered)
end

-- ── Target indicator ─────────────────────────────────────────────────────────
-- Anchor point, and which way this piece's x/y push it from the bar. The corner
-- order matches the order presets list their texture coords in.
local INDICATOR_CORNERS = {
    { "TOPLEFT",     -1,  1 },
    { "BOTTOMLEFT",  -1, -1 },
    { "BOTTOMRIGHT",  1, -1 },
    { "TOPRIGHT",     1,  1 },
}

-- Both sides push y the same way: these pieces are mirrored horizontally, not
-- diagonally, so a positive y raises both rather than splitting them apart.
local INDICATOR_SIDES = {
    { "LEFT",  -1, 1 },
    { "RIGHT",  1, 1 },
}

-- Below this the bar is a sliver: there's nothing to decorate, and the scale
-- maths would be asking for sub-pixel textures.
local INDICATOR_MIN_BAR = 4

local function hideIndicator(f)
    if not f.indCorners then return end
    for i = 1, 4 do f.indCorners[i]:Hide() end
    for i = 1, 2 do f.indSides[i]:Hide() end
end

-- Lay one piece out: art, crop, blend, size and position, all scaled together.
local function applyIndicatorPiece(tex, preset, coords, anchor, scale, r, g, b)
    tex:SetTexture(preset.path)
    tex:SetTexCoord(unpack(coords))
    tex:SetBlendMode(preset.blend or "BLEND")
    tex:SetDesaturated(preset.desaturated and true or false)
    tex:SetAlpha(preset.alpha or 1)
    tex:SetVertexColor(r, g, b)
    tex:SetSize(preset.width  * scale * (preset.wscale or 1),
                preset.height * scale * (preset.hscale or 1))

    local point, xDir, yDir = anchor[1], anchor[2], anchor[3]
    tex:ClearAllPoints()
    tex:SetPoint(point, tex:GetParent(), point,
        xDir * (preset.x or 0) * scale,
        yDir * (preset.y or 0) * scale)
end

local function updateIndicator(f, isTarget)
    local d = cfg()
    local t = (d and d.target) or {}
    local preset = Data.TARGET_INDICATORS[t.indicator or "None"]
    local barH = f:GetHeight() or 0

    if not preset or not isTarget or not t.enabled or barH < INDICATOR_MIN_BAR then
        hideIndicator(f)
        return
    end

    local color = (t.indicatorColorEnabled and t.indicatorColor)
        or Data.INDICATOR_COLORS[preset.color or "white"]
        or Data.INDICATOR_COLORS.white
    local cr, cg, cb = rgb(color, 1, 1, 1)

    local corners = (#preset.coords == 4)

    -- Re-anchoring art on every 10Hz tick is what makes an indicator shimmer, so the
    -- layout is only redone when the look changed. Bar height counts: it drives the
    -- scale. Showing is deliberately OUTSIDE the check — the pieces keep their
    -- layout while hidden, so a target dropped and re-picked mustn't wait on a cache
    -- that already matches.
    local st = f.indState
    if not st then
        st = {}
        f.indState = st
    end
    if st.style ~= t.indicator or st.height ~= barH
        or st.r ~= cr or st.g ~= cg or st.b ~= cb then
        st.style, st.height = t.indicator, barH
        st.r, st.g, st.b = cr, cg, cb

        -- autoScale measures the art against the bar so it keeps its proportions at any
        -- plate size; a fixed `scale` pins it; otherwise the art is treated as drawn for
        -- a 10px bar.
        local scale = (not preset.autoScale and preset.scale)
            or (barH / (preset.autoScale and preset.height or 10))

        local pieces  = corners and f.indCorners or f.indSides
        local anchors = corners and INDICATOR_CORNERS or INDICATOR_SIDES
        for i = 1, #anchors do
            applyIndicatorPiece(pieces[i], preset, preset.coords[i], anchors[i],
                scale, cr, cg, cb)
        end
    end

    -- Only ever one set on screen: the preset's shape picks which.
    for i = 1, 4 do f.indCorners[i]:SetShown(corners) end
    for i = 1, 2 do f.indSides[i]:SetShown(not corners) end
end

-- Split out of updateTarget because the two change on different schedules: the
-- target only moves when you retarget, while whether something is fighting you
-- changes on its own.
local function updateAlpha(f)
    local d = cfg()
    if not (d and f.unit) then return end
    local t = d.target or {}
    local g = d.general

    local alpha = pct(g.alpha, 100)
    if t.enabled then
        if f.isTarget then
            alpha = alpha * pct(t.alpha, 100)
        elseif t.dimOthers and UnitExists("target") then
            alpha = alpha * pct(t.othersAlpha, 55)
        end
    end

    -- Multiplied in rather than replacing the target dim. Your own target is exempt
    -- however unbothered it is by you.
    if g.dimInactive and not f.isTarget and not engagedWithPlayer(f.unit) then
        alpha = alpha * pct(g.inactiveAlpha, 45)
    end

    f:SetAlpha(math.max(0, math.min(1, alpha)))
end

-- How far above everything else the target's plate lifts. Nine levels are the
-- plate's own (setPlateLevel), so this clears that plus room for anything
-- parented to a plate from outside.
local TARGET_RAISE = 20

-- Measured against the HIGHEST base plate seen rather than as a bump from this
-- plate's own base: the client gives every base its own level and they aren't
-- the same number per plate, so a target could land under its neighbour — which
-- shows in the indicator ornament, sliced through by the neighbour's bar.
local function raisedLevel()
    local top = 0
    for base in pairs(plates) do
        local lvl = base:GetFrameLevel() or 0
        if lvl > top then top = lvl end
    end
    return top + TARGET_RAISE
end

local function updateTarget(f)
    local d = cfg()
    if not (d and f.unit) then return end
    local t = d.target or {}

    local wasTarget = f.isTarget
    local isTarget  = UnitIsUnit(f.unit, "target") and true or false
    f.isTarget = isTarget

    -- Both of these frame the health bar, so on a name-only plate they'd ring
    -- and decorate empty space.
    local showGlow = isTarget and t.enabled and t.highlight and not f.nameOnly
    setBorderShown(f.glow, showGlow)
    updateIndicator(f, isTarget and not f.nameOnly)
    updateAlpha(f)

    local raise = t.enabled and t.raise and isTarget
    setPlateLevel(f, raise and raisedLevel() or f.baseLevel)

    -- Target scale lives in updateStyle, so only re-run it when the flag flips.
    if wasTarget ~= isTarget then updateStyle(f) end
end

-- ── Cast bar ─────────────────────────────────────────────────────────────────
-- Polled rather than event-driven: nameplate units come and go constantly, and
-- routing eight spellcast events through a unit→plate map still misses a plate
-- appearing partway through a cast.
local function refreshCast(f)
    local unit = f.unit
    local grp  = f.group
    if not unit or grp.showCastBar == false or f.nameOnly then
        f.casting = nil
        showCast(f, false)
        return
    end

    local name, text, texture, startMS, endMS = UnitCastingInfo(unit)
    local channel = false
    if not name then
        name, text, texture, startMS, endMS = UnitChannelInfo(unit)
        channel = name and true or false
    end

    if not name or not startMS or not endMS then
        f.casting = nil
        showCast(f, false)
        return
    end

    local start = startMS / 1000
    f.castStart   = start
    f.castEnd     = endMS / 1000
    f.cast:SetMinMaxValues(start, f.castEnd)

    -- Everything below is the same for every tick of one cast, and this runs 10Hz
    -- per plate. Re-reading the start time is how a pushback or a second cast of the
    -- same spell is still noticed.
    if f.casting and f.castSeen == start and f.castChannel == channel then return end
    f.casting     = true
    f.castSeen    = start
    f.castChannel = channel
    f.cast:SetStatusBarColor(rgb(channel and grp.castChannelColor or grp.castColor, 0.9, 0.7, 0.15))
    if grp.castShowName ~= false then f.castName:SetText(text or name) end
    if grp.castShowIcon ~= false then f.castIcon:SetTexture(texture) end
    showCast(f, true)
end

local function advanceCast(f)
    if not f.casting then return end
    local now = GetTime()
    if now >= f.castEnd then
        f.casting = nil
        showCast(f, false)
        return
    end
    -- A channel drains instead of filling, matching every other cast bar in the
    -- game (and making "how long do I have left" readable at a glance).
    f.cast:SetValue(f.castChannel and (f.castEnd - (now - f.castStart)) or now)
    if f.group.castShowTimer ~= false then
        f.castTime:SetFormattedText("%.1f", math.max(0, f.castEnd - now))
    end
end

-- Everything that only changes when the unit or the settings do.
local function fullUpdate(f)
    if not f.unit then return end
    updateStyle(f)
    updateName(f)
    updateHealth(f)
    updateColor(f)
    updateTarget(f)
    refreshCast(f)
    Icons.updateRaid(f)
    Icons.updateUnit(f)
    updateTargetOfTarget(f)
    updateAuras(f)
    -- Read straight from the store rather than left to the dirty flag: a plate that
    -- came into view mid-pull missed every timer callback naming this GUID.
    Boss.updateRow(f)
    -- Forced: this is a unit the plate has not shown before, so the rescan
    -- timer's "checked recently" is about the previous occupant.
    Icons.updateQuest(f, true)
end

-- ── Attach / detach ──────────────────────────────────────────────────────────
-- Base plates are recycled between units, so every field derived from the OLD
-- occupant is cleared here — above all isTarget and castSeen, which gate work
-- that would otherwise be skipped for the new one.
local function clearUnit(f)
    -- Guarded on identity: a handover can attach the new occupant before the old is
    -- cleared, and an unconditional wipe would take the entry the new plate had just
    -- claimed for the same GUID.
    if f.guid and byGUID[f.guid] == f then byGUID[f.guid] = nil end
    f.guid = nil
    f.unit, f.npcID, f.kind, f.group = nil, nil, nil, nil
    f.casting, f.castSeen = nil, nil
    f.isTarget = false
    -- Both wiped, not just the answer: keeping the timestamp would let the next
    -- occupant inherit "checked two seconds ago" and wear this one's icon.
    f.questKind, f.questCheckedAt = nil, nil
    f.raidIcon:Hide()
    f.questIcon:Hide()
    -- The four static ones too: they describe the unit that has just left, and
    -- the plate can be handed a normal mob before anything reads them again.
    f.factionIcon:Hide()
    f.eliteIcon:Hide()
    f.rareIcon:Hide()
    f.petIcon:Hide()
    -- Likewise the target-of-target line and bar: they name whoever the OLD occupant
    -- was hitting.
    f.totText:Hide()
    f.totClip:Hide()
    f.totBar:Hide()
    -- The whole strip, not just the flag: the icons belong to the unit that just
    -- left, and leaving them up shows the new occupant wearing its debuffs.
    f.auraDirty, f.bossDirty = nil, nil
    if f.iconRows then
        for _, row in ipairs(f.iconRows) do hideAuraRow(row) end
    end
    -- Wiped so the next unit on this recycled plate snaps to its size instead of
    -- easing there from whatever the previous one was showing.
    f.curScale = nil
    showCast(f, false)
    f.hover:Hide()
    f.hovered = nil
    setBorderShown(f.glow, false)
    hideIndicator(f)
end

-- ── Anchor for other addons ──────────────────────────────────────────────────
-- LibGetFrame is how WeakAuras and friends find a nameplate's frame. It walks a
-- list of known addons and, matching none, falls through to Blizzard's
-- `UnitFrame.healthBar` — which this module HIDES, so an anchored aura attaches
-- to a hidden frame and is never drawn.
--
-- `nameplate.unitFrame.Health` is its first check, and the lib tests that same
-- condition twice under different addon labels, so it's the closest thing to a
-- convention there is. Left alone if something else got there first.
local function exposeAnchor(base, f)
    if base.unitFrame and base.unitFrame ~= f then return end
    f.Health = f.health
    base.unitFrame = f
end

local function clearAnchor(base, f)
    if base.unitFrame == f then base.unitFrame = nil end
end

local function detach(base, f)
    if f then
        clearUnit(f)
        f:Hide()
        -- Blizzard's plate is coming back, so its bar is the right anchor again.
        clearAnchor(base, f)
    end
    setBlizzardShown(base, true)
end

local function attach(unit)
    local base = C_NamePlate.GetNamePlateForUnit(unit)
    if not base then return end
    local f = getPlate(base)

    local d = cfg()
    if not (d and isEnabled()) then
        detach(base, f)
        return
    end

    local kind = unitKind(unit)
    local grp  = groupFor(d, kind)
    -- A group switched off means "leave these alone", not "hide them" — the
    -- Blizzard plate comes back for that unit type.
    if not grp.enabled then
        detach(base, f)
        return
    end

    clearUnit(f)
    -- Re-read rather than kept from buildPlate: the client hands base plates out and
    -- takes them back, and the level it gives one is not the level it had when we
    -- built on it. Every level here derives from this number.
    f.baseLevel = (base:GetFrameLevel() or 0) + 1
    f.unit  = unit
    f.kind  = kind
    f.group = grp
    f.guid  = UnitGUID(unit)
    f.npcID = npcIDFromGUID(f.guid)
    if f.guid then byGUID[f.guid] = f end

    setBlizzardShown(base, false)
    exposeAnchor(base, f)
    active[unit] = f
    f:Show()
    fullUpdate(f)
end

-- Deliberately OUT of attach(): a plate we don't take over is still an NPC
-- you've met, and mousing over one whose plate is hidden should count too.
local function rememberUnit(unit)
    if not (unit and UnitExists(unit)) then return end
    if UnitIsPlayer(unit) or not isEnabled() then return end
    local id = npcIDFromGUID(UnitGUID(unit))
    if not id then return end
    local zone = GetRealZoneText()
    if not zone or zone == "" then zone = GetZoneText() end
    if Data.Remember(id, UnitName(unit), zone) and NP.onNpcAdded then
        NP.onNpcAdded()
    end
end

local function release(unit)
    local f = active[unit]
    active[unit] = nil
    if not f then return end
    local base = f:GetParent()
    clearUnit(f)
    f:Hide()
    -- Deliberately does NOT re-show Blizzard's plate: the base is about to be
    -- recycled, and un-hiding here makes it flicker back in for a frame on every
    -- handover.
    if not isEnabled() then setBlizzardShown(base, true) end
end

-- ── CVars / engine settings ──────────────────────────────────────────────────
-- SetCVar is refused in combat, so a mid-fight change is replayed on
-- PLAYER_REGEN_ENABLED rather than lost.
local cvarsPending = false

local function setCVarSafe(name, value)
    pcall(SetCVar, name, value)
end

-- The clickable base plate is a separate frame from the bar, in WorldFrame's
-- space (scale 1) while the bar draws at the interface scale. So its size can't
-- be the bar's width: a 190-wide bar at 0.65 UI scale covers only 124 units of
-- base plate, and any flat number is wrong the moment either scale changes.
--
-- One size covers every plate (the API is global), from whichever unit type
-- draws the widest bar. The target multiplier is left out — growing every click
-- box for the one plate you already clicked makes packed plates fight over the
-- mouse. CLICK_PAD is slack so clicks just off a thin bar still land.
--
-- The vertical half is not only slack: it lands in the HEIGHT handed to
-- SetNamePlateSize, and that rect is what the client stacks plates by. On a 22px
-- bar it is most of the gap between two stacked plates, which is why it is a
-- setting (general.clickPadX/Y) rather than a constant — a "my plates are too far
-- apart" reading has to be able to tell this apart from Vertical spacing, and
-- then act on it. These are only the fallbacks behind those keys.
local CLICK_PAD_X_DEFAULT, CLICK_PAD_Y_DEFAULT = 10, 24

-- Floored and clamped at the read rather than the write, so a value that reached
-- the profile some other way (import, hand-edited SavedVariables) can't hand a
-- fractional or negative size to the plate API.
local function clickPad(g)
    local x = math.floor(tonumber(g and g.clickPadX) or CLICK_PAD_X_DEFAULT)
    local y = math.floor(tonumber(g and g.clickPadY) or CLICK_PAD_Y_DEFAULT)
    return math.max(0, x), math.max(0, y)
end

local sizesPending = false

-- The plate's size is NOT the clickable area: the client applies a per-type
-- inset cropping the rect inwards, which must be cleared or the outer part of a
-- plate sized to our bar won't take clicks.
--
-- Two generations of this, and 11509 has only the newer:
--
--   C_NamePlateManager.SetNamePlateHitTestInsets(type, l, r, t, b)
--       Current. Positive crops inwards, negative expands — Plater's "click
--       through" toggle is literally +10000 vs -10000 on these.
--
--       Zero does NOT mean "the hit area is the plate rect". Measured on 11509:
--       with the plate sized past the bar and zeros passed here, the outer bar
--       still refused clicks — the client crops by an amount of its own and
--       won't say how much, since the getter returns secret values.
--
--   C_NamePlate.SetNamePlate{Enemy,Friendly}PreferredClickInsets(l, r, t, b)
--       Older, and gone here. Blizzard filled these by measuring BLIZZARD'S
--       health bar against the plate — so with their bar hidden and ours a
--       different size, the crop described a bar that isn't on screen.
--
-- Kept both: the old costs a nil check where it survives, and nothing here can
-- tell which generation the next patch ships.
local lastInsetReport = nil

-- Applied to all four sides, large enough to swamp whatever the client crops by.
-- It has to be "big enough" rather than measured: the crop isn't exposed and the
-- getter is unreadable, so there's nothing to subtract from. Same value Plater
-- ships for its "definitely clickable" state, and the expansion is clamped.
--
-- Being global rather than per-plate is what makes the hit area follow the
-- nameplate on its own: one write covers every plate, present and future. What
-- each plate is worth clicking is decided by its SIZE (applyPlateSizes); this
-- just stops the client shrinking that back down.
local HIT_INSET_EXPAND = -10000

-- Overridable live by `/denp inset <n>`, so a client that clamps differently can
-- be dialled in without a rebuild.
local hitInset = HIT_INSET_EXPAND

local function applyHitInsets(n)
    local report = {}

    local mgr = C_NamePlateManager
    if mgr and mgr.SetNamePlateHitTestInsets and Enum and Enum.NamePlateType then
        for _, key in ipairs({ "Enemy", "Friendly" }) do
            local kind = Enum.NamePlateType[key]
            if kind ~= nil then
                local ok, err = pcall(mgr.SetNamePlateHitTestInsets, kind, n, n, n, n)
                table.insert(report, { name = "HitTestInsets." .. key, ok = ok, err = err })
            else
                table.insert(report, { name = "HitTestInsets." .. key, missing = true })
            end
        end
    end

    -- Never expanded, only cleared. On the older API zero already means "the whole
    -- plate rect" — its crop came from measuring Blizzard's health bar, not a hidden
    -- client-side shrink — so the swamp-it value the newer one needs has nothing to
    -- do here, and its behaviour past zero is untested on any client this runs on.
    local old = math.max(n, 0)
    for _, key in ipairs({ "Enemy", "Friendly" }) do
        local fn = C_NamePlate["SetNamePlate" .. key .. "PreferredClickInsets"]
        if fn then
            local ok, err = pcall(fn, old, old, old, old)
            table.insert(report, { name = "PreferredClickInsets." .. key, ok = ok, err = err })
        end
    end

    lastInsetReport = report
end

local function clearClickInsets()
    if InCombatLockdown() then
        sizesPending = true
        return
    end
    applyHitInsets(hitInset)
end

-- Returns the click box the current settings ask for, in base-plate units, plus
-- the bar extents it came from. Split out of applyPlateSizes so the debug dump
-- reports exactly what was sent to the client rather than its own re-guess.
local function computePlateSize()
    local d = cfg()
    if not d then return nil end
    local g = d.general

    local ui, global = uiScale(), pct(g.scale, 100)
    local widest, tallest = 0, 0
    for _, key in ipairs({ "enemyNPC", "enemyPlayer" }) do
        local grp = d[key]
        if grp then
            local s = ui * global * pct(grp.scale, 100)
            widest  = math.max(widest,  (tonumber(grp.width)  or 124) * s)
            tallest = math.max(tallest, (tonumber(grp.height) or 12)  * s)
        end
    end
    if widest <= 0 then return nil end

    -- Rounded: these end up as frame sizes, and a fractional one only invites the
    -- same per-side pixel rounding that made the borders uneven.
    local padX, padY = clickPad(g)
    return math.floor(widest  + padX + 0.5),
           math.floor(tallest + padY + 0.5),
           widest, tallest
end

-- Every plate-size setter that has existed, newest first. SetNamePlateSize is
-- the unified one on current clients and it is the one that wins where it
-- exists — the per-type setters are the older API and are not necessarily
-- honoured alongside it (Plater branches on exactly this: `if
-- C_NamePlate.SetNamePlateSize then ... else the per-type ones ... end`).
-- Calling the whole list in this order costs nothing and stops us silently
-- writing to an API the client has stopped listening to.
local SIZE_SETTERS = {
    "SetNamePlateSize",
    "SetNamePlateOtherSize",
    "SetNamePlateEnemySize",
    "SetNamePlateFriendlySize",
}

-- Filled in by applyPlateSizes so `/denp dump` can report what was actually
-- attempted and what came back, rather than re-guessing it after the fact.
local lastSizeReport = nil

local function applyPlateSizes()
    if not isEnabled() then return end
    -- Plate geometry belongs to the secure nameplate system, so both the size
    -- setters and the inset ones are refused while the player is in combat.
    if InCombatLockdown() then
        sizesPending = true
        return
    end
    sizesPending = false

    local w, h = computePlateSize()
    if not w then return end

    local report = { w = w, h = h, calls = {} }
    for _, fn in ipairs(SIZE_SETTERS) do
        if C_NamePlate[fn] then
            local ok, err = pcall(C_NamePlate[fn], w, h)
            table.insert(report.calls, { name = fn, ok = ok, err = err })
        else
            table.insert(report.calls, { name = fn, missing = true })
        end
    end
    lastSizeReport = report

    -- Sizing the plate is only half of it: the insets crop that rect back down,
    -- and they are stale the moment we stop drawing Blizzard's bar.
    clearClickInsets()
end

-- Blizzard's driver recomputes plate sizes from its own CVars whenever it runs
-- (a CVar change, a resolution change, VARIABLES_LOADED), which silently throws
-- ours away — including on the very CVar writes applyEngineSettings does just
-- below. Re-asserting afterwards is what makes the size stick.
local sizeHookInstalled = false

local function hookNamePlateDriver()
    if sizeHookInstalled then return end
    if not (NamePlateDriverFrame and NamePlateDriverFrame.UpdateNamePlateOptions) then return end
    sizeHookInstalled = true
    hooksecurefunc(NamePlateDriverFrame, "UpdateNamePlateOptions", applyPlateSizes)

    -- Zeroing once isn't enough: UpdateNamePlateOptions wipes the driver's
    -- `preferredInsets` cache, and the next plate of each type re-derives them from
    -- Blizzard's hidden health bar. Re-zeroing right after it runs is what makes it
    -- hold. Guarded — a driver internal, absent on clients without per-type insets.
    if NamePlateDriverFrame.UpdateInsetsForType then
        hooksecurefunc(NamePlateDriverFrame, "UpdateInsetsForType", function()
            if isEnabled() then clearClickInsets() end
        end)
    end
end

-- Every CVar the engine scales a plate by. The client scales by distance between
-- nameplateMinScale/MaxScale, then multiplies the targeted plate by
-- nameplateSelectedScale again, so the engine's 1.2 and ours compound — which is
-- why a plate could jump when targeted well past the 10-15% asked for. Pinning
-- them to 1 leaves this module's settings as the only thing sizing a plate.
local SCALE_CVARS = {
    "nameplateMinScale", "nameplateMaxScale", "nameplateSelectedScale",
    "nameplateLargerScale", "nameplateGlobalScale",
}

-- Restoring means putting back what YOU had, not what Blizzard ships: these are
-- account-wide CVars this module didn't set, and guessing at defaults would
-- overwrite a deliberate choice. The originals are snapshotted on first pin.
local function restorePlateScales(g)
    local saved = g and g.savedScaleCVars
    if not saved then return end
    for name, value in pairs(saved) do setCVarSafe(name, value) end
    -- Cleared as well as applied: leaving it behind would let a later re-pin
    -- treat our own 1s as "what you had before".
    g.savedScaleCVars = nil
end

local function pinPlateScales(g)
    if g.constantSize == false then
        restorePlateScales(g)
        return
    end

    if not g.savedScaleCVars then
        local saved = {}
        for _, name in ipairs(SCALE_CVARS) do
            local ok, v = pcall(GetCVar, name)
            -- Only what this client actually has: the family has shifted between builds, and
            -- a snapshot entry for a CVar that doesn't exist would fail the restore forever.
            if ok and v ~= nil then saved[name] = v end
        end
        g.savedScaleCVars = saved
    end

    for _, name in ipairs(SCALE_CVARS) do setCVarSafe(name, 1) end
end

-- Every CVar the engine fades a plate by, and why the Fade settings can look
-- ignored: the client dims the BASE plate our frame is a child of, so its alpha
-- and ours multiply. nameplateNotSelectedAlpha ships at 0.5, so targeting one mob
-- halves every other plate whether or not the fade option is ticked.
--
-- nameplateOccludedAlphaMult is deliberately absent: that fires for a unit
-- actually behind something, which is a fact about the world.
local ALPHA_CVARS = {
    "nameplateSelectedAlpha", "nameplateNotSelectedAlpha",
    "nameplateMinAlpha", "nameplateMaxAlpha",
}

local function restorePlateAlphas(g)
    local saved = g and g.savedAlphaCVars
    if not saved then return end
    for name, value in pairs(saved) do setCVarSafe(name, value) end
    g.savedAlphaCVars = nil
end

local function pinPlateAlphas(g)
    if g.constantAlpha == false then
        restorePlateAlphas(g)
        return
    end

    if not g.savedAlphaCVars then
        local saved = {}
        for _, name in ipairs(ALPHA_CVARS) do
            local ok, v = pcall(GetCVar, name)
            if ok and v ~= nil then saved[name] = v end
        end
        g.savedAlphaCVars = saved
    end

    for _, name in ipairs(ALPHA_CVARS) do setCVarSafe(name, 1) end
end

local function applyEngineSettings()
    local d = cfg()
    if not d then return end
    if InCombatLockdown() then
        cvarsPending = true
        return
    end
    cvarsPending = false
    local g = d.general

    if isEnabled() then
        pinPlateScales(g)
        pinPlateAlphas(g)
        setCVarSafe("nameplateShowEnemies", g.showEnemies and 1 or 0)
        setCVarSafe("nameplateShowFriends", g.showFriends and 1 or 0)
        setCVarSafe("nameplateShowAll",     g.showAll and 1 or 0)
        setCVarSafe("nameplateMaxDistance", math.max(5, math.min(41, tonumber(g.maxDistance) or 41)))
        setCVarSafe("nameplateMotion",      g.stacking and 1 or 0)
        setCVarSafe("nameplateOverlapV",    (tonumber(g.overlapV) or 110) / 100)

        -- After the CVar writes above, not before: each of those can wake
        -- Blizzard's driver, which resets the sizes we are about to set.
        hookNamePlateDriver()
        applyPlateSizes()
    end
end

-- ── Driver ───────────────────────────────────────────────────────────────────
-- Assigned by the click-area debugging section at the bottom of the file. A
-- no-op until then, and afterwards unless the overlay is on.
local refreshClickDebug = function() end

local driver = CreateFrame("Frame")
local SLOW_INTERVAL = 0.1
local sinceSlow = 0

-- Exponential ease towards the goal scale, as a fraction of the remaining gap
-- per second. Frame-rate independent, so it takes the same ~0.2s at 30 or 144fps.
local SCALE_RATE = 14
-- Close enough to snap. Without it the ease approaches the goal forever and the
-- plate never stops re-scaling.
local SCALE_EPSILON = 0.002

local function advanceScale(f, elapsed)
    local goal = f.targetScale
    if not (goal and f.curScale) or f.curScale == goal then return end
    local gap = goal - f.curScale
    if math.abs(gap) <= SCALE_EPSILON then
        setPlateScale(f, goal)
        return
    end
    setPlateScale(f, f.curScale + gap * math.min(1, elapsed * SCALE_RATE))
end

-- Registered only while something needs them: COMBAT_LOG_EVENT_UNFILTERED fires
-- for every swing in a forty-man pull, and a profile that infers nothing
-- shouldn't pay to read one.
local inferEventsOn = false
local durationsOn   = false

-- Is any aura strip actually drawing? `requireFromEvents` narrows that to unit
-- types whose strips are ALSO fed by the combat log, which is what the inferred
-- store needs. The duration engine does not: rebuilding the timer on an aura
-- the client already listed has nothing to do with whether we additionally
-- infer the ones it won't list.
local function auraStripsWanted(requireFromEvents)
    if not isEnabled() then return false end
    local d = cfg()
    local a = d and d.auras
    if not (a and a.enabled ~= false and a.units) then return false end

    -- Both halves must hold for the SAME unit type: events on for players is no
    -- reason to listen if only the NPC lists have anything in them.
    for _, def in ipairs(Data.AURA_UNITS) do
        local u = a.units[def.key]
        if u and (u.fromEvents or not requireFromEvents) then
            for _, which in ipairs(AURA_KINDS) do
                local o = u[which]
                local lookup = Data.AuraLookup(def.key, which)
                -- `main`, not `count`: entries moved onto a special frame are
                -- not drawn by this row and can't keep it listening.
                if o and o.enabled ~= false and lookup.main > 0 then return true end
                -- And the frames themselves, which draw whether or not the row
                -- an entry came off is showing — so they answer for themselves.
                for _, bar in ipairs(Data.SpecialBars(def.key)) do
                    if bar.enabled ~= false and (lookup.bars[bar.id] or 0) > 0 then
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function syncAuraEvents()
    -- The duration engine reads the combat log itself and costs nothing while
    -- nobody has registered, so it follows the weaker condition of the two.
    if Durations then
        local wantDurations = auraStripsWanted(false)
        if wantDurations ~= durationsOn then
            durationsOn = wantDurations
            if wantDurations then
                Durations.Register("Nameplates")
            else
                Durations.Unregister("Nameplates")
            end
        end
    end

    local want = auraStripsWanted(true)
    if want == inferEventsOn then return end
    inferEventsOn = want

    if want then
        driver:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
        driver:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    else
        driver:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
        driver:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED")
        -- Held records are guesses that nothing is updating any more, so they
        -- go with the events that fed them.
        wipeInferred()
    end
end

driver:SetScript("OnUpdate", function(_, elapsed)
    -- Ahead of the early-out below: records outlive the plates that showed them,
    -- so the stores still need pruning on a screen with no nameplates on it.
    sweepInferred(elapsed)
    Boss.sweep(elapsed)
    if not next(active) then return end
    sinceSlow = sinceSlow + elapsed
    local slow = sinceSlow >= SLOW_INTERVAL
    if slow then sinceSlow = 0 end

    local d = cfg()
    local hover = d and d.general and d.general.hoverHighlight ~= false
    local hasMouseover = hover and UnitExists("mouseover")
    -- Read once for the whole pass rather than per plate, and only on a slow tick —
    -- learnFromPlate throttles again on top. Under the master switch as well as its
    -- own, since that checkbox sits above the tab the Learned page lives on.
    local learning = slow and d and d.auras
        and d.auras.enabled ~= false and d.auras.learn ~= false
    local now = learning and GetTime() or 0

    for _, f in pairs(active) do
        advanceScale(f, elapsed)
        if hover then updateHover(f, hasMouseover) end
        if slow then
            updateHealth(f)
            updateColor(f)
            refreshCast(f)
            Icons.updateRaid(f)
            -- Self-throttling: this only reaches the tooltip every QUEST_RESCAN
            -- seconds per plate, the rest of the time it just re-reads a cache.
            Icons.updateQuest(f)
            -- No event says a mob has changed target, so this is the only way
            -- the line under the plate ever moves.
            updateTargetOfTarget(f)
            -- Whether something is fighting you changes on its own, with no event to hang it
            -- off — unlike the target dim, which updateTarget covers.
            updateAlpha(f)
            -- Border thickness is snapped against the border frame's effective scale, so it
            -- goes stale when the game rescales the plate. Measured on `deco`, whose
            -- counter-scale cancels our own, so the target-scale animation doesn't drag a
            -- relayout with it.
            local es = f.deco:GetEffectiveScale()
            if es and math.abs(es - (f.borderScale or 0)) > 0.0001 then
                layoutPlateBorders(f)
            end
            -- UNIT_AURA only marks the plate; the rescan happens here, so a raid pull's
            -- burst of aura events costs one scan per plate per tick, not one per event.
            if f.auraDirty then updateAuras(f) end
            -- Marked by the boss mod callbacks and by the sweep, so a plate with
            -- no timers on it costs one nil check here.
            if f.bossDirty then Boss.updateRow(f) end
            advanceAuraTimers(f)
            if learning then learnFromPlate(f, now) end
        end
        -- Cast fill advances every frame (only for the handful of units actually
        -- casting), so the bar is smooth without polling everything at 60Hz.
        if f.casting then advanceCast(f) end
    end
end)

driver:RegisterEvent("PLAYER_LOGIN")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:RegisterEvent("PLAYER_REGEN_ENABLED")
driver:RegisterEvent("PLAYER_TARGET_CHANGED")
driver:RegisterEvent("NAME_PLATE_CREATED")
driver:RegisterEvent("NAME_PLATE_UNIT_ADDED")
driver:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
driver:RegisterEvent("UNIT_NAME_UPDATE")
driver:RegisterEvent("UNIT_LEVEL")
driver:RegisterEvent("UNIT_FACTION")
driver:RegisterEvent("UNIT_MAXHEALTH")
driver:RegisterEvent("UNIT_AURA")
driver:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
driver:RegisterEvent("RAID_TARGET_UPDATE")
-- The objective→type map is built from the quest log, so it goes stale whenever
-- the log does.
driver:RegisterEvent("QUEST_LOG_UPDATE")
driver:RegisterEvent("QUEST_ACCEPTED")
driver:RegisterEvent("QUEST_REMOVED")
-- Plate size and border thickness both derive from the interface scale and
-- neither re-derives itself, so a UI scale change would leave every plate sized
-- for the old one until recycled.
driver:RegisterEvent("UI_SCALE_CHANGED")
driver:RegisterEvent("DISPLAY_SIZE_CHANGED")
-- Only to clear boss mod timers left over from a pull that ended badly. Harmless
-- on a client that never fires it.
driver:RegisterEvent("ENCOUNTER_END")

driver:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
    -- First, and by itself: this is the one event here that arrives in the
    -- thousands, and every comparison ahead of it is paid per swing.
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        onCombatLogAura()
        return
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        onCastSucceeded(arg1, arg3)
        return
    end

    if event == "NAME_PLATE_CREATED" then
        -- A brand-new base plate is built at whatever size Blizzard last told the
        -- pool to use, so it needs our click area stamped on straight away.
        applyPlateSizes()
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        rememberUnit(arg1)
        attach(arg1)
        -- After attach: a base plate only enters `plates` when it first gets a frame of
        -- ours, so this is the earliest the overlay can be hung on a recycled plate.
        refreshClickDebug()
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        release(arg1)
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        rememberUnit("mouseover")
    elseif event == "RAID_TARGET_UPDATE" then
        for _, f in pairs(active) do Icons.updateRaid(f) end
    elseif event == "QUEST_LOG_UPDATE" or event == "QUEST_ACCEPTED" or event == "QUEST_REMOVED" then
        -- Rebuilt lazily on the next scan: QUEST_LOG_UPDATE fires in bursts, and walking
        -- the whole log per event is work the next one throws away.
        questTypesStale = true
        for _, f in pairs(active) do Icons.updateQuest(f, true) end
    elseif event == "PLAYER_TARGET_CHANGED" then
        rememberUnit("target")
        for _, f in pairs(active) do updateTarget(f) end
    elseif event == "UNIT_NAME_UPDATE" or event == "UNIT_LEVEL" then
        local f = active[arg1]
        if f then updateName(f) end
    elseif event == "UNIT_FACTION" then
        local f = active[arg1]
        -- A faction flip can move the unit into a different settings group entirely, so
        -- re-run the whole attach rather than just recolouring.
        if f then attach(arg1) end
    elseif event == "UNIT_MAXHEALTH" then
        local f = active[arg1]
        if f then updateHealth(f) end
    elseif event == "UNIT_AURA" then
        -- Marked, not scanned: this fires for every aura tick on every unit in
        -- range, and the poll tick coalesces the burst into one scan per plate.
        local f = active[arg1]
        if f then f.auraDirty = true end
    elseif event == "UI_SCALE_CHANGED" or event == "DISPLAY_SIZE_CHANGED" then
        NP.refresh()
    elseif event == "PLAYER_REGEN_ENABLED" then
        if cvarsPending then applyEngineSettings() end
        if sizesPending then applyPlateSizes() end
    elseif event == "ENCOUNTER_END" then
        -- Boss mods stop their own bars, but a wipe or a disconnect mid-pull can
        -- leave records behind with nothing coming to clear them.
        Boss.wipe()
    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        Boss.wipe()
        Data.EnsureSeeded()
        applyEngineSettings()
        NP.refresh()
    end
end)

-- ── Public interface ─────────────────────────────────────────────────────────
-- Re-derives every visible plate from current settings. Called by the settings
-- UI on any change, and by core's RefreshAllModules after a profile switch.
function NP.refresh()
    Data.EnsureSeeded()
    -- Before anything reads the aura settings: a profile saved under the old
    -- single-pair shape still has its whitelists at auras.buffs/auras.debuffs.
    Data.MigrateAuras()
    -- After it, since it works on the per-unit-type blocks that migration
    -- creates. Like the NPC seed, it fires here as well as at login so a profile
    -- switched to later gets its starting frame on the switch.
    Data.EnsureSpecialBars()
    -- The whitelists flatten into match maps nothing else diffs, so every path that
    -- can change them drops the cache here. The preview's list derives from them too.
    Data.InvalidateAuras()
    previewArtCache = {}
    applyEngineSettings()
    -- After the invalidate, not before: whether the events are worth listening to
    -- depends partly on whether the whitelists are empty.
    syncAuraEvents()
    -- Retried on every refresh rather than once at login: a boss mod can load on
    -- demand after we've been through here, and hooking is idempotent.
    Boss.sync()

    if not isEnabled() then
        for unit, f in pairs(active) do
            clearUnit(f)
            f:Hide()
            active[unit] = nil
        end
        for base, f in pairs(plates) do
            setBlizzardShown(base, true)
            -- Handing the anchor back too: with the module off, Blizzard's bar
            -- is on screen and ours isn't, so it's the one auras should follow.
            clearAnchor(base, f)
        end
        -- The insets and pinned CVars are globals the client keeps until something
        -- changes them, so switching the module off must hand them back.
        if not InCombatLockdown() then
            applyHitInsets(0)
            local d = cfg()
            if d and d.general then
                restorePlateScales(d.general)
                restorePlateAlphas(d.general)
            end
        end
        return
    end

    -- Re-attach from the live plate list rather than `active`: a plate skipped while
    -- the module was off isn't in `active` and would stay Blizzard-styled.
    for _, base in ipairs(C_NamePlate.GetNamePlates() or {}) do
        local unit = base.namePlateUnitToken or (base.UnitFrame and base.UnitFrame.unit)
        if unit and UnitExists(unit) then attach(unit) end
    end
end

-- Draws made-up icon rows instead of real auras on one unit type's plates, so
-- size/spacing/nudge can be judged against real nameplates. Not persisted: a
-- /reload with the window shut mustn't leave fake icons behind.
function NP.SetAuraPreview(unitKey)
    if auraPreviewUnit == unitKey then return end
    auraPreviewUnit = unitKey
    previewArtCache = {}
    for _, f in pairs(active) do updateAuras(f) end
end

-- The same for the boss mod strip, also unpersisted. No unit key: that row is
-- fed by an encounter rather than a kind of unit.
function NP.SetBossPreview(on)
    on = on and true or false
    if Boss.preview == on then return end
    Boss.preview = on
    for _, f in pairs(active) do Boss.updateRow(f) end
end

-- And the markers hung off the bar, for the same reasons again. One call for all
-- six: they sit on one tab, so the tab being open is the whole condition.
function NP.SetIconPreview(on)
    on = on and true or false
    if Icons.preview == on then return end
    Icons.preview = on
    for _, f in pairs(active) do
        Icons.updateRaid(f)
        Icons.updateUnit(f)
        -- Forced: switching the preview off has to go back to what this unit
        -- really is, and the last real answer under it can be minutes old.
        Icons.updateQuest(f, true)
    end
end

-- Ten seconds of stand-in target-of-target on every plate. Ends on a clock
-- rather than on the settings window closing, since this element is normally
-- only on screen while you're busy. Returns the seconds it runs for.
function NP.TestTargetOfTarget()
    totTestUntil = GetTime() + TOT_TEST_SECONDS
    -- Straight away rather than on the next tick: a button that takes up to a
    -- tenth of a second to do anything reads as a button that didn't work.
    for _, f in pairs(active) do updateTargetOfTarget(f) end
    return TOT_TEST_SECONDS
end

-- Set by the settings UI so a newly auto-detected NPC shows up in an open list
-- without needing the tab reopened. Left nil when the panel has never been built.
NP.onNpcAdded = nil

-- Same idea for the aura lists: a by-name entry that has just worked out what
-- it matches should stop showing a question mark while you are looking at it.
NP.onAuraLearned = nil

NP.plates = plates
NP.active = active

-- ── Click-area debugging ─────────────────────────────────────────────────────
-- The click area is invisible, in a different coordinate space from the bar, and
-- its crop has no getter, so "the edges won't click" can't be eyeballed.
--
--   /denp click  outlines each base plate's rect. With insets zeroed that rect
--                IS the click box: a bar outside it means the plate is too
--                small, a bar inside it with dead edges means something else is
--                cropping or covering it. Yellow while the client considers the
--                unit moused over — a cursor-in-rect test is impossible here,
--                see unitIsHovered.
--   /denp dump   the same as numbers, including the two widths in screen pixels.
local function debugPrint(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cfffb2c36Nameplates:|r " .. msg)
end

local clickDebugShown = false

-- Nameplates are hit-tested in the world, under the whole UI, so ANY
-- mouse-enabled frame over one swallows the click — classically an addon that
-- enabled the mouse on a full-screen frame like UIErrorsFrame. Indistinguishable
-- from a too-small click box, so the overlay names whatever is under the cursor.
-- Printed only on change and time-limited, or a cursor on a boundary is two
-- lines of chat a frame.
--
-- Reaches less than it used to, now that the caller's hover test is the mouseover
-- TOKEN rather than a cursor-in-rect test (see unitIsHovered): a frame that
-- blocks world hit-testing outright also stops the token being set, so this can't
-- fire for it. What it still catches is the token coming from the unit's 3D model
-- while a frame covers the plate itself — same finding, reached from the side.
local lastFocusKey, lastFocusAt = nil, 0
local FOCUS_REPORT_INTERVAL = 2

local mouseFocusFrame = addon.GetMouseFocusFrame

local function reportMouseFocus()
    local focus = mouseFocusFrame()
    local key = tostring(focus)
    if key == lastFocusKey then return end
    local now = GetTime()
    if now - lastFocusAt < FOCUS_REPORT_INTERVAL then return end
    lastFocusKey, lastFocusAt = key, now
    if focus and focus ~= WorldFrame then
        local name = (focus.GetName and focus:GetName()) or "an unnamed frame"
        debugPrint(("this unit is your mouseover, but |cffff4040%s|r is over its plate and takes the mouse — that frame is eating the click.")
            :format(name))
    end
end

-- This client pairs the setter with GetNamePlateHitTestInsets, so the overlay can
-- draw where clicks actually land. Insets are per-type and the type follows the
-- unit, so a plate with no unit reads as Friendly.
--
-- The returns need sanitising: pcall protects the CALL, not what comes back, and
-- this client hands out "secret values" that survive being stored then throw the
-- moment anything does arithmetic on or compares them. Plater carries
-- issecretvalue() checks for the same reason.
local function safeNumber(v)
    if issecretvalue and issecretvalue(v) then return nil end
    local ok, n = pcall(tonumber, v)
    if not ok or type(n) ~= "number" then return nil end
    return n
end

-- The same restricted-region wall the hover test hits: measuring a base plate can
-- throw outright rather than return a number. nil means "the client won't say",
-- which is a different answer from 0 and has to stay tellable apart from it.
local function safeSize(frame)
    local ok, w, h = pcall(function() return frame:GetWidth(), frame:GetHeight() end)
    if not ok then return nil end
    return safeNumber(w), safeNumber(h)
end

local function hitInsetsFor(base)
    local mgr = C_NamePlateManager
    if not (mgr and mgr.GetNamePlateHitTestInsets and Enum and Enum.NamePlateType) then
        return nil
    end
    local f = plates[base]
    local unit = f and f.unit
    local hostile = unit and UnitCanAttack("player", unit)
    local kind = hostile and Enum.NamePlateType.Enemy or Enum.NamePlateType.Friendly
    local ok, rl, rr, rt, rb = pcall(mgr.GetNamePlateHitTestInsets, kind)
    if not ok then return nil end

    local l, r, t, b = safeNumber(rl), safeNumber(rr), safeNumber(rt), safeNumber(rb)
    if not (l and r and t and b) then return nil end
    return l, r, t, b, hostile and "enemy" or "friendly"
end

-- Keyed off the "mouseover" unit token for exactly the reason spelled out above
-- updateHover: the overlay is parented to the restricted base plate, where every
-- position-measurement API is blocked. `parent:IsMouseOver()` threw "Can't
-- measure restricted regions" once per plate per frame and took /denp click down
-- with it — and asking our own overlay instead fails the same way, since its rect
-- is anchored to the base.
--
-- So yellow means "the client considers this unit moused over", NOT "the cursor
-- is geometrically inside the outline". Weaker, but for a click box arguably the
-- more useful of the two: it says whether the client agrees your cursor is on the
-- unit at that spot, which is the question being asked. The token also lights up
-- when you point at the unit's 3D model, so it's the reading NEAR THE PLATE that
-- means anything.
local function unitIsHovered(base)
    if not UnitExists("mouseover") then return false end
    local f = plates[base]
    return (f and f.unit and UnitIsUnit(f.unit, "mouseover")) and true or false
end

local function clickBoxOverlay(base)
    local o = base.drievClickBox
    if o then return o end

    o = CreateFrame("Frame", nil, base)
    o:SetAllPoints(base)
    -- Clear of everything the module draws: the target's plate is lifted
    -- TARGET_RAISE above the highest base on screen, and a plate's top sits 8 above
    -- its own level again.
    o:SetFrameLevel((base:GetFrameLevel() or 0) + TARGET_RAISE + 20)

    local fill = o:CreateTexture(nil, "OVERLAY", nil, 6)
    fill:SetTexture(WHITE)
    fill:SetAllPoints(o)
    o.fill = fill

    -- The plate's own border helpers, so the outline is pixel-snapped and sits just
    -- OUTSIDE the rect — the last row of pixels inside it is still click box.
    o.edge = createBorder(o, 7)
    layoutBorder(o.edge, o, 1, 0)

    o:SetScript("OnUpdate", function(self)
        local parent = self:GetParent()

        -- Re-anchored only when the insets actually change: they're per-type and
        -- effectively static, and this runs per plate per frame.
        local l, r, t, b = hitInsetsFor(parent)
        if l and (l ~= self.il or r ~= self.ir or t ~= self.it or b ~= self.ib) then
            self.il, self.ir, self.it, self.ib = l, r, t, b
            -- Positive crops inwards, so the top-left corner moves in by (l, t)
            -- and the bottom-right by (r, b).
            self:ClearAllPoints()
            self:SetPoint("TOPLEFT",     parent, "TOPLEFT",      l, -t)
            self:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -r,  b)
        end

        local over = unitIsHovered(parent)
        local cr, cg = over and 1 or 0, over and 0.85 or 1
        self.fill:SetVertexColor(cr, cg, 0, over and 0.20 or 0.08)
        paintBorder(self.edge, cr, cg, 0, 1)
        if over then reportMouseFocus() end
    end)

    base.drievClickBox = o
    return o
end

local function setClickDebug(shown)
    clickDebugShown = shown and true or false
    for base in pairs(plates) do
        if clickDebugShown then
            clickBoxOverlay(base):Show()
        elseif base.drievClickBox then
            base.drievClickBox:Hide()
        end
    end
end

-- ── Click pad overlay ────────────────────────────────────────────────────────
-- Different question from /denp click, so a different overlay: that one asks
-- "where does the client take a click", this one asks "how much of the plate rect
-- is padding rather than bar" — which is the number that also sets how far apart
-- stacked plates sit, and the one you're tuning on the settings page.
--
-- Four textures covering exactly plate rect MINUS bar, once each: top and bottom
-- run the full width (so they own the corners), left and right only the bar's
-- height. Anchored rather than sized — the bar lives in a scaled frame and the
-- plate rect doesn't, and a cross-frame anchor resolves in screen space across
-- that difference, the same thing `deco` relies on. That also means the bands
-- re-fit themselves when the pad, the bar size or the scale changes, with nothing
-- to recompute.
local function padOverlay(base)
    local o = base.drievPadBox
    if o then return o end

    -- No bar to measure the pad against: a plate that has never held a unit has
    -- no frame of ours yet, and NAME_PLATE_UNIT_ADDED will come back through here.
    local f = plates[base]
    if not (f and f.health) then return nil end

    o = CreateFrame("Frame", nil, base)
    o:SetAllPoints(base)   -- the RAW plate rect, uncropped: what the pad produces
    -- One under the click box overlay, so running both at once layers the same way
    -- every time: the hit-area outline reads over the shaded pad, not through it.
    o:SetFrameLevel((base:GetFrameLevel() or 0) + TARGET_RAISE + 19)

    local h = f.health

    local function band()
        local t = o:CreateTexture(nil, "OVERLAY", nil, 5)
        t:SetTexture(WHITE)
        -- Cyan, so it can't be confused with /denp click's green/yellow if both
        -- are up at once.
        t:SetVertexColor(0.2, 0.8, 1, 0.30)
        return t
    end

    local top = band()
    top:SetPoint("TOPLEFT",  o, "TOPLEFT")
    top:SetPoint("TOPRIGHT", o, "TOPRIGHT")
    top:SetPoint("BOTTOM",   h, "TOP")

    local bottom = band()
    bottom:SetPoint("BOTTOMLEFT",  o, "BOTTOMLEFT")
    bottom:SetPoint("BOTTOMRIGHT", o, "BOTTOMRIGHT")
    bottom:SetPoint("TOP",         h, "BOTTOM")

    local left = band()
    left:SetPoint("LEFT",   o, "LEFT")
    left:SetPoint("RIGHT",  h, "LEFT")
    left:SetPoint("TOP",    h, "TOP")
    left:SetPoint("BOTTOM", h, "BOTTOM")

    local right = band()
    right:SetPoint("RIGHT",  o, "RIGHT")
    right:SetPoint("LEFT",   h, "RIGHT")
    right:SetPoint("TOP",    h, "TOP")
    right:SetPoint("BOTTOM", h, "BOTTOM")

    -- The plate rect's own edge, so the outer boundary of the pad is a line rather
    -- than wherever the tint fades out against the world behind it.
    o.edge = createBorder(o, 7)
    layoutBorder(o.edge, o, 1, 0)
    paintBorder(o.edge, 0.2, 0.8, 1, 1)

    base.drievPadBox = o
    return o
end

-- 0 is off, otherwise the time it comes down at. One value rather than a shown
-- flag alongside a deadline, so the two can't disagree about whether it's up.
local padDebugUntil = 0

local function setPadDebug(until_)
    padDebugUntil = until_ or 0
    local on = padDebugUntil > GetTime()
    for base in pairs(plates) do
        if on then
            local o = padOverlay(base)
            if o then o:Show() end
        elseif base.drievPadBox then
            base.drievPadBox:Hide()
        end
    end

    if on then
        local deadline = padDebugUntil
        C_Timer.After(padDebugUntil - GetTime(), function()
            -- Only the run that scheduled this may take it down. Pressing the
            -- button again mid-window moves the deadline, and every plate that
            -- appears while it's up schedules one of these too — all of them fire,
            -- and this is what makes the stale ones no-ops instead of cutting the
            -- window short.
            if padDebugUntil == deadline then setPadDebug(0) end
        end)
    end
end

refreshClickDebug = function()
    if clickDebugShown then setClickDebug(true) end
    -- Re-run through setPadDebug rather than shown-checked here: a plate that
    -- entered the pool mid-window needs its overlay built, and the deadline is
    -- already carried in padDebugUntil.
    if padDebugUntil > GetTime() then setPadDebug(padDebugUntil) end
end

-- Seconds the settings page's button runs for, and the default for the command.
local PAD_SHOW_SECONDS = 10

-- Returns the seconds it will run for, so the caller can say so without the two
-- of them carrying separate copies of the number.
function NP.ShowClickPadArea(seconds)
    -- Clamped rather than trusted: a "show it for N seconds" call that was handed
    -- 0 or a negative would hide the thing it was asked to show, and the caller
    -- would still be told it was up.
    seconds = math.min(300, math.max(1, tonumber(seconds) or PAD_SHOW_SECONDS))
    setPadDebug(GetTime() + seconds)
    return seconds
end

local function cvarStr(name)
    local ok, v = pcall(GetCVar, name)
    if not ok or v == nil then return name .. "=n/a" end
    return name .. "=" .. tostring(v)
end

-- Base plates print "?" for their unit surprisingly often: namePlateUnitToken is
-- set by Blizzard's driver, not the client, so a plate can be styled before that
-- field appears. Ours is reliable, since attach() put the frame there.
local function plateUnit(base)
    local f = plates[base]
    return base.namePlateUnitToken
        or (f and f.unit)
        or (base.UnitFrame and base.UnitFrame.unit)
        or "?"
end

local function dumpPlate(i, base, w, h)
    local bw, bh = base:GetWidth() or 0, base:GetHeight() or 0
    local mismatch = math.abs(bw - w) > 0.5 or math.abs(bh - h) > 0.5
    debugPrint(("|cffffff00%d|r %s (%s) — rect %.1f x %.1f, scale %.2f%s")
        :format(i, plateUnit(base), base:GetName() or "unnamed", bw, bh, base:GetScale() or 1,
            mismatch and ("  |cffff4040<- we set %d x %d|r"):format(w, h) or ""))

    -- Per side, in screen pixels, from the real edges rather than the widths: a
    -- width comparison averages the sides and can't see a hit area that is the right
    -- SIZE but off-centre.
    local f = plates[base]
    if f and f:IsShown() then
        local bs, fs = base:GetEffectiveScale(), f:GetEffectiveScale()
        local hitL, hitR = (base:GetLeft() or 0) * bs, (base:GetRight() or 0) * bs
        local hitT, hitB = (base:GetTop() or 0) * bs, (base:GetBottom() or 0) * bs

        local l, r, t, b, kind = hitInsetsFor(base)
        if l then
            -- The insets are in plate units, so they scale with the plate.
            hitL, hitR = hitL + l * bs, hitR - r * bs
            hitT, hitB = hitT - t * bs, hitB + b * bs
            debugPrint(("    hit insets (%s): L%.1f R%.1f T%.1f B%.1f"):format(kind, l, r, t, b))
        else
            debugPrint("    hit insets: |cffff4040unreadable|r — box below is the raw plate rect")
        end

        local barL, barR = (f:GetLeft() or 0) * fs, (f:GetRight() or 0) * fs
        local gapL, gapR = barL - hitL, hitR - barR
        -- Shifting the hit area right by d lifts gapR by d and drops gapL by d,
        -- so half their difference is the shift and its sign is the direction.
        local shift = (gapR - gapL) / 2
        debugPrint(("    gap to hit edge: left %.1fpx, right %.1fpx%s")
            :format(gapL, gapR,
                math.abs(shift) > 0.5
                    and ("  |cffff4040hit area sits %.1fpx to the %s of the bar|r")
                        :format(math.abs(shift), shift > 0 and "right" or "left")
                    or ""))
        local barT, barB = (f:GetTop() or 0) * fs, (f:GetBottom() or 0) * fs
        debugPrint(("    vertical gap: %.1fpx above the bar, %.1fpx below")
            :format(hitT - barT, barB - hitB))

        if gapL < 0 or gapR < 0 then
            debugPrint("    |cffff4040the bar sticks out past the hit area on at least one side|r")
        end
    end

    -- Only when it's there: on 11509 it never is, and a "not on this frame" line
    -- per plate is just noise now that the newer inset API is being read above.
    if base.GetPreferredInsets then
        local ok, l, r, t, b = pcall(base.GetPreferredInsets, base)
        if ok and tonumber(l) then
            debugPrint(("    Blizzard's preferred insets: L%.0f R%.0f T%.0f B%.0f")
                :format(l, r or 0, t or 0, b or 0))
        end
    end
end

local function dumpClickArea()
    local w, h, barW, barH = computePlateSize()
    if not w then
        debugPrint("Couldn't derive a plate size — settings aren't loaded yet.")
        return
    end

    debugPrint(("client %s, UI scale %.3f, combat %s")
        :format(tostring(select(4, GetBuildInfo())), uiScale(),
            InCombatLockdown() and "|cffff4040YES (writes are refused)|r" or "no"))
    debugPrint(("widest bar covers %.1f x %.1f plate units -> asking for %d x %d")
        :format(barW, barH, w, h))

    -- Which of the size API exists here, and what the last real attempt did with it.
    -- A "missing" line for SetNamePlateSize vs the per-type ones is the whole
    -- question of which API generation this client listens to.
    local parts = {}
    for _, fn in ipairs(SIZE_SETTERS) do
        table.insert(parts, fn:gsub("SetNamePlate", "") .. "="
            .. (C_NamePlate[fn] and "yes" or "|cffff4040MISSING|r"))
    end
    debugPrint("size api: " .. table.concat(parts, " "))

    if lastSizeReport then
        local r = {}
        for _, c in ipairs(lastSizeReport.calls) do
            if c.missing then
                -- already covered by the api line above
            elseif c.ok then
                table.insert(r, c.name:gsub("SetNamePlate", "") .. " ok")
            else
                table.insert(r, "|cffff4040" .. c.name:gsub("SetNamePlate", "") .. " ERR: "
                    .. tostring(c.err) .. "|r")
            end
        end
        debugPrint(("last apply (%d x %d): %s"):format(lastSizeReport.w, lastSizeReport.h,
            #r > 0 and table.concat(r, ", ") or "nothing to call"))
    else
        debugPrint("|cffff4040applyPlateSizes has never run|r — it bails in combat and on a disabled module.")
    end

    if lastInsetReport and #lastInsetReport > 0 then
        local r = {}
        for _, c in ipairs(lastInsetReport) do
            table.insert(r, c.missing and ("|cffff4040" .. c.name .. " no such type|r")
                or (c.ok and (c.name .. " ok")
                or ("|cffff4040" .. c.name .. " ERR: " .. tostring(c.err) .. "|r")))
        end
        debugPrint("insets zeroed: " .. table.concat(r, ", "))
    else
        debugPrint("|cffff4040no inset API was called|r — nothing is stopping the client cropping the hit area.")
    end

    -- Listed rather than probed by name: this is the generation that replaced the
    -- one that vanished, so read what it offers off the client instead of guessing.
    debugPrint("driver: UpdateNamePlateOptions="
        .. ((NamePlateDriverFrame and NamePlateDriverFrame.UpdateNamePlateOptions) and "yes" or "MISSING")
        .. " UpdateInsetsForType="
        .. ((NamePlateDriverFrame and NamePlateDriverFrame.UpdateInsetsForType) and "yes" or "MISSING")
        .. " hooked=" .. tostring(sizeHookInstalled))

    if C_NamePlateManager then
        local fns = {}
        for k, v in pairs(C_NamePlateManager) do
            if type(v) == "function" then table.insert(fns, k) end
        end
        table.sort(fns)
        debugPrint("C_NamePlateManager: " .. (#fns > 0 and table.concat(fns, " ") or "no functions"))
    end
    if Enum and Enum.NamePlateType then
        local kinds = {}
        for k, v in pairs(Enum.NamePlateType) do table.insert(kinds, k .. "=" .. tostring(v)) end
        table.sort(kinds)
        debugPrint("Enum.NamePlateType: " .. table.concat(kinds, " "))
    end

    -- Only the ones this client actually has: the old NamePlate*Scale names are
    -- gone here, and a wall of "n/a" hides the ones that do mean something.
    local cv = {}
    for _, name in ipairs({ "NamePlateHorizontalScale", "NamePlateVerticalScale",
                            "nameplateGlobalScale", "nameplateLargerScale",
                            "nameplateMinScale", "nameplateMaxScale",
                            "nameplateSelectedScale", "nameplateMotion",
                            "nameplateSelectedAlpha", "nameplateNotSelectedAlpha",
                            "nameplateMinAlpha", "nameplateMaxAlpha" }) do
        local s = cvarStr(name)
        if not s:find("=n/a", 1, true) then table.insert(cv, s) end
    end
    debugPrint("cvars: " .. (#cv > 0 and table.concat(cv, " ") or "none of the expected names exist"))

    -- GetNamePlates only returns what's on screen, which is the honest sample:
    -- pooled plates are resized as they're shown.
    local list = C_NamePlate.GetNamePlates() or {}
    if #list == 0 then
        debugPrint("No nameplates on screen — get something in view and run this again.")
        return
    end
    -- pcall'd per plate: this reads values straight off the client, and one that
    -- turns out not to be a plain number takes the whole dump down with it (see
    -- safeNumber). Reporting the error beats printing nothing.
    for i, base in ipairs(list) do
        local ok, err = pcall(dumpPlate, i, base, w, h)
        if not ok then
            debugPrint(("|cffff4040plate %d: dump failed|r — %s"):format(i, tostring(err)))
        end
    end
end

-- The default (HIT_INSET_EXPAND) is what makes the whole plate clickable, and
-- it's a swamp-it value rather than a measured one because the client won't say
-- how much it crops. This stays so a client clamping differently can be dialled
-- in live rather than needing a rebuild.
local function setHitInset(raw)
    local n = tonumber(raw)
    if not n then
        debugPrint(("hit inset is %d (default %d). Usage: /denp inset <number> — negative expands the hit area, positive crops it.")
            :format(hitInset, HIT_INSET_EXPAND))
        return
    end
    if InCombatLockdown() then
        debugPrint("|cffff4040In combat|r — the client refuses inset writes.")
        return
    end

    hitInset = n
    clearClickInsets()

    local applied = {}
    for _, c in ipairs(lastInsetReport or {}) do
        table.insert(applied, c.name .. (c.ok and " ok" or " FAILED"))
    end
    debugPrint(("hit inset set to %d on all four sides: %s"):format(n, table.concat(applied, ", ")))
    debugPrint("Now try clicking the far left and right ends of a health bar.")
end

-- The pad is invisible, in WorldFrame's coordinate space rather than the bar's,
-- and it decides two things at once: how far off a thin bar a click still lands,
-- and — through the plate height — how far apart stacked plates sit. Printing it
-- alongside the rect it produces and the resulting stacking gap is what makes
-- those two separable.
--
-- Reads and writes general.clickPadX/Y, the same keys the settings page drives:
-- one source of truth, so dialling it in here and then opening the page doesn't
-- show two different answers.
local function showClickPad(rawX, rawY)
    local d = cfg()
    local g = d and d.general
    if not g then
        debugPrint("no profile loaded yet — try again once you're in the world.")
        return
    end

    local x, y = tonumber(rawX), tonumber(rawY)
    if x or y then
        if InCombatLockdown() then
            debugPrint("|cffff4040In combat|r — the client refuses plate geometry writes.")
            return
        end
        -- Written raw; clickPad() is what floors and clamps, so the slash command
        -- and the settings page can't disagree about what a stored value means.
        if x then g.clickPadX = x end
        if y then g.clickPadY = y end
        applyPlateSizes()
    end

    local padX, padY = clickPad(g)
    debugPrint(("click pad is |cffffff00%d|r x |cffffff00%d|r (default %d x %d)")
        :format(padX, padY, CLICK_PAD_X_DEFAULT, CLICK_PAD_Y_DEFAULT))

    local w, h, barW, barH = computePlateSize()
    if w then
        debugPrint(("widest bar %.1f x %.1f  ->  plate rect %d x %d"):format(barW, barH, w, h))

        if g.stacking then
            local overlap = (tonumber(g.overlapV) or 110) / 100
            debugPrint(("stacking: %d x %.0f%% vertical spacing = |cffffff00%.1f|r apart, of which %d is pad and %.1f is bar")
                :format(h, overlap * 100, h * overlap, padY, barH))
        else
            debugPrint("stacking is off, so the height only sets the click box.")
        end
    else
        debugPrint("no plate size to report — the module is off, or no unit type has a width.")
    end

    debugPrint("Usage: /denp clickpad <x> <y> — saved to the profile, same as General > Engine > Click box padding. Lower Y stacks plates tighter; too low and clicks just off a thin bar stop landing.")
end

-- The decisive test the dump alone can't do: measure, re-apply, measure again.
-- If the rect doesn't move, the setters aren't being honoured on this client. If
-- it moves and then drifts back, something is overwriting us afterwards.
local function testApply()
    if InCombatLockdown() then
        debugPrint("|cffff4040In combat|r — the client refuses plate geometry writes, so this would prove nothing.")
        return
    end

    local list = C_NamePlate.GetNamePlates() or {}
    if #list == 0 then
        debugPrint("No nameplates on screen — get something in view and run this again.")
        return
    end

    -- Probed once up front rather than per plate: they're all the same kind of
    -- frame, so if one refuses to be measured they all will, and the whole point
    -- of this command is the before/after comparison. Better to say it can't be
    -- done than to print a confident 0 x 0 -> 0 x 0.
    if not safeSize(list[1]) then
        debugPrint("this client won't let an addon measure a base plate (restricted region), so before/after can't be compared. |cffdddddd/denp clickpad|r still shows the size being ASKED for — whether it landed can't be read back.")
        return
    end

    local before = {}
    for i, base in ipairs(list) do
        local bw, bh = safeSize(base)
        before[i] = { bw or 0, bh or 0 }
    end

    applyPlateSizes()

    local w, h = computePlateSize()
    for i, base in ipairs(list) do
        local aw, ah = safeSize(base)
        aw, ah = aw or 0, ah or 0
        local moved    = math.abs(aw - before[i][1]) > 0.5 or math.abs(ah - before[i][2]) > 0.5
        local atTarget = math.abs(aw - (w or 0)) <= 0.5 and math.abs(ah - (h or 0)) <= 0.5

        -- "Unchanged" alone means nothing: a plate already the right size is supposed to
        -- stay put. Only unchanged AND wrong is a failure — the distinction the first
        -- version of this got backwards.
        local verdict
        if atTarget then
            verdict = moved and "|cff40ff40landed|r" or "|cff40ff40already correct|r"
        elseif moved then
            verdict = "|cffff4040moved, but not to what we asked for|r"
        else
            verdict = "|cffff4040unchanged and wrong — the setters did nothing|r"
        end

        debugPrint(("|cffffff00%d|r %s: %.1f x %.1f -> %.1f x %.1f  %s")
            :format(i, plateUnit(base), before[i][1], before[i][2], aw, ah, verdict))
    end
    debugPrint("Run this again in a few seconds: if it drifts back, something re-sizes plates after us.")
end

-- Guarded: a module folder updated ahead of core would otherwise error at load
-- over a listing, which is the least important thing this file does.
if addon.RegisterSlash then
    addon.RegisterSlash("Nameplates", {
        { "/denp help",             "this list (also /drievnameplates)" },
        { "/denp click",            "outline the hit area on every nameplate" },
        { "/denp dump",             "print the click box measurements and API surface" },
        { "/denp apply",            "re-apply the plate size and report whether it moved" },
        { "/denp inset <n>",        "set the hit-test inset live (negative expands)" },
        { "/denp clickpad [x] [y]", "show or set the click padding around the bar, and what it does to stacking" },
        { "/denp padbox [secs]",    "shade that padding on every nameplate on screen for 10 seconds" },
    })
end

SLASH_DRIEVNAMEPLATES1 = "/denp"
SLASH_DRIEVNAMEPLATES2 = "/drievnameplates"
SlashCmdList["DRIEVNAMEPLATES"] = function(msg)
    local raw = strtrim(msg or "")
    local cmd, arg = raw:match("^(%S*)%s*(.-)$")
    cmd = strlower(cmd or "")
    if cmd == "inset" then
        setHitInset(arg)
    elseif cmd == "clickpad" or cmd == "pad" then
        -- Both optional and independent: "/denp clickpad" reports, and a lone
        -- number sets X only, which is the shape `inset` already taught.
        local x, y = arg:match("^(%S*)%s*(%S*)")
        showClickPad(x, y)
    elseif cmd == "padbox" or cmd == "showpad" then
        local secs = NP.ShowClickPadArea(arg)
        debugPrint(("Click pad shaded on every plate for %.0f seconds — cyan is the padding, the clear gap inside it is the bar. The top and bottom bands are what stacking measures.")
            :format(secs))
    elseif cmd == "click" or cmd == "clickbox" then
        setClickDebug(not clickDebugShown)
        debugPrint(clickDebugShown
            and "Overlay ON. The outline is the hit area as the client reports it, falling back to the raw plate rect when the insets can't be read — so where clicks actually land falling short of the outline is itself the finding. Yellow means the client agrees you're on that unit: drag the cursor in from outside and the edge where it turns yellow is the real one, wherever the outline is."
            or  "Overlay off.")
    elseif cmd == "dump" then
        dumpClickArea()
    elseif cmd == "apply" then
        testApply()
    else
        debugPrint("/denp click            : outline the hit area on every nameplate")
        debugPrint("/denp dump             : print the click box measurements and API surface")
        debugPrint("/denp apply            : re-apply the plate size and report whether it moved")
        debugPrint("/denp inset <n>        : set the hit-test inset live (negative expands)")
        debugPrint("/denp clickpad [x] [y] : show or set the click padding around the bar, and what it does to stacking")
        debugPrint("/denp padbox [secs]    : shade that padding on every nameplate on screen for 10 seconds")
    end
end
