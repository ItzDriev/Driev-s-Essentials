-- Particles module: settings UI. Loads only alongside core (## Dependencies),
-- so the shared namespace below always exists.
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
local createSideTab   = W.createSideTab
local activateTab     = W.activateTab
local selectSubTab    = W.selectSubTab
local makeScrollPanel = W.makeScrollPanel
local buildStepper    = W.buildStepper
local flatButton      = W.flatButton

-- Settings this module owns. Registered into core's defaults at load time and
-- merged into the active profile at PLAYER_LOGIN, so disabling this addon
-- simply leaves the (harmless) saved values untouched.
addon.RegisterDefaults("particles", { enabled = false, classes = { WARRIOR = true } })

-- Seconds a boss with no built-in linger starts at once the user ticks its
-- linger box. Bosses that DO have one (boss.linger in core's Raids.lua) seed
-- from that instead, so the old hardcoded timers survive untouched.
local DEFAULT_LINGER_SECONDS = 10
local MAX_LINGER_SECONDS     = 120

-- Lazy: only writes to SavedVariables when the panel is actually built. On first
-- init for a raid, pre-checks bosses with `default = true` and pre-arms linger
-- for bosses with a built-in duration. The sub-tables are healed separately from
-- `d` itself, since imported or older profiles can have a raid entry with none —
-- indexing them in buildRaidPanel would then error.
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
    if not d.linger then
        d.linger, d.lingerSecs = {}, {}
        for _, boss in ipairs(raid.bosses) do
            if boss.linger then
                d.linger[boss.name]     = true
                d.lingerSecs[boss.name] = boss.linger
            end
        end
    end
    d.lingerSecs = d.lingerSecs or {}
    return d
end

local function lingerSeconds(raid, boss)
    local secs = tonumber(particlesData(raid).lingerSecs[boss.name])
    return secs or boss.linger or DEFAULT_LINGER_SECONDS
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

-- onEnableChanged(checked) lets a caller showing a status indicator elsewhere
-- (the raid-selector dot) update immediately rather than on its next OnShow.
local function buildRaidPanel(parent, raid, onEnableChanged)
    local shell, panel = makeScrollPanel(parent)

    -- Read particlesData(raid) live in each handler, never captured at build time,
    -- so a profile switch (which repoints addon.db) is reflected on the next OnShow
    -- instead of writing to the old profile's table.
    local enable = createCheckbox(panel, "Enable particle system for " .. raid.label, 300)
    enable:SetPoint("TOPLEFT", 14, -14)
    enable.OnChange = function(_, checked)
        particlesData(raid).enabled = checked
        if onEnableChanged then onEnableChanged(checked) end
    end

    -- The Stockades debug raid doubles as the module's diagnostics surface, so
    -- the encounter chat spam toggle lives here with the encounters it reports
    -- on. It writes `chat`, not `enabled` — `enabled` is this raid's own switch,
    -- read by Particles.lua to treat a 5-man as raid-like.
    local chatCB
    local anchor = enable
    if raid.key == "debug" then
        chatCB = createCheckbox(panel, "Show encounter messages in chat", 280,
            "Prints each ENCOUNTER_START/END and the particle density changes that follow to the chat frame.")
        chatCB:SetPoint("TOPLEFT", enable, "BOTTOMLEFT", 0, -6)
        chatCB.OnChange = function(_, checked)
            particlesData(raid).chat = checked or nil
        end
        anchor = chatCB
    end

    local headline = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    headline:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -18)
    headline:SetText("Select Bosses")
    UI.tint(headline, C.red)

    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", headline, "BOTTOMLEFT", 0, -4)
    desc:SetWidth(560); desc:SetJustifyH("LEFT")
    desc:SetText("Selected bosses keep particle effects enabled during their encounter (raid baseline is off). Linger keeps them on for a few extra seconds after the encounter ends, for lingering ground effects (Viscidus slime, Ouro residue, etc).")
    UI.tint(desc, C.textGrey)

    -- One row per boss: [enable] name … [linger] [seconds]. A single column rather
    -- than a 3-up grid so the linger controls line up; the scroll panel handles
    -- overflow on longer raids.
    local NAME_W, LINGER_X, SECS_X = 250, 262, 320
    local rowHeight = 24

    local lingerHdr = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lingerHdr:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", LINGER_X - 4, -16)
    lingerHdr:SetText("Linger")
    UI.tint(lingerHdr, C.textDim)

    local secsHdr = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    secsHdr:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", SECS_X, -16)
    secsHdr:SetText("Seconds")
    UI.tint(secsHdr, C.textDim)

    local gridAnchor = CreateFrame("Frame", nil, panel)
    gridAnchor:SetSize(1, 1)
    gridAnchor:SetPoint("TOPLEFT", lingerHdr, "BOTTOMLEFT", -(LINGER_X - 4), -6)

    local bossCBs, lingerCBs, lingerSteppers = {}, {}, {}
    for i, boss in ipairs(raid.bosses) do
        local y = -(i - 1) * rowHeight

        -- Colour the name by wing (Naxx); the "(!)" default/note marker stays red.
        local wingHex = boss.wing and WING_COLORS[boss.wing]
        local nameStr = wingHex and ("|cff" .. wingHex .. boss.name .. "|r") or boss.name
        local bossLabel = ((boss.default or boss.note) and raid.key ~= "debug")
            and (nameStr .. " |cfffb2c36(!)|r")
            or nameStr
        local cb = createCheckbox(panel, bossLabel, NAME_W)
        cb:SetPoint("TOPLEFT", gridAnchor, "TOPLEFT", 0, y)
        cb.OnChange = function(_, checked)
            particlesData(raid).bosses[boss.name] = checked or nil
        end
        bossCBs[boss.name] = cb

        -- Greys out the seconds box while linger is off, so the row reads as
        -- "this number isn't doing anything right now" without hiding the value.
        local stepper
        local function paintStepper(on)
            stepper.value:SetTextColor(unpack(on and C.red or C.textDim))
        end

        local lcb = createCheckbox(panel, "", 16)
        lcb:SetPoint("TOPLEFT", gridAnchor, "TOPLEFT", LINGER_X, y)
        lcb.OnChange = function(_, checked)
            local d = particlesData(raid)
            d.linger[boss.name] = checked or nil
            -- Stamp the effective duration on enable so the stored value always
            -- matches what the box shows.
            if checked then d.lingerSecs[boss.name] = lingerSeconds(raid, boss) end
            paintStepper(checked)
        end
        lingerCBs[boss.name] = lcb

        stepper = buildStepper(panel, {
            min = 1, max = MAX_LINGER_SECONDS, valueWidth = 30,
            get = function() return lingerSeconds(raid, boss) end,
            set = function(v) particlesData(raid).lingerSecs[boss.name] = v end,
        })
        stepper:SetPoint("TOPLEFT", gridAnchor, "TOPLEFT", SECS_X, y - 1)
        stepper.Paint = paintStepper
        lingerSteppers[boss.name] = stepper
    end

    local function refreshPanel()
        local d = particlesData(raid)
        enable:SetChecked(d.enabled)
        if chatCB then chatCB:SetChecked(d.chat == true) end
        for name, cb in pairs(bossCBs) do
            cb:SetChecked(d.bosses[name] == true)
        end
        for name, lcb in pairs(lingerCBs) do
            local on = d.linger[name] == true
            lcb:SetChecked(on)
            lingerSteppers[name].Refresh()
            lingerSteppers[name].Paint(on)
        end
    end
    shell:SetScript("OnShow", refreshPanel)
    refreshPanel()

    return shell
end

local function buildGeneralPanel(parent)
    local shell, panel = makeScrollPanel(parent)

    -- ── Master switch ─────────────────────────────────────────────────────
    local function getModuleData()
        addon.db.settings.particles = addon.db.settings.particles or {}
        return addon.db.settings.particles
    end

    local enableCB = createCheckbox(panel, "Enable Particles", 260)
    enableCB:SetPoint("TOPLEFT", 14, -14)
    enableCB.OnChange = function(_, checked)
        getModuleData().enabled = checked
        if addon.Particles then addon.Particles.refresh() end
        UI.RefreshTabDots()
    end

    -- ── Class filter ──────────────────────────────────────────────────────
    local function getClassData()
        addon.db.settings.particles         = addon.db.settings.particles or {}
        addon.db.settings.particles.classes = addon.db.settings.particles.classes or { WARRIOR = true }
        return addon.db.settings.particles.classes
    end

    local classHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    classHeader:SetPoint("TOPLEFT", enableCB, "BOTTOMLEFT", 0, -18)
    classHeader:SetText("Class Filter")
    UI.tint(classHeader, C.red)

    local classDesc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    classDesc:SetPoint("TOPLEFT", classHeader, "BOTTOMLEFT", 0, -4)
    classDesc:SetText("Particle system only runs while playing a selected class")
    UI.tint(classDesc, C.textGrey)

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
    UI.tint(headline, C.red)

    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", headline, "BOTTOMLEFT", 0, -4)
    desc:SetWidth(560); desc:SetJustifyH("LEFT")
    desc:SetText("Select the particle density used when particles are enabled for a boss encounter. Raids always use 0 between encounters, aka particles are disabled on trash. Outside of raids it will use the same particle density as selected here")
    UI.tint(desc, C.textGrey)

    local rowLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    rowLabel:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -34)
    rowLabel:SetText("Encounter density:")
    UI.tint(rowLabel, C.textWhite)

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
    UI.tint(rangeNote, C.textDim)

    local function refreshDisplay()
        enableCB:SetChecked(getModuleData().enabled == true)
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
            btn.text:SetFontObject("GameFontNormalSmall")   -- matches every other inner sidebar list
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
            -- Built on first selection (activateTab resolves the function) —
            -- eight raids' worth of boss rows at once is a long enough stall to
            -- risk the "script ran too long" watchdog on slower machines.
            shell.raidPanels[raid.key] = function()
                return buildRaidPanel(detail, raid,
                    function(checked) setDot(raid, checked) end)
            end
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
    local panel, _, _, addSubTab = W.makeSubTabPanel(parent)

    local debugRaid
    for _, raid in ipairs(addon.RAIDS) do
        if raid.key == "debug" then debugRaid = raid end
    end

    addSubTab("general", "General", 80, buildGeneralPanel)
    addSubTab("raids",   "Raids",   80, buildParticlesRaidsPanel)
    addSubTab("debug",   "Debug",   80, function(subContent)
        return debugRaid and buildRaidPanel(subContent, debugRaid)
            or CreateFrame("Frame", nil, subContent)
    end)

    selectSubTab(panel, "general")
    return panel
end

-- Adds the Particles entry to core's settings sidebar. Because this lives in
-- the module, disabling the addon removes the tab entirely.
UI.RegisterTab({ key = "particles", label = "Particles", order = 20, build = buildParticlesPanel,
    status = function()
        local d = addon.db and addon.db.settings and addon.db.settings.particles
        return d and d.enabled or false
    end })
