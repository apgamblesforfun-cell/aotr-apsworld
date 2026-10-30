loadstring([==[
--[[
  Apache - Attack on Titan: Revolution helper for Matcha

  Insert = show / hide menu
  F1     = autofarm on / off
  F2     = titan ESP on / off
  F3     = ESP tracers on / off

  Debug logging is OFF by default. To turn it on, run this BEFORE the script:
    _G.ApacheDebug = true
]]

local ScriptStart = os.clock()

local Config = {
  Autofarm = true,
  TitanESP = true,
  EspDistance = true,
  EspTracers = false,
  MenuVisible = true,
}

local DEBUG = _G.ApacheDebug == true


--#region -- Logging --

local CurrentLogFile = nil
local DebugRateLimit = {}
local LogBuffer, LogCount = {}, 0

local function Say(message) print("[Apache] " .. message) end
local function Fail(message) warn("[Apache] " .. message) end

if DEBUG then
  local FileName = "ApacheScripts/Aotr/logs/log_" .. os.date("%Y-%m-%d") .. "_" .. os.date("%H-%M-%S") .. ".txt"

  local Header = {
    string.rep("-", 50),
    "Debug file for Apache",
    "Date: " .. os.date("%A, %B %d, %Y"),
    "Time: " .. os.date("%X"),
    "File Path: C:/matcha/workspace/" .. FileName,
    string.rep("-", 50),
    "\n"
  }

  writefile(FileName, table.concat(Header, "\n"))
  Say("Debug mode is on. Logging to: " .. FileName)

  CurrentLogFile = FileName
end

local function FlushLog()
  if LogCount == 0 or not CurrentLogFile then return end

  local chunk = table.concat(LogBuffer, "\n", 1, LogCount) .. "\n"
  LogBuffer, LogCount = {}, 0

  appendfile(CurrentLogFile, chunk)
end

if DEBUG then
  task.spawn(function()
    while true do
      task.wait(1)
      pcall(FlushLog)

      local now = os.clock()
      for key, data in pairs(DebugRateLimit) do
        if now - data.WindowStart > 10 then
          DebugRateLimit[key] = nil
        end
      end
    end
  end)
end

local HANDLERS = { print = print, warn = warn, debug = print }

-- maxAmount: max prints per second for this call site (nil or 0 = unlimited)
-- Does nothing unless debug mode is on.
local function DebugPrint(mode, maxAmount, stackOffset, functionName, ...)
  if not DEBUG then return end

  if maxAmount and maxAmount ~= 0 then
    local key = (functionName or "?") .. "|" .. tostring((...))
    local now = os.clock()
    local data = DebugRateLimit[key]

    if not data then
      data = { WindowStart = now, Count = 0 }
      DebugRateLimit[key] = data
    end

    if now - data.WindowStart >= 1 then
      data.WindowStart = now
      data.Count = 0
    end

    if data.Count >= maxAmount then return end
    data.Count += 1
  end

  local args = table.pack(...)
  for i = 1, args.n do
    args[i] = tostring(args[i])
  end

  local line = string.format("[%.4f] [line: %s || func: %s] [Apache] [%s]: %s",
    os.clock() - ScriptStart,
    tostring(debug.info((stackOffset or 1) + 1, "l")),
    functionName or "<anonymous>",
    mode,
    table.concat(args, " ", 1, args.n)
  )

  local handler = HANDLERS[mode] or print
  handler(line)

  if CurrentLogFile then
    LogCount += 1
    LogBuffer[LogCount] = line
  end
end

--#endregion -- Logging --


--#region -- Startup checks --

task.wait(0.5)

if identifyexecutor and identifyexecutor() ~= "Matcha" then Fail("Not using Matcha..?"); return end
if game.GameId ~= 4658598196 then Fail("Wrong game detected."); return end
if game.PlaceId == 14916516914 then Fail("You seem to be in the lobby. Please execute this inside a match."); return end

local function WaitForService(serviceName)
  local Service = nil
  repeat
    Service = game:GetService(serviceName)
    task.wait(0.05)
  until Service
  return Service
end

local Workspace = WaitForService("Workspace")
local Players = WaitForService("Players")
local HttpService = WaitForService("HttpService")
local RunService = WaitForService("RunService")

local LocalPlayer = nil; repeat task.wait(0.03); LocalPlayer = Players.LocalPlayer until LocalPlayer
local PlayerGui = nil; repeat task.wait(0.03); PlayerGui = LocalPlayer:FindFirstChild("PlayerGui") until PlayerGui
local TitansFolder = nil; repeat task.wait(0.03); TitansFolder = Workspace:FindFirstChild("Titans") until TitansFolder

repeat task.wait(0.1) until TitansFolder:FindFirstChildOfClass("Model")

DebugPrint("debug", nil, nil, nil, "Services and titans folder loaded.")

--#endregion -- Startup checks --


--#region -- State --

local TitansCache = {}
local KnownTitans = {}      -- address -> titan model
local CharacterCache = {}
local UiCache = {}
local BladeCache = {}
local EspObjects = {}

local TitansInfo = {
  ["HeightStall"] = 100,
  ["HeightAttack"] = 160,
  ["HeightColossal"] = 200,
  ["BobAmplitude"] = 2,
}

local GasTankModel = nil
local GasTankPosition = nil

local Vector3New = Vector3.new
local Vector2New = Vector2.new
local Vector3Zero = Vector3New(0, 0, 0)
local NapeSize = Vector3New(15, 15, 15)

local SafePos = CFrame.new(900, 9999, 900)

local CachedNearestTitan = nil
local LastNearestUpdate = 0

local CurrentTitanTarget = nil
local TargetHrp = nil          -- resolved once per target, used every frame
local TargetHeight = 120

local CachedBladesBroken = false
local LastBladeCheck = 0

local CurrentRobloxState = "Active"
local WhatShouldIBeDoing = "attack"
local StatusText = "Starting"
local TitanCount = 0

local ReloadingBlades = false
local LastReloadingTime = 0

local TWO_PI = math.pi * 2
local BobAmplitude = TitansInfo.BobAmplitude

--#endregion -- State --


--#region -- Small helpers --

local function IsValid(object)
  return object ~= nil and object.Parent ~= nil
end

-- Runs fn protected. Returns its first result, or nil if it errored (so one bad read can't kill a loop).
local function Safe(fn, ...)
  local ok, result = pcall(fn, ...)

  if not ok then
    DebugPrint("warn", 2, nil, "Safe", tostring(result))
    return nil
  end

  return result
end

local function ReadMem(kind, address)
  local ok, value = pcall(memory_read, kind, address)
  if ok then return value end
  return nil
end

-- No yielding between segments
local function GetPath(root, warning, ...)
  local current = root

  for i = 1, select("#", ...) do
    local name = select(i, ...)
    local nextInstance = current:FindFirstChild(name)

    if not nextInstance then
      if warning then
        DebugPrint("warn", nil, nil, "GetPath", "Missing: ", name, " in ", current:GetFullName())
      end
      return nil
    end

    current = nextInstance
  end

  return current
end

--#endregion -- Small helpers --


--#region -- Gas tank + offsets --

local GasTankPaths = {
  { "Shiganshina", { "Climbable",   "Walls",     "Gate",      "GasTanks" } },
  { "Trost/Forest",{ "Unclimbable", "Camps",     "Camp",      "GasTanks" } },
  { "Outskirts",   { "Climbable",   "_Walls",    "Gate",      "GasTanks" } },
  { "UtGard",      { "Climbable",   "Utgard",    "GasTanks" } },
  { "Docks",       { "Unclimbable", "World",     "Buildings", "Hanger", "GasTanks" } },
  { "Stohess",     { "Unclimbable", "Props",     "HQ",        "GasTanks" } },
  { "Chapel",      { "Unclimbable", "Reloads",   "GasTanks" } },
  { "Waves",       { "Unclimbable", "Objective", "Waves",     "GasTanks" } },
}

for _, entry in ipairs(GasTankPaths) do
  local Found = GetPath(Workspace, false, table.unpack(entry[2]))

  if Found then
    DebugPrint("debug", nil, nil, "GasTank", entry[1] .. " detected!")
    GasTankModel = Found
    break
  end
end

if not GasTankModel then
  Fail("No known gas tank path found for this map, so the script can't run here.")
  return
end

local function GetOffsets()
  local ok, res = pcall(game.HttpGet, game, "https://imtheo.lol/Offsets/Offsets.json")

  if not ok or not res then
    DebugPrint("warn", nil, nil, "GetOffsets", "Failed to fetch offsets: ", tostring(res))
    return nil
  end

  local success, decoded = pcall(HttpService.JSONDecode, HttpService, res)

  if not success then
    DebugPrint("warn", nil, nil, "GetOffsets", "JSON decode failed: ", decoded)
    return nil
  end

  return decoded
end

local OffsetsData = GetOffsets()

if not OffsetsData or not OffsetsData.Offsets then
  Fail("Couldn't download the offsets file, so the script can't run.")
  return
end

local Offsets = OffsetsData.Offsets

local PrimaryPartOffset = Offsets.Model.PrimaryPart
local BaseToPrimitiveOffset = Offsets.BasePart.Primitive
local PrimitivePositionOffset = Offsets.Primitive.Position
local VisibleOffset = Offsets.GuiObject.Visible
local TransparencyBasePartOffset = Offsets.BasePart.Transparency

--#endregion -- Gas tank + offsets --


--#region -- Player functions --

local function GetHrp(instance) return instance:FindFirstChild("HumanoidRootPart") end
local function GetHumanoid(instance) return instance:FindFirstChildOfClass("Humanoid") end

local function RegisterPlayer(player)
  local existing = CharacterCache[player.Address]

  if existing then
    existing.Character = player.Character
    return existing
  end

  local entry = {
    Character = player.Character,
    Hrp = nil,
    Username = player.Name,
  }

  CharacterCache[player.Address] = entry
  return entry
end

local function GetPlayerCharacter(player)
  local Cache = CharacterCache[player.Address] or RegisterPlayer(player)

  local CachedCharacter = Cache.Character
  if IsValid(CachedCharacter) then return CachedCharacter end

  local Character = player.Character
  if not IsValid(Character) then return nil end

  Cache.Character = Character
  return Character
end

local function GetPlayerHrp(player)
  local Cache = CharacterCache[player.Address] or RegisterPlayer(player)

  local CachedHrp = Cache.Hrp
  if IsValid(CachedHrp) then return CachedHrp end

  local Character = GetPlayerCharacter(player); if not Character then return nil end
  local Hrp = GetHrp(Character); if not Hrp then return nil end

  Cache.Hrp = Hrp
  return Hrp
end

--#endregion -- Player functions --


--#region -- Titan functions --

local function GetTitanHrp(titan)
  if not IsValid(titan) then return nil end

  local TitanCache = TitansCache[titan.Address]; if not TitanCache then return nil end
  local CachedHrp = TitanCache.Parts.HumanoidRootPart; if IsValid(CachedHrp) then return CachedHrp end

  local TitanHrp = GetHrp(titan); if not TitanHrp then return nil end

  TitanCache.Parts.HumanoidRootPart = TitanHrp
  return TitanHrp
end

local function GetTitanHumanoid(titan)
  if not IsValid(titan) then return nil end

  local TitanCache = TitansCache[titan.Address]; if not TitanCache then return nil end
  local CachedHumanoid = TitanCache.Parts.Humanoid; if IsValid(CachedHumanoid) then return CachedHumanoid end

  local TitanHumanoid = GetHumanoid(titan); if not TitanHumanoid then return nil end

  TitanCache.Parts.Humanoid = TitanHumanoid
  return TitanHumanoid
end

local function GetTitanType(titan)
  local TitanCache = TitansCache[titan.Address]; if not TitanCache then return "Normal" end

  local Cached = TitanCache.Info.Type; if Cached then return Cached end

  local TitanType = titan:GetAttribute("Type") or "Normal"
  TitanCache.Info.Type = TitanType
  return TitanType
end

local function GetTitanNape(titan)
  if not IsValid(titan) then return nil end

  local TitanCache = TitansCache[titan.Address]; if not TitanCache then return nil end
  local CachedNape = TitanCache.Parts.Nape; if IsValid(CachedNape) then return CachedNape end

  local NapePart = GetPath(titan, true, "Hitboxes", "Hit", "Nape"); if not NapePart then return nil end

  TitanCache.Parts.Nape = NapePart
  return NapePart
end

local function IsTitanAlive(titan)
  if not titan or not titan.Parent then return false end

  local TitanCache = TitansCache[titan.Address]; if not TitanCache then return false end

  -- Use the 0.2s cache BEFORE doing any other work
  local Info, now = TitanCache.Info, os.clock()
  if Info.LastAliveCheck and now - Info.LastAliveCheck < 0.2 then
    return Info.Alive or false
  end

  local TitanHumanoid = GetTitanHumanoid(titan); if not TitanHumanoid then return false end

  local ok, health = pcall(function() return TitanHumanoid.Health end)

  Info.LastAliveCheck = now

  -- Health can come back nil if the humanoid was destroyed mid-check (titan just died)
  if not ok or type(health) ~= "number" then
    Info.Alive = false
    return false
  end

  Info.Alive = health > 0
  return Info.Alive
end

local function BringNapeToPlayer(titan, size)
  local TitanCache = TitansCache[titan.Address]; if not TitanCache then return end
  local NapePart = GetTitanNape(titan); if not NapePart then return end
  local PlayerHrp = GetPlayerHrp(LocalPlayer); if not PlayerHrp then return end

  NapePart.CFrame = PlayerHrp.CFrame * CFrame.new(0, 2, 0)

  -- Only write the size when it actually changed
  if size and TitanCache.NapeSize ~= size then
    NapePart.Size = size
    TitanCache.NapeSize = size
  end
end

local function GetTitanBobHeight(titan)
  return TitansInfo["Height" .. GetTitanType(titan)] or 120
end

-- Resolve everything the per-frame follow loop needs, once per target
local function SetTarget(titan)
  if CurrentTitanTarget == titan then return end

  CurrentTitanTarget = titan
  TargetHrp = GetTitanHrp(titan)
  TargetHeight = GetTitanBobHeight(titan)
end

local function GetNearestTitan()
  if os.clock() - LastNearestUpdate < 1
    and CachedNearestTitan
    and CachedNearestTitan.Parent
    and IsTitanAlive(CachedNearestTitan) then
    return CachedNearestTitan
  end

  local PlayerHrp = GetPlayerHrp(LocalPlayer)
  if not PlayerHrp then return nil end

  local NearestTitan = nil
  local NearestDistSq = math.huge
  local PlayerPos = PlayerHrp.Position

  for _, titan in pairs(KnownTitans) do
    if titan.Parent and IsTitanAlive(titan) then
      local TitanHrp = GetTitanHrp(titan)

      if TitanHrp then
        local Delta = TitanHrp.Position - PlayerPos
        local DistSq = Delta:Dot(Delta)

        if DistSq < NearestDistSq then
          NearestDistSq = DistSq
          NearestTitan = titan
        end
      end
    end
  end

  CachedNearestTitan = NearestTitan
  LastNearestUpdate = os.clock()

  return NearestTitan
end

local function RegisterTitan(titan)
  if not titan or not titan.Parent then return end
  if TitansCache[titan.Address] then return end

  TitansCache[titan.Address] = {
    Info = { Name = titan.Name, Type = nil, Alive = true, LastAliveCheck = nil },
    Parts = { Nape = nil, HumanoidRootPart = nil, Humanoid = nil },
    NapeSize = nil,
  }

  GetTitanNape(titan)
  GetTitanHrp(titan)
  GetTitanHumanoid(titan)
end

--#endregion -- Titan functions --


--#region -- HUD / reload / retry functions --

local function GetUiCached(cacheKey, parent, ...)
  local cached = UiCache[cacheKey]; if cached and cached.Parent then return cached end

  local obj = GetPath(parent, false, ...); if not obj then return nil end

  UiCache[cacheKey] = obj
  return obj
end

local function FindDescendantByName(root, name, maxDepth)
  local direct = root:FindFirstChild(name)
  if direct then return direct end
  if maxDepth <= 0 then return nil end

  for _, child in ipairs(root:GetChildren()) do
    local found = FindDescendantByName(child, name, maxDepth - 1)
    if found then return found end
  end

  return nil
end

-- Finds a HUD frame ("Blades" / "Gas"). Tries the known path first, then searches the HUD,
-- so it still works if the HUD loads late or a parent frame gets renamed.
local function GetHudFrame(name)
  local cached = UiCache["Hud_" .. name]; if cached and cached.Parent then return cached end

  local Hud = GetPath(PlayerGui, false, "Interface", "HUD"); if not Hud then return nil end

  local found = GetPath(Hud, false, "Main", "Top", "7", name) or FindDescendantByName(Hud, name, 5)
  if not found then return nil end

  UiCache["Hud_" .. name] = found
  return found
end

local function AreBladesFullyBroken()
  local now = os.clock()
  if now - LastBladeCheck < 0.5 then return CachedBladesBroken end

  LastBladeCheck = now

  local RightBlade = BladeCache.RightBlade
  local LeftBlade = BladeCache.LeftBlade

  if not RightBlade or not RightBlade.Parent or not LeftBlade or not LeftBlade.Parent then
    local Character = GetPlayerCharacter(LocalPlayer); if not Character then return false end
    local Rig_ = Character:FindFirstChild("Rig_" .. LocalPlayer.Name); if not Rig_ then return false end

    local RightHand = BladeCache.RightHand
    local LeftHand = BladeCache.LeftHand

    if not RightHand or not LeftHand then
      RightHand = Rig_:FindFirstChild("RightHand")
      LeftHand = Rig_:FindFirstChild("LeftHand")

      if not RightHand or not LeftHand then return false end

      BladeCache.RightHand = RightHand
      BladeCache.LeftHand = LeftHand
    end

    RightBlade = RightHand:FindFirstChild("Blade_1")
    LeftBlade = LeftHand:FindFirstChild("Blade_1")

    if not RightBlade or not LeftBlade then return false end

    BladeCache.RightBlade = RightBlade
    BladeCache.LeftBlade = LeftBlade
  end

  local RightTransparency = ReadMem("float", RightBlade.Address + TransparencyBasePartOffset)
  local LeftTransparency = ReadMem("float", LeftBlade.Address + TransparencyBasePartOffset)

  if not RightTransparency or not LeftTransparency then return false end

  CachedBladesBroken = RightTransparency >= 0.9 and LeftTransparency >= 0.9
  return CachedBladesBroken
end

local function DoINeedToRefill() -- The 0 / 3 counter
  local Blades = GetHudFrame("Blades"); if not Blades then return true end
  local TextForBlades = GetUiCached("TextForBlades", Blades, "Sets"); if not TextForBlades then return true end

  local Gas = GetHudFrame("Gas"); if not Gas then return true end
  local TextForGas = GetUiCached("TextForGas", Gas, "Percentage"); if not TextForGas then return true end

  local BladesValue = tonumber(TextForBlades.Text:match("%d+")) or 0
  local GasValue = tonumber(TextForGas.Text:match("%d+")) or 0

  local NeedRefill = BladesValue == 0 or GasValue == 0

  if NeedRefill then
    WhatShouldIBeDoing = "refill"
  end

  return NeedRefill
end

local function IsReloadingBlades() -- When reloading the 0 / 3 counter, the 'BV' is missing
  local Hrp = GetPlayerHrp(LocalPlayer); if not Hrp then return false end

  return Hrp:FindFirstChild("BV") == nil
end

local function HandleAllReloads()
  if not Safe(AreBladesFullyBroken) then return end

  local Hrp = GetPlayerHrp(LocalPlayer); if not Hrp then return end

  local Time = os.clock()

  if Safe(DoINeedToRefill) then
    StatusText = "Refilling"
    DebugPrint("debug", 0, nil, nil, "Refilling.")

    while true do
      if not Config.Autofarm then WhatShouldIBeDoing = "attack"; break end
      if not Safe(DoINeedToRefill) then WhatShouldIBeDoing = "attack"; break end

      if Safe(IsReloadingBlades) then
        task.wait(0.5)
        continue
      end

      if os.clock() - Time > 10 then
        DebugPrint("warn", 0, nil, nil, "Timeout while trying to refill.")
        WhatShouldIBeDoing = "attack"
        break
      end

      if GasTankPosition then
        Hrp.AssemblyLinearVelocity = Vector3Zero
        task.wait(0.24)

        Hrp.Position = GasTankPosition + Vector3New(5, 0, 0)
        Hrp.AssemblyLinearVelocity = Vector3Zero

        task.wait(0.5)

        keypress(0x52)
        task.wait(0.5)
        keyrelease(0x52)

        task.wait(1)
        continue
      end

      local PrimaryPart = GasTankModel:FindFirstChild("Primary")
      if PrimaryPart and PrimaryPart:IsA("BasePart") then
        GasTankPosition = PrimaryPart.Position
        continue
      end

      local PartAddress = ReadMem("uintptr_t", GasTankModel.Address + PrimaryPartOffset)
      if not PartAddress or PartAddress == 0 then
        DebugPrint("warn", 0, nil, nil, "No PrimaryPart for gas tank found!")
        WhatShouldIBeDoing = "attack"
        return
      end

      local Primitive = ReadMem("uintptr_t", PartAddress + BaseToPrimitiveOffset)
      if not Primitive or Primitive == 0 then
        DebugPrint("warn", 0, nil, nil, "No Primitive found for the gas tank part!")
        WhatShouldIBeDoing = "attack"
        return
      end

      local x = ReadMem("float", Primitive + PrimitivePositionOffset)
      local y = ReadMem("float", Primitive + PrimitivePositionOffset + 4)
      local z = ReadMem("float", Primitive + PrimitivePositionOffset + 8)

      if not x or not y or not z then
        WhatShouldIBeDoing = "attack"
        return
      end

      GasTankPosition = Vector3New(x, y, z)
    end

  else -- Only needs to reload blades
    if ReloadingBlades then return end
    if os.clock() - LastReloadingTime < 3 then return end

    ReloadingBlades = true
    LastReloadingTime = os.clock()
    StatusText = "Reloading"

    task.spawn(function()
      if not isrbxactive() then
        ReloadingBlades = false
        return
      end

      Hrp.CFrame = SafePos

      keypress(0x52)
      task.wait(0.5)
      keyrelease(0x52)
      task.wait(0.5)

      ReloadingBlades = false
    end)
  end
end

local function IsObjectVisible(object)
  if not object or not object.Address then return false end

  local value = ReadMem("byte", object.Address + VisibleOffset)
  return value ~= nil and value ~= 0
end

local function IsRetryVisible()
  local Cached = UiCache.RewardsFrame
  if Cached and Cached.Parent then
    return IsObjectVisible(Cached)
  end

  local RewardsFrame = GetPath(PlayerGui, false, "Interface", "Rewards"); if not RewardsFrame then return false end

  UiCache.RewardsFrame = RewardsFrame
  return IsObjectVisible(RewardsFrame)
end

local function TapKey(key, holdTime, afterTime)
  keypress(key)
  task.wait(holdTime)
  keyrelease(key)
  task.wait(afterTime)
end

local RetryCount = 0

local function PressRetry()
  if not Safe(IsRetryVisible) then return end

  task.wait(0.5)

  if RetryCount < 3 then -- ui navigation
    TapKey(0xDC, 0.3, 1.0) -- Backslash
    TapKey(0x44, 0.2, 0.4) -- D
    TapKey(0x44, 0.2, 0.4) -- D
    TapKey(0x0D, 0.3, 0.6) -- Enter

    RetryCount += 1

  else -- Press retry via mouse
    local RetryButton = GetPath(PlayerGui, false, "Interface", "Rewards", "Main", "Info", "Main", "Buttons", "Retry"); if not RetryButton then return end

    local Pos = RetryButton.AbsolutePosition
    local Size = RetryButton.AbsoluteSize

    mousemoveabs(Pos.X + (Size.X / 2), Pos.Y + (Size.Y / 2) + 36)
    task.wait(1)
    mouse1click()
  end
end

local function KillTitan(titan)
  if not titan or not titan.Parent then return end
  if not GetPlayerHrp(LocalPlayer) then return end

  local StartTime = os.clock()
  StatusText = "Attacking"

  while true do
    task.wait(0.06)

    if not Config.Autofarm then break end
    if not Safe(IsTitanAlive, titan) then break end
    if Safe(AreBladesFullyBroken) then break end
    if os.clock() - StartTime > 10 then break end

    if CurrentRobloxState == "Inactive" then
      StatusText = "Window inactive"
      task.wait(0.5)
    else
      if WhatShouldIBeDoing ~= "attack" then task.wait(0.1); continue end
      StatusText = "Attacking"

      Safe(SetTarget, titan)
      Safe(BringNapeToPlayer, titan, NapeSize)

      task.wait()
      mouse1click()
      task.wait(0.03)
      keypress(0x20)
      task.wait(0.03)
      keyrelease(0x20)
    end
  end
end

--#endregion -- HUD / reload / retry functions --


--#region -- Titan ESP --

local HAS_DRAWING = Drawing ~= nil and Drawing.new ~= nil

local ESP_COLOR = Color3.fromRGB(255, 90, 90)
local ESP_TARGET_COLOR = Color3.fromRGB(90, 255, 130)

local function NewDrawing(kind, props)
  local ok, obj = pcall(Drawing.new, kind)
  if not ok or not obj then return nil end

  for key, value in pairs(props) do
    pcall(function() obj[key] = value end)
  end

  return obj
end

local function RemoveDrawing(obj)
  if obj then pcall(function() obj:Remove() end) end
end

local function RemoveEsp(address)
  local obj = EspObjects[address]; if not obj then return end

  RemoveDrawing(obj.Text)
  RemoveDrawing(obj.Line)
  EspObjects[address] = nil
end

local function ClearEsp()
  for address in pairs(EspObjects) do
    RemoveEsp(address)
  end
end

local function CreateEsp()
  return {
    Text = NewDrawing("Text", { Size = 15, Center = true, Outline = true, Color = ESP_COLOR, Visible = false, Text = "" }),
    Line = NewDrawing("Line", { Thickness = 1, Color = ESP_COLOR, Visible = false }),
    LastText = "",
    LastColor = ESP_COLOR,
  }
end

local function SetEspVisible(obj, visible)
  if obj.Text then obj.Text.Visible = visible end
  if obj.Line then obj.Line.Visible = visible and Config.EspTracers end
end

local function HideAllEsp()
  for _, obj in pairs(EspObjects) do
    SetEspVisible(obj, false)
    if obj.Line then obj.Line.Visible = false end
  end
end

-- Returns x, y, onScreen. Uses Matcha's WorldToScreen if it exists, else the camera.
local function ToScreen(position)
  if WorldToScreen then
    local ok, v, visible = pcall(WorldToScreen, position)
    if ok and v then return v.X, v.Y, visible ~= false end
  end

  local Camera = Workspace.CurrentCamera
  if Camera then
    local ok, v, visible = pcall(function() return Camera:WorldToViewportPoint(position) end)
    if ok and v then return v.X, v.Y, visible ~= false end
  end

  return nil, nil, false
end

local EspWasOn = false

local function UpdateEsp()
  if not HAS_DRAWING then return end

  if not Config.TitanESP then
    if EspWasOn then HideAllEsp(); EspWasOn = false end
    return
  end

  EspWasOn = true

  local PlayerHrp = GetPlayerHrp(LocalPlayer)
  local PlayerPos = PlayerHrp and PlayerHrp.Position

  local TracerFrom = nil
  if Config.EspTracers then
    local Camera = Workspace.CurrentCamera
    if Camera then
      local ViewportSize = Camera.ViewportSize
      TracerFrom = Vector2New(ViewportSize.X / 2, ViewportSize.Y)
    end
  end

  for address, titan in pairs(KnownTitans) do
    local obj = EspObjects[address]
    if not obj then
      obj = CreateEsp()
      EspObjects[address] = obj
    end

    local show = false
    local TitanHrp = IsTitanAlive(titan) and GetTitanHrp(titan) or nil

    if TitanHrp then
      local Position = TitanHrp.Position
      local x, y, onScreen = ToScreen(Position)

      if x and onScreen then
        show = true

        local label = GetTitanType(titan)
        if Config.EspDistance and PlayerPos then
          label = label .. " [" .. tostring(math.floor((Position - PlayerPos).Magnitude / 5) * 5) .. "]"
        end

        local color = (titan == CurrentTitanTarget) and ESP_TARGET_COLOR or ESP_COLOR

        if obj.Text then
          if obj.LastText ~= label then
            obj.Text.Text = label
            obj.LastText = label
          end

          if obj.LastColor ~= color then
            obj.Text.Color = color
            if obj.Line then obj.Line.Color = color end
            obj.LastColor = color
          end

          obj.Text.Position = Vector2New(x, y)
        end

        if obj.Line and TracerFrom then
          obj.Line.From = TracerFrom
          obj.Line.To = Vector2New(x, y)
        end
      end
    end

    if obj.Text then obj.Text.Visible = show end
    if obj.Line then obj.Line.Visible = show and Config.EspTracers end
  end
end

--#endregion -- Titan ESP --


--#region -- Menu --

local Toggles = {
  { Key = "Autofarm",    Label = "Autofarm",     Hotkey = 0x70, HotkeyName = "F1" },
  { Key = "TitanESP",    Label = "Titan ESP",    Hotkey = 0x71, HotkeyName = "F2" },
  { Key = "EspDistance", Label = "ESP distance" },
  { Key = "EspTracers",  Label = "ESP tracers",  Hotkey = 0x72, HotkeyName = "F3" },
}

local KEY_INSERT = 0x2D

local MENU_X, MENU_Y, MENU_W = 30, 160, 250
local TITLE_H, ROW_H, FOOTER_H = 30, 28, 48

-- If menu clicks land a little too high / low, adjust this (the in-game top bar can offset the mouse)
local MouseYOffset = 0

local Mouse = nil
pcall(function() Mouse = LocalPlayer:GetMouse() end)

local MenuAll = {}
local MenuRows = {}
local MenuStatus, MenuInfo = nil, nil
local MenuBuilt = false

local function Track(obj)
  if obj then table.insert(MenuAll, obj) end
  return obj
end

local function BuildMenu()
  if not HAS_DRAWING then return end

  local height = TITLE_H + (#Toggles * ROW_H) + FOOTER_H

  Track(NewDrawing("Square", {
    Position = Vector2New(MENU_X, MENU_Y), Size = Vector2New(MENU_W, height),
    Color = Color3.fromRGB(20, 20, 26), Filled = true, ZIndex = 1, Visible = true
  }))

  Track(NewDrawing("Square", {
    Position = Vector2New(MENU_X, MENU_Y), Size = Vector2New(MENU_W, TITLE_H),
    Color = Color3.fromRGB(200, 70, 40), Filled = true, ZIndex = 2, Visible = true
  }))

  Track(NewDrawing("Text", {
    Position = Vector2New(MENU_X + 10, MENU_Y + 7), Size = 16, Text = "Apache  |  AOTR",
    Color = Color3.fromRGB(255, 255, 255), Outline = true, ZIndex = 4, Visible = true
  }))

  for i, toggle in ipairs(Toggles) do
    local y = MENU_Y + TITLE_H + ((i - 1) * ROW_H)

    local label = toggle.Label
    if toggle.HotkeyName then label = label .. "  [" .. toggle.HotkeyName .. "]" end

    Track(NewDrawing("Square", {
      Position = Vector2New(MENU_X + 6, y + 2), Size = Vector2New(MENU_W - 12, ROW_H - 4),
      Color = Color3.fromRGB(34, 34, 44), Filled = true, ZIndex = 2, Visible = true
    }))

    Track(NewDrawing("Text", {
      Position = Vector2New(MENU_X + 14, y + 7), Size = 14, Text = label,
      Color = Color3.fromRGB(230, 230, 230), Outline = true, ZIndex = 4, Visible = true
    }))

    MenuRows[i] = Track(NewDrawing("Text", {
      Position = Vector2New(MENU_X + MENU_W - 52, y + 7), Size = 14, Text = "",
      Color = Color3.fromRGB(255, 255, 255), Outline = true, ZIndex = 4, Visible = true
    }))
  end

  local footerY = MENU_Y + TITLE_H + (#Toggles * ROW_H) + 6

  MenuStatus = Track(NewDrawing("Text", {
    Position = Vector2New(MENU_X + 10, footerY), Size = 13, Text = "Status: ...",
    Color = Color3.fromRGB(255, 200, 120), Outline = true, ZIndex = 4, Visible = true
  }))

  MenuInfo = Track(NewDrawing("Text", {
    Position = Vector2New(MENU_X + 10, footerY + 18), Size = 12, Text = "Insert = hide menu",
    Color = Color3.fromRGB(150, 150, 160), Outline = true, ZIndex = 4, Visible = true
  }))

  MenuBuilt = true
end

local LastMenuRefresh = 0

local function RefreshMenu()
  if not MenuBuilt then return end

  for i, toggle in ipairs(Toggles) do
    local row = MenuRows[i]

    if row then
      local on = Config[toggle.Key]
      row.Text = on and "ON" or "OFF"
      row.Color = on and Color3.fromRGB(100, 255, 130) or Color3.fromRGB(255, 100, 100)
    end
  end

  if MenuStatus then MenuStatus.Text = "Status: " .. StatusText end
  if MenuInfo then MenuInfo.Text = "Titans: " .. tostring(TitanCount) .. "   |   Insert = hide menu" end
end

local function SetMenuVisible(visible)
  Config.MenuVisible = visible

  for _, obj in ipairs(MenuAll) do
    pcall(function() obj.Visible = visible end)
  end
end

local function ToggleOption(key)
  Config[key] = not Config[key]
  Say(key .. ": " .. (Config[key] and "ON" or "OFF"))

  if key == "Autofarm" and not Config[key] then
    StatusText = "Paused"
  end

  RefreshMenu()
end

local HeldKeys = {}

local function KeyJustPressed(code)
  local down = false

  if iskeypressed then
    local ok, result = pcall(iskeypressed, code)
    down = ok and result and true or false
  end

  local previous = HeldKeys[code]
  HeldKeys[code] = down

  return down and not previous
end

local function IsMouseDown()
  local fn = ismouse1pressed or isleftpressed or isleftclicked
  if not fn then return false end

  local ok, result = pcall(fn)
  return ok and result and true or false
end

local MouseWasDown = false

local function HandleMouse()
  local down = IsMouseDown()
  local clicked = down and not MouseWasDown
  MouseWasDown = down

  if not clicked or not MenuBuilt or not Config.MenuVisible then return end

  -- The farm clicks constantly while attacking, so ignore mouse input then (hotkeys still work)
  if StatusText == "Attacking" then return end

  if not Mouse then return end

  local ok, mx, my = pcall(function() return Mouse.X, Mouse.Y end)
  if not ok or not mx or not my then return end

  my += MouseYOffset

  for i, toggle in ipairs(Toggles) do
    local y = MENU_Y + TITLE_H + ((i - 1) * ROW_H)

    if mx >= MENU_X + 6 and mx <= MENU_X + MENU_W - 6 and my >= y and my <= y + ROW_H then
      ToggleOption(toggle.Key)
      return
    end
  end
end

local function UpdateInput()
  if CurrentRobloxState ~= "Active" then return end

  if KeyJustPressed(KEY_INSERT) then
    SetMenuVisible(not Config.MenuVisible)
  end

  for _, toggle in ipairs(Toggles) do
    if toggle.Hotkey and KeyJustPressed(toggle.Hotkey) then
      ToggleOption(toggle.Key)
    end
  end

  HandleMouse()

  local now = os.clock()
  if now - LastMenuRefresh > 0.25 then
    LastMenuRefresh = now
    RefreshMenu()
  end
end

--#endregion -- Menu --


--#region -- Main loops and events --

RegisterPlayer(LocalPlayer)

local function TitanStep()
  local Seen = {}

  for _, titan in ipairs(TitansFolder:GetChildren()) do
    if titan:IsA("Model") then
      local Address = titan.Address
      Seen[Address] = true

      if not KnownTitans[Address] and GetHumanoid(titan) then
        KnownTitans[Address] = titan
        RegisterTitan(titan)
      end
    end
  end

  local Count = 0

  for Address, titan in pairs(KnownTitans) do
    if not Seen[Address] or not titan.Parent then
      KnownTitans[Address] = nil
      TitansCache[Address] = nil
      RemoveEsp(Address)
    else
      Count += 1
    end
  end

  TitanCount = Count
end

local function PlayerStep()
  for _, player in ipairs(Players:GetPlayers()) do
    RegisterPlayer(player)
  end

  for PlayerAddress, cache in pairs(CharacterCache) do
    local character = cache.Character

    if not character or not character.Parent then
      CharacterCache[PlayerAddress] = nil
    end
  end
end

task.spawn(function() -- KnownTitans / TitansCache / ESP cleanup
  while true do
    Safe(TitanStep)
    task.wait(1)
  end
end)

task.spawn(function() -- Players cache
  while true do
    Safe(PlayerStep)
    task.wait(10)
  end
end)

task.spawn(function() -- Tracks whether the Roblox window is focused
  while true do
    local ok, active = pcall(isrbxactive)
    CurrentRobloxState = (ok and active) and "Active" or "Inactive"
    task.wait(0.5)
  end
end)

task.spawn(function() -- The main loop, where the magic happens
  local LastRetryCheck = 0

  while true do
    if not Config.Autofarm then
      StatusText = "Paused"
      task.wait(0.5)
      continue
    end

    -- Retry button check is throttled to twice a second
    local now = os.clock()
    if now - LastRetryCheck >= 0.5 then
      LastRetryCheck = now

      if Safe(IsRetryVisible) then
        StatusText = "Retrying"
        PressRetry()
        task.wait(3)
        continue
      end
    end

    if Safe(AreBladesFullyBroken) then
      HandleAllReloads()
      task.wait(1)
      continue
    end

    local NearestTitan = Safe(GetNearestTitan)

    if not NearestTitan then
      StatusText = "Searching for titans"
      task.wait(0.05)
      continue
    end

    KillTitan(NearestTitan)
    task.wait(0.1)
  end
end)

task.spawn(function() -- loop to fix matcha's weird task's bug
  while true do
    task.wait(math.huge)
  end
end)

-- Per-frame follow: everything expensive was resolved in SetTarget, so this stays tiny
local function FollowTarget()
  if not Config.Autofarm then return end
  if WhatShouldIBeDoing ~= "attack" then return end

  local Hrp = GetPlayerHrp(LocalPlayer); if not Hrp then return end

  if CurrentRobloxState == "Inactive" then
    Hrp.CFrame = SafePos
    return
  end

  if not CurrentTitanTarget or not IsValid(TargetHrp) then return end

  local p = TargetHrp.Position
  Hrp.CFrame = CFrame.new(p.X, p.Y + TargetHeight + math.sin(os.clock() * TWO_PI) * BobAmplitude, p.Z)
end

if HAS_DRAWING then
  pcall(BuildMenu)
  pcall(RefreshMenu)
else
  Fail("Drawing library not found, so there is no menu or ESP. Autofarm still works.")
end

RunService.RenderStepped:Connect(function()
  pcall(FollowTarget)

  if not pcall(UpdateEsp) then
    pcall(ClearEsp) -- rebuilt on the next frame
  end

  pcall(UpdateInput)
end)

Say("Loaded. Insert = menu, F1 = autofarm, F2 = titan ESP, F3 = tracers.")

--#endregion -- Main loops and events --

]==])()
