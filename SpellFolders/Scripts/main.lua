--[[
    Spell Folders - RuneScape: Dragonwilds (UE4SS Lua mod)

    Adds folders to the spell system. A folder sits in one slot of the spell radial (Q)
    and holds up to 12 spells of its own, laid out like a page of the radial.

      * Folders are listed in the Spellbook (P) under "Spell Folders". Drag one into a
        radial slot like a spell.
      * Pick a folder in the radial and the radial opens again showing the folder's
        spells. Pick one and the game casts it. The bottom slot (7) of a folder is a
        Back button that takes you back to your own spells.
      * In the Spellbook, point at a folder in the radial and press O to open it. The
        radial then shows the folder's spells and you arrange them like any page: drag
        spells in from the list, drag them between slots, remove them. O again goes
        back. Dropping a spell from the list onto a closed folder adds it too.
        (Opening the Spellbook from an open folder's radial shows that folder as well.)

    How it fits into the game:
      * A folder is a copy of one of the game's spells with no effect of its own. When
        the game starts casting it, the mod stops that cast and opens the folder.
      * An open folder is shown by the game's own radial: for as long as it is open,
        the mod puts the folder's spells into the radial page the folder is on, and
        puts the page back afterwards. Picking, casting, rune costs, cooldowns, aiming
        and placing are all the game's own.
      * Saves only ever contain IDs the game knows. A folder borrows the save ID of an
        always-available spell (Siphon Runes), and the mod keeps the folders and the
        slots they are in in its own file (saved_<character>.txt). Removing the mod can
        never stop a character from loading: those slots just show Siphon Runes.
      * Only works in your own world (single player or as host).
]]

local U = require("folders.util")
local UI = require("folders.ui")

------------------------------------------------------------------------ config

local Defaults = {
    Folders = 8,
    BackButton = true,                 -- the bottom slot of an open folder goes back to your spells
    BackIcon = "/Game/Art/UI/MainMenu/CharacterSelect/T_Arrow_L",
    CategoryName = "SPELL FOLDERS",
    CategoryIcon = "",                 -- texture path; empty = the Magic skill's icon
    AliasSpell = "/Game/Gameplay/UtilityMagic/WorldInteractionSpells/USD_SiphonRunes",
    BaseSpell = "/Game/Gameplay/UtilityMagic/PerkSpells/DetectOre/USD_DetectOre",
    DebugLogging = false,
}
local Config = {}
for k, v in pairs(Defaults) do Config[k] = v end
do
    local ok, user = pcall(require, "config")
    if ok and type(user) == "table" then
        for k, v in pairs(user) do Config[k] = v end
    elseif not ok then
        U.Log("config.lua could not be loaded, using defaults: %s", tostring(user))
    end
end
U.Debug = Config.DebugLogging == true
Config.Folders = math.max(1, math.min(24, math.floor(tonumber(Config.Folders) or Defaults.Folders)))

local MOD_FOLDER = U.ModFolder()
local PER_PAGE = 12          -- slots on one page of the game's radial
local BACK_SLOT = 6          -- the bottom slot (the radial numbers it 7)
local WIDGET_RADIAL = 21     -- EWidgetType::Spellcasting (the radial on the HUD)
local WIDGET_SPELLBOOK = 20  -- EWidgetType::SpellBook

-- Keys in the Spellbook (names from UE4SS's Key table).
local KEY_OPEN, KEY_RENAME, KEY_PICTURE = "O", "R", "I"

-- Pictures a folder can have (KEY_PICTURE in an open folder in the Spellbook steps through them).
local TOMES = "/Game/Art/UI/Icons/Skill_Tomes_Concept_Art/"
local ICONS = {
    TOMES .. "T_Icon_Skill_Tome_Magic",
    TOMES .. "T_Icon_Skill_Tome_Attack",
    TOMES .. "T_Icon_Skill_Tome_Mining",
    TOMES .. "T_Icon_Skill_Tome_Woodcutting",
    TOMES .. "T_Icon_Skill_Tome_Construction",
    TOMES .. "T_Icon_Skill_Tome_Farming",
    TOMES .. "T_Icon_Skill_Tome_Cooking",
    TOMES .. "T_Icon_Skill_Tome_Runecrafting",
    TOMES .. "T_Icon_Skill_Tome_Ranged",
    TOMES .. "T_Icon_Skill_Tome_Artisan",
    TOMES .. "T_Icon_Skill_Tome_Fishing",
    TOMES .. "T_Icon_Tome_of_the_Dragon_Slayer",
}

-- Spell modules kept from the base spell. Everything else (the base spell's effect) is removed.
local KEEP_MODULES = {
    SpellModule_PlayMontage = true,
    SpellModule_PlayMontageForHeldEquipment = true,
    SpellModule_Cast = true,
    SpellModule_CostItems = true,
}

------------------------------------------------------------------------ state

local Folders = {}       -- index -> { index, object, perk, name, icon, slots = { [0..11] = spell key } }
local ByAddress = {}     -- address of a folder's game object -> folder
local AliasId = nil      -- persistence ID borrowed from the alias spell
local AliasAddr = nil    -- address of the alias spell itself
local Ready = false      -- folder objects created
local stopped = false    -- this copy of the mod was told to stop (a newer copy runs)

local World = {
    pawnAddr = nil,
    restoreAt = nil,
    restored = false,
    file = nil,
    slots = {},          -- radial slot (0-based, all pages) -> folder index
    cleanUntil = nil,
    pending = nil,       -- pages an open folder had replaced when the file was last read: page -> { [0..11] = key }
}

-- The open folder, if any:
-- { folder, context = "hud" | "book", pages = { { page, original = { [k] = object } } },
--   unresolved = { [k] = key }, at, opened, closed }
local View = nil

-- The Back button: one more copied spell with no effect, shown in the bottom slot of an
-- open folder. { object, perk, addr }
local Back = nil

local function IsBack(object)
    return Back ~= nil and U.Valid(object) and U.Addr(object) == Back.addr
end

local function DefaultName(i) return "Folder " .. i end
local function DefaultIcon(i) return (i - 1) % #ICONS + 1 end

------------------------------------------------------------------------ the game's spells

-- Spells are remembered by their InternalName ("spell_windstep", or "sf_accio" for a
-- Spell Framework spell), which stays the same between sessions.
local SpellIndex = {}    -- key -> spell object
local indexedAt = -100

local function KeyOf(spell)
    local key = U.Str(U.Get(spell, "InternalName"))
    if key == "" then key = U.Name(spell) end
    return key
end

local function RefreshSpellIndex(force)
    if not force and os.clock() - indexedAt < 2 then return end
    indexedAt = os.clock()
    local sub = FindFirstOf("UtilitySpellDataSubsystem")
    if not U.Valid(sub) then return end
    local index = {}
    pcall(function()
        sub.InternalNameToDataMap:ForEach(function(_, v)
            local spell = v:get()
            if U.Valid(spell) then index[KeyOf(spell)] = spell end
        end)
    end)
    SpellIndex = index
end

local function FindSpell(key)
    if not key then return nil end
    local spell = SpellIndex[key]
    if U.Valid(spell) then return spell end
    RefreshSpellIndex(false)
    spell = SpellIndex[key]
    if U.Valid(spell) then return spell end
    return nil
end

local function SpellName(spell) return U.Str(U.Get(spell, "SpellDisplayName")) end

local function Modules(spell)
    local container = U.Get(spell, "Modules")
    local arr = container and U.Get(container, "Modules")
    local list = {}
    for i = 1, (arr and arr:GetArrayNum() or 0) do
        local m = U.Get(arr[i], "Module")
        if U.Valid(m) then list[#list + 1] = { module = m, class = m:GetClass():GetFName():ToString() } end
    end
    return list, arr
end

------------------------------------------------------------------------ folders

local function FolderCount(folder)
    local n = 0
    for k = 0, PER_PAGE - 1 do
        if folder.slots[k] then n = n + 1 end
    end
    return n
end

local function FolderHas(folder, key)
    for k = 0, PER_PAGE - 1 do
        if folder.slots[k] == key then return true end
    end
    return false
end

local function FirstFree(folder)
    for k = 0, PER_PAGE - 1 do
        if not folder.slots[k] and not (Config.BackButton and k == BACK_SLOT) then return k end
    end
    return nil
end

local function StripModules(spell)
    local list, arr = Modules(spell)
    local keep = {}
    for _, m in ipairs(list) do
        if KEEP_MODULES[m.class] then
            keep[#keep + 1] = m.module
            if m.class == "SpellModule_Cast" then
                -- No skill XP from the base spell's XP table entry.
                U.Set(m.module, "CastXpEvent", { DataTable = nil, RowName = FName("None") })
                U.Set(m.module, "SpellMakesNoise", false)
            elseif m.class == "SpellModule_CostItems" then
                U.Set(m.module, "ItemCostMultiplierAttribute", nil)
                U.Set(m.module, "bUseMagicAmmo", false)
                local costs = U.Get(m.module, "ItemsCostInfo")
                if costs then pcall(function() costs:Empty() end) end
            end
        end
    end
    if #keep ~= #list and arr then
        local ok = pcall(function() arr:Empty() end)
        for i, m in ipairs(keep) do
            if ok then ok = pcall(function() arr[i] = { Module = m } end) end
        end
        if not ok then U.Log("Warning: could not remove the base spell's effect from a folder.") end
    end
end

local function FolderDescription(folder)
    local names = {}
    for k = 0, PER_PAGE - 1 do
        local spell = FindSpell(folder.slots[k])
        if spell then names[#names + 1] = SpellName(spell) end
    end
    local text = "A folder of spells. Pick it in the radial to open it. " ..
                 "In the Spellbook, point at it and press " .. KEY_OPEN .. " to open it and arrange its spells."
    if #names > 0 then
        text = text .. " Holds: " .. table.concat(names, ", ") .. "."
    else
        text = text .. " Empty."
    end
    return text
end

-- Writes a folder's name, picture and description into its game objects.
local function ApplyLook(folder)
    local icon = U.Soft(ICONS[folder.icon] or ICONS[1])
    U.Set(folder.object, "SpellDisplayName", FText(folder.name))
    if icon then U.Set(folder.object, "SpellIcon", icon) end
    if U.Valid(folder.perk) then
        U.Set(folder.perk, "PerkName", FText(folder.name))
        U.Set(folder.perk, "PerkDescription", FText(FolderDescription(folder)))
        if icon then U.Set(folder.perk, "SkillPerkImage", icon) end
    end
end

-- A copy of the base spell that does nothing when cast, known to the game's spell data
-- like a spell loaded from the game's files. Returns the spell and its Spellbook entry (perk).
local function NewRadialObject(template, internalName, objectName)
    local spell = U.Clone(template, nil, "USD_" .. objectName)
    if not spell then return nil end
    StripModules(spell)
    U.Set(spell, "PersistenceID", AliasId)
    U.Set(spell, "InternalName", internalName)
    U.Set(spell, "CooldownDuration", 0.0)
    U.Set(spell, "SpecialRequirementsStrategy", nil)
    U.Set(spell, "bNeedsUnlocking", true)
    U.Set(spell, "CastType", 0)
    -- No skill tag (the base spell's little pickaxe) next to the picture.
    pcall(function()
        local lib = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        spell.SpellTagIcon = lib:Conv_SoftObjPathToSoftObjRef(lib:MakeSoftObjectPath(""))
    end)

    local perk = nil
    local perkTemplate = U.Get(template, "OwningPerk")
    if U.Valid(perkTemplate) then
        perk = U.Clone(perkTemplate, nil, "PERK_" .. objectName)
        if perk then
            U.Set(perk, "PersistenceID", "")
            U.Set(perk, "InternalName", "perk_" .. internalName)
            local mods = U.Get(perk, "PerkModules")
            for j = 1, (mods and mods:GetArrayNum() or 0) do
                local m = mods[j]
                if U.Valid(m) and U.Get(m, "SpellData") ~= nil then U.Set(m, "SpellData", spell) end
            end
        end
    end
    U.Set(spell, "OwningPerk", perk)

    local sub = FindFirstOf("UtilitySpellDataSubsystem")
    if not U.Valid(sub) then return nil end
    pcall(function() sub.InternalNameToDataMap:Add(internalName, spell) end)
    pcall(function() sub.AssetNameToDataMap:Add(U.Name(spell), spell) end)
    local ok = pcall(function()
        local n = sub.NetIdToData:GetArrayNum()
        sub.NetIdToData[n + 1] = spell
        sub.DataToNetIdMap:Add(spell, { NetId = n })
    end)
    if not ok then return nil end
    return spell, perk
end

local function CreateFolder(i, template)
    local spell, perk = NewRadialObject(template, "spellfolder_" .. i, "SpellFolder_" .. i)
    if not spell then return nil end
    local folder = { index = i, object = spell, perk = perk, name = DefaultName(i), icon = DefaultIcon(i), slots = {} }
    ApplyLook(folder)
    return folder
end

local function CreateBack(template)
    local spell, perk = NewRadialObject(template, "spellfolder_back", "SpellFolder_Back")
    if not spell then return nil end
    local name, text = "Back", "Back to your own spells."
    local icon = U.Soft(Config.BackIcon)
    U.Set(spell, "SpellDisplayName", FText(name))
    if icon then U.Set(spell, "SpellIcon", icon) end
    if U.Valid(perk) then
        U.Set(perk, "PerkName", FText(name))
        U.Set(perk, "PerkDescription", FText(text))
        if icon then U.Set(perk, "SkillPerkImage", icon) end
    end
    return { object = spell, perk = perk, addr = U.Addr(spell) }
end

local function CreateAll()
    local alias = U.Load(Config.AliasSpell)
    AliasId = alias and U.Str(U.Get(alias, "PersistenceID")) or ""
    AliasAddr = alias and U.Addr(alias)
    if AliasId == "" then
        U.Log("Alias spell %s not found; folders are disabled so your saves stay safe.", tostring(Config.AliasSpell))
        return
    end
    local template = U.Load(Config.BaseSpell)
    if not template then
        U.Log("Base spell %s not found; folders are disabled.", tostring(Config.BaseSpell))
        return
    end
    for i = 1, Config.Folders do
        local ok, folder = pcall(CreateFolder, i, template)
        if ok and folder then
            Folders[i] = folder
            ByAddress[U.Addr(folder.object)] = folder
        else
            U.Log("Folder %d could not be created: %s", i, tostring(folder))
        end
    end
    if Config.BackButton then
        local ok, back = pcall(CreateBack, template)
        if ok and back then
            Back = back
        else
            U.Log("The Back button could not be created: %s", tostring(back))
        end
    end
    UI.RemoveLeftovers()
    Ready = true
    U.Log("%d spell folder(s) ready.", #Folders)
end

------------------------------------------------------------------------ the saved file

local function CharacterKey()
    local pc = U.PlayerController()
    local ok, key = pcall(function()
        local g = pc:GetCharacterGuid().InnerGuid
        return string.format("%08X%08X%08X%08X", g.A & 0xFFFFFFFF, g.B & 0xFFFFFFFF, g.C & 0xFFFFFFFF, g.D & 0xFFFFFFFF)
    end)
    if ok and key and key ~= "00000000000000000000000000000000" then return key end
    local ps = U.Get(pc, "PlayerState")
    local okName, name = pcall(function() return ps:GetPlayerName():ToString() end)
    if okName and name and name ~= "" then return (name:gsub("[^%w_%-]", "_")) end
    return "default"
end

local function SaveState()
    if not World.file then return end
    local lines = { "# Spell Folders: your folders and the radial slots they are in. Written by the mod.",
                    "# format 2" }
    local keys = {}
    for slot in pairs(World.slots) do keys[#keys + 1] = slot end
    table.sort(keys)
    for _, slot in ipairs(keys) do lines[#lines + 1] = "slot " .. slot .. "=" .. World.slots[slot] end
    for i, folder in ipairs(Folders) do
        if folder.name ~= DefaultName(i) then lines[#lines + 1] = "folder " .. i .. " name=" .. folder.name end
        if folder.icon ~= DefaultIcon(i) then lines[#lines + 1] = "folder " .. i .. " icon=" .. folder.icon end
        for k = 0, PER_PAGE - 1 do
            if folder.slots[k] then lines[#lines + 1] = "folder " .. i .. " at " .. k .. "=" .. folder.slots[k] end
        end
    end
    -- While a folder is open, its spells sit in a radial page. If the game stops before the
    -- folder closes, the next load puts these pages back.
    if View then
        for _, p in ipairs(View.pages) do
            local parts = {}
            for k = 0, PER_PAGE - 1 do
                local object = p.original[k]
                parts[#parts + 1] = U.Valid(object) and KeyOf(object) or ""
            end
            lines[#lines + 1] = "open page " .. p.page .. "=" .. table.concat(parts, "|")
        end
    end
    U.WriteFile(World.file, table.concat(lines, "\n") .. "\n")
end

-- Reads the saved file into the folders (every folder is reset first, so a character
-- without a file starts with empty folders). Returns the folder slots and the pages an
-- open folder had replaced.
local function LoadState(path)
    local slots, pending = {}, nil
    for i, folder in ipairs(Folders) do
        folder.name, folder.icon, folder.slots = DefaultName(i), DefaultIcon(i), {}
    end
    local text = U.ReadFile(path) or ""
    for line in text:gmatch("[^\r\n]+") do
        local slot, idx = line:match("^slot (%d+)=(%d+)$")
        local page, keys = line:match("^open page (%d+)=(.*)$")
        if slot then
            if Folders[tonumber(idx)] then slots[tonumber(slot)] = tonumber(idx) end
        elseif page then
            local list, k = {}, 0
            for key in (keys .. "|"):gmatch("([^|]*)|") do
                if key ~= "" and k < PER_PAGE then list[k] = key end
                k = k + 1
            end
            pending = pending or {}
            pending[tonumber(page)] = list
        else
            local i, field, value = line:match("^folder (%d+) (%a+)=(.*)$")
            local at, key
            if not i then
                i, at, key = line:match("^folder (%d+) at (%d+)=(.+)$")
            end
            local folder = i and Folders[tonumber(i)]
            if folder and at then
                if tonumber(at) < PER_PAGE then folder.slots[tonumber(at)] = key end
            elseif folder then
                if field == "name" and value ~= "" then
                    folder.name = value
                elseif field == "icon" and ICONS[tonumber(value) or 0] then
                    folder.icon = tonumber(value)
                elseif field == "spell" and value ~= "" then
                    -- format 1: a plain list
                    local free = FirstFree(folder)
                    if free then folder.slots[free] = value end
                end
            end
        end
    end
    return slots, pending
end

------------------------------------------------------------------------ the game's radial

local function IsTemplate(obj)
    local name = U.FullName(obj)
    return name:find("Default__", 1, true) ~= nil or name:find("^%S+ /Game/") ~= nil
end

local function SelectedSpells()
    local sc = U.OwnedComponent("SpellcastingComponent", U.PlayerController())
    local arr = sc and U.Get(sc, "SelectedSpells")
    if not arr then return nil end
    return arr, sc
end

local menuApi
local function MenuApi()
    if U.Valid(menuApi) then return menuApi end
    menuApi = nil
    -- (It lives inside the world, under /Game/Maps, so IsTemplate would wrongly skip it.)
    for _, a in ipairs(FindAllOf("InputManagerUIAPI") or {}) do
        if U.Valid(a) and not U.FullName(a):find("Default__", 1, true) then menuApi = a end
    end
    return menuApi
end

local function IsOpen(widgetType)
    local api, pc = MenuApi(), U.PlayerController()
    if not (api and pc) then return false end
    local ok, open = pcall(function() return api:IsOpen(pc, widgetType) end)
    return ok and open == true
end

-- The game's spell radial on the HUD (not the copy inside the Spellbook), and its panel.
local hudRadial, hudPanel
local function HudRadial()
    if U.Valid(hudRadial) and U.Valid(hudPanel) then return hudRadial, hudPanel end
    hudRadial, hudPanel = nil, nil
    for _, panel in ipairs(FindAllOf("SpellcastingMainPanel") or {}) do
        if U.Valid(panel) and not IsTemplate(panel) then
            local radial = U.Get(panel, "SpellRadialWidget")
            if U.Valid(radial) then hudRadial, hudPanel = radial, panel end
        end
    end
    return hudRadial, hudPanel
end

-- The open Spellbook screen, if any.
local function OpenSpellbook()
    for _, screen in ipairs(FindAllOf("SpellBookScreen") or {}) do
        if U.Valid(screen) and not IsTemplate(screen) then
            local ok, visible = pcall(function() return screen:IsVisible() end)
            if ok and visible then return screen end
        end
    end
    return nil
end

-- Which page the Spellbook's radial shows, and which slot the mouse is over (nil if none).
local function BookState(screen)
    local radial = U.Get(screen, "RadialSpellSelector")
    if not U.Valid(radial) then return nil end
    local page
    pcall(function() page = radial.SpellbookSelector.RadioGroup:GetSelectedValue() end)
    local slice = tonumber(U.Get(radial, "CachedSectionId"))
    if slice and (slice < 0 or slice >= PER_PAGE) then slice = nil end
    return tonumber(page), slice, radial
end

-- Makes the radials on screen show what the slots hold now.
local function RefreshRadials()
    if IsOpen(WIDGET_RADIAL) then
        local radial = HudRadial()
        if radial then U.Call(radial, "RefreshAllSlices") end
    end
    local screen = OpenSpellbook()
    local radial = screen and U.Get(screen, "RadialSpellSelector")
    if U.Valid(radial) then
        U.Call(radial, "RefreshAllSlices")
        -- The name and description in the middle belong to the slot the mouse was already
        -- over. Forgetting that slot makes the radial look at it again.
        U.Set(radial, "CachedSectionId", 255)
    end
end

local function SetSlot(arr, slot, spell)
    pcall(function() arr[slot + 1] = spell end)
end

local function ReadPage(arr, page)
    local objects = {}
    for k = 0, PER_PAGE - 1 do
        local current = arr[page * PER_PAGE + k + 1]
        if U.Valid(current) then objects[k] = current end
    end
    return objects
end

local function WritePage(arr, page, objects)
    for k = 0, PER_PAGE - 1 do
        local object = objects[k]
        SetSlot(arr, page * PER_PAGE + k, U.Valid(object) and object or nil)
    end
end

local function PagesHolding(arr, object)
    local addr, pages, seen = U.Addr(object), {}, {}
    for i = 1, arr:GetArrayNum() do
        local sp = arr[i]
        if U.Valid(sp) and U.Addr(sp) == addr then
            local page = (i - 1) // PER_PAGE
            if not seen[page] then
                seen[page] = true
                pages[#pages + 1] = page
            end
        end
    end
    return pages
end

local function UnlockFolders()
    local prog = U.OwnedComponent("ProgressComponent", U.PlayerController())
    if not prog then return false end
    local list, objects = {}, {}
    for _, folder in ipairs(Folders) do objects[#objects + 1] = folder.object end
    if Back then objects[#objects + 1] = Back.object end
    for _, object in ipairs(objects) do
        local ok, unlocked = U.Call(prog, "IsSpellUnlocked", object)
        if not (ok and unlocked) then list[#list + 1] = object end
    end
    if #list > 0 then U.Call(prog, "UnlockSpells", list) end
    return true
end

-- Puts back the pages a folder was open on when the game last stopped, then the folders
-- themselves into the radial slots they were in. (The save holds the alias spell there.)
local function RestoreSlots()
    local arr = SelectedSpells()
    if not arr then return false end
    local n = arr:GetArrayNum()
    if World.pending then
        for page, keys in pairs(World.pending) do
            if (page + 1) * PER_PAGE <= n then
                local objects = {}
                for k = 0, PER_PAGE - 1 do objects[k] = FindSpell(keys[k]) end
                WritePage(arr, page, objects)
            end
        end
        World.pending = nil
        U.Log("A folder was open when the game last stopped; its radial page is back as it was.")
    end
    for slot, idx in pairs(World.slots) do
        local folder = Folders[idx]
        if folder and slot < n then
            local current = arr[slot + 1]
            -- (Another folder there was put in by the game when the folders were unlocked.)
            if not U.Valid(current) or U.Addr(current) == AliasAddr or ByAddress[U.Addr(current)] then
                SetSlot(arr, slot, folder.object)
            end
        end
    end
    return true
end

-- Folders made by an earlier copy of this mod (UE4SS can restart a mod without restarting
-- the game) are dead objects now. Takes them out of the radial; RestoreSlots puts the
-- new ones in.
local function ClearStaleFolders()
    local arr = SelectedSpells()
    if not arr then return end
    for i = 1, arr:GetArrayNum() do
        local sp = arr[i]
        if U.Valid(sp) and not ByAddress[U.Addr(sp)] and not IsBack(sp)
            and U.Str(U.Get(sp, "InternalName")):match("^spellfolder_") then
            SetSlot(arr, i - 1, nil)
        end
    end
end

-- Unlocking a spell makes the game put it into the first empty radial slot, and the
-- folders are unlocked again on every load. This empties every slot that holds a folder
-- the player didn't put there, or the Back button (which only belongs in an open folder).
-- Returns how many slots were emptied. Not for use while a folder is open.
local function CleanRadial()
    local arr = SelectedSpells()
    if not arr then return 0 end
    local removed = 0
    for i = 1, arr:GetArrayNum() do
        local folder = ByAddress[U.Addr(arr[i])]
        if (folder and World.slots[i - 1] ~= folder.index) or IsBack(arr[i]) then
            SetSlot(arr, i - 1, nil)
            removed = removed + 1
        end
    end
    if removed > 0 then RefreshRadials() end
    return removed
end

------------------------------------------------------------------------ spellbook category

local Book = { entries = {} }   -- screen address -> our list entry

local function UpdateSpellbook()
    if not Ready or #Folders == 0 then return end
    local screen = OpenSpellbook()
    local list = screen and U.Get(screen, "SpellsList")
    if not U.Valid(list) then return end
    local okNum, num = U.Call(list, "GetNumItems")
    if not (okNum and type(num) == "number" and num > 0) then return end
    local key = U.Addr(screen)
    local mine = Book.entries[key]
    if U.Valid(mine) then
        for i = 0, num - 1 do
            local okItem, item = U.Call(list, "GetItemAt", i)
            if okItem and U.Same(item, mine) then return end
        end
    end
    local first = select(2, U.Call(list, "GetItemAt", 0))
    local magic, stale = nil, {}
    for i = 0, num - 1 do
        local _, item = U.Call(list, "GetItemAt", i)
        if U.Valid(item) then
            local skill = U.Str(U.Get(item, "SkillName"))
            if skill:upper() == "MAGIC" then magic = item end
            if skill == Config.CategoryName then stale[#stale + 1] = item end
        end
    end
    -- A category left by an earlier copy of this mod.
    for _, item in ipairs(stale) do
        U.Call(list, "RemoveItem", item)
        num = num - 1
    end
    local entry = U.NewObject("/Script/Dominion.SpellBookListEntryData", screen, "SpellFolders", false)
    if not entry then return end
    U.Set(entry, "SkillName", FText(Config.CategoryName))
    if Config.CategoryIcon ~= "" then
        U.Set(entry, "SkillIcon", U.Soft(Config.CategoryIcon))
    elseif magic or first then
        U.Set(entry, "SkillIcon", U.Get(magic or first, "SkillIcon"))
    end
    U.Set(entry, "Index", num)
    local entries = U.Get(entry, "DataEntries")
    for i, folder in ipairs(Folders) do
        pcall(function()
            entries[i] = { SpellData = folder.object, SkillPerkData = U.Soft(U.FullName(folder.perk):match("^%S+ (.+)$")) }
        end)
    end
    U.Call(list, "AddItem", entry)
    Book.entries[key] = entry
    U.DebugLog("Added the %s category to the spellbook.", Config.CategoryName)
end

------------------------------------------------------------------------ an open folder

-- While the player aims or places a spell, the game shows a placement actor. The page a
-- folder borrowed is only given back once that is over.
local placing, placingSince = 0, 0
local hooked = false
local function HookPlacement()
    if hooked then return end
    local ok1 = pcall(RegisterHook, "/Script/Dominion.SpellcastingComponent:Server_SpawnSpellPlacementVisualizer", function()
        placing, placingSince = placing + 1, os.clock()
    end)
    local ok2 = pcall(RegisterHook, "/Script/Dominion.SpellcastingComponent:Server_DespawnSpellPlacementVisualizer", function()
        placing = math.max(0, placing - 1)
    end)
    hooked = ok1 and ok2
    if hooked then U.DebugLog("Watching spell placement.") end
end

local function Placing()
    if not hooked then
        -- Without the hooks, look for the placement actor itself.
        for _, actor in ipairs(FindAllOf("UtilitySpellPlacementVisualizer") or {}) do
            if U.Valid(actor) and not IsTemplate(actor) then return true end
        end
        return false
    end
    if placing > 0 and os.clock() - placingSince > 120 then placing = 0 end
    return placing > 0
end

-- What the open folder's page holds now, as the folder's own slots. A spell the game
-- doesn't have right now (a missing spell mod) keeps its place unless something else was
-- put there. Folders can't go inside folders. Returns the slots and how many folders
-- were left out.
local function PageAsFolderSlots(arr, view)
    local page = view.pages[1].page
    local slots, nested = {}, 0
    for k = 0, PER_PAGE - 1 do
        local current = arr[page * PER_PAGE + k + 1]
        if IsBack(current) then
            -- not one of the folder's spells
        elseif U.Valid(current) then
            if ByAddress[U.Addr(current)] then
                nested = nested + 1
            else
                slots[k] = KeyOf(current)
            end
        elseif view.unresolved[k] then
            slots[k] = view.unresolved[k]
        end
    end
    return slots, nested
end

-- In the Spellbook the player can drag things onto or off the Back button's slot. This puts
-- the button back: a spell dropped on it moves to the first free slot (or is left out if
-- the folder is full). Returns whether anything was changed.
local function KeepBackInPlace(arr, view)
    if not view.back then return false end
    local base = view.pages[1].page * PER_PAGE
    local changed = false
    for k = 0, PER_PAGE - 1 do
        if k ~= BACK_SLOT and IsBack(arr[base + k + 1]) then
            SetSlot(arr, base + k, nil)
            changed = true
        end
    end
    local at = arr[base + BACK_SLOT + 1]
    if not IsBack(at) then
        if U.Valid(at) then
            local free = nil
            for k = 0, PER_PAGE - 1 do
                if not free and k ~= BACK_SLOT and not U.Valid(arr[base + k + 1]) then free = k end
            end
            if free then
                SetSlot(arr, base + free, at)
            else
                UI.Toast("This folder is full (slot 7 is its Back button).", 3)
            end
        end
        SetSlot(arr, base + BACK_SLOT, Back.object)
        changed = true
    end
    return changed
end

local function SameSlots(a, b)
    for k = 0, PER_PAGE - 1 do
        if a[k] ~= b[k] then return false end
    end
    return true
end

-- The radial's title ("SPELLBOOK 1") is a label on each of its page buttons.
local function TitleLabels(radial)
    local prefix = U.Valid(radial) and U.FullName(radial):match("^%S+ (.+)$")
    if not prefix then return {} end
    prefix = prefix .. "."
    local list = {}
    for _, t in ipairs(FindAllOf("TextBlock") or {}) do
        if U.Valid(t) and U.Name(t) == "LabelText" then
            local path = U.FullName(t):match("^%S+ (.+)$") or ""
            if path:sub(1, #prefix) == prefix and path:find(".SpellbookSelector.", 1, true) then list[#list + 1] = t end
        end
    end
    return list
end

-- Shows the open folder's name where the radial shows its page name. In the Spellbook,
-- the text in the middle of the radial ("Drag spell into the spellbook") lists the keys.
local function ShowTitle(view)
    local radial
    if view.context == "hud" then
        radial = HudRadial()
    else
        local screen = OpenSpellbook()
        radial = screen and U.Get(screen, "RadialSpellSelector")
        local info = U.Valid(radial) and U.Get(radial, "AssignInfoTextBlock")
        if U.Valid(info) then
            local ok, text = pcall(function() return info:GetText():ToString() end)
            if ok then
                view.info = { widget = info, text = text }
                pcall(function()
                    info:SetText(FText(KEY_OPEN .. ": close folder\n" .. KEY_RENAME .. ": rename\n" .. KEY_PICTURE .. ": picture"))
                end)
            end
        end
    end
    view.titles = {}
    for _, t in ipairs(TitleLabels(radial)) do
        local ok, text = pcall(function() return t:GetText():ToString() end)
        if ok then
            view.titles[#view.titles + 1] = { widget = t, text = text }
            pcall(function() t:SetText(FText(view.folder.name)) end)
        end
    end
end

local function RestoreTitle(view)
    if view.info then
        local widget, text = view.info.widget, view.info.text
        if U.Valid(widget) then pcall(function() widget:SetText(FText(text)) end) end
        view.info = nil
    end
    for _, title in ipairs(view.titles or {}) do
        local widget, text = title.widget, title.text
        if U.Valid(widget) then pcall(function() widget:SetText(FText(text)) end) end
    end
    view.titles = nil
end

local NormalFade   -- defined with OpenRadial below

-- Opens a folder: its spells replace the given radial pages until CloseFolder.
local function OpenFolder(folder, pages, context)
    local arr = SelectedSpells()
    if not arr or #pages == 0 then return false end
    RefreshSpellIndex(true)
    local view = { folder = folder, context = context, pages = {}, unresolved = {}, at = os.clock() }
    -- The Back button takes the bottom slot. A spell an older version put there moves to a
    -- free slot; only a folder with all twelve slots used goes without the button.
    if Back and folder.slots[BACK_SLOT] then
        local free = FirstFree(folder)
        if free then
            folder.slots[free], folder.slots[BACK_SLOT] = folder.slots[BACK_SLOT], nil
        end
    end
    view.back = Back ~= nil and not folder.slots[BACK_SLOT]
    local content = {}
    for k = 0, PER_PAGE - 1 do
        local key = folder.slots[k]
        if key then
            content[k] = FindSpell(key)
            if not content[k] then view.unresolved[k] = key end
        end
    end
    if view.back then content[BACK_SLOT] = Back.object end
    for _, page in ipairs(pages) do
        view.pages[#view.pages + 1] = { page = page, original = ReadPage(arr, page) }
    end
    for _, p in ipairs(view.pages) do WritePage(arr, p.page, content) end
    View = view
    SaveState()
    RefreshRadials()
    ShowTitle(view)
    U.DebugLog("Opened %s (%s).", folder.name, context)
    return true
end

-- Closes the open folder: what the player arranged in the Spellbook becomes the folder's
-- content, and the radial pages get back what they held.
local function CloseFolder(why)
    local view = View
    if not view then return end
    View = nil
    if view.fast then NormalFade(view) end
    RestoreTitle(view)
    local arr = SelectedSpells()
    if arr then
        if view.context == "book" then
            KeepBackInPlace(arr, view)
            local slots, nested = PageAsFolderSlots(arr, view)
            view.folder.slots = slots
            if nested > 0 then UI.Toast("A folder can't go inside a folder.") end
        end
        for _, p in ipairs(view.pages) do WritePage(arr, p.page, p.original) end
    end
    ApplyLook(view.folder)
    SaveState()
    RefreshRadials()
    U.DebugLog("Closed %s (%s).", view.folder.name, tostring(why))
end

-- The Spellbook was opened while a folder was open in the radial: keep the folder open
-- there, on the page the Spellbook shows, so it can be arranged.
local function MoveViewToSpellbook(view, screen)
    local arr = SelectedSpells()
    local shown = BookState(screen)
    if not arr then return false end
    local keep = view.pages[1]
    for _, p in ipairs(view.pages) do
        if p.page == shown then keep = p end
    end
    for _, p in ipairs(view.pages) do
        if p ~= keep then WritePage(arr, p.page, p.original) end
    end
    RestoreTitle(view)
    view.pages = { keep }
    view.context = "book"
    SaveState()
    RefreshRadials()
    ShowTitle(view)
    U.DebugLog("%s stays open in the Spellbook (page %d).", view.folder.name, keep.page + 1)
    return true
end

-- Opens the game's spell radial the way its own key does (ToggleWidget makes the radial
-- start exactly as a press of the key does).
-- This runs within a frame of the folder being picked, when the radial has only just begun
-- to fade out. Its quarter-second fade-in is hurried along so the folder's spells are
-- there at once, and no slot starts out highlighted, so a second click that was already
-- on its way (a double-click on the folder) picks nothing.
local FADE_SPEED = 8.0
local function OpenRadial(view)
    local api, pc = MenuApi(), U.PlayerController()
    if not (api and pc) or IsOpen(WIDGET_RADIAL) then return end
    U.Call(api, "ToggleWidget", pc, WIDGET_RADIAL, false, true)
    local radial, panel = HudRadial()
    local anim = U.Valid(panel) and U.Get(panel, "InAnimation")
    if U.Valid(anim) and U.Call(panel, "SetPlaybackSpeed", anim, FADE_SPEED) then view.fast = true end
    if U.Valid(radial) then U.Set(radial, "CachedSectionId", 255) end
end

NormalFade = function(view)
    view.fast = nil
    local _, panel = HudRadial()
    local anim = U.Valid(panel) and U.Get(panel, "InAnimation")
    if U.Valid(anim) then U.Call(panel, "SetPlaybackSpeed", anim, 1.0) end
end

-- After the Back button: the radial is opened again on the player's own spells.
-- { at, asked, opened, fast }
local Reopen = nil

local function UpdateReopen()
    local r = Reopen
    if not r then return end
    local now = os.clock()
    if IsOpen(WIDGET_RADIAL) then
        if not r.opened then
            r.opened = now
            RefreshRadials()
        end
        if not r.fast or now - r.opened > 0.5 then
            if r.fast then NormalFade(r) end
            Reopen = nil
        end
    elseif r.opened or now - r.at > 2 then
        if r.fast then NormalFade(r) end
        Reopen = nil
    elseif now - (r.asked or 0) > 0.3 then
        r.asked = now
        OpenRadial(r)
    end
end

-- Runs often while a folder is open.
local function UpdateView(slow)
    local view = View
    if not view then return end
    local now = os.clock()
    if view.context == "hud" then
        local open = IsOpen(WIDGET_RADIAL)
        if not view.opened then
            if open then
                view.opened = now
                RefreshRadials()
            elseif now - view.at > 2.5 then
                CloseFolder("the radial didn't open")
            elseif now - (view.asked or 0) > 0.3 then
                view.asked = now
                OpenRadial(view)
            end
        elseif open then
            view.closed = nil
            if view.fast and now - view.opened > 0.5 then NormalFade(view) end
        else
            view.closed = view.closed or now
            local screen = OpenSpellbook()
            if screen then
                MoveViewToSpellbook(view, screen)
            elseif IsOpen(WIDGET_SPELLBOOK) and now - view.closed < 2 then
                -- the Spellbook is on its way up
            elseif now - view.closed > 0.5 and not Placing() then
                -- (Half a second, so a Spellbook opened from the radial is seen first.)
                CloseFolder("radial closed")
            end
        end
    else
        local screen = OpenSpellbook()
        local page = screen and BookState(screen)
        if not screen or page ~= view.pages[1].page then
            CloseFolder(screen and "page changed" or "spellbook closed")
        elseif slow then
            -- Keep the saved folder in step with what the player has arranged so far.
            local arr = SelectedSpells()
            if arr then
                if KeepBackInPlace(arr, view) then RefreshRadials() end
                local slots = PageAsFolderSlots(arr, view)
                if not SameSlots(slots, view.folder.slots) then
                    view.folder.slots = slots
                    SaveState()
                end
            end
        end
    end
end

------------------------------------------------------------------------ watching the game's casts

local NewActors = {}      -- spell actors created since the last tick

local function OnNewSpellActor(actor)
    if not stopped then NewActors[#NewActors + 1] = actor end
end

local function UpdateCasts()
    if #NewActors == 0 then return end
    local actors = NewActors
    NewActors = {}
    for _, actor in ipairs(actors) do
        if U.Valid(actor) then
            local data = U.Get(actor, "Data")
            local folder = U.Valid(data) and ByAddress[U.Addr(data)]
            if IsBack(data) then
                -- The Back button: stop its cast, close the folder, show the player's own spells.
                local pawn = U.Pawn()
                local magic = pawn and U.Get(pawn, "PlayerUtilityMagicComponent")
                if U.Valid(magic) then U.Call(magic, "Server_CancelSpell") end
                if View then CloseFolder("back") end
                Reopen = { at = os.clock() }
            elseif folder then
                local comp = U.Get(actor, "OwningMagicComponent")
                local owner = U.Valid(comp) and select(2, U.Call(comp, "GetOwner")) or nil
                if not owner or U.Addr(owner) == World.pawnAddr then
                    -- Stop the game's cast of the folder itself and open the folder instead.
                    local pawn = U.Pawn()
                    local magic = pawn and U.Get(pawn, "PlayerUtilityMagicComponent")
                    if U.Valid(magic) then U.Call(magic, "Server_CancelSpell") end
                    local okAuth, auth = pcall(function() return pawn:HasAuthority() end)
                    local arr = SelectedSpells()
                    if okAuth and auth == false then
                        UI.Toast("Spell folders only work in your own world.")
                    elseif View or not arr then
                        U.DebugLog("Folder cast ignored: another folder is open.")
                    elseif FolderCount(folder) == 0 then
                        UI.Toast(folder.name .. " is empty. In the Spellbook (P), point at it and press " .. KEY_OPEN ..
                                 " to open it, then drag spells in.", 5)
                    else
                        -- The folder was picked from the page the player is on; open it on
                        -- every page that holds it, so that page is certainly one of them.
                        OpenFolder(folder, PagesHolding(arr, folder.object), "hud")
                    end
                end
            end
        end
    end
end

------------------------------------------------------------------------ watching the radial

local Prev = nil    -- slot -> { addr, object, folder } at the last look

local function Snapshot(arr)
    local snap = {}
    for i = 1, arr:GetArrayNum() do
        local sp = arr[i]
        if U.Valid(sp) then
            local addr = U.Addr(sp)
            snap[i - 1] = { addr = addr, object = sp, folder = ByAddress[addr] }
        end
    end
    return snap
end

-- A spell dropped onto a closed folder in the Spellbook goes into the folder.
local function AddDropped(folder, spell)
    local key, name = KeyOf(spell), SpellName(spell)
    local free = FirstFree(folder)
    if FolderHas(folder, key) then
        UI.Toast(name .. " is already in " .. folder.name .. ".", 2)
    elseif not free then
        UI.Toast(folder.name .. " is full.", 2)
    else
        folder.slots[free] = key
        SpellIndex[key] = spell
        ApplyLook(folder)
        UI.Toast(name .. " added to " .. folder.name .. ".", 2)
    end
end

-- Keeps track of which slots hold folders. Not run while a folder is open (its page
-- holds the folder's spells then).
local function TrackRadial()
    if View then
        Prev = nil
        return
    end
    local arr = SelectedSpells()
    if not arr then return end
    local changed, redraw = false, false
    if Back then
        for i = 1, arr:GetArrayNum() do
            if IsBack(arr[i]) then
                SetSlot(arr, i - 1, nil)
                redraw = true
            end
        end
    end
    local now = Snapshot(arr)
    if Prev and OpenSpellbook() then
        for slot, was in pairs(Prev) do
            local is = now[slot]
            if was.folder and is and not is.folder then
                -- Not a drop if the folder just moved to the slot this spell came from (a swap).
                local moved = false
                for other, o in pairs(now) do
                    if other ~= slot and o.folder == was.folder then
                        local before = Prev[other]
                        if not (before and before.folder == was.folder) then moved = true end
                    end
                end
                if not moved then
                    AddDropped(was.folder, is.object)
                    SetSlot(arr, slot, was.folder.object)
                    now[slot] = was
                    changed, redraw = true, true
                end
            end
        end
    end
    Prev = now
    local slots = {}
    for slot, s in pairs(now) do
        if s.folder then slots[slot] = s.folder.index end
    end
    for slot, idx in pairs(slots) do if World.slots[slot] ~= idx then changed = true end end
    for slot in pairs(World.slots) do if not slots[slot] then changed = true end end
    if changed then
        World.slots = slots
        SaveState()
    end
    if redraw then RefreshRadials() end
end

------------------------------------------------------------------------ keys

-- Set by the key binds (which UE4SS runs outside the game thread) and read by Tick.
local Pressed = { [KEY_OPEN] = false, [KEY_RENAME] = false, [KEY_PICTURE] = false, ESCAPE = false, RETURN = false }

local function RenameFolder(folder)
    -- Typing needs the game's menus out of the way: close the Spellbook, ask, open it again.
    local api, pc = MenuApi(), U.PlayerController()
    if not (api and pc) then return end
    U.Call(api, "CloseWidgetIfOpen", pc, WIDGET_SPELLBOOK, false, true)
    local function Back()
        U.Call(api, "OpenWidgetIfClosed", pc, WIDGET_SPELLBOOK, false, true)
    end
    UI.Prompt({
        title = "Name this folder",
        hint = DefaultName(folder.index),
        text = folder.name,
        help = "Enter saves the name  -  Esc cancels",
        onSubmit = function(text)
            text = (text or ""):gsub("[\r\n=|]", " "):gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 30)
            folder.name = text ~= "" and text or DefaultName(folder.index)
            ApplyLook(folder)
            SaveState()
            Back()
        end,
        onCancel = Back,
    })
end

-- The open key in the Spellbook: opens the folder under the mouse, or closes the open one.
-- (Not a right-click: the game removes a spell from its slot on a right-click.)
local function OnOpenKey()
    local screen = OpenSpellbook()
    if not screen then return end
    if View then
        if View.context == "book" then CloseFolder("key") end
        return
    end
    local page, slice = BookState(screen)
    local arr = SelectedSpells()
    local current = arr and page and slice and arr[page * PER_PAGE + slice + 1]
    local folder = U.Valid(current) and ByAddress[U.Addr(current)]
    if folder then
        OpenFolder(folder, { page }, "book")
    else
        UI.Toast("Point at a folder in the radial, then press " .. KEY_OPEN .. " to open it.", 3)
    end
end

local function UpdateKeys()
    local open, r, i = Pressed[KEY_OPEN], Pressed[KEY_RENAME], Pressed[KEY_PICTURE]
    local esc, enter = Pressed.ESCAPE, Pressed.RETURN
    for name in pairs(Pressed) do Pressed[name] = false end
    if UI.IsOpen() then
        if esc then UI.Key("ESCAPE") elseif enter then UI.Key("RETURN") end
        return
    end
    if open then
        U.DebugLog("Key %s.", KEY_OPEN)
        OnOpenKey()
    end
    if View and View.context == "book" then
        local folder = View.folder
        if i then
            folder.icon = folder.icon % #ICONS + 1
            ApplyLook(folder)
            SaveState()
            UI.Toast(folder.name .. ": picture " .. folder.icon .. " of " .. #ICONS .. ".", 2)
        elseif r then
            CloseFolder("rename")
            RenameFolder(folder)
        end
    end
end

------------------------------------------------------------------------ the player's world

local function UpdateWorld()
    local pawn = U.Pawn()
    local addr = pawn and U.Addr(pawn)
    if addr ~= World.pawnAddr then
        World.pawnAddr = addr
        World.restored = false
        World.restoreAt = pawn and (os.clock() + 2.5) or nil
        -- An open folder's page is put back from the saved file on the next load.
        if View then RestoreTitle(View) end
        Prev, View, Reopen = nil, nil, nil
        UI.Close()
    end
    if not pawn or not Ready then return false end
    if not World.restored then
        if os.clock() < (World.restoreAt or 0) then return false end
        local key = CharacterKey()
        World.file = MOD_FOLDER .. "saved_" .. key .. ".txt"
        World.slots, World.pending = LoadState(World.file)
        RefreshSpellIndex(true)
        for _, folder in ipairs(Folders) do ApplyLook(folder) end
        ClearStaleFolders()
        if RestoreSlots() and UnlockFolders() and RestoreSlots() then
            World.restored = true
            -- The game may place the unlocked folders a moment later; keep cleaning for a few seconds.
            World.cleanUntil = os.clock() + 5
            CleanRadial()
            SaveState()
            RefreshRadials()
            U.DebugLog("Character %s: folders unlocked and radial restored.", key)
        end
        return false
    end
    if World.cleanUntil then
        if os.clock() < World.cleanUntil then
            CleanRadial()
            return false
        end
        World.cleanUntil = nil
    end
    return true
end

------------------------------------------------------------------------ driving

-- The tick runs about once a frame so that a picked folder is back on screen at once.
-- Everything that isn't urgent runs on every SLOW_EVERY-th tick (about four times a second).
local TICK_MS = 16
local SLOW_EVERY = 15
local tickCount = 0
local worldReady = false
local function Tick()
    if stopped then return end
    tickCount = tickCount + 1
    local slow = tickCount % SLOW_EVERY == 0
    UI.Tick()
    if not Ready then return end
    if slow then
        worldReady = UpdateWorld()
        if not hooked and tickCount % (SLOW_EVERY * 20) == 0 then HookPlacement() end
        -- Development: with DebugLogging on, a file named stop.txt in the mod folder stops
        -- this copy of the mod (so another copy can be run without restarting the game).
        if U.Debug and tickCount % (SLOW_EVERY * 4) == 0 and U.ReadFile(MOD_FOLDER .. "stop.txt") then
            U.Log("stop.txt found: this copy of the mod stops.")
            SpellFoldersStop()
            return
        end
    end
    if not worldReady then return end
    UpdateKeys()
    UpdateCasts()
    UpdateReopen()
    UpdateView(slow)
    if slow then
        TrackRadial()
        UpdateSpellbook()
    end
end

local function SafeTick()
    local ok, err = pcall(Tick)
    if not ok then U.Log("Tick error: %s", tostring(err)) end
end

-- Waits for the game's spell data to load, then creates the folders.
-- Some engine lookups fail in the first seconds after the game starts, so wait a bit.
local START_DELAY = 15
local loadedAt = os.clock()
local function TryStart()
    if os.clock() - loadedAt < START_DELAY and not SpellFoldersNoDelay then return false end
    local sub = FindFirstOf("UtilitySpellDataSubsystem")
    if not U.Valid(sub) then return false end
    local ok, n = pcall(function() return sub.NetIdToData:GetArrayNum() end)
    if not ok or n == 0 then return false end
    CreateAll()
    HookPlacement()
    return true
end

local started = false
U.GameThreadLoop(TICK_MS, function()
    if not started then
        local ok, res = pcall(TryStart)
        if not ok then
            U.Log("Startup error: %s", tostring(res))
            started = true
        elseif res then
            started = true
        end
        return
    end
    SafeTick()
end)

pcall(NotifyOnNewObject, "/Script/Dominion.DominionSpellActor", OnNewSpellActor)

for name in pairs(Pressed) do
    local key = Key[name]
    if key then
        RegisterKeyBind(key, function()
            if not stopped then Pressed[name] = true end
        end)
    end
end

-- For the console and for testing: one line of status, and a way to stop this copy.
function SpellFoldersStatus()
    local parts = {}
    for i, folder in ipairs(Folders) do
        local keys = {}
        for k = 0, PER_PAGE - 1 do
            if folder.slots[k] then keys[#keys + 1] = k .. ":" .. folder.slots[k] end
        end
        if #keys > 0 or folder.name ~= DefaultName(i) then
            parts[#parts + 1] = string.format("%d:%s[%s]", i, folder.name, table.concat(keys, ","))
        end
    end
    local slots = {}
    for slot, idx in pairs(World.slots) do slots[#slots + 1] = slot .. "=" .. idx end
    table.sort(slots)
    local view = "none"
    if View then
        local pages = {}
        for _, p in ipairs(View.pages) do pages[#pages + 1] = p.page end
        view = string.format("%s:%d@%s%s", View.context, View.folder.index, table.concat(pages, "+"),
            (View.opened or View.context == "book") and "" or "(opening)")
    end
    return string.format("ready=%s restored=%s view=%s placing=%d prompt=%s slots{%s} %s", tostring(Ready), tostring(World.restored),
        view, placing, tostring(UI.IsOpen()), table.concat(slots, " "), table.concat(parts, " "))
end
function SpellFoldersStop()
    if View then pcall(CloseFolder, "mod stopped") end
    stopped = true
    UI.Close()
end

U.Log("Loaded. Folders are kept in %ssaved_<character>.txt", MOD_FOLDER)
