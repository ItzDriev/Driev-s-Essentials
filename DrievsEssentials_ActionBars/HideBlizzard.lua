-- Part of the Action Bars module. Hides Blizzard's default bars so ours can
-- replace them, the way Bartender4 does. Nothing is destroyed: frames are
-- reparented to a permanently-hidden frame and their buttons unregistered,
-- which is enough to stop them fighting us for layout while leaving the secure
-- action system intact.
--
-- Everything is nil-checked — Classic Era lacks many frames retail has. Runs
-- once, guarded by addon.ActionBars.blizzardHidden, and only when the module is
-- enabled, so disabling this addon leaves Blizzard's bars untouched.
local addon = _G.DrievEssentials
if not addon then return end

local UIHider

local function ensureHider()
    if not UIHider then
        UIHider = CreateFrame("Frame")
        UIHider:Hide()
    end
    return UIHider
end

-- Writing a table key from insecure code can taint it even when setting nil;
-- this no-ops on unrelated numeric keys until the target reports secure again.
-- Same trick as Bartender4's Util:PurgeKey.
local function purgeKey(t, k)
    t[k] = nil
    local c = 42
    repeat
        if t[c] == nil then t[c] = nil end
        c = c + 1
    until issecurevariable(t, k)
end

local function hideBarFrame(frame, clearEvents)
    if not frame then return end
    if clearEvents and frame.UnregisterAllEvents then
        frame:UnregisterAllEvents()
    end
    -- EditMode (1.15.9+) tracks frames via `.system` and overrides Hide with a
    -- version that talks to that system — calling it on a frame still marked as an
    -- active system both fails to hide it and risks tainting that path. HideBase is
    -- the untainted original; clearing isShownExternal first tells Edit Mode's
    -- bookkeeping the frame is gone.
    if frame.system then
        purgeKey(frame, "isShownExternal")
    end
    if frame.HideBase then
        frame:HideBase()
    else
        frame:Hide()
    end
    frame:SetParent(ensureHider())
end

local function hideButton(button)
    if not button then return end
    button:Hide()
    if button.UnregisterAllEvents then button:UnregisterAllEvents() end
    button:SetAttribute("statehidden", true)
end

-- Bar frames whose native buttons we blank out. Name strings (looked up via _G)
-- so a global missing on Classic is skipped rather than erroring at parse time.
local NATIVE_BUTTON_PREFIXES = {
    "ActionButton",
    "MultiBarBottomLeftButton",
    "MultiBarBottomRightButton",
    "MultiBarRightButton",
    "MultiBarLeftButton",
    "StanceButton",       -- both possible globals blanked, same reasoning as the
    "ShapeshiftButton",   -- bar frame itself above — nil lookups just no-op
    "PetActionButton",
}

-- Exposed so ActionBars.lua calls it once, only when the module is enabled.
function addon.HideBlizzardActionBars()
    if addon.ActionBars and addon.ActionBars.blizzardHidden then return end

    hideBarFrame(_G.MainMenuBar,        false)
    -- Classic Era's Edit Mode moved Action Bar 1's system frame off MainMenuBar
    -- (now a legacy shell) onto MainActionBar. Without hiding it, Edit Mode still
    -- registers and highlights it alongside ours.
    hideBarFrame(_G.MainActionBar,      false)
    hideBarFrame(_G.MultiBarBottomLeft,  true)
    hideBarFrame(_G.MultiBarBottomRight, true)
    hideBarFrame(_G.MultiBarLeft,        true)
    hideBarFrame(_G.MultiBarRight,       true)
    -- Both globals are hidden regardless of which the running client uses —
    -- hideBarFrame no-ops on nil, so this covers a rename between clients.
    hideBarFrame(_G.StanceBarFrame,      true)
    hideBarFrame(_G.ShapeshiftBarFrame,  true)
    -- Same as MainActionBar: 1.15.9 moved the stance bar's system frame onto its own
    -- "StanceBar". The buttons are already parked on the hidden frame, but without
    -- hiding this too, Edit Mode leaves StanceBar's decorative border art stuck on
    -- screen with nothing behind it.
    hideBarFrame(_G.StanceBar,           true)
    hideBarFrame(_G.PetActionBarFrame,   true)
    hideBarFrame(_G.PetActionBar,        true)
    -- Same as MainActionBar: BagsBar is its own Edit Mode system. buildBagBar()
    -- already reparents its buttons, but the empty frame still needs hiding or Edit
    -- Mode keeps showing it as a separate bag bar.
    hideBarFrame(_G.BagsBar,             true)

    for _, prefix in ipairs(NATIVE_BUTTON_PREFIXES) do
        for i = 1, 12 do
            hideButton(_G[prefix .. i])
        end
    end

    -- These events re-show MainMenuBar on combat/grid changes; stop them so the
    -- bar we just hid stays hidden (mirrors BT4).
    if _G.MainMenuBar then
        _G.MainMenuBar:UnregisterEvent("PLAYER_REGEN_ENABLED")
        _G.MainMenuBar:UnregisterEvent("PLAYER_REGEN_DISABLED")
        _G.MainMenuBar:UnregisterEvent("ACTIONBAR_SHOWGRID")
        _G.MainMenuBar:UnregisterEvent("ACTIONBAR_HIDEGRID")
    end

    if addon.ActionBars then addon.ActionBars.blizzardHidden = true end
end
