-- Nameplates module: saved settings and the NPC registry. Split out from the
-- engine and the settings UI so both share one definition of the defaults, the
-- seeded NPC list and the per-NPC colour helpers.
local addon = _G.DrievEssentials
if not addon then return end

local Data = {}
addon.NameplatesData = Data

-- ── Named color palette ─────────────────────────────────────────────────────
-- The NPC list's "Select Color" column picks from these by name, but every entry
-- stores a plain {r, g, b}, so a colour picked freehand from the swatch is just
-- as valid.
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

-- Returns a FRESH copy: callers store the result straight into SavedVariables,
-- and handing out the palette's own table would make every NPC coloured
-- "magenta" share (and then mutate) one table.
function Data.ColorByName(name)
    local rgb = byName[name] or byName.white
    return { rgb[1], rgb[2], rgb[3] }
end

-- Reverse lookup for the list's color column: the palette name whose triple
-- matches, or nil for a color the user picked freehand out of the swatch.
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
-- Registered into core's defaults at load and merged at PLAYER_LOGIN. Off by
-- default, like every module's master toggle.

-- A function rather than a table shared by all four rows: core's applyDefaults
-- copies scalars but recurses into tables, so a shared borderColor (or list)
-- would be the SAME table on every row and recolouring one would recolour all.
local function auraRowDefaults(y, size)
    return {
        enabled     = true,
        size        = size,
        spacing     = 2,
        max         = 8,
        growth      = "center",  -- a value from Data.AURA_GROWTHS below
        x           = 0,
        y           = y,         -- up from the top edge of the health bar
        onlyMine    = false,
        -- Off: at this icon size the swipe alone says how long is left, and a
        -- number on top of it is one more thing in the middle of a pull.
        showTimer   = false,
        showStacks  = true,
        timerSize   = 9,
        borderSize  = 1,
        borderColor = { 0.00, 0.00, 0.00 },
        -- [key] = { id = <number|nil>, name = <string|nil>, enabled, duration,
        --           bar = <special frame id|nil>, group = <group id|nil> }
        list        = {},
        -- Headings inside this list, in the order they are drawn, and the last id
        -- handed out. Organisation only: nothing here reaches a nameplate, and an
        -- entry's `group` is never read by the engine.
        groups      = {},
        nextGroupID = 0,
    }
end

local DEFAULTS = {
    -- On: this module is the reason to install the addon for most of the people
    -- who install it, and a nameplate module that does nothing until it is found
    -- in a settings tree is one nobody ever sees. Everything below is set up to
    -- be usable the moment it comes on.
    enabled = true,

    general = {
        -- Shared media for every plate. "Clean" and "Expressway" come from
        -- LibSharedMedia and are only present if a pack supplying them is installed;
        -- barTexture/fontPath fall back to the Blizzard originals, so this is a
        -- preference rather than a dependency.
        texture      = "Clean",
        castTexture  = "Clean",
        -- Core's shared font block (Font.lua): face, size, outline, offset and
        -- drop shadow. Every string on a plate is drawn from this unless it has
        -- an override below.
        font         = addon.Font.New({ font = "Expressway", size = 9 }),

        -- Per-element overrides, each a font block of its own sitting IN FRONT of
        -- the general one: whatever an override doesn't set still comes from
        -- above, so a per-element typeface alone still follows the general size
        -- and outline. Each keeps its picked font alongside the flag rather than
        -- using nil to mean "off", so unticking and re-ticking gets the same font
        -- back instead of a reset.
        nameFontEnabled   = false,
        nameFont          = { font = "Friz Quadrata TT" },
        healthFontEnabled = false,
        healthFont        = { font = "Friz Quadrata TT" },
        levelFontEnabled  = false,
        levelFont         = { font = "Friz Quadrata TT" },
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

        -- Who each unit is swinging at, under the bottom right of its plate. `tot*`
        -- throughout, because that's what elementFont() reads.
        --
        -- Off, alone among the settings on this page, which are otherwise a
        -- working setup out of the box: this one puts a second line of text on
        -- every plate on screen, which is a real change to what the game looks
        -- like and wants asking for. Everything below it is sized and placed for
        -- the moment it is asked for.
        totEnabled     = false,
        -- The tick box governs the FACE alone: size, outline, offset and shadow
        -- are this line's own either way, because it sits over the world rather
        -- than on a bar and readability there is a different question. The
        -- offsets are in screen directions (+X is right on both sides) and are
        -- applied to the anchor point rather than the text, so moving it moves
        -- the corner it grows from instead of flipping the direction.
        totFontEnabled = false,
        totFont        = addon.Font.New({ font = "Friz Quadrata TT", size = 15, y = 7 }),
        totAlpha       = 100,         -- %
        -- Which bottom corner the name (and its bar) hangs off. Either way the name is
        -- pinned by the end nearest that corner and grows inwards, so the corner holds
        -- still and a long name never drags the element off the plate.
        totAnchor      = "bottomRight",   -- "bottomRight" | "bottomLeft"
        -- What decides the name's colour. One setting rather than a stack of switches,
        -- since the three are alternatives and only one can win.
        --
        --   "class"  the class colour of whatever is being hit, which only a player has.
        --            Falls back to `totColor` for anything else.
        --   "health" green at full through yellow to red at empty.
        --   "drain"  the same ramp spent right to left across the letters: the name is
        --            drawn twice and the coloured copy clipped to health left. Needs
        --            SetClipsChildren; falls back to "health".
        --   "custom" `totColor`, flat.
        totColorMode   = "class",   -- "class" | "health" | "drain" | "custom"
        totColor       = { 0.80, 0.80, 0.80 },

        -- The health ramp, used by whichever of the name and bar is set to it. Three
        -- colours, not two: a fade to the middle then off it, so green and red ends
        -- don't put a muddy olive at half health. Set the middle to the halfway blend of
        -- the ends and it becomes one plain fade.
        totRampFull    = { 0.00, 1.00, 0.00 },   -- at full health
        totRampMid     = { 1.00, 1.00, 0.00 },   -- at half
        totRampEmpty   = { 1.00, 0.00, 0.00 },   -- at empty
        -- What the spent part of a draining name is left wearing.
        totSpentColor  = { 0.35, 0.35, 0.35 },

        -- A health bar for that unit, under or over its name. `totBarWidth = 0` means
        -- "as wide as the name", so a bar ending where the name ends reads as part of
        -- it; any other value is a fixed pixel width.
        -- Off with the name it belongs to, and for the same reason.
        totBarEnabled   = false,
        -- Colours the bar by how much is left rather than taking the name's colour. On
        -- by default, since the ramp answers "how hurt is it" without being looked at.
        -- Unticking hands it back to the name's colour.
        totBarGradient  = true,
        totBarTexture   = "Clean",
        totBarHeight    = 8,
        -- Fixed rather than name-width: above the name, a bar that changed width
        -- with every unit read as the plate itself twitching.
        totBarWidth     = 75,
        totBarPlacement = "above",   -- "above" | "below", relative to the name
        totBarX         = 0,
        totBarY         = 4,

        -- CVar-backed engine settings. Applied on login and whenever they
        -- change; deferred out of combat when the game refuses them.
        showEnemies  = true,
        showFriends  = false,
        showAll      = true,   -- show plates outside combat too
        maxDistance  = 20,     -- Classic Era caps this at 41 yards
        stacking     = true,   -- nameplateMotion: stacked instead of overlapping
        overlapV     = 110,    -- % vertical spacing when stacking

        -- Slack added around the widest bar to make the invisible click box, in
        -- WorldFrame units (screen pixels) rather than bar units — so it stays the
        -- same physical size whatever the interface scale, which is what click
        -- slack should do.
        --
        -- Y is NOT only slack: it lands in the height handed to SetNamePlateSize,
        -- and that rect is what the client stacks plates by. At these defaults a
        -- 22px bar at 0.65 UI scale makes a 38-unit rect, so 24 of it is pad —
        -- most of the gap between two stacked plates. 24/10 is what covers the
        -- cast bar below and the name above at a typical scale; drop Y to tighten
        -- stacking, at the cost of the name falling outside the clickable box.
        clickPadX    = 10,
        clickPadY    = 24,

        -- Pins the engine's own distance and target scaling to 1, so this module's
        -- settings are the only thing sizing a plate. On by default: the engine's
        -- scaling compounds with ours.
        constantSize = true,
        -- Snapshot of the scale CVars as they were before the pin, so unticking
        -- gives back what you had. Written by the engine, not a preference.
        savedScaleCVars = nil,

        -- The same for the engine's fading. The client dims every plate that isn't your
        -- target (nameplateNotSelectedAlpha, 0.5) and fades distant ones, on the BASE
        -- plate our frame is a child of — so it lands on top of everything the Fade
        -- settings decide, and turning "fade the other nameplates" off doesn't stop it.
        constantAlpha = true,
        savedAlphaCVars = nil,
    },

    enemyNPC = {
        enabled       = true,
        width         = 180,
        height        = 22,
        scale         = 100,   -- %
        showName      = true,
        nameSize      = 8,
        -- On the bar rather than above it, which is what the 22px height and the
        -- 15-character truncation are sized for: the name shares the bar with the health
        -- text, so it must be small and bounded.
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
        -- The same rect as an enemy NPC's. Two plate sizes on screen at once
        -- reads as two addons, and in the open world the players and the mobs
        -- are stood among each other.
        width         = 180,
        height        = 22,
        scale         = 100,
        classColor    = true,   -- health bar takes the class color
        classColorName = true,  -- so does the name text
        -- Players you can't attack lose the bar entirely and keep just a name.
        nameOnlyWhenSafe = true,
        -- Its own size here, because the one above is sized to share the bar with the
        -- level and health text. With those gone the name is the whole plate.
        nameOnlySize     = 12,
        showName      = true,
        nameSize      = 10,
        -- Matching enemyNPC: on the bar, not above it. A player plate labelling itself
        -- somewhere different from every mob plate beside it reads as two addons.
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
        -- Only recolor mobs that are fighting YOU or your group. Everything else
        -- keeps the reaction color below — hostile red, neutral yellow — which is
        -- what a mob you have nothing to do with should be saying. Without this,
        -- anything in combat with anybody reports the bottom of a threat table
        -- you are not on, i.e. reassuring green on a mob that would still eat you.
        combatOnly          = true,
        overrideNpcColors   = true,  -- threat beats a custom NPC color…
        overrideOnlyOnAggro = true,  -- …but only once you've actually pulled it
        overrideOnGaining   = true,  -- …counting "about to pull" as pulled too
        colors = {
            -- DPS/healer mode: green = safely off the threat table.
            noThreat   = { 0.25, 0.80, 0.35 },
            gaining    = { 0.95, 0.80, 0.20 },
            aggro      = { 0.90, 0.15, 0.15 },
            -- Sitting on a raid member assigned Main Tank. A cool desaturated slate
            -- deliberately: it must read as "not your problem" without competing with the
            -- green/amber/red ladder everything else uses.
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
        -- Ornament around the targeted plate, from Data.TARGET_INDICATORS. "None" is the
        -- off switch, so this needs no separate enable flag.
        indicator             = "Pins",
        indicatorColorEnabled = false,   -- each preset carries its own color
        indicatorColor        = { 0.00, 0.44, 1.00 },
        scale          = 110,   -- % on top of the group scale
        alpha          = 100,   -- % for the targeted plate
        -- Off, with the others at full: the "fade bystanders" setting in general covers
        -- dimming by what's actually fighting you, which is a better reason to push a
        -- plate back than merely not being the current target.
        dimOthers      = false,
        othersAlpha    = 50,    -- % for every other plate, if dimOthers is switched on
        raise          = true,  -- draw the target's plate above the others
    },

    -- Markers hung off the health bar, each placed by picking a point on the bar and
    -- nudging the icon's CENTRE from there — so "LEFT, x = -10" means "ten out from
    -- the left edge" at any bar size.
    --
    -- Elite and rare ship off: the dragon is a big piece of art to hang on every
    -- plate in a raid, and their placements below are still what they land on the
    -- moment either is ticked. The other four are on, sat clear of each other —
    -- the marker and the faction badge out to the left of the bar, the quest icon
    -- and the pet icon above it.
    icons = {
        raidMarker = { enabled = true,  anchor = "LEFT",     x = -20, y =  0, size = 30 },
        faction    = { enabled = true,  anchor = "LEFT",     x =  -8, y =  0, size = 16 },
        quest      = { enabled = true,  anchor = "TOPLEFT",  x =   6, y = 11, size = 16 },
        pet        = { enabled = true,  anchor = "TOPLEFT",  x =   8, y = 10, size = 14 },
        elite      = { enabled = false, anchor = "RIGHT",    x =  17, y =  0, size = 24 },
        rare       = { enabled = false, anchor = "TOPRIGHT", x =  10, y =  8, size = 16 },
    },

    -- ── Aura tracking ────────────────────────────────────────────────────────────
    -- Four independent rows, one per (unit type × buffs/debuffs), each with its own
    -- whitelist. A whitelist rather than a blacklist because a nameplate has room
    -- for a handful of icons at most.
    --
    -- Split by unit type first, because that's where the answers differ: debuffs
    -- stuck on a boss and what an enemy healer is running with are different lists,
    -- wanted at different sizes and places. Friendly units borrow the matching enemy
    -- block, as they borrow its styling group.
    --
    -- Every list starts EMPTY, so nothing draws until something is added. Within a
    -- unit type the rows stack, so turning both on doesn't pile one on the other.
    --
    -- `fromEvents` is off for NPCs and on for players: debuffs on an NPC come back
    -- off the unit fine, a hostile player's buffs never do.
    auras = {
        enabled = true,

        -- Every aura seen on a nameplate, so whitelists can be filled from things
        -- actually met. On by default, like the auto-detected NPC list: a catalogue you
        -- must switch on first is empty exactly when you go looking for it.
        --
        -- Collapsed by spell NAME, not ID — ranks would fill it with eight rows of the
        -- same shout, and the name is what a whitelist entry matches on anyway.
        learn = true,
        learned = {
            buffs   = { list = {}, n = 0 },
            debuffs = { list = {}, n = 0 },
        },

        units = {
            -- Buffs sit a full row above the debuffs (the y is measured from the
            -- top of the health bar, so it has to clear the debuff row's own
            -- icons), and the player rows run slightly larger than the NPC ones
            -- because there are never forty players on screen at once.
            --
            -- `special` is the extra frames off the side of the plate, holding
            -- whichever whitelist entries are ticked onto them. Empty here and
            -- filled by Data.EnsureSpecialBars: a frame shipped as a default
            -- would grow back every login once deleted.
            --   bars   = ordered list of Data.NewSpecialBar tables
            --   nextID = the last id handed out, never reused
            --   seed   = which starting frame this profile has had
            enemyPlayer = {
                fromEvents = true,
                buffs      = auraRowDefaults(40, 32),
                debuffs    = auraRowDefaults(4,  32),
                special    = { bars = {}, nextID = 0, seed = 0 },
            },
            enemyNPC = {
                fromEvents = false,
                buffs      = auraRowDefaults(36, 28),
                debuffs    = auraRowDefaults(4,  28),
                special    = { bars = {}, nextID = 0, seed = 0 },
            },
        },
    },

    -- ── Boss mod timers ──────────────────────────────────────────────────────────
    -- A fifth strip of icons off the health bar's top-left, fed by DBM and BigWigs
    -- rather than the game: both run a countdown bar for the mechanic you're waiting
    -- on, and both can say which unit it's about. That GUID is the whole feature —
    -- it turns a line on a list off to one side into an icon on the mob it belongs
    -- to, which is the difference between four identical Shield Wall bars and
    -- knowing which horseman.
    --
    -- Top-left rather than above the bar, since the aura rows are already there and
    -- this has to be readable on a plate wearing both.
    bossMods = {
        enabled     = true,
        -- One switch per boss mod. Having both installed and reporting the same pull is
        -- a real state, hence two switches rather than one dropdown.
        dbm         = true,
        bigwigs     = true,

        -- Bigger than the aura icons on the same plate, deliberately: these are
        -- the mechanic you are waiting on, and they are competing with a screen
        -- full of everything else during a pull.
        size        = 32,
        spacing     = 3,
        max         = 3,
        -- Leftwards, away from the corner it is pinned to, so a second timer
        -- grows out into empty space instead of over the health bar.
        growth      = "left",
        x           = -4,
        y           = 4,
        -- Off: the swipe on an icon this size is readable on its own, and the
        -- number sits over the art it is counting down.
        showTimer   = false,
        showStacks  = false,
        timerSize   = 10,
        borderSize  = 1,
        borderColor = { 0.00, 0.00, 0.00 },
    },

    -- [npcID] = { name, zone, rename, enabled, color = {r,g,b}, auto }
    npcs    = {},
    autoAdd = true,
    npcSeed = 0,
}

addon.RegisterDefaults("nameplates", DEFAULTS)

-- Every font on a plate was a bare LibSharedMedia name, with the general one's
-- size and outline (and target of target's size, outline and nudges) as flat
-- keys beside it. Folding those into their blocks has to run before the defaults
-- are merged, since the merge starts a fresh table wherever a saved value isn't
-- one and the picked face would be gone before anything read it.
local function nameplateGeneral(s)
    return type(s.nameplates) == "table" and s.nameplates.general or nil
end

addon.Font.MigrateBlock(nameplateGeneral, "font",
    { size = "fontSize", outline = "fontOutline" })
addon.Font.MigrateBlock(nameplateGeneral, "nameFont")
addon.Font.MigrateBlock(nameplateGeneral, "healthFont")
addon.Font.MigrateBlock(nameplateGeneral, "levelFont")
addon.Font.MigrateBlock(nameplateGeneral, "totFont",
    { size = "totSize", outline = "totOutline", x = "totX", y = "totY" })

-- This module is why profile exports got unwieldy: a raid night's worth of
-- learned auras and auto-detected mobs is local discovery, and it outweighed
-- the actual settings five to one. So an exported profile carries only what the
-- profile is actually SET to watch — the whitelists under auras.units, and the
-- NPC rows that are switched on. Everything else is this account's record of
-- what it has met, and refills itself on whoever imports the string.
--
-- Registered defensively: an older core has neither registry (they arrived
-- together, so one check covers both).
if addon.RegisterExportPruner and addon.RegisterImportFiller then
    addon.RegisterExportPruner("nameplates", function(np)
        -- The catalogue of every aura seen. The whitelists it exists to be
        -- picked from live elsewhere (auras.units) and travel untouched.
        if type(np.auras) == "table" then np.auras.learned = nil end

        -- Switched-off rows go, whether auto-detected or hand-made: a disabled
        -- entry changes nothing about how the importer's plates look, so it's
        -- the same "seen it" note the auto rows are.
        if type(np.npcs) == "table" then
            for id, e in pairs(np.npcs) do
                if not (type(e) == "table" and e.enabled) then np.npcs[id] = nil end
            end
        end
    end)

    -- And on the way back in, those whitelists append themselves to the Learned
    -- tab, so it lists what the profile watches for rather than nothing at all.
    -- Only the names it doesn't already hold — see AddListsToLearned. The NPC
    -- side needs no counterpart: its rows ARE the list, so the ones that
    -- travelled are in it already, and an import can only add to it.
    addon.RegisterImportFiller("nameplates", function(np)
        Data.AddListsToLearned(np)
    end)
end

-- ── Health text formats ──────────────────────────────────────────────────────
-- One ordered list drives both the dropdown and the engine, so a format can't
-- exist in one and not the other. The label IS the example, since the six differ
-- only in looks.
--
-- `build` takes the already-shortened numbers — the engine owns how 6723 becomes
-- "6.7k", and a format re-deriving it could disagree. The first four values are
-- spelled exactly as they shipped, so existing profiles keep their choice.
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
-- Each entry is the pair of anchor points plus the matching justification: a
-- name anchored by its right edge and left-justified drifts as the text
-- shortens, so the two are never picked independently.
--
-- `dx`/`dy` are built-in breathing room, not a preference — the user's own nudge
-- is added on top. `row` tells the layout code whether the name shares the strip
-- above the bar with the level text or is on the bar itself.
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
-- Ported from ClassicNameplatesPlus (which took them from Plater), so the looks
-- are familiar.
--
-- `coords` decides the shape: four entries draw one per corner (TL, BL, BR, TR),
-- two draw at the left and right edges. Some pairs run high→low on purpose, which
-- mirrors the crop so one piece of art serves all four corners.
--
-- Sizes are in the art's own units: `autoScale` measures against the bar height
-- so proportions hold at any plate size, `scale` pins a fixed multiplier. Every
-- preset crops art the game ships, so no media files are needed — CNP's Arrow
-- presets are absent because they read .tga files from that addon's folder.
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

-- Named preset colors. Only these two are used above; anything unrecognised
-- falls back to white.
Data.INDICATOR_COLORS = {
    white = { 1, 1, 1 },
    red   = { 1, 0, 0 },
}

-- ── Aura tracking ────────────────────────────────────────────────────────────
-- Which way a row grows from its anchor. "Centred" widens both ways; the other
-- two pin the FIRST icon to one edge, so the icon you look at first never moves.
-- `short` is what a half-width column's dropdown can show.
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
-- above — friendly units borrow the matching enemy block.
Data.AURA_UNIT_FOR_KIND = {
    enemyPlayer    = "enemyPlayer",
    friendlyPlayer = "enemyPlayer",
    enemyNPC       = "enemyNPC",
    friendlyNPC    = "enemyNPC",
}

-- ── Special buff frames ──────────────────────────────────────────────────────
-- Extra strips of icons, off the side of the plate rather than stacked above it,
-- each holding whichever entries of the two whitelists are ticked for it. The
-- point is the one thing the pair of rows above the bar can't do: take the two
-- or three auras a fight is actually about out of a queue of eight identical
-- ones and put them somewhere the eye already is, at whatever size they deserve.
--
-- Per unit type, like the whitelists they draw from, and shared by that type's
-- buffs and debuffs — an entry moves to a frame, and which list it came off
-- stops mattering the moment it does.
--
-- Where the frame hangs off the health bar. Eight points rather than the four
-- sides, since a corner is the placement that stays clear of both rows above the
-- bar and the cast bar under it.
Data.SPECIAL_ANCHORS = {
    { value = "RIGHT",       label = "Right of the bar",   short = "Right"        },
    { value = "LEFT",        label = "Left of the bar",    short = "Left"         },
    { value = "TOP",         label = "Above the bar",      short = "Above"        },
    { value = "BOTTOM",      label = "Below the bar",      short = "Below"        },
    { value = "TOPRIGHT",    label = "Top right corner",   short = "Top right"    },
    { value = "TOPLEFT",     label = "Top left corner",    short = "Top left"     },
    { value = "BOTTOMRIGHT", label = "Bottom right corner", short = "Bottom right" },
    { value = "BOTTOMLEFT",  label = "Bottom left corner",  short = "Bottom left"  },
}

Data.SPECIAL_ANCHOR_BY_VALUE = {}
for _, e in ipairs(Data.SPECIAL_ANCHORS) do Data.SPECIAL_ANCHOR_BY_VALUE[e.value] = e end

function Data.SpecialAnchor(value)
    if value and Data.SPECIAL_ANCHOR_BY_VALUE[value] then return value end
    return "RIGHT"
end

-- The three growths the rows above the bar have, plus their vertical mirrors: a
-- frame off the SIDE of a plate has height to grow into and almost no width, so
-- a column is what fits there.
Data.SPECIAL_GROWTHS = {
    { value = "right",   label = "Rightwards",         short = "Right"    },
    { value = "left",    label = "Leftwards",          short = "Left"     },
    { value = "center",  label = "Centred, in a row",  short = "Centred —" },
    { value = "down",    label = "Downwards",          short = "Down"     },
    { value = "up",      label = "Upwards",            short = "Up"       },
    { value = "vcenter", label = "Centred, in a column", short = "Centred |" },
}

Data.SPECIAL_GROWTH_BY_VALUE = {}
for _, e in ipairs(Data.SPECIAL_GROWTHS) do Data.SPECIAL_GROWTH_BY_VALUE[e.value] = e end

-- Which of the six stack rather than queue. Read by the engine to decide whether
-- an icon's offset from the last one is an x or a y.
Data.SPECIAL_VERTICAL = { up = true, down = true, vcenter = true }

function Data.SpecialGrowth(value)
    if value and Data.SPECIAL_GROWTH_BY_VALUE[value] then return value end
    return "right"
end

-- The horizontal and vertical halves of an anchor point, so the frame's own
-- attach point can be worked out as the mirror of whichever half the icons do
-- not run along. Pure sides have only one half, and get nil for the other.
local ANCHOR_V = {
    TOP = "TOP", TOPLEFT = "TOP", TOPRIGHT = "TOP",
    BOTTOM = "BOTTOM", BOTTOMLEFT = "BOTTOM", BOTTOMRIGHT = "BOTTOM",
}
local ANCHOR_H = {
    LEFT = "LEFT", TOPLEFT = "LEFT", BOTTOMLEFT = "LEFT",
    RIGHT = "RIGHT", TOPRIGHT = "RIGHT", BOTTOMRIGHT = "RIGHT",
}

local MIRROR = { TOP = "BOTTOM", BOTTOM = "TOP", LEFT = "RIGHT", RIGHT = "LEFT" }

-- Which point on the frame itself is pinned to that anchor. Two rules, and
-- between them every combination lands outside the health bar rather than over
-- it: the icons' own axis is pinned at the end they grow FROM, and the other
-- axis takes the mirror of the anchor's — a frame hung off the top edge sits
-- with its BOTTOM on it, so it goes up rather than down over the bar.
--
-- The frame is sized to exactly the icons on it (see finishAuraRow), so a
-- "centred" growth is nothing more than pinning the middle instead of an end.
function Data.SpecialRowPoint(anchor, growth)
    anchor = Data.SpecialAnchor(anchor)
    growth = Data.SpecialGrowth(growth)

    local along, across
    if Data.SPECIAL_VERTICAL[growth] then
        along  = (growth == "down" and "TOP") or (growth == "up" and "BOTTOM") or ""
        across = MIRROR[ANCHOR_H[anchor] or ""] or ""
        return (along .. across) ~= "" and (along .. across) or "CENTER"
    end

    along  = (growth == "right" and "LEFT") or (growth == "left" and "RIGHT") or ""
    across = MIRROR[ANCHOR_V[anchor] or ""] or ""
    return (across .. along) ~= "" and (across .. along) or "CENTER"
end

-- Name and icon for a spell ID *or* name. Classic Era still has the global
-- getters, but C_Spell is what newer builds expect, so prefer it and fall back.
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
-- buffs/debuffs used to live at auras.buffs/auras.debuffs and apply to every
-- plate. The old block is copied onto BOTH unit types and then removed — copied,
-- not moved, since there's no basis for guessing which type entries were for.
--
-- Self-limiting with no version flag: the old keys are gone afterwards and
-- DEFAULTS no longer carries them, so applyDefaults can't put them back.
--
-- The "already split?" test is whether the target row has a whitelist of its
-- own, NOT whether it exists — it always exists by now, since applyDefaults has
-- already filled every new row with the shipped defaults.
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
        -- The one flag of the intermediate shape that survives applyDefaults, and the
        -- only one worth carrying: a unit type switched off entirely is now both rows off.
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

-- An entry is keyed by what it matches on: the spell ID as a string for a
-- numeric entry, the lowercased name for a written one. Keying on the *matching*
-- form is what stops "Rend" and "rend" becoming two rows firing on one aura.
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

-- `text` is whatever was typed: an ID or a name, since both are things people
-- have to hand. Returns the entry, or nil plus a message — terse, because a
-- half-width column has room for one short line beside the search box.
function Data.AddAura(unitKey, which, text)
    local list = Data.AuraList(unitKey, which)
    if not list then return nil, "Not ready yet." end

    local key, id, name = Data.AuraKeyFor(text)
    if not key then return nil, "Type a name or ID." end
    if list[key] then return nil, "Already on the list." end

    local entry = { enabled = true, id = id, name = name }
    -- An ID resolves to a name only if the client has that spell cached. Left nil
    -- otherwise and backfilled by Data.AuraDisplay next time the list is drawn.
    if id then entry.name = (Data.SpellInfo(id)) end

    -- Seeded from the catalogue when the module has already met this spell. Not an
    -- optimisation: without it a name added straight off the Learned tab shows a
    -- question mark on the very list you just added it to, because the icon lives on
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

-- The override duration: what this entry's countdown is, in seconds, when the
-- user wants to say rather than have it worked out.
--
-- Three sources feed a countdown, in order of authority. A real aura read off
-- the unit carries its own and always wins. Failing that, addon.Durations
-- reconstructs one from its table of 1.12 durations. This field beats that
-- reconstruction, for a spell the table has wrong or has never heard of.
--
-- Blank — which is almost every entry — means "let the other two answer", and
-- when neither can the icon draws with no swipe and no countdown rather than a
-- made-up one.
--
-- Still stored as `duration`: the meaning of the number has not changed, only
-- what it takes precedence over, and renaming the key would strand it in every
-- saved profile and shared import string.
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

-- ── Special buff frames: the frames themselves ───────────────────────────────
-- Stored per unit type as an ORDERED list, since the settings page lists them
-- and a list that reshuffles between visits is unusable. Each carries a numeric
-- `id` that never changes and a `name` the user can rewrite at will: whitelist
-- entries point at the id, so renaming a frame cannot orphan what is on it.
--
-- Capped low on purpose. Every frame adds a checkbox to every row of both
-- whitelists, and a plate has only so many sides.
Data.SPECIAL_BAR_CAP  = 5
Data.SPECIAL_NAME_MAX = 18

-- What a brand new frame looks like. Bigger and fewer than the rows above the
-- bar, because that is the whole reason to move something onto one: an aura you
-- singled out is one you want to see, not one more 28px square in a queue.
function Data.NewSpecialBar(id, name)
    return {
        id          = id,
        name        = name,
        enabled     = true,
        anchor      = "RIGHT",   -- a value from Data.SPECIAL_ANCHORS
        growth      = "right",   -- a value from Data.SPECIAL_GROWTHS
        size        = 34,
        spacing     = 2,
        max         = 3,
        -- Clear of the health bar's own border and the target ornament, rather
        -- than flush against the edge.
        x           = 8,
        y           = 0,
        onlyMine    = false,
        -- On, unlike the rows above the bar: an aura worth its own frame is one
        -- whose remaining seconds you are watching for.
        showTimer   = true,
        showStacks  = true,
        timerSize   = 12,
        borderSize  = 1,
        borderColor = { 0.00, 0.00, 0.00 },
    }
end

-- The per-unit-type block, created on demand like every other aura table.
function Data.SpecialBlock(unitKey)
    local u = Data.AuraUnit(unitKey)
    if not u then return nil end
    u.special = u.special or {}
    u.special.bars = u.special.bars or {}
    return u.special
end

-- Shared, so a caller with no profile yet still gets something it can ipairs
-- over. Never written to — every writer goes through the block accessors.
local EMPTY_LIST = {}

function Data.SpecialBars(unitKey)
    local s = Data.SpecialBlock(unitKey)
    return s and s.bars or EMPTY_LIST
end

function Data.SpecialBar(unitKey, id)
    if not id then return nil end
    for _, bar in ipairs(Data.SpecialBars(unitKey)) do
        if bar.id == id then return bar end
    end
    return nil
end

-- Cut at a character rather than at a byte: the edit box counts letters and Lua
-- counts bytes, so clipping the raw string would leave half of an accented one
-- behind. Walks lead bytes and stops on the boundary after the cap.
local function clipChars(text, maxChars)
    local i, n, chars = 1, #text, 0
    while i <= n do
        local c = text:byte(i)
        local size = (c < 0x80 and 1) or (c < 0xE0 and 2) or (c < 0xF0 and 3) or 4
        chars = chars + 1
        if chars > maxChars then return text:sub(1, i - 1) end
        i = i + size
    end
    return text
end

-- Trimmed and clipped rather than rejected: the box is 18 characters wide and
-- what fits in it is what the checkbox rows have room for anyway.
function Data.CleanSpecialName(text)
    if type(text) ~= "string" then return "" end
    text = text:match("^%s*(.-)%s*$") or ""
    return clipChars(text, Data.SPECIAL_NAME_MAX)
end

-- Names are what the whitelist checkboxes are labelled with, so two frames
-- sharing one would leave a row of checkboxes you cannot tell apart.
local function nameTaken(unitKey, name, exceptID)
    local lowered = name:lower()
    for _, bar in ipairs(Data.SpecialBars(unitKey)) do
        if bar.id ~= exceptID and (bar.name or ""):lower() == lowered then return true end
    end
    return false
end

function Data.AddSpecialBar(unitKey, text)
    local s = Data.SpecialBlock(unitKey)
    if not s then return nil, "Not ready yet." end
    if #s.bars >= Data.SPECIAL_BAR_CAP then
        return nil, "That is all " .. Data.SPECIAL_BAR_CAP .. " of them."
    end

    local name = Data.CleanSpecialName(text)
    if name == "" then name = "Special " .. (#s.bars + 1) end
    if nameTaken(unitKey, name) then return nil, "Already a frame called that." end

    -- Counted up and never reused, so an id can't be handed to a new frame while
    -- whitelist entries still point at the deleted one that had it.
    s.nextID = (tonumber(s.nextID) or 0) + 1
    local bar = Data.NewSpecialBar(s.nextID, name)
    s.bars[#s.bars + 1] = bar
    Data.InvalidateAuras()
    return bar
end

-- Takes the entries on it back to the rows above the health bar rather than
-- leaving them pointing at nothing: an aura you whitelisted is one you asked to
-- see, and deleting a frame is a statement about the frame.
function Data.RemoveSpecialBar(unitKey, id)
    local s = Data.SpecialBlock(unitKey)
    if not (s and id) then return false end

    local found
    for i, bar in ipairs(s.bars) do
        if bar.id == id then found = i; break end
    end
    if not found then return false end

    table.remove(s.bars, found)
    for _, which in ipairs({ "buffs", "debuffs" }) do
        for _, entry in pairs(Data.AuraList(unitKey, which) or {}) do
            if entry.bar == id then entry.bar = nil end
        end
    end
    Data.InvalidateAuras()
    return true
end

-- Returns the name actually stored, so a caller can put the box back to it when
-- what was typed was blank, too long, or already in use.
function Data.RenameSpecialBar(unitKey, id, text)
    local bar = Data.SpecialBar(unitKey, id)
    if not bar then return nil end

    local name = Data.CleanSpecialName(text)
    if name ~= "" and not nameTaken(unitKey, name, id) then bar.name = name end
    return bar.name
end

-- Which frame an entry is drawn on, or nil for the row above the health bar.
-- One at a time by design: the checkbox row says "show this here INSTEAD", so
-- ticking a second frame moves it rather than copying it.
function Data.SetAuraBar(unitKey, which, key, barID)
    local list = Data.AuraList(unitKey, which)
    local entry = list and key and list[key]
    if not entry then return nil end

    if barID and Data.SpecialBar(unitKey, barID) then
        entry.bar = barID
    else
        entry.bar = nil
    end
    Data.InvalidateAuras()
    return entry.bar
end

-- ── Groups ───────────────────────────────────────────────────────────────────
-- Headings inside one whitelist, and nothing more: "Stuns", "CC", "Things I have
-- to dispel". A group changes NOTHING about what is drawn or how — the engine
-- never reads one — which is exactly why they're worth having, because it means
-- a list you can find things in costs nothing to keep.
--
-- Per list rather than per unit type: the groups a debuff list wants and the ones
-- a buff list wants have nothing to say to each other.
--
-- Same id/name split as the special frames, for the same reason: entries point at
-- `id`, so a group can be renamed as often as you like.
Data.AURA_GROUP_CAP      = 12
Data.AURA_GROUP_NAME_MAX = 22

function Data.AuraGroups(unitKey, which)
    local o = Data.AuraOpts(unitKey, which)
    if not o then return EMPTY_LIST end
    o.groups = o.groups or {}
    return o.groups
end

function Data.AuraGroup(unitKey, which, id)
    if not id then return nil end
    for _, g in ipairs(Data.AuraGroups(unitKey, which)) do
        if g.id == id then return g end
    end
    return nil
end

-- Names are free-form and need not be unique — they label a heading rather than
-- identify one, and two groups both called "Adds" is the user's business.
function Data.AddAuraGroup(unitKey, which, text)
    local o = Data.AuraOpts(unitKey, which)
    if not o then return nil, "Not ready yet." end
    local groups = Data.AuraGroups(unitKey, which)
    if #groups >= Data.AURA_GROUP_CAP then
        return nil, "That is all " .. Data.AURA_GROUP_CAP .. " groups."
    end

    local name = clipChars((type(text) == "string" and text:match("^%s*(.-)%s*$")) or "",
        Data.AURA_GROUP_NAME_MAX)
    if name == "" then name = "Group " .. (#groups + 1) end

    o.nextGroupID = (tonumber(o.nextGroupID) or 0) + 1
    local group = { id = o.nextGroupID, name = name }
    groups[#groups + 1] = group
    return group
end

-- The entries in it are NOT deleted — they go back to being ungrouped. Deleting
-- a heading is a statement about the heading.
function Data.RemoveAuraGroup(unitKey, which, id)
    local groups = Data.AuraGroups(unitKey, which)
    local found
    for i, g in ipairs(groups) do
        if g.id == id then found = i; break end
    end
    if not found then return false end

    table.remove(groups, found)
    for _, entry in pairs(Data.AuraList(unitKey, which) or {}) do
        if entry.group == id then entry.group = nil end
    end
    return true
end

function Data.RenameAuraGroup(unitKey, which, id, text)
    local group = Data.AuraGroup(unitKey, which, id)
    if not group then return nil end

    local name = clipChars((type(text) == "string" and text:match("^%s*(.-)%s*$")) or "",
        Data.AURA_GROUP_NAME_MAX)
    if name ~= "" then group.name = name end
    return group.name
end

-- Which group an entry sits under, or nil for none. An id this list doesn't have
-- reads as none, so a dropped drag onto something that has just been deleted
-- lands the entry in the ungrouped pile rather than nowhere.
function Data.SetAuraGroup(unitKey, which, key, groupID)
    local list = Data.AuraList(unitKey, which)
    local entry = list and key and list[key]
    if not entry then return nil end

    if groupID and Data.AuraGroup(unitKey, which, groupID) then
        entry.group = groupID
    else
        entry.group = nil
    end
    return entry.group
end

-- Collapsing is per group, and the ungrouped pile keeps its own flag on the list
-- itself — it has no group table to hang one on.
function Data.ToggleAuraGroup(unitKey, which, id)
    if id then
        local group = Data.AuraGroup(unitKey, which, id)
        if not group then return end
        group.collapsed = not group.collapsed
        return
    end

    local o = Data.AuraOpts(unitKey, which)
    if o then o.looseCollapsed = not o.looseCollapsed end
end

-- ── Learning what a name matches ─────────────────────────────────────────────
-- The client only resolves a spell NAME in your own spellbook, and the effects
-- worth watching on an enemy are exactly the ones that aren't. So a by-name
-- entry starts with no ID and no art, and no table could give it one.
--
-- What there is, is the aura itself: every time the engine matches a name entry
-- against a real one it has the ID and icon in hand and writes them back. Since
-- entries live in saved variables, it stays taught.
--
-- Every ID is kept, not just the first: matching by name is a deliberate "every
-- rank of this", and which ranks that meant is what the entry couldn't tell you.
function Data.NoteAuraSeen(entry, spellID, icon)
    if type(entry) ~= "table" or type(spellID) ~= "number" then return false end

    if icon and not entry.icon then entry.icon = icon end

    entry.seen = entry.seen or {}
    if entry.seen[spellID] then return false end
    entry.seen[spellID] = true
    return true
end

-- Sorted here rather than stored in order: it's read when a tooltip opens and
-- written mid-combat-scan, so the cost belongs on the reader.
function Data.AuraSeenIDs(entry)
    local out = {}
    if type(entry) == "table" and entry.seen then
        for id in pairs(entry.seen) do out[#out + 1] = id end
        table.sort(out)
    end
    return out
end

-- What the settings list shows for a row. Both derived rather than stored for ID
-- entries, and the resolved name is written back so an entry added before the
-- client knew the spell stops being "Spell 12345" once it does.
function Data.AuraDisplay(entry)
    if type(entry) ~= "table" then return "", nil end
    local lookupKey = entry.id or entry.name
    local name, icon = Data.SpellInfo(lookupKey)
    if name and entry.id and entry.name ~= name then entry.name = name end

    -- Whatever the client wouldn't give us, from what the entry has learned. The
    -- stored icon covers the usual case; the walk over seen IDs is for an entry that
    -- learned an ID before this code existed, or whose art wasn't cached then.
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
        -- Last resort, catching entries added before any of this existed: the catalogue
        -- may have met the spell even though this entry never has. Cached onto the entry
        -- so it survives the catalogue being cleared.
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

-- The same list with its headings folded in: one flat array of `group` and `aura`
-- items, in the order they are drawn. Flat rather than nested because the list is
-- virtualised — the settings panel walks a window of it by index and never has to
-- know what a group is.
--
-- A list with no groups comes back exactly as SortedAuras left it, no headings at
-- all, so a whitelist nobody has organised looks and behaves as it always did.
--
-- `group.count` is what the heading shows, and it counts what the heading is
-- ACTUALLY over — so under a search it is the number of matches, not a total that
-- disagrees with the rows beneath it.
function Data.GroupedAuras(unitKey, which, filter)
    local sorted = Data.SortedAuras(unitKey, which, filter)
    local groups = Data.AuraGroups(unitKey, which)
    if #groups == 0 then return sorted end

    local searching = filter ~= nil and filter ~= ""

    -- One pass over the entries into per-group buckets, rather than a pass over
    -- the entries per group.
    local bucket, loose = {}, {}
    for _, g in ipairs(groups) do bucket[g.id] = {} end
    for _, item in ipairs(sorted) do
        local into = item.entry.group and bucket[item.entry.group]
        item.group = into and item.entry.group or nil
        local dest = into or loose
        dest[#dest + 1] = item
    end

    local out = {}
    local function section(id, name, held, collapsed)
        -- A group with nothing in it still gets its heading: it is the thing you
        -- drag onto, and one you cannot see is one you cannot fill. Under a
        -- search it goes, since a search is asking to be shown less.
        if searching and #held == 0 then return end

        -- A search overrides collapse rather than hiding matches under a heading
        -- that says it found them — and the heading reports the state it is
        -- actually in, so the twisty never points the wrong way.
        local shut = collapsed and not searching
        out[#out + 1] = {
            kind = "group", id = id, name = name,
            count = #held, collapsed = shut and true or false,
        }
        if shut then return end
        for _, item in ipairs(held) do out[#out + 1] = item end
    end

    for _, g in ipairs(groups) do
        section(g.id, g.name or "", bucket[g.id], g.collapsed)
    end

    -- Last, and always present while there are groups at all: it is where a drag
    -- back OUT of a group has to land.
    local o = Data.AuraOpts(unitKey, which)
    section(nil, "Ungrouped", loose, o and o.looseCollapsed)

    return out
end

-- ── Learned aura catalogue ───────────────────────────────────────────────────
-- What the module has SEEN, as opposed to what it's been told to watch for. The
-- whitelists answer "show me this"; this answers "what is there to ask for".
--
-- Capped, because a raid night meets more auras than anyone will scroll through.
-- Once full it stops taking NEW names but keeps filling in extra ranks and
-- missing art for the ones it has.
Data.LEARNED_CAP = 400

-- How many distinct NPCs one record names before it stops collecting. A debuff
-- you apply yourself is seen on everything you fight, so uncapped a single row
-- would list every mob in the game. Players collapse to the one word "Player",
-- since which player wore it is never the question.
Data.LEARNED_SOURCE_CAP = 12

-- Takes the settings block explicitly, because the import rebuilder fills a
-- profile that isn't the active one (and may never be).
local function learnedBucketIn(d, which)
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

function Data.LearnedBucket(which)
    return learnedBucketIn(Data.Get(), which)
end

-- Returns true when something was actually recorded, so the caller can redraw an
-- open settings list. False is the overwhelmingly common answer — this runs for
-- every aura on every plate — and costs a hash lookup.
--
-- `isPlayer` and `unitName` describe what was WEARING the aura, which is what
-- turns a bare list of names into something actionable: "Free Action" next to
-- Player reads differently from "Bile Sludge" next to a boss.
function Data.NoteLearnedAura(which, spellID, name, icon, isPlayer, unitName)
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

    if isPlayer then
        -- One flag, not a list of names. See LEARNED_SOURCE_CAP.
        if not rec.player then
            rec.player = true
            learned = true
        end
    elseif type(unitName) == "string" and unitName ~= "" then
        rec.npcs = rec.npcs or {}
        if not rec.npcs[unitName] and (rec.npcN or 0) < Data.LEARNED_SOURCE_CAP then
            rec.npcs[unitName] = true
            rec.npcN = (rec.npcN or 0) + 1
            learned = true
        end
    end

    -- The library's buff/debuff split leans on this catalogue for everything the
    -- 1.12 table declares no type for, so a new sighting can move a row from one
    -- list to the other.
    if learned and Data.InvalidateLibrary then Data.InvalidateLibrary() end

    return learned
end

-- Adds a profile's tracked auras to its own catalogue, for a profile that
-- arrived as an import. The export drops the catalogue — it's an account's
-- record of what it has met, and it was most of the string — so without this the
-- Learned tab of an imported profile is empty even though its rows are already
-- being tracked, and the importer can't see what the profile watches for except
-- by opening each whitelist. Every tracked aura goes in, enabled or not: a row
-- switched off is still one the profile knows about and offers.
--
-- Purely additive. A name already in the catalogue is left exactly as it stands,
-- IDs and art and sightings included — this only ever appends the ones missing,
-- so it can't overwrite what a catalogue learned the honest way.
--
-- No sources are invented either. The "seen on" column is a record of sightings,
-- and an appended row has none — it shows "—" until this client meets the aura
-- itself, and then fills itself in.
--
-- `np` is a settings.nameplates block, not necessarily the active one.
function Data.AddListsToLearned(np)
    if type(np) ~= "table" or type(np.auras) ~= "table" then return 0 end
    local units = np.auras.units
    if type(units) ~= "table" then return 0 end

    local added = 0
    for _, unit in pairs(units) do
        if type(unit) == "table" then
            for _, which in ipairs({ "buffs", "debuffs" }) do
                local row  = unit[which]
                local list = type(row) == "table" and row.list or nil
                if type(list) == "table" then
                    local b = learnedBucketIn(np, which)
                    for _, entry in pairs(list) do
                        -- Catalogue records are keyed by name, so an ID-only
                        -- entry the client can't resolve has nothing to file
                        -- under and is skipped. It still tracks fine; it just
                        -- can't be listed until the client knows the spell.
                        local name = type(entry) == "table"
                            and (entry.name or (entry.id and (Data.SpellInfo(entry.id)))) or nil
                        if b and type(name) == "string" and name ~= "" then
                            local key = name:lower()
                            if not b.list[key] and b.n < Data.LEARNED_CAP then
                                -- Seeded with everything the whitelist entry itself
                                -- knows: the ID it was added by, plus every rank it
                                -- has since matched.
                                local ids = {}
                                if entry.id then ids[entry.id] = true end
                                for seenID in pairs(entry.seen or {}) do ids[seenID] = true end

                                b.list[key] = {
                                    name = name,
                                    ids  = ids,
                                    icon = entry.icon or select(2, Data.SpellInfo(entry.id or name)),
                                }
                                b.n = b.n + 1
                                added = added + 1
                            end
                        end
                    end
                end
            end
        end
    end
    return added
end

-- What was seen wearing this, for display. "Player" leads when it applies —
-- it's the category the other entries are exceptions to — and the NPCs follow
-- in name order so the list doesn't reshuffle between draws.
function Data.LearnedSources(rec)
    local out = {}
    if type(rec) ~= "table" then return out end
    if rec.player then out[#out + 1] = "Player" end

    local npcs = {}
    for npc in pairs(rec.npcs or {}) do npcs[#npcs + 1] = npc end
    table.sort(npcs)
    for _, npc in ipairs(npcs) do out[#out + 1] = npc end
    return out
end

function Data.ClearLearned(which)
    local b = Data.LearnedBucket(which)
    if not b then return end
    b.list = {}
    b.n = 0
end

-- The catalogue's record for a spell name, whichever list it landed in. This is
-- how a whitelist entry gets art for a spell the client won't look up by name:
-- the module has already met it and written down what it looked like.
--
-- `which` is a preference, not a filter — a name existing as both buff and
-- debuff should answer with the one asked about, but either icon beats none.
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
-- matches the name, any of the IDs, and what was seen wearing it — because
-- "I know it was 25289" and "show me everything that boss does" are both things
-- you turn up with, as often as the spell's name is.
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
            if not ok and rec.player and ("player"):find(filter, 1, true) then ok = true end
            if not ok then
                for npc in pairs(rec.npcs or {}) do
                    if npc:lower():find(filter, 1, true) then ok = true; break end
                end
            end
        end
        if ok then out[#out + 1] = { key = key, rec = rec } end
    end

    table.sort(out, function(a, b2) return a.key < b2.key end)
    return out
end

-- ── Spell library ────────────────────────────────────────────────────────────
-- The catalogue above answers "what have I met". This answers "what is there",
-- off addon.Durations' table of 1.12 spells — so a whitelist can be filled in
-- before ever meeting the spell, which is the whole reason that library exists.
--
-- Three lists. Buffs and debuffs are the ~430 player spells, ranks collapsed to
-- one row each because the whitelist matches by name and every rank under it.
-- Creature is the ~4000 abilities cast by mobs, which is where boss mechanics
-- live and is far and away the longest of the three.
Data.LIBRARY_KINDS = {
    { key = "debuffs",  label = "Debuffs"  },
    { key = "buffs",    label = "Buffs"    },
    { key = "creature", label = "Creature" },
}

-- The library declares `type = "BUFF"` on 260 of its 432 player spells and says
-- nothing at all about the other 172. Silence is not evidence — it only means
-- the duration library never needed to know — so the undeclared ones are read
-- as debuffs, which is what about 150 of them are.
--
-- These are the exceptions: undeclared entries that are plainly buffs. Every
-- rank is listed because the row's representative id is whichever rank the name
-- resolves to. Anything missed here corrects itself the first time the
-- catalogue actually sees the aura land — see libraryKindFor.
local LIBRARY_BUFFS = {}
for _, id in ipairs({
    132, 2970, 11743,                          -- Detect Invisibility
    1539,                                      -- Feed Pet Effect
    5217, 6793, 9845, 9846,                    -- Tiger's Fury
    5697,                                      -- Unending Breath
    6307, 7804, 7805, 11766, 11767,            -- Blood Pact
    11327, 11329,                              -- Vanish
    12042,                                     -- Arcane Power
    12043,                                     -- Presence of Mind
    12328,                                     -- Death Wish
    17767, 17850, 17851, 17852, 17853, 17854,  -- Consume Shadows
    19480,                                     -- Paranoia
    23099, 23109, 23110,                       -- Pet Dash
    23451, 23493, 23505,                       -- Battleground buffs
    349981,                                    -- Chronoboon: world effect suspended
    355363, 22888,                             -- Rallying Cry of the Dragonslayer
    355365, 24425,                             -- Spirit of Zandalar
    355366, 16609,                             -- Warchief's Blessing
}) do LIBRARY_BUFFS[id] = true end

local function durations()
    return addon.Durations
end

-- ── Labels ───────────────────────────────────────────────────────────────────
-- Searchable tags on a library row, so "cc", "stun" or "magic" finds the spells
-- rather than needing their names. Three sources feed them.
--
-- The DR table is the first and covers 85 ids, but it answers a different
-- question — what shares a diminishing returns bracket — and the two only
-- mostly agree. Hibernate and Wyvern Sting sit in the INCAP bracket and are
-- sleeps; Frost Shock has a bracket of its own and is a slow, not a root. So DR
-- gives the default and the tables below override it.
--
-- The second source is everything 1.12 never diminished at all and which the DR
-- table therefore says nothing about: silences, disarms, charms, banishes, and
-- Blind and Frostbite (both left out on purpose — see DiminishingReturns.lua).
--
-- The third is dispel school. The library declares `buffType` on 84 spells and
-- the only value it ever holds is "Magic", because it only ever needed the
-- school of a BUFF. Curse, Poison and Disease are named below so a mage looking
-- for what they can decurse can search for it.
local LABEL_BY_DR = {
    STUN = "Stun", RANDOM_STUN = "Stun", KIDNEY_SHOT = "Stun",
    ROOT = "Root", RANDOM_ROOT = "Root",
    INCAP = "Incap",
    FEAR = "Fear",
    -- FROST_SHOCK is deliberately absent: it is a bracket, not a school of CC,
    -- and the spell in it is a slow. It picks its label up from SLOW below.
}

-- Hard crowd control — it stops the target acting or moving, and so earns the
-- generic "CC" tag as well as its own. Silence, Disarm and Slow are searchable
-- by name but are NOT under CC: they take away one option, not all of them.
local HARD_CC = {
    Stun = true, Root = true, Fear = true, Incap = true,
    Sleep = true, Charm = true, Banish = true, Horror = true,
}

local SPELL_LABEL = {}
local function label(text, ids)
    for _, id in ipairs(ids) do SPELL_LABEL[id] = text end
end

label("Silence", { 15487, 18469, 18425, 24259, 18498 })
label("Disarm",  { 676, 14251 })
label("Charm",   { 605, 10911, 10912 })
label("Banish",  { 710, 18647 })
label("Horror",  { 6789, 17925, 17926 })
label("Sleep",   { 2637, 18657, 18658, 19386, 24132, 24133 })
label("Incap",   { 2094, 9484, 9485, 10955 })
label("Fear",    { 1513, 14326, 14327, 2878, 5627, 20511 })
label("Root",    { 12494, 19975, 19229, 23694, 19185 })

local SLOW = {}
for _, id in ipairs({
    1715, 7372, 7373,                                        -- Hamstring
    3409, 11201,                                             -- Crippling Poison
    18223,                                                   -- Curse of Exhaustion
    8056, 8058, 10472, 10473,                                -- Frost Shock
    116, 205, 837, 7322, 8406, 8407, 8408,
    10179, 10180, 10181, 25304,                              -- Frostbolt
    120, 8492, 10159, 10160, 10161,                          -- Cone of Cold
    6136, 7321,                                              -- Frost / Ice Armor chill
    12484, 12485, 12486,                                     -- Improved Blizzard
    8034, 8037, 10458, 16352, 16353,                         -- Frostbrand
    3600,                                                    -- Earthbind Totem
    2974, 14267, 14268,                                      -- Wing Clip
    5116,                                                    -- Concussive Shot
    12323,                                                   -- Piercing Howl
    1604,                                                    -- Daze
}) do SLOW[id] = true end

-- Debuff dispel schools, which the duration library has no field for at all.
local SCHOOL = {}
local function school(text, ids)
    for _, id in ipairs(ids) do SCHOOL[id] = text end
end
school("Curse", {
    1714, 11719,                                             -- Tongues
    702, 1108, 6205, 7646, 11707, 11708,                     -- Weakness
    17862, 17937,                                            -- Shadows
    1490, 11721, 11722,                                      -- Elements
    704, 7658, 7659, 11717,                                  -- Recklessness
    603,                                                     -- Doom
    18223,                                                   -- Exhaustion
    980, 1014, 6217, 11711, 11712, 11713,                    -- Agony
})
school("Poison", {
    3409, 11201,                                             -- Crippling
    13218, 13222, 13223, 13224,                              -- Wound
    2818, 2819, 11353, 11354, 25349,                         -- Deadly
    5760, 8692, 11398,                                       -- Mind-numbing
})
school("Disease", { 2944, 19276, 19277, 19278, 19279, 19280 })  -- Devouring Plague

-- Every tag on one spell, generic first. Returns the list and one lowercased
-- blob for the search box to match against.
function Data.LibraryLabels(id, opts)
    local D = durations()
    local out = {}

    local cc = SPELL_LABEL[id] or (D and D.drCategory and LABEL_BY_DR[D.drCategory[id]])
    if cc then
        if HARD_CC[cc] then out[#out + 1] = "CC" end
        out[#out + 1] = cc
    end
    if SLOW[id] then out[#out + 1] = "Slow" end

    local dispel = (opts and opts.buffType) or SCHOOL[id]
    if dispel then out[#out + 1] = dispel end

    return out, (#out > 0) and (" " .. table.concat(out, " "):lower()) or ""
end

-- Has the catalogue recorded this name under that kind? This is the runtime
-- auraType straight off the combat log, so it outranks anything inferred from
-- the table's silence — but not an explicit declaration.
local function seenAs(key, which)
    local b = Data.LearnedBucket(which)
    return (b and b.list[key]) ~= nil
end

local function libraryKindFor(key, id, opts)
    if opts and opts.type == "BUFF" then return "buffs" end
    if LIBRARY_BUFFS[id] then return "buffs" end
    -- Watched land as a buff and never as a debuff: believe what was seen.
    if seenAs(key, "buffs") and not seenAs(key, "debuffs") then return "buffs" end
    return "debuffs"
end

-- Which of a unit's two whitelists a row belongs on. Buffs and debuffs answer
-- for themselves; a creature ability has no declared type at all, so it lands
-- on the debuff list unless the catalogue has seen otherwise.
function Data.LibraryWhichFor(kind, key)
    if kind ~= "creature" then return kind end
    if seenAs(key, "buffs") and not seenAs(key, "debuffs") then return "buffs" end
    return "debuffs"
end

-- "18s", "10m", "~12s" for one that varies with rank or talent, "∞" for a
-- permanent aura, "—" for one the library will not commit to.
function Data.LibraryDurationText(id)
    local D = durations()
    if not D or not D.DescribeDuration then return "—" end

    local seconds, varies, permanent = D.DescribeDuration(id)
    if permanent then return "∞" end
    if not seconds then return varies and "~?" or "—" end

    local text
    if seconds >= 3600 then
        text = ("%gh"):format(seconds / 3600)
    elseif seconds >= 60 then
        text = ("%gm"):format(seconds / 60)
    else
        text = ("%gs"):format(seconds)
    end
    return varies and ("~" .. text) or text
end

-- Built once per kind and kept: the roster itself never changes at runtime, and
-- the creature list costs ~4000 name lookups to assemble. The buff/debuff split
-- CAN move as the catalogue learns, so those two are rebuilt when it does — see
-- Data.InvalidateLibrary, which the learn path calls.
local libraryCache = {}

function Data.InvalidateLibrary()
    libraryCache.buffs, libraryCache.debuffs = nil, nil
end

local function buildPlayerRoster()
    local D = durations()
    local buffs, debuffs = {}, {}
    if not (D and D.spells) then
        libraryCache.buffs, libraryCache.debuffs = buffs, debuffs
        return
    end

    -- Collapsed by name, which is exactly the key a whitelist entry uses, so a
    -- row added from here and the same name typed by hand are one entry.
    local byName = {}
    for id in pairs(D.spells) do
        local name = Data.SpellInfo(id)
        if name and name ~= "" then
            local key = name:lower()
            if not byName[key] then
                local repID = (D.LastRankIDForName and D.LastRankIDForName(name)) or id
                byName[key] = {
                    key = key, id = repID, name = name,
                    icon = select(2, Data.SpellInfo(repID)),
                }
            end
        end
    end

    for key, row in pairs(byName) do
        local opts = D.spells[row.id]
        row.durText = Data.LibraryDurationText(row.id)
        row.labels, row.labelBlob = Data.LibraryLabels(row.id, opts)
        row.labelText = (#row.labels > 0) and table.concat(row.labels, ", ") or ""
        row.search = key .. " " .. row.id .. row.labelBlob
        table.insert(libraryKindFor(key, row.id, opts) == "buffs" and buffs or debuffs, row)
    end

    local byLabel = function(a, b) return a.name < b.name end
    table.sort(buffs, byLabel)
    table.sort(debuffs, byLabel)
    libraryCache.buffs, libraryCache.debuffs = buffs, debuffs
end

local function buildCreatureRoster()
    local D = durations()
    local out = {}
    if not (D and D.npcSpells) then
        libraryCache.creature = out
        return
    end

    local byName = {}
    for id in pairs(D.npcSpells) do
        local name, icon = Data.SpellInfo(id)
        if name and name ~= "" then
            local key = name:lower()
            -- Lowest id wins the row: mob abilities are not ranked, so several
            -- ids under one name are variants and any of them names the same
            -- thing to a whitelist that matches on the name.
            local prev = byName[key]
            if not prev then
                byName[key] = { key = key, id = id, name = name, icon = icon }
            elseif id < prev.id then
                prev.id, prev.icon = id, icon
            end
        end
    end

    for _, row in pairs(byName) do
        row.durText = Data.LibraryDurationText(row.id)
        -- No opts to read a dispel school off — a creature ability has rules
        -- nowhere but the duration number — so these only ever pick up a label
        -- from the DR table or the hand-written lists.
        row.labels, row.labelBlob = Data.LibraryLabels(row.id, nil)
        row.labelText = (#row.labels > 0) and table.concat(row.labels, ", ") or ""
        row.search = row.key .. " " .. row.id .. row.labelBlob
        out[#out + 1] = row
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    libraryCache.creature = out
end

-- The whole roster for a kind, unfiltered. Sorted at build so a keystroke only
-- costs the filter pass.
function Data.LibraryRoster(kind)
    if not libraryCache[kind] then
        if kind == "creature" then buildCreatureRoster() else buildPlayerRoster() end
    end
    return libraryCache[kind] or {}
end

function Data.LibraryRows(kind, filter)
    local roster = Data.LibraryRoster(kind)
    filter = filter and filter ~= "" and filter:lower() or nil
    if not filter then return roster, #roster end

    -- One blob per row holds name, ID and every label, so "cc", "stun", "magic"
    -- and "curse" search alongside the spell's own name.
    local out = {}
    for _, row in ipairs(roster) do
        if (row.search or row.key):find(filter, 1, true) then
            out[#out + 1] = row
        end
    end
    return out, #roster
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

    -- Every special frame this unit type has, INCLUDING the switched-off ones: an
    -- entry moved onto a frame that is currently hidden stays on it and draws
    -- nowhere, which is what a hidden frame means. Only a frame that has been
    -- deleted sends its entries back to the row above the bar, and RemoveSpecialBar
    -- already clears those — this is the belt to its braces, for an entry that
    -- arrives pointing at a frame the profile it came from had and this one hasn't.
    local known = {}
    for _, bar in ipairs(Data.SpecialBars(unitKey)) do known[bar.id] = true end

    -- The maps hold the ENTRY rather than `true`: a match still answers "is this
    -- tracked" by being non-nil, and event-inferred auras need the entry's
    -- duration, which a boolean threw away.
    --
    -- `barFor` is the entry's frame after that check, so the engine's scan loop
    -- asks one question of one table instead of re-testing the id per aura per
    -- plate per tick. Absent means the row above the health bar.
    --
    -- `main` and `bars` count what each destination would draw, so a row with
    -- nothing bound for it can bail before walking forty aura slots — the same
    -- early-out `count` has always given the pair above the bar.
    local out = { byID = {}, byName = {}, count = 0, main = 0, bars = {}, barFor = {} }
    for key, entry in pairs(Data.AuraList(unitKey, which) or {}) do
        if entry.enabled ~= false then
            if entry.id then
                out.byID[entry.id] = entry
            else
                out.byName[key] = entry   -- the key IS the lowercased name
            end
            out.count = out.count + 1

            local bar = entry.bar
            if bar and known[bar] then
                out.barFor[entry] = bar
                out.bars[bar] = (out.bars[bar] or 0) + 1
            else
                out.main = out.main + 1
            end
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

-- The one special buff frame every unit type starts with, seeded the same way
-- and for the same reason as the NPC list above: a frame shipped through
-- DEFAULTS would come back every login after it was deleted, because
-- applyDefaults refills whatever it finds missing.
--
-- Seeded even for a profile that predates the feature. It draws nothing until
-- something is ticked onto it, so an existing profile gains a place to put
-- things and no change to how its plates look.
Data.SPECIAL_SEED_VERSION = 1
Data.SPECIAL_SEED_NAME    = "Special Buffs"

function Data.EnsureSpecialBars()
    if not Data.Get() then return end
    for _, def in ipairs(Data.AURA_UNITS) do
        local s = Data.SpecialBlock(def.key)
        if s and (s.seed or 0) < Data.SPECIAL_SEED_VERSION then
            s.seed = Data.SPECIAL_SEED_VERSION
            -- Guarded on the list being empty, not just on the flag: an imported
            -- profile arrives with frames of its own and no seed marker, and
            -- adding a second "Special Buffs" to it would be nonsense.
            if #s.bars == 0 then Data.AddSpecialBar(def.key, Data.SPECIAL_SEED_NAME) end
        end
    end
end

function Data.GetNpc(npcID)
    local d = Data.Get()
    return npcID and d and d.npcs and d.npcs[npcID] or nil
end

-- The color this NPC should paint its health bar, or nil when the entry is
-- absent, switched off, or has no color of its own (auto-detected entries
-- start colorless — they're a record that you've seen the mob, not a rule).
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
-- switched off and colorless so simply walking through a zone never changes
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
        -- touch the user's own rename/color/enabled choices.
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
-- keeps anything the user has enabled, renamed or colored, even if it was
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
    for key, e in pairs(incoming) do
        -- Serialized table keys come back as whatever type they went out as, and
        -- an NPC id is only ever a number here — anything else isn't ours.
        local id = tonumber(key)
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
