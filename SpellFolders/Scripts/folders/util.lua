-- Spell Folders: shared helpers.
local UEHelpers = require("UEHelpers")

local U = {}
U.TAG = "[SpellFolders] "
U.Debug = false

function U.Log(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print(U.TAG .. (ok and msg or tostring(fmt)) .. "\n")
end

function U.DebugLog(fmt, ...)
    if U.Debug then U.Log(fmt, ...) end
end

function U.Valid(obj)
    if obj == nil then return false end
    local ok, res = pcall(function() return obj:IsValid() end)
    return ok and res == true
end

function U.Get(obj, prop)
    local ok, value = pcall(function() return obj[prop] end)
    if ok then return value end
    return nil
end

function U.Set(obj, prop, value)
    local ok, err = pcall(function() obj[prop] = value end)
    if not ok then U.DebugLog("Could not set %s: %s", tostring(prop), tostring(err)) end
    return ok
end

function U.Call(obj, fn, ...)
    local args = table.pack(...)
    local ok, res = pcall(function() return obj[fn](obj, table.unpack(args, 1, args.n)) end)
    if not ok then U.DebugLog("%s failed: %s", tostring(fn), tostring(res)) end
    return ok, res
end

function U.Addr(obj)
    local ok, addr = pcall(function() return obj:GetAddress() end)
    if ok then return addr end
    return nil
end

function U.Same(a, b)
    if not (U.Valid(a) and U.Valid(b)) then return false end
    return U.Addr(a) == U.Addr(b)
end

function U.Str(value)
    if value == nil then return "" end
    local ok, s = pcall(function() return value:ToString() end)
    if ok and type(s) == "string" then return s end
    return tostring(value)
end

function U.FullName(obj)
    if not U.Valid(obj) then return "None" end
    local ok, n = pcall(function() return obj:GetFullName() end)
    return ok and n or "?"
end

function U.Name(obj)
    if not U.Valid(obj) then return "None" end
    local ok, n = pcall(function() return obj:GetFName():ToString() end)
    return ok and n or "?"
end

-- "/Game/Foo/Bar" -> "/Game/Foo/Bar.Bar"; full object paths are left alone.
function U.ObjectPath(path)
    if type(path) ~= "string" or path == "" then return nil end
    if path:find("%.[^/]*$") then return path end
    local last = path:match("([^/]+)$")
    return path .. "." .. last
end

-- Loads an asset by path. Must be called on the game thread.
function U.Load(path)
    local full = U.ObjectPath(path)
    if not full then return nil end
    local okFind, found = pcall(StaticFindObject, full)
    if okFind and U.Valid(found) then return found end
    local ok, obj = pcall(LoadAsset, full)
    if ok and U.Valid(obj) then return obj end
    U.Log("Could not load %s", full)
    return nil
end

local ksl
local function KSL()
    if not U.Valid(ksl) then ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
    return ksl
end

-- A TSoftObjectPtr value for a path, for assigning to soft object properties.
function U.Soft(path)
    local full = U.ObjectPath(path)
    if not full then return nil end
    local ok, ref = pcall(function()
        local lib = KSL()
        return lib:Conv_SoftObjPathToSoftObjRef(lib:MakeSoftObjectPath(full))
    end)
    if ok then return ref end
    U.Log("Could not make a soft reference to %s: %s", full, tostring(ref))
    return nil
end

function U.SoftToString(value)
    local ok, s = pcall(function() return KSL():Conv_SoftObjectReferenceToString(value):ToString() end)
    if ok then return s end
    return ""
end

local transient
function U.Transient()
    if U.Valid(transient) then return transient end
    local ok, pkg = pcall(StaticFindObject, "/Engine/Transient")
    if ok and U.Valid(pkg) then
        transient = pkg
        return transient
    end
    -- Fallback: the game instance lives in the transient package; walk up to it.
    local obj = UEHelpers.GetGameInstance()
    for _ = 1, 8 do
        local okOuter, outer = pcall(function() return obj:GetOuter() end)
        if not okOuter or not U.Valid(outer) then break end
        obj = outer
    end
    if U.Valid(obj) then transient = obj end
    return transient
end

local RF_PUBLIC, RF_ROOTSET = 0x1, 0x80

-- Every object the mod creates gets a name no other object has. A fixed name
-- fails (nothing is created) when an object with that name still exists, e.g.
-- when the game rebuilds a list and we add our entries again, or the mod is reloaded.
local SESSION = tostring(os.time())
local nameCount = 0
function U.UniqueName(base)
    nameCount = nameCount + 1
    return string.format("%s_%s_%d", base, SESSION, nameCount)
end

-- A copy of `template` (subobjects included) that is never garbage collected.
function U.Clone(template, outer, name)
    local ok, obj = pcall(StaticConstructObject, template:GetClass(), outer or U.Transient(), FName(U.UniqueName(name)),
        RF_PUBLIC | RF_ROOTSET, 0, false, false, template)
    if ok and U.Valid(obj) then return obj end
    U.Log("Could not copy %s: %s", U.FullName(template), tostring(obj))
    return nil
end

function U.NewObject(classPath, outer, name, keep)
    local cls = StaticFindObject(classPath)
    if not U.Valid(cls) then return nil end
    local flags = keep and (RF_PUBLIC | RF_ROOTSET) or 0
    local ok, obj = pcall(StaticConstructObject, cls, outer or U.Transient(), FName(U.UniqueName(name)), flags)
    if ok and U.Valid(obj) then return obj end
    return nil
end

-------------------------------------------------------------------- player

local cachedPC, retryAt = nil, 0
function U.PlayerController()
    if U.Valid(cachedPC) then return cachedPC end
    local now = os.clock()
    if now < retryAt then return nil end
    retryAt = now + 1
    local pc = UEHelpers.GetPlayerController()
    if U.Valid(pc) then cachedPC = pc return pc end
    return nil
end

local characterClass
function U.Pawn()
    local pc = U.PlayerController()
    if not pc then return nil end
    local pawn = U.Get(pc, "Pawn")
    if not U.Valid(pawn) then return nil end
    if not U.Valid(characterClass) then characterClass = StaticFindObject("/Script/Dominion.DominionPlayerCharacter") end
    if U.Valid(characterClass) then
        local ok, isPlayer = pcall(function() return pawn:IsA(characterClass) end)
        if ok and not isPlayer then return nil end
    end
    return pawn
end

-- The first component of class `className` owned by `actor`.
function U.OwnedComponent(className, actor)
    if not U.Valid(actor) then return nil end
    local addr = U.Addr(actor)
    for _, c in ipairs(FindAllOf(className) or {}) do
        if U.Valid(c) then
            local ok, owner = pcall(function() return c:GetOwner() end)
            if ok and U.Addr(owner) == addr then return c end
        end
    end
    return nil
end

function U.Location(actor)
    local ok, loc = pcall(function() return actor:K2_GetActorLocation() end)
    if ok and loc then return { X = loc.X, Y = loc.Y, Z = loc.Z } end
    return nil
end

function U.Distance(a, b)
    if not (a and b) then return math.huge end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-------------------------------------------------------------------- files

-- Folder that holds this mod's Scripts folder, e.g. ".../Mods/SpellFolders/".
function U.ModFolder()
    local info = debug.getinfo(1, "S")
    local source = info and info.source or ""
    local dir = source:match("^@(.*[\\/])") or ""
    -- this file is Scripts/folders/util.lua
    return (dir:gsub("[\\/]Scripts[\\/]folders[\\/]$", "/"))
end

function U.ReadFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

function U.WriteFile(path, text)
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "w")
    if not f then
        U.Log("Could not write %s: %s", path, tostring(err))
        return false
    end
    f:write(text)
    f:close()
    os.remove(path)
    local ok = os.rename(tmp, path)
    return ok ~= nil
end

-- Names of the .lua files in a folder (inside the game folder), using UE4SS's directory listing.
function U.ListLuaFiles(absFolder)
    local want = absFolder:gsub("\\", "/"):gsub("/+$", ""):lower()
    local results = {}
    local ok, dirs = pcall(IterateGameDirectories)
    if not ok or type(dirs) ~= "table" then return nil end
    local function walk(t, depth)
        if depth > 12 or type(t) ~= "table" then return false end
        local okPath, path = pcall(function() return t.__absolute_path end)
        if not okPath then path = nil end
        if type(path) == "string" and path:gsub("\\", "/"):gsub("/+$", ""):lower() == want then
            local okFiles, files = pcall(function() return t.__files end)
            for _, f in ipairs((okFiles and files) or {}) do
                local okName, name = pcall(function() return f.__name end)
                if not okName then name = nil end
                if type(name) == "string" and name:lower():sub(-4) == ".lua" then results[#results + 1] = name end
            end
            return true
        end
        if type(path) == "string" then
            local p = path:gsub("\\", "/"):gsub("/+$", ""):lower()
            if want:sub(1, #p) ~= p then return false end
        end
        for k, v in pairs(t) do
            if type(k) == "string" and k:sub(1, 2) ~= "__" and type(v) == "table" then
                if walk(v, depth + 1) then return true end
            end
        end
        return false
    end
    if walk(dirs, 0) then
        table.sort(results)
        return results
    end
    return nil
end

-------------------------------------------------------------------- update loop

-- Calls fn on the game thread every `ms` milliseconds, for as long as the game runs.
-- LoopInGameThreadWithDelay keeps all of the mod's Lua on the game thread. The older
-- LoopAsync + ExecuteInGameThread pattern runs Lua on two threads at once; once, at
-- startup, that lost the queued callback and the loop never ran again.
function U.GameThreadLoop(ms, fn)
    if type(LoopInGameThreadWithDelay) == "function" then
        local ok = pcall(LoopInGameThreadWithDelay, ms, function() fn() end)
        if ok then return end
    end
    -- Older UE4SS: queue one call at a time, and queue again if one never ran.
    local queuedAt = nil
    LoopAsync(ms, function()
        local now = os.clock()
        if queuedAt and now - queuedAt < 2 then return false end
        queuedAt = now
        ExecuteInGameThread(function()
            queuedAt = nil
            fn()
        end)
        return false
    end)
end

return U
