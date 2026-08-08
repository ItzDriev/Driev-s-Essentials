-- Driev's Essentials — Nameplates module: the engine.
--
-- Takes over nameplate handling the way Plater does: Blizzard's own plate frame
-- is hidden and a frame of ours is parented to the same base plate, so the base
-- keeps doing the (secure, protected) job of positioning and click-targeting
-- while everything drawn on it is ours — health bar, cast bar, name, level,
-- threat colouring and per-NPC colours/renames.
--
-- `...` would hand us this addon's OWN private table, so reach for core's shared
-- namespace instead — the .toc's ## Dependencies guarantees core has loaded.
local addon = _G.DrievEssentials
if not addon then return end

local Data = addon.NameplatesData
if not Data then return end

local NP = {}
addon.Nameplates = NP

local LSM   = LibStub and LibStub("LibSharedMedia-3.0", true)
local WHITE = "Interface\\Buttons\\WHITE8x8"

local function cfg()
    return addon.db and addon.db.settings and addon.db.settings.nameplates
end

local function isEnabled()
    local d = cfg()
    return (d and d.enabled == true) and true or false
end

-- ── Shared media ─────────────────────────────────────────────────────────────
-- Every texture/font goes through LibSharedMedia (bundled by core), with a
-- hardcoded Blizzard fallback for the case where the named media has since been
-- uninstalled — Fetch's noDefault flag returns nil there rather than silently
-- swapping in something unrelated.
local function barTexture(name)
    return (LSM and name and LSM:Fetch("statusbar", name, true))
        or "Interface\\TargetingFrame\\UI-StatusBar"
end

local function fontPath(name)
    return (LSM and name and LSM:Fetch("font", name, true)) or "Fonts\\FRIZQT__.TTF"
end

local function outlineFlag(name)
    if name == "OUTLINE" or name == "THICKOUTLINE" then return name end
    return ""
end

-- Per-element font override, falling back to the shared one. The flag is what
-- decides, not whether a font has been picked: unticking the box has to go back
-- to the general font, and it would otherwise silently keep using whatever the
-- picker was last left on.
local function elementFont(g, key)
    if g[key .. "Enabled"] and g[key] then return fontPath(g[key]) end
    return fontPath(g.font)
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

-- Which settings group a unit belongs to. Friendly units deliberately reuse the
-- matching enemy group's layout: Classic Era hides friendly plates by default,
-- so rather than ship two more near-identical tabs nobody opens, friendly plates
-- borrow the geometry and get a friendly reaction colour.
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
-- Blizzard re-shows plate.UnitFrame whenever it reassigns a unit to the plate,
-- so a one-off Hide() doesn't hold. The OnShow hook is installed once per plate
-- and gated on a flag, which is also what lets the module be switched back off
-- without a /reload.
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
-- A backdrop's edgeFile is ONE tiled art file: its four sides and four corners
-- are each laid out at the frame's effective scale and each round to physical
-- pixels independently. Nameplates are scaled — by the camera, and by this
-- module's own global/group/target scale settings — so that rounding lands
-- differently per side and the ring visibly wobbles in thickness, thicker on one
-- edge than another (and doubled where corner art overlaps side art).
--
-- Four explicit flat textures, each snapped to a whole number of screen pixels,
-- can't do that. This is what Plater's NamePlateBorderTemplate does under the
-- hood (PixelUtil inside its UpdateSizes), and what the border code in
-- ClassicNameplatesPlus does too.
--
-- PixelUtil is absent on older clients, hence the passthrough fallbacks — those
-- get the old behaviour rather than an error.
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

-- Edges sit OUTSIDE `target`, pushed a further `inset` out so rings can be
-- stacked (the health bar's own outline, then the target ring just beyond it)
-- without either needing to know the other's thickness.
--
-- All four sides are snapped with the same size against the same effective
-- scale, so they round to the same pixel count — that identical rounding is what
-- makes the ring even. `size` doubles as the minimum-pixel floor, matching what
-- Plater's border passes, so a scaled-down plate can't round its border away to
-- nothing (or to one pixel on two sides and two on the others).
--
-- CORNERS: only the two side strips are measured against `target`. Top and
-- bottom then span between the sides' own outer edges, anchored straight to them
-- with no offset of their own, so the corners close by construction. Reaching
-- the corners with arithmetic instead does not work: that needs `size + inset`
-- snapped as one value on the horizontal strips while the vertical ones get
-- there as `inset` snapped plus `size` snapped separately, and
-- Round(size + inset) ~= Round(inset) + Round(size). The pixel of disagreement
-- is invisible on a thick border and is the entire corner on a 1px one.
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
-- [unit GUID] = our frame. The combat log identifies units by GUID and nothing
-- else, so an aura event has no way back to a plate without this; walking
-- `active` per event would be up to forty comparisons a time in a raid.
local byGUID = {}

-- ── Aura rows ────────────────────────────────────────────────────────────────
-- One row per aura kind (buffs, debuffs). The row owns no art of its own: it is
-- a container sized to exactly fit however many icons are showing, and the
-- growth setting decides which of its edges gets pinned to the health bar.
-- Sizing it to fit is what makes "centred" free — anchor its CENTRE and the
-- strip stays centred however many icons come and go.
local function createAuraRow(f)
    local row = CreateFrame("Frame", nil, f)
    row:SetSize(1, 1)
    row.icons = {}
    row.shown = 0
    row:Hide()
    return row
end

-- Icons are built on demand and then pooled on the row. A plate is recycled
-- between units, so the mob that turns up wearing eight tracked debuffs must
-- never cost eight frames mid-pull more than once.
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
    -- The swipe is the point; its own countdown numbers are not. This module
    -- draws the timer itself so it can follow the font settings — and so OmniCC
    -- and friends don't stack a second number on top of ours.
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

-- Every piece of a plate carries an EXPLICIT frame level, so raising the
-- target's plate above its neighbours has to move the whole stack: bumping only
-- `f` would leave its health bar sitting at the old absolute level (and
-- therefore underneath the very frames we were trying to clear).
local function setPlateLevel(f, level)
    f:SetFrameLevel(level)
    f.health:SetFrameLevel(level + 1)
    f.deco:SetFrameLevel(level + 2)
    f.overlay:SetFrameLevel(level + 3)
    f.cast:SetFrameLevel(level + 1)
    f.castOverlay:SetFrameLevel(level + 3)
    -- Child frame levels are absolute, not inherited, so re-levelling the plate
    -- has to walk the pooled aura icons too — otherwise the target's raised
    -- plate leaves its own aura strip behind at the old depth, underneath its
    -- neighbours' bars.
    if f.auraRows then
        for _, row in pairs(f.auraRows) do
            row:SetFrameLevel(level + 4)
            for _, b in ipairs(row.icons) do
                b:SetFrameLevel(level + 5)
                b.cd:SetFrameLevel(level + 6)
                b.textLayer:SetFrameLevel(level + 7)
            end
        end
    end
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

    -- Mouseover highlight. ARTWORK sub-layer 3 puts it over the status bar's own
    -- fill (which sits at ARTWORK 0) but still under the overlay frame's text,
    -- so the name and health numbers stay readable through it. ADD blend
    -- lightens whatever colour the bar happens to be rather than washing it to
    -- grey, which is what makes it read the same on a red bar and a green one.
    local hover = health:CreateTexture(nil, "ARTWORK", nil, 3)
    hover:SetAllPoints(health)
    hover:SetTexture(WHITE)
    hover:SetBlendMode("ADD")
    hover:SetVertexColor(1, 1, 1)
    hover:Hide()
    f.hover = hover

    -- Every border lives here rather than on the plate itself. `f` gets scaled —
    -- by the global/group settings and by the target multiplier — and a border
    -- parented to it would grow and shrink with the bar, so targeting something
    -- would visibly fatten its outline. This frame is counter-scaled to exactly
    -- undo whatever scale `f` is carrying (see updateStyle), which leaves its
    -- effective scale pinned to the base nameplate's no matter what `f` does. Its
    -- children anchor straight to the health/cast bars, which resolves in screen
    -- space across the scale difference, so the ring still hugs the bar exactly.
    --
    -- Still a child of `f`, so it inherits alpha and shown state for free.
    local deco = CreateFrame("Frame", nil, f)
    deco:SetPoint("CENTER", f, "CENTER", 0, 0)
    deco:SetSize(1, 1)
    f.deco = deco

    -- Health outline (sub-layer 5) and the target ring just outside it (6).
    f.border = createBorder(deco, 5)

    -- Text lives on its own frame above the bar: FontStrings drawn directly on
    -- `f` would sit UNDER the health bar's textures, since the bar is a child
    -- frame at a higher level.
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

    -- Target highlight: a second ring immediately outside the health bar's own
    -- outline, so it reads as an outline rather than tinting the bar itself.
    f.glow = createBorder(deco, 6)
    setBorderShown(f.glow, false)

    -- Icons hung off the bar. Sub-layer 6 puts them over the name and health
    -- text, which is deliberate: an icon parked on top of the numbers should
    -- cover them rather than be half-swallowed by them. Both are built here and
    -- merely hidden when unused — this frame is pooled across units, so a plate
    -- picking up a marked mob must never have to create anything.
    f.raidIcon = overlay:CreateTexture(nil, "OVERLAY", nil, 6)
    f.raidIcon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
    f.raidIcon:Hide()

    f.questIcon = overlay:CreateTexture(nil, "OVERLAY", nil, 6)
    -- Standard icon-art crop: these are 64x64 icons with a border baked in that
    -- everything else in the game trims off the same way.
    f.questIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.questIcon:Hide()

    -- Target indicator ornament. Six textures are built either way: a preset
    -- draws EITHER its four corners OR its two sides, and the unused set is just
    -- hidden — switching preset must never mean rebuilding frames. Sub-level 7
    -- puts them above the name and health text sharing this overlay.
    f.indCorners, f.indSides = {}, {}
    for i = 1, 4 do
        local t = overlay:CreateTexture(nil, "OVERLAY", nil, 7)
        t:Hide()
        f.indCorners[i] = t
    end
    for i = 1, 2 do
        local t = overlay:CreateTexture(nil, "OVERLAY", nil, 7)
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
    -- Built empty (no icons yet) and anchored per-update, since both the anchor
    -- point and the strip's width depend on how many auras are showing.
    f.auraRows = {
        buffs   = createAuraRow(f),
        debuffs = createAuraRow(f),
    }

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

-- Lays out and colours all three rings — health outline, target ring, cast bar
-- outline — from current settings. Split out of updateStyle because the pixel
-- snapping inside layoutBorder resolves against the plate's effective scale AT
-- CALL TIME: when the game rescales a nameplate (camera distance, or our own
-- target-scale multiplier) the snapped sizes go stale, and this is what re-runs
-- them. `f.borderScale` records what they were last snapped against.
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

    -- The target ring is pushed out by the health outline's own thickness, so
    -- the two sit flush as an inner black / outer white pair rather than
    -- overlapping into one smeared band.
    local hs = math.max(1, math.floor((tonumber(tgt.highlightSize) or 2) + 0.5))
    local hr, hg, hb = rgb(tgt.highlightColor, 1, 1, 1)
    layoutBorder(f.glow, f.health, hs, bs)
    paintBorder(f.glow, hr, hg, hb, 1)

    -- Tracked on `deco`, which is the frame the snapping actually resolved
    -- against. Reading it off `f` would see the target-scale animation ticking
    -- and pointlessly re-snap every frame of it.
    f.borderScale = f.deco:GetEffectiveScale()
end

-- Showing or hiding the cast bar has to take its outline with it. Those textures
-- used to be parented to the cast bar, so hiding it hid them; they're on `deco`
-- now, which is always shown, and without this the cast bar's border was left
-- floating as a black rectangle under the plate between casts.
local function showCast(f, shown)
    shown = shown and true or false
    f.cast:SetShown(shown)
    setBorderShown(f.castBorder, shown and f.borderOn)
end

-- Applies a plate scale, counter-scaling the border frame so outlines keep the
-- same on-screen thickness whatever the plate is doing. `f.decoScale` is the
-- effective scale the borders should end up at (the interface scale — see
-- uiScale in updateStyle), so the counter-scale lands there instead of on 1.
local function setPlateScale(f, scale)
    if not (scale and scale > 0) then scale = 1 end
    f.curScale = scale
    f:SetScale(scale)
    f.deco:SetScale((f.decoScale or 1) / scale)
end

-- Anchored by the icon's CENTRE to a point on the bar, not edge-to-edge: it
-- makes "LEFT, x = -10" mean "ten out from the left edge" regardless of how big
-- the icon is, so changing the size doesn't silently move it as well.
--
-- Up here with the layout code rather than down with the icon updates, because
-- updateStyle is what places them and it runs long before that section.
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

-- The placement a plate is actually using, which is not always the one that was
-- picked. A name-only plate has no bar on screen, so there is no left or right
-- edge for the name to sit against — an edge placement leaves it hanging off the
-- side of a rect nobody can see, reading as misaligned rather than deliberate.
-- Those centre instead, whatever the setting says.
--
-- Shared by the anchoring in updateStyle and the width in updateName so the two
-- can't disagree about where the name is.
local function namePlacementFor(f, grp)
    if f.nameOnly then return Data.NamePlacement("innerCenter") end
    return Data.NamePlacement(grp.namePlacement)
end

-- ── Styling (geometry, media, fonts) ─────────────────────────────────────────
-- Re-derived wholesale from settings rather than patched incrementally, so a
-- settings change and a fresh plate go down exactly the same path.
local function updateStyle(f)
    local d = cfg()
    if not (d and f.unit) then return end
    local g   = d.general
    local tgt = d.target or {}
    local grp = f.group

    -- Name-only mode: a player you can't attack has no health worth watching and
    -- no cast worth interrupting, so the bar is stripped and just the name is
    -- left floating. Recomputed here rather than cached at attach because
    -- flagging for PvP changes the answer mid-session — UNIT_FACTION re-runs the
    -- whole attach, which lands back here.
    local nameOnly = grp.nameOnlyWhenSafe and UnitIsPlayer(f.unit)
        and not UnitCanAttack("player", f.unit) and true or false
    f.nameOnly = nameOnly
    local fp  = fontPath(g.font)
    local fl  = outlineFlag(g.fontOutline)

    local w = (tonumber(grp.width)  or 124)
    local h = (tonumber(grp.height) or 12)
    f:SetSize(w, h)

    -- Nameplate base frames hang off WorldFrame, not UIParent, so by default
    -- nothing on them is touched by the interface scale. Folding UIParent's
    -- effective scale in puts the whole plate in the same coordinate space as
    -- the rest of the UI, which is what Plater does — plates follow the UI Scale
    -- slider, and one border unit becomes one physical pixel at a pixel-perfect
    -- UI scale. That last part is why the border steppers were unusable before:
    -- at WorldFrame's scale of 1, one UI unit is ~1.9 physical pixels on a 1440p
    -- screen, so borders could only ever snap to 2px, 4px, 6px — every value in
    -- between was unreachable no matter what number you typed.
    local ui = uiScale()
    local scale = ui * pct(g.scale, 100) * pct(grp.scale, 100)
    if f.isTarget and tgt.enabled then scale = scale * pct(tgt.scale, 115) end
    if scale <= 0 then scale = 1 end
    f.decoScale = ui

    -- Only the goal is set here; the driver eases the plate towards it (see
    -- SCALE_RATE). Snapping straight to the new value is what made targeting
    -- something jump instead of grow — and up close, where the plate is already
    -- large, that jump is the most obvious. `curScale` is nil for a plate that
    -- has just picked up a new unit (clearUnit wipes it), and that case DOES
    -- snap: a plate should appear at its size, not animate in from the last
    -- occupant's.
    f.targetScale = scale
    if not f.curScale then setPlateScale(f, scale) end

    f.health:SetStatusBarTexture(barTexture(g.texture))
    local br, bg_, bb = rgb(g.bgColor, 0.08, 0.08, 0.10)
    f.healthBG:SetVertexColor(br, bg_, bb, pct(g.bgAlpha, 80))

    f.hover:SetAlpha(pct(g.hoverAlpha, 25))
    if g.hoverHighlight == false then
        f.hover:Hide()
    end
    -- Cleared, not set: whether the cursor is actually over this plate is the
    -- OnUpdate hover check's business, and a stale cached answer from the plate's
    -- previous occupant would stop it noticing the change.
    f.hovered = nil

    local nameSize = tonumber(grp.nameSize) or tonumber(g.fontSize) or 10
    f.name:SetFont(elementFont(g, "nameFont"), nameSize, fl)
    f.name:SetShown(grp.showName ~= false)

    -- Re-anchored from scratch: the placements use different anchor points, and
    -- switching between them has to drop the old one rather than stack on it.
    -- Anchored against the health bar rather than `f` so the inner placements
    -- land on the bar itself — the two have the same rect today, but only the
    -- bar is guaranteed to.
    local place = namePlacementFor(f, grp)
    f.name:ClearAllPoints()
    f.name:SetPoint(place.point, f.health, place.rel,
        place.dx + (tonumber(grp.nameX) or 0),
        place.dy + (tonumber(grp.nameY) or 0))
    f.name:SetJustifyH(place.justify)
    f.level:SetFont(elementFont(g, "levelFont"), nameSize, fl)
    f.level:SetShown(not nameOnly and grp.showLevel ~= false)
    f.healthText:SetFont(elementFont(g, "healthFont"), tonumber(g.fontSize) or 10, fl)
    f.healthText:SetShown(not nameOnly and grp.showHealthText ~= false and grp.healthFormat ~= "none")

    -- The bar carries its background, fill and hover highlight as children, so
    -- one call takes the lot. It keeps its geometry while hidden, which is what
    -- lets the name stay anchored to it and land where it always did.
    f.health:SetShown(not nameOnly)

    -- Re-anchored from scratch every time: the anchor point is one of three and
    -- switching between them has to drop the previous one, not stack on it.
    -- The 2px inset on the edge anchors keeps the text off the bar's own
    -- outline; centre needs no such nudge, which is why it isn't applied there.
    local hAnchor = grp.healthTextAnchor or "RIGHT"
    if hAnchor ~= "LEFT" and hAnchor ~= "CENTER" then hAnchor = "RIGHT" end
    local hEdge = (hAnchor == "LEFT" and 2) or (hAnchor == "RIGHT" and -2) or 0
    f.healthText:ClearAllPoints()
    f.healthText:SetPoint(hAnchor, f.health, hAnchor,
        hEdge + (tonumber(grp.healthTextX) or 0), tonumber(grp.healthTextY) or 0)
    f.healthText:SetJustifyH(hAnchor)

    layoutIcon(f.raidIcon,  f.health, iconOpts(d, "raidMarker"))
    layoutIcon(f.questIcon, f.health, iconOpts(d, "quest"))

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
    f.castName:SetFont(fp, math.max(6, ch - 2), fl)
    f.castName:SetShown(grp.castShowName ~= false)
    f.castTime:SetFont(fp, math.max(6, ch - 2), fl)
    f.castTime:SetShown(grp.castShowTimer ~= false)

    -- Last: the rings anchor to the health and cast bars, and their pixel
    -- snapping resolves against the scale set above, so both have to be final.
    layoutPlateBorders(f)
end

-- ── Colouring ────────────────────────────────────────────────────────────────
-- Whether the mob is currently swinging at a raid member flagged Main Tank.
--
-- Read off the mob's own target rather than by walking the raid and comparing
-- threat: the client won't give a DPS everyone else's threat numbers, but who
-- the mob is hitting is right there. Assignments only exist in a raid, so this
-- is false for the whole of solo and party play and the colour never appears
-- where it would be meaningless.
local function mainTankHasAggro(unit)
    if not GetPartyAssignment then return false end
    local target = unit .. "target"
    if not UnitExists(target) then return false end
    -- Your own aggro is the caller's business and has already been handled;
    -- being the main tank yourself must not paint your own pulls as safe.
    if UnitIsUnit(target, "player") then return false end
    return GetPartyAssignment("MAINTANK", target) and true or false
end

-- Returns (colour, alarm, warning). A nil colour means threat colouring doesn't
-- apply to this unit at all.
--
-- The two flags are the threat state sorted into tiers, which is what the NPC
-- colour overrides key off:
--
--   alarm   — the thing you must not miss: DPS/healer with aggro on you, or a
--             tank who has lost it entirely.
--   warning — the tier below: DPS/healer climbing the list, or a tank losing
--             grip on it.
--
-- Both modes map onto the same two tiers deliberately. They used to be reported
-- for DPS/healer mode only, which meant that in tank mode — with the default
-- "only once I've actually pulled threat" ticked — threat could never take over
-- a custom NPC colour at all, whatever was happening.
local function threatColor(d, unit)
    local t = d.threat
    if not (t and t.enabled) then return nil, false, false end
    if not UnitCanAttack("player", unit) then return nil, false, false end
    -- Players have no threat table, and the "is it hitting me?" fallback below
    -- would paint every enemy player permanently red. They keep their class or
    -- reaction colour instead.
    if UnitIsPlayer(unit) then return nil, false, false end
    if t.combatOnly and not UnitAffectingCombat(unit) then return nil, false, false end

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

    -- Off you, and parked on the person whose job it is. That is a different
    -- kind of fine from "off you and nobody knows where it went", and worth
    -- saying: it's the difference between a pull going to plan and one that
    -- isn't. Checked last, so nothing about your own threat is ever hidden by
    -- someone else's.
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
        -- Both apply. The NPC colour is the user's own deliberate tag, so it
        -- wins by default; threat only takes it over when they've asked it to,
        -- and (with overrideOnlyOnAggro) only once the threat state is worth
        -- shouting about. overrideOnGaining widens that from "it has turned on
        -- me" to "it's about to", which is the point at which there's still
        -- something to be done about it.
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

-- The client returns -1 for a unit whose level it won't state — the skull — and
-- it does that once the unit is more than this many levels above the player.
-- So the lowest the unit can actually be is the first level past the cut-off,
-- which is what gets shown, with a "+" to say it's a floor and not the number.
--
-- The gap is the game's, not ours, and nothing exposes it: it's the long-
-- standing 10. If skulls ever read one off, this is the line to change.
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

    if grp.showName ~= false then
        local name = Data.GetNpcName(f.npcID) or UnitName(unit) or ""
        local limit = tonumber(grp.truncateName) or 0
        if limit > 0 and #name > limit then name = name:sub(1, limit) .. ".." end
        f.name:SetText(name)

        -- How much room the name gets depends on where it is. Sharing the strip
        -- above the bar with the level text means leaving room for it; on the
        -- bar it's bounded by the bar, inset so it isn't flush to the outline;
        -- below the bar it has the whole width to itself.
        local place = namePlacementFor(f, grp)
        local reserve = 0
        if place.row == "above" and grp.showLevel ~= false then
            reserve = 28
        elseif place.row == "inner" then
            reserve = 6
        end
        f.name:SetWidth(math.max(10, (f:GetWidth() or 0) - reserve))

        local cc = grp.classColorName and UnitIsPlayer(unit) and classColorFor(unit)
        if cc then
            f.name:SetTextColor(cc[1], cc[2], cc[3])
        else
            f.name:SetTextColor(1, 1, 1)
        end
    end

    if grp.showLevel ~= false then
        local level = UnitLevel(unit)
        f.level:SetText(levelText(unit))
        local c = (level and level > 0) and GetQuestDifficultyColor
            and GetQuestDifficultyColor(level) or nil
        if c then f.level:SetTextColor(c.r, c.g, c.b) else f.level:SetTextColor(0.9, 0.9, 0.9) end
    end
end

-- ── Icons ────────────────────────────────────────────────────────────────────
-- The eight raid markers are one 4x2 sheet, indexed left to right, top row
-- first — the same layout SetRaidTargetIconTexture walks, done here so the
-- coords are visible next to everything else that crops art in this file.
local function raidCoords(index)
    local i = index - 1
    local l = (i % 4) * 0.25
    local t = math.floor(i / 4) * 0.25
    return l, l + 0.25, t, t + 0.25
end

local function updateRaidIcon(f)
    local opt = iconOpts(cfg(), "raidMarker")
    local index = (opt and opt.enabled ~= false and f.unit)
        and GetRaidTargetIndex and GetRaidTargetIndex(f.unit) or nil
    if not index then
        f.raidIcon:Hide()
        return
    end
    f.raidIcon:SetTexCoord(raidCoords(index))
    f.raidIcon:Show()
end

-- ── Aura tracking ────────────────────────────────────────────────────────────
-- Two whitelisted strips of icons above the health bar. Whitelisted rather than
-- filtered: a nameplate has room for a handful of icons, so the question is
-- never "which of these forty do I hide" but "which two do I actually watch".
--
-- Driven by UNIT_AURA rather than polled — a raid pull fires that event dozens
-- of times a second across every plate on screen, so it only marks the plate
-- dirty and the poll tick does the scan at most once per 0.1s per plate.
local AURA_FILTER   = { buffs = "HELPFUL", debuffs = "HARMFUL" }
local AURA_KINDS    = { "buffs", "debuffs" }
-- Classic Era's aura list is capped at 40; the loop breaks on the first empty
-- slot anyway, so this is only the guard against an API that never returns nil.
local MAX_AURA_SCAN = 40
-- What an aura the client can't hand out an icon for is drawn as.
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"

-- One reader for both aura APIs. C_UnitAuras is what current builds expect;
-- UnitAura is what Classic Era still ships and what the rest of this addon
-- already uses. Returns the same flat tuple either way.
local function readAura(unit, index, filter)
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        local a = C_UnitAuras.GetAuraDataByIndex(unit, index, filter)
        if not a then return nil end
        return a.name, a.icon, a.applications, a.duration, a.expirationTime, a.spellId
    end
    if not UnitAura then return nil end
    local name, icon, count, _, duration, expires, _, _, _, spellID = UnitAura(unit, index, filter)
    if not name then return nil end
    return name, icon, count, duration, expires, spellID
end

-- Coarse at the top, precise at the bottom: the exact second only matters when
-- there are few of them left, and "1.4" where "23m" would do is unreadable at
-- nameplate size.
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

local function readAuraStyle(o, g)
    local st = auraStyle
    st.size    = math.max(4, tonumber(o.size) or 20)
    st.spacing = math.max(0, tonumber(o.spacing) or 2)
    st.max     = math.max(1, math.min(20, tonumber(o.max) or 8))
    st.growth  = Data.AuraGrowth(o.growth)
    st.step    = st.size + st.spacing

    st.font     = fontPath(g.font)
    st.outline  = outlineFlag(g.fontOutline)
    st.textSize = math.max(6, tonumber(o.timerSize) or 9)
    st.showTime = o.showTimer ~= false
    st.showQty  = o.showStacks ~= false

    st.borderSize = math.max(0, math.floor((tonumber(o.borderSize) or 1) + 0.5))
    st.br, st.bg, st.bb = rgb(o.borderColor, 0, 0, 0)

    st.x = tonumber(o.x) or 0
    st.y = tonumber(o.y) or 0
    return st
end

-- One icon, from whatever aura data the caller has: a real one off the unit, or
-- a made-up one from the preview. Shared rather than written twice precisely
-- because the preview is only worth anything if it is drawn by the same code
-- that draws the real thing — a second copy would drift and start lying.
local function drawAuraIcon(row, index, st, icon, count, duration, expires, now)
    local b = auraIcon(row, index)

    b:SetSize(st.size, st.size)
    b:ClearAllPoints()
    -- The first icon is pinned to the growth edge and the rest queue up behind
    -- it, so whichever one you look at first never moves as auras come and go.
    -- Centred is the exception by definition — there the whole strip shifts,
    -- which is what "centred" means.
    if st.growth == "left" then
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
    b.timer:SetFont(st.font, st.textSize, st.outline)
    b.timer:SetShown(b.timerOn)
    if b.timerOn then b.timer:SetText(auraTimeText(math.max(0, b.expires - now))) end

    count = tonumber(count) or 0
    b.count:SetFont(st.font, st.textSize, st.outline)
    b.count:SetShown(st.showQty and count > 1)
    if count > 1 then b.count:SetFormattedText("%d", count) end

    b:Show()
    return b
end

-- Sizes the row to exactly the icons that ended up on it and pins it to the
-- growth edge — see createAuraRow for why fitting it is what makes "centred"
-- free.
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
    row:SetSize(shown * st.size + (shown - 1) * st.spacing, st.size)
    row:ClearAllPoints()

    -- Anchored to the health bar, not to `f`: on a name-only plate the bar is
    -- hidden but still positioned, so the strip lands where it always does
    -- instead of drifting to whatever `f` happens to measure.
    if st.growth == "right" then
        row:SetPoint("BOTTOMLEFT", f.health, "TOPLEFT", st.x, st.y)
    elseif st.growth == "left" then
        row:SetPoint("BOTTOMRIGHT", f.health, "TOPRIGHT", st.x, st.y)
    else
        row:SetPoint("BOTTOM", f.health, "TOP", st.x, st.y)
    end
    row:Show()
end

-- A by-name whitelist entry has no ID and no art of its own (see
-- Data.NoteAuraSeen for why there is no way to give it either up front), so it
-- learns from the auras it matches. Only name entries: an ID entry already knows
-- the only ID it will ever match, and resolves its own icon from that.
--
-- Free in the steady state — every call after the first for a given ID is one
-- table lookup and a return — which is what lets this sit in the scan loop.
local function learnAura(entry, spellID, icon)
    if not (entry and spellID) or entry.id then return end
    if Data.NoteAuraSeen(entry, spellID, icon) and NP.onAuraLearned then
        NP.onAuraLearned()
    end
end

-- ── Learned catalogue ────────────────────────────────────────────────────────
-- Everything above only ever looks at auras somebody already asked for, which
-- leaves the chicken-and-egg the settings panel actually runs into: to whitelist
-- a debuff you have to know its name, and the way you find that out is to see
-- it. So this walks the auras a plate is wearing regardless of the whitelists
-- and writes down what it finds.
--
-- Deliberately NOT on the 0.1s tick the rest of the module runs on. A full scan
-- is forty reads per filter per plate, and a catalogue has no reason to be
-- current to a tenth of a second — three seconds a plate turns twenty thousand
-- reads a minute into a few hundred, and misses nothing that lasts longer than
-- a global cooldown.
local LEARN_INTERVAL = 3

local function learnFromPlate(f, now)
    if not f.unit then return end
    if f.learnAt and now < f.learnAt then return end
    -- Staggered, not aligned: without the jitter every plate that appeared in
    -- the same pull would come due on the same frame for the rest of the fight.
    f.learnAt = now + LEARN_INTERVAL + math.random() * 0.5

    local touched = false
    for _, which in ipairs(AURA_KINDS) do
        local filter = AURA_FILTER[which]
        for i = 1, MAX_AURA_SCAN do
            local name, icon, _, _, _, spellID = readAura(f.unit, i, filter)
            if not name then break end
            if Data.NoteLearnedAura(which, spellID, name, icon) then touched = true end
        end
    end
    if touched and NP.onAuraLearned then NP.onAuraLearned() end
end

-- ── Inferred auras ───────────────────────────────────────────────────────────
-- Classic Era will not tell you what buffs a hostile player is carrying. The
-- aura API answers for your target, your mouseover and your group, and for
-- anything else it reports nothing at all — which is why a whitelisted Battle
-- Shout never shows up on an enemy plate however it is spelled, and why the
-- whole feature reads as broken in PvP while looking fine on a boss.
--
-- What the client DOES hand over is the events. The enemy's cast arrives as
-- UNIT_SPELLCAST_SUCCEEDED against their own nameplate unit, and the combat log
-- carries SPELL_AURA_APPLIED / _REFRESH / _REMOVED for them by GUID. Neither is
-- a substitute for reading the unit — there is no duration in either, and both
-- go quiet while the unit is out of range — so what is built here is a record of
-- what was last seen to happen, and it always loses to a real aura when there
-- is one. Knowing late beats not knowing.
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

-- Without a duration to expire on, an inferred aura rides until the log says it
-- is gone. That message needs the unit to have stayed in range, so there is a
-- backstop: five minutes of never hearing otherwise and the icon is a guess too
-- old to be worth showing.
local INFER_TTL = 300
-- How often the store is walked for records nothing is looking at any more.
local INFER_SWEEP = 10

-- [destGUID] = { [lowercased spell name] = record }. Keyed on the name rather
-- than the spell ID so ranks collapse into one icon — which is what the by-name
-- whitelist entries mean, and what stops a real Battle Shout and an inferred one
-- drawing twice side by side.
local inferred = {}
local inferredGUIDs = 0
local sinceInferSweep = 0

-- Which set of whitelists a GUID answers to. The combat log deals in GUIDs and
-- nothing else — no unit token, so no UnitIsPlayer — but the GUID itself says
-- which it is: player GUIDs are the only ones that begin "Player". Hostility
-- doesn't come into it, because friendly units share the enemy block anyway.
local function unitKeyForGUID(guid)
    if type(guid) ~= "string" then return nil end
    return guid:sub(1, 6) == "Player" and "enemyPlayer" or "enemyNPC"
end

-- Whether a spell is on the whitelist for that unit type and row, and the entry
-- if it is. This is the filter that keeps the store to a handful of records:
-- almost everything the combat log shouts about is rejected here.
local function trackedEntry(unitKey, which, spellID, name)
    local lookup = Data.AuraLookup(unitKey, which)
    if lookup.count == 0 then return nil end
    return (spellID and lookup.byID[spellID])
        or (name and lookup.byName[name:lower()])
        or nil
end

-- UNIT_AURA is what normally tells a plate its icons are stale, and for the
-- units this whole block exists for that event never comes. So every change to
-- the store nudges the plate itself, or an enemy's buff would appear (and, worse,
-- linger) only when something unrelated happened to trigger a rescan.
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

local function rememberInferred(guid, which, spellID, name, icon, count)
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
    -- The combat log carries no icon, so it is resolved from the spell and kept
    -- on the record: the same aura re-applies over and over in a fight, and
    -- that lookup should not be paid every time.
    if icon then
        rec.icon = icon
    elseif not rec.icon then
        rec.icon = select(2, Data.SpellInfo(spellID or name))
    end

    -- The other place a by-name entry can be told what it matches. It reaches
    -- further than the scan does: the combat log names a spell whether or not
    -- the client would ever resolve that name for us, and whether or not the
    -- unit is one we can read auras off at all.
    learnAura(entry, spellID, rec.icon)

    count = tonumber(count) or 0
    rec.count = count > 1 and count or 1

    local dur = tonumber(entry.duration)
    rec.duration = (dur and dur > 0) and dur or nil
    rec.applied  = GetTime()
    rec.expires  = rec.applied + (rec.duration or INFER_TTL)
    -- Only a duration the user supplied earns a swipe and a countdown. Timing
    -- an aura we are guessing at from a number nobody gave us would be the one
    -- kind of wrong that looks authoritative.
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
-- back), so nothing else prunes them. Cheap when the store is empty, which is
-- the state for anyone not running this feature.
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
    local _, sub, _, _, _, _, _, destGUID, _, _, _, spellID, spellName, _, auraType, amount =
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

    -- Removal doesn't consult auraType, and mustn't: the payload isn't the same
    -- shape across these. SPELL_AURA_BROKEN_SPELL carries the breaking spell in
    -- the middle, which pushes its auraType two slots past where the others keep
    -- it — and reading the wrong slot there would silently leave the icon up.
    -- The name is in the same place in all of them, and the name is the key.
    if action == "drop" then
        forgetInferred(destGUID, spellName)
        return
    end

    local which = AURA_TYPE_ROW[auraType]
    if not which then return end

    -- Free catalogue entries: this handler has already paid to decode the event,
    -- and it reaches auras on units the plate scan can't read at all. Gated on
    -- the same switch, since it feeds the same list.
    local d = cfg()
    if d and d.auras and d.auras.enabled ~= false and d.auras.learn ~= false then
        if Data.NoteLearnedAura(which, spellID, spellName, nil) and NP.onAuraLearned then
            NP.onAuraLearned()
        end
    end

    rememberInferred(destGUID, which, spellID, spellName, nil, amount)
end

-- A cast that landed, on a unit the client is willing to name. The aura is
-- ASSUMED to be the spell itself, on its caster — true of exactly the self
-- buffs this exists for (Battle Shout, Bloodrage) and false of anything aimed
-- at someone else, which is why the whitelist gates it: nothing is recorded
-- unless you asked for that spell by name or by ID.
--
-- Kept alongside the combat log rather than replaced by it because it reaches
-- further: the log needs the caster in range of you, and this only needs their
-- nameplate to exist.
local function onCastSucceeded(unit, spellID)
    if not (unit and spellID) then return end
    if not UnitCanAttack("player", unit) then return end
    local guid = UnitGUID(unit)
    if not guid then return end
    local name, icon = Data.SpellInfo(spellID)
    if not name then return end
    rememberInferred(guid, "buffs", spellID, name, icon, nil)
end

-- Sorted before drawing so the strip doesn't reshuffle itself every scan —
-- pairs() over the bag has no order, and an icon that swaps places with its
-- neighbour twice a second is worse than no icon. Oldest first, so a newly
-- applied aura joins the end rather than shoving the others along.
local inferScratch = {}

local function collectInferred(f, which, seen, now)
    wipe(inferScratch)
    local bag = f.guid and inferred[f.guid]
    if not bag then return inferScratch end

    for key, rec in pairs(bag) do
        if now >= rec.expires then
            bag[key] = nil
        elseif rec.which == which and not seen[key] then
            inferScratch[#inferScratch + 1] = rec
        end
    end
    table.sort(inferScratch, function(a, b) return a.applied < b.applied end)
    return inferScratch
end

-- ── Preview ──────────────────────────────────────────────────────────────────
-- Switched on by the settings UI while an aura tab is open, and drawn on every
-- plate on screen. Sizing, spacing and the nudges are the settings here that
-- can't be judged from their numbers, and without this you can only judge them
-- by whitelisting something and finding a mob wearing it — which is no help at
-- all when the whitelist is empty, i.e. the state everyone starts in.
--
-- Both rows at once, on the plates of whichever unit type's tab is open. Both,
-- because the tab shows both and they stack — seeing them together is the only
-- way to judge whether the two Nudge Y values keep them clear of each other.
-- One unit type, because that's the tab you're looking at, and a preview on
-- everything else on screen would just be noise.
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

    -- Nothing whitelisted means nothing to draw, and the scan below would walk
    -- every aura on the unit to discover that. Checked first for that reason:
    -- with every list empty (the shipped state) this feature costs one table
    -- lookup per plate per tick. Nothing can have been inferred either — the
    -- store is fed through the same whitelist.
    local lookup = Data.AuraLookup(uKey, which)
    if lookup.count == 0 then
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
            shown = shown + 1
            auraSeen[key] = true
            -- The one moment a by-name entry can be told what it matches: the
            -- name that found it and the ID and art that came with it are all
            -- in hand right here, and nowhere else.
            learnAura(hit, spellID, icon)
            drawAuraIcon(row, shown, st, icon, count, duration, expires, now)
            if shown >= st.max then break end
        end
    end

    -- Then whatever the unit wouldn't own up to, filled in from the events.
    -- Strictly second: a real aura carries the true duration and stack count and
    -- an inferred one carries neither, so where both exist the real one wins and
    -- the guess is dropped on the floor.
    --
    -- Skipped entirely under "only ones I applied" — the events say who cast
    -- what, but the store doesn't keep it, and quietly showing someone else's
    -- aura under a filter that promises otherwise is worse than showing none.
    if shown < st.max and u.fromEvents and not o.onlyMine then
        for _, rec in ipairs(collectInferred(f, which, auraSeen, now)) do
            shown = shown + 1
            drawAuraIcon(row, shown, st, rec.icon, rec.count,
                rec.timed and rec.duration or 0,
                rec.timed and rec.expires  or 0, now)
            if shown >= st.max then break end
        end
    end

    finishAuraRow(f, row, shown, st)
end

local function updateAuras(f)
    if not f.auraRows then return end
    f.auraDirty = nil
    for _, which in ipairs(AURA_KINDS) do updateAuraRow(f, which) end
end

-- Ticks the timer text on whatever is already showing, without re-scanning. An
-- aura that has run out marks the plate for a rescan: UNIT_AURA normally covers
-- that, but a unit whose auras expire while the event is being missed (out of
-- range, or a plate that appeared mid-fight) would otherwise wear a dead icon.
local function advanceAuraTimers(f)
    if not f.auraRows then return end
    local now = GetTime()
    for _, row in pairs(f.auraRows) do
        for i = 1, row.shown or 0 do
            local b = row.icons[i]
            local expires = b and b.expires
            if expires then
                local left = expires - now
                if left <= 0 then
                    f.auraDirty = true
                elseif b.timerOn then
                    b.timer:SetText(auraTimeText(left))
                end
            end
        end
    end
end

-- ── Quest objectives ─────────────────────────────────────────────────────────
-- No unit API says "this mob counts towards a quest", so it comes off the unit
-- tooltip the way every quest-icon addon reads it: a line carrying an "x/y"
-- counter means this unit feeds an objective you're on.
--
-- WHICH icon needs the objective's kind, and the tooltip only has the player's
-- language — "slain" is not an enum. So the quest log classifies it instead:
-- C_QuestLog hands back a type per objective, and the objective's text there is
-- the same string the tooltip prints, minus the progress tail that ticks as you
-- play. Stripping that tail off both sides is what makes them comparable.
local QUEST_ICON = {
    monster = "Interface\\Icons\\INV_Sword_04",       -- kill it
    item    = "Interface\\Icons\\INV_Misc_Bag_08",    -- it drops something
}

local questTypes = {}          -- [stripped objective text] = "monster" | "item" | …
local questTypesStale = true

-- Same hardening that makes the nameplate inset getter unreadable: text off a
-- protected API can come back as a secret value that survives being stored and
-- then throws the moment anything matches against it. Everything read out of
-- the tooltip and the quest log goes through here, so a client that starts
-- hiding either costs this feature and nothing else.
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

-- Returns "monster", "item", another objective type, or false for "checked, and
-- this mob is not part of anything". Never nil, so callers can cache the answer
-- and still tell it apart from "not looked at yet".
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
                -- Not in the log under that wording (a locale that phrases the
                -- tooltip differently, or an objective type the log spells
                -- another way). A line naming the mob itself is something to
                -- kill; anything else is something it drops.
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

-- Re-checked on a timer rather than once on attach: a plate can appear before
-- the client has the unit's tooltip data, and accepting a quest mid-pull has to
-- light up the mobs already on screen. Two seconds is slow enough that a busy
-- pull costs a handful of tooltip reads a second, fast enough not to be noticed.
local QUEST_RESCAN = 2

local function updateQuestIcon(f, force)
    local opt = iconOpts(cfg(), "quest")
    if not (opt and opt.enabled ~= false and f.unit) then
        f.questIcon:Hide()
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
-- Keyed off the "mouseover" unit token, NOT a cursor-in-rect test on our own
-- frame. Frame:IsMouseOver() looks like the precise answer, but our frame is
-- parented to Blizzard's nameplate base — a restricted frame — and every
-- position-measurement API is blocked inside a restricted hierarchy. Calling it
-- throws "Can't measure restricted regions" and, polled every frame, spams it.
--
-- The token is the taint-free equivalent, at the cost of also going live when
-- you point at the unit's 3D model rather than its plate. That's a fair trade:
-- it still answers "what is under my cursor", which is the question the
-- highlight exists to answer.
--
-- Run every frame, not on the slow tick — a highlight trailing 100ms behind the
-- cursor reads as broken — so it does nothing unless the shown state changes.
-- `hasMouseover` is resolved once by the caller so the common "pointing at
-- nothing" case costs one call for the whole sweep instead of one per plate.
local function updateHover(f, hasMouseover)
    local hovered = (hasMouseover and f.unit and UnitIsUnit(f.unit, "mouseover")) and true or false
    if hovered == f.hovered then return end
    f.hovered = hovered
    f.hover:SetShown(hovered)
end

-- ── Target indicator ─────────────────────────────────────────────────────────
-- Anchor point, and which way this piece's x/y push it away from the bar. The
-- corner order matches the order the presets list their texture coords in.
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

    -- Re-anchoring and re-sizing art on every 10Hz tick is exactly what makes an
    -- indicator shimmer, so the layout is only redone when the look actually
    -- changed. Bar height counts as part of that: it drives the scale, and it
    -- moves whenever the size or scale settings do.
    --
    -- Showing is deliberately OUTSIDE this check: the pieces keep their layout
    -- while hidden, so a target dropped and picked back up must not be left
    -- waiting on a cache that already matches.
    local st = f.indState
    if not st then
        st = {}
        f.indState = st
    end
    if st.style ~= t.indicator or st.height ~= barH
        or st.r ~= cr or st.g ~= cg or st.b ~= cb then
        st.style, st.height = t.indicator, barH
        st.r, st.g, st.b = cr, cg, cb

        -- autoScale measures the art against the bar so it keeps its proportions
        -- at any nameplate size; a fixed `scale` pins it; otherwise the art is
        -- treated as having been drawn for a 10px bar.
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

-- "Fighting me" rather than "in combat": a mob brawling with another player
-- across the room is in combat and is exactly what the dim exists to push into
-- the background.
--
-- UnitThreatSituation answers it directly when the API is live, but Classic Era
-- returns nil for anything the player isn't on the threat table of — which is
-- indistinguishable from "no threat API at all". The fallback is the same one
-- threatColor uses, widened to the group: who is it actually swinging at.
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

-- Split out of updateTarget because the two change on different schedules: the
-- target only moves when you retarget, while whether something is fighting you
-- changes on its own, so this also runs on the poll tick.
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

    -- Multiplied in rather than replacing the target dim: a plate that is
    -- neither your target nor fighting you is the least interesting thing on
    -- screen and should read that way. Your own target is exempt however
    -- unbothered it is by you — you pointed at it on purpose.
    if g.dimInactive and not f.isTarget and not engagedWithPlayer(f.unit) then
        alpha = alpha * pct(g.inactiveAlpha, 45)
    end

    f:SetAlpha(math.max(0, math.min(1, alpha)))
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

    setPlateLevel(f, f.baseLevel + ((t.enabled and t.raise and isTarget) and 20 or 0))

    -- Target scale lives in updateStyle, so only re-run it when the flag flips.
    if wasTarget ~= isTarget then updateStyle(f) end
end

-- ── Cast bar ─────────────────────────────────────────────────────────────────
-- Polled rather than event-driven: nameplate units come and go constantly, and
-- routing eight spellcast events through a unit→plate map still misses the case
-- that matters most (a plate appearing partway through a cast). One read per
-- plate per tick covers every case with no bookkeeping.
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

    -- Everything below is the same for every tick of one cast, and this runs ten
    -- times a second per plate. Re-reading the start time is how a pushback or a
    -- second cast of the same spell is still noticed (both move it).
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
    updateRaidIcon(f)
    updateAuras(f)
    -- Forced: this is a unit the plate has not shown before, so the rescan
    -- timer's "checked recently" is about the previous occupant.
    updateQuestIcon(f, true)
end

-- ── Attach / detach ──────────────────────────────────────────────────────────
-- Base plates are recycled between units, so every field derived from the OLD
-- occupant has to be cleared here — most of all isTarget and castSeen, which
-- both gate work that would otherwise be skipped for the new one.
local function clearUnit(f)
    -- Guarded on identity: a plate handover can attach the new occupant before
    -- the old one is cleared, and an unconditional wipe would take the entry the
    -- new plate had just claimed for the same GUID.
    if f.guid and byGUID[f.guid] == f then byGUID[f.guid] = nil end
    f.guid = nil
    f.unit, f.npcID, f.kind, f.group = nil, nil, nil, nil
    f.casting, f.castSeen = nil, nil
    f.isTarget = false
    -- Both wiped, not just the answer: keeping the timestamp would let the next
    -- occupant inherit this one's "checked two seconds ago" and wear its icon
    -- until the rescan came round.
    f.questKind, f.questCheckedAt = nil, nil
    f.raidIcon:Hide()
    f.questIcon:Hide()
    -- The whole strip, not just the flag: the auras on screen belong to the unit
    -- that has just left, and leaving them up until the next scan would show the
    -- new occupant wearing the old one's debuffs.
    f.auraDirty = nil
    if f.auraRows then
        for _, row in pairs(f.auraRows) do hideAuraRow(row) end
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
-- LibGetFrame is how WeakAuras — and everything else that anchors to
-- nameplates — finds the frame to hang things off. It walks a fixed list of
-- known nameplate addons and, matching none of them, falls through to
-- Blizzard's own `UnitFrame.healthBar`. This module HIDES that bar, so an aura
-- anchored to a nameplate ends up attached to a hidden frame and is simply
-- never drawn — which looks exactly like the anchoring having failed.
--
-- Its first check is `nameplate.unitFrame.Health`. That shape isn't any one
-- addon's marker: the lib tests the identical condition twice, labelled "elvui"
-- and "bdui nameplates", so it is the closest thing to a convention there is for
-- "here is my plate, and here is its health bar".
--
-- Left alone if something else got there first. Another nameplate addon running
-- alongside this one owns the field, and for the plates IT is drawing its anchor
-- is the correct one — quietly taking the name would point auras at a bar that
-- isn't on screen, which is the very bug this exists to fix.
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

-- Records an NPC in the settings list the first time it's seen. Deliberately
-- kept OUT of attach(): a plate we don't take over (because Enemy NPC styling is
-- switched off, say) is still an NPC you've met, and mousing over or targeting
-- something whose nameplate is hidden entirely should count as well. Gated on
-- the module being enabled so switching it off leaves the game untouched.
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
    -- Deliberately does NOT re-show Blizzard's plate: the base frame is about to
    -- be recycled for another unit, and un-hiding here would make it flicker
    -- back in for a frame on every single plate handover.
    if not isEnabled() then setBlizzardShown(base, true) end
end

-- ── CVars / engine settings ──────────────────────────────────────────────────
-- SetCVar is refused while the player is in combat, so a change made mid-fight
-- is remembered and replayed on PLAYER_REGEN_ENABLED rather than lost.
local cvarsPending = false

local function setCVarSafe(name, value)
    pcall(SetCVar, name, value)
end

-- The clickable base plate is a separate frame from the bar we draw on it, and
-- it lives in WorldFrame's coordinate space — scale 1, untouched by the
-- interface scale — while the bar is drawn at the interface scale. So its size
-- can't just be the bar's width: a 190-wide bar at a 0.65 interface scale only
-- covers 124 units of base plate, and anything typed in as a flat number is in
-- the wrong units the moment either scale changes. Deriving it from what the bar
-- actually covers on screen is the only version that can't drift apart, which is
-- what left the outer part of a widened bar refusing clicks.
--
-- One size covers every plate (the API is global, not per-plate), so it's taken
-- from whichever unit type draws the widest bar. The target multiplier is
-- deliberately left out: growing EVERY plate's click box by 15% for the sake of
-- the one plate you have already clicked just makes packed plates fight over the
-- mouse.
--
-- A little slack around the bar, so clicks just off the edge of a thin bar still
-- land. Fixed rather than a setting: it was exposed as one, and with the click
-- rect being cropped by the insets below it could not visibly do anything, so
-- there was nothing to tune. These are the values that setting defaulted to.
local CLICK_PAD_X, CLICK_PAD_Y = 10, 24

local sizesPending = false

-- The plate's size is NOT the clickable area: on top of it the client applies a
-- per-type inset that crops the rect inwards, and it has to be cleared or the
-- outer part of a plate sized to our bar simply won't take clicks.
--
-- There are two generations of this and 11509 has only the newer one:
--
--   C_NamePlateManager.SetNamePlateHitTestInsets(type, l, r, t, b)
--       Current. Positive crops inwards, negative expands — Plater's
--       "click through" toggle is literally +10000 vs -10000 on these.
--
--       Zero does NOT mean "the hit area is the plate rect". Measured on 11509:
--       with the plate sized past the bar on every side and zeros passed here,
--       the outer part of the bar still refused clicks, so the client crops by
--       an amount of its own on top of whatever we pass — and it won't say how
--       much, since the getter returns secret values (see safeNumber).
--
--   C_NamePlate.SetNamePlate{Enemy,Friendly}PreferredClickInsets(l, r, t, b)
--       Older, and gone here. Blizzard filled these from the first plate of
--       each type via NamePlateBaseMixin:GetPreferredInsets(), which measures
--       BLIZZARD'S health bar against the plate — so with their bar hidden and
--       ours a different size, the crop described a bar that isn't on screen.
--
-- Kept both: the old one costs a nil check on clients that still have it, and
-- nothing here can tell which generation the next patch ships.
local lastInsetReport = nil

-- Applied to all four sides, and large enough to swamp whatever the client crops
-- by. It has to be a "big enough" number rather than a measured one: the crop
-- isn't exposed and the getter is unreadable, so there is nothing to subtract
-- from. This is the same value Plater ships for its "definitely clickable"
-- state, and the expansion is clamped — verified in game, where it made the
-- whole bar clickable without plates picking up clicks aimed anywhere else.
--
-- Being global rather than per-plate is what makes the hit area follow the
-- nameplate on its own: one write covers every plate, present and future, so
-- there is nothing to keep in sync as plates are recycled. What each plate is
-- worth clicking is decided by its SIZE (applyPlateSizes, derived from the bar),
-- and this just stops the client shrinking that back down.
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

    -- Never expanded, only ever cleared. On the older API zero already means
    -- "the whole plate rect" — its crop came from measuring Blizzard's health
    -- bar, not from a hidden client-side shrink — so the swamp-it value that the
    -- newer one needs has nothing to do here, and its behaviour past zero is
    -- untested on any client this would run on.
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

-- Returns the click box the current settings ask for, in base-plate units
-- (WorldFrame's coordinate space, scale 1), plus the bar extents it was derived
-- from. Split out from applyPlateSizes so the debug dump reports exactly the
-- numbers that were actually sent to the client rather than its own re-guess.
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
    return math.floor(widest  + CLICK_PAD_X + 0.5),
           math.floor(tallest + CLICK_PAD_Y + 0.5),
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

    -- Zeroing the insets once isn't enough. UpdateNamePlateOptions wipes the
    -- driver's `preferredInsets` cache, and the next plate of each type to be
    -- shown then re-derives them from Blizzard's hidden health bar through
    -- UpdateInsetsForType. Re-zeroing right after it runs is what makes it
    -- hold — including on the very first plate after a /reload, which is
    -- before applyPlateSizes has ever had a plate to work with.
    --
    -- Guarded rather than assumed: this is a driver internal, not API, and it
    -- is absent on clients old enough not to have per-type insets at all.
    if NamePlateDriverFrame.UpdateInsetsForType then
        hooksecurefunc(NamePlateDriverFrame, "UpdateInsetsForType", function()
            if isEnabled() then clearClickInsets() end
        end)
    end
end

-- Every CVar the engine scales a plate by. Ours is not the only multiplier in
-- play: the client scales plates by distance between nameplateMinScale and
-- nameplateMaxScale, then multiplies the targeted one by nameplateSelectedScale
-- again. That's why a plate could sit small in the distance and then jump when
-- targeted, well past the 10-15% this module's own target scale asks for — the
-- engine's 1.2 and ours compound.
--
-- Pinning them all to 1 leaves this module's scale settings as the only thing
-- sizing a plate, which is the whole point of taking nameplates over.
local SCALE_CVARS = {
    "nameplateMinScale", "nameplateMaxScale", "nameplateSelectedScale",
    "nameplateLargerScale", "nameplateGlobalScale",
}

-- Restoring means putting back what YOU had, not what Blizzard ships: these are
-- account-wide CVars this module didn't set, and guessing at defaults would
-- quietly overwrite a deliberate choice. So the originals are snapshotted into
-- the profile the first time they're pinned.
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
            -- Only what this client actually has: the family has shifted
            -- between builds, and writing a snapshot entry for a CVar that
            -- doesn't exist would make the restore fail on it forever.
            if ok and v ~= nil then saved[name] = v end
        end
        g.savedScaleCVars = saved
    end

    for _, name in ipairs(SCALE_CVARS) do setCVarSafe(name, 1) end
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
-- Assigned by the click-area debugging section at the bottom of the file (it
-- needs things declared between here and there). A no-op until then, and a
-- no-op afterwards too unless the overlay has actually been switched on — this
-- is called on every plate handover.
local refreshClickDebug = function() end

local driver = CreateFrame("Frame")
local SLOW_INTERVAL = 0.1
local sinceSlow = 0

-- Exponential ease towards the goal scale, in "fraction of the remaining gap per
-- second". Frame-rate independent (the step is scaled by elapsed), so the
-- animation takes the same ~0.2s whether the client is running at 30fps or 144.
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

-- Registered only while something actually needs them. COMBAT_LOG_EVENT_UNFILTERED
-- fires for every swing in a forty-man pull, and a profile that infers nothing —
-- which is every PvE profile, and every profile with an empty whitelist — should
-- not be paying to read a single one of them.
local inferEventsOn = false

local function auraInferenceWanted()
    if not isEnabled() then return false end
    local d = cfg()
    local a = d and d.auras
    if not (a and a.enabled ~= false and a.units) then return false end

    -- Both halves have to hold for the SAME unit type: events switched on for
    -- players is no reason to listen if only the NPC lists have anything in
    -- them, since nothing arriving could ever be recorded.
    for _, def in ipairs(Data.AURA_UNITS) do
        local u = a.units[def.key]
        if u and u.fromEvents then
            for _, which in ipairs(AURA_KINDS) do
                local o = u[which]
                if o and o.enabled ~= false and Data.AuraLookup(def.key, which).count > 0 then
                    return true
                end
            end
        end
    end
    return false
end

local function syncAuraEvents()
    local want = auraInferenceWanted()
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
    -- so the store still needs pruning on a screen with no nameplates on it.
    sweepInferred(elapsed)
    if not next(active) then return end
    sinceSlow = sinceSlow + elapsed
    local slow = sinceSlow >= SLOW_INTERVAL
    if slow then sinceSlow = 0 end

    local d = cfg()
    local hover = d and d.general and d.general.hoverHighlight ~= false
    local hasMouseover = hover and UnitExists("mouseover")
    -- Read once for the whole pass rather than per plate, and only consulted on
    -- a slow tick — learnFromPlate throttles itself again on top of this.
    -- Under the master switch as well as its own: that checkbox sits above the
    -- tab strip the Learned page lives on, so it has to mean what it looks like
    -- it means.
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
            updateRaidIcon(f)
            -- Self-throttling: this only reaches the tooltip every QUEST_RESCAN
            -- seconds per plate, the rest of the time it just re-reads a cache.
            updateQuestIcon(f)
            -- Whether something is fighting you changes on its own, with no
            -- event to hang it off — unlike the target dim, which updateTarget
            -- already covers.
            updateAlpha(f)
            -- Border thickness is snapped to whole screen pixels against the
            -- border frame's effective scale, so it goes stale the moment the
            -- game rescales the nameplate under us (Blizzard's own distance
            -- scaling, nameplateMinScale/MaxScale). Measured on `deco`, whose
            -- counter-scale cancels out our own scaling — so the target-scale
            -- animation ticking away above doesn't drag a relayout with it.
            local es = f.deco:GetEffectiveScale()
            if es and math.abs(es - (f.borderScale or 0)) > 0.0001 then
                layoutPlateBorders(f)
            end
            -- UNIT_AURA only marks the plate; the rescan happens here, so a raid
            -- pull's burst of aura events costs one scan per plate per tick
            -- instead of one per event.
            if f.auraDirty then updateAuras(f) end
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
-- the log does: accepting, abandoning or completing a quest all change which
-- mobs are worth an icon and which icon they get.
driver:RegisterEvent("QUEST_LOG_UPDATE")
driver:RegisterEvent("QUEST_ACCEPTED")
driver:RegisterEvent("QUEST_REMOVED")
-- Plate size and border thickness are both derived from the interface scale now,
-- and neither re-derives itself: the counter-scale on `deco` is set explicitly,
-- so a UI scale change would otherwise leave every plate sized for the old one
-- until each was next recycled.
driver:RegisterEvent("UI_SCALE_CHANGED")
driver:RegisterEvent("DISPLAY_SIZE_CHANGED")

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
        -- After attach: a base plate only enters `plates` when it first gets a
        -- frame of ours, so this is the earliest point the overlay can be hung
        -- on a plate that has just come out of the pool.
        refreshClickDebug()
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        release(arg1)
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        rememberUnit("mouseover")
    elseif event == "RAID_TARGET_UPDATE" then
        for _, f in pairs(active) do updateRaidIcon(f) end
    elseif event == "QUEST_LOG_UPDATE" or event == "QUEST_ACCEPTED" or event == "QUEST_REMOVED" then
        -- Rebuilt lazily on the next scan rather than here: QUEST_LOG_UPDATE
        -- fires in bursts, and walking the whole log per event would be work
        -- thrown away by the next one in the burst.
        questTypesStale = true
        for _, f in pairs(active) do updateQuestIcon(f, true) end
    elseif event == "PLAYER_TARGET_CHANGED" then
        rememberUnit("target")
        for _, f in pairs(active) do updateTarget(f) end
    elseif event == "UNIT_NAME_UPDATE" or event == "UNIT_LEVEL" then
        local f = active[arg1]
        if f then updateName(f) end
    elseif event == "UNIT_FACTION" then
        local f = active[arg1]
        -- A faction flip can move the unit into a different settings group
        -- entirely (an enemy player going friendly), so re-run the whole
        -- attach rather than just recolouring.
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
    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        Data.EnsureSeeded()
        applyEngineSettings()
        NP.refresh()
    end
end)

-- ── Public interface ─────────────────────────────────────────────────────────
-- Re-derives every visible plate from the current settings. Called by the
-- settings UI on any change, and by core's RefreshAllModules after a profile
-- switch (which repoints addon.db at a different table entirely).
function NP.refresh()
    Data.EnsureSeeded()
    -- Before anything reads the aura settings: a profile saved under the old
    -- single-pair shape still has its whitelists at auras.buffs/auras.debuffs,
    -- and every reader below now looks for them per unit type.
    Data.MigrateAuras()
    -- The whitelists are flattened into match maps that nothing else diffs, so
    -- every path that can have changed them — a settings edit, an import, a
    -- profile switch — has to drop the cache here. The preview's icon list is
    -- derived from the same whitelists, so it goes with them.
    Data.InvalidateAuras()
    previewArtCache = {}
    applyEngineSettings()
    -- After the invalidate, not before: whether the events are worth listening
    -- to is decided partly by whether the whitelists are empty, and that has to
    -- be re-read from the edit that got us here.
    syncAuraEvents()

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
        -- The insets and the scale CVars are both globals the client keeps until
        -- something changes them, so switching the module off has to hand them
        -- back — otherwise Blizzard's own plates are left wearing our expanded
        -- hit area and our pinned scaling.
        if not InCombatLockdown() then
            applyHitInsets(0)
            local d = cfg()
            if d and d.general then restorePlateScales(d.general) end
        end
        return
    end

    -- Re-attach from the live plate list rather than from `active`: a plate that
    -- was skipped while the module (or its group) was switched off isn't in
    -- `active` at all, and would otherwise stay Blizzard-styled until it was
    -- next recycled.
    for _, base in ipairs(C_NamePlate.GetNamePlates() or {}) do
        local unit = base.namePlateUnitToken or (base.UnitFrame and base.UnitFrame.unit)
        if unit and UnitExists(unit) then attach(unit) end
    end
end

-- Draws made-up rows of icons instead of the real auras, on the plates of one
-- unit type, so the size/spacing/nudge settings can be judged against actual
-- nameplates while they're being changed. `unitKey` is "enemyPlayer" or
-- "enemyNPC"; nil turns it off. Deliberately not persisted: it is a state of
-- the settings window, and a /reload with the window shut must not leave fake
-- icons behind.
function NP.SetAuraPreview(unitKey)
    if auraPreviewUnit == unitKey then return end
    auraPreviewUnit = unitKey
    previewArtCache = {}
    for _, f in pairs(active) do updateAuras(f) end
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
-- The clickable area is invisible, it lives in a different coordinate space from
-- the bar drawn on it, and the inset that crops it has no getter — so "the edges
-- won't click" can't be eyeballed or worked out from the settings. These make it
-- measurable:
--
--   /denp click  outlines the base plate's rect on every nameplate. With the
--                preferred insets zeroed that rect IS the click box, so:
--                  · bar sticking out past the outline  -> the plate is too
--                    small, i.e. the size setters aren't landing
--                  · bar inside the outline, edges still dead -> the rect is
--                    right and something is still cropping or covering it
--                The outline turns yellow while the cursor is geometrically
--                inside the rect, which separates "the game doesn't think the
--                mouse is here" from "it does, and still won't target".
--
--   /denp dump   the same thing as numbers: what was asked for, what the client
--                actually made the plate, and the two widths in screen pixels.
local function debugPrint(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cfffb2c36Nameplates:|r " .. msg)
end

local clickDebugShown = false

-- Nameplates are hit-tested in the world, underneath the whole UI, so ANY
-- mouse-enabled frame lying over one swallows the click before the plate is
-- ever considered — the classic offender being an addon that switched the mouse
-- on for a full-screen frame like UIErrorsFrame. That looks identical from the
-- outside to a click box that's too small, so the overlay reports it: while the
-- cursor is inside a plate rect, anything but WorldFrame under it is the
-- culprit. Printed only when the answer changes, or it would be one line a frame.
-- Keyed AND time-limited: the key alone stops the steady state repeating, but a
-- cursor resting on a boundary can flip the answer every frame, and two frames
-- of that is already two lines of chat.
local lastFocusKey, lastFocusAt = nil, 0
local FOCUS_REPORT_INTERVAL = 2

local function mouseFocusFrame()
    -- GetMouseFocus is deprecated in favour of the plural form on newer builds
    -- and removed on some; whichever exists is fine, the first entry is the
    -- topmost frame either way.
    if GetMouseFoci then
        local foci = GetMouseFoci()
        return foci and foci[1]
    end
    return GetMouseFocus and GetMouseFocus()
end

local function reportMouseFocus()
    local focus = mouseFocusFrame()
    local key = tostring(focus)
    if key == lastFocusKey then return end
    local now = GetTime()
    if now - lastFocusAt < FOCUS_REPORT_INTERVAL then return end
    lastFocusKey, lastFocusAt = key, now
    if focus and focus ~= WorldFrame then
        local name = (focus.GetName and focus:GetName()) or "an unnamed frame"
        debugPrint(("cursor is inside a plate, but |cffff4040%s|r is over it and takes the mouse — that frame is eating the click.")
            :format(name))
    end
end

-- The hit area really is knowable now: this client pairs the setter with
-- GetNamePlateHitTestInsets, so the overlay can draw where clicks actually land
-- instead of the plate rect and a hope that nothing is cropping it.
--
-- The insets are per-type, and the type follows the unit rather than the plate,
-- so a plate with no unit on it is read as Friendly — which is what the client
-- does with it too until something is assigned.
--
-- The returns need sanitising before they are touched. pcall protects the CALL,
-- not what comes back, and this client hands out "secret values" from hardened
-- APIs: they survive being stored and passed around, then throw the moment
-- anything does arithmetic on or compares them. That is what killed the dump
-- one line into each plate (`hitL + l * bs` runs before the print that would
-- have shown them) and what made the overlay throw every frame (`l ~= self.il`).
-- Plater carries issecretvalue() checks for the same reason.
local function safeNumber(v)
    if issecretvalue and issecretvalue(v) then return nil end
    local ok, n = pcall(tonumber, v)
    if not ok or type(n) ~= "number" then return nil end
    return n
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

local function clickBoxOverlay(base)
    local o = base.drievClickBox
    if o then return o end

    o = CreateFrame("Frame", nil, base)
    o:SetAllPoints(base)
    -- Clear of everything the module draws: the target's plate is raised by 20
    -- levels in setPlateLevel and its own overlay sits 3 above that.
    o:SetFrameLevel((base:GetFrameLevel() or 0) + 40)

    local fill = o:CreateTexture(nil, "OVERLAY", nil, 6)
    fill:SetTexture(WHITE)
    fill:SetAllPoints(o)
    o.fill = fill

    -- The plate's own border helpers, so the outline is pixel-snapped and sits
    -- just OUTSIDE the rect — the last row of pixels inside it is still part of
    -- the click box, which is exactly what's being measured here.
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

        local over = parent:IsMouseOver()
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

refreshClickDebug = function()
    if clickDebugShown then setClickDebug(true) end
end

local function cvarStr(name)
    local ok, v = pcall(GetCVar, name)
    if not ok or v == nil then return name .. "=n/a" end
    return name .. "=" .. tostring(v)
end

-- Base plates print as "?" for their unit surprisingly often — namePlateUnitToken
-- is set by Blizzard's driver, not by the client, so a plate can be on screen
-- and styled before (or without) that field ever appearing. Ours is the reliable
-- answer, since attach() is what put a frame on this plate in the first place.
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

    -- Per side, in screen pixels, measured from the real edges rather than from
    -- the widths. A width comparison averages the two sides together and so
    -- cannot see a hit area that is the right SIZE but sitting off-centre —
    -- which is what "the left edge is worse than the right" is.
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

    -- Which of the size API actually exists here, and what the last real attempt
    -- did with it. A "missing" line for SetNamePlateSize vs the per-type ones is
    -- the whole question of which generation of the API this client listens to.
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

    -- Listed rather than probed by name: this is the API generation that
    -- replaced the one that vanished, so what it offers is worth reading
    -- straight off the client instead of guessing at spellings.
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
                            "nameplateSelectedScale", "nameplateMotion" }) do
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

-- The default (HIT_INSET_EXPAND) is what makes the whole plate clickable, and it
-- is a swamp-it value rather than a measured one because the client won't say
-- how much it crops. This stays so a client that clamps differently can be
-- dialled in live rather than needing a rebuild to find out.
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

    local before = {}
    for i, base in ipairs(list) do before[i] = { base:GetWidth() or 0, base:GetHeight() or 0 } end

    applyPlateSizes()

    local w, h = computePlateSize()
    for i, base in ipairs(list) do
        local aw, ah = base:GetWidth() or 0, base:GetHeight() or 0
        local moved    = math.abs(aw - before[i][1]) > 0.5 or math.abs(ah - before[i][2]) > 0.5
        local atTarget = math.abs(aw - (w or 0)) <= 0.5 and math.abs(ah - (h or 0)) <= 0.5

        -- "Unchanged" on its own means nothing: a plate that was already the
        -- right size is supposed to stay put. Only unchanged AND wrong is a
        -- failure, which is exactly the distinction the first version of this
        -- got backwards.
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

SLASH_DRIEVNAMEPLATES1 = "/denp"
SLASH_DRIEVNAMEPLATES2 = "/drievnameplates"
SlashCmdList["DRIEVNAMEPLATES"] = function(msg)
    local raw = strtrim(msg or "")
    local cmd, arg = raw:match("^(%S*)%s*(.-)$")
    cmd = strlower(cmd or "")
    if cmd == "inset" then
        setHitInset(arg)
    elseif cmd == "click" or cmd == "clickbox" then
        setClickDebug(not clickDebugShown)
        debugPrint(clickDebugShown
            and "Overlay ON. The outline is the hit area as the client reports it, falling back to the raw plate rect when the insets can't be read — so where clicks actually land falling short of the outline is itself the finding. Yellow while the cursor is inside it."
            or  "Overlay off.")
    elseif cmd == "dump" then
        dumpClickArea()
    elseif cmd == "apply" then
        testApply()
    else
        debugPrint("/denp click     : outline the hit area on every nameplate")
        debugPrint("/denp dump      : print the click box measurements and API surface")
        debugPrint("/denp apply     : re-apply the plate size and report whether it moved")
        debugPrint("/denp inset <n> : set the hit-test inset live (negative expands)")
    end
end
