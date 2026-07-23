-- Driev's Essentials — Trinkets module: settings UI.
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

local applyBackdrop        = W.applyBackdrop
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
    swapDelay        = 1.0,
    menuOrder        = {},
    hidden           = {},
    menuEdgePad      = 0,
    menuButtonGap    = 6,
    displayEdgePad   = 0,
    displayButtonGap = 2,
    displayScale     = 1.0,
    menuOrderEnabled = false,
    triggerOnKeyUp   = false,
    reverseClickSlots = false, -- swap left/right click targets: left = bottom slot, right = top slot
    elvuiSkinEnabled  = true,  -- auto-skin the Display/Bag Menu buttons when ElvUI/ShadowElvUI is loaded
    blockModCtrl     = false,
    blockModAlt      = false,
    blockModShift    = false,
    swapWatchdog     = true,
    softQueueMod     = "shift", -- "shift"/"ctrl"/"none": modifier+click a trinket to soft-queue
    swapMod          = "ctrl",  -- "shift"/"ctrl"/"none": modifier+click a worn trinket to swap top/bottom slots
    encounters       = {},   -- [encounterID] = { enabled, mainTop, mainBottom, softTop, softBottom }
    debugEncounters  = false, -- gate for the Stockades (debug raid) test encounters
    encQueueDelayEnabled = true, -- Specific Auto Queue safeguard delay toggle
    encQueueDelaySeconds = 5.0,  -- required continuous encounter+combat duration before queuing
})

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

    -- Click-drag on the thumb (previously only the mouse wheel scrolled).
    local sbDragging, sbStartY, sbStartScroll = false, 0, 0
    thumb:EnableMouse(true)
    thumb:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        sbDragging    = true
        sbStartY      = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
        sbStartScroll = sf:GetVerticalScroll()
    end)
    thumb:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then sbDragging = false end
    end)
    thumb:SetScript("OnUpdate", function()
        if not sbDragging then return end
        local n = #rows
        local visRows = math.floor(LIST_H / ROW_H)
        local maxScroll = math.max(0, (n - visRows) * ROW_H)
        local tH = track:GetHeight()
        local thumbH = thumb:GetHeight()
        if tH > thumbH and maxScroll > 0 then
            local curY  = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
            local delta = sbStartY - curY
            sf:SetVerticalScroll(math.max(0, math.min(
                sbStartScroll + delta * maxScroll / (tH - thumbH), maxScroll)))
            updateThumb()
        end
    end)
    thumb:SetScript("OnEnter", function(self) self:SetBackdropColor(unpack(C.tabHover)) end)
    thumb:SetScript("OnLeave", function(self) self:SetBackdropColor(unpack(C.tabIdle))  end)

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

    -- Click-drag on the thumb. Without these handlers the thumb was purely a
    -- visual indicator (only the mouse wheel scrolled the list).
    local sbDragging, sbStartY, sbStartScroll = false, 0, 0
    thumb:EnableMouse(true)
    thumb:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        sbDragging   = true
        sbStartY     = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
        sbStartScroll = sf:GetVerticalScroll()
    end)
    thumb:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then sbDragging = false end
    end)
    thumb:SetScript("OnUpdate", function()
        if not sbDragging then return end
        local n = #rows
        local visRows = math.floor(LIST_H / ROW_H)
        local maxScroll = math.max(0, (n - visRows) * ROW_H)
        local tH = track:GetHeight()
        local thumbH = thumb:GetHeight()
        if tH > thumbH and maxScroll > 0 then
            local curY  = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
            local delta = sbStartY - curY
            sf:SetVerticalScroll(math.max(0, math.min(
                sbStartScroll + delta * maxScroll / (tH - thumbH), maxScroll)))
            updateThumb()
        end
    end)
    thumb:SetScript("OnEnter", function(self) self:SetBackdropColor(unpack(C.tabHover)) end)
    thumb:SetScript("OnLeave", function(self) self:SetBackdropColor(unpack(C.tabIdle))  end)

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

-- Ordered list of every trinket the player has been seen carrying/wearing
-- (accumulated in d.menuOrder), resolved to { id, name, texture }. Feeds the
-- per-encounter trinket pickers. Ids whose item data isn't cached yet are
-- skipped — they reappear once GetItemInfo resolves them.
local function registeredTrinkets(d)
    local out = {}
    for _, id in ipairs(d and d.menuOrder or {}) do
        local name, _, _, _, _, _, _, _, _, tex = GetItemInfo(tonumber(id) or id)
        if name then out[#out + 1] = { id = id, name = name, texture = tex } end
    end
    return out
end

-- One shared popup reused by EVERY trinket dropdown. Building a full backdropped
-- menu + scrollbar per dropdown (there are ~190 across the Encounters/Debug grid)
-- created enough frames to trip WoW's "script ran too long" watchdog during the
-- settings build. Now each dropdown is just a light button that borrows this
-- single picker on click. Created lazily on first open.
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
            il:SetJustifyH("LEFT"); il:SetTextColor(unpack(C.textWhite))
            item.ico, item.lbl = iico, il
            item:SetScript("OnEnter", function(self) self:SetBackdropColor(unpack(C.tabHover)) end)
            item:SetScript("OnLeave", function(self) self:SetBackdropColor(unpack(C.panelDark)) end)
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
    mthumb:SetScript("OnEnter", function(self) self:SetBackdropColor(unpack(C.tabHover)) end)
    mthumb:SetScript("OnLeave", function(self) self:SetBackdropColor(unpack(C.tabIdle))  end)
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

-- A dropdown whose options are the live registered-trinket list (rebuilt each
-- time it opens, so newly discovered trinkets appear without a reload) plus a
-- "None" entry. getVal/setVal read/write the stored item id (nil = None);
-- listProvider() returns the current registeredTrinkets list. The popup itself
-- is the single shared getTrinketPicker() instance — this is just the button.
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
    text:SetTextColor(unpack(C.textWhite))

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
    dd:SetScript("OnEnter", function() dd:SetBackdropBorderColor(unpack(C.red)) end)
    dd:SetScript("OnLeave", function() dd:SetBackdropBorderColor(unpack(C.tabBorder)) end)
    dd:SetScript("OnHide", function()
        if trinketPicker and trinketPicker.active() == ctx then trinketPicker.close() end
    end)

    dd.Refresh = refresh
    refresh()
    return dd
end

-- "Specific Auto Queue" trinkets sub-tab, laid out like the General sub-tab: a
-- fixed header (the global safeguard-delay control) over a left sidebar of raids
-- and, to its right, a scrollable panel showing the selected raid's per-boss
-- trinket config. Each boss is a checkbox + name plus a 2×2 grid of trinket
-- pickers — rows are the Top/Bottom equipment slots, columns are the Main queue
-- and the Soft queue — so ticking a boss can preset two full sets of trinkets
-- to auto-queue when you engage it. The Stockades ("Debug") is the last sidebar
-- entry, gated behind its own module-enable checkbox for testing.
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
        if e and not e.enabled and not e.mainTop and not e.mainBottom
           and not e.softTop and not e.softBottom then
            d.encounters[id] = nil
        end
    end

    -- ── Safeguard delay (fixed header) ────────────────────────────────────────
    -- Both trigger conditions (ENCOUNTER_START + in combat — see
    -- maybeQueueEncounter in Trinkets.lua) can line up the instant a pull
    -- starts. This optional delay instead requires them to hold TRUE
    -- CONTINUOUSLY for the configured duration before anything queues — any
    -- combat drop or encounter end/change during that window cancels the
    -- attempt and the full delay must restart.
    local delayCB = createCheckbox(shell,
        "Safeguard delay: require encounter + combat simultaneously before queuing", 520)
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
    delayLbl:SetTextColor(unpack(C.textGrey))

    local delayStepper = buildStepper(delayRow, {
        min = 0.1, max = 30, step = 0.5, valueWidth = 34,
        format = function(v) return string.format("%.1f", v) end,
        get = function() local d = getTData(); return (d and d.encQueueDelaySeconds) or 5.0 end,
        set = function(v) local d = getTData(); if d then d.encQueueDelaySeconds = v end end,
    })
    delayStepper:SetPoint("LEFT", delayLbl, "RIGHT", 8, 0)

    local delaySec = delayRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    delaySec:SetPoint("LEFT", delayStepper.plus, "RIGHT", 4, 0)
    delaySec:SetText("s"); delaySec:SetTextColor(unpack(C.textDim))

    refreshers[#refreshers + 1] = function()
        local d = getTData()
        delayCB:SetChecked(d and d.encQueueDelayEnabled or false)
        delayStepper.Refresh()
    end

    local hint = shell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOPLEFT", delayRow, "BOTTOMLEFT", -20, -12)
    hint:SetWidth(820); hint:SetJustifyH("LEFT")
    hint:SetText("On engaging a ticked boss (once you're in combat), the Main trinkets queue to swap in first; the Soft trinkets then swap in afterwards, once the Main trinket has been used and its effect has expired.")
    hint:SetTextColor(unpack(C.textDim))

    -- ── Raids heading + sidebar / scrollable content ─────────────────────────
    local raidsHdr = shell:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    raidsHdr:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -12)
    raidsHdr:SetText("Raids")
    raidsHdr:SetTextColor(unpack(C.red))

    -- The sidebar column and content box both stretch to the bottom of the
    -- (non-scrolling) sub-panel, so the content box fills whatever vertical
    -- space the window offers and its per-raid panel scrolls inside it. Its
    -- left edge sits flush with the content box (shell) so it lines up with the
    -- tab bar backdrop above; the TOPLEFT hangs off the Raids header for its
    -- vertical position, so its x is pulled back 14px to reach that left edge.
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
    -- scrollbar (no bottom inset — this isn't near the window's resize grip),
    -- auto-sized to its content via fitInnerHeight. Returns (rshell, inner);
    -- rshell is the toggled unit, inner is the scroll child widgets stack into.
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

    -- Per-boss block is two dropdown rows (Top slot / Bottom slot) × two columns
    -- (Main queue / Soft queue). cols() derives the four x-offsets from the block
    -- origin so the column headers and the dropdowns can't drift apart.
    local NAME_W, DD_W, LBL_W = 140, 96, 26
    local SUBROW, BLOCK_H = 24, 56
    local function cols(xOff)
        local nameX = xOff + 22
        local lblX  = nameX + NAME_W + 2
        local mainX = lblX + LBL_W + 4
        local softX = mainX + DD_W + 10
        return nameX, lblX, mainX, softX
    end

    local function buildBossRow(inner, boss, xOff, y)
        local nameX, lblX, mainX, softX = cols(xOff)

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
        nm:SetText(boss.name); nm:SetTextColor(unpack(C.textWhite))

        local function slotLabel(txt, py)
            local l = inner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            l:SetPoint("TOPLEFT", inner, "TOPLEFT", lblX, -(py + 4))
            l:SetText(txt); l:SetTextColor(unpack(C.textGrey))
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

        refreshers[#refreshers + 1] = function()
            local e = entry(getTData(), boss.id)
            cb:SetChecked(e and e.enabled or false)
            mainTopDD.Refresh(); softTopDD.Refresh()
            mainBotDD.Refresh(); softBotDD.Refresh()
        end
    end

    -- Builds one raid's config into its own scroll panel; returns the rshell for
    -- the sidebar's activateTab. The Stockades ("debug") raid gets an extra
    -- module-enable checkbox + hint above its boss list.
    local function buildRaidSection(raid)
        local rshell, inner = raidScrollPanel()
        local y = 10

        if raid.key == "debug" then
            local dbgEnableCB = createCheckbox(inner,
                "Enable Debug module (The Stockades encounters)", 380)
            dbgEnableCB:SetPoint("TOPLEFT", inner, "TOPLEFT", 8, -y)
            dbgEnableCB.OnChange = function(_, checked)
                local d = getTData(); if d then d.debugEncounters = checked or nil end
            end
            refreshers[#refreshers + 1] = function()
                local d = getTData()
                dbgEnableCB:SetChecked(d and d.debugEncounters or false)
            end
            y = y + 26

            local dbgHint = inner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            dbgHint:SetPoint("TOPLEFT", inner, "TOPLEFT", 8, -y)
            dbgHint:SetWidth(560); dbgHint:SetJustifyH("LEFT")
            dbgHint:SetText("For testing: configure trinkets for The Stockades bosses, then run the dungeon. These only auto-queue while the Debug module above is enabled.")
            dbgHint:SetTextColor(unpack(C.textDim))
            y = y + 44
        end

        local _, _, mainX, softX = cols(8)
        local hMain = inner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hMain:SetPoint("TOPLEFT", inner, "TOPLEFT", mainX, -y)
        hMain:SetText("Main"); hMain:SetTextColor(unpack(C.red))
        local hSoft = inner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hSoft:SetPoint("TOPLEFT", inner, "TOPLEFT", softX, -y)
        hSoft:SetText("Soft"); hSoft:SetTextColor(unpack(C.red))
        y = y + 22

        for _, boss in ipairs(raid.bosses) do
            buildBossRow(inner, boss, 8, y)
            y = y + BLOCK_H
        end

        return rshell
    end

    -- ── Raid sidebar + panels ────────────────────────────────────────────────
    local raidTabs, raidPanels = {}, {}
    local prevSb, firstKey
    for _, raid in ipairs(addon.RAIDS or {}) do
        local key = raid.key
        raidPanels[key] = buildRaidSection(raid)

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
    shell:HookScript("OnShow", function()
        for _, fn in ipairs(refreshers) do fn() end
    end)

    return shell
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
    dispHeader:SetTextColor(unpack(C.red))

    local dispDesc = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dispDesc:SetPoint("TOPLEFT", dispHeader, "BOTTOMLEFT", 0, -4)
    dispDesc:SetText("Shows your two equipped trinket slots as clickable buttons.\nLeft-click uses the trinket. Hover to open the bag menu for swapping.")
    dispDesc:SetTextColor(unpack(C.textGrey))
    dispDesc:SetJustifyH("LEFT")
    dispDesc:SetWidth(380)

    local enableCB = createCheckbox(displayPanel, "Enable Trinket Menu", 260)
    enableCB:SetPoint("TOPLEFT", dispDesc, "BOTTOMLEFT", 0, -14)
    enableCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.enabled = checked end
        if addon.Trinkets then addon.Trinkets.applyVisibility() end
    end

    local moveBtn = flatButton(displayPanel, "Move", 80, 22)
    moveBtn:SetPoint("TOPLEFT", enableCB, "BOTTOMLEFT", 0, -10)
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

    -- ── Swap delay ─────────────────────────────────────────────────────────────
    local swapLabel = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    swapLabel:SetPoint("TOPLEFT", dockHint, "BOTTOMLEFT", -20, -14)
    swapLabel:SetText("Menu rebuild delay after swap:")
    swapLabel:SetTextColor(unpack(C.textGrey))

    local swapStepper = buildStepper(displayPanel, {
        min = 0.1, max = 5.0, step = 0.1, valueWidth = 30,
        format = function(v) return string.format("%.1f", v) end,
        get = function() local d = getTData(); return (d and d.swapDelay) or 1.0 end,
        set = function(v) local d = getTData(); if d then d.swapDelay = v end end,
    })
    swapStepper:SetPoint("LEFT", swapLabel, "RIGHT", 8, 0)

    local swapSec = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    swapSec:SetPoint("LEFT", swapStepper.plus, "RIGHT", 4, 0)
    swapSec:SetText("s"); swapSec:SetTextColor(unpack(C.textDim))

    local refreshSwapDelay = swapStepper.Refresh

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

    local watchdogCB = createCheckbox(displayPanel,
        "Auto re-queue failed trinket swaps (watchdog)", 340)
    watchdogCB:SetPoint("TOPLEFT", notifyCB, "BOTTOMLEFT", 0, -6)
    watchdogCB.OnChange = function(_, checked)
        local d = getTData(); if d then d.swapWatchdog = checked end
    end

    local watchdogHint = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    watchdogHint:SetPoint("TOPLEFT", watchdogCB, "BOTTOMLEFT", 20, -8)
    watchdogHint:SetText("When a swap silently fails (e.g. a frame-long combat drop too short for the swap to go out), the stuck grayed-out trinket is always auto-recovered. This option additionally re-queues the failed swap to retry automatically.")
    watchdogHint:SetTextColor(unpack(C.textDim))
    watchdogHint:SetWidth(340); watchdogHint:SetJustifyH("LEFT")

    -- ── Modifier-click settings (soft queue + slot swap) ────────────────────────
    -- Two dropdowns choosing Shift / Ctrl / None. "None" only disables the
    -- MANUAL modifier+click action — it does not disable the soft-queue system
    -- itself (Specific Auto Queue still soft-queues). If you pick the modifier
    -- the other setting already uses, a popup offers to swap the two so they
    -- never collide.
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
    softQRow:SetPoint("TOPLEFT", watchdogHint, "BOTTOMLEFT", -20, -14)

    local softQLbl = softQRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    softQLbl:SetPoint("LEFT", 0, 0)
    softQLbl:SetText("Soft queue modifier:")
    softQLbl:SetTextColor(unpack(C.textGrey))

    softQDD = createDropdown(softQRow, 90, MOD_OPTS,
        function() local d = getTData(); return (d and d.softQueueMod) or "shift" end,
        function(v) setModifier("softQueueMod", "swapMod", "Swap slots modifier", v) end)
    softQDD:SetPoint("LEFT", softQLbl, "RIGHT", 8, 0)

    local softQHint = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    softQHint:SetPoint("TOPLEFT", softQRow, "BOTTOMLEFT", 0, -8)
    softQHint:SetText("Hold this modifier and click a trinket in the bag menu to Soft queue it. It swaps in only once your current trinket has been used and its effect has run out. Shown as a yellow-bordered icon in the bottom-right corner.")
    softQHint:SetTextColor(unpack(C.textDim))
    softQHint:SetWidth(340); softQHint:SetJustifyH("LEFT")

    -- ── Swap slots modifier ─────────────────────────────────────────────────────
    local swapRow = CreateFrame("Frame", nil, displayPanel)
    swapRow:SetSize(360, 22)
    swapRow:SetPoint("TOPLEFT", softQHint, "BOTTOMLEFT", 0, -14)

    local swapLbl = swapRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    swapLbl:SetPoint("LEFT", 0, 0)
    swapLbl:SetText("Swap slots modifier:")
    swapLbl:SetTextColor(unpack(C.textGrey))

    swapDD = createDropdown(swapRow, 90, MOD_OPTS,
        function() local d = getTData(); return (d and d.swapMod) or "ctrl" end,
        function(v) setModifier("swapMod", "softQueueMod", "Soft queue modifier", v) end)
    swapDD:SetPoint("LEFT", swapLbl, "RIGHT", 8, 0)

    local swapHint = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    swapHint:SetPoint("TOPLEFT", swapRow, "BOTTOMLEFT", 0, -8)
    swapHint:SetText("Hold this modifier and click a worn trinket to swap your Top and Bottom slot trinkets around.")
    swapHint:SetTextColor(unpack(C.textDim))
    swapHint:SetWidth(340); swapHint:SetJustifyH("LEFT")

    local keyUpCB = createCheckbox(displayPanel,
        "Trigger keybind on key up (default: key down)", 340)
    keyUpCB:SetPoint("TOPLEFT", softQHint, "BOTTOMLEFT", 0, -14)
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
        prompt:SetTextColor(unpack(C.textWhite))

        local hint = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hint:SetPoint("BOTTOM", 0, 12)
        hint:SetText("Escape to cancel  •  Right-click keybind button to clear")
        hint:SetTextColor(unpack(C.textGrey))

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
        -- Bind a mouse button — but never left/right click: binding those would
        -- hijack normal clicking, so a left/right click just cancels the capture
        -- instead. Wired to BOTH the popup's own click area AND the full-screen
        -- catcher below, so any bindable mouse button can be pressed anywhere on
        -- screen (no need to hover the little popup, unlike before).
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
    kbHeader:SetTextColor(unpack(C.red))

    local kbDesc = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    kbDesc:SetPoint("TOPLEFT", kbHeader, "BOTTOMLEFT", 0, -4)
    kbDesc:SetText("Set a keybind for using the Top/Bottom slot\nLeft-click to open bind menu for key/mouse, Right-click to clear the keybind")
    kbDesc:SetTextColor(unpack(C.textGrey))
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
        kbSlotLbls[which] = slotLbl
        prevKbAnchor = slotLbl
    end

    -- ── Menu padding controls ──────────────────────────────────────────────────
    local padHeader = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    padHeader:SetPoint("TOPLEFT", prevKbAnchor, "BOTTOMLEFT", 0, -20)
    padHeader:SetText("Padding")
    padHeader:SetTextColor(unpack(C.red))

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
        rowLbl:SetTextColor(unpack(C.textGrey))

        local btnM = CreateFrame("Button", nil, row, "BackdropTemplate")
        btnM:SetSize(22, 22)
        btnM:SetPoint("LEFT", rowLbl, "RIGHT", 8, 0)
        applyBackdrop(btnM, 1, C.panelDark, C.tabBorder)
        local mLbl = btnM:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        mLbl:SetPoint("CENTER"); mLbl:SetText("-"); mLbl:SetTextColor(unpack(C.textWhite))

        local numLbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        numLbl:SetPoint("LEFT", btnM, "RIGHT", 6, 0)
        numLbl:SetWidth(20); numLbl:SetJustifyH("CENTER")
        numLbl:SetTextColor(unpack(C.textWhite))

        local btnP = CreateFrame("Button", nil, row, "BackdropTemplate")
        btnP:SetSize(22, 22)
        btnP:SetPoint("LEFT", numLbl, "RIGHT", 6, 0)
        applyBackdrop(btnP, 1, C.panelDark, C.tabBorder)
        local pLbl = btnP:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        pLbl:SetPoint("CENTER"); pLbl:SetText("+"); pLbl:SetTextColor(unpack(C.textWhite))

        local pxLbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
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

    -- ── Misc section ──────────────────────────────────────────────────────────
    local miscHeader = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    miscHeader:SetPoint("TOPLEFT", dispEdgePadRow, "BOTTOMLEFT", 0, -20)
    miscHeader:SetText("Misc")
    miscHeader:SetTextColor(unpack(C.red))

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

    -- ── Redesigned layout ──────────────────────────────────────────────────────
    -- Header row: the "Trinket Menu" block (dispHeader/dispDesc/enableCB/moveBtn)
    -- stays top-left; the Keybinds block moves top-right. Below, a "Settings"
    -- heading over a left sub-sidebar (Display Menu / Bag Menu / Behavior / Misc),
    -- each section's content shown to the right with its own General/Layout tabs
    -- where applicable. All widgets above are reused — just re-parented here.

    -- Keybinds block → top-right of the header area.
    kbHeader:ClearAllPoints()
    kbHeader:SetPoint("TOPLEFT", displayPanel, "TOPLEFT", 440, -14)

    -- Anchor the Settings heading directly beneath the header block (Trinket
    -- Menu column on the left / Keybinds on the right) instead of a fixed
    -- offset, so the gap hugs the content. moveBtn is the lowest element of
    -- the left column; the keybind block on the right is shorter, so this
    -- clears both.
    local settingsHdr = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    settingsHdr:SetPoint("TOPLEFT", moveBtn, "BOTTOMLEFT", 0, -12)
    settingsHdr:SetText("Settings")
    settingsHdr:SetTextColor(unpack(C.red))

    -- The Settings box stretches from just under its heading down to the bottom
    -- of the (non-scrolling) sub-panel, filling whatever vertical space the
    -- window offers. Each section's content is its own scroll area (see
    -- scrollArea below), so a section taller than the box scrolls inside it.
    local sideCol = CreateFrame("Frame", nil, displayPanel, "BackdropTemplate")
    -- Left edge flush with the content box (displayPanel = subContent), so the
    -- sidebar lines up with the tab bar backdrop above it. The header content
    -- (Settings, etc.) keeps its 14px indent; only the sidebar goes fully left.
    -- The TOPLEFT still hangs off the Settings header for its vertical position,
    -- so its x is pulled back 14px to reach the content's left edge.
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

    -- A scroll viewport filling `parent` (a section's backdrop box): a
    -- ScrollFrame leaving room for the themed track on the right, plus a
    -- scroll-child `inner` that stackIn() fills and sizes. Returns
    -- (wrap, inner): `wrap` is the toggled unit (its track hides with it, so
    -- General/Layout tabs don't leave a stray scrollbar behind); `inner` is
    -- what widgets get stacked into. `inner._update` refreshes the thumb.
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
        { cdCB }, { showBindCB }, { truncBindCB, indent = 20 }, { notifyCB },
    })
    stackIn(dmLay, {
        { dispScaleHeader, h = 18 }, { dispScaleRow, gap = 4 },
        { dispGapRow, gap = 16 }, { dispEdgePadRow, gap = 6 },
    })

    stackIn(bmGen, {
        { alwaysShowCB }, { dockedCB }, { dockHint, indent = 20, h = 38 },
        { keepCB, gap = 12 }, { ttCB }, { tinyTipCB, indent = 20 },
        { swapLabel, gap = 14 },
    })
    swapStepper:SetParent(bmGen); swapStepper.value:SetParent(bmGen)
    swapStepper.plus:SetParent(bmGen);  swapSec:SetParent(bmGen)

    stackIn(bmLay, {
        { orientRow }, { perLineRow, gap = 10 }, { alignRow, gap = 12 },
        { scaleHeader, gap = 16, h = 18 }, { scaleRow, gap = 4 },
        { btnGapRow, gap = 16 }, { edgePadRow, gap = 6 },
    })

    stackIn(behInner, {
        { watchdogCB }, { watchdogHint, indent = 20, h = 48 },
        { softQRow, gap = 12 }, { softQHint, h = 48 },
        { swapRow, gap = 12 }, { swapHint, h = 34 },
        { keyUpCB, gap = 12 }, { ctrlCB, gap = 12 }, { altCB }, { shiftCB },
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
        showBindCB:SetChecked(d.showBindings ~= false)
        truncBindCB:SetChecked(d.truncateBindings ~= false)
        keyUpCB:SetChecked(d.triggerOnKeyUp or false)
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
    panel.subTabs["display"]   = createTab(subBar, "General", 80)
    panel.subTabs["order"]     = createTab(subBar, "Menu Order", 100)
    panel.subTabs["specific"]  = createTab(subBar, "Specific Auto Queue (beta)", 205)
    panel.subTabs["autoqueue"] = createTab(subBar, "Auto Queue", 100)
    panel.subPanels["display"] = displayShell
    panel.subPanels["order"]   = menuOrderPanel
    panel.subPanels["specific"] = buildSpecificAutoQueuePanel(subContent, getTData)
    panel.subPanels["autoqueue"] = autoQueueShell

    -- Tab order: Display, Menu Order, Specific Auto Queue, Auto Queue
    panel.subTabs["display"]:SetHeight(22)
    panel.subTabs["display"]:SetPoint("LEFT", 4, 0)
    panel.subTabs["display"]:SetScript("OnClick", function() selectSubTab(panel, "display") end)

    panel.subTabs["order"]:SetHeight(22)
    panel.subTabs["order"]:SetPoint("LEFT", panel.subTabs["display"], "RIGHT", 4, 0)
    panel.subTabs["order"]:SetScript("OnClick", function() selectSubTab(panel, "order") end)

    panel.subTabs["specific"]:SetHeight(22)
    panel.subTabs["specific"]:SetPoint("LEFT", panel.subTabs["order"], "RIGHT", 4, 0)
    panel.subTabs["specific"]:SetScript("OnClick", function() selectSubTab(panel, "specific") end)

    panel.subTabs["autoqueue"]:SetHeight(22)
    panel.subTabs["autoqueue"]:SetPoint("LEFT", panel.subTabs["specific"], "RIGHT", 4, 0)
    panel.subTabs["autoqueue"]:SetScript("OnClick", function() selectSubTab(panel, "autoqueue") end)

    selectSubTab(panel, "display")
    return panel
end

-- Adds the Trinkets entry to core's settings sidebar. Because this lives in the
-- module, disabling the addon removes the tab entirely.
UI.RegisterTab({ key = "trinkets", label = "Trinkets", order = 40, build = buildTrinketsPanel })
