-- Part of the Action Bars module addon. Hides Blizzard's default action bars so
-- our own LibActionButton-based bars can replace them, mirroring the approach
-- Bartender4 uses (its HideBlizzard.lua). We never destroy the Blizzard frames —
-- they're reparented to a permanently-hidden frame and their buttons are
-- unregistered, which is enough to get them off-screen and stop them fighting us
-- for layout, while leaving the secure action system intact underneath.
--
-- Everything here is deliberately defensive: Classic Era does not have every
-- frame retail does (no MultiBar5/6/7, no MicroMenu, etc.), and a future patch
-- could rename more, so each frame is nil-checked before we touch it. This runs
-- once, guarded by addon.ActionBars.blizzardHidden, and only when the module is
-- actually enabled (see ActionBars.lua) — so a user who disables this addon
-- keeps Blizzard's own bars untouched.
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

-- Writing to a table key from insecure code can taint that key even when you're
-- just setting it to nil; this repeatedly no-ops on unrelated numeric keys until
-- the target key reports secure again. Same trick Bartender4 uses (Util:PurgeKey)
-- to clean up after clearing Edit Mode's isShownExternal tracking below.
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
    -- EditMode (1.15.9+) tracks its own frames via `.system` and overrides Hide
    -- with a version that talks to that system instead of just hiding the frame —
    -- calling it directly on a frame still marked as an active Edit Mode system
    -- both fails to actually hide the frame (it stays visible/selectable in
    -- Blizzard's Edit Mode) and risks tainting that call path. HideBase is the
    -- untainted original Hide when present (same guard BT4 uses); clearing
    -- isShownExternal first tells Edit Mode's own bookkeeping the frame is gone.
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

-- The set of bar frames whose native buttons we blank out. Kept as name strings
-- (looked up via _G) so a missing global on Classic is simply skipped rather
-- than erroring at file-parse time.
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
    -- Classic Era's Edit Mode moved Action Bar 1's actual system frame off
    -- MainMenuBar (now just a legacy shell with no EditMode integration) onto
    -- a separate MainActionBar frame (inherits EditModeActionBarTemplate, has
    -- its own .system/.Selection). Without hiding this too, Edit Mode still
    -- registers and highlights it as its own "Action Bar 1", alongside ours.
    hideBarFrame(_G.MainActionBar,      false)
    hideBarFrame(_G.MultiBarBottomLeft,  true)
    hideBarFrame(_G.MultiBarBottomRight, true)
    hideBarFrame(_G.MultiBarLeft,        true)
    hideBarFrame(_G.MultiBarRight,       true)
    -- Both possible globals are hidden regardless of which one the running
    -- client actually uses — hideBarFrame no-ops on nil, so this is safe either
    -- way and covers a rename between clients.
    hideBarFrame(_G.StanceBarFrame,      true)
    hideBarFrame(_G.ShapeshiftBarFrame,  true)
    hideBarFrame(_G.PetActionBarFrame,   true)
    hideBarFrame(_G.PetActionBar,        true)
    -- Same story as MainActionBar: BagsBar inherits EditModeBagsSystemTemplate,
    -- so it's a registered Edit Mode system in its own right. buildBagBar()
    -- (ActionBars.lua) already reparents its buttons onto our own bag bar, but
    -- the now-empty BagsBar frame itself still needs hiding or Edit Mode keeps
    -- showing it as its own separate bag bar.
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
