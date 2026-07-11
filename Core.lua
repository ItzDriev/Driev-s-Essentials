local addonName, addon = ...

addon.version = "1.0.7"
addon.title   = "Driev's Essentials"

-- Public event bus for addons that don't use WeakAuras. WeakAuras.ScanEvents
-- (used by TTK.lua) is WeakAuras' own custom-trigger event system and only
-- reaches WeakAuras users; CallbackHandler-1.0 is a near-ubiquitous, bundled
-- library any addon can grab via LibStub to listen in without depending on
-- WeakAuras at all. Exposed globally so external addons can reach it without
-- needing a reference to our private namespace table.
addon.callbacks = LibStub("CallbackHandler-1.0"):New(addon)
_G.DrievEssentials = addon

-- Vanilla class roster used to filter when particle functionality is active
-- for the locally logged-in character. Token must match the classFileName
-- returned by UnitClass("player").
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
            fontSize = 24,
            fontName = "Friz Quadrata TT",
        },
        particles = {
            classes = { WARRIOR = true },
        },
        editAlpha     = 0.4,
        editPad       = 4,    -- extra px the edit-mode box extends beyond each element
        editBorder    = 1,    -- edit-mode box border thickness
        moveBgOpacity = 15,   -- % scaling the Move UI dimmed background + grid lines
        moveBgEnabled = true, -- whether the Move UI dimmed background + grid show at all
        trinkets = {
            enabled          = false,
            showCooldowns    = true,
            showTooltips     = true,
            tinyTooltips     = false,
            keepOpen         = false,
            notify           = false,
            alwaysShow       = false,
            menuDocked       = true,
            menuDockCorner   = "below-left",
            menuPerLine      = 4,
            menuOrientation  = "horizontal",
            menuAlign        = "left",
            menuScale        = 1.0,
            showBindings     = true,
            truncateBindings = true,
            swapDelay        = 1.0,
            menuOrder        = {},
            hidden           = {},
            menuEdgePad      = 0,
            menuButtonGap    = 6,
            displayEdgePad   = 0,
            displayButtonGap = 2,
            displayScale     = 1.0,
            menuOrderEnabled = false,
            triggerOnKeyUp   = false,
            blockModCtrl     = false,
            blockModAlt      = false,
            blockModShift    = false,
            swapWatchdog     = true,
            softQueueMod     = "shift",
            multiQueue       = false,
            encounters       = {},   -- [encounterID] = { enabled, mainTop, mainBottom, softTop, softBottom }
            debugEncounters  = false, -- gate for the Stockades (debug raid) test encounters
        },
    },
}

-- Shared opacity for the translucent boxes shown around movable elements
-- while in edit/move mode (TTK display, raid frame anchor) — one value so
-- the in-game opacity slider controls every edit-mode box at once.
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

-- The Move UI dimmed backdrop + grid lines (owned by UI.lua) are a single
-- full-screen overlay, not a per-element box, so their settings live here
-- alongside the others but the live-refresh call is delegated to UI.lua.
function addon.GetMoveBgOpacity()
    return (addon.db and addon.db.settings and addon.db.settings.moveBgOpacity) or 15
end

function addon.SetMoveBgOpacity(value)
    value = math.max(0, math.min(100, math.floor(value + 0.5)))
    addon.db.settings.moveBgOpacity = value
    if addon.UI and addon.UI.RefreshMoveOverlay then addon.UI.RefreshMoveOverlay() end
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

-- ── Shared edit-mode box ──────────────────────────────────────────────────────
-- One translucent, red-bordered box is drawn per movable element while in edit
-- mode. Centralising it here (instead of each module colouring its own frame's
-- backdrop) lets a single opacity / padding / border-thickness control style
-- every box at once, and lets padding grow the box *beyond* the element — which
-- a frame's own backdrop can't do. Each box is a sibling of UIParent anchored to
-- its target and kept one frame level below it, so it sits behind the element's
-- own content (icons / text) just like the old per-frame backdrop did.
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
        -- Forwards mouse down/up to the target frame so the padding area is
        -- both draggable AND click-to-open-position-editor, same as clicking
        -- the target directly. Move-mode drives movement straight off
        -- OnMouseDown/OnMouseUp (not RegisterForDrag/OnDragStart) so it starts
        -- instantly instead of waiting on WoW's native drag-recognition
        -- threshold — forwarding those same two events here keeps the padding
        -- halo consistent with that. Looked up live (not captured once)
        -- because each module assigns its own OnMouseDown/OnMouseUp on the
        -- target *after* calling ShowEditBox, and may re-assign them across
        -- edit sessions.
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

-- ── Profiles ───────────────────────────────────────────────────────────────
-- DrievSettingsDB is a single ACCOUNT-WIDE SavedVariable (shared across every
-- character), so per-character profiles aren't automatic the way
-- SavedVariablesPerCharacter would give us — we track our own assignment map
-- (character key -> profile name) inside that shared DB instead. addon.db
-- always points at the active profile's table, which has the exact same
-- { minimap = {...}, settings = {...} } shape the addon used before profiles
-- existed, so every other file's addon.db.settings.X / addon.db.minimap.X
-- access keeps working unmodified — only which table addon.db points to changes.
local function getCharKey()
    local name  = UnitName("player") or "Unknown"
    local realm = GetRealmName() or "Unknown"
    return name .. " - " .. realm
end

-- Pre-profiles installs have minimap/settings sitting at the DB's top level.
-- Move that into profiles.Default (once) so existing users keep their config
-- instead of silently resetting to defaults the first time this code runs.
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

function addon.GetActiveProfileName()
    return addon.activeProfileName or "Default"
end

function addon.GetProfileList()
    local list = {}
    for name in pairs(DrievSettingsDB.profiles) do table.insert(list, name) end
    table.sort(list)
    return list
end

-- Re-applies every module's visuals/state from the (now-active) addon.db, and
-- refreshes the settings window if it's currently open. Called after any
-- profile switch; each module re-derives everything from its own getData(),
-- so this is just "call every module's existing apply-from-settings entry
-- point" rather than anything profile-specific.
function addon.RefreshAllModules()
    if addon.TTK then
        if addon.TTK.applyFont       then addon.TTK.applyFont() end
        if addon.TTK.applyPosition   then addon.TTK.applyPosition() end
        if addon.TTK.applyVisibility then addon.TTK.applyVisibility() end
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
    if addon.Particles and addon.Particles.refresh then addon.Particles.refresh() end
    if addon.Raid      and addon.Raid.refresh      then addon.Raid.refresh() end
    if addon.Minimap   and addon.Minimap.refresh   then addon.Minimap.refresh() end
    -- Any currently-visible settings sub-panel refreshes its controls via its
    -- own OnShow handler; toggling the window's shown state cascades OnShow
    -- to whatever's actually on screen without needing a bespoke hook per tab.
    if addon.UI and addon.UI.frame and addon.UI.frame:IsShown() then
        addon.UI.frame:Hide()
        addon.UI.frame:Show()
    end
end

-- Makes `name` the active profile for the CURRENT character and re-applies
-- everything. Fills in any settings keys added since the profile was last
-- used (e.g. after an addon update) the same way login does.
function addon.SetActiveProfile(name)
    if not DrievSettingsDB.profiles[name] then return false, "Profile not found." end
    DrievSettingsDB.profiles[name] = applyDefaults(defaults, DrievSettingsDB.profiles[name])
    addon.db = DrievSettingsDB.profiles[name]
    addon.activeProfileName = name
    DrievSettingsDB.profileAssignments[getCharKey()] = name
    addon.RefreshAllModules()
    return true
end

-- Creates a fresh, default-populated profile. Does not switch to it — the
-- caller decides whether/when to (the Profiles UI switches immediately).
function addon.CreateProfile(name)
    name = name and name:match("^%s*(.-)%s*$") or ""
    if name == "" then return nil, "Enter a profile name." end
    if DrievSettingsDB.profiles[name] then return nil, "A profile with that name already exists." end
    DrievSettingsDB.profiles[name] = applyDefaults(defaults, {})
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

-- ── Profile export/import ────────────────────────────────────────────────────
-- A profile is just nested booleans/numbers/strings/tables, so it's encoded
-- with a small hand-rolled serializer instead of loadstring() — a pasted
-- string comes from another player, and loadstring on untrusted input would
-- let it run arbitrary Lua. Each value is tagged with its type so the reader
-- never has to guess or execute anything: T/F for booleans, N<digits>; for
-- numbers, S<len>:<bytes> for strings (length-prefixed so string contents
-- never need escaping), and {...} for tables. The result is then base64-
-- encoded so it's a single line safe to paste anywhere (Discord, Pastebin,
-- in-game edit boxes) regardless of what bytes the profile happens to contain.

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
    if not ok then return nil, "Corrupt or invalid profile string." end
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

-- Returns an opaque, copy-pasteable string encoding the named profile, or
-- nil + an error message.
function addon.ExportProfile(name)
    local prof = DrievSettingsDB.profiles[name]
    if not prof then return nil, "Profile not found." end
    local ok, payload = pcall(serialize, prof)
    if not ok then return nil, "Could not export this profile." end
    return EXPORT_PREFIX .. base64Encode(payload)
end

-- Creates a new profile called `name` from a string produced by ExportProfile.
-- Returns the profile name on success, or nil + an error message.
function addon.ImportProfile(name, str)
    name = name and name:match("^%s*(.-)%s*$") or ""
    if name == "" then return nil, "Enter a profile name." end
    if DrievSettingsDB.profiles[name] then return nil, "A profile with that name already exists." end

    str = str and str:match("^%s*(.-)%s*$") or ""
    if str:sub(1, #EXPORT_PREFIX) ~= EXPORT_PREFIX then
        return nil, "That doesn't look like a valid profile string."
    end

    local payload = base64Decode(str:sub(#EXPORT_PREFIX + 1))
    local data, err = deserialize(payload)
    if type(data) ~= "table" then
        return nil, err or "That doesn't look like a valid profile string."
    end

    DrievSettingsDB.profiles[name] = applyDefaults(defaults, data)
    return name
end

-- Single bootstrap frame: registers events, then unregisters/releases itself.
local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" then
        if name ~= addonName then return end
        migrateToProfiles()
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        local charKey      = getCharKey()
        local profileName  = DrievSettingsDB.profileAssignments[charKey]
        if not profileName or not DrievSettingsDB.profiles[profileName] then
            profileName = "Default"
            DrievSettingsDB.profileAssignments[charKey] = profileName
        end
        DrievSettingsDB.profiles[profileName] = applyDefaults(defaults, DrievSettingsDB.profiles[profileName])
        addon.db = DrievSettingsDB.profiles[profileName]
        addon.activeProfileName = profileName

        if addon.CreateMinimapButton then
            addon.CreateMinimapButton()
        end
        self:UnregisterEvent("PLAYER_LOGIN")
        self:SetScript("OnEvent", nil)
    end
end)

SLASH_DRIEVSETTINGS1 = "/driev"
SLASH_DRIEVSETTINGS2 = "/dv"
SLASH_DRIEVSETTINGS3 = "/dre"
SlashCmdList["DRIEVSETTINGS"] = function(msg)
    local cmd = msg and msg:lower():match("^%s*(%S*)") or ""

    if cmd == "debug" then
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
            print("|cfffb2c36Driev's Essentials|r debug commands:")
            print("  |cffdddddd/de debug on|r    — start logging API events to SavedVariables")
            print("  |cffdddddd/de debug off|r   — stop logging")
            print("  |cffdddddd/de debug print|r — dump saved log to chat")
            print("  |cffdddddd/de debug clear|r — wipe the saved log")
        end
    else
        if addon.ToggleUI then addon.ToggleUI() end
    end
end
