-- Driev's Essentials — Nameplates module: settings UI.
--
-- This addon only loads when the core addon is present (## Dependencies in the
-- .toc guarantees load order), so the shared namespace below always exists.
local addon = _G.DrievEssentials
if not addon then return end

local Data = addon.NameplatesData
if not Data then return end

local UI = addon.UI
local C  = UI.colors
local W  = UI.widgets

local applyBackdrop        = W.applyBackdrop
local createCheckbox       = W.createCheckbox
local createDropdown       = W.createDropdown
local createScrollDropdown = W.createScrollDropdown
local createTab            = W.createTab
local selectSubTab         = W.selectSubTab
local makeScrollPanel      = W.makeScrollPanel
local attachScrollTrack    = W.attachScrollTrack
local buildStepper         = W.buildStepper
local flatButton           = W.flatButton

-- Every accessor below re-reads addon.db live (never captured once at build
-- time) so a profile switch/import — which repoints addon.db at a different
-- table — is reflected on the next OnShow instead of writing to the old one.
local function npData()
    addon.db.settings.nameplates = addon.db.settings.nameplates or {}
    return addon.db.settings.nameplates
end

local function gen()
    local t = npData()
    t.general = t.general or {}
    return t.general
end

local function grp(key)
    local t = npData()
    t[key] = t[key] or {}
    return t[key]
end

local function threatData()
    local t = npData()
    t.threat = t.threat or {}
    t.threat.colors   = t.threat.colors or {}
    t.threat.reaction = t.threat.reaction or {}
    return t.threat
end

local function targetData()
    local t = npData()
    t.target = t.target or {}
    return t.target
end

local function iconData(key)
    local t = npData()
    t.icons = t.icons or {}
    t.icons[key] = t.icons[key] or {}
    return t.icons[key]
end

-- Any settings change goes straight back through the engine's single
-- re-derive-everything entry point, so the plates on screen update as you click
-- rather than at the next pull.
local function apply()
    if addon.Nameplates then addon.Nameplates.refresh() end
end

-- Puts the engine into (or out of) aura preview: fake icons on every plate of
-- one unit type, for as long as that type's aura tab is open. Guarded because
-- the settings UI can outlive an engine that failed to load.
local function setAuraPreview(unitKey)
    local NP = addon.Nameplates
    if NP and NP.SetAuraPreview then NP.SetAuraPreview(unitKey) end
end

-- Hover help. Where a setting needs a paragraph to justify itself but the panel
-- only has room for a line, the line goes under the control and the paragraph
-- goes here — so the full story is one hover away instead of gone.
--
-- HookScript, not SetScript: the widgets set their own OnEnter/OnLeave for the
-- hover highlight, and replacing those would trade the border glow for the
-- tooltip. `body` is a list of paragraphs, each wrapped by the tooltip itself.
local function attachTooltip(widget, title, body)
    widget:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(title, 1, 1, 1)
        for _, para in ipairs(body) do
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(para, 0.75, 0.75, 0.75, true)
        end
        GameTooltip:Show()
    end)
    widget:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

local function mediaList(kind, fallback)
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    local list = {}
    if LSM then
        for _, name in ipairs(LSM:List(kind) or {}) do list[#list + 1] = name end
    end
    if #list == 0 then list[1] = fallback end
    return list
end

-- A clickable colour swatch opening WoW's native colour picker (RGB only — this
-- module keeps opacity on its own steppers, so the two never fight over one
-- value). Handles both the modern SetupColorPickerAndShow API and the older
-- field-based one, since which is present isn't guaranteed across Classic Era
-- builds.
local function colorSwatch(parent, getRGB, setRGB, onChange, size)
    local swatch = CreateFrame("Button", nil, parent, "BackdropTemplate")
    swatch:SetSize(size or 20, size or 20)
    applyBackdrop(swatch, 1, { 1, 1, 1 }, C.tabBorder)

    local function refresh()
        local r, g, b = getRGB()
        swatch:SetBackdropColor(r or 1, g or 1, b or 1, 1)
    end

    swatch:SetScript("OnClick", function()
        local r, g, b = getRGB()
        local function commit()
            local nr, ng, nb = ColorPickerFrame:GetColorRGB()
            setRGB(nr, ng, nb)
            refresh()
            if onChange then onChange() end
        end
        local function cancel()
            setRGB(r, g, b)
            refresh()
            if onChange then onChange() end
        end
        if ColorPickerFrame.SetupColorPickerAndShow then
            ColorPickerFrame:SetupColorPickerAndShow({
                r = r, g = g, b = b, hasOpacity = false,
                swatchFunc = commit, cancelFunc = cancel,
            })
        else
            ColorPickerFrame.hasOpacity = false
            ColorPickerFrame.func       = commit
            ColorPickerFrame.cancelFunc = cancel
            ColorPickerFrame:SetColorRGB(r, g, b)
            ColorPickerFrame:Hide()  -- force OnShow to refire with these values
            ColorPickerFrame:Show()
        end
    end)

    swatch.Refresh = refresh
    refresh()
    return swatch
end

-- Themed single-line text input, matching the numeric boxes elsewhere in the
-- addon (bordered wrapper + borderless EditBox inside).
local function textBox(parent, w, h, onCommit, maxLetters)
    local wrap = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    wrap:SetSize(w, h or 20)
    applyBackdrop(wrap, 1, C.panelDark, C.tabBorder)

    local box = CreateFrame("EditBox", nil, wrap)
    box:SetPoint("TOPLEFT", 4, 0)
    box:SetPoint("BOTTOMRIGHT", -4, 0)
    box:SetAutoFocus(false)
    box:SetFontObject("GameFontNormalSmall")
    box:SetTextColor(unpack(C.textWhite))
    box:SetMaxLetters(maxLetters or 40)

    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEditFocusLost", function(self)
        if onCommit then onCommit(self:GetText()) end
    end)
    wrap:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(unpack(C.red)) end)
    wrap:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(unpack(C.tabBorder)) end)

    wrap.box = box
    return wrap
end

-- Grey prompt inside an empty box. A bare Classic Era EditBox has no
-- placeholder of its own, and the alternative — a label beside the box — costs
-- panel width to say what the box can say for free.
--
-- Hidden while the box has focus as well as while it has text: once you're
-- typing into it you know what it's for, and prompt text under a live cursor
-- reads as content that won't delete.
local function setPlaceholder(wrap, text)
    local box  = wrap.box
    local hint = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("LEFT", 0, 0)
    hint:SetPoint("RIGHT", 0, 0)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(false)
    hint:SetText(text)
    hint:SetTextColor(unpack(C.textDim))

    local function update()
        hint:SetShown(not box:HasFocus() and (box:GetText() or "") == "")
    end
    -- Hooked, not set: every one of these already has a handler of its own on
    -- at least one of the three.
    box:HookScript("OnTextChanged", update)
    box:HookScript("OnEditFocusGained", update)
    box:HookScript("OnEditFocusLost", update)
    update()

    wrap.hint = hint
    return wrap
end

-- ── Form builder ─────────────────────────────────────────────────────────────
-- The five settings panels are all the same shape — a vertical run of labelled
-- controls, each reading and writing one settings key and then re-applying. A
-- tiny builder keeps them declarative rather than 200 lines of SetPoint each,
-- and collects every control's refresh function so OnShow can re-sync the lot.
local LABEL_W = 200
local ROW_W   = 620

-- insetX/insetY are where the first control lands inside the panel. They're
-- only ever passed by the Search tab, which puts one control in a container of
-- its own and so needs it flush rather than indented like a full page.
local function newForm(panel, insetX, insetY)
    local form = { panel = panel, controls = {}, last = nil,
                   insetX = insetX or 14, insetY = insetY or 14 }

    function form:place(obj, gap)
        if self.last then
            obj:SetPoint("TOPLEFT", self.last, "BOTTOMLEFT", 0, -(gap or 8))
        else
            obj:SetPoint("TOPLEFT", self.panel, "TOPLEFT", self.insetX, -self.insetY)
        end
        self.last = obj
        return obj
    end

    function form:header(text, desc)
        local h = self.panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        self:place(h, 20)
        h:SetText(text)
        h:SetTextColor(unpack(C.red))
        if desc then
            local d = self.panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            d:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -4)
            d:SetWidth(ROW_W); d:SetJustifyH("LEFT")
            d:SetText(desc)
            d:SetTextColor(unpack(C.textGrey))
            self.last = d
        end
        return h
    end

    function form:note(text)
        local n = self.panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        self:place(n, 6)
        n:SetWidth(ROW_W); n:SetJustifyH("LEFT")
        n:SetText(text)
        n:SetTextColor(unpack(C.textDim))
        return n
    end

    function form:check(label, get, set, onChange)
        local cb = createCheckbox(self.panel, label, 400)
        self:place(cb, 10)
        cb.OnChange = function(_, checked)
            set(checked)
            if onChange then onChange(checked) else apply() end
        end
        self.controls[#self.controls + 1] = function() cb:SetChecked(get() and true or false) end
        return cb
    end

    function form:row(label)
        local row = CreateFrame("Frame", nil, self.panel)
        row:SetSize(ROW_W, 22)
        self:place(row, 8)
        local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("LEFT", 0, 0)
        lbl:SetWidth(LABEL_W); lbl:SetJustifyH("LEFT")
        lbl:SetText(label)
        lbl:SetTextColor(unpack(C.textGrey))
        row.lbl = lbl
        return row
    end

    function form:stepper(label, min, max, get, set, suffix, step)
        local row = self:row(label)
        local st = buildStepper(row, {
            min = min, max = max, step = step or 1, valueWidth = 46,
            get = function() return tonumber(get()) or min end,
            set = function(v) set(v); apply() end,
        })
        st:SetPoint("LEFT", row.lbl, "RIGHT", 6, 0)
        if suffix then
            local s = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            s:SetPoint("LEFT", st.plus, "RIGHT", 6, 0)
            s:SetText(suffix)
            s:SetTextColor(unpack(C.textDim))
        end
        self.controls[#self.controls + 1] = st.Refresh
        return row
    end

    function form:dropdown(label, options, get, set, width)
        local row = self:row(label)
        local dd = createDropdown(row, width or 160, options, get, set, apply)
        dd:SetPoint("LEFT", row.lbl, "RIGHT", 6, 0)
        self.controls[#self.controls + 1] = dd.Refresh
        return row
    end

    -- `kind` doubles as the preview mode, so each row shows the font it names /
    -- the bar texture it names rather than just spelling it out.
    function form:media(label, kind, fallback, get, set, width)
        local row = self:row(label)
        local dd = createScrollDropdown(row, width or 200,
            function() return mediaList(kind, fallback) end,
            function(name) set(name); apply() end,
            { preview = kind })
        dd:SetPoint("LEFT", row.lbl, "RIGHT", 6, 0)
        self.controls[#self.controls + 1] = function() dd:setValue(get() or fallback) end
        return row
    end

    -- getTbl() must hand back the live {r, g, b} table to mutate in place, so
    -- the swatch always edits whichever profile is active right now.
    function form:color(label, getTbl)
        local row = self:row(label)
        local sw = colorSwatch(row,
            function()
                local c = getTbl() or {}
                return c[1] or 1, c[2] or 1, c[3] or 1
            end,
            function(r, g, b)
                local c = getTbl()
                if c then c[1], c[2], c[3] = r, g, b end
            end,
            apply)
        sw:SetPoint("LEFT", row.lbl, "RIGHT", 6, 0)
        self.controls[#self.controls + 1] = sw.Refresh
        return row
    end

    function form:refresh()
        for _, fn in ipairs(self.controls) do fn() end
    end

    return form
end

-- ── General ──────────────────────────────────────────────────────────────────
local OUTLINE_OPTIONS = {
    { value = "NONE",         label = "None"  },
    { value = "OUTLINE",      label = "Thin"  },
    { value = "THICKOUTLINE", label = "Thick" },
}

-- Wraps a content function — a run of `form:` calls and nothing else — in the
-- scrolling panel every settings tab uses. Splitting the two apart is what lets
-- the Search tab replay the exact same calls against a recorder (see
-- collectEntries) to learn what settings exist without building a single frame:
-- a setting can't be in one and missing from the other, because there is only
-- one list of them.
local function formPanel(parent, fill)
    local shell, panel = makeScrollPanel(parent)
    local form = newForm(panel)
    fill(form)
    shell:HookScript("OnShow", function() form:refresh() end)
    return shell
end

local function generalContent(form)
    form:header("Nameplates",
        "Replaces Blizzard's nameplates with this addon's own, the way Plater does: the game keeps handling positioning and click-targeting, everything drawn on top is ours.")

    form:check("Enable Nameplates",
        function() return npData().enabled end,
        function(v) npData().enabled = v end,
        function() apply(); UI.RefreshTabDots() end)

    form:header("Appearance", "Shared by every nameplate. Textures and fonts come from LibSharedMedia, so anything a media pack you have installed adds shows up here automatically.")
    form:media("Health bar texture", "statusbar", "Blizzard",
        function() return gen().texture end,
        function(v) gen().texture = v end)
    form:media("Cast bar texture", "statusbar", "Blizzard",
        function() return gen().castTexture end,
        function(v) gen().castTexture = v end)
    form:media("Font", "font", "Friz Quadrata TT",
        function() return gen().font end,
        function(v) gen().font = v end)
    form:stepper("Font size", 6, 24,
        function() return gen().fontSize end,
        function(v) gen().fontSize = v end)
    form:dropdown("Font outline", OUTLINE_OPTIONS,
        function() return gen().fontOutline or "OUTLINE" end,
        function(v) gen().fontOutline = v end, 120)

    form:header("Per-text fonts", "Each of these can use its own font instead of the one above. Size and outline still come from the general settings — this is the typeface only.")
    -- Checkbox plus picker rather than a "same as general" entry in the font
    -- list: that list is LibSharedMedia's, every entry in it renders itself in
    -- the font it names, and a sentinel row would have nothing to render with.
    form:check("Name uses its own font",
        function() return gen().nameFontEnabled end,
        function(v) gen().nameFontEnabled = v end)
    form:media("Name font", "font", "Friz Quadrata TT",
        function() return gen().nameFont end,
        function(v) gen().nameFont = v end)
    form:check("Health text uses its own font",
        function() return gen().healthFontEnabled end,
        function(v) gen().healthFontEnabled = v end)
    form:media("Health text font", "font", "Friz Quadrata TT",
        function() return gen().healthFont end,
        function(v) gen().healthFont = v end)
    form:check("Level text uses its own font",
        function() return gen().levelFontEnabled end,
        function(v) gen().levelFontEnabled = v end)
    form:media("Level font", "font", "Friz Quadrata TT",
        function() return gen().levelFont end,
        function(v) gen().levelFont = v end)
    form:note("A picker with its box unticked is ignored, and keeps whatever you left it on for next time.")
    form:stepper("Border thickness", 0, 5,
        function() return gen().borderSize end,
        function(v) gen().borderSize = v end, "px")
    form:color("Border colour", function() gen().borderColor = gen().borderColor or { 0, 0, 0 }; return gen().borderColor end)
    form:color("Background colour", function() gen().bgColor = gen().bgColor or { 0.08, 0.08, 0.10 }; return gen().bgColor end)
    form:stepper("Background opacity", 0, 100,
        function() return gen().bgAlpha end,
        function(v) gen().bgAlpha = v end, "%", 5)
    form:stepper("Global scale", 50, 200,
        function() return gen().scale end,
        function(v) gen().scale = v end, "%", 5)
    form:stepper("Nameplate opacity", 20, 100,
        function() return gen().alpha end,
        function(v) gen().alpha = v end, "%", 5)

    form:header("Fade bystanders", "Dims everything that isn't actually fighting you or your group, so the pull you're in stands out from whatever else is going on around it. Your current target is never dimmed.")
    form:check("Fade nameplates not in combat with me",
        function() return gen().dimInactive end,
        function(v) gen().dimInactive = v end)
    form:stepper("Faded opacity", 5, 100,
        function() return gen().inactiveAlpha end,
        function(v) gen().inactiveAlpha = v end, "%", 5)
    form:note("A mob is counted as fighting you if you're on its threat table, or — where the game won't say — if it's swinging at you, your pet, or someone in your group.")

    form:header("Hover highlight", "Lightens the health bar of whichever unit the cursor is over, so you can see what you're about to click in a packed pull. Pointing at the mob itself counts, not only at its nameplate.")
    form:check("Highlight the nameplate under the mouse",
        function() return gen().hoverHighlight ~= false end,
        function(v) gen().hoverHighlight = v end)
    form:stepper("Highlight opacity", 0, 100,
        function() return gen().hoverAlpha end,
        function(v) gen().hoverAlpha = v end, "%", 5)

    form:header("Engine", "These drive Blizzard's own nameplate CVars. The game refuses CVar changes during combat, so anything changed mid-fight is applied the moment you drop out of it.")
    form:check("Show enemy nameplates",
        function() return gen().showEnemies end,
        function(v) gen().showEnemies = v end)
    form:check("Show friendly nameplates",
        function() return gen().showFriends end,
        function(v) gen().showFriends = v end)
    form:check("Always show nameplates (not only in combat)",
        function() return gen().showAll end,
        function(v) gen().showAll = v end)
    form:stepper("View distance", 5, 41,
        function() return gen().maxDistance end,
        function(v) gen().maxDistance = v end, "yards")
    form:check("Stack nameplates instead of overlapping them",
        function() return gen().stacking end,
        function(v) gen().stacking = v end)
    form:stepper("Vertical spacing", 50, 250,
        function() return gen().overlapV end,
        function(v) gen().overlapV = v end, "%", 5)
    form:check("Keep nameplates the same size at any distance",
        function() return gen().constantSize ~= false end,
        function(v) gen().constantSize = v end)
    form:note("The game shrinks distant nameplates and grows the one you're targeting, on top of anything this addon does — so a 15% target scale ends up nearer 40%. This pins the game's own scaling to 1, leaving the Scale settings here as the only thing sizing a plate. Unticking puts back the values you had before it was first ticked.")
    form:note("The click area is the invisible box the game uses for targeting, separate from the bar you see. It's sized automatically to match the widest bar, so it follows your width, height and scale settings on its own.")
end

local function buildGeneralPanel(parent)
    return formPanel(parent, generalContent)
end

-- ── Enemy NPC / Enemy Player ─────────────────────────────────────────────────
-- One builder for both: the two unit types differ only in their heading text and
-- the class-colour option, so a second near-identical 150-line panel would just
-- be somewhere for the two to drift apart.
-- Straight off Data's list, so the dropdown can't offer a format the engine
-- doesn't know how to draw. The labels there are the examples themselves.
local function healthFormatOptions()
    local out = {}
    for _, e in ipairs(Data.HEALTH_FORMATS) do
        out[#out + 1] = { value = e.value, label = e.label }
    end
    return out
end

local HEALTH_TEXT_ANCHORS = {
    { value = "LEFT",   label = "Left"   },
    { value = "CENTER", label = "Centre" },
    { value = "RIGHT",  label = "Right"  },
}

-- Same deal as the health formats: built off Data's list so the picker can't
-- offer a placement the engine has no anchor points for.
local function namePlacementOptions()
    local out = {}
    for _, e in ipairs(Data.NAME_PLACEMENTS) do
        out[#out + 1] = { value = e.value, label = e.label }
    end
    return out
end

local function unitContent(form, key, title, desc, enableLabel, extras)
    form:header(title, desc)
    form:check(enableLabel,
        function() return grp(key).enabled end,
        function(v) grp(key).enabled = v end)
    form:note("Switched off, these units keep Blizzard's own nameplates instead of being hidden.")

    form:header("Size")
    form:stepper("Bar width", 40, 300,
        function() return grp(key).width end,
        function(v) grp(key).width = v end, "px", 2)
    form:stepper("Bar height", 4, 40,
        function() return grp(key).height end,
        function(v) grp(key).height = v end, "px")
    form:stepper("Scale", 50, 200,
        function() return grp(key).scale end,
        function(v) grp(key).scale = v end, "%", 5)

    if extras then extras(form, key) end

    form:header("Name and level")
    form:check("Show name",
        function() return grp(key).showName end,
        function(v) grp(key).showName = v end)
    form:stepper("Name font size", 6, 24,
        function() return grp(key).nameSize end,
        function(v) grp(key).nameSize = v end)
    form:dropdown("Position", namePlacementOptions(),
        function() return grp(key).namePlacement or "aboveLeft" end,
        function(v) grp(key).namePlacement = v end, 170)
    form:stepper("Nudge X", -150, 150,
        function() return grp(key).nameX end,
        function(v) grp(key).nameX = v end, "px")
    form:stepper("Nudge Y", -100, 100,
        function() return grp(key).nameY end,
        function(v) grp(key).nameY = v end, "px")
    form:note("Inner places the name on the bar itself. Below sits where the cast bar goes, so nudge one of them clear if you use both.")
    form:stepper("Truncate name after", 0, 40,
        function() return grp(key).truncateName end,
        function(v) grp(key).truncateName = v end, "characters (0 = never)")
    form:check("Show level",
        function() return grp(key).showLevel end,
        function(v) grp(key).showLevel = v end)
    form:note("Skull-level mobs show the lowest they could be with a \"+\" — the game won't give an exact number for anything that far above you.")

    form:header("Health text")
    form:check("Show health text on the bar",
        function() return grp(key).showHealthText end,
        function(v) grp(key).showHealthText = v end)
    form:dropdown("Format", healthFormatOptions(),
        function() return grp(key).healthFormat or "percent" end,
        function(v) grp(key).healthFormat = v end, 140)
    form:note("Each option is written the way it will appear on the bar.")
    form:dropdown("Align to", HEALTH_TEXT_ANCHORS,
        function() return grp(key).healthTextAnchor or "RIGHT" end,
        function(v) grp(key).healthTextAnchor = v end, 140)
    form:stepper("Nudge X", -100, 100,
        function() return grp(key).healthTextX end,
        function(v) grp(key).healthTextX = v end, "px")
    form:stepper("Nudge Y", -50, 50,
        function() return grp(key).healthTextY end,
        function(v) grp(key).healthTextY = v end, "px")
    form:note("The nudge is applied on top of the alignment, so you can sit the text just off the end of the bar or lift it above.")

    form:header("Cast bar")
    form:check("Show cast bar",
        function() return grp(key).showCastBar end,
        function(v) grp(key).showCastBar = v end)
    form:stepper("Cast bar height", 4, 30,
        function() return grp(key).castHeight end,
        function(v) grp(key).castHeight = v end, "px")
    form:stepper("Gap below health bar", 0, 20,
        function() return grp(key).castOffset end,
        function(v) grp(key).castOffset = v end, "px")
    form:check("Show spell icon",
        function() return grp(key).castShowIcon end,
        function(v) grp(key).castShowIcon = v end)
    form:check("Show spell name",
        function() return grp(key).castShowName end,
        function(v) grp(key).castShowName = v end)
    form:check("Show remaining cast time",
        function() return grp(key).castShowTimer end,
        function(v) grp(key).castShowTimer = v end)
    form:color("Cast colour", function()
        local g = grp(key); g.castColor = g.castColor or { 0.90, 0.70, 0.15 }; return g.castColor
    end)
    form:color("Channel colour", function()
        local g = grp(key); g.castChannelColor = g.castChannelColor or { 0.35, 0.75, 0.95 }; return g.castChannelColor
    end)
end

local function enemyNPCContent(form)
    unitContent(form, "enemyNPC", "Enemy NPC",
        "Everything you can attack that isn't a player — trash, bosses, neutral mobs. Friendly NPCs borrow this layout too, with a friendly reaction colour.",
        "Use custom nameplates for enemy NPCs")
end

local function enemyPlayerContent(form)
    unitContent(form, "enemyPlayer", "Enemy Player",
        "Hostile players — the other faction in the world, and anyone flagged for PvP. Friendly players borrow this layout too.",
        "Use custom nameplates for enemy players",
        function(form, key)
            form:header("Colour")
            form:check("Colour the health bar by class",
                function() return grp(key).classColor end,
                function(v) grp(key).classColor = v end)
            form:check("Colour the name by class",
                function() return grp(key).classColorName end,
                function(v) grp(key).classColorName = v end)
            form:note("Threat colouring never applies to players, so these (or the hostile reaction colour) are what you see. Either can be used without the other.")

            form:header("Players you can't attack",
                "Anyone on your own side, and the other faction where PvP isn't live. There's no health worth watching and no cast worth interrupting on them.")
            form:check("Show only their name, with no bar",
                function() return grp(key).nameOnlyWhenSafe end,
                function(v) grp(key).nameOnlyWhenSafe = v end)
            form:note("The bar, its outline, the level, the health text and the cast bar all go; the name stays exactly where your Position setting puts it. Flagging for PvP brings the full plate back straight away.")
        end)
end

local function buildEnemyNPCPanel(parent)
    return formPanel(parent, enemyNPCContent)
end

local function buildEnemyPlayerPanel(parent)
    return formPanel(parent, enemyPlayerContent)
end

-- ── Colors / Threat ──────────────────────────────────────────────────────────
local function threatContent(form)
    form:header("Threat colouring",
        "Recolours enemy NPC health bars by how much threat you have on them. Players are never threat-coloured — they use their class or reaction colour instead.")
    form:check("Enable threat colouring",
        function() return threatData().enabled end,
        function(v) threatData().enabled = v end)
    form:check("Tank mode — I'm the one meant to be holding threat",
        function() return threatData().tankMode end,
        function(v) threatData().tankMode = v end)
    form:check("Only colour units that are actually in combat",
        function() return threatData().combatOnly end,
        function(v) threatData().combatOnly = v end)

    form:header("Threat colours — DPS and healers")
    form:color("Not on me (good)", function()
        local c = threatData().colors; c.noThreat = c.noThreat or { 0.25, 0.80, 0.35 }; return c.noThreat
    end)
    form:color("Climbing the list", function()
        local c = threatData().colors; c.gaining = c.gaining or { 0.95, 0.80, 0.20 }; return c.gaining
    end)
    form:color("I have aggro (bad)", function()
        local c = threatData().colors; c.aggro = c.aggro or { 0.90, 0.15, 0.15 }; return c.aggro
    end)
    form:color("On the main tank", function()
        local c = threatData().colors; c.mainTank = c.mainTank or { 0.45, 0.58, 0.72 }; return c.mainTank
    end)
    form:note("The main tank colour needs a raid Main Tank assignment to appear, so it never shows up solo or in a party. It's checked after your own threat, so it can't hide a mob that's actually on you.")

    form:header("Threat colours — tank mode", "The same three states with their meanings flipped: holding threat is what you want.")
    form:color("Holding threat (good)", function()
        local c = threatData().colors; c.tankSecure = c.tankSecure or { 0.25, 0.55, 0.95 }; return c.tankSecure
    end)
    form:color("Losing threat", function()
        local c = threatData().colors; c.tankLosing = c.tankLosing or { 0.95, 0.80, 0.20 }; return c.tankLosing
    end)
    form:color("Lost it entirely (bad)", function()
        local c = threatData().colors; c.tankLost = c.tankLost or { 0.90, 0.15, 0.15 }; return c.tankLost
    end)

    form:header("Priority against NPC colours",
        "An NPC tagged on the NPC List tab normally keeps its own colour no matter what your threat on it is. These decide when threat is allowed to take it over.")
    form:check("Threat colours override custom NPC colours",
        function() return threatData().overrideNpcColors end,
        function(v) threatData().overrideNpcColors = v end)
    form:check("...only once I've actually pulled threat",
        function() return threatData().overrideOnlyOnAggro end,
        function(v) threatData().overrideOnlyOnAggro = v end)
    form:check("...counting climbing the threat list as pulled",
        function() return threatData().overrideOnGaining end,
        function(v) threatData().overrideOnGaining = v end)
    form:note("With the first two ticked, a tagged NPC keeps its colour right up until it turns on you — then it flips to the aggro colour so you can't miss it. Add the third and it flips one step earlier, while you're still climbing the list and can still do something about it. Untick the second to have threat colouring win at every threat level.")
    form:note("In tank mode the same two steps are losing your grip on threat and having lost it outright.")

    form:header("Reaction colours", "Used whenever threat colouring doesn't apply — out of combat, on units you're not on the threat table of, and on friendly units.")
    form:color("Hostile", function()
        local r = threatData().reaction; r.hostile = r.hostile or { 0.85, 0.16, 0.16 }; return r.hostile
    end)
    form:color("Neutral", function()
        local r = threatData().reaction; r.neutral = r.neutral or { 0.92, 0.78, 0.20 }; return r.neutral
    end)
    form:color("Friendly", function()
        local r = threatData().reaction; r.friendly = r.friendly or { 0.20, 0.75, 0.25 }; return r.friendly
    end)
    form:color("Tapped by someone else", function()
        local r = threatData().reaction; r.tapped = r.tapped or { 0.50, 0.50, 0.50 }; return r.tapped
    end)
end

local function buildThreatPanel(parent)
    return formPanel(parent, threatContent)
end

-- ── Icons ────────────────────────────────────────────────────────────────────
-- Listed as the nine frame anchor points rather than a free-form dropdown of
-- every string a frame will accept, because those nine are the ones that mean
-- something against a health bar.
local ICON_ANCHORS = {
    { value = "LEFT",        label = "Left edge"     },
    { value = "RIGHT",       label = "Right edge"    },
    { value = "TOP",         label = "Top edge"      },
    { value = "BOTTOM",      label = "Bottom edge"   },
    { value = "CENTER",      label = "Centre"        },
    { value = "TOPLEFT",     label = "Top left"      },
    { value = "TOPRIGHT",    label = "Top right"     },
    { value = "BOTTOMLEFT",  label = "Bottom left"   },
    { value = "BOTTOMRIGHT", label = "Bottom right"  },
}

local function iconsContent(form)
    form:header("Icons",
        "Markers hung off the health bar. Each one picks a point on the bar to sit against, then gets nudged from there — the icon is centred on that point, so changing its size won't move it.")

    -- One builder for both: they differ only in their heading and what turns
    -- them on, and two near-identical blocks would just be somewhere for the
    -- offsets to drift apart.
    local function iconGroup(title, key, desc, showLabel)
        form:header(title, desc)
        form:check(showLabel,
            function() return iconData(key).enabled ~= false end,
            function(v) iconData(key).enabled = v end)
        form:dropdown("Sit against", ICON_ANCHORS,
            function() return iconData(key).anchor or "LEFT" end,
            function(v) iconData(key).anchor = v end, 150)
        form:stepper("Nudge X", -150, 150,
            function() return iconData(key).x end,
            function(v) iconData(key).x = v end, "px")
        form:stepper("Nudge Y", -150, 150,
            function() return iconData(key).y end,
            function(v) iconData(key).y = v end, "px")
        form:stepper("Size", 4, 48,
            function() return iconData(key).size end,
            function(v) iconData(key).size = v end, "px")
    end

    iconGroup("Raid marker", "raidMarker",
        "The skull, cross, star and the rest, shown on whatever your group has marked.",
        "Show the raid marker")

    iconGroup("Quest icon", "quest",
        "Shown on mobs that count towards a quest you're on: a sword when the mob itself is the objective, a bag when you need something it drops.",
        "Show the quest icon")

    form:note("Quest status is read off the mob's tooltip, which is the only place the game exposes it — so it can take a moment to appear on a plate that has only just come into view.")
end

local function buildIconsPanel(parent)
    return formPanel(parent, iconsContent)
end

-- ── Target ───────────────────────────────────────────────────────────────────
-- Built once from Data.TARGET_INDICATOR_ORDER (pairs() over the preset table has
-- no order, and a picker that reshuffles itself every login is unusable).
local INDICATOR_OPTIONS

local function indicatorOptions()
    if not INDICATOR_OPTIONS then
        INDICATOR_OPTIONS = {}
        for _, name in ipairs(Data.TARGET_INDICATOR_ORDER) do
            INDICATOR_OPTIONS[#INDICATOR_OPTIONS + 1] = { value = name, label = name }
        end
    end
    return INDICATOR_OPTIONS
end

local function targetContent(form)
    form:header("Target", "Makes the nameplate of whatever you're targeting stand out from the pack.")
    form:check("Enable target styling",
        function() return targetData().enabled end,
        function(v) targetData().enabled = v end)

    form:header("Highlight")
    form:check("Outline the targeted nameplate",
        function() return targetData().highlight end,
        function(v) targetData().highlight = v end)
    form:color("Outline colour", function()
        local t = targetData(); t.highlightColor = t.highlightColor or { 1, 1, 1 }; return t.highlightColor
    end)
    form:stepper("Outline thickness", 1, 6,
        function() return targetData().highlightSize end,
        function(v) targetData().highlightSize = v end, "px")

    form:header("Indicator")
    form:dropdown("Style", indicatorOptions(),
        function() return targetData().indicator or "None" end,
        function(v) targetData().indicator = v end, 160)
    form:check("Override the indicator's colour",
        function() return targetData().indicatorColorEnabled end,
        function(v) targetData().indicatorColorEnabled = v end)
    form:color("Indicator colour", function()
        local t = targetData(); t.indicatorColor = t.indicatorColor or { 1, 1, 1 }; return t.indicatorColor
    end)
    form:note("Ornaments placed around the targeted nameplate's health bar. Some sit at the four corners (Pins, Magneto, Gray Bold, Silver), others at the left and right edges (Ornament, Golden, Epic). They scale with the nameplate so they keep their proportions at any size, and each preset carries its own colour unless you override it above. \"None\" turns them off.")

    form:header("Emphasis")
    form:stepper("Target scale", 50, 250,
        function() return targetData().scale end,
        function(v) targetData().scale = v end, "%", 5)
    form:stepper("Target opacity", 20, 100,
        function() return targetData().alpha end,
        function(v) targetData().alpha = v end, "%", 5)
    form:check("Draw the target's nameplate above the others",
        function() return targetData().raise end,
        function(v) targetData().raise = v end)

    form:header("Everything else")
    form:check("Fade the other nameplates while I have a target",
        function() return targetData().dimOthers end,
        function(v) targetData().dimOthers = v end)
    form:stepper("Faded opacity", 0, 100,
        function() return targetData().othersAlpha end,
        function(v) targetData().othersAlpha = v end, "%", 5)
end

local function buildTargetPanel(parent)
    return formPanel(parent, targetContent)
end

-- ── NPC Colors and Names ─────────────────────────────────────────────────────
-- A virtualised table: only enough rows to fill the visible area are ever
-- created, and they're re-bound to a different slice of the data as you scroll.
-- The list can run to hundreds of entries once auto-detection has been running
-- for a few raid nights, and a frame per row would stall the window open (the
-- same "script ran too long" trap the lazy tab building elsewhere avoids).
local ROW_H    = 24
local HEADER_H = 22
-- Rows sit 3px inside the list box's border; the column header has no such
-- inset of its own, so its labels carry the same shift to stay lined up.
local COL_INSET = 3

local COL = {
    enable = 8,
    id     = 40,
    name   = 100,
    rename = 262,
    zone   = 382,
    swatch = 524,
    color  = 548,
    remove = 656,
}
local LIST_W = 690

local COLOR_NAMES  -- built lazily from the palette; "custom" covers freehand picks

local function colorNameList()
    if not COLOR_NAMES then
        COLOR_NAMES = { "none" }
        for _, c in ipairs(Data.COLORS) do COLOR_NAMES[#COLOR_NAMES + 1] = c.name end
    end
    return COLOR_NAMES
end

local function buildNpcPanel(parent)
    local shell = CreateFrame("Frame", nil, parent)
    shell:SetAllPoints()
    shell:Hide()

    local filter = ""
    local list   = {}
    local rows   = {}
    local rebuild, syncRows

    -- ── Toolbar ──────────────────────────────────────────────────────────────
    local desc = shell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", 12, -10)
    desc:SetWidth(560); desc:SetJustifyH("LEFT")
    desc:SetText("For raid and dungeon NPCs: they're added to this list the first time you see one. Tick an NPC and give it a colour to make its nameplate stand out, and optionally a shorter name to show instead of the real one.")
    desc:SetTextColor(unpack(C.textGrey))

    local exportBtn = flatButton(shell, "Export", 80, 22)
    exportBtn:SetPoint("TOPRIGHT", -12, -10)
    exportBtn:SetScript("OnClick", function()
        local str, err = Data.ExportNpcs()
        UI.showTextPopup({
            title      = "Export NPC List",
            hint       = "Copy this string (Ctrl+A, Ctrl+C) and share it with someone else.",
            text       = str or "",
            error      = str and "" or (err or "Could not export the NPC list."),
            actionText = "Close",
            selectAll  = true,
        })
    end)

    local importBtn = flatButton(shell, "Import", 80, 22)
    importBtn:SetPoint("RIGHT", exportBtn, "LEFT", -6, 0)
    importBtn:SetScript("OnClick", function()
        UI.showTextPopup({
            title      = "Import NPC List",
            hint       = "Paste an NPC list string exported from Driev's Essentials. Entries you already have are overwritten; everything else is left alone.",
            actionText = "Import",
            onAction   = function(_, text)
                local n, err = Data.ImportNpcs(text)
                if not n then return nil, err or "Import failed." end
                rebuild()
                apply()
                return true
            end,
        })
    end)

    local searchLbl = shell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    searchLbl:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -12)
    searchLbl:SetText("Search:")
    searchLbl:SetTextColor(unpack(C.textGrey))

    local searchBox = textBox(shell, 160, 20, nil, 60)
    searchBox:SetPoint("LEFT", searchLbl, "RIGHT", 6, 0)
    -- Filters as you type rather than on Enter: the list is short enough that
    -- re-sorting per keystroke is free, and waiting for Enter to see whether a
    -- mob is already in the list is the slower way round.
    searchBox.box:SetScript("OnTextChanged", function(self)
        filter = self:GetText() or ""
        rebuild()
    end)

    local addLbl = shell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    addLbl:SetPoint("LEFT", searchBox, "RIGHT", 18, 0)
    addLbl:SetText("Add NPC ID:")
    addLbl:SetTextColor(unpack(C.textGrey))

    local addBox = textBox(shell, 70, 20, nil, 8)
    addBox:SetPoint("LEFT", addLbl, "RIGHT", 6, 0)

    local addBtn = flatButton(shell, "Add", 50, 22)
    addBtn:SetPoint("LEFT", addBox, "RIGHT", 6, 0)
    addBtn:SetScript("OnClick", function()
        local id = tonumber(addBox.box:GetText())
        if not id then return end
        local d = npData()
        d.npcs = d.npcs or {}
        -- Nothing maps an ID to a name offline, so a hand-added entry starts as
        -- a placeholder; Data.Remember fills the real name in the first time the
        -- mob is actually seen. Typing an ID you already have (auto-detected,
        -- switched off) is a request to turn it on, not a no-op.
        local e = d.npcs[id]
        if not e then
            e = { name = "NPC " .. id, zone = "" }
            d.npcs[id] = e
        end
        e.enabled = true
        e.color   = e.color or Data.ColorByName("magenta")
        e.auto    = nil
        addBox.box:SetText("")
        addBox.box:ClearFocus()
        rebuild()
        apply()
    end)

    local autoCB = createCheckbox(shell, "Remember new NPCs automatically", 260)
    autoCB:SetPoint("TOPLEFT", searchLbl, "BOTTOMLEFT", 0, -12)
    autoCB.OnChange = function(_, checked) npData().autoAdd = checked end

    local clearBtn = flatButton(shell, "Clear auto-detected", 150, 22)
    clearBtn:SetPoint("LEFT", autoCB, "RIGHT", 20, 0)
    clearBtn:SetScript("OnClick", function()
        UI.showConfirmPopup({
            title       = "Clear auto-detected NPCs",
            message     = "Remove every NPC that was auto-detected and never configured?\n\nAnything you enabled, renamed or coloured is kept.",
            confirmText = "Clear",
            onConfirm   = function()
                Data.ClearAutoNpcs()
                rebuild()
            end,
        })
    end)

    local countText = shell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countText:SetPoint("LEFT", clearBtn, "RIGHT", 16, 0)
    countText:SetTextColor(unpack(C.textDim))

    -- ── Column header ────────────────────────────────────────────────────────
    -- Anchored under the toolbar rather than at a fixed offset from the top: the
    -- description above wraps to a different number of lines depending on how
    -- wide the window has been dragged, and a fixed offset would have the header
    -- either overlap it or float away from it.
    local headerRow = CreateFrame("Frame", nil, shell, "BackdropTemplate")
    headerRow:SetPoint("TOPLEFT", autoCB, "BOTTOMLEFT", -4, -12)
    headerRow:SetPoint("RIGHT", shell, "RIGHT", -8, 0)
    headerRow:SetHeight(HEADER_H)
    applyBackdrop(headerRow, 1, C.panelDark, C.tabBorder)

    local function headerLabel(text, x, width)
        local fs = headerRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("LEFT", x + COL_INSET, 0)
        fs:SetWidth(width); fs:SetJustifyH("LEFT")
        fs:SetText(text)
        fs:SetTextColor(unpack(C.textWhite))
        return fs
    end
    headerLabel("On",       COL.enable, 30)
    headerLabel("NPC ID",   COL.id,     56)
    headerLabel("NPC Name", COL.name,   155)
    headerLabel("Rename To",COL.rename, 115)
    headerLabel("Zone",     COL.zone,   135)
    headerLabel("Colour",   COL.swatch, 120)
    headerLabel("",         COL.remove, 30)

    -- ── Scrolling list ───────────────────────────────────────────────────────
    local listBox = CreateFrame("Frame", nil, shell, "BackdropTemplate")
    listBox:SetPoint("TOPLEFT", headerRow, "BOTTOMLEFT", 0, -2)
    listBox:SetPoint("BOTTOMRIGHT", shell, "BOTTOMRIGHT", -8, 8)
    applyBackdrop(listBox, 1, C.panelDeep, C.tabBorder)

    local scroll = CreateFrame("ScrollFrame", nil, listBox)
    scroll:SetPoint("TOPLEFT", 3, -3)
    scroll:SetPoint("BOTTOMRIGHT", -(W.scrollbarWidth + 5), 3)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(LIST_W, 1)
    scroll:SetScrollChild(content)

    local _, updateTrack = attachScrollTrack(scroll, listBox)

    local emptyText = listBox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    emptyText:SetPoint("TOP", 0, -30)
    emptyText:SetTextColor(unpack(C.textDim))
    emptyText:Hide()

    local function createRow(index)
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(LIST_W, ROW_H)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)  -- re-anchored by syncRows

        -- Zebra striping, matching the header's tone so the columns stay
        -- readable across a long list.
        local stripe = row:CreateTexture(nil, "BACKGROUND")
        stripe:SetAllPoints(row)
        stripe:SetTexture("Interface\\Buttons\\WHITE8x8")
        row.stripe = stripe

        row.enable = createCheckbox(row, "", 16)
        row.enable:SetPoint("LEFT", COL.enable, 0)
        row.enable.OnChange = function(self, checked)
            if not row.entry then return end
            row.entry.enabled = checked
            -- An entry switched on with no colour yet would look like a no-op,
            -- so give it the list's default rather than nothing at all.
            if checked and not row.entry.color then
                row.entry.color = Data.ColorByName("magenta")
                row.swatch.Refresh()
                row.colorDD:setValue("magenta")
            end
            row.entry.auto = nil   -- the user has touched it; no longer just noise
            apply()
        end

        row.idText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.idText:SetPoint("LEFT", COL.id, 0)
        row.idText:SetWidth(56); row.idText:SetJustifyH("LEFT")
        row.idText:SetTextColor(unpack(C.textGrey))

        row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.nameText:SetPoint("LEFT", COL.name, 0)
        row.nameText:SetWidth(155); row.nameText:SetJustifyH("LEFT")
        row.nameText:SetTextColor(unpack(C.textWhite))

        row.renameBox = textBox(row, 112, 18, function(text)
            if not row.entry then return end
            text = text and text:match("^%s*(.-)%s*$") or ""
            row.entry.rename = text ~= "" and text or nil
            if text ~= "" then row.entry.auto = nil end
            apply()
        end, 30)
        row.renameBox:SetPoint("LEFT", COL.rename, 0)

        row.zoneText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.zoneText:SetPoint("LEFT", COL.zone, 0)
        row.zoneText:SetWidth(135); row.zoneText:SetJustifyH("LEFT")
        row.zoneText:SetTextColor(unpack(C.textGrey))

        row.swatch = colorSwatch(row,
            function()
                local c = row.entry and row.entry.color
                return c and c[1] or 0.4, c and c[2] or 0.4, c and c[3] or 0.42
            end,
            function(r, g, b)
                if not row.entry then return end
                row.entry.color = { r, g, b }
                row.entry.auto  = nil
                row.colorDD:setValue(Data.ColorName(row.entry.color) or "custom")
            end,
            apply, 18)
        row.swatch:SetPoint("LEFT", COL.swatch, 0)

        row.colorDD = createScrollDropdown(row, 100, colorNameList, function(name)
            if not row.entry then return end
            if name == "none" then
                row.entry.color = nil
            else
                row.entry.color = Data.ColorByName(name)
                row.entry.auto  = nil
            end
            row.swatch.Refresh()
            apply()
        end)
        row.colorDD:SetPoint("LEFT", COL.color, 0)
        row.colorDD:SetHeight(18)

        row.remove = flatButton(row, "X", 20, 18, "GameFontNormalSmall")
        row.remove:SetPoint("LEFT", COL.remove, 0)
        row.remove.label:SetTextColor(unpack(C.red))
        row.remove:SetScript("OnClick", function()
            if not row.id then return end
            Data.RemoveNpc(row.id)
            rebuild()
            apply()
        end)

        rows[index] = row
        return row
    end

    local function bindRow(row, item, dataIndex)
        -- Scrolling recycles rows underneath the cursor. Dropping focus BEFORE
        -- the row is repointed lets the rename box commit what was typed to the
        -- NPC it was actually typed into, rather than to whichever one has just
        -- scrolled into its place.
        if row.id ~= item.id and row.renameBox.box:HasFocus() then
            row.renameBox.box:ClearFocus()
        end
        row.id    = item.id
        row.entry = item.entry
        row.stripe:SetVertexColor(0.14, 0.15, 0.23, (dataIndex % 2 == 0) and 0.55 or 0.20)
        row.enable:SetChecked(item.entry.enabled and true or false)
        row.idText:SetText(tostring(item.id))
        row.nameText:SetText(item.entry.name or ("NPC " .. item.id))
        if not row.renameBox.box:HasFocus() then
            row.renameBox.box:SetText(item.entry.rename or "")
        end
        row.zoneText:SetText(item.entry.zone or "")
        row.swatch.Refresh()
        row.colorDD:setValue(item.entry.color
            and (Data.ColorName(item.entry.color) or "custom") or "none")
    end

    -- Re-binds the pooled rows to whichever slice of `list` the scroll offset
    -- now lands on. Called on every scroll as well as after a rebuild.
    syncRows = function()
        local offset = scroll:GetVerticalScroll() or 0
        local first  = math.floor(offset / ROW_H)
        local visible = math.ceil((scroll:GetHeight() or 0) / ROW_H) + 2

        for i = 1, visible do
            local row = rows[i] or createRow(i)
            local dataIndex = first + i
            local item = list[dataIndex]
            if item then
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -((dataIndex - 1) * ROW_H))
                bindRow(row, item, dataIndex)
                row:Show()
            else
                row.id, row.entry = nil, nil
                row:Hide()
            end
        end
        for i = visible + 1, #rows do
            rows[i].id, rows[i].entry = nil, nil
            rows[i]:Hide()
        end
    end

    rebuild = function()
        list = Data.SortedNpcs(filter)
        content:SetHeight(math.max(#list * ROW_H, 1))
        local total = 0
        local d = npData()
        for _ in pairs(d.npcs or {}) do total = total + 1 end
        countText:SetText(#list == total
            and (total .. " NPCs")
            or (#list .. " of " .. total .. " NPCs"))
        emptyText:SetText(total == 0
            and "No NPCs yet — they appear here as you run into them."
            or "Nothing matches that search.")
        emptyText:SetShown(#list == 0)
        syncRows()
        updateTrack()
    end

    scroll:HookScript("OnVerticalScroll", syncRows)
    scroll:HookScript("OnSizeChanged", function() syncRows(); updateTrack() end)

    shell:HookScript("OnShow", function()
        Data.EnsureSeeded()
        autoCB:SetChecked(npData().autoAdd ~= false)
        rebuild()
        -- The list's own geometry (and therefore how many rows fit) isn't final
        -- on the very frame it's first shown, so take a second pass once the
        -- layout has settled — same reason makeScrollPanel defers its re-fit.
        C_Timer.After(0, rebuild)
    end)

    -- The engine calls this when it records an NPC it has never seen. Throttled:
    -- pulling a big trash pack fires it a dozen times in one second, and each
    -- rebuild re-sorts the whole list.
    local pending = false
    if addon.Nameplates then
        addon.Nameplates.onNpcAdded = function()
            if pending or not shell:IsShown() then return end
            pending = true
            C_Timer.After(1, function()
                pending = false
                if shell:IsShown() then rebuild() end
            end)
        end
    end

    return shell
end

-- ── Aura whitelists ──────────────────────────────────────────────────────────
-- Four of these, one per unit type per row, and each is a complete editor: its
-- own look settings and its own whitelist. Split that way because that is what
-- the two jobs actually are — the debuffs you have stuck on a boss and the buffs
-- the enemy healer is running around with are different lists, wanted at
-- different sizes, in different places. One shared pair could only ever be a
-- compromise between them.
--
-- Two sit side by side under each unit tab, so a column is half the panel wide
-- and half of a resizable window is not a fixed number. Everything in the table
-- below is therefore measured off the column's live width each time it is
-- rebuilt, rather than pinned to constants that would be right at one size only.
local AURA_ROW_H = 22

-- Only the spell name flexes; the rest of the columns are as wide as what goes
-- in them, and squeezing those would just overlap the text.
local AURA_ICON_W   = 18
local AURA_MATCH_W  = 54
local AURA_TIMER_W  = 38
local AURA_REMOVE_W = 20
local AURA_NAME_MIN = 60

local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"

-- Short forms of the growth labels. The full ones spell out what each does,
-- which is right on a full-width row and impossible in a half-column dropdown.
local AURA_GROWTH_OPTIONS = {}
for _, e in ipairs(Data.AURA_GROWTHS) do
    AURA_GROWTH_OPTIONS[#AURA_GROWTH_OPTIONS + 1] = { value = e.value, label = e.short or e.label }
end

local function auraRoot()
    local t = npData()
    t.auras = t.auras or {}
    t.auras.units = t.auras.units or {}
    return t.auras
end

local function auraUnit(unitKey)
    local a = auraRoot()
    a.units[unitKey] = a.units[unitKey] or {}
    return a.units[unitKey]
end

local function auraOpts(unitKey, which)
    local u = auraUnit(unitKey)
    u[which] = u[which] or {}
    u[which].list = u[which].list or {}
    return u[which]
end

-- Where each column of the table starts, for a given usable width. Right-hand
-- columns are placed from the right edge inwards, so the flexible name column
-- absorbs every pixel the window gains or loses.
local function auraLayout(w)
    local c = {}
    c.enable = 4
    c.icon   = c.enable + 20
    c.name   = c.icon + AURA_ICON_W + 6
    c.remove = w - AURA_REMOVE_W - 4
    c.timer  = c.remove - AURA_TIMER_W - 10
    c.match  = c.timer - AURA_MATCH_W - 8
    c.nameW  = math.max(AURA_NAME_MIN, c.match - c.name - 8)
    c.width  = w
    return c
end

-- Every column built so far, so the engine's one "an entry just learned an ID"
-- callback can reach all of them. Columns are never destroyed once built (frames
-- can't be), so this only ever grows to four.
local auraColumns = {}

if addon.Nameplates then
    addon.Nameplates.onAuraLearned = function()
        for _, notify in ipairs(auraColumns) do notify() end
    end
end

-- One column: a run of look settings and the whitelist they apply to. Shared by
-- all four rather than copied, which is the only thing keeping them from
-- drifting into four subtly different features.
local function buildAuraColumn(parent, unitKey, which, label)
    local shell = CreateFrame("Frame", nil, parent)

    local filter  = ""
    local list    = {}
    local rows    = {}
    local refresh = {}
    local cols    = auraLayout(280)
    local rebuild, syncRows

    local function o() return auraOpts(unitKey, which) end

    local head = shell:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    head:SetPoint("TOPLEFT", 2, -2)
    head:SetText(label)
    head:SetTextColor(unpack(C.red))

    -- ── Toggles ──────────────────────────────────────────────────────────────
    local function toggle(text, width, get, set)
        local cb = createCheckbox(shell, text, width)
        cb.OnChange = function(_, checked) set(checked); apply() end
        refresh[#refresh + 1] = function() cb:SetChecked(get() and true or false) end
        return cb
    end

    local showCB = toggle("Show these above the health bar", 210,
        function() return o().enabled ~= false end,
        function(v) o().enabled = v end)
    showCB:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -6)

    -- Clipped labels rather than the full sentences the full-width panel had
    -- room for: three switches on one line is worth more here than three lines
    -- of prose, because every line spent up here is a line off the list.
    local mineCB = toggle("Only mine", 86,
        function() return o().onlyMine end,
        function(v) o().onlyMine = v end)
    mineCB:SetPoint("TOPLEFT", showCB, "BOTTOMLEFT", 0, -2)

    local timerCB = toggle("Timer", 64,
        function() return o().showTimer ~= false end,
        function(v) o().showTimer = v end)
    timerCB:SetPoint("LEFT", mineCB, "RIGHT", 4, 0)

    local stackCB = toggle("Stacks", 70,
        function() return o().showStacks ~= false end,
        function(v) o().showStacks = v end)
    stackCB:SetPoint("LEFT", timerCB, "RIGHT", 4, 0)

    -- ── Numbers ──────────────────────────────────────────────────────────────
    -- Two per line at fixed x positions rather than packed left to right: the
    -- labels are different lengths, and packing them would land the second
    -- stepper somewhere different on every line.
    local STEP_COL2 = 134
    local STEP_LBL  = 42

    local function newLine(above, gap)
        local line = CreateFrame("Frame", nil, shell)
        line:SetHeight(22)
        line:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -(gap or 5))
        line:SetPoint("RIGHT", shell, "RIGHT", 0, 0)
        return line
    end

    local function addLabel(line, x, text)
        local fs = line:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("LEFT", x, 0)
        fs:SetWidth(STEP_LBL); fs:SetJustifyH("LEFT")
        fs:SetText(text)
        fs:SetTextColor(unpack(C.textGrey))
        return fs
    end

    local function addStepper(line, x, text, min, max, get, set)
        local fs = addLabel(line, x, text)
        local st = buildStepper(line, {
            min = min, max = max, step = 1, valueWidth = 32, gap = 4,
            get = function() return tonumber(get()) or min end,
            set = function(v) set(v); apply() end,
        })
        st:SetPoint("LEFT", fs, "RIGHT", 2, 0)
        refresh[#refresh + 1] = st.Refresh
        return st
    end

    local sizeLine = newLine(mineCB, 8)
    addStepper(sizeLine, 0, "Size", 4, 64,
        function() return o().size end, function(v) o().size = v end)
    addStepper(sizeLine, STEP_COL2, "Gap", 0, 30,
        function() return o().spacing end, function(v) o().spacing = v end)

    local maxLine = newLine(sizeLine)
    addStepper(maxLine, 0, "Max", 1, 20,
        function() return o().max end, function(v) o().max = v end)
    addStepper(maxLine, STEP_COL2, "Text", 6, 24,
        function() return o().timerSize end, function(v) o().timerSize = v end)

    local nudgeLine = newLine(maxLine)
    addStepper(nudgeLine, 0, "Nudge X", -400, 400,
        function() return o().x end, function(v) o().x = v end)
    addStepper(nudgeLine, STEP_COL2, "Nudge Y", -400, 400,
        function() return o().y end, function(v) o().y = v end)

    local borderLine = newLine(nudgeLine)
    addStepper(borderLine, 0, "Border", 0, 4,
        function() return o().borderSize end, function(v) o().borderSize = v end)
    local swatchLbl = addLabel(borderLine, STEP_COL2, "Colour")
    local borderSwatch = colorSwatch(borderLine,
        function()
            local c = o().borderColor or {}
            return c[1] or 0, c[2] or 0, c[3] or 0
        end,
        function(r, g, b)
            local t = o()
            t.borderColor = t.borderColor or {}
            t.borderColor[1], t.borderColor[2], t.borderColor[3] = r, g, b
        end,
        apply, 18)
    borderSwatch:SetPoint("LEFT", swatchLbl, "RIGHT", 2, 0)
    refresh[#refresh + 1] = borderSwatch.Refresh

    local growLine = newLine(borderLine)
    addLabel(growLine, 0, "Grow")
    local growDD = createDropdown(growLine, 150, AURA_GROWTH_OPTIONS,
        function() return Data.AuraGrowth(o().growth) end,
        function(v) o().growth = v end, apply)
    growDD:SetPoint("LEFT", growLine, "LEFT", STEP_LBL + 2, 0)
    refresh[#refresh + 1] = growDD.Refresh

    -- ── Whitelist toolbar ────────────────────────────────────────────────────
    -- The count on its own line above the boxes is what leaves room for search
    -- and add to share the row below it: search on the left because it acts on
    -- the list underneath, add on the right because it puts things there.
    --
    -- One line doing two jobs. An add that fails has something to say and the
    -- column has no spare row to say it on, so the message takes over the count
    -- until the next rebuild puts the count back.
    local info = shell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    info:SetPoint("TOPLEFT", growLine, "BOTTOMLEFT", 2, -8)
    info:SetPoint("RIGHT", shell, "RIGHT", -2, 0)
    info:SetJustifyH("LEFT")
    -- Truncate rather than wrap: a second line would push the boxes below it
    -- down onto the table header.
    info:SetWordWrap(false)

    local toolRow = CreateFrame("Frame", nil, shell)
    toolRow:SetHeight(20)
    toolRow:SetPoint("TOPLEFT", info, "BOTTOMLEFT", -2, -4)
    toolRow:SetPoint("RIGHT", shell, "RIGHT", 0, 0)

    local searchBox = textBox(toolRow, 112, 20, nil, 40)
    searchBox:SetPoint("LEFT", 0, 0)
    setPlaceholder(searchBox, "search")
    searchBox.box:SetScript("OnTextChanged", function(self)
        filter = self:GetText() or ""
        rebuild()
    end)

    local addBtn = flatButton(toolRow, "Add", 42, 20, "GameFontNormalSmall")
    addBtn:SetPoint("RIGHT", 0, 0)

    -- The flexible one of the three, so the width a wider window gives the
    -- column lands here: a spell name is longer than the search term that finds
    -- it, and this is the box that has to hold a whole one.
    local addBox = textBox(toolRow, 100, 20, nil, 60)
    addBox:SetPoint("LEFT", searchBox, "RIGHT", 8, 0)
    addBox:SetPoint("RIGHT", addBtn, "LEFT", -4, 0)
    setPlaceholder(addBox, "name or ID")
    addBox.box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)

    local function doAdd()
        local text = addBox.box:GetText()
        local entry, err = Data.AddAura(unitKey, which, text)
        if not entry then
            info:SetText(err or "")
            info:SetTextColor(unpack(C.red))
            return
        end
        addBox.box:SetText("")
        addBox.box:ClearFocus()
        rebuild()
        apply()
    end
    addBtn:SetScript("OnClick", doAdd)
    -- Enter in the box does the same thing: typing a spell ID and reaching for
    -- the mouse is the slower way round when you're adding several.
    addBox.box:SetScript("OnEnterPressed", doAdd)

    -- ── Column header ────────────────────────────────────────────────────────
    local headerRow = CreateFrame("Frame", nil, shell, "BackdropTemplate")
    headerRow:SetPoint("TOPLEFT", toolRow, "BOTTOMLEFT", 0, -8)
    headerRow:SetPoint("RIGHT", shell, "RIGHT", 0, 0)
    headerRow:SetHeight(HEADER_H)
    applyBackdrop(headerRow, 1, C.panelDark, C.tabBorder)

    local function headerLabel(text)
        local fs = headerRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetJustifyH("LEFT")
        fs:SetText(text)
        fs:SetTextColor(unpack(C.textWhite))
        return fs
    end
    local hOn    = headerLabel("On")
    local hSpell = headerLabel("Spell")
    -- "Matched on" rather than a Spell ID column: which of the two an entry
    -- matches on is the whole difference between it catching every rank of a
    -- spell and only the one you pasted, and at this width there is room for
    -- the answer or the ID but not both. The ID IS the answer when there is one.
    local hMatch = headerLabel("Matched on")
    local hTimer = headerLabel("Timer(s)")

    -- ── Scrolling list ───────────────────────────────────────────────────────
    local listBox = CreateFrame("Frame", nil, shell, "BackdropTemplate")
    listBox:SetPoint("TOPLEFT", headerRow, "BOTTOMLEFT", 0, -2)
    listBox:SetPoint("BOTTOMRIGHT", shell, "BOTTOMRIGHT", 0, 0)
    applyBackdrop(listBox, 1, C.panelDeep, C.tabBorder)

    local scroll = CreateFrame("ScrollFrame", nil, listBox)
    scroll:SetPoint("TOPLEFT", 3, -3)
    scroll:SetPoint("BOTTOMRIGHT", -(W.scrollbarWidth + 5), 3)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(280, 1)
    scroll:SetScrollChild(content)

    local _, updateTrack = attachScrollTrack(scroll, listBox)

    local emptyText = listBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    emptyText:SetPoint("TOPLEFT", 8, -10)
    emptyText:SetPoint("RIGHT", listBox, "RIGHT", -8, 0)
    emptyText:SetJustifyH("LEFT")
    emptyText:SetTextColor(unpack(C.textDim))
    emptyText:Hide()

    -- Applied to the header and to every row, whenever the usable width has
    -- actually moved. Re-anchoring costs six SetPoints a row, so it is not done
    -- on a rebuild that changed nothing about the geometry.
    local function layoutHeader()
        for _, fs in ipairs({ hOn, hSpell, hMatch, hTimer }) do fs:ClearAllPoints() end
        hOn:SetPoint("LEFT", cols.enable + COL_INSET, 0)
        hSpell:SetPoint("LEFT", cols.name + COL_INSET, 0); hSpell:SetWidth(cols.nameW)
        hMatch:SetPoint("LEFT", cols.match + COL_INSET, 0); hMatch:SetWidth(AURA_MATCH_W + 8)
        hTimer:SetPoint("LEFT", cols.timer + COL_INSET, 0); hTimer:SetWidth(AURA_TIMER_W + 12)
    end

    local function layoutRow(row)
        if row.laidOutFor == cols.width then return end
        row.laidOutFor = cols.width
        row:SetWidth(cols.width)
        for _, part in ipairs({ row.enable, row.icon, row.iconHit, row.nameText,
                                row.matchText, row.timerBox, row.remove }) do
            part:ClearAllPoints()
        end
        row.enable:SetPoint("LEFT", cols.enable, 0)
        row.icon:SetPoint("LEFT", cols.icon, 0)
        row.iconHit:SetPoint("LEFT", cols.icon, 0)
        row.nameText:SetPoint("LEFT", cols.name, 0)
        row.nameText:SetWidth(cols.nameW)
        row.matchText:SetPoint("LEFT", cols.match, 0)
        row.timerBox:SetPoint("LEFT", cols.timer, 0)
        row.remove:SetPoint("LEFT", cols.remove, 0)
    end

    local function createRow(index)
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(cols.width, AURA_ROW_H)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)  -- re-anchored by syncRows

        local stripe = row:CreateTexture(nil, "BACKGROUND")
        stripe:SetAllPoints(row)
        stripe:SetTexture("Interface\\Buttons\\WHITE8x8")
        row.stripe = stripe

        row.enable = createCheckbox(row, "", 16)
        row.enable.OnChange = function(_, checked)
            if not row.entry then return end
            row.entry.enabled = checked
            apply()
        end

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(AURA_ICON_W, AURA_ICON_W)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        -- A texture can't take the mouse, so the hover target is a frame sitting
        -- over it. What it has to say belongs on the icon rather than the name:
        -- the icon is the part that has nothing to show until the entry has
        -- worked out what it matches, so it is the part you go to when you want
        -- to know why.
        row.iconHit = CreateFrame("Frame", nil, row)
        row.iconHit:SetSize(AURA_ICON_W, AURA_ICON_W)
        row.iconHit:EnableMouse(true)
        row.iconHit:SetScript("OnEnter", function(self)
            local entry = row.entry
            if not entry then return end

            local name = Data.AuraDisplay(entry)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(name ~= "" and name or row.key, 1, 1, 1)

            if entry.id then
                GameTooltip:AddLine("Matched on spell ID " .. entry.id
                    .. " — that rank and no other.", 0.75, 0.75, 0.75, true)
                GameTooltip:Show()
                return
            end

            GameTooltip:AddLine("Matched by name — every rank that shares it.",
                0.75, 0.75, 0.75, true)

            local ids = Data.AuraSeenIDs(entry)
            GameTooltip:AddLine(" ")
            if #ids > 0 then
                GameTooltip:AddLine("Seen so far:", 1, 1, 1)
                for _, id in ipairs(ids) do
                    local spell = Data.SpellInfo(id)
                    GameTooltip:AddLine(spell and (id .. "  " .. spell) or tostring(id),
                        0.75, 0.75, 0.75)
                end
            else
                GameTooltip:AddLine("Nothing seen yet.", 1, 1, 1)
                GameTooltip:AddLine("The client only looks up a spell name that is in your own spellbook, so an effect like a triggered stun has no icon here until the module actually sees it. It learns the ID and the art from the first one that turns up, and keeps them.",
                    0.75, 0.75, 0.75, true)
            end
            GameTooltip:Show()
        end)
        row.iconHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

        row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.nameText:SetJustifyH("LEFT")
        row.nameText:SetTextColor(unpack(C.textWhite))

        row.matchText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.matchText:SetWidth(AURA_MATCH_W); row.matchText:SetJustifyH("LEFT")
        row.matchText:SetTextColor(unpack(C.textGrey))

        -- Only ever read for auras the engine had to work out from events, which
        -- is why it's an optional box and not a stepper: for everything else the
        -- game supplies the real duration and this is left blank.
        row.timerBox = textBox(row, AURA_TIMER_W, 18, function(text)
            if not row.key then return end
            local secs = Data.SetAuraDuration(unitKey, which, row.key, text)
            row.timerBox.box:SetText(secs and tostring(secs) or "")
            apply()
        end, 4)
        row.timerBox.box:SetNumeric(true)

        row.remove = flatButton(row, "X", AURA_REMOVE_W, 16, "GameFontNormalSmall")
        row.remove.label:SetTextColor(unpack(C.red))
        row.remove:SetScript("OnClick", function()
            if not row.key then return end
            Data.RemoveAura(unitKey, which, row.key)
            rebuild()
            apply()
        end)

        rows[index] = row
        return row
    end

    local function bindRow(row, item, dataIndex)
        -- Before row.key moves, not after. Rows are recycled as you scroll, and
        -- dropping focus is what commits the timer box — so this has to land on
        -- the entry that was being edited, not on the one taking its place.
        row.timerBox.box:ClearFocus()
        layoutRow(row)

        row.key   = item.key
        row.entry = item.entry
        row.stripe:SetVertexColor(0.14, 0.15, 0.23, (dataIndex % 2 == 0) and 0.55 or 0.20)
        row.enable:SetChecked(item.entry.enabled ~= false)

        local name, icon = Data.AuraDisplay(item.entry)
        row.icon:SetTexture(icon or QUESTION_MARK)
        row.nameText:SetText(name ~= "" and name or item.key)
        row.matchText:SetText(item.entry.id and tostring(item.entry.id) or "Name")
        row.timerBox.box:SetText(item.entry.duration and tostring(item.entry.duration) or "")
    end

    syncRows = function()
        local offset  = scroll:GetVerticalScroll() or 0
        local first   = math.floor(offset / AURA_ROW_H)
        local visible = math.ceil((scroll:GetHeight() or 0) / AURA_ROW_H) + 2

        for i = 1, visible do
            local row = rows[i] or createRow(i)
            local dataIndex = first + i
            local item = list[dataIndex]
            if item then
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -((dataIndex - 1) * AURA_ROW_H))
                bindRow(row, item, dataIndex)
                row:Show()
            else
                -- Hidden before it's unbound, for the same reason bindRow drops
                -- focus first: hiding the row commits whatever was being typed
                -- into its timer box, and that edit belongs to the entry the row
                -- is still holding.
                row:Hide()
                row.key, row.entry = nil, nil
            end
        end
        for i = visible + 1, #rows do
            rows[i]:Hide()
            rows[i].key, rows[i].entry = nil, nil
        end
    end

    rebuild = function()
        local usable = (scroll:GetWidth() or 0)
        if usable > 20 and math.abs(usable - cols.width) > 0.5 then
            cols = auraLayout(usable)
            layoutHeader()
            content:SetWidth(usable)
        end

        list = Data.SortedAuras(unitKey, which, filter)
        content:SetHeight(math.max(#list * AURA_ROW_H, 1))

        local total = 0
        for _ in pairs(Data.AuraList(unitKey, which) or {}) do total = total + 1 end
        info:SetText(#list == total
            and (total .. " tracked")
            or (#list .. " of " .. total))
        info:SetTextColor(unpack(C.textDim))

        emptyText:SetText(total == 0
            and "Nothing tracked yet."
            or "Nothing matches that.")
        emptyText:SetShown(#list == 0)
        syncRows()
        updateTrack()
    end

    scroll:HookScript("OnVerticalScroll", syncRows)
    scroll:HookScript("OnSizeChanged", function() rebuild() end)

    layoutHeader()

    -- The engine calls this when a by-name entry has just worked out an ID it
    -- matches, so a question mark turns into the real icon while you're looking
    -- at it. Throttled and gated on being visible for the same reason the NPC
    -- list's hook is: one pull can teach several entries at once, and each
    -- rebuild re-sorts the whole list.
    local pending = false
    auraColumns[#auraColumns + 1] = function()
        if pending or not shell:IsShown() then return end
        pending = true
        C_Timer.After(1, function()
            pending = false
            if shell:IsShown() then rebuild() end
        end)
    end

    shell.Refresh = function()
        for _, fn in ipairs(refresh) do fn() end
        rebuild()
    end
    return shell
end

-- ── Learned ──────────────────────────────────────────────────────────────────
-- The catalogue, and the way into the four whitelists from it. Everything else
-- in this module asks you to already know what you want to track; this is the
-- page for when you don't, because the thing you are after has a name you can't
-- spell and an ID you have no way to look up.
--
-- Full panel width rather than split like the unit tabs: there is one list here,
-- not two, and the four Add buttons a row carries need the room.
local LEARN_ROW_H  = 22
local LEARN_ICON_W = 18
-- Wide enough for the buttons to name their own destination. They cost more of
-- the row than a bare "NPC" would, but a button that says where it sends things
-- needs no column heading explaining that it does.
local LEARN_BTN_W  = 118

local function buildLearnedPanel(parent)
    local shell = CreateFrame("Frame", nil, parent)
    shell:SetAllPoints()
    shell:Hide()

    local which   = "debuffs"
    local filter  = ""
    local list    = {}
    local rows    = {}
    local cols    = {}
    local rebuild, syncRows

    -- ── Recording ────────────────────────────────────────────────────────────
    local recordCB = createCheckbox(shell, "Record every aura I see on a nameplate", 320)
    recordCB:SetPoint("TOPLEFT", 10, -8)
    recordCB.OnChange = function(_, checked) auraRoot().learn = checked end
    attachTooltip(recordCB, "Record every aura I see on a nameplate", {
        "Walks the auras on each nameplate every few seconds and writes down what it finds, whether or not anything is watching for it. That is what fills the list below.",
        "Kept out of the module's normal tick on purpose: a full read is forty slots per row per plate, and a catalogue has no reason to be current to a tenth of a second.",
        "Collapsed by spell name, so eight ranks of the same shout are one row. Hover a row's icon to see which IDs it has actually been seen as.",
        "Capped at " .. Data.LEARNED_CAP .. " names per list. Once full it stops taking new ones but keeps filling in extra ranks and missing art for what it has.",
    })

    local clearBtn = flatButton(shell, "Clear list", 80, 20, "GameFontNormalSmall")
    clearBtn:SetPoint("TOPRIGHT", -10, -8)
    clearBtn:SetScript("OnClick", function()
        Data.ClearLearned(which)
        rebuild()
    end)

    -- ── Kind selector ────────────────────────────────────────────────────────
    local bar = CreateFrame("Frame", nil, shell)
    bar:SetHeight(22)
    bar:SetPoint("TOPLEFT", recordCB, "BOTTOMLEFT", 0, -8)
    bar:SetPoint("RIGHT", shell, "RIGHT", -10, 0)

    local kindTabs = {}

    local function selectKind(key)
        which = key
        for k, tab in pairs(kindTabs) do
            local on = (k == key)
            tab.active = on
            tab:SetBackdropColor(unpack(on and C.tabActive or C.tabIdle))
            tab:SetBackdropBorderColor(unpack(on and C.tabActiveBdr or C.tabBorder))
            tab.text:SetTextColor(unpack(on and C.textWhite or C.textGrey))
        end
        rebuild()
    end

    -- Debuffs first, matching the unit tabs' left-hand column.
    local prev
    for _, def in ipairs({ { key = "debuffs", label = "Debuffs" },
                           { key = "buffs",   label = "Buffs"   } }) do
        local tab = createTab(bar, def.label, 72)
        tab:SetHeight(20)
        tab.text:SetFontObject("GameFontNormalSmall")
        if prev then tab:SetPoint("LEFT", prev, "RIGHT", 4, 0) else tab:SetPoint("LEFT", 0, 0) end
        tab:SetScript("OnClick", function() selectKind(def.key) end)
        kindTabs[def.key] = tab
        prev = tab
    end

    local searchBox = textBox(bar, 150, 20, nil, 40)
    searchBox:SetPoint("LEFT", prev, "RIGHT", 14, 0)
    setPlaceholder(searchBox, "search name or ID")
    searchBox.box:SetScript("OnTextChanged", function(self)
        filter = self:GetText() or ""
        rebuild()
    end)

    local countText = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countText:SetPoint("LEFT", searchBox, "RIGHT", 12, 0)
    countText:SetPoint("RIGHT", clearBtn, "LEFT", -10, 0)
    countText:SetJustifyH("LEFT")
    countText:SetWordWrap(false)
    countText:SetTextColor(unpack(C.textDim))

    -- ── Column header ────────────────────────────────────────────────────────
    local headerRow = CreateFrame("Frame", nil, shell, "BackdropTemplate")
    headerRow:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", -4, -8)
    headerRow:SetPoint("RIGHT", shell, "RIGHT", -6, 0)
    headerRow:SetHeight(HEADER_H)
    applyBackdrop(headerRow, 1, C.panelDark, C.tabBorder)

    local function headerLabel(text)
        local fs = headerRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetJustifyH("LEFT")
        fs:SetText(text)
        fs:SetTextColor(unpack(C.textWhite))
        return fs
    end
    local hSpell = headerLabel("Spell")
    local hIDs   = headerLabel("Seen as")

    -- ── Scrolling list ───────────────────────────────────────────────────────
    local listBox = CreateFrame("Frame", nil, shell, "BackdropTemplate")
    listBox:SetPoint("TOPLEFT", headerRow, "BOTTOMLEFT", 0, -2)
    listBox:SetPoint("BOTTOMRIGHT", shell, "BOTTOMRIGHT", -6, 8)
    applyBackdrop(listBox, 1, C.panelDeep, C.tabBorder)

    local scroll = CreateFrame("ScrollFrame", nil, listBox)
    scroll:SetPoint("TOPLEFT", 3, -3)
    scroll:SetPoint("BOTTOMRIGHT", -(W.scrollbarWidth + 5), 3)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(600, 1)
    scroll:SetScrollChild(content)

    local _, updateTrack = attachScrollTrack(scroll, listBox)

    local emptyText = listBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    emptyText:SetPoint("TOPLEFT", 10, -12)
    emptyText:SetPoint("RIGHT", listBox, "RIGHT", -10, 0)
    emptyText:SetJustifyH("LEFT")
    emptyText:SetTextColor(unpack(C.textDim))
    emptyText:Hide()

    -- Measured off the live width, same as the whitelist columns: this panel is
    -- as resizable as the window is.
    local function layout(w)
        cols.icon   = 6
        cols.name   = cols.icon + LEARN_ICON_W + 8
        cols.player = w - LEARN_BTN_W - 6
        cols.npc    = cols.player - LEARN_BTN_W - 6
        cols.ids    = math.floor((cols.name + cols.npc) / 2)
        cols.nameW  = math.max(80, cols.ids - cols.name - 10)
        cols.idsW   = math.max(60, cols.npc - cols.ids - 12)
        cols.width  = w
    end
    layout(600)

    local function layoutHeader()
        for _, fs in ipairs({ hSpell, hIDs }) do fs:ClearAllPoints() end
        hSpell:SetPoint("LEFT", cols.name + COL_INSET, 0); hSpell:SetWidth(cols.nameW)
        hIDs:SetPoint("LEFT", cols.ids + COL_INSET, 0);    hIDs:SetWidth(cols.idsW)
    end

    local function layoutRow(row)
        if row.laidOutFor == cols.width then return end
        row.laidOutFor = cols.width
        row:SetWidth(cols.width)
        for _, part in ipairs({ row.icon, row.iconHit, row.nameText, row.idText,
                                row.npcBtn, row.playerBtn }) do
            part:ClearAllPoints()
        end
        row.icon:SetPoint("LEFT", cols.icon, 0)
        row.iconHit:SetPoint("LEFT", cols.icon, 0)
        row.nameText:SetPoint("LEFT", cols.name, 0); row.nameText:SetWidth(cols.nameW)
        row.idText:SetPoint("LEFT", cols.ids, 0);    row.idText:SetWidth(cols.idsW)
        row.npcBtn:SetPoint("LEFT", cols.npc, 0)
        row.playerBtn:SetPoint("LEFT", cols.player, 0)
    end

    -- Whether this spell is already on that unit type's list for the kind being
    -- shown. Keyed on the lowercased name, which is exactly the key a by-name
    -- whitelist entry uses — so adding from here and typing the name by hand
    -- land on the same row rather than making two.
    local function alreadyOn(unitKey, key)
        local l = Data.AuraList(unitKey, which)
        return l and l[key] ~= nil
    end

    local function refreshAddButton(btn, unitKey, key)
        local on = alreadyOn(unitKey, key)
        btn.label:SetText(on and "On list" or btn.addLabel)
        btn.label:SetTextColor(unpack(on and C.textDim or C.textWhite))
        -- Enable/Disable rather than SetEnabled: the older pair has been on
        -- Button for every version of this client and reads the same.
        if on then btn:Disable() else btn:Enable() end
    end

    local function createRow(index)
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(cols.width, LEARN_ROW_H)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)  -- re-anchored by syncRows

        local stripe = row:CreateTexture(nil, "BACKGROUND")
        stripe:SetAllPoints(row)
        stripe:SetTexture("Interface\\Buttons\\WHITE8x8")
        row.stripe = stripe

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(LEARN_ICON_W, LEARN_ICON_W)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        row.iconHit = CreateFrame("Frame", nil, row)
        row.iconHit:SetSize(LEARN_ICON_W, LEARN_ICON_W)
        row.iconHit:EnableMouse(true)
        row.iconHit:SetScript("OnEnter", function(self)
            local rec = row.rec
            if not rec then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(rec.name or row.key, 1, 1, 1)
            local ids = Data.LearnedIDs(rec)
            if #ids > 0 then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Seen as:", 1, 1, 1)
                for _, id in ipairs(ids) do
                    GameTooltip:AddLine(tostring(id), 0.75, 0.75, 0.75)
                end
            end
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Adding puts it on the list by NAME, so it catches every rank above. Type one of these IDs into that list by hand instead if you want only that one.",
                0.75, 0.75, 0.75, true)
            GameTooltip:Show()
        end)
        row.iconHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

        row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.nameText:SetJustifyH("LEFT")
        row.nameText:SetTextColor(unpack(C.textWhite))

        row.idText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.idText:SetJustifyH("LEFT")
        row.idText:SetWordWrap(false)
        row.idText:SetTextColor(unpack(C.textGrey))

        local function addButton(unitKey, label)
            local btn = flatButton(row, label, LEARN_BTN_W, 16, "GameFontNormalSmall")
            btn.addLabel = label
            btn:SetScript("OnClick", function(self)
                if not row.key then return end
                -- By name, not by the ID this row happens to have been first
                -- seen as: the row IS a name, and every rank under it is what
                -- the user picked when they picked this row.
                Data.AddAura(unitKey, which, row.rec and row.rec.name or row.key)
                refreshAddButton(self, unitKey, row.key)
                apply()
            end)
            return btn
        end
        row.npcBtn    = addButton("enemyNPC",    "Add to Enemy NPC")
        row.playerBtn = addButton("enemyPlayer", "Add to Enemy Player")

        rows[index] = row
        return row
    end

    local function bindRow(row, item, dataIndex)
        layoutRow(row)
        row.key = item.key
        row.rec = item.rec
        row.stripe:SetVertexColor(0.14, 0.15, 0.23, (dataIndex % 2 == 0) and 0.55 or 0.20)

        row.icon:SetTexture(item.rec.icon or QUESTION_MARK)
        row.nameText:SetText(item.rec.name or item.key)

        local ids = Data.LearnedIDs(item.rec)
        if #ids == 0 then
            row.idText:SetText("—")
        elseif #ids == 1 then
            row.idText:SetText(tostring(ids[1]))
        else
            row.idText:SetText(ids[1] .. "  +" .. (#ids - 1))
        end

        refreshAddButton(row.npcBtn,    "enemyNPC",    item.key)
        refreshAddButton(row.playerBtn, "enemyPlayer", item.key)
    end

    syncRows = function()
        local offset  = scroll:GetVerticalScroll() or 0
        local first   = math.floor(offset / LEARN_ROW_H)
        local visible = math.ceil((scroll:GetHeight() or 0) / LEARN_ROW_H) + 2

        for i = 1, visible do
            local row = rows[i] or createRow(i)
            local dataIndex = first + i
            local item = list[dataIndex]
            if item then
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -((dataIndex - 1) * LEARN_ROW_H))
                bindRow(row, item, dataIndex)
                row:Show()
            else
                row.key, row.rec = nil, nil
                row:Hide()
            end
        end
        for i = visible + 1, #rows do
            rows[i].key, rows[i].rec = nil, nil
            rows[i]:Hide()
        end
    end

    rebuild = function()
        local usable = scroll:GetWidth() or 0
        if usable > 20 and math.abs(usable - cols.width) > 0.5 then
            layout(usable)
            layoutHeader()
            content:SetWidth(usable)
        end

        list = Data.SortedLearned(which, filter)
        content:SetHeight(math.max(#list * LEARN_ROW_H, 1))

        local bucket = Data.LearnedBucket(which)
        local total  = bucket and bucket.n or 0
        countText:SetText(#list == total
            and (total .. " seen")
            or (#list .. " of " .. total .. " seen"))

        emptyText:SetText(total == 0
            and "Nothing recorded yet. Auras are written down as you meet them, so this fills up as you play — go and pull something."
            or "Nothing matches that.")
        emptyText:SetShown(#list == 0)
        syncRows()
        updateTrack()
    end

    scroll:HookScript("OnVerticalScroll", syncRows)
    scroll:HookScript("OnSizeChanged", function() rebuild() end)

    layoutHeader()

    -- Same hook the whitelist columns register: the engine calls it when it has
    -- written something down, which for this list is most of what it does.
    local pending = false
    auraColumns[#auraColumns + 1] = function()
        if pending or not shell:IsShown() then return end
        pending = true
        C_Timer.After(1, function()
            pending = false
            if shell:IsShown() then rebuild() end
        end)
    end

    shell:HookScript("OnShow", function()
        recordCB:SetChecked(auraRoot().learn ~= false)
        selectKind(which)
        -- The list's geometry isn't final on the frame it's first shown, so take
        -- a second pass once the layout has settled.
        C_Timer.After(0, rebuild)
    end)

    return shell
end

-- What the events switch is for. The one-liner sits under the checkbox because
-- that setting is off by default on NPCs and on by default on players, and a
-- switch whose default flips between tabs has to say why somewhere you can't
-- miss. The rest is a hover away: it's the reasoning, and reasoning costs rows
-- that the two lists below need more.
local AURA_EVENTS_TITLE = "Work missing auras out from events"

local AURA_EVENTS_HELP = {
    enemyPlayer = {
        note = "Classic Era never reports a hostile player's buffs — without this they cannot show at all.",
        body = {
            "The aura API answers for your target, your mouseover and your group. For anyone else it reports nothing, so a whitelisted buff on an enemy player can never appear however it is spelled.",
            "With this on, the module watches their cast land and reads the combat log's own aura lines instead.",
            "That makes it a record of what was last seen to happen rather than a reading of the unit: it can miss an aura applied before the plate came into view, or one that ran out while they were away from you. A real aura always wins where there is one.",
            "Neither source carries a duration. Fill in Timer(s) against a spell to give its worked-out icon a countdown.",
        },
    },
    enemyNPC = {
        note = "Rarely needed here — an NPC's debuffs read off the unit properly.",
        body = {
            "Debuffs you have applied to an NPC come back off the unit correctly, so working them out from events would only be a worse copy of what is already right.",
            "Worth turning on for buffs an NPC gives itself, which the client is no more forthcoming about than it is for players.",
            "Neither source carries a duration. Fill in Timer(s) against a spell to give its worked-out icon a countdown.",
        },
    },
}

-- ── One unit type ────────────────────────────────────────────────────────────
-- The events switch, which is the one setting that belongs to the unit type
-- rather than to either row, and then the two whitelists side by side. Debuffs
-- on the left because that is the row nearest the health bar by default, so the
-- panel reads bottom-up the way the plate does.
local function buildAuraUnitPanel(parent, def)
    local shell = CreateFrame("Frame", nil, parent)
    shell:SetAllPoints()
    shell:Hide()

    local function u() return auraUnit(def.key) end

    local help = AURA_EVENTS_HELP[def.key] or AURA_EVENTS_HELP.enemyNPC

    local eventsCB = createCheckbox(shell, "Work missing auras out from cast and combat log events", 400)
    eventsCB:SetPoint("TOPLEFT", 10, -8)
    eventsCB.OnChange = function(_, checked) u().fromEvents = checked; apply() end
    attachTooltip(eventsCB, AURA_EVENTS_TITLE, help.body)

    local eventsNote = shell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    eventsNote:SetPoint("TOPLEFT", eventsCB, "BOTTOMLEFT", 0, -2)
    eventsNote:SetPoint("RIGHT", shell, "RIGHT", -10, 0)
    eventsNote:SetJustifyH("LEFT")
    eventsNote:SetTextColor(unpack(C.textDim))
    eventsNote:SetText(help.note)

    local left  = buildAuraColumn(shell, def.key, "debuffs", "Debuffs")
    local right = buildAuraColumn(shell, def.key, "buffs",   "Buffs")

    left:SetPoint("TOPLEFT", eventsNote, "BOTTOMLEFT", 0, -10)
    left:SetPoint("BOTTOMRIGHT", shell, "BOTTOM", -7, 8)
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", 14, 0)
    right:SetPoint("BOTTOMRIGHT", shell, "BOTTOMRIGHT", -10, 8)

    local divider = shell:CreateTexture(nil, "ARTWORK")
    divider:SetTexture("Interface\\Buttons\\WHITE8x8")
    divider:SetVertexColor(unpack(C.tabBorder))
    divider:SetPoint("TOPLEFT", left, "TOPRIGHT", 6, 0)
    divider:SetPoint("BOTTOMRIGHT", left, "BOTTOMRIGHT", 7, 0)

    local function syncEvents() eventsCB:SetChecked(u().fromEvents and true or false) end

    shell:HookScript("OnShow", function()
        syncEvents()
        left.Refresh()
        right.Refresh()
        -- Neither column's geometry is final on the frame it is first shown —
        -- the wrapped note above them hasn't settled its height yet, so the
        -- lists don't know how tall they are. Same deferred re-fit the NPC list
        -- and makeScrollPanel both use.
        C_Timer.After(0, function()
            left.Refresh()
            right.Refresh()
        end)
        setAuraPreview(def.key)
    end)

    -- Covers every way out, not just the sub-tab buttons: OnHide also fires when
    -- an ancestor goes — leaving the module's tab, or closing the window — and
    -- those must switch the preview off too. Switching sub-tabs hides the old
    -- panel before showing the new one, so the nil never lands on top of the
    -- other type's preview.
    shell:HookScript("OnHide", function() setAuraPreview(nil) end)

    return shell
end

local function buildAurasPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()

    local master = createCheckbox(panel, "Enable aura tracking on nameplates", 320)
    master:SetPoint("TOPLEFT", 12, -6)
    master.OnChange = function(_, checked) auraRoot().enabled = checked; apply() end

    -- Synced both here and on OnShow: this panel is built already visible (it's
    -- resolved on the way into being shown), so the OnShow that re-syncs it on
    -- every later visit never fires for the first one.
    local function syncMaster() master:SetChecked(auraRoot().enabled ~= false) end

    local bar = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    bar:SetHeight(24)
    bar:SetPoint("TOPLEFT", master, "BOTTOMLEFT", -6, -6)
    bar:SetPoint("RIGHT", panel, "RIGHT", -6, 0)
    applyBackdrop(bar, 1, C.panelDark)

    local content = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    content:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -2)
    content:SetPoint("BOTTOMRIGHT", -6, 6)
    applyBackdrop(content, 1, C.panelDeep)

    -- A second, nested tab strip rather than three more entries on the module's
    -- own sub-bar: that bar is full at the window's minimum width, and the first
    -- two of these are one page shown twice over anyway.
    panel.subTabs, panel.subPanels = {}, {}

    local defs = {}
    for _, def in ipairs(Data.AURA_UNITS) do
        defs[#defs + 1] = {
            key   = def.key,
            label = def.label,
            width = 110,
            build = function() return buildAuraUnitPanel(content, def) end,
        }
    end
    -- Last, and set apart by being last: the two before it are where you say
    -- what to show, and this is where you find out what there is to ask for.
    defs[#defs + 1] = {
        key   = "learned",
        label = "Learned",
        width = 90,
        build = function() return buildLearnedPanel(content) end,
    }

    local prev
    for _, def in ipairs(defs) do
        local tab = createTab(bar, def.label, def.width)
        tab:SetHeight(20)
        tab.text:SetFontObject("GameFontNormalSmall")
        if prev then
            tab:SetPoint("LEFT", prev, "RIGHT", 4, 0)
        else
            tab:SetPoint("LEFT", 4, 0)
        end
        tab:SetScript("OnClick", function() selectSubTab(panel, def.key) end)
        panel.subTabs[def.key]   = tab
        panel.subPanels[def.key] = def.build
        prev = tab
    end

    panel:HookScript("OnShow", syncMaster)
    syncMaster()

    selectSubTab(panel, Data.AURA_UNITS[1].key)
    return panel
end

-- ── Search ───────────────────────────────────────────────────────────────────
-- The module has grown past the point where you can find a setting by opening
-- tabs until you spot it. Every form-built tab is a run of `form:` calls and
-- nothing else, so the index behind this tab is built by replaying those same
-- calls against a recorder that creates no frames and just writes down what it
-- was asked for. The list of settings and the panels showing them are therefore
-- the same list, and can't drift apart.
--
-- Auras and the NPC list are deliberately outside it: both are hand-built
-- editors for a list of things you add, not runs of labelled settings, so
-- there'd be nothing to record and nothing useful to match against.
local SEARCH_SOURCES = {
    { tab = "General",      fill = generalContent     },
    { tab = "Enemy NPC",    fill = enemyNPCContent    },
    { tab = "Enemy Player", fill = enemyPlayerContent },
    { tab = "Threat",       fill = threatContent      },
    { tab = "Target",       fill = targetContent      },
    { tab = "Icons",        fill = iconsContent       },
}

-- Rebuilding a recorded entry is the same call the panel made, so each kind
-- keeps its arguments by name rather than as a positional list — several of
-- them are optional and a table with holes in it can't be unpacked safely.
local REPLAY = {
    check    = function(form, e) form:check(e.label, e.a.get, e.a.set, e.a.onChange) end,
    stepper  = function(form, e) form:stepper(e.label, e.a.min, e.a.max, e.a.get, e.a.set, e.a.suffix, e.a.step) end,
    dropdown = function(form, e) form:dropdown(e.label, e.a.options, e.a.get, e.a.set, e.a.width) end,
    media    = function(form, e) form:media(e.label, e.a.kind, e.a.fallback, e.a.get, e.a.set, e.a.width) end,
    color    = function(form, e) form:color(e.label, e.a.getTbl) end,
}

-- What one replayed control occupies, so a result row can be sized before the
-- control inside it has been laid out. These match createCheckbox's row height
-- and form:row's, which is the only thing either kind ever produces.
local ENTRY_H = { check = 20, stepper = 22, dropdown = 22, media = 22, color = 22 }

-- Space above each control for the "which tab, which section" caption.
local CAPTION_H = 15

local function newRecorder(tab, out)
    local rec = {}

    local function add(kind, label, a)
        out[#out + 1] = { kind = kind, label = label, a = a, tab = tab, section = rec.section }
    end

    -- Headers aren't results in their own right; they're what tells you where a
    -- result you got lives, so the last one seen is carried onto every entry
    -- after it. Notes are prose about a setting rather than a setting.
    function rec:header(text) self.section = text end
    function rec:note() end
    function rec:refresh() end

    function rec:check(label, get, set, onChange)
        add("check", label, { get = get, set = set, onChange = onChange })
    end
    function rec:stepper(label, min, max, get, set, suffix, step)
        add("stepper", label, { min = min, max = max, get = get, set = set, suffix = suffix, step = step })
    end
    function rec:dropdown(label, options, get, set, width)
        add("dropdown", label, { options = options, get = get, set = set, width = width })
    end
    function rec:media(label, kind, fallback, get, set, width)
        add("media", label, { kind = kind, fallback = fallback, get = get, set = set, width = width })
    end
    function rec:color(label, getTbl)
        add("color", label, { getTbl = getTbl })
    end

    return rec
end

-- Built on the first search rather than at load: it costs a full pass over every
-- panel's declarations, and most sessions never open this tab.
local ENTRIES

local function collectEntries()
    if ENTRIES then return ENTRIES end
    ENTRIES = {}
    for _, src in ipairs(SEARCH_SOURCES) do
        src.fill(newRecorder(src.tab, ENTRIES))
    end
    for _, e in ipairs(ENTRIES) do
        -- One lowercased string per entry, matched with a plain (non-pattern)
        -- find: typing "colour (" or "%" shouldn't blow up as a Lua pattern.
        e.haystack = (e.tab .. " " .. (e.section or "") .. " " .. e.label):lower()
    end
    return ENTRIES
end

-- Enough to be worth scrolling, few enough that a one-letter search can't build
-- a hundred controls in a single frame (the "script ran too long" trap the lazy
-- tab building elsewhere exists to avoid).
local RESULT_CAP = 40

local function buildSearchPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()

    local searchLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    searchLbl:SetPoint("TOPLEFT", 14, -14)
    searchLbl:SetText("Search settings:")
    searchLbl:SetTextColor(unpack(C.textGrey))

    local countText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countText:SetTextColor(unpack(C.textDim))

    local rebuild

    local searchBox = textBox(panel, 240, 22, nil, 40)
    searchBox:SetPoint("LEFT", searchLbl, "RIGHT", 8, 0)
    -- Filters as you type, like the NPC list's own search: the index is a few
    -- hundred short strings, so a pass over it per keystroke is free, and only
    -- the handful of matches ever become frames.
    searchBox.box:SetScript("OnTextChanged", function() rebuild() end)

    countText:SetPoint("LEFT", searchBox, "RIGHT", 12, 0)

    local box = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    box:SetPoint("TOPLEFT", searchLbl, "BOTTOMLEFT", -6, -12)
    box:SetPoint("BOTTOMRIGHT", -8, 8)
    applyBackdrop(box, 1, C.panelDeep)

    local shell, content, refit = makeScrollPanel(box)
    shell:Show()

    local emptyText = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    emptyText:SetPoint("TOPLEFT", 14, -14)
    emptyText:SetWidth(ROW_W); emptyText:SetJustifyH("LEFT")
    emptyText:SetTextColor(unpack(C.textDim))

    -- One control per entry for the life of the window, created the first time
    -- that entry matches something. Typing narrows and widens constantly, so
    -- rebuilding the matches from scratch each keystroke would leak a control
    -- per keystroke — frames can't be destroyed once made.
    local function ensureRow(e)
        if e.row then return e.row end

        local row = CreateFrame("Frame", nil, content)
        row:SetSize(ROW_W, CAPTION_H + (ENTRY_H[e.kind] or 22))

        local caption = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        caption:SetPoint("TOPLEFT", 0, 0)
        caption:SetText(e.section and (e.tab .. "  ›  " .. e.section) or e.tab)
        caption:SetTextColor(unpack(C.red))

        -- Flush inside its own container rather than indented like a page, and
        -- clear of the caption above it.
        local form = newForm(row, 0, CAPTION_H)
        REPLAY[e.kind](form, e)

        e.row, e.form = row, form
        return row
    end

    rebuild = function()
        local query = (searchBox.box:GetText() or ""):lower():match("^%s*(.-)%s*$")
        local entries = collectEntries()

        local matched = {}
        if query ~= "" then
            for _, e in ipairs(entries) do
                if e.haystack:find(query, 1, true) then matched[#matched + 1] = e end
            end
        end

        local shown = math.min(#matched, RESULT_CAP)
        local live, prev = {}, nil
        for i = 1, shown do
            local e = matched[i]
            local row = ensureRow(e)
            live[e] = true
            row:ClearAllPoints()
            if prev then
                row:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -12)
            else
                row:SetPoint("TOPLEFT", content, "TOPLEFT", 14, -14)
            end
            row:Show()
            e.form:refresh()
            prev = row
        end

        -- Unanchored as well as hidden: the scroll panel measures its content by
        -- the lowest child edge, and a hidden row left anchored still has one.
        for _, e in ipairs(entries) do
            if e.row and not live[e] then
                e.row:Hide()
                e.row:ClearAllPoints()
            end
        end

        if query == "" then
            countText:SetText("")
            emptyText:SetText("Type any part of a setting's name — try \"font\", \"cast\", \"threat\", \"opacity\". Matches from every tab show up here and can be changed on the spot.")
        elseif #matched == 0 then
            countText:SetText("")
            emptyText:SetText("Nothing matches that. The Auras and NPC List tabs aren't searchable — they're lists you add to rather than settings.")
        elseif #matched > shown then
            countText:SetText(("first %d of %d"):format(shown, #matched))
            emptyText:SetText("")
        else
            countText:SetText(#matched == 1 and "1 setting" or (#matched .. " settings"))
            emptyText:SetText("")
        end
        emptyText:SetShown(emptyText:GetText() ~= "")

        refit()
    end

    -- Re-syncs whatever is on screen against the current profile, the same as
    -- every other tab's OnShow — a result left showing from last time would
    -- otherwise still be displaying the values of a profile you've since left.
    panel:HookScript("OnShow", function()
        rebuild()
        -- Same reason the other lists defer a second pass: the scroll panel's
        -- geometry isn't final on the frame it's first shown.
        C_Timer.After(0, refit)
    end)

    rebuild()
    return panel
end

-- ── Top-level Nameplates tab ─────────────────────────────────────────────────
local SUB_TAB_H   = 22
local SUB_ROW_PAD = 3
-- Padding above and below the single row.
local SUB_BAR_H   = SUB_TAB_H + SUB_ROW_PAD * 2

local function buildNameplatesShell(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()

    local subBar = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    subBar:SetHeight(SUB_BAR_H)
    subBar:SetPoint("TOPLEFT", 4, -4)
    subBar:SetPoint("TOPRIGHT", -4, -4)
    applyBackdrop(subBar, 1, C.panelDark)

    local subContent = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    subContent:SetPoint("TOPLEFT", subBar, "BOTTOMLEFT", 0, -2)
    subContent:SetPoint("BOTTOMRIGHT", -4, 4)
    applyBackdrop(subContent, 1, C.panelDeep)

    panel.subTabs, panel.subPanels = {}, {}

    -- One row, which is what sets these widths: eight tabs and Search have to
    -- fit inside a bar that is only about 590px at the window's minimum width,
    -- and a strip running off its own right edge hides whichever tabs fall off
    -- the end. That's also why two of the labels are shorter than the pages
    -- they open — "Threat" and "NPC List" cost 120px between them against the
    -- names they replaced, which is the difference between fitting and not.
    --
    -- Registered as builder functions, never built eagerly: the NPC list alone
    -- is a few hundred frames, and building every sub-tab on first open is what
    -- trips Blizzard's "script ran too long" watchdog.
    local defs = {
        { key = "general", label = "General",      width = 58, build = buildGeneralPanel     },
        { key = "npc",     label = "Enemy NPC",    width = 74, build = buildEnemyNPCPanel    },
        { key = "player",  label = "Enemy Player", width = 86, build = buildEnemyPlayerPanel },
        { key = "threat",  label = "Threat",       width = 54, build = buildThreatPanel      },
        { key = "target",  label = "Target",       width = 54, build = buildTargetPanel      },
        { key = "icons",   label = "Icons",        width = 48, build = buildIconsPanel       },
        { key = "auras",   label = "Auras",        width = 50, build = buildAurasPanel       },
        { key = "npclist", label = "NPC List",     width = 66, build = buildNpcPanel         },
    }

    local function addTab(def)
        local tab = createTab(subBar, def.label, def.width)
        tab:SetHeight(SUB_TAB_H)
        tab.text:SetFontObject("GameFontNormalSmall")
        tab:SetScript("OnClick", function() selectSubTab(panel, def.key) end)
        panel.subTabs[def.key]   = tab
        panel.subPanels[def.key] = function() return def.build(subContent) end
        return tab
    end

    local prev
    for _, def in ipairs(defs) do
        local tab = addTab(def)
        if prev then
            tab:SetPoint("LEFT", prev, "RIGHT", 4, 0)
        else
            tab:SetPoint("TOPLEFT", subBar, "TOPLEFT", 4, -SUB_ROW_PAD)
        end
        prev = tab
    end

    -- Anchored to the bar's right edge rather than after the last tab: it isn't
    -- one of the settings pages, it's the way into all of them, and the gap
    -- between it and them is what says so.
    addTab({ key = "search", label = "Search", width = 58, build = buildSearchPanel })
        :SetPoint("TOPRIGHT", subBar, "TOPRIGHT", -4, -SUB_ROW_PAD)

    selectSubTab(panel, "general")
    return panel
end

-- Adds the Nameplates entry to core's settings sidebar. Because this lives in
-- the module, disabling the addon removes the tab entirely.
UI.RegisterTab({ key = "nameplates", label = "Nameplates", order = 65, build = buildNameplatesShell,
    status = function()
        local d = addon.db and addon.db.settings and addon.db.settings.nameplates
        return d and d.enabled or false
    end })
