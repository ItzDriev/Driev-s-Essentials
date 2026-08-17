local addonName, addon = ...

addon.version = "1.3.4"
addon.title   = "Driev's Essentials"

-- Public event bus for addons that don't use WeakAuras (TTK.lua uses
-- WeakAuras.ScanEvents, which only reaches WeakAuras users). Global so external
-- addons can reach it without our private namespace table.
addon.callbacks = LibStub("CallbackHandler-1.0"):New(addon)
_G.DrievEssentials = addon

-- Vanilla class roster for the particle per-class filter. Token must match
-- UnitClass("player")'s classFileName.
addon.CLASSES = {
    { token = "WARRIOR", label = "Warrior" },
    { token = "PALADIN", label = "Paladin" },
    { token = "HUNTER",  label = "Hunter"  },
    { token = "ROGUE",   label = "Rogue"   },
    { token = "PRIEST",  label = "Priest"  },
    { token = "SHAMAN",  label = "Shaman"  },
    { token = "MAGE",    label = "Mage"    },
    { token = "WARLOCK", label = "Warlock" },
    { token = "DRUID",   label = "Druid"   },
}

-- Defaults are kept tiny on purpose; merged into SavedVariables on first load.
local defaults = {
    minimap = {
        hide  = false,
        angle = 225,
    },
    settings = {
        ttk = {
            enabled  = false,
            bossOnly = false,
            -- The shared font block (Font.lua): face, size, outline, offsets and
            -- shadow, the same eight settings every other text in the addon has.
            -- The old fontName/fontSize pair is folded into it on first load and
            -- is deliberately no longer declared here — see addon.Font.Adopt.
            font     = addon.Font.New({ size = 24 }),
        },
        tooltip = {
            enabled        = false, -- master toggle for the whole skin
            colorByUnit    = true,  -- border colored by class (players) / reaction (NPCs)
            showHealth     = true,  -- append a "current / max (pct%)" line on unit tooltips
            hideRealm      = false, -- strip "-Realmname" from the name line
            anchorCursor   = false, -- follow the mouse instead of Blizzard's default anchor
            useAnchor      = false, -- park it on the movable anchor instead
            anchorX        = nil,   -- anchor position, absent until first moved
            anchorY        = nil,
            healthBorder   = true,  -- class-colored outline around the health bar
            customBorder   = false, -- use borderColor below instead of class/reaction
            borderColor    = { 0.30, 0.31, 0.42 },
            bgColor        = { 0.090, 0.098, 0.165 },
            bgOpacity      = 100,
        },
        editBarX      = nil,  -- Edit Mode control box position, absent until moved
        editBarY      = nil,
        editAlpha     = 0.4,
        editPad       = 4,    -- extra px the edit-mode box extends beyond each element
        editBorder    = 1,    -- edit-mode box border thickness
        moveBgOpacity = 15,   -- % scaling the Move UI dimmed background + grid lines
        moveBgEnabled = true, -- whether the Move UI dimmed background + grid show at all
        uiScale       = 1,    -- settings window scale (the slider next to Edit Mode)
        -- Palette overrides keyed by UI.lua's C table names, holding { r, g, b, a }.
        -- Only changed entries are stored, so later palette tweaks still reach users.
        uiColors      = {},
        editParked    = {},   -- module labels parked (unticked) in the Edit Mode Modules list
        editOffscreen = false,-- let elements be dragged (mostly) past the screen edge
        -- settingsWinW/H (last dragged size) are absent until the user resizes;
        -- createMainFrame() falls back to a built-in default.
    },
}

-- Settings keys registered by a module rather than declared in `defaults` above.
-- Only used to decide what the General section's catch-all may swallow — see
-- sectionSettingsKeys().
local moduleSettingsKeys = {}

-- Module addons register their own settings block here at load time, so core
-- doesn't need to know they exist. Everything loads before PLAYER_LOGIN, which
-- is when defaults are merged. A disabled module's settings stay untouched.
function addon.RegisterDefaults(key, tbl)
    defaults.settings[key] = tbl
    moduleSettingsKeys[key] = true
end

-- Shared opacity for every edit-mode box, so one slider controls them all.
function addon.GetEditAlpha()
    return (addon.db and addon.db.settings and addon.db.settings.editAlpha) or 0.4
end

function addon.SetEditAlpha(value)
    value = math.max(0, math.min(1, value))
    addon.db.settings.editAlpha = value
    addon.RefreshEditBoxes()
    return value
end

function addon.GetEditPad()
    return (addon.db and addon.db.settings and addon.db.settings.editPad) or 4
end

function addon.SetEditPad(value)
    value = math.max(0, math.min(40, math.floor(value + 0.5)))
    addon.db.settings.editPad = value
    addon.RefreshEditBoxes()
    return value
end

function addon.GetEditBorder()
    return (addon.db and addon.db.settings and addon.db.settings.editBorder) or 1
end

function addon.SetEditBorder(value)
    value = math.max(1, math.min(10, math.floor(value + 0.5)))
    addon.db.settings.editBorder = value
    addon.RefreshEditBoxes()
    return value
end

-- The Move UI backdrop + grid is one full-screen overlay, not a per-element box,
-- so the setting lives here but the live refresh is delegated to UI.lua.
function addon.GetMoveBgOpacity()
    return (addon.db and addon.db.settings and addon.db.settings.moveBgOpacity) or 15
end

function addon.SetMoveBgOpacity(value)
    value = math.max(0, math.min(100, math.floor(value + 0.5)))
    addon.db.settings.moveBgOpacity = value
    if addon.UI and addon.UI.RefreshMoveOverlay then addon.UI.RefreshMoveOverlay() end
    return value
end

-- Scale of the settings window itself (slider next to Edit Mode) — unrelated to
-- editAlpha/editPad/editBorder, which only affect the in-game edit boxes.
function addon.GetUIScale()
    return (addon.db and addon.db.settings and addon.db.settings.uiScale) or 1
end

function addon.SetUIScale(value)
    value = math.max(0.5, math.min(1.5, value))
    addon.db.settings.uiScale = value
    if addon.UI and addon.UI.frame then addon.UI.frame:SetScale(value) end
    return value
end

function addon.GetMoveBgEnabled()
    local v = addon.db and addon.db.settings and addon.db.settings.moveBgEnabled
    if v == nil then return true end
    return v
end

function addon.SetMoveBgEnabled(value)
    value = value and true or false
    addon.db.settings.moveBgEnabled = value
    if addon.UI and addon.UI.RefreshMoveOverlay then addon.UI.RefreshMoveOverlay() end
    return value
end

-- ── Off-screen dragging ──────────────────────────────────────────────────────
-- The client clamps a frame by its *clamp rectangle*, and SetClampRectInsets
-- pulls that rectangle's edges inward from the frame's own, so shrinking it to a
-- small patch lets the rest slide off screen. Never to nothing: what's left is
-- the only thing there is to grab the frame by. Public because ItemRack shrinks
-- a whole bar's bounding box by the same rule.
function addon.OffscreenKeep(size)
    -- ~20% of the frame, floored at 20px and capped at 60px. Frames under the floor
    -- just stay fully on screen on that axis.
    return math.min(size, math.max(20, math.min(60, size * 0.2)))
end
local offscreenKeep = addon.OffscreenKeep

-- anchorTop keeps the surviving strip at the frame's top edge — for windows
-- whose only drag handle is a title bar, which must stay reachable.
function addon.ApplyOffscreenClamp(frame, allowed, anchorTop)
    if not (frame and frame.SetClampRectInsets) then return end
    frame:SetClampedToScreen(true)
    if not allowed then
        frame:SetClampRectInsets(0, 0, 0, 0)
        return
    end
    local w, h = frame:GetWidth() or 0, frame:GetHeight() or 0
    local x = math.max(0, (w - offscreenKeep(w)) / 2)
    if anchorTop then
        frame:SetClampRectInsets(x, -x, 0, math.max(0, h - offscreenKeep(h)))
    else
        local y = math.max(0, (h - offscreenKeep(h)) / 2)
        frame:SetClampRectInsets(x, -x, -y, y)
    end
end

-- Off by default: the settings window re-centres each session so it can't be
-- lost, but positioned elements keep saved coordinates forever, and one left
-- three quarters off screen is easy to cause and hard to notice.
function addon.GetEditOffscreen()
    return (addon.db and addon.db.settings and addon.db.settings.editOffscreen) and true or false
end

function addon.SetEditOffscreen(value)
    value = value and true or false
    if addon.db and addon.db.settings then addon.db.settings.editOffscreen = value end
    if addon.UI and addon.UI.RefreshMovableClamps then addon.UI.RefreshMovableClamps() end
    return value
end

-- Modules parked (unticked) in Edit Mode's "Modules" tab, keyed by the label
-- shown there (UI.MovableLabel). Persisted so parking survives the session.
function addon.IsEditParked(key)
    return (addon.db and addon.db.settings and addon.db.settings.editParked and addon.db.settings.editParked[key]) and true or false
end

function addon.SetEditParked(key, parked)
    if not (addon.db and addon.db.settings) then return end
    addon.db.settings.editParked = addon.db.settings.editParked or {}
    if parked then
        addon.db.settings.editParked[key] = true
    else
        addon.db.settings.editParked[key] = nil
    end
end

-- ── Shared media (LibSharedMedia-3.0) ─────────────────────────────────────────
-- Bundled, but every lookup stays optional: a stripped Libs folder should cost
-- a fallback font, not an error.

local function getLSM()
    return LibStub and LibStub("LibSharedMedia-3.0", true)
end

-- Path behind a registered media name, or nil. noDefault, so an unknown name
-- comes back nil rather than LSM's substitute — callers have their own fallback.
function addon.FetchMedia(kind, name)
    local LSM = getLSM()
    if not (LSM and name) then return nil end
    return LSM:Fetch(kind, name, true)
end

-- Every media dropdown is built from this.
--   opts.lead     — entry pinned to the front (e.g. "Default", not an LSM name)
--   opts.fallback — the whole list when nothing else is available
-- Always a fresh table; LSM:List returns its own, which callers must not keep.
function addon.MediaList(kind, opts)
    opts = opts or {}
    local list = {}
    if opts.lead then list[1] = opts.lead end
    local LSM = getLSM()
    if LSM then
        for _, name in ipairs(LSM:List(kind) or {}) do list[#list + 1] = name end
    end
    if #list == 0 and opts.fallback then list[1] = opts.fallback end
    return list
end

-- ── Shared slot-button styling ────────────────────────────────────────────────
-- Item Rack (bars + set editor) and Trinkets all build ActionButtonTemplate
-- buttons and bake the Blizzard Classic look onto them, so it lives here.
--
-- 1.15.9's modernized templates define their state textures as nine-sliced atlas
-- frames. Slice margins, texcoord and tint live on the texture *region*, so they
-- survive SetNormalTexture and stretch our plain texture into a huge, washed-out
-- frame. Guarded — older clients lack these APIs and the bug. Only visible
-- without Masque, which replaces every region.
local function resetTemplateTexture(tex)
    if not tex then return end
    if tex.SetTextureSliceMargins then tex:SetTextureSliceMargins(0, 0, 0, 0) end
    if tex.SetTexCoord    then tex:SetTexCoord(0, 1, 0, 1) end
    if tex.SetVertexColor then tex:SetVertexColor(1, 1, 1) end
    if tex.SetAlpha       then tex:SetAlpha(1) end
end

-- The classic art is drawn oversized relative to its icon; these are the 36px
-- original's ratios, so any button size keeps the proportions.
local ICON_REF     = 36
local NORMAL_RATIO = 66 / ICON_REF
local PUSHED_RATIO = 38 / ICON_REF

-- opts.skipPushed: the set editor's slot buttons never showed a depress flash,
-- and shouldn't start now.
function addon.StyleSlotButton(btn, size, opts)
    -- SlotBackground/SlotArt only make sense on a real type="action" slot; ours are
    -- type="item", so nothing hides them and they frame our baked art.
    if btn.SlotBackground then btn.SlotBackground:Hide() end
    if btn.SlotArt        then btn.SlotArt:Hide()        end
    -- Silence the inherited OnEvent so it can't re-show those regions later. Safe:
    -- callers create these out of combat, we drive icon/cooldown/checked ourselves,
    -- and the secure click runs off attributes, not this Lua-side OnEvent.
    btn:UnregisterAllEvents()
    btn:SetScript("OnEvent", nil)

    btn:SetNormalTexture("Interface\\Buttons\\UI-Quickslot2")
    local nt = btn:GetNormalTexture()
    if nt then
        resetTemplateTexture(nt)
        nt:ClearAllPoints()
        local w = size * NORMAL_RATIO
        nt:SetSize(w, w)
        nt:SetPoint("CENTER", btn, "CENTER", 0.5, -0.5)
    end

    if not (opts and opts.skipPushed) then
        btn:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
        local pt = btn:GetPushedTexture()
        if pt then
            resetTemplateTexture(pt)
            pt:ClearAllPoints()
            local w = size * PUSHED_RATIO
            pt:SetSize(w, w)
            pt:SetPoint("CENTER", btn, "CENTER", 0, 0)
        end
    end

    btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    local ht = btn:GetHighlightTexture()
    if ht then resetTemplateTexture(ht); ht:ClearAllPoints(); ht:SetAllPoints(btn) end
end

-- GetMouseFocus became GetMouseFoci (a list, front-most first) part way through
-- 11.x; Classic Era still has the old one, some builds neither.
function addon.GetMouseFocusFrame()
    if GetMouseFoci then
        local foci = GetMouseFoci()
        return foci and foci[1]
    end
    return GetMouseFocus and GetMouseFocus()
end

-- ── Blizzard's Edit Mode ──────────────────────────────────────────────────────
-- Returns whether registration actually happened — EditModeManagerFrame doesn't
-- exist on every build, so callers store the result and retry on a later event.
function addon.HookBlizzardEditMode(onEnter, onExit)
    if not (EventRegistry and EditModeManagerFrame) then return false end
    if onEnter then EventRegistry:RegisterCallback("EditMode.Enter", onEnter) end
    if onExit  then EventRegistry:RegisterCallback("EditMode.Exit",  onExit)  end
    return true
end

-- ── Shared edit-mode box ──────────────────────────────────────────────────────
-- One box per movable element while in edit mode. Centralised so a single
-- opacity/padding/border control styles every box, and so padding can grow the
-- box *beyond* the element (a frame's own backdrop can't). Each is a UIParent
-- sibling anchored to its target, one level below it.
local WHITE = "Interface\\Buttons\\WHITE8x8"
local editBoxes = {}   -- [targetFrame] = overlay Frame

local function styleEditBox(box, target)
    local pad    = addon.GetEditPad()
    local border = math.max(1, addon.GetEditBorder())
    box:SetFrameStrata(target:GetFrameStrata())
    box:SetFrameLevel(math.max(0, target:GetFrameLevel() - 1))
    box:ClearAllPoints()
    box:SetPoint("TOPLEFT",     target, "TOPLEFT",     -pad,  pad)
    box:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT",  pad, -pad)
    box:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = border })
    box:SetBackdropColor(0.141, 0.149, 0.227, addon.GetEditAlpha())
    box:SetBackdropBorderColor(0.984, 0.173, 0.212, 1)
end

function addon.ShowEditBox(target)
    if not target then return end
    local box = editBoxes[target]
    if not box then
        box = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        box:EnableMouse(true)
        -- Forward mouse down/up to the target so the padding halo drags and click-opens
        -- the position editor like the element itself. Looked up live: modules assign
        -- their handlers after ShowEditBox and may reassign between sessions.
        box:SetScript("OnMouseDown", function(_, button)
            local fn = target:GetScript("OnMouseDown")
            if fn then fn(target, button) end
        end)
        box:SetScript("OnMouseUp", function(_, button)
            local fn = target:GetScript("OnMouseUp")
            if fn then fn(target, button) end
        end)
        editBoxes[target] = box
    end
    styleEditBox(box, target)
    box:Show()
end

function addon.HideEditBox(target)
    local box = target and editBoxes[target]
    if box then box:Hide() end
end

function addon.RefreshEditBoxes()
    for target, box in pairs(editBoxes) do
        if box:IsShown() then styleEditBox(box, target) end
    end
end

local function applyDefaults(src, dst)
    if type(dst) ~= "table" then dst = {} end
    for k, v in pairs(src) do
        if type(v) == "table" then
            dst[k] = applyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end

-- ── Shape migrations ─────────────────────────────────────────────────────────
-- A setting that changed SHAPE — the font blocks are the reason this exists —
-- has to be rewritten BEFORE applyDefaults, never after. Two things go wrong
-- afterwards: the merge has already filled every missing key from the defaults,
-- so a value the user chose is indistinguishable from one just installed; and
-- where the default is now a table over a saved scalar, the merge discards the
-- scalar outright (it starts a fresh table for anything that isn't one).
--
-- Modules register at load time, which is before PLAYER_LOGIN merges anything.
-- A migration takes the raw stored profile, must tolerate every key being
-- absent, and must be safe to run again — profile switch, copy and import all
-- come back through here.
local migrations = {}

function addon.RegisterMigration(fn)
    migrations[#migrations + 1] = fn
end

local function normalizeProfile(prof)
    if type(prof) ~= "table" then prof = {} end
    for _, fn in ipairs(migrations) do
        -- pcall: a module's migration is not worth a broken login, and the
        -- merge below still produces a usable profile without it.
        local ok, err = pcall(fn, prof)
        if not ok then
            print("|cfffb2c36Driev's Essentials|r: a settings migration failed — " .. tostring(err))
        end
    end
    return applyDefaults(defaults, prof)
end

-- ── Profile sections ─────────────────────────────────────────────────────────
-- A section is one module's slice of a profile: the settings keys it owns. It's
-- the unit export, import and copy work in when the user wants less than the
-- whole profile ("give me your nameplates, keep my chat"). Modules register
-- theirs next to their defaults, so core still doesn't need to know they exist.
--
--   def = {
--     key      -- stable id; travels inside export strings, so don't rename one
--     label    -- shown in the module picker
--     order    -- picker order, mirrors the settings window's tab order
--     settings -- list of addon.db.settings keys the section owns
--     roots    -- optional list of PROFILE-level keys (only "minimap" today)
--     catchAll -- see sectionSettingsKeys(); core's General section only
--   }
--
-- Registering an existing key MERGES into it, because a module can spread its
-- settings over several files (Chat has seven) and each should be able to claim
-- its own block where it declares it.
local profileSections = {}

local function appendUnique(list, values)
    if type(values) ~= "table" then return end
    for _, v in ipairs(values) do
        local dupe = false
        for _, existing in ipairs(list) do
            if existing == v then dupe = true break end
        end
        if not dupe then list[#list + 1] = v end
    end
end

function addon.RegisterProfileSection(def)
    if type(def) ~= "table" or not def.key then return end
    local sec = profileSections[def.key]
    if not sec then
        sec = { key = def.key, label = def.key, order = 500, settings = {}, roots = {} }
        profileSections[def.key] = sec
    end
    if def.label then sec.label = def.label end
    if def.order then sec.order = def.order end
    if def.catchAll then sec.catchAll = true end
    appendUnique(sec.settings, def.settings)
    appendUnique(sec.roots, def.roots)
    return sec
end

-- "swingTimer" -> "Swing Timer", for a module that registered defaults but no
-- section of its own.
local function humanizeKey(key)
    local words = key:gsub("(%l)(%u)", "%1 %2")
    return (words:gsub("^%l", string.upper))
end

-- Ordered list of every section, plus a stand-in for any module settings block
-- nobody claimed — without it a new module's settings would quietly ride along
-- inside General's catch-all instead of being pickable on their own.
function addon.GetProfileSections()
    local list, claimed = {}, {}
    for _, sec in pairs(profileSections) do
        list[#list + 1] = sec
        for _, key in ipairs(sec.settings) do claimed[key] = true end
    end
    for key in pairs(moduleSettingsKeys) do
        if not claimed[key] then
            list[#list + 1] = {
                key = key, label = humanizeKey(key), order = 500,
                settings = { key }, roots = {},
            }
        end
    end
    table.sort(list, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.label < b.label
    end)
    return list
end

-- Section defs behind a list of section keys, in display order. Unknown keys are
-- dropped rather than erroring: a string can name a module this install doesn't
-- have loaded.
local function resolveSections(keys)
    if not keys then return nil end
    local wanted = {}
    for _, k in ipairs(keys) do wanted[k] = true end
    local out = {}
    for _, sec in ipairs(addon.GetProfileSections()) do
        if wanted[sec.key] then out[#out + 1] = sec end
    end
    return out
end

-- The settings keys a section covers right now. Fixed for a normal section; the
-- catch-all (General) is instead everything no other section claims — core's
-- loose top-level settings (edit mode, UI colours, window size) today, and
-- whatever an unrecognised string carries tomorrow, so a whole-profile export
-- can't silently drop a key.
--
-- `extras` are further settings tables to sweep for keys beyond the defaults —
-- the profile being exported, the payload being imported.
local function sectionSettingsKeys(sec, extras)
    if not sec.catchAll then return sec.settings end

    local claimed = {}
    for _, other in ipairs(addon.GetProfileSections()) do
        if other.key ~= sec.key then
            for _, key in ipairs(other.settings) do claimed[key] = true end
        end
    end

    local out, seen = {}, {}
    local function sweep(tbl)
        if type(tbl) ~= "table" then return end
        for key in pairs(tbl) do
            if not claimed[key] and not seen[key] then
                seen[key] = true
                out[#out + 1] = key
            end
        end
    end
    sweep(defaults.settings)
    for _, tbl in ipairs(extras or {}) do sweep(tbl) end
    table.sort(out)
    return out
end

-- Overwrites `dst`'s copy of each selected section with `incoming`'s. `incoming`
-- must already be a normalised profile (migrations run, defaults merged), so a
-- section the payload said nothing about lands as defaults rather than as a
-- half-shaped block — "make my nameplates look like yours", not "merge them".
local function mergeSections(dst, incoming, secs)
    dst.settings = dst.settings or {}
    incoming.settings = incoming.settings or {}
    for _, sec in ipairs(secs) do
        for _, key in ipairs(sectionSettingsKeys(sec, { dst.settings, incoming.settings })) do
            dst.settings[key] = incoming.settings[key]
        end
        for _, root in ipairs(sec.roots) do
            dst[root] = incoming[root]
        end
    end
end

-- Core's own sections, ordered to match the settings window's tabs. General is
-- the catch-all: the minimap button plus every loose settings field (edit mode,
-- UI colours, saved window size) that isn't a module's block.
addon.RegisterProfileSection({ key = "general", label = "General", order = 10,
    roots = { "minimap" }, catchAll = true })
addon.RegisterProfileSection({ key = "ttk",     label = "Time to Kill", order = 12, settings = { "ttk" } })
addon.RegisterProfileSection({ key = "tooltip", label = "Tooltip",      order = 14, settings = { "tooltip" } })
addon.RegisterProfileSection({ key = "raid",    label = "Raid",         order = 30, settings = { "raid", "raidFrames" } })

-- ── Profiles ───────────────────────────────────────────────────────────────
-- DrievSettingsDB is one ACCOUNT-WIDE SavedVariable, so per-character profiles
-- aren't automatic — we keep our own character-key -> profile-name map inside it.
-- addon.db points at the active profile and keeps the same { minimap, settings }
-- shape as before profiles existed, so every other file's access is unchanged.
local function getCharKey()
    local name  = UnitName("player") or "Unknown"
    local realm = GetRealmName() or "Unknown"
    return name .. " - " .. realm
end

-- Pre-profiles installs kept minimap/settings at the DB's top level. Move that
-- into profiles.Default once, so existing users don't silently reset.
local function migrateToProfiles()
    if type(DrievSettingsDB) ~= "table" then DrievSettingsDB = {} end
    if not DrievSettingsDB.profiles then
        DrievSettingsDB.profiles = {}
        if DrievSettingsDB.minimap or DrievSettingsDB.settings then
            DrievSettingsDB.profiles.Default = {
                minimap  = DrievSettingsDB.minimap,
                settings = DrievSettingsDB.settings,
            }
            DrievSettingsDB.minimap  = nil
            DrievSettingsDB.settings = nil
        end
    end
    if not DrievSettingsDB.profiles.Default then
        DrievSettingsDB.profiles.Default = {}
    end
    if not DrievSettingsDB.profileAssignments then
        DrievSettingsDB.profileAssignments = {}
    end
end

-- 1.1.0 renamed this addon's folder, and WoW names SavedVariables after the
-- folder — so an updating user's settings sit in a file nothing loads. The bridge
-- addon keeps the old filename alive in DrievEssentialsLegacyDB. Adopted only
-- when this install has no profiles of its own, so a leftover bridge can't
-- overwrite newer settings, and before migrateToProfiles() so it's normalised.
local function migrateLegacyDB()
    local legacy = _G.DrievEssentialsLegacyDB
    if type(legacy) ~= "table" or type(legacy.profiles) ~= "table" then return end
    if next(legacy.profiles) == nil then return end

    local haveOwnData = type(DrievSettingsDB) == "table"
        and type(DrievSettingsDB.profiles) == "table"
        and next(DrievSettingsDB.profiles) ~= nil
    if haveOwnData then return end

    DrievSettingsDB = legacy
    addon.migratedFromLegacy = true
end

-- Chat and Action Bars make one-way changes to Blizzard's frames on login (see
-- HideBlizzard.lua and Chat.lua) that RefreshAllModules() can't undo live, so a
-- profile switch that changes them needs a /reload. Compare old vs new to decide
-- whether to ask for one.
local function deepEquals(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not deepEquals(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

StaticPopupDialogs["DRIEV_PROFILE_RELOAD"] = {
    text = "Switching profiles changed your Chat and/or Action Bars settings.\n\nThese need a UI reload to fully take effect.",
    button1 = "Reload Now",
    button2 = "Later",
    OnAccept = function() ReloadUI() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

local function promptReloadIfNeeded(oldSettings, newSettings)
    if not (oldSettings and newSettings) then return end
    if deepEquals(oldSettings.chat, newSettings.chat)
        and deepEquals(oldSettings.actionBars, newSettings.actionBars) then
        return
    end
    StaticPopup_Show("DRIEV_PROFILE_RELOAD")
end

function addon.GetActiveProfileName()
    return addon.activeProfileName or "Default"
end

function addon.GetProfileList()
    local list = {}
    for name in pairs(DrievSettingsDB.profiles) do table.insert(list, name) end
    table.sort(list)
    return list
end

-- Re-applies every module from the now-active addon.db and refreshes the
-- settings window if open. Each module re-derives everything from its own
-- getData(), so this is just "call every apply-from-settings entry point".
function addon.RefreshAllModules()
    -- First: the palette is per-profile, and every panel refreshed below
    -- repaints itself from it.
    if addon.UI and addon.UI.ApplyPalette then addon.UI.ApplyPalette() end
    if addon.UI and addon.UI.colorsPopup then addon.UI.colorsPopup:Refresh() end
    if addon.TTK then
        if addon.TTK.applyFont       then addon.TTK.applyFont() end
        if addon.TTK.applyPosition   then addon.TTK.applyPosition() end
        if addon.TTK.applyVisibility then addon.TTK.applyVisibility() end
    end
    if addon.SwingTimer and addon.SwingTimer.applyAll then
        addon.SwingTimer.applyAll()
    end
    if addon.RaidFrames and addon.RaidFrames.applyAll then
        addon.RaidFrames.applyAll()
    end
    if addon.Trinkets then
        if addon.Trinkets.applyVisibility    then addon.Trinkets.applyVisibility() end
        if addon.Trinkets.applyClickTrigger   then addon.Trinkets.applyClickTrigger() end
        if addon.Trinkets.applyModifierBlockers then addon.Trinkets.applyModifierBlockers() end
        if addon.Trinkets.applySoftQueueMod   then addon.Trinkets.applySoftQueueMod() end
        if addon.Trinkets.populateQueueSorts  then addon.Trinkets.populateQueueSorts() end
    end
    -- Item Rack's buttons are frames we own outright and its whole layout is
    -- re-derived from settings, so a profile switch can be applied live.
    if addon.ItemRack and addon.ItemRack.Refresh then addon.ItemRack.Refresh() end
    if addon.Particles and addon.Particles.refresh then addon.Particles.refresh() end
    -- Re-derives every visible plate and re-seeds the NPC list, so a switch
    -- applies live rather than at the next pull.
    if addon.Nameplates and addon.Nameplates.refresh then addon.Nameplates.refresh() end
    if addon.Tooltip  and addon.Tooltip.refresh  then addon.Tooltip.refresh() end
    if addon.Raid      and addon.Raid.refresh      then addon.Raid.refresh() end
    if addon.Minimap   and addon.Minimap.refresh   then addon.Minimap.refresh() end
    if addon.ActionBars and addon.ActionBars.refresh then addon.ActionBars.refresh() end
    -- DataTexts bars are frames we own and rebuildAll re-derives them, so unlike the
    -- rest of Chat they can be re-applied live. Needed because settings.dataTexts is
    -- a sibling of settings.chat and isn't one of the subtrees promptReloadIfNeeded
    -- compares — without this, a datatexts-only profile got neither.
    if addon.DataTexts and addon.DataTexts.refresh then addon.DataTexts.refresh() end
    -- Same reasoning as DataTexts: settings.chatChannels and settings.chatWindows
    -- are siblings of settings.chat, so promptReloadIfNeeded never sees them
    -- change, and both are re-runnable calls into Blizzard's own chat APIs rather
    -- than one-way patches. Channels first — a window can't display a channel
    -- this character hasn't joined.
    if addon.ChatChannels and addon.ChatChannels.apply then addon.ChatChannels.apply() end
    if addon.ChatWindows  and addon.ChatWindows.apply  then addon.ChatWindows.apply()  end
    -- Visible sub-panels refresh via their own OnShow, so toggling the window's
    -- shown state cascades to whatever is on screen without a per-tab hook.
    if addon.UI and addon.UI.frame and addon.UI.frame:IsShown() then
        addon.UI.frame:Hide()
        addon.UI.frame:Show()
    end
end

-- Makes `name` active for the CURRENT character and re-applies everything,
-- filling in any settings keys added since it was last used.
function addon.SetActiveProfile(name)
    if not DrievSettingsDB.profiles[name] then return false, "Profile not found." end
    local oldSettings = addon.db and addon.db.settings

    DrievSettingsDB.profiles[name] = normalizeProfile(DrievSettingsDB.profiles[name])
    addon.db = DrievSettingsDB.profiles[name]
    addon.activeProfileName = name
    DrievSettingsDB.profileAssignments[getCharKey()] = name
    addon.RefreshAllModules()
    promptReloadIfNeeded(oldSettings, addon.db.settings)
    return true
end

-- Creates a fresh, default-populated profile. Does not switch to it — the
-- caller decides whether/when to (the Profiles UI switches immediately).
function addon.CreateProfile(name)
    name = name and name:match("^%s*(.-)%s*$") or ""
    if name == "" then return nil, "Enter a profile name." end
    if DrievSettingsDB.profiles[name] then return nil, "A profile with that name already exists." end
    DrievSettingsDB.profiles[name] = normalizeProfile({})
    return name
end

function addon.DeleteProfile(name)
    if name == "Default" then return false, "The Default profile can't be deleted." end
    if not DrievSettingsDB.profiles[name] then return false, "Profile not found." end
    if addon.GetActiveProfileName() == name then
        return false, "Can't delete the profile currently in use — switch to another one first."
    end
    DrievSettingsDB.profiles[name] = nil
    -- Any other character assigned to the deleted profile falls back to Default.
    for charKey, assigned in pairs(DrievSettingsDB.profileAssignments) do
        if assigned == name then DrievSettingsDB.profileAssignments[charKey] = "Default" end
    end
    return true
end

local function deepCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do out[k] = deepCopy(val) end
    return out
end

-- Overwrites `toName` with a deep copy of `fromName` (fresh tables, so the two
-- don't share afterwards). If `toName` is in use on THIS character, addon.db is
-- re-pointed and modules re-applied, mirroring SetActiveProfile.
--
-- `only` — a list of section keys — copies just those modules and leaves the
-- rest of `toName` alone. The destination table is then edited in place rather
-- than replaced, so addon.db keeps pointing at it.
function addon.CopyProfile(fromName, toName, only)
    if not (fromName and toName) then return false, "Pick both profiles." end
    if fromName == toName then return false, "Pick two different profiles." end
    local src = DrievSettingsDB.profiles[fromName]
    if not src then return false, "Source profile not found." end
    local dst = DrievSettingsDB.profiles[toName]
    if not dst then return false, "Destination profile not found." end

    local isActive    = (addon.GetActiveProfileName() == toName)
    local oldSettings = isActive and deepCopy(dst.settings) or nil
    local copy        = normalizeProfile(deepCopy(src))

    if only then
        local secs = resolveSections(only)
        if #secs == 0 then return false, "Pick at least one module to copy." end
        mergeSections(dst, copy, secs)
    else
        DrievSettingsDB.profiles[toName] = copy
    end

    if isActive then
        addon.db = DrievSettingsDB.profiles[toName]
        addon.RefreshAllModules()
        promptReloadIfNeeded(oldSettings, addon.db.settings)
    end
    return true
end

-- ── Profile export/import ────────────────────────────────────────────────────
-- Hand-rolled serializer rather than loadstring(): a pasted string comes from
-- another player, and loadstring on untrusted input runs arbitrary Lua. Values
-- are type-tagged so the reader never guesses or executes — T/F, N<digits>;,
-- S<len>:<bytes> (length-prefixed, so contents never need escaping), {...}.
-- Base64'd so it pastes anywhere as one line.

local function serializeValue(v, buf)
    local t = type(v)
    if t == "boolean" then
        buf[#buf + 1] = v and "T" or "F"
    elseif t == "number" then
        buf[#buf + 1] = "N" .. tostring(v) .. ";"
    elseif t == "string" then
        buf[#buf + 1] = "S" .. #v .. ":" .. v
    elseif t == "table" then
        buf[#buf + 1] = "{"
        for k, val in pairs(v) do
            serializeValue(k, buf)
            serializeValue(val, buf)
        end
        buf[#buf + 1] = "}"
    end
    -- nil/function/other unsupported types are simply omitted.
end

local function serialize(root)
    local buf = {}
    serializeValue(root, buf)
    return table.concat(buf)
end

local function deserialize(str)
    local pos = 1
    local readValue

    readValue = function()
        local tag = str:sub(pos, pos)
        pos = pos + 1
        if tag == "T" then
            return true
        elseif tag == "F" then
            return false
        elseif tag == "N" then
            local e = str:find(";", pos, true)
            if not e then error("malformed number") end
            local n = tonumber(str:sub(pos, e - 1))
            pos = e + 1
            return n
        elseif tag == "S" then
            local e = str:find(":", pos, true)
            if not e then error("malformed string") end
            local len = tonumber(str:sub(pos, e - 1))
            pos = e + 1
            local s = str:sub(pos, pos + len - 1)
            pos = pos + len
            return s
        elseif tag == "{" then
            local tbl = {}
            while str:sub(pos, pos) ~= "}" do
                if pos > #str then error("malformed table") end
                local k = readValue()
                local val = readValue()
                tbl[k] = val
            end
            pos = pos + 1
            return tbl
        else
            error("unknown tag")
        end
    end

    local ok, result = pcall(readValue)
    -- Deliberately not "…profile string": the codec is shared with module data
    -- (Item Rack's sets), so the message can't name one of its callers.
    if not ok then return nil, "Corrupt or unreadable string." end
    return result
end

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64Encode(data)
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        b = b or 0
        c = c or 0
        local n = a * 65536 + b * 256 + c
        local chunk = math.min(3, #data - i + 1)
        out[#out + 1] = B64_CHARS:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
        out[#out + 1] = B64_CHARS:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
        out[#out + 1] = (chunk >= 2) and B64_CHARS:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "="
        out[#out + 1] = (chunk >= 3) and B64_CHARS:sub(n % 64 + 1, n % 64 + 1) or "="
    end
    return table.concat(out)
end

local b64Lookup
local function base64Decode(str)
    if not b64Lookup then
        b64Lookup = {}
        for i = 1, #B64_CHARS do b64Lookup[B64_CHARS:sub(i, i)] = i - 1 end
    end
    str = str:gsub("[^%w%+%/%=]", "")
    local out = {}
    local i = 1
    while i <= #str do
        local c1 = b64Lookup[str:sub(i, i)]
        local c2 = b64Lookup[str:sub(i + 1, i + 1)]
        local e3, e4 = str:sub(i + 2, i + 2), str:sub(i + 3, i + 3)
        local c3, c4 = b64Lookup[e3], b64Lookup[e4]
        if not c1 or not c2 then break end
        local n = c1 * 262144 + c2 * 4096 + (c3 or 0) * 64 + (c4 or 0)
        out[#out + 1] = string.char(math.floor(n / 65536) % 256)
        if e3 ~= "=" and e3 ~= "" then out[#out + 1] = string.char(math.floor(n / 256) % 256) end
        if e4 ~= "=" and e4 ~= "" then out[#out + 1] = string.char(n % 256) end
        i = i + 4
    end
    return table.concat(out)
end

local EXPORT_PREFIX = "DrievEssentials1:"

-- The codec isn't profile-specific, so modules with their own copy-pasteable
-- data (Item Rack's sets) share it. `prefix` tags what kind of data it is, so a
-- set string pasted into the profile box is rejected rather than half-applied.
function addon.EncodeTable(prefix, tbl)
    local ok, payload = pcall(serialize, tbl)
    if not ok then return nil, "Could not encode this data." end
    return prefix .. base64Encode(payload)
end

function addon.DecodeTable(prefix, str)
    str = str and str:match("^%s*(.-)%s*$") or ""
    if str:sub(1, #prefix) ~= prefix then
        return nil, "That doesn't look like the right kind of Driev's Essentials string."
    end
    local data, err = deserialize(base64Decode(str:sub(#prefix + 1)))
    if type(data) ~= "table" then return nil, err or "Corrupt or invalid string." end
    return data
end

-- ── Slimming an export ───────────────────────────────────────────────────────
-- Two passes stand between a stored profile and its export string, because most
-- of a profile is not worth sending. It holds what modules have WATCHED as well
-- as what the user set, and every default it was merged with at login. Straight
-- encoding ran ~193,000 characters — enough that filling the box locked the
-- client for ~25 seconds, and so did pasting it into anything else.

-- Modules whose settings block accumulates observed data (the nameplate
-- module's learned-aura catalogue and its auto-detected NPC rows) register a
-- pruner here. It's handed a throwaway copy of settings[key] and strips it in
-- place: that data is a record of what this account has met, it rebuilds itself
-- on whoever imports the string, and it was 84% of the export.
local exportPruners = {}

function addon.RegisterExportPruner(key, fn)
    exportPruners[key] = fn
end

-- The other end of the same deal, run on a freshly imported profile once its
-- defaults are merged: a pruner strips data the settings themselves imply, and
-- this is where the module adds back what they imply. Nameplates appends the
-- whitelists that travelled to its aura catalogue, so an imported profile's
-- tracked auras are pickable on the Learned tab instead of the tab being empty
-- until the importer meets each spell again.
--
-- Fillers only ever ADD. Nothing here may clear or overwrite what the profile
-- arrived with — a filler runs against a profile that already holds everything
-- the string carried, and the string is the authority on all of it.
local importFillers = {}

function addon.RegisterImportFiller(key, fn)
    importFillers[key] = fn
end

-- Second pass: drop everything the profile shares with the defaults, since
-- ImportProfile merges defaults back in and an unchanged value costs nothing to
-- leave out. A key with no default behind it (a module the exporter runs and
-- the importer doesn't) has nothing to fall back on, so it always travels.
--
-- Sub-tables the user emptied come back defaulted rather than empty — but so
-- does the stored profile at every login, since applyDefaults refills exactly
-- the same keys, so the round trip loses nothing that survives a /reload today.
-- Returns nil, not an empty table, when `src` matches `def` outright — that's
-- what lets a parent drop the whole branch instead of shipping empty scaffolding.
local function diffDefaults(src, def)
    local out
    for k, v in pairs(src) do
        -- Spelled out rather than `type(def) == "table" and def[k] or nil`,
        -- which would read a stored `false` back as nil and keep it forever.
        local d
        if type(def) == "table" then d = def[k] end

        local keep
        if type(v) == "table" then
            if type(d) == "table" then
                keep = diffDefaults(v, d)
            else
                keep = v
            end
        elseif v ~= d then
            keep = v
        end

        if keep ~= nil then
            out = out or {}
            out[k] = keep
        end
    end
    return out
end

-- A partial export names the sections it carries, so the import picker can
-- offer exactly those instead of resetting modules the string says nothing
-- about. Stripped before the payload becomes a profile — it's an envelope, not
-- a setting. Absent on whole-profile strings, including every one written
-- before sections existed.
local META_KEY = "__meta"

-- Returns an opaque, copy-pasteable string encoding the named profile, or
-- nil + an error message. `only` — a list of section keys — limits it to those
-- modules; nil exports the whole profile.
--
-- Older full-fat strings still import fine — the reader merges defaults either
-- way, so a pruned payload and a complete one land in the same place.
function addon.ExportProfile(name, only)
    local prof = DrievSettingsDB.profiles[name]
    if not prof then return nil, "Profile not found." end

    local slim, secs
    if only then
        secs = resolveSections(only)
        if #secs == 0 then return nil, "Pick at least one module to export." end
        slim = { settings = {} }
        for _, sec in ipairs(secs) do
            for _, key in ipairs(sectionSettingsKeys(sec, { prof.settings })) do
                local block = prof.settings and prof.settings[key]
                if block ~= nil then slim.settings[key] = deepCopy(block) end
            end
            for _, root in ipairs(sec.roots) do
                if prof[root] ~= nil then slim[root] = deepCopy(prof[root]) end
            end
        end
    else
        slim = deepCopy(prof)
    end

    for key, prune in pairs(exportPruners) do
        local block = slim.settings and slim.settings[key]
        if type(block) == "table" then prune(block) end
    end

    -- `or {}` for the profile that matches the defaults exactly: nothing to
    -- diff still has to encode as an empty table, not as nothing at all.
    local payload = diffDefaults(slim, defaults) or {}
    if secs then
        local keys = {}
        for _, sec in ipairs(secs) do keys[#keys + 1] = sec.key end
        payload[META_KEY] = { sections = keys }
    end

    local str = addon.EncodeTable(EXPORT_PREFIX, payload)
    if not str then return nil, "Could not export this profile." end
    return str
end

-- Decodes a string without applying any of it, and reports which sections it
-- carries so the caller can offer them. Returns data, sectionKeys — or
-- nil, nil, error message.
--
-- A string with no section list is a whole profile, so every section is on
-- offer: the payload is diffed against the defaults, and a module it doesn't
-- mention genuinely means "defaults", not "unknown".
function addon.ReadProfileString(str)
    local data, err = addon.DecodeTable(EXPORT_PREFIX, str)
    if not data then
        return nil, nil, err or "That doesn't look like a valid profile string."
    end

    local keys = {}
    local meta = data[META_KEY]
    if type(meta) == "table" and type(meta.sections) == "table" then
        -- Filtered through the registry so a section this install doesn't have
        -- loaded never reaches the picker as an unusable row.
        for _, sec in ipairs(resolveSections(meta.sections)) do keys[#keys + 1] = sec.key end
    else
        for _, sec in ipairs(addon.GetProfileSections()) do keys[#keys + 1] = sec.key end
    end
    return data, keys
end

-- Turns decoded data into a complete, current-shape profile: envelope dropped,
-- migrations run, defaults merged, then the import fillers — after the merge,
-- so a filler is handed a complete block rather than whatever subset the string
-- happened to carry.
local function profileFromData(data)
    local prof = deepCopy(data)
    prof[META_KEY] = nil
    prof = normalizeProfile(prof)
    for key, fill in pairs(importFillers) do
        local block = prof.settings and prof.settings[key]
        if type(block) == "table" then fill(block) end
    end
    return prof
end

-- Creates a new profile called `name` from a string produced by ExportProfile.
-- Returns the profile name on success, or nil + an error message. A partial
-- string is fine here: the modules it doesn't carry arrive as defaults.
function addon.ImportProfile(name, str)
    name = name and name:match("^%s*(.-)%s*$") or ""
    if name == "" then return nil, "Enter a profile name." end
    if DrievSettingsDB.profiles[name] then return nil, "A profile with that name already exists." end

    local data, err = addon.DecodeTable(EXPORT_PREFIX, str)
    if not data then
        return nil, err or "That doesn't look like a valid profile string."
    end

    DrievSettingsDB.profiles[name] = profileFromData(data)
    return name
end

-- Imports only `only` (a list of section keys) from `source` — a string, or the
-- data ReadProfileString already decoded — into the EXISTING profile
-- `targetName`, leaving every other module in it untouched.
function addon.ImportProfileSections(targetName, source, only)
    local target = DrievSettingsDB.profiles[targetName]
    if not target then return false, "Profile not found." end

    local data = source
    if type(data) == "string" then
        local decoded, err = addon.DecodeTable(EXPORT_PREFIX, data)
        if not decoded then
            return false, err or "That doesn't look like a valid profile string."
        end
        data = decoded
    end
    if type(data) ~= "table" then return false, "Nothing to import." end

    local secs = resolveSections(only)
    if not secs or #secs == 0 then return false, "Pick at least one module to import." end

    local isActive    = (addon.GetActiveProfileName() == targetName)
    local oldSettings = isActive and deepCopy(target.settings) or nil

    mergeSections(target, profileFromData(data), secs)

    if isActive then
        addon.RefreshAllModules()
        promptReloadIfNeeded(oldSettings, target.settings)
    end
    return true
end

-- Single bootstrap frame: registers events, then unregisters/releases itself.
local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" then
        if name ~= addonName then return end
        migrateLegacyDB()
        migrateToProfiles()
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        local charKey      = getCharKey()
        local profileName  = DrievSettingsDB.profileAssignments[charKey]
        if not profileName or not DrievSettingsDB.profiles[profileName] then
            profileName = "Default"
            DrievSettingsDB.profileAssignments[charKey] = profileName
        end
        DrievSettingsDB.profiles[profileName] = normalizeProfile(DrievSettingsDB.profiles[profileName])
        addon.db = DrievSettingsDB.profiles[profileName]
        addon.activeProfileName = profileName

        -- Before any module builds a frame off the palette: core's files are
        -- loaded and module PLAYER_LOGIN handlers register after this one, so
        -- nothing is ever painted in shipped colours and then recoloured.
        if addon.UI and addon.UI.ApplyPalette then addon.UI.ApplyPalette() end

        if addon.CreateMinimapButton then
            addon.CreateMinimapButton()
        end
        -- Tell the user their settings were rescued, otherwise a silent recovery
        -- looks identical to "my profiles are gone" until they go and check.
        if addon.migratedFromLegacy then
            print("|cfffb2c36Driev's Essentials|r: recovered your settings from the pre-1.1.0 install. "
                .. "The |cffdddddd\"Driev's Essentials (settings bridge)\"|r addon has done its job and can be deleted.")
        end
        self:UnregisterEvent("PLAYER_LOGIN")
        self:SetScript("OnEvent", nil)
    end
end)

-- ── Slash commands ───────────────────────────────────────────────────────────
-- Every module ships a command of its own and nothing listed them, so a user who
-- forgot `/denp` had no way back to it short of reading the source. Modules
-- register here at load time exactly as they register their defaults, which is
-- what makes `/driev help` list what is actually loaded rather than everything
-- that could be.
--
-- `entries` is an ordered list of { command, description } pairs, or a function
-- returning one — Item Rack's aliases aren't known until it has seen which of
-- them another addon already owns.
local slashGroups = {}

function addon.RegisterSlash(label, entries)
    slashGroups[#slashGroups + 1] = { label = label, entries = entries }
end

local function printSlashHelp()
    print("|cfffb2c36Driev's Essentials|r — slash commands:")
    for _, group in ipairs(slashGroups) do
        local entries = group.entries
        if type(entries) == "function" then
            -- pcall: one module's listing going wrong must not swallow the rest
            -- of the help, which is the only way to find the others.
            local ok, result = pcall(entries)
            entries = ok and result or nil
        end
        if type(entries) == "table" and #entries > 0 then
            print("  |cffffd100" .. group.label .. "|r")
            for _, entry in ipairs(entries) do
                print(("    |cffdddddd%s|r — %s"):format(entry[1], entry[2]))
            end
        end
    end
end

addon.RegisterSlash("Core", {
    { "/driev",              "open the settings window (also /dv, /dre)" },
    { "/driev help",         "this list" },
    { "/driev debug on|off", "start or stop logging API events to SavedVariables" },
    { "/driev debug print",  "dump the saved log to chat" },
    { "/driev debug clear",  "wipe the saved log" },
})

SLASH_DRIEVSETTINGS1 = "/driev"
SLASH_DRIEVSETTINGS2 = "/dv"
SLASH_DRIEVSETTINGS3 = "/dre"
SlashCmdList["DRIEVSETTINGS"] = function(msg)
    local cmd = msg and msg:lower():match("^%s*(%S*)") or ""

    if cmd == "help" or cmd == "?" or cmd == "commands" then
        printSlashHelp()
    elseif cmd == "debug" then
        local sub = msg:lower():match("%S+%s+(%S*)") or ""
        if sub == "on" then
            if addon.State then addon.State.setDebug(true) end
        elseif sub == "off" then
            if addon.State then addon.State.setDebug(false) end
        elseif sub == "print" or sub == "dump" then
            if addon.State then addon.State.printLog() end
        elseif sub == "clear" then
            if addon.State then addon.State.clearLog() end
        else
            -- /de was never one of the registered commands (they are /driev, /dv
            -- and /dre), so following this listing did nothing.
            print("|cfffb2c36Driev's Essentials|r debug commands:")
            print("  |cffdddddd/driev debug on|r    — start logging API events to SavedVariables")
            print("  |cffdddddd/driev debug off|r   — stop logging")
            print("  |cffdddddd/driev debug print|r — dump saved log to chat")
            print("  |cffdddddd/driev debug clear|r — wipe the saved log")
        end
    else
        if addon.ToggleUI then addon.ToggleUI() end
    end
end
