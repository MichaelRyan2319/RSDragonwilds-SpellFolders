-- Spell Folders: on-screen UI built from plain UMG widgets at run time.
--   UI.Toast(text, seconds)   short message at the top of the screen
--   UI.Wheel(spec)            a folder's wheel, drawn like the game's spell radial
--   UI.Prompt(spec)           text box (naming a folder)
-- Only one Wheel or Prompt is open at a time. UI.Tick() must be called often
-- (about every 50 ms) on the game thread, and UI.Key(name) when a key is pressed.
local UEHelpers = require("UEHelpers")
local U = require("folders.util")

local UI = {}
local active = nil      -- the open Wheel or Prompt
local toasts = {}

local WHITE = { R = 1, G = 1, B = 1, A = 1 }
local GOLD = { R = 0.93, G = 0.78, B = 0.45, A = 1 }
local GREY = { R = 0.7, G = 0.7, B = 0.7, A = 1 }

local function New(classPath, outer, name)
    return StaticConstructObject(StaticFindObject(classPath), outer, FName(U.UniqueName(name)))
end

local function Root(name)
    local gi = UEHelpers.GetGameInstance()
    local w = New("/Script/UMG.UserWidget", gi, "SFold_" .. name)
    w.WidgetTree = New("/Script/UMG.WidgetTree", w, "WidgetTree")
    local canvas = New("/Script/UMG.CanvasPanel", w.WidgetTree, "Canvas")
    w.WidgetTree.RootWidget = canvas
    return w, canvas
end

-- Places `child` on `canvas` at (x, y) from the anchor point (the screen centre by default).
local function Place(canvas, child, x, y, w, h, alignX, alignY, anchorX, anchorY)
    local slot = canvas:AddChildToCanvas(child)
    anchorX, anchorY = anchorX or 0.5, anchorY or 0.5
    pcall(function() slot:SetAnchors({ Minimum = { X = anchorX, Y = anchorY }, Maximum = { X = anchorX, Y = anchorY } }) end)
    pcall(function() slot:SetAlignment({ X = alignX or 0.5, Y = alignY or 0.5 }) end)
    pcall(function() slot:SetPosition({ X = x, Y = y }) end)
    if w and h then
        pcall(function() slot:SetSize({ X = w, Y = h }) end)
    else
        pcall(function() slot:SetAutoSize(true) end)
    end
    return slot
end

local function Text(tree, s, size, color, justify)
    local t = New("/Script/UMG.TextBlock", tree, "Text")
    t:SetText(FText(s or ""))
    pcall(function() t:SetColorAndOpacity({ SpecifiedColor = color or WHITE, ColorUseRule = 0 }) end)
    if size then
        pcall(function()
            local font = t.Font
            font.Size = size
            t:SetFont(font)
        end)
    end
    if justify then pcall(function() t:SetJustification(justify) end) end
    return t
end

local function SetText(t, s, color)
    pcall(function() t:SetText(FText(s or "")) end)
    if color then pcall(function() t:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 }) end) end
end

local function Box(tree, color, padding)
    local b = New("/Script/UMG.Border", tree, "Box")
    pcall(function() b:SetBrushColor(color or { R = 0.02, G = 0.02, B = 0.02, A = 0.8 }) end)
    local p = padding or 12
    pcall(function() b:SetPadding({ Left = p, Top = p, Right = p, Bottom = p }) end)
    return b
end

local textureCache = {}
local function Texture(path)
    if not path or path == "" then return nil end
    local t = textureCache[path]
    if U.Valid(t) then return t end
    t = U.Load(path)
    textureCache[path] = t
    return t
end

local function Image(tree, texturePath, w, h, tint)
    local img = New("/Script/UMG.Image", tree, "Img")
    local tex = Texture(texturePath)
    if tex then pcall(function() img:SetBrushFromTexture(tex, false) end) end
    pcall(function() img:SetDesiredSizeOverride({ X = w, Y = h }) end)
    if tint then pcall(function() img:SetColorAndOpacity(tint) end) end
    return img, tex ~= nil
end

local function Show(widget, z)
    widget:AddToViewport(z or 900)
end

local function Remove(widget)
    if U.Valid(widget) then pcall(function() widget:RemoveFromParent() end) end
end

-------------------------------------------------------------------- input mode

local wbl
local function WBL()
    if not U.Valid(wbl) then wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary") end
    return wbl
end

local function EnterUIMode(focusWidget)
    local pc = U.PlayerController()
    if not pc then return end
    U.Set(pc, "bShowMouseCursor", true)
    pcall(function() WBL():SetInputMode_UIOnlyEx(pc, focusWidget, 0, true) end)
    if focusWidget then pcall(function() focusWidget:SetKeyboardFocus() end) end
end

local function LeaveUIMode()
    local pc = U.PlayerController()
    if not pc then return end
    pcall(function() WBL():SetInputMode_GameOnly(pc, true) end)
    U.Set(pc, "bShowMouseCursor", false)
end

local wll
local function MouseFromCenter()
    if not U.Valid(wll) then wll = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary") end
    local pc = U.PlayerController()
    if not (U.Valid(wll) and pc) then return nil end
    local ok, res = pcall(function()
        local mouse = wll:GetMousePositionOnViewport(pc)
        local size = wll:GetViewportSize(pc)
        local scale = wll:GetViewportScale(pc)
        if not scale or scale <= 0 then scale = 1 end
        return { X = mouse.X - size.X / scale / 2, Y = mouse.Y - size.Y / scale / 2 }
    end)
    if ok then return res end
    return nil
end

-------------------------------------------------------------------- toasts

function UI.Toast(message, seconds)
    local ok, err = pcall(function()
        for _, t in ipairs(toasts) do Remove(t.widget) end
        toasts = {}
        local w, canvas = Root("Toast")
        local box = Box(w.WidgetTree, { R = 0.03, G = 0.025, B = 0.02, A = 0.85 }, 14)
        box:SetContent(Text(w.WidgetTree, message, 20, GOLD, 1))
        Place(canvas, box, 0, 140, nil, nil, 0.5, 0, 0.5, 0)
        Show(w, 950)
        toasts[#toasts + 1] = { widget = w, untilTime = os.clock() + (seconds or 3) }
    end)
    if not ok then U.Log("Toast failed: %s (%s)", tostring(err), tostring(message)) end
    U.Log("%s", message)
end

-------------------------------------------------------------------- wheel

-- The folder wheel copies the game's spell radial (WBP_SurvivalSorcery_RadialSelector):
-- the same textures, fonts, colours and sizes, read from the game's own widget.
local ART = "/Game/Art/UI/Spellcasting/"
local KEYS = "/Game/Art/UI/Inputs/Keyboard/"
local MOUSE = "/Game/Art/UI/Inputs/Mouse/"
local FONT_HEADER = "/Game/UI/Fonts/Amiri-Regular_Font"
local FONT_TEXT = "/Game/UI/Fonts/Poppins-Regular_Font"
local CREAM = { R = 0.88, G = 0.84, B = 0.79, A = 1 }       -- spell names
local GOLD_TEXT = { R = 0.58, G = 0.40, B = 0.16, A = 1 }   -- costs, cooldowns, descriptions
local DIM = { R = 0.6, G = 0.57, B = 0.53, A = 1 }
local BAD = { R = 0.72, G = 0.14, B = 0.12, A = 1 }         -- the game's "can't cast" red
local SLICES = 12                 -- the game's radial has 12 slots, 30 degrees apart, slot 1 at the top
local SEG_W, SEG_H = 137.5, 262.5 -- one slot's segment image; its bottom edge sits on the centre
local KEY_RADIUS = 283            -- where the number-key boxes sit

UI.MaxOptions = SLICES

-- Pictures for the controls listed at the bottom right of a wheel.
UI.Input = {
    LeftMouse = MOUSE .. "T_Mouse-Buttons-Left",
    RightMouse = MOUSE .. "T_Mouse-Buttons-Right",
    Esc = KEYS .. "T_Keys-Special-Esc",
    R = KEYS .. "T_Keys-Standard-R",
    I = KEYS .. "T_Keys-Standard-I",
}

local fontCache = {}
local function Font(t, path, size, spacing)
    pcall(function()
        local font = t.Font
        local obj = fontCache[path]
        if not U.Valid(obj) then obj = U.Load(path) fontCache[path] = obj end
        if obj then
            font.FontObject = obj
            font.TypefaceFontName = FName("Default")
        end
        font.Size = size
        font.LetterSpacing = spacing or 0
        t:SetFont(font)
    end)
end

local function GameText(tree, s, header, size, color, justify)
    local t = New("/Script/UMG.TextBlock", tree, "Text")
    pcall(function() t:SetText(FText(s or "")) end)
    pcall(function() t:SetColorAndOpacity({ SpecifiedColor = color or CREAM, ColorUseRule = 0 }) end)
    if header then Font(t, FONT_HEADER, size or 13, 120) else Font(t, FONT_TEXT, size or 11, 0) end
    pcall(function() t:SetJustification(justify or 1) end)
    return t
end

-- An image of a fixed size inside a box (SetDesiredSizeOverride has no effect there).
-- Returns the size box, which is what gets added to the box, and the image.
local function SizedImage(tree, texturePath, w, h, tint)
    local box = New("/Script/UMG.SizeBox", tree, "Size")
    pcall(function() box:SetWidthOverride(w) end)
    pcall(function() box:SetHeightOverride(h) end)
    local img = Image(tree, texturePath, w, h, tint)
    pcall(function() box:SetContent(img) end)
    return box, img
end

-- Slot alignment values (EHorizontalAlignment / EVerticalAlignment).
local FILL, START, CENTER = 0, 1, 2

local function Visible(widget, on)
    pcall(function() widget:SetVisibility(on and 4 or 1) end) -- SelfHitTestInvisible / Collapsed
end

local function Opacity(widget, value)
    pcall(function() widget:SetRenderOpacity(value) end)
end

-- Picture + count for each item of a cost, like the game's WBP_SpellItemCost.
local function CostRow(tree, cost)
    local row = New("/Script/UMG.HorizontalBox", tree, "Cost")
    for _, c in ipairs(cost or {}) do
        local col = New("/Script/UMG.VerticalBox", tree, "CostItem")
        local img = SizedImage(tree, c.icon, 42, 42)
        pcall(function() col:AddChildToVerticalBox(img):SetHorizontalAlignment(CENTER) end)
        local count = GameText(tree, tostring(c.count), false, 11, c.missing and BAD or GOLD_TEXT)
        pcall(function() col:AddChildToVerticalBox(count):SetHorizontalAlignment(CENTER) end)
        pcall(function() row:AddChildToHorizontalBox(col):SetPadding({ Left = 6, Top = 0, Right = 6, Bottom = 0 }) end)
    end
    return row
end

-- Wheel slot (0-based, clockwise from the top) for each option, spread evenly.
local function SlotsFor(n)
    local list, used = {}, {}
    for i = 1, n do
        local s = math.floor((i - 1) * SLICES / n + 0.5) % SLICES
        while used[s] do s = (s + 1) % SLICES end
        used[s] = true
        list[i] = s
    end
    return list
end

local function AngleDiff(a, b)
    return (a - b + 180) % 360 - 180
end

-- spec: {
--   title, hint,                       -- shown when no option is pointed at (an empty wheel shows only these)
--   selected,                          -- option to start on
--   instant = true,                    -- no fade-in and no click delay (a wheel that replaces another)
--   options = { {
--     name, description, icon (texture path), disabled,
--     cost = { {icon, count, missing} },  -- shown with pictures in the centre
--     status = "Ready in 2s", statusBad = true/false,
--     detail = "...", cooldown = seconds } },
--   legend = { {label, texture} },     -- controls listed at the bottom right, top one first
--   onPick(index, option),             -- left click, Enter or a number key; the wheel closes first
--   onRemove(index, option),           -- right click; the wheel stays open
--   onKey(key, index),                 -- any other key from UI.Keys
--   onCancel() }                       -- Esc
function UI.Wheel(spec)
    UI.Close()
    local options = spec.options or {}
    local n = math.min(#options, SLICES)
    local w, canvas = Root("Wheel")
    local tree = w.WidgetTree
    local cy = -50   -- the game's wheel sits a little above the middle of the screen
    local self = { kind = "wheel", widget = w, options = options, spec = spec, hovered = nil, slots = {},
                   opened = os.clock() - (spec.instant and 1 or 0), pointerAngle = nil }
    local function At(x, y) return x, cy + y end

    -- Layers, bottom to top, all centred on the wheel.
    local function Layer(tex, sizeX, sizeY, x, y, tint)
        local img = Image(tree, ART .. tex, sizeX, sizeY, tint)
        local px, py = At(x or 0, y or 0)
        Place(canvas, img, px, py, sizeX, sizeY)
        return img
    end
    Layer("T_Spell_Bg_Shadow", 737.5, 748, 0, 0, { R = 0, G = 0, B = 0, A = 0.8 })
    Layer("T_Radial_Base_Bg", 630, 629)
    Layer("T_Radial_Circleline_Bg", 630, 630)
    Layer("T_Radial_Symbol_Bg", 521, 521)
    Layer("T_Spell_Radial_Lines", 630, 630)

    -- The 12 slots, each a segment image turned around the centre; options fill some of them.
    local slotOf = SlotsFor(n)
    local optionAt = {}
    for i = 1, n do optionAt[slotOf[i]] = i end
    for s = 0, SLICES - 1 do
        local angle = s * 360 / SLICES
        local seg = New("/Script/UMG.Overlay", tree, "Slice")
        local function Add(widget, ha, va, top)
            pcall(function()
                local sl = seg:AddChildToOverlay(widget)
                sl:SetHorizontalAlignment(ha)
                sl:SetVerticalAlignment(va)
                if top then sl:SetPadding({ Left = 0, Top = top, Right = 0, Bottom = 0 }) end
            end)
            return widget
        end
        local bg = Add(Image(tree, ART .. "T_Segment_Normal", SEG_W, SEG_H), FILL, FILL)
        Opacity(bg, 0.6)
        local i = optionAt[s]
        local entry = { angle = angle, slot = s }
        if i then
            local opt = options[i]
            entry.highlight = Add(Image(tree, ART .. "T_Segment_Highlight", SEG_W, SEG_H), FILL, FILL)
            entry.highlightBad = Add(Image(tree, ART .. "T_Segment_Highlight_Disabled", SEG_W, SEG_H, BAD), FILL, FILL)
            Opacity(entry.highlight, 0)
            Opacity(entry.highlightBad, 0)
            -- The icon sits 20 from the segment's outer edge and is turned back upright.
            local iconBox = Add(SizedImage(tree, opt.icon, 80, 80), CENTER, START, 20)
            pcall(function() iconBox:SetRenderTransformAngle(-angle) end)
            Opacity(iconBox, 0.75)
            entry.icon = iconBox
            if opt.disabled then
                local mark = Add(SizedImage(tree, ART .. "T_Disabled_Marker", 36, 34.5), CENTER, START, 42)
                pcall(function() mark:SetRenderTransformAngle(-angle) end)
            end
            self.slots[i] = entry
        end
        local px, py = At(0, 0)
        Place(canvas, seg, px, py, SEG_W, SEG_H, 0.5, 1.0)
        pcall(function() seg:SetRenderTransformPivot({ X = 0.5, Y = 1.0 }) end)
        pcall(function() seg:SetRenderTransformAngle(angle) end)
    end

    -- Number-key boxes next to the options (keys 1-9 pick an option).
    for i = 1, math.min(n, 9) do
        local a = math.rad(self.slots[i].angle)
        local box = New("/Script/UMG.Overlay", tree, "Key")
        local bgKey = Image(tree, KEYS .. "T_Keys-Standard-Blank", 32, 32)
        pcall(function() box:AddChildToOverlay(bgKey) end)
        local num = GameText(tree, tostring(i), false, 11, CREAM)
        pcall(function()
            local sl = box:AddChildToOverlay(num)
            sl:SetHorizontalAlignment(2)
            sl:SetVerticalAlignment(2)
        end)
        local px, py = At(math.sin(a) * KEY_RADIUS, -math.cos(a) * KEY_RADIUS)
        Place(canvas, box, px, py, 32, 32)
    end

    -- Centre: the pointer turns towards the chosen option.
    local pointer = Layer("T_Radial_Centre_Pointer", 630, 630)
    Layer("T_Radial_Centre_Bg", 630, 630)
    self.pointer = pointer
    if n == 0 then Opacity(pointer, 0) end

    local px, py = At(0, -55)
    local name = GameText(tree, "", true, 13, CREAM)
    Place(canvas, name, px, py, 250, 30)
    px, py = At(0, -38)
    Place(canvas, Image(tree, ART .. "T_Header_Underline", 165.5, 1), px, py, 165.5, 1)
    self.costRows, self.details = {}, {}
    for i = 1, n do
        local opt = options[i]
        if opt.cost and #opt.cost > 0 then
            local row = CostRow(tree, opt.cost)
            px, py = At(0, -2)
            Place(canvas, row, px, py, nil, nil, 0.5, 0.5)
            Visible(row, false)
            self.costRows[i] = row
        else
            local d = GameText(tree, opt.detail or "", false, 11, GOLD_TEXT)
            px, py = At(0, -2)
            Place(canvas, d, px, py, 220, 24)
            Visible(d, false)
            self.details[i] = d
        end
    end
    local status = GameText(tree, "", false, 11, CREAM)
    pcall(function() status:SetAutoWrapText(true) end)
    px, py = At(0, 52)
    Place(canvas, status, px, py, 220, 40)
    px, py = At(0, 79)
    Place(canvas, Image(tree, ART .. "T_Header_Underline", 165.5, 1), px, py, 165.5, 1)
    self.name, self.status = name, status

    -- Title bar above the wheel, with the folder's name.
    -- (The bar image's band is 34 below the image's centre; the title sits on the band.)
    px, py = At(0, -364)
    Place(canvas, Image(tree, ART .. "T_Spells_TitleBar_Main", 740, 146), px, py, 740, 146)
    px, py = At(0, -380)
    Place(canvas, Image(tree, ART .. "T_Icon_Spellbook", 74.5, 63), px, py, 74.5, 63)
    local title = GameText(tree, (spec.title or ""):upper(), true, 14, CREAM)
    px, py = At(0, -330)
    Place(canvas, title, px, py, 600, 34)

    -- Description bar below the wheel.
    px, py = At(0, 375)
    Place(canvas, Image(tree, ART .. "T_Spells_Description_Bar", 883.5, 166), px, py, 883.5, 166)
    local barTitle = New("/Script/UMG.HorizontalBox", tree, "BarTitle")
    local barName = GameText(tree, "", true, 13, CREAM)
    local barCooldown = GameText(tree, "", false, 11, DIM)
    pcall(function() barTitle:AddChildToHorizontalBox(barName):SetVerticalAlignment(2) end)
    pcall(function()
        local sl = barTitle:AddChildToHorizontalBox(barCooldown)
        sl:SetVerticalAlignment(2)
        sl:SetPadding({ Left = 14, Top = 0, Right = 0, Bottom = 0 })
    end)
    px, py = At(0, 358)
    Place(canvas, barTitle, px, py, nil, nil, 0.5, 0.5)
    local desc = GameText(tree, "", false, 11, GOLD_TEXT)
    pcall(function() desc:SetAutoWrapText(true) end)
    px, py = At(0, 372)
    Place(canvas, desc, px, py, 760, 48, 0.5, 0)
    self.barName, self.barCooldown, self.desc = barName, barCooldown, desc

    -- Controls, bottom right like the game's input legend (the last one is at the bottom).
    local legend = spec.legend or { { label = "Cast", texture = UI.Input.LeftMouse }, { label = "Close", texture = UI.Input.Esc } }
    for i, item in ipairs(legend) do
        local row = New("/Script/UMG.HorizontalBox", tree, "Legend")
        local t = GameText(tree, item.label, false, 11, CREAM, 2)
        pcall(function() row:AddChildToHorizontalBox(t):SetVerticalAlignment(CENTER) end)
        local icon = SizedImage(tree, item.texture, 32, 32)
        pcall(function()
            local sl = row:AddChildToHorizontalBox(icon)
            sl:SetVerticalAlignment(CENTER)
            sl:SetPadding({ Left = 12, Top = 0, Right = 0, Bottom = 0 })
        end)
        Place(canvas, row, -112, -72 - (#legend - i) * 45, nil, nil, 1, 0.5, 1, 1)
    end

    if spec.instant then Opacity(w, 1) else Opacity(w, 0) end
    Show(w, 940)
    EnterUIMode(nil)
    active = self

    function self.Highlight(idx, force)
        if self.hovered == idx and not force then return end
        self.hovered = idx
        for j, s in pairs(self.slots) do
            local on = (j == idx)
            local bad = options[j].disabled
            Opacity(s.highlight, (on and not bad) and 1 or 0)
            Opacity(s.highlightBad, (on and bad) and 1 or 0)
            Opacity(s.icon, on and 1 or 0.75)
        end
        for j, row in pairs(self.costRows) do Visible(row, j == idx) end
        for j, d in pairs(self.details) do Visible(d, j == idx) end
        local opt = idx and options[idx]
        if opt then
            SetText(self.name, (opt.name or ""):upper())
            SetText(self.status, opt.status or "", opt.statusBad and BAD or CREAM)
            SetText(self.barName, (opt.name or ""):upper())
            SetText(self.barCooldown, (opt.cooldown and opt.cooldown > 0) and ("Cooldown " .. opt.cooldown .. "s") or "")
            SetText(self.desc, opt.description or "")
        else
            SetText(self.name, (spec.title or ""):upper())
            SetText(self.status, spec.emptyText or "")
            SetText(self.barName, (spec.title or ""):upper())
            SetText(self.barCooldown, "")
            SetText(self.desc, spec.hint or "")
        end
    end

    function self.Tick()
        local fade = (os.clock() - self.opened) / 0.12
        if fade < 1.05 then Opacity(w, math.min(fade, 1)) end
        if n == 0 then return end
        local m = MouseFromCenter()
        if m then
            local mx, my = m.X, m.Y - cy
            if mx * mx + my * my >= 60 * 60 then -- inside the centre the last choice stays
                local a = math.deg(math.atan(mx, -my)) -- clockwise from the top, like the slots
                local best, bestDiff = nil, math.huge
                for j, s in pairs(self.slots) do
                    local d = math.abs(AngleDiff(a, s.angle))
                    if d < bestDiff then best, bestDiff = j, d end
                end
                self.Highlight(best)
            end
        end
        -- Turn the pointer smoothly towards the chosen option.
        local target = self.hovered and self.slots[self.hovered] and self.slots[self.hovered].angle
        if target then
            local cur = self.pointerAngle or target
            cur = cur + AngleDiff(target, cur) * 0.45
            self.pointerAngle = cur
            pcall(function() self.pointer:SetRenderTransformAngle(cur) end)
        end
    end

    function self.Pick(idx)
        local opt = idx and options[idx]
        if not opt then return end
        UI.Close()
        if spec.onPick then
            local ok, err = pcall(spec.onPick, idx, opt)
            if not ok then U.Log("Wheel choice failed: %s", tostring(err)) end
        end
    end

    function self.Key(key)
        if key == "ESCAPE" then
            UI.Close()
            if spec.onCancel then pcall(spec.onCancel) end
        elseif key == "LEFT_MOUSE_BUTTON" or key == "RETURN" then
            if os.clock() - self.opened > 0.25 then self.Pick(self.hovered) end
        elseif key == "RIGHT_MOUSE_BUTTON" then
            local opt = self.hovered and options[self.hovered]
            if opt and spec.onRemove and os.clock() - self.opened > 0.25 then
                local ok, err = pcall(spec.onRemove, self.hovered, opt)
                if not ok then U.Log("Wheel remove failed: %s", tostring(err)) end
            end
        elseif key:match("^%d$") then
            self.Pick(tonumber(key))
        elseif spec.onKey then
            local ok, err = pcall(spec.onKey, key, self.hovered)
            if not ok then U.Log("Wheel key failed: %s", tostring(err)) end
        end
    end

    -- Like the game, start on the option chosen last time.
    if n > 0 then
        local first = (spec.selected and self.slots[spec.selected]) and spec.selected or 1
        self.Highlight(first, true)
        self.pointerAngle = self.slots[first].angle
        pcall(function() pointer:SetRenderTransformAngle(self.pointerAngle) end)
    else
        self.Highlight(nil, true)
    end
    return self
end

-------------------------------------------------------------------- prompt

-- spec: { title, hint, text, help, suggest = function(text) -> { {label, value}... },
--         onSubmit(text, suggestion), onCancel }
function UI.Prompt(spec)
    UI.Close()
    local w, canvas = Root("Prompt")
    local tree = w.WidgetTree
    local panel = Box(tree, { R = 0.03, G = 0.025, B = 0.02, A = 0.9 }, 18)
    local vb = New("/Script/UMG.VerticalBox", tree, "VB")
    panel:SetContent(vb)
    vb:AddChildToVerticalBox(Text(tree, spec.title or "", 24, GOLD))
    local input = New("/Script/UMG.EditableTextBox", tree, "Input")
    pcall(function() input:SetHintText(FText(spec.hint or "")) end)
    if spec.text and spec.text ~= "" then pcall(function() input:SetText(FText(spec.text)) end) end
    vb:AddChildToVerticalBox(input)
    local rows = {}
    for i = 1, (spec.suggest and 8 or 0) do
        local t = Text(tree, "", 17, WHITE)
        vb:AddChildToVerticalBox(t)
        rows[i] = t
    end
    local help = Text(tree, spec.help or "Enter confirms  -  Esc cancels", 13, GREY)
    vb:AddChildToVerticalBox(help)
    Place(canvas, panel, 0, -120, 620, spec.suggest and 400 or 150)
    Show(w, 940)

    local self = { kind = "prompt", widget = w, input = input, rows = rows, list = {}, selected = 1, lastText = nil, opened = os.clock() }

    local function Current()
        local ok, s = pcall(function() return input:GetText():ToString() end)
        return ok and s or ""
    end

    function self.Refresh(force)
        if not spec.suggest then return end
        local text = Current()
        if not force and text == self.lastText then return end
        self.lastText = text
        local ok, list = pcall(spec.suggest, text)
        self.list = (ok and type(list) == "table") and list or {}
        if self.selected > #self.list then self.selected = 1 end
        for i, row in ipairs(rows) do
            local s = self.list[i]
            if s then
                SetText(row, (i == self.selected and "> " or "   ") .. s.label, i == self.selected and GOLD or WHITE)
            else
                SetText(row, "")
            end
        end
    end

    function self.Tick() self.Refresh(false) end

    function self.Key(key)
        if key == "ESCAPE" then
            UI.Close()
            if spec.onCancel then pcall(spec.onCancel) end
        elseif key == "DOWN_ARROW" then
            if #self.list > 0 then self.selected = self.selected % math.min(#self.list, #rows) + 1 end
            self.Refresh(true)
        elseif key == "UP_ARROW" then
            if #self.list > 0 then
                self.selected = self.selected - 1
                if self.selected < 1 then self.selected = math.min(#self.list, #rows) end
            end
            self.Refresh(true)
        elseif key == "TAB" then
            local s = self.list[self.selected]
            if s then
                pcall(function() input:SetText(FText(s.complete or s.value or s.label)) end)
                self.Refresh(true)
            end
        elseif key == "RETURN" then
            if os.clock() - self.opened < 0.2 then return end
            local text = Current()
            local s = self.list[self.selected]
            UI.Close()
            if spec.onSubmit then
                local ok, err = pcall(spec.onSubmit, text, s)
                if not ok then U.Log("Prompt failed: %s", tostring(err)) end
            end
        end
    end

    active = self
    EnterUIMode(input)
    self.Refresh(true)
    return self
end

-------------------------------------------------------------------- shared

function UI.IsOpen() return active ~= nil end

-- Removes widgets an earlier copy of this mod left on screen (UE4SS can restart a mod
-- without restarting the game).
function UI.RemoveLeftovers()
    for _, w in ipairs(FindAllOf("UserWidget") or {}) do
        if U.Valid(w) and U.Name(w):sub(1, 6) == "SFold_" then Remove(w) end
    end
end

function UI.Close()
    if active then
        Remove(active.widget)
        active = nil
        LeaveUIMode()
    end
end

function UI.Key(key)
    if active and active.Key then
        local ok, err = pcall(active.Key, key)
        if not ok then U.Log("UI key error: %s", tostring(err)) end
    end
end

function UI.Tick()
    local now = os.clock()
    for i = #toasts, 1, -1 do
        if now >= toasts[i].untilTime then
            Remove(toasts[i].widget)
            table.remove(toasts, i)
        end
    end
    if active then
        if not U.Valid(active.widget) then
            active = nil
            LeaveUIMode()
            return
        end
        local ok, err = pcall(active.Tick)
        if not ok then U.Log("UI tick error: %s", tostring(err)) end
    end
end

-- Keys the UI listens for. main.lua registers these with UE4SS.
UI.Keys = { "ESCAPE", "RETURN", "TAB", "UP_ARROW", "DOWN_ARROW", "LEFT_MOUSE_BUTTON", "RIGHT_MOUSE_BUTTON",
            "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE", "R", "I" }
UI.KeyAlias = { ONE = "1", TWO = "2", THREE = "3", FOUR = "4", FIVE = "5", SIX = "6", SEVEN = "7", EIGHT = "8", NINE = "9" }

return UI
