local addon = _G.DrievEssentials
if not addon then return end

-- Sound alerts. Currently one trigger (incoming whisper); the structure is
-- built to take more.
--
-- Sounds come from LibSharedMedia-3.0, which the core addon already bundles and
-- already uses for the font picker. That's the standard way WoW addons share
-- media: anything registered by a sound pack the user has installed (or by
-- ElvUI, WeakAuras, etc.) shows up in the list automatically, without this
-- addon shipping audio of its own.
--
-- LSM ships exactly one sound out of the box ("None"), so a handful of
-- Blizzard's own files are registered below to give the dropdown something
-- useful on a fresh install. They're registered INTO LSM rather than kept in a
-- private list, so other addons get them too.

local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

-- The default sound is bundled with the addon (Media\Whisper.ogg) rather than
-- being one of Blizzard's, so it's guaranteed present and consistent. Its name
-- is used as the whisperSound default below, so the two must match.
local DEFAULT_SOUND = "Driev Whisper"

-- LSM validates that sound paths end in .ogg or .mp3 and silently rejects
-- anything else, so these must stay .ogg.
local BUILTIN_SOUNDS = {
    [DEFAULT_SOUND]  = [[Interface\AddOns\DrievsEssentials_Chat\Media\Whisper.ogg]],
    ["Whisper"]      = [[Sound\Interface\iTellMessage.ogg]],
    ["Ready Check"]  = [[Sound\Interface\ReadyCheck.ogg]],
    ["Raid Warning"] = [[Sound\Interface\RaidWarning.ogg]],
    ["Level Up"]     = [[Sound\Interface\LevelUp.ogg]],
    ["Map Ping"]     = [[Sound\Interface\MapPing.ogg]],
    ["Auction Open"] = [[Sound\Interface\AuctionWindowOpen.ogg]],
    ["Bell Toll"]    = [[Sound\Doodad\BellTollAlliance.ogg]],
}

if LSM then
    for name, path in pairs(BUILTIN_SOUNDS) do
        LSM:Register("sound", name, path)
    end
end

addon.RegisterDefaults("alerts", {
    whisperEnabled = true,
    whisperSound   = DEFAULT_SOUND,
    -- Whispers can arrive in bursts; without a floor between plays a few
    -- arriving together stack into one long noise.
    throttle       = 3,
})

local function isReady()
    return addon.db ~= nil and addon.db.settings ~= nil
end

local function getData()
    addon.db.settings.alerts = addon.db.settings.alerts or {}
    return addon.db.settings.alerts
end

-- The list shown in the dropdown. Read live from LSM so sounds registered by
-- other addons after load still appear.
local function soundList()
    if not LSM then return { "None" } end
    local list = LSM:List("sound")
    -- LSM hands back its own internal table; copy it so sorting can't disturb
    -- the library's state.
    local out = {}
    for i = 1, #list do out[i] = list[i] end
    table.sort(out)
    return out
end

-- Plays a named LSM sound. Returns whether it actually started, so the UI's
-- test button can report a sound that failed to load.
local function playSound(name)
    if not (LSM and name) or name == "None" then return false end
    local path = LSM:Fetch("sound", name, true)
    if not path or path == 1 then return false end
    local willPlay = PlaySoundFile(path, "Master")
    return willPlay and true or false
end

local lastPlayed = 0
local function fireWhisperAlert()
    if not isReady() then return end
    local d = getData()
    if not d.whisperEnabled then return end
    -- "Enable Chat System" (chat.enabled) is the parent switch for this whole
    -- module — whisper alerts enabled on their own tab still shouldn't fire
    -- while that's off.
    if addon.Chat and not addon.Chat.isEnabled() then return end

    local now = GetTime()
    if now - lastPlayed < (d.throttle or 3) then return end
    lastPlayed = now

    playSound(d.whisperSound)
end

local f = CreateFrame("Frame")
f:RegisterEvent("CHAT_MSG_WHISPER")
f:RegisterEvent("CHAT_MSG_BN_WHISPER")
f:SetScript("OnEvent", function(_, _, _, sender)
    -- Ignore our own whispers echoed back (CHAT_MSG_WHISPER_INFORM is a
    -- separate event, but guard anyway for oddities like addon relays).
    if sender and sender == UnitName("player") then return end
    fireWhisperAlert()
end)

addon.Alerts = {
    soundList = soundList,
    playSound = playSound,
    getData   = getData,
}
