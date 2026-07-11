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
}

local WHITE = "Interface\\Buttons\\WHITE8x8"

local function applyBackdrop(frame, edgeSize, bg, border)
    frame:SetBackdrop({
        bgFile   = WHITE,
        edgeFile = WHITE,
        edgeSize = edgeSize or 1,
        insets   = { left = 0, right = 0, top = 0, bottom = 0 },
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

local function attachScrollTrack(scroll, trackParent)
    local track = CreateFrame("Frame", nil, trackParent, "BackdropTemplate")
    track:SetWidth(SCROLLBAR_W)
    track:SetPoint("TOPRIGHT",    trackParent, "TOPRIGHT",    -1, -1)
    track:SetPoint("BOTTOMRIGHT", trackParent, "BOTTOMRIGHT", -1,  1)
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
            thumb:SetHeight(trackH)
            thumb:ClearAllPoints()
            thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 1, 0)
            return
        end
        local visibleH = scroll:GetHeight()
        local thumbH   = math.max(16, trackH * visibleH / (visibleH + maxScroll))
        local cur      = scroll:GetVerticalScroll()
        local frac     = cur / maxScroll
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
        bottom = findLowestBottom(child, bottom)
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

    local _, update = attachScrollTrack(scroll, shell)

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

    return shell, inner
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

-- Lazy: only writes into SavedVariables when the panel is actually built.
-- On first init for a raid, pre-checks any boss with `default = true` (the
-- bosses that were hardcoded in the original WeakAura's encounter list).
-- `d.bosses` is healed separately from `d` itself (rather than only on fresh
-- creation) since older or imported profile data can have a particles entry
-- for a raid with no `bosses` sub-table at all — without this, indexing
-- data.bosses in buildRaidPanel below would error for that raid.
local function particlesData(raid)
    addon.db.settings.particles = addon.db.settings.particles or {}
    local d = addon.db.settings.particles[raid.key]
    if not d then
        d = { enabled = false }
        addon.db.settings.particles[raid.key] = d
    end
    if not d.bosses then
        d.bosses = {}
        for _, boss in ipairs(raid.bosses) do
            if boss.default then d.bosses[boss.name] = true end
        end
    end
    return d
end

local function buildRaidPanel(parent, raid)
    local shell, panel = makeScrollPanel(parent)

    -- Read particlesData(raid) live inside each handler (never captured once at
    -- build time) so a profile switch/import — which repoints addon.db — is
    -- reflected on the next OnShow instead of writing to / showing the old
    -- profile's table.
    local enable = createCheckbox(panel, "Enable for " .. raid.label, 260)
    enable:SetPoint("TOPLEFT", 14, -14)
    enable.OnChange = function(_, checked) particlesData(raid).enabled = checked end

    local headline = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    headline:SetPoint("TOPLEFT", enable, "BOTTOMLEFT", 0, -18)
    headline:SetText("Select Bosses")
    headline:SetTextColor(unpack(C.red))

    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", headline, "BOTTOMLEFT", 0, -4)
    desc:SetText("Selected bosses keep particle effects enabled during their encounter (raid baseline is off).")
    desc:SetTextColor(unpack(C.textGrey))

    -- Grid: cap of 4 checkboxes per column; columns grow as needed.
    local gridAnchor = CreateFrame("Frame", nil, panel)
    gridAnchor:SetSize(1, 1)
    gridAnchor:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -14)

    local colWidth, rowHeight = 200, 22
    local bossCBs = {}
    for i, boss in ipairs(raid.bosses) do
        local col = math.floor((i - 1) / 4)
        local row = (i - 1) % 4

        local bossLabel = ((boss.default or boss.note) and raid.key ~= "debug")
            and (boss.name .. " |cfffb2c36(!)|r")
            or boss.name
        local cb = createCheckbox(panel, bossLabel, colWidth - 10)
        cb:SetPoint("TOPLEFT", gridAnchor, "TOPLEFT", col * colWidth, -row * rowHeight)
        cb.OnChange = function(_, checked)
            particlesData(raid).bosses[boss.name] = checked or nil
        end
        bossCBs[boss.name] = cb
    end

    local function refreshPanel()
        local d = particlesData(raid)
        enable:SetChecked(d.enabled)
        for name, cb in pairs(bossCBs) do
            cb:SetChecked(d.bosses[name] == true)
        end
    end
    shell:SetScript("OnShow", refreshPanel)
    refreshPanel()

    return shell
end

local function buildGeneralPanel(parent)
    local shell, panel = makeScrollPanel(parent)

    -- ── Class filter ──────────────────────────────────────────────────────
    local function getClassData()
        addon.db.settings.particles         = addon.db.settings.particles or {}
        addon.db.settings.particles.classes = addon.db.settings.particles.classes or { WARRIOR = true }
        return addon.db.settings.particles.classes
    end

    local classHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    classHeader:SetPoint("TOPLEFT", 14, -14)
    classHeader:SetText("Class Filter")
    classHeader:SetTextColor(unpack(C.red))

    local classDesc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    classDesc:SetPoint("TOPLEFT", classHeader, "BOTTOMLEFT", 0, -4)
    classDesc:SetText("Particle functionality only runs while playing a checked class.")
    classDesc:SetTextColor(unpack(C.textGrey))

    local classGridAnchor = CreateFrame("Frame", nil, panel)
    classGridAnchor:SetSize(1, 1)
    classGridAnchor:SetPoint("TOPLEFT", classDesc, "BOTTOMLEFT", 0, -10)

    local classCBs = {}
    local CLASS_COL_W, CLASS_ROW_H, CLASS_PER_COL = 120, 22, 3
    for i, class in ipairs(addon.CLASSES) do
        local col = math.floor((i - 1) / CLASS_PER_COL)
        local row = (i - 1) % CLASS_PER_COL
        local cb = createCheckbox(panel, class.label, CLASS_COL_W - 10)
        cb:SetPoint("TOPLEFT", classGridAnchor, "TOPLEFT", col * CLASS_COL_W, -row * CLASS_ROW_H)
        cb.OnChange = function(_, checked)
            getClassData()[class.token] = checked or nil
        end
        classCBs[class.token] = cb
    end

    local enableAllBtn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    enableAllBtn:SetSize(175, 24)
    enableAllBtn:SetPoint("TOPLEFT", classGridAnchor, "TOPLEFT", 0, -(CLASS_PER_COL * CLASS_ROW_H) - 14)
    applyBackdrop(enableAllBtn, 1, C.panelDark, C.tabBorder)
    local enableAllLabel = enableAllBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    enableAllLabel:SetPoint("CENTER")
    enableAllLabel:SetText("Enable For All Raids")
    enableAllLabel:SetTextColor(unpack(C.textWhite))
    enableAllBtn:SetScript("OnClick", function()
        for _, raid in ipairs(addon.RAIDS) do
            if raid.key ~= "debug" then
                particlesData(raid).enabled = true
            end
        end
    end)
    enableAllBtn:SetScript("OnEnter", function() enableAllBtn:SetBackdropBorderColor(unpack(C.red)) end)
    enableAllBtn:SetScript("OnLeave", function() enableAllBtn:SetBackdropBorderColor(unpack(C.tabBorder)) end)

    local disableAllBtn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    disableAllBtn:SetSize(175, 24)
    disableAllBtn:SetPoint("LEFT", enableAllBtn, "RIGHT", 8, 0)
    applyBackdrop(disableAllBtn, 1, C.panelDark, C.tabBorder)
    local disableAllLabel = disableAllBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    disableAllLabel:SetPoint("CENTER")
    disableAllLabel:SetText("Disable For All Raids")
    disableAllLabel:SetTextColor(unpack(C.textWhite))
    disableAllBtn:SetScript("OnClick", function()
        for _, raid in ipairs(addon.RAIDS) do
            if raid.key ~= "debug" then
                particlesData(raid).enabled = false
            end
        end
    end)
    disableAllBtn:SetScript("OnEnter", function() disableAllBtn:SetBackdropBorderColor(unpack(C.red)) end)
    disableAllBtn:SetScript("OnLeave", function() disableAllBtn:SetBackdropBorderColor(unpack(C.tabBorder)) end)

    -- ── Encounter particle level ────────────────────────────────────────────
    local headline = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    headline:SetPoint("TOPLEFT", enableAllBtn, "BOTTOMLEFT", 0, -24)
    headline:SetText("Encounter Particle Level")
    headline:SetTextColor(unpack(C.red))

    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", headline, "BOTTOMLEFT", 0, -4)
    desc:SetText("Particle density used when particles are enabled for a boss encounter.\nRaids always use 0 between encounters; outside raids keeps your system default.")
    desc:SetTextColor(unpack(C.textGrey))

    local rowLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    rowLabel:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -22)
    rowLabel:SetText("Encounter density:")
    rowLabel:SetTextColor(unpack(C.textWhite))

    local function getData()
        addon.db.settings.particles         = addon.db.settings.particles or {}
        addon.db.settings.particles.general = addon.db.settings.particles.general or { encounterDensity = 3 }
        return addon.db.settings.particles.general
    end

    local btnMinus = CreateFrame("Button", nil, panel, "BackdropTemplate")
    btnMinus:SetSize(22, 22)
    btnMinus:SetPoint("LEFT", rowLabel, "RIGHT", 12, 0)
    applyBackdrop(btnMinus, 1, C.panelDark, C.tabBorder)
    local minusLabel = btnMinus:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    minusLabel:SetPoint("CENTER")
    minusLabel:SetText("-")
    minusLabel:SetTextColor(unpack(C.textWhite))

    local valDisplay = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    valDisplay:SetPoint("CENTER", btnMinus, "RIGHT", 18, 0)
    valDisplay:SetTextColor(unpack(C.red))

    local btnPlus = CreateFrame("Button", nil, panel, "BackdropTemplate")
    btnPlus:SetSize(22, 22)
    btnPlus:SetPoint("LEFT", btnMinus, "RIGHT", 36, 0)
    applyBackdrop(btnPlus, 1, C.panelDark, C.tabBorder)
    local plusLabel = btnPlus:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    plusLabel:SetPoint("CENTER")
    plusLabel:SetText("+")
    plusLabel:SetTextColor(unpack(C.textWhite))

    local rangeNote = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rangeNote:SetPoint("LEFT", btnPlus, "RIGHT", 10, 0)
    rangeNote:SetText("(1 - 5)")
    rangeNote:SetTextColor(unpack(C.textDim))

    local function refreshDisplay()
        valDisplay:SetText(tostring(getData().encounterDensity))
        local classData = getClassData()
        for token, cb in pairs(classCBs) do
            cb:SetChecked(classData[token] == true)
        end
    end

    local function adjustValue(delta)
        local d = getData()
        d.encounterDensity = math.max(1, math.min(5, d.encounterDensity + delta))
        refreshDisplay()
    end

    btnMinus:SetScript("OnClick", function() adjustValue(-1) end)
    btnMinus:SetScript("OnEnter", function() btnMinus:SetBackdropBorderColor(unpack(C.red)) end)
    btnMinus:SetScript("OnLeave", function() btnMinus:SetBackdropBorderColor(unpack(C.tabBorder)) end)

    btnPlus:SetScript("OnClick", function() adjustValue(1) end)
    btnPlus:SetScript("OnEnter", function() btnPlus:SetBackdropBorderColor(unpack(C.red)) end)
    btnPlus:SetScript("OnLeave", function() btnPlus:SetBackdropBorderColor(unpack(C.tabBorder)) end)

    shell:SetScript("OnShow", refreshDisplay)

    return shell
end

local function buildParticlesPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()

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

    local generalTab = createTab(subBar, "General", 70)
    generalTab:SetHeight(22)
    generalTab:SetPoint("LEFT", 4, 0)
    generalTab:SetScript("OnClick", function() selectSubTab(panel, "general") end)
    panel.subTabs["general"]   = generalTab
    panel.subPanels["general"] = buildGeneralPanel(subContent)

    local prev = generalTab
    for _, raid in ipairs(addon.RAIDS) do
        local tab = createTab(subBar, raid.label, 70)
        tab:SetHeight(22)
        tab:SetPoint("LEFT", prev, "RIGHT", 4, 0)
        tab:SetScript("OnClick", function() selectSubTab(panel, raid.key) end)
        panel.subTabs[raid.key]   = tab
        panel.subPanels[raid.key] = buildRaidPanel(subContent, raid)
        prev = tab
    end

    selectSubTab(panel, "general")
    return panel
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

    local namesCheck = createCheckbox(panel, "Disable Names in Raid", 260)
    namesCheck:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -18)
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

    local moveBtn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    moveBtn:SetSize(140, 22)
    moveBtn:SetPoint("TOPLEFT", enableCB, "BOTTOMLEFT", 0, -14)
    applyBackdrop(moveBtn, 1, C.panelDark, C.tabBorder)
    local moveBtnLabel = moveBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    moveBtnLabel:SetPoint("CENTER")
    moveBtnLabel:SetText("Move / Resize")
    moveBtnLabel:SetTextColor(unpack(C.textWhite))
    moveBtn:SetScript("OnEnter", function() moveBtn:SetBackdropBorderColor(unpack(C.red)) end)
    moveBtn:SetScript("OnLeave", function() moveBtn:SetBackdropBorderColor(unpack(C.tabBorder)) end)
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
    btn._built = false

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
        local n = #btn._rows
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
        local maxScroll = math.max(0, (#btn._rows - MAX_VIS) * ITEM_H)
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

    local function build()
        if btn._built then return end
        btn._built = true
        local items = getItems()
        for i, name in ipairs(items) do
            local row = CreateFrame("Button", nil, sc)
            row:SetSize(CONTENT_W, ITEM_H)
            row:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -(i - 1) * ITEM_H)
            row._name = name

            local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            lbl:SetPoint("LEFT", 4, 0)
            lbl:SetPoint("RIGHT", -4, 0)
            lbl:SetJustifyH("LEFT")
            lbl:SetText(name)
            lbl:SetTextColor(unpack(C.textGrey))
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

            tinsert(btn._rows, row)
        end
        sc:SetHeight(math.max(#items * ITEM_H, 1))
    end

    btn:SetScript("OnClick", function()
        if popup:IsShown() then close(); return end

        build()
        refreshColors()

        local visH = math.min(#btn._rows, MAX_VIS) * ITEM_H
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
            for i, row in ipairs(btn._rows) do
                if row._name == btn._value then
                    local maxScroll = math.max(0, (#btn._rows - MAX_VIS) * ITEM_H)
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
    local moveBtn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    moveBtn:SetSize(80, 22)
    moveBtn:SetPoint("TOPLEFT", enableCB, "BOTTOMLEFT", 0, -10)
    applyBackdrop(moveBtn, 1, C.panelDark, C.tabBorder)
    local moveBtnLabel = moveBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    moveBtnLabel:SetPoint("CENTER")
    moveBtnLabel:SetText("Move")
    moveBtnLabel:SetTextColor(unpack(C.textWhite))
    moveBtn:SetScript("OnEnter", function() moveBtn:SetBackdropBorderColor(unpack(C.red)) end)
    moveBtn:SetScript("OnLeave", function() moveBtn:SetBackdropBorderColor(unpack(C.tabBorder)) end)
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

    local sizeMinus = CreateFrame("Button", nil, panel, "BackdropTemplate")
    sizeMinus:SetSize(22, 22)
    sizeMinus:SetPoint("LEFT", sizeLabel, "RIGHT", 10, 0)
    applyBackdrop(sizeMinus, 1, C.panelDark, C.tabBorder)
    local sizeMinusLbl = sizeMinus:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sizeMinusLbl:SetPoint("CENTER")
    sizeMinusLbl:SetText("-")
    sizeMinusLbl:SetTextColor(unpack(C.textWhite))

    local sizeDisplay = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    sizeDisplay:SetPoint("CENTER", sizeMinus, "RIGHT", 18, 0)
    sizeDisplay:SetTextColor(unpack(C.red))

    local sizePlus = CreateFrame("Button", nil, panel, "BackdropTemplate")
    sizePlus:SetSize(22, 22)
    sizePlus:SetPoint("LEFT", sizeMinus, "RIGHT", 36, 0)
    applyBackdrop(sizePlus, 1, C.panelDark, C.tabBorder)
    local sizePlusLbl = sizePlus:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sizePlusLbl:SetPoint("CENTER")
    sizePlusLbl:SetText("+")
    sizePlusLbl:SetTextColor(unpack(C.textWhite))

    local function refreshPanel()
        local d  = getTTKData()
        local fn = d.fontName or "Friz Quadrata TT"
        debugCB:SetChecked(getDebugData().enabled or false)
        minimapHideCB:SetChecked(addon.db.minimap.hide or false)
        enableCB:SetChecked(d.enabled or false)
        bossOnlyCB:SetChecked(d.bossOnly or false)
        sizeDisplay:SetText(tostring(d.fontSize or 24))
        fontDropdown:setValue(fn)
    end

    sizeMinus:SetScript("OnClick", function()
        local d = getTTKData()
        d.fontSize = math.max(10, (d.fontSize or 24) - 1)
        sizeDisplay:SetText(tostring(d.fontSize))
        if addon.TTK then addon.TTK.applyFont() end
    end)
    sizeMinus:SetScript("OnEnter", function() sizeMinus:SetBackdropBorderColor(unpack(C.red)) end)
    sizeMinus:SetScript("OnLeave", function() sizeMinus:SetBackdropBorderColor(unpack(C.tabBorder)) end)

    sizePlus:SetScript("OnClick", function()
        local d = getTTKData()
        d.fontSize = math.min(60, (d.fontSize or 24) + 1)
        sizeDisplay:SetText(tostring(d.fontSize))
        if addon.TTK then addon.TTK.applyFont() end
    end)
    sizePlus:SetScript("OnEnter", function() sizePlus:SetBackdropBorderColor(unpack(C.red)) end)
    sizePlus:SetScript("OnLeave", function() sizePlus:SetBackdropBorderColor(unpack(C.tabBorder)) end)

    shell:SetScript("OnShow", refreshPanel)

    return shell
end

-- ── Trinkets tab ──────────────────────────────────────────────────────────────

-- Drag-to-reorder for the pooled list rows used by the menu-order and queue
-- sort lists. The row pool is index-fixed and re-skinned on each rebuild, so we
-- track the dragged ITEM by value (ctx.dragId), not by row frame: as the cursor
-- crosses row slots we live-reorder the backing list, so the row under the
-- cursor always shows the dragged item and selectRow keeps it highlighted.
-- ctx = { getList, selectRow, dragUpdate, onReorder }.
local function attachRowDrag(row, rowIndex, ctx)
    row:RegisterForDrag("LeftButton")
    row:SetScript("OnDragStart", function(self)
        local id = ctx.getList()[rowIndex]
        if not id then return end
        ctx.dragId = id
        ctx.selectRow(rowIndex)
        self:SetScript("OnUpdate", function() ctx.dragUpdate() end)
    end)
    row:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        if ctx.dragId then
            ctx.dragId = nil
            if ctx.onReorder then ctx.onReorder() end
        end
    end)
end

-- Shared per-frame drag handler body. Computes the list slot under the cursor,
-- auto-scrolls near the viewport edges, and live-moves the dragged item there.
-- All the list-specific frames/functions come in via `p`.
local function runRowDrag(ctx, p)
    if not ctx.dragId then return end
    local list = p.getList()
    local curIdx
    for k, v in ipairs(list) do if v == ctx.dragId then curIdx = k; break end end
    if not curIdx then return end

    local cursorY = select(2, GetCursorPosition()) / p.sf:GetEffectiveScale()

    -- Auto-scroll when the cursor nears the top/bottom edge of the viewport.
    local sfTop, sfBottom = p.sf:GetTop(), p.sf:GetBottom()
    local visRows   = math.floor(p.LIST_H / p.ROW_H)
    local maxScroll = math.max(0, (#list - visRows) * p.ROW_H)
    if sfTop and cursorY > sfTop - 4 then
        p.sf:SetVerticalScroll(math.max(0, p.sf:GetVerticalScroll() - 6)); p.updateThumb()
    elseif sfBottom and cursorY < sfBottom + 4 then
        p.sf:SetVerticalScroll(math.min(maxScroll, p.sf:GetVerticalScroll() + 6)); p.updateThumb()
    end

    local top = p.sc:GetTop()
    if not top then return end
    local targetIdx = math.max(1, math.min(#list, math.floor((top - cursorY) / p.ROW_H) + 1))
    if targetIdx ~= curIdx then
        table.remove(list, curIdx)
        table.insert(list, targetIdx, ctx.dragId)
        p.rebuildRows()
        p.selectRow(targetIdx)
    end
end

local function buildMenuOrderList(parent)
    -- Reorderable list of ALL known trinket IDs stored in d.menuOrder.
    -- Controls the display order in the bag menu.
    local LIST_W = 310
    local LIST_H = 240
    local ROW_H  = 26
    local SB_W   = 10

    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(LIST_W + SB_W + 4 + 80, LIST_H + 60)

    local header = container:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetText("Menu Display Order")
    header:SetTextColor(unpack(C.red))

    local desc = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    desc:SetText("Drag items to reorder. New trinkets are added automatically when scanned.")
    desc:SetTextColor(unpack(C.textGrey))

    local listBG = CreateFrame("Frame", nil, container, "BackdropTemplate")
    listBG:SetSize(LIST_W, LIST_H)
    listBG:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -10)
    applyBackdrop(listBG, 1, C.panelDeep, C.tabBorder)

    local sf = CreateFrame("ScrollFrame", nil, listBG)
    sf:SetPoint("TOPLEFT", 1, -1)
    sf:SetSize(LIST_W - SB_W - 3, LIST_H - 2)

    local sc = CreateFrame("Frame", nil, sf)
    sc:SetWidth(LIST_W - SB_W - 3)
    sf:SetScrollChild(sc)

    local track = CreateFrame("Frame", nil, listBG, "BackdropTemplate")
    track:SetWidth(SB_W)
    track:SetPoint("TOPRIGHT",    listBG, "TOPRIGHT",    -1, -1)
    track:SetPoint("BOTTOMRIGHT", listBG, "BOTTOMRIGHT", -1,  1)
    applyBackdrop(track, 1, C.panelDark, C.tabBorder)

    local thumb = CreateFrame("Button", nil, track, "BackdropTemplate")
    thumb:SetWidth(SB_W - 2)
    applyBackdrop(thumb, 1, C.tabIdle, C.tabBorder)
    thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 1, 0)

    local rows    = {}
    local selected = nil
    local dragCtx = {}   -- populated after rebuildRows/selectRow exist

    local function getData()
        return addon.Trinkets and addon.Trinkets.getData and addon.Trinkets.getData()
    end

    local function getList()
        local d = getData()
        return d and d.menuOrder or {}
    end

    local function updateThumb()
        local n = #rows
        if n == 0 then track:Hide(); return end
        local visRows = math.floor(LIST_H / ROW_H)
        if n <= visRows then track:Hide(); return end
        track:Show()
        local tH = track:GetHeight()
        if tH <= 0 then return end
        local thumbH    = math.max(16, tH * visRows / n)
        local maxScroll = (n - visRows) * ROW_H
        local cur       = sf:GetVerticalScroll()
        local frac      = maxScroll > 0 and (cur / maxScroll) or 0
        thumb:SetHeight(thumbH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 1, -(frac * (tH - thumbH)))
    end

    listBG:EnableMouseWheel(true)
    listBG:SetScript("OnMouseWheel", function(_, d)
        local n       = #rows
        local visRows = math.floor(LIST_H / ROW_H)
        local maxScroll = math.max(0, (n - visRows) * ROW_H)
        sf:SetVerticalScroll(math.max(0, math.min(sf:GetVerticalScroll() - d * ROW_H * 2, maxScroll)))
        updateThumb()
    end)

    local function makeBtn(label, y)
        local b = CreateFrame("Button", nil, container, "BackdropTemplate")
        b:SetSize(72, 22)
        b:SetPoint("TOPLEFT", listBG, "TOPRIGHT", 6, -y)
        applyBackdrop(b, 1, C.panelDark, C.tabBorder)
        local lbl = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("CENTER"); lbl:SetText(label); lbl:SetTextColor(unpack(C.textWhite))
        b:SetScript("OnEnter", function() b:SetBackdropBorderColor(unpack(C.red)) end)
        b:SetScript("OnLeave", function() b:SetBackdropBorderColor(unpack(C.tabBorder)) end)
        return b
    end
    local btnTop     = makeBtn("Top",     4)
    local btnUp      = makeBtn("Up",      30)
    local btnDown    = makeBtn("Down",    56)
    local btnBottom  = makeBtn("Bottom",  82)
    local btnRemove  = makeBtn("Remove",  112)
    local btnReverse = makeBtn("Reverse", 142)

    local function selectRow(idx)
        selected = idx and getList()[idx] or nil
        for i, row in ipairs(rows) do
            if i == idx then
                applyBackdrop(row, 1, C.panelDark, C.red)
            else
                applyBackdrop(row, 1, C.panelDeep, { 0, 0, 0, 0 })
            end
        end
        local n = #getList()
        btnTop:SetEnabled(idx and idx > 1 or false)
        btnUp:SetEnabled(idx and idx > 1 or false)
        btnDown:SetEnabled(idx and idx < n or false)
        btnBottom:SetEnabled(idx and idx < n or false)
        btnRemove:SetEnabled(idx ~= nil)
    end

    local rebuildRows
    rebuildRows = function()
        local list = getList()
        local n    = #list
        while #rows < n do
            local i = #rows + 1
            local row = CreateFrame("Button", nil, sc, "BackdropTemplate")
            row:SetSize(LIST_W - SB_W - 5, ROW_H - 2)
            row:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -(i-1)*ROW_H)
            applyBackdrop(row, 1, C.panelDeep, { 0, 0, 0, 0 })
            local ico = row:CreateTexture(nil, "ARTWORK")
            ico:SetSize(18, 18)
            ico:SetPoint("LEFT", 4, 0)
            ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            row.ico = ico
            local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            lbl:SetPoint("LEFT", ico, "RIGHT", 4, 0)
            lbl:SetPoint("RIGHT", -6, 0)
            lbl:SetJustifyH("LEFT")
            lbl:SetTextColor(unpack(C.textWhite))
            row.lbl = lbl
            row:SetScript("OnClick", function() selectRow(i) end)
            row:SetScript("OnEnter", function(self)
                if getList()[i] ~= selected then
                    self:SetBackdropBorderColor(unpack(C.tabBorder))
                end
            end)
            row:SetScript("OnLeave", function(self)
                if getList()[i] ~= selected then
                    self:SetBackdropBorderColor(0, 0, 0, 0)
                end
            end)
            attachRowDrag(row, i, dragCtx)
            rows[i] = row
        end
        for i = 1, #rows do
            local row = rows[i]
            if i <= n then
                local id   = list[i]
                local name, _, _, _, _, _, _, _, _, tex = GetItemInfo(tonumber(id) or id)
                row.ico:SetTexture(tex or "")
                row.lbl:SetText(i .. ". " .. (name or ("[" .. id .. "]")))
                row:Show()
            else
                row:Hide()
            end
        end
        sc:SetHeight(math.max(n * ROW_H, 1))
        updateThumb()
    end

    local function liveMenuRebuild()
        if addon.Trinkets and addon.Trinkets.buildMenu then
            if _G["DrievTrinketMenu"] and _G["DrievTrinketMenu"]:IsShown() then
                addon.Trinkets.buildMenu()
            end
        end
    end

    -- Wire up drag-to-reorder (rows call attachRowDrag with this ctx).
    dragCtx.getList    = getList
    dragCtx.selectRow  = selectRow
    dragCtx.onReorder  = liveMenuRebuild
    dragCtx.dragUpdate = function()
        runRowDrag(dragCtx, {
            getList = getList, selectRow = selectRow, rebuildRows = rebuildRows,
            updateThumb = updateThumb, sf = sf, sc = sc, ROW_H = ROW_H, LIST_H = LIST_H,
        })
    end

    local function moveSelected(dir)
        if not selected then return end
        local list = getList()
        local idx
        for i, id in ipairs(list) do if id == selected then idx = i; break end end
        if not idx then return end
        local target
        if     dir == "top"    then target = 1
        elseif dir == "up"     then target = idx - 1
        elseif dir == "down"   then target = idx + 1
        elseif dir == "bottom" then target = #list
        end
        if not target or target < 1 or target > #list then return end
        table.remove(list, idx)
        table.insert(list, target, selected)
        rebuildRows()
        selectRow(target)
        liveMenuRebuild()
    end

    btnTop:SetScript("OnClick",    function() moveSelected("top") end)
    btnUp:SetScript("OnClick",     function() moveSelected("up") end)
    btnDown:SetScript("OnClick",   function() moveSelected("down") end)
    btnBottom:SetScript("OnClick", function() moveSelected("bottom") end)
    btnRemove:SetScript("OnClick", function()
        if not selected then return end
        local list = getList()
        for i, id in ipairs(list) do
            if id == selected then table.remove(list, i); break end
        end
        selected = nil
        rebuildRows()
        selectRow(nil)
        liveMenuRebuild()
    end)
    btnReverse:SetScript("OnClick", function()
        local list = getList()
        local n = #list
        for i = 1, math.floor(n / 2) do
            list[i], list[n - i + 1] = list[n - i + 1], list[i]
        end
        selected = nil
        rebuildRows()
        selectRow(nil)
        liveMenuRebuild()
    end)

    local refreshBtn = CreateFrame("Button", nil, container, "BackdropTemplate")
    refreshBtn:SetSize(LIST_W, 22)
    refreshBtn:SetPoint("TOPLEFT", listBG, "BOTTOMLEFT", 0, -8)
    applyBackdrop(refreshBtn, 1, C.panelDark, C.tabBorder)
    local refreshLbl = refreshBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    refreshLbl:SetPoint("CENTER")
    refreshLbl:SetText("Refresh (scan bags for new trinkets)")
    refreshLbl:SetTextColor(unpack(C.textWhite))
    refreshBtn:SetScript("OnEnter", function() refreshBtn:SetBackdropBorderColor(unpack(C.red)) end)
    refreshBtn:SetScript("OnLeave", function() refreshBtn:SetBackdropBorderColor(unpack(C.tabBorder)) end)
    refreshBtn:SetScript("OnClick", function()
        if addon.Trinkets then addon.Trinkets.populateMenuOrder() end
        selected = nil
        rebuildRows()
        selectRow(nil)
    end)

    function container:Refresh()
        selected = nil
        rebuildRows()
        selectRow(nil)
    end

    return container
end

local function buildSortList(parent, which)
    -- Returns a frame containing a scrollable sort list for queue slot `which`.
    -- Exposes :Refresh() to rebuild from saved data.
    local LIST_W  = 310
    local LIST_H  = 240
    local ROW_H   = 26
    local SB_W    = 10

    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(LIST_W + SB_W + 4 + 80, LIST_H + 30)  -- extra for buttons

    local header = container:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetText(which == 0 and "Top Slot Queue" or "Bottom Slot Queue")
    header:SetTextColor(unpack(C.red))

    local enableCB = createCheckbox(container, "Enable Auto Queue", 200)
    enableCB:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6)
    enableCB.OnChange = function(_, checked)
        local d = addon.Trinkets and addon.Trinkets.getData and addon.Trinkets.getData()
        if d then d.queue[which].enabled = checked end
        if addon.Trinkets and addon.Trinkets.updateQueueIndicators then
            addon.Trinkets.updateQueueIndicators()
        end
    end

    -- Scrollable list
    local listBG = CreateFrame("Frame", nil, container, "BackdropTemplate")
    listBG:SetSize(LIST_W, LIST_H)
    listBG:SetPoint("TOPLEFT", enableCB, "BOTTOMLEFT", 0, -10)
    applyBackdrop(listBG, 1, C.panelDeep, C.tabBorder)

    local sf = CreateFrame("ScrollFrame", nil, listBG)
    sf:SetPoint("TOPLEFT", 1, -1)
    sf:SetSize(LIST_W - SB_W - 3, LIST_H - 2)

    local sc = CreateFrame("Frame", nil, sf)
    sc:SetWidth(LIST_W - SB_W - 3)
    sf:SetScrollChild(sc)

    local track = CreateFrame("Frame", nil, listBG, "BackdropTemplate")
    track:SetWidth(SB_W)
    track:SetPoint("TOPRIGHT",    listBG, "TOPRIGHT",    -1, -1)
    track:SetPoint("BOTTOMRIGHT", listBG, "BOTTOMRIGHT", -1,  1)
    applyBackdrop(track, 1, C.panelDark, C.tabBorder)

    local thumb = CreateFrame("Button", nil, track, "BackdropTemplate")
    thumb:SetWidth(SB_W - 2)
    applyBackdrop(thumb, 1, C.tabIdle, C.tabBorder)
    thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 1, 0)

    local rows = {}
    local selected = nil
    local dragCtx = {}   -- populated after rebuildRows/selectRow exist

    local function updateThumb()
        local n = #rows
        if n == 0 then track:Hide(); return end
        local visRows = math.floor(LIST_H / ROW_H)
        if n <= visRows then track:Hide(); return end
        track:Show()
        local tH = track:GetHeight()
        if tH <= 0 then return end
        local thumbH = math.max(16, tH * visRows / n)
        local maxScroll = (n - visRows) * ROW_H
        local cur = sf:GetVerticalScroll()
        local frac = maxScroll > 0 and (cur / maxScroll) or 0
        thumb:SetHeight(thumbH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 1, -(frac * (tH - thumbH)))
    end

    listBG:EnableMouseWheel(true)
    listBG:SetScript("OnMouseWheel", function(_, d)
        local n = #rows
        local visRows = math.floor(LIST_H / ROW_H)
        local maxScroll = math.max(0, (n - visRows) * ROW_H)
        sf:SetVerticalScroll(math.max(0, math.min(sf:GetVerticalScroll() - d * ROW_H * 2, maxScroll)))
        updateThumb()
    end)

    -- Move buttons (right side of list)
    local btnX = LIST_W + 6
    local function makeBtn(label, y)
        local b = CreateFrame("Button", nil, container, "BackdropTemplate")
        b:SetSize(72, 22)
        b:SetPoint("TOPLEFT", listBG, "TOPRIGHT", 6, -y)
        applyBackdrop(b, 1, C.panelDark, C.tabBorder)
        local lbl = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("CENTER"); lbl:SetText(label); lbl:SetTextColor(unpack(C.textWhite))
        b:SetScript("OnEnter", function() b:SetBackdropBorderColor(unpack(C.red)) end)
        b:SetScript("OnLeave", function() b:SetBackdropBorderColor(unpack(C.tabBorder)) end)
        return b
    end
    local btnTop    = makeBtn("Top",    4)
    local btnUp     = makeBtn("Up",     30)
    local btnDown   = makeBtn("Down",   56)
    local btnBottom = makeBtn("Bottom", 82)

    -- Priority checkbox shown below list when a row is selected
    local priorityCB = createCheckbox(container, "Priority (equip even if not on CD)", LIST_W)
    priorityCB:SetPoint("TOPLEFT", listBG, "BOTTOMLEFT", 0, -8)
    priorityCB:Hide()
    priorityCB.OnChange = function(_, checked)
        if not selected then return end
        local d = addon.Trinkets and addon.Trinkets.getData and addon.Trinkets.getData()
        if not d then return end
        d.queue[which].stats = d.queue[which].stats or {}
        d.queue[which].stats[selected] = d.queue[which].stats[selected] or {}
        d.queue[which].stats[selected].priority = checked or nil
        if not next(d.queue[which].stats[selected]) then
            d.queue[which].stats[selected] = nil
        end
    end

    local function getData()
        return addon.Trinkets and addon.Trinkets.getData and addon.Trinkets.getData()
    end

    local function getList()
        local d = getData()
        return d and d.queue[which].sort or {}
    end

    local function selectRow(idx)
        selected = idx and getList()[idx] or nil
        for i, row in ipairs(rows) do
            if i == idx then
                applyBackdrop(row, 1, C.panelDark, C.red)
            else
                applyBackdrop(row, 1, C.panelDeep, { 0, 0, 0, 0 })
            end
        end
        if selected then
            local d = getData()
            local stats = d and d.queue[which].stats and d.queue[which].stats[selected]
            priorityCB:SetChecked(stats and stats.priority and true or false)
            priorityCB:Show()
        else
            priorityCB:Hide()
        end
        -- enable/disable buttons
        local n = #getList()
        btnTop:SetEnabled(idx and idx > 1 or false)
        btnUp:SetEnabled(idx and idx > 1 or false)
        btnDown:SetEnabled(idx and idx < n or false)
        btnBottom:SetEnabled(idx and idx < n or false)
    end

    local function rebuildRows()
        local list = getList()
        local n = #list
        -- Grow or shrink the pool of row frames
        while #rows < n do
            local i = #rows + 1
            local row = CreateFrame("Button", nil, sc, "BackdropTemplate")
            row:SetSize(LIST_W - SB_W - 5, ROW_H - 2)
            row:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -(i-1)*ROW_H)
            applyBackdrop(row, 1, C.panelDeep, { 0, 0, 0, 0 })
            local ico = row:CreateTexture(nil, "ARTWORK")
            ico:SetSize(18, 18)
            ico:SetPoint("LEFT", 4, 0)
            ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            row.ico = ico
            local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            lbl:SetPoint("LEFT", ico, "RIGHT", 4, 0)
            lbl:SetPoint("RIGHT", -6, 0)
            lbl:SetJustifyH("LEFT")
            lbl:SetTextColor(unpack(C.textWhite))
            row.lbl = lbl
            row:SetScript("OnClick", function() selectRow(i) end)
            row:SetScript("OnEnter", function(self)
                if getList()[i] ~= selected then
                    self:SetBackdropBorderColor(unpack(C.tabBorder))
                end
            end)
            row:SetScript("OnLeave", function(self)
                if getList()[i] ~= selected then
                    self:SetBackdropBorderColor(0, 0, 0, 0)
                end
            end)
            attachRowDrag(row, i, dragCtx)
            rows[i] = row
        end
        for i = 1, #rows do
            local row = rows[i]
            if i <= n then
                local id = list[i]
                local name, _, _, _, _, _, _, _, _, tex = GetItemInfo(tonumber(id) or id)
                if row.ico then row.ico:SetTexture(tex or "") end
                row.lbl:SetText(i .. ". " .. (name or ("[" .. id .. "]")))
                row:Show()
            else
                row:Hide()
            end
        end
        sc:SetHeight(math.max(n * ROW_H, 1))
        updateThumb()
    end

    -- Wire up drag-to-reorder (rows call attachRowDrag with this ctx).
    dragCtx.getList    = getList
    dragCtx.selectRow  = selectRow
    dragCtx.dragUpdate = function()
        runRowDrag(dragCtx, {
            getList = getList, selectRow = selectRow, rebuildRows = rebuildRows,
            updateThumb = updateThumb, sf = sf, sc = sc, ROW_H = ROW_H, LIST_H = LIST_H,
        })
    end

    local function moveSelected(dir)
        if not selected then return end
        local list = getList()
        local idx
        for i, id in ipairs(list) do
            if id == selected then idx = i; break end
        end
        if not idx then return end
        local target
        if dir == "top"    then target = 1
        elseif dir == "up" then target = idx - 1
        elseif dir == "down" then target = idx + 1
        elseif dir == "bottom" then target = #list
        end
        if not target or target < 1 or target > #list then return end
        table.remove(list, idx)
        table.insert(list, target, selected)
        rebuildRows()
        selectRow(target)
    end

    btnTop:SetScript("OnClick",    function() moveSelected("top") end)
    btnUp:SetScript("OnClick",     function() moveSelected("up") end)
    btnDown:SetScript("OnClick",   function() moveSelected("down") end)
    btnBottom:SetScript("OnClick", function() moveSelected("bottom") end)

    local refreshBtn = CreateFrame("Button", nil, container, "BackdropTemplate")
    refreshBtn:SetSize(LIST_W, 22)
    refreshBtn:SetPoint("TOPLEFT", priorityCB, "BOTTOMLEFT", 0, -8)
    applyBackdrop(refreshBtn, 1, C.panelDark, C.tabBorder)
    local refreshLbl = refreshBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    refreshLbl:SetPoint("CENTER")
    refreshLbl:SetText("Refresh (scan bags for new trinkets)")
    refreshLbl:SetTextColor(unpack(C.textWhite))
    refreshBtn:SetScript("OnEnter", function() refreshBtn:SetBackdropBorderColor(unpack(C.red)) end)
    refreshBtn:SetScript("OnLeave", function() refreshBtn:SetBackdropBorderColor(unpack(C.tabBorder)) end)
    refreshBtn:SetScript("OnClick", function()
        if addon.Trinkets then addon.Trinkets.populateQueueSorts() end
        selected = nil
        rebuildRows()
        selectRow(nil)
    end)

    function container:Refresh()
        local d = getData()
        if d then
            enableCB:SetChecked(d.queue[which].enabled)
        end
        selected = nil
        rebuildRows()
        selectRow(nil)
    end

    container:Refresh()
    return container
end

local function buildTrinketsPanel(parent)
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

    -- ── Display sub-panel (scrollable, themed scrollbar) ─────────────────────
    local displayShell = CreateFrame("Frame", nil, subContent)
    displayShell:SetAllPoints()
    displayShell:Hide()

    local displayScroll = CreateFrame("ScrollFrame", nil, displayShell)
    displayScroll:SetPoint("TOPLEFT", 0, 0)
    displayScroll:SetPoint("BOTTOMRIGHT", -(SCROLLBAR_W + 6), 0)

    local displayPanel = CreateFrame("Frame", nil, displayScroll)
    displayPanel:SetHeight(700)
    displayScroll:SetScrollChild(displayPanel)

    local _, updateDisplayThumb = attachScrollTrack(displayScroll, displayShell)
    -- See makeScrollPanel's identical refreshScroll/HookScript for why this is
    -- needed: a fixed height taller than the real content always reports room
    -- to scroll, and GetVerticalScrollRange() isn't reliable until actually
    -- shown — so fit to real content and force a recompute on every show
    -- instead of waiting for the next scroll/resize.
    local function refreshDisplayScroll()
        fitInnerHeight(displayPanel, displayScroll)
        updateDisplayThumb()
    end
    displayScroll:SetScript("OnSizeChanged", function(self, w)
        displayPanel:SetWidth(w)
        refreshDisplayScroll()
    end)
    displayPanel:SetScript("OnSizeChanged", updateDisplayThumb)
    displayShell:HookScript("OnShow", function()
        refreshDisplayScroll()
        C_Timer.After(0, refreshDisplayScroll)
    end)

    local function getTData()
        return addon.db and addon.db.settings and addon.db.settings.trinkets
    end

    -- ── Header ────────────────────────────────────────────────────────────────
    local dispHeader = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    dispHeader:SetPoint("TOPLEFT", 14, -14)
    dispHeader:SetText("Trinket Display")
    dispHeader:SetTextColor(unpack(C.red))

    local dispDesc = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dispDesc:SetPoint("TOPLEFT", dispHeader, "BOTTOMLEFT", 0, -4)
    dispDesc:SetText("Shows your two equipped trinket slots as clickable buttons.\nLeft-click uses the trinket. Hover to open the bag menu for swapping.")
    dispDesc:SetTextColor(unpack(C.textGrey))

    local enableCB = createCheckbox(displayPanel, "Enable Trinket Display", 260)
    enableCB:SetPoint("TOPLEFT", dispDesc, "BOTTOMLEFT", 0, -14)
    enableCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.enabled = checked end
        if addon.Trinkets then addon.Trinkets.applyVisibility() end
    end

    local moveBtn = CreateFrame("Button", nil, displayPanel, "BackdropTemplate")
    moveBtn:SetSize(80, 22)
    moveBtn:SetPoint("TOPLEFT", enableCB, "BOTTOMLEFT", 0, -10)
    applyBackdrop(moveBtn, 1, C.panelDark, C.tabBorder)
    local moveLbl = moveBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    moveLbl:SetPoint("CENTER"); moveLbl:SetText("Move"); moveLbl:SetTextColor(unpack(C.textWhite))
    moveBtn:SetScript("OnEnter", function() moveBtn:SetBackdropBorderColor(unpack(C.red)) end)
    moveBtn:SetScript("OnLeave", function() moveBtn:SetBackdropBorderColor(unpack(C.tabBorder)) end)
    moveBtn:SetScript("OnClick", function() UI.EnterMoveMode({ addon.Trinkets }) end)

    -- ── Bag Menu section ──────────────────────────────────────────────────────
    local menuHeader = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    menuHeader:SetPoint("TOPLEFT", moveBtn, "BOTTOMLEFT", 0, -20)
    menuHeader:SetText("Bag Menu")
    menuHeader:SetTextColor(unpack(C.red))

    local alwaysShowCB = createCheckbox(displayPanel, "Always show bag menu (don't close on mouse leave)", 380)
    alwaysShowCB:SetPoint("TOPLEFT", menuHeader, "BOTTOMLEFT", 0, -10)
    alwaysShowCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.alwaysShow = checked end
        if addon.Trinkets then addon.Trinkets.applyVisibility() end
    end

    local dockedCB = createCheckbox(displayPanel, "Keep bag menu docked to display frame", 340)
    dockedCB:SetPoint("TOPLEFT", alwaysShowCB, "BOTTOMLEFT", 0, -6)
    dockedCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.menuDocked = checked end
        local mf = _G["DrievTrinketMenu"]
        if mf and mf:IsShown() and addon.Trinkets then
            addon.Trinkets.positionMenu()
        end
    end

    local dockHint = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dockHint:SetPoint("TOPLEFT", dockedCB, "BOTTOMLEFT", 20, -8)
    dockHint:SetText("When docked, drag the bag menu around the display in Move UI mode — it snaps to whichever corner is closest and stays anchored there.")
    dockHint:SetTextColor(unpack(C.textDim))
    dockHint:SetWidth(340); dockHint:SetJustifyH("LEFT")

    -- ── Layout section ────────────────────────────────────────────────────────
    local layoutHeader = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    layoutHeader:SetPoint("TOPLEFT", dockHint, "BOTTOMLEFT", -20, -18)
    layoutHeader:SetText("Layout")
    layoutHeader:SetTextColor(unpack(C.red))

    -- Orientation toggle (Horizontal / Vertical)
    local orientRow = CreateFrame("Frame", nil, displayPanel)
    orientRow:SetSize(310, 22)
    orientRow:SetPoint("TOPLEFT", layoutHeader, "BOTTOMLEFT", 0, -10)

    local orientLbl = orientRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    orientLbl:SetPoint("LEFT", 0, 0)
    orientLbl:SetText("Orientation:")
    orientLbl:SetTextColor(unpack(C.textGrey))

    local ORIENTS = { "horizontal", "vertical" }
    local ORIENT_LABELS = { horizontal = "Horizontal", vertical = "Vertical" }
    local orientBtns = {}

    local function refreshOrientation()
        local d   = getTData()
        local cur = (d and d.menuOrientation) or "horizontal"
        for _, o in ipairs(ORIENTS) do
            local b = orientBtns[o]
            if b then
                if o == cur then
                    b:SetBackdropColor(unpack(C.tabActive)); b:SetBackdropBorderColor(unpack(C.red))
                else
                    b:SetBackdropColor(unpack(C.panelDark)); b:SetBackdropBorderColor(unpack(C.tabBorder))
                end
            end
        end
    end

    -- forward-declare so orient-button OnClick can call refreshPerLine
    local refreshPerLine

    local prevOb
    for _, o in ipairs(ORIENTS) do
        local b = CreateFrame("Button", nil, orientRow, "BackdropTemplate")
        b:SetSize(82, 20)
        b:SetPoint("LEFT", prevOb and prevOb or orientLbl, prevOb and "RIGHT" or "RIGHT", 4, 0)
        applyBackdrop(b, 1, C.panelDark, C.tabBorder)
        local bl = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        bl:SetPoint("CENTER"); bl:SetText(ORIENT_LABELS[o]); bl:SetTextColor(unpack(C.textWhite))
        b:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(unpack(C.red)) end)
        b:SetScript("OnLeave", function() refreshOrientation() end)
        b:SetScript("OnClick", function()
            local d = getTData(); if d then d.menuOrientation = o end
            refreshOrientation()
            if refreshPerLine then refreshPerLine() end
            if addon.Trinkets then addon.Trinkets.buildMenu() end
        end)
        orientBtns[o] = b
        prevOb = b
    end

    -- Trinkets per row / per column
    local perLineRow = CreateFrame("Frame", nil, displayPanel)
    perLineRow:SetSize(260, 22)
    perLineRow:SetPoint("TOPLEFT", orientRow, "BOTTOMLEFT", 0, -8)

    local perLineLbl = perLineRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    perLineLbl:SetPoint("LEFT", 0, 0)
    perLineLbl:SetTextColor(unpack(C.textGrey))

    local perLineMinus = CreateFrame("Button", nil, perLineRow, "BackdropTemplate")
    perLineMinus:SetSize(22, 22)
    perLineMinus:SetPoint("LEFT", 130, 0)
    applyBackdrop(perLineMinus, 1, C.panelDark, C.tabBorder)
    local pml = perLineMinus:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pml:SetPoint("CENTER"); pml:SetText("-"); pml:SetTextColor(unpack(C.textWhite))
    perLineMinus:SetScript("OnEnter", function() perLineMinus:SetBackdropBorderColor(unpack(C.red)) end)
    perLineMinus:SetScript("OnLeave", function() perLineMinus:SetBackdropBorderColor(unpack(C.tabBorder)) end)

    local perLineNum = perLineRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    perLineNum:SetPoint("LEFT", perLineMinus, "RIGHT", 6, 0)
    perLineNum:SetWidth(16); perLineNum:SetJustifyH("CENTER")
    perLineNum:SetTextColor(unpack(C.textWhite))

    local perLinePlus = CreateFrame("Button", nil, perLineRow, "BackdropTemplate")
    perLinePlus:SetSize(22, 22)
    perLinePlus:SetPoint("LEFT", perLineNum, "RIGHT", 6, 0)
    applyBackdrop(perLinePlus, 1, C.panelDark, C.tabBorder)
    local ppl = perLinePlus:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ppl:SetPoint("CENTER"); ppl:SetText("+"); ppl:SetTextColor(unpack(C.textWhite))
    perLinePlus:SetScript("OnEnter", function() perLinePlus:SetBackdropBorderColor(unpack(C.red)) end)
    perLinePlus:SetScript("OnLeave", function() perLinePlus:SetBackdropBorderColor(unpack(C.tabBorder)) end)

    refreshPerLine = function()
        local d = getTData()
        local n = (d and d.menuPerLine) or 4
        perLineNum:SetText(tostring(n))
        local vert = d and d.menuOrientation == "vertical"
        perLineLbl:SetText(vert and "Trinkets per column:" or "Trinkets per row:")
    end

    perLineMinus:SetScript("OnClick", function()
        local d = getTData(); if not d then return end
        d.menuPerLine = math.max(1, (d.menuPerLine or 4) - 1)
        refreshPerLine()
        if addon.Trinkets then addon.Trinkets.buildMenu() end
    end)
    perLinePlus:SetScript("OnClick", function()
        local d = getTData(); if not d then return end
        d.menuPerLine = math.min(10, (d.menuPerLine or 4) + 1)
        refreshPerLine()
        if addon.Trinkets then addon.Trinkets.buildMenu() end
    end)

    -- Alignment dropdown (left / right). Right builds the menu from the right
    -- edge so the 1st trinket in menu order sits at the far right.
    local alignRow = CreateFrame("Frame", nil, displayPanel)
    alignRow:SetSize(260, 22)
    alignRow:SetPoint("TOPLEFT", perLineRow, "BOTTOMLEFT", 0, -10)

    local alignLbl = alignRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    alignLbl:SetPoint("LEFT", 0, 0)
    alignLbl:SetText("Alignment:")
    alignLbl:SetTextColor(unpack(C.textGrey))

    local alignDD = createDropdown(alignRow, 110,
        { { value = "left", label = "Left" }, { value = "right", label = "Right" } },
        function() local d = getTData(); return (d and d.menuAlign) or "left" end,
        function(v) local d = getTData(); if d then d.menuAlign = v end end,
        function()
            if addon.Trinkets then
                addon.Trinkets.buildMenu()      -- re-pack buttons for the new side
                addon.Trinkets.positionMenu()   -- re-anchor so it grows the right way
            end
        end)
    alignDD:SetPoint("LEFT", alignLbl, "RIGHT", 8, 0)

    -- ── Display Scale section ─────────────────────────────────────────────────
    local dispScaleHeader = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    dispScaleHeader:SetPoint("TOPLEFT", alignRow, "BOTTOMLEFT", 0, -20)
    dispScaleHeader:SetText("Display Scale")
    dispScaleHeader:SetTextColor(unpack(C.red))

    local dispScaleRow = CreateFrame("Frame", nil, displayPanel)
    dispScaleRow:SetSize(360, 22)
    dispScaleRow:SetPoint("TOPLEFT", dispScaleHeader, "BOTTOMLEFT", 0, -10)

    local DISP_SCALE_MIN, DISP_SCALE_MAX, DISP_SCALE_TRACK_W = 50, 200, 160

    local dispSliderBg = CreateFrame("Frame", nil, dispScaleRow, "BackdropTemplate")
    dispSliderBg:SetSize(DISP_SCALE_TRACK_W, 8)
    dispSliderBg:SetPoint("LEFT", 0, 0)
    applyBackdrop(dispSliderBg, 1, C.panelDeep, C.tabBorder)
    dispSliderBg:EnableMouse(true)

    local dispScaleFill = dispSliderBg:CreateTexture(nil, "ARTWORK")
    dispScaleFill:SetTexture(WHITE)
    dispScaleFill:SetVertexColor(unpack(C.red))
    dispScaleFill:SetPoint("TOPLEFT",    dispSliderBg, "TOPLEFT",    1, -1)
    dispScaleFill:SetPoint("BOTTOMLEFT", dispSliderBg, "BOTTOMLEFT", 1,  1)
    dispScaleFill:SetWidth(1)

    local dispScaleThumb = CreateFrame("Button", nil, dispSliderBg, "BackdropTemplate")
    dispScaleThumb:SetSize(14, 14)
    applyBackdrop(dispScaleThumb, 1, C.tabIdle, C.tabBorder)
    dispScaleThumb:SetPoint("CENTER", dispSliderBg, "LEFT", 0, 0)

    local dispScaleBox = CreateFrame("EditBox", nil, dispScaleRow, "BackdropTemplate")
    dispScaleBox:SetSize(44, 22)
    dispScaleBox:SetPoint("LEFT", dispSliderBg, "RIGHT", 10, 0)
    applyBackdrop(dispScaleBox, 1, C.panelDeep, C.tabBorder)
    dispScaleBox:SetAutoFocus(false)
    dispScaleBox:SetMaxLetters(3)
    dispScaleBox:SetFontObject("GameFontNormal")
    dispScaleBox:SetJustifyH("CENTER")
    dispScaleBox:SetTextInsets(4, 4, 0, 0)
    dispScaleBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    dispScaleBox:SetScript("OnEscapePressed",   function(self) self:ClearFocus() end)

    local dispScalePct = dispScaleRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dispScalePct:SetPoint("LEFT", dispScaleBox, "RIGHT", 4, 0)
    dispScalePct:SetText("%"); dispScalePct:SetTextColor(unpack(C.textGrey))

    local function setDispScaleVisual(pct)
        local frac = (pct - DISP_SCALE_MIN) / (DISP_SCALE_MAX - DISP_SCALE_MIN)
        frac = math.max(0, math.min(1, frac))
        dispScaleFill:SetWidth(math.max(frac * (DISP_SCALE_TRACK_W - 2), 1))
        dispScaleThumb:ClearAllPoints()
        dispScaleThumb:SetPoint("CENTER", dispSliderBg, "LEFT", frac * DISP_SCALE_TRACK_W, 0)
    end

    local function applyDispScaleValue(pct)
        pct = math.max(DISP_SCALE_MIN, math.min(DISP_SCALE_MAX, math.floor(pct + 0.5)))
        setDispScaleVisual(pct)
        if not dispScaleBox:HasFocus() then dispScaleBox:SetText(tostring(pct)) end
        local d = getTData(); if d then d.displayScale = pct / 100 end
        if addon.Trinkets then addon.Trinkets.applyDisplayScale() end
    end

    local function pctFromCursorDispScale()
        local left = dispSliderBg:GetLeft()
        if not left then return DISP_SCALE_MIN end
        local x    = GetCursorPosition() / UIParent:GetEffectiveScale()
        local frac = math.max(0, math.min(1, (x - left) / DISP_SCALE_TRACK_W))
        return DISP_SCALE_MIN + frac * (DISP_SCALE_MAX - DISP_SCALE_MIN)
    end

    local dispScaleDragging = false
    dispScaleThumb:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        dispScaleDragging = true
        dispScaleThumb:SetScript("OnUpdate", function() applyDispScaleValue(pctFromCursorDispScale()) end)
    end)
    dispScaleThumb:SetScript("OnMouseUp", function(_, button)
        if button ~= "LeftButton" then return end
        dispScaleDragging = false
        dispScaleThumb:SetScript("OnUpdate", nil)
        dispScaleThumb:SetBackdropBorderColor(unpack(C.tabBorder))
    end)
    dispScaleThumb:SetScript("OnEnter", function() dispScaleThumb:SetBackdropBorderColor(unpack(C.red)) end)
    dispScaleThumb:SetScript("OnLeave", function()
        if not dispScaleDragging then dispScaleThumb:SetBackdropBorderColor(unpack(C.tabBorder)) end
    end)
    dispSliderBg:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then applyDispScaleValue(pctFromCursorDispScale()) end
    end)
    dispSliderBg:EnableMouseWheel(true)
    dispSliderBg:SetScript("OnMouseWheel", function(_, delta)
        local cur = tonumber(dispScaleBox:GetText()) or 100
        applyDispScaleValue(cur + delta * 5)
    end)

    local function refreshDisplayScale()
        local d   = getTData()
        local pct = math.floor(((d and d.displayScale) or 1.0) * 100 + 0.5)
        setDispScaleVisual(pct)
        dispScaleBox:SetText(tostring(pct))
    end

    dispScaleBox:SetScript("OnEnterPressed", function(self)
        local val = tonumber(self:GetText())
        if val then applyDispScaleValue(val) end
        self:ClearFocus()
    end)
    dispScaleBox:SetScript("OnEditFocusLost", function(self)
        local d   = getTData()
        local pct = math.floor(((d and d.displayScale) or 1.0) * 100 + 0.5)
        self:SetText(tostring(pct))
    end)

    -- ── Menu Scale section ────────────────────────────────────────────────────
    local scaleHeader = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    scaleHeader:SetPoint("TOPLEFT", dispScaleRow, "BOTTOMLEFT", 0, -20)
    scaleHeader:SetText("Menu Scale")
    scaleHeader:SetTextColor(unpack(C.red))

    local scaleRow = CreateFrame("Frame", nil, displayPanel)
    scaleRow:SetSize(360, 22)
    scaleRow:SetPoint("TOPLEFT", scaleHeader, "BOTTOMLEFT", 0, -10)

    local SCALE_MIN, SCALE_MAX, SCALE_TRACK_W = 50, 200, 160

    -- Track (same style as the edit-mode opacity control)
    local sliderBg = CreateFrame("Frame", nil, scaleRow, "BackdropTemplate")
    sliderBg:SetSize(SCALE_TRACK_W, 8)
    sliderBg:SetPoint("LEFT", 0, 0)
    applyBackdrop(sliderBg, 1, C.panelDeep, C.tabBorder)
    sliderBg:EnableMouse(true)

    local scaleFill = sliderBg:CreateTexture(nil, "ARTWORK")
    scaleFill:SetTexture(WHITE)
    scaleFill:SetVertexColor(unpack(C.red))
    scaleFill:SetPoint("TOPLEFT",    sliderBg, "TOPLEFT",    1, -1)
    scaleFill:SetPoint("BOTTOMLEFT", sliderBg, "BOTTOMLEFT", 1,  1)
    scaleFill:SetWidth(1)

    local scaleThumb = CreateFrame("Button", nil, sliderBg, "BackdropTemplate")
    scaleThumb:SetSize(14, 14)
    applyBackdrop(scaleThumb, 1, C.tabIdle, C.tabBorder)
    scaleThumb:SetPoint("CENTER", sliderBg, "LEFT", 0, 0)

    -- Manual-entry box
    local scaleBox = CreateFrame("EditBox", nil, scaleRow, "BackdropTemplate")
    scaleBox:SetSize(44, 22)
    scaleBox:SetPoint("LEFT", sliderBg, "RIGHT", 10, 0)
    applyBackdrop(scaleBox, 1, C.panelDeep, C.tabBorder)
    scaleBox:SetAutoFocus(false)
    scaleBox:SetMaxLetters(3)
    scaleBox:SetFontObject("GameFontNormal")
    scaleBox:SetJustifyH("CENTER")
    scaleBox:SetTextInsets(4, 4, 0, 0)
    scaleBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    scaleBox:SetScript("OnEscapePressed",   function(self) self:ClearFocus() end)

    local scalePct = scaleRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    scalePct:SetPoint("LEFT", scaleBox, "RIGHT", 4, 0)
    scalePct:SetText("%"); scalePct:SetTextColor(unpack(C.textGrey))

    local function setScaleVisual(pct)
        local frac = (pct - SCALE_MIN) / (SCALE_MAX - SCALE_MIN)
        frac = math.max(0, math.min(1, frac))
        scaleFill:SetWidth(math.max(frac * (SCALE_TRACK_W - 2), 1))
        scaleThumb:ClearAllPoints()
        scaleThumb:SetPoint("CENTER", sliderBg, "LEFT", frac * SCALE_TRACK_W, 0)
    end

    local function applyScaleValue(pct)
        pct = math.max(SCALE_MIN, math.min(SCALE_MAX, math.floor(pct + 0.5)))
        setScaleVisual(pct)
        if not scaleBox:HasFocus() then scaleBox:SetText(tostring(pct)) end
        local d = getTData(); if d then d.menuScale = pct / 100 end
        if addon.Trinkets then addon.Trinkets.applyScale() end
    end

    local function pctFromCursorScale()
        local left = sliderBg:GetLeft()
        if not left then return SCALE_MIN end
        local x    = GetCursorPosition() / UIParent:GetEffectiveScale()
        local frac = math.max(0, math.min(1, (x - left) / SCALE_TRACK_W))
        return SCALE_MIN + frac * (SCALE_MAX - SCALE_MIN)
    end

    local scaleDragging = false
    scaleThumb:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        scaleDragging = true
        scaleThumb:SetScript("OnUpdate", function() applyScaleValue(pctFromCursorScale()) end)
    end)
    scaleThumb:SetScript("OnMouseUp", function(_, button)
        if button ~= "LeftButton" then return end
        scaleDragging = false
        scaleThumb:SetScript("OnUpdate", nil)
        scaleThumb:SetBackdropBorderColor(unpack(C.tabBorder))
    end)
    scaleThumb:SetScript("OnEnter", function() scaleThumb:SetBackdropBorderColor(unpack(C.red)) end)
    scaleThumb:SetScript("OnLeave", function()
        if not scaleDragging then scaleThumb:SetBackdropBorderColor(unpack(C.tabBorder)) end
    end)
    sliderBg:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then applyScaleValue(pctFromCursorScale()) end
    end)
    sliderBg:EnableMouseWheel(true)
    sliderBg:SetScript("OnMouseWheel", function(_, delta)
        local cur = tonumber(scaleBox:GetText()) or 100
        applyScaleValue(cur + delta * 5)
    end)

    local function refreshScale()
        local d   = getTData()
        local pct = math.floor(((d and d.menuScale) or 1.0) * 100 + 0.5)
        setScaleVisual(pct)
        scaleBox:SetText(tostring(pct))
    end

    scaleBox:SetScript("OnEnterPressed", function(self)
        local val = tonumber(self:GetText())
        if val then applyScaleValue(val) end
        self:ClearFocus()
    end)
    scaleBox:SetScript("OnEditFocusLost", function(self)
        local d   = getTData()
        local pct = math.floor(((d and d.menuScale) or 1.0) * 100 + 0.5)
        self:SetText(tostring(pct))
    end)

    -- ── Behavior section ──────────────────────────────────────────────────────
    local behHeader = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    behHeader:SetPoint("TOPLEFT", scaleRow, "BOTTOMLEFT", 0, -20)
    behHeader:SetText("Behavior")
    behHeader:SetTextColor(unpack(C.red))

    local cdCB = createCheckbox(displayPanel, "Show cooldown timers on trinket buttons", 300)
    cdCB:SetPoint("TOPLEFT", behHeader, "BOTTOMLEFT", 0, -10)
    cdCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.showCooldowns = checked end
    end

    local keepCB = createCheckbox(displayPanel, "Keep bag menu open after swapping", 300)
    keepCB:SetPoint("TOPLEFT", cdCB, "BOTTOMLEFT", 0, -6)
    keepCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.keepOpen = checked end
    end

    local notifyCB = createCheckbox(displayPanel, "Print chat message when trinket cooldown is ready", 340)
    notifyCB:SetPoint("TOPLEFT", keepCB, "BOTTOMLEFT", 0, -6)
    notifyCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.notify = checked end
    end

    local ttCB = createCheckbox(displayPanel, "Show tooltips in bag menu", 300)
    ttCB:SetPoint("TOPLEFT", notifyCB, "BOTTOMLEFT", 0, -6)
    ttCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.showTooltips = checked end
    end

    local tinyTipCB = createCheckbox(displayPanel,
        "Tiny tooltips (name, charges and cooldown only)", 340)
    tinyTipCB:SetPoint("TOPLEFT", ttCB, "BOTTOMLEFT", 20, -6)
    tinyTipCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.tinyTooltips = checked end
    end

    local watchdogCB = createCheckbox(displayPanel,
        "Auto-recover stuck trinket swaps (watchdog)", 340)
    watchdogCB:SetPoint("TOPLEFT", tinyTipCB, "BOTTOMLEFT", -20, -6)
    watchdogCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.swapWatchdog = checked end
    end

    local watchdogHint = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    watchdogHint:SetPoint("TOPLEFT", watchdogCB, "BOTTOMLEFT", 20, -8)
    watchdogHint:SetText("Failsafe for frame-long combat drops that dont give enough time for the trinket swap to go out, auto re-queues the trinket you were trying to queue.")
    watchdogHint:SetTextColor(unpack(C.textDim))
    watchdogHint:SetWidth(340); watchdogHint:SetJustifyH("LEFT")

    -- ── Keybind display controls ───────────────────────────────────────────────
    local showBindCB = createCheckbox(displayPanel, "Show keybind text on trinket buttons", 340)
    showBindCB:SetPoint("TOPLEFT", watchdogHint, "BOTTOMLEFT", -20, -18)
    showBindCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.showBindings = checked end
        if addon.Trinkets then addon.Trinkets.updateHotkeys() end
    end

    local truncBindCB = createCheckbox(displayPanel, "Truncate keybind text (Numpad+ → NP+, Ctrl-K → CK)", 400)
    truncBindCB:SetPoint("TOPLEFT", showBindCB, "BOTTOMLEFT", 20, -6)
    truncBindCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.truncateBindings = checked end
        if addon.Trinkets then addon.Trinkets.updateHotkeys() end
    end

    local keyUpCB = createCheckbox(displayPanel,
        "Trigger keybind on key up (default: key down)", 340)
    keyUpCB:SetPoint("TOPLEFT", truncBindCB, "BOTTOMLEFT", -20, -6)
    keyUpCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.triggerOnKeyUp = checked end
        if addon.Trinkets then addon.Trinkets.applyClickTrigger() end
    end

    -- ── Keybind modifier blockers ──────────────────────────────────────────────
    -- Lets a trinket keybind share a physical key with an unrelated modified
    -- shortcut from outside the game (e.g. a Discord push-to-talk bound to
    -- Alt+NumpadPlus) — WoW itself has no binding registered for that modified
    -- combo, so it would otherwise just see NumpadPlus and fire the trinket.
    local ctrlCB = createCheckbox(displayPanel, "Ignore trinket keybind while Ctrl is held", 340)
    ctrlCB:SetPoint("TOPLEFT", keyUpCB, "BOTTOMLEFT", 0, -6)
    ctrlCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.blockModCtrl = checked end
        if addon.Trinkets then addon.Trinkets.applyModifierBlockers() end
    end

    local altCB = createCheckbox(displayPanel, "Ignore trinket keybind while Alt is held", 340)
    altCB:SetPoint("TOPLEFT", ctrlCB, "BOTTOMLEFT", 0, -6)
    altCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.blockModAlt = checked end
        if addon.Trinkets then addon.Trinkets.applyModifierBlockers() end
    end

    local shiftCB = createCheckbox(displayPanel, "Ignore trinket keybind while Shift is held", 340)
    shiftCB:SetPoint("TOPLEFT", altCB, "BOTTOMLEFT", 0, -6)
    shiftCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.blockModShift = checked end
        if addon.Trinkets then addon.Trinkets.applyModifierBlockers() end
    end

    -- ── Swap delay ─────────────────────────────────────────────────────────────
    local swapLabel = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    swapLabel:SetPoint("TOPLEFT", shiftCB, "BOTTOMLEFT", 0, -12)
    swapLabel:SetText("Menu rebuild delay after swap:")
    swapLabel:SetTextColor(unpack(C.textGrey))

    local swapMinus = CreateFrame("Button", nil, displayPanel, "BackdropTemplate")
    swapMinus:SetSize(22, 22)
    swapMinus:SetPoint("LEFT", swapLabel, "RIGHT", 8, 0)
    applyBackdrop(swapMinus, 1, C.panelDark, C.tabBorder)
    local swapMinusLbl = swapMinus:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    swapMinusLbl:SetPoint("CENTER"); swapMinusLbl:SetText("-"); swapMinusLbl:SetTextColor(unpack(C.textWhite))

    local swapNum = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    swapNum:SetPoint("LEFT", swapMinus, "RIGHT", 6, 0)
    swapNum:SetWidth(30); swapNum:SetJustifyH("CENTER")
    swapNum:SetTextColor(unpack(C.textWhite))

    local swapPlus = CreateFrame("Button", nil, displayPanel, "BackdropTemplate")
    swapPlus:SetSize(22, 22)
    swapPlus:SetPoint("LEFT", swapNum, "RIGHT", 6, 0)
    applyBackdrop(swapPlus, 1, C.panelDark, C.tabBorder)
    local swapPlusLbl = swapPlus:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    swapPlusLbl:SetPoint("CENTER"); swapPlusLbl:SetText("+"); swapPlusLbl:SetTextColor(unpack(C.textWhite))

    local swapSec = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    swapSec:SetPoint("LEFT", swapPlus, "RIGHT", 4, 0)
    swapSec:SetText("s"); swapSec:SetTextColor(unpack(C.textDim))

    local refreshSwapDelay
    refreshSwapDelay = function()
        local d = getTData()
        swapNum:SetText(string.format("%.1f", (d and d.swapDelay) or 1.0))
    end

    swapMinus:SetScript("OnClick", function()
        local d = getTData(); if not d then return end
        d.swapDelay = math.max(0.1, math.floor(((d.swapDelay or 1.0) - 0.1) * 10 + 0.5) / 10)
        refreshSwapDelay()
    end)
    swapMinus:SetScript("OnEnter", function() swapMinus:SetBackdropBorderColor(unpack(C.red)) end)
    swapMinus:SetScript("OnLeave", function() swapMinus:SetBackdropBorderColor(unpack(C.tabBorder)) end)

    swapPlus:SetScript("OnClick", function()
        local d = getTData(); if not d then return end
        d.swapDelay = math.min(5.0, math.floor(((d.swapDelay or 1.0) + 0.1) * 10 + 0.5) / 10)
        refreshSwapDelay()
    end)
    swapPlus:SetScript("OnEnter", function() swapPlus:SetBackdropBorderColor(unpack(C.red)) end)
    swapPlus:SetScript("OnLeave", function() swapPlus:SetBackdropBorderColor(unpack(C.tabBorder)) end)

    -- ── Keybind assignment ─────────────────────────────────────────────────────
    -- Lazy capture popup — a small floating dialog (no full-screen overlay).
    -- Captures keyboard keys AND mouse buttons (via RegisterForClicks on inner Button).
    local bindCapture = { action = nil, label = nil }
    local capturePopup

    local function getOrCreateCapturePopup()
        if capturePopup then return capturePopup end

        -- Invisible full-screen click-catcher at DIALOG strata: clicking outside
        -- the popup (at TOOLTIP strata above) cancels capture without consuming a bind.
        local catcher = CreateFrame("Button", nil, UIParent)
        catcher:SetAllPoints()
        catcher:SetFrameStrata("DIALOG")
        catcher:Hide()

        -- Small popup dialog: no full-screen background, just a compact bordered box.
        local popup = CreateFrame("Frame", "DrievKeybindCapture", UIParent, "BackdropTemplate")
        popup:SetSize(300, 74)
        popup:SetPoint("CENTER")
        popup:SetFrameStrata("TOOLTIP")
        popup:EnableKeyboard(true)
        popup:SetPropagateKeyboardInput(false)
        applyBackdrop(popup, 2, C.panelBG, C.red)
        popup:Hide()

        local prompt = popup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        prompt:SetPoint("TOP", 0, -14)
        prompt:SetText("Press a key or mouse button to bind")
        prompt:SetTextColor(unpack(C.textWhite))

        local hint = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hint:SetPoint("BOTTOM", 0, 12)
        hint:SetText("Escape to cancel  •  Right-click keybind button to clear")
        hint:SetTextColor(unpack(C.textGrey))

        -- Invisible button filling the popup so mouse clicks register as binds.
        local clickArea = CreateFrame("Button", nil, popup)
        clickArea:SetAllPoints(popup)
        clickArea:RegisterForClicks("AnyUp")

        local function finishCapture(rawKey)   -- nil = cancel/clear
            if bindCapture.action then
                local old = GetBindingKey(bindCapture.action)
                if old then SetBinding(old) end
                if rawKey then SetBinding(rawKey, bindCapture.action) end
                SaveBindings(GetCurrentBindingSet())
                if bindCapture.label then
                    local k = GetBindingKey(bindCapture.action)
                    bindCapture.label:SetText(k and GetBindingText(k, "KEY_") or "None")
                end
                if addon.Trinkets then addon.Trinkets.updateHotkeys() end
            end
            bindCapture = { action = nil, label = nil }
            popup:Hide()
            catcher:Hide()
        end

        popup:SetScript("OnKeyDown", function(_, key)
            if key == "ESCAPE" then finishCapture(nil); return end
            if key == "LSHIFT" or key == "RSHIFT" or key == "LCTRL" or key == "RCTRL"
               or key == "LALT" or key == "RALT" or key == "LMETA" or key == "RMETA" then
                return
            end
            local mod = ""
            if IsControlKeyDown() then mod = "CTRL-"  .. mod end
            if IsAltKeyDown()     then mod = "ALT-"   .. mod end
            if IsShiftKeyDown()   then mod = "SHIFT-" .. mod end
            finishCapture(mod .. key)
        end)

        -- Map WoW click button names → WoW binding key names.
        local btnToKey = {
            LeftButton   = "BUTTON1", RightButton  = "BUTTON2",
            MiddleButton = "BUTTON3", Button4      = "BUTTON4",
            Button5      = "BUTTON5", Button6      = "BUTTON6",
            Button7      = "BUTTON7", Button8      = "BUTTON8",
        }
        clickArea:SetScript("OnClick", function(_, btn)
            local rawKey = btnToKey[btn]
            if not rawKey then return end
            local mod = ""
            if IsControlKeyDown() then mod = "CTRL-"  .. mod end
            if IsAltKeyDown()     then mod = "ALT-"   .. mod end
            if IsShiftKeyDown()   then mod = "SHIFT-" .. mod end
            finishCapture(mod .. rawKey)
        end)

        catcher:SetScript("OnClick", function() finishCapture(nil) end)

        capturePopup = popup
        popup._catcher = catcher
        return popup
    end

    local kbHeader = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    kbHeader:SetPoint("TOPLEFT", swapMinus, "BOTTOMLEFT", 0, -20)
    kbHeader:SetText("Keybinds")
    kbHeader:SetTextColor(unpack(C.red))

    local kbDesc = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    kbDesc:SetPoint("TOPLEFT", kbHeader, "BOTTOMLEFT", 0, -4)
    kbDesc:SetText("Left-click to bind key/mouse.  Right-click to clear.")
    kbDesc:SetTextColor(unpack(C.textGrey))

    local kbBindBtns = {}
    local prevKbAnchor = kbDesc
    for which = 0, 1 do
        local action   = "CLICK DrievTrinketBtn"..which..":LeftButton"
        local slotName = (which == 0) and "Top Slot" or "Bottom Slot"

        local slotLbl = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        slotLbl:SetPoint("TOPLEFT", prevKbAnchor, "BOTTOMLEFT", 0, -18)
        slotLbl:SetText(slotName .. ":")
        slotLbl:SetTextColor(unpack(C.textGrey))

        local kbBtn = CreateFrame("Button", nil, displayPanel, "BackdropTemplate")
        kbBtn:SetSize(140, 22)
        kbBtn:SetPoint("LEFT", slotLbl, "RIGHT", 8, 0)
        kbBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        applyBackdrop(kbBtn, 1, C.panelDark, C.tabBorder)
        local kbLbl = kbBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        kbLbl:SetPoint("CENTER")
        kbLbl:SetTextColor(unpack(C.textWhite))
        kbBtn.lbl = kbLbl

        kbBtn:SetScript("OnClick", function(_, btn)
            if btn == "RightButton" then
                -- Clear the binding immediately on right-click.
                local old = GetBindingKey(action)
                if old then SetBinding(old) end
                SaveBindings(GetCurrentBindingSet())
                kbLbl:SetText("None")
                if addon.Trinkets then addon.Trinkets.updateHotkeys() end
                return
            end
            bindCapture.action = action
            bindCapture.label  = kbLbl
            local p = getOrCreateCapturePopup()
            p._catcher:Show()
            p:Show()
        end)
        kbBtn:SetScript("OnEnter", function() kbBtn:SetBackdropBorderColor(unpack(C.red)) end)
        kbBtn:SetScript("OnLeave", function() kbBtn:SetBackdropBorderColor(unpack(C.tabBorder)) end)

        kbBindBtns[which] = kbBtn
        prevKbAnchor = slotLbl
    end

    -- ── Menu padding controls ──────────────────────────────────────────────────
    local padHeader = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    padHeader:SetPoint("TOPLEFT", prevKbAnchor, "BOTTOMLEFT", 0, -20)
    padHeader:SetText("Padding")
    padHeader:SetTextColor(unpack(C.red))

    local function makePadRow(anchorAbove, label, getVal, setVal, apply)
        apply = apply or function() if addon.Trinkets then addon.Trinkets.buildMenu() end end
        local rowLbl = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        rowLbl:SetPoint("TOPLEFT", anchorAbove, "BOTTOMLEFT", 0, -18)
        rowLbl:SetText(label)
        rowLbl:SetTextColor(unpack(C.textGrey))

        local btnM = CreateFrame("Button", nil, displayPanel, "BackdropTemplate")
        btnM:SetSize(22, 22)
        btnM:SetPoint("LEFT", rowLbl, "RIGHT", 8, 0)
        applyBackdrop(btnM, 1, C.panelDark, C.tabBorder)
        local mLbl = btnM:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        mLbl:SetPoint("CENTER"); mLbl:SetText("-"); mLbl:SetTextColor(unpack(C.textWhite))

        local numLbl = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        numLbl:SetPoint("LEFT", btnM, "RIGHT", 6, 0)
        numLbl:SetWidth(20); numLbl:SetJustifyH("CENTER")
        numLbl:SetTextColor(unpack(C.textWhite))

        local btnP = CreateFrame("Button", nil, displayPanel, "BackdropTemplate")
        btnP:SetSize(22, 22)
        btnP:SetPoint("LEFT", numLbl, "RIGHT", 6, 0)
        applyBackdrop(btnP, 1, C.panelDark, C.tabBorder)
        local pLbl = btnP:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        pLbl:SetPoint("CENTER"); pLbl:SetText("+"); pLbl:SetTextColor(unpack(C.textWhite))

        local pxLbl = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        pxLbl:SetPoint("LEFT", btnP, "RIGHT", 4, 0)
        pxLbl:SetText("px"); pxLbl:SetTextColor(unpack(C.textDim))

        local function refresh() numLbl:SetText(tostring(getVal())) end

        btnM:SetScript("OnClick", function()
            setVal(math.max(0, getVal() - 1))
            refresh()
            apply()
        end)
        btnM:SetScript("OnEnter", function() btnM:SetBackdropBorderColor(unpack(C.red)) end)
        btnM:SetScript("OnLeave", function() btnM:SetBackdropBorderColor(unpack(C.tabBorder)) end)
        btnP:SetScript("OnClick", function()
            setVal(math.min(30, getVal() + 1))
            refresh()
            apply()
        end)
        btnP:SetScript("OnEnter", function() btnP:SetBackdropBorderColor(unpack(C.red)) end)
        btnP:SetScript("OnLeave", function() btnP:SetBackdropBorderColor(unpack(C.tabBorder)) end)

        return rowLbl, refresh
    end

    local btnGapLbl, refreshButtonGap = makePadRow(padHeader, "Bag menu — button gap (space between icons):",
        function() local d = getTData(); return (d and d.menuButtonGap) or 6 end,
        function(v) local d = getTData(); if d then d.menuButtonGap = v end end)

    local applyDisplayLayout = function() if addon.Trinkets then addon.Trinkets.layoutDisplay() end end

    local dispGapLbl, refreshDispButtonGap = makePadRow(btnGapLbl, "Display — gap between the two trinkets:",
        function() local d = getTData(); return (d and d.displayButtonGap) or 2 end,
        function(v) local d = getTData(); if d then d.displayButtonGap = v end end,
        applyDisplayLayout)

    local edgePadLbl, refreshEdgePad = makePadRow(dispGapLbl, "Bag menu — edge padding (frame border):",
        function() local d = getTData(); return (d and d.menuEdgePad) or 0 end,
        function(v) local d = getTData(); if d then d.menuEdgePad = v end end)

    local _, refreshDispEdgePad = makePadRow(edgePadLbl, "Display — edge padding (frame border):",
        function() local d = getTData(); return (d and d.displayEdgePad) or 0 end,
        function(v) local d = getTData(); if d then d.displayEdgePad = v end end,
        applyDisplayLayout)

    -- ── Two-column layout ──────────────────────────────────────────────────────
    -- The sections above are built in one chained sequence for readability; here
    -- we override only the section-header anchors to lay them out in two columns.
    -- Each section's contents stay anchored to their own header, so re-anchoring
    -- a header moves the whole section as a unit.
    --   Left  column (top→bottom): Trinket Display, Keybinds, Bag Menu, Behavior
    --   Right column (top→bottom): Layout, Display Scale, Menu Scale, Padding
    local RIGHT_X = 460

    -- Left column. dispHeader keeps its original (14, -14). prevKbAnchor is the
    -- Keybinds section's last row (the Bottom Slot label). dockHint sits +20
    -- indented, so Behavior counter-offsets by -20 to line its header up at 14.
    kbHeader:ClearAllPoints()
    kbHeader:SetPoint("TOPLEFT", moveBtn, "BOTTOMLEFT", 0, -20)
    menuHeader:ClearAllPoints()
    menuHeader:SetPoint("TOPLEFT", prevKbAnchor, "BOTTOMLEFT", 0, -20)
    behHeader:ClearAllPoints()
    behHeader:SetPoint("TOPLEFT", dockHint, "BOTTOMLEFT", -20, -18)

    -- Right column. dispScaleHeader (→perLineRow) and scaleHeader (→dispScaleRow)
    -- already chain correctly beneath Layout, so only the column head (Layout)
    -- and Padding need re-anchoring.
    layoutHeader:ClearAllPoints()
    layoutHeader:SetPoint("TOPLEFT", displayPanel, "TOPLEFT", RIGHT_X, -14)
    padHeader:ClearAllPoints()
    padHeader:SetPoint("TOPLEFT", scaleRow, "BOTTOMLEFT", 0, -20)

    -- OnShow fires when the Display sub-tab is selected
    local function refreshDisplay()
        local d = getTData(); if not d then return end
        enableCB:SetChecked(d.enabled or false)
        alwaysShowCB:SetChecked(d.alwaysShow or false)
        dockedCB:SetChecked(d.menuDocked ~= false)
        refreshOrientation()
        refreshPerLine()
        alignDD.Refresh()
        refreshDisplayScale()
        refreshScale()
        cdCB:SetChecked(d.showCooldowns ~= false)
        keepCB:SetChecked(d.keepOpen or false)
        notifyCB:SetChecked(d.notify or false)
        ttCB:SetChecked(d.showTooltips ~= false)
        tinyTipCB:SetChecked(d.tinyTooltips or false)
        watchdogCB:SetChecked(d.swapWatchdog ~= false)
        showBindCB:SetChecked(d.showBindings ~= false)
        truncBindCB:SetChecked(d.truncateBindings ~= false)
        keyUpCB:SetChecked(d.triggerOnKeyUp or false)
        ctrlCB:SetChecked(d.blockModCtrl or false)
        altCB:SetChecked(d.blockModAlt or false)
        shiftCB:SetChecked(d.blockModShift or false)
        refreshSwapDelay()
        for which = 0, 1 do
            local action = "CLICK DrievTrinketBtn"..which..":LeftButton"
            local k = GetBindingKey(action)
            kbBindBtns[which].lbl:SetText(k and GetBindingText(k, "KEY_") or "None")
        end
        refreshEdgePad()
        refreshButtonGap()
        refreshDispEdgePad()
        refreshDispButtonGap()
    end
    displayShell:SetScript("OnShow", refreshDisplay)

    -- ── Queue sub-panels ──────────────────────────────────────────────────────
    local topQueuePanel, topQueueInner = makeScrollPanel(subContent)
    local topList = buildSortList(topQueueInner, 0)
    topList:SetPoint("TOPLEFT", 14, -14)
    topQueuePanel:SetScript("OnShow", function() topList:Refresh() end)

    local botQueuePanel, botQueueInner = makeScrollPanel(subContent)
    local botList = buildSortList(botQueueInner, 1)
    botList:SetPoint("TOPLEFT", 14, -14)
    botQueuePanel:SetScript("OnShow", function() botList:Refresh() end)

    -- ── Menu Order sub-panel ──────────────────────────────────────────────────
    local menuOrderPanel, menuOrderInner = makeScrollPanel(subContent)

    local menuOrderEnableCB = createCheckbox(menuOrderInner,
        "Enable custom menu order (overrides bag-slot order)", 340)
    menuOrderEnableCB:SetPoint("TOPLEFT", 14, -14)
    menuOrderEnableCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.menuOrderEnabled = checked end
        if _G["DrievTrinketMenu"] and _G["DrievTrinketMenu"]:IsShown() then
            if addon.Trinkets then addon.Trinkets.buildMenu() end
        end
    end

    local orderList = buildMenuOrderList(menuOrderInner)
    orderList:SetPoint("TOPLEFT", menuOrderEnableCB, "BOTTOMLEFT", 0, -10)
    menuOrderPanel:SetScript("OnShow", function()
        local d = getTData()
        menuOrderEnableCB:SetChecked(d and d.menuOrderEnabled or false)
        orderList:Refresh()
    end)

    -- ── Sub-tabs ──────────────────────────────────────────────────────────────
    panel.subTabs["display"]   = createTab(subBar, "Display", 80)
    panel.subTabs["top"]       = createTab(subBar, "Top Slot", 90)
    panel.subTabs["bottom"]    = createTab(subBar, "Bottom Slot", 100)
    panel.subTabs["order"]     = createTab(subBar, "Menu Order", 100)
    panel.subPanels["display"] = displayShell
    panel.subPanels["top"]     = topQueuePanel
    panel.subPanels["bottom"]  = botQueuePanel
    panel.subPanels["order"]   = menuOrderPanel

    -- Tab order: Display, Menu Order, Top Slot, Bottom Slot
    panel.subTabs["display"]:SetHeight(22)
    panel.subTabs["display"]:SetPoint("LEFT", 4, 0)
    panel.subTabs["display"]:SetScript("OnClick", function() selectSubTab(panel, "display") end)

    panel.subTabs["order"]:SetHeight(22)
    panel.subTabs["order"]:SetPoint("LEFT", panel.subTabs["display"], "RIGHT", 4, 0)
    panel.subTabs["order"]:SetScript("OnClick", function() selectSubTab(panel, "order") end)

    panel.subTabs["top"]:SetHeight(22)
    panel.subTabs["top"]:SetPoint("LEFT", panel.subTabs["order"], "RIGHT", 4, 0)
    panel.subTabs["top"]:SetScript("OnClick", function() selectSubTab(panel, "top") end)

    panel.subTabs["bottom"]:SetHeight(22)
    panel.subTabs["bottom"]:SetPoint("LEFT", panel.subTabs["top"], "RIGHT", 4, 0)
    panel.subTabs["bottom"]:SetScript("OnClick", function() selectSubTab(panel, "bottom") end)

    selectSubTab(panel, "display")
    return panel
end

local function createMainFrame()
    local f = CreateFrame("Frame", "DrievSettingsFrame", UIParent, "BackdropTemplate")
    f:SetSize(860, 500)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    applyBackdrop(f, 2, C.panelBG, C.red)
    f:Hide()

    local topBar = CreateFrame("Frame", nil, f, "BackdropTemplate")
    topBar:SetHeight(34)
    topBar:SetPoint("TOPLEFT", 2, -2)
    topBar:SetPoint("TOPRIGHT", -2, -2)
    applyBackdrop(topBar, 1, C.panelDark)
    topBar:EnableMouse(true)
    topBar:RegisterForDrag("LeftButton")
    topBar:SetScript("OnMouseDown", function() f:StartMoving() end)
    topBar:SetScript("OnMouseUp",   function() f:StopMovingOrSizing() end)

    local title = topBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", 12, 0)
    title:SetText("|cfffb2c36Driev's|r |cffffffffEssentials|r")

    local version = topBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    version:SetPoint("LEFT", title, "RIGHT", 8, -1)
    version:SetText("|cffaaaaaav" .. addon.version .. "|r")

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

    local moveUIBtn = CreateFrame("Button", nil, topBar, "BackdropTemplate")
    moveUIBtn:SetSize(84, 22)
    moveUIBtn:SetPoint("RIGHT", close, "LEFT", -6, 0)
    applyBackdrop(moveUIBtn, 1, C.panelDark, C.tabBorder)
    local moveUILabel = moveUIBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    moveUILabel:SetPoint("CENTER")
    moveUILabel:SetText("Move UI")
    moveUILabel:SetTextColor(unpack(C.textWhite))
    moveUIBtn:SetScript("OnEnter", function() moveUIBtn:SetBackdropBorderColor(unpack(C.red)) end)
    moveUIBtn:SetScript("OnLeave", function() moveUIBtn:SetBackdropBorderColor(unpack(C.tabBorder)) end)
    moveUIBtn:SetScript("OnClick", function() UI.EnterMoveMode() end)

    local tabBar = CreateFrame("Frame", nil, f, "BackdropTemplate")
    tabBar:SetHeight(30)
    tabBar:SetPoint("TOPLEFT", topBar, "BOTTOMLEFT", 0, -2)
    tabBar:SetPoint("TOPRIGHT", topBar, "BOTTOMRIGHT", 0, -2)
    applyBackdrop(tabBar, 1, C.panelDark)

    local content = CreateFrame("Frame", nil, f, "BackdropTemplate")
    content:SetPoint("TOPLEFT", tabBar, "BOTTOMLEFT", 0, -2)
    content:SetPoint("BOTTOMRIGHT", -2, 2)
    applyBackdrop(content, 1, C.panelDeep)

    f.topBar  = topBar
    f.tabBar  = tabBar
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

-- ── Profiles tab ─────────────────────────────────────────────────────────────

local function buildProfilesPanel(parent)
    local shell, panel = makeScrollPanel(parent)

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

    -- ── List of existing profiles ─────────────────────────────────────────
    local listHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    listHeader:SetPoint("TOPLEFT", errText, "BOTTOMLEFT", 0, -20)
    listHeader:SetText("Existing Profiles")
    listHeader:SetTextColor(unpack(C.red))

    local rows = {}
    local ROW_W, ROW_H = 540, 26
    local refreshProfiles

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
        nameBox:SetText("")
        local list   = addon.GetProfileList and addon.GetProfileList() or {}
        local active = addon.GetActiveProfileName and addon.GetActiveProfileName() or "Default"

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

function UI.GetFrame()
    if UI.frame then return UI.frame end

    local f = createMainFrame()

    local generalTab = createTab(f.tabBar, "General")
    generalTab:SetPoint("LEFT", 6, 0)
    generalTab:SetScript("OnClick", function() selectTab(f, "general") end)
    f.tabs.general = generalTab

    local partTab = createTab(f.tabBar, "Particles")
    partTab:SetPoint("LEFT", generalTab, "RIGHT", 4, 0)
    partTab:SetScript("OnClick", function() selectTab(f, "particles") end)
    f.tabs.particles = partTab

    local raidTab = createTab(f.tabBar, "Raid")
    raidTab:SetPoint("LEFT", partTab, "RIGHT", 4, 0)
    raidTab:SetScript("OnClick", function() selectTab(f, "raid") end)
    f.tabs.raid = raidTab

    local raidFramesTab = createTab(f.tabBar, "Raid Frames")
    raidFramesTab:SetPoint("LEFT", raidTab, "RIGHT", 4, 0)
    raidFramesTab:SetScript("OnClick", function() selectTab(f, "raidframes") end)
    f.tabs.raidframes = raidFramesTab

    local trinketsTab = createTab(f.tabBar, "Trinkets")
    trinketsTab:SetPoint("LEFT", raidFramesTab, "RIGHT", 4, 0)
    trinketsTab:SetScript("OnClick", function() selectTab(f, "trinkets") end)
    f.tabs.trinkets = trinketsTab

    local profilesTab = createTab(f.tabBar, "Profiles")
    profilesTab:SetPoint("LEFT", trinketsTab, "RIGHT", 4, 0)
    profilesTab:SetScript("OnClick", function() selectTab(f, "profiles") end)
    f.tabs.profiles = profilesTab

    f.panels.general    = buildGeneralTabPanel(f.content)
    f.panels.particles  = buildParticlesPanel(f.content)
    f.panels.raid       = buildRaidSettingsPanel(f.content)
    f.panels.raidframes = buildRaidFramesPanel(f.content)
    f.panels.trinkets   = buildTrinketsPanel(f.content)
    f.panels.profiles   = buildProfilesPanel(f.content)

    selectTab(f, "general")

    UI.frame = f
    return f
end

function addon.ToggleUI()
    local f = UI.GetFrame()
    if f:IsShown() then f:Hide() else f:Show() end
end

-- Themed horizontal slider used in the Move UI bar: [label] [track] [box].
-- The typeable value box sits to the RIGHT of the track. opts = { label, min,
-- max, get, set, suffix }. Returns a row frame exposing :Refresh() to re-read
-- the current value from opts.get().
local EDIT_SLIDER_TRACK_W = 110

local function buildEditSlider(parent, opts)
    local mn, mx = opts.min, opts.max
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(244, 22)

    local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("LEFT", row, "LEFT", 0, 0)
    label:SetWidth(58); label:SetJustifyH("LEFT")
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
        local x = GetCursorPosition() / UIParent:GetEffectiveScale()
        local frac = math.max(0, math.min(1, (x - left) / EDIT_SLIDER_TRACK_W))
        return mn + frac * (mx - mn)
    end

    thumb:SetScript("OnMouseDown", function(_, b)
        if b ~= "LeftButton" then return end
        dragging = true
        thumb:SetScript("OnUpdate", function() setValue(valFromCursor()) end)
    end)
    thumb:SetScript("OnMouseUp", function(_, b)
        if b ~= "LeftButton" then return end
        dragging = false
        thumb:SetScript("OnUpdate", nil)
        thumb:SetBackdropBorderColor(unpack(C.tabBorder))
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
    movables = movables or { addon.TTK, addon.RaidFrames, addon.Trinkets }
    UI.activeMovables = movables

    if UI.frame then UI.frame:Hide() end

    -- Each movable's own enterMoveMode() wires up OnMouseDown/OnMouseUp itself
    -- (instant StartMoving() + click-vs-drag detection that opens the precise
    -- position editor), so this loop just shows the frame and hands off.
    for _, m in ipairs(movables) do
        local f = m.getFrame()
        if f then f:Show() end
        m.enterMoveMode()
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
        bar:SetSize(280, 300)
        bar:SetPoint("TOP", UIParent, "TOP", 0, -8)
        bar:SetFrameStrata("TOOLTIP")
        applyBackdrop(bar, 2, C.panelBG, C.red)

        local hint = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hint:SetPoint("TOP", bar, "TOP", 0, -8)
        hint:SetText("Drag to reposition")
        hint:SetTextColor(unpack(C.textGrey))

        local boxHeader = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        boxHeader:SetPoint("TOP", bar, "TOP", 0, -28)
        boxHeader:SetText("Edit Box")
        boxHeader:SetTextColor(unpack(C.red))

        local opacity = buildEditSlider(bar, {
            label = "Opacity", min = 0, max = 100, suffix = "%",
            get = function() return math.floor(addon.GetEditAlpha() * 100 + 0.5) end,
            set = function(v) addon.SetEditAlpha(v / 100) end,
        })
        opacity:SetPoint("TOP", boxHeader, "BOTTOM", 0, -8)

        local padding = buildEditSlider(bar, {
            label = "Padding", min = 0, max = 40, suffix = "px",
            get = function() return addon.GetEditPad() end,
            set = function(v) addon.SetEditPad(v) end,
        })
        padding:SetPoint("TOP", opacity, "BOTTOM", 0, -6)

        local border = buildEditSlider(bar, {
            label = "Border", min = 1, max = 10, suffix = "px",
            get = function() return addon.GetEditBorder() end,
            set = function(v) addon.SetEditBorder(v) end,
        })
        border:SetPoint("TOP", padding, "BOTTOM", 0, -6)

        UI.editSliders = { opacity, padding, border }

        local bgHeader = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        bgHeader:SetPoint("TOP", border, "BOTTOM", 0, -16)
        bgHeader:SetText("Background")
        bgHeader:SetTextColor(unpack(C.red))

        local bgOpacity = buildEditSlider(bar, {
            label = "Opacity", min = 0, max = 100, suffix = "%",
            get = function() return addon.GetMoveBgOpacity() end,
            set = function(v) addon.SetMoveBgOpacity(v) end,
        })
        bgOpacity:SetPoint("TOP", bgHeader, "BOTTOM", 0, -8)
        UI.bgOpacitySlider = bgOpacity

        local bgToggleBtn = CreateFrame("Button", nil, bar, "BackdropTemplate")
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

        local lockBtn = CreateFrame("Button", nil, bar, "BackdropTemplate")
        lockBtn:SetSize(120, 22)
        lockBtn:SetPoint("TOP", bgToggleBtn, "BOTTOM", 0, -16)
        applyBackdrop(lockBtn, 1, C.panelDark, C.tabBorder)
        local lockLabel = lockBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lockLabel:SetPoint("CENTER")
        lockLabel:SetText("Lock")
        lockLabel:SetTextColor(unpack(C.red))
        lockBtn:SetScript("OnEnter", function() lockLabel:SetTextColor(unpack(C.textWhite)) end)
        lockBtn:SetScript("OnLeave", function() lockLabel:SetTextColor(unpack(C.red)) end)
        lockBtn:SetScript("OnClick", function() UI.ExitMoveMode() end)

        UI.lockBar = bar
    end
    if UI.editSliders then
        for _, s in ipairs(UI.editSliders) do s:Refresh() end
    end
    if UI.bgOpacitySlider then UI.bgOpacitySlider:Refresh() end
    if UI.refreshBgToggle then UI.refreshBgToggle() end
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
