-- Driev's Essentials — Nameplates module: saved settings and the NPC registry.
--
-- Split out from the engine and the settings UI so both share one definition of
-- the defaults, the seeded NPC list, and the helpers that read/write per-NPC
-- colour entries. `...` would hand us this addon's OWN private table, so reach
-- for core's shared namespace instead — the .toc's ## Dependencies guarantees
-- core has already loaded and set this global.
local addon = _G.DrievEssentials
if not addon then return end

local Data = {}
addon.NameplatesData = Data

-- ── Named colour palette ─────────────────────────────────────────────────────
-- The NPC list's "Select Color" column picks from these by name, but every
-- entry stores a plain {r, g, b} triple — so a colour picked straight out of the
-- swatch (with no name at all) is just as valid as one of these.
Data.COLORS = {
    { name = "white",   rgb = { 1.00, 1.00, 1.00 } },
    { name = "red",     rgb = { 0.95, 0.15, 0.15 } },
    { name = "orange",  rgb = { 1.00, 0.55, 0.10 } },
    { name = "yellow",  rgb = { 1.00, 0.95, 0.20 } },
    { name = "green",   rgb = { 0.20, 0.90, 0.25 } },
    { name = "cyan",    rgb = { 0.20, 0.95, 0.95 } },
    { name = "blue",    rgb = { 0.25, 0.45, 1.00 } },
    { name = "purple",  rgb = { 0.60, 0.25, 0.95 } },
    { name = "magenta", rgb = { 1.00, 0.00, 1.00 } },
    { name = "pink",    rgb = { 1.00, 0.50, 0.80 } },
    { name = "brown",   rgb = { 0.60, 0.40, 0.20 } },
    { name = "grey",    rgb = { 0.60, 0.60, 0.62 } },
    { name = "black",   rgb = { 0.05, 0.05, 0.05 } },
}

local byName = {}
for _, c in ipairs(Data.COLORS) do byName[c.name] = c.rgb end

-- Returns a FRESH copy — callers store the result straight into SavedVariables,
-- and handing out the palette's own table would make every NPC coloured
-- "magenta" share (and then mutate) one table.
function Data.ColorByName(name)
    local rgb = byName[name] or byName.white
    return { rgb[1], rgb[2], rgb[3] }
end

-- Reverse lookup for the list's colour column: the palette name whose triple
-- matches, or nil for a colour the user picked freehand out of the swatch.
function Data.ColorName(rgb)
    if type(rgb) ~= "table" then return nil end
    for _, c in ipairs(Data.COLORS) do
        if math.abs((rgb[1] or 0) - c.rgb[1]) < 0.01
            and math.abs((rgb[2] or 0) - c.rgb[2]) < 0.01
            and math.abs((rgb[3] or 0) - c.rgb[3]) < 0.01 then
            return c.name
        end
    end
    return nil
end

-- ── Defaults ─────────────────────────────────────────────────────────────────
-- Registered into core's defaults at load time and merged into the active
-- profile at PLAYER_LOGIN, so disabling this addon simply leaves the (harmless)
-- saved values untouched.
--
-- Off by default, same as every other module's master toggle: a fresh install
-- leaves Blizzard's nameplates completely alone until explicitly turned on.

-- One aura row's settings. A function rather than a table shared by all four
-- rows: core's applyDefaults copies scalars but recurses into tables, so a
-- shared borderColor (or list) would end up as the SAME table on every row, and
-- recolouring one would recolour the lot.
local function auraRowDefaults(y)
    return {
        enabled     = true,
        size        = 20,
        spacing     = 2,
        max         = 8,
        growth      = "center",  -- a value from Data.AURA_GROWTHS below
        x           = 0,
        y           = y,         -- up from the top edge of the health bar
        onlyMine    = false,
        showTimer   = true,
        showStacks  = true,
        timerSize   = 9,
        borderSize  = 1,
        borderColor = { 0.00, 0.00, 0.00 },
        -- [key] = { id = <number|nil>, name = <string|nil>, enabled, duration }
        list        = {},
    }
end

local DEFAULTS = {
    enabled = false,

    general = {
        -- Shared media, applied to every plate regardless of unit type.
        -- "Clean" and "Expressway" come from LibSharedMedia and are only there
        -- if a media pack supplying them is installed; barTexture/fontPath both
        -- fall back to the Blizzard originals when a name can't be resolved, so
        -- this is a preference rather than a dependency.
        texture      = "Clean",
        castTexture  = "Clean",
        font         = "Expressway",
        fontSize     = 9,
        fontOutline  = "OUTLINE",

        -- Per-element overrides of `font` above. Each keeps its own picked font
        -- alongside the flag rather than using nil to mean "off", so unticking
        -- and re-ticking gets the same font back instead of a reset.
        nameFontEnabled   = false,
        nameFont          = "Friz Quadrata TT",
        healthFontEnabled = false,
        healthFont        = "Friz Quadrata TT",
        levelFontEnabled  = false,
        levelFont         = "Friz Quadrata TT",
        borderSize   = 1,
        borderColor  = { 0.00, 0.00, 0.00 },
        bgColor      = { 0.08, 0.08, 0.10 },
        bgAlpha      = 85,     -- %
        scale        = 100,    -- % applied on top of each group's own scale
        alpha        = 100,    -- % base alpha for every plate

        -- Lightens the health bar of whichever plate the cursor is over.
        hoverHighlight = true,
        hoverAlpha     = 40,   -- %

        -- Fades everything that isn't actually fighting you, so a pull you're
        -- tanking stands out from the room it's in.
        dimInactive    = true,
        inactiveAlpha  = 50,   -- % for plates not engaged with you or your group

        -- CVar-backed engine settings. Applied on login and whenever they
        -- change; deferred out of combat when the game refuses them.
        showEnemies  = true,
        showFriends  = false,
        showAll      = true,   -- show plates outside combat too
        maxDistance  = 20,     -- Classic Era caps this at 41 yards
        stacking     = true,   -- nameplateMotion: stacked instead of overlapping
        overlapV     = 110,    -- % vertical spacing when stacking

        -- Pins the engine's own distance and target scaling to 1, so this
        -- module's scale settings are the only thing sizing a plate. On by
        -- default: the engine's scaling compounds with ours, which is not what
        -- anyone means when they set a target scale of 110%.
        constantSize = true,
        -- Snapshot of the scale CVars as they were before the pin, so unticking
        -- gives back what you had. Written by the engine, not a preference.
        savedScaleCVars = nil,
    },

    enemyNPC = {
        enabled       = true,
        width         = 180,
        height        = 22,
        scale         = 100,   -- %
        showName      = true,
        nameSize      = 8,
        -- On the bar rather than above it, which is what the 22px height and the
        -- 15-character truncation below are sized for: the name shares the bar
        -- with the health text, so it has to be small and bounded.
        namePlacement = "innerLeft",  -- a value from Data.NAME_PLACEMENTS below
        nameX         = 0,
        nameY         = 0,
        truncateName  = 15,    -- 0 = never truncate, else max characters
        showLevel     = true,
        showHealthText = true,
        healthFormat  = "bothBracket",  -- a value from Data.HEALTH_FORMATS below
        healthTextAnchor = "RIGHT", -- LEFT | CENTER | RIGHT, against the bar
        healthTextX   = 0,
        healthTextY   = 0,
        showCastBar   = true,
        castHeight    = 10,
        castOffset    = 3,
        castShowIcon  = true,
        castShowName  = true,
        castShowTimer = true,
        castColor     = { 0.90, 0.70, 0.15 },
        castChannelColor = { 0.35, 0.75, 0.95 },
    },

    enemyPlayer = {
        enabled       = true,
        width         = 150,
        height        = 17,
        scale         = 100,
        classColor    = true,   -- health bar takes the class colour
        classColorName = true,  -- so does the name text
        -- Players you can't attack lose the bar entirely and keep just a name.
        nameOnlyWhenSafe = true,
        showName      = true,
        nameSize      = 10,
        -- Matching enemyNPC: on the bar, not above it. A player plate that
        -- labels itself in a different place from every mob plate next to it
        -- reads as two different addons.
        namePlacement = "innerLeft",  -- a value from Data.NAME_PLACEMENTS below
        nameX         = 0,
        nameY         = 0,
        truncateName  = 0,
        showLevel     = true,
        showHealthText = true,
        healthFormat  = "percent",
        healthTextAnchor = "RIGHT",
        healthTextX   = 0,
        healthTextY   = 0,
        showCastBar   = true,
        castHeight    = 10,
        castOffset    = 3,
        castShowIcon  = true,
        castShowName  = true,
        castShowTimer = true,
        castColor     = { 0.90, 0.70, 0.15 },
        castChannelColor = { 0.35, 0.75, 0.95 },
    },

    threat = {
        enabled             = true,
        tankMode            = false,
        combatOnly          = true,  -- only recolour units actually in combat
        overrideNpcColors   = true,  -- threat beats a custom NPC colour…
        overrideOnlyOnAggro = true,  -- …but only once you've actually pulled it
        overrideOnGaining   = true,  -- …counting "about to pull" as pulled too
        colors = {
            -- DPS/healer mode: green = safely off the threat table.
            noThreat   = { 0.25, 0.80, 0.35 },
            gaining    = { 0.95, 0.80, 0.20 },
            aggro      = { 0.90, 0.15, 0.15 },
            -- Sitting on a raid member assigned Main Tank. Deliberately a cool,
            -- desaturated slate: it has to read as "not your problem" at a
            -- glance, which means not competing with the green/amber/red ladder
            -- that everything else on screen is using.
            mainTank   = { 0.45, 0.58, 0.72 },
            -- Tank mode inverts the meaning of the same three states.
            tankSecure = { 0.25, 0.55, 0.95 },
            tankLosing = { 0.95, 0.80, 0.20 },
            tankLost   = { 0.90, 0.15, 0.15 },
        },
        reaction = {
            hostile  = { 0.85, 0.16, 0.16 },
            neutral  = { 0.92, 0.78, 0.20 },
            friendly = { 0.20, 0.75, 0.25 },
            tapped   = { 0.50, 0.50, 0.50 },
        },
    },

    target = {
        enabled        = true,
        highlight      = true,
        highlightColor = { 1.00, 1.00, 1.00 },
        highlightSize  = 2,
        -- Ornament drawn around the targeted plate, picked from
        -- Data.TARGET_INDICATORS below. "None" is the off switch, so this needs
        -- no separate enable flag.
        indicator             = "Pins",
        indicatorColorEnabled = false,   -- each preset carries its own colour
        indicatorColor        = { 0.48, 0.66, 0.88 },
        scale          = 110,   -- % on top of the group scale
        alpha          = 100,   -- % for the targeted plate
        -- Off, with the others at full: the "fade bystanders" setting in general
        -- covers dimming by what's actually fighting you, which is a better
        -- reason to push a plate back than merely not being the current target.
        dimOthers      = false,
        othersAlpha    = 100,   -- % for every other plate while you have a target
        raise          = true,  -- draw the target's plate above the others
    },

    -- Markers hung off the health bar. Each is placed by picking a point on the
    -- bar and nudging the icon's CENTRE from there, so "LEFT, x = -10" reads as
    -- "ten out from the left edge" whatever size the bar is — anchoring the
    -- icon's own matching edge instead would make every offset depend on the
    -- icon's size as well.
    icons = {
        raidMarker = { enabled = true, anchor = "LEFT",  x = -20, y = 0, size = 30 },
        quest      = { enabled = true, anchor = "RIGHT", x =  10, y = 0, size = 14 },
    },

    -- ── Aura tracking ────────────────────────────────────────────────────────
    -- Two independent rows of icons above the health bar, buffs and debuffs,
    -- each with its own whitelist. A whitelist rather than a blacklist because
    -- a nameplate has room for a handful of icons at most: showing everything
    -- and then hiding what you don't want round is the wrong way round at that
    -- size, and in a raid it is the difference between "the two debuffs I care
    -- about" and an unreadable strip.
    --
    -- Both lists start EMPTY, so nothing is drawn until something is added.
    -- That's deliberate — this is a nameplate replacement, not an aura addon,
    -- and switching it on should never paper the screen with icons.
    --
    -- The two rows default to stacking: debuffs just off the bar, buffs a row
    -- above them, so turning both on doesn't pile one on top of the other.
    -- Four independent rows of icons, one per (unit type × buffs/debuffs). The
    -- split is by unit type first because that is where the answers genuinely
    -- differ: the debuffs you have stuck on a boss and what the enemy healer is
    -- running around with are different lists, wanted at different sizes, in
    -- different places, and a single pair of rows could only ever be a
    -- compromise between the two.
    --
    -- Every list starts EMPTY, so nothing is drawn until something is added.
    -- That's deliberate — this is a nameplate replacement, not an aura addon,
    -- and switching it on should never paper the screen with icons.
    --
    -- Within a unit type the two rows default to stacking: debuffs just off the
    -- bar, buffs a row above them, so turning both on doesn't pile one on top
    -- of the other.
    --
    -- Friendly units borrow the matching enemy block, exactly as they borrow
    -- its styling group (see unitKind in the engine).
    --
    -- `fromEvents` is off for NPCs and on for players because that is where the
    -- client differs: debuffs on an NPC come back off the unit fine, and a
    -- hostile player's buffs never do (see the engine's inference block).
    -- Inferring what can be read properly would only be a worse copy of it.
    auras = {
        enabled = true,

        -- Every aura the module has seen on a nameplate, kept so the whitelists
        -- can be filled from a list of things you have actually met rather than
        -- from memory or a database site. Same idea as the auto-detected NPC
        -- list, and on by default for the same reason: a catalogue you have to
        -- switch on before it starts collecting is empty exactly when you first
        -- go looking for it.
        --
        -- Collapsed by spell NAME, not by ID. Ranks would otherwise fill it with
        -- eight rows of the same shout, and the name is what a whitelist entry
        -- made from one of these rows will match on anyway.
        learn = true,
        learned = {
            buffs   = { list = {}, n = 0 },
            debuffs = { list = {}, n = 0 },
        },

        units = {
            enemyPlayer = {
                fromEvents = true,
                buffs      = auraRowDefaults(28),
                debuffs    = auraRowDefaults(4),
            },
            enemyNPC = {
                fromEvents = false,
                buffs      = auraRowDefaults(28),
                debuffs    = auraRowDefaults(4),
            },
        },
    },

    -- [npcID] = { name, zone, rename, enabled, color = {r,g,b}, auto }
    npcs    = {},
    autoAdd = true,
    npcSeed = 0,
}

addon.RegisterDefaults("nameplates", DEFAULTS)

-- ── Health text formats ──────────────────────────────────────────────────────
-- One ordered list drives both the dropdown and the engine, so a format can't
-- exist in one and not the other.
--
-- The label IS the example. "Current + percent" tells you less about what ends
-- up on the bar than "6.7k  100%" does, and the whole reason to have six of
-- these is that the difference between them is purely how they look.
--
-- `build` takes the already-shortened numbers rather than the raw ones: the
-- engine owns how 6723 becomes "6.7k", and a format that re-derived that would
-- be free to disagree with the others.
--
-- The first four values are the ones that shipped originally, kept spelled
-- exactly as they were so existing profiles keep the format they chose.
Data.HEALTH_FORMATS = {
    { value = "percent",     label = "100%",        build = function(_, p) return p .. "%" end },
    { value = "current",     label = "6.7k",        build = function(c) return c end },
    { value = "both",        label = "6.7k  100%",  build = function(c, p) return c .. "  " .. p .. "%" end },
    { value = "bothPipe",    label = "6.7k | 100%", build = function(c, p) return c .. " | " .. p .. "%" end },
    { value = "bothBracket", label = "6.7k [100%]", build = function(c, p) return c .. " [" .. p .. "%]" end },
    { value = "bothParen",   label = "6.7k (100%)", build = function(c, p) return c .. " (" .. p .. "%)" end },
    { value = "bothDash",    label = "6.7k - 100%", build = function(c, p) return c .. " - " .. p .. "%" end },
    { value = "currentMax",  label = "6.7k / 8.2k", build = function(c, _, m) return c .. " / " .. m end },
    { value = "none",        label = "Hidden",      build = function() return "" end },
}

Data.HEALTH_FORMAT_BY_VALUE = {}
for _, e in ipairs(Data.HEALTH_FORMATS) do
    Data.HEALTH_FORMAT_BY_VALUE[e.value] = e
end

-- ── Name placement ───────────────────────────────────────────────────────────
-- Where the unit's name sits relative to the health bar. Each entry is the pair
-- of anchor points that puts it there, plus the justification that matches — a
-- name anchored by its right edge and left-justified drifts away from its anchor
-- as the text gets shorter, so the two are never picked independently.
--
-- `dx`/`dy` are the built-in breathing room, not a preference: "above" wants a
-- few pixels of gap or the text sits on the border, and the inner placements
-- want an inset so the text isn't flush against the bar's outline. The user's
-- own nudge is added on top of these.
--
-- `row` is what the layout code needs to know beyond the anchoring: whether the
-- name is sharing the strip above the bar with the level text (and so has to
-- leave room for it), or is on the bar itself (and is bounded by it).
Data.NAME_PLACEMENTS = {
    { value = "aboveLeft",   label = "Above — left",   point = "BOTTOMLEFT",  rel = "TOPLEFT",     justify = "LEFT",   row = "above", dx =  0, dy =  3 },
    { value = "aboveCenter", label = "Above — centre", point = "BOTTOM",      rel = "TOP",         justify = "CENTER", row = "above", dx =  0, dy =  3 },
    { value = "aboveRight",  label = "Above — right",  point = "BOTTOMRIGHT", rel = "TOPRIGHT",    justify = "RIGHT",  row = "above", dx =  0, dy =  3 },
    { value = "innerLeft",   label = "Inner — left",   point = "LEFT",        rel = "LEFT",        justify = "LEFT",   row = "inner", dx =  3, dy =  0 },
    { value = "innerCenter", label = "Inner — centre", point = "CENTER",      rel = "CENTER",      justify = "CENTER", row = "inner", dx =  0, dy =  0 },
    { value = "innerRight",  label = "Inner — right",  point = "RIGHT",       rel = "RIGHT",       justify = "RIGHT",  row = "inner", dx = -3, dy =  0 },
    { value = "belowLeft",   label = "Below — left",   point = "TOPLEFT",     rel = "BOTTOMLEFT",  justify = "LEFT",   row = "below", dx =  0, dy = -3 },
    { value = "belowCenter", label = "Below — centre", point = "TOP",         rel = "BOTTOM",      justify = "CENTER", row = "below", dx =  0, dy = -3 },
    { value = "belowRight",  label = "Below — right",  point = "TOPRIGHT",    rel = "BOTTOMRIGHT", justify = "RIGHT",  row = "below", dx =  0, dy = -3 },
}

Data.NAME_PLACEMENT_BY_VALUE = {}
for _, e in ipairs(Data.NAME_PLACEMENTS) do
    Data.NAME_PLACEMENT_BY_VALUE[e.value] = e
end

function Data.NamePlacement(value)
    return Data.NAME_PLACEMENT_BY_VALUE[value or "aboveLeft"]
        or Data.NAME_PLACEMENT_BY_VALUE.aboveLeft
end

-- ── Target indicators ────────────────────────────────────────────────────────
-- Ornaments placed around the targeted plate's health bar, ported from the
-- preset table in ClassicNameplatesPlus (which took them from Plater), so the
-- looks are the familiar ones.
--
-- `coords` decides the shape: four entries are drawn one per corner (top-left,
-- bottom-left, bottom-right, top-right, in that order), two entries are drawn at
-- the left and right edges. Some coord pairs run high→low on purpose — that
-- mirrors the crop, which is how one piece of art serves all four corners.
-- `x`/`y` push each piece outwards from its anchor, and scale with the art.
--
-- Sizes are in the art's own units, not pixels: `autoScale` measures them
-- against the health bar's height so an indicator keeps its proportions at any
-- nameplate size, while `scale` pins a fixed multiplier instead.
--
-- Every preset here crops art the game itself ships, so this module needs no
-- media files of its own. ClassicNameplatesPlus's three Arrow presets are
-- deliberately absent: those read .tga files out of that addon's media folder,
-- and this module doesn't carry them.
Data.TARGET_INDICATORS = {
    ["Magneto"] = {
        path   = "Interface\\Artifacts\\RelicIconFrame",
        coords = { {0, .5, 0, .5}, {0, .5, .5, 1}, {.5, 1, .5, 1}, {.5, 1, 0, .5} },
        width = 8, height = 10,
        autoScale = true,
        x = 2, y = 2,
    },

    ["Gray Bold"] = {
        path   = "Interface\\ContainerFrame\\UI-Icon-QuestBorder",
        coords = { {0, .5, 0, .5}, {0, .5, .5, 1}, {.5, 1, .5, 1}, {.5, 1, 0, .5} },
        desaturated = true,
        width = 10, height = 10,
        autoScale = true,
        x = 2, y = 2,
    },

    ["Pins"] = {
        path   = "Interface\\ITEMSOCKETINGFRAME\\UI-ItemSockets",
        coords = {
            {145/256, 161/256,  3/256, 19/256},
            {145/256, 161/256, 19/256,  3/256},
            {161/256, 145/256, 19/256,  3/256},
            {161/256, 145/256,  3/256, 19/256},
        },
        desaturated = true,
        width = 4, height = 4,
        x = 2, y = 2,
    },

    ["Silver"] = {
        path   = "Interface\\PETBATTLES\\PETBATTLEHUD",
        coords = {
            {848/1024, 868/1024, 454/512, 474/512},
            {848/1024, 868/1024, 474/512, 495/512},
            {868/1024, 889/1024, 474/512, 495/512},
            {868/1024, 889/1024, 454/512, 474/512},
        },
        width = 6, height = 6,
        autoScale = true,
        x = 1, y = 1,
    },

    ["Ornament"] = {
        path   = "Interface\\PETBATTLES\\PETJOURNAL",
        coords = {
            {124/512, 161/512, 71/1024, 99/1024},
            {119/512, 156/512, 29/1024, 57/1024},
        },
        width = 18, height = 12,
        wscale = 1, hscale = 1.2,
        autoScale = true,
        x = 14, y = 0,
    },

    ["Golden"] = {
        path   = "Interface\\Artifacts\\Artifacts",
        coords = {
            {137/1024, (137 + 29)/1024, 920/1024, 978/1024},
            {(137 + 30)/1024, 195/1024, 920/1024, 978/1024},
        },
        width = 8, height = 12,
        wscale = 1, hscale = 1.2,
        autoScale = true,
        x = 0, y = 0,
    },

    ["Ornament Gray"] = {
        path   = "Interface\\Challenges\\challenges-besttime-bg",
        coords = {
            { 89/512, 123/512, 0, 1},
            {123/512,  89/512, 0, 1},
        },
        width = 8, height = 12,
        alpha = 0.7,
        wscale = 1, hscale = 1.2,
        autoScale = true,
        x = 0, y = 0,
        color = "red",
    },

    ["Epic"] = {
        path   = "Interface\\UNITPOWERBARALT\\WowUI_Horizontal_Frame",
        coords = {
            {30/256, 40/256, 15/64, 49/64},
            {40/256, 30/256, 15/64, 49/64},
        },
        width = 6, height = 12,
        wscale = 1, hscale = 1.2,
        autoScale = true,
        x = 3, y = 0,
        blend = "ADD",
    },
}

-- pairs() has no order, and a picker that reshuffles itself every login is
-- unusable. "None" is the real off switch, so it leads.
Data.TARGET_INDICATOR_ORDER = {
    "None",
    "Magneto", "Gray Bold", "Pins", "Silver",
    "Ornament", "Golden", "Ornament Gray", "Epic",
}

-- Named preset colours. Only these two are used above; anything unrecognised
-- falls back to white.
Data.INDICATOR_COLORS = {
    white = { 1, 1, 1 },
    red   = { 1, 0, 0 },
}

-- ── Aura tracking ────────────────────────────────────────────────────────────
-- Which way a row of icons grows out of its anchor point. "Centred" keeps the
-- whole strip centred on the bar and widens both ways; the other two pin the
-- FIRST icon to one edge and add the rest behind it, so the icon you look at
-- first never moves as auras come and go.
-- `short` is what a half-width column's dropdown can actually show. The long
-- form says what each one does and is the one worth reading once; the short
-- form is the one you pick from afterwards.
Data.AURA_GROWTHS = {
    { value = "center", label = "Centred — grows both ways",      short = "Centred"    },
    { value = "right",  label = "From the left edge, rightwards", short = "Rightwards" },
    { value = "left",   label = "From the right edge, leftwards", short = "Leftwards"  },
}

Data.AURA_GROWTH_BY_VALUE = {}
for _, e in ipairs(Data.AURA_GROWTHS) do Data.AURA_GROWTH_BY_VALUE[e.value] = e end

function Data.AuraGrowth(value)
    if value and Data.AURA_GROWTH_BY_VALUE[value] then return value end
    return "center"
end

-- The unit types aura tracking can be switched on and off for, and the settings
-- block behind each. Ordered, because it drives the tabs.
Data.AURA_UNITS = {
    { key = "enemyNPC",    label = "Enemy NPCs"    },
    { key = "enemyPlayer", label = "Enemy Players" },
}

-- The four unit kinds the engine sorts plates into, folded onto the two blocks
-- above — friendly units borrow the matching enemy block the same way they
-- borrow its styling group.
Data.AURA_UNIT_FOR_KIND = {
    enemyPlayer    = "enemyPlayer",
    friendlyPlayer = "enemyPlayer",
    enemyNPC       = "enemyNPC",
    friendlyNPC    = "enemyNPC",
}

-- Name and icon for a spell ID *or* a spell name. Classic Era still has the
-- global getters, but C_Spell is what newer builds expect, so prefer it and
-- fall back — a client with neither costs this feature and nothing else.
function Data.SpellInfo(key)
    if not key then return nil end
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, key)
        if ok and info and info.name then return info.name, info.iconID end
    end
    if GetSpellInfo then
        local ok, name, _, icon = pcall(GetSpellInfo, key)
        if ok and name then return name, icon end
    end
    return nil
end

-- The unit-type block ("enemyPlayer" / "enemyNPC"), created on demand so a
-- profile that predates this feature doesn't need a login to grow one.
function Data.AuraUnit(unitKey)
    local d = Data.Get()
    if not d then return nil end
    d.auras = d.auras or {}
    d.auras.units = d.auras.units or {}
    d.auras.units[unitKey] = d.auras.units[unitKey] or {}
    return d.auras.units[unitKey]
end

-- The live settings block for one row: a unit type and one of "buffs" /
-- "debuffs". All four are independent, right down to the whitelist.
function Data.AuraOpts(unitKey, which)
    local u = Data.AuraUnit(unitKey)
    if not u then return nil end
    u[which] = u[which] or {}
    local o = u[which]
    o.list = o.list or {}
    return o
end

function Data.AuraList(unitKey, which)
    local o = Data.AuraOpts(unitKey, which)
    return o and o.list or nil
end

-- ── Migration: one pair of rows to four ──────────────────────────────────────
-- The buffs/debuffs settings used to live at auras.buffs and auras.debuffs and
-- apply to every nameplate. Splitting them by unit type would otherwise throw
-- away whatever was already whitelisted, so the old block is copied onto BOTH
-- unit types and then removed. Copied rather than moved because there is no
-- basis for guessing which type the entries were meant for — they applied to
-- everything, so they keep applying to everything.
--
-- Self-limiting with no version flag: the old keys are gone afterwards and
-- DEFAULTS no longer carries them, so applyDefaults can't put them back.
--
-- The test for "has this profile already been split" is whether the target row
-- has a whitelist of its own, NOT whether it exists. It always exists by the
-- time this runs: core's applyDefaults has been over the profile first and has
-- filled every new row in with the shipped defaults, so an "is it there yet"
-- check would answer yes on exactly the profiles that still need migrating —
-- and the entries would then be deleted along with the old block.
local function copyDeep(src)
    if type(src) ~= "table" then return src end
    local out = {}
    for k, v in pairs(src) do out[k] = copyDeep(v) end
    return out
end

function Data.MigrateAuras()
    local d = Data.Get()
    local a = d and d.auras
    if not a then return end
    if not (type(a.buffs) == "table" or type(a.debuffs) == "table") then return end

    a.units = a.units or {}
    for _, def in ipairs(Data.AURA_UNITS) do
        local u = a.units[def.key] or {}
        a.units[def.key] = u
        -- The one flag of the intermediate shape that survives applyDefaults
        -- (nothing in the new defaults refills it), and the only one worth
        -- carrying: a unit type switched off entirely is now both its rows off.
        local typeOff = (u.enabled == false)

        for _, which in ipairs({ "buffs", "debuffs" }) do
            if type(u[which]) ~= "table" then u[which] = {} end
            local row = u[which]
            row.list = row.list or {}

            local old = a[which]
            if type(old) == "table" and next(row.list) == nil then
                for k, v in pairs(old) do
                    if k ~= "list" then row[k] = copyDeep(v) end
                end
                row.list = copyDeep(old.list or {})
            end

            if typeOff then row.enabled = false end
        end
        u.enabled = nil
    end

    a.buffs, a.debuffs = nil, nil
    Data.InvalidateAuras()
end

-- One whitelist entry is keyed by what it matches on: the spell ID as a string
-- for a numeric entry, the lowercased spell name for a written one. Keying on
-- the *matching* form is what stops "Rend" and "rend" becoming two rows that
-- both fire on the same aura.
function Data.AuraKeyFor(text)
    if type(text) == "number" then text = tostring(text) end
    if type(text) ~= "string" then return nil end
    text = text:match("^%s*(.-)%s*$") or ""
    if text == "" then return nil end
    local id = tonumber(text)
    if id then
        if id <= 0 or id ~= math.floor(id) then return nil end
        return tostring(id), id, nil
    end
    return text:lower(), nil, text
end

-- Adds a spell to one of the whitelists. `text` is whatever was typed: a spell
-- ID or a spell name, since both are things people have to hand (an ID off a
-- database site, a name off the combat log). Returns the entry, or nil plus a
-- message to show.
--
-- The messages are terse because of where they land: a half-width column has
-- room for one short line beside the search box and nothing more.
function Data.AddAura(unitKey, which, text)
    local list = Data.AuraList(unitKey, which)
    if not list then return nil, "Not ready yet." end

    local key, id, name = Data.AuraKeyFor(text)
    if not key then return nil, "Type a name or ID." end
    if list[key] then return nil, "Already on the list." end

    local entry = { enabled = true, id = id, name = name }
    -- An ID is resolvable to a name only if the client has that spell cached,
    -- which it usually does for anything you have seen. Left nil otherwise and
    -- backfilled by Data.AuraDisplay the next time the list is drawn.
    if id then entry.name = (Data.SpellInfo(id)) end

    -- Seeded from the catalogue when the module has already met this spell. Not
    -- an optimisation: without it a name added straight off the Learned tab
    -- shows a question mark on the very list you just added it to, while the
    -- page you added it from displays it perfectly — because the icon lives on
    -- the catalogue record and the new entry was built without one.
    local rec = Data.LearnedFor(entry.name or name, which)
    if rec then
        entry.icon = entry.icon or rec.icon
        if rec.ids then
            entry.seen = entry.seen or {}
            for seenID in pairs(rec.ids) do entry.seen[seenID] = true end
        end
    end

    list[key] = entry
    Data.InvalidateAuras()
    return entry
end

function Data.RemoveAura(unitKey, which, key)
    local list = Data.AuraList(unitKey, which)
    if list and key then
        list[key] = nil
        Data.InvalidateAuras()
    end
end

-- How long the aura lasts, in seconds, for the one case where the game won't
-- say: an aura the engine had to infer from events rather than read off the
-- unit. Nothing to do with real auras — those carry their own duration, and it
-- always wins. Blank (nil) means "no idea", which draws the icon with no swipe
-- and no countdown rather than a made-up one.
Data.AURA_DURATION_MAX = 3600

function Data.SetAuraDuration(unitKey, which, key, text)
    local list = Data.AuraList(unitKey, which)
    local entry = list and key and list[key]
    if not entry then return nil end

    local seconds = tonumber(text)
    if seconds and seconds > 0 then
        entry.duration = math.min(Data.AURA_DURATION_MAX, math.floor(seconds + 0.5))
    else
        entry.duration = nil
    end
    Data.InvalidateAuras()
    return entry.duration
end

-- ── Learning what a name matches ─────────────────────────────────────────────
-- The client will only resolve a spell NAME that is in your own spellbook, and
-- the effects worth watching on an enemy are exactly the ones that aren't: a
-- triggered stun like "Intercept Stun", another class's shout, a rank you have
-- never trained. So a by-name entry starts with no ID and no art, and there is
-- no table anywhere that could give it one.
--
-- What there is, is the aura itself. Every time the engine matches a name entry
-- against a real aura it has both the spell ID and the icon in hand, and writes
-- them back here. The entry teaches itself, once, the first time the thing it is
-- watching for actually turns up — and because entries live in saved variables,
-- it stays taught.
--
-- Every ID is kept, not just the first: matching by name is a deliberate "every
-- rank of this", and which ranks that turned out to mean is the one thing the
-- entry can't otherwise tell you.
function Data.NoteAuraSeen(entry, spellID, icon)
    if type(entry) ~= "table" or type(spellID) ~= "number" then return false end

    if icon and not entry.icon then entry.icon = icon end

    entry.seen = entry.seen or {}
    if entry.seen[spellID] then return false end
    entry.seen[spellID] = true
    return true
end

-- The IDs this entry has been seen to match, lowest first. Sorted here rather
-- than stored in order: it's read when a tooltip opens and written in the
-- middle of a combat scan, so the cost belongs on the reader.
function Data.AuraSeenIDs(entry)
    local out = {}
    if type(entry) == "table" and entry.seen then
        for id in pairs(entry.seen) do out[#out + 1] = id end
        table.sort(out)
    end
    return out
end

-- What the settings list shows for a row: a readable name and an icon. Both are
-- derived rather than stored for ID entries, and the resolved name is written
-- back so an entry added before the client knew the spell stops being "Spell
-- 12345" once it does.
function Data.AuraDisplay(entry)
    if type(entry) ~= "table" then return "", nil end
    local lookupKey = entry.id or entry.name
    local name, icon = Data.SpellInfo(lookupKey)
    if name and entry.id and entry.name ~= name then entry.name = name end

    -- Whatever the client wouldn't give us, taken from what the entry has
    -- learned instead. The stored icon covers the usual case; the walk over the
    -- seen IDs is for an entry that learned an ID before this code existed, or
    -- one whose art the client had not cached at the moment it was recorded.
    if not icon then
        icon = entry.icon
        if not icon and entry.seen then
            for id in pairs(entry.seen) do
                local _, learned = Data.SpellInfo(id)
                if learned then
                    entry.icon = learned
                    icon = learned
                    break
                end
            end
        end
        -- Last resort, and the one that catches entries added before any of
        -- this existed: the catalogue may well have met the spell even though
        -- this entry never has. Cached onto the entry so it survives the
        -- catalogue being cleared.
        if not icon then
            local rec = Data.LearnedFor(entry.name)
            if rec and rec.icon then
                entry.icon = rec.icon
                icon = rec.icon
            end
        end
    end

    return entry.name or name or (entry.id and ("Spell " .. entry.id)) or "", icon
end

-- Sorted by name (then key for the nameless), enabled rows first — same shape
-- and the same reasoning as Data.SortedNpcs.
function Data.SortedAuras(unitKey, which, filter)
    local list = Data.AuraList(unitKey, which)
    local out = {}
    if not list then return out end
    filter = filter and filter ~= "" and filter:lower() or nil
    for key, entry in pairs(list) do
        local name = Data.AuraDisplay(entry)
        local ok = true
        if filter then
            ok = ((name or "") .. " " .. key):lower():find(filter, 1, true) ~= nil
        end
        if ok then out[#out + 1] = { key = key, entry = entry, name = name or "" } end
    end
    table.sort(out, function(a, b)
        local ae, be = a.entry.enabled and true or false, b.entry.enabled and true or false
        if ae ~= be then return ae end
        if a.name ~= b.name then return a.name < b.name end
        return a.key < b.key
    end)
    return out
end

-- ── Learned aura catalogue ───────────────────────────────────────────────────
-- What the module has seen, as opposed to what it has been told to watch for.
-- The whitelists answer "show me this"; this answers "what is there to ask
-- for", which is the question you actually have when a debuff you want has no
-- name you can spell and no ID you can find.
--
-- Capped, because a raid night meets more auras than anyone will scroll
-- through, and an unbounded saved variable is a saved variable that eventually
-- becomes a problem. Once full it stops taking NEW names but keeps filling in
-- extra ranks and missing art for the ones it has.
Data.LEARNED_CAP = 400

function Data.LearnedBucket(which)
    local d = Data.Get()
    if not d then return nil end
    d.auras = d.auras or {}
    d.auras.learned = d.auras.learned or {}
    local b = d.auras.learned[which]
    if not b then
        b = { list = {}, n = 0 }
        d.auras.learned[which] = b
    end
    b.list = b.list or {}
    b.n = b.n or 0
    return b
end

-- Returns true when something was actually recorded, so the caller can tell an
-- open settings list to redraw. False is the overwhelmingly common answer —
-- this is called for every aura on every plate — and costs a hash lookup.
function Data.NoteLearnedAura(which, spellID, name, icon)
    if type(name) ~= "string" or name == "" then return false end
    local b = Data.LearnedBucket(which)
    if not b then return false end

    local key = name:lower()
    local rec = b.list[key]
    if not rec then
        if b.n >= Data.LEARNED_CAP then return false end
        rec = { name = name, ids = {} }
        b.list[key] = rec
        b.n = b.n + 1
    end

    local learned = false
    if type(spellID) == "number" and not rec.ids[spellID] then
        rec.ids[spellID] = true
        learned = true
    end
    -- Only chased while it's still missing: the combat log carries no art, so
    -- an entry first met there has to resolve its own, and an entry met on a
    -- plate arrives with one already.
    if not rec.icon then
        rec.icon = icon or select(2, Data.SpellInfo(spellID or name))
        if rec.icon then learned = true end
    end
    return learned
end

function Data.ClearLearned(which)
    local b = Data.LearnedBucket(which)
    if not b then return end
    b.list = {}
    b.n = 0
end

-- The catalogue's record for a spell name, whichever list it landed in. This is
-- how a whitelist entry gets art for a spell the client will not look up by
-- name: the module has already met it, written down what it looked like, and
-- the two are only keyed apart by which table they are in.
--
-- `which` is a preference, not a filter — a name that exists as both a buff and
-- a debuff should answer with the one being asked about, but either record's
-- icon beats no icon at all.
function Data.LearnedFor(name, which)
    if type(name) ~= "string" or name == "" then return nil end
    local key = name:lower()

    if which then
        local b = Data.LearnedBucket(which)
        local rec = b and b.list[key]
        if rec then return rec end
    end
    for _, kind in ipairs({ "buffs", "debuffs" }) do
        if kind ~= which then
            local b = Data.LearnedBucket(kind)
            local rec = b and b.list[key]
            if rec then return rec end
        end
    end
    return nil
end

function Data.LearnedIDs(rec)
    local out = {}
    if type(rec) == "table" and rec.ids then
        for id in pairs(rec.ids) do out[#out + 1] = id end
        table.sort(out)
    end
    return out
end

-- Sorted by name, same as the whitelists, so the two lists read alike. `filter`
-- matches the name and any of the IDs, because "I know it was 25289" is as
-- likely to be what you have as the name is.
function Data.SortedLearned(which, filter)
    local b = Data.LearnedBucket(which)
    local out = {}
    if not b then return out end
    filter = filter and filter ~= "" and filter:lower() or nil

    for key, rec in pairs(b.list) do
        local ok = true
        if filter then
            ok = key:find(filter, 1, true) ~= nil
            if not ok then
                for id in pairs(rec.ids or {}) do
                    if tostring(id):find(filter, 1, true) then ok = true; break end
                end
            end
        end
        if ok then out[#out + 1] = { key = key, rec = rec } end
    end

    table.sort(out, function(a, b2) return a.key < b2.key end)
    return out
end

-- ── Match lookup ─────────────────────────────────────────────────────────────
-- The engine tests every aura on every tracked plate against these, so they are
-- built once into flat maps rather than walked per aura. Rebuilt lazily after
-- any edit (and after a profile switch, which the engine's refresh invalidates
-- through), so nothing has to diff the list.
local auraCache = {}

function Data.InvalidateAuras()
    auraCache = {}
end

function Data.AuraLookup(unitKey, which)
    local byUnit = auraCache[unitKey]
    if not byUnit then
        byUnit = {}
        auraCache[unitKey] = byUnit
    end
    local cached = byUnit[which]
    if cached then return cached end

    -- The maps hold the ENTRY rather than `true`: a match still answers "is this
    -- tracked" by being non-nil, and event-inferred auras need the entry's
    -- duration, which a boolean threw away.
    local out = { byID = {}, byName = {}, count = 0 }
    for key, entry in pairs(Data.AuraList(unitKey, which) or {}) do
        if entry.enabled ~= false then
            if entry.id then
                out.byID[entry.id] = entry
            else
                out.byName[key] = entry   -- the key IS the lowercased name
            end
            out.count = out.count + 1
        end
    end
    byUnit[which] = out
    return out
end

-- ── Seeded NPC list ──────────────────────────────────────────────────────────
-- The starting set of tagged raid mobs. Seeded ONCE per profile (tracked by
-- npcSeed) rather than living in DEFAULTS: core's applyDefaults refills any
-- missing key on every login, so a seeded-through-defaults entry the user
-- deleted would silently come back the next time they logged in.
Data.SEED_VERSION = 1

local SEED = {
    { id = 16142, name = "Bile Sludge",            zone = "Naxxramas",        color = "magenta" },
    { id = 12458, name = "Blackwing Taskmaster",   zone = "Blackwing Lair",   color = "magenta" },
    { id = 12468, name = "Death Talon Hatcher",    zone = "Blackwing Lair",   color = "magenta" },
    { id = 16451, name = "Deathknight Vindicator", zone = "Naxxramas",        color = "magenta", rename = "Vindicator" },
    { id = 15953, name = "Grand Widow Faerlina",   zone = "Naxxramas",        color = "magenta", rename = "Faerlina"   },
    { id = 16385, name = "Lightning Totem",        zone = "Naxxramas",        color = "magenta" },
    { id = 16021, name = "Living Monstrosity",     zone = "Naxxramas",        color = "magenta", rename = "Monstrosity" },
    { id = 16297, name = "Mutated Grub",           zone = "Naxxramas",        color = "magenta", rename = "Grub"        },
    { id = 16505, name = "Naxxramas Follower",     zone = "Naxxramas",        color = "magenta", rename = "Follower"    },
    { id = 16453, name = "Necro Stalker",          zone = "Naxxramas",        color = "magenta" },
    { id = 16034, name = "Plague Beast",           zone = "Naxxramas",        color = "magenta" },
    { id = 16193, name = "Skeletal Smith",         zone = "Naxxramas",        color = "magenta", rename = "Smith" },
    { id = 15229, name = "Vekniss Soldier",        zone = "Ahn'Qiraj Temple", color = "magenta" },
    { id = 15976, name = "Venom Stalker",          zone = "Naxxramas",        color = "magenta" },
}

-- The module's settings block, or nil before core has resolved a profile.
function Data.Get()
    return addon.db and addon.db.settings and addon.db.settings.nameplates
end

-- Fills a profile that has never been seeded with the starting NPC list. Safe
-- to call as often as you like — it's a no-op once npcSeed has caught up, which
-- is what makes deleting a seeded entry stick. Called on login AND from
-- refresh(), so a profile created/imported later gets seeded on the switch
-- rather than only at the next login.
function Data.EnsureSeeded()
    local d = Data.Get()
    if not d then return end
    d.npcs = d.npcs or {}
    if (d.npcSeed or 0) >= Data.SEED_VERSION then return end
    for _, e in ipairs(SEED) do
        if not d.npcs[e.id] then
            d.npcs[e.id] = {
                name    = e.name,
                zone    = e.zone,
                rename  = e.rename,
                enabled = true,
                color   = Data.ColorByName(e.color),
            }
        end
    end
    d.npcSeed = Data.SEED_VERSION
end

function Data.GetNpc(npcID)
    local d = Data.Get()
    return npcID and d and d.npcs and d.npcs[npcID] or nil
end

-- The colour this NPC should paint its health bar, or nil when the entry is
-- absent, switched off, or has no colour of its own (auto-detected entries
-- start colourless — they're a record that you've seen the mob, not a rule).
function Data.GetNpcColor(npcID)
    local e = Data.GetNpc(npcID)
    if e and e.enabled and type(e.color) == "table" then return e.color end
    return nil
end

-- The rename to show instead of the real name, or nil to leave it alone.
function Data.GetNpcName(npcID)
    local e = Data.GetNpc(npcID)
    if e and e.enabled and e.rename and e.rename ~= "" then return e.rename end
    return nil
end

-- Records an NPC the engine has just seen for the first time. New entries land
-- switched off and colourless so simply walking through a zone never changes
-- how anything looks — they're there to be picked out of the list later.
-- Returns true only when a genuinely new row was added, so the caller can
-- refresh an open settings list without diffing the whole table.
function Data.Remember(npcID, name, zone)
    local d = Data.Get()
    if not (d and npcID and name and name ~= "") then return false end
    d.npcs = d.npcs or {}

    local e = d.npcs[npcID]
    if e then
        -- Backfill what a hand-added (ID-only) entry is missing, but never
        -- touch the user's own rename/colour/enabled choices.
        if not e.name or e.name == "" then e.name = name end
        if (not e.zone or e.zone == "") and zone and zone ~= "" then e.zone = zone end
        return false
    end

    if not d.autoAdd then return false end
    d.npcs[npcID] = { name = name, zone = zone or "", enabled = false, auto = true }
    return true
end

function Data.RemoveNpc(npcID)
    local d = Data.Get()
    if d and d.npcs then d.npcs[npcID] = nil end
end

-- Drops every entry that was auto-detected and never configured. Deliberately
-- keeps anything the user has enabled, renamed or coloured, even if it was
-- auto-added — otherwise "clear the noise" would also throw away their work.
-- Returns how many rows went.
function Data.ClearAutoNpcs()
    local d = Data.Get()
    if not (d and d.npcs) then return 0 end
    local removed = 0
    for id, e in pairs(d.npcs) do
        if e.auto and not e.enabled and not e.color and (not e.rename or e.rename == "") then
            d.npcs[id] = nil
            removed = removed + 1
        end
    end
    return removed
end

-- Sorted by name (then ID for the nameless), matching the settings list's own
-- ordering. `filter` is an optional lowercase substring matched against the
-- name, the rename, the zone and the ID.
function Data.SortedNpcs(filter)
    local d = Data.Get()
    local out = {}
    if not (d and d.npcs) then return out end
    filter = filter and filter ~= "" and filter:lower() or nil
    for id, e in pairs(d.npcs) do
        local ok = true
        if filter then
            local hay = ((e.name or "") .. " " .. (e.rename or "") .. " "
                .. (e.zone or "") .. " " .. tostring(id)):lower()
            ok = hay:find(filter, 1, true) ~= nil
        end
        if ok then out[#out + 1] = { id = id, entry = e } end
    end
    -- Enabled first. The list fills up with auto-detected mobs you will never
    -- touch, and the handful you have actually configured are the ones you come
    -- back to edit — so they go to the top rather than being scattered through
    -- alphabetically. Within each half it's still name, then ID as the
    -- tie-break, so the order is stable across rebuilds.
    table.sort(out, function(a, b)
        local ae, be = a.entry.enabled and true or false, b.entry.enabled and true or false
        if ae ~= be then return ae end
        local an, bn = a.entry.name or "", b.entry.name or ""
        if an ~= bn then return an < bn end
        return a.id < b.id
    end)
    return out
end

-- ── Export / import ──────────────────────────────────────────────────────────
-- Reuses core's serializer (see EncodeTable/DecodeTable in Core.lua) so an NPC
-- list is a single pasteable line, and pasting a profile string into the NPC box
-- (or the other way round) is rejected outright by the prefix rather than
-- half-applied.
local NPC_PREFIX = "DrievNameplateNPCs1:"

function Data.ExportNpcs()
    local d = Data.Get()
    if not (d and d.npcs) then return nil, "Nothing to export yet." end
    local payload = {}
    local count = 0
    for id, e in pairs(d.npcs) do
        -- Auto-detected, never-configured rows are local noise, not something
        -- worth shipping to someone else.
        if e.enabled or e.color or (e.rename and e.rename ~= "") then
            payload[id] = { name = e.name, zone = e.zone, rename = e.rename,
                            enabled = e.enabled, color = e.color }
            count = count + 1
        end
    end
    if count == 0 then return nil, "No configured NPCs to export." end
    return addon.EncodeTable(NPC_PREFIX, payload)
end

-- Merges an imported list in. Existing rows are overwritten (an import is an
-- explicit "use these"), rows not mentioned are left alone. Returns how many
-- entries were applied, or nil + a message.
function Data.ImportNpcs(str)
    local d = Data.Get()
    if not d then return nil, "Settings aren't ready yet." end
    local incoming, err = addon.DecodeTable(NPC_PREFIX, str)
    if not incoming then return nil, err or "That doesn't look like an NPC list string." end

    d.npcs = d.npcs or {}
    local applied = 0
    for id, e in pairs(incoming) do
        id = tonumber(id)
        if id and type(e) == "table" then
            d.npcs[id] = {
                name    = e.name or (d.npcs[id] and d.npcs[id].name),
                zone    = e.zone or (d.npcs[id] and d.npcs[id].zone),
                rename  = e.rename,
                enabled = e.enabled and true or false,
                color   = type(e.color) == "table"
                    and { e.color[1] or 1, e.color[2] or 1, e.color[3] or 1 } or nil,
            }
            applied = applied + 1
        end
    end
    if applied == 0 then return nil, "That string didn't contain any NPCs." end
    return applied
end
