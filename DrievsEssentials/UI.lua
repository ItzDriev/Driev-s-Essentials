local addonName, addon = ...

local UI = {}
addon.UI = UI

-- Palette derived from user-specified hex: bg #24263A, accent #fb2c36.
-- All other shades are darker/lighter variants of the bg to keep hierarchy
-- without introducing unrelated hues.
local C = {
    panelBG       = { 0.141, 0.149, 0.227, 0.97 }, -- #24263A
    panelDark     = { 0.090, 0.098, 0.165, 1    },
    panelDeep     = { 0.055, 0.062, 0.115, 1    },
    red           = { 0.984, 0.173, 0.212, 1    }, -- #fb2c36
    tabIdle       = { 0.180, 0.190, 0.280, 1    },
    tabHover      = { 0.270, 0.290, 0.400, 1    },
    tabActive     = { 0.984, 0.173, 0.212, 1    },
    tabBorder     = { 0.300, 0.310, 0.420, 1    },
    tabActiveBdr  = { 1.000, 0.400, 0.450, 1    },
    checkBg       = { 0.080, 0.090, 0.150, 1    },
    checkBorder   = { 0.400, 0.420, 0.550, 1    },
    textWhite     = { 1.0, 1.0, 1.0 },
    textGrey      = { 0.75, 0.75, 0.80 },
    textDim       = { 0.50, 0.50, 0.55 },
    statusOn      = { 0.30, 0.85, 0.35, 1 },  -- enabled/on indicator dots
    statusOff     = { 0.45, 0.45, 0.50, 1 },  -- disabled/off indicator dots
}

local WHITE = "Interface\\Buttons\\WHITE8x8"

-- Insets matching edgeSize pull the background in from the frame's edge so
-- the border strip frames it cleanly instead of the border texture drawing
-- flush against (and slightly overlapping) a full-bleed background.
local function applyBackdrop(frame, edgeSize, bg, border)
    edgeSize = edgeSize or 1
    frame:SetBackdrop({
        bgFile   = WHITE,
        edgeFile = WHITE,
        edgeSize = edgeSize,
        insets   = { left = edgeSize, right = edgeSize, top = edgeSize, bottom = edgeSize },
    })
    frame:SetBackdropColor(unpack(bg))
    frame:SetBackdropBorderColor(unpack(border or { 0, 0, 0, 0 }))
end

-- Reusable tab button. OnClick is attached by the caller so the same factory
-- works for top-level and sub-tabs.
local function createTab(parent, label, width)
    local tab = CreateFrame("Button", nil, parent, "BackdropTemplate")
    tab:SetSize(width or 110, 24)
    applyBackdrop(tab, 1, C.tabIdle, C.tabBorder)

    local text = tab:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("CENTER")
    text:SetText(label)
    text:SetTextColor(unpack(C.textGrey))
    tab.text = text

    tab:SetScript("OnEnter", function(self)
        if not self.active then self:SetBackdropColor(unpack(C.tabHover)) end
    end)
    tab:SetScript("OnLeave", function(self)
        if not self.active then self:SetBackdropColor(unpack(C.tabIdle)) end
    end)
    return tab
end

-- Tall, full-width, left-aligned tab button for a vertical sidebar (the main
-- nav column, and the per-raid selector inside Particles → Raids). Caller
-- anchors LEFT/RIGHT to the containing column and TOP to the previous button;
-- OnClick is attached by the caller. Shares tab.text + backdrop so the same
-- activateTab() drives its active/idle look.
local function createSideTab(parent, label, height)
    local tab = CreateFrame("Button", nil, parent, "BackdropTemplate")
    tab:SetHeight(height or 28)
    applyBackdrop(tab, 1, C.tabIdle, C.tabBorder)

    local text = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    text:SetPoint("LEFT", 14, 0)
    text:SetText(label)
    text:SetTextColor(unpack(C.textGrey))
    tab.text = text

    tab:SetScript("OnEnter", function(self)
        if not self.active then self:SetBackdropColor(unpack(C.tabHover)) end
    end)
    tab:SetScript("OnLeave", function(self)
        if not self.active then self:SetBackdropColor(unpack(C.tabIdle)) end
    end)
    return tab
end

-- Standard flat action button: dark backdrop, centred white label, red hover
-- border. The caller anchors it (SetPoint) and wires OnClick; `.label` is
-- exposed for buttons that recolour or relabel it. `font` defaults to
-- GameFontNormal.
local function flatButton(parent, text, w, h, font)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(w or 80, h or 22)
    applyBackdrop(btn, 1, C.panelDark, C.tabBorder)
    local label = btn:CreateFontString(nil, "OVERLAY", font or "GameFontNormal")
    label:SetPoint("CENTER")
    label:SetText(text or "")
    label:SetTextColor(unpack(C.textWhite))
    btn.label = label
    btn:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(unpack(C.red)) end)
    btn:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(unpack(C.tabBorder)) end)
    return btn
end

-- A themed [-] [value] [+] stepper. Creates the two square buttons (with the
-- standard red hover border) and a centred value label between them, wired so
-- clicking adjusts opts.get()/opts.set() by opts.step (default 1), clamped to
-- [opts.min, opts.max], re-rendered through opts.format (default tostring), then
-- runs opts.onChange(v). Returns the minus button as the layout handle (the
-- caller SetPoints it), with `.value`/`.plus` exposed for anchoring a trailing
-- suffix and `.Refresh()` to re-read the stored value. opts.get must always
-- return a number (fall back to a default when the store isn't ready yet).
local function buildStepper(parent, opts)
    local step = opts.step or 1
    local fmt  = opts.format or tostring
    local gap  = opts.gap or 6

    local minus = CreateFrame("Button", nil, parent, "BackdropTemplate")
    minus:SetSize(22, 22)
    applyBackdrop(minus, 1, C.panelDark, C.tabBorder)
    local ml = minus:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ml:SetPoint("CENTER"); ml:SetText("-"); ml:SetTextColor(unpack(C.textWhite))

    local value = parent:CreateFontString(nil, "OVERLAY", opts.valueFont or "GameFontNormal")
    value:SetPoint("LEFT", minus, "RIGHT", gap, 0)
    value:SetWidth(opts.valueWidth or 24); value:SetJustifyH("CENTER")
    value:SetTextColor(unpack(opts.valueColor or C.textWhite))

    local plus = CreateFrame("Button", nil, parent, "BackdropTemplate")
    plus:SetSize(22, 22)
    plus:SetPoint("LEFT", value, "RIGHT", gap, 0)
    applyBackdrop(plus, 1, C.panelDark, C.tabBorder)
    local pl = plus:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pl:SetPoint("CENTER"); pl:SetText("+"); pl:SetTextColor(unpack(C.textWhite))

    local function refresh() value:SetText(fmt(opts.get())) end
    local function adjust(delta)
        local v = math.min(opts.max, math.max(opts.min, opts.get() + delta))
        v = math.floor(v * 1000 + 0.5) / 1000   -- kill float drift on fractional steps
        opts.set(v)
        refresh()
        if opts.onChange then opts.onChange(v) end
    end
    minus:SetScript("OnClick", function() adjust(-step) end)
    plus:SetScript("OnClick",  function() adjust(step) end)
    minus:SetScript("OnEnter", function() minus:SetBackdropBorderColor(unpack(C.red)) end)
    minus:SetScript("OnLeave", function() minus:SetBackdropBorderColor(unpack(C.tabBorder)) end)
    plus:SetScript("OnEnter",  function() plus:SetBackdropBorderColor(unpack(C.red)) end)
    plus:SetScript("OnLeave",  function() plus:SetBackdropBorderColor(unpack(C.tabBorder)) end)

    minus.plus, minus.value, minus.Refresh = plus, value, refresh
    refresh()
    return minus
end

-- Generic tab/panel switcher; usable for both the top-level tabs and the
-- in-Particles raid sub-tabs.
local function activateTab(tabs, panels, key)
    for k, tab in pairs(tabs) do
        local active = (k == key)
        tab.active = active
        if active then
            tab:SetBackdropColor(unpack(C.tabActive))
            tab:SetBackdropBorderColor(unpack(C.tabActiveBdr))
            tab.text:SetTextColor(unpack(C.textWhite))
        else
            tab:SetBackdropColor(unpack(C.tabIdle))
            tab:SetBackdropBorderColor(unpack(C.tabBorder))
            tab.text:SetTextColor(unpack(C.textGrey))
        end
    end
    for k, panel in pairs(panels) do
        panel:SetShown(k == key)
    end
end

local function selectTab(frame, key)
    frame.activeTab = key
    activateTab(frame.tabs, frame.panels, key)
end

local function selectSubTab(parent, key)
    parent.activeSubTab = key
    activateTab(parent.subTabs, parent.subPanels, key)
end

-- ── Scrollable panels ────────────────────────────────────────────────────────
-- Themed, draggable vertical scrollbar (track + thumb) for an existing
-- ScrollFrame, matching the style already used by the font-picker dropdown
-- and the profile export/import popup. `trackParent` is the frame the
-- track's right edge anchors to — normally the outer shell the ScrollFrame
-- fills (minus the width reserved for the track itself). Returns an
-- `update()` function; call it whenever the scroll child's content height
-- changes (resizing rows, showing/hiding optional widgets, etc.) to keep the
-- thumb's size/position in sync.
local SCROLLBAR_W = 10
-- Clearance to keep a scrollbar track clear of the main window's bottom-right
-- resize grip (see createMainFrame's `sizer`). Only the outer panels that
-- actually reach that corner opt in via attachScrollTrack's `bottomInset`;
-- nested scrollbars pass nothing and run the full height of their box.
local SCROLLBAR_BOTTOM_CLEARANCE = 16

local function attachScrollTrack(scroll, trackParent, bottomInset)
    local track = CreateFrame("Frame", nil, trackParent, "BackdropTemplate")
    track:SetWidth(SCROLLBAR_W)
    track:SetPoint("TOPRIGHT",    trackParent, "TOPRIGHT",    -1, -1)
    track:SetPoint("BOTTOMRIGHT", trackParent, "BOTTOMRIGHT", -1,  bottomInset or 1)
    applyBackdrop(track, 1, C.panelDeep, C.tabBorder)

    local thumb = CreateFrame("Button", nil, track, "BackdropTemplate")
    thumb:SetWidth(SCROLLBAR_W - 2)
    applyBackdrop(thumb, 1, C.tabIdle, C.tabBorder)
    thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 1, 0)

    -- Track is always visible (not conditionally hidden on maxScroll<=0) —
    -- GetVerticalScrollRange() isn't reliably accurate until the frame has
    -- actually been shown/laid out, so hiding based on it produced a track
    -- that silently never appeared until some other event forced a recompute.
    -- When there's nothing to scroll the thumb just fills the whole track.
    local function update()
        track:Show()
        local trackH = track:GetHeight()
        if trackH <= 0 then return end
        -- GetVerticalScrollRange() can return a stale/cached value until the
        -- ScrollFrame's scroll-child rect is explicitly recomputed — this is
        -- the real fix for the thumb reading wrong until the user scrolls
        -- once (which forces an internal refresh as a side effect).
        if scroll.UpdateScrollChildRect then scroll:UpdateScrollChildRect() end
        local maxScroll = scroll:GetVerticalScrollRange()
        if maxScroll <= 0 then
            if scroll:GetVerticalScroll() ~= 0 then scroll:SetVerticalScroll(0) end
            thumb:SetHeight(trackH)
            thumb:ClearAllPoints()
            thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 1, 0)
            return
        end
        local visibleH = scroll:GetHeight()
        local thumbH   = math.max(16, trackH * visibleH / (visibleH + maxScroll))
        local cur      = scroll:GetVerticalScroll()
        -- Shrinking the window (or its content) while scrolled near the
        -- bottom can leave the saved offset past the new, smaller range —
        -- without reclamping, frac exceeds 1 and the thumb is pushed past the
        -- end of the track (or off-screen entirely), flickering every time
        -- update() re-fires during the resize.
        if cur > maxScroll then
            cur = maxScroll
            scroll:SetVerticalScroll(cur)
        elseif cur < 0 then
            cur = 0
            scroll:SetVerticalScroll(cur)
        end
        local frac = cur / maxScroll
        thumb:SetHeight(thumbH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 1, -(frac * (trackH - thumbH)))
    end

    local isDragging, dragStartY, dragStartScroll = false, 0, 0
    thumb:EnableMouse(true)
    thumb:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then
            isDragging      = true
            dragStartY      = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
            dragStartScroll = scroll:GetVerticalScroll()
        end
    end)
    thumb:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then isDragging = false end
    end)
    thumb:SetScript("OnUpdate", function()
        if not isDragging then return end
        local curY      = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
        local delta      = dragStartY - curY
        local trackH     = track:GetHeight()
        local thumbH     = thumb:GetHeight()
        local maxScroll  = scroll:GetVerticalScrollRange()
        if trackH > thumbH and maxScroll > 0 then
            scroll:SetVerticalScroll(math.max(0, math.min(
                dragStartScroll + delta * maxScroll / (trackH - thumbH),
                maxScroll
            )))
            update()
        end
    end)
    thumb:SetScript("OnEnter", function(self) self:SetBackdropColor(unpack(C.tabHover)) end)
    thumb:SetScript("OnLeave", function(self) self:SetBackdropColor(unpack(C.tabIdle))  end)

    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(_, d)
        local maxScroll = scroll:GetVerticalScrollRange()
        scroll:SetVerticalScroll(math.max(0, math.min(scroll:GetVerticalScroll() - d * 30, maxScroll)))
        update()
    end)

    return track, update
end

-- Recursively finds the lowest (screen-space) bottom edge among a frame's
-- descendants — both child frames (GetChildren) and directly-drawn regions
-- like FontStrings/Textures (GetRegions), since e.g. a checkbox row's own
-- label is a region on the row, not on `inner`. Used to size a scroll child
-- to its ACTUAL content height rather than a guessed fixed value — a fixed
-- height taller than the real content makes GetVerticalScrollRange() always
-- report room to scroll, even on panels with nothing to scroll.
local function findLowestBottom(frame, bottom)
    for _, child in ipairs({ frame:GetChildren() }) do
        local cb = child:GetBottom()
        if cb and (not bottom or cb < bottom) then bottom = cb end
        -- Don't descend into a nested ScrollFrame: it clips and scrolls its own
        -- (possibly much taller) child, so only its own visible bottom edge
        -- should count toward the enclosing panel's height — otherwise the
        -- outer panel grows to fit the inner scroll's full content and you can
        -- scroll the outer panel down into empty space below it.
        if child:GetObjectType() ~= "ScrollFrame" then
            bottom = findLowestBottom(child, bottom)
        end
    end
    for _, region in ipairs({ frame:GetRegions() }) do
        if region.GetBottom then
            local rb = region:GetBottom()
            if rb and (not bottom or rb < bottom) then bottom = rb end
        end
    end
    return bottom
end

-- Resizes `inner` to fit its actual content (see findLowestBottom), with a
-- floor of the scroll frame's own visible height so a short panel never
-- becomes "scrollable" into empty space.
local function fitInnerHeight(inner, scroll)
    local top = inner:GetTop()
    if not top then return end
    local bottom = findLowestBottom(inner, nil)
    local visibleH = scroll:GetHeight() or 0
    local contentH = bottom and math.max(1, top - bottom + 20) or visibleH
    inner:SetHeight(math.max(contentH, visibleH))
end

-- Wraps a tab/sub-tab's content in a scrollable area with the themed
-- scrollbar above — for panels whose content can grow taller than the fixed
-- settings window. Returns (shell, inner): `shell` is what callers treat
-- exactly like the old flat panel (anchor/size it, SetShown it, hang an
-- OnShow script off it for refresh-on-tab-switch — activateTab only toggles
-- THIS frame, so its Show/Hide state — and therefore OnShow firing — behaves
-- identically to before); `inner` is what all of the panel's actual widgets
-- should be created on/anchored to, exactly as the old flat panel was.
local function makeScrollPanel(parent, innerHeight)
    local shell = CreateFrame("Frame", nil, parent)
    shell:SetAllPoints()
    shell:Hide()

    local scroll = CreateFrame("ScrollFrame", nil, shell)
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", -(SCROLLBAR_W + 6), 0)

    local inner = CreateFrame("Frame", nil, scroll)
    inner:SetHeight(innerHeight or 1600)
    scroll:SetScrollChild(inner)

    local _, update = attachScrollTrack(scroll, shell, SCROLLBAR_BOTTOM_CLEARANCE)

    -- fitInnerHeight resizes `inner`, which re-triggers inner's own
    -- OnSizeChanged below — that handler only calls update() (never
    -- fitInnerHeight again), so this can't recurse.
    local function refreshScroll()
        fitInnerHeight(inner, scroll)
        update()
    end

    scroll:SetScript("OnSizeChanged", function(self, w)
        inner:SetWidth(w)
        refreshScroll()
    end)
    inner:SetScript("OnSizeChanged", update)
    -- GetVerticalScrollRange() isn't reliably accurate (and content may not
    -- have its final size) until the frame is actually visible, so the very
    -- first pass (from the OnSizeChanged calls above, which can fire while
    -- still hidden during initial layout) can under-report it. HookScript
    -- (not SetScript) so this doesn't clobber the caller's own OnShow
    -- refresh, attached separately after this function returns. GetTop()/
    -- GetBottom() can ALSO still be stale on the very same frame a panel is
    -- first shown (only settling one frame later — this is why scrolling,
    -- which re-triggers the calc later, "fixed" it) so also defer a second
    -- pass via C_Timer.After(0, ...) to catch that case on first open.
    shell:HookScript("OnShow", function()
        refreshScroll()
        C_Timer.After(0, refreshScroll)
    end)

    -- Third return value lets a caller re-fit the scroll child after adding
    -- or removing rows while the panel is already shown (rebuilding a list
    -- doesn't fire OnShow/OnSizeChanged on its own).
    return shell, inner, refreshScroll
end

-- Custom dark/red themed checkbox. The whole row is clickable.
local function createCheckbox(parent, label, width)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(width or 200, 20)

    local box = CreateFrame("Frame", nil, row, "BackdropTemplate")
    box:SetSize(14, 14)
    box:SetPoint("LEFT", 0, 0)
    applyBackdrop(box, 1, C.checkBg, C.checkBorder)

    local fill = box:CreateTexture(nil, "ARTWORK")
    fill:SetTexture(WHITE)
    fill:SetPoint("TOPLEFT", 2, -2)
    fill:SetPoint("BOTTOMRIGHT", -2, 2)
    fill:SetVertexColor(unpack(C.red))
    fill:Hide()

    local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("LEFT", box, "RIGHT", 6, 0)
    text:SetText(label)
    text:SetTextColor(unpack(C.textWhite))

    row.box, row.fill, row.text = box, fill, text
    row.checked = false

    function row:SetChecked(v)
        self.checked = v and true or false
        if self.checked then fill:Show() else fill:Hide() end
    end
    function row:GetChecked() return self.checked end

    row:SetScript("OnEnter", function() box:SetBackdropBorderColor(unpack(C.red)) end)
    row:SetScript("OnLeave", function() box:SetBackdropBorderColor(unpack(C.checkBorder)) end)
    row:SetScript("OnClick", function(self)
        self:SetChecked(not self.checked)
        if self.OnChange then self:OnChange(self.checked) end
    end)
    return row
end

-- Compact themed dropdown. options = array of { value, label }. The pop-out
-- option list is parented to UIParent (so the settings scroll-frame can't clip
-- it) at DIALOG strata with a full-screen catcher behind it to close on an
-- outside click, and it also closes if the dropdown itself is hidden (e.g. the
-- settings window closes). Exposes :Refresh() to re-read the current value.
local function createDropdown(parent, width, options, getVal, setVal, onSelect)
    local dd = CreateFrame("Button", nil, parent, "BackdropTemplate")
    dd:SetSize(width, 22)
    applyBackdrop(dd, 1, C.panelDark, C.tabBorder)

    local text = dd:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", 8, 0)
    text:SetTextColor(unpack(C.textWhite))

    local arrow = dd:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
    arrow:SetSize(16, 16)
    arrow:SetPoint("RIGHT", -4, -1)

    local catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("DIALOG")
    catcher:Hide()

    local menu = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    menu:SetFrameStrata("DIALOG")
    menu:SetFrameLevel(catcher:GetFrameLevel() + 10)
    menu:SetPoint("TOPLEFT",  dd, "BOTTOMLEFT",  0, -2)
    menu:SetPoint("TOPRIGHT", dd, "BOTTOMRIGHT", 0, -2)
    menu:SetHeight(#options * 22 + 2)
    applyBackdrop(menu, 1, C.panelBG, C.tabBorder)
    menu:Hide()

    local function labelFor(val)
        for _, o in ipairs(options) do if o.value == val then return o.label end end
        return options[1] and options[1].label or ""
    end
    local function refresh() text:SetText(labelFor(getVal())) end
    local function close() menu:Hide(); catcher:Hide() end

    for i, o in ipairs(options) do
        local item = CreateFrame("Button", nil, menu, "BackdropTemplate")
        item:SetPoint("TOPLEFT", menu, "TOPLEFT", 1, -1 - (i - 1) * 22)
        item:SetPoint("RIGHT",   menu, "RIGHT",  -1, 0)
        item:SetHeight(22)
        applyBackdrop(item, 1, C.panelDark, { 0, 0, 0, 0 })
        local il = item:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        il:SetPoint("LEFT", 8, 0); il:SetText(o.label); il:SetTextColor(unpack(C.textWhite))
        item:SetScript("OnEnter", function() item:SetBackdropColor(unpack(C.tabHover)) end)
        item:SetScript("OnLeave", function() item:SetBackdropColor(unpack(C.panelDark)) end)
        item:SetScript("OnClick", function()
            setVal(o.value); refresh(); close()
            if onSelect then onSelect(o.value) end
        end)
    end

    dd:SetScript("OnClick", function()
        if menu:IsShown() then close() else menu:Show(); catcher:Show() end
    end)
    dd:SetScript("OnEnter", function() dd:SetBackdropBorderColor(unpack(C.red)) end)
    dd:SetScript("OnLeave", function() dd:SetBackdropBorderColor(unpack(C.tabBorder)) end)
    dd:SetScript("OnHide", close)
    catcher:SetScript("OnClick", close)

    dd.Refresh = refresh
    refresh()
    return dd
end


local function raidData()
    addon.db.settings.raid = addon.db.settings.raid or {}
    return addon.db.settings.raid
end

local function buildRaidSettingsPanel(parent)
    local shell, panel = makeScrollPanel(parent)

    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 14, -14)
    header:SetText("Raid Settings")
    header:SetTextColor(unpack(C.red))

    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    desc:SetText("Applied automatically when entering a raid instance and reverted on leaving.")
    desc:SetTextColor(unpack(C.textGrey))

    local enableCheck = createCheckbox(panel, "Enable Raid Settings", 260)
    enableCheck:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -14)
    enableCheck.OnChange = function(_, checked)
        raidData().enabled = checked
        if addon.Raid then addon.Raid.refresh() end
    end

    local namesCheck = createCheckbox(panel, "Disable Names in Raid", 260)
    namesCheck:SetPoint("TOPLEFT", enableCheck, "BOTTOMLEFT", 0, -18)
    namesCheck.OnChange = function(_, checked)
        raidData().disableNames = checked
        if addon.Raid then addon.Raid.refresh() end
    end

    local namesDesc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    namesDesc:SetPoint("TOPLEFT", namesCheck, "BOTTOMLEFT", 20, -2)
    namesDesc:SetText("Hides friendly player, pet, guardian, and totem names.")
    namesDesc:SetTextColor(unpack(C.textDim))

    local bubblesCheck = createCheckbox(panel, "Disable Chat Bubbles in Raid", 260)
    bubblesCheck:SetPoint("TOPLEFT", namesDesc, "BOTTOMLEFT", -20, -14)
    bubblesCheck.OnChange = function(_, checked)
        raidData().disableChatBubbles = checked
        if addon.Raid then addon.Raid.refresh() end
    end

    local debugLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    debugLabel:SetPoint("TOPLEFT", bubblesCheck, "BOTTOMLEFT", 0, -22)
    debugLabel:SetText("Debug")
    debugLabel:SetTextColor(unpack(C.textDim))

    local debugCheck = createCheckbox(panel, "Treat Stockades as Raid", 260)
    debugCheck:SetPoint("TOPLEFT", debugLabel, "BOTTOMLEFT", 0, -6)
    debugCheck.OnChange = function(_, checked)
        raidData().debug = checked
        if addon.Raid then addon.Raid.refresh() end
    end

    local debugDesc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    debugDesc:SetPoint("TOPLEFT", debugCheck, "BOTTOMLEFT", 20, -2)
    debugDesc:SetText("Use the Stockades to test raid settings without entering a real raid.")
    debugDesc:SetTextColor(unpack(C.textDim))

    local function refreshPanel()
        local d = raidData()
        enableCheck:SetChecked(d.enabled or false)
        namesCheck:SetChecked(d.disableNames or false)
        bubblesCheck:SetChecked(d.disableChatBubbles or false)
        debugCheck:SetChecked(d.debug or false)
    end
    shell:SetScript("OnShow", refreshPanel)

    return shell
end

local function raidFramesData()
    addon.db.settings.raidFrames = addon.db.settings.raidFrames or {
        enabled = false,
        scale   = 1,
    }
    return addon.db.settings.raidFrames
end

local function buildRaidFramesPanel(parent)
    local shell, panel = makeScrollPanel(parent)

    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 14, -14)
    header:SetText("Raid Frame Manager")
    header:SetTextColor(unpack(C.red))

    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    desc:SetText("Reposition and resize the default raid frames. Drag the box to move it, drag its corner to resize.")
    desc:SetTextColor(unpack(C.textGrey))

    local enableCB = createCheckbox(panel, "Enable Raid Frame Manager", 280)
    enableCB:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -14)
    enableCB.OnChange = function(_, checked)
        raidFramesData().enabled = checked
        if addon.RaidFrames then addon.RaidFrames.applyAll() end
    end

    local moveBtn = flatButton(panel, "Move / Resize", 140, 22)
    moveBtn:SetPoint("TOPLEFT", enableCB, "BOTTOMLEFT", 0, -14)
    moveBtn:SetScript("OnClick", function() UI.EnterMoveMode({ addon.RaidFrames }) end)

    local scaleText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    scaleText:SetPoint("LEFT", moveBtn, "RIGHT", 14, 0)
    scaleText:SetText("Scale:")
    scaleText:SetTextColor(unpack(C.textWhite))

    local scaleBoxWrap = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    scaleBoxWrap:SetSize(50, 22)
    scaleBoxWrap:SetPoint("LEFT", scaleText, "RIGHT", 8, 0)
    applyBackdrop(scaleBoxWrap, 1, C.panelDark, C.tabBorder)

    local scaleBox = CreateFrame("EditBox", nil, scaleBoxWrap)
    scaleBox:SetSize(40, 18)
    scaleBox:SetPoint("CENTER")
    scaleBox:SetAutoFocus(false)
    scaleBox:SetMaxLetters(6)
    scaleBox:SetJustifyH("CENTER")
    scaleBox:SetFontObject("GameFontNormal")
    scaleBox:SetTextColor(unpack(C.textWhite))

    local scalePctLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    scalePctLabel:SetPoint("LEFT", scaleBoxWrap, "RIGHT", 4, 0)
    scalePctLabel:SetText("%")
    scalePctLabel:SetTextColor(unpack(C.textWhite))

    local minPct = addon.RaidFrames and math.floor(addon.RaidFrames.minScale * 100) or 50
    local maxPct = addon.RaidFrames and math.floor(addon.RaidFrames.maxScale * 100) or 200

    local scaleRangeNote = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    scaleRangeNote:SetPoint("LEFT", scalePctLabel, "RIGHT", 8, 0)
    scaleRangeNote:SetText(string.format("(%d - %d)", minPct, maxPct))
    scaleRangeNote:SetTextColor(unpack(C.textDim))

    local function displayScale()
        local d = raidFramesData()
        scaleBox:SetText(tostring(math.floor((d.scale or 1) * 100 + 0.5)))
    end

    local function commitScale()
        local num = tonumber(scaleBox:GetText())
        if num and addon.RaidFrames then
            local applied = addon.RaidFrames.setScale(num / 100)
            scaleBox:SetText(tostring(math.floor(applied * 100 + 0.5)))
        else
            displayScale()
        end
        scaleBox:ClearFocus()
    end

    scaleBoxWrap:SetScript("OnEnter", function() scaleBoxWrap:SetBackdropBorderColor(unpack(C.red)) end)
    scaleBoxWrap:SetScript("OnLeave", function() scaleBoxWrap:SetBackdropBorderColor(unpack(C.tabBorder)) end)
    scaleBox:SetScript("OnEnterPressed", commitScale)
    scaleBox:SetScript("OnEditFocusLost", commitScale)
    scaleBox:SetScript("OnEscapePressed", function()
        displayScale()
        scaleBox:ClearFocus()
    end)

    local function refreshPanel()
        local d = raidFramesData()
        enableCB:SetChecked(d.enabled or false)
        if not scaleBox:HasFocus() then
            displayScale()
        end
    end

    shell:SetScript("OnShow", refreshPanel)

    return shell
end

-- Wraps the Raid settings and Raid Frames panels under one top-level "Raid" tab
-- with its own sub-tab bar (General / Raid Frames), mirroring the Particles and
-- Trinkets tabs' sub-tab layout.
local function buildRaidTabPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()
    panel:Hide()

    local subBar = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    subBar:SetHeight(26)
    subBar:SetPoint("TOPLEFT", 4, -4)
    subBar:SetPoint("TOPRIGHT", -4, -4)
    applyBackdrop(subBar, 1, C.panelDark)

    local subContent = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    subContent:SetPoint("TOPLEFT", subBar, "BOTTOMLEFT", 0, -2)
    subContent:SetPoint("BOTTOMRIGHT", -4, 4)
    applyBackdrop(subContent, 1, C.panelDeep)

    panel.subTabs   = {}
    panel.subPanels = {}

    local generalTab = createTab(subBar, "General", 80)
    generalTab:SetHeight(22)
    generalTab:SetPoint("LEFT", 4, 0)
    generalTab:SetScript("OnClick", function() selectSubTab(panel, "general") end)
    panel.subTabs["general"]   = generalTab
    panel.subPanels["general"] = buildRaidSettingsPanel(subContent)

    local framesTab = createTab(subBar, "Raid Frames", 110)
    framesTab:SetHeight(22)
    framesTab:SetPoint("LEFT", generalTab, "RIGHT", 4, 0)
    framesTab:SetScript("OnClick", function() selectSubTab(panel, "raidframes") end)
    panel.subTabs["raidframes"]   = framesTab
    panel.subPanels["raidframes"] = buildRaidFramesPanel(subContent)

    selectSubTab(panel, "general")
    return panel
end

-- Scrollable dropdown that anchors cleanly beneath (or above) its button.
-- getItems() is called once on first open; onChange(name) fires on selection.
local function createScrollDropdown(parent, width, getItems, onChange)
    local ITEM_H    = 20
    local MAX_VIS   = 8
    local SB_W      = 10          -- scrollbar track width
    local W         = width or 160
    local CONTENT_W = W - SB_W - 3  -- scroll frame / row width

    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(W, 22)
    applyBackdrop(btn, 1, C.panelDark, C.tabBorder)

    local btnText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    btnText:SetPoint("LEFT", 6, 0)
    btnText:SetPoint("RIGHT", -18, 0)
    btnText:SetJustifyH("LEFT")
    btnText:SetTextColor(unpack(C.textWhite))

    local arrowText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    arrowText:SetPoint("RIGHT", -5, 0)
    arrowText:SetText("v")
    arrowText:SetTextColor(unpack(C.textDim))

    btn._value = nil
    btn._rows  = {}
    btn._count = 0

    -- Popup parented to UIParent so it is never clipped by the settings frame.
    local popup = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    popup:SetWidth(W)
    popup:SetFrameStrata("TOOLTIP")
    applyBackdrop(popup, 1, C.panelDark, C.tabBorder)
    popup:Hide()

    local sf = CreateFrame("ScrollFrame", nil, popup)
    sf:SetPoint("TOPLEFT", popup, "TOPLEFT", 1, -1)
    sf:SetWidth(CONTENT_W)

    local sc = CreateFrame("Frame", nil, sf)
    sc:SetWidth(CONTENT_W)
    sc:SetHeight(1)
    sf:SetScrollChild(sc)

    -- Scrollbar track — hidden when all items fit without scrolling.
    local track = CreateFrame("Frame", nil, popup, "BackdropTemplate")
    track:SetWidth(SB_W)
    track:SetPoint("TOPRIGHT",    popup, "TOPRIGHT",    -1, -1)
    track:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -1,  1)
    applyBackdrop(track, 1, C.panelDeep, C.tabBorder)
    track:Hide()

    -- Scrollbar thumb (draggable).
    local thumb = CreateFrame("Button", nil, track, "BackdropTemplate")
    thumb:SetWidth(SB_W - 2)
    applyBackdrop(thumb, 1, C.tabIdle, C.tabBorder)
    thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 1, 0)  -- placeholder; overwritten by updateThumb

    local function updateThumb()
        local n = btn._count
        if n <= MAX_VIS then track:Hide(); return end
        track:Show()
        local trackH = track:GetHeight()
        if trackH <= 0 then return end
        local thumbH    = math.max(16, trackH * MAX_VIS / n)
        local maxScroll = (n - MAX_VIS) * ITEM_H
        local cur       = sf:GetVerticalScroll()
        local frac      = maxScroll > 0 and (cur / maxScroll) or 0
        thumb:SetHeight(thumbH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 1, -(frac * (trackH - thumbH)))
    end

    -- Thumb drag logic.
    local isDragging     = false
    local dragStartY     = 0
    local dragStartScroll = 0

    thumb:EnableMouse(true)
    thumb:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then
            isDragging    = true
            dragStartY    = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
            dragStartScroll = sf:GetVerticalScroll()
        end
    end)
    thumb:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then isDragging = false end
    end)
    thumb:SetScript("OnUpdate", function()
        if not isDragging then return end
        local curY      = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
        local delta     = dragStartY - curY
        local trackH    = track:GetHeight()
        local thumbH    = thumb:GetHeight()
        local maxScroll = math.max(0, (btn._count - MAX_VIS) * ITEM_H)
        if trackH > thumbH then
            sf:SetVerticalScroll(math.max(0, math.min(
                dragStartScroll + delta * maxScroll / (trackH - thumbH),
                maxScroll
            )))
            updateThumb()
        end
    end)
    thumb:SetScript("OnEnter", function(self) self:SetBackdropColor(unpack(C.tabHover)) end)
    thumb:SetScript("OnLeave", function(self) self:SetBackdropColor(unpack(C.tabIdle))  end)

    popup:EnableMouseWheel(true)
    popup:SetScript("OnMouseWheel", function(_, d)
        sf:SetVerticalScroll(math.max(0, sf:GetVerticalScroll() - d * ITEM_H * 2))
        updateThumb()
    end)

    -- Full-screen catcher closes popup when clicking outside.
    local catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints()
    catcher:SetFrameStrata("FULLSCREEN_DIALOG")
    catcher:Hide()

    local function close()
        popup:Hide()
        catcher:Hide()
    end
    catcher:SetScript("OnClick", close)

    local function refreshColors()
        for _, row in ipairs(btn._rows) do
            row.lbl:SetTextColor(unpack(
                row._name == btn._value and C.red or C.textGrey
            ))
        end
    end

    -- (Re)populates the row pool from getItems() every time the popup opens, so
    -- the list stays current when its source changes (e.g. profiles being added
    -- or removed). Rows are pooled and reused; any surplus is hidden. btn._count
    -- is the number of live items (the pool may be larger).
    local function populate()
        local items = getItems()
        for i, name in ipairs(items) do
            local row = btn._rows[i]
            if not row then
                row = CreateFrame("Button", nil, sc)
                row:SetSize(CONTENT_W, ITEM_H)
                row:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -(i - 1) * ITEM_H)

                local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                lbl:SetPoint("LEFT", 4, 0)
                lbl:SetPoint("RIGHT", -4, 0)
                lbl:SetJustifyH("LEFT")
                row.lbl = lbl

                row:SetScript("OnEnter", function(self)
                    self.lbl:SetTextColor(unpack(C.textWhite))
                end)
                row:SetScript("OnLeave", function(self)
                    self.lbl:SetTextColor(unpack(
                        self._name == btn._value and C.red or C.textGrey
                    ))
                end)
                row:SetScript("OnClick", function(self)
                    btn._value = self._name
                    btnText:SetText(self._name)
                    refreshColors()
                    close()
                    if onChange then onChange(self._name) end
                end)

                btn._rows[i] = row
            end
            row._name = name
            row.lbl:SetText(name)
            row.lbl:SetTextColor(unpack(name == btn._value and C.red or C.textGrey))
            row:Show()
        end
        for i = #items + 1, #btn._rows do btn._rows[i]:Hide() end
        btn._count = #items
        sc:SetHeight(math.max(#items * ITEM_H, 1))
    end

    btn:SetScript("OnClick", function()
        if popup:IsShown() then close(); return end

        populate()

        local visH = math.min(btn._count, MAX_VIS) * ITEM_H
        popup:SetHeight(visH + 2)
        sf:SetHeight(visH)

        local left   = btn:GetLeft()   or 0
        local bottom = btn:GetBottom() or 0
        local top_   = btn:GetTop()    or 0
        popup:ClearAllPoints()
        if bottom - (visH + 2) < 0 then
            popup:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left, top_)
        else
            popup:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, bottom)
        end

        popup:Show()
        catcher:Show()
        updateThumb()

        -- Scroll so the selected item is centred in the visible window.
        if btn._value then
            for i = 1, btn._count do
                if btn._rows[i]._name == btn._value then
                    local maxScroll = math.max(0, (btn._count - MAX_VIS) * ITEM_H)
                    local target    = math.max(0, (i - 1) * ITEM_H - math.floor(MAX_VIS / 2) * ITEM_H)
                    sf:SetVerticalScroll(math.min(target, maxScroll))
                    updateThumb()
                    break
                end
            end
        end
    end)

    btn:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(unpack(C.red)) end)
    btn:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(unpack(C.tabBorder)) end)

    function btn:setValue(v)
        self._value = v
        btnText:SetText(v or "")
        refreshColors()
    end

    return btn
end

local function buildGeneralTabPanel(parent)
    local shell, panel = makeScrollPanel(parent)

    local function getTTKData()
        addon.db.settings.ttk = addon.db.settings.ttk or {
            enabled  = false,
            bossOnly = false,
            fontSize = 24,
            fontName = "Friz Quadrata TT",
        }
        return addon.db.settings.ttk
    end

    local function getLSM()
        return LibStub and LibStub("LibSharedMedia-3.0", true)
    end

    local function getFontList()
        local LSM = getLSM()
        return (LSM and LSM:List("font")) or { "Friz Quadrata TT" }
    end

    -- ── Debug section ──────────────────────────────────────────────────────
    local function getDebugData()
        addon.db.settings.particles       = addon.db.settings.particles or {}
        addon.db.settings.particles.debug = addon.db.settings.particles.debug or { enabled = false }
        return addon.db.settings.particles.debug
    end

    local debugHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    debugHeader:SetPoint("TOPLEFT", 14, -14)
    debugHeader:SetText("Debug")
    debugHeader:SetTextColor(unpack(C.red))

    local debugCB = createCheckbox(panel, "Show encounter messages in chat", 280)
    debugCB:SetPoint("TOPLEFT", debugHeader, "BOTTOMLEFT", 0, -10)
    debugCB.OnChange = function(_, checked)
        getDebugData().enabled = checked
    end

    -- ── Minimap section ───────────────────────────────────────────────────────
    local minimapHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    minimapHeader:SetPoint("TOPLEFT", debugCB, "BOTTOMLEFT", 0, -24)
    minimapHeader:SetText("Minimap")
    minimapHeader:SetTextColor(unpack(C.red))

    local minimapHideCB = createCheckbox(panel, "Disable minimap button", 260)
    minimapHideCB:SetPoint("TOPLEFT", minimapHeader, "BOTTOMLEFT", 0, -10)
    minimapHideCB.OnChange = function(_, checked)
        addon.db.minimap.hide = checked
        if addon.minimapButton then
            if checked then addon.minimapButton:Hide()
            else             addon.minimapButton:Show() end
        end
    end

    -- ── Time To Kill section ───────────────────────────────────────────────
    local ttkHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    ttkHeader:SetPoint("TOPLEFT", minimapHideCB, "BOTTOMLEFT", 0, -24)
    ttkHeader:SetText("Time To Kill")
    ttkHeader:SetTextColor(unpack(C.red))

    -- Enable checkbox
    local enableCB = createCheckbox(panel, "Enable Time To Kill", 260)
    enableCB:SetPoint("TOPLEFT", ttkHeader, "BOTTOMLEFT", 0, -14)
    enableCB.OnChange = function(_, checked)
        getTTKData().enabled = checked
        if addon.TTK then addon.TTK.applyVisibility() end
    end

    -- Move button
    local moveBtn = flatButton(panel, "Move", 80, 22)
    moveBtn:SetPoint("TOPLEFT", enableCB, "BOTTOMLEFT", 0, -10)
    moveBtn:SetScript("OnClick", function() UI.EnterMoveMode({ addon.TTK }) end)

    -- Boss-only checkbox
    local bossOnlyCB = createCheckbox(panel, "Only show during boss fights", 260)
    bossOnlyCB:SetPoint("TOPLEFT", moveBtn, "BOTTOMLEFT", 0, -10)
    bossOnlyCB.OnChange = function(_, checked)
        getTTKData().bossOnly = checked
    end

    -- Font row
    local fontLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fontLabel:SetPoint("TOPLEFT", bossOnlyCB, "BOTTOMLEFT", 0, -18)
    fontLabel:SetText("Font:")
    fontLabel:SetTextColor(unpack(C.textWhite))

    local fontDropdown = createScrollDropdown(panel, 160, getFontList, function(name)
        getTTKData().fontName = name
        if addon.TTK then addon.TTK.applyFont() end
    end)
    fontDropdown:SetPoint("LEFT", fontLabel, "RIGHT", 10, 0)

    -- Size row
    local sizeLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sizeLabel:SetPoint("TOPLEFT", fontLabel, "BOTTOMLEFT", 0, -14)
    sizeLabel:SetText("Size:")
    sizeLabel:SetTextColor(unpack(C.textWhite))

    local sizeStepper = buildStepper(panel, {
        min = 10, max = 60, valueFont = "GameFontNormalLarge", valueColor = C.red,
        get = function() return (getTTKData().fontSize) or 24 end,
        set = function(v) getTTKData().fontSize = v end,
        onChange = function() if addon.TTK then addon.TTK.applyFont() end end,
    })
    sizeStepper:SetPoint("LEFT", sizeLabel, "RIGHT", 10, 0)

    -- A clickable colour swatch opening WoW's native picker. RGB only — opacity
    -- is a separate stepper here, so the two controls can't fight over alpha.
    local function ttSwatch(parent, getRGB, setRGB, onChange)
        local sw = CreateFrame("Button", nil, parent, "BackdropTemplate")
        sw:SetSize(20, 20)
        applyBackdrop(sw, 1, { 1, 1, 1 }, C.tabBorder)

        local function paint()
            local r, g, b = getRGB()
            sw:SetBackdropColor(r or 1, g or 1, b or 1, 1)
        end

        sw:SetScript("OnClick", function()
            local r, g, b = getRGB()
            local function apply()
                local nr, ng, nb = ColorPickerFrame:GetColorRGB()
                setRGB(nr, ng, nb); paint(); if onChange then onChange() end
            end
            local function cancel()
                setRGB(r, g, b); paint(); if onChange then onChange() end
            end
            if ColorPickerFrame.SetupColorPickerAndShow then
                ColorPickerFrame:SetupColorPickerAndShow({
                    r = r, g = g, b = b, hasOpacity = false,
                    swatchFunc = apply, cancelFunc = cancel,
                })
            else
                ColorPickerFrame.hasOpacity = false
                ColorPickerFrame.func       = apply
                ColorPickerFrame.cancelFunc = cancel
                ColorPickerFrame:SetColorRGB(r, g, b)
                ColorPickerFrame:Hide() -- force OnShow to refire with these values
                ColorPickerFrame:Show()
            end
        end)

        sw.Refresh = paint
        paint()
        return sw
    end

    -- ── Tooltip section ──────────────────────────────────────────────────────
    local function getTooltipData()
        addon.db.settings.tooltip = addon.db.settings.tooltip or {}
        return addon.db.settings.tooltip
    end

    local ttHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    ttHeader:SetPoint("TOPLEFT", sizeStepper, "BOTTOMLEFT", -10, -24)
    ttHeader:SetText("Tooltip")
    ttHeader:SetTextColor(unpack(C.red))

    local ttDesc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ttDesc:SetPoint("TOPLEFT", ttHeader, "BOTTOMLEFT", 0, -4)
    ttDesc:SetWidth(420); ttDesc:SetJustifyH("LEFT")
    ttDesc:SetText("Restyles the game tooltip (item/unit/etc.) to match this addon's theme.")
    ttDesc:SetTextColor(unpack(C.textGrey))

    local ttEnableCB = createCheckbox(panel, "Enable custom tooltip skin", 300)
    ttEnableCB:SetPoint("TOPLEFT", ttDesc, "BOTTOMLEFT", 0, -10)
    ttEnableCB.OnChange = function(_, checked)
        getTooltipData().enabled = checked
        if addon.Tooltip then addon.Tooltip.refresh() end
    end

    local ttColorCB = createCheckbox(panel, "Color border by class (players) / reaction (NPCs)", 340)
    ttColorCB:SetPoint("TOPLEFT", ttEnableCB, "BOTTOMLEFT", 0, -6)
    ttColorCB.OnChange = function(_, checked)
        getTooltipData().colorByUnit = checked
    end

    local ttHealthCB = createCheckbox(panel, "Show health value on unit tooltips", 340)
    ttHealthCB:SetPoint("TOPLEFT", ttColorCB, "BOTTOMLEFT", 0, -6)
    ttHealthCB.OnChange = function(_, checked)
        getTooltipData().showHealth = checked
    end

    local ttRealmCB = createCheckbox(panel, "Hide realm name", 300)
    ttRealmCB:SetPoint("TOPLEFT", ttHealthCB, "BOTTOMLEFT", 0, -6)
    ttRealmCB.OnChange = function(_, checked)
        getTooltipData().hideRealm = checked
    end

    local ttHealthBorderCB = createCheckbox(panel, "Class-color the health bar outline", 340)
    ttHealthBorderCB:SetPoint("TOPLEFT", ttRealmCB, "BOTTOMLEFT", 0, -6)
    ttHealthBorderCB.OnChange = function(_, checked)
        getTooltipData().healthBorder = checked
    end

    local ttCursorCB = createCheckbox(panel, "Anchor tooltip to cursor", 300)
    ttCursorCB:SetPoint("TOPLEFT", ttHealthBorderCB, "BOTTOMLEFT", 0, -6)
    ttCursorCB.OnChange = function(_, checked)
        getTooltipData().anchorCursor = checked
    end

    local ttAnchorCB = createCheckbox(panel, "Use a movable tooltip anchor", 340)
    ttAnchorCB:SetPoint("TOPLEFT", ttCursorCB, "BOTTOMLEFT", 0, -6)
    ttAnchorCB.OnChange = function(_, checked)
        getTooltipData().useAnchor = checked
    end

    local ttAnchorHint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ttAnchorHint:SetPoint("TOPLEFT", ttAnchorCB, "BOTTOMLEFT", 20, -4)
    ttAnchorHint:SetWidth(420); ttAnchorHint:SetJustifyH("LEFT")
    ttAnchorHint:SetText("Parks the tooltip on a handle you can drag in Edit Mode. Cursor anchoring wins if both are ticked.")
    ttAnchorHint:SetTextColor(unpack(C.textDim))

    local function ttChanged()
        if addon.Tooltip then addon.Tooltip.refresh() end
    end

    -- One colour serves two roles: it is the fallback whenever there is no
    -- class/reaction tint to apply, and it is what the override below uses when
    -- switched on. Two separate colours could disagree for no good reason.
    local ttBorderRow = CreateFrame("Frame", nil, panel)
    ttBorderRow:SetSize(320, 22)
    ttBorderRow:SetPoint("TOPLEFT", ttAnchorHint, "BOTTOMLEFT", -20, -12)
    local ttBorderLbl = ttBorderRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ttBorderLbl:SetPoint("LEFT", 0, 0); ttBorderLbl:SetWidth(150); ttBorderLbl:SetJustifyH("LEFT")
    ttBorderLbl:SetText("Default border color:"); ttBorderLbl:SetTextColor(unpack(C.textGrey))
    local ttBorderSwatch = ttSwatch(ttBorderRow,
        function()
            local c = getTooltipData().borderColor or { 0.30, 0.31, 0.42 }
            return c[1], c[2], c[3]
        end,
        function(r, g, b) getTooltipData().borderColor = { r, g, b } end, ttChanged)
    ttBorderSwatch:SetPoint("LEFT", ttBorderLbl, "RIGHT", 6, 0)

    local ttBorderHint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ttBorderHint:SetPoint("TOPLEFT", ttBorderRow, "BOTTOMLEFT", 0, -4)
    ttBorderHint:SetWidth(420); ttBorderHint:SetJustifyH("LEFT")
    ttBorderHint:SetText("Used whenever there is no class or reaction color to apply — items, spells, objects and the like.")
    ttBorderHint:SetTextColor(unpack(C.textDim))

    local ttCustomBorderCB = createCheckbox(panel, "Use it for units too, ignoring class colors", 360)
    ttCustomBorderCB:SetPoint("TOPLEFT", ttBorderHint, "BOTTOMLEFT", 0, -10)
    ttCustomBorderCB.OnChange = function(_, checked)
        getTooltipData().customBorder = checked
        ttChanged()
    end

    local ttBgRow = CreateFrame("Frame", nil, panel)
    ttBgRow:SetSize(320, 22)
    ttBgRow:SetPoint("TOPLEFT", ttCustomBorderCB, "BOTTOMLEFT", 0, -10)
    local ttBgLbl = ttBgRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ttBgLbl:SetPoint("LEFT", 0, 0); ttBgLbl:SetWidth(150); ttBgLbl:SetJustifyH("LEFT")
    ttBgLbl:SetText("Background color:"); ttBgLbl:SetTextColor(unpack(C.textGrey))
    local ttBgSwatch = ttSwatch(ttBgRow,
        function()
            local c = getTooltipData().bgColor or { 0.090, 0.098, 0.165 }
            return c[1], c[2], c[3]
        end,
        function(r, g, b) getTooltipData().bgColor = { r, g, b } end, ttChanged)
    ttBgSwatch:SetPoint("LEFT", ttBgLbl, "RIGHT", 6, 0)

    local ttOpRow = CreateFrame("Frame", nil, panel)
    ttOpRow:SetSize(320, 22)
    ttOpRow:SetPoint("TOPLEFT", ttBgRow, "BOTTOMLEFT", 0, -8)
    local ttOpLbl = ttOpRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ttOpLbl:SetPoint("LEFT", 0, 0); ttOpLbl:SetWidth(150); ttOpLbl:SetJustifyH("LEFT")
    ttOpLbl:SetText("Background opacity:"); ttOpLbl:SetTextColor(unpack(C.textGrey))
    local ttOpStepper = buildStepper(ttOpRow, {
        min = 0, max = 100, step = 5,
        get = function() return getTooltipData().bgOpacity or 100 end,
        set = function(v) getTooltipData().bgOpacity = v end,
        onChange = ttChanged,
    })
    ttOpStepper:SetPoint("LEFT", ttOpLbl, "RIGHT", 6, 0)
    local ttOpSuffix = ttOpRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ttOpSuffix:SetPoint("LEFT", ttOpStepper.plus, "RIGHT", 6, 0)
    ttOpSuffix:SetText("%"); ttOpSuffix:SetTextColor(unpack(C.textDim))

    local function refreshPanel()
        local d  = getTTKData()
        local fn = d.fontName or "Friz Quadrata TT"
        debugCB:SetChecked(getDebugData().enabled or false)
        minimapHideCB:SetChecked(addon.db.minimap.hide or false)
        enableCB:SetChecked(d.enabled or false)
        bossOnlyCB:SetChecked(d.bossOnly or false)
        sizeStepper.Refresh()
        fontDropdown:setValue(fn)

        local td = getTooltipData()
        ttEnableCB:SetChecked(td.enabled ~= false)
        ttColorCB:SetChecked(td.colorByUnit ~= false)
        ttHealthCB:SetChecked(td.showHealth ~= false)
        ttRealmCB:SetChecked(td.hideRealm or false)
        ttHealthBorderCB:SetChecked(td.healthBorder ~= false)
        ttCursorCB:SetChecked(td.anchorCursor or false)
        ttAnchorCB:SetChecked(td.useAnchor or false)
        ttCustomBorderCB:SetChecked(td.customBorder or false)
        ttBorderSwatch.Refresh(); ttBgSwatch.Refresh(); ttOpStepper.Refresh()
    end

    shell:SetScript("OnShow", refreshPanel)

    return shell
end


-- Themed horizontal slider used in the Move UI bar (and the settings window's
-- own UI Scale slider, next to Edit Mode): [label] [track] [box]. The
-- typeable value box sits to the RIGHT of the track. opts = { label, min,
-- max, get, set, suffix }. Returns a row frame exposing :Refresh() to re-read
-- the current value from opts.get(). Defined ahead of createMainFrame()
-- (rather than left where it's mainly used, near the Move UI bar further
-- down) since createMainFrame's own UI Scale slider needs it as a local
-- upvalue, and Lua locals aren't visible to code written before them.
local EDIT_SLIDER_TRACK_W = 110

local function buildEditSlider(parent, opts)
    local mn, mx = opts.min, opts.max
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(244, 22)

    local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("LEFT", row, "LEFT", 0, 0)
    label:SetWidth(opts.labelWidth or 58); label:SetJustifyH("LEFT")
    label:SetText(opts.label)
    label:SetTextColor(unpack(C.textWhite))

    local track = CreateFrame("Frame", nil, row, "BackdropTemplate")
    track:SetSize(EDIT_SLIDER_TRACK_W, 8)
    track:SetPoint("LEFT", label, "RIGHT", 6, 0)
    applyBackdrop(track, 1, C.panelDark, C.tabBorder)
    track:EnableMouse(true)

    local fill = track:CreateTexture(nil, "ARTWORK")
    fill:SetTexture(WHITE)
    fill:SetVertexColor(unpack(C.red))
    fill:SetPoint("TOPLEFT", track, "TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMLEFT", track, "BOTTOMLEFT", 1, 1)
    fill:SetWidth(1)

    local thumb = CreateFrame("Button", nil, track, "BackdropTemplate")
    thumb:SetSize(14, 14)
    applyBackdrop(thumb, 1, C.tabIdle, C.tabBorder)
    thumb:SetPoint("CENTER", track, "LEFT", 0, 0)

    local boxWrap = CreateFrame("Frame", nil, row, "BackdropTemplate")
    boxWrap:SetSize(40, 20)
    boxWrap:SetPoint("LEFT", track, "RIGHT", 10, 0)
    applyBackdrop(boxWrap, 1, C.panelDark, C.tabBorder)

    local box = CreateFrame("EditBox", nil, boxWrap)
    box:SetSize(32, 16); box:SetPoint("CENTER")
    box:SetAutoFocus(false); box:SetMaxLetters(3)
    box:SetJustifyH("CENTER"); box:SetFontObject("GameFontNormal")
    box:SetTextColor(unpack(C.textWhite))

    if opts.suffix then
        local suf = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        suf:SetPoint("LEFT", boxWrap, "RIGHT", 3, 0)
        suf:SetText(opts.suffix); suf:SetTextColor(unpack(C.textGrey))
    end

    local value    = mn
    local dragging  = false

    local function setVisual(v)
        local frac = (v - mn) / (mx - mn)
        frac = math.max(0, math.min(1, frac))
        fill:SetWidth(math.max(frac * (EDIT_SLIDER_TRACK_W - 2), 1))
        thumb:ClearAllPoints()
        thumb:SetPoint("CENTER", track, "LEFT", frac * EDIT_SLIDER_TRACK_W, 0)
    end

    local function setValue(v, skipSet)
        v = math.floor(math.max(mn, math.min(mx, v)) + 0.5)
        value = v
        setVisual(v)
        if not box:HasFocus() then box:SetText(tostring(v)) end
        if not skipSet and opts.set then opts.set(v) end
    end

    local function valFromCursor()
        local left = track:GetLeft()
        if not left then return value end
        -- track:GetLeft() is reported in the track's OWN effective-scale
        -- coordinate space, so the raw cursor position must be divided by that
        -- same scale — NOT UIParent's. They're equal for sliders on an
        -- unscaled parent (the Move UI bar), which is why this was fine there;
        -- but the settings window's Scale slider lives inside a frame we
        -- SetScale() ourselves, so using UIParent's scale here left the cursor
        -- math off by a factor of the window's scale (unusable at 150%, jumpy
        -- elsewhere). track:GetEffectiveScale() is correct in every case.
        local x = GetCursorPosition() / track:GetEffectiveScale()
        local frac = math.max(0, math.min(1, (x - left) / EDIT_SLIDER_TRACK_W))
        return mn + frac * (mx - mn)
    end

    -- opts.deferSet: for a slider whose opts.set() rescales one of the
    -- slider's own ancestors (e.g. the UI Scale slider, which SetScale()s the
    -- whole settings window it lives in), calling opts.set on every OnUpdate
    -- tick during a drag is self-referential — rescaling the window mid-drag
    -- shifts track:GetLeft()/width under the cursor, which throws off the
    -- very next valFromCursor() call and spirals (observed as the thumb
    -- jumping to max on a single click, or refusing to move at all once
    -- already scaled up). Deferring the real opts.set() until the drag ends
    -- keeps the track's geometry stable for the whole drag.
    thumb:SetScript("OnMouseDown", function(_, b)
        if b ~= "LeftButton" then return end
        dragging = true
        thumb:SetScript("OnUpdate", function() setValue(valFromCursor(), opts.deferSet) end)
    end)
    thumb:SetScript("OnMouseUp", function(_, b)
        if b ~= "LeftButton" then return end
        dragging = false
        thumb:SetScript("OnUpdate", nil)
        thumb:SetBackdropBorderColor(unpack(C.tabBorder))
        if opts.deferSet and opts.set then opts.set(value) end
    end)
    thumb:SetScript("OnEnter", function() thumb:SetBackdropBorderColor(unpack(C.red)) end)
    thumb:SetScript("OnLeave", function() if not dragging then thumb:SetBackdropBorderColor(unpack(C.tabBorder)) end end)

    track:SetScript("OnMouseDown", function(_, b) if b == "LeftButton" then setValue(valFromCursor()) end end)
    track:EnableMouseWheel(true)
    track:SetScript("OnMouseWheel", function(_, delta) setValue(value + delta) end)

    local function commit()
        local n = tonumber(box:GetText())
        if n then setValue(n) else box:SetText(tostring(value)) end
        box:ClearFocus()
    end
    box:SetScript("OnEnterPressed", commit)
    box:SetScript("OnEditFocusLost", commit)
    box:SetScript("OnEscapePressed", function() box:SetText(tostring(value)); box:ClearFocus() end)
    boxWrap:SetScript("OnEnter", function() boxWrap:SetBackdropBorderColor(unpack(C.red)) end)
    boxWrap:SetScript("OnLeave", function() boxWrap:SetBackdropBorderColor(unpack(C.tabBorder)) end)

    function row:Refresh() setValue((opts.get and opts.get()) or mn, true) end

    row:Refresh()
    return row
end

-- Compact [label] [-] [box] [+] [px] stepper used in the top bar for the window
-- width/height (moved there from the General tab). opts = { label, min, max,
-- step, get, set }. Returns a row frame exposing :Refresh() to re-read the
-- current value (e.g. after a corner-drag resize).
local function buildSizeStepper(parent, opts)
    local mn, mx, step = opts.min, opts.max, opts.step or 10
    local function cur() return (opts.get and opts.get()) or mn end

    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(130, 22)

    local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("LEFT", 0, 0)
    label:SetWidth(12); label:SetJustifyH("LEFT")
    label:SetText(opts.label)
    label:SetTextColor(unpack(C.textWhite))

    local minus = CreateFrame("Button", nil, row, "BackdropTemplate")
    minus:SetSize(20, 20)
    minus:SetPoint("LEFT", label, "RIGHT", 6, 0)
    applyBackdrop(minus, 1, C.panelDark, C.tabBorder)
    local minusLbl = minus:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    minusLbl:SetPoint("CENTER"); minusLbl:SetText("-"); minusLbl:SetTextColor(unpack(C.textWhite))

    local boxWrap = CreateFrame("Frame", nil, row, "BackdropTemplate")
    boxWrap:SetSize(46, 20)
    boxWrap:SetPoint("LEFT", minus, "RIGHT", 4, 0)
    applyBackdrop(boxWrap, 1, C.panelDark, C.tabBorder)

    local box = CreateFrame("EditBox", nil, boxWrap)
    box:SetSize(38, 16); box:SetPoint("CENTER")
    box:SetAutoFocus(false); box:SetMaxLetters(4); box:SetNumeric(true)
    box:SetJustifyH("CENTER"); box:SetFontObject("GameFontNormalSmall")
    box:SetTextColor(unpack(C.textWhite))

    local plus = CreateFrame("Button", nil, row, "BackdropTemplate")
    plus:SetSize(20, 20)
    plus:SetPoint("LEFT", boxWrap, "RIGHT", 4, 0)
    applyBackdrop(plus, 1, C.panelDark, C.tabBorder)
    local plusLbl = plus:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    plusLbl:SetPoint("CENTER"); plusLbl:SetText("+"); plusLbl:SetTextColor(unpack(C.textWhite))

    local suffix = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    suffix:SetPoint("LEFT", plus, "RIGHT", 4, 0)
    suffix:SetText("px"); suffix:SetTextColor(unpack(C.textGrey))

    local function refresh()
        if not box:HasFocus() then box:SetText(tostring(math.floor(cur() + 0.5))) end
    end
    local function commit(v)
        v = math.max(mn, math.min(mx, math.floor(v + 0.5)))
        if opts.set then opts.set(v) end
        refresh()
    end

    minus:SetScript("OnClick", function() commit(cur() - step) end)
    plus:SetScript("OnClick",  function() commit(cur() + step) end)
    minus:SetScript("OnEnter", function() minus:SetBackdropBorderColor(unpack(C.red)) end)
    minus:SetScript("OnLeave", function() minus:SetBackdropBorderColor(unpack(C.tabBorder)) end)
    plus:SetScript("OnEnter",  function() plus:SetBackdropBorderColor(unpack(C.red)) end)
    plus:SetScript("OnLeave",  function() plus:SetBackdropBorderColor(unpack(C.tabBorder)) end)

    box:SetScript("OnEnterPressed", function()
        local n = tonumber(box:GetText())
        if n then commit(n) else refresh() end
        box:ClearFocus()
    end)
    box:SetScript("OnEditFocusLost", refresh)
    box:SetScript("OnEscapePressed", function() refresh(); box:ClearFocus() end)
    boxWrap:SetScript("OnEnter", function() boxWrap:SetBackdropBorderColor(unpack(C.red)) end)
    boxWrap:SetScript("OnLeave", function() boxWrap:SetBackdropBorderColor(unpack(C.tabBorder)) end)

    row.Refresh = refresh
    refresh()
    return row
end

local SIDEBAR_W = 150
local MIN_WIN_W, MIN_WIN_H = 760, 420
local MAX_WIN_W, MAX_WIN_H = 1800, 1200

local function createMainFrame()
    local f = CreateFrame("Frame", "DrievSettingsFrame", UIParent, "BackdropTemplate")
    -- Wider than before to make room for the left nav sidebar while keeping the
    -- content area roughly the same width the panels were designed against.
    -- Falls back to that default size until the user drags the resize grip
    -- (see `sizer` below), which persists whatever size they land on.
    local savedW = addon.db and addon.db.settings and addon.db.settings.settingsWinW
    local savedH = addon.db and addon.db.settings and addon.db.settings.settingsWinH
    f:SetSize(savedW or 1000, savedH or 560)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:SetResizable(true)
    if f.SetResizeBounds then
        f:SetResizeBounds(MIN_WIN_W, MIN_WIN_H, MAX_WIN_W, MAX_WIN_H)
    elseif f.SetMinResize then
        f:SetMinResize(MIN_WIN_W, MIN_WIN_H)
        if f.SetMaxResize then f:SetMaxResize(MAX_WIN_W, MAX_WIN_H) end
    end
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetScale(addon.GetUIScale())
    applyBackdrop(f, 2, C.panelBG, C.red)
    f:Hide()

    -- Full-height left sidebar: brand header at the top, vertical nav below.
    -- Draggable (grabbing anywhere not on a nav button moves the window).
    local sidebar = CreateFrame("Frame", nil, f, "BackdropTemplate")
    sidebar:SetWidth(SIDEBAR_W)
    sidebar:SetPoint("TOPLEFT", 2, -2)
    sidebar:SetPoint("BOTTOMLEFT", 2, 2)
    applyBackdrop(sidebar, 1, C.panelDark)
    sidebar:EnableMouse(true)
    sidebar:RegisterForDrag("LeftButton")
    sidebar:SetScript("OnMouseDown", function() f:StartMoving() end)
    sidebar:SetScript("OnMouseUp",   function() f:StopMovingOrSizing() end)

    local title = sidebar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -12)
    title:SetText("|cfffb2c36Driev's|r |cffffffffEssentials|r")

    local version = sidebar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    version:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
    version:SetText("|cffaaaaaav" .. addon.version .. "|r")

    -- Top bar spanning only the content area (right of the sidebar). Holds the
    -- Edit Mode + close buttons; also draggable.
    local topBar = CreateFrame("Frame", nil, f, "BackdropTemplate")
    -- 40 (rather than 34): the extra height lets the content box sit just 2px
    -- below the top bar — matching the 2px sidebar↔content gap — while still
    -- dropping each panel's tab bar down far enough to line up with the first
    -- sidebar nav button (see the content anchor below).
    topBar:SetHeight(40)
    topBar:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 2, 0)
    topBar:SetPoint("TOPRIGHT", -2, -2)
    applyBackdrop(topBar, 1, C.panelDark)
    topBar:EnableMouse(true)
    topBar:RegisterForDrag("LeftButton")
    topBar:SetScript("OnMouseDown", function() f:StartMoving() end)
    topBar:SetScript("OnMouseUp",   function() f:StopMovingOrSizing() end)

    local close = CreateFrame("Button", nil, topBar)
    close:SetSize(26, 26)
    close:SetPoint("RIGHT", -6, 0)
    local closeLabel = close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    closeLabel:SetPoint("CENTER")
    closeLabel:SetText("X")
    closeLabel:SetTextColor(unpack(C.red))
    close:SetScript("OnEnter", function() closeLabel:SetTextColor(unpack(C.textWhite)) end)
    close:SetScript("OnLeave", function() closeLabel:SetTextColor(unpack(C.red)) end)
    close:SetScript("OnClick", function() f:Hide() end)

    local moveUIBtn = flatButton(topBar, "Edit Mode", 90, 22)
    moveUIBtn:SetPoint("RIGHT", close, "LEFT", -6, 0)
    moveUIBtn:SetScript("OnClick", function() UI.EnterMoveMode() end)

    local scaleSlider = buildEditSlider(topBar, {
        label = "Scale", labelWidth = 36, min = 50, max = 150, suffix = "%", deferSet = true,
        get = function() return math.floor(addon.GetUIScale() * 100 + 0.5) end,
        set = function(v) addon.SetUIScale(v / 100) end,
    })
    scaleSlider:SetPoint("RIGHT", moveUIBtn, "LEFT", -14, 0)

    -- Window width/height steppers, left of the Scale slider. They write the
    -- same saved settingsWinW/H the resize grip persists (and are refreshed from
    -- it — see sizer below), so typed size and corner-drag stay in sync.
    local heightStepper = buildSizeStepper(topBar, {
        label = "H", min = MIN_WIN_H, max = MAX_WIN_H, step = 10,
        get = function() return math.floor(f:GetHeight() + 0.5) end,
        set = function(v)
            f:SetHeight(v)
            if addon.db and addon.db.settings then addon.db.settings.settingsWinH = v end
        end,
    })
    heightStepper:SetPoint("RIGHT", scaleSlider, "LEFT", -16, 0)

    local widthStepper = buildSizeStepper(topBar, {
        label = "W", min = MIN_WIN_W, max = MAX_WIN_W, step = 10,
        get = function() return math.floor(f:GetWidth() + 0.5) end,
        set = function(v)
            f:SetWidth(v)
            if addon.db and addon.db.settings then addon.db.settings.settingsWinW = v end
        end,
    })
    widthStepper:SetPoint("RIGHT", heightStepper, "LEFT", -10, 0)

    local content = CreateFrame("Frame", nil, f, "BackdropTemplate")
    -- 2px gap below the top bar, matching the 2px sidebar↔content gap. The tab
    -- bars still line up with the sidebar nav because the top bar is 6px taller
    -- than its contents need (see topBar:SetHeight above).
    content:SetPoint("TOPLEFT", topBar, "BOTTOMLEFT", 0, -2)
    content:SetPoint("BOTTOMRIGHT", -2, 2)
    applyBackdrop(content, 1, C.panelDeep)

    -- Resize grip, bottom-right corner. Leaves the window's own edges alone
    -- (no visible frame of its own) and just starts/stops a native resize;
    -- every panel already re-anchors off `content`'s edges, and
    -- attachScrollTrack's SCROLLBAR_BOTTOM_CLEARANCE keeps this from
    -- overlapping a tab's scrollbar.
    local sizer = CreateFrame("Button", nil, f)
    sizer:SetSize(16, 16)
    sizer:SetPoint("BOTTOMRIGHT", -3, 3)
    sizer:SetFrameLevel(f:GetFrameLevel() + 10)
    local grip = sizer:CreateTexture(nil, "OVERLAY")
    grip:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetAllPoints()
    sizer:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then f:StartSizing("BOTTOMRIGHT") end
    end)
    sizer:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        if addon.db and addon.db.settings then
            addon.db.settings.settingsWinW = f:GetWidth()
            addon.db.settings.settingsWinH = f:GetHeight()
        end
        widthStepper:Refresh()
        heightStepper:Refresh()
    end)

    f.topBar  = topBar
    f.sidebar = sidebar
    f.content = content
    f.tabs    = {}
    f.panels  = {}

    tinsert(UISpecialFrames, "DrievSettingsFrame")
    return f
end

-- ── Profile export/import popup ─────────────────────────────────────────────
-- One shared floating window, repurposed for both showing an export string
-- (read-focused, pre-selected for Ctrl+C) and pasting an import string
-- (empty, with an Import button). Mirrors getPositionEditor's floating-panel
-- style (draggable TOOLTIP-strata BackdropTemplate frame with an "X" close).

local function getTextPopup()
    if UI.textPopup then return UI.textPopup end

    local panel = CreateFrame("Frame", "DrievTextPopup", UIParent, "BackdropTemplate")
    panel:SetSize(460, 400)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("TOOLTIP")
    applyBackdrop(panel, 2, C.panelBG, C.red)
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    panel:SetMovable(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
    panel:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
    panel:Hide()

    -- Every element below is a fixed size and anchored via single-point
    -- TOP/BOTTOM chains centered on the previous element, rather than
    -- TOPLEFT+TOPRIGHT pairs relative to the (variable-width) title text —
    -- otherwise the popup's width would shift depending on how long the
    -- title/hint text happens to be (e.g. a long profile name).
    local CONTENT_W = 420

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", panel, "TOP", 0, -12)
    title:SetWidth(CONTENT_W)
    title:SetJustifyH("CENTER")
    title:SetTextColor(unpack(C.red))
    panel.title = title

    local closeBtn = CreateFrame("Button", nil, panel)
    closeBtn:SetSize(18, 18)
    closeBtn:SetPoint("TOPRIGHT", -8, -8)
    local closeLbl = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    closeLbl:SetPoint("CENTER"); closeLbl:SetText("X"); closeLbl:SetTextColor(unpack(C.red))
    closeBtn:SetScript("OnEnter", function() closeLbl:SetTextColor(unpack(C.textWhite)) end)
    closeBtn:SetScript("OnLeave", function() closeLbl:SetTextColor(unpack(C.red)) end)
    closeBtn:SetScript("OnClick", function() panel:Hide() end)

    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOP", title, "BOTTOM", 0, -8)
    hint:SetWidth(CONTENT_W)
    hint:SetJustifyH("CENTER")
    hint:SetTextColor(unpack(C.textGrey))
    panel.hint = hint

    -- Import-only: profile name to import into. Hidden for Export, where the
    -- popup instead re-anchors scrollWrap straight under the hint text.
    local nameRow = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    nameRow:SetSize(220, 24)
    nameRow:SetPoint("TOP", hint, "BOTTOM", 0, -10)
    applyBackdrop(nameRow, 1, C.panelDark, C.tabBorder)

    local nameEdit = CreateFrame("EditBox", nil, nameRow)
    nameEdit:SetSize(206, 18)
    nameEdit:SetPoint("CENTER")
    nameEdit:SetAutoFocus(false)
    nameEdit:SetMaxLetters(32)
    nameEdit:SetFontObject("GameFontNormal")
    nameEdit:SetTextColor(unpack(C.textWhite))
    nameEdit:SetTextInsets(4, 4, 0, 0)
    nameEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    panel.nameRow, panel.nameEdit = nameRow, nameEdit

    nameEdit:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        panel.box:SetFocus()
    end)

    local SB_W = 10   -- scrollbar track width, matches the font-picker dropdown

    local scrollWrap = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    scrollWrap:SetSize(CONTENT_W, 190)
    scrollWrap:SetPoint("TOP", hint, "BOTTOM", 0, -10)
    applyBackdrop(scrollWrap, 1, C.panelDark, C.tabBorder)
    panel.scrollWrap = scrollWrap

    -- Plain ScrollFrame (no template) — the scrollbar below is hand-built to
    -- match the themed track/thumb used by the font-picker dropdown
    -- (createScrollDropdown) instead of the default Blizzard scrollbar.
    local scroll = CreateFrame("ScrollFrame", nil, scrollWrap)
    scroll:SetPoint("TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", -(SB_W + 8), 6)

    local box = CreateFrame("EditBox", nil, scroll)
    box:SetMultiLine(true)
    box:SetAutoFocus(false)
    box:SetFontObject("ChatFontNormal")
    box:SetTextColor(unpack(C.textWhite))
    box:SetWidth(CONTENT_W - SB_W - 40)
    box:SetHeight(500)
    box:EnableMouse(true)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(box)
    panel.box = box

    local track = CreateFrame("Frame", nil, scrollWrap, "BackdropTemplate")
    track:SetWidth(SB_W)
    track:SetPoint("TOPRIGHT",    scrollWrap, "TOPRIGHT",    -1, -1)
    track:SetPoint("BOTTOMRIGHT", scrollWrap, "BOTTOMRIGHT", -1,  1)
    applyBackdrop(track, 1, C.panelDeep, C.tabBorder)

    local thumb = CreateFrame("Button", nil, track, "BackdropTemplate")
    thumb:SetWidth(SB_W - 2)
    applyBackdrop(thumb, 1, C.tabIdle, C.tabBorder)
    thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 1, 0)

    local function updateThumb()
        local maxScroll = scroll:GetVerticalScrollRange()
        local visibleH  = scroll:GetHeight()
        if maxScroll <= 0 then track:Hide(); return end
        track:Show()
        local trackH = track:GetHeight()
        if trackH <= 0 then return end
        local thumbH = math.max(16, trackH * visibleH / (visibleH + maxScroll))
        local cur    = scroll:GetVerticalScroll()
        local frac   = maxScroll > 0 and (cur / maxScroll) or 0
        thumb:SetHeight(thumbH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 1, -(frac * (trackH - thumbH)))
    end
    panel.updateThumb = updateThumb
    box:SetScript("OnTextChanged", updateThumb)
    box:SetScript("OnCursorChanged", updateThumb)

    local isDragging, dragStartY, dragStartScroll = false, 0, 0
    thumb:EnableMouse(true)
    thumb:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then
            isDragging      = true
            dragStartY      = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
            dragStartScroll = scroll:GetVerticalScroll()
        end
    end)
    thumb:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then isDragging = false end
    end)
    thumb:SetScript("OnUpdate", function()
        if not isDragging then return end
        local curY      = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
        local delta      = dragStartY - curY
        local trackH     = track:GetHeight()
        local thumbH     = thumb:GetHeight()
        local maxScroll  = scroll:GetVerticalScrollRange()
        if trackH > thumbH and maxScroll > 0 then
            scroll:SetVerticalScroll(math.max(0, math.min(
                dragStartScroll + delta * maxScroll / (trackH - thumbH),
                maxScroll
            )))
            updateThumb()
        end
    end)
    thumb:SetScript("OnEnter", function(self) self:SetBackdropColor(unpack(C.tabHover)) end)
    thumb:SetScript("OnLeave", function(self) self:SetBackdropColor(unpack(C.tabIdle))  end)

    scrollWrap:EnableMouseWheel(true)
    scrollWrap:SetScript("OnMouseWheel", function(_, d)
        local maxScroll = scroll:GetVerticalScrollRange()
        scroll:SetVerticalScroll(math.max(0, math.min(scroll:GetVerticalScroll() - d * 20, maxScroll)))
        updateThumb()
    end)

    -- The visible area is much shorter than the box itself (SetHeight(500)),
    -- so clicking on blank space below short text still needs to focus it —
    -- forward clicks on the wrapper/scroll frame to the EditBox explicitly
    -- rather than relying solely on the box's own (smaller) hit region.
    scrollWrap:EnableMouse(true)
    scrollWrap:SetScript("OnMouseDown", function() box:SetFocus() end)
    scroll:EnableMouse(true)
    scroll:SetScript("OnMouseDown", function() box:SetFocus() end)

    local errText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    errText:SetPoint("TOP", scrollWrap, "BOTTOM", 0, -8)
    errText:SetWidth(CONTENT_W)
    errText:SetJustifyH("CENTER")
    errText:SetTextColor(unpack(C.red))
    panel.errText = errText

    local actionBtn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    actionBtn:SetSize(120, 24)
    actionBtn:SetPoint("BOTTOM", panel, "BOTTOM", 0, 14)
    applyBackdrop(actionBtn, 1, C.panelDark, C.tabBorder)
    local actionLbl = actionBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    actionLbl:SetPoint("CENTER"); actionLbl:SetTextColor(unpack(C.textWhite))
    actionBtn:SetScript("OnEnter", function() actionBtn:SetBackdropBorderColor(unpack(C.red)) end)
    actionBtn:SetScript("OnLeave", function() actionBtn:SetBackdropBorderColor(unpack(C.tabBorder)) end)
    panel.actionBtn, panel.actionLbl = actionBtn, actionLbl

    UI.textPopup = panel
    return panel
end

local function showExportPopup(profileName)
    local exportStr, err = addon.ExportProfile(profileName)
    local panel = getTextPopup()
    panel.title:SetText("Export Profile: " .. profileName)
    panel.hint:SetText("Copy this string (Ctrl+A, Ctrl+C) and share it with someone else.")
    panel.errText:SetText(exportStr and "" or (err or "Could not export this profile."))
    panel.box:SetText(exportStr or "")
    panel.actionLbl:SetText("Close")
    panel.actionBtn:SetScript("OnClick", function() panel:Hide() end)

    panel.nameRow:Hide()
    panel.scrollWrap:ClearAllPoints()
    panel.scrollWrap:SetPoint("TOP", panel.hint, "BOTTOM", 0, -10)

    panel:Show()
    panel.box:SetFocus()
    panel.box:HighlightText()
    panel.updateThumb()
end

local function showImportPopup(onImported)
    local panel = getTextPopup()
    panel.title:SetText("Import Profile")
    panel.hint:SetText("Enter a name for the new profile, paste a string exported from Driev's Essentials below, then click Import.")
    panel.errText:SetText("")
    panel.box:SetText("")
    panel.nameEdit:SetText("")
    panel.actionLbl:SetText("Import")
    panel.actionBtn:SetScript("OnClick", function()
        local profName, err = addon.ImportProfile(panel.nameEdit:GetText(), panel.box:GetText())
        if not profName then
            panel.errText:SetText(err or "Import failed.")
            return
        end
        panel:Hide()
        if onImported then onImported(profName) end
    end)

    panel.nameRow:Show()
    panel.scrollWrap:ClearAllPoints()
    panel.scrollWrap:SetPoint("TOP", panel.nameRow, "BOTTOM", 0, -10)

    panel:Show()
    panel.nameEdit:SetFocus()
    panel.updateThumb()
end

-- ── Themed confirmation popup ────────────────────────────────────────────────
-- Same floating-panel look as getTextPopup (draggable TOOLTIP-strata
-- BackdropTemplate frame), but for a yes/no prompt instead of text entry.

local function getConfirmPopup()
    if UI.confirmPopup then return UI.confirmPopup end

    local panel = CreateFrame("Frame", "DrievConfirmPopup", UIParent, "BackdropTemplate")
    panel:SetSize(360, 150)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("TOOLTIP")
    applyBackdrop(panel, 2, C.panelBG, C.red)
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    panel:SetMovable(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
    panel:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
    panel:Hide()

    local CONTENT_W = 320

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", panel, "TOP", 0, -14)
    title:SetWidth(CONTENT_W)
    title:SetJustifyH("CENTER")
    title:SetTextColor(unpack(C.red))
    panel.title = title

    local message = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    message:SetPoint("TOP", title, "BOTTOM", 0, -16)
    message:SetWidth(CONTENT_W)
    message:SetJustifyH("CENTER")
    message:SetTextColor(unpack(C.textWhite))
    panel.message = message

    local cancelBtn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    cancelBtn:SetSize(120, 24)
    cancelBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOM", 6, 16)
    applyBackdrop(cancelBtn, 1, C.panelDark, C.tabBorder)
    local cancelLbl = cancelBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    cancelLbl:SetPoint("CENTER"); cancelLbl:SetText("Cancel"); cancelLbl:SetTextColor(unpack(C.textWhite))
    cancelBtn:SetScript("OnEnter", function() cancelBtn:SetBackdropBorderColor(unpack(C.red)) end)
    cancelBtn:SetScript("OnLeave", function() cancelBtn:SetBackdropBorderColor(unpack(C.tabBorder)) end)
    cancelBtn:SetScript("OnClick", function() panel:Hide() end)
    panel.cancelBtn = cancelBtn

    local confirmBtn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    confirmBtn:SetSize(120, 24)
    confirmBtn:SetPoint("BOTTOMRIGHT", panel, "BOTTOM", -6, 16)
    applyBackdrop(confirmBtn, 1, C.panelDark, C.tabBorder)
    local confirmLbl = confirmBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    confirmLbl:SetPoint("CENTER"); confirmLbl:SetTextColor(unpack(C.textWhite))
    confirmBtn:SetScript("OnEnter", function() confirmBtn:SetBackdropBorderColor(unpack(C.red)) end)
    confirmBtn:SetScript("OnLeave", function() confirmBtn:SetBackdropBorderColor(unpack(C.tabBorder)) end)
    panel.confirmBtn, panel.confirmLbl = confirmBtn, confirmLbl

    UI.confirmPopup = panel
    return panel
end

-- opts = { title, message, confirmText, onConfirm }
local function showConfirmPopup(opts)
    local panel = getConfirmPopup()
    panel.title:SetText(opts.title or "Confirm")
    panel.message:SetText(opts.message or "")
    panel.confirmLbl:SetText(opts.confirmText or "Confirm")
    panel.confirmBtn:SetScript("OnClick", function()
        panel:Hide()
        if opts.onConfirm then opts.onConfirm() end
    end)
    panel:Show()
end
-- Exposed for module addons (Trinkets uses it for the modifier-conflict prompt)
-- and for any panel defined above this point — a plain local isn't visible to
-- code written before its definition.
UI.showConfirmPopup = showConfirmPopup

-- ── Profiles tab ─────────────────────────────────────────────────────────────

local function buildProfilesPanel(parent)
    local shell, panel = makeScrollPanel(parent)

    -- Forward-declared so the Copy Profile section's button (built before the
    -- Existing Profiles list) can re-run it after a copy.
    local refreshProfiles

    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 14, -14)
    header:SetText("Profiles")
    header:SetTextColor(unpack(C.red))

    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    desc:SetWidth(560); desc:SetJustifyH("LEFT")
    desc:SetText("Every setting and saved position belongs to a profile. Switch profiles to use a different setup on this character — handy for separate configs per character or class.")
    desc:SetTextColor(unpack(C.textGrey))

    -- ── Create new profile ────────────────────────────────────────────────
    local newHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    newHeader:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -20)
    newHeader:SetText("New Profile")
    newHeader:SetTextColor(unpack(C.red))

    local nameBoxWrap = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    nameBoxWrap:SetSize(220, 24)
    nameBoxWrap:SetPoint("TOPLEFT", newHeader, "BOTTOMLEFT", 0, -10)
    applyBackdrop(nameBoxWrap, 1, C.panelDark, C.tabBorder)

    local nameBox = CreateFrame("EditBox", nil, nameBoxWrap)
    nameBox:SetSize(206, 18)
    nameBox:SetPoint("CENTER")
    nameBox:SetAutoFocus(false)
    nameBox:SetMaxLetters(32)
    nameBox:SetFontObject("GameFontNormal")
    nameBox:SetTextColor(unpack(C.textWhite))
    nameBox:SetTextInsets(4, 4, 0, 0)

    local createBtn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    createBtn:SetSize(90, 24)
    createBtn:SetPoint("LEFT", nameBoxWrap, "RIGHT", 8, 0)
    applyBackdrop(createBtn, 1, C.panelDark, C.tabBorder)
    local createLbl = createBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    createLbl:SetPoint("CENTER"); createLbl:SetText("Create"); createLbl:SetTextColor(unpack(C.textWhite))
    createBtn:SetScript("OnEnter", function() createBtn:SetBackdropBorderColor(unpack(C.red)) end)
    createBtn:SetScript("OnLeave", function() createBtn:SetBackdropBorderColor(unpack(C.tabBorder)) end)

    local importBtn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    importBtn:SetSize(120, 24)
    importBtn:SetPoint("LEFT", createBtn, "RIGHT", 8, 0)
    applyBackdrop(importBtn, 1, C.panelDark, C.tabBorder)
    local importLbl = importBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    importLbl:SetPoint("CENTER"); importLbl:SetText("Import Profile"); importLbl:SetTextColor(unpack(C.textWhite))
    importBtn:SetScript("OnEnter", function() importBtn:SetBackdropBorderColor(unpack(C.red)) end)
    importBtn:SetScript("OnLeave", function() importBtn:SetBackdropBorderColor(unpack(C.tabBorder)) end)

    local errText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    errText:SetPoint("TOPLEFT", nameBoxWrap, "BOTTOMLEFT", 0, -6)
    errText:SetTextColor(unpack(C.red))
    errText:SetText("")

    -- ── Copy profile ──────────────────────────────────────────────────────
    -- Pick a source and a destination profile, then Copy (with a confirm
    -- prompt) to overwrite the destination with the source's settings.
    local copyHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    copyHeader:SetPoint("TOPLEFT", errText, "BOTTOMLEFT", 0, -20)
    copyHeader:SetText("Copy Profile")
    copyHeader:SetTextColor(unpack(C.red))

    local copyDesc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    copyDesc:SetPoint("TOPLEFT", copyHeader, "BOTTOMLEFT", 0, -4)
    copyDesc:SetWidth(560); copyDesc:SetJustifyH("LEFT")
    copyDesc:SetText("Overwrite one profile's settings with a copy of another's.")
    copyDesc:SetTextColor(unpack(C.textGrey))

    local copyFrom, copyTo

    local fromLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fromLbl:SetPoint("TOPLEFT", copyDesc, "BOTTOMLEFT", 0, -12)
    fromLbl:SetText("From:")
    fromLbl:SetTextColor(unpack(C.textGrey))

    local fromDD = createScrollDropdown(panel, 150,
        function() return addon.GetProfileList() end,
        function(v) copyFrom = v end)
    fromDD:SetPoint("LEFT", fromLbl, "RIGHT", 6, 0)

    local toLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    toLbl:SetPoint("LEFT", fromDD, "RIGHT", 14, 0)
    toLbl:SetText("To:")
    toLbl:SetTextColor(unpack(C.textGrey))

    local toDD = createScrollDropdown(panel, 150,
        function() return addon.GetProfileList() end,
        function(v) copyTo = v end)
    toDD:SetPoint("LEFT", toLbl, "RIGHT", 6, 0)

    local copyErr = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    copyErr:SetPoint("TOPLEFT", fromLbl, "BOTTOMLEFT", 0, -12)
    copyErr:SetTextColor(unpack(C.red))
    copyErr:SetText("")

    local copyBtn = flatButton(panel, "Copy", 80, 22)
    copyBtn:SetPoint("LEFT", toDD, "RIGHT", 14, 0)
    copyBtn:SetScript("OnClick", function()
        copyErr:SetText("")
        if not (copyFrom and copyTo) then
            copyErr:SetText("Select a profile in both dropdowns.")
            return
        end
        if copyFrom == copyTo then
            copyErr:SetText("Pick two different profiles.")
            return
        end
        showConfirmPopup({
            title       = "Copy Profile",
            message     = string.format('Overwrite "%s" with a copy of "%s"? This replaces all of "%s"\'s settings.', copyTo, copyFrom, copyTo),
            confirmText = "Copy",
            onConfirm   = function()
                local ok, err = addon.CopyProfile(copyFrom, copyTo)
                if not ok then copyErr:SetText(err or "Could not copy profile.") end
                refreshProfiles()
            end,
        })
    end)

    -- ── List of existing profiles ─────────────────────────────────────────
    local listHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    listHeader:SetPoint("TOPLEFT", copyErr, "BOTTOMLEFT", 0, -20)
    listHeader:SetText("Existing Profiles")
    listHeader:SetTextColor(unpack(C.red))

    local rows = {}
    local ROW_W, ROW_H = 540, 26

    local function makeRow()
        local row = CreateFrame("Frame", nil, panel, "BackdropTemplate")
        row:SetSize(ROW_W, ROW_H)
        applyBackdrop(row, 1, C.panelDeep, C.tabBorder)

        local nameFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameFS:SetPoint("LEFT", 8, 0)
        nameFS:SetTextColor(unpack(C.textWhite))
        row.nameFS = nameFS

        local activeFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        activeFS:SetPoint("LEFT", nameFS, "RIGHT", 8, 0)
        activeFS:SetText("(active on this character)")
        activeFS:SetTextColor(unpack(C.red))
        row.activeFS = activeFS

        local deleteBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
        deleteBtn:SetSize(70, 20)
        deleteBtn:SetPoint("RIGHT", -6, 0)
        applyBackdrop(deleteBtn, 1, C.panelDark, C.tabBorder)
        local deleteLbl = deleteBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        deleteLbl:SetPoint("CENTER"); deleteLbl:SetText("Delete")
        deleteBtn:SetScript("OnEnter", function() if row.canDelete then deleteBtn:SetBackdropBorderColor(unpack(C.red)) end end)
        deleteBtn:SetScript("OnLeave", function() deleteBtn:SetBackdropBorderColor(unpack(C.tabBorder)) end)
        row.deleteBtn, row.deleteLbl = deleteBtn, deleteLbl

        local switchBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
        switchBtn:SetSize(90, 20)
        switchBtn:SetPoint("RIGHT", deleteBtn, "LEFT", -6, 0)
        applyBackdrop(switchBtn, 1, C.panelDark, C.tabBorder)
        local switchLbl = switchBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        switchLbl:SetPoint("CENTER"); switchLbl:SetText("Use"); switchLbl:SetTextColor(unpack(C.textWhite))
        switchBtn:SetScript("OnEnter", function() switchBtn:SetBackdropBorderColor(unpack(C.red)) end)
        switchBtn:SetScript("OnLeave", function() switchBtn:SetBackdropBorderColor(unpack(C.tabBorder)) end)
        row.switchBtn = switchBtn

        local exportBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
        exportBtn:SetSize(70, 20)
        exportBtn:SetPoint("RIGHT", switchBtn, "LEFT", -6, 0)
        applyBackdrop(exportBtn, 1, C.panelDark, C.tabBorder)
        local exportLbl = exportBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        exportLbl:SetPoint("CENTER"); exportLbl:SetText("Export"); exportLbl:SetTextColor(unpack(C.textWhite))
        exportBtn:SetScript("OnEnter", function() exportBtn:SetBackdropBorderColor(unpack(C.red)) end)
        exportBtn:SetScript("OnLeave", function() exportBtn:SetBackdropBorderColor(unpack(C.tabBorder)) end)
        row.exportBtn = exportBtn

        return row
    end

    refreshProfiles = function()
        errText:SetText("")
        copyErr:SetText("")
        nameBox:SetText("")
        local list   = addon.GetProfileList and addon.GetProfileList() or {}
        local active = addon.GetActiveProfileName and addon.GetActiveProfileName() or "Default"

        -- Drop any copy selection whose profile no longer exists, and re-sync
        -- the dropdown labels (their lists repopulate live when opened).
        local exists = {}
        for _, n in ipairs(list) do exists[n] = true end
        if copyFrom and not exists[copyFrom] then copyFrom = nil end
        if copyTo   and not exists[copyTo]   then copyTo   = nil end
        fromDD:setValue(copyFrom)
        toDD:setValue(copyTo)

        while #rows < #list do
            rows[#rows + 1] = makeRow()
        end

        local prevRow
        for i, profName in ipairs(list) do
            local row = rows[i]
            row:ClearAllPoints()
            if prevRow then
                row:SetPoint("TOPLEFT", prevRow, "BOTTOMLEFT", 0, -6)
            else
                row:SetPoint("TOPLEFT", listHeader, "BOTTOMLEFT", 0, -10)
            end
            row.nameFS:SetText(profName)

            local isActive = (profName == active)
            row.activeFS:SetShown(isActive)
            row.switchBtn:SetShown(not isActive)
            row.switchBtn:SetScript("OnClick", function() addon.SetActiveProfile(profName) end)
            row.exportBtn:SetScript("OnClick", function() showExportPopup(profName) end)

            row.canDelete = (profName ~= "Default") and not isActive
            row.deleteBtn:SetEnabled(row.canDelete)
            if row.canDelete then
                row.deleteLbl:SetTextColor(unpack(C.textWhite))
            else
                row.deleteLbl:SetTextColor(unpack(C.textDim))
            end
            row.deleteBtn:SetBackdropBorderColor(unpack(C.tabBorder))
            if row.canDelete then
                row.deleteBtn:SetScript("OnClick", function()
                    showConfirmPopup({
                        title       = "Delete Profile",
                        message     = string.format('Are you sure you want to delete the "%s" profile?', profName),
                        confirmText = "Delete",
                        onConfirm   = function()
                            addon.DeleteProfile(profName)
                            refreshProfiles()
                        end,
                    })
                end)
            else
                row.deleteBtn:SetScript("OnClick", nil)
            end

            row:Show()
            prevRow = row
        end
        for i = #list + 1, #rows do
            rows[i]:Hide()
        end
    end

    createBtn:SetScript("OnClick", function()
        local name, err = addon.CreateProfile(nameBox:GetText())
        if not name then
            errText:SetText(err or "Could not create profile.")
            return
        end
        addon.SetActiveProfile(name)
        refreshProfiles()
    end)
    importBtn:SetScript("OnClick", function()
        showImportPopup(function(importedName)
            addon.SetActiveProfile(importedName)
            refreshProfiles()
        end)
    end)
    nameBox:SetScript("OnEnterPressed", function(self)
        createBtn:GetScript("OnClick")(createBtn)
        self:ClearFocus()
    end)
    nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    shell:SetScript("OnShow", refreshProfiles)
    return shell
end

-- ── Nav tab registry ─────────────────────────────────────────────────────────
-- Every sidebar tab registers itself here instead of GetFrame hardcoding a list,
-- so a separate module addon (Particles, Trinkets) can contribute its own tab
-- just by calling UI.RegisterTab at load time. Registration must happen before
-- the settings window is first opened, which is always the case: addons finish
-- loading long before the user can click anything.
--   def = { key, label, order, build = function(parent) -> panel frame }
-- `order` sorts the sidebar top→down (ties fall back to registration order).
UI.tabRegistry = {}

-- Names of addon.X tables (TTK, RaidFrames, Trinkets, ...) that expose the
-- movable interface (getFrame/enterMoveMode/leaveMoveMode/savePosition/
-- getPosition/setPosition — see TTK.lua for the reference shape) and should
-- be included whenever UI.EnterMoveMode() is called with no explicit list
-- (the "Edit Mode" button). A module addon calls UI.RegisterMovable("Name")
-- once at load time instead of core needing to know it exists.
UI.movableNames = { "TTK", "RaidFrames", "Trinkets", "Tooltip" }

-- Display names for the Modules list in Edit Mode. Keyed by the addon.X name;
-- anything missing falls back to the key itself.
UI.movableLabels = {
    TTK        = "Time to Kill",
    RaidFrames = "Raid Frames",
    Trinkets   = "Trinket Menu",
    Tooltip    = "Tooltip Anchor",
}

-- A movable's name for that list. Runtime-created movables (DataText bars,
-- chat panels) supply their own getLabel, since their names are user-editable
-- and there is no fixed addon.X key to look them up by.
function UI.MovableLabel(m)
    if type(m.getLabel) == "function" then
        local ok, text = pcall(m.getLabel)
        if ok and text then return text end
    end
    if m.label then return m.label end
    for _, name in ipairs(UI.movableNames) do
        if addon[name] == m then return UI.movableLabels[name] or name end
    end
    return "Element"
end

function UI.RegisterMovable(name)
    if not name then return end
    for _, n in ipairs(UI.movableNames) do
        if n == name then return end -- already registered
    end
    UI.movableNames[#UI.movableNames + 1] = name
end

-- For movables that don't exist as a fixed addon.X table — things the user
-- creates at runtime (DataText bars, chat docks), where the set changes as
-- they add/remove them. A provider is a function returning a list of movable
-- objects; it's called fresh every time Edit Mode opens, so newly-created
-- objects are picked up without re-registering anything.
UI.movableProviders = {}

function UI.RegisterMovableProvider(fn)
    if type(fn) ~= "function" then return end
    UI.movableProviders[#UI.movableProviders + 1] = fn
end

function UI.RegisterTab(def)
    if not (def and def.key and def.build) then return end
    def.order = def.order or 100
    def._seq  = #UI.tabRegistry + 1
    UI.tabRegistry[#UI.tabRegistry + 1] = def
end

local function sortedTabs()
    local list = {}
    for _, def in ipairs(UI.tabRegistry) do list[#list + 1] = def end
    table.sort(list, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a._seq < b._seq
    end)
    return list
end

function UI.GetFrame()
    if UI.frame then return UI.frame end

    local f = createMainFrame()

    -- Vertical sidebar nav, built from whatever tabs registered. Buttons stack
    -- top→down, full sidebar width.
    local defs = sortedTabs()
    local prevNav
    for _, def in ipairs(defs) do
        local tab = createSideTab(f.sidebar, def.label or def.key)
        if prevNav then
            tab:SetPoint("TOPLEFT",  prevNav, "BOTTOMLEFT",  0, -2)
            tab:SetPoint("TOPRIGHT", prevNav, "BOTTOMRIGHT", 0, -2)
        else
            -- Start below the sidebar brand header (title + version).
            tab:SetPoint("TOPLEFT",  f.sidebar, "TOPLEFT",   3, -48)
            tab:SetPoint("TOPRIGHT", f.sidebar, "TOPRIGHT", -3, -48)
        end
        tab:SetScript("OnClick", function() selectTab(f, def.key) end)
        f.tabs[def.key] = tab
        prevNav = tab
    end

    for _, def in ipairs(defs) do
        f.panels[def.key] = def.build(f.content)
    end

    if defs[1] then selectTab(f, defs[1].key) end

    UI.frame = f
    return f
end

-- Core's own tabs. The Particles (order 20) and Trinkets (order 40) module
-- addons register their own from their own files, so they slot into the gaps
-- below — and disappear entirely when those addons are disabled.
UI.RegisterTab({ key = "general",   label = "General",   order = 10, build = buildGeneralTabPanel })
UI.RegisterTab({ key = "raid",      label = "Raid",      order = 30, build = buildRaidTabPanel })
UI.RegisterTab({ key = "profiles",  label = "Profiles",  order = 90, build = buildProfilesPanel })

function addon.ToggleUI()
    local f = UI.GetFrame()
    if f:IsShown() then f:Hide() else f:Show() end
end

-- Small floating popup opened by clicking (not dragging) a movable element
-- while in edit mode: precise X/Y entry plus a directional nudge pad
-- (1 unit per click) arranged left/right/top/bottom around the boxes.
-- Works against any movable object exposing getPosition()/setPosition(x,y).
local function getPositionEditor()
    if UI.positionEditor then return UI.positionEditor end

    local panel = CreateFrame("Frame", "DrievPositionEditor", UIParent, "BackdropTemplate")
    panel:SetSize(200, 130)
    panel:SetFrameStrata("TOOLTIP")
    applyBackdrop(panel, 2, C.panelBG, C.red)
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    panel:SetMovable(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
    panel:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
    panel:Hide()

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", panel, "TOP", 0, -8)
    title:SetText("Position")
    title:SetTextColor(unpack(C.textWhite))

    local closeBtn = CreateFrame("Button", nil, panel)
    closeBtn:SetSize(18, 18)
    closeBtn:SetPoint("TOPRIGHT", -6, -6)
    local closeLbl = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    closeLbl:SetPoint("CENTER")
    closeLbl:SetText("X")
    closeLbl:SetTextColor(unpack(C.red))
    closeBtn:SetScript("OnEnter", function() closeLbl:SetTextColor(unpack(C.textWhite)) end)
    closeBtn:SetScript("OnLeave", function() closeLbl:SetTextColor(unpack(C.red)) end)
    closeBtn:SetScript("OnClick", function() panel:Hide() end)

    local function makeBox(parent)
        local wrap = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        wrap:SetSize(50, 22)
        applyBackdrop(wrap, 1, C.panelDark, C.tabBorder)
        wrap:SetScript("OnEnter", function() wrap:SetBackdropBorderColor(unpack(C.red)) end)
        wrap:SetScript("OnLeave", function() wrap:SetBackdropBorderColor(unpack(C.tabBorder)) end)

        local box = CreateFrame("EditBox", nil, wrap)
        box:SetSize(42, 18)
        box:SetPoint("CENTER")
        box:SetAutoFocus(false)
        box:SetJustifyH("CENTER")
        box:SetMaxLetters(7)
        box:SetFontObject("GameFontNormal")
        box:SetTextColor(unpack(C.textWhite))
        return wrap, box
    end

    local function makeArrow(glyph)
        local btn = CreateFrame("Button", nil, panel, "BackdropTemplate")
        btn:SetSize(20, 20)
        applyBackdrop(btn, 1, C.panelDark, C.tabBorder)
        local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("CENTER")
        lbl:SetText(glyph)
        lbl:SetTextColor(unpack(C.textWhite))
        btn:SetScript("OnEnter", function() btn:SetBackdropBorderColor(unpack(C.red)) end)
        btn:SetScript("OnLeave", function() btn:SetBackdropBorderColor(unpack(C.tabBorder)) end)
        return btn
    end

    -- Invisible reference frame the boxes sit on, so the four arrows can
    -- anchor to its LEFT/RIGHT/TOP/BOTTOM edges and end up symmetrically
    -- placed around the whole X/Y pair instead of around just one box.
    local row = CreateFrame("Frame", nil, panel)
    row:SetSize(140, 22)
    row:SetPoint("TOP", title, "BOTTOM", 0, -34)

    local xLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    xLabel:SetPoint("LEFT", row, "LEFT", 0, 0)
    xLabel:SetText("X:")
    xLabel:SetTextColor(unpack(C.textWhite))

    local xBoxWrap, xBox = makeBox(panel)
    xBoxWrap:SetPoint("LEFT", xLabel, "RIGHT", 4, 0)

    local yLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    yLabel:SetPoint("LEFT", xBoxWrap, "RIGHT", 12, 0)
    yLabel:SetText("Y:")
    yLabel:SetTextColor(unpack(C.textWhite))

    local yBoxWrap, yBox = makeBox(panel)
    yBoxWrap:SetPoint("LEFT", yLabel, "RIGHT", 4, 0)

    local leftBtn = makeArrow("<")
    leftBtn:SetPoint("RIGHT", row, "LEFT", -8, 0)
    local rightBtn = makeArrow(">")
    rightBtn:SetPoint("LEFT", row, "RIGHT", 8, 0)
    local upBtn = makeArrow("^")
    upBtn:SetPoint("BOTTOM", row, "TOP", 0, 6)
    local downBtn = makeArrow("v")
    downBtn:SetPoint("TOP", row, "BOTTOM", 0, -6)

    local target

    local function refresh()
        if not target then return end
        local x, y = target.getPosition()
        if not xBox:HasFocus() then xBox:SetText(tostring(math.floor(x + 0.5))) end
        if not yBox:HasFocus() then yBox:SetText(tostring(math.floor(y + 0.5))) end
    end

    local function commit()
        if not target then return end
        local x = tonumber(xBox:GetText())
        local y = tonumber(yBox:GetText())
        if x and y then target.setPosition(x, y) end
        refresh()
    end

    local function nudge(dx, dy)
        if not target then return end
        local x, y = target.getPosition()
        target.setPosition(x + dx, y + dy)
        refresh()
    end

    for _, box in ipairs({ xBox, yBox }) do
        box:SetScript("OnEnterPressed", function(self) commit(); self:ClearFocus() end)
        box:SetScript("OnEditFocusLost", commit)
        box:SetScript("OnEscapePressed", function(self) refresh(); self:ClearFocus() end)
    end

    leftBtn:SetScript("OnClick",  function() nudge(-1, 0) end)
    rightBtn:SetScript("OnClick", function() nudge(1, 0) end)
    upBtn:SetScript("OnClick",    function() nudge(0, 1) end)
    downBtn:SetScript("OnClick",  function() nudge(0, -1) end)

    function panel:SetTarget(movable)
        target = movable
        refresh()
    end

    UI.positionEditor = panel
    return panel
end

function UI.OpenPositionEditor(movable, anchorFrame)
    local editor = getPositionEditor()
    editor:SetTarget(movable)
    editor:ClearAllPoints()
    if anchorFrame then
        editor:SetPoint("BOTTOMLEFT", anchorFrame, "TOPRIGHT", 8, 8)
    else
        editor:SetPoint("CENTER", UIParent, "CENTER", 0, 150)
    end
    editor:Show()
end

-- Applies moveBgOpacity / moveBgEnabled to the Move UI dimmed backdrop + grid
-- lines. SetAlpha multiplies on top of each texture's own baked-in vertex
-- alpha (0.55 for the dim, 0.07 per grid line), so 100% reproduces the
-- original fixed look and 0% fades everything out uniformly.
function UI.RefreshMoveOverlay()
    local overlay = UI.moveOverlay
    if not overlay then return end
    if not addon.GetMoveBgEnabled() then
        overlay:Hide()
        return
    end
    if UI.activeMovables then overlay:Show() end
    local mult = addon.GetMoveBgOpacity() / 100
    if overlay.bg then overlay.bg:SetAlpha(mult) end
    for _, line in ipairs(overlay.gridLines or {}) do
        line:SetAlpha(mult)
    end
end

function UI.EnterMoveMode(movables)
    if not movables then
        -- Collect by name rather than building { addon.TTK, ... } directly: a
        -- module addon (Trinkets) can be disabled, and a nil inside a table
        -- constructor silently truncates it for ipairs.
        -- A movable can opt out of Edit Mode entirely via isEnabled() (e.g. the
        -- "Enable Time to Kill" checkbox off) — skip it here so a disabled
        -- feature's box never appears, rather than filtering it out later.
        movables = {}
        for _, name in ipairs(UI.movableNames) do
            local m = addon[name]
            if m and (type(m.isEnabled) ~= "function" or m.isEnabled()) then
                movables[#movables + 1] = m
            end
        end
        -- Runtime-created movables (DataText bars, chat docks) — see
        -- UI.RegisterMovableProvider.
        for _, provider in ipairs(UI.movableProviders) do
            local ok, list = pcall(provider)
            if ok and type(list) == "table" then
                for _, m in ipairs(list) do
                    if m and m.getFrame then movables[#movables + 1] = m end
                end
            end
        end
    end
    UI.activeMovables = movables

    if UI.frame then UI.frame:Hide() end

    -- Each movable's own enterMoveMode() wires up OnMouseDown/OnMouseUp itself
    -- (instant StartMoving() + click-vs-drag detection that opens the precise
    -- position editor), so this loop just shows the frame and hands off.
    --
    -- Whether an element starts parked (unticked in the Modules tab) is
    -- persisted per label via addon.SetEditParked, so a box tucked out of the
    -- way stays tucked away on the next Edit Mode entry instead of resetting
    -- to movable every time.
    for _, m in ipairs(movables) do
        local parked = addon.IsEditParked(UI.MovableLabel(m))
        m.__editEnabled = not parked
        local f = m.getFrame()
        if f then f:Show() end
        if parked then
            m.leaveMoveMode()
        else
            m.enterMoveMode()
        end
    end

    if not UI.moveOverlay then
        local overlay = CreateFrame("Frame", "DrievMoveOverlay", UIParent)
        overlay:SetAllPoints(UIParent)
        overlay:SetFrameStrata("DIALOG")
        -- Click-through: the grid is purely visual. Mouse stays disabled so
        -- camera rotation / character turning still works while editing;
        -- the individual draggable boxes and the lock bar sit on top with
        -- their own mouse handling and remain interactive regardless.
        overlay:EnableMouse(false)

        local bg = overlay:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(WHITE)
        bg:SetVertexColor(0, 0, 0, 0.55)
        overlay.bg = bg

        local W    = UIParent:GetWidth()
        local H    = UIParent:GetHeight()
        local step = 50
        overlay.gridLines = {}
        for i = 0, math.ceil(W / step) do
            local line = overlay:CreateTexture(nil, "ARTWORK")
            line:SetTexture(WHITE)
            line:SetVertexColor(1, 1, 1, 0.07)
            line:SetPoint("TOPLEFT", overlay, "TOPLEFT", i * step, 0)
            line:SetSize(1, H)
            table.insert(overlay.gridLines, line)
        end
        for i = 0, math.ceil(H / step) do
            local line = overlay:CreateTexture(nil, "ARTWORK")
            line:SetTexture(WHITE)
            line:SetVertexColor(1, 1, 1, 0.07)
            line:SetPoint("TOPLEFT", overlay, "TOPLEFT", 0, -(i * step))
            line:SetSize(W, 1)
            table.insert(overlay.gridLines, line)
        end

        UI.moveOverlay = overlay
    end
    UI.RefreshMoveOverlay()

    if not UI.lockBar then
        local bar = CreateFrame("Frame", "DrievLockBar", UIParent, "BackdropTemplate")
        bar:SetSize(280, 400)
        bar:SetFrameStrata("TOOLTIP")
        applyBackdrop(bar, 2, C.panelBG, C.red)

        -- Draggable, and it remembers where it was left. With the grid covering
        -- the screen this box can easily sit on top of whatever you are trying
        -- to position, and being unable to shift it out of the way is the whole
        -- problem.
        bar:SetClampedToScreen(true)
        bar:EnableMouse(true)
        bar:SetMovable(true)
        bar:RegisterForDrag("LeftButton")
        bar:SetScript("OnDragStart", function(self) self:StartMoving() end)
        bar:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            if addon.db and addon.db.settings then
                addon.db.settings.editBarX = self:GetLeft()
                addon.db.settings.editBarY = self:GetBottom()
            end
        end)

        local hint = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hint:SetPoint("TOP", bar, "TOP", 0, -7)
        hint:SetText("Drag this box to move it")
        hint:SetTextColor(unpack(C.textGrey))

        -- Tabs
        bar.tabs, bar.panels = {}, {}

        local settingsTab = createTab(bar, "Settings", 122)
        settingsTab:SetHeight(20)
        settingsTab:SetPoint("TOPLEFT", bar, "TOPLEFT", 8, -24)

        local modulesTab = createTab(bar, "Modules", 122)
        modulesTab:SetHeight(20)
        modulesTab:SetPoint("LEFT", settingsTab, "RIGHT", 4, 0)

        local function makeBarPanel()
            local p = CreateFrame("Frame", nil, bar)
            p:SetPoint("TOPLEFT", settingsTab, "BOTTOMLEFT", 0, -10)
            p:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -8, 42)
            p:Hide()
            return p
        end

        local settingsPanel = makeBarPanel()

        -- The Modules list grows with however many bars/movables exist (14
        -- action bars alone), which can easily run taller than the fixed-size
        -- lock bar — even off the bottom of the screen. Scrollable, unlike the
        -- Settings tab's fixed set of sliders.
        local modulesHost = makeBarPanel()
        modulesHost:Show()
        local modulesShell, modulesPanel, refreshModulesScroll = makeScrollPanel(modulesHost)

        bar.tabs.settings   = settingsTab
        bar.tabs.modules    = modulesTab
        bar.panels.settings = settingsPanel
        bar.panels.modules  = modulesShell

        settingsTab:SetScript("OnClick", function() activateTab(bar.tabs, bar.panels, "settings") end)
        modulesTab:SetScript("OnClick",  function() activateTab(bar.tabs, bar.panels, "modules")  end)

        -- Settings tab
        local boxHeader = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        boxHeader:SetPoint("TOP", settingsPanel, "TOP", 0, -2)
        boxHeader:SetText("Edit Box")
        boxHeader:SetTextColor(unpack(C.red))

        local opacity = buildEditSlider(settingsPanel, {
            label = "Opacity", min = 0, max = 100, suffix = "%",
            get = function() return math.floor(addon.GetEditAlpha() * 100 + 0.5) end,
            set = function(v) addon.SetEditAlpha(v / 100) end,
        })
        opacity:SetPoint("TOP", boxHeader, "BOTTOM", 0, -8)

        local padding = buildEditSlider(settingsPanel, {
            label = "Padding", min = 0, max = 40, suffix = "px",
            get = function() return addon.GetEditPad() end,
            set = function(v) addon.SetEditPad(v) end,
        })
        padding:SetPoint("TOP", opacity, "BOTTOM", 0, -6)

        local border = buildEditSlider(settingsPanel, {
            label = "Border", min = 1, max = 10, suffix = "px",
            get = function() return addon.GetEditBorder() end,
            set = function(v) addon.SetEditBorder(v) end,
        })
        border:SetPoint("TOP", padding, "BOTTOM", 0, -6)

        UI.editSliders = { opacity, padding, border }

        local bgHeader = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        bgHeader:SetPoint("TOP", border, "BOTTOM", 0, -16)
        bgHeader:SetText("Background")
        bgHeader:SetTextColor(unpack(C.red))

        local bgOpacity = buildEditSlider(settingsPanel, {
            label = "Opacity", min = 0, max = 100, suffix = "%",
            get = function() return addon.GetMoveBgOpacity() end,
            set = function(v) addon.SetMoveBgOpacity(v) end,
        })
        bgOpacity:SetPoint("TOP", bgHeader, "BOTTOM", 0, -8)
        UI.bgOpacitySlider = bgOpacity

        local bgToggleBtn = CreateFrame("Button", nil, settingsPanel, "BackdropTemplate")
        bgToggleBtn:SetSize(200, 22)
        bgToggleBtn:SetPoint("TOP", bgOpacity, "BOTTOM", 0, -10)
        applyBackdrop(bgToggleBtn, 1, C.panelDark, C.tabBorder)
        local bgToggleLabel = bgToggleBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        bgToggleLabel:SetPoint("CENTER")
        bgToggleBtn:SetScript("OnEnter", function() bgToggleBtn:SetBackdropBorderColor(unpack(C.red)) end)
        bgToggleBtn:SetScript("OnLeave", function() bgToggleBtn:SetBackdropBorderColor(unpack(C.tabBorder)) end)
        local function refreshBgToggle()
            local on = addon.GetMoveBgEnabled()
            bgToggleLabel:SetText(on and "Grid & Background: ON" or "Grid & Background: OFF")
            bgToggleLabel:SetTextColor(unpack(on and C.textWhite or C.textGrey))
        end
        bgToggleBtn:SetScript("OnClick", function()
            addon.SetMoveBgEnabled(not addon.GetMoveBgEnabled())
            refreshBgToggle()
        end)
        UI.refreshBgToggle = refreshBgToggle

        -- Modules tab
        local modHint = modulesPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        modHint:SetPoint("TOPLEFT", modulesPanel, "TOPLEFT", 4, -2)
        modHint:SetWidth(250); modHint:SetJustifyH("LEFT")
        modHint:SetText("Untick an element to park it, so you can reach whatever sits underneath it.")
        modHint:SetTextColor(unpack(C.textGrey))

        local modRows = {}

        -- Rebuilt on every entry to Edit Mode: which elements exist changes with
        -- what the user has created and which module addons are enabled.
        local function refreshModuleList()
            local list = UI.activeMovables or {}

            while #modRows < #list do
                modRows[#modRows + 1] = createCheckbox(modulesPanel, "", 220)
            end

            for i, m in ipairs(list) do
                local cb = modRows[i]
                cb:ClearAllPoints()
                cb:SetPoint("TOPLEFT", modHint, "BOTTOMLEFT", 0, -8 - (i - 1) * 22)
                cb.text:SetText(UI.MovableLabel(m))
                cb:SetChecked(m.__editEnabled ~= false)
                cb.OnChange = function(_, checked)
                    m.__editEnabled = checked
                    -- Persisted so a parked element stays parked next time
                    -- Edit Mode opens instead of resetting to movable.
                    addon.SetEditParked(UI.MovableLabel(m), not checked)
                    if checked then
                        local f = m.getFrame()
                        if f then f:Show() end
                        m.enterMoveMode()
                    else
                        -- leaveMoveMode clears the element's mouse handlers and
                        -- hides its edit box, which is exactly what stops it
                        -- intercepting clicks meant for what sits beneath.
                        m.leaveMoveMode()
                    end
                end
                cb:Show()
            end
            for i = #list + 1, #modRows do modRows[i]:Hide() end
            if refreshModulesScroll then refreshModulesScroll() end
        end
        UI.RefreshModuleList = refreshModuleList

        -- Lock
        local lockBtn = CreateFrame("Button", nil, bar, "BackdropTemplate")
        lockBtn:SetSize(120, 22)
        lockBtn:SetPoint("BOTTOM", bar, "BOTTOM", 0, 10)
        applyBackdrop(lockBtn, 1, C.panelDark, C.tabBorder)
        local lockLabel = lockBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lockLabel:SetPoint("CENTER")
        lockLabel:SetText("Lock")
        lockLabel:SetTextColor(unpack(C.red))
        lockBtn:SetScript("OnEnter", function() lockLabel:SetTextColor(unpack(C.textWhite)) end)
        lockBtn:SetScript("OnLeave", function() lockLabel:SetTextColor(unpack(C.red)) end)
        lockBtn:SetScript("OnClick", function() UI.ExitMoveMode() end)

        activateTab(bar.tabs, bar.panels, "settings")
        UI.lockBar = bar
    end

    -- Position is applied on every entry rather than only at creation: the
    -- saved coordinates live in addon.db, which may not have loaded at the
    -- moment the frame was first built.
    UI.lockBar:ClearAllPoints()
    local bx = addon.db and addon.db.settings and addon.db.settings.editBarX
    local by = addon.db and addon.db.settings and addon.db.settings.editBarY
    if bx and by then
        UI.lockBar:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", bx, by)
    else
        UI.lockBar:SetPoint("TOP", UIParent, "TOP", 0, -8)
    end
    if UI.editSliders then
        for _, s in ipairs(UI.editSliders) do s:Refresh() end
    end
    if UI.bgOpacitySlider then UI.bgOpacitySlider:Refresh() end
    if UI.refreshBgToggle then UI.refreshBgToggle() end
    if UI.RefreshModuleList then UI.RefreshModuleList() end
    UI.lockBar:Show()
end

function UI.ExitMoveMode()
    for _, m in ipairs(UI.activeMovables or {}) do
        -- m.leaveMoveMode() below clears its own OnMouseDown/OnMouseUp.
        m.savePosition()
        m.leaveMoveMode()
        if m.applyVisibility then m.applyVisibility() end
    end
    UI.activeMovables = nil

    if UI.moveOverlay then UI.moveOverlay:Hide() end
    if UI.lockBar then UI.lockBar:Hide() end
    if UI.positionEditor then UI.positionEditor:Hide() end

    UI.GetFrame():Show()
end

-- ── Shared widget toolkit ────────────────────────────────────────────────────
-- Everything above is file-local, which is invisible to a separate addon. A
-- module addon (Particles, Trinkets) builds its tab with these so its panels
-- look identical to core's, e.g.:
--     local UI = _G.DrievEssentials.UI
--     local w, C = UI.widgets, UI.colors
--     local cb = w.createCheckbox(panel, "Enable thing", 260)
-- Declared at the very end of the file so every helper it references is defined.
-- Core's own code keeps using the plain locals — this table is purely an export.
UI.colors  = C
UI.WHITE   = WHITE
UI.widgets = {
    -- backdrops / buttons
    applyBackdrop       = applyBackdrop,
    flatButton          = flatButton,
    createTab           = createTab,
    createSideTab       = createSideTab,
    -- tab/panel switching
    activateTab         = activateTab,
    selectTab           = selectTab,
    selectSubTab        = selectSubTab,
    -- scrolling
    attachScrollTrack   = attachScrollTrack,
    fitInnerHeight      = fitInnerHeight,
    makeScrollPanel     = makeScrollPanel,
    scrollbarWidth      = SCROLLBAR_W,
    -- inputs
    createCheckbox      = createCheckbox,
    createDropdown      = createDropdown,
    createScrollDropdown= createScrollDropdown,
    buildStepper        = buildStepper,
    buildEditSlider     = buildEditSlider,
    buildSizeStepper    = buildSizeStepper,
    -- dialogs
    showConfirmPopup    = showConfirmPopup,
}
