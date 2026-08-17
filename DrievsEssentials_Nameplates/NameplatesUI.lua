-- Nameplates module: settings UI. Loads only alongside core (## Dependencies),
-- so the shared namespace always exists.
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
local makeSubTabPanel      = W.makeSubTabPanel
local makeScrollPanel      = W.makeScrollPanel
local attachScrollTrack    = W.attachScrollTrack
local buildStepper         = W.buildStepper
local flatButton           = W.flatButton
local attachTooltip        = W.attachTooltip

-- Every accessor re-reads addon.db live, never captured at build time, so a
-- profile switch (which repoints addon.db) is reflected on the next OnShow
-- rather than writing to the old table.
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

-- Any change goes back through the engine's single re-derive entry point, so
-- plates update as you click rather than at the next pull.
local function apply()
    if addon.Nameplates then addon.Nameplates.refresh() end
end

-- Fake icons on every plate of one unit type while that tab is open. Guarded,
-- since the settings UI can outlive an engine that failed to load.
local function setAuraPreview(unitKey)
    local NP = addon.Nameplates
    if NP and NP.SetAuraPreview then NP.SetAuraPreview(unitKey) end
end

-- Same again for the boss mod strip, which previews on every plate rather than
-- on one unit type's — so it takes a flag rather than a key.
local function setBossPreview(on)
    local NP = addon.Nameplates
    if NP and NP.SetBossPreview then NP.SetBossPreview(on) end
end

-- And the raid marker / quest icon pair, which preview on every plate on screen
-- for the same reason the boss strip does: neither is fed by a unit type.
local function setIconPreview(on)
    local NP = addon.Nameplates
    if NP and NP.SetIconPreview then NP.SetIconPreview(on) end
end

local function mediaList(kind, fallback)
    return addon.MediaList(kind, { fallback = fallback })
end

-- The shared swatch, with this module's per-call square size (its NPC and aura
-- rows use smaller ones than the general panel) as a positional argument.
local function colorSwatch(parent, getRGB, setRGB, onChange, size)
    return W.createColorSwatch(parent, getRGB, setRGB, onChange, { size = size })
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
    UI.tint(box, C.textWhite)
    box:SetMaxLetters(maxLetters or 40)

    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEditFocusLost", function(self)
        if onCommit then onCommit(self:GetText()) end
    end)
    wrap:SetScript("OnEnter", function(self) UI.tintBorder(self, C.red) end)
    wrap:SetScript("OnLeave", function(self) UI.tintBorder(self, C.tabBorder) end)

    wrap.box = box
    return wrap
end

-- Grey prompt inside an empty box: a Classic Era EditBox has no placeholder, and
-- a label beside it costs panel width. Hidden on focus as well as on text —
-- prompt text under a live cursor reads as content.
local function setPlaceholder(wrap, text)
    local box  = wrap.box
    local hint = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("LEFT", 0, 0)
    hint:SetPoint("RIGHT", 0, 0)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(false)
    hint:SetText(text)
    UI.tint(hint, C.textDim)

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
-- The five settings panels are the same shape: a vertical run of labelled
-- controls, each reading and writing one key then re-applying. The builder keeps
-- them declarative and collects every refresh function so OnShow re-syncs all.
local LABEL_W = 200
local ROW_W   = 620

-- Where the first control lands inside the panel. Only passed by the Search tab,
-- which puts one control in a container of its own and needs it flush.
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
        UI.tint(h, C.red)
        if desc then
            local d = self.panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            d:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -4)
            d:SetWidth(ROW_W); d:SetJustifyH("LEFT")
            d:SetText(desc)
            UI.tint(d, C.textGrey)
            self.last = d
        end
        return h
    end

    function form:note(text)
        local n = self.panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        self:place(n, 6)
        n:SetWidth(ROW_W); n:SetJustifyH("LEFT")
        n:SetText(text)
        UI.tint(n, C.textDim)
        return n
    end

    -- `desc` is hover help: a setting's explanation lives in its tooltip rather than
    -- as grey text under the control, so a page stays scannable.
    function form:check(label, get, set, onChange, desc)
        local cb = createCheckbox(self.panel, label, 400, desc)
        self:place(cb, 10)
        cb.OnChange = function(_, checked)
            set(checked)
            if onChange then onChange(checked) else apply() end
        end
        self.controls[#self.controls + 1] = function() cb:SetChecked(get() and true or false) end
        return cb
    end

    -- An action rather than a setting: it writes nothing, so it registers no refresh
    -- callback and the Search recorder skips it — a button isn't findable by
    -- searching for what it changes, because it changes nothing.
    function form:button(text, onClick, desc, width)
        local btn = flatButton(self.panel, text, width or 170, 22, "GameFontNormalSmall")
        self:place(btn, 10)
        btn:SetScript("OnClick", onClick)
        attachTooltip(btn, text, desc)
        return btn
    end

    function form:row(label)
        local row = CreateFrame("Frame", nil, self.panel)
        row:SetSize(ROW_W, 22)
        self:place(row, 8)
        local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("LEFT", 0, 0)
        lbl:SetWidth(LABEL_W); lbl:SetJustifyH("LEFT")
        lbl:SetText(label)
        UI.tint(lbl, C.textGrey)
        row.lbl = lbl
        return row
    end

    function form:stepper(label, min, max, get, set, suffix, step, desc)
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
            UI.tint(s, C.textDim)
        end
        -- Both halves of the stepper, so the tooltip is there wherever on the
        -- control the cursor happens to land.
        attachTooltip(st, label, desc)
        attachTooltip(st.plus, label, desc)
        self.controls[#self.controls + 1] = st.Refresh
        return row
    end

    function form:dropdown(label, options, get, set, width, desc)
        local row = self:row(label)
        local dd = createDropdown(row, width or 160, options, get, set, apply, label, desc)
        dd:SetPoint("LEFT", row.lbl, "RIGHT", 6, 0)
        self.controls[#self.controls + 1] = dd.Refresh
        return row
    end

    -- `kind` doubles as the preview mode, so each row shows the font it names /
    -- the bar texture it names rather than just spelling it out.
    function form:media(label, kind, fallback, get, set, width, desc)
        local row = self:row(label)
        local dd = createScrollDropdown(row, width or 200,
            function() return mediaList(kind, fallback) end,
            function(name) set(name); apply() end,
            { preview = kind, tipTitle = label, tipBody = desc })
        dd:SetPoint("LEFT", row.lbl, "RIGHT", 6, 0)
        self.controls[#self.controls + 1] = function() dd:setValue(get() or fallback) end
        return row
    end

    -- getTbl() must hand back the live {r, g, b} table to mutate in place, so
    -- the swatch always edits whichever profile is active right now.
    function form:color(label, getTbl, desc)
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
        attachTooltip(sw, label, desc)
        self.controls[#self.controls + 1] = sw.Refresh
        return row
    end

    function form:refresh()
        for _, fn in ipairs(self.controls) do fn() end
    end

    return form
end

-- ── Font blocks ──────────────────────────────────────────────────────────────
-- Core's shared font block (Font.lua), laid out from this panel's own row
-- primitives rather than through UI.widgets.buildFontOptions: every setting on
-- these tabs has to be an individual `form:` call for the Search tab to index it
-- (see the recorder at the bottom of this file). Same settings, in the same
-- order, as every other font in the addon.
--
-- `get` returns the live block. `defaults` is what an unset field falls back to,
-- and takes a function for the per-element blocks — theirs is the general block,
-- so it changes as that one is edited.
local FONT_TIP =
    "Any font registered with LibSharedMedia by this or another addon."
local SHADOW_TIP =
    "Only visible once one of the shadow offsets below is non-zero — at no offset "
    .. "the shadow sits directly behind the text and is drawn as nothing at all."

local function fontLabels(prefix)
    if not prefix then
        return { "Font", "Font size", "Font outline",
                 "Custom font color", "Font color",
                 "Font X offset", "Font Y offset",
                 "Font shadow color", "Font shadow X", "Font shadow Y" }
    end
    return { prefix .. " font",              prefix .. " font size",
             prefix .. " font outline",      prefix .. " custom font color",
             prefix .. " font color",        prefix .. " font X offset",
             prefix .. " font Y offset",     prefix .. " font shadow color",
             prefix .. " font shadow X",     prefix .. " font shadow Y" }
end

local function fontBlock(form, prefix, get, defaults, opts)
    opts = opts or {}
    local F = addon.Font
    local L = fontLabels(prefix)
    local function def()
        return (type(defaults) == "function" and defaults()) or defaults or F.DEFAULTS
    end

    form:media(L[1], "font", F.DEFAULT_NAME,
        function() return F.Name(get(), def()) end,
        function(v) get().font = v end, nil, opts.fontDesc or FONT_TIP)
    form:stepper(L[2], opts.sizeMin or F.SIZE_MIN, opts.sizeMax or 32,
        function() return F.Size(get(), def()) end,
        function(v) get().size = v end)
    form:dropdown(L[3], F.OUTLINES,
        function()
            local v = get().outline or def().outline
            return (v == nil or v == "") and "NONE" or v
        end,
        function(v) get().outline = v end, 140, opts.outlineDesc)
    -- The colour is an override, so it is a tick box and a swatch: unticked, the
    -- text keeps whatever colour it would have had. form:color hands the swatch a
    -- live table to edit in place, so an unset colour is seeded from whatever
    -- this block currently resolves to rather than from a literal — for a
    -- per-element block that is the general one's.
    if not opts.skipColor then
        local colorDesc = opts.colorDesc
            or "Paints the text this colour. Left unticked it keeps whatever "
                .. "colour it already had."
        form:check(L[4],
            function() return F.ColorEnabled(get(), def()) end,
            function(v) get().colorEnabled = v end, nil, colorDesc)
        form:color(L[5], function()
            local block = get()
            if not block.color then
                local r, g, b = F.Color(nil, def())
                block.color = { r, g, b }
            end
            return block.color
        end, colorDesc)
    end
    form:stepper(L[6], -F.OFFSET_RANGE, F.OFFSET_RANGE,
        function() return (F.Offsets(get(), def())) end,
        function(v) get().x = v end, "px", nil, opts.offsetDesc)
    form:stepper(L[7], -F.OFFSET_RANGE, F.OFFSET_RANGE,
        function() return select(2, F.Offsets(get(), def())) end,
        function(v) get().y = v end, "px", nil, opts.offsetDesc)
    form:color(L[8], function()
        local block = get()
        if not block.shadowColor then
            local r, g, b = F.ShadowColor(nil, def())
            block.shadowColor = { r, g, b }
        end
        return block.shadowColor
    end, SHADOW_TIP)
    form:stepper(L[9], -F.SHADOW_RANGE, F.SHADOW_RANGE,
        function() return (F.ShadowOffsets(get(), def())) end,
        function(v) get().shadowX = v end, "px")
    form:stepper(L[10], -F.SHADOW_RANGE, F.SHADOW_RANGE,
        function() return select(2, F.ShadowOffsets(get(), def())) end,
        function(v) get().shadowY = v end, "px")
end

-- ── General ──────────────────────────────────────────────────────────────────
-- The general block, and the per-element ones that fall back to it. Adopt is
-- what upgrades a profile written before these were blocks; it is a no-op once
-- the login migration in NameplateData.lua has run.
local function genFont()
    return addon.Font.Adopt(gen(), "font", { size = "fontSize", outline = "fontOutline" })
end

local function elementFont(key, legacy)
    return addon.Font.Adopt(gen(), key, legacy)
end

-- One picker rather than a stack of switches: the three are alternatives, so as
-- checkboxes there was an order of precedence to learn and a combination that
-- quietly did nothing.
local TOT_COLOR_MODES = {
    { value = "class",  label = "Class of the target" },
    { value = "health", label = "How much health it has left" },
    { value = "drain",  label = "Health, draining across the name" },
    { value = "custom", label = "The colour below" },
}

-- Only the two bottom corners: the element sits below the plate by design, and
-- the name is pinned by whichever end is nearest so it grows inwards.
local TOT_ANCHORS = {
    { value = "bottomRight", label = "Bottom right, outside" },
    { value = "bottomLeft",  label = "Bottom left, outside"  },
}

-- Two options rather than the nine an icon gets: the bar belongs to that name
-- and lines its outer end up with it, so the only question is which side.
local TOT_BAR_PLACEMENTS = {
    { value = "below", label = "Below the name" },
    { value = "above", label = "Above the name" },
}

-- Wraps a content function — a run of `form:` calls and nothing else — in the
-- scrolling panel every tab uses. Splitting the two apart is what lets the
-- Search tab replay those same calls against a recorder to learn what settings
-- exist without building a frame: there is only one list of them.
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
    local PLATE_COLOR_NOTE =
        "Paints the text this colour. Left unticked it keeps whatever colour it "
        .. "already had — and a class-coloured name keeps its class colour either "
        .. "way, since that is decided per unit rather than here."
    fontBlock(form, nil, genFont, nil, {
        sizeMin = 6, sizeMax = 24,
        colorDesc = PLATE_COLOR_NOTE,
        offsetDesc = "Nudges every string on a plate that hasn't been given an offset of its own. Each unit type's own name and health-text nudges are added on top of this.",
    })

    form:header("Per-text fonts", "Each of these can be given a font of its own instead of the one above. Anything you leave alone still comes from the general settings, so a typeface on its own doesn't drag the size and outline with it.")
    -- Checkbox plus block rather than a "same as general" entry in the font list:
    -- that list is LibSharedMedia's, every entry renders itself in the font it
    -- names, and a sentinel row would have nothing to render with.
    local PER_TEXT_FONT_NOTE =
        "A block with its box unticked is ignored, and keeps whatever you left it on for next time."
    form:check("Name uses its own font",
        function() return gen().nameFontEnabled end,
        function(v) gen().nameFontEnabled = v end, nil, PER_TEXT_FONT_NOTE)
    fontBlock(form, "Name", function() return elementFont("nameFont") end, genFont,
        { sizeMin = 6, sizeMax = 24, fontDesc = PER_TEXT_FONT_NOTE,
          colorDesc = PLATE_COLOR_NOTE })
    form:check("Health text uses its own font",
        function() return gen().healthFontEnabled end,
        function(v) gen().healthFontEnabled = v end, nil, PER_TEXT_FONT_NOTE)
    fontBlock(form, "Health text", function() return elementFont("healthFont") end, genFont,
        { sizeMin = 6, sizeMax = 24, fontDesc = PER_TEXT_FONT_NOTE,
          colorDesc = PLATE_COLOR_NOTE })
    form:check("Level text uses its own font",
        function() return gen().levelFontEnabled end,
        function(v) gen().levelFontEnabled = v end, nil, PER_TEXT_FONT_NOTE)
    fontBlock(form, "Level", function() return elementFont("levelFont") end, genFont,
        { sizeMin = 6, sizeMax = 24, fontDesc = PER_TEXT_FONT_NOTE,
          colorDesc = PLATE_COLOR_NOTE })
    form:check("Guild name uses its own font",
        function() return gen().guildFontEnabled end,
        function(v) gen().guildFontEnabled = v end, nil, PER_TEXT_FONT_NOTE)
    fontBlock(form, "Guild name", function() return elementFont("guildFont") end, genFont,
        { sizeMin = 6, sizeMax = 24, fontDesc = PER_TEXT_FONT_NOTE,
          colorDesc = PLATE_COLOR_NOTE })
    form:stepper("Border thickness", 0, 5,
        function() return gen().borderSize end,
        function(v) gen().borderSize = v end, "px")
    form:color("Border color", function() gen().borderColor = gen().borderColor or { 0, 0, 0 }; return gen().borderColor end)
    form:color("Background color", function() gen().bgColor = gen().bgColor or { 0.08, 0.08, 0.10 }; return gen().bgColor end)
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
        function(v) gen().dimInactive = v end, nil,
        "A mob is counted as fighting you if you're on its threat table, or — where the game won't say — if it's swinging at you, your pet, or someone in your group.")
    form:stepper("Faded opacity", 5, 100,
        function() return gen().inactiveAlpha end,
        function(v) gen().inactiveAlpha = v end, "%", 5)

    form:header("Hover highlight", "Lightens the health bar of whichever unit the cursor is over, so you can see what you're about to click in a packed pull. Pointing at the mob itself counts, not only at its nameplate.")
    form:check("Highlight the nameplate under the mouse",
        function() return gen().hoverHighlight ~= false end,
        function(v) gen().hoverHighlight = v end)
    form:stepper("Highlight opacity", 0, 100,
        function() return gen().hoverAlpha end,
        function(v) gen().hoverAlpha = v end, "%", 5)

    form:header("Target of target",
        "Writes whoever a unit is currently swinging at under the bottom right corner of its plate — on every nameplate, not just the one you have targeted, since \"which of these is on the healer\" is a question about the mobs you aren't looking at.")
    form:check("Show each unit's current target",
        function() return gen().totEnabled end,
        function(v) gen().totEnabled = v end, nil,
        "There is no event for a mob changing target, so this is read ten times a second per plate. It costs nothing while it is switched off.")
    form:check("Target of target uses its own font",
        function() return gen().totFontEnabled end,
        function(v) gen().totFontEnabled = v end, nil,
        "A picker with its box unticked is ignored, and keeps whatever you left it on for next time.")
    -- The tick box above governs the face alone, so this block is passed no
    -- fallback of its own: everything but the typeface is this line's whether the
    -- box is on or off.
    fontBlock(form, "Target of target",
        function()
            return elementFont("totFont",
                { size = "totSize", outline = "totOutline", x = "totX", y = "totY" })
        end, genFont, {
        sizeMin = 6, sizeMax = 32,
        -- No colour row: "Colour by" below is this line's colour setting, and a
        -- second one in the block would be two controls fighting over one string.
        skipColor = true,
        outlineDesc = "Its own, not the general one: this line sits over the world rather than on a coloured bar, so what it takes to stay readable is a different question.",
        offsetDesc = "Nudges in screen directions rather than mirrored ones: +X is right on both sides. Applied to the corner the name hangs off rather than to the text, so it keeps growing the same way wherever you put it.",
    })
    form:stepper("Opacity", 10, 100,
        function() return gen().totAlpha end,
        function(v) gen().totAlpha = v end, "%", 5,
        "Fades the name only — the bar keeps its own. It's on top of whatever the plate is already at, so a faded nameplate still takes this with it.")
    form:dropdown("Corner", TOT_ANCHORS,
        function() return gen().totAnchor or "bottomRight" end,
        function(v) gen().totAnchor = v end, 170)
    form:dropdown("Colour by", TOT_COLOR_MODES,
        function() return gen().totColorMode or "class" end,
        function(v) gen().totColorMode = v end, 170,
        "One of them, never a mix. Class colour is the one that says a person is being hit rather than another NPC, before you've read the name; health is the one that says how hurt it is. Anything without a class colour to take — which is most targets — falls back to the custom colour below.")
    form:note("\"Draining across the name\" turns the name itself into the bar: it greys out from the right as health is lost, and what's left of it carries the green-to-red colour for whatever is left. The cut lands wherever the health does, mid-letter included — it isn't stepping a letter at a time.")
    form:color("Custom colour", function()
        gen().totColor = gen().totColor or { 0.80, 0.80, 0.80 }; return gen().totColor
    end, "Used outright in Custom, and as the fallback in Class for everything that isn't a player.")
    form:color("Health colour at full", function()
        gen().totRampFull = gen().totRampFull or { 0.00, 1.00, 0.00 }; return gen().totRampFull
    end, "The top of the ramp, used by whichever of the name and the bar you've set to health.")
    form:color("Health colour at half", function()
        gen().totRampMid = gen().totRampMid or { 1.00, 1.00, 0.00 }; return gen().totRampMid
    end, "The ramp fades to this on the way down and off it on the way to empty. It exists because a straight green-to-red fade spends the middle of its range in a muddy olive — set this to the halfway blend of the other two and you get that single fade back.")
    form:color("Health colour at empty", function()
        gen().totRampEmpty = gen().totRampEmpty or { 1.00, 0.00, 0.00 }; return gen().totRampEmpty
    end, "The bottom of the ramp.")
    form:color("Drained colour", function()
        gen().totSpentColor = gen().totSpentColor or { 0.35, 0.35, 0.35 }; return gen().totSpentColor
    end, "What the spent part of the name is left wearing in the draining mode. Dim rather than invisible out of the box — it's still a name, and half of one is no use — but it's yours to take as far as you like.")
    form:note("The three health colours drive the name and the bar both, wherever either of them is set to colour by health, so the two can't drift apart into different-looking ramps.")
    form:note("The name is pinned by whichever of its ends is nearest the corner you pick — the right end on the right, the left end on the left — so it grows inwards along the plate and stays flush with that corner however long it is. The nudges move the corner rather than the text, so it keeps growing the same way wherever you put it, and +X is rightwards on both sides. It sits below the cast bar where there is one, so a cast never slides out over it.")

    form:check("Show a health bar for it too",
        function() return gen().totBarEnabled end,
        function(v) gen().totBarEnabled = v end, nil,
        "How hurt whatever it's hitting is.")
    form:check("Colour the bar by how much health is left",
        function() return gen().totBarGradient ~= false end,
        function(v) gen().totBarGradient = v end, nil,
        "Green at full, yellow at half, red at empty — the ramp every health bar in the game uses, so it reads without being learned. Untick it and the bar takes the name's colour instead, which is what ties the two together as one element.")
    form:media("Bar texture", "statusbar", "Blizzard",
        function() return gen().totBarTexture end,
        function(v) gen().totBarTexture = v end)
    form:stepper("Bar height", 1, 20,
        function() return gen().totBarHeight end,
        function(v) gen().totBarHeight = v end, "px")
    form:stepper("Bar width", 0, 400,
        function() return gen().totBarWidth end,
        function(v) gen().totBarWidth = v end, "px", 5)
    form:dropdown("Bar sits", TOT_BAR_PLACEMENTS,
        function() return gen().totBarPlacement or "below" end,
        function(v) gen().totBarPlacement = v end, 150)
    form:stepper("Bar nudge X", -150, 150,
        function() return gen().totBarX end,
        function(v) gen().totBarX = v end, "px")
    form:stepper("Bar nudge Y", -150, 150,
        function() return gen().totBarY end,
        function(v) gen().totBarY = v end, "px")
    form:note("A bar width of 0 makes the bar exactly as wide as the name, re-measured as the name changes — so it reads as part of the name rather than as its own element. Any other value is a fixed width. Either way the bar's outer end lines up with the name's, on whichever corner you've put them.")
    form:note("The bar hangs off the same corner as the name rather than off the name itself, so the two nudge pairs move them separately — nudging the name leaves the bar where it is. Above/below decides which side of the name's resting line the bar starts on; once you've moved either of them, that's where it began rather than where they've ended up.")
    form:note("Health for anything outside your group is reported as a percentage rather than in hit points, which is why this is a bar and never a number — the fraction is the part that's true either way.")

    form:button("Test it for 20 seconds", function()
        local NP = addon.Nameplates
        if NP and NP.TestTargetOfTarget then NP.TestTargetOfTarget() end
    end, "Puts the name and its bar on every nameplate around you for twenty seconds, reading \"testmode\", with the health draining from full to empty so the whole colour ramp goes past. It ignores the two switches above, so it shows you something whether or not you've turned them on yet, and it keeps running with this window closed — which is the only way to see where this sits while you're actually playing.")

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
    form:stepper("Click box padding X", -100, 100,
        function() return gen().clickPadX end,
        function(v) gen().clickPadX = v end, "px", 1,
        { "Slack added either side of the widest bar to make the invisible click box, so clicks just off the end of a bar still land. Screen pixels, not bar pixels — it stays the same physical size whatever your interface scale.",
          "Negative pulls the box in narrower than the bar instead, for plates packed side by side where the ends of one keep catching clicks meant for its neighbour." })
    form:stepper("Click box padding Y", -100, 100,
        function() return gen().clickPadY end,
        function(v) gen().clickPadY = v end, "px", 1,
        { "The same above and below the bar — but this one also sets how far apart stacked nameplates sit, because the game spaces them by the click box rather than by the bar you see. At the default it's most of the gap: lower it to stack plates tighter, and the point where the name stops being clickable is roughly where to stop.",
          "Negative carries on past that, taking the box inside the bar so plates stack closer than the bar is tall. Less and less of the bar takes clicks as it goes, and the box never collapses past 1px however far you take it." })
    form:button("Show Clickpad Area for 10s", function()
        local NP = addon.Nameplates
        if NP and NP.ShowClickPadArea then NP.ShowClickPadArea() end
    end, "Shades the padding on every nameplate on screen for ten seconds: cyan is the slack the two numbers above add, and the clear gap inside it is your health bar. The top and bottom bands are the ones that also set stacking distance. It keeps running with this window closed, which is the only way to judge it against real plates.", 200)
    form:check("Keep nameplates the same size at any distance",
        function() return gen().constantSize ~= false end,
        function(v) gen().constantSize = v end, nil,
        "The game shrinks distant nameplates and grows the one you're targeting, on top of anything this addon does — so a 15% target scale ends up nearer 40%. This pins the game's own scaling to 1, leaving the Scale settings here as the only thing sizing a plate. Unticking puts back the values you had before it was first ticked.")
    form:check("Keep nameplates at the same opacity at any distance",
        function() return gen().constantAlpha ~= false end,
        function(v) gen().constantAlpha = v end, nil,
        "The same again for fading. The game dims every plate that isn't your target — half opacity out of the box — and fades distant ones, and it does it underneath everything on this page, so mobs you're fighting still grey out the moment you target one of them even with the Fade settings turned off. This pins the game's own fading to 1, leaving the Fade settings here as the only thing dimming a plate. Unticking puts back the values you had before it was first ticked.")
    form:note("The click area is the invisible box the game uses for targeting, separate from the bar you see. It tracks the widest bar on its own, following your width, height and scale settings; the two padding numbers are the slack added around that. Padding Y is worth knowing about even if clicking is fine — the game stacks nameplates by this box, not by the bar, so it and Vertical spacing multiply together to make the gap you actually see.")
end

local function buildGeneralPanel(parent)
    return formPanel(parent, generalContent)
end

-- ── Enemy NPC / Enemy Player ─────────────────────────────────────────────────
-- One builder for both: they differ only in heading text and the class-color
-- option, so a second near-identical panel would just be somewhere to drift
-- apart. Formats come off Data's list, so the dropdown can't offer one the
-- engine can't draw.
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
        function(v) grp(key).enabled = v end, nil,
        "Switched off, these units keep Blizzard's own nameplates instead of being hidden.")

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
        function(v) grp(key).namePlacement = v end, 170,
        "Inner places the name on the bar itself. Below sits where the cast bar goes, so nudge one of them clear if you use both.")
    form:stepper("Nudge X", -150, 150,
        function() return grp(key).nameX end,
        function(v) grp(key).nameX = v end, "px")
    form:stepper("Nudge Y", -100, 100,
        function() return grp(key).nameY end,
        function(v) grp(key).nameY = v end, "px")
    form:stepper("Truncate name after", 0, 40,
        function() return grp(key).truncateName end,
        function(v) grp(key).truncateName = v end, "characters (0 = never)")
    form:check("Show level",
        function() return grp(key).showLevel end,
        function(v) grp(key).showLevel = v end, nil,
        "Skull-level mobs show the lowest they could be with a \"+\" — the game won't give an exact number for anything that far above you.")

    form:header("Health text")
    form:check("Show health text on the bar",
        function() return grp(key).showHealthText end,
        function(v) grp(key).showHealthText = v end)
    local HEALTH_NUDGE_NOTE =
        "The nudge is applied on top of the alignment, so you can sit the text just off the end of the bar or lift it above."
    form:dropdown("Format", healthFormatOptions(),
        function() return grp(key).healthFormat or "percent" end,
        function(v) grp(key).healthFormat = v end, 140,
        "Each option is written the way it will appear on the bar.")
    form:dropdown("Align to", HEALTH_TEXT_ANCHORS,
        function() return grp(key).healthTextAnchor or "RIGHT" end,
        function(v) grp(key).healthTextAnchor = v end, 140)
    form:stepper("Nudge X", -100, 100,
        function() return grp(key).healthTextX end,
        function(v) grp(key).healthTextX = v end, "px", nil, HEALTH_NUDGE_NOTE)
    form:stepper("Nudge Y", -50, 50,
        function() return grp(key).healthTextY end,
        function(v) grp(key).healthTextY = v end, "px", nil, HEALTH_NUDGE_NOTE)

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
    form:color("Cast color", function()
        local g = grp(key); g.castColor = g.castColor or { 0.90, 0.70, 0.15 }; return g.castColor
    end)
    form:color("Channel color", function()
        local g = grp(key); g.castChannelColor = g.castChannelColor or { 0.35, 0.75, 0.95 }; return g.castChannelColor
    end)
end

local function enemyNPCContent(form)
    unitContent(form, "enemyNPC", "Enemy NPC",
        "Everything you can attack that isn't a player — trash, bosses, neutral mobs. Friendly NPCs borrow this layout too, with a friendly reaction color.",
        "Use custom nameplates for enemy NPCs",
        function(form, key)
            -- Two switches under one header rather than a section each: they are
            -- the same result reached over a different set of plates, and they
            -- share the font size underneath.
            form:header("Name only",
                "Dropping the bar and keeping just the name. What goes with it: the bar's outline, the level, the health text, the cast bar, the target ornament and every icon on the Icons tab. The name stays where your Position setting puts it — centred, since there are no bar edges left to sit against.")
            form:check("Always, for every NPC",
                function() return grp(key).nameOnlyAlways end,
                function(v) grp(key).nameOnlyAlways = v end, nil,
                "Every NPC plate, whether or not you can attack it — a screen of names and nothing else. Threat coloring has no bar left to color, so what it reaches is the name.\n\nWorth knowing: if \"Hide them on players shown as a name only\" is ticked on the Auras page, this switches the NPC aura rows off along with the bars, since every NPC plate is now a name-only one.")
            form:check("For NPCs I can't attack",
                function() return grp(key).nameOnlyWhenSafe end,
                function(v) grp(key).nameOnlyWhenSafe = v end, nil,
                "Quest givers, vendors, guards — and everything belonging to a player you can't attack: their pet, their totems, their guardians. There is no health worth watching and no cast worth interrupting on any of them, and the moment one becomes attackable the full plate is back.")
            form:stepper("Name font size without the bar", 6, 32,
                function() return grp(key).nameOnlySize end,
                function(v) grp(key).nameOnlySize = v end, nil, nil,
                "A size of its own, because the one on the Name section above is sized to share the bar with the level and the health text. With those gone the name is the whole plate and can afford to be bigger.")
        end)
end

local function enemyPlayerContent(form)
    unitContent(form, "enemyPlayer", "Enemy Player",
        "Hostile players — the other faction in the world, and anyone flagged for PvP. Friendly players borrow this layout too.",
        "Use custom nameplates for enemy players",
        function(form, key)
            local CLASS_COLOR_NOTE =
                "Threat coloring never applies to players, so these (or the hostile reaction color) are what you see. Either can be used without the other."
            form:header("Color")
            form:check("Color the health bar by class",
                function() return grp(key).classColor end,
                function(v) grp(key).classColor = v end, nil, CLASS_COLOR_NOTE)
            form:check("Color the name by class",
                function() return grp(key).classColorName end,
                function(v) grp(key).classColorName = v end, nil, CLASS_COLOR_NOTE)

            form:header("Guild",
                "Their guild name in angle brackets, on a line of its own. Only players have one, so nothing here reaches an NPC plate — and a player with no guild simply has no line rather than a blank one.")
            form:check("Show guild name",
                function() return grp(key).showGuild end,
                function(v) grp(key).showGuild = v end, nil,
                "Read straight off the unit, so it is there for anyone the client will answer about — it does not need them targeted or inspected.")
            form:stepper("Guild font size", 6, 24,
                function() return grp(key).guildSize end,
                function(v) grp(key).guildSize = v end)
            form:dropdown("Guild position", namePlacementOptions(),
                function() return grp(key).guildPlacement or "belowCenter" end,
                function(v) grp(key).guildPlacement = v end, 170,
                "Anchored against the health bar exactly as the name is, and set independently of it — so the name can sit on the bar with the guild under it, which is where this starts. Below is also where the cast bar goes, so nudge one clear of the other if you use both.")
            form:stepper("Guild nudge X", -150, 150,
                function() return grp(key).guildX end,
                function(v) grp(key).guildX = v end, "px")
            form:stepper("Guild nudge Y", -100, 100,
                function() return grp(key).guildY end,
                function(v) grp(key).guildY = v end, "px")

            form:header("Players you can't attack",
                "Anyone on your own side, and the other faction where PvP isn't live. There's no health worth watching and no cast worth interrupting on them.")
            form:check("Show only their name, with no bar",
                function() return grp(key).nameOnlyWhenSafe end,
                function(v) grp(key).nameOnlyWhenSafe = v end, nil,
                "The bar, its outline, the level, the health text, the cast bar, the target ornament and every icon on the Icons tab all go; the name stays exactly where your Position setting puts it — centred, since there are no bar edges left to sit against. Flagging for PvP brings the full plate back straight away.")
            form:stepper("Name font size without the bar", 6, 32,
                function() return grp(key).nameOnlySize end,
                function(v) grp(key).nameOnlySize = v end, nil, nil,
                "A size of its own, because the one on the Name section above is sized to share the bar with the level and the health text. With those gone the name is the whole plate and can afford to be bigger.")
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
    form:header("Threat coloring",
        "Recolors enemy NPC health bars by how much threat you have on them. Players are never threat-colored — they use their class or reaction color instead.")
    form:check("Enable threat coloring",
        function() return threatData().enabled end,
        function(v) threatData().enabled = v end)
    form:check("Tank mode — I'm the one meant to be holding threat",
        function() return threatData().tankMode end,
        function(v) threatData().tankMode = v end)
    form:check("Only color units that are fighting me or my group",
        function() return threatData().combatOnly end,
        function(v) threatData().combatOnly = v end, nil,
        "Everything else keeps its reaction color instead — red for hostile, yellow for neutral — which is what a mob you have nothing to do with should be telling you. Untick this and anything in combat with anybody gets threat-colored, which reads as reassuring green on mobs whose threat table you aren't even on.")

    form:header("Threat colors — DPS and healers")
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
    end, "The main tank color needs a raid Main Tank assignment to appear, so it never shows up solo or in a party. It's checked after your own threat, so it can't hide a mob that's actually on you.")

    form:header("Threat colors — tank mode", "The same three states with their meanings flipped: holding threat is what you want.")
    form:color("Holding threat (good)", function()
        local c = threatData().colors; c.tankSecure = c.tankSecure or { 0.25, 0.55, 0.95 }; return c.tankSecure
    end)
    form:color("Losing threat", function()
        local c = threatData().colors; c.tankLosing = c.tankLosing or { 0.95, 0.80, 0.20 }; return c.tankLosing
    end)
    form:color("Lost it entirely (bad)", function()
        local c = threatData().colors; c.tankLost = c.tankLost or { 0.90, 0.15, 0.15 }; return c.tankLost
    end)

    form:header("Priority against NPC colors",
        "An NPC tagged on the NPC List tab normally keeps its own color no matter what your threat on it is. These decide when threat is allowed to take it over.")
    local OVERRIDE_NOTE = {
        "With the first two ticked, a tagged NPC keeps its color right up until it turns on you — then it flips to the aggro color so you can't miss it. Add the third and it flips one step earlier, while you're still climbing the list and can still do something about it. Untick the second to have threat coloring win at every threat level.",
        "In tank mode the same two steps are losing your grip on threat and having lost it outright.",
    }
    form:check("Threat colors override custom NPC colors",
        function() return threatData().overrideNpcColors end,
        function(v) threatData().overrideNpcColors = v end, nil, OVERRIDE_NOTE)
    form:check("...only once I've actually pulled threat",
        function() return threatData().overrideOnlyOnAggro end,
        function(v) threatData().overrideOnlyOnAggro = v end, nil, OVERRIDE_NOTE)
    form:check("...counting climbing the threat list as pulled",
        function() return threatData().overrideOnGaining end,
        function(v) threatData().overrideOnGaining = v end, nil, OVERRIDE_NOTE)

    form:header("Reaction colors", "Used whenever threat coloring doesn't apply — out of combat, on units you're not on the threat table of, and on friendly units.")
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
-- The nine frame anchor points rather than every string a frame accepts, since
-- those nine are the ones that mean something against a health bar.
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
        "Markers hung off the health bar. Each one picks a point on the bar to sit against, then gets nudged from there — the icon is centred on that point, so changing its size won't move it. A plate showing only a name has no bar to hang them off, so it gets none of these.")

    form:note("While this tab is open every icon you have switched on is drawn on all the nameplates around you, whatever those mobs actually are, so the placement can be judged against a real plate. They go back to the truth as soon as you leave.")

    -- One builder for all six: they differ only in heading and what turns them on.
    local function iconGroup(title, key, desc, showLabel, showDesc)
        form:header(title, desc)
        form:check(showLabel,
            function() return iconData(key).enabled ~= false end,
            function(v) iconData(key).enabled = v end, nil, showDesc)
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
        "Show the quest icon",
        "Quest status is read off the mob's tooltip, which is the only place the game exposes it — so it can take a moment to appear on a plate that has only just come into view.")

    -- The last four are all "what the unit IS" rather than what it's doing, so
    -- they share one explanation.
    local UNIT_KIND_NOTE =
        "These four — faction, elite, rare and pet — say what the unit IS, so they're worked out once when a plate picks a unit up rather than re-checked as you fight; nothing here changes mid-pull. All four ship switched off: they're new, and a plate you already had set up shouldn't sprout four icons because you updated the addon."

    iconGroup("Faction icon", "faction",
        "The Alliance lion or the Horde symbol, on anything that fights for one of them — enemy players, and the NPCs that belong to a side. Neutral mobs have no faction to show and get nothing.",
        "Show the faction icon", UNIT_KIND_NOTE)

    iconGroup("Elite icon", "elite",
        "The gold dragon, on elites and world bosses.",
        "Show the elite icon", UNIT_KIND_NOTE)

    iconGroup("Rare icon", "rare",
        "The silver dragon, on rares. A rare elite is both, and wears both — these are separate switches, so it is yours to decide which of the two you want on the plate.",
        "Show the rare icon", UNIT_KIND_NOTE)

    iconGroup("Pet icon", "pet",
        "Shown on anything a player owns rather than something that wandered up on its own: hunter pets, warlock minions, and whatever else is currently answering to someone.",
        "Show the pet icon", UNIT_KIND_NOTE)
end

local function buildIconsPanel(parent)
    local page = formPanel(parent, iconsContent)
    -- Stand-in markers on every plate while this page is up, as the aura and boss
    -- mod tabs do. OnHide covers every way out — it fires when an ancestor goes too,
    -- so leaving the module's tab or closing the window switches them off as well.
    page:HookScript("OnShow", function() setIconPreview(true)  end)
    page:HookScript("OnHide", function() setIconPreview(false) end)
    return page
end

-- ── Target ───────────────────────────────────────────────────────────────────
-- Built once from Data.TARGET_INDICATOR_ORDER: pairs() over the preset table has
-- no order, and a picker that reshuffles every login is unusable.
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
    form:color("Outline color", function()
        local t = targetData(); t.highlightColor = t.highlightColor or { 1, 1, 1 }; return t.highlightColor
    end)
    form:stepper("Outline thickness", 1, 6,
        function() return targetData().highlightSize end,
        function(v) targetData().highlightSize = v end, "px")

    form:header("Indicator")
    form:dropdown("Style", indicatorOptions(),
        function() return targetData().indicator or "None" end,
        function(v) targetData().indicator = v end, 160,
        "Ornaments placed around the targeted nameplate's health bar. Some sit at the four corners (Pins, Magneto, Gray Bold, Silver), others at the left and right edges (Ornament, Golden, Epic). They scale with the nameplate so they keep their proportions at any size, and each preset carries its own color unless you override it below. \"None\" turns them off.")
    form:check("Override the indicator's color",
        function() return targetData().indicatorColorEnabled end,
        function(v) targetData().indicatorColorEnabled = v end)
    form:color("Indicator color", function()
        local t = targetData(); t.indicatorColor = t.indicatorColor or { 1, 1, 1 }; return t.indicatorColor
    end)

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
-- A virtualised table: only enough rows to fill the visible area exist, re-bound
-- to a different slice as you scroll. The list runs to hundreds of entries after
-- a few raid nights, and a frame per row would stall the window open.
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
    desc:SetText("For raid and dungeon NPCs: they're added to this list the first time you see one. Tick an NPC and give it a color to make its nameplate stand out, and optionally a shorter name to show instead of the real one.")
    UI.tint(desc, C.textGrey)

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
    UI.tint(searchLbl, C.textGrey)

    local searchBox = textBox(shell, 160, 20, nil, 60)
    searchBox:SetPoint("LEFT", searchLbl, "RIGHT", 6, 0)
    -- Filters as you type rather than on Enter: the list is short enough that
    -- re-sorting per keystroke is free.
    searchBox.box:SetScript("OnTextChanged", function(self)
        filter = self:GetText() or ""
        rebuild()
    end)

    local addLbl = shell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    addLbl:SetPoint("LEFT", searchBox, "RIGHT", 18, 0)
    addLbl:SetText("Add NPC ID:")
    UI.tint(addLbl, C.textGrey)

    local addBox = textBox(shell, 70, 20, nil, 8)
    addBox:SetPoint("LEFT", addLbl, "RIGHT", 6, 0)

    local addBtn = flatButton(shell, "Add", 50, 22)
    addBtn:SetPoint("LEFT", addBox, "RIGHT", 6, 0)
    addBtn:SetScript("OnClick", function()
        local id = tonumber(addBox.box:GetText())
        if not id then return end
        local d = npData()
        d.npcs = d.npcs or {}
        -- Nothing maps an ID to a name offline, so a hand-added entry starts as a
        -- placeholder and Data.Remember fills the name in when the mob is first seen.
        -- Typing an ID you already have is a request to turn it on, not a no-op.
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
            message     = "Remove every NPC that was auto-detected and never configured?\n\nAnything you enabled, renamed or colored is kept.",
            confirmText = "Clear",
            onConfirm   = function()
                Data.ClearAutoNpcs()
                rebuild()
            end,
        })
    end)

    local countText = shell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countText:SetPoint("LEFT", clearBtn, "RIGHT", 16, 0)
    UI.tint(countText, C.textDim)

    -- ── Column header ────────────────────────────────────────────────────────
    -- Anchored under the toolbar rather than at a fixed offset: the description
    -- above wraps differently depending on window width, and a fixed offset would
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
        UI.tint(fs, C.textWhite)
        return fs
    end
    headerLabel("On",       COL.enable, 30)
    headerLabel("NPC ID",   COL.id,     56)
    headerLabel("NPC Name", COL.name,   155)
    headerLabel("Rename To",COL.rename, 115)
    headerLabel("Zone",     COL.zone,   135)
    headerLabel("Color",   COL.swatch, 120)
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
    UI.tint(emptyText, C.textDim)
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
            -- An entry switched on with no color yet would look like a no-op,
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
        UI.tint(row.idText, C.textGrey)

        row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.nameText:SetPoint("LEFT", COL.name, 0)
        row.nameText:SetWidth(155); row.nameText:SetJustifyH("LEFT")
        UI.tint(row.nameText, C.textWhite)

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
        UI.tint(row.zoneText, C.textGrey)

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
        UI.tint(row.remove.label, C.red)
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
        -- Scrolling recycles rows under the cursor. Dropping focus BEFORE the row is
        -- repointed lets the rename box commit to the NPC it was typed into rather than
        -- whichever has just scrolled into its place.
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
        -- The list's geometry (and so how many rows fit) isn't final on the frame it's
        -- first shown, so take a second pass once the layout has settled.
        C_Timer.After(0, rebuild)
    end)

    -- Throttled: pulling a big trash pack fires this a dozen times a second, and
    -- each rebuild re-sorts the whole list.
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
-- Four of these, one per unit type per row, each a complete editor with its own
-- look settings and whitelist. Two sit side by side under each unit tab, so a
-- column is half the panel wide — and half of a resizable window isn't a fixed
-- number, so everything below is measured off the column's live width.
local AURA_ROW_H = 22

-- Only the spell name flexes; the rest of the columns are as wide as what goes
-- in them, and squeezing those would just overlap the text.
local AURA_ICON_W   = 18
local AURA_MATCH_W  = 54
local AURA_TIMER_W  = 38
local AURA_REMOVE_W = 20
local AURA_NAME_MIN = 60

-- The row of "put this on a special frame" boxes each whitelist entry carries
-- under it. One line of them is shorter than the entry's own row: they are a
-- footnote to it, and reading as one is what keeps a list of ten auras with
-- three frames from reading as a list of forty things.
local BAR_CHECK_H   = 17
local BAR_CHECK_BOX = 14   -- createCheckbox's own square, which it doesn't expose
local BAR_CHECK_GAP = 10

-- A group heading inside a whitelist, and the gap above it that separates one
-- section from the last. The gap is part of the heading's height rather than
-- padding on the row before it, so the list stays a run of items whose heights
-- add up — which is what the virtualised list walks.
local GROUP_ROW_H = 20
local GROUP_GAP   = 6

local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"

-- ── Dragging an aura onto a group ────────────────────────────────────────────
-- One ghost for the whole addon, not one per column: only one drag can be in
-- flight, and it is what makes a drag legible — without something under the
-- cursor, dragging is indistinguishable from a click that did nothing.
--
-- Built on first use. Most sessions never drag anything.
local dragGhost
local function auraDragGhost()
    if dragGhost then return dragGhost end

    local g = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    g:SetSize(200, 22)
    -- Over the settings window, which is DIALOG: a ghost the window covers is
    -- worse than no ghost.
    g:SetFrameStrata("TOOLTIP")
    applyBackdrop(g, 1, C.panelDark, C.red)
    g:Hide()

    g.icon = g:CreateTexture(nil, "ARTWORK")
    g.icon:SetSize(16, 16)
    g.icon:SetPoint("LEFT", 4, 0)
    g.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    g.text = g:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    g.text:SetPoint("LEFT", g.icon, "RIGHT", 5, 0)
    g.text:SetPoint("RIGHT", -6, 0)
    g.text:SetJustifyH("LEFT")
    g.text:SetWordWrap(false)
    UI.tint(g.text, C.textWhite)

    -- Follows the cursor here rather than in the column that owns the drag, so
    -- the column has one job: say what a drop would mean. `tick` is set while a
    -- drag is in flight and is what hit-tests and finishes it.
    g:SetScript("OnUpdate", function(self)
        local scale = UIParent:GetEffectiveScale()
        local x, y = GetCursorPosition()
        self:ClearAllPoints()
        -- Below and right of the cursor, so the pointer stays on the row it is
        -- over rather than on the thing it is carrying.
        self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale + 14, y / scale - 4)
        if self.tick then self.tick() end
    end)

    dragGhost = g
    return g
end

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

-- Where each column starts for a given usable width. Right-hand columns are
-- placed from the right edge inwards, so the flexible name column absorbs every
-- pixel the window gains or loses.
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

-- Every column built so far, so the engine's "an entry just learned an ID"
-- callback can reach all of them. Columns are never destroyed, so this only ever
-- grows to four.
local auraColumns = {}

if addon.Nameplates then
    addon.Nameplates.onAuraLearned = function()
        for _, notify in ipairs(auraColumns) do notify() end
    end
end

-- A column's heading and the refresh closures its controls register, so one
-- Refresh() re-syncs the lot. Shared by both pages rather than written twice,
-- which is what keeps the Buffs and Debuffs columns from drifting apart.
local function newAuraColumn(parent, label)
    local col = { shell = CreateFrame("Frame", nil, parent), refresh = {} }

    local head = col.shell:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    head:SetPoint("TOPLEFT", 2, -2)
    head:SetText(label)
    UI.tint(head, C.red)
    col.head = head

    return col
end

-- ── Number grid ──────────────────────────────────────────────────────────────
-- Two steppers to a line at fixed x positions rather than packed left to right:
-- the labels are different lengths, so packing would land the second stepper
-- somewhere different on every line.
--
-- Shared by the appearance columns and the special frame editor, which lay out
-- the same run of numbers in the same half-width space — and, being the same
-- settings, would be a bug if they ever stopped looking alike.
local STEP_COL2 = 134
local STEP_LBL  = 42

local function numberGrid(shell, refresh)
    local g = {}

    function g.line(above, gap)
        local line = CreateFrame("Frame", nil, shell)
        line:SetHeight(22)
        line:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -(gap or 5))
        line:SetPoint("RIGHT", shell, "RIGHT", 0, 0)
        return line
    end

    function g.label(line, x, text)
        local fs = line:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("LEFT", x, 0)
        fs:SetWidth(STEP_LBL); fs:SetJustifyH("LEFT")
        fs:SetText(text)
        UI.tint(fs, C.textGrey)
        return fs
    end

    function g.stepper(line, x, text, min, max, get, set)
        local fs = g.label(line, x, text)
        local st = buildStepper(line, {
            min = min, max = max, step = 1, valueWidth = 32, gap = 4,
            get = function() return tonumber(get()) or min end,
            set = function(v) set(v); apply() end,
        })
        st:SetPoint("LEFT", fs, "RIGHT", 2, 0)
        refresh[#refresh + 1] = st.Refresh
        return st
    end

    return g
end

-- ── Appearance column ────────────────────────────────────────────────────────
-- What the row looks like and where it sits. Nothing here decides what shows up
-- — that's the tracking page — which is why they're separate pages: this is a
-- wall of numbers you set once, that one is a list you come back to.
local function buildAuraLookColumn(parent, unitKey, which, label)
    local col     = newAuraColumn(parent, label)
    local shell   = col.shell
    local refresh = col.refresh

    local function o() return auraOpts(unitKey, which) end

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
    showCB:SetPoint("TOPLEFT", col.head, "BOTTOMLEFT", 0, -6)

    -- Clipped labels rather than full sentences: three switches on one line beats
    -- three lines of prose in a half-width column.
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
    local grid = numberGrid(shell, refresh)
    local newLine, addLabel, addStepper = grid.line, grid.label, grid.stepper

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
    local swatchLbl = addLabel(borderLine, STEP_COL2, "Color")
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

    -- ── Magic border ─────────────────────────────────────────────────────────
    -- Buffs only. A buff that is Magic is the one thing on a hostile plate that
    -- is a decision — it means purgeable — and repainting its border is how you
    -- pick it out of a queue of identical squares without adding a second row.
    -- A debuff's own school is somebody else's problem, on somebody else's frame,
    -- so the debuffs column doesn't carry this at all.
    local lastLine = borderLine
    if which == "buffs" then
        local magicLine = newLine(borderLine)
        local magicCB = createCheckbox(magicLine, "Magic border", 120)
        magicCB:SetPoint("LEFT", 0, 0)
        magicCB.OnChange = function(_, checked) o().magicBorder = checked; apply() end
        refresh[#refresh + 1] = function()
            magicCB:SetChecked(o().magicBorder and true or false)
        end
        attachTooltip(magicCB, "Magic border", {
            "Marks a purgeable buff: its border is drawn in the color beside this, at the thickness under it, instead of the row's usual one. Everything else about the icon is unchanged — it is a mark on something you were already watching, not a second kind of icon.",
            "It stands on its own, so a row drawn with no border at all still marks the ones you can dispel.",
            "The client only reports an aura's school for a unit it will answer about at all: your target, your mouseover, and your own group. Everywhere else — which on an enemy player is every buff they have, since Classic Era will not list those at all — the school comes from the addon's own table of 1.12 spells instead.",
            "So a spell that table has never heard of, and that the client will not answer about either, draws with the plain border.",
        })

        local magicLbl = addLabel(magicLine, STEP_COL2, "Color")
        local magicSwatch = colorSwatch(magicLine,
            function()
                local c = o().magicBorderColor or {}
                return c[1] or 0.25, c[2] or 0.45, c[3] or 1
            end,
            function(r, g, b)
                local t = o()
                t.magicBorderColor = t.magicBorderColor or {}
                t.magicBorderColor[1], t.magicBorderColor[2], t.magicBorderColor[3] = r, g, b
            end,
            apply, 18)
        magicSwatch:SetPoint("LEFT", magicLbl, "RIGHT", 2, 0)
        refresh[#refresh + 1] = magicSwatch.Refresh

        -- A line of its own rather than squeezed in beside the swatch: a labelled
        -- stepper runs to STEP_COL2 on its own, which is exactly where the color
        -- above it starts.
        --
        -- Thicker than the row's border by default, and separate from it, because
        -- this is a mark meant to be caught in peripheral vision mid-fight and the
        -- same weight in another color is not one. 0 is allowed and means no mark,
        -- which is why the floor is not 1.
        local magicSizeLine = newLine(magicLine)
        addStepper(magicSizeLine, 0, "Thick", 0, 6,
            function() return o().magicBorderSize or 2 end,
            function(v) o().magicBorderSize = v end)

        lastLine = magicSizeLine
    end

    local growLine = newLine(lastLine)
    addLabel(growLine, 0, "Grow")
    local growDD = createDropdown(growLine, 150, AURA_GROWTH_OPTIONS,
        function() return Data.AuraGrowth(o().growth) end,
        function(v) o().growth = v end, apply)
    growDD:SetPoint("LEFT", growLine, "LEFT", STEP_LBL + 2, 0)
    refresh[#refresh + 1] = growDD.Refresh

    shell.Refresh = function()
        for _, fn in ipairs(refresh) do fn() end
    end
    return shell
end

-- ── Special buff frames ──────────────────────────────────────────────────────
-- Extra strips of icons off the side of the plate, each holding whichever
-- whitelist entries have been ticked onto it over on the tracking page. This is
-- where the frames themselves are made and placed; what goes ON them is decided
-- next to the auras, because that is where you are when you decide it.
--
-- Same two-column split as the other pages, but the halves are a list and an
-- editor rather than buffs and debuffs: there are at most five frames and they
-- carry a screenful of settings each, so a column apiece is the shape that fits.
local SPECIAL_ANCHOR_OPTIONS = {}
for _, e in ipairs(Data.SPECIAL_ANCHORS) do
    SPECIAL_ANCHOR_OPTIONS[#SPECIAL_ANCHOR_OPTIONS + 1] = { value = e.value, label = e.short or e.label }
end

local SPECIAL_GROWTH_OPTIONS = {}
for _, e in ipairs(Data.SPECIAL_GROWTHS) do
    SPECIAL_GROWTH_OPTIONS[#SPECIAL_GROWTH_OPTIONS + 1] = { value = e.value, label = e.short or e.label }
end

local SPECIAL_ROW_H = 22

local SPECIAL_INTRO = {
    "A strip of icons of its own, off whichever side of the plate you point it at. Anything on the two whitelists can be moved onto one — tick it in the row of boxes under the aura, over on Aura Tracking.",
    "What it is for is the aura the pull is actually about. Above the health bar an interrupt-me cast and a stacking bleed are two more 28px squares in a queue of eight; on a frame of their own at twice the size, off to the side, they are the thing you see.",
    "An aura moved onto a frame stops being drawn above the health bar — it is shown there INSTEAD, not as well.",
}

-- The list half. Rows are built once for the whole cap and bound on refresh:
-- five is few enough that a scrolling, recycling list would be more machinery
-- than the thing it lists.
local function buildSpecialList(shell, unitKey, opts)
    local col  = newAuraColumn(shell, "Frames")
    local list = col.shell
    local rows = {}

    local info = list:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    info:SetPoint("TOPLEFT", col.head, "BOTTOMLEFT", 2, -6)
    info:SetPoint("RIGHT", list, "RIGHT", -2, 0)
    info:SetJustifyH("LEFT")
    info:SetWordWrap(false)

    -- A heading is a FontString and takes no mouse, so the hover target is a
    -- frame laid over it — the same trick the whitelist's row icons use.
    local headHit = CreateFrame("Frame", nil, list)
    headHit:SetAllPoints(col.head)
    headHit:EnableMouse(true)
    attachTooltip(headHit, "Special buff frames", SPECIAL_INTRO)

    -- Same toolbar as the whitelist's, and for the same reason: the count above
    -- doubles as the line a rejected add explains itself on.
    local toolRow = CreateFrame("Frame", nil, list)
    toolRow:SetHeight(20)
    toolRow:SetPoint("TOPLEFT", info, "BOTTOMLEFT", -2, -4)
    toolRow:SetPoint("RIGHT", list, "RIGHT", 0, 0)

    local addBtn = flatButton(toolRow, "Add", 42, 20, "GameFontNormalSmall")
    addBtn:SetPoint("RIGHT", 0, 0)

    local addBox = textBox(toolRow, 100, 20, nil, Data.SPECIAL_NAME_MAX)
    addBox:SetPoint("LEFT", 0, 0)
    addBox:SetPoint("RIGHT", addBtn, "LEFT", -4, 0)
    setPlaceholder(addBox, "name")

    local function doAdd()
        local bar, err = Data.AddSpecialBar(unitKey, addBox.box:GetText())
        if not bar then
            info:SetText(err or "")
            UI.tint(info, C.red)
            return
        end
        addBox.box:SetText("")
        addBox.box:ClearFocus()
        -- Straight onto the new one: you made it to set it up.
        opts.select(bar.id)
        apply()
    end
    addBtn:SetScript("OnClick", doAdd)
    addBox.box:SetScript("OnEnterPressed", doAdd)

    local listBox = CreateFrame("Frame", nil, list, "BackdropTemplate")
    listBox:SetPoint("TOPLEFT", toolRow, "BOTTOMLEFT", 0, -8)
    listBox:SetPoint("RIGHT", list, "RIGHT", 0, 0)
    listBox:SetHeight(Data.SPECIAL_BAR_CAP * SPECIAL_ROW_H + 6)
    applyBackdrop(listBox, 1, C.panelDeep, C.tabBorder)

    local function createRow(index)
        local row = CreateFrame("Button", nil, listBox)
        row:SetHeight(SPECIAL_ROW_H)
        row:SetPoint("TOPLEFT", listBox, "TOPLEFT", 3, -3 - (index - 1) * SPECIAL_ROW_H)
        row:SetPoint("RIGHT", listBox, "RIGHT", -3, 0)
        row:Hide()

        local stripe = row:CreateTexture(nil, "BACKGROUND")
        stripe:SetAllPoints(row)
        stripe:SetTexture("Interface\\Buttons\\WHITE8x8")
        row.stripe = stripe

        -- Switches the frame off without taking it apart: the entries ticked onto
        -- it stay where they are and simply stop being drawn, so a frame you keep
        -- for one fight can be parked rather than rebuilt.
        row.enable = createCheckbox(row, "", 16,
            "Draws this frame. Unticked, what is on it stays on it and shows nowhere.")
        row.enable:SetPoint("LEFT", 4, 0)
        row.enable.OnChange = function(_, checked)
            local bar = Data.SpecialBar(unitKey, row.id)
            if not bar then return end
            bar.enabled = checked
            apply()
        end

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.name:SetPoint("LEFT", 26, 0)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)

        row.count = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.count:SetJustifyH("RIGHT")
        UI.tint(row.count, C.textDim)

        row.remove = flatButton(row, "X", AURA_REMOVE_W, 16, "GameFontNormalSmall")
        row.remove:SetPoint("RIGHT", -4, 0)
        UI.tint(row.remove.label, C.red)
        row.remove:SetScript("OnClick", function()
            if not row.id then return end
            Data.RemoveSpecialBar(unitKey, row.id)
            -- Falls onto whatever is left rather than onto nothing: deleting the
            -- third of three frames is not a decision to stop editing.
            local first = Data.SpecialBars(unitKey)[1]
            opts.select(first and first.id or nil)
            apply()
        end)

        -- The count sits between the two, and the name truncates against it: a
        -- long name is still recognisable clipped, and "how many are on it" is
        -- one word that has to be readable in full.
        row.count:SetPoint("RIGHT", row.remove, "LEFT", -6, 0)
        row.name:SetPoint("RIGHT", row.count, "LEFT", -6, 0)

        row:SetScript("OnClick", function() opts.select(row.id) end)

        rows[index] = row
        return row
    end

    -- One line, and only because this page cannot answer the question it raises:
    -- everything here makes a frame and places it, and nothing here puts anything
    -- ON one. Without a pointer, a frame reading "empty" has no next step.
    local hint = list:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOPLEFT", listBox, "BOTTOMLEFT", 2, -10)
    hint:SetPoint("RIGHT", list, "RIGHT", -2, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText("Auras go on a frame from the Aura Tracking page: every entry there carries a box per frame, and ticking one moves that aura onto it.")
    UI.tint(hint, C.textDim)

    -- How many whitelist entries a frame is holding, across both lists. The one
    -- number that says whether a frame is doing anything, and the reason a frame
    -- drawing nothing on your plates is easy to explain.
    local function boundCount(id)
        local n = 0
        for _, which in ipairs({ "buffs", "debuffs" }) do
            for _, entry in pairs(Data.AuraList(unitKey, which) or {}) do
                if entry.bar == id and entry.enabled ~= false then n = n + 1 end
            end
        end
        return n
    end

    list.Refresh = function()
        local bars = Data.SpecialBars(unitKey)
        for i = 1, Data.SPECIAL_BAR_CAP do
            local bar = bars[i]
            local row = rows[i] or createRow(i)
            if bar then
                row.id = bar.id
                row.enable:SetChecked(bar.enabled ~= false)
                row.name:SetText(bar.name or "")
                UI.tint(row.name, bar.enabled == false and C.textDim or C.textWhite)

                local n = boundCount(bar.id)
                row.count:SetText(n > 0 and tostring(n) or "empty")
                -- The selected row is the one the editor beside this is editing,
                -- so it is lit rather than merely striped.
                local on = (bar.id == opts.selected())
                row.stripe:SetVertexColor(0.14, 0.15, 0.23, on and 0.85 or ((i % 2 == 0) and 0.5 or 0.18))
                row:Show()
            else
                row.id = nil
                row:Hide()
            end
        end

        info:SetText(#bars .. " of " .. Data.SPECIAL_BAR_CAP)
        UI.tint(info, C.textDim)
        addBox:SetShown(#bars < Data.SPECIAL_BAR_CAP)
        addBtn:SetShown(#bars < Data.SPECIAL_BAR_CAP)
    end

    return list
end

-- The editor half: everything about the frame the list has selected. Same run of
-- numbers as an appearance column, plus the two settings only a frame with a side
-- of its own needs — where it hangs, and which way it runs from there.
local function buildSpecialEditor(shell, unitKey, opts)
    local col     = newAuraColumn(shell, "Frame settings")
    local editor  = col.shell
    local refresh = {}

    -- Stands in for "nothing selected" so every accessor below can be written as
    -- though there always is one. Written to only while the controls are hidden,
    -- and thrown away unread.
    local ORPHAN = { borderColor = {} }
    local function b() return Data.SpecialBar(unitKey, opts.selected()) or ORPHAN end

    local empty = editor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    empty:SetPoint("TOPLEFT", col.head, "BOTTOMLEFT", 2, -8)
    empty:SetPoint("RIGHT", editor, "RIGHT", -2, 0)
    empty:SetJustifyH("LEFT")
    empty:SetText("Pick a frame on the left, or add one.")
    UI.tint(empty, C.textDim)

    -- Everything that only means something with a frame selected, hidden as one
    -- rather than a dozen times over.
    local body = CreateFrame("Frame", nil, editor)
    body:SetPoint("TOPLEFT", col.head, "BOTTOMLEFT", 0, -4)
    body:SetPoint("BOTTOMRIGHT", editor, "BOTTOMRIGHT", 0, 0)

    local nameLbl = body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameLbl:SetPoint("TOPLEFT", 2, -4)
    nameLbl:SetText("Name")
    UI.tint(nameLbl, C.textGrey)

    -- The name is what labels this frame's checkbox on every whitelist row, so
    -- it is worth keeping short and worth keeping meaningful.
    --
    -- Committed against the frame the box was FILLED for rather than whatever is
    -- selected when it commits: dropping focus is what commits an edit, and
    -- switching frames is one of the things that drops it — so those two are the
    -- same moment, and reading the selection here would write the name you typed
    -- for one frame onto the next one.
    -- Declared before it is built, because the commit handler below is part of
    -- the call that builds it: written as `local nameBox = textBox(...)` the
    -- closure captures the global, and the first rename indexes nil.
    local nameBox
    nameBox = textBox(body, 150, 20, function(text)
        local id = nameBox.editingID
        if not id then return end
        -- Put back to what was actually stored: blank, over-long and already-taken
        -- names are all refused, and a box still showing a refused name reads as
        -- though it took.
        nameBox.box:SetText(Data.RenameSpecialBar(unitKey, id, text) or "")
        opts.renamed()
        apply()
    end, Data.SPECIAL_NAME_MAX)
    nameBox:SetPoint("LEFT", nameLbl, "RIGHT", 8, 0)

    local function toggle(text, width, get, set, desc)
        local cb = createCheckbox(body, text, width, desc)
        cb.OnChange = function(_, checked) set(checked); apply() end
        refresh[#refresh + 1] = function() cb:SetChecked(get() and true or false) end
        return cb
    end

    local mineCB = toggle("Only mine", 86,
        function() return b().onlyMine end,
        function(v) b().onlyMine = v end,
        "Only auras you applied yourself.")
    mineCB:SetPoint("TOPLEFT", nameLbl, "BOTTOMLEFT", 0, -8)

    local timerCB = toggle("Timer", 64,
        function() return b().showTimer ~= false end,
        function(v) b().showTimer = v end)
    timerCB:SetPoint("LEFT", mineCB, "RIGHT", 4, 0)

    local stackCB = toggle("Stacks", 70,
        function() return b().showStacks ~= false end,
        function(v) b().showStacks = v end)
    stackCB:SetPoint("LEFT", timerCB, "RIGHT", 4, 0)

    local grid = numberGrid(body, refresh)

    -- Placement first, since it's the pair that makes this a special frame
    -- rather than a third row above the bar.
    local anchorLine = grid.line(mineCB, 8)
    grid.label(anchorLine, 0, "Side")
    local anchorDD = createDropdown(anchorLine, 150, SPECIAL_ANCHOR_OPTIONS,
        function() return Data.SpecialAnchor(b().anchor) end,
        function(v) b().anchor = v end, apply, "Side",
        "Which point on the health bar the frame hangs off. The corners are the placements that keep clear of both the aura rows above the bar and the cast bar below it.")
    anchorDD:SetPoint("LEFT", anchorLine, "LEFT", STEP_LBL + 2, 0)
    refresh[#refresh + 1] = anchorDD.Refresh

    local growLine = grid.line(anchorLine)
    grid.label(growLine, 0, "Grow")
    local growDD = createDropdown(growLine, 150, SPECIAL_GROWTH_OPTIONS,
        function() return Data.SpecialGrowth(b().growth) end,
        function(v) b().growth = v end, apply, "Grow",
        "Which way the icons run from that point, and so which way the frame is laid out: a row, or a column. A frame off the left or right of a plate has height to grow into and almost no width, so a column is usually what fits there.")
    growDD:SetPoint("LEFT", growLine, "LEFT", STEP_LBL + 2, 0)
    refresh[#refresh + 1] = growDD.Refresh

    local sizeLine = grid.line(growLine)
    grid.stepper(sizeLine, 0, "Size", 4, 80,
        function() return b().size end, function(v) b().size = v end)
    grid.stepper(sizeLine, STEP_COL2, "Gap", 0, 30,
        function() return b().spacing end, function(v) b().spacing = v end)

    local maxLine = grid.line(sizeLine)
    grid.stepper(maxLine, 0, "Max", 1, 20,
        function() return b().max end, function(v) b().max = v end)
    grid.stepper(maxLine, STEP_COL2, "Text", 6, 24,
        function() return b().timerSize end, function(v) b().timerSize = v end)

    local nudgeLine = grid.line(maxLine)
    grid.stepper(nudgeLine, 0, "Nudge X", -400, 400,
        function() return b().x end, function(v) b().x = v end)
    grid.stepper(nudgeLine, STEP_COL2, "Nudge Y", -400, 400,
        function() return b().y end, function(v) b().y = v end)

    local borderLine = grid.line(nudgeLine)
    grid.stepper(borderLine, 0, "Border", 0, 4,
        function() return b().borderSize end, function(v) b().borderSize = v end)
    local swatchLbl = grid.label(borderLine, STEP_COL2, "Color")
    local borderSwatch = colorSwatch(borderLine,
        function()
            local c = b().borderColor or {}
            return c[1] or 0, c[2] or 0, c[3] or 0
        end,
        function(r, g, b2)
            local t = b()
            t.borderColor = t.borderColor or {}
            t.borderColor[1], t.borderColor[2], t.borderColor[3] = r, g, b2
        end,
        apply, 18)
    borderSwatch:SetPoint("LEFT", swatchLbl, "RIGHT", 2, 0)
    refresh[#refresh + 1] = borderSwatch.Refresh

    -- A commit re-enters this through opts.renamed(), and the pass already
    -- running is about to sync everything anyway.
    local syncing = false

    editor.Refresh = function()
        if syncing then return end
        syncing = true

        -- First, so a half-typed name lands on the frame it was typed for while
        -- editingID still names it — see the box itself.
        nameBox.box:ClearFocus()

        local bar = Data.SpecialBar(unitKey, opts.selected())
        col.head:SetText(bar and (bar.name or "Frame settings") or "Frame settings")
        empty:SetShown(not bar)
        body:SetShown(bar and true or false)

        nameBox.editingID = bar and bar.id or nil
        nameBox.box:SetText(bar and (bar.name or "") or "")
        for _, fn in ipairs(refresh) do fn() end

        syncing = false
    end

    return editor
end

local function buildSpecialPage(parent, def)
    local shell = CreateFrame("Frame", nil, parent)
    shell:SetAllPoints()
    shell:Hide()

    -- Which frame the editor is showing. Per unit type, since the two tabs have
    -- their own frames — a remembered id from the other one names nothing here.
    local selected

    local listCol, editorCol
    local function refreshBoth()
        if listCol then listCol.Refresh() end
        if editorCol then editorCol.Refresh() end
    end

    local opts = {
        selected = function() return selected end,
        select = function(id)
            selected = id
            refreshBoth()
        end,
        -- A rename changes the list's labels and this page's heading, but nothing
        -- about what is selected.
        renamed = refreshBoth,
    }

    listCol   = buildSpecialList(shell, def.key, opts)
    editorCol = buildSpecialEditor(shell, def.key, opts)

    listCol:SetPoint("TOPLEFT", shell, "TOPLEFT", 10, -8)
    listCol:SetPoint("BOTTOMRIGHT", shell, "BOTTOM", -7, 8)
    editorCol:SetPoint("TOPLEFT", listCol, "TOPRIGHT", 14, 0)
    editorCol:SetPoint("BOTTOMRIGHT", shell, "BOTTOMRIGHT", -10, 8)

    local divider = shell:CreateTexture(nil, "ARTWORK")
    divider:SetTexture("Interface\\Buttons\\WHITE8x8")
    UI.tintTexture(divider, C.tabBorder)
    divider:SetPoint("TOPLEFT", listCol, "TOPRIGHT", 6, 0)
    divider:SetPoint("BOTTOMRIGHT", listCol, "BOTTOMRIGHT", 7, 0)

    shell:HookScript("OnShow", function()
        -- Falls onto the first frame rather than nothing: there is one to start
        -- with, and a page that opens on an empty editor looks broken.
        if not Data.SpecialBar(def.key, selected) then
            local first = Data.SpecialBars(def.key)[1]
            selected = first and first.id or nil
        end
        refreshBoth()
    end)

    return shell
end

-- ── Tracking column ──────────────────────────────────────────────────────────
-- The whitelist itself: what to add, what is on it, and what each entry matches.
-- With the look settings on their own page this gets the whole column height
-- below its two-line toolbar, which is the difference between a list you can
-- read and one you scroll three rows at a time.
local function buildAuraTrackColumn(parent, unitKey, which, label)
    local col     = newAuraColumn(parent, label)
    local shell   = col.shell

    local filter  = ""
    local list    = {}
    local rows    = {}
    -- The group headings, pooled separately from the aura rows: the two are
    -- different shapes, and one pool of rows that could be either would be a row
    -- carrying both sets of widgets with half of them hidden.
    local heads   = {}
    local cols    = auraLayout(280)
    -- Forward-declared: the toolbar is built before the list it acts on, so its
    -- buttons close over these names before there is anything to bind them to.
    local rebuild, syncRows, scrollToGroup
    -- The group whose name box should take focus on the next bind — set when one
    -- is made, since which row it lands on isn't known until the list is rebuilt.
    local focusGroup

    -- ── Special frame checkboxes ─────────────────────────────────────────────
    -- One box per special buff frame, under each entry: tick it and that aura is
    -- drawn on that frame instead of in this row. One at a time, so ticking a
    -- second box moves the aura rather than copying it — an aura is somewhere,
    -- and "instead" is what the frames are for.
    --
    -- The boxes are laid out once per rebuild rather than once per row: every row
    -- carries the same set, so the positions are worked out on a plan the rows
    -- then apply. That plan is also what makes the list's fixed row height still
    -- true — every row is the same amount taller, so the virtualised list can go
    -- on multiplying an index by a constant.
    local barPlan = {}
    local rowH    = AURA_ROW_H
    -- Bumped whenever the plan changes, so a recycled row knows to re-anchor its
    -- boxes rather than trusting the ones it was left with.
    local planStamp = 0

    -- Names are the user's, so their width is measured rather than guessed.
    local ruler = shell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ruler:Hide()

    -- Filled in place and compared as it goes, so a rebuild that finds the frames
    -- exactly as it left them doesn't bump the stamp — and the rows on screen
    -- don't re-anchor a set of boxes that hasn't moved. Every rebuild comes
    -- through here (see the call site for why), so this is the common case.
    local function planBarChecks()
        local bars = Data.SpecialBars(unitKey)
        -- Indented to the spell name, not to the row's edge: the boxes belong to
        -- the aura above them, and lining them up under its name says so.
        local left    = cols.name
        local avail   = math.max(80, cols.width - left - 4)
        local changed = false

        local n, x, line = 0, 0, 0
        for _, bar in ipairs(bars) do
            local name = bar.name or ""
            ruler:SetText(name)
            local w = BAR_CHECK_BOX + 6 + math.ceil(ruler:GetStringWidth() or 0) + 2
            -- Wrapped rather than clipped: five frames with names of any length
            -- won't fit on one line of a half-width column, and a box whose label
            -- is cut off names nothing.
            if x > 0 and x + w > avail then
                line = line + 1
                x = 0
            end

            n = n + 1
            local p = barPlan[n]
            if not p then
                p = {}
                barPlan[n] = p
            end
            if p.id ~= bar.id or p.name ~= name or p.x ~= left + x
               or p.line ~= line or p.w ~= w then
                p.id, p.name, p.x, p.line, p.w = bar.id, name, left + x, line, w
                changed = true
            end

            x = x + w + BAR_CHECK_GAP
        end

        for i = #barPlan, n + 1, -1 do
            barPlan[i] = nil
            changed = true
        end

        rowH = AURA_ROW_H + ((n > 0) and (line + 1) or 0) * BAR_CHECK_H
        if changed then planStamp = planStamp + 1 end
    end

    -- ── Whitelist toolbar ────────────────────────────────────────────────────
    -- The count on its own line above the boxes is what leaves room for search and
    -- add to share the row below: search on the left because it acts on the list
    -- underneath, add on the right because it puts things there.
    --
    -- One line doing two jobs: a failed add has something to say and the column has
    -- no spare row, so the message takes over the count until the next rebuild.
    local info = shell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    info:SetPoint("TOPLEFT", col.head, "BOTTOMLEFT", 2, -6)
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

    -- Makes an empty heading and opens its name for typing, the way a new folder
    -- works everywhere else. Deliberately NOT fed from the box beside it: that box
    -- is where spells go, and a button next to it that sometimes takes what is in
    -- it and sometimes doesn't is worse than one that never does.
    local groupBtn = flatButton(toolRow, "Group", 50, 20, "GameFontNormalSmall")
    groupBtn:SetPoint("RIGHT", 0, 0)
    attachTooltip(groupBtn, "New group", {
        "A heading inside this list, to drag auras under: \"Stuns\", \"CC\", \"Dispel these\".",
        "Organisation, mostly — what is drawn and how is the same whether a whitelist has headings or none.",
        "The exception is the box on the heading itself, which keeps only one aura for the whole group: the longest remaining of them, or the shortest.",
        "Drag an aura by its row onto a heading to put it there, and onto Ungrouped to take it back out.",
    })

    local addBtn = flatButton(toolRow, "Add", 42, 20, "GameFontNormalSmall")
    addBtn:SetPoint("RIGHT", groupBtn, "LEFT", -4, 0)

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
            UI.tint(info, C.red)
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

    groupBtn:SetScript("OnClick", function()
        local group, err = Data.AddAuraGroup(unitKey, which)
        if not group then
            info:SetText(err or "")
            UI.tint(info, C.red)
            return
        end
        -- A search would hide the new one the moment it appeared: it holds
        -- nothing, and an empty group is what a search drops.
        filter = ""
        searchBox.box:SetText("")
        rebuild()
        -- A new group joins the END of the list, which on a long one is past the
        -- bottom of the view — so its heading is never bound and the box nobody
        -- can see is the one about to be told to take the typing.
        scrollToGroup(group.id)

        -- Asked for LAST, and this is the whole reason it is a flag rather than a
        -- call: binding a heading drops focus (it is what commits a rename), and
        -- the scroll above re-binds every row it moves. Anything that syncs the
        -- rows after this point takes the focus away again.
        focusGroup = group.id
        syncRows()
    end)

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
        UI.tint(fs, C.textWhite)
        return fs
    end
    local hOn    = headerLabel("On")
    local hSpell = headerLabel("Spell")
    -- "Matched on" rather than a Spell ID column: which of the two an entry
    -- matches on is the whole difference between it catching every rank of a
    -- spell and only the one you pasted, and at this width there is room for
    -- the answer or the ID but not both. The ID IS the answer when there is one.
    local hMatch = headerLabel("Matched on")
    -- "Override" rather than "Timer" since the duration engine started filling
    -- these in: a blank box is no longer a missing countdown, it is the normal
    -- state. A number here is what you type when the worked-out one is wrong.
    local hTimer = headerLabel("Override")

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
    UI.tint(emptyText, C.textDim)
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

    -- ── Dragging into a group ────────────────────────────────────────────────
    -- Per column, because a drag can only ever end in the list it started in:
    -- the two columns are separate whitelists, and an entry has no meaning in
    -- the other one.
    --
    -- Hit-tested per frame against the rows actually on screen rather than
    -- resolved from cursor coordinates: the list scrolls, and its rows move
    -- under the cursor while the drag is in flight. There are at most a couple
    -- of dozen of them.
    --
    -- `dragKey` is the whitelist key being carried, `dropOn` the group it would
    -- land in — an id, `false` for the ungrouped pile, or nil for nowhere.
    local dragKey, dropOn

    -- Every frame that answers for a group: the headings, and the aura rows
    -- under them (dropping onto a row means the group that row is in, which is
    -- what makes a whole section a target rather than one line of it).
    local function dropTargetAt()
        -- Inside the list first: a row that is only half scrolled into view still
        -- has a full-height rect, and without this the top one would answer for
        -- the cursor sitting on the table header above it.
        if not scroll:IsMouseOver() then return nil end

        for _, head in ipairs(heads) do
            -- The Disabled band is skipped rather than treated as a target: it
            -- carries no group id, so without this a drop on it would read as
            -- `false` and quietly un-group the aura.
            if head:IsShown() and not head.isDivider and head:IsMouseOver() then
                return head.groupID or false
            end
        end
        for _, row in ipairs(rows) do
            if row:IsShown() and row:IsMouseOver() then
                return row.groupID or false
            end
        end
        return nil
    end

    -- The highlight is on the target, not on the cursor: what matters is which
    -- section a drop lands in, and the section is what has to say so.
    local function paintTargets()
        for _, head in ipairs(heads) do
            head.hit:SetShown(dragKey ~= nil and dropOn ~= nil
                and not head.isDivider
                and (head.groupID or false) == dropOn)
        end
        for _, row in ipairs(rows) do
            row.hit:SetShown(dragKey ~= nil and dropOn ~= nil
                and (row.groupID or false) == dropOn)
        end
    end

    local function endDrag(commit)
        if not dragKey then return end
        local key, target = dragKey, dropOn
        dragKey, dropOn = nil, nil

        local ghost = auraDragGhost()
        ghost.tick, ghost.release = nil, nil
        ghost:Hide()
        paintTargets()

        -- A drop on nothing puts it back where it was rather than un-grouping
        -- it: letting go over the toolbar is how a drag is cancelled everywhere
        -- else, and Ungrouped is a target you can aim at.
        if not (commit and target ~= nil) then return end
        Data.SetAuraGroup(unitKey, which, key, target or nil)
        rebuild()
    end

    local function beginDrag(row)
        if not row.key then return end
        GameTooltip:Hide()

        local ghost = auraDragGhost()
        -- The ghost is shared by all four whitelists, so taking it means telling
        -- whoever had it that their drag is over. Nothing should be able to get
        -- here with another one in flight — a drag ends when the button comes up
        -- and a new one needs it pressed again — but the columns cannot see each
        -- other, and this is the one place the invariant can be stated.
        if ghost.release then ghost.release() end
        ghost.release = function() endDrag(false) end

        dragKey = row.key
        dropOn  = nil

        ghost.icon:SetTexture(row.icon:GetTexture() or QUESTION_MARK)
        ghost.text:SetText(row.nameText:GetText() or row.key)
        ghost.tick = function()
            -- The safety net, and the reason a lost OnDragStop can't strand the
            -- ghost on screen: a drag is over when the button is up, whatever
            -- the frame it started on has had happen to it since (recycled by a
            -- scroll, hidden by a rebuild).
            if not IsMouseButtonDown("LeftButton") then
                endDrag(true)
                return
            end
            local target = dropTargetAt()
            if target ~= dropOn then
                dropOn = target
                paintTargets()
            end
        end
        ghost:Show()
        paintTargets()
    end

    -- Both scripts, because either can be the one that fires: OnDragStop is the
    -- normal end, and the ghost's own tick covers the case where the row it
    -- started on was recycled out from under the drag.
    local function makeDraggable(frame, row)
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", function() beginDrag(row) end)
        frame:SetScript("OnDragStop", function() endDrag(true) end)
    end

    -- ── Group headings ───────────────────────────────────────────────────────
    -- A band across the list with a name you can type into, a count, a twisty
    -- and a delete. The ungrouped pile gets the same band with a plain label
    -- instead of the box and no delete — it isn't a group, it's what is left.
    local function createHead(index)
        local head = CreateFrame("Button", nil, content, "BackdropTemplate")
        head:SetHeight(GROUP_ROW_H)
        head:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)  -- re-anchored by syncRows
        applyBackdrop(head, 1, C.panelDark, C.tabBorder)
        head:Hide()

        -- Over the backdrop and under the widgets: it says "this section" and
        -- must not swallow the name box.
        head.hit = head:CreateTexture(nil, "BORDER")
        head.hit:SetAllPoints(head)
        head.hit:SetTexture("Interface\\Buttons\\WHITE8x8")
        head.hit:SetVertexColor(0.95, 0.15, 0.15, 0.30)
        head.hit:Hide()

        head.twisty = flatButton(head, "-", 16, 16, "GameFontNormalSmall")
        head.twisty:SetPoint("LEFT", 3, 0)
        head.twisty:SetScript("OnClick", function()
            if head.isDivider then return end
            Data.ToggleAuraGroup(unitKey, which, head.groupID)
            rebuild()
        end)

        -- What the ungrouped pile gets instead of the box: it has no name to
        -- change, and a box you can type into that throws the typing away is
        -- worse than a label.
        head.label = head:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        head.label:SetPoint("LEFT", head.twisty, "RIGHT", 6, 0)
        head.label:SetJustifyH("LEFT")
        head.label:SetWordWrap(false)
        UI.tint(head.label, C.textGrey)

        -- Committed against the group the box was FILLED for: rows are recycled,
        -- and dropping focus is both what commits an edit and what a rebind does.
        head.nameBox = textBox(head, 120, 16, function(text)
            local id = head.editingID
            if not id then return end
            head.nameBox.box:SetText(Data.RenameAuraGroup(unitKey, which, id, text) or "")
        end, Data.AURA_GROUP_NAME_MAX)
        head.nameBox:SetPoint("LEFT", head.twisty, "RIGHT", 4, 0)
        head.nameBox.box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)

        head.count = head:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        head.count:SetJustifyH("RIGHT")
        UI.tint(head.count, C.textDim)

        head.remove = flatButton(head, "X", AURA_REMOVE_W, 14, "GameFontNormalSmall")
        head.remove:SetPoint("RIGHT", -3, 0)
        UI.tint(head.remove.label, C.red)
        -- Asked about, unlike deleting one aura: a heading is minutes of sorting
        -- rather than one row, and there is no undo. The entries under it are NOT
        -- deleted with it — they go back to Ungrouped — and saying so is most of
        -- what the question is for.
        head.remove:SetScript("OnClick", function()
            local id = head.groupID
            if not id then return end
            head.nameBox.box:ClearFocus()
            local name = head.nameBox.box:GetText() or ""
            UI.showConfirmPopup({
                title       = "Delete group",
                message     = "Delete the heading " .. (name ~= "" and ("\"" .. name .. "\"") or "this group")
                    .. "?\n\nThe auras under it are kept — they go back to Ungrouped.",
                confirmText = "Delete",
                onConfirm   = function()
                    Data.RemoveAuraGroup(unitKey, which, id)
                    rebuild()
                    -- A limited group deleted is icons appearing on the plates
                    -- again, so this reaches further than the list in front of it.
                    apply()
                end,
            })
        end)

        -- ── One icon for the whole group ─────────────────────────────────────
        -- The only thing on this band that reaches a nameplate. Two controls
        -- rather than one because it is two questions: whether the group is
        -- limited at all, and which end of the durations it keeps — and the
        -- second is meaningless until the first is answered, so it only appears
        -- once the box is ticked.
        head.limitMode = flatButton(head, "Longest", 58, 14, "GameFontNormalSmall")
        head.limitMode:SetScript("OnClick", function()
            if not head.groupID then return end
            local now = Data.AuraGroupLimit(head.limitValue)
            Data.SetAuraGroupLimit(unitKey, which, head.groupID,
                now == "shortest" and "longest" or "shortest")
            rebuild()
            apply()
        end)

        -- ── Tracking the group at all ────────────────────────────────────────
        -- Reads its own state rather than saying what it will do: a heading is
        -- either being watched for or it isn't, and a band of buttons all
        -- labelled "Disable" tells you nothing about which of them are.
        head.power = flatButton(head, "On", 32, 14, "GameFontNormalSmall")
        head.power:SetScript("OnClick", function()
            if not head.groupID then return end
            Data.SetAuraGroupEnabled(unitKey, which, head.groupID, head.groupOff and true or false)
            rebuild()
            -- Reaches the plates, not just the list: this is the whole point of
            -- the button.
            apply()
        end)
        attachTooltip(head.power, "Track this group", {
            "Switches the whole heading off. Its auras stop being matched — nothing under it draws on a plate, and nothing under it is recorded from the combat log either.",
            "Nothing is lost: the rows keep their art, their typed durations and their frame assignments, and the group keeps them. It is the switch for a list that matters on raid night and is noise the rest of the week.",
            "A switched-off group drops to the bottom of this list, under Disabled.",
        })

        head.limitCB = createCheckbox(head, "", 16)
        head.limitCB.OnChange = function(_, checked)
            if not head.groupID then return end
            -- "Longest" on the way on: a group of CC is watched to know when the
            -- target is free again, and the one ending last is what answers that.
            Data.SetAuraGroupLimit(unitKey, which, head.groupID, checked and "longest" or nil)
            rebuild()
            apply()
        end
        attachTooltip(head.limitCB, "Only one from this group", {
            "Draws a single icon for the whole heading instead of one per aura: whichever of them has the longest remaining, or the shortest.",
            "What it is for is a group that is really one question asked several ways — twelve hard CCs whitelisted so that whichever lands is shown, of which one is usually all that is on the unit anyway, and a row of duplicates the moment two are.",
            "An aura with no countdown the client will give up (a permanent buff, an unknown duration) only wins where nothing timed is competing.",
            "Whichever survives is drawn wherever that group's auras were going — the row above the health bar, or a special buff frame.",
        })

        -- Right to left across the band, so a long group name is what gives way:
        -- the name is the user's and can be truncated back to something readable,
        -- and every control to its right has a fixed size it needs.
        head.count:SetPoint("RIGHT", head.remove, "LEFT", -6, 0)
        head.limitMode:SetPoint("RIGHT", head.count, "LEFT", -8, 0)
        head.limitCB:SetPoint("RIGHT", head.limitMode, "LEFT", -4, 0)
        head.power:SetPoint("RIGHT", head.limitCB, "LEFT", -6, 0)
        head.nameBox:SetPoint("RIGHT", head.power, "LEFT", -6, 0)
        head.label:SetPoint("RIGHT", head.count, "LEFT", -6, 0)

        -- The whole band toggles, not just the twisty: it is a heading, and
        -- collapsing is the only thing a heading does. The Disabled band is not a
        -- heading and has nothing to fold, hence the guard here and on the twisty.
        head:SetScript("OnClick", function()
            if head.isDivider then return end
            Data.ToggleAuraGroup(unitKey, which, head.groupID)
            rebuild()
        end)

        -- The only place the drag is explained to someone who has found the
        -- headings but not worked out how to fill them.
        head:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.isDivider then
                GameTooltip:AddLine("Disabled", 1, 1, 1)
                GameTooltip:AddLine("Everything below this line is switched off: not drawn on any plate, and not recorded from the combat log either. Nothing about it has been deleted — press On to bring a group back up.",
                    0.75, 0.75, 0.75, true)
                GameTooltip:Show()
                return
            end
            GameTooltip:AddLine(self.groupID and "Group" or "Ungrouped", 1, 1, 1)
            GameTooltip:AddLine("Drag an aura's row onto this band to put it here.",
                0.75, 0.75, 0.75, true)
            GameTooltip:AddLine("Click the band to fold it away. A heading changes nothing about what is drawn — groups are for finding things in a long list — unless you tick the box on it, which keeps only one of them, or switch the whole heading off with the On button.",
                0.75, 0.75, 0.75, true)
            if not self.groupID then
                GameTooltip:AddLine("This is everything that isn't in a group, and where a drag out of one lands.",
                    0.75, 0.75, 0.75, true)
            end
            GameTooltip:Show()
        end)
        head:SetScript("OnLeave", function() GameTooltip:Hide() end)

        heads[index] = head
        return head
    end

    local function bindHead(head, item)
        -- Before groupID moves, for the same reason bindRow drops the timer box
        -- first: dropping focus commits, and that edit belongs to the group the
        -- row is still holding.
        head.nameBox.box:ClearFocus()

        head.groupID   = item.id
        head.editingID = item.id
        head.limitValue = item.limit
        head.isDivider = item.divider and true or false
        head.groupOff  = item.disabled and true or false

        local real = item.id ~= nil
        head.nameBox:SetShown(real)
        head.remove:SetShown(real)
        head.label:SetShown(not real)
        -- Ungrouped is not a group: it is what is left over, it cannot be
        -- deleted, and there is nothing to limit to one of.
        head.limitCB:SetShown(real)
        head.limitCB:SetChecked(item.limit and true or false)
        -- The mode only exists while the limit does, so an unticked group shows
        -- one control rather than one control and a dead word beside it.
        head.limitMode:SetShown(real and item.limit and true or false)
        head.limitMode.label:SetText(item.limit == "shortest" and "Shortest" or "Longest")

        head.power:SetShown(real)
        head.power.label:SetText(head.groupOff and "Off" or "On")
        UI.tint(head.power.label, head.groupOff and C.red or C.textWhite)

        -- The Disabled band: furniture, not a heading. Everything that acts on a
        -- group goes, including the twisty and the count — there is nothing here
        -- to fold and nothing to count, and a control that does nothing is worse
        -- than no control.
        head.twisty:SetShown(not head.isDivider)
        head.count:SetShown(not head.isDivider)

        if real then
            head.nameBox.box:SetText(item.name or "")
        else
            head.label:SetText(item.name or "Ungrouped")
            -- Red, so the one band that is a statement about everything under it
            -- doesn't read as just another section.
            UI.tint(head.label, head.isDivider and C.red or C.textGrey)
        end
        -- No re-anchoring for the divider: the label is pinned to the twisty,
        -- and a hidden frame keeps its geometry — so "Disabled" lines up with the
        -- group names rather than sliding left into the gap it left.

        head.twisty.label:SetText(item.collapsed and "+" or "-")
        head.count:SetText(item.count > 0 and tostring(item.count) or "empty")

        -- Typing straight into a group you have just made, without going to find
        -- the row it landed on.
        if real and focusGroup == item.id then
            focusGroup = nil
            head.nameBox.box:SetFocus()
        end
    end

    -- One of the boxes under an entry. Built here rather than in createRow
    -- because how many there are is a setting, not a fact about the row.
    local function newBarCheck(row, index)
        local cb = createCheckbox(row, "", 16)
        -- A footnote to the entry above it, and sized like one.
        cb.text:SetFontObject("GameFontNormalSmall")

        cb.OnChange = function(self, checked)
            if not row.key then
                self:SetChecked(false)
                return
            end
            Data.SetAuraBar(unitKey, which, row.key, checked and self.barID or nil)
            -- Ticking one unticks the rest: the aura is drawn in exactly one
            -- place, so these are boxes behaving as a set of alternatives rather
            -- than a set of flags. Untick the ticked one to bring it back to the
            -- row above the health bar.
            if checked then
                for _, other in ipairs(row.barChecks) do
                    if other ~= self then other:SetChecked(false) end
                end
            end
            apply()
        end

        -- Written on hover rather than baked in: the label is the frame's name and
        -- the user can rewrite it whenever they like.
        cb:HookScript("OnEnter", function(self)
            if not self.barName then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.barName, 1, 1, 1)
            GameTooltip:AddLine("Draws this aura on the " .. self.barName
                .. " frame instead of in the row above the health bar.",
                0.75, 0.75, 0.75, true)
            GameTooltip:Show()
        end)
        cb:HookScript("OnLeave", function() GameTooltip:Hide() end)

        row.barChecks[index] = cb
        return cb
    end

    local function layoutRow(row)
        if row.laidOutFor == cols.width and row.planStamp == planStamp then return end
        row.laidOutFor = cols.width
        row.planStamp  = planStamp
        row:SetSize(cols.width, rowH)
        for _, part in ipairs({ row.enable, row.icon, row.iconHit, row.nameText,
                                row.matchText, row.timerBox, row.remove }) do
            part:ClearAllPoints()
        end
        -- Against the entry's own band rather than the row, which is taller than
        -- it whenever there are frames to tick — centring on the whole thing
        -- would drop the entry into the middle of its own footnotes.
        row.enable:SetPoint("LEFT", row.main, "LEFT", cols.enable, 0)
        row.icon:SetPoint("LEFT", row.main, "LEFT", cols.icon, 0)
        row.iconHit:SetPoint("LEFT", row.main, "LEFT", cols.icon, 0)
        row.nameText:SetPoint("LEFT", row.main, "LEFT", cols.name, 0)
        row.nameText:SetWidth(cols.nameW)
        row.matchText:SetPoint("LEFT", row.main, "LEFT", cols.match, 0)
        row.timerBox:SetPoint("LEFT", row.main, "LEFT", cols.timer, 0)
        row.remove:SetPoint("LEFT", row.main, "LEFT", cols.remove, 0)

        for i, p in ipairs(barPlan) do
            local cb = row.barChecks[i] or newBarCheck(row, i)
            cb.barID   = p.id
            cb.barName = p.name
            cb.text:SetText(p.name)
            cb:SetSize(p.w, BAR_CHECK_H - 1)
            cb:ClearAllPoints()
            cb:SetPoint("TOPLEFT", row, "TOPLEFT", p.x, -(AURA_ROW_H + p.line * BAR_CHECK_H))
            cb:Show()
        end
        for i = #barPlan + 1, #row.barChecks do
            row.barChecks[i]:Hide()
            row.barChecks[i].barID, row.barChecks[i].barName = nil, nil
        end
    end

    local function createRow(index)
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(cols.width, rowH)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)  -- re-anchored by syncRows

        local stripe = row:CreateTexture(nil, "BACKGROUND")
        stripe:SetAllPoints(row)
        stripe:SetTexture("Interface\\Buttons\\WHITE8x8")
        row.stripe = stripe

        -- What says a row belongs to the heading above it. A bar down the left
        -- edge rather than an indent: every column position on this row is
        -- measured off the panel's live width, and shifting them all sideways to
        -- say one thing about the row is a lot of arithmetic for a hint.
        row.groupBar = row:CreateTexture(nil, "BACKGROUND", nil, 1)
        row.groupBar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
        row.groupBar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
        row.groupBar:SetWidth(2)
        row.groupBar:SetTexture("Interface\\Buttons\\WHITE8x8")
        UI.tintTexture(row.groupBar, C.red)
        row.groupBar:Hide()

        -- The drop highlight, over the stripe and under everything else.
        row.hit = row:CreateTexture(nil, "BORDER")
        row.hit:SetAllPoints(row)
        row.hit:SetTexture("Interface\\Buttons\\WHITE8x8")
        row.hit:SetVertexColor(0.95, 0.15, 0.15, 0.20)
        row.hit:Hide()

        -- Mouse-enabled so the row can be picked up; its widgets are children and
        -- still get the clicks that land on them.
        row:EnableMouse(true)
        makeDraggable(row, row)

        -- The entry's own band, which is one AURA_ROW_H tall whatever the row
        -- underneath it grows to. Everything about the entry hangs off this;
        -- the special frame boxes hang off the row below it.
        row.main = CreateFrame("Frame", nil, row)
        row.main:SetHeight(AURA_ROW_H)
        row.main:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
        row.main:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)

        row.barChecks = {}

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
        -- The icon is the obvious thing to grab, and it is the one part of the
        -- row that has a frame of its own over it — without this, a drag started
        -- on the picture is a drag that doesn't happen.
        makeDraggable(row.iconHit, row)
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
        UI.tint(row.nameText, C.textWhite)

        row.matchText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.matchText:SetWidth(AURA_MATCH_W); row.matchText:SetJustifyH("LEFT")
        UI.tint(row.matchText, C.textGrey)

        -- An override, and empty for almost every entry: the duration engine
        -- works a countdown out for anything in its 1.12 tables, and a real
        -- aura off the unit carries its own. This is the way to force a number
        -- onto the handful neither of them can answer for.
        row.timerBox = textBox(row, AURA_TIMER_W, 18, function(text)
            if not row.key then return end
            local secs = Data.SetAuraDuration(unitKey, which, row.key, text)
            row.timerBox.box:SetText(secs and tostring(secs) or "")
            apply()
        end, 4)
        row.timerBox.box:SetNumeric(true)

        row.remove = flatButton(row, "X", AURA_REMOVE_W, 16, "GameFontNormalSmall")
        UI.tint(row.remove.label, C.red)
        row.remove:SetScript("OnClick", function()
            if not row.key then return end
            Data.RemoveAura(unitKey, which, row.key)
            rebuild()
            apply()
        end)

        rows[index] = row
        return row
    end

    local function bindRow(row, item, stripeIndex)
        -- Before row.key moves, not after. Rows are recycled as you scroll, and
        -- dropping focus is what commits the timer box — so this has to land on
        -- the entry that was being edited, not on the one taking its place.
        row.timerBox.box:ClearFocus()
        layoutRow(row)

        row.key   = item.key
        row.entry = item.entry
        -- What a drop on this row would mean: the group it is already in. Kept on
        -- the row so the hit test is one field read per frame, and so a row that
        -- has scrolled out of the data still answers for what it last showed.
        row.groupID = item.group
        row.groupBar:SetShown(item.group ~= nil)
        row.stripe:SetVertexColor(0.14, 0.15, 0.23, (stripeIndex % 2 == 0) and 0.55 or 0.20)
        row.enable:SetChecked(item.entry.enabled ~= false)

        local name, icon = Data.AuraDisplay(item.entry)
        row.icon:SetTexture(icon or QUESTION_MARK)
        row.nameText:SetText(name ~= "" and name or item.key)
        row.matchText:SetText(item.entry.id and tostring(item.entry.id) or "Name")
        row.timerBox.box:SetText(item.entry.duration and tostring(item.entry.duration) or "")

        -- After layoutRow, which is what has built and labelled these.
        for i, p in ipairs(barPlan) do
            local cb = row.barChecks[i]
            if cb then cb:SetChecked(item.entry.bar == p.id) end
        end
    end

    -- Brings a heading into view, for the one case that needs it: a group just
    -- made, which joins the end of a list that may be longer than the window.
    scrollToGroup = function(id)
        for _, item in ipairs(list) do
            if item.kind == "group" and item.id == id then
                scroll:SetVerticalScroll(math.max(0,
                    math.min(item.y, scroll:GetVerticalScrollRange() or 0)))
                return
            end
        end
    end

    -- The first item whose bottom edge is past the top of the view. Binary
    -- search rather than a division, because the items are no longer all one
    -- height: a heading is shorter than an entry, and an entry is as tall as the
    -- special frame boxes under it make it.
    local function firstVisible(offset)
        local lo, hi, found = 1, #list, #list + 1
        while lo <= hi do
            local mid = math.floor((lo + hi) / 2)
            local item = list[mid]
            if item.y + item.h > offset then
                found = mid
                hi = mid - 1
            else
                lo = mid + 1
            end
        end
        return found
    end

    syncRows = function()
        local offset = scroll:GetVerticalScroll() or 0
        -- One row of slack past the bottom edge, so a partly-scrolled row is
        -- bound rather than blank.
        local last   = offset + (scroll:GetHeight() or 0) + 1

        local nRows, nHeads = 0, 0
        local i = firstVisible(offset)
        while i <= #list do
            local item = list[i]
            if item.y >= last then break end

            if item.kind == "group" then
                nHeads = nHeads + 1
                local head = heads[nHeads] or createHead(nHeads)
                bindHead(head, item)
                head:ClearAllPoints()
                -- The gap belongs to the heading's own height, so the band is
                -- drawn below it and the section above keeps its breathing room.
                head:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(item.y + GROUP_GAP))
                head:SetPoint("RIGHT", content, "RIGHT", 0, 0)
                head:Show()
            else
                nRows = nRows + 1
                local row = rows[nRows] or createRow(nRows)
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -item.y)
                -- The stripe is the item's own, not the pooled row's: banding by
                -- which recycled frame happens to be showing it would repaint
                -- every row as the list scrolls.
                bindRow(row, item, item.stripe or 1)
                row:Show()
            end
            i = i + 1
        end

        for j = nRows + 1, #rows do
            -- Hidden before it's unbound, for the same reason bindRow drops focus
            -- first: hiding the row commits whatever was being typed into its
            -- timer box, and that edit belongs to the entry the row is still
            -- holding.
            rows[j]:Hide()
            rows[j].key, rows[j].entry, rows[j].groupID = nil, nil, nil
        end
        for j = nHeads + 1, #heads do
            heads[j]:Hide()
            heads[j].groupID, heads[j].editingID = nil, nil
            heads[j].isDivider = nil
        end

        -- A drag in flight has just had the rows move under it.
        if dragKey then paintTargets() end
    end

    rebuild = function()
        local usable = (scroll:GetWidth() or 0)
        if usable > 20 and math.abs(usable - cols.width) > 0.5 then
            cols = auraLayout(usable)
            layoutHeader()
            content:SetWidth(usable)
        end

        -- Re-planned on every rebuild, not only on a width change: frames are
        -- added, renamed and deleted on a page of their own, and coming back
        -- here is how you find out. It costs one text measurement per frame.
        planBarChecks()

        list = Data.GroupedAuras(unitKey, which, filter)

        -- Where each item sits and how tall it is, worked out once here so
        -- scrolling is a lookup rather than a sum. Entries alone means no
        -- headings at all, and the list is exactly what it was before groups.
        local y, drawn, headings, held = 0, 0, 0, 0
        for _, item in ipairs(list) do
            item.y = y
            item.h = (item.kind == "group") and (GROUP_ROW_H + GROUP_GAP) or rowH
            if item.kind == "group" then
                headings = headings + 1
                held = held + item.count
            else
                drawn = drawn + 1
                item.stripe = drawn
            end
            y = y + item.h
        end
        content:SetHeight(math.max(y, 1))

        -- What the count line is about is how much of the list you are looking at,
        -- which is a question about the SEARCH and not about which sections happen
        -- to be folded away. So a collapsed group's rows still count — they are
        -- matches, they are just not on screen — and with headings present that
        -- number is the headings' own counts rather than the rows drawn.
        local matched = (headings > 0) and held or drawn

        local total = 0
        for _ in pairs(Data.AuraList(unitKey, which) or {}) do total = total + 1 end
        info:SetText(matched == total
            and (total .. " tracked")
            or (matched .. " of " .. total))
        UI.tint(info, C.textDim)

        emptyText:SetText(total == 0
            and "Nothing tracked yet."
            or "Nothing matches that.")
        -- On the list being empty outright: with headings there is always
        -- something drawn, and each says for itself that it holds nothing.
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

    shell.Refresh = rebuild
    return shell
end

-- ── Library ──────────────────────────────────────────────────────────────────
-- Everything the duration library knows about, browsable, with the same two Add
-- buttons the Seen page carries. The difference between the two pages is where
-- the rows come from: this one is the 1.12 spell tables, so it is complete from
-- the first login and does not need you to have met anything.
--
-- Duration is the column the Seen page cannot offer at all, and it is usually
-- the reason to come here — knowing a debuff runs 18s is what tells you whether
-- it is worth a slot on a nameplate.
local LIB_ROW_H  = 22
local LIB_ICON_W = 18
local LIB_BTN_W  = 118
local LIB_DUR_W  = 54
local LIB_ID_W   = 60
local LIB_TYPE_W = 92
local LIB_GAP    = 10

local function buildLibraryPanel(parent)
    local shell = CreateFrame("Frame", nil, parent)
    shell:SetAllPoints()
    shell:Hide()

    local kind    = "debuffs"
    local filter  = ""
    local list, total = {}, 0
    local rows    = {}
    local cols    = {}
    local rebuild, syncRows

    -- ── Kind selector ────────────────────────────────────────────────────────
    local bar = CreateFrame("Frame", nil, shell)
    bar:SetHeight(22)
    bar:SetPoint("TOPLEFT", 10, -8)
    bar:SetPoint("RIGHT", shell, "RIGHT", -10, 0)

    local kindTabs = {}

    local function selectKind(key)
        kind = key
        for k, tab in pairs(kindTabs) do
            local on = (k == key)
            tab.active = on
            tab:SetBackdropColor(unpack(on and C.tabActive or C.tabIdle))
            tab:SetBackdropBorderColor(unpack(on and C.tabActiveBdr or C.tabBorder))
            tab.text:SetTextColor(unpack(on and C.textWhite or C.textGrey))
        end
        rebuild()
    end

    local prev
    for _, def in ipairs(Data.LIBRARY_KINDS) do
        local tab = createTab(bar, def.label, 76)
        tab:SetHeight(20)
        tab.text:SetFontObject("GameFontNormalSmall")
        if prev then tab:SetPoint("LEFT", prev, "RIGHT", 4, 0) else tab:SetPoint("LEFT", 0, 0) end
        tab:SetScript("OnClick", function() selectKind(def.key) end)
        kindTabs[def.key] = tab
        prev = tab
    end

    local searchBox = textBox(bar, 150, 20, nil, 40)
    searchBox:SetPoint("LEFT", prev, "RIGHT", 14, 0)
    setPlaceholder(searchBox, "name, ID or type")
    attachTooltip(searchBox, "Search", {
        "Matches the spell's name, its ID, and any of the tags in the Type column — so \"cc\" lists every hard crowd control at once, and \"stun\" narrows it to the stuns.",
        "Tags: CC covers Stun, Root, Fear, Incap, Sleep, Charm, Banish and Horror. Silence, Disarm and Slow are searchable on their own but are deliberately NOT under CC — they take one option away from the target rather than all of them.",
        "Dispel schools are here too: Magic, Curse, Poison and Disease.",
        "Creature abilities carry far fewer tags. The 1.12 tables record nothing but a duration for those, so only the ones sharing a diminishing returns bracket with a player spell are labelled.",
    })
    searchBox.box:SetScript("OnTextChanged", function(self)
        filter = self:GetText() or ""
        rebuild()
    end)

    local countText = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countText:SetPoint("LEFT", searchBox, "RIGHT", 12, 0)
    countText:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
    countText:SetJustifyH("LEFT")
    countText:SetWordWrap(false)
    UI.tint(countText, C.textDim)

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
        UI.tint(fs, C.textWhite)
        return fs
    end
    local hSpell = headerLabel("Spell")
    local hType  = headerLabel("Type")
    local hID    = headerLabel("ID")
    local hDur   = headerLabel("Duration")

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
    UI.tint(emptyText, C.textDim)
    emptyText:Hide()

    -- ID and Duration are fixed: both hold a short token, and a share of a wide
    -- window would only pad them. The name takes everything left over.
    local function layout(w)
        cols.icon   = 6
        cols.name   = cols.icon + LIB_ICON_W + 8
        cols.player = w - LIB_BTN_W - 6
        cols.npc    = cols.player - LIB_BTN_W - 6
        cols.dur    = cols.npc - LIB_GAP - LIB_DUR_W
        cols.durW   = LIB_DUR_W
        cols.id     = cols.dur - LIB_GAP - LIB_ID_W
        cols.idW    = LIB_ID_W
        cols.type   = cols.id - LIB_GAP - LIB_TYPE_W
        cols.typeW  = LIB_TYPE_W
        cols.nameW  = math.max(70, cols.type - LIB_GAP - cols.name)
        cols.width  = w
    end
    layout(600)

    local function layoutHeader()
        for _, fs in ipairs({ hSpell, hType, hID, hDur }) do fs:ClearAllPoints() end
        hSpell:SetPoint("LEFT", cols.name + COL_INSET, 0); hSpell:SetWidth(cols.nameW)
        hType:SetPoint("LEFT", cols.type + COL_INSET, 0);  hType:SetWidth(cols.typeW)
        hID:SetPoint("LEFT", cols.id + COL_INSET, 0);      hID:SetWidth(cols.idW)
        hDur:SetPoint("LEFT", cols.dur + COL_INSET, 0);    hDur:SetWidth(cols.durW)
    end

    local function layoutRow(row)
        if row.laidOutFor == cols.width then return end
        row.laidOutFor = cols.width
        row:SetWidth(cols.width)
        for _, part in ipairs({ row.icon, row.iconHit, row.nameText, row.typeText,
                                row.idText, row.durText, row.npcBtn, row.playerBtn }) do
            part:ClearAllPoints()
        end
        row.icon:SetPoint("LEFT", cols.icon, 0)
        row.iconHit:SetPoint("LEFT", cols.icon, 0)
        row.nameText:SetPoint("LEFT", cols.name, 0); row.nameText:SetWidth(cols.nameW)
        row.typeText:SetPoint("LEFT", cols.type, 0); row.typeText:SetWidth(cols.typeW)
        row.idText:SetPoint("LEFT", cols.id, 0);     row.idText:SetWidth(cols.idW)
        row.durText:SetPoint("LEFT", cols.dur, 0);   row.durText:SetWidth(cols.durW)
        row.npcBtn:SetPoint("LEFT", cols.npc, 0)
        row.playerBtn:SetPoint("LEFT", cols.player, 0)
    end

    -- The name normally; the id when something else answers to the same name.
    -- The Library has this collision the other way round from the Seen page: it
    -- lists only the spell the 1.12 tables know, so adding "Shadow Protection"
    -- by name from here would quietly also catch the potion's.
    local function addTokenFor(item)
        local token, byID = Data.AuraAddToken(item.name, nil, item.id)
        return token, (Data.AuraKeyFor(token)), byID
    end

    local function refreshAddButton(btn, unitKey, item, addKey)
        local which = Data.LibraryWhichFor(kind, item.key)
        local l  = Data.AuraList(unitKey, which)
        local on = l and l[addKey] ~= nil
        btn.label:SetText(on and "On list" or btn.addLabel)
        btn.label:SetTextColor(unpack(on and C.textDim or C.textWhite))
        if on then btn:Disable() else btn:Enable() end
    end

    local function createRow(index)
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(cols.width, LIB_ROW_H)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)  -- re-anchored by syncRows

        local stripe = row:CreateTexture(nil, "BACKGROUND")
        stripe:SetAllPoints(row)
        stripe:SetTexture("Interface\\Buttons\\WHITE8x8")
        row.stripe = stripe

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(LIB_ICON_W, LIB_ICON_W)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        row.iconHit = CreateFrame("Frame", nil, row)
        row.iconHit:SetSize(LIB_ICON_W, LIB_ICON_W)
        row.iconHit:EnableMouse(true)
        row.iconHit:SetScript("OnEnter", function(self)
            local item = row.item
            if not item then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(item.name, 1, 1, 1)
            GameTooltip:AddLine("Spell ID " .. item.id, 0.75, 0.75, 0.75)
            if item.labelText ~= "" then
                GameTooltip:AddLine(item.labelText, 0.55, 0.75, 1)
            end

            local seconds, varies, permanent = addon.Durations
                and addon.Durations.DescribeDuration(item.id)
            GameTooltip:AddLine(" ")
            if permanent then
                GameTooltip:AddLine("Lasts until it is removed — no countdown is drawn for it.",
                    0.75, 0.75, 0.75, true)
            elseif not seconds then
                GameTooltip:AddLine("The library has no duration for this one. Its icon will show with no countdown unless you fill in an Override on the whitelist.",
                    0.75, 0.75, 0.75, true)
            elseif varies then
                GameTooltip:AddLine(("About %gs. This one varies with rank, talents or combo points, so the real number depends on who cast it — the addon works the exact one out from the combat log when it lands."):format(seconds),
                    0.75, 0.75, 0.75, true)
            else
                GameTooltip:AddLine(("Lasts %gs."):format(seconds), 0.75, 0.75, 0.75, true)
            end

            local which = Data.LibraryWhichFor(kind, item.key)
            GameTooltip:AddLine(" ")
            if row.addByID then
                GameTooltip:AddLine(("Adds to the %s list as ID %d, not by name — something else in the game answers to this name too, and a name-matched entry would catch both."):format(
                    which == "buffs" and "buff" or "debuff", item.id), 1, 0.82, 0, true)
            else
                GameTooltip:AddLine(("Adds to the %s list, by NAME — so it catches every rank."):format(
                    which == "buffs" and "buff" or "debuff"), 0.75, 0.75, 0.75, true)
            end
            GameTooltip:Show()
        end)
        row.iconHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

        row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.nameText:SetJustifyH("LEFT")
        row.nameText:SetWordWrap(false)
        UI.tint(row.nameText, C.textWhite)

        -- Tinted like a heading rather than like the grey data columns: the tags
        -- are how you find a row, so they should catch the eye while scanning a
        -- filtered list for the one you meant.
        row.typeText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.typeText:SetJustifyH("LEFT")
        row.typeText:SetWordWrap(false)
        UI.tint(row.typeText, C.textWhite)

        row.idText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.idText:SetJustifyH("LEFT")
        row.idText:SetWordWrap(false)
        UI.tint(row.idText, C.textGrey)

        row.durText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.durText:SetJustifyH("LEFT")
        row.durText:SetWordWrap(false)
        UI.tint(row.durText, C.textGrey)

        local function addButton(unitKey, label)
            local btn = flatButton(row, label, LIB_BTN_W, 16, "GameFontNormalSmall")
            btn.addLabel = label
            btn:SetScript("OnClick", function(self)
                local item = row.item
                if not item then return end
                Data.AddAura(unitKey, Data.LibraryWhichFor(kind, item.key),
                    row.addToken or item.name)
                refreshAddButton(self, unitKey, item, row.addKey)
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
        row.item = item
        row.stripe:SetVertexColor(0.14, 0.15, 0.23, (dataIndex % 2 == 0) and 0.55 or 0.20)

        row.icon:SetTexture(item.icon or QUESTION_MARK)
        row.nameText:SetText(item.name)
        row.typeText:SetText(item.labelText ~= "" and item.labelText or "—")
        row.idText:SetText(tostring(item.id))
        row.durText:SetText(item.durText or "—")

        row.addToken, row.addKey, row.addByID = addTokenFor(item)
        refreshAddButton(row.npcBtn,    "enemyNPC",    item, row.addKey)
        refreshAddButton(row.playerBtn, "enemyPlayer", item, row.addKey)
    end

    syncRows = function()
        local offset  = scroll:GetVerticalScroll() or 0
        local first   = math.floor(offset / LIB_ROW_H)
        local visible = math.ceil((scroll:GetHeight() or 0) / LIB_ROW_H) + 2

        for i = 1, visible do
            local row = rows[i] or createRow(i)
            local dataIndex = first + i
            local item = list[dataIndex]
            if item then
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -((dataIndex - 1) * LIB_ROW_H))
                bindRow(row, item, dataIndex)
                row:Show()
            else
                row.item = nil
                row:Hide()
            end
        end
        for i = visible + 1, #rows do
            rows[i].item = nil
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

        list, total = Data.LibraryRows(kind, filter)
        content:SetHeight(math.max(#list * LIB_ROW_H, 1))

        countText:SetText(#list == total
            and (total .. " spells")
            or (#list .. " of " .. total .. " spells"))

        emptyText:SetText(total == 0
            and "The duration library did not load, so there is nothing to list here."
            or "Nothing matches that.")
        emptyText:SetShown(#list == 0)
        syncRows()
        updateTrack()
    end

    scroll:HookScript("OnVerticalScroll", syncRows)
    scroll:HookScript("OnSizeChanged", function() rebuild() end)

    layoutHeader()

    shell:HookScript("OnShow", function()
        selectKind(kind)
        C_Timer.After(0, rebuild)
    end)

    return shell
end

-- ── Learned ──────────────────────────────────────────────────────────────────
-- The catalogue, and the way into the four whitelists from it. Everything else
-- here asks you to already know what you want to track; this is the page for
-- when you don't, because the thing you're after has a name you can't spell and
-- an ID you can't look up.
--
-- Full panel width rather than split like the unit tabs: one list, not two, and
-- the four Add buttons a row carries need the room.
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
        "Collapsed by spell name, so eight ranks of the same shout are one row. Hover a row's icon to see every ID it has been seen as and everything it has been seen on.",
        "Players are recorded as just \"Player\" — which one was wearing it is never the question. NPCs are recorded by name, up to " .. Data.LEARNED_SOURCE_CAP .. " of them per spell.",
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
    setPlaceholder(searchBox, "search name, ID or source")
    searchBox.box:SetScript("OnTextChanged", function(self)
        filter = self:GetText() or ""
        rebuild()
    end)

    local countText = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countText:SetPoint("LEFT", searchBox, "RIGHT", 12, 0)
    countText:SetPoint("RIGHT", clearBtn, "LEFT", -10, 0)
    countText:SetJustifyH("LEFT")
    countText:SetWordWrap(false)
    UI.tint(countText, C.textDim)

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
        UI.tint(fs, C.textWhite)
        return fs
    end
    local hSpell = headerLabel("Spell")
    local hFrom  = headerLabel("Learned from")
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
    UI.tint(emptyText, C.textDim)
    emptyText:Hide()

    -- Measured off the live width, same as the whitelist columns. "Seen as" is the
    -- only fixed one: it holds an ID and maybe a "+2", so a share of a wide window
    -- would only pad a short number. Spell and Learned from split what's left evenly
    -- — either can be the long one.
    local LEARN_IDS_W = 72
    local LEARN_GAP   = 10

    local function layout(w)
        cols.icon   = 6
        cols.name   = cols.icon + LEARN_ICON_W + 8
        cols.player = w - LEARN_BTN_W - 6
        cols.npc    = cols.player - LEARN_BTN_W - 6
        cols.ids    = cols.npc - LEARN_GAP - LEARN_IDS_W
        cols.idsW   = LEARN_IDS_W

        local text  = cols.ids - LEARN_GAP - cols.name
        cols.nameW  = math.max(70, math.floor((text - LEARN_GAP) / 2))
        cols.from   = cols.name + cols.nameW + LEARN_GAP
        cols.fromW  = math.max(60, cols.ids - LEARN_GAP - cols.from)
        cols.width  = w
    end
    layout(600)

    local function layoutHeader()
        for _, fs in ipairs({ hSpell, hFrom, hIDs }) do fs:ClearAllPoints() end
        hSpell:SetPoint("LEFT", cols.name + COL_INSET, 0); hSpell:SetWidth(cols.nameW)
        hFrom:SetPoint("LEFT", cols.from + COL_INSET, 0);  hFrom:SetWidth(cols.fromW)
        hIDs:SetPoint("LEFT", cols.ids + COL_INSET, 0);    hIDs:SetWidth(cols.idsW)
    end

    local function layoutRow(row)
        if row.laidOutFor == cols.width then return end
        row.laidOutFor = cols.width
        row:SetWidth(cols.width)
        for _, part in ipairs({ row.icon, row.iconHit, row.nameText, row.fromText,
                                row.idText, row.npcBtn, row.playerBtn }) do
            part:ClearAllPoints()
        end
        row.icon:SetPoint("LEFT", cols.icon, 0)
        row.iconHit:SetPoint("LEFT", cols.icon, 0)
        row.nameText:SetPoint("LEFT", cols.name, 0); row.nameText:SetWidth(cols.nameW)
        row.fromText:SetPoint("LEFT", cols.from, 0); row.fromText:SetWidth(cols.fromW)
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

    -- What this row would add, and under what key. Normally the name, so the
    -- entry catches every rank; the id instead when the name turns out to be
    -- shared by two different spells — see Data.AuraAddToken.
    local function addTokenFor(rec, fallbackKey)
        if not rec then return fallbackKey, fallbackKey, false end
        local ids = Data.LearnedIDs(rec)
        local token, byID = Data.AuraAddToken(rec.name or fallbackKey, rec.ids, ids[1])
        return token, (Data.AuraKeyFor(token)), byID
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
            local from = Data.LearnedSources(rec)
            if #from > 0 then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Seen on:", 1, 1, 1)
                for _, source in ipairs(from) do
                    GameTooltip:AddLine(source, 0.75, 0.75, 0.75)
                end
                if (rec.npcN or 0) >= Data.LEARNED_SOURCE_CAP then
                    GameTooltip:AddLine("(stopped naming NPCs after " .. Data.LEARNED_SOURCE_CAP .. ")",
                        0.5, 0.5, 0.5, true)
                end
            end

            local ids = Data.LearnedIDs(rec)
            if #ids > 0 then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Seen as:", 1, 1, 1)
                for _, id in ipairs(ids) do
                    GameTooltip:AddLine(tostring(id), 0.75, 0.75, 0.75)
                end
            end
            GameTooltip:AddLine(" ")
            if row.addByID then
                GameTooltip:AddLine(("More than one spell answers to this name, so adding it puts ID %s on the list rather than the name — otherwise the entry would catch the other one too, and resolve to whichever the client looks the name up to."):format(tostring(row.addToken)),
                    1, 0.82, 0, true)
            else
                GameTooltip:AddLine("Adding puts it on the list by NAME, so it catches every rank above. Type one of these IDs into that list by hand instead if you want only that one.",
                    0.75, 0.75, 0.75, true)
            end
            GameTooltip:Show()
        end)
        row.iconHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

        row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.nameText:SetJustifyH("LEFT")
        UI.tint(row.nameText, C.textWhite)

        row.fromText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.fromText:SetJustifyH("LEFT")
        row.fromText:SetWordWrap(false)
        UI.tint(row.fromText, C.textGrey)

        row.idText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.idText:SetJustifyH("LEFT")
        row.idText:SetWordWrap(false)
        UI.tint(row.idText, C.textGrey)

        local function addButton(unitKey, label)
            local btn = flatButton(row, label, LEARN_BTN_W, 16, "GameFontNormalSmall")
            btn.addLabel = label
            btn:SetScript("OnClick", function(self)
                if not row.key then return end
                -- By name, so the entry catches every rank under it — which is
                -- what picking this row means. The exception is a name two
                -- different spells answer to, where the name cannot say which
                -- you meant and the id goes on instead.
                Data.AddAura(unitKey, which, row.addToken or row.key)
                refreshAddButton(self, unitKey, row.addKey or row.key)
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

        -- First plus a count, not the whole list: the column is one line and the
        -- rest are a hover away on the icon.
        local from = Data.LearnedSources(item.rec)
        if #from == 0 then
            row.fromText:SetText("—")
        elseif #from == 1 then
            row.fromText:SetText(from[1])
        else
            row.fromText:SetText(from[1] .. "  +" .. (#from - 1))
        end

        row.addToken, row.addKey, row.addByID = addTokenFor(item.rec, item.key)
        refreshAddButton(row.npcBtn,    "enemyNPC",    row.addKey)
        refreshAddButton(row.playerBtn, "enemyPlayer", row.addKey)
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

-- ── Spells ───────────────────────────────────────────────────────────────────
-- The two ways of finding out what there is to track, under one tab.
--
-- Library is the duration library's own roster: complete from the first login,
-- and the only one of the two that can tell you how long anything lasts. Seen
-- is what this install has actually watched land — the only one that knows who
-- wears what, and the only one that reaches spells the 1.12 tables never had.
--
-- Both end in the same two Add buttons, so which page you found something on
-- makes no difference to where it goes.
local function buildSpellsPanel(parent)
    local panel, _, _, addSubTab = makeSubTabPanel(parent, { barHeight = 22, hidden = true })
    addSubTab("library", "Library", 90, buildLibraryPanel)
    addSubTab("seen",    "Seen",    76, buildLearnedPanel)
    selectSubTab(panel, "library")
    return panel
end

-- What the events switch is for. The one-liner sits under the checkbox because
-- that setting is off by default on NPCs and on by default on players, and a
-- switch whose default flips between tabs has to say why somewhere you can't
-- miss. The rest is a hover away: it's the reasoning, and reasoning costs rows
-- that the two lists below need more.
local AURA_EVENTS_TITLE = "Work missing auras out from events"

local AURA_EVENTS_HELP = {
    enemyPlayer = {
        tip = {
            "Classic Era never reports a hostile player's buffs — without this they cannot show at all.",
            "The aura API answers for your target, your mouseover and your group. For anyone else it reports nothing, so a whitelisted buff on an enemy player can never appear however it is spelled.",
            "With this on, the module watches their cast land and reads the combat log's own aura lines instead.",
            "That makes it a record of what was last seen to happen rather than a reading of the unit: it can miss an aura applied before the plate came into view, or one that ran out while they were away from you. A real aura always wins where there is one.",
            "Neither source carries a duration, so the countdown is worked out from the addon's own table of 1.12 durations. Where that has nothing to say — an unlisted spell, or a server that changed one — fill in Override against the spell to force a number.",
        },
    },
    enemyNPC = {
        tip = {
            "Rarely needed here — an NPC's debuffs read off the unit properly.",
            "Debuffs you have applied to an NPC come back off the unit correctly, so working them out from events would only be a worse copy of what is already right.",
            "Worth turning on for buffs an NPC gives itself, which the client is no more forthcoming about than it is for players.",
            "Neither source carries a duration, so the countdown is worked out from the addon's own table of 1.12 durations — which covers creature abilities as well as player ones. Fill in Override against a spell it has nothing for.",
        },
    },
}

-- ── One unit type ────────────────────────────────────────────────────────────
-- Two pages of two columns. Debuffs on the left of both because that's the row
-- nearest the health bar by default, so the page reads bottom-up the way the
-- plate does.
--
-- Split into pages because the halves are used at completely different times:
-- the look settings are a wall of numbers you set once, the whitelist is a list
-- you return to whenever you meet something new. Sharing one column meant the
-- list — the part that needs the height — got whatever ten rows of steppers left.
local function splitAuraColumns(shell, def, buildColumn, below)
    local left  = buildColumn(shell, def.key, "debuffs", "Debuffs")
    local right = buildColumn(shell, def.key, "buffs",   "Buffs")

    if below then
        left:SetPoint("TOPLEFT", below, "BOTTOMLEFT", 0, -10)
    else
        left:SetPoint("TOPLEFT", shell, "TOPLEFT", 10, -8)
    end
    left:SetPoint("BOTTOMRIGHT", shell, "BOTTOM", -7, 8)
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", 14, 0)
    right:SetPoint("BOTTOMRIGHT", shell, "BOTTOMRIGHT", -10, 8)

    local divider = shell:CreateTexture(nil, "ARTWORK")
    divider:SetTexture("Interface\\Buttons\\WHITE8x8")
    UI.tintTexture(divider, C.tabBorder)
    divider:SetPoint("TOPLEFT", left, "TOPRIGHT", 6, 0)
    divider:SetPoint("BOTTOMRIGHT", left, "BOTTOMRIGHT", 7, 0)

    return left, right
end

-- The events switch heads this page rather than the other one because it is a
-- tracking setting: it decides what gets FOUND, not what the icons look like.
local function buildAuraTrackingPage(parent, def)
    local shell = CreateFrame("Frame", nil, parent)
    shell:SetAllPoints()
    shell:Hide()

    local function u() return auraUnit(def.key) end
    local help = AURA_EVENTS_HELP[def.key] or AURA_EVENTS_HELP.enemyNPC

    local eventsCB = createCheckbox(shell, "Work missing auras out from cast and combat log events", 400)
    eventsCB:SetPoint("TOPLEFT", 10, -8)
    eventsCB.OnChange = function(_, checked) u().fromEvents = checked; apply() end
    -- The one-line "is this worth turning on here" verdict leads the tooltip, so
    -- the answer is the first thing read rather than the last.
    attachTooltip(eventsCB, AURA_EVENTS_TITLE, help.tip)

    local left, right = splitAuraColumns(shell, def, buildAuraTrackColumn, eventsCB)

    -- ── Clear ────────────────────────────────────────────────────────────────
    -- Right-aligned on the events row, as far from the Add buttons under them as
    -- the page allows. Both lists ship filled — see NameplateSeed.lua — so the
    -- one thing somebody who wants to build their own from nothing needs is a way
    -- out of sixty entries that isn't sixty clicks on X.
    --
    -- Each button is over the column it empties: Buffs on the right, Debuffs on
    -- its left, matching the columns underneath.
    local function clearButton(label, which, column)
        local btn = flatButton(shell, label, 112, 20, "GameFontNormalSmall")
        btn:SetScript("OnClick", function()
            local total = 0
            for _ in pairs(Data.AuraList(def.key, which) or {}) do total = total + 1 end
            UI.showConfirmPopup({
                title       = label,
                message     = "Remove all " .. total .. " tracked "
                    .. which .. " for " .. (def.label or "this unit type")
                    .. ", and the groups they are sorted into?"
                    .. "\n\nThe special buff frames themselves are kept."
                    .. "\n\nThis cannot be undone.",
                confirmText = "Clear",
                onConfirm   = function()
                    Data.ClearAuraList(def.key, which)
                    column.Refresh()
                    apply()
                end,
            })
        end)
        return btn
    end

    local clearBuffs   = clearButton("Clear All Buffs",   "buffs",   right)
    local clearDebuffs = clearButton("Clear All Debuffs", "debuffs", left)

    -- ── Restore ──────────────────────────────────────────────────────────────
    -- The way back from the two beside it, and from any amount of drift. One
    -- button for both lists rather than one each: the shipped headings and frame
    -- assignments span the pair — the CC frame takes debuffs and Stance takes
    -- buffs — so half a restore would be a setup that never shipped. It also
    -- keeps the row to three buttons, which is what fits at the minimum width.
    local restoreBtn = flatButton(shell, "Restore Defaults", 112, 20, "GameFontNormalSmall")
    restoreBtn:SetScript("OnClick", function()
        UI.showConfirmPopup({
            title       = "Restore default auras",
            message     = "Put the buff and debuff lists for "
                .. (def.label or "this unit type")
                .. " back to the ones the addon ships with?"
                .. "\n\nThis REPLACES both lists and their groups — anything you added"
                .. " or moved is lost. Special buff frames are left where they are,"
                .. " and any the defaults need but you have deleted come back."
                .. "\n\nThis cannot be undone.",
            confirmText = "Restore",
            onConfirm   = function()
                Data.RestoreAuraDefaults(def.key)
                left.Refresh()
                right.Refresh()
                apply()
            end,
        })
    end)

    -- Left of the pair, not among them: the two Clears read as a set and this is
    -- the opposite of what they do.
    --
    -- All three off the shell rather than off the checkbox beside them: the label
    -- below is anchored to these, and anchoring these back to it would be a
    -- circle for the layout engine to complain about.
    clearBuffs:SetPoint("TOPRIGHT", shell, "TOPRIGHT", -10, -8)
    clearDebuffs:SetPoint("RIGHT", clearBuffs, "LEFT", -6, 0)
    restoreBtn:SetPoint("RIGHT", clearDebuffs, "LEFT", -6, 0)

    -- The label stops where the buttons start rather than running under them at
    -- the minimum window width: it is a whole sentence and these three take 350px
    -- off the row. Truncated rather than wrapped, since a second line would push
    -- into the lists below.
    eventsCB.text:SetPoint("RIGHT", restoreBtn, "LEFT", -10, 0)
    eventsCB.text:SetJustifyH("LEFT")
    eventsCB.text:SetWordWrap(false)

    shell:HookScript("OnShow", function()
        eventsCB:SetChecked(u().fromEvents and true or false)
        left.Refresh()
        right.Refresh()
        -- Neither column's geometry is final on the frame it is first shown, so
        -- the lists don't yet know how tall they are. Same deferred re-fit the
        -- NPC list and makeScrollPanel both use.
        C_Timer.After(0, function()
            left.Refresh()
            right.Refresh()
        end)
    end)

    return shell
end

local function buildAuraLookPage(parent, def)
    local shell = CreateFrame("Frame", nil, parent)
    shell:SetAllPoints()
    shell:Hide()

    -- Heads this page rather than the tracking one because it changes where the
    -- icons GO, not what gets found — and it spans the pair, so it belongs above
    -- both columns rather than inside either.
    local function u() return auraUnit(def.key) end

    local combineCB = createCheckbox(shell, "Put buffs and debuffs on one row", 400)
    combineCB:SetPoint("TOPLEFT", 10, -8)
    combineCB.OnChange = function(_, checked) u().combine = checked; apply() end
    attachTooltip(combineCB, "Put buffs and debuffs on one row", {
        "One strip above the health bar instead of two stacked ones. Debuffs take their places first, so where the cap cuts the row off it is a buff that is dropped rather than the CC you were watching for.",
        "The single row is the DEBUFFS row: everything about how it looks — size, gap, cap, growth, position, borders, countdown — comes from the Debuffs column, and the Buffs column's own look settings stop being used.",
        "What each column still decides for itself is what it TRACKS: its \"Show these above the health bar\" tick and its \"Only mine\". Untick Show on one and the row is simply the other kind.",
        "The Magic border still comes from Buffs and still only marks buffs — a debuff's own school is not what that setting is about.",
        "Special buff frames are unaffected: an aura moved onto one is drawn there either way.",
    })

    local left, right = splitAuraColumns(shell, def, buildAuraLookColumn, combineCB)

    shell:HookScript("OnShow", function()
        combineCB:SetChecked(u().combine and true or false)
        left.Refresh()
        right.Refresh()
    end)

    return shell
end

-- Which of the two pages was last open, remembered across the unit types rather
-- than per tab: switching from Enemy NPCs to Enemy Players is almost always to
-- compare the same thing, and landing back on page one every time would undo
-- the comparison you were making.
local auraSection = "tracking"

local AURA_SECTIONS = {
    { key = "tracking",   label = "Aura Tracking", width = 106, build = buildAuraTrackingPage },
    { key = "appearance", label = "Appearance",    width =  96, build = buildAuraLookPage     },
    -- Last: it is about where a handful of the entries on the first page go, so
    -- it reads as a refinement of that page rather than a third way in.
    { key = "special",    label = "Special Buffs", width = 104, build = buildSpecialPage      },
}

local function buildAuraUnitPanel(parent, def)
    local shell = CreateFrame("Frame", nil, parent)
    shell:SetAllPoints()
    shell:Hide()

    local bar = CreateFrame("Frame", nil, shell, "BackdropTemplate")
    bar:SetHeight(22)
    bar:SetPoint("TOPLEFT", 4, -4)
    bar:SetPoint("RIGHT", shell, "RIGHT", -4, 0)
    applyBackdrop(bar, 1, C.panelDark)

    local content = CreateFrame("Frame", nil, shell)
    content:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -2)
    content:SetPoint("BOTTOMRIGHT", shell, "BOTTOMRIGHT", -4, 2)

    shell.subTabs, shell.subPanels = {}, {}

    local prev
    for _, sec in ipairs(AURA_SECTIONS) do
        local tab = createTab(bar, sec.label, sec.width)
        tab:SetHeight(18)
        tab.text:SetFontObject("GameFontNormalSmall")
        if prev then
            tab:SetPoint("LEFT", prev, "RIGHT", 4, 0)
        else
            tab:SetPoint("LEFT", 4, 0)
        end
        tab:SetScript("OnClick", function()
            auraSection = sec.key
            selectSubTab(shell, sec.key)
        end)
        shell.subTabs[sec.key]   = tab
        shell.subPanels[sec.key] = function() return sec.build(content, def) end
        prev = tab
    end

    shell:HookScript("OnShow", function()
        setAuraPreview(def.key)
        -- Follow whatever the other unit type was last showing. Guarded, or
        -- every show would re-resolve (and therefore build) the page.
        if shell.activeSubTab ~= auraSection then selectSubTab(shell, auraSection) end
    end)

    -- Covers every way out, not just the sub-tab buttons: OnHide also fires when
    -- an ancestor goes — leaving the module's tab, or closing the window — and
    -- those must switch the preview off too. Switching sub-tabs hides the old
    -- panel before showing the new one, so the nil never lands on top of the
    -- other type's preview.
    shell:HookScript("OnHide", function() setAuraPreview(nil) end)

    selectSubTab(shell, auraSection)
    return shell
end

-- ── Boss mods ────────────────────────────────────────────────────────────────
-- The fifth icon strip, and the only one this addon doesn't feed itself. DBM and
-- BigWigs both run a countdown for the mechanic you're waiting on and can say
-- which unit it's about; where they do, the bar becomes an icon on that plate.
--
-- Form-built rather than hand-laid like the aura pages, because it's a run of
-- switches and numbers rather than a list you add to.
local function bossData()
    local t = npData()
    t.bossMods = t.bossMods or {}
    return t.bossMods
end

local function auraGrowthOptions()
    local out = {}
    for _, e in ipairs(Data.AURA_GROWTHS) do
        out[#out + 1] = { value = e.value, label = e.label }
    end
    return out
end

local function bossModsContent(form)
    local function b() return bossData() end

    form:header("Boss mod timers", "A separate strip of icons off the top left corner of the health bar, fed by your boss mod rather than by the game. A timer bar that names the unit it belongs to is drawn on that unit's nameplate — the Four Horsemen's Shield Wall counting down on the horseman it is about, instead of four identical bars you have to read the labels of.")
    form:check("Show boss mod timers on nameplates",
        function() return b().enabled ~= false end,
        function(v) b().enabled = v end, nil,
        "Nothing here works out what a fight is doing — that is entirely your boss mod's job. This only draws the bars it announces, and stays empty when neither is installed.")

    form:header("DBM options", "Deadly Boss Mods reports every timer it starts, and newer builds name the unit the timer belongs to. Only those bars can be placed on a nameplate; a timer about the encounter as a whole has no plate to go on.")
    form:check("Turn DBM timer bars into nameplate icons",
        function() return b().dbm ~= false end,
        function(v) b().dbm = v end)

    form:header("BigWigs options", "BigWigs sends its nameplate bars as their own messages, already carrying the unit they belong to.")
    form:check("Turn BigWigs nameplate bars into icons",
        function() return b().bigwigs ~= false end,
        function(v) b().bigwigs = v end, nil,
        "Ordinary BigWigs bars are not included: those carry no unit, so there is nothing to attach them to. Not every BigWigs build has the nameplate feature — where it is missing this switch simply never has anything to do.")

    form:header("Icons", "Sizing and placement for the strip. It is pinned to the health bar's top left corner, so growing it leftwards runs it out into empty space rather than back over the bar.")
    form:stepper("Icon size", 8, 64,
        function() return b().size end,
        function(v) b().size = v end, "px", 1)
    form:stepper("Spacing", 0, 20,
        function() return b().spacing end,
        function(v) b().spacing = v end, "px", 1)
    form:stepper("Most icons at once", 1, 10,
        function() return b().max end,
        function(v) b().max = v end, nil, 1)
    form:dropdown("Growth", auraGrowthOptions(),
        function() return Data.AuraGrowth(b().growth) end,
        function(v) b().growth = v end, 220)
    form:stepper("Nudge X", -200, 200,
        function() return b().x end,
        function(v) b().x = v end, "px", 1)
    form:stepper("Nudge Y", -100, 100,
        function() return b().y end,
        function(v) b().y = v end, "px", 1)

    form:header("Countdown")
    form:check("Show the time remaining",
        function() return b().showTimer ~= false end,
        function(v) b().showTimer = v end)
    form:stepper("Countdown size", 6, 24,
        function() return b().timerSize end,
        function(v) b().timerSize = v end, "px", 1)
    form:stepper("Border thickness", 0, 4,
        function() return b().borderSize end,
        function(v) b().borderSize = v end, "px", 1)
    form:color("Border color", function()
        local t = b()
        t.borderColor = t.borderColor or { 0, 0, 0 }
        return t.borderColor
    end)
end

local function buildAurasPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()

    local master = createCheckbox(panel, "Enable aura tracking on nameplates", 320)
    master:SetPoint("TOPLEFT", 12, -6)
    master.OnChange = function(_, checked) auraRoot().enabled = checked; apply() end

    -- Sits with the master rather than on either unit tab: the plates it is about
    -- are friendly players, and those borrow the Enemy Players lists rather than
    -- having a tab of their own — a switch about them filed under "Enemy Players"
    -- would read as a mistake.
    local nameOnly = createCheckbox(panel, "Hide them on players shown as a name only", 320,
        { "Anyone you can't attack, where \"Show only their name, with no bar\" on the Enemy Players styling tab has taken their health bar away. The icons are the last thing left stacked over a bar that isn't there.",
          "Only the icons go. What they were watching stays tracked the whole time, so the moment he flags for PvP and the bar comes back, everything he is already wearing comes back with it — rather than being pieced together from whatever lands next." })
    nameOnly:SetPoint("TOPLEFT", master, "BOTTOMLEFT", 0, -2)
    nameOnly.OnChange = function(_, checked) auraRoot().hideNameOnly = checked; apply() end

    -- Synced both here and on OnShow: this panel is built already visible (it's
    -- resolved on the way into being shown), so the OnShow that re-syncs it on
    -- every later visit never fires for the first one.
    local function syncMaster()
        master:SetChecked(auraRoot().enabled ~= false)
        nameOnly:SetChecked(auraRoot().hideNameOnly ~= false)
    end

    local bar = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    bar:SetHeight(24)
    bar:SetPoint("TOPLEFT", nameOnly, "BOTTOMLEFT", -6, -6)
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
        key   = "spells",
        label = "Spells",
        width = 90,
        build = function() return buildSpellsPanel(content) end,
    }
    -- And then the one strip on the plate that isn't fed from these lists at
    -- all. It lives here because it is icons on a nameplate and this is the tab
    -- for those; its own enable switch is on the page, not the master above,
    -- since that one says "aura tracking" and means it.
    defs[#defs + 1] = {
        key   = "bossmods",
        label = "Boss mods",
        width = 96,
        build = function()
            local page = formPanel(content, bossModsContent)
            -- Stand-in timers on every plate while this page is open, the same
            -- as each aura tab does for its own rows. OnHide covers every way
            -- out, not just the tab buttons: it fires when an ancestor goes too,
            -- so leaving the module's tab or closing the window switches the
            -- fake icons off as well.
            page:HookScript("OnShow", function() setBossPreview(true)  end)
            page:HookScript("OnHide", function() setBossPreview(false) end)
            return page
        end,
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
-- The module has grown past finding a setting by opening tabs until you spot it.
-- Every form-built tab is a run of `form:` calls and nothing else, so the index
-- is built by replaying those calls against a recorder that creates no frames
-- and just writes down what it was asked for. The list of settings and the
-- panels showing them are therefore the same list and can't drift apart.
--
-- The aura whitelists and NPC list are deliberately outside it: both are
-- hand-built editors for things you add, not runs of labelled settings. Boss
-- mods is in, despite sharing a tab with the aura lists, because it IS a run of
-- labelled settings — and it's the page nobody would look for behind "Auras".
local SEARCH_SOURCES = {
    { tab = "General",      fill = generalContent     },
    { tab = "Enemy NPC",    fill = enemyNPCContent    },
    { tab = "Enemy Player", fill = enemyPlayerContent },
    { tab = "Threat",       fill = threatContent      },
    { tab = "Target",       fill = targetContent      },
    { tab = "Icons",        fill = iconsContent       },
    { tab = "Boss mods",    fill = bossModsContent    },
}

-- Rebuilding a recorded entry is the same call the panel made, so each kind
-- keeps its arguments by name rather than as a positional list — several of
-- them are optional and a table with holes in it can't be unpacked safely.
local REPLAY = {
    check    = function(form, e) form:check(e.label, e.a.get, e.a.set, e.a.onChange, e.a.desc) end,
    stepper  = function(form, e) form:stepper(e.label, e.a.min, e.a.max, e.a.get, e.a.set, e.a.suffix, e.a.step, e.a.desc) end,
    dropdown = function(form, e) form:dropdown(e.label, e.a.options, e.a.get, e.a.set, e.a.width, e.a.desc) end,
    media    = function(form, e) form:media(e.label, e.a.kind, e.a.fallback, e.a.get, e.a.set, e.a.width, e.a.desc) end,
    color    = function(form, e) form:color(e.label, e.a.getTbl, e.a.desc) end,
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
    -- Buttons do something rather than store something, so there is nothing for
    -- a search result to show or set — same reason notes are skipped.
    function rec:button() end

    function rec:check(label, get, set, onChange, desc)
        add("check", label, { get = get, set = set, onChange = onChange, desc = desc })
    end
    function rec:stepper(label, min, max, get, set, suffix, step, desc)
        add("stepper", label, { min = min, max = max, get = get, set = set, suffix = suffix, step = step, desc = desc })
    end
    function rec:dropdown(label, options, get, set, width, desc)
        add("dropdown", label, { options = options, get = get, set = set, width = width, desc = desc })
    end
    function rec:media(label, kind, fallback, get, set, width, desc)
        add("media", label, { kind = kind, fallback = fallback, get = get, set = set, width = width, desc = desc })
    end
    function rec:color(label, getTbl, desc)
        add("color", label, { getTbl = getTbl, desc = desc })
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
        -- find: typing "color (" or "%" shouldn't blow up as a Lua pattern.
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
    UI.tint(searchLbl, C.textGrey)

    local countText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    UI.tint(countText, C.textDim)

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
    UI.tint(emptyText, C.textDim)

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
        UI.tint(caption, C.red)

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
            emptyText:SetText("Nothing matches that. The aura whitelists and the NPC List aren't searchable — they're lists you add to rather than settings.")
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
-- Inset at each end of the bar, and between neighbouring tabs.
local SUB_TAB_INSET = 4
local SUB_TAB_GAP   = 3
-- Extra breathing room before Search, which is the one entry on the bar that
-- isn't a settings page. It used to say so by being anchored off on its own with
-- everything else packed left; now that the row fills the bar there is no "off
-- on its own" left, so the gap has to carry that on its own.
local SUB_SEARCH_GAP = 12

local function buildNameplatesShell(parent)
    -- Shared shell, but this tab lays its own tabs out (see layoutTabs below),
    -- so addSubTab's left-to-right chaining is deliberately not used here — only
    -- the taller bar the two-line-free single row needs.
    local panel, subBar, subContent = W.makeSubTabPanel(parent, { barHeight = SUB_BAR_H })

    -- One row filling the bar end to end. The numbers are WEIGHTS, not widths: the
    -- bar's live width is divided in these proportions, so tabs grow with the window
    -- instead of leaving an ever-widening strip of empty backdrop.
    --
    -- The proportions are the label lengths, so a long name gets the room it needs.
    -- They also come out very close to the fixed widths this replaced, so the
    -- tightest case — the window at its 760px minimum — lands on sizes already known
    -- to fit.
    --
    -- "Threat" and "NPC List" are still shorter than the pages they open: at minimum
    -- width the full names would be the difference between fitting and not.
    --
    -- Registered as builder functions, never built eagerly: the NPC list alone is a
    -- few hundred frames, and building every sub-tab on first open is what trips
    -- Blizzard's "script ran too long" watchdog.
    local defs = {
        { key = "general", label = "General",      weight = 60, build = buildGeneralPanel     },
        { key = "npc",     label = "Enemy NPC",    weight = 76, build = buildEnemyNPCPanel    },
        { key = "player",  label = "Enemy Player", weight = 88, build = buildEnemyPlayerPanel },
        { key = "threat",  label = "Threat",       weight = 56, build = buildThreatPanel      },
        { key = "target",  label = "Target",       weight = 56, build = buildTargetPanel      },
        { key = "icons",   label = "Icons",        weight = 50, build = buildIconsPanel       },
        { key = "auras",   label = "Auras",        weight = 52, build = buildAurasPanel       },
        { key = "npclist", label = "NPC List",     weight = 68, build = buildNpcPanel         },
        -- Last, and the only one that isn't a settings page: it's the way into
        -- all of them. SUB_SEARCH_GAP is what still says so.
        { key = "search",  label = "Search",       weight = 54, build = buildSearchPanel, apart = true },
    }

    local tabs = {}
    for _, def in ipairs(defs) do
        local tab = createTab(subBar, def.label, def.weight)
        tab:SetHeight(SUB_TAB_H)
        tab.text:SetFontObject("GameFontNormalSmall")
        tab:SetScript("OnClick", function() selectSubTab(panel, def.key) end)
        panel.subTabs[def.key]   = tab
        panel.subPanels[def.key] = function() return def.build(subContent) end
        tabs[#tabs + 1] = { tab = tab, weight = def.weight, apart = def.apart }
    end

    -- Re-run whenever the bar is resized, which covers both the window being
    -- dragged and the frame simply not having a width yet on the pass that
    -- built it.
    local function layoutTabs()
        local barW = subBar:GetWidth() or 0
        if barW <= 0 then return end

        local gaps, total = 0, 0
        for i, t in ipairs(tabs) do
            if i > 1 then gaps = gaps + (t.apart and SUB_SEARCH_GAP or SUB_TAB_GAP) end
            total = total + t.weight
        end

        local avail = barW - SUB_TAB_INSET * 2 - gaps
        if avail <= 0 or total <= 0 then return end

        local x, used = SUB_TAB_INSET, 0
        for i, t in ipairs(tabs) do
            -- The last tab takes whatever is left rather than its own share, so
            -- eight roundings-down can't add up to a row that stops a few pixels
            -- short of the right edge.
            local w = (i == #tabs) and (avail - used) or math.floor(avail * t.weight / total)
            used = used + w

            if i > 1 then x = x + (t.apart and SUB_SEARCH_GAP or SUB_TAB_GAP) end
            t.tab:SetWidth(math.max(1, w))
            t.tab:ClearAllPoints()
            t.tab:SetPoint("TOPLEFT", subBar, "TOPLEFT", x, -SUB_ROW_PAD)
            x = x + w
        end
    end

    subBar:SetScript("OnSizeChanged", layoutTabs)
    -- OnSizeChanged covers the window being dragged, but this panel is built
    -- lazily on the way into being shown and its anchors aren't resolved yet on
    -- that pass — so lay out now for the case where they are, again next frame
    -- for the case where they aren't, and on every show in case the window was
    -- resized while this tab was hidden.
    layoutTabs()
    C_Timer.After(0, layoutTabs)
    panel:HookScript("OnShow", layoutTabs)

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
