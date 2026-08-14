local addonName, addon = ...

-- ── Generic font handler ─────────────────────────────────────────────────────
-- Every configurable font in the addon — the TTK counter, swing timer strings,
-- nameplate text, keybind text, chat — is stored as ONE table shape and painted
-- by ONE function, so a font is customized the same way wherever you find it:
--
--   { font, size, outline, color, x, y, shadowColor, shadowX, shadowY }
--
-- Modules used to each carry their own subset of that (a bare face name here, a
-- face plus size there), which is why the same setting had a different name and
-- a different set of neighbours in every panel. Anything holding a font block
-- now gets the full set for free, and UI.widgets.buildFontOptions lays those
-- eight controls out in one fixed order.
--
-- Nothing here reads the saved variables itself: a caller hands in the block it
-- owns plus its own defaults, so this file has no opinion about where in the
-- profile a font lives.

local Font = {}
addon.Font = Font

-- The client's own face, since a missing LSM entry must still render something.
-- STANDARD_TEXT_FONT is the locale-correct one where the client defines it.
Font.DEFAULT_PATH = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
Font.DEFAULT_NAME = "Friz Quadrata TT"   -- LSM's name for the same file

-- SetFont takes these as a flag string; "NONE" is this addon's stored spelling
-- for "no flags", since an empty string in a dropdown reads as a missing value.
Font.OUTLINES = {
    { value = "NONE",         label = "None"          },
    { value = "OUTLINE",      label = "Outline"       },
    { value = "THICKOUTLINE", label = "Thick outline" },
}

-- Shared limits, so the same setting can't offer ±10 in one panel and ±200 in
-- the next. Offsets are generous because a font block also positions text that
-- sits beside its element rather than inside it.
Font.SIZE_MIN     = 6
Font.SIZE_MAX     = 64
Font.OFFSET_RANGE = 200
Font.SHADOW_RANGE = 10

-- The shipped block. Modules override what they need through Font.New rather
-- than restating the whole shape.
Font.DEFAULTS = {
    font        = Font.DEFAULT_NAME,
    size        = 12,
    outline     = "OUTLINE",
    -- The colour is an OVERRIDE, off until asked for: most text in this addon
    -- already gets a colour from somewhere (a class-coloured name, a level's
    -- difficulty colour, LibActionButton's own grey), and a colour that applied
    -- the moment the block existed would silently flatten all of it.
    colorEnabled = false,
    color       = { 1, 1, 1 },
    x           = 0,
    y           = 0,
    shadowColor = { 0, 0, 0 },
    shadowX     = 0,
    shadowY     = 0,
}

-- A fresh defaults block for a module's DEFAULTS table:
--   addon.Font.New({ size = 24, outline = "THICKOUTLINE" })
-- Always a new table (including a new shadowColor), or two modules would share
-- one colour table and recolouring either would recolour both.
function Font.New(overrides)
    local t = {}
    for k, v in pairs(Font.DEFAULTS) do
        t[k] = (type(v) == "table") and { v[1], v[2], v[3] } or v
    end
    if overrides then
        for k, v in pairs(overrides) do
            t[k] = (type(v) == "table") and { v[1], v[2], v[3] } or v
        end
    end
    return t
end

-- ── Reading ──────────────────────────────────────────────────────────────────
-- Every getter below takes (cfg, def) and tolerates either being nil or, in
-- cfg's case, being the bare LSM name string a pre-font-block profile saved.
-- That last case is what lets a module adopt the new shape without a migration
-- step running before every read.
local function resolve(cfg, def, key)
    if type(cfg) == "table" and cfg[key] ~= nil then return cfg[key] end
    if type(def) == "table" and def[key] ~= nil then return def[key] end
    return Font.DEFAULTS[key]
end

-- The LSM name, honouring a legacy string-valued block.
function Font.Name(cfg, def)
    if type(cfg) == "string" then return cfg end
    return resolve(cfg, def, "font")
end

-- Always a usable file path — a FontString whose SetFont failed renders nothing
-- at all, so an uninstalled font must never reach SetFont as nil.
function Font.Path(cfg, def)
    return addon.FetchMedia("font", Font.Name(cfg, def)) or Font.DEFAULT_PATH
end

-- SetFont flags. "NONE" is stored, "" is what the client wants.
function Font.Flags(cfg, def)
    local flags = resolve(cfg, def, "outline")
    if flags == "NONE" or flags == nil then return "" end
    return flags
end

function Font.Size(cfg, def)
    return tonumber(resolve(cfg, def, "size")) or Font.DEFAULTS.size
end

-- How far the text is nudged from wherever its owner anchors it. Returned
-- rather than applied, since every element has its own idea of where "normally"
-- is; callers add these to their own placement.
function Font.Offsets(cfg, def)
    return tonumber(resolve(cfg, def, "x")) or 0, tonumber(resolve(cfg, def, "y")) or 0
end

-- Whether the custom colour is switched on for this block.
function Font.ColorEnabled(cfg, def)
    return resolve(cfg, def, "colorEnabled") and true or false
end

-- The colour STORED in the block, whether or not it is switched on — this is
-- what the settings swatch shows, so that unticking the box and ticking it again
-- gets the same colour back rather than a reset.
function Font.Color(cfg, def)
    local c = resolve(cfg, def, "color")
    if type(c) ~= "table" then return 1, 1, 1 end
    return c[1] or 1, c[2] or 1, c[3] or 1
end

-- The colour to actually paint with: the block's when its box is ticked, and the
-- caller's own answer — the colour that text would have had anyway — when it
-- isn't. Kept out of Font.Apply on purpose; see ApplyColor.
function Font.ColorOr(cfg, def, r, g, b)
    if Font.ColorEnabled(cfg, def) then return Font.Color(cfg, def) end
    return r or 1, g or 1, b or 1
end

function Font.ShadowColor(cfg, def)
    local c = resolve(cfg, def, "shadowColor")
    if type(c) ~= "table" then return 0, 0, 0 end
    return c[1] or 0, c[2] or 0, c[3] or 0
end

function Font.ShadowOffsets(cfg, def)
    return tonumber(resolve(cfg, def, "shadowX")) or 0, tonumber(resolve(cfg, def, "shadowY")) or 0
end

-- ── Painting ─────────────────────────────────────────────────────────────────
-- A shadow at no offset sits directly behind the glyph and only muddies its
-- antialiased edges, so zero offset means no shadow rather than needing a
-- separate toggle to say so — which is also why the shadow colour is a live
-- setting even while nothing is drawn.
function Font.ApplyShadow(fs, cfg, def)
    if not (fs and fs.SetShadowColor) then return end
    local r, g, b = Font.ShadowColor(cfg, def)
    local sx, sy  = Font.ShadowOffsets(cfg, def)
    fs:SetShadowColor(r, g, b, (sx ~= 0 or sy ~= 0) and 1 or 0)
    fs:SetShadowOffset(sx, sy)
end

-- The block's colour, applied to the text itself — but only where its box is
-- ticked. `r, g, b` is what that text is otherwise coloured, and is what gets
-- painted while the override is off; leave it out and an unticked block leaves
-- the string's colour alone entirely.
--
-- Separate from Apply, and never folded into it, because plenty of this addon's
-- text is coloured by something other than a setting — a class-coloured name, a
-- level's difficulty colour, a health ramp. Those are decided on a different
-- tick from the one that styles the font, so a colour inside Apply would paint
-- over them every time the layout was re-derived. Each caller therefore places
-- this call where it knows nothing dynamic is going to want the colour instead.
function Font.ApplyColor(fs, cfg, def, r, g, b)
    if not (fs and fs.SetTextColor) then return end
    if not (Font.ColorEnabled(cfg, def) or r) then return end
    fs:SetTextColor(Font.ColorOr(cfg, def, r, g, b))
end

-- Face, size, flags and shadow — but NOT colour (see ApplyColor). Returns the
-- x/y offsets so a caller that owns the anchoring can fold them into its own
-- placement:
--
--   local dx, dy = addon.Font.Apply(fs, cfg, def)
--   fs:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -2 + dx, -2 + dy)
--
-- `sizeOverride` is for the elements sized by something other than the block
-- (a nameplate's cast text tracks its bar height); everything else about the
-- font still comes from the block.
function Font.Apply(fs, cfg, def, sizeOverride)
    if not (fs and fs.SetFont) then return 0, 0 end
    local size  = tonumber(sizeOverride) or Font.Size(cfg, def)
    local flags = Font.Flags(cfg, def)
    -- SetFont returns false when the client rejects a file, which leaves the
    -- string invisible — so a rejected face falls back rather than being trusted.
    if fs:SetFont(Font.Path(cfg, def), size, flags) == false then
        fs:SetFont(Font.DEFAULT_PATH, size, flags)
    end
    Font.ApplyShadow(fs, cfg, def)
    return Font.Offsets(cfg, def)
end

-- Apply plus re-seat, for the callers whose placement is entirely the block's.
-- Two anchor shapes:
--
--   { point = "TOPRIGHT", relativeTo = f, relativePoint = "TOPRIGHT",
--     x = -2, y = -2, justifyH = "RIGHT" }
--       one point, with the block's offsets added to x/y.
--
--   { fill = frame, inset = 4, justifyH = "LEFT" }
--       pinned to both corners of `fill` and justified inside it. Use this
--       wherever the text is edge-aligned in a box: an edge-anchored FontString
--       is sized to its own content and a drop shadow is PART of that content,
--       so moving the shadow would drag the glyphs the other way. A fixed box
--       can't be pushed around by what's drawn inside it.
function Font.ApplyAt(fs, cfg, def, anchor, sizeOverride)
    local dx, dy = Font.Apply(fs, cfg, def, sizeOverride)
    if not anchor then return dx, dy end

    fs:ClearAllPoints()
    if anchor.fill then
        local inset = anchor.inset or 0
        fs:SetPoint("TOPLEFT",      anchor.fill, "TOPLEFT",       inset + dx,  dy)
        fs:SetPoint("BOTTOMRIGHT",  anchor.fill, "BOTTOMRIGHT",  -inset + dx,  dy)
        fs:SetJustifyV(anchor.justifyV or "MIDDLE")
    else
        local point = anchor.point or "CENTER"
        fs:SetPoint(point, anchor.relativeTo or fs:GetParent(),
            anchor.relativePoint or point,
            (anchor.x or 0) + dx, (anchor.y or 0) + dy)
    end
    if anchor.justifyH then fs:SetJustifyH(anchor.justifyH) end
    return dx, dy
end

-- ── Storage ──────────────────────────────────────────────────────────────────
-- The live block under `parent[key]`, created on demand. Settings panels read
-- through this so a profile that predates the setting still edits something.
function Font.Block(parent, key)
    if type(parent) ~= "table" then return nil end
    if type(parent[key]) ~= "table" then parent[key] = {} end
    return parent[key]
end

-- One-time upgrade of a profile written before the block existed. `map` names
-- the old flat keys, e.g.
--
--   addon.Font.Adopt(d, "font", { font = "fontName", size = "fontSize" })
--
-- A string already sitting at parent[key] is taken as the face — that is what
-- every module stored before this file, so it needs no entry in the map.
--
-- The old keys are cleared afterwards, which is only safe because they have
-- also been dropped from the module's DEFAULTS: applyDefaults refills anything
-- still declared there at the next login, and a cleared key that comes back
-- would overwrite the block again on every load.
-- Registers Adopt as a profile migration, which is where the upgrade really has
-- to happen: applyDefaults runs at login and would otherwise have replaced a
-- saved face name with a freshly defaulted block before anything read it. See
-- addon.RegisterMigration.
--
--   addon.Font.MigrateBlock(function(s) return s.itemRack end, "hotkeyFont",
--       { size = "hotkeyFontSize", x = "hotkeyOffsetX", y = "hotkeyOffsetY" })
--
-- `locate` is handed the profile's `settings` table and returns the table the
-- block lives in, or nil when this profile never had that module.
function Font.MigrateBlock(locate, key, map)
    addon.RegisterMigration(function(prof)
        local settings = prof.settings
        if type(settings) ~= "table" then return end
        local parent = locate(settings)
        if type(parent) == "table" then Font.Adopt(parent, key, map) end
    end)
end

function Font.Adopt(parent, key, map)
    if type(parent) ~= "table" then return end

    local legacyName
    if type(parent[key]) == "string" then
        legacyName  = parent[key]
        parent[key] = nil
    end
    if type(parent[key]) == "table" and not legacyName and not map then return parent[key] end

    local block = Font.Block(parent, key)
    if legacyName and block.font == nil then block.font = legacyName end

    if map then
        for field, oldKey in pairs(map) do
            local v = parent[oldKey]
            if v ~= nil then
                if block[field] == nil then block[field] = v end
                parent[oldKey] = nil
            end
        end
    end
    return block
end
