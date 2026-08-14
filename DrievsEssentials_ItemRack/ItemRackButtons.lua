-- Item Rack module: movable buttons, pop-out menus and character sheet
-- integration. Hovering a character sheet slot pops out every item that fits it;
-- Alt+click a slot spawns a movable button, Alt+click the model spawns the set
-- button.
--
-- Buttons snap ("dock") to each other when dragged close, forming a bar. The
-- dock relationship is saved rather than a raw position, so a chain moves as one.
local addon = _G.DrievEssentials
if not addon then return end

local IR = addon.ItemRack
if not IR then return end

local UI    = addon.UI
local WHITE = "Interface\\Buttons\\WHITE8x8"

local DB      = IR.DB       -- per-character: sets, hidden entries
local Layout  = IR.Layout   -- profile: buttons, clusters
local getData = IR.GetData
local GetID   = IR.GetID

local _   -- scratch for the multi-return item APIs below

local GetContainerNumSlots = C_Container.GetContainerNumSlots
local GetItemCooldown      = C_Container.GetItemCooldown or _G.GetItemCooldown

local BTN_SIZE  = 36
local SET_BTN   = IR.SET_BUTTON

local buttons   = {}   -- [0..20] = frame, created lazily
local menuFrame, menuButtons, menuControls
local menuEntries = {} -- what the menu is currently showing, index -> id/setname

-- Bakes the classic action-button art onto an ActionButtonTemplate button, and
-- works around 1.15.9's nine-sliced state textures while doing it. Shared with
-- the set editor and the Trinkets module — see addon.StyleSlotButton in Core.
local styleSlotButton = addon.StyleSlotButton

-- ── Masque ───────────────────────────────────────────────────────────────────
-- Masque is a shared LibStub library: any addon embedding it makes
-- LibStub("Masque") available and keeps applying whichever skin was last chosen
-- for a group name. Registration is unconditional — the buttons already carry
-- the baked look, so anyone who doesn't want skinning disables our groups in
-- Masque's own options. Three groups, mirroring upstream ItemRack, so the bar
-- can be skinned separately from the menus and the editor grid.
local MASQUE_LABELS = {
    buttons = "Item Rack Buttons",
    menus   = "Item Rack Menus",
    editor  = "Item Rack Set Editor",
}
local masqueGroups = {}

-- Masque's auto-detect only reliably finds Icon and Cooldown; every other layer
-- must be listed by hand or it keeps drawing our un-skinned texture over the
-- skin. Absent regions are nil here and Masque skips them.
--
-- irBorder is deliberately NOT handed over: Masque would apply its skin's colour
-- to the Border layer, fighting the red/blue "missing" vs "in the bank" tint.
local function masqueButtonData(btn)
    return {
        Icon      = btn.icon,
        Cooldown  = btn.Cooldown or btn.cooldown,
        Normal    = btn:GetNormalTexture(),
        Pushed    = btn:GetPushedTexture(),
        Highlight = btn:GetHighlightTexture(),
        Checked   = btn:GetCheckedTexture(),
        Count     = btn.irCount,
        HotKey    = btn.irHotKey,
        Name      = btn.irName,
    }
end

-- Called once per button, at the end of its creation — every region a skin
-- touches must already be in place, since ButtonData is captured here.
function IR.AddToMasque(key, btn)
    local MSQ = LibStub and LibStub("Masque", true)
    if not MSQ then return end
    local group = masqueGroups[key]
    if not group then
        group = MSQ:Group("Driev's Essentials", MASQUE_LABELS[key] or key)
        masqueGroups[key] = group
    end
    group:AddButton(btn, masqueButtonData(btn))
end

-- ── Docking geometry ─────────────────────────────────────────────────────────

-- A docked button's Side names the edge of ITSELF that meets its anchor — the
-- same xoff/yoff convention upstream ItemRack used. Side="LEFT" sits this
-- button's LEFT edge against the anchor's RIGHT edge, nudged by xoff*spacing.
local DockOffset = {
    LEFT   = { xoff =  1, yoff =  0 },
    RIGHT  = { xoff = -1, yoff =  0 },
    TOP    = { xoff =  0, yoff = -1 },
    BOTTOM = { xoff =  0, yoff =  1 },
}
local OppositeSide = { LEFT = "RIGHT", RIGHT = "LEFT", TOP = "BOTTOM", BOTTOM = "TOP" }

-- The grid a pop-out menu's icons lay out on, one cell per icon. Icon spacing is
-- a user setting, so the cell is read fresh rather than baked in.
local function getCell()
    return BTN_SIZE + (getData().menuIconSpacing or 4)
end
IR.GetMenuCell = getCell

-- Where a pop-out menu grows from once docked corner-to-corner. Keyed by
-- mainDock..menuDock; rebuilt when icon spacing changes, since two of its four
-- numbers are in icon-spacing units:
--
--   NEAR — how far the first icon sits from the menu's backdrop border on the
--          axis facing the button: half the border's 12px plus half a gap.
--   FAR  — the same from the icon's FAR edge, for where the frame's anchor
--          corner is on the opposite side of the grid from the button.
--
-- xoff/yoff corner-match the menu to the button; one is always 0 — the axis the
-- menu separates along, and the one the menu-gap setting adds to. `side` names
-- it so DockWindows needn't re-derive it per hover.
local function buildMenuDockInfo(near, far)
    return {
        TOPRIGHTTOPLEFT       = { xoff = 0,    yoff =  near, xdir =  1, ydir = -1, xstart =  near, ystart = -near, side = "RIGHT"  },
        BOTTOMRIGHTBOTTOMLEFT = { xoff = 0,    yoff = -near, xdir =  1, ydir =  1, xstart =  near, ystart =  far,  side = "RIGHT"  },
        TOPLEFTTOPRIGHT       = { xoff = 0,    yoff =  near, xdir = -1, ydir = -1, xstart = -far,  ystart = -near, side = "LEFT"   },
        BOTTOMLEFTBOTTOMRIGHT = { xoff = 0,    yoff = -near, xdir = -1, ydir =  1, xstart = -far,  ystart =  far,  side = "LEFT"   },
        TOPRIGHTBOTTOMRIGHT   = { xoff =  near, yoff = 0,    xdir = -1, ydir =  1, xstart = -far,  ystart =  far,  side = "TOP"    },
        BOTTOMRIGHTTOPRIGHT   = { xoff =  near, yoff = 0,    xdir = -1, ydir = -1, xstart = -far,  ystart = -near, side = "BOTTOM" },
        TOPLEFTBOTTOMLEFT     = { xoff = -near, yoff = 0,    xdir =  1, ydir =  1, xstart =  near, ystart =  far,  side = "TOP"    },
        BOTTOMLEFTTOPLEFT     = { xoff = -near, yoff = 0,    xdir =  1, ydir = -1, xstart =  near, ystart = -near, side = "BOTTOM" },
    }
end

-- Cached and rebuilt only when the spacing setting changes, so a drag preview
-- polling this several times a second isn't allocating eight tables a tick.
local menuDockInfoCache, menuDockInfoNear

local function getMenuDockInfo()
    local near = 6 + (getData().menuIconSpacing or 4) / 2
    if near ~= menuDockInfoNear then
        menuDockInfoCache  = buildMenuDockInfo(near, near + BTN_SIZE)
        menuDockInfoNear   = near
    end
    return menuDockInfoCache
end

-- Which direction along the gap axis is "further from the button", per side —
-- RIGHT/TOP need a bigger offset to push away, LEFT/BOTTOM need a smaller one.
local MenuGapSign = { RIGHT = 1, LEFT = -1, TOP = 1, BOTTOM = -1 }

-- The frame edge touches the button at 0 on the separating axis, but the first
-- ICON sits NEAR further inside it — the menu's own backdrop border. That
-- padding is what a menu gap of 0 still showed: the FRAMES were flush, the icon
-- wasn't. Cancelled out here so "Menu Gap = 0" means the icon sits flush.
local function menuDockOffset(info, gap)
    local near  = 6 + (getData().menuIconSpacing or 4) / 2
    local delta = ((gap or 0) - near) * MenuGapSign[info.side]
    if info.side == "LEFT" or info.side == "RIGHT" then
        return info.xoff + delta, info.yoff
    else
        return info.xoff, info.yoff + delta
    end
end

-- Forward declaration: layoutCluster below positions buttons, but button
-- creation is defined further down the file.
local getOrCreateButton

-- ── Clusters ─────────────────────────────────────────────────────────────────
-- A cluster is one bar of docked buttons, and it is pure bookkeeping —
-- buttons[id] = { cluster, DockTo, Side } and clusters[cid] = { px, py, ... } —
-- NOT a frame owning the buttons as children.
--
-- That matters because :SetParent() on a secure frame taints whatever it's moved
-- into. An earlier version made a container Frame the parent of each cluster
-- (for shared scale/alpha via inheritance); every SetParent() quietly tainted
-- it, and the first container:Show()/:Hide() raised ADDON_ACTION_BLOCKED. These
-- are SecureActionButtonTemplate buttons — never reparent them after creation.
--
-- Instead, as upstream ItemRack, Bartender4 and Dominos all do: buttons stay on
-- UIParent for life. The HEAD (no DockTo) owns the absolute position and every
-- other member is SetPoint-anchored to its dock-chain neighbour, so dragging the
-- head carries the chain for free. Scale/alpha are applied per button.

-- Detached fallback for a nil/unknown cid — e.g. the settings UI reading a
-- stepper before a bar is picked. Never written back, so it can't create a
-- phantom cluster entry.
local NO_CLUSTER = { scale = 1, spacing = 4, alpha = 1 }

local function clusterData(cid)
    if cid == nil then return NO_CLUSTER end
    local layout = Layout()
    layout.clusters[cid] = layout.clusters[cid] or {}
    local c = layout.clusters[cid]
    local d = getData()
    if c.scale   == nil then c.scale   = d.buttonScale   or 1 end
    if c.spacing == nil then c.spacing = d.buttonSpacing or 4 end
    if c.alpha   == nil then c.alpha   = d.buttonAlpha   or 1 end
    return c
end
IR.ClusterData = clusterData

local function clusterMembers(cid)
    local list = {}
    for id, data in pairs(Layout().buttons) do
        if data.cluster == cid then list[#list + 1] = id end
    end
    table.sort(list)
    return list
end
IR.ClusterMembers = clusterMembers

local function clusterIDs()
    local seen, list = {}, {}
    for _, data in pairs(Layout().buttons) do
        if data.cluster and not seen[data.cluster] then
            seen[data.cluster] = true
            list[#list + 1] = data.cluster
        end
    end
    table.sort(list)
    return list
end
IR.ClusterIDs = clusterIDs

-- Whichever member owns the absolute position: the one with no DockTo, or
-- (defensively) one whose DockTo points outside this cluster or at itself.
local function clusterHead(cid, members)
    local buttonsDB = Layout().buttons
    for _, id in ipairs(members) do
        local data   = buttonsDB[id]
        local anchor = data.DockTo
        if not anchor or anchor == id then return id end
        local adata = buttonsDB[anchor]
        if not adata or adata.cluster ~= cid then return id end
    end
    return members[1]
end
IR.ClusterHead = clusterHead

local function newCluster(px, py, from)
    local layout = Layout()
    local cid = layout.nextCluster
    layout.nextCluster = cid + 1
    local d = getData()
    layout.clusters[cid] = {
        px = px, py = py,
        scale   = from and from.scale   or d.buttonScale   or 1,
        spacing = from and from.spacing or d.buttonSpacing or 4,
        alpha   = from and from.alpha   or d.buttonAlpha   or 1,
    }
    return cid
end

-- Reads a button's absolute (UIParent-space) position, the same GetLeft()*scale
-- technique upstream's ReflectMainScale uses: GetLeft()/GetTop() are already in
-- the parent's space, so multiplying by the button's own scale gives pixels.
local function buttonAbsolutePosition(btn)
    if not (btn and btn:GetLeft()) then return nil, nil end
    local scale = btn:GetScale() or 1
    return btn:GetLeft() * scale, btn:GetTop() * scale
end

-- Saves the cluster's position from wherever its head button currently sits —
-- called after a plain (non-merging) drag ends.
local function saveClusterHeadPosition(cid)
    local head = clusterHead(cid, clusterMembers(cid))
    local px, py = buttonAbsolutePosition(buttons[head])
    if px then
        local c = clusterData(cid)
        c.px, c.py = px, py
    end
end

-- Screen clamping is the HEAD's job alone. Every other member is anchored to a
-- neighbour, so clamping it individually lets the screen edge override its dock
-- offset — which is what made a bar pushed into a corner squash its icons
-- together. With only the head clamped, and its clamp rect grown to cover the
-- whole bar, the bar stops at the edge.
--
-- SetClampRectInsets shifts each edge of the clamped rect relative to the
-- frame's own, so feeding it the bar's bounding box in the head's coordinate
-- space clamps the bar, not the button. Read off live frames at drag time.
local function applyClusterClamp(cid)
    -- Same combat rule the rest of the layout code follows: these are secure
    -- buttons, so leave their clamping alone until the lockdown lifts.
    if InCombatLockdown() then return end
    local members = clusterMembers(cid)
    local head    = clusterHead(cid, members)
    local headBtn = buttons[head]
    if not (headBtn and headBtn:GetLeft()) then return end

    local minL, maxR = headBtn:GetLeft(), headBtn:GetRight()
    local maxT, minB = headBtn:GetTop(),  headBtn:GetBottom()
    for _, id in ipairs(members) do
        local btn = buttons[id]
        if btn and btn:IsShown() and btn:GetLeft() then
            minL = math.min(minL, btn:GetLeft())
            maxR = math.max(maxR, btn:GetRight())
            maxT = math.max(maxT, btn:GetTop())
            minB = math.min(minB, btn:GetBottom())
        end
    end

    local l = minL - headBtn:GetLeft()
    local r = maxR - headBtn:GetRight()
    local t = maxT - headBtn:GetTop()
    local b = minB - headBtn:GetBottom()

    -- "Allow dragging off screen" pulls that rectangle back to a small patch at the
    -- middle of the bar. Same keep-a-handle rule core applies to single-frame
    -- movables, against the bar's bounding box rather than one frame's rect.
    if addon.GetEditOffscreen and addon.GetEditOffscreen() then
        local barW, barH = maxR - minL, maxT - minB
        local dx = math.max(0, (barW - addon.OffscreenKeep(barW)) / 2)
        local dy = math.max(0, (barH - addon.OffscreenKeep(barH)) / 2)
        l, r, t, b = l + dx, r - dx, t - dy, b + dy
    end

    headBtn:SetClampRectInsets(l, r, t, b)
end

-- Anchors every member to its own dock-chain neighbour. The head owns the
-- absolute position; the rest are positioned breadth-first outward from it, as
-- upstream's ConstructLayout does. No frame is ever reparented.
local function layoutCluster(cid)
    if InCombatLockdown() then return end
    local db      = Layout()
    local members = clusterMembers(cid)

    if #members == 0 then
        Layout().clusters[cid] = nil
        return
    end

    local c = clusterData(cid)
    for _, id in ipairs(members) do
        local btn = getOrCreateButton(id)
        if btn then
            btn:SetScale(c.scale or 1)
            btn:SetAlpha(c.alpha or 1)
        end
    end

    local head    = clusterHead(cid, members)
    local headBtn = buttons[head]
    if not headBtn then return end

    -- Membership may have changed since the last pass, so hand the clamp back
    -- to whoever the head is now.
    for _, id in ipairs(members) do
        local btn = buttons[id]
        if btn then
            btn:SetClampRectInsets(0, 0, 0, 0)
            btn:SetClampedToScreen(id == head)
        end
    end

    headBtn:ClearAllPoints()
    local scale = c.scale or 1
    if c.px and c.py then
        headBtn:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", c.px / scale, c.py / scale)
    else
        headBtn:SetPoint("CENTER", UIParent, "CENTER")
    end
    headBtn:Show()

    -- Breadth-first from the head so a button's anchor is always already
    -- placed before it's used as a relativeTo target.
    local placed  = { [head] = true }
    local pending = {}
    for _, id in ipairs(members) do
        if id ~= head then pending[id] = true end
    end

    local progressed = true
    while progressed do
        progressed = false
        for id in pairs(pending) do
            local data = db.buttons[id]
            if placed[data.DockTo] then
                local btn       = getOrCreateButton(id)
                local anchorBtn = buttons[data.DockTo]
                if btn and anchorBtn then
                    local info = DockOffset[data.Side] or DockOffset.LEFT
                    btn:ClearAllPoints()
                    btn:SetPoint(data.Side, anchorBtn, OppositeSide[data.Side],
                        info.xoff * (c.spacing or 4), info.yoff * (c.spacing or 4))
                    btn:Show()
                end
                placed[id]  = true
                pending[id] = nil
                progressed  = true
            end
        end
    end
    -- A dangling DockTo (its anchor isn't actually in this cluster, shouldn't
    -- normally happen) falls back to sitting on the head rather than being lost.
    for id in pairs(pending) do
        local btn = getOrCreateButton(id)
        if btn then
            btn:ClearAllPoints()
            btn:SetPoint("CENTER", headBtn, "CENTER")
            btn:Show()
        end
    end
end

-- Re-roots a cluster's dock chain at `newHead` by reversing every link between
-- it and the old head. Used when the dragged button isn't the one its cluster
-- currently hangs from.
local function reroot(newHead)
    local db = Layout()
    local prev, prevSide = nil, nil
    local id, guard = newHead, 0
    while id and guard < 24 do
        local data = db.buttons[id]
        if not data then break end
        local nextID, nextSide = data.DockTo, data.Side
        data.DockTo, data.Side = prev, prevSide
        prev     = id
        prevSide = nextSide and OppositeSide[nextSide] or nil
        id       = nextID
        guard    = guard + 1
    end
end

-- Anything docked to a departing button re-links to that button's own anchor, so
-- the tail isn't orphaned. If it was the head, the first child takes over.
local function relinkChildren(id)
    local db     = Layout()
    local data   = db.buttons[id]
    if not data then return end
    local anchor = data.DockTo
    local newHead
    for other, odata in pairs(db.buttons) do
        if other ~= id and odata.DockTo == id then
            if anchor then
                odata.DockTo = anchor
            elseif newHead then
                odata.DockTo = newHead
            else
                odata.DockTo, odata.Side = nil, nil
                newHead = other
            end
        end
    end
end

-- ── Docking brackets ─────────────────────────────────────────────────────────
-- Two thin coloured bars lighting up the edges about to be joined. Plain
-- textures rather than ItemRack's bracket art, so no media ships with this.
local brackets = {}
local function getBracket(which)
    if brackets[which] then return brackets[which] end
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("TOOLTIP")
    local tex = f:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints()
    tex:SetTexture(WHITE)
    tex:SetVertexColor(0.984, 0.173, 0.212, 0.9)
    f.tex = tex
    f:Hide()
    brackets[which] = f
    return f
end

local function hideBrackets()
    for _, f in pairs(brackets) do f:Hide() end
    IR.docking = nil
end

-- `side` is the edge of `frame` being highlighted. Brackets are plain frames
-- reparented onto the button they highlight — safe, since the bracket is never
-- secure and the button itself isn't the thing being reparented.
local function showBracket(which, side, frame)
    local f = getBracket(which)
    f:ClearAllPoints()
    f:SetParent(frame)
    f:SetFrameStrata("TOOLTIP")
    if side == "LEFT" or side == "RIGHT" then
        f:SetSize(3, frame:GetHeight())
    else
        f:SetSize(frame:GetWidth(), 3)
    end
    f:SetPoint(side, frame, side, 0, 0)
    f:Show()
end

-- ── Dragging and docking ─────────────────────────────────────────────────────

local function near(a, b)
    return a and b and math.abs(a - b) < 12
end

local dockTicker

-- While a cluster is dragged, look for one of its buttons flush against a button
-- of another cluster. Comparisons are in screen space, so two clusters at
-- different scales still snap sensibly.
local function clusterDocking()
    local moving = IR.clusterMoving
    if not moving then
        if dockTicker then dockTicker:Cancel(); dockTicker = nil end
        return
    end
    hideBrackets()

    local movingData = Layout().buttons[moving:GetID()]
    if not movingData then return end
    local movingID = movingData.cluster
    local sources  = clusterMembers(movingID)

    for _, cid in ipairs(clusterIDs()) do
        if cid ~= movingID then
            for _, targetID in ipairs(clusterMembers(cid)) do
                local dst = buttons[targetID]
                if dst and dst:IsShown() then
                    for _, srcID in ipairs(sources) do
                        local src = buttons[srcID]
                        if src and src:IsShown() then
                            local side
                            if near(src:GetLeft(), dst:GetRight())
                                and (near(src:GetTop(), dst:GetTop()) or near(src:GetBottom(), dst:GetBottom())) then
                                side = "LEFT"
                            elseif near(src:GetRight(), dst:GetLeft())
                                and (near(src:GetTop(), dst:GetTop()) or near(src:GetBottom(), dst:GetBottom())) then
                                side = "RIGHT"
                            elseif near(src:GetTop(), dst:GetBottom())
                                and (near(src:GetLeft(), dst:GetLeft()) or near(src:GetRight(), dst:GetRight())) then
                                side = "TOP"
                            elseif near(src:GetBottom(), dst:GetTop())
                                and (near(src:GetLeft(), dst:GetLeft()) or near(src:GetRight(), dst:GetRight())) then
                                side = "BOTTOM"
                            end
                            if side then
                                showBracket("main", side, src)
                                showBracket("menu", OppositeSide[side], dst)
                                IR.docking = { side = side, from = srcID, to = targetID, into = cid }
                                return
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Pulls one button into a cluster of its own, placed where it already sits and
-- inheriting the old cluster's look. Pure bookkeeping — layoutCluster does the
-- actual re-anchoring.
local function splitButton(id)
    local db   = Layout()
    local data = db.buttons[id]
    if not data then return end
    local oldCid = data.cluster
    local old    = oldCid and clusterData(oldCid) or nil
    local px, py = buttonAbsolutePosition(buttons[id])

    relinkChildren(id)
    local cid = newCluster(px, py, old)
    data.cluster = cid
    data.DockTo, data.Side = nil, nil

    if oldCid then layoutCluster(oldCid) end
    layoutCluster(cid)
    return cid
end

-- No combat guard on StartMoving() itself; only the SetPoint/SetScale layout in
-- layoutCluster needs one. Dragging the head carries every docked sibling for
-- free, since their anchors are relative to it.
local function startMovingButton(self)
    if getData().locked or IR.editMode then return end
    local db   = Layout()
    local data = db.buttons[self:GetID()]
    if not data then return end

    local cid = data.cluster
    if IsShiftKeyDown() and data.DockTo then
        if InCombatLockdown() then
            IR.Print("Sorry, you can't pull a button out of a bar during combat.")
            return
        end
        cid = splitButton(self:GetID())
    end
    if not cid then return end

    local headBtn = buttons[clusterHead(cid, clusterMembers(cid))]
    if not headBtn then return end

    IR.clusterMoving = headBtn
    applyClusterClamp(cid)
    headBtn:StartMoving()
    if dockTicker then dockTicker:Cancel() end
    dockTicker = C_Timer.NewTicker(0.2, clusterDocking)
end

local function stopMovingButton()
    local headBtn = IR.clusterMoving
    if not headBtn then return end
    if dockTicker then dockTicker:Cancel(); dockTicker = nil end
    headBtn:StopMovingOrSizing()

    local db   = Layout()
    local data = db.buttons[headBtn:GetID()]
    local cid  = data and data.cluster
    local dock = IR.docking
    IR.clusterMoving = nil
    hideBrackets()
    if not cid then return end

    if dock and not InCombatLockdown() then
        -- Merge into the target cluster: the dragged button that touched becomes the
        -- link, so re-root its own cluster on it first. Every member then adopts the
        -- target's scale, padding and alpha.
        reroot(dock.from)
        db.buttons[dock.from].DockTo = dock.to
        db.buttons[dock.from].Side   = dock.side
        for _, id in ipairs(clusterMembers(cid)) do
            db.buttons[id].cluster = dock.into
        end
        db.clusters[cid] = nil
        -- The dragged bar's own head just became an ordinary member; drop the
        -- clamp rect it was carrying so it can't fight its new anchor.
        headBtn:SetClampRectInsets(0, 0, 0, 0)
        layoutCluster(dock.into)
    else
        saveClusterHeadPosition(cid)
    end
end

-- ── Button creation ──────────────────────────────────────────────────────────

-- Parented to UIParent for life — see the Clusters comment for why it must never
-- be SetParent()'d again.
function getOrCreateButton(id)
    if buttons[id] then return buttons[id] end
    -- Secure frames and SetAttribute are both blocked in combat; callers must
    -- tolerate a nil and retry once combat drops.
    if InCombatLockdown() then return nil end

    local btn = CreateFrame("CheckButton", "DrievIRButton" .. id, UIParent,
        "ActionButtonTemplate,SecureActionButtonTemplate")
    btn:SetID(id)
    btn:SetSize(BTN_SIZE, BTN_SIZE)
    btn:SetMovable(true)
    -- Clamping is handed to whichever button heads this one's bar, by
    -- layoutCluster; see applyClusterClamp for why it can't be per-button.
    btn:SetClampedToScreen(false)
    btn:RegisterForDrag("LeftButton", "RightButton")
    -- BOTH click phases, always. Using an inventory item is protected, and the
    -- client honours it on ONE physical phase only — whichever
    -- `ActionButtonUseKeyDown` names, for mouse as much as keybind. A button on the
    -- other phase still gets its OnClick, but the protected use is silently refused,
    -- which is what left these unable to activate anything by mouse. Registering
    -- both puts a use on the accepted phase and the other no-ops. PostClick now
    -- arrives twice per press, so IR.ButtonPostClick keeps only the CVar's phase.
    btn:RegisterForClicks("LeftButtonDown", "LeftButtonUp", "RightButtonDown", "RightButtonUp")
    styleSlotButton(btn, BTN_SIZE)

    if id < SET_BTN then
        btn:SetAttribute("type", "item")
        btn:SetAttribute("slot", id)
    end

    local icon = btn.icon or _G["DrievIRButton" .. id .. "Icon"]
    icon:SetAllPoints(btn)
    btn.Icon = icon   -- Masque

    local cd = btn.cooldown or _G["DrievIRButton" .. id .. "Cooldown"]
    if cd then
        cd:SetDrawBling(false)
        cd:SetSwipeColor(0, 0, 0, 0.8)
        btn.Cooldown = cd
    end

    -- Own regions rather than the template's, whose names and anchors have moved
    -- around between client versions.
    local count = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    count:SetPoint("BOTTOMRIGHT", -2, 2)
    btn.irCount = count

    local hotkey = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmallGray")
    hotkey:SetPoint("TOPRIGHT", -2, -2)
    btn.irHotKey = hotkey

    local name = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmallOutline")
    name:SetPoint("BOTTOM", 0, 2)
    name:SetWidth(BTN_SIZE + 8)
    btn.irName = name

    local time = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    time:SetPoint("BOTTOM", 0, 2)
    btn.irTime = time

    -- Small overlay showing what's waiting to swap in once combat ends. Inset into
    -- the button rather than hung off its corner, so it can't overlap whatever the
    -- button is docked against.
    local queue = btn:CreateTexture(nil, "OVERLAY")
    queue:SetSize(16, 16)
    queue:SetPoint("TOPLEFT", 2, -2)
    queue:Hide()
    btn.irQueue = queue

    btn:SetCheckedTexture("Interface\\Buttons\\CheckButtonHilight")
    local ct = btn:GetCheckedTexture()
    if ct then
        ct:SetBlendMode("ADD")
        ct:ClearAllPoints()
        ct:SetAllPoints(btn)
        btn.Checked = ct
    end

    btn:SetScript("OnDragStart", startMovingButton)
    btn:SetScript("OnDragStop",  stopMovingButton)
    btn:SetScript("OnEnter", function(self)
        if IR.editMode then return end
        IR.InventoryTooltip(self, self:GetID())
        local d = getData()
        if IR.clusterMoving or d.menuOnRight then return end
        if d.menuOnShift and not IsShiftKeyDown() then return end
        IR.DockMenuToButton(self:GetID())
        IR.BuildMenu(self:GetID())
    end)
    btn:SetScript("OnLeave", function() IR.ClearTooltip() end)
    btn:SetScript("PostClick", function(self, mouseButton, down)
        IR.ButtonPostClick(self, mouseButton, down)
    end)

    IR.AddToMasque("buttons", btn)

    buttons[id] = btn
    return btn
end

-- ── Adding / removing buttons ────────────────────────────────────────────────

-- Every new button lands mid-screen as its own bar, never bolted onto the last
-- one — joining bars is a deliberate drag. Successive spawns step down and right
-- by a cell so several land as a readable stack.
local function centreSpawnPosition()
    local n     = #clusterIDs() % 8
    local scale = getData().buttonScale or 1
    local w, h  = UIParent:GetWidth(), UIParent:GetHeight()
    return w / 2 - (BTN_SIZE * scale) / 2 + n * 12,
           h / 2 + (BTN_SIZE * scale) / 2 - n * 12
end

function IR.AddButton(id)
    if InCombatLockdown() then
        IR.Print("Sorry, you can't add or remove buttons during combat.")
        return
    end
    local saved = Layout().buttons
    local btn = getOrCreateButton(id)
    if not btn then return end

    saved[id] = { cluster = newCluster(centreSpawnPosition()) }

    btn.icon:SetTexture(IR.GetTextureBySlot(id))
    layoutCluster(saved[id].cluster)
    IR.UpdateButtonCooldowns()
    IR.UpdateHotKeys()
    if id == SET_BTN then IR.UpdateCurrentSet() end
end

function IR.RemoveButton(id)
    if InCombatLockdown() then
        IR.Print("Sorry, you can't add or remove buttons during combat.")
        return
    end
    local saved = Layout().buttons
    local data  = saved[id]
    if not data then return end
    local cid = data.cluster

    relinkChildren(id)
    saved[id] = nil
    if buttons[id] then
        buttons[id]:Hide()
        buttons[id]:SetClampRectInsets(0, 0, 0, 0)
    end
    if cid then layoutCluster(cid) end
end

function IR.ToggleButton(id)
    if Layout().buttons[id] then
        IR.RemoveButton(id)
    else
        IR.AddButton(id)
    end
end

function IR.ResetButtons()
    for id in pairs(Layout().buttons) do IR.RemoveButton(id) end
    local layout = Layout()
    wipe(layout.clusters)
    layout.nextCluster = 1
    local d = getData()
    d.buttonAlpha, d.buttonScale, d.buttonSpacing = 1, 1, 4
    d.menuScale, d.locked = 0.85, false
end

-- Rebuilds every cluster from saved data, and sweeps up any button whose cluster
-- record went missing by giving it one of its own rather than leaving it
-- unplaceable.
function IR.ConstructLayout()
    if InCombatLockdown() then return end
    local saved = Layout().buttons

    -- Frames live for the session but their layout belongs to the profile, so a
    -- profile switch can leave a button on screen the new profile doesn't ask for.
    -- Nothing else hides those.
    for id, btn in pairs(buttons) do
        if not saved[id] then
            btn:Hide()
            btn:SetClampRectInsets(0, 0, 0, 0)
        end
    end

    for id, data in pairs(saved) do
        if not data.cluster then
            data.cluster = newCluster()
            data.DockTo, data.Side = nil, nil
        end
    end
    -- A DockTo pointing at a button that no longer exists (or lives in another
    -- cluster) would leave this one stacked on the head; promote it instead.
    for id, data in pairs(saved) do
        local anchor = data.DockTo and saved[data.DockTo]
        if data.DockTo and (not anchor or anchor.cluster ~= data.cluster) then
            data.DockTo, data.Side = nil, nil
        end
    end

    for _, cid in ipairs(clusterIDs()) do layoutCluster(cid) end

    -- Drop settings for clusters that no longer have any members.
    local live = {}
    for _, cid in ipairs(clusterIDs()) do live[cid] = true end
    for cid in pairs(Layout().clusters) do
        if not live[cid] then Layout().clusters[cid] = nil end
    end

    IR.UpdateButtons()
end

-- ── Button visuals ───────────────────────────────────────────────────────────

function IR.UpdateButtons()
    for id in pairs(Layout().buttons) do
        local btn = buttons[id]
        if btn then
            if id < SET_BTN then
                btn.icon:SetTexture(IR.GetTextureBySlot(id))
            end
            if id == 0 then
                -- Ammo is the one slot where the stack size matters more than
                -- the icon, so it carries a count.
                local baseID = IR.GetIRString(GetID(0), true)
                btn.irCount:SetText(baseID ~= 0 and GetItemCount(baseID) or "")
            end
        end
    end
    IR.UpdateCurrentSet()
    IR.UpdateButtonCooldowns()
end

function IR.UpdateButtonCooldowns()
    local showNumbers = getData().cooldownCount
    for id in pairs(Layout().buttons) do
        local btn = buttons[id]
        if btn and id < SET_BTN then
            if btn.Cooldown then
                CooldownFrame_Set(btn.Cooldown, GetInventoryItemCooldown("player", id))
            end
            -- WriteButtonCooldowns bails out entirely when numbers are off, so
            -- clear here or the last drawn number would stay on the button.
            if not showNumbers then btn.irTime:SetText("") end
        end
    end
    IR.WriteButtonCooldowns()
end

-- Numeric cooldown text, when the user has asked for it instead of (or on top
-- of) the sweep.
local function writeCooldown(fontString, start, duration)
    local d = getData()
    if not fontString then return end
    if start == 0 or not d.cooldownCount then
        fontString:SetText("")
        return
    end
    local remain = duration - (GetTime() - start)
    if remain < 3 and not fontString:GetText() then
        -- The global cooldown looks identical to a real one here; showing it
        -- would just make every button flicker on every cast.
        return
    end
    local threshold = d.cooldown90 and 90 or 60
    if remain < threshold then
        fontString:SetText(math.floor(remain + 0.5) .. " s")
    elseif remain < 3600 then
        fontString:SetText(math.ceil(remain / 60) .. " m")
    else
        fontString:SetText(math.ceil(remain / 3600) .. " h")
    end
end

function IR.WriteButtonCooldowns()
    if not getData().cooldownCount then return end
    for id in pairs(Layout().buttons) do
        local btn = buttons[id]
        if btn and id < SET_BTN then
            writeCooldown(btn.irTime, GetInventoryItemCooldown("player", id))
        end
    end
end

function IR.UpdateButtonLocks()
    for id in pairs(Layout().buttons) do
        local btn = buttons[id]
        if btn and id < SET_BTN then
            btn.icon:SetDesaturated(IsInventoryItemLocked(id) and true or false)
        end
    end
end

local mouseFocusFrame = addon.GetMouseFocusFrame

-- Walks up from whatever has mouse focus, because the focus can be a child
-- region of the button (its cooldown frame) rather than the button itself.
function IR.HoveredSlotButtonID()
    local focus = mouseFocusFrame()
    while focus do
        if focus.GetID then
            local id = focus:GetID()
            if id and buttons[id] == focus then return id end
        end
        focus = focus.GetParent and focus:GetParent() or nil
    end
end

-- How a slot button is referred to in prompts and messages.
function IR.SlotButtonLabel(id)
    if id == SET_BTN then return "the equipment set button" end
    local info = IR.SlotInfo[id]
    return "the " .. (info and string.lower(info.real) or ("slot " .. id)) .. " button"
end

-- ── Keybind text ─────────────────────────────────────────────────────────────

-- Same abbreviations the action bars use (LibKeyBound's ToShortKey), written out
-- here rather than reached for, because LibKeyBound ships with the Action Bars
-- module and this one has to stand alone.
--
-- Order matters: each replacement runs on the last one's result, so longer names
-- must be consumed before the shorter ones they contain (PAGEUP before UP).
local KEY_SHORTENINGS = {
    { "ALT%-",   "A" },
    { "CTRL%-",  "C" },
    { "SHIFT%-", "S" },
    { "META%-",  "M" },

    { "NUMPAD",   "NP" },
    { "PLUS",     "+"  },
    { "MINUS",    "-"  },
    { "MULTIPLY", "*"  },
    { "DIVIDE",   "/"  },
    { "DECIMAL",  "."  },

    { "MOUSEWHEELDOWN", "WD"  },
    { "MOUSEWHEELUP",   "WU"  },
    { "BACKSPACE",      "BS"  },
    { "CAPSLOCK",       "Cp"  },
    { "SCROLLLOCK",     "SL"  },
    { "NUMLOCK",        "NL"  },
    { "PAGEDOWN",       "PD"  },
    { "PAGEUP",         "PU"  },
    { "PRINTSCREEN",    "PS"  },
    { "SPACEBAR",       "Sp"  },
    { "SPACE",          "Sp"  },
    { "INSERT",         "Ins" },
    { "DELETE",         "Del" },
    { "ESCAPE",         "Esc" },
    { "CLEAR",          "Cl"  },
    { "HOME",           "HM"  },
    { "TAB",            "Tb"  },
    { "END",            "En"  },

    { "DOWNARROW",  "Dn" },
    { "LEFTARROW",  "Lf" },
    { "RIGHTARROW", "Rt" },
    { "UPARROW",    "Up" },
    { "DOWN",       "Dn" },
    { "LEFT",       "Lf" },
    { "RIGHT",      "Rt" },
    { "UP",         "Up" },
}

function IR.AbbreviateKey(key)
    if not key or key == "" then return "" end
    key = string.upper(key)
    key = string.gsub(key, " ", "")
    for _, pair in ipairs(KEY_SHORTENINGS) do
        key = string.gsub(key, pair[1], pair[2])
    end
    -- Mouse buttons read as M3 / SM4 rather than B3 / SB4, matching the Action
    -- Bars module's own retint of LibKeyBound's table.
    key = string.gsub(key, "BUTTON(%d+)", "M%1")
    return key
end

-- Font, size, colour and position of a button's keybind text, from the shared
-- font block (core's Font.lua). The block's defaults reproduce the treatment
-- LibActionButton gives the action bars (the game's number font, an explicit
-- size, OUTLINE): the font object's own drop shadow is what made this text look
-- softer than theirs, and outline is what keeps small text crisp against an icon.
--
-- The offsets are the block's, so the anchor itself is the bare corner.
local HOTKEY_DEFAULT = addon.Font.New({
    font = "Arial Narrow", size = 13, x = -2, y = -2,
})
local HOTKEY_LEGACY = {
    size  = "hotkeyFontSize", x = "hotkeyOffsetX", y = "hotkeyOffsetY",
    color = "hotkeyColor",
}

local function applyHotKeyStyle(btn)
    local d    = getData()
    local text = btn.irHotKey

    -- Adopt upgrades a profile that stored the face as a bare LSM name (or as
    -- `false`, meaning the game's own font) alongside flat size/offset/colour keys.
    local cfg = addon.Font.Adopt(d, "hotkeyFont", HOTKEY_LEGACY)
    addon.Font.ApplyAt(text, cfg, HOTKEY_DEFAULT, {
        point = "TOPRIGHT", relativeTo = btn, relativePoint = "TOPRIGHT",
        justifyH = "RIGHT",
    })
    -- The block's own colour, which is where the separate hotkeyColor setting
    -- went: one font, one set of controls. White while it is unticked, which is
    -- what hotkeyColor defaulted to.
    addon.Font.ApplyColor(text, cfg, HOTKEY_DEFAULT, 1, 1, 1)
end

function IR.UpdateHotKeys()
    local show = getData().showHotKeys
    for id in pairs(Layout().buttons) do
        local btn = buttons[id]
        if btn then
            applyHotKeyStyle(btn)
            btn.irHotKey:SetText(show and IR.AbbreviateKey(IR.GetSlotBindingKey(id)) or "")
        end
    end
end

-- ── Keypress feedback ────────────────────────────────────────────────────────
-- Keys are bound to a hidden twin (see IR.SetSlotBinding), so the visible button
-- hears nothing unless the twin passes it on. The twin registers both phases, so
-- a keypress arrives as a down click and (where the client sends one) a matching
-- up click — which is what lets the pushed state last as long as the key is held.
-- PRESS_STUCK is a safety net for a release that never arrives.
--
-- PRESS_FLASH covers the one case where no release can come: a client sending
-- only the UP half, where the up click IS the press, so it gets a fixed flash.
local PRESS_FLASH = 0.2
local PRESS_STUCK = 5

local heldID, heldToken, lastPressID = nil, 0, nil

local function releaseSlotButton()
    local btn = heldID and buttons[heldID]
    heldID = nil
    if btn and btn:GetButtonState() == "PUSHED" then btn:SetButtonState("NORMAL") end
end

-- Called from the twin's PostClick. `down` is false on the release half of a
-- press, true (or nil on a client that doesn't pass it) on the way down.
function IR.SlotButtonClicked(id, down)
    local btn = buttons[id]
    if not btn then return end

    -- The release that answers a press we're showing.
    if down == false and lastPressID == id then
        lastPressID = nil
        if heldID == id then releaseSlotButton() end
        return
    end

    -- Otherwise this is the press — including a release with no press behind it (see
    -- PRESS_FLASH). `lastPressID` is only set from a genuine down click, so an
    -- up-only client's clicks can't be mistaken for each other's halves.
    local paired = down ~= false
    if heldID and heldID ~= id then releaseSlotButton() end
    heldID = id
    btn:SetButtonState("PUSHED")
    if paired then lastPressID = id end

    heldToken = heldToken + 1
    local token = heldToken
    C_Timer.After(paired and PRESS_STUCK or PRESS_FLASH, function()
        if heldToken == token and heldID == id then releaseSlotButton() end
    end)
end

-- Buttons have no container to hide as a unit, so this hides each one
-- individually — same as upstream ItemRack's ReflectHideOOC.
function IR.ReflectHideOOC()
    -- Combat events fire whether or not the module is on, and this would happily
    -- re-show buttons the master toggle had just hidden.
    if not getData().enabled then return end

    -- Both calls below are protected: these are SecureActionButtonTemplate
    -- buttons, so Show() and Hide() are refused in combat — even when the frame
    -- is already in the state being asked for. The one in-combat caller the
    -- client lets through is PLAYER_REGEN_DISABLED, which gets a grace window
    -- before the lockdown bites; that's what makes "show them as the fight
    -- starts" work at all, and it flags itself here. Everything else arriving
    -- mid-combat — PLAYER_ALIVE and PLAYER_UNGHOST both can, and so can a zone
    -- change that re-fires PLAYER_REGEN_DISABLED with the lockdown long since up
    -- — has to wait. Nothing is lost by waiting: leaving combat fires this again,
    -- and mid-fight there was nothing to change anyway.
    if InCombatLockdown() and not IR.regenGrace then return end

    local hide = getData().hideOOC and not IR.inCombat
    for id in pairs(Layout().buttons) do
        local btn = buttons[id]
        if btn then
            if hide then btn:Hide() else btn:Show() end
        end
    end
end

function IR.ReflectAlpha()
    if menuFrame then menuFrame:SetAlpha(getData().buttonAlpha or 1) end
end

-- ── Per-cluster layout ───────────────────────────────────────────────────────
-- Scale, padding and transparency belong to a cluster, not the module, so a
-- compact trinket bar and an oversized set button can coexist. Position is kept
-- in UIParent coordinates, which is what stops a cluster wandering on rescale.

-- All three no-op on a nil cid rather than writing into the detached NO_CLUSTER
-- fallback and then laying out a bar that doesn't exist.
function IR.SetClusterScale(cid, value)
    if not cid then return end
    clusterData(cid).scale = math.max(0.5, math.min(2, value))
    layoutCluster(cid)
end

function IR.SetClusterSpacing(cid, value)
    if not cid then return end
    clusterData(cid).spacing = math.max(0, math.min(24, math.floor(value + 0.5)))
    layoutCluster(cid)
end

function IR.SetClusterAlpha(cid, value)
    if not cid then return end
    clusterData(cid).alpha = math.max(0.1, math.min(1, value))
    layoutCluster(cid)
end

-- A cluster is named after the slots it holds, so the Layout tab and Edit Mode
-- identify a bar by contents rather than a bare number. `full` lists every
-- member instead of truncating after three — a slot lives on only one bar, so
-- the full list is unique, which lets the picker tell two bars apart.
function IR.ClusterLabel(cid, full)
    local members = clusterMembers(cid)
    local names = {}
    for i, id in ipairs(members) do
        if not full and i > 3 then
            names[#names + 1] = "…"
            break
        end
        names[#names + 1] = (id == SET_BTN) and "Set" or (IR.SlotInfo[id] and IR.SlotInfo[id].real or id)
    end
    if #names == 0 then return "Item Rack bar" end
    return "Item Rack: " .. table.concat(names, ", ")
end

-- Re-applies the module-wide defaults to every existing cluster. Used by the
-- "Apply to all bars" buttons in the Layout tab.
function IR.ApplyDefaultsToAllClusters()
    local d = getData()
    for _, cid in ipairs(clusterIDs()) do
        local c = clusterData(cid)
        c.scale   = d.buttonScale   or 1
        c.spacing = d.buttonSpacing or 4
        c.alpha   = d.buttonAlpha   or 1
        layoutCluster(cid)
    end
end

-- Right-click opening menus needs the secure right-click to be suppressed, or
-- the client fires the item instead of (only) opening the menu.
function IR.ReflectMenuOnRight()
    if InCombatLockdown() then return end
    local noop = getData().menuOnRight and ATTRIBUTE_NOOP or nil
    for id, btn in pairs(buttons) do
        if id < SET_BTN then btn:SetAttribute("slot2", noop) end
    end
end

function IR.ReflectAltClick()
    if InCombatLockdown() then return end
    local noop = getData().disableAltClick and nil or ATTRIBUTE_NOOP
    for id, btn in pairs(buttons) do
        if id < SET_BTN then btn:SetAttribute("alt-slot*", noop) end
    end
end

-- Every "Lock bars" checkbox registers here rather than each place overwriting a
-- single global sync function: several can exist at once, and locking from any
-- one has to be reflected in the rest.
IR.LockCheckboxes = IR.LockCheckboxes or {}

function IR.RegisterLockCheckbox(cb)
    if cb then table.insert(IR.LockCheckboxes, cb) end
end

function IR.ReflectLock()
    if menuFrame then
        local locked = getData().locked
        -- The background/border is the "this can be dragged" cue for a menu docked to a
        -- movable cluster button. The set editor docks the same shared menuFrame to its
        -- non-movable slot buttons, where the cue would be meaningless.
        local showBorder = not locked and IR.menuMovable and true or false
        menuFrame:EnableMouse(not locked)
        menuFrame:SetBackdropBorderColor(0.3, 0.3, 0.3, showBorder and 1 or 0)
        menuFrame:SetBackdropColor(0, 0, 0, showBorder and 0.85 or 0)
    end
    -- Keep every registered checkbox honest, whichever control was used to
    -- flip the lock.
    local locked = getData().locked and true or false
    for _, cb in ipairs(IR.LockCheckboxes) do cb:SetChecked(locked) end
end

-- Brief checked flash so a swap or use registers visually.
function IR.FlashButton(id)
    local btn = buttons[id]
    if not btn then return end
    btn:SetChecked(false)
    btn:SetChecked(true)
    if btn.flashTimer then btn.flashTimer:Cancel() end
    btn.flashTimer = C_Timer.NewTimer(0.5, function()
        btn.flashTimer = nil
        btn:SetChecked(false)
    end)
end

-- The set button shows the current set's icon and name while gear matches it, or
-- while the engine is still working towards it — that case fades the icon rather
-- than swapping it, which would flicker to the generic icon and back as the
-- pending move lands. Once gear has drifted with nothing fixing it, it falls
-- back to the default gear icon with no label.
function IR.UpdateCurrentSet()
    local db  = DB()
    local set = db.currentSet and db.sets[db.currentSet]

    local setname, texture, desaturate = "", IR.DEFAULT_SET_ICON, false
    if set then
        if IR.IsSetEquipped(db.currentSet) then
            setname, texture = db.currentSet, set.icon or IR.DEFAULT_SET_ICON
        elseif IR.SetSwapInProgress() then
            setname, texture, desaturate = db.currentSet, set.icon or IR.DEFAULT_SET_ICON, true
        end
    end

    local btn = buttons[SET_BTN]
    if btn and Layout().buttons[SET_BTN] then
        btn.icon:SetTexture(texture)
        btn.icon:SetDesaturated(desaturate)
        btn.irName:SetText(setname)
    end
end

-- Pending-swap overlay, both on our own buttons and on the character sheet.
function IR.UpdateCombatQueue()
    -- Which set the queued items belong to, if any — IR.combatSet only means
    -- anything while the queue still holds something, since EquipItemByID queues
    -- single items with no set behind them.
    local queuedSet = next(IR.CombatQueue) and IR.combatSet
    if queuedSet and string.match(queuedSet, "^~") then queuedSet = nil end

    for id in pairs(Layout().buttons) do
        local btn = buttons[id]
        if btn then
            local texture
            if id == SET_BTN then
                -- The set button owns no inventory slot, so it shows the set
                -- that's waiting for combat to end rather than a single item.
                local set = queuedSet and DB().sets[queuedSet]
                if set then texture = set.icon or IR.DEFAULT_SET_ICON end
            else
                local queued = IR.CombatQueue[id]
                if queued then texture = select(2, IR.GetInfoByID(queued)) end
            end
            if texture then
                btn.irQueue:SetTexture(texture)
                btn.irQueue:Show()
            else
                btn.irQueue:Hide()
            end
        end
    end
    for i = 1, 19 do
        local overlay = IR.sheetQueue and IR.sheetQueue[i]
        if overlay then
            local queued = IR.CombatQueue[i]
            if queued then
                overlay:SetTexture(select(2, IR.GetInfoByID(queued)))
                overlay:Show()
            else
                overlay:Hide()
            end
        end
    end
end

-- ── Button clicks ────────────────────────────────────────────────────────────

-- Which half of a click counts as the press. The buttons register both phases so
-- the protected use lands on the accepted one, but everything non-secure must
-- happen exactly once — otherwise one right-click would open a menu and close it
-- again. Tied to the same CVar rather than a fixed phase. `down` is nil on a
-- client that doesn't pass it, where only one phase arrives.
local function isPressPhase(down)
    if down == nil then return true end
    return down == (GetCVarBool("ActionButtonUseKeyDown") and true or false)
end

function IR.ButtonPostClick(self, mouseButton, down)
    self:SetChecked(false)
    if not isPressPhase(down) then return end
    local id = self:GetID()
    local d  = getData()

    if mouseButton == "RightButton" and d.menuOnRight then
        if menuFrame and menuFrame:IsShown() and IR.menuOpen == id then
            IR.HideMenu()
        else
            IR.DockMenuToButton(id)
            IR.BuildMenu(id)
        end

    elseif IsShiftKeyDown() then
        if id < SET_BTN then
            if ChatFrame1EditBox:IsVisible() then
                ChatFrame1EditBox:Insert(GetInventoryItemLink("player", id) or "")
            end
        elseif DB().currentSet then
            IR.UnequipSet(DB().currentSet)
        end

    elseif IsAltKeyDown() and not d.disableAltClick then
        -- Alt+click created this button, so Alt+click takes it away again.
        IR.RemoveButton(id)

    elseif id == SET_BTN then
        -- Equipping the current set is all a left click does. Opening the set editor
        -- used to be the catch-all for every OTHER click, which is how a click that
        -- missed the left button threw the window open mid-fight. It's per mouse
        -- button now: right click owns the editor (on by default — it has nothing
        -- else to do, unless menuOnRight has taken it for the set menu), and left
        -- click only offers it as an opt-in for when there's no set to equip.
        if mouseButton == "LeftButton" and DB().currentSet then
            if d.equipToggle then
                IR.ToggleSet(DB().currentSet)
            else
                IR.EquipSet(DB().currentSet)
            end
        elseif mouseButton == "RightButton" then
            if d.setEditorOnRight then IR.ToggleSetEditor() end
        elseif d.setEditorOnLeft then
            IR.ToggleSetEditor()
        end

    else
        IR.ReflectItemUse(id)
    end
end

-- ── Menu ─────────────────────────────────────────────────────────────────────

-- Where the menu sits is a per-bar preference, and it SNAPS: dropping it picks
-- one of the eight corner pairings ItemRack has always used rather than leaving
-- it under the mouse, so it can't drift or be lost off screen. Which side each
-- pairing puts the menu on is buildMenuDockInfo; this is the map from a snap
-- decision back to the { mainDock, menuDock } producing it.
local SnapDocks = {
    -- Beside the button: aligning tops makes the menu hang downwards, aligning
    -- bottoms makes it rise.
    RIGHT  = { alignTop    = { "TOPRIGHT",    "TOPLEFT"     },
               alignBottom = { "BOTTOMRIGHT", "BOTTOMLEFT"  } },
    LEFT   = { alignTop    = { "TOPLEFT",     "TOPRIGHT"    },
               alignBottom = { "BOTTOMLEFT",  "BOTTOMRIGHT" } },
    -- Above or below it: aligning left edges makes the menu run right, aligning
    -- right edges makes it run left.
    TOP    = { alignLeft   = { "TOPLEFT",     "BOTTOMLEFT"  },
               alignRight  = { "TOPRIGHT",    "BOTTOMRIGHT" } },
    BOTTOM = { alignLeft   = { "BOTTOMLEFT",  "TOPLEFT"     },
               alignRight  = { "BOTTOMRIGHT", "TOPRIGHT"    } },
}

-- GetLeft() and friends report in the frame's OWN coordinate space, and the menu
-- and its button are at different scales, so both must go through their
-- effective scale before they can be compared.
local function screenRect(f)
    local l, r, t, b = f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom()
    if not l then return end
    local s = f:GetEffectiveScale()
    return l * s, r * s, t * s, b * s
end

local SIDE_ORDER = { "RIGHT", "LEFT", "TOP", "BOTTOM" }

-- Where the menu would land if dropped now. Kept separate from applying it so
-- the drag preview and the drop can't disagree — one decision, read twice.
local function computeSnap()
    local owner = IR.menuOwner
    if not (menuFrame and owner) then return end

    local ml, mr, mt, mb = screenRect(menuFrame)
    local bl, br, bt, bb = screenRect(owner)
    if not (ml and bl) then return end

    -- The side it clears outright wins. Measuring the gap rather than comparing
    -- centres keeps a long strip honest: a twelve-item column's centre is nowhere
    -- near the button, but the only side it has cleared is still the one aimed at.
    local gaps = { RIGHT = ml - br, LEFT = bl - mr, TOP = mb - bt, BOTTOM = bb - mt }
    local side, best
    for _, name in ipairs(SIDE_ORDER) do
        if not best or gaps[name] > best then side, best = name, gaps[name] end
    end
    -- Dropped still overlapping the button: go by which way it has drifted.
    local dx = (ml + mr) / 2 - (bl + br) / 2
    local dy = (mt + mb) / 2 - (bt + bb) / 2
    if best <= 0 then
        if math.abs(dx) >= math.abs(dy) then
            side = dx >= 0 and "RIGHT" or "LEFT"
        else
            side = dy >= 0 and "TOP" or "BOTTOM"
        end
    end

    -- Then the alignment — which way the grid runs. A menu dropped low wants to hang
    -- down from the button's top, one dropped high to rise from its bottom. The flip
    -- needs half a button of clearance, so a drop aimed squarely at one side lands
    -- on the conventional alignment rather than on which pixel was nearer.
    local align
    if side == "RIGHT" or side == "LEFT" then
        align = dy > (bt - bb) / 2 and "alignBottom" or "alignTop"
    else
        align = dx < -(br - bl) / 2 and "alignRight" or "alignLeft"
    end

    local pair = SnapDocks[side][align]
    return side, pair[1], pair[2]
end

-- ── Snap preview ─────────────────────────────────────────────────────────────
-- A drag that snaps has to say where it will land before the mouse comes up, or
-- the menu just jumps somewhere unasked. Two live cues: an outline of the
-- footprint it will occupy, and a bar down the button edge it will attach to.

local snapGhost

local function getSnapGhost()
    if snapGhost then return snapGhost end
    local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    f:SetFrameStrata("TOOLTIP")
    f:SetBackdrop({
        bgFile   = WHITE,
        edgeFile = WHITE,
        edgeSize = 2,
        insets   = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    f:SetBackdropColor(0.984, 0.173, 0.212, 0.15)
    f:SetBackdropBorderColor(0.984, 0.173, 0.212, 0.9)
    f:Hide()
    snapGhost = f
    return f
end

local function hideSnapPreview()
    if snapGhost then snapGhost:Hide() end
    if brackets.snap then brackets.snap:Hide() end
end

-- Run from the menu's OnUpdate during a drag, recomputed a few times a second
-- rather than every frame: the outline only jumps between eight fixed places.
local SNAP_PREVIEW_STEP = 0.05
local snapPreviewAfter  = 0

local function updateSnapPreview(_, elapsed)
    snapPreviewAfter = snapPreviewAfter + (elapsed or 0)
    if snapPreviewAfter < SNAP_PREVIEW_STEP then return end
    snapPreviewAfter = 0

    local side, mainDock, menuDock = computeSnap()
    if not side then
        hideSnapPreview()
        return
    end
    local owner = IR.menuOwner
    local dockInfo = getMenuDockInfo()
    local info  = dockInfo[mainDock .. menuDock] or dockInfo.TOPLEFTBOTTOMLEFT

    -- Parented to the button at the menu's own scale, so the outline is drawn in the
    -- coordinate space the menu will be re-docked into and its size copies across
    -- as-is. Snapping never changes the menu's dimensions, only its corner.
    local ox, oy = menuDockOffset(info, getData().menuGap)
    local ghost = getSnapGhost()
    if ghost:GetParent() ~= owner then ghost:SetParent(owner) end
    ghost:SetFrameStrata("TOOLTIP")
    ghost:SetScale(menuFrame:GetScale())
    ghost:SetSize(menuFrame:GetWidth(), menuFrame:GetHeight())
    ghost:ClearAllPoints()
    ghost:SetPoint(menuDock, owner, mainDock, ox, oy)
    ghost:Show()

    showBracket("snap", side, owner)
end

-- Turns wherever the user dropped the menu into a corner pairing, and hands it
-- to the bar the menu belongs to.
local function snapMenuToOwner()
    local id = IR.menuMovable
    if not id then return end
    local data = Layout().buttons[id]
    if not (data and data.cluster) then return end

    local _, mainDock, menuDock = computeSnap()
    if not mainDock then return end

    local c = clusterData(data.cluster)
    c.mainDock, c.menuDock = mainDock, menuDock
end

-- Puts a bar's menu placement back to the default: above the button, growing up.
function IR.ResetMenuPosition(cid)
    if not cid then return end
    local c = clusterData(cid)
    c.mainDock, c.menuDock, c.menuOrient = nil, nil, nil
    IR.HideMenu()
end

-- Only menus belonging to a movable button can be dragged: the character sheet's
-- own slot menus have no bar to remember a position for. The whole menu is a
-- drag handle, entries included — a click that turns into a drag doesn't fire
-- OnClick, so a plain click on an entry still equips it.
local function startMenuDrag()
    if not menuFrame or getData().locked or not IR.menuMovable then return end
    menuFrame.isMoving = true
    menuFrame:StartMoving()
    -- Pre-armed so the outline appears on the first frame of the drag rather
    -- than a throttle step into it.
    snapPreviewAfter = SNAP_PREVIEW_STEP
    menuFrame:SetScript("OnUpdate", updateSnapPreview)
end

local function stopMenuDrag()
    if not (menuFrame and menuFrame.isMoving) then return end
    menuFrame.isMoving = nil
    menuFrame:StopMovingOrSizing()
    menuFrame:SetScript("OnUpdate", nil)
    hideSnapPreview()
    snapMenuToOwner()
    -- Re-anchor to the button (the menu is loose at the absolute spot StartMoving
    -- left it) and rebuild: the new pairing changes which corner the grid starts
    -- from and which way it runs, so the entries must be laid out again.
    if IR.menuOpen then
        IR.DockMenuToButton(IR.menuOpen)
        IR.BuildMenu()
    end
end

-- Right-clicking the menu's background — not an entry, which still equips —
-- flips which way the grid runs. Same gate as dragging.
local function cycleMenuDirection()
    if getData().locked or not IR.menuMovable then return end
    local data = Layout().buttons[IR.menuMovable]
    if not (data and data.cluster) then return end
    local c = clusterData(data.cluster)
    c.menuOrient = (c.menuOrient == "HORIZONTAL") and "VERTICAL" or "HORIZONTAL"
    if IR.menuOpen then
        IR.DockMenuToButton(IR.menuOpen)
        IR.BuildMenu()
    end
end

local function getOrCreateMenu()
    if menuFrame then return menuFrame end

    local f = CreateFrame("Frame", "DrievIRMenuFrame", UIParent, "BackdropTemplate")
    f:SetSize(getCell() + 12, getCell() + 12)
    f:SetFrameStrata("HIGH")
    -- Deliberately NOT clamped. The menu is anchored to its button and resized on
    -- every build, so a screen edge would shove it off that anchor and back over the
    -- button — and while dragging it would refuse to pass the edge at all, making
    -- "snap below" unreachable near the bottom. Snapping is what stops it being lost.
    f:SetClampedToScreen(false)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetBackdrop({
        bgFile   = WHITE,
        edgeFile = WHITE,
        edgeSize = 1,
        insets   = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    f:SetBackdropColor(0.055, 0.062, 0.115, 0.85)
    f:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    f:Hide()

    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", startMenuDrag)
    f:SetScript("OnDragStop",  stopMenuDrag)
    f:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then cycleMenuDirection() end
    end)

    menuFrame   = f
    menuButtons = {}
    return f
end

function IR.MenuIsVisible() return menuFrame and menuFrame:IsShown() end

function IR.HideMenu()
    if menuFrame then
        -- A drag can't outlive the menu: release it here too, or the frame stays
        -- stuck to the cursor and the snap outline is left hanging on the button.
        if menuFrame.isMoving then
            menuFrame.isMoving = nil
            menuFrame:StopMovingOrSizing()
        end
        menuFrame:SetScript("OnUpdate", nil)
        menuFrame:Hide()
    end
    hideSnapPreview()
    if IR.menuTicker then IR.menuTicker:Cancel(); IR.menuTicker = nil end
    IR.menuDockedTo = nil
    IR.menuLeftAt   = nil
end

-- Frames the mouse may sit over without the menu closing: the menu, its button,
-- and anything registered as keep-alive. The character sheet and set editor
-- register themselves, so crossing the gap between them doesn't dismiss it.
IR.menuKeepAlive = {}

function IR.RegisterMenuKeepAlive(f)
    if f then IR.menuKeepAlive[f] = true end
end

local function mouseIsInMenuRegion()
    if MouseIsOver(menuFrame) or IsShiftKeyDown() then return true end
    if menuFrame and menuFrame.isMoving then return true end
    if IR.menuOwner and IR.menuOwner:IsVisible() and MouseIsOver(IR.menuOwner) then return true end
    for f in pairs(IR.menuKeepAlive) do
        if f:IsVisible() and MouseIsOver(f) then return true end
    end
    return false
end

-- A menu dragged away from its button leaves bare screen between the two, and
-- crossing that gap counts as leaving the region — so it can't close the instant
-- the mouse is outside. Long enough to cross a gap in one movement, short enough
-- not to leave the menu hanging over whatever the mouse moved on to.
local MENU_LINGER = 0.25

local function menuMouseoverTick()
    if not (menuFrame and menuFrame:IsShown()) then
        if IR.menuTicker then IR.menuTicker:Cancel(); IR.menuTicker = nil end
        return
    end
    if mouseIsInMenuRegion() then
        IR.menuLeftAt = nil
        return
    end
    IR.menuLeftAt = IR.menuLeftAt or GetTime()
    if GetTime() - IR.menuLeftAt < MENU_LINGER then return end
    IR.HideMenu()
end

-- menuDock/mainDock name the corners being joined — what a drag picks by
-- snapping — and orient decides whether the grid runs sideways or up/down.
function IR.DockWindows(menuDock, relativeTo, mainDock, orient, movableID)
    local f = getOrCreateMenu()
    local key = mainDock .. menuDock
    local dockInfo = getMenuDockInfo()
    local info = dockInfo[key] or dockInfo.TOPLEFTBOTTOMLEFT
    local ox, oy = menuDockOffset(info, getData().menuGap)
    f:ClearAllPoints()
    f:SetParent(relativeTo)
    f:SetFrameStrata("HIGH")
    f:SetPoint(menuDock, relativeTo, mainDock, ox, oy)
    f:SetScale(getData().menuScale or 0.85)

    -- Reparenting doesn't renumber the frame level, and in the set editor the menu's
    -- new parent is a slot button at the same depth as the side set list and the
    -- icon grid's scrollbar, which would draw over it. Walk up to the window the
    -- button belongs to, take the deepest level on the way, and clear it.
    local deepest, node = relativeTo:GetFrameLevel(), relativeTo
    while node do
        local parent = node:GetParent()
        if not parent or parent == UIParent or parent == WorldFrame then break end
        node = parent
        deepest = math.max(deepest, node:GetFrameLevel())
    end
    f:SetFrameLevel(deepest + 20)

    IR.currentDock   = key
    IR.mainDock      = mainDock
    IR.menuDock      = menuDock
    IR.menuOrient    = orient
    IR.menuMovable   = movableID
    IR.menuOwner     = relativeTo
    IR.menuDockedTo  = relativeTo:GetName()
    IR.ReflectLock()
end

function IR.DockMenuToButton(id)
    local d = getData()
    -- Trinket menu mode merges both trinket slots into one menu anchored to
    -- whichever trinket the user nominated.
    if (id == 13 or id == 14) and d.trinketMenuMode and Layout().buttons[13] and Layout().buttons[14] then
        id = 13 + (d.anchorOther and 1 or 0)
    end
    local btn = buttons[id]
    if not btn then return end
    -- Menu placement is a per-bar preference, so it lives on the cluster rather
    -- than on the individual button.
    local data = Layout().buttons[id]
    local c    = (data and data.cluster) and clusterData(data.cluster) or {}
    IR.DockWindows(c.menuDock or "BOTTOMLEFT", btn, c.mainDock or "TOPLEFT",
        c.menuOrient or "VERTICAL", id)
end

local function getOrCreateMenuButton(index)
    if menuButtons[index] then return menuButtons[index] end
    local btn = CreateFrame("CheckButton", "DrievIRMenu" .. index, menuFrame, "ActionButtonTemplate")
    btn:SetID(index)
    btn:SetSize(BTN_SIZE, BTN_SIZE)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    styleSlotButton(btn, BTN_SIZE)
    btn.icon:SetAllPoints(btn)
    btn.Icon = btn.icon
    if btn.cooldown then
        btn.cooldown:SetDrawBling(false)
        btn.cooldown:SetSwipeColor(0, 0, 0, 0.8)
        btn.Cooldown = btn.cooldown
    end

    local count = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    count:SetPoint("BOTTOMRIGHT", -2, 2)
    btn.irCount = count

    local name = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmallOutline")
    name:SetPoint("BOTTOM", 0, 2)
    name:SetWidth(BTN_SIZE + 8)
    btn.irName = name

    local time = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    time:SetPoint("BOTTOM", 0, 2)
    btn.irTime = time

    -- Coloured outline: red = every item in the set is missing, blue = it's in
    -- the bank rather than on you.
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    border:SetBlendMode("ADD")
    border:SetSize(BTN_SIZE * 1.9, BTN_SIZE * 1.9)
    border:SetPoint("CENTER")
    border:Hide()
    btn.irBorder = border

    btn:RegisterForDrag("LeftButton")
    btn:SetScript("OnDragStart", startMenuDrag)
    btn:SetScript("OnDragStop",  stopMenuDrag)
    btn:SetScript("OnClick", function(self) IR.MenuOnClick(self) end)
    btn:SetScript("OnEnter", function(self)
        IR.MenuItemTooltip(self, menuEntries[self:GetID()])
    end)
    btn:SetScript("OnLeave", function() IR.ClearTooltip() end)

    IR.AddToMasque("menus", btn)

    menuButtons[index] = btn
    return btn
end

-- Lock / Set editor / Remove, shown as one extra cell at the end of a menu that
-- belongs to a movable button while the buttons are unlocked.
local function getOrCreateMenuControls()
    if menuControls then return menuControls end
    local f = CreateFrame("Frame", nil, menuFrame)
    f:SetSize(BTN_SIZE, BTN_SIZE)

    local defs = {
        { key = "lock",   texture = "Interface\\Buttons\\LockButton-Unlocked-Up",
          title = "Lock Buttons", body = "Prevent buttons and menus from being moved.\n\nHold Alt while opening a menu to reach these controls while locked." },
        { key = "sets",   texture = "Interface\\Icons\\INV_Misc_Gear_01",
          title = "Equipment Sets", body = "Open the set editor." },
        { key = "remove", texture = "Interface\\Buttons\\UI-GroupLoot-Pass-Up",
          title = "Remove", body = "Remove the button this menu opened from." },
    }

    for i, def in ipairs(defs) do
        local b = CreateFrame("Button", nil, f)
        b:SetSize(16, 16)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", 2 + ((i - 1) % 2) * 18, -2 - math.floor((i - 1) / 2) * 18)
        b:SetNormalTexture(def.texture)
        b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        b:SetScript("OnEnter", function(self) IR.OnTooltip(self, def.title, def.body) end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        b:SetScript("OnClick", function()
            if def.key == "lock" then
                getData().locked = not getData().locked
                IR.ReflectLock()
                IR.BuildMenu()
            elseif def.key == "sets" then
                IR.ToggleSetEditor()
                IR.HideMenu()
            else
                if IR.menuOpen then IR.RemoveButton(IR.menuOpen) end
                IR.HideMenu()
            end
        end)
    end

    menuControls = f
    return f
end

local function addToMenu(id)
    local d = getData()
    if not d.allowHidden or IsAltKeyDown() or not IR.IsHidden(id) then
        table.insert(menuEntries, id)
    end
end

local function alreadyInMenu(id)
    for _, existing in ipairs(menuEntries) do
        if existing == id then return true end
    end
end

-- Every item that could go into `slot`, from bags and (when open) the bank.
-- `include` also adds the worn item(s), which the set editor wants.
local function collectSlotEntries(slot, include)
    local d = getData()

    -- `include` means the set editor opened this menu. Whatever it already has in
    -- this slot is on the hovered button, so listing it again offers a click that
    -- changes nothing. The paired slot's item stays: picking that is a real swap.
    local skip = include and IR.GetEditorSlotID and IR.GetEditorSlotID(slot)
    if skip == 0 then skip = nil end

    if include then
        local worn = GetID(slot)
        if worn ~= 0 and worn ~= skip then addToMenu(worn) end
        local other = IR.SlotInfo[slot].other
        if other then
            local otherID = GetID(other)
            if otherID ~= 0 and otherID ~= skip then addToMenu(otherID) end
        end
    end

    local function scanBag(bag)
        for bagSlot = 1, (GetContainerNumSlots(bag) or 0) do
            local id = GetID(bag, bagSlot)
            local _, _, equipSlot = IR.GetInfoByID(id)
            if equipSlot and IR.SlotInfo[slot][equipSlot] and id ~= skip
                and IR.PlayerCanWear(slot, bag, bagSlot)
                and (not d.hideTradables or IR.IsSoulbound(bag, bagSlot)) then
                -- Ammo stacks are interchangeable, so only the first of a kind
                -- is listed; gear is listed per copy.
                if slot ~= 0 or not alreadyInMenu(id) then
                    addToMenu(id)
                end
            end
        end
    end

    for bag = 0, 4 do scanBag(bag) end

    if IR.BankOpen then
        for _, bag in ipairs(IR.BankSlots) do scanBag(bag) end
    elseif GetID(slot) ~= 0 and d.allowEmpty then
        table.insert(menuEntries, 0)
    end
end

local function collectSetEntries()
    -- Already in the user's chosen order (and already filtered of "~" scratch
    -- sets), so no sort here — sorting would undo the side list's drag order.
    for _, setname in ipairs(IR.GetOrderedSetNames()) do
        addToMenu(setname)
    end
end

-- id: 0-19 for a slot, 20 for the set list, nil to rebuild whatever is showing.
function IR.BuildMenu(id, include)
    local f = getOrCreateMenu()
    local d = getData()

    if id then
        IR.menuOpen    = id
        IR.menuInclude = include
    else
        id      = IR.menuOpen
        include = IR.menuInclude
    end
    if not id then return end

    wipe(menuEntries)
    if id < SET_BTN then
        collectSlotEntries(id, include)
    else
        collectSetEntries()
    end

    local showControls = IR.menuMovable and (IsAltKeyDown() or not d.locked)
    local cells = #menuEntries + (showControls and 1 or 0)
    if cells < 1 then
        IR.HideMenu()
        return
    end

    -- Wrap so a big menu forms a block instead of a screen-long line.
    local maxCols = 1
    if d.setMenuWrap then
        maxCols = math.max(1, d.setMenuWrapValue or 3)
    elseif cells > 24 then maxCols = 5
    elseif cells > 18 then maxCols = 4
    elseif cells > 9  then maxCols = 3
    elseif cells > 4  then maxCols = 2
    end

    local dockInfo = getMenuDockInfo()
    local info = dockInfo[IR.currentDock] or dockInfo.TOPLEFTBOTTOMLEFT
    local cell = getCell()
    local x, y = info.xstart, info.ystart
    local col, row = 0, 0

    local function place(child)
        child:ClearAllPoints()
        child:SetPoint("TOPLEFT", f, IR.menuDock, x, y)
        child:SetFrameLevel(f:GetFrameLevel() + 1)
        child:Show()
        if IR.menuOrient == "VERTICAL" then
            x = x + info.xdir * cell
            col = col + 1
            if col == maxCols then
                x, col = info.xstart, 0
                y = y + info.ydir * cell
                row = row + 1
            end
        else
            y = y + info.ydir * cell
            col = col + 1
            if col == maxCols then
                y, col = info.ystart, 0
                x = x + info.xdir * cell
                row = row + 1
            end
        end
    end

    for i, entry in ipairs(menuEntries) do
        local btn = getOrCreateMenuButton(i)
        local texture
        if id == SET_BTN then
            texture = DB().sets[entry] and DB().sets[entry].icon
        elseif entry == 0 then
            texture = select(2, GetInventorySlotInfo(IR.SlotInfo[id].name))
        else
            texture = select(2, IR.GetInfoByID(entry))
        end
        btn.icon:SetTexture(texture)
        btn.icon:SetDesaturated(d.allowHidden and IsAltKeyDown() and IR.IsHidden(entry) or false)

        btn.irBorder:Hide()
        if id == SET_BTN then
            btn.irName:SetText(entry)
            local missing = IR.MissingItems(entry)
            if missing == 0 then
                btn.irBorder:SetVertexColor(1, 0.1, 0.1); btn.irBorder:Show()
            elseif missing == 1 then
                btn.irBorder:SetVertexColor(0.3, 0.5, 1); btn.irBorder:Show()
            end
        else
            btn.irName:SetText("")
            if entry ~= 0 and IR.GetCountByID(entry) == 0 then
                btn.irBorder:SetVertexColor(0.3, 0.5, 1); btn.irBorder:Show()
            end
        end

        if id == 0 then
            local count = IR.GetCountByID(entry)
            btn.irCount:SetText(count > 0 and count or "")
        else
            btn.irCount:SetText("")
        end

        place(btn)
    end

    for i = #menuEntries + 1, #menuButtons do menuButtons[i]:Hide() end

    if showControls then
        place(getOrCreateMenuControls())
    elseif menuControls then
        menuControls:Hide()
    end

    if col == 0 then row = row - 1 end
    if IR.menuOrient == "VERTICAL" then
        f:SetSize(12 + maxCols * cell, 12 + (row + 1) * cell)
    else
        f:SetSize(12 + (row + 1) * cell, 12 + maxCols * cell)
    end

    f:SetAlpha(d.buttonAlpha or 1)
    f:Show()
    IR.UpdateMenuCooldowns()

    if IR.menuTicker then IR.menuTicker:Cancel() end
    IR.menuLeftAt = nil
    -- Polled rather than driven by OnLeave, since the menu and its button are
    -- separate frames with a gap between them. The tick must be well under
    -- MENU_LINGER or it, not the linger, sets how long the menu hangs around.
    IR.menuTicker = C_Timer.NewTicker(0.05, menuMouseoverTick)
end

function IR.UpdateMenuCooldowns()
    for i, entry in ipairs(menuEntries) do
        local btn = menuButtons[i]
        if btn and btn.Cooldown then
            local baseID = tonumber(IR.GetIRString(entry, true))
            if baseID and baseID > 0 and (IR.menuOpen or SET_BTN) < SET_BTN then
                CooldownFrame_Set(btn.Cooldown, GetItemCooldown(baseID))
            else
                btn.Cooldown:Hide()
            end
        end
    end
    IR.WriteMenuCooldowns()
end

function IR.WriteMenuCooldowns()
    if not (getData().cooldownCount and IR.MenuIsVisible()) then return end
    for i, entry in ipairs(menuEntries) do
        local btn = menuButtons[i]
        if btn then
            local baseID = tonumber(IR.GetIRString(entry, true))
            if baseID and baseID > 0 then
                writeCooldown(btn.irTime, GetItemCooldown(baseID))
            else
                btn.irTime:SetText("")
            end
        end
    end
end

-- Puts an item's link in the chat edit box, preferring a real link from the
-- copy the player actually owns and falling back to the stored id.
local function chatLinkID(id)
    local inv, bag, slot = IR.FindItem(id)
    local link
    if bag then
        link = C_Container.GetContainerItemLink(bag, slot)
    elseif inv then
        link = GetInventoryItemLink("player", inv)
    else
        _, link = GetItemInfo(IR.IRStringToItemString(IR.UpdateIRString(id)))
    end
    if link then ChatFrame1EditBox:Insert(link) end
end
IR.ChatLinkID = chatLinkID

function IR.MenuOnClick(self, mouseButton)
    self:SetChecked(false)
    local entry = menuEntries[self:GetID()]
    if entry == nil then return end
    local d = getData()
    IR.ClearLockList()

    if IsAltKeyDown() and d.allowHidden then
        IR.ToggleHidden(entry)
        IR.BuildMenu()
        return
    end

    if IsShiftKeyDown() and ChatFrame1EditBox:IsVisible() then
        chatLinkID(entry)
        return
    end

    -- The set editor takes over menu picks while it is waiting for one, so
    -- choosing an item assigns it to the set instead of equipping it.
    if IR.menuInclude and IR.OnMenuPickForEditor then
        IR.OnMenuPickForEditor(IR.menuOpen, entry)
        IR.HideMenu()
        return
    end

    if IR.menuOpen < SET_BTN then
        if IR.BankOpen then
            -- At the bank a click shuttles the item between bank and bags
            -- instead of equipping it.
            if IR.GetCountByID(entry) == 0 then
                local bankBag, bankSlot = IR.FindInBank(entry)
                if bankBag then
                    local freeBag, freeSlot = IR.FindSpace()
                    if freeBag and not SpellIsTargeting() and not GetCursorInfo() then
                        C_Container.PickupContainerItem(bankBag, bankSlot)
                        C_Container.PickupContainerItem(freeBag, freeSlot)
                    else
                        IR.Print("Not enough room in bags to pull this item from the bank.")
                    end
                end
            else
                local bankBag, bankSlot = IR.FindBankSpace()
                if bankBag then
                    local _, bag, slot = IR.FindItem(entry)
                    if bag and not SpellIsTargeting() and not GetCursorInfo() then
                        C_Container.PickupContainerItem(bag, slot)
                        C_Container.PickupContainerItem(bankBag, bankSlot)
                    end
                else
                    IR.Print("Not enough room in the bank to put this item.")
                end
            end
            return
        end

        local target = IR.menuOpen
        if target >= 13 and target <= 14 and d.trinketMenuMode
            and Layout().buttons[13] and Layout().buttons[14] then
            target = (mouseButton == "RightButton") and 14 or 13
        end
        IR.EquipItemByID(entry, target)
        IR.HideMenu()

    else
        if IR.BankOpen then
            if IR.MissingItems(entry) == 1 then
                IR.GetBankedSet(entry)
            else
                IR.PutBankedSet(entry)
            end
        else
            if d.equipToggle or IsShiftKeyDown() then
                IR.ToggleSet(entry)
            else
                IR.EquipSet(entry)
            end
            IR.HideMenu()
        end
    end
end

-- ── Character sheet integration ──────────────────────────────────────────────

-- Corner choice per slot mirrors the character sheet's own layout: the top and
-- bottom rows open downwards, the two side columns open outwards.
local function dockMenuToSheetSlot(frame, slot)
    if slot == 0 or (slot >= 16 and slot <= 18) then
        IR.DockWindows("TOPLEFT", frame, "BOTTOMLEFT", "VERTICAL")
    else
        local target = frame
        if slot == 14 and getData().trinketMenuMode and CharacterTrinket0Slot then
            target = CharacterTrinket0Slot
        end
        IR.DockWindows("TOPLEFT", target, "TOPRIGHT", "HORIZONTAL")
    end
    IR.BuildMenu(slot)
end

function IR.InitCharacterSheet()
    IR.sheetQueue = {}
    IR.RegisterMenuKeepAlive(PaperDollFrame)
    for slot = 0, 19 do
        local info  = IR.SlotInfo[slot]
        local frame = _G["Character" .. info.name]
        if frame then
            -- HookScript rather than replacing the global PaperDoll handlers:
            -- these are Blizzard frames, and a hook can't taint them.
            frame:HookScript("OnEnter", function(self)
                local d = getData()
                if not (d.enabled and d.characterSheetMenus) then return end
                if d.menuOnShift and not IsShiftKeyDown() then return end
                if IR.menuDockedTo == self:GetName() then return end
                dockMenuToSheetSlot(self, slot)
            end)
            frame:HookScript("OnClick", function()
                if not getData().enabled then return end
                if not IsAltKeyDown() then return end
                IR.ToggleButton(slot)
                -- Blizzard's handler ran first and a plain left click on a paper doll slot picks
                -- the worn item onto the cursor. Put it straight back — ClearCursor returns an
                -- inventory item to the slot it came from, so this is safe either way.
                if CursorHasItem() then ClearCursor() end
            end)

            local overlay = frame:CreateTexture(nil, "OVERLAY")
            overlay:SetSize(20, 20)
            overlay:SetPoint("TOPLEFT", -2, 2)
            overlay:Hide()
            IR.sheetQueue[slot] = overlay
        end
    end

    -- Alt+click in the empty middle of the sheet (over the character model)
    -- toggles the equipment-set button.
    local model = _G.CharacterModelFrame or _G.CharacterModelScene
    if model then
        model:HookScript("OnMouseUp", function()
            if not getData().enabled then return end
            if IsAltKeyDown() then IR.ToggleButton(SET_BTN) end
        end)
    end
end

-- ── Edit Mode ────────────────────────────────────────────────────────────────
-- Each cluster is its own movable, so Edit Mode draws one red box per bar, each
-- draggable (or positionable via the X/Y editor) independently.
--
-- The box is a purely cosmetic overlay — nothing is ever SetParent()'d to it,
-- and it exists only while Edit Mode shows it (see the Clusters section for why
-- buttons can never be reparented). It's anchored to the head button's corner
-- rather than to screen coordinates, so it tracks the bar for free while the
-- head is dragged.
local editOverlays  = {}
local clusterMovables = {}

local function getOrCreateEditOverlay(cid)
    if editOverlays[cid] then return editOverlays[cid] end
    local f = CreateFrame("Frame", "DrievIRClusterEdit" .. cid, UIParent, "BackdropTemplate")
    -- Deliberately NOT clamped: it's anchored by two corners to the head button,
    -- and clamping would stretch the box away from the bar it's meant to outline
    -- the moment the bar reaches a screen edge. The head button's own clamp
    -- (applyClusterClamp) is what keeps the bar on screen.
    f:Hide()
    editOverlays[cid] = f
    return f
end

-- (Re)sizes and (re)positions the overlay to bound every member button, all
-- anchored relative to the head so the box follows it live during a drag —
-- WoW re-evaluates the SetPoint offsets each frame, no OnUpdate needed.
local function layoutEditOverlay(cid)
    local overlay = getOrCreateEditOverlay(cid)
    local members = clusterMembers(cid)
    local head    = clusterHead(cid, members)
    local headBtn = buttons[head]
    if not headBtn or not headBtn:GetLeft() then return overlay end

    local minL, maxR = headBtn:GetLeft(), headBtn:GetRight()
    local maxT, minB = headBtn:GetTop(),  headBtn:GetBottom()
    for _, id in ipairs(members) do
        local btn = buttons[id]
        if btn and btn:GetLeft() then
            minL = math.min(minL, btn:GetLeft())
            maxR = math.max(maxR, btn:GetRight())
            maxT = math.max(maxT, btn:GetTop())
            minB = math.min(minB, btn:GetBottom())
        end
    end

    local pad = 4
    overlay:ClearAllPoints()
    overlay:SetPoint("TOPLEFT", headBtn, "TOPLEFT",
        (minL - headBtn:GetLeft()) - pad, (maxT - headBtn:GetTop()) + pad)
    overlay:SetPoint("BOTTOMRIGHT", headBtn, "TOPLEFT",
        (maxR - headBtn:GetLeft()) + pad, (minB - headBtn:GetTop()) - pad)
    return overlay
end

local function clusterMovable(cid)
    if clusterMovables[cid] then return clusterMovables[cid] end

    local m = { clusterID = cid }

    m.getLabel = function() return IR.ClusterLabel(cid) end
    -- Recomputed fresh each time Edit Mode opens, so a bar rearranged since last
    -- time still gets an accurately sized box.
    m.getFrame = function() return layoutEditOverlay(cid) end

    m.getPosition = function()
        local head = clusterHead(cid, clusterMembers(cid))
        local px, py = buttonAbsolutePosition(buttons[head])
        return px or 0, py or 0
    end

    m.setPosition = function(x, y)
        local c = clusterData(cid)
        c.px, c.py = x, y
        layoutCluster(cid)
    end

    m.savePosition = function() saveClusterHeadPosition(cid) end

    -- Movement runs off OnMouseDown/OnMouseUp rather than RegisterForDrag: it starts
    -- instantly, and the same pair does click-vs-drag detection so a plain click
    -- opens the position editor. StartMoving() targets the HEAD BUTTON (a secure
    -- frame), which the normal in-bar drag handler already does safely; what's
    -- unsafe is SetParent(), which never happens here.
    m.enterMoveMode = function()
        local overlay = layoutEditOverlay(cid)
        overlay:EnableMouse(true)
        overlay:SetFrameStrata("TOOLTIP")
        addon.ShowEditBox(overlay)
        overlay:SetScript("OnMouseDown", function(self, button)
            if button ~= "LeftButton" then return end
            self._clickX, self._clickY = GetCursorPosition()
            local headBtn = buttons[clusterHead(cid, clusterMembers(cid))]
            self._dragHead = headBtn
            if headBtn then
                applyClusterClamp(cid)
                headBtn:StartMoving()
            end
        end)
        overlay:SetScript("OnMouseUp", function(self, button)
            if button ~= "LeftButton" then return end
            if self._dragHead then self._dragHead:StopMovingOrSizing() end
            saveClusterHeadPosition(cid)
            local x, y = GetCursorPosition()
            local sx, sy = self._clickX or x, self._clickY or y
            if math.abs(x - sx) < 4 and math.abs(y - sy) < 4 then
                addon.UI.OpenPositionEditor(m, self)
            end
        end)
    end

    m.leaveMoveMode = function()
        local overlay = editOverlays[cid]
        if not overlay then return end
        overlay:SetFrameStrata("MEDIUM")
        overlay:EnableMouse(false)
        addon.HideEditBox(overlay)
        overlay:SetScript("OnMouseDown", nil)
        overlay:SetScript("OnMouseUp", nil)
        overlay:Hide()
    end

    clusterMovables[cid] = m
    return m
end

-- Clusters come and go as the user Alt+clicks slots, so Edit Mode collects them
-- through a provider (re-run every time it opens) rather than a fixed list.
UI.RegisterMovableProvider(function()
    if not getData().enabled then return {} end
    local list = {}
    for _, cid in ipairs(clusterIDs()) do
        list[#list + 1] = clusterMovable(cid)
    end
    return list
end)

-- While boxes are being positioned, hovering a button must not pop a menu over
-- them and dragging must not fight the box drag. Both gate on IR.editMode, which
-- tracks Edit Mode via post-hooks on core's enter/exit rather than polling.
hooksecurefunc(UI, "EnterMoveMode", function()
    IR.editMode = true
    IR.HideMenu()
end)
hooksecurefunc(UI, "ExitMoveMode", function()
    IR.editMode = false
end)

-- ── Init ─────────────────────────────────────────────────────────────────────

function IR.InitButtons()
    IR.InitCharacterSheet()
    if not getData().enabled then return end
    IR.ApplyEnabled()
end

-- Set when the toggle flips mid-combat, where none of the frame work below is
-- allowed; cleared by the flush on leaving combat.
local applyPending = false

-- Called at login and whenever the module's master toggle flips.
function IR.ApplyEnabled()
    -- Both ways round: switching the module off has to stop the event engine
    -- reacting, not just hide the buttons. Ahead of the combat guard because
    -- it's plain Lua — the module going quiet shouldn't have to wait for a
    -- fight to end.
    if IR.ReflectEvents then IR.ReflectEvents() end

    -- Everything past here shows, hides or moves SecureActionButtonTemplate
    -- frames, all of which the client refuses under a combat lockdown — and
    -- someone unticking the module because it's misbehaving is quite likely to
    -- be doing it mid-fight. Deferred whole rather than guarded call by call: a
    -- half-applied layout is worse than a late one.
    if InCombatLockdown() then
        applyPending = true
        return
    end
    applyPending = false

    if not getData().enabled then
        IR.HideMenu()
        -- An editor left open from before the toggle flipped would otherwise sit
        -- there fully usable while the module is off.
        if IR.HideSetEditor then IR.HideSetEditor() end
        for _, btn in pairs(buttons) do btn:Hide() end
        return
    end
    IR.ConstructLayout()
    IR.ReflectAlpha()
    IR.ReflectMenuOnRight()
    IR.ReflectAltClick()
    IR.ReflectLock()
    IR.ReflectHideOOC()
    IR.UpdateHotKeys()
    IR.UpdateCombatQueue()
end

-- Combat-deferred half of the above, from PLAYER_REGEN_ENABLED.
function IR.FlushPendingApply()
    if not applyPending then return end
    IR.ApplyEnabled()
    -- The other half of what a toggle or a profile switch asks for: IR.Refresh
    -- pairs these two, and SetSetBindings bails in combat on its own account, so
    -- whatever sent us here left its keys unapplied as well.
    IR.SetSetBindings()
end

-- Everything the settings UI can change that needs the live buttons re-derived.
-- Also runs on a profile switch.
function IR.Refresh()
    IR.MigrateHotKeyDefault()
    IR.ApplyEnabled()
    -- Slot keys live in the profile, so a switch brings a different set: apply this
    -- profile's and take the last one's back off (SetSetBindings clears any key it
    -- applied that nothing wants any more).
    IR.SetSetBindings()
    IR.UpdateHotKeys()
end
