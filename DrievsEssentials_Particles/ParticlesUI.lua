-- Driev's Essentials — Particles module: settings UI.
--
-- This addon only loads when the core addon is present (## Dependencies in the
-- .toc guarantees load order), so the shared namespace below always exists.
local addon = _G.DrievEssentials
if not addon then return end

local UI = addon.UI

-- Bind core's shared widget toolkit to locals so the panel code below reads
-- exactly as it did when it lived inside core's UI.lua.
local C     = UI.colors
local WHITE = UI.WHITE
local W     = UI.widgets

local applyBackdrop   = W.applyBackdrop
local createCheckbox  = W.createCheckbox
local createTab       = W.createTab
local createSideTab   = W.createSideTab
local activateTab     = W.activateTab
local selectSubTab    = W.selectSubTab
local makeScrollPanel = W.makeScrollPanel
local buildStepper    = W.buildStepper
local flatButton      = W.flatButton

-- Settings this module owns. Registered into core's defaults at load time and
-- merged into the active profile at PLAYER_LOGIN, so disabling this addon
-- simply leaves the (harmless) saved values untouched.
addon.RegisterDefaults("particles", { classes = { WARRIOR = true } })

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

-- Boss-name colours per raid "wing" (Naxx). Bosses with no wing use the default
-- white checkbox text. Hex only (no |cff prefix) so it can be inlined.
local WING_COLORS = {
    spider    = "33ccff",   -- cyan
    plague    = "ff9933",   -- orange
    military  = "33cc66",   -- green
    construct = "ff66cc",   -- magenta
    frostwyrm = "ffcc33",   -- gold
}

-- onEnableChanged(checked) is an optional callback fired whenever the "Enable
-- particle system" checkbox changes, so a caller showing a status indicator
-- elsewhere (e.g. the raid-selector dot in buildParticlesRaidsPanel) can update
-- it immediately rather than waiting for its own next OnShow.
local function buildRaidPanel(parent, raid, onEnableChanged)
    local shell, panel = makeScrollPanel(parent)

    -- Read particlesData(raid) live inside each handler (never captured once at
    -- build time) so a profile switch/import — which repoints addon.db — is
    -- reflected on the next OnShow instead of writing to / showing the old
    -- profile's table.
    local enable = createCheckbox(panel, "Enable particle system for " .. raid.label, 300)
    enable:SetPoint("TOPLEFT", 14, -14)
    enable.OnChange = function(_, checked)
        particlesData(raid).enabled = checked
        if onEnableChanged then onEnableChanged(checked) end
    end

    local headline = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    headline:SetPoint("TOPLEFT", enable, "BOTTOMLEFT", 0, -18)
    headline:SetText("Select Bosses")
    headline:SetTextColor(unpack(C.red))

    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", headline, "BOTTOMLEFT", 0, -4)
    desc:SetText("Selected bosses keep particle effects enabled during their encounter (raid baseline is off).")
    desc:SetTextColor(unpack(C.textGrey))

    -- Grid: cap of ROWS_PER_COL checkboxes per column; columns grow as needed.
    -- Kept to 5 rows / ~225px columns so it fits the narrower detail area beside
    -- the raid-selector column in Particles → Raids.
    local gridAnchor = CreateFrame("Frame", nil, panel)
    gridAnchor:SetSize(1, 1)
    gridAnchor:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -14)

    local ROWS_PER_COL = 5
    local colWidth, rowHeight = 225, 22
    local bossCBs = {}
    for i, boss in ipairs(raid.bosses) do
        local col = math.floor((i - 1) / ROWS_PER_COL)
        local row = (i - 1) % ROWS_PER_COL

        -- Colour the name by wing (Naxx); the "(!)" default/note marker stays red.
        local wingHex = boss.wing and WING_COLORS[boss.wing]
        local nameStr = wingHex and ("|cff" .. wingHex .. boss.name .. "|r") or boss.name
        local bossLabel = ((boss.default or boss.note) and raid.key ~= "debug")
            and (nameStr .. " |cfffb2c36(!)|r")
            or nameStr
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
    classDesc:SetText("Particle system only runs while playing a selected class")
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

    local enableAllBtn = flatButton(panel, "Enable For All Raids", 175, 24)
    enableAllBtn:SetPoint("TOPLEFT", classGridAnchor, "TOPLEFT", 0, -(CLASS_PER_COL * CLASS_ROW_H) - 14)
    enableAllBtn:SetScript("OnClick", function()
        for _, raid in ipairs(addon.RAIDS) do
            if raid.key ~= "debug" then
                particlesData(raid).enabled = true
            end
        end
    end)

    local disableAllBtn = flatButton(panel, "Disable For All Raids", 175, 24)
    disableAllBtn:SetPoint("LEFT", enableAllBtn, "RIGHT", 8, 0)
    disableAllBtn:SetScript("OnClick", function()
        for _, raid in ipairs(addon.RAIDS) do
            if raid.key ~= "debug" then
                particlesData(raid).enabled = false
            end
        end
    end)

    -- ── Encounter particle level ────────────────────────────────────────────
    local headline = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    headline:SetPoint("TOPLEFT", enableAllBtn, "BOTTOMLEFT", 0, -24)
    headline:SetText("Encounter Particle Level")
    headline:SetTextColor(unpack(C.red))

    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", headline, "BOTTOMLEFT", 0, -4)
    desc:SetWidth(560); desc:SetJustifyH("LEFT")
    desc:SetText("Select the particle density used when particles are enabled for a boss encounter. Raids always use 0 between encounters, aka particles are disabled on trash. Outside of raids it will use the same particle density as selected here")
    desc:SetTextColor(unpack(C.textGrey))

    local rowLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    rowLabel:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -34)
    rowLabel:SetText("Encounter density:")
    rowLabel:SetTextColor(unpack(C.textWhite))

    local function getData()
        addon.db.settings.particles         = addon.db.settings.particles or {}
        addon.db.settings.particles.general = addon.db.settings.particles.general or { encounterDensity = 3 }
        return addon.db.settings.particles.general
    end

    local densityStepper = buildStepper(panel, {
        min = 1, max = 5, valueFont = "GameFontNormalLarge", valueColor = C.red,
        get = function() return getData().encounterDensity end,
        set = function(v) getData().encounterDensity = v end,
    })
    densityStepper:SetPoint("LEFT", rowLabel, "RIGHT", 12, 0)

    local rangeNote = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rangeNote:SetPoint("LEFT", densityStepper.plus, "RIGHT", 10, 0)
    rangeNote:SetText("(1 - 5)")
    rangeNote:SetTextColor(unpack(C.textDim))

    local function refreshDisplay()
        densityStepper.Refresh()
        local classData = getClassData()
        for token, cb in pairs(classCBs) do
            cb:SetChecked(classData[token] == true)
        end
    end

    shell:SetScript("OnShow", refreshDisplay)

    return shell
end

-- Particles → Raids: a left column of raid-selector buttons and, to its right,
-- the selected raid's enable checkbox + boss grid (buildRaidPanel). Excludes the
-- Stockades "debug" raid, which lives on the separate Debug sub-tab.
local function buildParticlesRaidsPanel(parent)
    local shell = CreateFrame("Frame", nil, parent)
    shell:SetAllPoints()
    shell:Hide()

    local raidCol = CreateFrame("Frame", nil, shell, "BackdropTemplate")
    raidCol:SetWidth(120)
    -- Flush with the content box's left edge (x = 0) so the sidebar's left lines
    -- up with the tab bar / content backdrop above it, rather than sitting 4px
    -- inside it.
    raidCol:SetPoint("TOPLEFT", 0, -4)
    raidCol:SetPoint("BOTTOMLEFT", 0, 4)
    applyBackdrop(raidCol, 1, C.panelDark)

    local detail = CreateFrame("Frame", nil, shell)
    detail:SetPoint("TOPLEFT", raidCol, "TOPRIGHT", 4, 0)
    detail:SetPoint("BOTTOMRIGHT", -4, 4)

    shell.raidTabs   = {}
    shell.raidPanels = {}
    local raidDots = {}

    local function setDot(raid, checked)
        local dot = raidDots[raid.key]
        if dot then dot:SetVertexColor(unpack(checked and C.statusOn or C.statusOff)) end
    end

    local prev, firstKey
    for _, raid in ipairs(addon.RAIDS) do
        if raid.key ~= "debug" then
            local btn = createSideTab(raidCol, raid.label, 24)
            if prev then
                btn:SetPoint("TOPLEFT",  prev, "BOTTOMLEFT",  0, -2)
                btn:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -2)
            else
                btn:SetPoint("TOPLEFT",  raidCol, "TOPLEFT",   3, -3)
                btn:SetPoint("TOPRIGHT", raidCol, "TOPRIGHT", -3, -3)
                firstKey = raid.key
            end
            btn:SetScript("OnClick", function()
                activateTab(shell.raidTabs, shell.raidPanels, raid.key)
            end)

            -- Enabled/disabled status dot, right-aligned in the tab.
            local dot = btn:CreateTexture(nil, "OVERLAY")
            dot:SetTexture(WHITE)
            dot:SetSize(8, 8)
            dot:SetPoint("RIGHT", -10, 0)
            raidDots[raid.key] = dot

            shell.raidTabs[raid.key]   = btn
            shell.raidPanels[raid.key] = buildRaidPanel(detail, raid,
                function(checked) setDot(raid, checked) end)
            prev = btn
        end
    end

    -- Sync all dots from saved data whenever this sub-tab is shown (e.g. after
    -- a profile switch, or the first time it's opened).
    shell:SetScript("OnShow", function()
        for _, raid in ipairs(addon.RAIDS) do
            if raid.key ~= "debug" then setDot(raid, particlesData(raid).enabled) end
        end
    end)

    if firstKey then activateTab(shell.raidTabs, shell.raidPanels, firstKey) end
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

    local debugRaid
    for _, raid in ipairs(addon.RAIDS) do
        if raid.key == "debug" then debugRaid = raid end
    end

    local generalTab = createTab(subBar, "General", 80)
    generalTab:SetHeight(22)
    generalTab:SetPoint("LEFT", 4, 0)
    generalTab:SetScript("OnClick", function() selectSubTab(panel, "general") end)
    panel.subTabs["general"]   = generalTab
    panel.subPanels["general"] = buildGeneralPanel(subContent)

    local raidsTab = createTab(subBar, "Raids", 80)
    raidsTab:SetHeight(22)
    raidsTab:SetPoint("LEFT", generalTab, "RIGHT", 4, 0)
    raidsTab:SetScript("OnClick", function() selectSubTab(panel, "raids") end)
    panel.subTabs["raids"]   = raidsTab
    panel.subPanels["raids"] = buildParticlesRaidsPanel(subContent)

    local debugTab = createTab(subBar, "Debug", 80)
    debugTab:SetHeight(22)
    debugTab:SetPoint("LEFT", raidsTab, "RIGHT", 4, 0)
    debugTab:SetScript("OnClick", function() selectSubTab(panel, "debug") end)
    panel.subTabs["debug"]   = debugTab
    panel.subPanels["debug"] = debugRaid and buildRaidPanel(subContent, debugRaid)
        or CreateFrame("Frame", nil, subContent)

    selectSubTab(panel, "general")
    return panel
end

-- Adds the Particles entry to core's settings sidebar. Because this lives in
-- the module, disabling the addon removes the tab entirely.
UI.RegisterTab({ key = "particles", label = "Particles", order = 20, build = buildParticlesPanel })
