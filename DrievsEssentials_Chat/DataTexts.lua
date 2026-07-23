local addon = _G.DrievEssentials
if not addon then return end

local UI = addon.UI
local C  = UI.colors

-- Movable ElvUI-style stat bars. The user can create any number of bars; each
-- has its own position (via the addon's Edit Mode), size, colors and its own
-- chosen set of datatexts.
--
-- Ten built-in providers (below) plus any user-created custom ones (see
-- registerCustomProvider); each is a small { label, events/poll, getText }
-- definition living in the same `providers` table regardless of origin, so
-- the bar/layout code never needs to tell built-in from custom apart.

local WHITE = "Interface\\Buttons\\WHITE8x8"

local BAR_DEFAULTS = {
    height          = 24,
    minWidth        = 40,
    -- Inset from the bar's left and right edges, applied to both sides. This is
    -- the only spacing control: the gap BETWEEN datatexts is derived, splitting
    -- whatever room is left over evenly, so raising the padding is what draws
    -- them closer together.
    padding         = 6,
    -- With fixedWidth off the bar shrink-wraps its contents. On, it stays at
    -- `width` and long datatexts are truncated to fit instead.
    fixedWidth      = false,
    width           = 300,
    borderThickness = 1,
    bgColor         = { 0.090, 0.098, 0.165 },
    bgOpacity       = 100,
    borderColor     = { 0.30, 0.31, 0.42 },
    borderOpacity   = 100,
    -- texts is a SET (key -> true) of datatext keys shown on this bar; display
    -- order comes from providerOrder, so no separate ordering is stored.
    texts           = {},
    -- px/py (saved position) are absent until the bar is moved; it falls back
    -- to bottom-center of the screen when unset.
}

addon.RegisterDefaults("dataTexts", {
    enabled   = true,
    bars      = {},  -- [id] = table shaped like BAR_DEFAULTS + { name }
    nextBarID = 0,
    -- User-created datatexts: [id] = { label, code, poll }. id is a string
    -- counter key, bumped by nextCustomID each time one is added. Whether a
    -- given datatext is SHOWN is per-bar (bar.texts), not stored here.
    custom       = {},
    nextCustomID = 0,
    -- User-overridden text prefixes: [providerKey] = "Stam: ". Absent means
    -- "use the provider's own default"; an empty string is a real choice
    -- meaning "show no prefix at all", so the two can't be collapsed.
    prefixes     = {},
    -- Character names kept out of the gold tooltip. Array rather than a set so
    -- the settings list has a stable order to display.
    goldBlacklist = {},
})

-- addon.db only exists once Core has applied the active profile at
-- PLAYER_LOGIN. The poll/event driver below is installed at file scope and so
-- starts ticking before that, hence every entry point checks this first rather
-- than indexing a nil profile.
local function isReady()
    return addon.db ~= nil and addon.db.settings ~= nil
end

local function getData()
    addon.db.settings.dataTexts = addon.db.settings.dataTexts or {}
    return addon.db.settings.dataTexts
end

-- ── Built-in providers ───────────────────────────────────────────────────────
-- providerOrder also defines the left-to-right order segments appear in on a
-- bar, so per-bar assignment can be stored as a plain set with no ordering.
-- ── Value colouring ─────────────────────────────────────────────────────────
-- Only the VALUE is coloured, never the label: the prefix is prepended by
-- updateSegment outside the colour code, so "FPS: " keeps the bar's text colour
-- and only the number shifts.

-- Interpolates through {threshold, r, g, b} stops ordered by ascending
-- threshold, clamping outside the ends.
local function gradient(value, stops)
    local first, last = stops[1], stops[#stops]
    if value <= first[1] then return first[2], first[3], first[4] end
    if value >= last[1]  then return last[2],  last[3],  last[4]  end

    for i = 1, #stops - 1 do
        local a, b = stops[i], stops[i + 1]
        if value >= a[1] and value <= b[1] then
            local span = b[1] - a[1]
            local t = span > 0 and (value - a[1]) / span or 0
            return a[2] + (b[2] - a[2]) * t,
                   a[3] + (b[3] - a[3]) * t,
                   a[4] + (b[4] - a[4]) * t
        end
    end
    return last[2], last[3], last[4]
end

-- WoW colour escapes are |cAARRGGBB, so alpha is available for the flash below.
local function colorize(text, r, g, b, a)
    return string.format("|c%02x%02x%02x%02x%s|r",
        math.floor((a or 1) * 255 + 0.5),
        math.floor(r * 255 + 0.5),
        math.floor(g * 255 + 0.5),
        math.floor(b * 255 + 0.5),
        text)
end

local RED    = { 1.00, 0.15, 0.15 }
local YELLOW = { 1.00, 0.85, 0.10 }
local GREEN  = { 0.30, 0.95, 0.30 }

-- Higher is better: green from 100 up, yellowing below that, red under 60.
local FPS_STOPS = {
    {  30, RED[1],    RED[2],    RED[3]    },
    {  60, YELLOW[1], YELLOW[2], YELLOW[3] },
    { 100, GREEN[1],  GREEN[2],  GREEN[3]  },
}

-- Lower is better: green to 50ms, yellowing past it, red at 100ms and above.
local MS_STOPS = {
    {  50, GREEN[1],  GREEN[2],  GREEN[3]  },
    {  75, YELLOW[1], YELLOW[2], YELLOW[3] },
    { 100, RED[1],    RED[2],    RED[3]    },
}

-- Straight 0-100 ramp, passing through yellow at the midpoint.
local DUR_STOPS = {
    {   0, RED[1],    RED[2],    RED[3]    },
    {  50, YELLOW[1], YELLOW[2], YELLOW[3] },
    { 100, GREEN[1],  GREEN[2],  GREEN[3]  },
}

-- A blink, not a smooth pulse: a datatext only re-renders on its poll tick, and
-- a fade sampled that coarsely reads as stutter rather than animation.
local function blinkAlpha()
    return (math.floor(GetTime() * 2) % 2 == 0) and 1 or 0.35
end

local providers, providerOrder = {}, {}

-- Editable text prefixes, keyed independently of providers.
--
-- Usually a datatext has one label and its slot key IS the provider key. But a
-- datatext can show more than one value ("FPS: 220 MS: 22"), and each of those
-- needs its own renameable label — so slots live in their own registry, and a
-- provider may declare extras via `extraPrefixes`. Each extra gets its own row
-- in the Labels list, and the provider's getText reads it back with getPrefix.
local prefixDefaults, prefixLabels, prefixOrder = {}, {}, {}

-- Forward declaration: the provider closures below call this, but it can't be
-- defined until getData exists further down.
local getPrefix

local function registerPrefixSlot(key, label, default)
    if prefixDefaults[key] == nil then
        prefixOrder[#prefixOrder + 1] = key
    end
    prefixDefaults[key] = default or ""
    prefixLabels[key]   = label or key
end

local function RegisterDataText(key, def)
    def.key = key
    providers[key] = def
    providerOrder[#providerOrder + 1] = key

    registerPrefixSlot(key, def.label, def.prefix)
    for _, extra in ipairs(def.extraPrefixes or {}) do
        registerPrefixSlot(extra.key, extra.label, extra.default)
    end
end

-- Opening the bags is the obvious action for both the money and bag-space
-- readouts, so they share one handler.
local function openBags()
    if ToggleAllBags then ToggleAllBags()
    elseif OpenAllBags then OpenAllBags() end
end

-- ── Gold across characters ──────────────────────────────────────────────────
-- Kept in DrievGoldDB, an ACCOUNT-WIDE SavedVariable, because the whole point
-- is reading it from a different character than the one that wrote it. It sits
-- outside the profile system deliberately: this is observed data, not a
-- setting, so copying a profile shouldn't carry another character's balance
-- around with it.

local function goldStore()
    DrievGoldDB = DrievGoldDB or {}
    DrievGoldDB.chars = DrievGoldDB.chars or {}
    return DrievGoldDB.chars
end

local function charKey()
    return (UnitName("player") or "?") .. " - " .. (GetRealmName() or "?")
end

-- GetMoney() returns 0 in two situations that have nothing to do with an empty
-- purse: before the server has sent this character's balance after login, and
-- while the world is tearing down at logout. Both were being written, and the
-- logout one is what zeroed every alt — it happens on the way out of EVERY
-- session, so a character's last stored value was always 0.
--
-- So a zero is only accepted from PLAYER_MONEY, which fires precisely because
-- the balance changed and is therefore known-good (including a genuine drop to
-- nothing). From any other event a zero means "not a real reading" and is
-- discarded rather than overwriting what is stored.
local function recordGold(trusted)
    -- ElvUI's own guard in Gold.lua: money isn't meaningful until the player is
    -- actually in the world, and several of these events fire before that.
    if IsLoggedIn and not IsLoggedIn() then return end

    local money = GetMoney()
    if not money then return end
    if money == 0 and not trusted then return end

    local _, class = UnitClass("player")
    goldStore()[charKey()] = {
        gold    = money,
        class   = class,
        faction = UnitFactionGroup("player"),
        updated = time(),
    }
end

-- Matches either the full "Name - Realm" key or just the character name, and
-- ignores case — typing the exact stored key by hand is a poor thing to demand.
local function isBlacklisted(key)
    local list = getData().goldBlacklist
    if not list or #list == 0 then return false end

    local lowKey  = key:lower()
    local lowName = (key:match("^(.-) %- ") or key):lower()
    for _, entry in ipairs(list) do
        local e = tostring(entry):lower():match("^%s*(.-)%s*$")
        if e ~= "" and (e == lowKey or e == lowName) then return true end
    end
    return false
end

local function goldTooltip(tt)
    local rows, total = {}, 0
    for key, info in pairs(goldStore()) do
        -- Blacklisted characters are left out of the total as well as the list:
        -- an excluded character that still moved the total would be confusing.
        if not isBlacklisted(key) then
            rows[#rows + 1] = { key = key, gold = info.gold or 0, class = info.class }
            total = total + (info.gold or 0)
        end
    end

    if #rows == 0 then
        tt:AddLine("No characters recorded yet.", 0.6, 0.6, 0.65)
        return
    end

    table.sort(rows, function(a, b) return a.gold > b.gold end)

    for _, row in ipairs(rows) do
        local c = row.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[row.class]
        local r, g, b = 1, 1, 1
        if c then r, g, b = c.r, c.g, c.b end
        tt:AddDoubleLine(row.key, GetCoinTextureString(row.gold), r, g, b, 1, 1, 1)
    end

    tt:AddLine(" ")
    tt:AddDoubleLine("Total", GetCoinTextureString(total), 1, 0.82, 0, 1, 1, 1)
end

-- Recorded from its own frame rather than from the gold datatext's getText, so
-- a character's balance is still logged on alts that don't display the gold
-- datatext at all.
local goldWatcher = CreateFrame("Frame")
-- Deliberately NOT PLAYER_LOGOUT: GetMoney() reads 0 while the world unloads,
-- and writing that zeroed every character on the way out of every session.
-- Nothing is lost by dropping it — the balance is already recorded on login and
-- on every change, and SavedVariables persist whatever is in memory at exit.
goldWatcher:RegisterEvent("PLAYER_LOGIN")
goldWatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
goldWatcher:RegisterEvent("PLAYER_MONEY")
-- The rest are the money-moving events ElvUI's Gold datatext listens to; each
-- can change the balance without PLAYER_MONEY covering the moment.
goldWatcher:RegisterEvent("SEND_MAIL_MONEY_CHANGED")
goldWatcher:RegisterEvent("SEND_MAIL_COD_CHANGED")
goldWatcher:RegisterEvent("PLAYER_TRADE_MONEY")
goldWatcher:RegisterEvent("TRADE_MONEY_CHANGED")
goldWatcher:SetScript("OnEvent", function(_, event)
    -- Only PLAYER_MONEY is trusted to report a real zero: it fires *because*
    -- the balance changed.
    recordGold(event == "PLAYER_MONEY")
end)

RegisterDataText("gold", {
    label   = "Gold",
    prefix  = "",
    events  = { "PLAYER_MONEY", "PLAYER_ENTERING_WORLD" },
    getText = function() return GetCoinTextureString(GetMoney()) end,
    onClick = openBags,
    hint    = "Click to open your bags",
    tooltip = goldTooltip,
})

RegisterDataText("bags", {
    label   = "Bags",
    prefix  = "Bags: ",
    events  = { "BAG_UPDATE", "PLAYER_ENTERING_WORLD" },
    onClick = openBags,
    hint    = "Click to open your bags",
    getText = function()
        local free, total = 0, 0
        for bag = 0, 4 do
            total = total + (C_Container.GetContainerNumSlots(bag) or 0)
            free  = free + (C_Container.GetContainerNumFreeSlots(bag) or 0)
        end
        return string.format("%d/%d", free, total)
    end,
})

-- Scanning 18 slots is too expensive to repeat at the poll rate the flash
-- needs, so the value is cached for a second and only the colour is recomputed
-- on each tick.
local durCache, durCachedAt = nil, 0
local function durabilityPercent()
    local now = GetTime()
    if durCachedAt > 0 and (now - durCachedAt) < 1 then return durCache end

    local cur, max = 0, 0
    for slot = 1, 18 do
        local c, m = GetInventoryItemDurability(slot)
        if c and m and m > 0 then cur = cur + c; max = max + m end
    end

    durCache    = (max > 0) and (cur / max * 100) or nil
    durCachedAt = now
    return durCache
end

RegisterDataText("durability", {
    label  = "Durability",
    prefix = "Durability: ",
    events = { "UPDATE_INVENTORY_DURABILITY", "PLAYER_ENTERING_WORLD" },
    -- Polled as well as event-driven, purely so the low-durability flash has
    -- something to animate on. The cache above keeps that cheap.
    poll   = 0.25,
    getText = function()
        local pct = durabilityPercent()
        if not pct then return "--" end

        local r, g, b = gradient(pct, DUR_STOPS)
        -- Below a quarter it blinks, so it's noticeable without having to be
        -- read. Above that it sits at full alpha.
        local alpha = (pct < 25) and blinkAlpha() or 1
        return colorize(string.format("%d%%", math.floor(pct + 0.5)), r, g, b, alpha)
    end,
})

RegisterDataText("coords", {
    label  = "Coordinates",
    prefix = "",
    poll   = 0.25, -- no event fires continuously while moving, so this is polled
    getText = function()
        local mapID = C_Map.GetBestMapForUnit("player")
        if not mapID then return "" end
        local pos = C_Map.GetPlayerMapPosition(mapID, "player")
        if not pos then return "" end
        local x, y = pos:GetXY()
        return string.format("%.1f, %.1f", (x or 0) * 100, (y or 0) * 100)
    end,
})

-- One datatext showing two values, so it needs two labels: the main prefix in
-- front of the framerate, and a second slot in front of the latency.
RegisterDataText("fps", {
    label   = "FPS / Latency",
    prefix  = "FPS: ",
    extraPrefixes = {
        { key = "fps_ms", label = "FPS / Latency — ms", default = "MS: " },
    },
    poll    = 1,
    getText = function()
        local fps = math.floor(GetFramerate() or 0)
        -- down, up, latencyHome, latencyWorld — home is the realm connection;
        -- fall back to world if home isn't reported yet.
        local _, _, home, world = GetNetStats()
        local ms = home or world or 0

        -- Each number carries its own colour; the labels between them stay the
        -- bar's own text colour. Only the ms label is composed here — the FPS
        -- one is prepended by updateSegment like every other main prefix.
        return colorize(fps, gradient(fps, FPS_STOPS))
            .. " " .. getPrefix("fps_ms")
            .. colorize(ms, gradient(ms, MS_STOPS))
    end,
})

RegisterDataText("date", {
    label   = "Date",
    prefix  = "",
    poll    = 30,
    getText = function() return date("%b %d") end,
})

RegisterDataText("armor", {
    label  = "Armor",
    prefix = "Armor: ",
    events = { "UNIT_INVENTORY_CHANGED", "PLAYER_ENTERING_WORLD" },
    getText = function()
        local _, effective = UnitArmor("player")
        return string.format("%d", effective or 0)
    end,
})

RegisterDataText("stamina", {
    label  = "Stamina",
    prefix = "Stamina: ",
    events = { "UNIT_STATS", "PLAYER_ENTERING_WORLD" },
    getText = function()
        return string.format("%d", UnitStat("player", 3) or 0)
    end,
})

RegisterDataText("haste", {
    label  = "Attack Speed",
    prefix = "Haste: ",
    events = { "UNIT_ATTACK_SPEED", "UNIT_AURA", "UNIT_INVENTORY_CHANGED", "PLAYER_ENTERING_WORLD" },
    -- Classic Era has no haste RATING — the old CR_HASTE_MELEE lookup here
    -- always failed, which is why this only ever printed "n/a". What actually
    -- exists is bonus attack speed from buffs/enchants, which GetMeleeHaste
    -- reports directly as a percentage.
    getText = function()
        local bonus
        if GetMeleeHaste then
            local ok, v = pcall(GetMeleeHaste)
            if ok and type(v) == "number" then bonus = v end
        end
        local speed = UnitAttackSpeed and UnitAttackSpeed("player")

        -- Signed, so slows (Thunderfury and friends) read as negative.
        if bonus and bonus ~= 0 then
            return string.format("%+.0f%%", bonus)
        elseif speed and speed > 0 then
            -- With no bonus active the raw swing timer is the useful number.
            return string.format("0%% (%.2fs)", speed)
        end
        return bonus and "0%" or "n/a"
    end,
})

RegisterDataText("mail", {
    label   = "Mail",
    prefix  = "",
    events  = { "UPDATE_PENDING_MAIL", "PLAYER_ENTERING_WORLD" },
    getText = function() return HasNewMail() and "New Mail!" or "No Mail" end,
})

-- ── Text prefixes ───────────────────────────────────────────────────────────
-- A provider's getText returns only the VALUE; the words in front of it
-- ("Stamina: ") are a separate prefix so they can be renamed without touching
-- the code that produces the number. Overrides are global per datatext rather
-- than per bar — the same stat on two bars reads the same way.

local function prefixStore()
    local d = getData()
    d.prefixes = d.prefixes or {}
    return d.prefixes
end

-- Assigning the forward-declared local, not creating a new one — the provider
-- closures above already captured it.
getPrefix = function(key)
    local override = prefixStore()[key]
    if override ~= nil then return override end
    return prefixDefaults[key] or ""
end

local function setPrefix(key, text)
    prefixStore()[key] = text or ""
end

-- Removing the override (rather than setting it to "") is what restores the
-- registered default.
local function resetPrefix(key)
    prefixStore()[key] = nil
end

local function defaultPrefix(key)
    return prefixDefaults[key] or ""
end

-- Every renameable label, in registration order. Not the same as the provider
-- list: a datatext showing two values contributes two slots.
local function listPrefixSlots()
    local out = {}
    for _, key in ipairs(prefixOrder) do
        out[#out + 1] = { key = key, label = prefixLabels[key] or key }
    end
    return out
end

-- ── Custom (user-created) providers ─────────────────────────────────────────
-- Compiled with load(code, name, "t") — "t" restricts it to a text chunk (no
-- precompiled bytecode blobs), which is a cheap, standard precaution even for
-- a snippet the user wrote for themselves. Otherwise this is a full Lua
-- environment, the same trust model WeakAuras' custom triggers use — this is
-- the user's own local addon, running only on their own client.
local function compileCustom(id, entry)
    local fn = load(entry.code or "return \"\"", "DataText:" .. (entry.label or id), "t")
    if not fn then
        return function() return "|cffff5555(script error)|r" end
    end
    return function()
        local ok, result = pcall(fn)
        if not ok then return "|cffff5555(script error)|r" end
        if result == nil then return "" end
        return tostring(result)
    end
end

local function customKey(id) return "custom_" .. id end

local function registerCustomProvider(id, entry)
    local key = customKey(id)
    if not providers[key] then
        providerOrder[#providerOrder + 1] = key
    end
    providers[key] = {
        key = key, label = entry.label or ("Custom " .. id),
        -- No default prefix: a custom datatext's snippet returns whatever text
        -- the user wants outright. They can still add one via the override.
        prefix = "",
        poll = entry.poll or 2,
        getText = compileCustom(id, entry),
        isCustom = true, customID = id,
    }
    -- Custom datatexts get a renameable label slot too, so they show up in the
    -- Labels list alongside the built-ins. Re-registering on edit keeps the
    -- displayed name in step with the datatext's own label.
    registerPrefixSlot(key, providers[key].label, "")
end


local function unregisterCustomProvider(id)
    local key = customKey(id)
    providers[key] = nil
    for idx, k in ipairs(providerOrder) do
        if k == key then table.remove(providerOrder, idx); break end
    end
    -- Drop it from every bar that was showing it, so a deleted datatext cannot
    -- linger as a stale key in saved settings.
    for _, barCfg in pairs(getData().bars) do
        if barCfg.texts then barCfg.texts[key] = nil end
    end
end

-- ── Bars ─────────────────────────────────────────────────────────────────────
-- barFrames[id] = { frame = <Frame>, segments = { [providerKey] = {btn,text} } }
local barFrames = {}
local rebuildBar -- forward declaration: the mover interface below calls it

local function getBar(id)
    local d = getData()
    d.bars[id] = d.bars[id] or {}
    return d.bars[id]
end

local function getOrCreateBarFrame(id)
    if barFrames[id] then return barFrames[id] end

    local f = CreateFrame("Frame", "DrievDataTextBar" .. id, UIParent, "BackdropTemplate")
    f:SetSize(40, 24)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:Hide()

    local cfg = getBar(id)
    if cfg.px and cfg.py then
        f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", cfg.px, cfg.py)
    else
        f:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 4)
    end

    barFrames[id] = { frame = f, segments = {} }
    return barFrames[id]
end

local function applyBarStyle(id)
    local bf = getOrCreateBarFrame(id)
    local cfg = getBar(id)
    local edge = math.max(cfg.borderThickness or 1, 1)
    bf.frame:SetBackdrop({
        bgFile = WHITE, edgeFile = WHITE, edgeSize = edge,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    local bg = cfg.bgColor or { 0.090, 0.098, 0.165 }
    local bd = cfg.borderColor or { 0.30, 0.31, 0.42 }
    bf.frame:SetBackdropColor(bg[1], bg[2], bg[3], (cfg.bgOpacity or 100) / 100)
    bf.frame:SetBackdropBorderColor(bd[1], bd[2], bd[3], (cfg.borderOpacity or 100) / 100)
end

-- DataText segments share the Chat feature's one font setting (see Chat.lua).
-- Only the face is swapped; each segment keeps GameFontNormalSmall's size/flags.
local SEG_DEFAULT_FACE
local function applySegFont(text)
    if not (text and text.GetFont) then return end
    local _, size, flags = text:GetFont()
    if not size then return end
    if not SEG_DEFAULT_FACE then
        SEG_DEFAULT_FACE = (GameFontNormalSmall and select(1, GameFontNormalSmall:GetFont()))
                            or STANDARD_TEXT_FONT
    end
    local override = addon.Chat and addon.Chat.getFontPath and addon.Chat.getFontPath()
    text:SetFont(override or SEG_DEFAULT_FACE, size, flags)
end

local function ensureSegment(id, key)
    local bf = getOrCreateBarFrame(id)
    if bf.segments[key] then return bf.segments[key] end

    local btn = CreateFrame("Button", nil, bf.frame)
    local text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("CENTER")
    text:SetTextColor(unpack(C.textWhite))
    -- Required for truncation: a FontString only clips (with an ellipsis) when
    -- it has a width and wrapping is off. Without this a too-long datatext
    -- would wrap onto a second line instead of being cut.
    text:SetWordWrap(false)

    btn:SetScript("OnEnter", function(self)
        local provider = providers[key]
        if not provider then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(provider.label, 1, 1, 1)

        if provider.tooltip then
            -- A provider with its own tooltip body replaces the plain value
            -- echo, which would otherwise just repeat what the bar already
            -- shows immediately above it.
            provider.tooltip(GameTooltip)
        else
            GameTooltip:AddLine(text:GetText() or "", 0.8, 0.8, 0.8)
        end

        if provider.hint then
            GameTooltip:AddLine(provider.hint, 0.6, 0.6, 0.65)
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", GameTooltip_Hide)

    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function(_, button)
        local provider = providers[key]
        if provider and provider.onClick then provider.onClick(button) end
    end)

    bf.segments[key] = { btn = btn, text = text }
    return bf.segments[key]
end

-- A bar's left-to-right display order.
--
-- cfg.texts stays the SET of which datatexts are on the bar; cfg.order is their
-- sequence. Rebuilt lazily on each read so it self-heals: bars saved before
-- ordering existed have no order at all, datatexts can be ticked on and off,
-- and a custom datatext can be deleted out from under it.
local function barOrder(id)
    local cfg = getBar(id)
    cfg.texts = cfg.texts or {}
    cfg.order = cfg.order or {}

    local out, seen = {}, {}
    -- Keep the stored sequence for anything still enabled and still registered.
    for _, key in ipairs(cfg.order) do
        if cfg.texts[key] and providers[key] and not seen[key] then
            seen[key] = true
            out[#out + 1] = key
        end
    end
    -- Anything newly ticked on joins the end, in registration order.
    for _, key in ipairs(providerOrder) do
        if cfg.texts[key] and not seen[key] then
            seen[key] = true
            out[#out + 1] = key
        end
    end

    cfg.order = out
    return out
end

-- Moves one datatext left (-1) or right (+1) on its bar.
local function moveInBar(id, key, delta)
    local order = barOrder(id)
    for i, k in ipairs(order) do
        if k == key then
            local j = i + delta
            if j < 1 or j > #order then return false end
            order[i], order[j] = order[j], order[i]
            getBar(id).order = order
            return true
        end
    end
    return false
end

-- Re-flows one bar's visible segments left-to-right, sized to their text, and
-- shrink-wraps the bar (down to its configured minimum width).
-- Fallback inset either side of the datatext group, when a bar predates the
-- padding setting.
local BAR_PAD    = 6
-- Breathing room around a datatext's text inside its own clickable segment.
local SEG_PAD    = 12
local MIN_SEG_W  = 20
-- Floor for the gap between datatexts when there is no slack to spread.
local MIN_GAP    = 10

local function layoutBar(id)
    local bf   = getOrCreateBarFrame(id)
    local cfg  = getBar(id)
    local segH = math.max((cfg.height or 24) - 4, 10)
    local pad  = cfg.padding or BAR_PAD

    -- Measure everything before placing anything: spreading and truncation both
    -- need the total up front.
    --
    -- Widths are cleared first so GetStringWidth reports the text's natural
    -- size. Measuring while a previous pass's width constraint is still applied
    -- would feed the clamped value back in, and the segments would creep
    -- narrower on every refresh.
    local order   = barOrder(id)
    local visible = {}
    local natural = {}
    local sumW    = 0

    for _, key in ipairs(order) do
        local seg = bf.segments[key]
        if seg and seg.btn:IsShown() then
            seg.text:SetWidth(0)
            local w = math.max(seg.text:GetStringWidth() + SEG_PAD, MIN_SEG_W)
            visible[#visible + 1] = key
            natural[key] = w
            sumW = sumW + w
        end
    end

    local n = #visible
    local barW, scale, gap

    -- Spacing is derived, not configured: the datatexts are pushed out to the
    -- padding on each side and whatever room is left over is split evenly
    -- between them. Widening the padding is what pulls them back together.
    if cfg.fixedWidth then
        barW = math.max(cfg.width or 300, MIN_SEG_W + pad * 2)
        local avail = barW - pad * 2

        if sumW > avail then
            -- Too much content to spread: fall back to a minimum gap and shrink
            -- every segment by the same proportion. Scaling them all rather
            -- than dropping the ones that don't fit means nothing silently
            -- vanishes, and the short entries stay readable.
            gap = MIN_GAP
            local forSegs = avail - gap * math.max(n - 1, 0)
            scale = (forSegs > 0 and sumW > 0) and math.min(forSegs / sumW, 1) or 1
        else
            scale = 1
            gap = (n > 1) and ((avail - sumW) / (n - 1)) or 0
        end
    else
        -- Auto-width bars shrink-wrap their contents, so there is no slack to
        -- share out — the gap is simply the minimum. It only becomes a real
        -- spread when minWidth forces the bar wider than its contents.
        scale = 1
        gap   = MIN_GAP
        barW  = math.max(sumW + gap * math.max(n - 1, 0) + pad * 2, cfg.minWidth or 40)

        local avail = barW - pad * 2
        if n > 1 and sumW < avail then
            gap = (avail - sumW) / (n - 1)
        end
    end

    local finalW = {}
    local placedW = 0
    for _, key in ipairs(visible) do
        local w = math.max(math.floor(natural[key] * scale), MIN_SEG_W)
        finalW[key] = w
        placedW = placedW + w
    end

    -- A single datatext has nothing to spread against, so it is centred rather
    -- than pinned to the left padding.
    local x = (n == 1) and ((barW - placedW) / 2) or pad

    for _, key in ipairs(visible) do
        local seg = bf.segments[key]
        local w   = finalW[key]
        seg.btn:ClearAllPoints()
        seg.btn:SetPoint("LEFT", bf.frame, "LEFT", x, 0)
        seg.btn:SetSize(w, segH)
        -- Only constrain the text when it actually has to be cut; leaving it
        -- unconstrained otherwise avoids an unnecessary ellipsis from rounding.
        seg.text:SetWidth(scale < 1 and math.max(w - 4, 1) or 0)
        x = x + w + gap
    end

    bf.frame:SetHeight(cfg.height or 24)
    bf.frame:SetWidth(barW)
end

local function updateSegment(id, key)
    local bf = barFrames[id]
    if not bf then return end
    local seg = bf.segments[key]
    if not (seg and seg.btn:IsShown()) then return end
    local provider = providers[key]
    if not provider then return end
    local ok, value = pcall(provider.getText)
    if ok then
        seg.text:SetText(getPrefix(key) .. tostring(value or ""))
    else
        seg.text:SetText("")
    end
    layoutBar(id)
end

rebuildBar = function(id)
    local bf   = getOrCreateBarFrame(id)
    local cfg  = getBar(id)
    local show = getData().enabled ~= false

    for _, key in ipairs(providerOrder) do
        local seg = ensureSegment(id, key)
        applySegFont(seg.text)   -- re-apply the shared chat font before measuring
        seg.btn:SetShown(show and (cfg.texts or {})[key] == true)
    end
    applyBarStyle(id)
    layoutBar(id)
    for _, key in ipairs(providerOrder) do updateSegment(id, key) end

    if show then bf.frame:Show() else bf.frame:Hide() end
end

-- Rebuilds every bar. Called on load and whenever settings change.
local function rebuildAll()
    if not isReady() then return end
    local d = getData()
    -- Drop frames for bars that no longer exist.
    for id, bf in pairs(barFrames) do
        if not d.bars[id] then
            bf.frame:Hide()
            barFrames[id] = nil
        end
    end
    for id in pairs(d.bars) do rebuildBar(id) end
end

-- ── Mover interface (one object per bar) ────────────────────────────────────
local barMovers = {}

local function getBarMover(id)
    if barMovers[id] then return barMovers[id] end
    local mover = {}

    -- Read live rather than stored: bars are renameable, and the Modules list
    -- in Edit Mode should show whatever the bar is called right now.
    function mover.getLabel()
        return "Bar: " .. (getBar(id).name or ("Bar " .. tostring(id)))
    end

    function mover.getFrame() return getOrCreateBarFrame(id).frame end

    function mover.getPosition()
        local f = mover.getFrame()
        return f:GetLeft() or 0, f:GetBottom() or 0
    end

    function mover.setPosition(x, y)
        local f = mover.getFrame()
        f:ClearAllPoints()
        f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x, y)
        local cfg = getBar(id)
        cfg.px, cfg.py = x, y
    end

    function mover.savePosition()
        local bf = barFrames[id]
        if not bf then return end
        local cfg = getBar(id)
        cfg.px, cfg.py = bf.frame:GetLeft(), bf.frame:GetBottom()
    end

    function mover.applyVisibility() rebuildBar(id) end

    function mover.enterMoveMode()
        local f = mover.getFrame()
        f:SetFrameStrata("TOOLTIP")
        addon.ShowEditBox(f)
        f:EnableMouse(true)
        f:SetScript("OnMouseDown", function(self, button)
            if button ~= "LeftButton" then return end
            self._clickX, self._clickY = GetCursorPosition()
            self:StartMoving()
        end)
        f:SetScript("OnMouseUp", function(self, button)
            if button ~= "LeftButton" then return end
            self:StopMovingOrSizing()
            local x, y = GetCursorPosition()
            local sx, sy = self._clickX or x, self._clickY or y
            if math.abs(x - sx) < 4 and math.abs(y - sy) < 4 and addon.UI then
                addon.UI.OpenPositionEditor(mover, self)
            end
        end)
    end

    function mover.leaveMoveMode()
        local bf = barFrames[id]
        if not bf then return end
        bf.frame:SetFrameStrata("MEDIUM")
        addon.HideEditBox(bf.frame)
        bf.frame:EnableMouse(false)
        bf.frame:SetScript("OnMouseDown", nil)
        bf.frame:SetScript("OnMouseUp", nil)
    end

    barMovers[id] = mover
    return mover
end

-- ── Bar CRUD ─────────────────────────────────────────────────────────────────
local function copyTable(t)
    local out = {}
    for k, v in pairs(t) do out[k] = (type(v) == "table") and copyTable(v) or v end
    return out
end

local function addBar(name)
    local d = getData()
    d.nextBarID = (d.nextBarID or 0) + 1
    local id = tostring(d.nextBarID)
    local cfg = copyTable(BAR_DEFAULTS)
    cfg.name = name or ("Bar " .. id)
    d.bars[id] = cfg
    rebuildBar(id)
    return id
end

local function removeBar(id)
    local d = getData()
    d.bars[id] = nil
    local bf = barFrames[id]
    if bf then bf.frame:Hide(); barFrames[id] = nil end
    barMovers[id] = nil
end

local function listBars() return getData().bars end

-- ── Custom datatext CRUD ────────────────────────────────────────────────────
local function addCustomDataText(label, code, poll)
    local d = getData()
    d.nextCustomID = (d.nextCustomID or 0) + 1
    local id = tostring(d.nextCustomID)
    d.custom[id] = { label = label, code = code, poll = poll or 2 }
    registerCustomProvider(id, d.custom[id])
    rebuildAll()
    return id
end

local function updateCustomDataText(id, label, code, poll)
    local entry = getData().custom[id]
    if not entry then return end
    entry.label, entry.code, entry.poll = label, code, poll or entry.poll
    registerCustomProvider(id, entry) -- re-registering recompiles getText
    rebuildAll()
end

local function removeCustomDataText(id)
    local d = getData()
    d.custom[id] = nil
    unregisterCustomProvider(id)
    rebuildAll()
end

local function listCustomDataTexts() return getData().custom end

-- Every datatext key available to assign to a bar, in display order.
local function listProviders()
    local out = {}
    for _, key in ipairs(providerOrder) do
        out[#out + 1] = { key = key, label = providers[key].label }
    end
    return out
end

-- ── Event/poll dispatch ──────────────────────────────────────────────────────
local eventFrame = CreateFrame("Frame")
local pollElapsed = {} -- providerKey -> seconds since last update

local function updateKeyOnAllBars(key)
    for id in pairs(getData().bars) do updateSegment(id, key) end
end

local function registerEvents()
    local seen = {}
    for _, key in ipairs(providerOrder) do
        for _, ev in ipairs(providers[key].events or {}) do
            if not seen[ev] then
                eventFrame:RegisterEvent(ev)
                seen[ev] = true
            end
        end
    end
end

eventFrame:SetScript("OnEvent", function(_, event)
    if not isReady() then return end
    for _, key in ipairs(providerOrder) do
        for _, ev in ipairs(providers[key].events or {}) do
            if ev == event then updateKeyOnAllBars(key); break end
        end
    end
end)

eventFrame:SetScript("OnUpdate", function(_, elapsed)
    if not isReady() then return end
    for _, key in ipairs(providerOrder) do
        local provider = providers[key]
        if provider.poll then
            pollElapsed[key] = (pollElapsed[key] or provider.poll) + elapsed
            if pollElapsed[key] >= provider.poll then
                pollElapsed[key] = 0
                updateKeyOnAllBars(key)
            end
        end
    end
end)

-- ── Init ─────────────────────────────────────────────────────────────────────
local function applyVisibility() rebuildAll() end

local function init()
    local d = getData()
    for id, entry in pairs(d.custom) do
        registerCustomProvider(id, entry)
    end
    -- First run (or upgrading from the single-bar version): give the user a
    -- bar to work with, pre-filled with the common stats, rather than an empty
    -- screen with no obvious starting point.
    if not next(d.bars) then
        local id = addBar("Bar 1")
        local cfg = getBar(id)
        for _, key in ipairs({ "gold", "bags", "durability", "coords", "fps", "date", "mail" }) do
            cfg.texts[key] = true
        end
    end

    -- An interim version briefly split FPS and latency into two datatexts, then
    -- went back to one. Anyone who loaded that version has a dead "latency" key
    -- saved on their bars; barOrder already ignores keys with no provider, so
    -- it's inert, but clear it out rather than leaving it to puzzle over later.
    if d.migratedFpsSplit then
        d.migratedFpsSplit = nil
        for _, barCfg in pairs(d.bars) do
            if barCfg.texts then barCfg.texts.latency = nil end
            if barCfg.order then
                for i = #barCfg.order, 1, -1 do
                    if barCfg.order[i] == "latency" then table.remove(barCfg.order, i) end
                end
            end
        end
    end

    registerEvents()
    rebuildAll()
end

local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function()
    init()
    loginFrame:UnregisterEvent("PLAYER_LOGIN")
end)

addon.DataTexts = {
    refresh         = rebuildAll,
    applyVisibility = applyVisibility,
    -- bars
    addBar          = addBar,
    removeBar       = removeBar,
    listBars        = listBars,
    getBarMover     = getBarMover,
    rebuildBar      = rebuildBar,
    barOrder        = barOrder,
    moveInBar       = moveInBar,
    -- prefixes
    getPrefix       = getPrefix,
    setPrefix       = setPrefix,
    resetPrefix     = resetPrefix,
    defaultPrefix   = defaultPrefix,
    listPrefixSlots = listPrefixSlots,
    -- gold tracking
    listGoldChars   = function()
        local out = {}
        for key, info in pairs(goldStore()) do
            out[#out + 1] = { key = key, gold = info.gold or 0 }
        end
        table.sort(out, function(a, b) return a.gold > b.gold end)
        return out
    end,
    forgetGoldChar  = function(key) goldStore()[key] = nil end,
    -- datatexts
    addCustom       = addCustomDataText,
    updateCustom    = updateCustomDataText,
    removeCustom    = removeCustomDataText,
    listCustom      = listCustomDataTexts,
    listProviders   = listProviders,
}

-- Bars join Edit Mode through a provider (not UI.RegisterMovable, which only
-- handles fixed addon.X tables) since the set of bars changes at runtime.
UI.RegisterMovableProvider(function()
    local list = {}
    if not isReady() then return list end
    if getData().enabled == false then return list end
    for id in pairs(getData().bars) do list[#list + 1] = getBarMover(id) end
    return list
end)
