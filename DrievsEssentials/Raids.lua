local addonName, addon = ...

-- Bosses are { name, id, default? }. `id` is the WoW encounter ID emitted by
-- ENCOUNTER_START/ENCOUNTER_END. `default = true` means the checkbox is
-- pre-ticked on first init (matches the original WeakAura's encounter list).
--
-- IDs marked with -- ✓ are confirmed (came from the user's WeakAura or the
-- Stockades list). The rest are best-guess at Classic Era encounter IDs —
-- enable the Debug master toggle in-game and the addon will print live
-- ENCOUNTER_START ids to chat so wrong ones can be corrected here.
addon.RAIDS = {
    {
        key   = "naxx",
        label = "Naxx",
        name  = "Naxxramas",
        -- `wing` groups bosses for colour-coding in the Particles boss list.
        bosses = {
            { name = "Anub'Rekhan",           id = 1107, wing = "spider" },
            { name = "Grand Widow Faerlina",  id = 1110, default = true, wing = "spider" }, -- ✓
            { name = "Maexxna",               id = 1116, wing = "spider" },
            { name = "Noth the Plaguebringer",id = 1117, wing = "plague" },
            { name = "Heigan the Unclean",    id = 1112, wing = "plague" },
            { name = "Loatheb",               id = 1115, wing = "plague" },
            { name = "Instructor Razuvious",  id = 1113, wing = "military" },
            { name = "Gothik the Harvester",  id = 1109, wing = "military" },
            { name = "The Four Horsemen",     id = 1121, default = true, wing = "military" }, -- ✓
            { name = "Patchwerk",             id = 1118, wing = "construct" },
            { name = "Grobbulus",             id = 1111, default = true, wing = "construct" }, -- ✓
            { name = "Gluth",                 id = 1108, wing = "construct" },
            { name = "Thaddius",              id = 1120, wing = "construct" },
            { name = "Sapphiron",             id = 1119, default = true, wing = "frostwyrm" }, -- ✓
            { name = "Kel'Thuzad",            id = 1114, default = true, wing = "frostwyrm" }, -- ✓
        },
    },
    {
        key   = "aq40",
        label = "AQ40",
        name  = "Temple of Ahn'Qiraj",
        bosses = {
            { name = "The Prophet Skeram",     id = 709  },
            { name = "Bug Trio",               id = 710,  default = true }, -- ✓
            { name = "Battleguard Sartura",    id = 711  },
            { name = "Fankriss the Unyielding",id = 712  },
            { name = "Viscidus",               id = 713,  default = true }, -- ✓
            { name = "Princess Huhuran",       id = 714  },
            { name = "Twin Emperors",          id = 715,  default = true }, -- ✓
            { name = "Ouro",                   id = 716,  default = true }, -- ✓
            { name = "C'Thun",                 id = 717,  default = true }, -- ✓
        },
    },
    {
        key   = "bwl",
        label = "BWL",
        name  = "Blackwing Lair",
        bosses = {
            { name = "Razorgore the Untamed",    id = 610 },
            { name = "Vaelastrasz the Corrupt",  id = 611 },
            { name = "Broodlord Lashlayer",      id = 612 },
            { name = "Firemaw",                  id = 613 },
            { name = "Ebonroc",                  id = 614 },
            { name = "Flamegor",                 id = 615 },
            { name = "Chromaggus",               id = 616 },
            { name = "Nefarian",                 id = 617 },
        },
    },
    {
        key   = "mc",
        label = "MC",
        name  = "Molten Core",
        bosses = {
            { name = "Lucifron",                 id = 663 },
            { name = "Magmadar",                 id = 664 },
            { name = "Gehennas",                 id = 665 },
            { name = "Garr",                     id = 666 },
            { name = "Shazzrah",                 id = 667 },
            { name = "Baron Geddon",             id = 668,  default = true }, -- ✓
            { name = "Sulfuron Harbinger",       id = 669 },
            { name = "Golemagg the Incinerator", id = 670 },
            { name = "Majordomo Executus",       id = 671 },
            { name = "Ragnaros",                 id = 672 },
        },
    },
    {
        key   = "aq20",
        label = "AQ20",
        name  = "Ruins of Ahn'Qiraj",
        bosses = {
            { name = "Kurinnaxx",              id = 718 },
            { name = "General Rajaxx",         id = 719 },
            { name = "Moam",                   id = 720 },
            { name = "Buru the Gorger",        id = 721 },
            { name = "Ayamiss the Hunter",     id = 722 },
            { name = "Ossirian the Unscarred", id = 723 },
        },
    },
    {
        key   = "zg",
        label = "ZG",
        name  = "Zul'Gurub",
        bosses = {
            { name = "High Priestess Jeklik",  id = 785 },
            { name = "High Priest Venoxis",    id = 784, default = true }, -- ✓
            { name = "High Priestess Mar'li",  id = 791 },
            { name = "Bloodlord Mandokir",     id = 787 },
            { name = "Edge of Madness",        id = 789 },
            { name = "High Priest Thekal",     id = 788 },
            { name = "Gahz'ranka",             id = 792 },
            { name = "High Priestess Arlokk",  id = 790 },
            { name = "Jin'do the Hexxer",      id = 786 },
            { name = "Hakkar",                 id = 793, default = true }, -- ✓
        },
    },
    {
        key   = "debug",
        label = "Debug",
        name  = "The Stockades",
        bosses = {
            { name = "Targorr the Dread", id = 2756, default = true }, -- ✓
            { name = "Kam Deepfury",      id = 2757, default = true }, -- ✓
            { name = "Hamhock",           id = 2758, default = true }, -- ✓
            { name = "Dextren Ward",      id = 2759, default = true }, -- ✓
            { name = "Bazil Thredd",      id = 2760, default = true }, -- ✓
        },
    },
}
