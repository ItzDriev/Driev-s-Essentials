local addon = _G.DrievEssentials
if not addon then return end

-- The chat window LAYOUT (which windows exist, what each is called, and what each
-- one shows) kept in the profile, for the same reason ChatChannels.lua keeps the
-- channel roster there: Blizzard stores all of it per character, so every alt
-- starts with one window called General and nothing else.
--
-- Everything here goes through Blizzard's own ChatFrame_* / FCF_* functions —
-- the exact ones its chat settings UI calls — so the result is saved in the
-- client's config and survives independently of this addon.

addon.RegisterDefaults("chatWindows", {
    enabled = false,   -- module stays off until the user opts in
    -- Close windows this character has that the list doesn't mention. Off by
    -- default: it's the one half of the reconcile that destroys something, so it
    -- waits to be asked for rather than tidying away a window on first login.
    closeExtra = false,
    -- Ordered, one entry per window in the tab strip:
    --   { name = "General", groups = { SAY = true, … }, channels = { "Trade", … } }
    windows = {},
})

-- Part of the one "Chat" section in the Profiles tab (see Chat.lua).
if addon.RegisterProfileSection then
    addon.RegisterProfileSection({ key = "chat", settings = { "chatWindows" } })
end

local MAX_WINDOWS = 10   -- NUM_CHAT_WINDOWS, but that global isn't up at file scope

local function isReady()
    return addon.db ~= nil and addon.db.settings ~= nil
end

local function getData()
    addon.db.settings.chatWindows = addon.db.settings.chatWindows or {}
    local d = addon.db.settings.chatWindows
    d.windows = d.windows or {}
    return d
end

-- Gated by the Chat module's master switch as well as its own, matching Panels,
-- DataTexts and Alerts.
local function isEnabled()
    return isReady() and getData().enabled and addon.Chat and addon.Chat.isEnabled() or false
end

-- ── Message groups ──────────────────────────────────────────────────────────
-- Curated rather than derived from ChatTypeGroup, which also holds internal
-- groups with no meaning in a settings list. Sections mirror how Blizzard's own
-- chat settings groups them, so the list reads the way people already expect.
--
-- Anything this client build doesn't define is filtered out by sections() below,
-- so entries that exist only on some versions (Achievements, Instance chat) can
-- stay listed without a per-build check here.
local GROUP_SECTIONS = {
    { title = "Player", groups = {
        { "SAY",                  "Say" },
        { "EMOTE",                "Emote" },
        { "YELL",                 "Yell" },
        { "WHISPER",              "Whisper" },
        { "BN_WHISPER",           "Battle.net Whisper" },
        { "GUILD",                "Guild" },
        { "OFFICER",              "Officer" },
        { "PARTY",                "Party" },
        { "PARTY_LEADER",         "Party Leader" },
        { "RAID",                 "Raid" },
        { "RAID_LEADER",          "Raid Leader" },
        { "RAID_WARNING",         "Raid Warning" },
        { "INSTANCE_CHAT",        "Instance" },
        { "INSTANCE_CHAT_LEADER", "Instance Leader" },
        { "BATTLEGROUND",         "Battleground" },
        { "BATTLEGROUND_LEADER",  "Battleground Leader" },
        -- Join/leave/list notices, NOT the channel messages themselves — those
        -- follow the per-channel list further down the panel.
        { "CHANNEL",              "Channel Notices" },
        { "AFK",                  "AFK Replies" },
        { "DND",                  "DND Replies" },
        { "IGNORED",              "Ignored" },
    } },
    { title = "Creature", groups = {
        { "MONSTER_SAY",          "Creature Say" },
        { "MONSTER_EMOTE",        "Creature Emote" },
        { "MONSTER_YELL",         "Creature Yell" },
        { "MONSTER_WHISPER",      "Creature Whisper" },
        { "MONSTER_BOSS_EMOTE",   "Boss Emote" },
        { "MONSTER_BOSS_WHISPER", "Boss Whisper" },
    } },
    { title = "Combat & Progress", groups = {
        { "COMBAT_XP_GAIN",        "Experience" },
        { "COMBAT_HONOR_GAIN",     "Honor" },
        { "COMBAT_FACTION_CHANGE", "Reputation" },
        { "SKILL",                 "Skill" },
        { "LOOT",                  "Loot" },
        { "MONEY",                 "Money" },
        { "TRADESKILLS",           "Tradeskills" },
        { "OPENING",               "Opening" },
        { "PET_INFO",              "Pet Info" },
        { "COMBAT_MISC_INFO",      "Other Combat" },
        { "TARGETICONS",           "Target Icons" },
    } },
    { title = "System", groups = {
        { "SYSTEM",                "System" },
        { "ERRORS",                "Errors" },
        { "ACHIEVEMENT",           "Achievements" },
        { "GUILD_ACHIEVEMENT",     "Guild Achievements" },
        { "BN_INLINE_TOAST_ALERT", "Battle.net Alerts" },
    } },
}

-- What a window created from this panel starts with. Without a seed a new window
-- would come up showing nothing at all, which reads as broken rather than empty.
local NEW_WINDOW_GROUPS = { "SAY", "EMOTE", "YELL", "WHISPER", "GUILD", "PARTY", "RAID", "SYSTEM" }

local sectionCache
local function sections()
    if sectionCache then return sectionCache end
    sectionCache = {}
    for _, sec in ipairs(GROUP_SECTIONS) do
        local kept = {}
        for _, g in ipairs(sec.groups) do
            if ChatTypeGroup and ChatTypeGroup[g[1]] then
                kept[#kept + 1] = { key = g[1], label = g[2] }
            end
        end
        if #kept > 0 then
            sectionCache[#sectionCache + 1] = { title = sec.title, groups = kept }
        end
    end
    return sectionCache
end

-- ── The two windows WoW always has ──────────────────────────────────────────
-- ChatFrame1 is the main window and ChatFrame2 is the Combat Log. Neither can be
-- closed, so the list always leads with them and neither is removable. The Combat
-- Log's contents come from Blizzard's combat log filters rather than from message
-- groups or channels, so its name is the only part of it that's ours to set.
local function mainWindowName()  return GENERAL    or "General"    end
local function combatLogName()   return COMBAT_LOG or "Combat Log" end

local function newGroupSet()
    local groups = {}
    for _, g in ipairs(NEW_WINDOW_GROUPS) do
        if not ChatTypeGroup or ChatTypeGroup[g] then groups[g] = true end
    end
    return groups
end

-- Reads a live window into a config entry. Seeding from the client rather than
-- from a built-in default is what makes enabling the module a no-op on the
-- character doing the enabling: it records the window you already have instead of
-- imposing a layout over it, and only alts see anything change.
local function captureFrame(cf, fallbackName)
    local id     = cf and cf:GetID()
    local name   = id and GetChatWindowInfo and GetChatWindowInfo(id)
    local groups = {}
    for _, g in ipairs((cf and cf.messageTypeList) or {}) do groups[g] = true end
    local channels = {}
    for _, c in ipairs((cf and cf.channelList) or {}) do channels[#channels + 1] = c end
    -- Only when the frame told us nothing — an empty group set would be a window
    -- that displays nothing, which reads as broken rather than as a fresh start.
    if not next(groups) then groups = newGroupSet() end

    return {
        name     = (name and name ~= "" and name) or fallbackName,
        groups   = groups,
        channels = channels,
    }
end

-- Seeded here rather than through RegisterDefaults: applyDefaults merges key by
-- key, so a default group set living there would quietly reappear at every login
-- after the user unticked something.
local function ensureBase(d)
    local w = d.windows
    if not w[1] then
        w[1] = captureFrame(_G["ChatFrame1"], mainWindowName())
    end

    if not w[2] then
        local name = GetChatWindowInfo and GetChatWindowInfo(2)
        w[2] = {
            name      = (name and name ~= "" and name) or combatLogName(),
            combatLog = true,
        }
    elseif not w[2].combatLog then
        -- A profile written before the Combat Log became a fixed entry. If slot 2
        -- already held it, marking it is enough; anything else is pushed down
        -- rather than overwritten, so nothing the user configured is lost.
        if (w[2].name or "") == combatLogName() then
            w[2].combatLog = true
        else
            table.insert(w, 2, { name = combatLogName(), combatLog = true })
        end
    end
    -- Drop anything an older capture left on it; neither is applied any more.
    w[2].groups, w[2].channels = nil, nil
end

local function isPermanent(index) return index == 1 or index == 2 end

-- ── Which windows actually exist ────────────────────────────────────────────
-- A slot having a name in the client config does NOT mean the window exists: WoW
-- ships stored names for all ten — "Voice", "Chat 9", "Chat 10" and so on —
-- whether or not you ever opened them, and `isInitialized` is set for every slot
-- the config was loaded into. The only honest test is the one that decides
-- whether the window is drawn: is it on screen, or in a dock.
local function windowInUse(i)
    local cf = _G["ChatFrame" .. i]
    if not cf then return false end
    if i == 1 then return true end             -- the main window is always there
    if cf.IsShown and cf:IsShown() then return true end
    if not GetChatWindowInfo then return false end
    local name, _, _, _, _, _, shown, _, docked = GetChatWindowInfo(i)
    if not name or name == "" then return false end
    return (shown and shown ~= 0) or (docked and docked ~= 0) or false
end

-- A window this addon may touch, or nil. Temporary frames are the whisper/BN
-- conversation tabs the client opens and closes on its own — rewriting one would
-- turn someone's open conversation into a general chat window, so they're
-- excluded here and nowhere else, which is what keeps openWindow below from
-- mistaking a conversation tab that just opened for the window it asked for.
local function manageable(i)
    local cf = _G["ChatFrame" .. i]
    if cf and not cf.isTemporary and windowInUse(i) then return cf end
    return nil
end

local function manageableFrames()
    local out = {}
    for i = 1, (NUM_CHAT_WINDOWS or MAX_WINDOWS) do
        local cf = manageable(i)
        if cf then out[#out + 1] = cf end
    end
    return out
end

-- FCF_OpenNewWindow picks the slot itself and doesn't return the frame on every
-- build, so the slot it took is found by diffing what's manageable before and
-- after. Returns nil when the client refused to open one — every slot taken, by
-- real windows or by open conversation tabs.
local function openWindow(name)
    if not FCF_OpenNewWindow then return nil end

    local before = {}
    for i = 1, (NUM_CHAT_WINDOWS or MAX_WINDOWS) do before[i] = manageable(i) ~= nil end

    local created = FCF_OpenNewWindow(name and name ~= "" and name or "Chat")
    if type(created) == "table" and created.GetID then return created end

    for i = 1, (NUM_CHAT_WINDOWS or MAX_WINDOWS) do
        if not before[i] then
            local cf = manageable(i)
            if cf then return cf end
        end
    end
    return nil
end

-- Putting a channel in a window's list is NOT the same as the window listening
-- for it. ChatFrame_RemoveAllChannels unregisters CHAT_MSG_CHANNEL on its way out
-- (Blizzard drops the event as soon as the list empties) and ChatFrame_AddChannel
-- doesn't put it back — registration lives in ChatFrame_RegisterForChannels,
-- which only Blizzard's own load path calls. Without this the channels read as
-- enabled everywhere you can check them and the window stays silent until the
-- next reload.
--
-- Done by hand rather than by calling ChatFrame_RegisterForChannels ourselves:
-- that rebuilds the window's lists from GetChatWindowChannels, which reports
-- nothing until the client has flushed the config — so on a bad day it wipes the
-- list we just built instead of registering it.
--
-- zoneChannelList is fixed up here for the same reason. A zone channel's messages
-- are matched on a numeric zone id, never on the name, and the id is simply the
-- channel's position in EnumerateServerChannels() — which is how Blizzard resolves
-- it too. Reading it back from the saved config gives 0 for a channel that wasn't
-- joined at the moment it was written, and a 0 is exactly what leaves General,
-- Trade and LookingForGroup looking correctly configured while receiving nothing.
local serverIndex
local function zoneChannelID(name)
    if not serverIndex then
        serverIndex = {}
        if EnumerateServerChannels then
            for i, n in ipairs({ EnumerateServerChannels() }) do
                if type(n) == "string" then serverIndex[n:lower()] = i end
            end
        end
    end
    return serverIndex[(name or ""):lower()] or 0
end

local function hasChannel(cf, name)
    for _, n in ipairs(cf.channelList or {}) do
        if n:lower() == name:lower() then return true end
    end
    return false
end

local function registerChannels(cf)
    local list = cf.channelList
    if not (list and #list > 0) then return end

    cf.zoneChannelList = cf.zoneChannelList or {}
    for i, name in ipairs(list) do
        -- Only the server channels get an override; 0 is the right answer for a
        -- custom channel and mustn't be stamped over.
        local zone = zoneChannelID(name)
        if zone > 0 or cf.zoneChannelList[i] == nil then
            cf.zoneChannelList[i] = zone
        end
    end

    if cf.RegisterEvent then cf:RegisterEvent("CHAT_MSG_CHANNEL") end
end

-- Returns true when the window was actually renamed, which is the only part of
-- this that the caller has to follow up on.
local function applyWindow(cf, cfg)
    local renamed = false
    -- Only when the name really differs. FCF_SetWindowName re-measures the tab
    -- and makes the dock re-lay-out its whole strip, so calling it on every pass
    -- meant every ticked checkbox visibly nudged the tabs about.
    local current = GetChatWindowInfo and GetChatWindowInfo(cf:GetID())
    if cfg.name and cfg.name ~= "" and cfg.name ~= current and FCF_SetWindowName then
        FCF_SetWindowName(cf, cfg.name)
        renamed = true
    end
    -- Rename-only: see the Combat Log note above.
    if cfg.combatLog then return renamed end

    -- Remove-all-then-add rather than a diff: it's what Blizzard's own settings
    -- panel effectively does, and it means a group unticked here actually goes
    -- away instead of lingering because we never noticed it was there.
    if ChatFrame_RemoveAllMessageGroups then ChatFrame_RemoveAllMessageGroups(cf) end
    if ChatFrame_AddMessageGroup then
        for _, sec in ipairs(sections()) do
            for _, g in ipairs(sec.groups) do
                if cfg.groups and cfg.groups[g.key] then
                    ChatFrame_AddMessageGroup(cf, g.key)
                end
            end
        end
    end

    if ChatFrame_RemoveAllChannels then ChatFrame_RemoveAllChannels(cf) end
    cf.channelList     = cf.channelList or {}
    cf.zoneChannelList = cf.zoneChannelList or {}
    local CC = addon.ChatChannels
    for i, name in ipairs(cfg.channels or {}) do
        if name ~= "" then
            -- The window config Blizzard's chat settings reads back is compared
            -- exactly, while joining isn't: a channel added as "World" when the
            -- server calls it "world" delivers its messages but shows unchecked
            -- in Blizzard's Global Channels list. Store the client's spelling,
            -- and correct our own copy so the two stay in step.
            local canon = CC and CC.canonicalName(name) or name
            if canon ~= name then
                cfg.channels[i] = canon
                name = canon
            end

            if ChatFrame_AddChannel then ChatFrame_AddChannel(cf, name) end
            -- ChatFrame_AddChannel declines silently for a channel this character
            -- isn't in yet, which would leave the window configured for nothing at
            -- all. Writing the entry ourselves costs nothing when the helper
            -- already did it, and it's what makes the channel work the moment it's
            -- joined instead of only after the next reload.
            if not hasChannel(cf, name) then
                cf.channelList[#cf.channelList + 1]         = name
                cf.zoneChannelList[#cf.zoneChannelList + 1] = zoneChannelID(name)
                if AddChatWindowChannel then AddChatWindowChannel(cf:GetID(), name) end
            end
        end
    end
    registerChannels(cf)
    return renamed
end

-- Windows this character has that the list doesn't. Walked from the end so the
-- positions still to be checked can't shift underneath us.
local function closeExtras(keep)
    if not FCF_Close then return 0 end

    local frames = manageableFrames()
    local closed = 0
    for k = #frames, keep + 1, -1 do
        local cf = frames[k]
        -- ChatFrame1 and ChatFrame2 are Blizzard's own and refuse to close. The
        -- list always holds both, so k is never below 3 here — this is what makes
        -- that an invariant rather than an assumption.
        if cf:GetID() > 2 then
            -- pcall because FCF_Close reaches into the dock manager, and a window
            -- it declines to close must not take the rest of the pass with it.
            if pcall(FCF_Close, cf) then closed = closed + 1 end
        end
    end
    return closed
end

-- Reconciles this character's tab strip against the list: extra windows are
-- closed, missing ones created, and the rest renamed and refilled in place.
--
-- Entry k is paired with the k-th window that actually exists, rather than with
-- ChatFrame k: the unused slots carrying stock names sit in between, so index
-- arithmetic against them would land the config on the wrong window.
--
-- Returns how many entries could not be given a window, and how many were closed.
local function apply()
    if not isEnabled() then return 0, 0 end
    local d = getData()
    ensureBase(d)

    -- Before the pairing loop: closing frees the slots that creating then needs,
    -- and it keeps position k meaning the same thing throughout.
    local closed = d.closeExtra and closeExtras(#d.windows) or 0

    local frames = manageableFrames()
    local unplaced, touched = 0, closed > 0
    for k, cfg in ipairs(d.windows) do
        local cf = frames[k]
        if not cf then
            cf = openWindow(cfg.name)
            if cf then
                frames[k] = cf
                touched = true
                -- Created long after PLAYER_LOGIN, so it missed Chat.lua's
                -- per-frame hooks (timestamps, copy arrow, chat history) and
                -- would be the one window without them until the next reload.
                if addon.Chat and addon.Chat.hookFrame then
                    addon.Chat.hookFrame(cf, cf:GetID())
                end
            end
        end
        if cf then
            if applyWindow(cf, cfg) then touched = true end
        else
            unplaced = unplaced + 1
        end
    end

    -- Only when the tab strip actually changed; see applyOne.
    if touched and addon.Chat then addon.Chat.refresh() end
    return unplaced, closed
end

-- ── List editing (called from ChatUI) ───────────────────────────────────────
local function addWindow(name)
    if not isReady() then return nil, "Settings aren't loaded yet." end
    local windows = getData().windows
    if #windows >= (NUM_CHAT_WINDOWS or MAX_WINDOWS) then
        return nil, "WoW supports at most " .. (NUM_CHAT_WINDOWS or MAX_WINDOWS) .. " chat windows."
    end

    windows[#windows + 1] = {
        name     = (name and name ~= "" and name) or ("Chat " .. (#windows + 1)),
        groups   = newGroupSet(),
        channels = {},
    }
    return #windows
end

-- Pushes ONE entry to its window, creating it if this character doesn't have it
-- yet. What the panel uses so an edit shows up in chat straight away; a full
-- apply() would also reorder and close windows, which is far more than a ticked
-- checkbox asked for. Returns the frame, or nil if there was no slot for it.
local function applyOne(index)
    if not isEnabled() then return nil end
    local d = getData()
    ensureBase(d)
    if not d.windows[index] then return nil end

    -- A window can only show a channel this character has actually joined, and a
    -- zone channel can only resolve its numeric id once joined. At login
    -- ChatChannels runs two seconds ahead for exactly that reason; an edit made in
    -- the panel has no such ordering, so nudge it first. No-op when that module is
    -- switched off.
    if addon.ChatChannels then addon.ChatChannels.apply() end

    local frames = manageableFrames()
    -- Windows pair with entries by position, so entry `index` can't have one
    -- until every entry before it does — creating only the one asked for would
    -- land it on the slot an earlier entry is waiting for. Each stepping stone
    -- gets its own settings on the way past.
    local touched = false
    for k = #frames + 1, index do
        local cf = openWindow(d.windows[k] and d.windows[k].name)
        if not cf then return nil end
        if addon.Chat and addon.Chat.hookFrame then addon.Chat.hookFrame(cf, cf:GetID()) end
        frames[k] = cf
        touched = true
        if k < index and d.windows[k] then applyWindow(cf, d.windows[k]) end
    end

    local cf = frames[index]
    if not cf then return nil end
    if applyWindow(cf, d.windows[index]) then touched = true end

    -- Only when a tab actually appeared or was renamed. Chat.refresh restyles
    -- every chat frame, and running it for a ticked message type was both wasted
    -- work and a visible flicker in the tab strip.
    if touched and addon.Chat then addon.Chat.refresh() end
    return cf
end

-- What the window is actually set to receive right now, lowercased. Lets the
-- panel name the channel that didn't take, instead of leaving "it doesn't work"
-- as the only symptom available.
local function liveChannels(index)
    local out = {}
    if not isReady() then return out end
    local cf = manageableFrames()[index]
    if not cf then return out end
    -- A populated list the frame isn't listening on receives nothing, so it
    -- doesn't count as live.
    if cf.IsEventRegistered and not cf:IsEventRegistered("CHAT_MSG_CHANNEL") then
        return out
    end
    local CC = addon.ChatChannels
    for _, n in ipairs(cf.channelList or {}) do
        -- Configured is not the same as receiving. The window happily holds a
        -- channel this character hasn't joined — that's deliberate, so it starts
        -- working the moment they do — but until then nothing arrives, and that's
        -- the case worth telling them about.
        if not CC or CC.channelIndex(n) > 0 then out[n:lower()] = true end
    end
    return out
end

-- Renames one window on the live client as well as in the list. Separate from
-- apply() because a name typed into the panel should show up on the tab as it's
-- typed, and a full reconcile would also rewrite message groups, rejoin channels
-- and close windows — far too much to hang off an edit box losing focus.
--
-- Returns true when the tab itself was renamed, false when the new name could
-- only be stored: the module is off, or this character doesn't have that window
-- yet (the panel marks those "(new)").
local function renameWindow(index, name)
    if not isReady() then return false end
    local d = getData()
    ensureBase(d)

    local cfg = d.windows[index]
    if not cfg then return false end
    name = (name or ""):match("^%s*(.-)%s*$")
    if name == "" then return false end
    cfg.name = name

    if not isEnabled() then return false end
    local cf = manageableFrames()[index]
    if not (cf and FCF_SetWindowName) then return false end

    -- Already wearing it: renaming re-measures the tab and reflows the dock, so
    -- doing it for no change would jiggle the strip for nothing.
    if (GetChatWindowInfo and GetChatWindowInfo(cf:GetID())) == name then return true end

    FCF_SetWindowName(cf, name)
    -- A tab's width comes from its text, and the dock lays its tabs out against
    -- those widths, so without this the renamed tab keeps its old footprint and
    -- overlaps its neighbour until something else forces a dock update.
    if FCFDock_UpdateTabs and GENERAL_CHAT_DOCK then
        pcall(FCFDock_UpdateTabs, GENERAL_CHAT_DOCK, true)
    end
    -- Re-asserts the flat-tab styling and font over Blizzard's relayout.
    if addon.Chat then addon.Chat.refresh() end
    return true
end

-- Swap rather than remove+insert: the list is short, and a swap leaves every
-- other entry's position — and therefore which window it drives — untouched.
--
-- Positions 1 and 2 are ChatFrame1 and ChatFrame2, which WoW owns, so nothing can
-- move into or out of them. That makes position 3 the top of the movable range.
local function moveWindow(index, delta)
    if not isReady() then return false end
    local d = getData()
    ensureBase(d)

    local target = index + delta
    if isPermanent(index) or isPermanent(target) then return false end
    if target < 1 or target > #d.windows then return false end

    d.windows[index], d.windows[target] = d.windows[target], d.windows[index]
    return true
end

-- Closes the window this entry is paired with, on THIS character. Deleting from
-- the panel is an explicit, confirmed action on one window, so it takes effect
-- there and then; `closeExtra` governs the automatic sweep at login on every
-- OTHER character, which is a different question and stays opt-in.
--
-- Must run BEFORE the entry is dropped: windows pair with entries by position, so
-- removing it first would point this at the next window along.
local function closeOne(index)
    if not (isReady() and isEnabled() and FCF_Close) then return false end
    if isPermanent(index) then return false end
    local cf = manageableFrames()[index]
    -- ChatFrame1 and ChatFrame2 refuse to close; see closeExtras.
    if not cf or cf:GetID() <= 2 then return false end
    return pcall(FCF_Close, cf) and true or false
end

-- Only the profile entry is dropped. The window itself is left open on whatever
-- characters already have it: closing chat windows out from under someone as a
-- side effect of editing a list is not something a settings panel should do.
local function removeWindow(index)
    if not isReady() then return false end
    -- The main window and the Combat Log exist on every character whether we
    -- manage them or not, so there's nothing a removal could mean.
    if isPermanent(index) then return false end
    table.remove(getData().windows, index)
    return true
end

-- Seeds the list from the windows this character already has, so an existing
-- setup can be captured once and pushed to every alt. Replaces the stored list —
-- unlike the channel roster, a half-merged window layout has no useful meaning.
--
-- Only windows that really exist are taken; see windowInUse for why the stock
-- names sitting in the unused slots are not evidence of one.
local function captureCurrent()
    if not isReady() then return 0 end
    local d = getData()
    wipe(d.windows)

    for k, cf in ipairs(manageableFrames()) do
        local i = cf:GetID()
        local name = GetChatWindowInfo and GetChatWindowInfo(i)
        name = (name and name ~= "" and name) or ("Chat " .. i)

        if i == 2 then
            -- ChatFrame2 is the Combat Log — name only, no groups or channels.
            d.windows[k] = { name = name, combatLog = true }
        else
            local groups = {}
            for _, g in ipairs(cf.messageTypeList or {}) do groups[g] = true end
            local channels = {}
            for _, c in ipairs(cf.channelList or {}) do channels[#channels + 1] = c end
            d.windows[k] = { name = name, groups = groups, channels = channels }
        end
    end

    -- Puts back either of the two permanent entries the capture somehow missed.
    ensureBase(d)
    return #d.windows
end

-- ── Login ───────────────────────────────────────────────────────────────────
-- Two passes, each two seconds behind ChatChannels.lua's, so a channel is joined
-- before a window is told to show it. Re-running is harmless: applyWindow is a
-- full rewrite of the window's lists, not an accumulate.
local booted = false
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:SetScript("OnEvent", function()
    -- First entry only: this also fires on every zone-in, and rebuilding the
    -- layout there would undo any tab the user rearranged mid-session.
    if booted then return end
    booted = true
    C_Timer.After(7,  apply)
    C_Timer.After(17, apply)
end)

addon.ChatWindows = {
    apply          = apply,
    refresh        = apply,
    isEnabled      = isEnabled,
    sections       = sections,
    addWindow      = addWindow,
    removeWindow   = removeWindow,
    renameWindow   = renameWindow,
    moveWindow     = moveWindow,
    applyOne       = applyOne,
    closeOne       = closeOne,
    liveChannels   = liveChannels,
    captureCurrent = captureCurrent,
    isPermanent    = isPermanent,
    -- How many of the listed windows this character actually has, so the panel
    -- can mark the rest as ones it will create.
    frameCount     = function() return #manageableFrames() end,
    list           = function()
        if not isReady() then return {} end
        local d = getData()
        ensureBase(d)
        return d.windows
    end,
}
