-- Spell Folders: the few widgets the mod draws itself, built from plain UMG at run time.
--   UI.Toast(text, seconds)   short message at the top of the screen
--   UI.Hint(text, x, y)       a line of text that stays until UI.Hint(nil)
--   UI.Prompt(spec)           text box (naming a folder)
-- UI.Tick() must be called often (about every 50 ms) on the game thread, and UI.Key(name)
-- when Enter or Esc is pressed while a prompt is open.
-- (Folders themselves are shown by the game's own spell radial.)
local UEHelpers = require("UEHelpers")
local U = require("folders.util")

local UI = {}
local active = nil      -- the open Prompt
local toasts = {}
local hint = nil

local WHITE = { R = 1, G = 1, B = 1, A = 1 }
local GOLD = { R = 0.93, G = 0.78, B = 0.45, A = 1 }
local GREY = { R = 0.7, G = 0.7, B = 0.7, A = 1 }
local CREAM = { R = 0.88, G = 0.84, B = 0.79, A = 1 }   -- the game's menu text
local FONT_TEXT = "/Game/UI/Fonts/Poppins-Regular_Font"

-- The game's menus (Spellbook, inventory) are drawn above ordinary viewport widgets;
-- these go above the menus.
local Z_TOP = 5000
local HIT_TEST_INVISIBLE = 3

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

local function Remove(widget)
    if U.Valid(widget) then pcall(function() widget:RemoveFromParent() end) end
end

-------------------------------------------------------------------- input mode (prompt only)

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

-------------------------------------------------------------------- toasts

function UI.Toast(message, seconds)
    local ok, err = pcall(function()
        for _, t in ipairs(toasts) do Remove(t.widget) end
        toasts = {}
        local w, canvas = Root("Toast")
        local box = Box(w.WidgetTree, { R = 0.03, G = 0.025, B = 0.02, A = 0.85 }, 14)
        box:SetContent(Text(w.WidgetTree, message, 20, GOLD, 1))
        Place(canvas, box, 0, 140, nil, nil, 0.5, 0, 0.5, 0)
        pcall(function() w:SetVisibility(HIT_TEST_INVISIBLE) end)
        w:AddToViewport(Z_TOP + 10)
        toasts[#toasts + 1] = { widget = w, untilTime = os.clock() + (seconds or 3) }
    end)
    if not ok then U.Log("Toast failed: %s (%s)", tostring(err), tostring(message)) end
    U.Log("%s", message)
end

-------------------------------------------------------------------- hint

-- A line of text in the game's menu font at (x, y) from the screen centre, until UI.Hint(nil).
function UI.Hint(text, x, y)
    if hint then
        Remove(hint.widget)
        hint = nil
    end
    if not text or text == "" then return end
    local ok, err = pcall(function()
        local w, canvas = Root("Hint")
        local t = Text(w.WidgetTree, text, 11, CREAM, 1)
        pcall(function()
            local font = t.Font
            local obj = U.Load(FONT_TEXT)
            if obj then
                font.FontObject = obj
                font.TypefaceFontName = FName("Default")
            end
            font.Size = 11
            t:SetFont(font)
        end)
        Place(canvas, t, x or 0, y or 0, nil, nil, 0.5, 0.5)
        pcall(function() w:SetVisibility(HIT_TEST_INVISIBLE) end)
        w:AddToViewport(Z_TOP)
        hint = { widget = w }
    end)
    if not ok then U.Log("Hint failed: %s", tostring(err)) end
end

-------------------------------------------------------------------- prompt

-- spec: { title, hint, text, help, onSubmit(text), onCancel() }
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
    vb:AddChildToVerticalBox(Text(tree, spec.help or "Enter confirms  -  Esc cancels", 13, GREY))
    Place(canvas, panel, 0, -120, 620, 150)
    w:AddToViewport(Z_TOP)

    local self = { kind = "prompt", widget = w, input = input, opened = os.clock() }

    function self.Key(key)
        if key == "ESCAPE" then
            UI.Close()
            if spec.onCancel then pcall(spec.onCancel) end
        elseif key == "RETURN" then
            if os.clock() - self.opened < 0.2 then return end
            local ok, text = pcall(function() return input:GetText():ToString() end)
            UI.Close()
            if spec.onSubmit then
                local okSubmit, err = pcall(spec.onSubmit, ok and text or "")
                if not okSubmit then U.Log("Prompt failed: %s", tostring(err)) end
            end
        end
    end

    active = self
    EnterUIMode(input)
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
    if active and not U.Valid(active.widget) then
        active = nil
        LeaveUIMode()
    end
end

return UI
