-- Trinkets module: settings UI. Loads only alongside core (## Dependencies), so
-- the shared namespace always exists.
local addon = _G.DrievEssentials
if not addon then return end

local UI = addon.UI

-- Bind core's shared widget toolkit to locals so the panel code below reads
-- exactly as it did when it lived inside core's UI.lua.
local C     = UI.colors
local WHITE = UI.WHITE
local W     = UI.widgets

local applyBackdrop        = W.applyBackdrop
local buildFontOptions     = W.buildFontOptions
local createCheckbox       = W.createCheckbox
local createDropdown       = W.createDropdown
local createTab            = W.createTab
local createSideTab        = W.createSideTab
local activateTab          = W.activateTab
local selectSubTab         = W.selectSubTab
local makeScrollPanel      = W.makeScrollPanel
local attachScrollTrack    = W.attachScrollTrack
local fitInnerHeight       = W.fitInnerHeight
local buildStepper         = W.buildStepper
local flatButton           = W.flatButton
local SCROLLBAR_W          = W.scrollbarWidth

-- Settings this module owns. Registered into core's defaults at load time and
-- merged into the active profile at PLAYER_LOGIN, so disabling this addon
-- simply leaves the (harmless) saved values untouched.
addon.RegisterDefaults("trinkets", {
    enabled          = false,
    showCooldowns    = true,
    showTooltips     = true,
    tinyTooltips     = false,
    keepOpen         = false,
    notify           = false,
    alwaysShow       = false,
    menuDocked       = true,
    menuDockCorner   = "below-left",
    menuPerLine      = 4,
    menuOrientation  = "horizontal",
    menuAlign        = "left",
    menuScale        = 1.0,
    showBindings     = true,
    truncateBindings = true,
    -- Keybind text, as core's shared font block (Font.lua): face, size, outline,
    -- offset from the button's top-right corner, and drop shadow. The defaults
    -- are what this drew when it was hardcoded, and match the Action Bars and
    -- Item Rack keybind text so the three read as one UI.
    bindingFont      = addon.Font.New({ font = "Friz Quadrata TT", size = 10, x = -2, y = -2 }),
    swapDelay        = 1.0,
    menuOrder        = {},
    hidden           = {},
    menuEdgePad      = 0,
    menuButtonGap    = 6,
    displayEdgePad   = 0,
    displayButtonGap = 2,
    displayScale     = 1.0,
    menuOrderEnabled = false,
    reverseClickSlots = false, -- swap left/right click targets: left = bottom slot, right = top slot
    elvuiSkinEnabled  = true,  -- auto-skin the Display/Bag Menu buttons when ElvUI/ShadowElvUI is loaded
    blockModCtrl     = false,
    blockModAlt      = false,
    blockModShift    = false,
    swapWatchdog     = true,
    softQueueMod     = "shift", -- "shift"/"ctrl"/"none": modifier+click a trinket to soft-queue
    swapMod          = "ctrl",  -- "shift"/"ctrl"/"none": modifier+click a worn trinket to swap top/bottom slots
    modKeybindActions = false,  -- off: the two modifier actions need a real mouse click, not the keybind
    encounters       = {},   -- [encounterID] = { enabled, trigger, mainTop, mainBottom, softTop, softBottom }
    debugEncounters  = false, -- gate for the Stockades (debug raid) test encounters
    encQueueDelayEnabled = true, -- Specific Auto Queue safeguard delay toggle
    encQueueDelaySeconds = 5.0,  -- required continuous encounter+combat duration before queuing
})

-- Makes the block above pickable on its own in the Profiles tab's export,
-- import and copy dialogs.
if addon.RegisterProfileSection then
    addon.RegisterProfileSection({ key = "trinkets", label = "Trinkets", order = 40,
        settings = { "trinkets" } })
end

-- Keybind text, as core's shared font block. Matches the engine's defaults
-- (Trinkets.lua) so the panel shows what a button actually draws.
local BIND_FONT_DEFAULT = addon.Font.New({
    font = "Friz Quadrata TT", size = 10, x = -2, y = -2,
})

-- ── Trinkets tab ──────────────────────────────────────────────────────────────
-- The two reorderable lists here — the bag menu's display order and each queue
-- slot's sort order — are the same widget: a scrollable column of
-- drag-to-reorder rows with a custom scrollbar and a strip of move buttons. Only
-- the rows' source and the buttons' actions differ.
local LIST_W, LIST_H, ROW_H, SB_W = 310, 240, 26, 10
local VIS_ROWS = math.floor(LIST_H / ROW_H)

-- The row pool is index-fixed and re-skinned on each rebuild, so the dragged
-- ITEM is tracked by value (ctx.dragId), not by frame: as the cursor crosses
-- slots the backing list is live-reordered, so the row under the cursor always
-- shows the dragged item.
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
    local maxScroll = math.max(0, (#list - VIS_ROWS) * ROW_H)
    if sfTop and cursorY > sfTop - 4 then
        p.sf:SetVerticalScroll(math.max(0, p.sf:GetVerticalScroll() - 6)); p.updateThumb()
    elseif sfBottom and cursorY < sfBottom + 4 then
        p.sf:SetVerticalScroll(math.min(maxScroll, p.sf:GetVerticalScroll() + 6)); p.updateThumb()
    end

    local top = p.sc:GetTop()
    if not top then return end
    local targetIdx = math.max(1, math.min(#list, math.floor((top - cursorY) / ROW_H) + 1))
    if targetIdx ~= curIdx then
        table.remove(list, curIdx)
        table.insert(list, targetIdx, ctx.dragId)
        p.rebuildRows()
        p.selectRow(targetIdx)
    end
end

-- Viewport, scroll child, and a hand-built scrollbar (Blizzard's templates don't
-- match this addon's chrome). `rows` is the caller's pool, which the scrollbar
-- sizes itself from. Returns the pieces the caller still needs.
local function makeListBox(container, anchorTo, rows)
    local listBG = CreateFrame("Frame", nil, container, "BackdropTemplate")
    listBG:SetSize(LIST_W, LIST_H)
    listBG:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -10)
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

    local function maxScroll()
        return math.max(0, (#rows - VIS_ROWS) * ROW_H)
    end

    local function updateThumb()
        local n = #rows
        if n <= VIS_ROWS then track:Hide(); return end
        track:Show()
        local tH = track:GetHeight()
        if tH <= 0 then return end
        local thumbH = math.max(16, tH * VIS_ROWS / n)
        local top    = maxScroll() > 0 and (sf:GetVerticalScroll() / maxScroll()) or 0
        thumb:SetHeight(thumbH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 1, -(top * (tH - thumbH)))
    end

    listBG:EnableMouseWheel(true)
    listBG:SetScript("OnMouseWheel", function(_, delta)
        sf:SetVerticalScroll(math.max(0,
            math.min(sf:GetVerticalScroll() - delta * ROW_H * 2, maxScroll())))
        updateThumb()
    end)

    -- Click-drag on the thumb; without these it would be a position indicator
    -- only, leaving the mouse wheel as the sole way to scroll.
    local dragging, startY, startScroll = false, 0, 0
    thumb:EnableMouse(true)
    thumb:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        dragging    = true
        startY      = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
        startScroll = sf:GetVerticalScroll()
    end)
    thumb:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then dragging = false end
    end)
    thumb:SetScript("OnUpdate", function()
        if not dragging then return end
        local tH, thumbH = track:GetHeight(), thumb:GetHeight()
        if tH <= thumbH or maxScroll() <= 0 then return end
        local curY  = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
        local delta = startY - curY
        sf:SetVerticalScroll(math.max(0,
            math.min(startScroll + delta * maxScroll() / (tH - thumbH), maxScroll())))
        updateThumb()
    end)
    thumb:SetScript("OnEnter", function(self) UI.tintBg(self, C.tabHover) end)
    thumb:SetScript("OnLeave", function(self) UI.tintBg(self, C.tabIdle)  end)

    return listBG, sf, sc, updateThumb
end

-- One of the Top/Up/Down/... buttons stacked down the right of a list box.
local function makeListButton(container, listBG, label, y)
    local b = CreateFrame("Button", nil, container, "BackdropTemplate")
    b:SetSize(72, 22)
    b:SetPoint("TOPLEFT", listBG, "TOPRIGHT", 6, -y)
    applyBackdrop(b, 1, C.panelDark, C.tabBorder)
    local lbl = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("CENTER"); lbl:SetText(label); UI.tint(lbl, C.textWhite)
    b:SetScript("OnEnter", function() UI.tintBorder(b, C.red) end)
    b:SetScript("OnLeave", function() UI.tintBorder(b, C.tabBorder) end)
    return b
end

-- One pooled, drag-to-reorder row at a fixed slot `i`.
-- ctx = { selectRow(i), isSelected(i), drag = <attachRowDrag ctx> }.
local function makeListRow(sc, i, ctx)
    local row = CreateFrame("Button", nil, sc, "BackdropTemplate")
    row:SetSize(LIST_W - SB_W - 5, ROW_H - 2)
    row:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -(i - 1) * ROW_H)
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
    UI.tint(lbl, C.textWhite)
    row.lbl = lbl

    row:SetScript("OnClick", function() ctx.selectRow(i) end)
    -- Hover only paints rows that aren't selected: the selected row already
    -- wears the red border, and re-tinting it on hover would drop that.
    row:SetScript("OnEnter", function(self)
        if not ctx.isSelected(i) then UI.tintBorder(self, C.tabBorder) end
    end)
    row:SetScript("OnLeave", function(self)
        if not ctx.isSelected(i) then self:SetBackdropBorderColor(0, 0, 0, 0) end
    end)
    attachRowDrag(row, i, ctx.drag)
    return row
end

-- Point the pooled rows at the current contents of `list`, hiding the surplus.
local function fillListRows(rows, list, sc)
    local n = #list
    for i = 1, #rows do
        local row = rows[i]
        if i <= n then
            local id = list[i]
            local name, _, _, _, _, _, _, _, _, tex = GetItemInfo(tonumber(id) or id)
            row.ico:SetTexture(tex or "")
            row.lbl:SetText(i .. ". " .. (name or ("[" .. id .. "]")))
            row:Show()
        else
            row:Hide()
        end
    end
    sc:SetHeight(math.max(n * ROW_H, 1))
end

-- The full-width "rescan my bags" strip under a list.
local function makeRefreshButton(container, anchorTo, onClick)
    local b = CreateFrame("Button", nil, container, "BackdropTemplate")
    b:SetSize(LIST_W, 22)
    b:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -8)
    applyBackdrop(b, 1, C.panelDark, C.tabBorder)
    local lbl = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("CENTER")
    lbl:SetText("Refresh (scan bags for new trinkets)")
    UI.tint(lbl, C.textWhite)
    b:SetScript("OnEnter", function() UI.tintBorder(b, C.red) end)
    b:SetScript("OnLeave", function() UI.tintBorder(b, C.tabBorder) end)
    b:SetScript("OnClick", onClick)
    return b
end

local function buildMenuOrderList(parent)
    -- Reorderable list of ALL known trinket IDs stored in d.menuOrder.
    -- Controls the display order in the bag menu.
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(LIST_W + SB_W + 4 + 80, LIST_H + 60)

    local header = container:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetText("Menu Display Order")
    UI.tint(header, C.red)

    local desc = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    desc:SetText("Drag items to reorder. New trinkets are added automatically when scanned.")
    UI.tint(desc, C.textGrey)

    local rows     = {}
    local selected = nil
    local dragCtx  = {}   -- populated after rebuildRows/selectRow exist

    local listBG, sf, sc, updateThumb = makeListBox(container, desc, rows)

    local function getData()
        return addon.Trinkets and addon.Trinkets.getData and addon.Trinkets.getData()
    end

    local function getList()
        local d = getData()
        return d and d.menuOrder or {}
    end

    local btnTop     = makeListButton(container, listBG, "Top",     4)
    local btnUp      = makeListButton(container, listBG, "Up",      30)
    local btnDown    = makeListButton(container, listBG, "Down",    56)
    local btnBottom  = makeListButton(container, listBG, "Bottom",  82)
    local btnRemove  = makeListButton(container, listBG, "Remove",  112)
    local btnReverse = makeListButton(container, listBG, "Reverse", 142)

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

    local rowCtx = {
        selectRow  = selectRow,
        isSelected = function(i) return getList()[i] == selected end,
        drag       = dragCtx,
    }

    local function rebuildRows()
        local list = getList()
        while #rows < #list do
            local i = #rows + 1
            rows[i] = makeListRow(sc, i, rowCtx)
        end
        fillListRows(rows, list, sc)
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
            updateThumb = updateThumb, sf = sf, sc = sc,
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

    makeRefreshButton(container, listBG, function()
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
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(LIST_W + SB_W + 4 + 80, LIST_H + 30)  -- extra for buttons

    local header = container:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetText(which == 0 and "Top Slot Queue" or "Bottom Slot Queue")
    UI.tint(header, C.red)

    local enableCB = createCheckbox(container, "Enable Auto Queue", 200)
    enableCB:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6)
    enableCB.OnChange = function(_, checked)
        local d = addon.Trinkets and addon.Trinkets.getData and addon.Trinkets.getData()
        if d then d.queue[which].enabled = checked end
        if addon.Trinkets and addon.Trinkets.updateQueueIndicators then
            addon.Trinkets.updateQueueIndicators()
        end
    end

    local rows     = {}
    local selected = nil
    local dragCtx  = {}   -- populated after rebuildRows/selectRow exist

    local listBG, sf, sc, updateThumb = makeListBox(container, enableCB, rows)

    local btnTop    = makeListButton(container, listBG, "Top",    4)
    local btnUp     = makeListButton(container, listBG, "Up",     30)
    local btnDown   = makeListButton(container, listBG, "Down",   56)
    local btnBottom = makeListButton(container, listBG, "Bottom", 82)

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

    local rowCtx = {
        selectRow  = selectRow,
        isSelected = function(i) return getList()[i] == selected end,
        drag       = dragCtx,
    }

    local function rebuildRows()
        local list = getList()
        while #rows < #list do
            local i = #rows + 1
            rows[i] = makeListRow(sc, i, rowCtx)
        end
        fillListRows(rows, list, sc)
        updateThumb()
    end

    -- Wire up drag-to-reorder (rows call attachRowDrag with this ctx).
    dragCtx.getList    = getList
    dragCtx.selectRow  = selectRow
    dragCtx.dragUpdate = function()
        runRowDrag(dragCtx, {
            getList = getList, selectRow = selectRow, rebuildRows = rebuildRows,
            updateThumb = updateThumb, sf = sf, sc = sc,
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

    makeRefreshButton(container, priorityCB, function()
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

-- Every trinket the player has been seen carrying, resolved to { id, name,
-- texture }. Ids whose item data isn't cached yet are skipped, and reappear once
-- GetItemInfo resolves them.
local function registeredTrinkets(d)
    local out = {}
    for _, id in ipairs(d and d.menuOrder or {}) do
        local name, _, _, _, _, _, _, _, _, tex = GetItemInfo(tonumber(id) or id)
        if name then out[#out + 1] = { id = id, name = name, texture = tex } end
    end
    return out
end

-- One shared popup reused by EVERY trinket dropdown: a full backdropped menu +
-- scrollbar per dropdown (~190 across the grid) was enough frames to trip the
-- "script ran too long" watchdog. Each dropdown is now a light button.
local trinketPicker
local function getTrinketPicker()
    if trinketPicker then return trinketPicker end
    local ROW, MAX_VIS, SBW = 22, 8, 10
    local active                     -- ctx of the dropdown currently open (or nil)
    local nOpts, scrollOff = 0, 0
    local itemPool = {}

    local catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("DIALOG")
    catcher:Hide()

    local menu = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    menu:SetFrameStrata("DIALOG")
    menu:SetFrameLevel(catcher:GetFrameLevel() + 10)
    applyBackdrop(menu, 1, C.panelBG, C.tabBorder)
    menu:EnableMouseWheel(true)
    menu:Hide()

    local mtrack = CreateFrame("Frame", nil, menu, "BackdropTemplate")
    mtrack:SetWidth(SBW)
    mtrack:SetPoint("TOPRIGHT",    menu, "TOPRIGHT",    -1, -1)
    mtrack:SetPoint("BOTTOMRIGHT", menu, "BOTTOMRIGHT", -1,  1)
    applyBackdrop(mtrack, 1, C.panelDark, C.tabBorder)
    local mthumb = CreateFrame("Button", nil, mtrack, "BackdropTemplate")
    mthumb:SetWidth(SBW - 2)
    applyBackdrop(mthumb, 1, C.tabIdle, C.tabBorder)
    mthumb:SetPoint("TOPLEFT", mtrack, "TOPLEFT", 1, 0)
    mtrack:Hide()

    local function close() menu:Hide(); catcher:Hide(); active = nil end

    local function layoutItems()
        local visN   = math.min(nOpts, MAX_VIS)
        local maxOff = math.max(0, nOpts - MAX_VIS)
        scrollOff = math.max(0, math.min(scrollOff, maxOff))
        local scrolled = nOpts > MAX_VIS
        local rightPad = scrolled and (SBW + 1) or 1
        for i, item in ipairs(itemPool) do
            local pos = i - 1 - scrollOff   -- 0-based row within the visible window
            if i <= nOpts and pos >= 0 and pos < MAX_VIS then
                item:ClearAllPoints()
                item:SetPoint("TOPLEFT", menu, "TOPLEFT", 1, -1 - pos * ROW)
                item:SetPoint("RIGHT",   menu, "RIGHT", -rightPad, 0)
                item:Show()
            else
                item:Hide()
            end
        end
        menu:SetHeight(visN * ROW + 2)
        if scrolled then
            mtrack:Show()
            local trackH = visN * ROW
            local thumbH = math.max(16, trackH * MAX_VIS / nOpts)
            local frac   = maxOff > 0 and (scrollOff / maxOff) or 0
            mthumb:SetHeight(thumbH)
            mthumb:ClearAllPoints()
            mthumb:SetPoint("TOPLEFT", mtrack, "TOPLEFT", 1, -(frac * (trackH - thumbH)))
        else
            mtrack:Hide()
        end
    end

    local function rebuildItems()
        local opts = { { id = nil, name = "None" } }
        for _, t in ipairs(active.list()) do opts[#opts + 1] = t end
        nOpts, scrollOff = #opts, 0
        while #itemPool < #opts do
            local i = #itemPool + 1
            local item = CreateFrame("Button", nil, menu, "BackdropTemplate")
            item:SetHeight(ROW)
            applyBackdrop(item, 1, C.panelDark, { 0, 0, 0, 0 })
            local iico = item:CreateTexture(nil, "ARTWORK")
            iico:SetSize(16, 16); iico:SetPoint("LEFT", 3, 0)
            iico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            local il = item:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            il:SetPoint("LEFT", iico, "RIGHT", 3, 0); il:SetPoint("RIGHT", -3, 0)
            il:SetJustifyH("LEFT"); UI.tint(il, C.textWhite)
            item.ico, item.lbl = iico, il
            item:SetScript("OnEnter", function(self) UI.tintBg(self, C.tabHover) end)
            item:SetScript("OnLeave", function(self) UI.tintBg(self, C.panelDark) end)
            itemPool[i] = item
        end
        for i, item in ipairs(itemPool) do
            local o = opts[i]
            if o then
                if o.id then item.ico:SetTexture(o.texture or ""); item.ico:Show()
                else item.ico:SetTexture(""); item.ico:Hide() end
                item.lbl:SetText(o.name)
                item:SetScript("OnClick", function()
                    if active then active.setVal(o.id); active.refresh() end
                    close()
                end)
            end
        end
        layoutItems()
    end

    menu:SetScript("OnMouseWheel", function(_, delta)
        scrollOff = scrollOff - delta
        layoutItems()
    end)

    local mDragging, mStartY, mStartOff = false, 0, 0
    mthumb:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        mDragging = true
        mStartY   = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
        mStartOff = scrollOff
    end)
    mthumb:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then mDragging = false end
    end)
    mthumb:SetScript("OnUpdate", function()
        if not mDragging then return end
        local trackH = math.min(nOpts, MAX_VIS) * ROW
        local thumbH = mthumb:GetHeight()
        local maxOff = math.max(0, nOpts - MAX_VIS)
        if trackH > thumbH and maxOff > 0 then
            local curY  = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
            local delta = mStartY - curY
            scrollOff = math.floor(mStartOff + delta * maxOff / (trackH - thumbH) + 0.5)
            layoutItems()
        end
    end)
    mthumb:SetScript("OnEnter", function(self) UI.tintBg(self, C.tabHover) end)
    mthumb:SetScript("OnLeave", function(self) UI.tintBg(self, C.tabIdle)  end)
    catcher:SetScript("OnClick", close)

    trinketPicker = {
        active = function() return active end,
        close  = close,
        openFor = function(ctx)
            active = ctx
            menu:ClearAllPoints()
            menu:SetPoint("TOPLEFT",  ctx.dd, "BOTTOMLEFT",  0, -2)
            menu:SetPoint("TOPRIGHT", ctx.dd, "BOTTOMRIGHT", 0, -2)
            rebuildItems()
            menu:Show(); catcher:Show()
        end,
    }
    return trinketPicker
end

-- A dropdown over the live registered-trinket list (rebuilt on each open, so new
-- trinkets appear without a reload) plus "None". The popup is the shared
-- getTrinketPicker() — this is just the button.
local function createTrinketDropdown(parent, width, getVal, setVal, listProvider)
    local dd = CreateFrame("Button", nil, parent, "BackdropTemplate")
    dd:SetSize(width, 22)
    applyBackdrop(dd, 1, C.panelDark, C.tabBorder)

    local ico = dd:CreateTexture(nil, "ARTWORK")
    ico:SetSize(16, 16)
    ico:SetPoint("LEFT", 3, 0)
    ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local text = dd:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", ico, "RIGHT", 3, 0)
    text:SetPoint("RIGHT", -14, 0)
    text:SetJustifyH("LEFT")
    UI.tint(text, C.textWhite)

    local arrow = dd:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
    arrow:SetSize(14, 14)
    arrow:SetPoint("RIGHT", -2, -1)

    local function refresh()
        local id = getVal()
        if id then
            local name, _, _, _, _, _, _, _, _, tex = GetItemInfo(tonumber(id) or id)
            ico:SetTexture(tex or ""); ico:Show()
            text:SetText(name or ("[" .. id .. "]"))
        else
            ico:SetTexture(""); ico:Hide()
            text:SetText("None")
        end
    end

    local ctx = { dd = dd, setVal = setVal, refresh = refresh, list = listProvider }

    dd:SetScript("OnClick", function()
        local p = getTrinketPicker()
        if p.active() == ctx then p.close() else p.openFor(ctx) end
    end)
    dd:SetScript("OnEnter", function() UI.tintBorder(dd, C.red) end)
    dd:SetScript("OnLeave", function() UI.tintBorder(dd, C.tabBorder) end)
    dd:SetScript("OnHide", function()
        if trinketPicker and trinketPicker.active() == ctx then trinketPicker.close() end
    end)

    dd.Refresh = refresh
    refresh()
    return dd
end

-- What the Trigger control is for at all, as opposed to what one option does.
-- Carried by the dropdown button only — repeating it on all four option rows
-- would bury the per-option text it's meant to introduce.
local TRIGGER_OVERVIEW =
    "Trigger decides when a ticked boss's trinkets queue. The default is Boss at 75%; In Combat (encounter + combat, plus the safeguard delay at the top of this tab), Encounter Start and Encounter End are the alternatives. Whenever it fires, the Main trinkets swap in first; the Soft trinkets follow once the Main trinket has been used and its effect has expired."

-- Hover help for one trigger option, from the paragraphs Trinkets.lua stores
-- alongside the behaviour. Shown by both the picker rows and the dropdown
-- button, so what a boss is set to can be read without opening the list.
local function triggerTooltip(owner, o, withOverview)
    if not o then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine(o.label, 1, 1, 1)
    for _, para in ipairs(o.desc or {}) do
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(para, 0.75, 0.75, 0.75, true)
    end
    if withOverview then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(TRIGGER_OVERVIEW, 0.75, 0.75, 0.75, true)
    end
    GameTooltip:Show()
end

-- One shared popup for every per-boss trigger dropdown, for the same reason as
-- getTrinketPicker. The option set is short, so this needs no scrollbar — just a
-- flip upwards when there's no room below.
local triggerPicker
local function getTriggerPicker()
    if triggerPicker then return triggerPicker end
    local ROW  = 22
    local opts = addon.TRINKET_ENC_TRIGGERS or {}
    local active                     -- ctx of the dropdown currently open (or nil)

    local catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("DIALOG")
    catcher:Hide()

    local menu = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    menu:SetFrameStrata("DIALOG")
    menu:SetFrameLevel(catcher:GetFrameLevel() + 10)
    menu:SetHeight(#opts * ROW + 2)
    applyBackdrop(menu, 1, C.panelBG, C.tabBorder)
    menu:Hide()

    local function close() menu:Hide(); catcher:Hide(); active = nil end

    for i, o in ipairs(opts) do
        local item = CreateFrame("Button", nil, menu, "BackdropTemplate")
        item:SetHeight(ROW)
        item:SetPoint("TOPLEFT", menu, "TOPLEFT",  1, -1 - (i - 1) * ROW)
        item:SetPoint("RIGHT",   menu, "RIGHT",   -1, 0)
        applyBackdrop(item, 1, C.panelDark, { 0, 0, 0, 0 })
        local il = item:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        il:SetPoint("LEFT", 6, 0); il:SetPoint("RIGHT", -6, 0)
        il:SetJustifyH("LEFT"); il:SetText(o.label); UI.tint(il, C.textWhite)
        item:SetScript("OnEnter", function(self)
            UI.tintBg(self, C.tabHover)
            triggerTooltip(self, o)
        end)
        item:SetScript("OnLeave", function(self)
            UI.tintBg(self, C.panelDark)
            GameTooltip:Hide()
        end)
        item:SetScript("OnClick", function()
            if active then active.setVal(o.value); active.refresh() end
            close()
        end)
    end

    catcher:SetScript("OnClick", close)

    triggerPicker = {
        active = function() return active end,
        close  = close,
        openFor = function(ctx)
            active = ctx
            menu:ClearAllPoints()
            -- Boss rows near the bottom of the scroll panel would drop the menu
            -- off the screen edge; open upwards from those instead.
            if (ctx.dd:GetBottom() or 0) - menu:GetHeight() < 0 then
                menu:SetPoint("BOTTOMLEFT",  ctx.dd, "TOPLEFT",  0, 2)
                menu:SetPoint("BOTTOMRIGHT", ctx.dd, "TOPRIGHT", 0, 2)
            else
                menu:SetPoint("TOPLEFT",  ctx.dd, "BOTTOMLEFT",  0, -2)
                menu:SetPoint("TOPRIGHT", ctx.dd, "BOTTOMRIGHT", 0, -2)
            end
            menu:Show(); catcher:Show()
        end,
    }
    return triggerPicker
end

-- A dropdown over addon.TRINKET_ENC_TRIGGERS. Trinkets.lua owns both the list
-- and the behaviour; this only reads/writes the stored string (nil = "combat").
local function createTriggerDropdown(parent, width, getVal, setVal)
    local dd = CreateFrame("Button", nil, parent, "BackdropTemplate")
    dd:SetSize(width, 22)
    applyBackdrop(dd, 1, C.panelDark, C.tabBorder)

    local text = dd:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", 6, 0)
    text:SetPoint("RIGHT", -16, 0)
    text:SetJustifyH("LEFT")
    UI.tint(text, C.textWhite)

    local arrow = dd:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
    arrow:SetSize(14, 14)
    arrow:SetPoint("RIGHT", -2, -1)

    local current   -- the option table currently shown, kept for the hover help
    local function refresh()
        local v = getVal() or addon.TRINKET_ENC_TRIGGER_DEFAULT
        current = nil
        for _, o in ipairs(addon.TRINKET_ENC_TRIGGERS or {}) do
            if o.value == v then current = o; break end
        end
        text:SetText(current and current.label or v)
    end

    local ctx = { dd = dd, setVal = setVal, refresh = refresh }

    dd:SetScript("OnClick", function()
        local p = getTriggerPicker()
        if p.active() == ctx then p.close() else p.openFor(ctx) end
    end)
    dd:SetScript("OnEnter", function()
        UI.tintBorder(dd, C.red)
        triggerTooltip(dd, current, true)
    end)
    dd:SetScript("OnLeave", function()
        UI.tintBorder(dd, C.tabBorder)
        GameTooltip:Hide()
    end)
    dd:SetScript("OnHide", function()
        if triggerPicker and triggerPicker.active() == ctx then triggerPicker.close() end
    end)

    dd.Refresh = refresh
    refresh()
    return dd
end

-- "Specific Auto Queue" sub-tab: a fixed header (the safeguard delay) over a
-- left sidebar of raids, with the selected raid's per-boss config scrolling to
-- its right. Each boss is a checkbox, a 2×2 grid of trinket pickers (rows =
-- Top/Bottom slots, columns = Main/Soft queue) and one Trigger dropdown.
local function buildSpecificAutoQueuePanel(parent, getTData)
    local shell = CreateFrame("Frame", nil, parent)
    shell:SetAllPoints()
    shell:Hide()

    local refreshers = {}

    local function entry(d, id, create)
        if not d then return nil end
        d.encounters = d.encounters or {}
        local e = d.encounters[id]
        if not e and create then e = {}; d.encounters[id] = e end
        return e
    end
    local function prune(d, id)
        local e = d.encounters and d.encounters[id]
        if e and not e.enabled and not e.trigger and not e.mainTop and not e.mainBottom
           and not e.softTop and not e.softBottom then
            d.encounters[id] = nil
        end
    end

    -- ── Safeguard delay (fixed header) ────────────────────────────────────────
    -- Applies to the "In Combat" trigger only — the one whose two conditions can
    -- line up the instant a pull starts. It requires them to hold TRUE CONTINUOUSLY
    -- for its duration; any combat drop restarts it. Other triggers fire on a single
    -- moment a delay could only make them miss.
    local delayCB = createCheckbox(shell,
        "Safeguard delay (In Combat trigger): require encounter + combat simultaneously", 520)
    delayCB:SetPoint("TOPLEFT", shell, "TOPLEFT", 14, -12)
    delayCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.encQueueDelayEnabled = checked end
    end

    local delayRow = CreateFrame("Frame", nil, shell)
    delayRow:SetSize(300, 22)
    delayRow:SetPoint("TOPLEFT", delayCB, "BOTTOMLEFT", 20, -6)

    local delayLbl = delayRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    delayLbl:SetPoint("LEFT", 0, 0)
    delayLbl:SetText("Delay:")
    UI.tint(delayLbl, C.textGrey)

    local delayStepper = buildStepper(delayRow, {
        min = 0.1, max = 30, step = 0.5, valueWidth = 34,
        format = function(v) return string.format("%.1f", v) end,
        get = function() local d = getTData(); return (d and d.encQueueDelaySeconds) or 5.0 end,
        set = function(v) local d = getTData(); if d then d.encQueueDelaySeconds = v end end,
    })
    delayStepper:SetPoint("LEFT", delayLbl, "RIGHT", 8, 0)

    local delaySec = delayRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    delaySec:SetPoint("LEFT", delayStepper.plus, "RIGHT", 4, 0)
    delaySec:SetText("s"); UI.tint(delaySec, C.textDim)

    refreshers[#refreshers + 1] = function()
        local d = getTData()
        delayCB:SetChecked(d and d.encQueueDelayEnabled or false)
        delayStepper.Refresh()
    end

    -- ── Raids heading + sidebar / scrollable content ─────────────────────────
    local raidsHdr = shell:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    raidsHdr:SetPoint("TOPLEFT", delayRow, "BOTTOMLEFT", -20, -14)
    raidsHdr:SetText("Raids")
    UI.tint(raidsHdr, C.red)

    -- Sidebar and content box both stretch to the bottom of the non-scrolling
    -- sub-panel, so the content fills the window and its per-raid panel scrolls
    -- inside. The left edge sits flush with the content box to line up with the tab
    -- bar above, so the TOPLEFT (hanging off the Raids header) is pulled back 14px.
    local sideCol = CreateFrame("Frame", nil, shell, "BackdropTemplate")
    sideCol:SetPoint("TOPLEFT", raidsHdr, "BOTTOMLEFT", -14, -8)
    sideCol:SetPoint("BOTTOMLEFT", shell, "BOTTOMLEFT", 0, 10)
    sideCol:SetWidth(120)
    applyBackdrop(sideCol, 1, C.panelDark)

    local sideContent = CreateFrame("Frame", nil, shell, "BackdropTemplate")
    sideContent:SetPoint("TOPLEFT", sideCol, "TOPRIGHT", 6, 0)
    sideContent:SetPoint("BOTTOMRIGHT", shell, "BOTTOMRIGHT", -4, 10)
    applyBackdrop(sideContent, 4, C.panelDeep, C.panelDark)

    -- A scroll viewport filling sideContent for one raid's config. Full-height
    -- scrollbar (not near the window's resize grip), auto-sized via fitInnerHeight.
    -- Returns (rshell, inner): rshell is the toggled unit, inner takes the widgets.
    local function raidScrollPanel()
        local rshell = CreateFrame("Frame", nil, sideContent)
        rshell:SetAllPoints()
        rshell:Hide()

        local scroll = CreateFrame("ScrollFrame", nil, rshell)
        scroll:SetPoint("TOPLEFT", 4, -4)
        scroll:SetPoint("BOTTOMRIGHT", -(SCROLLBAR_W + 6), 4)

        local inner = CreateFrame("Frame", nil, scroll)
        inner:SetSize(1, 1)
        scroll:SetScrollChild(inner)

        local _, update = attachScrollTrack(scroll, rshell)
        local function refresh()
            fitInnerHeight(inner, scroll)
            update()
        end
        scroll:SetScript("OnSizeChanged", function(_, w) inner:SetWidth(w); refresh() end)
        inner:SetScript("OnSizeChanged", update)
        rshell:HookScript("OnShow", function() refresh(); C_Timer.After(0, refresh) end)
        return rshell, inner
    end

    -- Each boss block is two dropdown rows (Top/Bottom slot) × two columns
    -- (Main/Soft queue), plus a full-height Trigger column to their right. cols()
    -- derives the x-offsets from the block origin so headers and dropdowns can't
    -- drift apart.
    local NAME_W, DD_W, LBL_W, TRIG_W = 140, 96, 26, 132
    local SUBROW, BLOCK_H = 24, 56
    local function cols(xOff)
        local nameX = xOff + 22
        local lblX  = nameX + NAME_W + 2
        local mainX = lblX + LBL_W + 4
        local softX = mainX + DD_W + 10
        local trigX = softX + DD_W + 14
        return nameX, lblX, mainX, softX, trigX
    end

    local function buildBossRow(inner, boss, xOff, y)
        local nameX, lblX, mainX, softX, trigX = cols(xOff)

        local cb = createCheckbox(inner, "", 18)
        cb:SetPoint("TOPLEFT", inner, "TOPLEFT", xOff, -y)
        cb.OnChange = function(_, checked)
            local d = getTData(); if not d then return end
            entry(d, boss.id, true).enabled = checked or nil
            prune(d, boss.id)
        end

        local nm = inner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        nm:SetPoint("TOPLEFT", inner, "TOPLEFT", nameX, -(y + 2))
        nm:SetWidth(NAME_W); nm:SetJustifyH("LEFT")
        nm:SetText(boss.name); UI.tint(nm, C.textWhite)

        local function slotLabel(txt, py)
            local l = inner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            l:SetPoint("TOPLEFT", inner, "TOPLEFT", lblX, -(py + 4))
            l:SetText(txt); UI.tint(l, C.textGrey)
        end
        slotLabel("TOP", y)
        slotLabel("BOT", y + SUBROW)

        local list = function() return registeredTrinkets(getTData()) end
        local function fieldDD(field, px, py)
            local dd = createTrinketDropdown(inner, DD_W,
                function() local e = entry(getTData(), boss.id); return e and e[field] end,
                function(id) local d = getTData(); if not d then return end
                    entry(d, boss.id, true)[field] = id; prune(d, boss.id) end,
                list)
            dd:SetPoint("TOPLEFT", inner, "TOPLEFT", px, -py)
            return dd
        end

        local mainTopDD = fieldDD("mainTop",    mainX, y)
        local softTopDD = fieldDD("softTop",    softX, y)
        local mainBotDD = fieldDD("mainBottom", mainX, y + SUBROW)
        local softBotDD = fieldDD("softBottom", softX, y + SUBROW)

        -- One trigger for the whole boss, not per equipment slot, so it sits centred
        -- across the two sub-rows. Picking the default writes nil rather than the
        -- string, so a boss row you set and set back prunes itself away.
        local trigDD = createTriggerDropdown(inner, TRIG_W,
            function() local e = entry(getTData(), boss.id); return e and e.trigger end,
            function(v) local d = getTData(); if not d then return end
                entry(d, boss.id, true).trigger =
                    (v ~= addon.TRINKET_ENC_TRIGGER_DEFAULT) and v or nil
                prune(d, boss.id) end)
        trigDD:SetPoint("TOPLEFT", inner, "TOPLEFT", trigX, -(y + SUBROW / 2))

        refreshers[#refreshers + 1] = function()
            local e = entry(getTData(), boss.id)
            cb:SetChecked(e and e.enabled or false)
            mainTopDD.Refresh(); softTopDD.Refresh()
            mainBotDD.Refresh(); softBotDD.Refresh()
            trigDD.Refresh()
        end
    end

    -- Builds one raid's config into its own scroll panel; returns the rshell for
    -- the sidebar's activateTab. The Stockades ("debug") raid gets an extra
    -- module-enable checkbox above its boss list.
    local function buildRaidSection(raid)
        local rshell, inner = raidScrollPanel()
        local y = 10

        if raid.key == "debug" then
            local dbgEnableCB = createCheckbox(inner,
                "Enable Debug module (The Stockades encounters)", 380,
                "For testing: configure trinkets for The Stockades bosses, then run the dungeon. These only auto-queue while this is ticked.")
            dbgEnableCB:SetPoint("TOPLEFT", inner, "TOPLEFT", 8, -y)
            dbgEnableCB.OnChange = function(_, checked)
                local d = getTData(); if d then d.debugEncounters = checked or nil end
            end
            refreshers[#refreshers + 1] = function()
                local d = getTData()
                dbgEnableCB:SetChecked(d and d.debugEncounters or false)
            end
            y = y + 30
        end

        local _, _, mainX, softX, trigX = cols(8)
        local hMain = inner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hMain:SetPoint("TOPLEFT", inner, "TOPLEFT", mainX, -y)
        hMain:SetText("Main"); UI.tint(hMain, C.red)
        local hSoft = inner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hSoft:SetPoint("TOPLEFT", inner, "TOPLEFT", softX, -y)
        hSoft:SetText("Soft"); UI.tint(hSoft, C.red)
        local hTrig = inner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hTrig:SetPoint("TOPLEFT", inner, "TOPLEFT", trigX, -y)
        hTrig:SetText("Trigger"); UI.tint(hTrig, C.red)
        y = y + 22

        for _, boss in ipairs(raid.bosses) do
            buildBossRow(inner, boss, 8, y)
            y = y + BLOCK_H
        end

        return rshell
    end

    -- ── Raid sidebar + panels ────────────────────────────────────────────────
    local function runRefreshers()
        for _, fn in ipairs(refreshers) do fn() end
    end

    local raidTabs, raidPanels = {}, {}
    local prevSb, firstKey
    for _, raid in ipairs(addon.RAIDS or {}) do
        local key = raid.key
        -- Deferred to the first click on this raid: building all of them is ~60 bosses ×
        -- five widgets, which tripped the "script ran too long" watchdog. A section
        -- created after the panel's OnShow already ran needs its refreshers fired by
        -- hand, or its boxes come up blank.
        raidPanels[key] = function()
            local section = buildRaidSection(raid)
            runRefreshers()
            return section
        end

        local b = createSideTab(sideCol, raid.label, 24)
        b.text:SetFontObject("GameFontNormalSmall")   -- matches every other inner sidebar list
        if prevSb then
            b:SetPoint("TOPLEFT",  prevSb, "BOTTOMLEFT",  0, -2)
            b:SetPoint("TOPRIGHT", prevSb, "BOTTOMRIGHT", 0, -2)
        else
            b:SetPoint("TOPLEFT",  sideCol, "TOPLEFT",   3, -3)
            b:SetPoint("TOPRIGHT", sideCol, "TOPRIGHT", -3, -3)
            firstKey = key
        end
        b:SetScript("OnClick", function() activateTab(raidTabs, raidPanels, key) end)
        raidTabs[key] = b
        prevSb = b
    end
    if firstKey then activateTab(raidTabs, raidPanels, firstKey) end

    -- Refresh on every open of the sub-tab. Hook `shell` (what selectSubTab
    -- actually toggles), not the raid panels — those are shown at build time and
    -- don't re-fire their own OnShow when the parent re-opens.
    shell:HookScript("OnShow", runRefreshers)

    return shell
end

local function buildTrinketsPanel(parent)
    local panel, _, subContent, addSubTab = W.makeSubTabPanel(parent, { hidden = true })

    -- ── Display sub-panel ────────────────────────────────────────────────────
    -- Not scrollable at this level: the fixed header sits at the top and the
    -- Settings box below stretches to fill the rest, with all scrolling handled
    -- inside each section's own scroll area (see scrollArea below).
    local displayShell = CreateFrame("Frame", nil, subContent)
    displayShell:SetAllPoints()
    displayShell:Hide()

    local displayPanel = CreateFrame("Frame", nil, displayShell)
    displayPanel:SetAllPoints()

    local function getTData()
        return addon.db and addon.db.settings and addon.db.settings.trinkets
    end

    -- ── Header ────────────────────────────────────────────────────────────────
    local dispHeader = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    dispHeader:SetPoint("TOPLEFT", 14, -14)
    dispHeader:SetText("Trinket Menu")
    UI.tint(dispHeader, C.red)

    local dispDesc = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dispDesc:SetPoint("TOPLEFT", dispHeader, "BOTTOMLEFT", 0, -4)
    dispDesc:SetText("Shows your two equipped trinket slots as clickable buttons.\nLeft-click uses the trinket. Hover to open the bag menu for swapping.")
    UI.tint(dispDesc, C.textGrey)
    dispDesc:SetJustifyH("LEFT")
    dispDesc:SetWidth(380)

    local enableCB = createCheckbox(displayPanel, "Enable Trinket Menu", 260)
    enableCB:SetPoint("TOPLEFT", dispDesc, "BOTTOMLEFT", 0, -14)
    enableCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.enabled = checked end
        if addon.Trinkets then addon.Trinkets.applyVisibility() end
        UI.RefreshTabDots()
    end

    local moveBtn = flatButton(displayPanel, "Move", 80, 22)
    moveBtn:SetPoint("TOPLEFT", enableCB, "BOTTOMLEFT", 0, -10)
    moveBtn:SetScript("OnClick", function() UI.EnterMoveMode({ addon.Trinkets }) end)

    -- ── Bag Menu section ──────────────────────────────────────────────────────
    local menuHeader = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    menuHeader:SetPoint("TOPLEFT", moveBtn, "BOTTOMLEFT", 0, -20)
    menuHeader:SetText("Bag Menu")
    UI.tint(menuHeader, C.red)

    local alwaysShowCB = createCheckbox(displayPanel, "Always show bag menu (don't close on mouse leave)", 380)
    alwaysShowCB:SetPoint("TOPLEFT", menuHeader, "BOTTOMLEFT", 0, -10)
    alwaysShowCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.alwaysShow = checked end
        if addon.Trinkets then addon.Trinkets.applyVisibility() end
    end

    local dockedCB = createCheckbox(displayPanel, "Keep bag menu docked to display frame", 340,
        "When docked, drag the bag menu around the display in Move UI mode — it snaps to whichever corner is closest and stays anchored there.")
    dockedCB:SetPoint("TOPLEFT", alwaysShowCB, "BOTTOMLEFT", 0, -6)
    dockedCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.menuDocked = checked end
        local mf = _G["DrievTrinketMenu"]
        if mf and mf:IsShown() and addon.Trinkets then
            addon.Trinkets.positionMenu()
        end
    end

    -- ── Swap delay ─────────────────────────────────────────────────────────────
    local swapLabel = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    swapLabel:SetPoint("TOPLEFT", dockedCB, "BOTTOMLEFT", 0, -14)
    swapLabel:SetText("Menu rebuild delay after swap:")
    UI.tint(swapLabel, C.textGrey)

    local swapStepper = buildStepper(displayPanel, {
        min = 0.1, max = 5.0, step = 0.1, valueWidth = 30,
        format = function(v) return string.format("%.1f", v) end,
        get = function() local d = getTData(); return (d and d.swapDelay) or 1.0 end,
        set = function(v) local d = getTData(); if d then d.swapDelay = v end end,
    })
    swapStepper:SetPoint("LEFT", swapLabel, "RIGHT", 8, 0)

    local swapSec = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    swapSec:SetPoint("LEFT", swapStepper.plus, "RIGHT", 4, 0)
    swapSec:SetText("s"); UI.tint(swapSec, C.textDim)

    local refreshSwapDelay = swapStepper.Refresh

    -- ── Layout section ────────────────────────────────────────────────────────
    local layoutHeader = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    layoutHeader:SetPoint("TOPLEFT", swapLabel, "BOTTOMLEFT", 0, -18)
    layoutHeader:SetText("Layout")
    UI.tint(layoutHeader, C.red)

    -- Orientation toggle (Horizontal / Vertical)
    local orientRow = CreateFrame("Frame", nil, displayPanel)
    orientRow:SetSize(310, 22)
    orientRow:SetPoint("TOPLEFT", layoutHeader, "BOTTOMLEFT", 0, -10)

    local orientLbl = orientRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    orientLbl:SetPoint("LEFT", 0, 0)
    orientLbl:SetText("Orientation:")
    UI.tint(orientLbl, C.textGrey)

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
                    UI.tintBg(b, C.tabActive); UI.tintBorder(b, C.red)
                else
                    UI.tintBg(b, C.panelDark); UI.tintBorder(b, C.tabBorder)
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
        bl:SetPoint("CENTER"); bl:SetText(ORIENT_LABELS[o]); UI.tint(bl, C.textWhite)
        b:SetScript("OnEnter", function(self) UI.tintBorder(self, C.red) end)
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
    UI.tint(perLineLbl, C.textGrey)

    local perLineStepper = buildStepper(perLineRow, {
        min = 1, max = 10, valueWidth = 16,
        get = function() local d = getTData(); return (d and d.menuPerLine) or 4 end,
        set = function(v) local d = getTData(); if d then d.menuPerLine = v end end,
        onChange = function() if addon.Trinkets then addon.Trinkets.buildMenu() end end,
    })
    perLineStepper:SetPoint("LEFT", 130, 0)

    -- The value number is driven by the stepper; refreshPerLine additionally
    -- swaps the label between "per row" / "per column" with the orientation.
    refreshPerLine = function()
        local d = getTData()
        local vert = d and d.menuOrientation == "vertical"
        perLineLbl:SetText(vert and "Trinkets per column:" or "Trinkets per row:")
        perLineStepper.Refresh()
    end

    -- Alignment dropdown (left / right). Right builds the menu from the right
    -- edge so the 1st trinket in menu order sits at the far right.
    local alignRow = CreateFrame("Frame", nil, displayPanel)
    alignRow:SetSize(260, 22)
    alignRow:SetPoint("TOPLEFT", perLineRow, "BOTTOMLEFT", 0, -10)

    local alignLbl = alignRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    alignLbl:SetPoint("LEFT", 0, 0)
    alignLbl:SetText("Alignment:")
    UI.tint(alignLbl, C.textGrey)

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
    UI.tint(dispScaleHeader, C.red)

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
    UI.tintTexture(dispScaleFill, C.red)
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
    dispScalePct:SetText("%"); UI.tint(dispScalePct, C.textGrey)

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
        UI.tintBorder(dispScaleThumb, C.tabBorder)
    end)
    dispScaleThumb:SetScript("OnEnter", function() UI.tintBorder(dispScaleThumb, C.red) end)
    dispScaleThumb:SetScript("OnLeave", function()
        if not dispScaleDragging then UI.tintBorder(dispScaleThumb, C.tabBorder) end
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
    UI.tint(scaleHeader, C.red)

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
    UI.tintTexture(scaleFill, C.red)
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
    scalePct:SetText("%"); UI.tint(scalePct, C.textGrey)

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
        UI.tintBorder(scaleThumb, C.tabBorder)
    end)
    scaleThumb:SetScript("OnEnter", function() UI.tintBorder(scaleThumb, C.red) end)
    scaleThumb:SetScript("OnLeave", function()
        if not scaleDragging then UI.tintBorder(scaleThumb, C.tabBorder) end
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
    UI.tint(behHeader, C.red)

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

    local watchdogCB = createCheckbox(displayPanel,
        "Auto re-queue failed trinket swaps (watchdog)", 340,
        "When a swap silently fails (e.g. a frame-long combat drop too short for the swap to go out), the stuck grayed-out trinket is always auto-recovered. This option additionally re-queues the failed swap to retry automatically.")
    watchdogCB:SetPoint("TOPLEFT", notifyCB, "BOTTOMLEFT", 0, -6)
    watchdogCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.swapWatchdog = checked end
    end

    -- ── Modifier-click settings (soft queue + slot swap) ────────────────────────
    -- Two dropdowns choosing Shift / Ctrl / None. "None" disables only the MANUAL
    -- modifier+click action, not the soft-queue system itself. Picking the modifier
    -- the other setting uses offers a swap, so the two never collide.
    local MOD_OPTS = {
        { value = "shift", label = "Shift" },
        { value = "ctrl",  label = "Ctrl"  },
        { value = "none",  label = "None"  },
    }
    local MOD_LABELS = { shift = "Shift", ctrl = "Ctrl", none = "None" }

    local softQDD, swapDD  -- forward-declared for the conflict-swap logic below

    local function applyMods()
        if addon.Trinkets and addon.Trinkets.applySoftQueueMod then
            addon.Trinkets.applySoftQueueMod()
        end
    end
    local function refreshMods()
        if softQDD then softQDD.Refresh() end
        if swapDD  then swapDD.Refresh()  end
    end

    -- Assigns modifier `v` to setting `key`. If the other setting (`otherKey`,
    -- named `otherName` in the prompt) already uses `v` (and v isn't "none"),
    -- offers to swap the two modifiers so they can't both be the same key.
    local function setModifier(key, otherKey, otherName, v)
        local d = getTData(); if not d then return end
        if v ~= "none" and d[otherKey] == v then
            UI.showConfirmPopup({
                title       = "Modifier already in use",
                message     = string.format('"%s" is already the %s. Swap the two modifiers?',
                                            MOD_LABELS[v], otherName),
                confirmText = "Swap",
                onConfirm   = function()
                    d[key], d[otherKey] = v, d[key]
                    refreshMods(); applyMods()
                end,
            })
            -- Leave both unchanged unless confirmed; createDropdown re-reads the
            -- (unchanged) value right after this returns, reverting its display.
            return
        end
        d[key] = v
        applyMods()
    end

    local softQRow = CreateFrame("Frame", nil, displayPanel)
    softQRow:SetSize(360, 22)
    softQRow:SetPoint("TOPLEFT", watchdogCB, "BOTTOMLEFT", 0, -14)

    local softQLbl = softQRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    softQLbl:SetPoint("LEFT", 0, 0)
    softQLbl:SetText("Soft queue modifier:")
    UI.tint(softQLbl, C.textGrey)

    softQDD = createDropdown(softQRow, 90, MOD_OPTS,
        function() local d = getTData(); return (d and d.softQueueMod) or "shift" end,
        function(v) setModifier("softQueueMod", "swapMod", "Swap slots modifier", v) end,
        nil,
        "Soft queue modifier",
        "Hold this modifier and click a trinket in the bag menu to Soft queue it. It swaps in only once your current trinket has been used and its effect has run out. Shown as a yellow-bordered icon in the bottom-right corner.")
    softQDD:SetPoint("LEFT", softQLbl, "RIGHT", 8, 0)

    -- ── Swap slots modifier ─────────────────────────────────────────────────────
    local swapRow = CreateFrame("Frame", nil, displayPanel)
    swapRow:SetSize(360, 22)
    swapRow:SetPoint("TOPLEFT", softQRow, "BOTTOMLEFT", 0, -10)

    local swapLbl = swapRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    swapLbl:SetPoint("LEFT", 0, 0)
    swapLbl:SetText("Swap slots modifier:")
    UI.tint(swapLbl, C.textGrey)

    swapDD = createDropdown(swapRow, 90, MOD_OPTS,
        function() local d = getTData(); return (d and d.swapMod) or "ctrl" end,
        function(v) setModifier("swapMod", "softQueueMod", "Soft queue modifier", v) end,
        nil,
        "Swap slots modifier",
        "Hold this modifier and click a worn trinket to swap your Top and Bottom slot trinkets around.")
    swapDD:SetPoint("LEFT", swapLbl, "RIGHT", 8, 0)

    local kbModCB = createCheckbox(displayPanel,
        "Trinket keybind can trigger the modifier actions too", 380,
        "Off (default): soft queue and slot swap need an actual mouse click on a trinket button. Holding the modifier while pressing the trinket keybind just uses the trinket — which is what you want when the bind itself contains that modifier, e.g. Shift-T.\n\nOn: the keybind triggers the modifier actions as well, so holding the modifier and pressing it soft-queues or swaps instead of using the trinket.")
    kbModCB:SetPoint("TOPLEFT", swapRow, "BOTTOMLEFT", 0, -14)
    kbModCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.modKeybindActions = checked end
        if addon.Trinkets and addon.Trinkets.applySoftQueueMod then
            addon.Trinkets.applySoftQueueMod()
        end
    end

    -- ── Keybind modifier blockers ──────────────────────────────────────────────
    -- Lets a trinket keybind share a physical key with a modified shortcut from
    -- outside the game (e.g. Discord push-to-talk on Alt+NumpadPlus) — WoW has no
    -- binding for that combo, so it would otherwise see NumpadPlus and fire the
    -- trinket. (Key-up vs key-down is game-wide now: General → Input.)
    local ctrlCB = createCheckbox(displayPanel, "Ignore trinket keybind while Ctrl is held", 340)
    ctrlCB:SetPoint("TOPLEFT", kbModCB, "BOTTOMLEFT", 0, -14)
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

    local reverseClickCB = createCheckbox(displayPanel, "Reverse bag menu click slots (left = bottom, right = top)", 340)
    reverseClickCB:SetPoint("TOPLEFT", shiftCB, "BOTTOMLEFT", 0, -6)
    reverseClickCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.reverseClickSlots = checked end
    end

    local elvuiSkinCB = createCheckbox(displayPanel, "Skin with ElvUI (if installed)", 340)
    elvuiSkinCB:SetPoint("TOPLEFT", reverseClickCB, "BOTTOMLEFT", 0, -6)
    elvuiSkinCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.elvuiSkinEnabled = checked end
        if addon.Trinkets and addon.Trinkets.refreshElvUISkin then addon.Trinkets.refreshElvUISkin() end
    end

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
        prompt:SetText("Press a key or mouse button (not left/right)")
        UI.tint(prompt, C.textWhite)

        local hint = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hint:SetPoint("BOTTOM", 0, 12)
        hint:SetText("Escape to cancel  •  Right-click keybind button to clear")
        UI.tint(hint, C.textGrey)

        -- Invisible button filling the popup so mouse clicks register as binds.
        local clickArea = CreateFrame("Button", nil, popup)
        clickArea:SetAllPoints(popup)
        clickArea:RegisterForClicks("AnyUp")

        local function finishCapture(rawKey)   -- nil = cancel (binding left unchanged)
            if rawKey and bindCapture.action then
                local old = GetBindingKey(bindCapture.action)
                if old then SetBinding(old) end
                SetBinding(rawKey, bindCapture.action)
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
        -- Bind a mouse button — but never left/right, which would hijack normal
        -- clicking, so those just cancel the capture. Wired to both the popup's click
        -- area AND the full-screen catcher, so any bindable button works anywhere.
        local function onCaptureClick(_, btn)
            local rawKey = btnToKey[btn]
            if rawKey == "BUTTON1" or rawKey == "BUTTON2" or not rawKey then
                finishCapture(nil)   -- left/right click (or unknown) = cancel
                return
            end
            local mod = ""
            if IsControlKeyDown() then mod = "CTRL-"  .. mod end
            if IsAltKeyDown()     then mod = "ALT-"   .. mod end
            if IsShiftKeyDown()   then mod = "SHIFT-" .. mod end
            finishCapture(mod .. rawKey)
        end
        clickArea:SetScript("OnClick", onCaptureClick)
        catcher:RegisterForClicks("AnyUp")
        catcher:SetScript("OnClick", onCaptureClick)

        capturePopup = popup
        popup._catcher = catcher
        return popup
    end

    local kbHeader = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    kbHeader:SetPoint("TOPLEFT", shiftCB, "BOTTOMLEFT", 0, -20)
    kbHeader:SetText("Keybinds")
    UI.tint(kbHeader, C.red)

    local kbDesc = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    kbDesc:SetPoint("TOPLEFT", kbHeader, "BOTTOMLEFT", 0, -4)
    kbDesc:SetText("Set a keybind for using the Top/Bottom slot\nLeft-click to open bind menu for key/mouse, Right-click to clear the keybind")
    UI.tint(kbDesc, C.textGrey)
    kbDesc:SetJustifyH("LEFT")

    local kbBindBtns = {}
    local kbSlotLbls = {}
    local prevKbAnchor = kbDesc
    for which = 0, 1 do
        local action   = "CLICK DrievTrinketBtn"..which..":LeftButton"
        local slotName = (which == 0) and "Use Top Slot" or "Use Bottom Slot"

        local slotLbl = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        slotLbl:SetWidth(80); slotLbl:SetJustifyH("LEFT")
        slotLbl:SetPoint("TOPLEFT", prevKbAnchor, "BOTTOMLEFT", 0, -18)
        slotLbl:SetText(slotName .. ":")
        UI.tint(slotLbl, C.textGrey)

        local kbBtn = CreateFrame("Button", nil, displayPanel, "BackdropTemplate")
        kbBtn:SetSize(140, 22)
        kbBtn:SetPoint("LEFT", slotLbl, "RIGHT", 8, 0)
        kbBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        applyBackdrop(kbBtn, 1, C.panelDark, C.tabBorder)
        local kbLbl = kbBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        kbLbl:SetPoint("CENTER")
        UI.tint(kbLbl, C.textWhite)
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
        kbBtn:SetScript("OnEnter", function() UI.tintBorder(kbBtn, C.red) end)
        kbBtn:SetScript("OnLeave", function() UI.tintBorder(kbBtn, C.tabBorder) end)

        kbBindBtns[which] = kbBtn
        kbSlotLbls[which] = slotLbl
        prevKbAnchor = slotLbl
    end

    -- ── Menu padding controls ──────────────────────────────────────────────────
    local padHeader = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    padHeader:SetPoint("TOPLEFT", prevKbAnchor, "BOTTOMLEFT", 0, -20)
    padHeader:SetText("Padding")
    UI.tint(padHeader, C.red)

    local function makePadRow(anchorAbove, label, getVal, setVal, apply)
        apply = apply or function() if addon.Trinkets then addon.Trinkets.buildMenu() end end
        -- Everything lives on a container frame so the whole row can be
        -- re-parented as one unit into the new tabbed layout below.
        local row = CreateFrame("Frame", nil, displayPanel)
        row:SetSize(420, 22)
        row:SetPoint("TOPLEFT", anchorAbove, "BOTTOMLEFT", 0, -18)

        local rowLbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        rowLbl:SetPoint("LEFT", 0, 0)
        rowLbl:SetText(label)
        UI.tint(rowLbl, C.textGrey)

        local btnM = CreateFrame("Button", nil, row, "BackdropTemplate")
        btnM:SetSize(22, 22)
        btnM:SetPoint("LEFT", rowLbl, "RIGHT", 8, 0)
        applyBackdrop(btnM, 1, C.panelDark, C.tabBorder)
        local mLbl = btnM:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        mLbl:SetPoint("CENTER"); mLbl:SetText("-"); UI.tint(mLbl, C.textWhite)

        local numLbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        numLbl:SetPoint("LEFT", btnM, "RIGHT", 6, 0)
        numLbl:SetWidth(20); numLbl:SetJustifyH("CENTER")
        UI.tint(numLbl, C.textWhite)

        local btnP = CreateFrame("Button", nil, row, "BackdropTemplate")
        btnP:SetSize(22, 22)
        btnP:SetPoint("LEFT", numLbl, "RIGHT", 6, 0)
        applyBackdrop(btnP, 1, C.panelDark, C.tabBorder)
        local pLbl = btnP:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        pLbl:SetPoint("CENTER"); pLbl:SetText("+"); UI.tint(pLbl, C.textWhite)

        local pxLbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        pxLbl:SetPoint("LEFT", btnP, "RIGHT", 4, 0)
        pxLbl:SetText("px"); UI.tint(pxLbl, C.textDim)

        local function refresh() numLbl:SetText(tostring(getVal())) end

        btnM:SetScript("OnClick", function()
            setVal(math.max(0, getVal() - 1))
            refresh()
            apply()
        end)
        btnM:SetScript("OnEnter", function() UI.tintBorder(btnM, C.red) end)
        btnM:SetScript("OnLeave", function() UI.tintBorder(btnM, C.tabBorder) end)
        btnP:SetScript("OnClick", function()
            setVal(math.min(30, getVal() + 1))
            refresh()
            apply()
        end)
        btnP:SetScript("OnEnter", function() UI.tintBorder(btnP, C.red) end)
        btnP:SetScript("OnLeave", function() UI.tintBorder(btnP, C.tabBorder) end)

        return row, refresh
    end

    local btnGapRow, refreshButtonGap = makePadRow(padHeader, "Button gap (space between icons):",
        function() local d = getTData(); return (d and d.menuButtonGap) or 6 end,
        function(v) local d = getTData(); if d then d.menuButtonGap = v end end)

    local applyDisplayLayout = function() if addon.Trinkets then addon.Trinkets.layoutDisplay() end end

    local dispGapRow, refreshDispButtonGap = makePadRow(btnGapRow, "Gap between the two trinkets:",
        function() local d = getTData(); return (d and d.displayButtonGap) or 2 end,
        function(v) local d = getTData(); if d then d.displayButtonGap = v end end,
        applyDisplayLayout)

    local edgePadRow, refreshEdgePad = makePadRow(dispGapRow, "Edge padding (frame border):",
        function() local d = getTData(); return (d and d.menuEdgePad) or 0 end,
        function(v) local d = getTData(); if d then d.menuEdgePad = v end end)

    local dispEdgePadRow, refreshDispEdgePad = makePadRow(edgePadRow, "Edge padding (frame border):",
        function() local d = getTData(); return (d and d.displayEdgePad) or 0 end,
        function(v) local d = getTData(); if d then d.displayEdgePad = v end end,
        applyDisplayLayout)

    -- ── Frame layer (strata + level) ──────────────────────────────────────────
    -- One row per frame: a strata dropdown (coarse layer) plus a level stepper (fine
    -- ordering within it). Both default to MEDIUM / 0, and can be raised or lowered
    -- to fix overlaps with other addons.
    local STRATA_LABELS = {
        BACKGROUND        = "Background",
        LOW               = "Low",
        MEDIUM            = "Medium",
        HIGH              = "High",
        DIALOG            = "Dialog",
        FULLSCREEN        = "Fullscreen",
        FULLSCREEN_DIALOG = "Fullscreen Dialog",
        TOOLTIP           = "Tooltip",
    }

    local function makeLayerRow(anchorAbove, getStrata, setStrata, getLevel, setLevel)
        local apply = function()
            if addon.Trinkets then addon.Trinkets.applyFrameLayers() end
        end

        local row = CreateFrame("Frame", nil, displayPanel)
        row:SetSize(460, 22)
        row:SetPoint("TOPLEFT", anchorAbove, "BOTTOMLEFT", 0, -18)

        local sLbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        sLbl:SetPoint("LEFT", 0, 0)
        sLbl:SetText("Frame strata:")
        UI.tint(sLbl, C.textGrey)

        -- Trinkets.lua loads before this file (see the .toc), so the shared
        -- strata list is always available — the dropdown's height is baked
        -- from #options at creation, so an empty list would build a dead
        -- control rather than fail loudly.
        local opts = {}
        for _, v in ipairs(addon.Trinkets.STRATA_OPTS) do
            opts[#opts + 1] = { value = v, label = STRATA_LABELS[v] or v }
        end
        local dd = createDropdown(row, 130, opts, getStrata, setStrata, apply)
        dd:SetPoint("LEFT", sLbl, "RIGHT", 8, 0)

        local lLbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lLbl:SetPoint("LEFT", dd, "RIGHT", 16, 0)
        lLbl:SetText("Level:")
        UI.tint(lLbl, C.textGrey)

        local btnM = CreateFrame("Button", nil, row, "BackdropTemplate")
        btnM:SetSize(22, 22)
        btnM:SetPoint("LEFT", lLbl, "RIGHT", 8, 0)
        applyBackdrop(btnM, 1, C.panelDark, C.tabBorder)
        local mLbl = btnM:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        mLbl:SetPoint("CENTER"); mLbl:SetText("-"); UI.tint(mLbl, C.textWhite)

        local numLbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        numLbl:SetPoint("LEFT", btnM, "RIGHT", 6, 0)
        numLbl:SetWidth(24); numLbl:SetJustifyH("CENTER")
        UI.tint(numLbl, C.textWhite)

        local btnP = CreateFrame("Button", nil, row, "BackdropTemplate")
        btnP:SetSize(22, 22)
        btnP:SetPoint("LEFT", numLbl, "RIGHT", 6, 0)
        applyBackdrop(btnP, 1, C.panelDark, C.tabBorder)
        local pLbl = btnP:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        pLbl:SetPoint("CENTER"); pLbl:SetText("+"); UI.tint(pLbl, C.textWhite)

        local function refresh()
            numLbl:SetText(tostring(getLevel()))
            if dd.Refresh then dd.Refresh() end
        end

        btnM:SetScript("OnClick", function()
            setLevel(math.max(0, getLevel() - 1)); refresh(); apply()
        end)
        btnM:SetScript("OnEnter", function() UI.tintBorder(btnM, C.red) end)
        btnM:SetScript("OnLeave", function() UI.tintBorder(btnM, C.tabBorder) end)
        btnP:SetScript("OnClick", function()
            setLevel(math.min(128, getLevel() + 1)); refresh(); apply()
        end)
        btnP:SetScript("OnEnter", function() UI.tintBorder(btnP, C.red) end)
        btnP:SetScript("OnLeave", function() UI.tintBorder(btnP, C.tabBorder) end)

        return row, refresh
    end

    local dispLayerRow, refreshDispLayer = makeLayerRow(dispEdgePadRow,
        function() local d = getTData(); return (d and d.displayStrata) or "MEDIUM" end,
        function(v) local d = getTData(); if d then d.displayStrata = v end end,
        function() local d = getTData(); return (d and d.displayLevel) or 0 end,
        function(v) local d = getTData(); if d then d.displayLevel = v end end)

    local menuLayerRow, refreshMenuLayer = makeLayerRow(dispLayerRow,
        function() local d = getTData(); return (d and d.menuStrata) or "MEDIUM" end,
        function(v) local d = getTData(); if d then d.menuStrata = v end end,
        function() local d = getTData(); return (d and d.menuLevel) or 0 end,
        function(v) local d = getTData(); if d then d.menuLevel = v end end)

    -- ── Misc section ──────────────────────────────────────────────────────────
    local miscHeader = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    miscHeader:SetPoint("TOPLEFT", dispEdgePadRow, "BOTTOMLEFT", 0, -20)
    miscHeader:SetText("Misc")
    UI.tint(miscHeader, C.red)

    local ttCB = createCheckbox(displayPanel, "Show tooltips in bag menu", 300)
    ttCB:SetPoint("TOPLEFT", miscHeader, "BOTTOMLEFT", 0, -10)
    ttCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.showTooltips = checked end
    end

    local tinyTipCB = createCheckbox(displayPanel,
        "Tiny tooltips (name, charges and cooldown only)", 340)
    tinyTipCB:SetPoint("TOPLEFT", ttCB, "BOTTOMLEFT", 20, -6)
    tinyTipCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.tinyTooltips = checked end
    end

    local showBindCB = createCheckbox(displayPanel, "Show keybind text on trinket buttons", 340)
    showBindCB:SetPoint("TOPLEFT", tinyTipCB, "BOTTOMLEFT", -20, -6)
    showBindCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.showBindings = checked end
        if addon.Trinkets then addon.Trinkets.updateHotkeys() end
    end

    local truncBindCB = createCheckbox(displayPanel, "Truncate keybind text (Numpad+ -> NP+, Ctrl-K -> CK)", 400)
    truncBindCB:SetPoint("TOPLEFT", showBindCB, "BOTTOMLEFT", 20, -6)
    truncBindCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.truncateBindings = checked end
        if addon.Trinkets then addon.Trinkets.updateHotkeys() end
    end

    -- The shared font block for that keybind text — the same eight controls, in
    -- the same order, as every other configurable text in the addon. Its offsets
    -- are from the button's top-right corner, so both normally read negative.
    local bindFontBox = buildFontOptions(displayPanel, {
        defaults   = BIND_FONT_DEFAULT,
        get        = function() return addon.Font.Block(getTData() or {}, "bindingFont") end,
        onChange   = function() if addon.Trinkets then addon.Trinkets.updateHotkeys() end end,
        labelWidth = 110,
        sizeMax    = 30,
    })

    -- ── Redesigned layout ──────────────────────────────────────────────────────
    -- Header row: "Trinket Menu" block top-left, Keybinds top-right. Below, a
    -- "Settings" heading over a left sub-sidebar (Display Menu / Bag Menu / Behavior
    -- / Misc), each section's content to the right with its own General/Layout tabs.
    -- All widgets above are reused — just re-parented here.

    -- Keybinds block → top-right of the header area.
    kbHeader:ClearAllPoints()
    kbHeader:SetPoint("TOPLEFT", displayPanel, "TOPLEFT", 440, -14)

    -- Anchored directly beneath the header block rather than at a fixed offset, so
    -- the gap hugs the content. moveBtn is the lowest element of the left column and
    -- the keybind block on the right is shorter, so this clears both.
    local settingsHdr = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    settingsHdr:SetPoint("TOPLEFT", moveBtn, "BOTTOMLEFT", 0, -12)
    settingsHdr:SetText("Settings")
    UI.tint(settingsHdr, C.red)

    -- The Settings box stretches from just under its heading down to the bottom
    -- of the (non-scrolling) sub-panel, filling whatever vertical space the
    -- window offers. Each section's content is its own scroll area (see
    -- scrollArea below), so a section taller than the box scrolls inside it.
    local sideCol = CreateFrame("Frame", nil, displayPanel, "BackdropTemplate")
    -- Left edge flush with the content box so the sidebar lines up with the tab bar
    -- above. Header content keeps its 14px indent; only the sidebar goes fully left,
    -- so the TOPLEFT (which hangs off the Settings header) is pulled back 14px.
    sideCol:SetPoint("TOPLEFT", settingsHdr, "BOTTOMLEFT", -14, -8)
    sideCol:SetPoint("BOTTOMLEFT", displayPanel, "BOTTOMLEFT", 0, 12)
    sideCol:SetWidth(130)
    applyBackdrop(sideCol, 1, C.panelDark)

    local sideContent = CreateFrame("Frame", nil, displayPanel, "BackdropTemplate")
    sideContent:SetPoint("TOPLEFT", sideCol, "TOPRIGHT", 6, 0)
    sideContent:SetPoint("BOTTOMRIGHT", displayPanel, "BOTTOMRIGHT", -14, 12)
    applyBackdrop(sideContent, 1, C.panelDeep)

    local sectionBtns, sectionShells = {}, {}

    local function newSectionShell()
        local s = CreateFrame("Frame", nil, sideContent)
        s:SetAllPoints()
        s:Hide()
        return s
    end

    -- A scroll viewport filling `parent`: a ScrollFrame leaving room for the themed
    -- track, plus a scroll-child `inner` that stackIn() fills and sizes. Returns
    -- (wrap, inner) — `wrap` is the toggled unit, so its track hides with it and
    -- General/Layout tabs leave no stray scrollbar. `inner._update` refreshes thumb.
    local function scrollArea(parent)
        local wrap = CreateFrame("Frame", nil, parent)
        wrap:SetAllPoints(parent)

        local scroll = CreateFrame("ScrollFrame", nil, wrap)
        scroll:SetPoint("TOPLEFT", 4, -4)
        scroll:SetPoint("BOTTOMRIGHT", -(SCROLLBAR_W + 4), 4)

        local inner = CreateFrame("Frame", nil, scroll)
        inner:SetSize(1, 1)
        scroll:SetScrollChild(inner)

        local _, update = attachScrollTrack(scroll, wrap)
        inner._update = update
        scroll:SetScript("OnSizeChanged", function(_, w) inner:SetWidth(w); update() end)
        -- GetVerticalScrollRange isn't reliable until shown (see makeScrollPanel);
        -- refresh the thumb on show and one frame later.
        wrap:HookScript("OnShow", function() update(); C_Timer.After(0, update) end)
        return wrap, inner
    end

    -- Section with its own General / Layout tab bar; returns (genInner, layInner).
    local function tabbedShell(shell)
        -- Height and the tabs' 3px top/left inset mirror the left sidebar
        -- (sideCol + its buttons at TOPLEFT 3,-3), so the tabs' tops line up
        -- with the "Display Menu" button's top rather than sitting slightly
        -- higher.
        local tbar = CreateFrame("Frame", nil, shell, "BackdropTemplate")
        tbar:SetHeight(26)
        tbar:SetPoint("TOPLEFT", 0, 0)
        tbar:SetPoint("TOPRIGHT", 0, 0)
        applyBackdrop(tbar, 1, C.panelDark)

        local body = CreateFrame("Frame", nil, shell, "BackdropTemplate")
        body:SetPoint("TOPLEFT", tbar, "BOTTOMLEFT", 0, -6)
        body:SetPoint("BOTTOMRIGHT", 0, 0)
        applyBackdrop(body, 4, C.panelDeep, C.panelDark)

        local genWrap, genInner = scrollArea(body)
        local layWrap, layInner = scrollArea(body)
        layWrap:Hide()

        local tabs = {}
        local panels = { general = genWrap, layout = layWrap }
        local gtab = createTab(tbar, "General", 80); gtab:SetHeight(20); gtab:SetPoint("TOPLEFT", 3, -3)
        gtab:SetScript("OnClick", function() activateTab(tabs, panels, "general") end)
        local ltab = createTab(tbar, "Layout", 80); ltab:SetHeight(20); ltab:SetPoint("LEFT", gtab, "RIGHT", 4, 0)
        ltab:SetScript("OnClick", function() activateTab(tabs, panels, "layout") end)
        tabs.general, tabs.layout = gtab, ltab
        activateTab(tabs, panels, "general")
        return genInner, layInner
    end

    -- Section with a single plain (but still scrollable) content area, no tabs.
    local function plainShell(shell)
        local bg = CreateFrame("Frame", nil, shell, "BackdropTemplate")
        bg:SetAllPoints()
        applyBackdrop(bg, 4, C.panelDeep, C.panelDark)

        local _, inner = scrollArea(bg)
        return inner
    end

    local dmShell = newSectionShell()
    local dmGen, dmLay = tabbedShell(dmShell)
    local bmShell = newSectionShell()
    local bmGen, bmLay = tabbedShell(bmShell)
    local behShell = newSectionShell()
    local behInner = plainShell(behShell)

    sectionShells.display  = dmShell
    sectionShells.bag      = bmShell
    sectionShells.behavior = behShell

    local sideDefs = {
        { key = "display",  label = "Display Menu" },
        { key = "bag",      label = "Bag Menu"     },
        { key = "behavior", label = "Behavior"     },
    }
    local prevSb
    for _, def in ipairs(sideDefs) do
        local b = createSideTab(sideCol, def.label, 26)
        b.text:SetFontObject("GameFontNormalSmall")   -- matches every other inner sidebar list
        if prevSb then
            b:SetPoint("TOPLEFT",  prevSb, "BOTTOMLEFT",  0, -2)
            b:SetPoint("TOPRIGHT", prevSb, "BOTTOMRIGHT", 0, -2)
        else
            b:SetPoint("TOPLEFT",  sideCol, "TOPLEFT",   3, -3)
            b:SetPoint("TOPRIGHT", sideCol, "TOPRIGHT", -3, -3)
        end
        b:SetScript("OnClick", function() activateTab(sectionBtns, sectionShells, def.key) end)
        sectionBtns[def.key] = b
        prevSb = b
    end
    activateTab(sectionBtns, sectionShells, "display")

    -- Re-parent + vertically re-stack the existing widgets into their section's
    -- scroll child, then size the child to its content so the scroll range (and
    -- thumb) reflect it.
    local function stackIn(inner, rows)
        local y = 10
        for _, r in ipairs(rows) do
            y = y + (r.gap or 8)
            r[1]:SetParent(inner)
            r[1]:ClearAllPoints()
            r[1]:SetPoint("TOPLEFT", inner, "TOPLEFT", 8 + (r.indent or 0), -y)
            y = y + (r.h or 22)
        end
        inner:SetHeight(y + 10)
        if inner._update then inner._update() end
    end

    stackIn(dmGen, {
        { cdCB }, { showBindCB }, { truncBindCB, indent = 20 },
        { bindFontBox, indent = 20, gap = 12, h = bindFontBox:GetHeight() },
        { notifyCB, gap = 12 },
    })
    stackIn(dmLay, {
        { dispScaleHeader, h = 18 }, { dispScaleRow, gap = 4 },
        { dispGapRow, gap = 16 }, { dispEdgePadRow, gap = 6 },
        { dispLayerRow, gap = 16 },
    })

    stackIn(bmGen, {
        { alwaysShowCB }, { dockedCB },
        { keepCB, gap = 12 }, { ttCB }, { tinyTipCB, indent = 20 },
        { swapLabel, gap = 14 },
    })
    swapStepper:SetParent(bmGen); swapStepper.value:SetParent(bmGen)
    swapStepper.plus:SetParent(bmGen);  swapSec:SetParent(bmGen)

    stackIn(bmLay, {
        { orientRow }, { perLineRow, gap = 10 }, { alignRow, gap = 12 },
        { scaleHeader, gap = 16, h = 18 }, { scaleRow, gap = 4 },
        { btnGapRow, gap = 16 }, { edgePadRow, gap = 6 },
        { menuLayerRow, gap = 16 },
    })

    stackIn(behInner, {
        { watchdogCB },
        { softQRow, gap = 12 },
        { swapRow, gap = 12 },
        { kbModCB, gap = 12 },
        { ctrlCB, gap = 12 }, { altCB }, { shiftCB },
        { reverseClickCB, gap = 12 }, { elvuiSkinCB, gap = 12 },
    })

    -- The old section headers are redundant now (the sidebar/tabs label them).
    menuHeader:Hide(); behHeader:Hide(); layoutHeader:Hide(); miscHeader:Hide(); padHeader:Hide()

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
        softQDD.Refresh()
        swapDD.Refresh()
        kbModCB:SetChecked(d.modKeybindActions or false)
        showBindCB:SetChecked(d.showBindings ~= false)
        truncBindCB:SetChecked(d.truncateBindings ~= false)
        bindFontBox:Refresh()
        ctrlCB:SetChecked(d.blockModCtrl or false)
        altCB:SetChecked(d.blockModAlt or false)
        shiftCB:SetChecked(d.blockModShift or false)
        reverseClickCB:SetChecked(d.reverseClickSlots or false)
        elvuiSkinCB:SetChecked(d.elvuiSkinEnabled ~= false)
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
        refreshDispLayer()
        refreshMenuLayer()
    end
    displayShell:SetScript("OnShow", refreshDisplay)

    -- ── Auto Queue sub-tab (nested Top Slot / Bottom Slot) ─────────────────────
    local autoQueueShell = CreateFrame("Frame", nil, subContent)
    autoQueueShell:SetAllPoints()
    autoQueueShell:Hide()

    local aqBar = CreateFrame("Frame", nil, autoQueueShell, "BackdropTemplate")
    aqBar:SetHeight(24)
    aqBar:SetPoint("TOPLEFT", 4, -4)
    aqBar:SetPoint("TOPRIGHT", -4, -4)
    applyBackdrop(aqBar, 1, C.panelDark)

    local aqContent = CreateFrame("Frame", nil, autoQueueShell)
    aqContent:SetPoint("TOPLEFT", aqBar, "BOTTOMLEFT", 0, -2)
    aqContent:SetPoint("BOTTOMRIGHT", 0, 0)

    local topQueuePanel, topQueueInner = makeScrollPanel(aqContent)
    local topList = buildSortList(topQueueInner, 0)
    topList:SetPoint("TOPLEFT", 14, -14)
    topQueuePanel:SetScript("OnShow", function() topList:Refresh() end)

    local botQueuePanel, botQueueInner = makeScrollPanel(aqContent)
    local botList = buildSortList(botQueueInner, 1)
    botList:SetPoint("TOPLEFT", 14, -14)
    botQueuePanel:SetScript("OnShow", function() botList:Refresh() end)

    autoQueueShell.nestedTabs = {
        top    = createTab(aqBar, "Top Slot", 90),
        bottom = createTab(aqBar, "Bottom Slot", 100),
    }
    autoQueueShell.nestedPanels = { top = topQueuePanel, bottom = botQueuePanel }
    autoQueueShell.nestedTabs.top:SetHeight(20)
    autoQueueShell.nestedTabs.top:SetPoint("LEFT", 4, 0)
    autoQueueShell.nestedTabs.top:SetScript("OnClick", function()
        activateTab(autoQueueShell.nestedTabs, autoQueueShell.nestedPanels, "top")
    end)
    autoQueueShell.nestedTabs.bottom:SetHeight(20)
    autoQueueShell.nestedTabs.bottom:SetPoint("LEFT", autoQueueShell.nestedTabs.top, "RIGHT", 4, 0)
    autoQueueShell.nestedTabs.bottom:SetScript("OnClick", function()
        activateTab(autoQueueShell.nestedTabs, autoQueueShell.nestedPanels, "bottom")
    end)
    activateTab(autoQueueShell.nestedTabs, autoQueueShell.nestedPanels, "top")
    -- Nested panels only re-fire their own OnShow on a nested-tab switch, not
    -- when the parent sub-tab re-opens — so refresh both lists on parent show.
    autoQueueShell:HookScript("OnShow", function() topList:Refresh(); botList:Refresh() end)

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
    addSubTab("display", "General",    80,  displayShell)
    addSubTab("order",   "Menu Order", 100, menuOrderPanel)
    -- By far the heaviest panel in the addon (every raid × boss × four trinket
    -- dropdowns), so it's the one sub-tab passed as a builder: it's constructed
    -- the first time it's opened rather than with the rest of the Trinkets tab.
    addSubTab("specific", "Specific Auto Queue (beta)", 205, function(content)
        return buildSpecificAutoQueuePanel(content, getTData)
    end)
    addSubTab("autoqueue", "Auto Queue", 100, autoQueueShell)

    selectSubTab(panel, "display")
    return panel
end

-- Adds the Trinkets entry to core's settings sidebar. Because this lives in the
-- module, disabling the addon removes the tab entirely.
UI.RegisterTab({ key = "trinkets", label = "Trinkets", order = 40, build = buildTrinketsPanel,
    status = function()
        local d = addon.db and addon.db.settings and addon.db.settings.trinkets
        return d and d.enabled or false
    end })
