-- Swing timer module: engine and bars. Loads only alongside core
-- (## Dependencies), so the shared namespace always exists.
local addon = _G.DrievEssentials
if not addon then return end

local UI = addon.UI

-- One bar per weapon hand, filling from the last observed swing to the next one.
-- The swing-tracking logic follows LibClassicSwingTimerAPI, but drives our own
-- bars from an OnUpdate instead of firing WeakAuras events, so there are no
-- per-swing C_Timer objects to cancel and re-create.

local WHITE        = "Interface\\Buttons\\WHITE8x8"
local DEFAULT_BAR  = "Interface\\TargetingFrame\\UI-StatusBar"
-- How far the text box is inset from the bar's edges. Both strings span that
-- whole box and justify to opposite sides of it; the user's X offset slides the
-- box, so positive always means "further right" for both of them.
local LABEL_INSET  = 4
local SPARK_TEXTURE = "Interface\\AddOns\\DrievsEssentials_SwingTimer\\Square_AlphaGradient.tga"
-- The fill is redrawn every frame. A throttle on the geometry is what makes a
-- swing timer step instead of slide: a 20ms one skips every other frame at 60fps,
-- so the bar moves at 30 — and wobbles between one- and two-frame gaps whenever
-- the frametime crosses the threshold. Only the genuinely expensive work is
-- throttled, and moving SetText and SetMinMaxValues behind change checks makes
-- the every-frame path cheaper than the old throttled one was.
local SLOW_STEP    = 0.1    -- queue poll, ~10Hz

-- ── Spell tables ─────────────────────────────────────────────────────────────
-- Only the reset list is user-editable (see resetSpells below); the rest describe
-- how the client itself behaves and aren't opinions anyone needs to change.

-- Casts that restart the swing timer outright.
local DEFAULT_RESET_SPELLS = {
    [16589] = true, -- Noggenfogger Elixir
    [2645]  = true, -- Ghost Wolf
    [2764]  = true, -- Throw
    [3018]  = true, -- Shoots
    [5384]  = true, -- Feign Death
    [5019]  = true, -- Shoot
    [75]    = true, -- Auto Shot
    [20066] = true, -- Repentance
    [11350] = true, -- Fire Shield
    -- Left unlabelled deliberately: the settings panel resolves every ID to its
    -- real name from the client, which beats a comment that might be wrong.
    [16323] = true,
    [16329] = true,
    [2480]  = true,
    [7918]  = true,
    [7919]  = true,
}

-- The two on-next-swing abilities that get their own bar colour while queued.
local HEROIC_STRIKE_RANKS = { 78, 284, 285, 1608, 11564, 11565, 11566, 11567, 25286 }
local CLEAVE_RANKS        = { 845, 7369, 11608, 11609, 20569 }

-- "On next swing" abilities: they replace the white hit, so the swing that lands
-- them shows up as SPELL_DAMAGE and never as SWING_DAMAGE.
local NEXT_MELEE_SPELLS = {
    [14266] = true, [14265] = true, [14264] = true, [14263] = true, -- Raptor Strike 8-5
    [14262] = true, [14261] = true, [14260] = true, [2973]  = true, -- Raptor Strike 4-1
    [6807]  = true, [6808]  = true, [6809]  = true, [8972]  = true, -- Maul 1-4
    [9745]  = true, [9880]  = true, [9881]  = true,                 -- Maul 5-7
}
for _, id in ipairs(HEROIC_STRIKE_RANKS) do NEXT_MELEE_SPELLS[id] = true end
for _, id in ipairs(CLEAVE_RANKS)        do NEXT_MELEE_SPELLS[id] = true end

-- Casts that do NOT reset the swing, so they have to be excluded from the
-- blanket "a completed cast resets the swing" rule below.
local NORESET_SPELLS = {
    [23063] = true, [4054]  = true, [4064]  = true, [4061]  = true, -- bombs / dynamite
    [8331]  = true, [4065]  = true, [4066]  = true, [4062]  = true,
    [4067]  = true, [4068]  = true, [23000] = true, [12421] = true,
    [4069]  = true, [12562] = true, [12543] = true, [19769] = true,
    [19784] = true, [19821] = true,
    [56641] = true, [34120] = true,                                 -- Steady Shot
    [19434] = true,                                                 -- Aimed Shot
    [1464]  = true, [8820]  = true, [11604] = true, [11605] = true, -- Slam 1-4
    [17402] = true, [17401] = true, [16914] = true,                 -- Hurricane 3-1
    [12051] = true,                                                 -- Evocation
    [14295] = true, [14294] = true, [1510]  = true,                 -- Volley 3-1
}

-- Casts that hold the swing where it is for their duration instead of resetting
-- it; the elapsed cast time is added back when they finish or are interrupted.
local PAUSE_SPELLS = {
    [1464] = true, [8820] = true, [11604] = true, [11605] = true, -- Slam 1-4
}

-- Shapeshifts fire UNIT_ATTACK_SPEED with the form's speed before the real one
-- settles, which would rescale the bar off a value that never applied.
local PREVENT_SPEED_UPDATE = {
    [768]  = true, -- Cat Form
    [5487] = true, -- Bear Form
    [9634] = true, -- Dire Bear Form
}

-- While one of these is up, a completed cast does not reset the swing.
local PREVENT_RESET_AURAS = {
    [408505] = true, -- Maelstrom Weapon
}

local AUTO_ATTACK_SPELL = 6603

-- ── Settings ─────────────────────────────────────────────────────────────────
-- resetSpells is a set keyed by spell ID. Removing one of the defaults stores
-- `false` rather than clearing the key: applyDefaults() only fills in keys that
-- are nil, so a cleared default would come straight back at the next login.
local DEFAULTS = {
    enabled      = false,
    width        = 255,
    height       = 13,
    spacing      = 0,      -- px between the mainhand and offhand bars' fills
    showTimer       = true,  -- seconds until the next attack, right of each bar
    timerCombatOnly = false, -- ...and only while in combat
    timerHideZero   = false, -- ...and not while it reads 0.0
    showLabel       = true,  -- "Mainhand" / "Offhand", left of each bar
    -- Per-string appearance, both the addon's shared font block (core's Font.lua):
    -- face, size, outline, x/y nudge and drop shadow. These two predate the block
    -- and stored the face under `name`; addon.Font.Adopt renames it in place on
    -- first read, which is why `name` is no longer declared here.
    timerFont = addon.Font.New({ size = 9 }),
    labelFont = addon.Font.New({ size = 9 }),
    color        = { 0, 0.118, 1 },       -- 0, 30, 255
    texture      = "Blizzard",
    -- The container's fill: sits behind both bars and shows through the padding
    -- gap between them. Opacity is a percentage, like every other one here, and
    -- multiplies with the combat-state opacity below.
    backdropColor   = { 0.04, 0.04, 0.06 },
    backdropOpacity = 85,
    outline      = false,
    outlineMode  = "around",   -- "around" the pair, or "each" bar separately
    outlineColor = { 0, 0, 0 },
    spark        = true,
    sparkWidth   = 1,
    -- Opacity is per combat state, so the bars can sit quietly out of combat
    -- without being turned off. Percentages, matching every other opacity in
    -- this addon.
    opacity      = 100,   -- in combat
    opacityOOC   = 50,    -- out of combat
    -- Queue colouring: an on-next-swing ability is spent on the MAINHAND swing,
    -- but both bars are recoloured by default because the pair reads as one
    -- element. queueBothBars = false narrows it to the hand it actually affects.
    queueColors       = true,
    queueBothBars     = true,
    cleaveColor       = { 0, 1, 0 },          -- 0, 255, 0
    heroicStrikeColor = { 1, 0.863, 0 },      -- 255, 220, 0
    px           = nil,    -- position, absent until first moved
    py           = nil,
    resetSpells  = DEFAULT_RESET_SPELLS,
}

addon.RegisterDefaults("swingTimer", DEFAULTS)

-- Makes the block above pickable on its own in the Profiles tab's export,
-- import and copy dialogs.
if addon.RegisterProfileSection then
    addon.RegisterProfileSection({ key = "swingTimer", label = "Swingtimer", order = 15,
        settings = { "swingTimer" } })
end

-- Both blocks stored the face under `name` before core's Font.lua existed. The
-- rename has to happen before the defaults are merged in, or the merge fills
-- `font` with the shipped default and the user's choice is left orphaned under
-- the old key.
addon.Font.MigrateBlock(function(s) return s.swingTimer end, "timerFont", { font = "name" })
addon.Font.MigrateBlock(function(s) return s.swingTimer end, "labelFont", { font = "name" })

local function stSettings()
    return addon.db and addon.db.settings and addon.db.settings.swingTimer
end

local function isEnabled()
    local s = stSettings()
    return (s and s.enabled) and true or false
end

local function resetSpells()
    local s = stSettings()
    return (s and s.resetSpells) or DEFAULT_RESET_SPELLS
end

-- ── Frame ────────────────────────────────────────────────────────────────────
local container, editing

-- Combat state for the two opacity settings, latched from PLAYER_REGEN_DISABLED/
-- ENABLED rather than read from InCombatLockdown(). That flag tracks the SECURE
-- lockdown, which isn't reliably set yet while the entering-combat event is being
-- handled — so asking it there left the bars on their out-of-combat opacity for
-- the whole fight.
local inCombat = false

-- A settings-panel preview: for its duration both strings are forced on and the
-- bars behave as though in combat, so the text options can be tuned without
-- going and finding something to hit.
local PREVIEW_SECONDS = 20
local previewUntil, previewTimer = 0, nil

local function isPreviewing()
    return GetTime() < previewUntil
end

-- The dark background lives on the CONTAINER, never on the individual bars: a
-- per-bar background is what put a permanent divider line between them that no
-- padding value could close. A bar carries an edge-only backdrop, used solely
-- for the "outline each bar" mode, and left fully transparent otherwise.
local function createBar(parent, label)
    local bar = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    bar:SetBackdrop({ edgeFile = WHITE, edgeSize = 1 })
    bar:SetBackdropBorderColor(0, 0, 0, 0)

    -- Re-anchored by applyLayout: the fill is inset by a pixel only when this bar
    -- draws its own outline, since a child frame covers its parent's backdrop.
    local fill = CreateFrame("StatusBar", nil, bar)
    fill:SetAllPoints()
    fill:SetMinMaxValues(0, 1)
    fill:SetValue(0)

    -- Rides the leading edge of the fill. ADD blend over a soft-edged texture is
    -- what makes it read as a glow rather than as a block on top of the bar.
    local spark = fill:CreateTexture(nil, "OVERLAY")
    spark:SetTexture(SPARK_TEXTURE)
    spark:SetBlendMode("ADD")
    spark:Hide()

    -- OVERLAY on the StatusBar itself, which draws the fill at ARTWORK — so both
    -- strings stay above the bar texture whatever it is. Created from a font
    -- object rather than bare: SetText on a FontString with no font set errors,
    -- and applyLayout's SetFont only lands once settings exist.
    local name = fill:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    name:SetPoint("LEFT", 4, 0)
    name:SetText(label)

    local timer = fill:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    timer:SetPoint("RIGHT", -4, 0)
    timer:SetText("")

    -- GameFontNormal is yellow and applyLayout's SetFont doesn't touch colour,
    -- so the white is set here, once.
    name:SetTextColor(1, 1, 1)
    timer:SetTextColor(1, 1, 1)

    bar.fill, bar.name, bar.timer, bar.spark = fill, name, timer, spark
    return bar
end

local function getOrCreate()
    if container then return container end

    local f = CreateFrame("Frame", "DrievSwingTimerFrame", UIParent, "BackdropTemplate")
    f:SetSize(255, 30)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, -180)
    -- Backs both bars and fills the padding gap between them, and carries the
    -- outline in its default "around the pair" mode.
    f:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    f:SetBackdropColor(0.04, 0.04, 0.06, 0.85)
    f:SetBackdropBorderColor(0, 0, 0, 1)
    -- Deliberately not SetMovable: dragging is done by hand in dragTick, which is
    -- what lets the centre-line snap take over the frame's X mid-drag.
    f:SetClampedToScreen(true)
    f:SetFrameStrata("MEDIUM")

    f.main = createBar(f, "Mainhand")
    f.off  = createBar(f, "Offhand")
    f:Hide()

    container = f
    return f
end

-- Whether an offhand is equipped and swinging. Drives whether the second bar
-- exists at all, so the frame is only as tall as it has bars to show.
local function hasOffhand()
    local _, off = UnitAttackSpeed("player")
    return (off or 0) > 0
end

-- Set by applyLayout so the next render re-applies the bar colour: the queue
-- colour is only written when it changes, and a settings edit changes it
-- without the queue itself moving.
local queueDirty = true

-- Opacity follows combat state. Edit Mode overrides it to full: a bar dragged at
-- 10% out of combat is a bar you can't see well enough to place.
local function applyAlpha()
    local f = getOrCreate()
    local s = stSettings() or DEFAULTS
    if editing then
        f:SetAlpha(1)
        return
    end
    local pct = (inCombat or isPreviewing()) and (s.opacity or DEFAULTS.opacity)
        or (s.opacityOOC or DEFAULTS.opacityOOC)
    f:SetAlpha(math.max(0, math.min(100, pct)) / 100)
end

-- Paints one string from its shared font block (core's Font.lua) and re-seats it.
--
-- `fill` rather than a single point: the string is pinned to the bar's whole
-- inner rect and justified to one side, rather than anchored by that side alone.
-- An edge-anchored FontString is sized to its own content, and a drop shadow is
-- PART of that content — so pinning the right edge of a shadowed string pushes
-- the glyphs left by the shadow offset, which looks like moving the shadow drags
-- the text along with it. A fixed box can't be pushed around by anything drawn
-- inside it.
local function applyFontTo(fs, key, justify)
    local s   = stSettings()
    local cfg = s and addon.Font.Adopt(s, key, { font = "name" }) or nil
    addon.Font.ApplyAt(fs, cfg, DEFAULTS[key], {
        fill = fs:GetParent(), inset = LABEL_INSET,
        justifyH = justify, justifyV = "MIDDLE",
    })
    -- White unless the block's custom colour is ticked, which is the colour
    -- this string has always been.
    addon.Font.ApplyColor(fs, cfg, DEFAULTS[key], 1, 1, 1)
end

-- The countdown can be limited to combat. Edit Mode counts as shown, so the
-- placeholder text is there to position against.
local function timerVisible()
    if isPreviewing() then return true end
    local s = stSettings() or DEFAULTS
    if s.showTimer == false then return false end
    if s.timerCombatOnly and not (inCombat or editing) then return false end
    return true
end

-- Its own entry point rather than part of applyLayout: combat transitions flip
-- it, and re-deriving the whole layout on every one of those would be wasteful.
local function applyTimerVisibility()
    local f = getOrCreate()
    local shown = timerVisible()
    f.main.timer:SetShown(shown)
    f.off.timer:SetShown(shown)
end

local function applyLayout()
    local f = getOrCreate()
    local s = stSettings() or DEFAULTS
    local w   = s.width   or DEFAULTS.width
    local h   = s.height  or DEFAULTS.height
    local pad = s.spacing or DEFAULTS.spacing
    local c   = s.color   or DEFAULTS.color
    local oc  = s.outlineColor or DEFAULTS.outlineColor
    local tex = addon.FetchMedia("statusbar", s.texture) or DEFAULT_BAR
    local showOff  = editing or hasOffhand()

    -- "around" draws one border enclosing both bars — top, sides and bottom, with
    -- nothing between them. "each" gives every bar its own. Whichever is off
    -- contributes no inset, so switching modes never changes the bars' own size.
    local outlineOn = (s.outline ~= false)
    local eachOn    = outlineOn and (s.outlineMode or DEFAULTS.outlineMode) == "each"
    local aroundOn  = outlineOn and not eachOn
    local outerPad  = aroundOn and 1 or 0
    local barPad    = eachOn   and 1 or 0
    local timerOn   = timerVisible()

    f:SetBackdropBorderColor(oc[1] or 0, oc[2] or 0, oc[3] or 0, aroundOn and 1 or 0)

    local bd  = s.backdropColor or DEFAULTS.backdropColor
    local bdA = math.max(0, math.min(100,
        s.backdropOpacity or DEFAULTS.backdropOpacity)) / 100
    f:SetBackdropColor(bd[1] or 0, bd[2] or 0, bd[3] or 0, bdA)

    for _, bar in ipairs({ f.main, f.off }) do
        bar:SetSize(w, h)
        bar:SetBackdropBorderColor(oc[1] or 0, oc[2] or 0, oc[3] or 0, eachOn and 1 or 0)
        bar.fill:ClearAllPoints()
        bar.fill:SetPoint("TOPLEFT",      barPad, -barPad)
        bar.fill:SetPoint("BOTTOMRIGHT", -barPad,  barPad)
        bar.fill:SetStatusBarTexture(tex)
        bar.fill:SetStatusBarColor(c[1] or 1, c[2] or 1, c[3] or 1)
        applyFontTo(bar.name,  "labelFont", "LEFT")
        applyFontTo(bar.timer, "timerFont", "RIGHT")
        bar.name:SetShown(isPreviewing() or s.showLabel ~= false)
        bar.timer:SetShown(timerOn)
        bar.spark:SetSize(s.sparkWidth or DEFAULTS.sparkWidth, math.max(1, h - barPad * 2))
        bar._innerW = math.max(1, w - barPad * 2)
    end

    f.main:ClearAllPoints()
    f.main:SetPoint("TOPLEFT", f, "TOPLEFT", outerPad, -outerPad)
    f.off:ClearAllPoints()
    -- `spacing` is now a plain gap between the two bars, showing the container's
    -- background through it. 0 puts them touching, with nothing drawn between.
    f.off:SetPoint("TOPLEFT", f.main, "BOTTOMLEFT", 0, -pad)
    f.off:SetShown(showOff)

    local barsH = showOff and (h * 2 + pad) or h
    f:SetSize(w + outerPad * 2, math.max(1, barsH) + outerPad * 2)
    queueDirty = true
    applyAlpha()
    if addon.RefreshEditBoxes then addon.RefreshEditBoxes() end
end

-- ── Position ─────────────────────────────────────────────────────────────────
-- Free to go anywhere, but the screen's vertical centre line pulls the bar in
-- while it's being dragged past it (see dragTick) — centring a swing timer by
-- eye is otherwise a pixel-hunt. Only the drag snaps: the position editor stays
-- exact, so a deliberate one-pixel offset is still reachable.
local SNAP_DISTANCE = 15

local function centerX()
    return (UIParent:GetWidth() or 0) / 2
end

-- Re-clicking restarts the countdown rather than stacking a second revert that
-- would cut the new run short.
local function previewText()
    previewUntil = GetTime() + PREVIEW_SECONDS
    applyLayout()
    if previewTimer then previewTimer:Cancel() end
    previewTimer = C_Timer.NewTimer(PREVIEW_SECONDS, function()
        previewTimer, previewUntil = nil, 0
        applyLayout()
    end)
end

local function applyPosition()
    local f = getOrCreate()
    local s = stSettings()
    if s and s.px and s.py then
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", s.px, s.py)
    end
end

local syncEvents   -- defined with the event frame below

local function applyVisibility()
    local f = getOrCreate()
    if syncEvents then syncEvents() end
    f:SetShown(isEnabled())
end

local function savePosition()
    local s = stSettings()
    if not s then return end
    local x, y = getOrCreate():GetCenter()
    s.px, s.py = x, y
end

local function getPosition()
    local x, y = getOrCreate():GetCenter()
    return x or 0, y or 0
end

local function setPosition(x, y)
    local f = getOrCreate()
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
end

local function applyAll()
    applyLayout()
    applyPosition()
    applyVisibility()
end

-- ── Swing tracking ───────────────────────────────────────────────────────────
local st = {
    mainSpeed = 0, mainExpires = 0,
    offSpeed  = 0, offExpires  = 0,
    casting = false, channeling = false, isAttacking = false,
    auraPreventReset = false,
    skipAttackTs = nil, skipAttackCount = 0,
    skipSpeedTs  = nil, skipSpeedCount  = 0,
    pausedAt = nil,
}

local function startMain(now)
    local main = UnitAttackSpeed("player") or 0
    st.mainSpeed   = main
    st.mainExpires = now + main
end

local function startOff(now)
    local _, off = UnitAttackSpeed("player")
    st.offSpeed   = off or 0
    st.offExpires = now + st.offSpeed
end

local function startBoth(now)
    startMain(now)
    startOff(now)
end

-- Rescales what's left of a swing when the weapon's speed changes mid-swing
-- (a haste buff landing or dropping): the fraction already elapsed is preserved.
local function rescale(oldSpeed, newSpeed, expires, now)
    if oldSpeed <= 0 or newSpeed <= 0 then return now + newSpeed end
    local left = (expires - now) * (newSpeed / oldSpeed)
    return now + math.max(0, left)
end

local function onAttackSpeedChanged(now)
    if st.skipSpeedTs and (now - st.skipSpeedTs) < 0.5 and st.skipSpeedCount > 0 then
        st.skipSpeedCount = st.skipSpeedCount - 1
        return
    end
    local main, off = UnitAttackSpeed("player")
    main, off = main or 0, off or 0

    if main > 0 and st.mainSpeed > 0 and main ~= st.mainSpeed then
        st.mainExpires = rescale(st.mainSpeed, main, st.mainExpires, now)
    end
    st.mainSpeed = main

    if off > 0 and st.offSpeed > 0 and off ~= st.offSpeed then
        st.offExpires = rescale(st.offSpeed, off, st.offExpires, now)
    end
    st.offSpeed = off

    -- An offhand appearing or disappearing changes how many bars there are — but
    -- this event also fires on every haste change, which in combat is a Flurry or
    -- Windfury proc several times a swing. An unconditional relayout there re-fetches
    -- the bar texture and re-applies four fonts mid-swing, so it only runs for the
    -- case it's actually here for. Edit Mode forces the offhand bar visible, which
    -- would otherwise read as a change on every event.
    if not editing and (off > 0) ~= getOrCreate().off:IsShown() then
        applyLayout()
    end
end

-- Parry haste: the remaining swing is cut by 40% of the weapon speed, but never
-- below 20% of it. (The reference library compares a timestamp against a
-- duration here, which lets the floor push the swing backwards; this doesn't.)
local function applyParryHaste(now)
    if st.mainSpeed <= 0 then return end
    local left    = st.mainExpires - now
    local reduced = math.max(left - 0.40 * st.mainSpeed, 0.20 * st.mainSpeed)
    if reduced < left then st.mainExpires = now + reduced end
end

local playerGUID

local function onCombatLog()
    local ts, sub, _, sourceGUID, _, _, _, destGUID, _, _, _,
          p1, p2, _, p4, _, _, _, _, _, p10 = CombatLogGetCurrentEventInfo()
    local now = GetTime()

    if sub == "SPELL_EXTRA_ATTACKS" and sourceGUID == playerGUID then
        -- Windfury / Sword Specialization: the extra swings land as ordinary
        -- SWING_DAMAGE lines but must not restart the timer.
        st.skipAttackTs    = ts
        st.skipAttackCount = tonumber(p4) or 0

    elseif (sub == "SWING_DAMAGE" or sub == "SWING_MISSED") and sourceGUID == playerGUID then
        local isOffHand = (sub == "SWING_MISSED") and p2 or p10
        if not isOffHand and st.skipAttackTs and (ts - st.skipAttackTs) < 0.04
            and st.skipAttackCount > 0 then
            st.skipAttackCount = st.skipAttackCount - 1
            return
        end
        if isOffHand then startOff(now) else startMain(now) end

    elseif sub == "SWING_MISSED" and p1 == "PARRY" and destGUID == playerGUID then
        applyParryHaste(now)

    elseif (sub == "SPELL_AURA_APPLIED" or sub == "SPELL_AURA_REMOVED")
        and sourceGUID == playerGUID then
        if PREVENT_SPEED_UPDATE[p1] then
            st.skipSpeedTs    = now
            st.skipSpeedCount = 2
        end
        if PREVENT_RESET_AURAS[p1] then
            st.auraPreventReset = (sub == "SPELL_AURA_APPLIED")
        end
    end
end

-- Slam and friends: the swing is held for the cast, then given back the time the
-- cast took, whether it completed or was interrupted.
local function pauseSwing(now)
    st.pausedAt = now
end

local function resumeSwing(now)
    if not st.pausedAt then return end
    local offset = now - st.pausedAt
    st.pausedAt = nil
    if st.mainSpeed > 0 then st.mainExpires = st.mainExpires + offset end
    if st.offSpeed  > 0 then st.offExpires  = st.offExpires  + offset end
end

local function onCastSucceeded(spellID)
    local now = GetTime()

    if spellID and NEXT_MELEE_SPELLS[spellID] then
        startMain(now)
    end
    -- Completing a cast resets the swing, except for the abilities that don't and
    -- while an aura says otherwise. Decided from THIS cast's ID rather than from a
    -- flag latched at cast start, which would otherwise stay set for good after
    -- the first no-reset cast of the session.
    local noReset = st.auraPreventReset or (spellID and NORESET_SPELLS[spellID])
    if (spellID and resetSpells()[spellID]) or (st.casting and not noReset) then
        startBoth(now)
    end
    if spellID and PAUSE_SPELLS[spellID] then
        resumeSwing(now)
    end
    if st.casting and spellID ~= AUTO_ATTACK_SPELL then
        st.casting = false
    end
end

local function onCastStart(spellID)
    if not spellID then return end
    st.casting = true
    if PAUSE_SPELLS[spellID] then pauseSwing(GetTime()) end
end

local function onCastStopped(spellID)
    st.casting = false
    if spellID and PAUSE_SPELLS[spellID] then resumeSwing(GetTime()) end
end

-- ── Queued on-next-swing abilities ───────────────────────────────────────────
-- There's no event for "Heroic Strike is now queued" that also covers unqueueing,
-- so the queue is polled. The rank lists are filtered to what the player actually
-- knows on SPELLS_CHANGED, which leaves the poll empty (and free) for everyone
-- who isn't a warrior.
local knownHS, knownCleave = {}, {}

local function isSpellKnown(id)
    if IsPlayerSpell then return IsPlayerSpell(id) end
    return IsSpellKnown and IsSpellKnown(id)
end

local function rebuildKnownQueueSpells()
    wipe(knownHS)
    wipe(knownCleave)
    for _, id in ipairs(HEROIC_STRIKE_RANKS) do
        if isSpellKnown(id) then knownHS[#knownHS + 1] = id end
    end
    for _, id in ipairs(CLEAVE_RANKS) do
        if isSpellKnown(id) then knownCleave[#knownCleave + 1] = id end
    end
end

local function isCurrentSpell(id)
    if C_Spell and C_Spell.IsCurrentSpell then return C_Spell.IsCurrentSpell(id) end
    return IsCurrentSpell and IsCurrentSpell(id)
end

local function queuedKind()
    for _, id in ipairs(knownCleave) do
        if isCurrentSpell(id) then return "cleave" end
    end
    for _, id in ipairs(knownHS) do
        if isCurrentSpell(id) then return "heroicStrike" end
    end
    return nil
end

local function queueColor(kind)
    local s = stSettings() or DEFAULTS
    if kind and s.queueColors ~= false then
        if kind == "cleave" then return s.cleaveColor or DEFAULTS.cleaveColor end
        return s.heroicStrikeColor or DEFAULTS.heroicStrikeColor
    end
    return s.color or DEFAULTS.color
end

-- ── Rendering ────────────────────────────────────────────────────────────────
-- Both caches are invalidated wherever the widgets are written past renderBar
-- (edit mode), so the next draw can't be skipped as a no-op against a value the
-- bar no longer holds.
local function invalidateBarCache(bar)
    bar._max, bar._text = nil, nil
end

local function renderBar(bar, speed, expires, now, sparkOn, hideZero)
    if speed <= 0 then
        if bar._max ~= 1 then
            bar._max = 1
            bar.fill:SetMinMaxValues(0, 1)
        end
        bar.fill:SetValue(0)
        if bar._text ~= "" then
            bar._text = ""
            bar.timer:SetText("")
        end
        bar.spark:Hide()
        return
    end
    local left = expires - now
    if left < 0 then left = 0 end
    -- Re-derives the fill's texture coordinates, so it's called when the weapon
    -- speed actually changes rather than on every frame of every swing.
    if bar._max ~= speed then
        bar._max = speed
        bar.fill:SetMinMaxValues(0, speed)
    end
    bar.fill:SetValue(speed - left)

    -- Compared against the formatted text rather than against `left`, so what's
    -- hidden is exactly what would have read "0.0" — anything under 0.05 rounds
    -- down to it and looks just as idle.
    local text = string.format("%.1f", left)
    if hideZero and text == "0.0" then text = "" end
    -- SetText re-lays out the string, which is the most expensive call in here by
    -- some way; at one decimal the text only changes ten times a second, so most
    -- frames it's the same string being handed back.
    if bar._text ~= text then
        bar._text = text
        bar.timer:SetText(text)
    end

    local frac = (speed - left) / speed
    if sparkOn and frac > 0.001 then
        -- CENTER is the spark's only anchor and re-pointing it replaces that
        -- point, so there's nothing for ClearAllPoints to do but churn.
        bar.spark:SetPoint("CENTER", bar.fill, "LEFT", frac * (bar._innerW or 0), 0)
        bar.spark:Show()
    else
        bar.spark:Hide()
    end
end

local slowAccum = 0
local lastQueued

-- Right after a loading screen UnitAttackSpeed reports no offhand until the
-- inventory finishes populating, so the layout derived at PLAYER_ENTERING_WORLD
-- hid the second bar — and with no further event to correct it, it stayed hidden
-- for the rest of the session. Cheap enough to just reconcile on a slow tick
-- instead of guessing which event marks "the inventory is real now".
local OFF_CHECK_STEP = 0.5
local offCheckAccum  = 0

-- Dragging is hand-rolled off the render loop rather than StartMoving(), so the
-- centre-line snap can adjust the frame's X as it moves. StartMoving owns the
-- frame's anchor while it runs, and re-placing it each frame fights the move it
-- is already applying.
local function dragTick(self)
    local cursorX, cursorY = GetCursorPosition()
    local scale = self:GetEffectiveScale()
    local x = (self._dragBaseX or 0) + cursorX / scale - (self._dragCursorX or 0)
    local y = (self._dragBaseY or 0) + cursorY / scale - (self._dragCursorY or 0)

    local mid = centerX()
    if math.abs(x - mid) <= SNAP_DISTANCE then x = mid end

    setPosition(x, y)
end

local function onUpdate(self, elapsed)
    if editing then
        if self._dragging then dragTick(self) end
        return
    end

    -- Both accumulators carry their remainder rather than zeroing it, so a tick
    -- that lands mid-frame keeps its own cadence instead of being pushed out to
    -- wherever the next whole frame falls.
    offCheckAccum = offCheckAccum + elapsed
    if offCheckAccum >= OFF_CHECK_STEP then
        offCheckAccum = offCheckAccum % OFF_CHECK_STEP
        if hasOffhand() ~= self.off:IsShown() then applyLayout() end
    end

    local now = GetTime()
    local s = stSettings() or DEFAULTS
    local sparkOn  = (s.spark ~= false)
    local hideZero = (s.timerHideZero == true) and not isPreviewing()

    -- The poll costs an IsCurrentSpell call per known rank, and the colour it
    -- decides can't change faster than the player can press a button — so it gets
    -- the slow tick rather than a place on the every-frame path. queueDirty is a
    -- settings edit and jumps the queue; it can't wait out a tick it didn't start.
    slowAccum = slowAccum + elapsed
    if slowAccum >= SLOW_STEP or queueDirty then
        slowAccum = slowAccum % SLOW_STEP
        -- Skipped outright when the feature is off, so the poll costs nothing.
        local kind = (s.queueColors ~= false) and queuedKind() or nil
        if queueDirty or kind ~= lastQueued then
            lastQueued, queueDirty = kind, false
            local c = queueColor(kind)
            self.main.fill:SetStatusBarColor(c[1] or 1, c[2] or 1, c[3] or 1)
            -- The offhand doesn't swing the queued ability, but the two bars read
            -- as one element, so by default it follows along. queueBothBars =
            -- false leaves it on the normal colour.
            local o = (s.queueBothBars ~= false) and c or (s.color or DEFAULTS.color)
            self.off.fill:SetStatusBarColor(o[1] or 1, o[2] or 1, o[3] or 1)
        end
    end

    -- Safety valve: the pause is lifted by the cast finishing or failing, and a
    -- missed event would otherwise freeze the bars for the rest of the session.
    if st.pausedAt and (now - st.pausedAt) > 5 then
        resumeSwing(now)
    end
    -- While a pause spell is casting the swing is held, so the bars are drawn as
    -- of the moment it started rather than ticking on toward an expiry that
    -- resumeSwing is about to push back.
    if st.pausedAt then
        renderBar(self.main, st.mainSpeed, st.mainExpires, st.pausedAt, sparkOn, hideZero)
        if self.off:IsShown() then
            renderBar(self.off, st.offSpeed, st.offExpires, st.pausedAt, sparkOn, hideZero)
        end
        return
    end

    -- A swing that lands mid-cast is clipped and starts over; outside that the
    -- bar simply sits full until the next swing is observed.
    if st.mainSpeed > 0 and now >= st.mainExpires
        and (st.casting or st.channeling) and st.isAttacking then
        startMain(now)
    end
    if st.offSpeed > 0 and now >= st.offExpires
        and (st.casting or st.channeling) and st.isAttacking then
        startOff(now)
    end

    renderBar(self.main, st.mainSpeed, st.mainExpires, now, sparkOn, hideZero)
    if self.off:IsShown() then
        renderBar(self.off, st.offSpeed, st.offExpires, now, sparkOn, hideZero)
    end
end

-- ── Events ───────────────────────────────────────────────────────────────────
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("SPELLS_CHANGED")

-- COMBAT_LOG_EVENT_UNFILTERED fires for every hit in the zone, so it and the
-- rest of the tracking events are only registered while the module is on.
local combatEventsOn = false
local COMBAT_EVENTS = {
    "COMBAT_LOG_EVENT_UNFILTERED",
    "PLAYER_EQUIPMENT_CHANGED",
    -- ENTER/LEAVE_COMBAT are the auto-attack toggle; REGEN_DISABLED/ENABLED are
    -- actual combat, which is what the two opacity settings key off.
    "PLAYER_ENTER_COMBAT",
    "PLAYER_LEAVE_COMBAT",
    "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED",
}
local UNIT_EVENTS = {
    "UNIT_ATTACK_SPEED",
    "UNIT_SPELLCAST_START",
    "UNIT_SPELLCAST_SUCCEEDED",
    "UNIT_SPELLCAST_INTERRUPTED",
    "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_CHANNEL_START",
    "UNIT_SPELLCAST_CHANNEL_STOP",
}

function syncEvents()   -- forward-declared local, see applyVisibility
    local want = isEnabled()
    if want == combatEventsOn then return end
    combatEventsOn = want
    for _, e in ipairs(COMBAT_EVENTS) do
        if want then eventFrame:RegisterEvent(e) else eventFrame:UnregisterEvent(e) end
    end
    for _, e in ipairs(UNIT_EVENTS) do
        if want then
            eventFrame:RegisterUnitEvent(e, "player")
        else
            eventFrame:UnregisterEvent(e)
        end
    end
    if want then
        playerGUID = UnitGUID("player")
        -- Direct query, not the latched flag: switching the module on mid-fight
        -- means the entering-combat event has already been and gone.
        inCombat   = UnitAffectingCombat("player") and true or false
        local now = GetTime()
        local main, off = UnitAttackSpeed("player")
        -- Seeded as "ready" rather than as a swing already in flight, so nothing
        -- counts down before the player has actually attacked.
        st.mainSpeed, st.mainExpires = main or 0, now
        st.offSpeed,  st.offExpires  = off  or 0, now
    end
end

eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        onCombatLog()

    elseif event == "PLAYER_ENTERING_WORLD" then
        playerGUID = UnitGUID("player")
        inCombat   = UnitAffectingCombat("player") and true or false
        rebuildKnownQueueSpells()
        applyAll()

    elseif event == "SPELLS_CHANGED" then
        rebuildKnownQueueSpells()

    elseif event == "UNIT_ATTACK_SPEED" then
        onAttackSpeedChanged(GetTime())

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        onCastSucceeded(arg3)

    elseif event == "UNIT_SPELLCAST_START" then
        onCastStart(arg3)

    elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" then
        onCastStopped(arg3)

    elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
        -- A channel fires SUCCEEDED as it BEGINS, before this, so its reset can't
        -- ride the "completed cast" rule in onCastSucceeded — starting the channel
        -- is the moment the swing resets.
        st.casting, st.channeling = true, true
        if not (st.auraPreventReset or NORESET_SPELLS[arg3]) then
            startBoth(GetTime())
        end

    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        st.casting, st.channeling = false, false

    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        -- 16/17/18: main hand, off hand, ranged. A weapon swap restarts both swings.
        if arg1 == 16 or arg1 == 17 or arg1 == 18 then
            startBoth(GetTime())
            applyLayout()
        end

    elseif event == "PLAYER_ENTER_COMBAT" then
        st.isAttacking = true

    elseif event == "PLAYER_LEAVE_COMBAT" then
        st.isAttacking = false

    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        applyAlpha()
        applyTimerVisibility()

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        applyAlpha()
        applyTimerVisibility()
    end
end)

getOrCreate():SetScript("OnUpdate", onUpdate)

-- ── Edit mode ────────────────────────────────────────────────────────────────
local function enterMoveMode()
    local f = getOrCreate()
    editing = true
    applyLayout()   -- forces the offhand bar visible, so both are draggable

    for _, bar in ipairs({ f.main, f.off }) do
        invalidateBarCache(bar)
        bar.fill:SetMinMaxValues(0, 1)
        bar.fill:SetValue(0.6)
        bar.timer:SetText("1.4")
        if (stSettings() or DEFAULTS).spark ~= false then
            bar.spark:ClearAllPoints()
            bar.spark:SetPoint("CENTER", bar.fill, "LEFT", 0.6 * (bar._innerW or 0), 0)
            bar.spark:Show()
        end
    end

    f:SetFrameStrata("TOOLTIP")
    addon.ShowEditBox(f)
    f:EnableMouse(true)
    -- Same click-vs-drag handling as TTK: movement starts on mouse down rather
    -- than waiting on WoW's drag threshold, and a net move under 4px is a click
    -- that opens the X/Y editor.
    f:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        self._clickX, self._clickY = GetCursorPosition()
        local scale = self:GetEffectiveScale()
        local cx, cy = self:GetCenter()
        self._dragBaseX,   self._dragBaseY   = cx or 0, cy or 0
        self._dragCursorX, self._dragCursorY = self._clickX / scale, self._clickY / scale
        self._dragging = true
    end)
    f:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        self._dragging = false
        local x, y = GetCursorPosition()
        local sx, sy = self._clickX or x, self._clickY or y
        if math.abs(x - sx) < 4 and math.abs(y - sy) < 4 and addon.UI then
            addon.UI.OpenPositionEditor(addon.SwingTimer, self)
        end
    end)
end

local function leaveMoveMode()
    local f = getOrCreate()
    editing = false
    f._dragging = false
    f:SetFrameStrata("MEDIUM")
    addon.HideEditBox(f)
    f:EnableMouse(false)
    f:SetScript("OnMouseDown", nil)
    f:SetScript("OnMouseUp",   nil)
    for _, bar in ipairs({ f.main, f.off }) do
        invalidateBarCache(bar)
        bar.timer:SetText("")
        bar.spark:Hide()
    end
    applyLayout()
end

addon.SwingTimer = {
    getFrame        = getOrCreate,
    applyAll        = applyAll,
    applyLayout     = applyLayout,
    applyPosition   = applyPosition,
    applyVisibility = applyVisibility,
    savePosition    = savePosition,
    enterMoveMode   = enterMoveMode,
    leaveMoveMode   = leaveMoveMode,
    getPosition     = getPosition,
    setPosition     = setPosition,
    isEnabled       = isEnabled,
    previewText     = previewText,
    previewSeconds  = PREVIEW_SECONDS,
    -- The settings panel offers "restore defaults" on the reset-spell list.
    defaultResetSpells = DEFAULT_RESET_SPELLS,
}

UI.RegisterMovable("SwingTimer")
UI.movableLabels.SwingTimer = "Swing Timer"
