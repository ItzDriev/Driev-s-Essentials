-- Nameplates module: the starting aura setup.
--
-- The whitelists, groups and special buff frames a fresh profile begins with,
-- rather than the two empty rows it used to. Everything here was a working setup
-- before it was a default: the enemy player lists are what a battleground
-- actually needs to see — every hard CC on one frame off the side of the plate,
-- stances and forms on another, slows and cooldowns grouped behind them — and
-- the enemy NPC lists are the taunt and threat effects a tank watches for.
--
-- SEEDED, not shipped through DEFAULTS, and that distinction is the whole reason
-- this file exists. Core's applyDefaults refills any key it finds missing on
-- every login, so a list shipped as a default would grow back every single time
-- the user deleted something out of it. A seed runs once per profile, marked by
-- a version flag, and what is done to it afterwards sticks.
--
-- Guarded on the profile being EMPTY as well as on the flag: a profile made
-- before this file existed, or imported from someone else, arrives with lists of
-- its own and no seed marker, and dropping sixty entries into it would be
-- vandalism rather than a default.
local addon = _G.DrievEssentials
if not addon then return end

local Data = addon.NameplatesData
if not Data then return end

-- Bumping this re-seeds only the unit types that are still empty — see
-- EnsureAuraSeed for what "empty" has to mean before anything is written.
Data.AURA_SEED_VERSION = 1

-- `group` and `bar` are INDEXES into the two lists above the entry, not ids: the
-- ids are handed out by the add functions as the seed is applied, and an index is
-- the only thing that can be written down before they exist.
--
-- `seen` is what the module had already learned each name matches. Carried rather
-- than left to be rediscovered, so a seeded list arrives with its art on it — an
-- entry with no icon draws a question mark until the spell is next met, and a
-- default that looks broken until you happen to meet a rogue is not much of a
-- default.
local SEED = {
    enemyNPC = {
        bars = {
            { name = "Special Buffs", anchor = "RIGHT", growth = "right", size = 34, spacing = 2, max = 3, x = 8, y = 0, timerSize = 12, borderSize = 1, showTimer = true, showStacks = true },
        },
        debuffs = {
            list = {
                { "Challenging Roar", icon = 132117, seen = { 5209 } },
                { "Challenging Shout", icon = 132091, seen = { 1161 } },
                { "Curse of Recklessness", icon = 136225, seen = { 11717 } },
                { "Demoralizing Shout", icon = 132366, seen = { 1160, 11556, 23511 } },
                { "Faerie Fire", icon = 136033, seen = { 9907 } },
                { "Growl", id = 6795 },
                { "Taunt", icon = 136080, seen = { 355, 29060 } },
            },
        },
        buffs = {
            list = {
                { "Shadow Protection", icon = 136121, seen = { 976, 10957, 10958 } },
            },
        },
    },
    enemyPlayer = {
        bars = {
            { name = "CC", anchor = "RIGHT", growth = "right", size = 26, spacing = 2, max = 3, x = 8, y = 0, timerSize = 12, borderSize = 1, showTimer = false, showStacks = true },
            { name = "Stance", anchor = "LEFT", growth = "left", size = 26, spacing = 2, max = 3, x = -8, y = 0, timerSize = 12, borderSize = 1, showTimer = false, showStacks = true },
        },
        debuffs = {
            groups = {
                { "Hard CC" },
                { "Slows", collapsed = true },
                { "Offensive CDs", collapsed = true },
            },
            list = {
                { "Banish", group = 1, bar = 1 },
                { "Bash", group = 1, bar = 1, icon = 132114, seen = { 8983 } },
                { "Blackout", group = 1, bar = 1, icon = 136160, seen = { 15269 } },
                { "Blind", group = 1, bar = 1, icon = 136175, seen = { 2094, 21060 } },
                { "Charge Stun", group = 1, bar = 1, icon = 135860, seen = { 7922 } },
                { "Cheap Shot", group = 1, bar = 1, icon = 132092, seen = { 1833 } },
                { "Concussion Blow", group = 1, bar = 1 },
                { "Curse of Recklessness", group = 1, bar = 1, icon = 136225, seen = { 11717 } },
                { "Death Coil", group = 1, bar = 1, icon = 136145, seen = { 17926, 28412 } },
                { "Entangling Roots", group = 1, bar = 1, icon = 136100, seen = { 9853, 19970 } },
                { "Entrapment", group = 1, bar = 1, icon = 136100, seen = { 19185 } },
                { "Fear", group = 1, bar = 1, icon = 136183, seen = { 6215, 22678, 26580, 27990 } },
                { "Flash Bomb", group = 1, bar = 1 },
                { "Freezing Trap Effect", group = 1, bar = 1, icon = 135834, seen = { 3355, 14308, 14309 } },
                { "Frost Nova", group = 1, bar = 1, icon = 135848, seen = { 122, 865, 10230, 29849, 30094 } },
                { "Frostbite", group = 1, bar = 1, icon = 135842, seen = { 12494 } },
                { "Gouge", group = 1, bar = 1, icon = 132155, seen = { 1776, 11286, 12540 } },
                { "Hammer of Justice", group = 1, bar = 1, icon = 135963, seen = { 853, 5589, 10308 } },
                { "Hibernate", group = 1, bar = 1, icon = 136090, seen = { 2637, 18658 } },
                { "Howl of Terror", group = 1, bar = 1, icon = 136147, seen = { 17928 } },
                { "Impact", group = 1, bar = 1, icon = 135821, seen = { 12355 } },
                { "Improved Concussive Shot", group = 1, bar = 1, icon = 135860, seen = { 19410 } },
                { "Improved Hamstring", group = 1, bar = 1, icon = 132316, seen = { 23694 } },
                { "Improved Wing Clip", group = 1, bar = 1, icon = 132309, seen = { 19229 } },
                { "Intercept Stun", group = 1, bar = 1, icon = 135860, seen = { 20615 } },
                { "Intimidating Shout", group = 1, bar = 1, icon = 132154, seen = { 5246, 19134, 20511, 29544 } },
                { "Intimidation", group = 1, bar = 1 },
                { "Kidney Shot", group = 1, bar = 1, icon = 132298, seen = { 8643 } },
                { "Mace Stun Effect", group = 1, bar = 1, icon = 135860, seen = { 5530 } },
                { "Mind Control", group = 1, bar = 1, icon = 136206, seen = { 10912 } },
                { "Net-o-Matic", group = 1, bar = 1, icon = 132149, seen = { 13099, 13119, 16566 } },
                { "Polymorph", group = 1, bar = 1, icon = 136071, seen = { 118, 12824, 12825, 12826, 28271, 28272, 29848 } },
                { "Polymorph: Cow", group = 1, bar = 1 },
                { "Pounce", group = 1, bar = 1 },
                { "Psychic Scream", group = 1, bar = 1, icon = 136184, seen = { 8122, 10888, 10890, 13704 } },
                { "Reckless Charge", group = 1, bar = 1, icon = 136010, seen = { 13327 } },
                { "Repentance", group = 1, bar = 1, icon = 135942, seen = { 20066 } },
                { "Revenge Stun", group = 1, bar = 1 },
                { "Sap", group = 1, bar = 1, icon = 132310, seen = { 6770, 11297 } },
                { "Scare Beast", group = 1, bar = 1, icon = 132118, seen = { 14327 } },
                { "Scatter Shot", group = 1, bar = 1, icon = 132153, seen = { 19503 } },
                { "Seduction", group = 1, bar = 1, icon = 136175, seen = { 6358 } },
                { "Shackle Undead", group = 1, bar = 1, icon = 136091, seen = { 10955 } },
                { "Sleep", group = 1, bar = 1, icon = 136090, seen = { 1090, 24004 } },
                { "Starfire Stun", group = 1, bar = 1, icon = 135753, seen = { 16922 } },
                { "Stun", group = 1, bar = 1, icon = 135860, seen = { 20170, 23454 } },
                { "Tidal Charm", group = 1, bar = 1, icon = 135861, seen = { 835 } },
                { "Turn Undead", group = 1, bar = 1, icon = 135983, seen = { 5627, 10326 } },
                { "War Stomp", group = 1, bar = 1, icon = 132091, seen = { 20549, 24375, 27758 } },
                { "Chilled", group = 2, icon = 135843, seen = { 6136, 7321, 12484, 12486, 20005 } },
                { "Concussive Shot", group = 2, icon = 135860, seen = { 5116 } },
                { "Cone of Cold", group = 2, icon = 135852, seen = { 120, 10161, 30095 } },
                { "Crippling Poison", group = 2, icon = 132274, seen = { 3409, 11201, 25809 } },
                { "Curse of Exhaustion", group = 2 },
                { "Dazed", group = 2, icon = 135860, seen = { 1604, 15571 } },
                { "Earthbind", group = 2, icon = 136102, seen = { 3600 } },
                { "Frost Shock", group = 2, icon = 135849, seen = { 10473 } },
                { "Frostbolt", group = 2, icon = 135846, seen = { 116, 837, 8406, 10181, 25304, 28478, 28479, 350025 } },
                { "Frostbrand Attack", group = 2 },
                { "Hamstring", group = 2, icon = 132316, seen = { 1715, 7372, 7373, 26141 } },
                { "Piercing Howl", group = 2, icon = 136147, seen = { 12323 } },
                { "Wing Clip", group = 2, icon = 132309, seen = { 2974, 14267, 14268 } },
                { "Blood Fury", group = 3, icon = 132293, seen = { 23230 } },
                { "Death Wish", group = 3, icon = 136146, seen = { 12328 } },
                { "Faerie Fire", icon = 136033, seen = { 778, 9907 } },
            },
        },
        buffs = {
            groups = {
                { "Stance / Forms", collapsed = true },
                { "Defensive CDs", collapsed = true },
                { "Offensive Cds", collapsed = true },
                { "Consumables", collapsed = true },
                { "Buffs >:)", collapsed = true },
            },
            list = {
                -- Every one of these carries bar = 2, the Stance frame. They are
                -- one question — "what is he in?" — and they answer it one at a
                -- time, so the whole group belongs in a single fixed spot off the
                -- side of the plate rather than shuffling along a shared row
                -- behind whatever else he happens to be wearing.
                { "Aquatic Form", group = 1, bar = 2 },
                { "Aspect of the Beast", group = 1, bar = 2 },
                { "Aspect of the Cheetah", group = 1, bar = 2, icon = 132242, seen = { 5118 } },
                { "Aspect of the Hawk", group = 1, bar = 2, icon = 136076, seen = { 13165, 14318, 14319, 14320, 14321, 14322, 25296 } },
                { "Aspect of the Monkey", group = 1, bar = 2, icon = 132159, seen = { 13163 } },
                { "Aspect of the Pack", group = 1, bar = 2, icon = 132267, seen = { 13159 } },
                { "Aspect of the Viper", group = 1, bar = 2 },
                { "Aspect of the Wild", group = 1, bar = 2, icon = 136074, seen = { 20190 } },
                { "Battle Stance", group = 1, bar = 2, icon = 132349, seen = { 2457, 7165 } },
                { "Bear Form", group = 1, bar = 2, icon = 132276, seen = { 5487 } },
                { "Berserker Stance", group = 1, bar = 2, icon = 132275, seen = { 2458 } },
                { "Cat Form", group = 1, bar = 2, icon = 132115, seen = { 768 } },
                { "Concentration Aura", group = 1, bar = 2, icon = 135933, seen = { 19746 } },
                { "Defensive Stance", group = 1, bar = 2, icon = 132341, seen = { 71, 7164 } },
                { "Devotion Aura", group = 1, bar = 2, icon = 135893, seen = { 465, 643, 1032, 10290, 10291, 10292, 10293 } },
                { "Dire Bear Form", group = 1, bar = 2, icon = 132276, seen = { 9634 } },
                { "Fire Resistance Aura", group = 1, bar = 2, icon = 135824, seen = { 19891, 19900 } },
                { "Frost Resistance Aura", group = 1, bar = 2, icon = 135865, seen = { 19897, 19898 } },
                { "Ghost Wolf", group = 1, bar = 2 },
                { "Moonkin Form", group = 1, bar = 2, icon = 136036, seen = { 24858 } },
                { "Retribution Aura", group = 1, bar = 2, icon = 135873, seen = { 7294, 10298, 10299, 10300, 10301 } },
                { "Shadow Resistance Aura", group = 1, bar = 2, icon = 136192, seen = { 19876, 19896 } },
                { "Travel Form", group = 1, bar = 2, icon = 132144, seen = { 783 } },
                { "Aura of Protection", group = 2, icon = 135893, seen = { 23506 } },
                { "Barkskin", group = 2 },
                { "Blessing of Freedom", group = 2, icon = 135968, seen = { 1044 } },
                { "Blessing of Protection", group = 2, icon = 135964, seen = { 10278 } },
                { "Blessing of Sacrifice", group = 2 },
                { "Deterrence", group = 2, icon = 132369, seen = { 19263 } },
                { "Divine Protection", group = 2, icon = 135954, seen = { 498, 5573 } },
                { "Divine Shield", group = 2, icon = 135896, seen = { 642, 1020 } },
                { "Fear Ward", group = 2, icon = 135902, seen = { 6346 } },
                { "Fire Ward", group = 2, icon = 135806, seen = { 8458, 10223, 10225 } },
                { "Frost Reflector", group = 2 },
                { "Ice Barrier", group = 2, icon = 135988, seen = { 11426, 13031, 13032, 13033 } },
                { "Ice Block", group = 2, icon = 135841, seen = { 11958 } },
                { "Innervate", group = 2, icon = 136048, seen = { 29166 } },
                { "Mana Shield", group = 2, icon = 136153, seen = { 1463, 8494, 10191, 10192, 10193 } },
                { "Power Word: Shield", group = 2, icon = 135940, seen = { 17, 592, 600, 3747, 6065, 6066, 10898, 10900, 10901 } },
                { "Restoration", group = 2 },
                { "Sacrifice", group = 2, icon = 136190, seen = { 19443 } },
                { "Self Invulnerability", group = 2 },
                { "Shadow Reflector", group = 2, icon = 136121, seen = { 23132 } },
                { "Stoneform", group = 2, icon = 136225, seen = { 20594 } },
                { "The Burrower's Shell", group = 2, icon = 135893, seen = { 29506 } },
                { "Adrenaline Rush", group = 3, icon = 136206, seen = { 13750 } },
                { "Arcane Power", group = 3, icon = 136048, seen = { 12042 } },
                { "Berserker Rage", group = 3, icon = 136009, seen = { 18499 } },
                { "Berserking", group = 3, icon = 135727, seen = { 26635 } },
                { "Bestial Wrath", group = 3 },
                { "Cold Blood", group = 3, icon = 135988, seen = { 14177 } },
                { "Elemental Mastery", group = 3, icon = 136115, seen = { 16166 } },
                { "Nature's Swiftness", group = 3, icon = 136076, seen = { 16188, 17116 } },
                { "Power Infusion", group = 3, icon = 135939, seen = { 10060 } },
                { "Rapid Fire", group = 3, icon = 132208, seen = { 3045 } },
                { "Recklessness", group = 3, icon = 132109, seen = { 1719 } },
                { "Arcane Protection", group = 4, icon = 135943, seen = { 17549 } },
                { "Fire Protection", group = 4, icon = 135806, seen = { 17543, 29432 } },
                { "Free Action", group = 4, icon = 134715, seen = { 6615 } },
                { "Frost Protection", group = 4, icon = 135843, seen = { 17544 } },
                { "Invulnerability", group = 4, icon = 135896, seen = { 3169 } },
                { "Living Free Action", group = 4, icon = 134718, seen = { 24364 } },
                { "Nature Protection", group = 4 },
                -- World buffs. Every one of them is an hour or two long and they
                -- all stack, so unlike the group above this one can genuinely be
                -- wearing all eleven at once — which is the point of seeing it on
                -- an enemy plate at all.
                --
                -- No `icon` on any of them: `seen` is enough. Data.AuraDisplay
                -- resolves art off the first seen ID it can, and every ID here is
                -- one the client will answer for, so writing the file IDs out by
                -- hand would only be a second place for them to be wrong. The
                -- second ID, where there is one, is the newer build's.
                { "Fengus' Ferocity", group = 5, seen = { 22817 } },
                { "Mol'dar's Moxie", group = 5, seen = { 22818 } },
                { "Rallying Cry of the Dragonslayer", group = 5, seen = { 22888, 355363 } },
                { "Sayge's Dark Fortune of Damage", group = 5, seen = { 23768 } },
                { "Sayge's Dark Fortune of Intelligence", group = 5, seen = { 23766 } },
                { "Sayge's Dark Fortune of Resistance", group = 5, seen = { 23769 } },
                { "Sayge's Dark Fortune of Spirit", group = 5, seen = { 23767 } },
                { "Slip'kik's Savvy", group = 5, seen = { 22820 } },
                { "Songflower Serenade", group = 5, seen = { 15366 } },
                { "Spirit of Zandalar", group = 5, seen = { 24425, 355365 } },
                { "Warchief's Blessing", group = 5, seen = { 16609, 355366 } },
            },
        },
    },
}

-- One entry, in the shape Data.AddAura leaves behind. Built here rather than put
-- through AddAura because that one resolves a name against the client's spellbook
-- and the learned catalogue, neither of which knows anything about a hostile
-- class's abilities — it would throw away the art the seed is carrying.
local function seedEntry(list, def, groupIDs, barIDs)
    local key, id, name = Data.AuraKeyFor(def.id or def[1])
    if not key or list[key] then return end

    local entry = { enabled = true, id = id, name = name or def[1] }
    entry.icon  = def.icon
    entry.group = def.group and groupIDs[def.group] or nil
    entry.bar   = def.bar   and barIDs[def.bar]     or nil
    if def.seen then
        local seen = {}
        for _, spellID in ipairs(def.seen) do seen[spellID] = true end
        entry.seen = seen
    end
    list[key] = entry
end

-- The seed's `bar` INDEXES turned into this profile's real frame ids.
--
-- A frame that is already here, matched by name, is reused exactly as it stands —
-- moved, resized, renamed off the seed's list, it does not matter. Only the ones
-- missing are created. On a fresh profile there are none, so this is the plain
-- "add all of them" it was written as; on a restore it is what stops the button
-- shoving a frame somebody placed back to where it shipped.
local function resolveBars(unitKey, def)
    local byName = {}
    for _, bar in ipairs(Data.SpecialBars(unitKey)) do
        byName[(bar.name or ""):lower()] = bar.id
    end

    local barIDs = {}
    for i, b in ipairs(def.bars or {}) do
        local id = byName[b.name:lower()]
        if not id then
            local bar = Data.AddSpecialBar(unitKey, b.name)
            if bar then
                for k, v in pairs(b) do
                    if k ~= "name" then bar[k] = v end
                end
                id = bar.id
            end
        end
        -- Left nil where the frame cap is already full: the entries that wanted it
        -- land on the row above the health bar, which is where an entry with no
        -- frame goes anyway.
        barIDs[i] = id
    end
    return barIDs
end

-- One list: its headings, then its entries. Returns how many entries went in, so
-- the restore button can say. Assumes the caller has decided what to do with
-- whatever was there before — this only adds.
local function seedRow(unitKey, which, row, barIDs)
    local groupIDs = {}
    for i, g in ipairs(row.groups or {}) do
        local group = Data.AddAuraGroup(unitKey, which, g[1])
        if group then
            -- Folded away as shipped, bar the one the list is really about:
            -- sixty entries under four open headings is a wall, and a heading you
            -- have to open is a heading you read.
            group.collapsed = g.collapsed and true or nil
            groupIDs[i] = group.id
        end
    end

    local list = Data.AuraList(unitKey, which)
    if not list then return 0 end

    local n = 0
    for _, e in ipairs(row.list or {}) do
        seedEntry(list, e, groupIDs, barIDs)
        n = n + 1
    end
    return n
end

-- Everything one unit type starts with. Split out so EnsureAuraSeed below reads
-- as the guard it is rather than as three levels of loop.
local function seedUnit(unitKey, def)
    -- Frames first: the whitelist entries underneath point at them, and an index
    -- can only be turned into an id once the id exists.
    local barIDs = resolveBars(unitKey, def)
    for _, which in ipairs({ "buffs", "debuffs" }) do
        if def[which] then seedRow(unitKey, which, def[which], barIDs) end
    end
end

-- ── Restore ──────────────────────────────────────────────────────────────────
-- Puts one unit type's whitelists back to what it ships with, on demand, however
-- far from them the profile has drifted. The seed is a once-per-profile thing by
-- design; this is the way back to it, and the only caller is the button on the
-- Aura Tracking page.
--
-- Both lists together rather than one at a time. The seed's headings and its
-- frame assignments span the pair — the CC frame takes debuffs and the Stance
-- frame takes buffs — and half a restore would be a setup that never shipped.
--
-- REPLACES rather than merges: the lists and their headings are cleared first, so
-- what comes out is exactly a fresh profile's, not a fresh profile's plus
-- whatever had accumulated. Frames are the exception, and are left where they are
-- — see resolveBars.
function Data.RestoreAuraDefaults(unitKey)
    local def = SEED[unitKey]
    if not (def and Data.Get()) then return 0 end

    -- Before the lists go, since an entry's frame is resolved through this and
    -- adding a frame is the one part of a restore that can fail (the cap).
    local barIDs = resolveBars(unitKey, def)

    local n = 0
    for _, which in ipairs({ "buffs", "debuffs" }) do
        if def[which] then
            Data.ClearAuraList(unitKey, which)
            n = n + seedRow(unitKey, which, def[which], barIDs)
        end
    end

    Data.InvalidateAuras()
    return n
end

-- Fills a profile that has never been seeded. Safe to call as often as you like:
-- it is a no-op once the flag has caught up, which is what makes deleting a
-- seeded entry stick.
--
-- Per unit type rather than all or nothing, so a profile someone set up for
-- enemy players and never touched for NPCs still gets the NPC half.
function Data.EnsureAuraSeed()
    local d = Data.Get()
    if not d then return end
    d.auras = d.auras or {}
    if (d.auras.seed or 0) >= Data.AURA_SEED_VERSION then return end

    for _, unit in ipairs(Data.AURA_UNITS) do
        local def = SEED[unit.key]
        local s   = def and Data.SpecialBlock(unit.key)
        -- Empty means empty on every count: no frames, and neither whitelist
        -- holding anything. A profile with so much as one entry of its own has
        -- been set up, and a default is not something to set up over the top.
        if s and #s.bars == 0
            and next(Data.AuraList(unit.key, "buffs")   or {}) == nil
            and next(Data.AuraList(unit.key, "debuffs") or {}) == nil then
            seedUnit(unit.key, def)
            -- Claims the older single-frame seed as well: that one adds a
            -- "Special Buffs" frame to any profile whose flag is behind, and the
            -- frames above are what this profile is having instead of it.
            s.seed = Data.SPECIAL_SEED_VERSION
        end
    end

    d.auras.seed = Data.AURA_SEED_VERSION
    Data.InvalidateAuras()
end
