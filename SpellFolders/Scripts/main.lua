--[[
    Spell Folders - RuneScape: Dragonwilds (UE4SS Lua mod)

    Adds folders to the spell system. A folder sits in one slot of the spell radial (Q)
    and holds up to 12 spells. Casting the folder opens a second wheel, drawn like the
    game's own, where you pick the spell to cast.

      * Folders are listed in the Spellbook (P) under "Spell Folders". Drag one into a
        radial slot like a spell.
      * To put a spell into a folder, drag it from the Spellbook list onto the folder
        in the radial.
      * In a folder's wheel: left click casts, right click takes the spell out of the
        folder, R renames the folder, I changes its picture.

    How it fits into the game:
      * A folder is a copy of one of the game's spells with no effect of its own. When
        the game starts casting it, the mod stops that cast and opens the wheel.
      * The spell you pick is cast by the game itself, through its own radial, so rune
        costs, cooldowns, aiming and placing all work as they do from the radial.
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
local MAX_SPELLS = UI.MaxOptions   -- a folder's wheel has 12 slots, like a page of the game's radial

-- Pictures a folder can have (I in the folder's wheel steps through them).
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
    "/Game/Art/UI/Icons/Skill_Tomes_Concept_Art/T_Icon_Tome_of_the_Dragon_Slayer",
}

-- Spell modules kept from the base spell. Everything else (the base spell's effect) is removed.
local KEEP_MODULES = {
    SpellModule_PlayMontage = true,
    SpellModule_PlayMontageForHeldEquipment = true,
    SpellModule_Cast = true,
    SpellModule_CostItems = true,
}

------------------------------------------------------------------------ state

local Folders = {}       -- index -> { index, object, perk, name, icon, spells = { key, ... } }
local ByAddress = {}     -- address of a folder's game object -> folder
local AliasId = nil      -- persistence ID borrowed from the alias spell
local AliasAddr = nil    -- address of the alias spell itself
local Ready = false      -- folder objects created

local World = {
    pawnAddr = nil,
    restoreAt = nil,
    restored = false,
    file = nil,
    slots = {},          -- radial slot (0-based, all pages) -> folder index
    cleanUntil = nil,
}

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

-- The player's main bag (BP_Components_Inventory on the player controller).
local function Bag()
    local pc = U.PlayerController()
    if not pc then return nil end
    local addr = U.Addr(pc)
    for _, c in ipairs(FindAllOf("InventoryComponent") or {}) do
        if U.Valid(c) and U.Name(c) == "BP_Components_Inventory" then
            local ok, owner = pcall(function() return c:GetOwner() end)
            if ok and U.Addr(owner) == addr then return c end
        end
    end
    return nil
end

-- What the folder wheel shows for a spell: name, picture, rune cost, cooldown, description.
local function SpellInfo(spell, bag)
    local info = { name = SpellName(spell), cost = {}, cooldown = U.Get(spell, "CooldownDuration") or 0 }
    local icon = U.SoftToString(U.Get(spell, "SpellIcon"))
    info.icon = icon ~= "" and icon or nil
    local perk = U.Get(spell, "OwningPerk")
    info.description = U.Valid(perk) and U.Str(U.Get(perk, "PerkDescription")) or ""
    for _, m in ipairs(Modules(spell)) do
        if m.class == "SpellModule_CostItems" then
            local costs = U.Get(m.module, "ItemsCostInfo")
            for i = 1, (costs and costs:GetArrayNum() or 0) do
                local item = U.Get(costs[i], "ItemData")
                local count = U.Get(costs[i], "Count") or 0
                if U.Valid(item) and count > 0 then
                    local itemIcon = U.SoftToString(U.Get(item, "Icon"))
                    local have = nil
                    if bag then
                        local ok, n = U.Call(bag, "GetNumItemsByData", item)
                        if ok and type(n) == "number" then have = n end
                    end
                    local missing = have ~= nil and have < count
                    info.cost[#info.cost + 1] = { icon = itemIcon ~= "" and itemIcon or nil, count = count,
                                                  name = U.Str(U.Get(item, "Name")), missing = missing }
                    if missing and not info.missing then info.missing = U.Str(U.Get(item, "Name")) end
                end
            end
        end
    end
    return info
end

------------------------------------------------------------------------ creating the folders

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
    for _, key in ipairs(folder.spells) do
        local spell = FindSpell(key)
        if spell then names[#names + 1] = SpellName(spell) end
    end
    local text = "A folder of spells. Cast it to open it, then pick a spell. " ..
                 "To add a spell, drag it from the Spellbook list onto the folder in the radial."
    if #names > 0 then text = text .. " Holds: " .. table.concat(names, ", ") .. "." end
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

local function CreateFolder(i, template)
    local spell = U.Clone(template, nil, "USD_SpellFolder_" .. i)
    if not spell then return nil end
    local folder = { index = i, object = spell, name = DefaultName(i), icon = DefaultIcon(i), spells = {} }
    StripModules(spell)
    U.Set(spell, "PersistenceID", AliasId)
    U.Set(spell, "InternalName", "spellfolder_" .. i)
    U.Set(spell, "CooldownDuration", 0.0)
    U.Set(spell, "SpecialRequirementsStrategy", nil)
    U.Set(spell, "bNeedsUnlocking", true)
    U.Set(spell, "CastType", 0)

    local perkTemplate = U.Get(template, "OwningPerk")
    if U.Valid(perkTemplate) then
        local perk = U.Clone(perkTemplate, nil, "PERK_SpellFolder_" .. i)
        if perk then
            U.Set(perk, "PersistenceID", "")
            U.Set(perk, "InternalName", "perk_spellfolder_" .. i)
            local mods = U.Get(perk, "PerkModules")
            for j = 1, (mods and mods:GetArrayNum() or 0) do
                local m = mods[j]
                if U.Valid(m) and U.Get(m, "SpellData") ~= nil then U.Set(m, "SpellData", spell) end
            end
            folder.perk = perk
        end
    end
    U.Set(spell, "OwningPerk", folder.perk)
    ApplyLook(folder)

    -- Make the game's spell data know the folder, like a spell loaded from the game's files.
    local sub = FindFirstOf("UtilitySpellDataSubsystem")
    if not U.Valid(sub) then return nil end
    pcall(function() sub.InternalNameToDataMap:Add("spellfolder_" .. i, spell) end)
    pcall(function() sub.AssetNameToDataMap:Add(U.Name(spell), spell) end)
    local ok = pcall(function()
        local n = sub.NetIdToData:GetArrayNum()
        sub.NetIdToData[n + 1] = spell
        sub.DataToNetIdMap:Add(spell, { NetId = n })
    end)
    if not ok then return nil end
    return folder
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
                    "# format 1" }
    local keys = {}
    for slot in pairs(World.slots) do keys[#keys + 1] = slot end
    table.sort(keys)
    for _, slot in ipairs(keys) do lines[#lines + 1] = "slot " .. slot .. "=" .. World.slots[slot] end
    for i, folder in ipairs(Folders) do
        if folder.name ~= DefaultName(i) then lines[#lines + 1] = "folder " .. i .. " name=" .. folder.name end
        if folder.icon ~= DefaultIcon(i) then lines[#lines + 1] = "folder " .. i .. " icon=" .. folder.icon end
        for _, key in ipairs(folder.spells) do lines[#lines + 1] = "folder " .. i .. " spell=" .. key end
    end
    U.WriteFile(World.file, table.concat(lines, "\n") .. "\n")
end

-- Reads the saved file into the folders (every folder is reset first, so a character
-- without a file starts with empty folders).
local function LoadState(path)
    local slots = {}
    for i, folder in ipairs(Folders) do
        folder.name, folder.icon, folder.spells = DefaultName(i), DefaultIcon(i), {}
    end
    local text = U.ReadFile(path) or ""
    for line in text:gmatch("[^\r\n]+") do
        local slot, idx = line:match("^slot (%d+)=(%d+)$")
        if slot then
            if Folders[tonumber(idx)] then slots[tonumber(slot)] = tonumber(idx) end
        else
            local i, field, value = line:match("^folder (%d+) (%a+)=(.*)$")
            local folder = i and Folders[tonumber(i)]
            if folder then
                if field == "name" and value ~= "" then
                    folder.name = value
                elseif field == "icon" and ICONS[tonumber(value) or 0] then
                    folder.icon = tonumber(value)
                elseif field == "spell" and value ~= "" and #folder.spells < MAX_SPELLS then
                    folder.spells[#folder.spells + 1] = value
                end
            end
        end
    end
    return slots
end

------------------------------------------------------------------------ the radial

local function SpellcastingComponent()
    return U.OwnedComponent("SpellcastingComponent", U.PlayerController())
end

local function SelectedSpells()
    local sc = SpellcastingComponent()
    local arr = sc and U.Get(sc, "SelectedSpells")
    if not arr then return nil end
    return arr, sc
end

-- Puts a spell (or nothing) into a radial slot and tells the game's interface.
local function SetSlot(sc, arr, slot, spell)
    pcall(function() arr[slot + 1] = spell end)
    if spell then U.Call(sc, "Client_NotifySelectedSpell", spell, slot) end
end

local function SlotsHolding(arr, object)
    local addr, list = U.Addr(object), {}
    for i = 1, arr:GetArrayNum() do
        local sp = arr[i]
        if U.Valid(sp) and U.Addr(sp) == addr then list[#list + 1] = i - 1 end
    end
    return list
end

-- Shows a folder's changed name or picture wherever it sits in the radial.
local function RefreshFolderSlots(folder)
    local arr, sc = SelectedSpells()
    if not arr then return end
    for _, slot in ipairs(SlotsHolding(arr, folder.object)) do
        U.Call(sc, "Client_NotifySelectedSpell", folder.object, slot)
    end
end

local function HasSpell(folder, key)
    for i, k in ipairs(folder.spells) do
        if k == key then return i end
    end
    return nil
end

local function UnlockFolders()
    local prog = U.OwnedComponent("ProgressComponent", U.PlayerController())
    if not prog then return false end
    local list = {}
    for _, folder in ipairs(Folders) do
        local ok, unlocked = U.Call(prog, "IsSpellUnlocked", folder.object)
        if not (ok and unlocked) then list[#list + 1] = folder.object end
    end
    if #list > 0 then U.Call(prog, "UnlockSpells", list) end
    return true
end

-- Puts the folders back into the radial slots they were in last time. The save holds
-- the alias spell there.
local function RestoreSlots()
    local arr, sc = SelectedSpells()
    if not arr then return false end
    local n = arr:GetArrayNum()
    for slot, idx in pairs(World.slots) do
        local folder = Folders[idx]
        if folder and slot < n then
            local current = arr[slot + 1]
            if not U.Valid(current) or U.Addr(current) == AliasAddr then SetSlot(sc, arr, slot, folder.object) end
        end
    end
    return true
end

-- Folders made by an earlier copy of this mod (UE4SS can restart a mod without restarting
-- the game) are dead objects now. Takes them out of the radial; RestoreSlots puts the
-- new ones in.
local function ClearStaleFolders()
    local arr, sc = SelectedSpells()
    if not arr then return end
    for i = 1, arr:GetArrayNum() do
        local sp = arr[i]
        if U.Valid(sp) and not ByAddress[U.Addr(sp)] and U.Str(U.Get(sp, "InternalName")):match("^spellfolder_%d+$") then
            SetSlot(sc, arr, i - 1, nil)
        end
    end
end

-- Unlocking a spell makes the game put it into the first empty radial slot, and the
-- folders are unlocked again on every load. This empties every slot that holds a folder
-- the player didn't put there. Returns how many slots were emptied.
local function CleanRadial()
    local arr, sc = SelectedSpells()
    if not arr then return 0 end
    local removed = 0
    for i = 1, arr:GetArrayNum() do
        local folder = ByAddress[U.Addr(arr[i])]
        if folder and World.slots[i - 1] ~= folder.index then
            SetSlot(sc, arr, i - 1, nil)
            removed = removed + 1
        end
    end
    return removed
end

------------------------------------------------------------------------ spellbook

local Book = { entries = {} }   -- screen address -> our list entry

local function IsTemplate(obj)
    local name = U.FullName(obj)
    return name:find("Default__", 1, true) ~= nil or name:find("^%S+ /Game/") ~= nil
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

------------------------------------------------------------------------ casting a spell from a folder

-- The game's spell radial on the HUD (not the copy inside the Spellbook).
local function HudRadial()
    for _, panel in ipairs(FindAllOf("SpellcastingMainPanel") or {}) do
        if U.Valid(panel) and not IsTemplate(panel) then
            local radial = U.Get(panel, "SpellRadialWidget")
            if U.Valid(radial) then return radial end
        end
    end
    return nil
end

-- Has the game cast `spell` exactly as if the player had picked it in the radial, so the
-- rune cost, cooldown, aiming and placing are all the game's own.
-- The radial's SelectSlice casts whatever is in the slot it last pointed at, on the page
-- the player is on. The spell is put into that slot on every page for the length of the
-- call, and what was there (the folder) is put back before anything else can run.
local function CastSpell(spell)
    local arr = SelectedSpells()
    local radial = HudRadial()
    if not (arr and radial and U.Valid(spell)) then return false end
    local n = arr:GetArrayNum()
    local perPage = 12
    local slice = tonumber(U.Get(radial, "CachedSectionId")) or 0
    if slice < 0 or slice >= perPage then
        slice = 0
        U.Set(radial, "CachedSectionId", 0)
    end
    local held = {}
    local ok = pcall(function()
        for slot = slice, n - 1, perPage do
            local current = arr[slot + 1]
            held[#held + 1] = { slot = slot, object = U.Valid(current) and current or nil }
            arr[slot + 1] = spell
        end
    end)
    if ok then ok = U.Call(radial, "SelectSlice") end
    for _, h in ipairs(held) do
        local slot, object = h.slot, h.object
        pcall(function() arr[slot + 1] = object end)
    end
    return ok
end

------------------------------------------------------------------------ the folder's wheel

local LastPick = {}     -- folder index -> option picked last time
local OpenWheel         -- defined below; the wheel reopens itself after a change

local function RemoveFromFolder(folder, key)
    local at = HasSpell(folder, key)
    if not at then return end
    table.remove(folder.spells, at)
    ApplyLook(folder)
    SaveState()
end

local function RenameFolder(folder)
    UI.Prompt({
        title = "Name this folder",
        hint = DefaultName(folder.index),
        text = folder.name,
        help = "Enter saves the name  -  Esc cancels",
        onSubmit = function(text)
            text = (text or ""):gsub("[\r\n=]", " "):gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 30)
            folder.name = text ~= "" and text or DefaultName(folder.index)
            ApplyLook(folder)
            RefreshFolderSlots(folder)
            SaveState()
            OpenWheel(folder, true)
        end,
        onCancel = function() OpenWheel(folder, true) end,
    })
end

OpenWheel = function(folder, instant)
    RefreshSpellIndex(true)
    local bag = Bag()
    local options, spells = {}, {}
    for _, key in ipairs(folder.spells) do
        local spell = FindSpell(key)
        if spell then
            local info = SpellInfo(spell, bag)
            options[#options + 1] = {
                name = info.name, description = info.description, icon = info.icon,
                cost = info.cost, detail = "No cost", cooldown = info.cooldown,
                status = info.missing and ("Not enough " .. info.missing) or "",
                statusBad = info.missing ~= nil, disabled = info.missing ~= nil,
            }
            spells[#spells + 1] = { key = key, object = spell, name = info.name }
        end
    end
    local hidden = #folder.spells - #spells
    local hint = "Left click casts a spell. Right click takes it out of the folder. " ..
                 "To add one, drag it from the Spellbook list (P) onto this folder in the radial."
    if #spells == 0 then
        hint = "This folder is empty. Open the Spellbook (P) and drag a spell from the list onto this folder in the radial."
    end
    if hidden > 0 then
        hint = hint .. " " .. hidden .. " spell(s) in this folder aren't in the game right now (a spell mod may be missing)."
    end
    UI.Wheel({
        title = folder.name,
        hint = hint,
        emptyText = #spells == 0 and "Empty" or "",
        options = options,
        selected = LastPick[folder.index],
        instant = instant,
        legend = {
            { label = "Cast", texture = UI.Input.LeftMouse },
            { label = "Take out", texture = UI.Input.RightMouse },
            { label = "Rename", texture = UI.Input.R },
            { label = "Picture", texture = UI.Input.I },
            { label = "Close", texture = UI.Input.Esc },
        },
        onPick = function(idx)
            local pick = spells[idx]
            if not pick then return end
            LastPick[folder.index] = idx
            if not U.Valid(pick.object) then return end
            if not CastSpell(pick.object) then UI.Toast("Spell Folders: the game didn't take the cast.") end
        end,
        onRemove = function(idx)
            local pick = spells[idx]
            if not pick then return end
            RemoveFromFolder(folder, pick.key)
            LastPick[folder.index] = math.max(1, math.min(idx, #spells - 1))
            OpenWheel(folder, true)
            UI.Toast(pick.name .. " taken out of " .. folder.name .. ".", 2)
        end,
        onKey = function(key)
            if key == "R" then
                RenameFolder(folder)
            elseif key == "I" then
                folder.icon = folder.icon % #ICONS + 1
                ApplyLook(folder)
                RefreshFolderSlots(folder)
                SaveState()
                UI.Toast(folder.name .. ": picture " .. folder.icon .. " of " .. #ICONS .. ".", 2)
            end
        end,
    })
end

------------------------------------------------------------------------ watching the game's casts

local NewActors = {}      -- spell actors created since the last tick

local stopped = false

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
            if folder then
                local comp = U.Get(actor, "OwningMagicComponent")
                local owner = U.Valid(comp) and select(2, U.Call(comp, "GetOwner")) or nil
                if not owner or U.Addr(owner) == World.pawnAddr then
                    -- Stop the game's cast of the folder itself and open its wheel instead.
                    local pawn = U.Pawn()
                    local magic = pawn and U.Get(pawn, "PlayerUtilityMagicComponent")
                    if U.Valid(magic) then U.Call(magic, "Server_CancelSpell") end
                    local okAuth, auth = pcall(function() return pawn:HasAuthority() end)
                    if okAuth and auth == false then
                        UI.Toast("Spell folders only work in your own world.")
                    else
                        OpenWheel(folder, false)
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

-- A spell dropped onto a folder in the Spellbook goes into the folder.
local function AddDropped(folder, spell)
    local key, name = KeyOf(spell), SpellName(spell)
    if HasSpell(folder, key) then
        UI.Toast(name .. " is already in " .. folder.name .. ".", 2)
    elseif #folder.spells >= MAX_SPELLS then
        UI.Toast(folder.name .. " is full (" .. MAX_SPELLS .. " spells).", 2)
    else
        folder.spells[#folder.spells + 1] = key
        SpellIndex[key] = spell
        ApplyLook(folder)
        UI.Toast(name .. " added to " .. folder.name .. ".", 2)
    end
end

local function TrackRadial()
    local arr, sc = SelectedSpells()
    if not arr then return end
    local now = Snapshot(arr)
    local changed = false
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
                    SetSlot(sc, arr, slot, was.folder.object)
                    now[slot] = was
                    changed = true
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
end

------------------------------------------------------------------------ the player's world

local function UpdateWorld()
    local pawn = U.Pawn()
    local addr = pawn and U.Addr(pawn)
    if addr ~= World.pawnAddr then
        World.pawnAddr = addr
        World.restored = false
        World.restoreAt = pawn and (os.clock() + 2.5) or nil
        Prev = nil
        UI.Close()
    end
    if not pawn or not Ready then return false end
    if not World.restored then
        if os.clock() < (World.restoreAt or 0) then return false end
        local key = CharacterKey()
        World.file = MOD_FOLDER .. "saved_" .. key .. ".txt"
        World.slots = LoadState(World.file)
        RefreshSpellIndex(true)
        for _, folder in ipairs(Folders) do ApplyLook(folder) end
        ClearStaleFolders()
        if UnlockFolders() and RestoreSlots() then
            World.restored = true
            -- The game may place the unlocked folders a moment later; keep cleaning for a few seconds.
            World.cleanUntil = os.clock() + 5
            CleanRadial()
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

local tickCount = 0
local worldReady = false
local function Tick()
    if stopped then return end
    tickCount = tickCount + 1
    UI.Tick()
    if not Ready then return end
    UpdateCasts()
    if tickCount % 5 == 0 then
        worldReady = UpdateWorld()
        if worldReady then TrackRadial() end
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
    return true
end

local started = false
U.GameThreadLoop(50, function()
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

for _, name in ipairs(UI.Keys) do
    local key = Key[name]
    if key then
        RegisterKeyBind(key, function()
            if UI.IsOpen() and not stopped then
                ExecuteInGameThread(function() UI.Key(UI.KeyAlias[name] or name) end)
            end
        end)
    end
end

-- For the console and for testing: one line of status, and a way to stop this copy.
function SpellFoldersStatus()
    local parts = {}
    for i, folder in ipairs(Folders) do
        parts[#parts + 1] = string.format("%d:%s[%s]", i, folder.name, table.concat(folder.spells, ","))
    end
    local slots = {}
    for slot, idx in pairs(World.slots) do slots[#slots + 1] = slot .. "=" .. idx end
    table.sort(slots)
    return string.format("ready=%s restored=%s ui=%s slots{%s} %s", tostring(Ready), tostring(World.restored),
        tostring(UI.IsOpen()), table.concat(slots, " "), table.concat(parts, " "))
end
function SpellFoldersStop()
    stopped = true
    UI.Close()
end

U.Log("Loaded. Folders are kept in %ssaved_<character>.txt", MOD_FOLDER)
