-- Item Rack module: the equipment set editor, laid out like the character sheet
-- it edits. Hovering a slot pops out the same item menu the character sheet
-- uses, except a click assigns to the set being edited instead of equipping.
local addon = _G.DrievEssentials
if not addon then return end

local IR = addon.ItemRack
if not IR then return end

local UI    = addon.UI
local C     = UI.colors
local W     = UI.widgets
local WHITE = UI.WHITE

local applyBackdrop        = W.applyBackdrop
local flatButton           = W.flatButton
local createTab            = W.createTab
local activateTab          = W.activateTab
local createCheckbox       = W.createCheckbox
local createScrollDropdown = W.createScrollDropdown
local showConfirmPopup     = W.showConfirmPopup
local showTextPopup        = W.showTextPopup
local showCheckListPopup   = W.showCheckListPopup

local DB      = IR.DB
local getData = IR.GetData
local GetID   = IR.GetID

local _   -- scratch for the multi-return item APIs below

-- ── Layout constants ─────────────────────────────────────────────────────────
local PAD       = 10
local BTN       = 36
local COL_STEP  = 40
-- Hugs the icon grid's footprint (8 cols × 28px plus a 6px gap before the
-- scrollbar) rather than leaving a wide margin. The name/search fields, dropdown
-- and save/delete buttons all key off this and shrink with it.
local CENTER_W  = 244
local TOPBAR_H  = 26
local HEADER_H  = 32 -- title line + "Select Set" label, above the picker row
-- The tab strip, between the title and the "Select Set" label. Sits in the
-- vertical stack like the rows below it, so everything under it moves as one.
local TABROW_H  = 28
-- The one row below the picker. Everything below it hangs off this, and the
-- window's height includes it, so the whole layout follows the constant.
local BINDROW_H = 24
-- The grid's height is what the window's spare height goes into: EXTRA_H below
-- is one more row of icons, so the options block and save row keep the space
-- they had.
local ICON_COLS = 8
local ICON_ROWS = 6
local ICON_CELL = 28
local EXTRA_H   = ICON_CELL
local AMMO_SCALE = 0.75
-- Slide-out set list on the left edge.
local SIDE_W    = 190
local SIDE_ROW  = 26
local SIDE_SB_W = 10

-- Character-sheet order, so muscle memory from the paper doll transfers.
local LEFT_COL     = { 1, 2, 3, 15, 5, 4, 19, 9 }    -- head … wrist
local RIGHT_COL    = { 10, 6, 7, 8, 11, 12, 13, 14 } -- hands … bottom trinket
local BOTTOM_ROW   = { 16, 17, 18 }                  -- weapons, grouped
local BOTTOM_EXTRA = 0                               -- ammo, set apart

local frame            -- the window, built on first open
local slotButtons = {}
local iconButtons = {}

-- Working copy of whatever is being edited. `selected` is what makes a slot part
-- of it; `id` is the item chosen for that slot. `filter` is nil for "show
-- everything" or an array of indices into the virtual list when searching.
--
-- `cond` is what the two tabs come down to: nil while the Set Editor tab is
-- editing the set's own equip list, or a conditional's key while the Set
-- Conditionals tab is editing that conditional's overrides. Both are slot → item
-- id tables, so the slot buttons, the pop-out item menus and everything else
-- below serve either without knowing which is loaded.
local editor = { inv = {}, headIcons = {}, filter = nil, selectedIcon = nil, iconOffset = 0, iconSearch = "", cond = nil }
for i = 0, 19 do editor.inv[i] = {} end

-- ── Icon list ────────────────────────────────────────────────────────────────

-- The icon list is virtual: nothing holds a copy. Its first HEAD_ICONS entries
-- are the addon's own — the 20 currently-chosen items plus two banners — and
-- everything behind them is resolved out of the client's macro icon list on
-- demand. The grid only draws ICON_COLS × ICON_ROWS cells, so scrolling touches
-- dozens, not thousands.
local HEAD_ICONS = 22

local applyIconFilter
-- Declared up here rather than beside the editor state below: the deferred
-- source resolve draws its results through refreshIcons.
local refreshInv, refreshIcons, validateButtons

-- Where the icons behind the head come from, resolved once on first use.
-- `count` is how many there are; `at(i)` is the texture for one of them.
local iconSource

local function resolveIconSource()
    if iconSource then return iconSource end

    -- Order matches what this module did before, so no client changes which list it
    -- sees. The first branch can only hand over everything at once; the second is
    -- indexable, and it's the one Classic Era takes.
    if _G.GetMacroIcons and _G.MACRO_ICON_FILENAMES then
        if RefreshPlayerSpellIconInfo then RefreshPlayerSpellIconInfo() end
        local list = GetMacroIcons(MACRO_ICON_FILENAMES)
        iconSource = {
            count = #list,
            at = function(i)
                local texture = GetSpellorMacroIconInfo and GetSpellorMacroIconInfo(i) or list[i]
                if type(texture) == "number" then return texture end
                return texture and ("Interface\\Icons\\" .. texture) or nil
            end,
        }
    elseif IconDataProviderMixin then
        local provider = CreateAndInitFromMixin(IconDataProviderMixin, IconDataProviderExtraType.Spell)
        if provider then
            -- Deliberately never Release()d: the provider IS the list now, and
            -- re-initialising it per open is the cost this whole shape avoids.
            iconSource = {
                count = provider:GetNumIcons(),
                at    = function(i) return provider:GetIconByIndex(i) end,
            }
        end
    end

    -- Neither API available: the head alone still gives a usable list.
    iconSource = iconSource or { count = 0, at = function() return nil end }
    return iconSource
end

-- Both read `iconSource` rather than resolving it, so the very first open can
-- draw its head immediately and let the source arrive a frame later.
local function totalIcons()
    return HEAD_ICONS + (iconSource and iconSource.count or 0)
end

local function iconAt(i)
    if i <= HEAD_ICONS then return editor.headIcons[i] end
    return iconSource and iconSource.at(i - HEAD_ICONS) or nil
end

-- What the grid actually draws: the whole virtual list, or the search hits.
local function viewCount()
    return editor.filter and #editor.filter or totalIcons()
end

local function viewIconAt(n)
    local index = editor.filter and editor.filter[n] or n
    return index and iconAt(index) or nil
end

local function populateInvIcons()
    for i = 0, 19 do
        local texture
        if editor.inv[i].id and editor.inv[i].id ~= 0 then
            _, texture = IR.GetInfoByID(editor.inv[i].id)
        else
            _, texture = GetInventorySlotInfo(IR.SlotInfo[i].name)
        end
        -- Never nil: a hole in the head would misalign every index behind it.
        editor.headIcons[i + 1] = texture or "Interface\\Icons\\INV_Misc_QuestionMark"
    end
    applyIconFilter()
end

-- What a search term is matched against: the file name for path textures, the
-- numeric file ID for the ones the newer clients hand back as bare numbers.
local function iconSearchKey(texture)
    if type(texture) == "number" then return tostring(texture) end
    if type(texture) ~= "string" then return "" end
    return string.lower(string.match(texture, "([^\\/]+)$") or texture)
end

-- Searching is the one thing that has to consider every icon, and it re-runs on
-- every keystroke — so the keys behind the head get worked out once, the first
-- time somebody actually types, and kept. Opening and scrolling never build it.
local tailKeys

local function tailSearchKeys()
    if tailKeys then return tailKeys end
    local source = resolveIconSource()
    tailKeys = {}
    for i = 1, source.count do
        tailKeys[i] = iconSearchKey(source.at(i))
    end
    return tailKeys
end

function applyIconFilter()
    local term = string.lower(editor.iconSearch or "")
    if term == "" then
        editor.filter = nil
        return
    end
    -- Indices, not textures: the list they point into is virtual, and an index
    -- is what viewIconAt needs to resolve one.
    local out = {}
    for i = 1, HEAD_ICONS do
        if string.find(iconSearchKey(editor.headIcons[i]), term, 1, true) then
            out[#out + 1] = i
        end
    end
    local keys = tailSearchKeys()
    for i = 1, #keys do
        if string.find(keys[i], term, 1, true) then
            out[#out + 1] = HEAD_ICONS + i
        end
    end
    editor.filter = out
end

local function populateInitialIcons()
    editor.headIcons[21] = "Interface\\Icons\\INV_Banner_02"
    editor.headIcons[22] = "Interface\\Icons\\INV_Banner_03"
    populateInvIcons()   -- fills 1-20 from the live gear, then re-filters

    -- The client's list still has to be asked for once, and that's the remaining
    -- lump of work — so it happens a frame after the window is up rather than on the
    -- click that opened it. The head fills the first rows meanwhile.
    if not iconSource then
        C_Timer.After(0, function()
            resolveIconSource()
            applyIconFilter()
            refreshIcons()
        end)
    end
end

-- ── Tri-state helm/cloak control ─────────────────────────────────────────────
-- Three meaningful states, not two: a set can show the piece, hide it, or say
-- nothing at all and leave whatever the player already had.
local TRI_LABELS = { [0] = "hidden", [1] = "shown" }

local function createTriState(parent, label, width)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(width or 150, 18)

    local box = CreateFrame("Frame", nil, row, "BackdropTemplate")
    box:SetSize(14, 14)
    box:SetPoint("LEFT", 0, 0)
    applyBackdrop(box, 1, C.checkBg, C.checkBorder)

    -- Two marks in the same box: a full red fill for "show", a thin grey bar for
    -- "hide", so the three states are distinguishable at a glance.
    local fill = box:CreateTexture(nil, "ARTWORK")
    fill:SetTexture(WHITE)
    fill:SetPoint("TOPLEFT", 2, -2)
    fill:SetPoint("BOTTOMRIGHT", -2, 2)
    UI.tintTexture(fill, C.red)
    fill:Hide()

    local bar = box:CreateTexture(nil, "ARTWORK")
    bar:SetTexture(WHITE)
    bar:SetSize(8, 2)
    bar:SetPoint("CENTER")
    UI.tintTexture(bar, C.textDim)
    bar:Hide()

    local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", box, "RIGHT", 6, 0)

    row.state = nil

    function row:SetState(v)
        self.state = v
        fill:SetShown(v == 1)
        bar:SetShown(v == 0)
        text:SetText(label .. (v ~= nil and (" (" .. TRI_LABELS[v] .. ")") or ""))
        text:SetTextColor(unpack(v == nil and C.textGrey or C.textWhite))
    end
    function row:GetState() return self.state end

    row:SetScript("OnClick", function(self)
        -- Cycle: unchanged → shown → hidden → unchanged.
        local nextState = (self.state == nil and 1) or (self.state == 1 and 0) or nil
        self:SetState(nextState)
    end)
    row:SetScript("OnEnter", function(self)
        UI.tintBorder(box, C.red)
        IR.OnTooltip(self, label,
            "Empty: leave this as it is.\nRed: show it when the set is equipped.\nGrey bar: hide it when the set is equipped.")
    end)
    row:SetScript("OnLeave", function()
        UI.tintBorder(box, C.checkBorder)
        GameTooltip:Hide()
    end)

    row:SetState(nil)
    return row
end

-- flatButton has no disabled look of its own, and a Delete button that stays
-- bright white when there's nothing to delete reads as broken.
local function setButtonEnabled(btn, enabled)
    btn:SetEnabled(enabled)
    btn.label:SetTextColor(unpack(enabled and C.textWhite or C.textDim))
end

-- ── Editor state ─────────────────────────────────────────────────────────────

local function currentName()
    return frame and frame.nameBox:GetText() or ""
end

-- The Hide checkbox tracks whichever SAVED set the typed name currently matches,
-- never state carried over from what was loaded. Otherwise editing "Tank"
-- (hidden) into "Tank Alt" and saving would create a new, already-hidden set.
local function syncHideCheckbox()
    if not frame then return end
    local setname = currentName()
    frame.hide:SetChecked(DB().sets[setname] and IR.IsHidden(setname) and true or false)
end

-- The slot → item table the working copy is filled from: the set's own equip
-- list, or the selected conditional's overrides while that tab is up.
local function editedSource(set)
    if not set then return nil end
    if editor.cond then
        return set.conditionals and set.conditionals[editor.cond]
    end
    return set.equip
end

-- Loads a saved set into the working copy. Slots it doesn't cover fall back to
-- whatever is worn, shown darkened, so they're easy to add.
local function loadSet(setname)
    local set    = setname and DB().sets[setname]
    local source = editedSource(set)
    for i = 0, 19 do
        if source and source[i] then
            editor.inv[i].id = source[i]
            editor.inv[i].selected = true
        else
            editor.inv[i].id = GetID(i)
            editor.inv[i].selected = nil
        end
    end
    if set and set.icon then editor.selectedIcon = set.icon end
    if frame then
        frame.nameBox:SetText(setname or "")
        frame.helm:SetState(set and set.showHelm or nil)
        frame.cloak:SetState(set and set.showCloak or nil)
        syncHideCheckbox()
        frame.setPicker:setValue(setname)
        -- Keeps the side list's highlight on whatever is actually loaded.
        if frame.sideList then frame.sideList:Refresh() end
    end
    refreshInv()
end

-- Re-reads whatever the editor is pointed at without changing which set that is.
-- What changed is the tab, or the conditional inside it.
local function reloadEditor()
    local setname = currentName()
    loadSet(setname ~= "" and setname or nil)
end

function IR.SaveSet()
    if not frame then return end
    -- The working copy holds a conditional's overrides while that tab is up, and
    -- writing those over the set's own gear is the one way this could go wrong.
    if editor.cond then return end
    frame.nameBox:ClearFocus()
    local setname = currentName()
    if setname == "" or IR.SetnameBlacklist[setname] then return end

    local db = DB()
    db.sets[setname] = db.sets[setname] or {}
    local set = db.sets[setname]

    set.icon   = editor.selectedIcon or IR.DEFAULT_SET_ICON
    set.oldset = nil
    -- `old` is where EquipSet records what a swap displaced so unequipping can
    -- put it back; it has to start empty on every save.
    set.old    = {}
    set.equip  = {}
    for i = 0, 19 do
        if editor.inv[i].selected then
            set.equip[i] = editor.inv[i].id
        end
    end
    set.showHelm  = frame.helm:GetState()
    set.showCloak = frame.cloak:GetState()

    local wantHidden = frame.hide:GetChecked() and true or false
    if wantHidden ~= (IR.IsHidden(setname) and true or false) then
        IR.ToggleHidden(setname)
    end

    IR.SetSetBindings()
    IR.UpdateCurrentSet()
    frame.setPicker:setValue(setname)
    if frame.sideList then frame.sideList:Refresh() end
    validateButtons()
    IR.Print("Saved set \"" .. setname .. "\".")
end

-- ── Conditionals ─────────────────────────────────────────────────────────────
-- The overrides for one conditional on one set: the slots ticked in the editor,
-- with the item each should carry while that conditional holds. Nothing else
-- about the set is touched, so saving a conditional can't disturb its base gear.

function IR.SaveConditional()
    if not (frame and editor.cond) then return end
    local setname = currentName()
    local set     = DB().sets[setname]
    if not set then return end

    local overrides, any = {}, nil
    for i = 0, 19 do
        if editor.inv[i].selected then
            overrides[i] = editor.inv[i].id
            any = true
        end
    end

    set.conditionals = set.conditionals or {}
    -- An empty conditional is stored as nothing at all rather than an empty
    -- table: the resolve pass tests `next(overrides)` anyway, and this keeps a
    -- set that has never used conditionals from carrying the bookkeeping.
    set.conditionals[editor.cond] = any and overrides or nil
    if not next(set.conditionals) then set.conditionals = nil end

    local def = IR.GetConditional(editor.cond)
    IR.Print(any
        and ("Saved " .. (def and def.label or editor.cond) .. " for \"" .. setname .. "\".")
        or  ("Cleared " .. (def and def.label or editor.cond) .. " for \"" .. setname .. "\"."))
    validateButtons()
end

-- Drops the overrides and reloads, which drops the ticks with them — the same
-- thing the Save button would do from an empty selection, said out loud.
function IR.ClearConditional()
    if not (frame and editor.cond) then return end
    local set = DB().sets[currentName()]
    if not (set and set.conditionals and set.conditionals[editor.cond]) then return end
    set.conditionals[editor.cond] = nil
    if not next(set.conditionals) then set.conditionals = nil end
    reloadEditor()
    validateButtons()
end

function IR.DeleteSet()
    local setname = currentName()
    local db = DB()
    if not db.sets[setname] then return end
    local hadKey = db.sets[setname].key
    db.sets[setname] = nil
    if db.currentSet == setname then db.currentSet = nil end
    -- Any event pointing at it is now pointing at nothing.
    if IR.ForgetSetInEvents then IR.ForgetSetInEvents(setname) end
    -- Take the deleted set's key back off the client, not just out of the DB.
    if hadKey then IR.SetSetBindings() end
    IR.UpdateCurrentSet()
    loadSet(nil)
    validateButtons()
end

-- What the editor currently has in a slot. collectSlotEntries reads this to keep
-- a slot's own item out of the menu that slot pops out.
function IR.GetEditorSlotID(slot)
    local entry = slot and editor.inv[slot]
    return entry and entry.id or 0
end

-- Menu picks route here while the editor's own slot menus are open.
function IR.OnMenuPickForEditor(slot, id)
    if not slot or slot > 19 then return end

    -- Paired slots (rings, trinkets, weapons) swap rather than duplicate. The paired
    -- slot must be marked selected too — RefreshSetEditorInv re-reads worn gear for
    -- unselected slots and would undo the swap on the next inventory event.
    local other    = IR.SlotInfo[slot].other
    local previous = editor.inv[slot].id
    if other and previous and previous ~= id and editor.inv[other].id == id then
        editor.inv[other].id = previous
        editor.inv[other].selected = true
    end

    editor.inv[slot].id = id
    editor.inv[slot].selected = true
    refreshInv()
    if getData().equipOnSetPick then
        IR.EquipItemByID(id, slot)
    end
end

-- Re-reads worn gear for any slot the user hasn't pinned into the set, so the
-- editor tracks what you're actually wearing while it's open.
function IR.RefreshSetEditorInv()
    if not (frame and frame:IsShown()) then return end
    for i = 0, 19 do
        if not editor.inv[i].selected then editor.inv[i].id = GetID(i) end
    end
    refreshInv()
end

-- ── Slot buttons ─────────────────────────────────────────────────────────────

-- Where a slot's pop-out menu grows from, mirroring the window layout: the left
-- column opens leftwards, the right column rightwards, the bottom row downwards.
local function slotDock(slot)
    for _, id in ipairs(LEFT_COL) do
        if id == slot then return "TOPRIGHT", "TOPLEFT", "HORIZONTAL" end
    end
    for _, id in ipairs(RIGHT_COL) do
        if id == slot then return "TOPLEFT", "TOPRIGHT", "HORIZONTAL" end
    end
    return "TOPLEFT", "BOTTOMLEFT", "VERTICAL"
end

local function createSlotButton(parent, slot, size)
    size = size or BTN
    local btn = CreateFrame("CheckButton", "DrievIRSetSlot" .. slot, parent, "ActionButtonTemplate")
    btn:SetID(slot)
    btn:SetSize(size, size)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    -- skipPushed: these are picker buttons, not things you "use", so they've
    -- never shown the depress flash the on-screen slot buttons do.
    addon.StyleSlotButton(btn, size, { skipPushed = true })

    btn.icon:SetAllPoints(btn)

    -- Blue = the item is only in the bank, red = it can't be found at all.
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    border:SetBlendMode("ADD")
    border:SetSize(size * 1.9, size * 1.9)
    border:SetPoint("CENTER")
    border:Hide()
    btn.irBorder = border

    btn:SetScript("OnEnter", function(self)
        local menuDock, mainDock, orient = slotDock(slot)
        IR.DockWindows(menuDock, self, mainDock, orient)
        -- include = true: offer the worn item too, and route clicks back into
        -- the editor instead of equipping.
        IR.BuildMenu(slot, true)
        IR.IDTooltip(self, editor.inv[slot].id)
    end)
    btn:SetScript("OnLeave", function() IR.ClearTooltip() end)
    btn:SetScript("OnClick", function(self)
        self:SetChecked(false)
        if IsShiftKeyDown() then
            IR.ChatLinkID(editor.inv[slot].id)
            return
        end
        editor.inv[slot].selected = not editor.inv[slot].selected
        refreshInv()
    end)

    IR.AddToMasque("editor", btn)

    slotButtons[slot] = btn
    return btn
end

function refreshInv()
    for i = 0, 19 do
        local btn = slotButtons[i]
        if btn then
            local entry = editor.inv[i]
            local texture
            if entry.id and entry.id ~= 0 then
                _, texture = IR.GetInfoByID(entry.id)
            else
                _, texture = GetInventorySlotInfo(IR.SlotInfo[i].name)
            end
            btn.icon:SetTexture(texture)

            btn.irBorder:Hide()
            if entry.selected and entry.id ~= 0 and IR.GetCountByID(entry.id) == 0 then
                if IR.FindInBank(entry.id) then
                    btn.irBorder:SetVertexColor(0.3, 0.5, 1)
                else
                    btn.irBorder:SetVertexColor(1, 0.1, 0.1)
                end
                btn.irBorder:Show()
            end

            -- Slots the set doesn't cover stay in the layout but read as inert.
            btn:UnlockHighlight()
            if entry.selected then
                btn.icon:SetVertexColor(1, 1, 1)
                if entry.id == 0 then btn:LockHighlight() end
            else
                btn.icon:SetVertexColor(0.25, 0.25, 0.25)
            end
        end
    end
    populateInvIcons()
    refreshIcons()
    validateButtons()
    if frame then frame.iconPreview:SetTexture(editor.selectedIcon) end
end

-- ── Icon picker ──────────────────────────────────────────────────────────────

-- How far the list can scroll, in rows. Shared by the wheel, the thumb drag and
-- the redraw so they can never disagree about the limit.
local function maxIconOffset()
    local rows = math.max(1, math.ceil(viewCount() / ICON_COLS))
    return math.max(0, rows - ICON_ROWS)
end

function refreshIcons()
    if not frame then return end
    local total  = viewCount()
    local rows   = math.max(1, math.ceil(total / ICON_COLS))
    local maxOff = math.max(0, rows - ICON_ROWS)
    editor.iconOffset = math.max(0, math.min(editor.iconOffset, maxOff))
    frame.iconEmpty:SetShown(total == 0)

    -- The only place icons are resolved at all: one lookup per visible cell.
    for i = 1, ICON_COLS * ICON_ROWS do
        local btn = iconButtons[i]
        local idx = editor.iconOffset * ICON_COLS + i
        if idx <= total then
            local texture = viewIconAt(idx)
            btn.icon:SetTexture(texture)
            btn.index = idx
            btn.sel:SetShown(texture == editor.selectedIcon)
            btn:Show()
        else
            btn:Hide()
        end
    end

    -- Thumb length tracks how much of the list is on screen; it disappears
    -- entirely when everything already fits.
    local track = frame.iconTrack
    if maxOff <= 0 then
        frame.iconThumb:Hide()
    else
        frame.iconThumb:Show()
        local trackH = track:GetHeight()
        local thumbH = math.max(20, trackH * (ICON_ROWS / rows))
        frame.iconThumb:SetHeight(thumbH)
        frame.iconThumb:ClearAllPoints()
        frame.iconThumb:SetPoint("TOP", track, "TOP", 0,
            -((trackH - thumbH) * (editor.iconOffset / maxOff)))
    end
end

local function buildIconPicker(parent)
    local grid = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    grid:SetSize(CENTER_W, ICON_ROWS * ICON_CELL + 10)
    applyBackdrop(grid, 1, C.panelDeep, C.tabBorder)
    grid:EnableMouseWheel(true)
    grid:SetScript("OnMouseWheel", function(_, delta)
        editor.iconOffset = editor.iconOffset - delta
        refreshIcons()
    end)

    for i = 1, ICON_COLS * ICON_ROWS do
        local btn = CreateFrame("Button", nil, grid)
        btn:SetSize(ICON_CELL - 4, ICON_CELL - 4)
        local col = (i - 1) % ICON_COLS
        local row = math.floor((i - 1) / ICON_COLS)
        btn:SetPoint("TOPLEFT", grid, "TOPLEFT", 6 + col * ICON_CELL, -6 - row * ICON_CELL)

        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints()
        btn.icon = icon

        local sel = btn:CreateTexture(nil, "OVERLAY")
        sel:SetColorTexture(0.984, 0.173, 0.212, 0.35)
        sel:SetAllPoints()
        sel:Hide()
        btn.sel = sel

        btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        btn:SetScript("OnClick", function(self)
            if not self.index then return end
            editor.selectedIcon = viewIconAt(self.index)
            frame.iconPreview:SetTexture(editor.selectedIcon)
            refreshIcons()
        end)
        iconButtons[i] = btn
    end

    local empty = grid:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    empty:SetPoint("CENTER")
    empty:SetText("No icons match that search.")
    empty:Hide()
    frame.iconEmpty = empty

    -- Slim scrollbar in the module palette rather than Blizzard's faux scroll
    -- frame, so it matches every other DE panel.
    local track = CreateFrame("Frame", nil, grid, "BackdropTemplate")
    track:SetSize(8, ICON_ROWS * ICON_CELL - 2)
    track:SetPoint("TOPRIGHT", grid, "TOPRIGHT", -4, -6)
    applyBackdrop(track, 1, C.panelDark, { 0, 0, 0, 0 })
    frame.iconTrack = track

    local thumb = CreateFrame("Frame", nil, track, "BackdropTemplate")
    thumb:SetWidth(8)
    thumb:SetPoint("TOP", track, "TOP", 0, 0)
    applyBackdrop(thumb, 1, C.tabBorder, { 0, 0, 0, 0 })
    frame.iconThumb = thumb

    -- Dragging the thumb: work in track-local coordinates so the maths holds up
    -- at any UI scale, and translate the thumb's top edge back into a row offset.
    thumb:EnableMouse(true)
    thumb:SetScript("OnMouseDown", function(self)
        local maxOff = maxIconOffset()
        if maxOff <= 0 then return end
        local _, cursorY = GetCursorPosition()
        self.dragCursorY = cursorY / track:GetEffectiveScale()
        self.dragStartOffset = editor.iconOffset
        self:SetScript("OnUpdate", function(s)
            -- Releasing off the thumb can swallow OnMouseUp, so the button state
            -- is what actually ends the drag.
            if not IsMouseButtonDown("LeftButton") then
                s:SetScript("OnUpdate", nil)
                return
            end
            local travel = track:GetHeight() - s:GetHeight()
            if travel <= 0 then return end
            local _, y = GetCursorPosition()
            local delta = s.dragCursorY - (y / track:GetEffectiveScale())
            local offset = s.dragStartOffset + (delta / travel) * maxOff
            offset = math.floor(math.max(0, math.min(maxOff, offset)) + 0.5)
            if offset ~= editor.iconOffset then
                editor.iconOffset = offset
                refreshIcons()
            end
        end)
    end)
    local function stopDrag(self) self:SetScript("OnUpdate", nil) end
    thumb:SetScript("OnMouseUp", stopDrag)
    thumb:SetScript("OnHide", stopDrag)

    -- Clicking the bare track jumps a page towards the click.
    track:EnableMouse(true)
    track:SetScript("OnMouseDown", function(self)
        local maxOff = maxIconOffset()
        if maxOff <= 0 then return end
        local _, y = GetCursorPosition()
        y = y / self:GetEffectiveScale()
        editor.iconOffset = math.max(0, math.min(maxOff,
            editor.iconOffset + (y < thumb:GetBottom() and ICON_ROWS or -ICON_ROWS)))
        refreshIcons()
    end)

    return grid
end

-- ── Slide-out set list ───────────────────────────────────────────────────────

-- A scrolling list of every set down the left edge, click to load, drag to
-- reorder. The order it writes is the one IR.GetOrderedSetNames hands to the
-- picker and the pop-out set menu, so a drag here moves the set everywhere.
local function buildSideList(parent, onPick)
    local panel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    panel:SetWidth(SIDE_W)
    -- Same height as the window it hangs off, so the two read as one surface.
    panel:SetPoint("TOPRIGHT", parent, "TOPLEFT", -2, 0)
    panel:SetPoint("BOTTOMRIGHT", parent, "BOTTOMLEFT", -2, 0)
    applyBackdrop(panel, 1, C.panelBG, C.tabBorder)
    -- Has to swallow the mouse, not just draw over things: this panel hangs outside
    -- the editor window's rect, so without it the cursor falls through to whatever
    -- is behind — including the on-screen buttons, which would pop their menus open.
    panel:EnableMouse(true)
    panel:Hide()

    -- Halves of the panel's inner width, which is what decides their labels:
    -- "Export"/"Import" fit where "Export Sets" wouldn't.
    local SIDE_BTN_W = math.floor((SIDE_W - 16 - 6) / 2)

    local exportBtn = flatButton(panel, "Export", SIDE_BTN_W, 18)
    exportBtn:SetPoint("TOPLEFT", 8, -8)
    exportBtn:SetScript("OnClick", function() IR.ShowExportSetsPopup() end)
    exportBtn:HookScript("OnEnter", function(self)
        IR.OnTooltip(self, "Export Sets",
            "Tick the sets you want and get a string to copy. Paste it into Import on another "
            .. "character to carry them over.")
    end)
    exportBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)

    local importBtn = flatButton(panel, "Import", SIDE_BTN_W, 18)
    importBtn:SetPoint("LEFT", exportBtn, "RIGHT", 6, 0)
    importBtn:SetScript("OnClick", function() IR.ShowImportSetsPopup() end)
    importBtn:HookScript("OnEnter", function(self)
        IR.OnTooltip(self, "Import Sets",
            "Paste in a string exported from another character. Its sets are added to the ones you "
            .. "already have — nothing is removed, and you're asked set by set before anything with a "
            .. "name you're already using is replaced.")
    end)
    importBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)

    -- Full width under the other two: "Import OLD" doesn't fit in half a panel,
    -- and it isn't a peer of them anyway — it's the one-off migration step.
    local importOldBtn = flatButton(panel, "Import OLD", SIDE_BTN_W * 2 + 6, 18)
    importOldBtn:SetPoint("TOPLEFT", exportBtn, "BOTTOMLEFT", 0, -6)
    importOldBtn:SetScript("OnClick", function() IR.ShowImportOriginalPopup() end)
    importOldBtn:HookScript("OnEnter", function(self)
        IR.OnTooltip(self, "Import From The Original ItemRack",
            "Copies this character's sets straight out of the original ItemRack addon — no export "
            .. "string needed.\n\n"
            .. "|cffffffffBoth addons have to be enabled at the same time|r for this: its sets are only "
            .. "readable while it's loaded. Once they're across, switch it off under Esc → AddOns.\n\n"
            .. "Any set here with the same name is replaced.")
    end)
    importOldBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)

    -- Binds sets by hovering them in the list below, so it belongs on this panel
    -- rather than in the bind row, which only ever addresses the loaded set.
    local quickBindBtn = flatButton(panel, "Quick Keybind", SIDE_BTN_W * 2 + 6, 18)
    quickBindBtn:SetPoint("TOPLEFT", importOldBtn, "BOTTOMLEFT", 0, -6)
    quickBindBtn:SetScript("OnClick", function()
        if IR.SetBindModeActive() then
            IR.StopSetBindMode()
        else
            IR.StartSetBindMode()
        end
    end)
    quickBindBtn:HookScript("OnEnter", function(self)
        IR.OnTooltip(self, "Quick Keybind",
            "Bind keys to sets without loading them: hover a set in the list below and press the key "
            .. "you want.\n\n"
            .. "Escape finishes. Delete clears the hovered set's binding.")
    end)
    quickBindBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)

    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    header:SetPoint("TOPLEFT", quickBindBtn, "BOTTOMLEFT", 0, -8)
    header:SetText("Sets")
    UI.tint(header, C.red)

    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
    hint:SetPoint("RIGHT", -8, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText("Click to load, drag to reorder.")

    local listBG = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    listBG:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -6)
    listBG:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8, 8)
    applyBackdrop(listBG, 1, C.panelDeep, C.tabBorder)

    local sf = CreateFrame("ScrollFrame", nil, listBG)
    sf:SetPoint("TOPLEFT", 1, -1)
    sf:SetPoint("BOTTOMRIGHT", -(SIDE_SB_W + 2), 1)

    local sc = CreateFrame("Frame", nil, sf)
    sc:SetSize(1, 1)
    sf:SetScrollChild(sc)

    local track = CreateFrame("Frame", nil, listBG, "BackdropTemplate")
    track:SetWidth(SIDE_SB_W)
    track:SetPoint("TOPRIGHT", listBG, "TOPRIGHT", -1, -1)
    track:SetPoint("BOTTOMRIGHT", listBG, "BOTTOMRIGHT", -1, 1)
    applyBackdrop(track, 1, C.panelDark, C.tabBorder)

    local thumb = CreateFrame("Button", nil, track, "BackdropTemplate")
    thumb:SetWidth(SIDE_SB_W - 2)
    thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 1, 0)
    applyBackdrop(thumb, 1, C.tabIdle, C.tabBorder)

    local rows     = {}
    local list     = {}   -- working copy; committed to the DB on drag stop
    local dragName            -- the set being dragged, tracked by name not row
    local refreshRows, updateThumb

    local function visibleRows()
        return math.max(1, math.floor(sf:GetHeight() / SIDE_ROW))
    end

    local function maxScroll()
        return math.max(0, (#list - visibleRows()) * SIDE_ROW)
    end

    function updateThumb()
        local limit = maxScroll()
        if limit <= 0 then
            thumb:Hide()
            sf:SetVerticalScroll(0)
            return
        end
        thumb:Show()
        local trackH = track:GetHeight()
        local thumbH = math.max(16, trackH * visibleRows() / #list)
        thumb:SetHeight(thumbH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 1,
            -((trackH - thumbH) * (sf:GetVerticalScroll() / limit)))
    end

    local function scrollBy(delta)
        sf:SetVerticalScroll(math.max(0, math.min(maxScroll(), sf:GetVerticalScroll() + delta)))
        updateThumb()
    end

    -- Live-reorder while the cursor moves: the row pool is index-fixed and re-skinned
    -- on every refresh, so the dragged set is tracked by name and the backing list
    -- moved under it, keeping the row beneath the cursor showing what's dragged.
    local function dragUpdate()
        if not dragName then return end
        local current
        for i, name in ipairs(list) do
            if name == dragName then current = i break end
        end
        if not current then return end

        local cursorY = select(2, GetCursorPosition()) / sf:GetEffectiveScale()
        local top, bottom = sf:GetTop(), sf:GetBottom()
        if not top then return end

        -- Dragging past either edge scrolls the list rather than dead-ending.
        if cursorY > top - 4 then
            scrollBy(-6)
        elseif bottom and cursorY < bottom + 4 then
            scrollBy(6)
        end

        local scTop = sc:GetTop()
        if not scTop then return end
        local target = math.max(1, math.min(#list, math.floor((scTop - cursorY) / SIDE_ROW) + 1))
        if target ~= current then
            table.remove(list, current)
            table.insert(list, target, dragName)
            refreshRows()
        end
    end

    local function createRow(index)
        local row = CreateFrame("Button", nil, sc, "BackdropTemplate")
        row:SetHeight(SIDE_ROW - 2)
        row.isSetRow = true   -- how the quick keybind mode recognises one
        -- Both horizontal edges pinned to the scroll child, which tracks the
        -- scroll frame's width, so rows can't overhang the scrollbar.
        row:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -(index - 1) * SIDE_ROW)
        row:SetPoint("TOPRIGHT", sc, "TOPRIGHT", 0, -(index - 1) * SIDE_ROW)
        applyBackdrop(row, 1, C.panelDeep, { 0, 0, 0, 0 })

        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(SIDE_ROW - 8, SIDE_ROW - 8)
        icon:SetPoint("LEFT", 4, 0)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        row.icon = icon

        -- Bind column first: the name is anchored to its left edge so a long set
        -- name truncates against the key rather than running underneath it.
        local key = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        key:SetPoint("RIGHT", -4, 0)
        key:SetJustifyH("RIGHT")
        UI.tint(key, C.textDim)
        row.key = key

        local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("LEFT", icon, "RIGHT", 6, 0)
        label:SetPoint("RIGHT", key, "LEFT", -4, 0)
        label:SetJustifyH("LEFT")
        row.label = label

        row:RegisterForClicks("LeftButtonUp")
        row:SetScript("OnClick", function(self)
            if self.setName and onPick then onPick(self.setName) end
        end)
        row:SetScript("OnEnter", function(self)
            UI.tintBorder(self, C.red)
        end)
        row:SetScript("OnLeave", function(self)
            self:SetBackdropBorderColor(0, 0, 0, 0)
        end)

        row:RegisterForDrag("LeftButton")
        row:SetScript("OnDragStart", function(self)
            if not self.setName then return end
            dragName = self.setName
            self:SetScript("OnUpdate", dragUpdate)
        end)
        local function endDrag(self)
            self:SetScript("OnUpdate", nil)
            if not dragName then return end
            dragName = nil
            IR.SetSetOrder(list)
            -- The pop-out set menu reads the same order, so a menu that happens
            -- to be open needs redrawing rather than left showing the old one.
            if IR.MenuIsVisible and IR.MenuIsVisible() then IR.BuildMenu() end
            refreshRows()
        end
        row:SetScript("OnDragStop", endDrag)
        -- Rows are pooled and hidden as the list shrinks, so a row vanishing
        -- mid-drag has to end the drag rather than leave an orphaned OnUpdate.
        row:SetScript("OnHide", endDrag)

        rows[index] = row
        return row
    end

    function refreshRows()
        local selected = frame and frame.nameBox and frame.nameBox:GetText()
        for i = 1, math.max(#list, #rows) do
            local row = rows[i] or (i <= #list and createRow(i))
            if row then
                local name = list[i]
                if name then
                    local set = DB().sets[name]
                    row.setName = name
                    row.icon:SetTexture((set and set.icon) or IR.DEFAULT_SET_ICON)
                    row.key:SetText(set and set.key and GetBindingText(set.key, nil, false) or "")
                    row.label:SetText(name)
                    row.label:SetTextColor(unpack(name == selected and C.red or C.textWhite))
                    applyBackdrop(row, 1, name == selected and C.panelDark or C.panelDeep,
                        { 0, 0, 0, 0 })
                    row:Show()
                else
                    row.setName = nil
                    row:Hide()
                end
            end
        end
        sc:SetHeight(math.max(#list * SIDE_ROW, 1))
        updateThumb()
    end

    -- Which set the pointer is over, for the quick keybind mode. Walks up from
    -- mouse focus for the same reason the slot buttons do: the focus can be a
    -- child region of the row rather than the row itself.
    function panel:HoveredSetName()
        local focus = addon.GetMouseFocusFrame()
        while focus do
            if focus.isSetRow then
                return focus:IsShown() and focus.setName or nil
            end
            focus = focus.GetParent and focus:GetParent() or nil
        end
    end

    -- Re-reads the saved order. Called whenever sets are saved, deleted or the
    -- window opens; skipped mid-drag so it can't yank the list out from under
    -- the cursor.
    function panel:Refresh()
        if dragName then return end
        wipe(list)
        for _, name in ipairs(IR.GetOrderedSetNames()) do list[#list + 1] = name end
        refreshRows()
    end

    -- A drag interrupted by the panel closing would otherwise leave dragName set,
    -- and Refresh() bails while a drag is live — the list would never update again.
    panel:SetScript("OnHide", function()
        -- Nothing left to hover, so the prompt goes with the list it points at.
        IR.StopSetBindMode()
        if not dragName then return end
        dragName = nil
        IR.SetSetOrder(list)
    end)

    -- Same reason as the panel itself: the gaps between rows are bare listBG.
    listBG:EnableMouse(true)
    listBG:EnableMouseWheel(true)
    listBG:SetScript("OnMouseWheel", function(_, delta) scrollBy(-delta * SIDE_ROW * 2) end)

    thumb:EnableMouse(true)
    thumb:SetScript("OnMouseDown", function(self)
        local limit = maxScroll()
        if limit <= 0 then return end
        local startY      = select(2, GetCursorPosition()) / track:GetEffectiveScale()
        local startScroll = sf:GetVerticalScroll()
        self:SetScript("OnUpdate", function(s)
            if not IsMouseButtonDown("LeftButton") then s:SetScript("OnUpdate", nil) return end
            local travel = track:GetHeight() - s:GetHeight()
            if travel <= 0 then return end
            local y = select(2, GetCursorPosition()) / track:GetEffectiveScale()
            sf:SetVerticalScroll(math.max(0, math.min(limit,
                startScroll + (startY - y) / travel * limit)))
            updateThumb()
        end)
    end)
    local function stopThumb(self) self:SetScript("OnUpdate", nil) end
    thumb:SetScript("OnMouseUp", stopThumb)
    thumb:SetScript("OnHide", stopThumb)
    thumb:SetScript("OnEnter", function(self) UI.tintBg(self, C.tabHover) end)
    thumb:SetScript("OnLeave", function(self) UI.tintBg(self, C.tabIdle) end)

    -- The list is sized off the scroll frame, whose dimensions aren't final
    -- until the panel has actually been laid out.
    sf:SetScript("OnSizeChanged", function(_, w)
        sc:SetWidth(w)
        updateThumb()
    end)

    return panel
end

-- ── Button states ────────────────────────────────────────────────────────────

function validateButtons()
    if not frame then return end
    local setname = currentName()
    local exists  = DB().sets[setname] ~= nil

    -- Built with the rest of the window, so it's always there by the time
    -- anything can call this; guarded only against the very first load, which
    -- runs while buildFrame is still on its way down the file.
    if frame.RefreshConditionals then frame.RefreshConditionals() end

    local anySelected
    for i = 0, 19 do
        if editor.inv[i].selected then anySelected = true break end
    end

    -- Saving needs a usable name and at least one slot; the rest only make sense
    -- against a set that already exists.
    setButtonEnabled(frame.saveBtn,
        setname ~= "" and not IR.SetnameBlacklist[setname] and anySelected and true or false)
    setButtonEnabled(frame.deleteBtn, exists)
    setButtonEnabled(frame.bindBtn, exists)

    -- Binding readout: only a saved set can carry one, so an unsaved name says
    -- why the button next to it is dead rather than just showing nothing.
    local key = exists and DB().sets[setname].key
    if key then
        -- Cross-check the client rather than trusting the saved key alone: if the
        -- binding didn't actually take (or something else has since claimed the
        -- key) that needs to be visible, not a key that silently does nothing.
        local action = GetBindingAction(key)
        local live   = action and string.find(action, "DrievItemRackSetBind", 1, true)
        -- Both messages are kept short: the readout shares its row with the two
        -- buttons either side of it and clips rather than wrapping, so what it
        -- says has to fit. The Bind Key tooltip carries the longer explanation.
        frame.bindLabel:SetText("Bound to |cfffb2c36" .. GetBindingText(key, nil, false) .. "|r"
            .. (live and "" or " |cffff8800(inactive)|r"))
        UI.tint(frame.bindLabel, C.textWhite)
    elseif exists then
        frame.bindLabel:SetText("No key bound")
        UI.tint(frame.bindLabel, C.textDim)
    else
        frame.bindLabel:SetText("Save the set first")
        UI.tint(frame.bindLabel, C.textDim)
    end
end

-- ── Slot button key binding ──────────────────────────────────────────────────
-- A mode rather than a dialog: what gets bound is whichever on-screen button the
-- pointer is over, so the buttons underneath must stay hoverable. The prompt
-- takes the keyboard and nothing else.

local slotBindPrompt   -- built on first use
local slotBindPaused   -- true while the "already bound" question is up

local function getSlotBindPrompt()
    if slotBindPrompt then return slotBindPrompt end

    local p = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    p:SetSize(440, 86)
    p:SetPoint("TOP", UIParent, "TOP", 0, -160)
    p:SetFrameStrata("FULLSCREEN_DIALOG")
    applyBackdrop(p, 2, C.panelBG, C.red)
    p:EnableMouse(false)   -- see above: the buttons being bound sit underneath
    p:EnableKeyboard(true)
    p:SetPropagateKeyboardInput(false)
    p:Hide()

    local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -10)
    title:SetText("|cfffb2c36Slot Key Binding|r")

    local help = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    help:SetPoint("TOP", title, "BOTTOM", 0, -6)
    help:SetWidth(410)
    help:SetJustifyH("CENTER")
    UI.tint(help, C.textGrey)
    help:SetText("Hover one of your Item Rack buttons and press a key.\n"
        .. "Escape finishes. Delete clears the hovered button's binding.")

    local status = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    status:SetPoint("BOTTOM", 0, 10)
    status:SetWidth(410)
    status:SetJustifyH("CENTER")
    p.status = status

    p:SetScript("OnUpdate", function(self, elapsed)
        self.throttle = (self.throttle or 0) + elapsed
        if self.throttle < 0.1 then return end
        self.throttle = 0
        -- Nothing can be bound in combat, so don't sit there swallowing the
        -- keyboard through a pull.
        if InCombatLockdown() then
            IR.StopSlotBindMode()
            IR.Print("Key bindings can't be changed in combat.")
            return
        end
        local id = IR.HoveredSlotButtonID()
        if not id then
            self.status:SetText("|cff9aa0aaNo button under the pointer.|r")
            return
        end
        local key = IR.GetSlotBindingKey(id)
        self.status:SetText("Over " .. IR.SlotButtonLabel(id) .. " — "
            .. (key and ("bound to |cfffb2c36" .. GetBindingText(key, nil, false) .. "|r")
                     or "|cff9aa0aanot bound|r"))
    end)

    p:SetScript("OnKeyDown", function(self, key)
        -- Keys are still swallowed while the question is up (this frame has the
        -- keyboard either way), so Escape has to be routed to the dialog by
        -- hand — hiding it runs its onCancel, which unpauses us.
        if slotBindPaused then
            if key == "ESCAPE" and UI.confirmPopup then UI.confirmPopup:Hide() end
            return
        end
        if IR.IsModifierKey(key) then return end
        if key == "ESCAPE" then
            IR.StopSlotBindMode()
            return
        end

        local id = IR.HoveredSlotButtonID()
        if not id then
            IR.Print("Hover an Item Rack button first, then press the key you want.")
            return
        end
        local what = IR.SlotButtonLabel(id)

        if key == "DELETE" or key == "BACKSPACE" then
            if IR.GetSlotBindingKey(id) or IR.SlotKeys()[id] then
                if IR.SetSlotBinding(id, nil) then
                    IR.Print("Cleared the key binding for " .. what .. ".")
                end
            end
            return
        end

        key = IR.ChordFromKey(key)
        if IR.SlotKeys()[id] == key then return end

        -- Suspended rather than closed while the question is up: the answer
        -- lands back here, and the user is most likely part way through binding
        -- a row of buttons.
        slotBindPaused = true
        IR.ConfirmBinding(key, what, IR.SlotBindingAction(id), function()
            slotBindPaused = nil
            if IR.SetSlotBinding(id, key) then
                IR.Print("Bound " .. GetBindingText(key, nil, false) .. " to " .. what .. ".")
            end
        end, function()
            slotBindPaused = nil
        end)
    end)

    slotBindPrompt = p
    return p
end

function IR.SlotBindModeActive()
    return slotBindPrompt and slotBindPrompt:IsShown() and true or false
end

function IR.StartSlotBindMode()
    if InCombatLockdown() then
        IR.Print("Key bindings can't be changed in combat.")
        return
    end
    if not next(IR.Layout().buttons) then
        IR.Print("No Item Rack buttons on screen to bind — Alt+click a slot on your character sheet to make one.")
        return
    end
    -- Two things listening for the same keypress is one too many.
    IR.StopSetBindMode()
    -- A focused edit box swallows the keyboard before any frame sees it, so the
    -- prompt would sit there looking ready while the set name quietly gained an
    -- "f" for every key pressed.
    if frame then
        if frame.nameBox   then frame.nameBox:ClearFocus()   end
        if frame.searchBox then frame.searchBox:ClearFocus() end
    end
    getSlotBindPrompt():Show()
end

function IR.StopSlotBindMode()
    slotBindPaused = nil
    if slotBindPrompt then slotBindPrompt:Hide() end
end

-- ── Quick set key binding ────────────────────────────────────────────────────
-- Slot binding's shape aimed at the side list: hover a set row and press a key,
-- without having to load each set to bind it. Same reasoning throughout — the
-- rows underneath must stay hoverable, so the prompt takes the keyboard only.

local setBindPrompt
local setBindPaused

local function bindableSideList()
    local list = frame and frame:IsShown() and frame.sideList
    return (list and list:IsShown()) and list or nil
end

local function hoveredSetName()
    local list = bindableSideList()
    return list and list:HoveredSetName() or nil
end

-- Both places a binding lands: the readout beside "Bind Key" is about the loaded
-- set, which may or may not be the one just bound, and the list carries the key
-- column for all of them.
local function afterSetBindChange()
    if not frame then return end
    validateButtons()
    if frame.sideList then frame.sideList:Refresh() end
end

local function getSetBindPrompt()
    if setBindPrompt then return setBindPrompt end

    local p = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    p:SetSize(440, 86)
    p:SetPoint("TOP", UIParent, "TOP", 0, -160)
    p:SetFrameStrata("FULLSCREEN_DIALOG")
    applyBackdrop(p, 2, C.panelBG, C.red)
    p:EnableMouse(false)   -- see above: the rows being bound sit underneath
    p:EnableKeyboard(true)
    p:SetPropagateKeyboardInput(false)
    p:Hide()

    local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -10)
    title:SetText("|cfffb2c36Quick Keybind|r")

    local help = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    help:SetPoint("TOP", title, "BOTTOM", 0, -6)
    help:SetWidth(410)
    help:SetJustifyH("CENTER")
    UI.tint(help, C.textGrey)
    help:SetText("Hover a set in the list and press a key.\n"
        .. "Escape finishes. Delete clears the hovered set's binding.")

    local status = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    status:SetPoint("BOTTOM", 0, 10)
    status:SetWidth(410)
    status:SetJustifyH("CENTER")
    p.status = status

    p:SetScript("OnUpdate", function(self, elapsed)
        self.throttle = (self.throttle or 0) + elapsed
        if self.throttle < 0.1 then return end
        self.throttle = 0
        -- Nothing can be bound in combat, so don't sit there swallowing the
        -- keyboard through a pull.
        if InCombatLockdown() then
            IR.StopSetBindMode()
            IR.Print("Key bindings can't be changed in combat.")
            return
        end
        -- The list can be folded away (or the window closed) from under the
        -- prompt, which would leave it holding the keyboard over nothing.
        if not bindableSideList() then
            IR.StopSetBindMode()
            return
        end
        local setname = hoveredSetName()
        if not setname then
            self.status:SetText("|cff9aa0aaNo set under the pointer.|r")
            return
        end
        local set = DB().sets[setname]
        local key = set and set.key
        self.status:SetText("Over \"" .. setname .. "\" — "
            .. (key and ("bound to |cfffb2c36" .. GetBindingText(key, nil, false) .. "|r")
                     or "|cff9aa0aanot bound|r"))
    end)

    p:SetScript("OnKeyDown", function(self, key)
        -- Keys are still swallowed while the question is up (this frame has the
        -- keyboard either way), so Escape has to be routed to the dialog by
        -- hand — hiding it runs its onCancel, which unpauses us.
        if setBindPaused then
            if key == "ESCAPE" and UI.confirmPopup then UI.confirmPopup:Hide() end
            return
        end
        if IR.IsModifierKey(key) then return end
        if key == "ESCAPE" then
            IR.StopSetBindMode()
            return
        end

        local setname = hoveredSetName()
        if not setname then
            IR.Print("Hover a set in the list first, then press the key you want.")
            return
        end
        local set = DB().sets[setname]
        if not set then return end

        if key == "DELETE" or key == "BACKSPACE" then
            if set.key then
                set.key = nil
                -- Has to run even with nothing left bound, or the binding we
                -- already handed the client stays live after the set stops
                -- claiming it.
                IR.SetSetBindings()
                afterSetBindChange()
                IR.Print("Cleared the key binding for \"" .. setname .. "\".")
            end
            return
        end

        key = IR.ChordFromKey(key)
        if set.key == key then return end

        -- Suspended rather than closed while the question is up: the answer lands
        -- back here, and the user is most likely part way down the list.
        setBindPaused = true
        IR.ConfirmBinding(key, "the set \"" .. setname .. "\"", nil, function()
            setBindPaused = nil
            -- Re-read: the set could have been deleted or renamed under the
            -- dialog, which is modal to nothing at all.
            local target = DB().sets[setname]
            if not target then return end
            target.key = key
            IR.SetSetBindings()
            afterSetBindChange()
            IR.Print("Bound \"" .. setname .. "\" to " .. GetBindingText(key, nil, false) .. ".")
        end, function()
            setBindPaused = nil
        end)
    end)

    setBindPrompt = p
    return p
end

function IR.SetBindModeActive()
    return setBindPrompt and setBindPrompt:IsShown() and true or false
end

function IR.StartSetBindMode()
    if InCombatLockdown() then
        IR.Print("Key bindings can't be changed in combat.")
        return
    end
    if not bindableSideList() then
        IR.Print("Open the set list first — quick keybinding works by hovering the sets in it.")
        return
    end
    if not next(DB().sets) then
        IR.Print("No sets to bind yet — save one first.")
        return
    end
    -- Two things listening for the same keypress is one too many.
    IR.StopSlotBindMode()
    -- A focused edit box swallows the keyboard before any frame sees it, so the
    -- prompt would sit there looking ready while the set name quietly gained an
    -- "f" for every key pressed.
    if frame then
        if frame.nameBox   then frame.nameBox:ClearFocus()   end
        if frame.searchBox then frame.searchBox:ClearFocus() end
    end
    getSetBindPrompt():Show()
end

function IR.StopSetBindMode()
    setBindPaused = nil
    if setBindPrompt then setBindPrompt:Hide() end
end

-- ── Build the window ─────────────────────────────────────────────────────────

-- ── Export / import dialogs ──────────────────────────────────────────────────
-- Reachable from two places — this window's own buttons and the settings tab —
-- so the whole flow lives here rather than at either call site.

-- An import can add or replace sets under an open editor. The picker re-reads
-- its list every time it opens, but the side list and the loaded working copy
-- are snapshots, so both are rebuilt.
function IR.RefreshSetEditorSets()
    if not (frame and frame:IsShown()) then return end
    if frame.sideList then frame.sideList:Refresh() end
    local setname = currentName()
    -- Only reload what's still there: a name typed but never saved is the
    -- user's unsaved work, and an import is no reason to throw it away.
    if setname ~= "" and DB().sets[setname] then loadSet(setname) end
end

-- Puts the encoded string in the copy box. `names` nil means every set.
local function showSetsString(names)
    local str, err = IR.ExportSets(names)
    if not str then return nil, err or "Could not export these sets." end
    showTextPopup({
        title      = "Export Item Rack Sets",
        hint       = "Copy this string (Ctrl+A, Ctrl+C), then import it elsewhere.",
        text       = str,
        actionText = "Close",
        selectAll  = true,
    })
    return true
end

-- Rows for a set-name list, in the order the editor shows them. `source` is the
-- table to read icons out of (the DB for export, the decoded string for import).
local function setListItems(names, source)
    local items = {}
    for _, name in ipairs(names) do
        local set = source[name]
        items[#items + 1] = {
            key   = name,
            label = name,
            icon  = (set and set.icon) or IR.DEFAULT_SET_ICON,
        }
    end
    return items
end

function IR.ShowExportSetsPopup()
    -- Nothing ticked to begin with: Select All covers "all of them", so the
    -- checkboxes only ever mean a deliberate choice.
    showCheckListPopup({
        title      = "Export Item Rack Sets",
        hint       = "Tick the sets to export, or Select All for the lot.",
        emptyText  = "This character has no sets to export.",
        items      = setListItems(IR.GetOrderedSetNames(), DB().sets),
        actionText = "Export",
        onAction   = function(keys) return showSetsString(keys) end,
    })
end

-- Writes the sets in, then reports what actually landed. `overwrite` is the
-- list of existing names the user agreed to replace; anything clashing that
-- isn't in it is left as it is.
local function finishImport(incoming, overwrite)
    local added, replaced = IR.ApplySetsImport(incoming, overwrite)
    local parts = {}
    if added > 0 then
        parts[#parts + 1] = "added " .. added .. " set" .. (added == 1 and "" or "s")
    end
    if replaced > 0 then
        parts[#parts + 1] = "replaced " .. replaced
    end
    if #parts == 0 then
        IR.Print("Import finished — nothing changed, every set was skipped.")
    else
        IR.Print("Import finished — " .. table.concat(parts, ", ") .. ".")
    end
    IR.RefreshSetEditorSets()
end

function IR.ShowImportSetsPopup()
    showTextPopup({
        title      = "Import Item Rack Sets",
        hint       = "Paste a string exported from another character. The sets in it are added to the "
            .. "ones you already have — nothing is removed.",
        actionText = "Import",
        onAction   = function(_, text)
            -- Second return is the clash list on success, the error on
            -- failure — nothing is written either way, so a bad string
            -- leaves the paste box open with the reason under it.
            local incoming, conflicts = IR.ReadSetsString(text)
            if not incoming then return nil, conflicts end

            -- No clashes: nothing to ask about, so don't interrupt.
            if #conflicts == 0 then
                finishImport(incoming, nil)
                return true
            end

            showCheckListPopup({
                title      = "Sets With The Same Name",
                hint       = "These sets already exist on this character. Tick the ones the imported "
                    .. "version should replace — anything left unticked keeps the set you have now.\n"
                    .. "Every other set in the string is imported either way.",
                items      = setListItems(conflicts, incoming),
                actionText = "Import",
                onAction   = function(keys)
                    finishImport(incoming, keys)
                    return true
                end,
                -- Backing out of the clash prompt must not half-apply the
                -- string, so the non-clashing sets wait for a decision too.
                onCancel   = function() IR.Print("Import cancelled — nothing was changed.") end,
            })
            return true
        end,
    })
end

-- Straight out of the original ItemRack's memory, no export string in between.
-- Same-named sets are replaced outright rather than asked about one by one, as
-- the string import does: there's a single obvious source here — the addon the
-- user is migrating off — and picking through a clash list on the way out of it
-- is ceremony. The confirmation says plainly that it overwrites instead.
function IR.ShowImportOriginalPopup()
    local incoming, conflicts = IR.ReadOriginalSets()
    -- Second return is the clash list on success, the reason on failure.
    if not incoming then
        IR.Print(conflicts)
        return
    end

    local count = 0
    for _ in pairs(incoming) do count = count + 1 end

    -- Counts, not names: the dialog is a fixed size, and a character with a
    -- dozen clashing sets would push its own buttons off the bottom.
    local message = "Import " .. count .. " set" .. (count == 1 and "" or "s")
        .. " from the original ItemRack?"
    if #conflicts > 0 then
        message = message .. "\n\n|cffff8800" .. #conflicts .. " set"
            .. (#conflicts == 1 and " here has that name and will be"
                                 or "s here have those names and will be")
            .. " replaced.|r"
    end

    showConfirmPopup({
        title       = "Import From The Original ItemRack",
        message     = message,
        confirmText = "Import",
        onConfirm   = function() finishImport(incoming, conflicts) end,
    })
end

local function buildFrame()
    local colH    = #LEFT_COL * COL_STEP
    -- The centre column used to end level with the bottom edge of the last slot
    -- button in each side column (wrist / lower trinket). EXTRA_H is the height
    -- the window gained on top of that, all of it the extra icon row, so the
    -- centre now runs that much past the side columns.
    local centerH  = (#LEFT_COL - 1) * COL_STEP + BTN + EXTRA_H
    local contentH = math.max(colH, centerH)
    local width   = PAD * 2 + COL_STEP * 2 + CENTER_W + 12
    local height  = HEADER_H + TABROW_H + TOPBAR_H + BINDROW_H + PAD
                  + contentH + 8 + COL_STEP + PAD

    local f = CreateFrame("Frame", "DrievItemRackSetFrame", UIParent, "BackdropTemplate")
    f:SetSize(width, height)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    applyBackdrop(f, 1, C.panelBG, C.tabBorder)
    f:Hide()
    tinsert(UISpecialFrames, "DrievItemRackSetFrame")
    -- Travelling from a slot button to its pop-out menu crosses the window
    -- itself, which would otherwise count as leaving the menu region.
    IR.RegisterMenuKeepAlive(f)
    frame = f

    -- ── Header: addon title, centered; close pinned to the window's own corner ──
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -(PAD - 2))
    title:SetText("|cfffb2c36Driev's|r |cffffffffEssentials|r - Item Rack")

    local close = flatButton(f, "X", 22, 18)
    close:SetPoint("TOPRIGHT", -3, -3)
    close:SetScript("OnClick", function() f:Hide() end)

    -- ── Tabs ─────────────────────────────────────────────────────────────────
    -- Split evenly across the window: there are only two of them, and sized to
    -- their labels they'd huddle in the corner looking like an afterthought.
    local tabW = math.floor((width - PAD * 2 - 4) / 2)

    local createTabBtn = createTab(f, "Set Editor", tabW)
    createTabBtn:SetHeight(TABROW_H - 6)
    createTabBtn:SetPoint("TOPLEFT", PAD, -(HEADER_H - 4))

    local condTabBtn = createTab(f, "Set Conditionals", tabW)
    condTabBtn:SetHeight(TABROW_H - 6)
    condTabBtn:SetPoint("LEFT", createTabBtn, "RIGHT", 4, 0)

    -- ── Top bar: set picker and lock ─────────────────────────────────────────
    -- Bare container: the controls inside carry their own framing, and a second
    -- box around them just added noise.
    local top = CreateFrame("Frame", nil, f)
    top:SetPoint("TOPLEFT", PAD, -(HEADER_H + TABROW_H + PAD - 2))
    top:SetPoint("TOPRIGHT", -PAD, -(HEADER_H + TABROW_H + PAD - 2))
    top:SetHeight(TOPBAR_H - 4)

    -- Sits just above the picker, explaining what it's for.
    local setLabel = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    setLabel:SetPoint("BOTTOMLEFT", top, "TOPLEFT", 4, 2)
    setLabel:SetText("Select Set")

    -- Locking lives here as well as in the settings window and the menus: this
    -- window is always reachable (/sets), and once the bars are locked the menu's
    -- own lock control needs Alt held to appear — a bad place for the only way out.
    local lock = createCheckbox(top, "Lock", 60)
    lock:SetPoint("RIGHT", 0, 0)
    lock.OnChange = function(_, checked)
        getData().locked = checked
        IR.ReflectLock()
    end
    lock:HookScript("OnEnter", function(self)
        IR.OnTooltip(self, "Lock Bars",
            "Stop Item Rack's bars and menus being dragged, and hide their control buttons.")
    end)
    lock:HookScript("OnLeave", function() GameTooltip:Hide() end)
    f.lock = lock
    lock:SetChecked(getData().locked and true or false)

    -- Anything else that flips the lock (the menu control, the settings panel,
    -- the one on the settings sub-tab bar) calls ReflectLock, which keeps every
    -- registered checkbox honest.
    IR.RegisterLockCheckbox(lock)

    -- createScrollDropdown re-reads its item list every time it opens, so the
    -- picker stays current as sets are saved and deleted without any rebuild.
    local picker = createScrollDropdown(top, 160, IR.GetOrderedSetNames,
        function(name) loadSet(name) end)
    picker:SetPoint("LEFT", 4, 0)
    picker:SetPoint("RIGHT", lock, "LEFT", -10, 0)
    picker:SetHeight(18)
    f.setPicker = picker

    -- ── Bind row ─────────────────────────────────────────────────────────────
    -- "Slot Keybinding" isn't tied to the set being edited — it binds the movable
    -- buttons — so it sits at the far end, with the current binding readout between.
    local bindRow = CreateFrame("Frame", nil, f)
    bindRow:SetPoint("TOPLEFT", top, "BOTTOMLEFT", 0, -6)
    bindRow:SetPoint("TOPRIGHT", top, "BOTTOMRIGHT", 0, -6)
    bindRow:SetHeight(18)

    local bind = flatButton(bindRow, "Bind Key", 74, 18)
    bind:SetPoint("LEFT", 4, 0)
    bind:HookScript("OnEnter", function(self)
        IR.OnTooltip(self, "Bind Key",
            "Give the set above a key of its own. Pressing it equips the set from anywhere.\n\n"
            .. "A binding shown as |cffff8800(inactive)|r is saved but isn't live — something else "
            .. "has taken the key, or the UI needs reloading for it to apply again.")
    end)
    bind:HookScript("OnLeave", function() GameTooltip:Hide() end)
    f.bindBtn = bind

    local slotBind = flatButton(bindRow, "Slot Keybinding", 110, 18)
    slotBind:SetPoint("RIGHT", -4, 0)
    slotBind:SetScript("OnClick", function()
        if IR.SlotBindModeActive() then
            IR.StopSlotBindMode()
        else
            IR.StartSlotBindMode()
        end
    end)
    slotBind:HookScript("OnEnter", function(self)
        IR.OnTooltip(self, "Slot Keybinding",
            "Bind keys to the movable Item Rack buttons. Hover a button and press the key you want; "
            .. "the key uses whatever that slot is wearing at the time.\n\n"
            .. "Move this window first if it's sitting over the buttons you want to bind.")
    end)
    slotBind:HookScript("OnLeave", function() GameTooltip:Hide() end)
    f.slotBindBtn = slotBind

    local bindLabel = bindRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bindLabel:SetPoint("LEFT", bind, "RIGHT", 8, 0)
    bindLabel:SetPoint("RIGHT", slotBind, "LEFT", -8, 0)
    bindLabel:SetJustifyH("LEFT")
    -- Boxed in between the two buttons now, so a long readout has to clip to
    -- the one line rather than wrapping down over the slot columns below.
    bindLabel:SetWordWrap(false)
    f.bindLabel = bindLabel

    -- ── Slot columns ─────────────────────────────────────────────────────────
    local function placeColumn(list, side)
        local prev
        for _, slot in ipairs(list) do
            local btn = createSlotButton(f, slot)
            if prev then
                btn:SetPoint("TOP", prev, "BOTTOM", 0, -(COL_STEP - BTN))
            else
                btn:SetPoint("TOP" .. side, f, "TOP" .. side,
                    side == "LEFT" and PAD or -PAD,
                    -(HEADER_H + TABROW_H + TOPBAR_H + BINDROW_H + PAD))
            end
            prev = btn
        end
    end
    placeColumn(LEFT_COL, "LEFT")
    placeColumn(RIGHT_COL, "RIGHT")

    -- Bottom row: the three weapon slots centred on the window as a group, with
    -- the smaller ammo button set apart just to their right.
    local weapons = {}
    for i, slot in ipairs(BOTTOM_ROW) do
        weapons[i] = createSlotButton(f, slot)
    end
    -- Anchor outwards from the middle weapon so the trio stays centred whatever
    -- the ammo button does to the right of it.
    local mid = math.ceil(#weapons / 2)
    weapons[mid]:SetPoint("BOTTOM", f, "BOTTOM", 0, PAD)
    for i = mid - 1, 1, -1 do
        weapons[i]:SetPoint("RIGHT", weapons[i + 1], "LEFT", -(COL_STEP - BTN), 0)
    end
    for i = mid + 1, #weapons do
        weapons[i]:SetPoint("LEFT", weapons[i - 1], "RIGHT", COL_STEP - BTN, 0)
    end

    local ammo = createSlotButton(f, BOTTOM_EXTRA, BTN * AMMO_SCALE)
    ammo:SetPoint("LEFT", weapons[#weapons], "RIGHT", 10, 0)

    -- ── Slide-out set list, bottom-left ──────────────────────────────────────
    local sideList = buildSideList(f, function(name) loadSet(name) end)
    f.sideList = sideList

    local sideToggle = flatButton(f, "<", 22, 22)
    sideToggle:SetPoint("BOTTOMLEFT", PAD, PAD)

    local function applySideList(open)
        getData().setListOpen = open
        sideToggle.label:SetText(open and ">" or "<")
        if open then
            sideList:Show()
            sideList:Refresh()
        else
            sideList:Hide()
        end
    end
    f.applySideList = applySideList

    sideToggle:SetScript("OnClick", function()
        applySideList(not sideList:IsShown())
    end)
    sideToggle:HookScript("OnEnter", function(self)
        IR.OnTooltip(self, "Set List",
            "Show every set in a list beside this window. Click one to load it, or drag it to reorder.\n\n"
            .. "The order you pick here is also the order sets appear in the dropdown above and in the "
            .. "pop-out menu on the set button.")
    end)
    sideToggle:HookScript("OnLeave", function() GameTooltip:Hide() end)

    -- ── Centre column ────────────────────────────────────────────────────────
    local center = CreateFrame("Frame", nil, f)
    center:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + COL_STEP + 6,
        -(HEADER_H + TABROW_H + TOPBAR_H + BINDROW_H + PAD))
    center:SetSize(CENTER_W, centerH)

    local nameBox = CreateFrame("EditBox", nil, center, "BackdropTemplate")
    nameBox:SetSize(CENTER_W, 22)
    nameBox:SetPoint("TOPLEFT")
    nameBox:SetAutoFocus(false)
    nameBox:SetFontObject("GameFontHighlightSmall")
    nameBox:SetTextInsets(6, 6, 0, 0)
    nameBox:SetMaxLetters(40)
    applyBackdrop(nameBox, 1, C.panelDark, C.tabBorder)
    f.nameBox = nameBox

    -- Parented to the EditBox itself, not `center` — a child frame's own layers
    -- always draw over its parent's regardless of layer, so a hint owned by the
    -- parent would end up hidden under the box's backdrop.
    local nameHint = nameBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    nameHint:SetPoint("LEFT", nameBox, "LEFT", 6, 0)
    nameHint:SetText("Set Name")

    local function syncHint()
        nameHint:SetShown(nameBox:GetText() == "" and not nameBox:HasFocus())
    end
    nameBox:SetScript("OnTextChanged", function() validateButtons(); syncHint(); syncHideCheckbox() end)
    nameBox:SetScript("OnEditFocusGained", syncHint)
    nameBox:SetScript("OnEditFocusLost", syncHint)
    nameBox:SetScript("OnEscapePressed", nameBox.ClearFocus)
    nameBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    -- Icon search, sitting directly above the grid it filters.
    local searchBox = CreateFrame("EditBox", nil, center, "BackdropTemplate")
    searchBox:SetSize(CENTER_W, 20)
    searchBox:SetPoint("TOPLEFT", nameBox, "BOTTOMLEFT", 0, -6)
    searchBox:SetAutoFocus(false)
    searchBox:SetFontObject("GameFontHighlightSmall")
    searchBox:SetTextInsets(6, 6, 0, 0)
    searchBox:SetMaxLetters(40)
    applyBackdrop(searchBox, 1, C.panelDark, C.tabBorder)
    f.searchBox = searchBox

    local searchHint = searchBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    searchHint:SetPoint("LEFT", searchBox, "LEFT", 6, 0)
    searchHint:SetText("Search icons by name or ID")

    searchBox:SetScript("OnTextChanged", function(self)
        searchHint:SetShown(self:GetText() == "" and not self:HasFocus())
        editor.iconSearch = self:GetText()
        editor.iconOffset = 0
        applyIconFilter()
        refreshIcons()
    end)
    searchBox:SetScript("OnEditFocusGained", function(self) searchHint:Hide() end)
    searchBox:SetScript("OnEditFocusLost", function(self)
        searchHint:SetShown(self:GetText() == "")
    end)
    searchBox:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    local grid = buildIconPicker(center)
    grid:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", 0, -6)

    local deleteBtn = flatButton(center, "Delete", 118, 22)
    deleteBtn:SetPoint("BOTTOMLEFT", center, "BOTTOMLEFT", 0, 0)
    f.deleteBtn = deleteBtn

    local saveBtn = flatButton(center, "Save", 118, 22)
    saveBtn:SetPoint("BOTTOMRIGHT", center, "BOTTOMRIGHT", 0, 0)
    saveBtn:SetScript("OnClick", function() IR.SaveSet() end)
    f.saveBtn = saveBtn

    -- Options block: helm/cloak/hide on the left, the chosen icon on the right.
    -- Pinned top *and* bottom so it absorbs whatever height is left between the
    -- grid and the save row, keeping that row level with the side columns.
    local opts = CreateFrame("Frame", nil, center, "BackdropTemplate")
    opts:SetPoint("TOPLEFT", grid, "BOTTOMLEFT", 0, -6)
    opts:SetPoint("TOPRIGHT", grid, "BOTTOMRIGHT", 0, -6)
    opts:SetPoint("BOTTOM", deleteBtn, "TOP", 0, 6)
    applyBackdrop(opts, 1, C.panelDark, C.tabBorder)

    local helm = createTriState(opts, "Show Helm", 150)
    helm:SetPoint("TOPLEFT", 8, -6)
    f.helm = helm

    local cloak = createTriState(opts, "Show Cloak", 150)
    cloak:SetPoint("TOPLEFT", helm, "BOTTOMLEFT", 0, -3)
    f.cloak = cloak

    local hide = createCheckbox(opts, "Hide", 150)
    hide:SetPoint("TOPLEFT", cloak, "BOTTOMLEFT", 0, -3)
    hide:HookScript("OnEnter", function(self)
        IR.OnTooltip(self, "Hide Set", "Keep this set out of the pop-out set menu.")
    end)
    hide:HookScript("OnLeave", function() GameTooltip:Hide() end)
    f.hide = hide

    local preview = opts:CreateTexture(nil, "ARTWORK")
    preview:SetSize(44, 44)
    preview:SetPoint("RIGHT", -10, 0)
    f.iconPreview = preview

    deleteBtn:SetScript("OnClick", function()
        local setname = currentName()
        if not DB().sets[setname] then return end
        showConfirmPopup({
            title       = "Delete Set",
            message     = "Delete the set \"" .. setname .. "\"?",
            confirmText = "Delete",
            onConfirm   = function() IR.DeleteSet() end,
        })
    end)

    -- ── Set Conditionals page ────────────────────────────────────────────────
    -- Everything the two tabs have in common — the slot columns, their pop-out
    -- item menus, the set list, the set picker — stays exactly where it is. This
    -- page is only what differs: which conditional is being edited, whether it
    -- holds right now, and where the ticked slots get written.

    -- The dropdown sits in the bind row's place, directly under "Select Set", so
    -- the page reads top-down: which set, which conditional, then the slots.
    local condRow = CreateFrame("Frame", nil, f)
    condRow:SetPoint("TOPLEFT", top, "BOTTOMLEFT", 0, -6)
    condRow:SetPoint("TOPRIGHT", top, "BOTTOMRIGHT", 0, -6)
    condRow:SetHeight(18)
    condRow:Hide()

    local condLabel = condRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condLabel:SetPoint("LEFT", 4, 0)
    condLabel:SetText("Conditional")
    UI.tint(condLabel, C.textDim)

    local function conditionalLabels()
        local out = {}
        for i, def in ipairs(IR.Conditionals) do out[i] = def.label end
        return out
    end

    local condPicker = createScrollDropdown(condRow, 200, conditionalLabels, function(label)
        for _, def in ipairs(IR.Conditionals) do
            if def.label == label then
                editor.cond = def.key
                break
            end
        end
        reloadEditor()
        validateButtons()
    end)
    condPicker:SetPoint("LEFT", condLabel, "RIGHT", 8, 0)
    condPicker:SetPoint("RIGHT", -4, 0)
    condPicker:SetHeight(18)

    -- Fills the centre column's footprint, so the slot columns either side keep
    -- their meaning and only the middle changes with the tab.
    local condPanel = CreateFrame("Frame", nil, f)
    condPanel:SetPoint("TOPLEFT", center, "TOPLEFT")
    condPanel:SetSize(CENTER_W, centerH)
    condPanel:Hide()

    local condSaveBtn = flatButton(condPanel, "Save", 118, 22)
    condSaveBtn:SetPoint("BOTTOMRIGHT", condPanel, "BOTTOMRIGHT", 0, 0)
    condSaveBtn:SetScript("OnClick", function() IR.SaveConditional() end)

    local condClearBtn = flatButton(condPanel, "Clear", 118, 22)
    condClearBtn:SetPoint("BOTTOMLEFT", condPanel, "BOTTOMLEFT", 0, 0)
    condClearBtn:SetScript("OnClick", function()
        local def = IR.GetConditional(editor.cond)
        showConfirmPopup({
            title       = "Clear Conditional",
            message     = "Forget the slots \"" .. currentName() .. "\" swaps for "
                        .. (def and def.label or "this conditional") .. "?",
            confirmText = "Clear",
            onConfirm   = function() IR.ClearConditional() end,
        })
    end)

    local condBody = CreateFrame("Frame", nil, condPanel, "BackdropTemplate")
    condBody:SetPoint("TOPLEFT")
    condBody:SetPoint("TOPRIGHT")
    condBody:SetPoint("BOTTOM", condSaveBtn, "TOP", 0, 6)
    applyBackdrop(condBody, 1, C.panelDark, C.tabBorder)

    local condTitle = condBody:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    condTitle:SetPoint("TOPLEFT", 10, -10)
    condTitle:SetPoint("RIGHT", -10, 0)
    condTitle:SetJustifyH("LEFT")
    UI.tint(condTitle, C.red)

    local condDesc = condBody:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condDesc:SetPoint("TOPLEFT", condTitle, "BOTTOMLEFT", 0, -6)
    condDesc:SetPoint("RIGHT", -10, 0)
    condDesc:SetJustifyH("LEFT")
    UI.tint(condDesc, C.textGrey)

    -- Reads live rather than on a refresh: applying a stone is exactly the moment
    -- someone wants to see this flip, and there's no event that says so.
    local condState = condBody:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condState:SetPoint("TOPLEFT", condDesc, "BOTTOMLEFT", 0, -10)
    condState:SetPoint("RIGHT", -10, 0)
    condState:SetJustifyH("LEFT")

    -- What the check is actually reading off your weapons. Shown whether or not
    -- the conditional holds: "not holding" with the right stone on is otherwise a
    -- dead end, and this turns it into a name that can be compared.
    local condEnchants = condBody:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    condEnchants:SetPoint("TOPLEFT", condState, "BOTTOMLEFT", 0, -4)
    condEnchants:SetPoint("RIGHT", -10, 0)
    condEnchants:SetJustifyH("LEFT")

    local condCount = condBody:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condCount:SetPoint("TOPLEFT", condEnchants, "BOTTOMLEFT", 0, -10)
    condCount:SetPoint("RIGHT", -10, 0)
    condCount:SetJustifyH("LEFT")
    UI.tint(condCount, C.textWhite)

    local condHint = condBody:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    condHint:SetPoint("BOTTOMLEFT", 10, 10)
    condHint:SetPoint("RIGHT", -10, 0)
    condHint:SetJustifyH("LEFT")
    condHint:SetText("Click a slot to include it, then hover it and pick the item to swap in. "
        .. "Slots left out keep whatever the set itself equips.")

    -- Whether the conditional currently holds is asked once a second while the
    -- page is up: cheap (two tooltip scans), and it makes the readout answer the
    -- question the user is standing there asking.
    condPanel:SetScript("OnUpdate", function(self, elapsed)
        self.throttle = (self.throttle or 0) + elapsed
        if self.throttle < 1 then return end
        self.throttle = 0
        local holds = editor.cond and IR.ConditionalHolds(editor.cond)
        condState:SetText(holds and "Right now: |cff4ade80holding|r — this set's swaps apply."
                                or  "Right now: |cff9aa0aanot holding|r — the set equips normally.")
        condEnchants:SetText("Weapon enchants: "
            .. (IR.WeaponEnchantName(16) or "none")
            .. "  |  " .. (IR.WeaponEnchantName(17) or "none"))
    end)

    -- Everything on the page that follows from which set and which conditional
    -- are selected. validateButtons calls it, so it runs on every load and save.
    function f.RefreshConditionals()
        local def = IR.GetConditional(editor.cond)
        condPicker:setValue(def and def.label or nil)
        condTitle:SetText(def and def.label or "No conditional selected")
        condDesc:SetText(def and def.desc or "")

        local setname = currentName()
        local set     = DB().sets[setname]
        local saved   = set and set.conditionals and set.conditionals[editor.cond]

        local count = 0
        for _ in pairs(saved or {}) do count = count + 1 end
        if not set then
            condCount:SetText("Save the set on the Set Editor tab first.")
            UI.tint(condCount, C.textDim)
        elseif count == 0 then
            condCount:SetText("\"" .. setname .. "\" swaps nothing for this conditional yet.")
            UI.tint(condCount, C.textDim)
        else
            condCount:SetText("\"" .. setname .. "\" swaps " .. count
                .. (count == 1 and " slot" or " slots") .. " while this holds.")
            UI.tint(condCount, C.textWhite)
        end

        setButtonEnabled(condSaveBtn, (set and def) and true or false)
        setButtonEnabled(condClearBtn, (saved and next(saved)) and true or false)
        -- Forces the readout rather than leaving the last conditional's answer up
        -- until the next tick.
        condPanel.throttle = 1
    end

    -- ── Key binding capture ──────────────────────────────────────────────────
    -- The next key pressed while this overlay is up becomes the set's hotkey.
    local bindOverlay = CreateFrame("Frame", nil, f, "BackdropTemplate")
    bindOverlay:SetAllPoints(center)
    bindOverlay:SetFrameStrata("DIALOG")
    bindOverlay:EnableKeyboard(true)
    bindOverlay:EnableMouse(true)
    bindOverlay:SetPropagateKeyboardInput(false)
    applyBackdrop(bindOverlay, 1, { 0.055, 0.062, 0.115, 0.95 }, C.red)
    bindOverlay:Hide()

    local bindText = bindOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    bindText:SetPoint("CENTER")
    bindText:SetWidth(CENTER_W - 20)
    bindText:SetJustifyH("CENTER")
    bindText:SetText("Press a key to bind this set.\n\nEscape cancels. Delete clears the binding.")

    bindOverlay:SetScript("OnKeyDown", function(self, key)
        if IR.IsModifierKey(key) then return end
        self:Hide()
        local setname = currentName()
        local set = DB().sets[setname]
        if not set or key == "ESCAPE" then return end
        if key == "DELETE" or key == "BACKSPACE" then
            set.key = nil
            -- Has to run even with nothing left bound, or the binding we already
            -- handed the client stays live after the set stops claiming it.
            IR.SetSetBindings()
            validateButtons()
            sideList:Refresh()
            IR.Print("Cleared the key binding for \"" .. setname .. "\".")
            return
        end

        key = IR.ChordFromKey(key)
        if set.key == key then return end

        IR.ConfirmBinding(key, "the set \"" .. setname .. "\"", nil, function()
            -- Re-read: the set could have been deleted or renamed under the
            -- dialog, which is modal to nothing at all.
            local target = DB().sets[setname]
            if not target then return end
            target.key = key
            IR.SetSetBindings()
            validateButtons()
            sideList:Refresh()
            IR.Print("Bound \"" .. setname .. "\" to " .. GetBindingText(key, nil, false) .. ".")
        end)
    end)

    bind:SetScript("OnClick", function()
        if not DB().sets[currentName()] then return end
        -- Anything else listening for the same keypress is one thing too many.
        IR.StopSlotBindMode()
        IR.StopSetBindMode()
        bindOverlay:Show()
    end)

    -- ── Tab switching ────────────────────────────────────────────────────────
    -- Only the middle of the window belongs to a tab. The set picker, the slot
    -- columns and the set list are the editing surface for both, and stay put —
    -- what changes is what the ticked slots mean, which is `editor.cond`.
    --
    -- The pieces are parented straight to the window rather than to a page frame
    -- of their own, so each page is a list of them. activateTab only ever asks a
    -- page for Show/Hide, which a list can answer to, and it keeps the tab
    -- styling in one place.
    local createRegions = { bindRow, center }
    local condRegions   = { condRow, condPanel }

    local function showRegions(list, shown)
        for _, region in ipairs(list) do region:SetShown(shown) end
    end

    local function showCreatePage(shown)
        showRegions(createRegions, shown)
        if shown then
            editor.cond = nil
            reloadEditor()
        else
            -- The overlay binds the loaded set's key, which is this page's
            -- business; the item menu hangs off the slot buttons it was opened
            -- from, and neither should outlive the tab.
            bindOverlay:Hide()
            IR.StopSlotBindMode()
            IR.HideMenu()
        end
    end

    local function showCondPage(shown)
        showRegions(condRegions, shown)
        if shown then
            -- Lands on something the moment the tab opens: a page whose dropdown
            -- reads "select a conditional" before anything can be edited is a
            -- click nobody needs to make.
            editor.cond = editor.cond or (IR.Conditionals[1] and IR.Conditionals[1].key)
            reloadEditor()
        else
            IR.HideMenu()
        end
    end

    local tabs  = { create = createTabBtn, conditionals = condTabBtn }
    local pages = {
        create       = { Show = function() showCreatePage(true)  end,
                         Hide = function() showCreatePage(false) end },
        conditionals = { Show = function() showCondPage(true)  end,
                         Hide = function() showCondPage(false) end },
    }

    local function selectPage(key)
        f.activeTab = key
        activateTab(tabs, pages, key)
        validateButtons()
    end
    createTabBtn:SetScript("OnClick", function() selectPage("create")       end)
    condTabBtn:SetScript("OnClick",   function() selectPage("conditionals") end)

    f:SetScript("OnShow", function()
        editor.iconSearch = ""
        editor.iconOffset = 0
        searchBox:SetText("")
        applySideList(getData().setListOpen ~= false)
        -- Before the load below: it decides whether that load reads the set's own
        -- gear or a conditional's overrides.
        selectPage(f.activeTab or "create")
        populateInitialIcons()
        editor.selectedIcon = editor.selectedIcon or IR.DEFAULT_SET_ICON
        lock:SetChecked(getData().locked and true or false)
        local db = DB()
        loadSet((db.currentSet and db.sets[db.currentSet]) and db.currentSet or nil)
    end)
    -- Slot binding is started from this window, so it ends with it: a prompt
    -- that owns the keyboard has no business outliving the thing that opened it.
    f:SetScript("OnHide", function()
        IR.HideMenu()
        IR.StopSlotBindMode()
        IR.StopSetBindMode()
    end)

    return f
end

function IR.ToggleSetEditor()
    if not IR.RequireEnabled() then return end
    local f = frame or buildFrame()
    if f:IsShown() then f:Hide() else f:Show() end
end

function IR.ShowSetEditor()
    if not IR.RequireEnabled() then return end
    local f = frame or buildFrame()
    f:Show()
end

-- Only touches the frame if it was ever built, so switching the module off on a
-- character that never opened the editor doesn't construct it just to hide it.
function IR.HideSetEditor()
    if frame then frame:Hide() end
end
