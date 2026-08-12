local addon = _G.DrievEssentials
if not addon then return end

-- A channel roster kept in the PROFILE rather than per character.
--
-- WoW stores which chat channels you're in — and what colour each one is — in the
-- per-character client config, so a fresh alt lands in General/Trade and nothing
-- else, with Blizzard's stock colours. This module replays the profile's list on
-- every login, which is what makes every character end up in the same channels,
-- in the same order, wearing the same colours.
--
-- Order matters and is why the list is an array rather than a keyed table: a
-- channel's number (/1, /2, …) is handed out by join order, so a list that
-- shuffled between characters would leave /5 meaning something different on each.

addon.RegisterDefaults("chatChannels", {
    enabled = false,          -- module stays off until the user opts in
    -- Any channel this character is in that isn't on the roster is added to it.
    -- On by default: the point of the module is a roster that matches what you
    -- actually use, and making that happen shouldn't need a button press.
    autoAdd = true,
    -- Ordered: { name = "World", password = "", color = {r,g,b}, useColor = false,
    --            number = 5 }  -- nil = whatever join order gives it
    list    = {},
    -- [lowercase name] = true for channels removed by hand while autoAdd is on.
    -- Without it, Remove would be undone by the next auto-add pass.
    ignored = {},
})

-- The most channels the client will hold, and therefore the highest number a
-- channel can be pinned to.
local MAX_CHANNELS = 10

local function isReady()
    return addon.db ~= nil and addon.db.settings ~= nil
end

local function getData()
    addon.db.settings.chatChannels = addon.db.settings.chatChannels or {}
    local d = addon.db.settings.chatChannels
    d.list    = d.list or {}
    d.ignored = d.ignored or {}
    return d
end

-- Gated by the Chat module's master switch as well as its own, matching Panels,
-- DataTexts and Alerts — turning the Chat System off turns everything off.
local function isEnabled()
    return isReady() and getData().enabled and addon.Chat and addon.Chat.isEnabled() or false
end

-- ── Reading the client's channel state ──────────────────────────────────────
-- GetChannelList returns a flat run of (id, name, disabled) in current builds and
-- (id, name) in older ones, so the stride is read back off the values instead of
-- assumed — guessing wrong silently pairs an id with the previous name.
local function eachJoined(fn)
    if not GetChannelList then return end
    local vals = { GetChannelList() }
    local i = 1
    while i <= #vals do
        local id, name = vals[i], vals[i + 1]
        if type(id) == "number" and type(name) == "string" and name ~= "" then
            fn(id, name)
        end
        i = i + (type(vals[i + 2]) == "boolean" and 3 or 2)
    end
end

-- Zone channels report through GetChannelList decorated with the zone they're for
-- ("General - Elwynn Forest"), but are stored — by Blizzard's own chat window
-- settings, and so by us — under their bare name, since the zone half differs on
-- every character and in every zone. EnumerateServerChannels is the client's own
-- list of which names behave that way, so a custom channel that happens to be
-- called "Something - Else" is left alone.
local serverBases
local function serverChannelBases()
    if not serverBases then
        serverBases = {}
        if EnumerateServerChannels then
            for _, n in ipairs({ EnumerateServerChannels() }) do
                if type(n) == "string" then serverBases[n:lower()] = n end
            end
        end
    end
    return serverBases
end

local function baseName(name)
    local head = name:match("^(.-) %- ")
    return head and serverChannelBases()[head:lower()] or name
end

-- The client's OWN spelling of a channel, which is not necessarily the one that
-- was typed. Joining is case-insensitive — /join World puts you in a channel the
-- server calls "world" — but the window config Blizzard's chat settings reads back
-- is compared exactly. Store "World" there and the channel's messages arrive while
-- its box in Blizzard's Global Channels list stays unchecked, because to that
-- comparison it's a different channel.
--
-- Falls back to the name as given when we aren't in the channel yet; a later pass
-- picks up the real spelling once we are.
local function canonicalName(name)
    if not (name and name ~= "") then return name end
    local base = baseName(name)

    -- EnumerateServerChannels is authoritative for the zone channels' casing,
    -- and works whether or not we're currently in them.
    local zone = serverChannelBases()[base:lower()]
    if zone then return zone end

    local found
    eachJoined(function(_, cname)
        cname = baseName(cname)
        if not found and cname:lower() == base:lower() then found = cname end
    end)
    return found or base
end

-- The channel's current number, or 0 when we aren't in it. Per character and not
-- stable across sessions, which is why nothing is cached from it.
local function channelIndex(name)
    if not (name and name ~= "" and GetChannelName) then return 0 end
    local id = tonumber((GetChannelName(name)))
    if id and id > 0 then return id end

    -- GetChannelName matches on the decorated name, so a zone channel stored as
    -- "General" misses above even while we're sitting in it.
    local found = 0
    eachJoined(function(cid, cname)
        if found == 0 and baseName(cname):lower() == name:lower() then found = cid end
    end)
    return found
end

-- Every channel we could sensibly offer a chat window: the configured roster plus
-- whatever this character happens to be in right now (zone channels like General
-- and Trade are joined by the client, so they'd otherwise never appear).
local function knownChannels()
    local out, seen = {}, {}
    if not isReady() then return out end
    for _, e in ipairs(getData().list) do
        local n = e.name
        if n and n ~= "" and not seen[n:lower()] then
            seen[n:lower()] = true
            out[#out + 1] = n
        end
    end
    eachJoined(function(_, name)
        name = baseName(name)
        if not seen[name:lower()] then
            seen[name:lower()] = true
            out[#out + 1] = name
        end
    end)
    return out
end

-- ── Joining ─────────────────────────────────────────────────────────────────
local function joinEntry(entry)
    if channelIndex(entry.name) > 0 then return false end   -- already in it
    if not JoinPermanentChannel then return false end

    local target = DEFAULT_CHAT_FRAME or _G["ChatFrame1"]
    local pass = entry.password
    if pass == "" then pass = nil end
    JoinPermanentChannel(entry.name, pass, target and target:GetID() or 1, false)
    -- Joining alone doesn't put the channel in any window — Blizzard's own join
    -- path pairs the two, and without it the channel is joined but invisible.
    -- ChatWindows.lua reassigns it afterwards if a window claims it.
    if ChatFrame_AddChannel and target then
        ChatFrame_AddChannel(target, entry.name)
    end
    return true
end

-- ── Pinned numbers ──────────────────────────────────────────────────────────
-- A channel's number is handed out by join order, which differs per character
-- because the client joins the zone channels itself before we get a look in.
-- Blizzard's chat settings reorder the list by swapping pairs, and that same
-- swap is the only way to put a channel on a chosen number.
local function swapFunc()
    if C_ChatInfo and C_ChatInfo.SwapChatChannelsByChannelIndex then
        return C_ChatInfo.SwapChatChannelsByChannelIndex
    end
    -- Pre-8.0 global, still present on some Classic builds.
    return SwapChatChannelsByChannelIndex
end

local function canReorder() return swapFunc() ~= nil end

local function swapChannels(a, b)
    local fn = swapFunc()
    if not fn then return false end
    fn(a, b)
    return true
end

local function joinedCount()
    local n = 0
    eachJoined(function() n = n + 1 end)
    return n
end

-- Processed in ascending order of the number asked for, so a swap can never
-- disturb a channel already parked correctly: every position below the target is
-- either unpinned or already holds the right channel.
local function applyOrder()
    if not isEnabled() then return end

    local wanted = {}
    for _, e in ipairs(getData().list) do
        local n = tonumber(e.number)
        if n and e.name and e.name ~= "" then
            wanted[#wanted + 1] = { name = e.name, want = math.floor(n) }
        end
    end
    if #wanted == 0 then return end
    table.sort(wanted, function(a, b) return a.want < b.want end)

    -- A number past the end of the list has nothing to swap with. Skipping (rather
    -- than clamping to the end) is what keeps two channels wanting 8 and 9 out of a
    -- tug-of-war over slot 6 on a character that's only in six.
    local total = joinedCount()
    for _, w in ipairs(wanted) do
        if w.want <= total then
            local cur = channelIndex(w.name)
            if cur > 0 and cur ~= w.want then
                if not swapChannels(cur, w.want) then return end
            end
        end
    end
end

-- Numbers stay unique by construction: handing one to an entry takes it off
-- whoever had it, so two channels can never be pinned to the same slot.
local function setNumber(index, n)
    if not isReady() then return end
    local list = getData().list
    local entry = list[index]
    if not entry then return end

    n = tonumber(n)
    n = n and math.floor(n) or nil
    if n and (n < 1 or n > MAX_CHANNELS) then n = nil end

    if n then
        for i, e in ipairs(list) do
            if i ~= index and e.number == n then e.number = nil end
        end
    end
    entry.number = n
end

-- ── Colours ─────────────────────────────────────────────────────────────────
-- Colours are stored against the channel's NUMBER ("CHANNEL1".."CHANNEL10"), not
-- its name, so this has to run once the server has actually assigned numbers —
-- hence the retry passes below rather than a single call at login.
local function applyColors()
    if not (isEnabled() and ChangeChatColor) then return end
    for _, e in ipairs(getData().list) do
        if e.useColor and e.color then
            local id = channelIndex(e.name)
            if id > 0 then
                ChangeChatColor("CHANNEL" .. id, e.color[1] or 1, e.color[2] or 1, e.color[3] or 1)
            end
        end
    end
end

-- ── Auto-detection ──────────────────────────────────────────────────────────
-- Adds joined channels the roster doesn't know about yet, keeping the colour each
-- currently wears. `manual` is the Capture button: an explicit click overrides the
-- ignore list, where an automatic pass respects it.
local function absorbJoined(manual)
    if not isReady() then return 0 end
    local d = getData()

    local seen = {}
    for _, e in ipairs(d.list) do seen[(e.name or ""):lower()] = true end

    local added = 0
    eachJoined(function(id, name)
        -- Stored bare, so "General - Elwynn Forest" seen on one character is still
        -- the right channel on an alt standing somewhere else.
        name = baseName(name)
        local key = name:lower()
        if seen[key] then return end
        if not manual and d.ignored[key] then return end

        seen[key] = true
        d.ignored[key] = nil
        local info = ChatTypeInfo and ChatTypeInfo["CHANNEL" .. id]
        d.list[#d.list + 1] = {
            name     = name,
            password = "",
            color    = info and { info.r, info.g, info.b } or { 1, 1, 1 },
            useColor = false,
        }
        added = added + 1
    end)
    return added
end

local function autoDetect()
    if not (isReady() and getData().autoAdd) then return 0 end
    return absorbJoined(false)
end

-- Rewrites stored names to the client's own spelling once we're actually in the
-- channel. Done as its own pass rather than only at add time, because the channel
-- usually isn't joined yet at the moment it's typed in.
local function normalizeNames()
    if not isReady() then return false end
    local changed = false
    for _, e in ipairs(getData().list) do
        local canon = canonicalName(e.name)
        if canon and canon ~= e.name then
            e.name = canon
            changed = true
        end
    end
    return changed
end

-- Everything that has to happen after the channel list changes, minus joining.
-- Deliberately no joins: CHAT_MSG_CHANNEL_NOTICE also fires when you LEAVE a
-- channel, and rejoining one second after a /leave would make leaving impossible
-- for the rest of the session. The roster is re-joined at the next login instead.
local function settle()
    if not isEnabled() then return end
    autoDetect()
    normalizeNames()
    applyOrder()
    applyColors()
end

local function apply()
    if not isEnabled() then return end
    autoDetect()
    -- Before joining, so a stored name differing only in case from one we're
    -- already in doesn't get joined a second time.
    normalizeNames()
    for _, e in ipairs(getData().list) do
        if e.name and e.name ~= "" then joinEntry(e) end
    end
    -- And again after: a channel joined just now reports back under the server's
    -- own spelling, which is the one the window config has to be written with.
    -- A join that hasn't landed yet is picked up by the channel-notice pass or by
    -- the second login pass, the same way colours and numbers converge.
    normalizeNames()
    -- A channel joined a moment ago has no number yet, so this pass only orders and
    -- colours the ones already settled; the channel events and the second login
    -- pass catch the rest.
    applyOrder()
    applyColors()
end

-- ── List editing (called from ChatUI) ───────────────────────────────────────
local function addChannel(name, password)
    if not isReady() then return nil, "Settings aren't loaded yet." end
    name = (name or ""):match("^%s*(.-)%s*$")
    if name == "" then return nil, "Enter a channel name." end

    local list = getData().list
    for _, e in ipairs(list) do
        if (e.name or ""):lower() == name:lower() then
            return nil, "That channel is already on the list."
        end
    end

    local entry = {
        -- If we're already in it, take the client's spelling rather than the
        -- typed one; see canonicalName.
        name     = canonicalName(name),
        password = (password or ""):match("^%s*(.-)%s*$"),
        color    = { 1, 1, 1 },
        useColor = false,
    }
    list[#list + 1] = entry
    -- Adding by hand is the clearest possible statement that it's wanted, so it
    -- overrides an earlier removal.
    getData().ignored[name:lower()] = nil
    return entry
end

local function removeChannel(index)
    if not isReady() then return end
    local d = getData()
    local entry = table.remove(d.list, index)
    -- With auto-add on, a channel you're still in would be straight back on the
    -- list a second later. Remembering the removal is what makes Remove stick.
    if entry and entry.name and d.autoAdd then
        d.ignored[entry.name:lower()] = true
    end
end

-- Swap rather than remove+insert: the list is short and a swap keeps every other
-- entry's index (and therefore its channel number) untouched.
local function moveChannel(index, delta)
    if not isReady() then return false end
    local list = getData().list
    local target = index + delta
    if target < 1 or target > #list then return false end
    list[index], list[target] = list[target], list[index]
    return true
end

-- The Capture button: same detection the automatic pass uses, but it also picks
-- up anything previously removed by hand.
local function captureCurrent()
    return absorbJoined(true)
end

-- ── Login + channel events ──────────────────────────────────────────────────
-- Two passes: channel numbers aren't handed out the instant JoinPermanentChannel
-- is called, and on a slow realm the first pass can find nothing to colour.
-- ChatWindows.lua runs its own passes two seconds behind each of these, so a
-- channel is always joined before a window is told to display it.
local function scheduleLoginPasses()
    C_Timer.After(5,  apply)
    C_Timer.After(15, apply)
end

local settleQueued = false
local function queueSettle()
    if settleQueued or not isEnabled() then return end
    settleQueued = true
    -- Channel notices arrive in bursts (one per channel on login), and each one
    -- would otherwise drive a full re-detect, reorder and recolour. Reordering
    -- fires CHANNEL_UI_UPDATE itself, so this converges rather than looping: the
    -- pass it triggers finds everything already in place and swaps nothing.
    C_Timer.After(1, function()
        settleQueued = false
        settle()
    end)
end

local booted = false
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("CHANNEL_UI_UPDATE")
f:RegisterEvent("CHANNEL_COUNT_UPDATE")
f:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE")
f:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_ENTERING_WORLD" then
        -- Only the first entry: zoning into an instance fires this too, and
        -- re-running the join pass there would fight the client's own zone
        -- channel handling.
        if booted then return end
        booted = true
        scheduleLoginPasses()
    else
        -- Anything that can renumber channels invalidates every pinned number and
        -- every colour we set, and a channel joined by hand is one the roster
        -- hasn't seen yet.
        queueSettle()
    end
end)

addon.ChatChannels = {
    apply          = apply,
    settle         = settle,
    applyColors    = applyColors,
    applyOrder     = applyOrder,
    refresh        = apply,
    isEnabled      = isEnabled,
    knownChannels  = knownChannels,
    channelIndex   = channelIndex,
    canonicalName  = canonicalName,
    joinedCount    = joinedCount,
    -- Lets the panel say so plainly rather than offering a number box that
    -- silently does nothing on a build without the swap API.
    canReorder     = canReorder,
    maxNumber      = MAX_CHANNELS,
    addChannel     = addChannel,
    removeChannel  = removeChannel,
    moveChannel    = moveChannel,
    setNumber      = setNumber,
    captureCurrent = captureCurrent,
    list           = function() return isReady() and getData().list or {} end,
}
