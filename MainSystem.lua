--------------------------------------------| Notes |-------------------------------------------
--|         - This script intentionally avoids ModuleScripts to keep all related mining
--|            logic auditable in one place (for application).
--|         - Pickaxe name is expected to be "Iron Pickaxe", "Gold Pickaxe", etc..
--|		    - Ore model name is expected to be "IronOre", "GoldOre", etc..
--|		    - Ore Drops must be a model and has 1 part/mesh named root.
--|		    - No animations are implemented here because a client script would be needed.
------------------------------------------------------------------------------------------------
--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")

--// References
local ServerAssets = ServerStorage:WaitForChild("Assets") --// Server storage for assets

local OreTemplates = ServerAssets:WaitForChild("OreModels")   --// Folder with ore models
local OreDropTemplates = ServerAssets:WaitForChild("OreDrops") --// Folder with ore drop templates
local OreSpawnLocations = workspace:WaitForChild("OreSpawnLocations"):GetChildren() --// Folder with spawn locations for ores
local OresTools_Folder = ServerAssets:WaitForChild("OresTools") --// Folder to store tools for ores  (Tools are created dynamically!)

--// Tables
local OresByRarity = {}

local Settings = {
	SpawnOreCooldown = 3      -- Spawn Ore every ... seconds
	,MaxDistanceToOre = 10    -- Maximum distance that the ore can be from the player to be mined (ProximityPrompt range and distance checks)
	,MaxOres = 10             -- Maximum number of ores that can be spawned at once
	,OreDespawnTime = 50      -- Despawn ore after ... seconds (if mined, cooldown will reset)
	,OreDropsDespawnTime = 60 -- Despawn ore drops after ... seconds (if not picked up) 
	,MaxPickupDistance = 10   -- Maximum distance that the player can be from the ore to pick up drops (ProximityPrompt range and distance checks)
}
-----------------------------
-------- Ore Config ---------
-----------------------------
local RarityChances = {    --// Chance of each rarity to spawn
	VeryCommon = 50,
	Common = 30,
	Uncommon = 15,
	Rare = 4,
	VeryRare = 1,
}

local OreData = {
	["Copper"] = {
		Health = 50              -- Health of the ore
		,CashReward = 5          -- Amount of money the player gets for mining this ore
		,DropAmount = 3          -- Amount of ores that the ore drops when mined
		,ModelName = "CopperOre" -- Name of the ore model in ReplicatedStorage.OreAssets
		,Rarity = "VeryCommon"   -- Rarity of the ore
		,MinRequiredTier = 1     -- Minimum Required tier to mine this ore
	}
	,["Iron"] = {
		Health = 100
		,CashReward = 10
		,DropAmount = 2
		,ModelName = "IronOre"
		,Rarity = "Common"
		,MinRequiredTier = 1
	}
	,["Gold"] = {
		Health = 200
		,CashReward = 25
		,DropAmount = 1
		,ModelName = "GoldOre"
		,Rarity = "Uncommon"
		,MinRequiredTier = 2
	}
}

-----------------------------
------ Pickaxe Config -------
-----------------------------
local PickaxesData = {
	["Wooden Pickaxe"] = {
		Damage = 25
		,Cooldown = 3
		,Tier = 1
	}
	,["Iron Pickaxe"] = {
		Damage = 40
		,Cooldown = 2.5
		,Tier = 2
	}
}

-----------------------------
-------- Player Init --------
-----------------------------
local LeaderboardValues = {
	Cash = {DefaultValue = 0, Type = "IntValue"},

}
Players.PlayerAdded:Connect(function(player)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player
	for statName, Data in pairs(LeaderboardValues) do
		local stat
		local success,_ = pcall(function()
			stat = Instance.new(Data.Type)
		end)
		if success then	
			stat.Name = statName
			stat.Value = Data.DefaultValue
			stat.Parent = leaderstats
		else
			warn("Please set a valid instance type for leaderstat value '"..(statName or "nill").."'!")
			warn("Current instance type that is set: "..(Data.Type or "nil"))
			return
		end
	end
end)

-----------------------------
------ Cooldown Manager -----
-----------------------------
local CooldownManager = {
	Players = {} -- [Player] = nextAllowedTime
}
-- Server time is used instead of tick() to prevent desync issues caused by lag or client-side time differences
function CooldownManager:CanMine(Player)
	local now = workspace:GetServerTimeNow() 
	if not self.Players[Player] then
		return true
	end
	return now >= self.Players[Player]
end

function CooldownManager:StartCooldown(Player, Cooldown)
	self.Players[Player] = workspace:GetServerTimeNow() + Cooldown
end

Players.PlayerRemoving:Connect(function(Player) -- Cooldown data is cleared on PlayerRemoving to prevent memory leaks
	if CooldownManager.Players[Player] then
		CooldownManager.Players[Player] = nil
	end
end)

-----------------------------
--------- Ore State --------- -- Centralized state table used instead of Instances to avoid unnecessary replication and improve server-side control
-----------------------------
local OreState = { -- Ore IDs are generated sequentially to guarantee uniqueness without relying on Instance:GetDebugId()
	ByID = {} -- [OreID] -> Ore
	,NextID = 0
	,SpawnedOres = 0 --// Number of spawned ores
}

function OreState:AddOre(Ore:Model)
	OreState.NextID += 1       -- Increment the next ID
	OreState.SpawnedOres += 1  -- Increment the spawned ores count
	local OreID = OreState.NextID 
	OreState.ByID[OreID] = Ore -- Store the ore with its ID 
	Ore:SetAttribute("OreID", OreID)
	return OreID
end

function OreState:RemoveOre(OreID)
	OreState.SpawnedOres -= 1
	OreState.ByID[OreID] = nil
end

-----------------------------
-------- World Data ---------
-----------------------------
local World = {
	SpawnSlots = {} --// List of spawn locations for ores
}
--// Get A Random Spawn Location (For OreID)
--// OreID: number
function World:GetRandomSpawnSlot(OreID)
	local validLocations = {}
	for _, Slot in pairs(World.SpawnSlots) do -- Loop through all spawn locations
		if not Slot.SpawnedOre then -- If the spawn location has no ore spawned
			table.insert(validLocations, Slot) -- Add it to the valid locations
		end
	end

	local ChosenSlot = validLocations[math.random(1, #validLocations)]
	if ChosenSlot then
		ChosenSlot.SpawnedOre = OreID
	end
	return ChosenSlot
end

function World:RemoveFromSlot(OreID) -- Spawn slot is freed to prevent dead slots after ore removal
	for _, Slot in pairs(World.SpawnSlots) do
		if Slot.SpawnedOre == OreID then
			Slot.SpawnedOre = nil
			return
		end
	end
end

-----------------------------
--------- Functions ---------
-----------------------------
--// Safely delete ore
--// OreID: number
--// Order: boolean. Default: false. (if true, it will delete the ore, if false, will check for TimeSinceLastMined.
--//  true should be used when you want to delete the ore, and false should be used for despawning logic)
local function DeleteOre(OreID, Order:boolean)
	local Ore = OreState.ByID[OreID]
	if Ore then
		local LastMined = Ore:GetAttribute("LastMined")
		if not Order and LastMined then
			local TimeSinceLastMined = workspace:GetServerTimeNow() - LastMined
			if TimeSinceLastMined < Settings.OreDespawnTime then
				task.delay(Settings.OreDespawnTime, function()
					DeleteOre(OreID, false)
				end)
				return
			end
		end
		Ore:Destroy()
		World:RemoveFromSlot(OreID)
		OreState:RemoveOre(OreID)
	end	
end
--// Register an ore
--// Use this function to register a new ore, will add health, ID, etc...
--// Ore: Model
local function RegisterOre(Ore:Model)
	local OreID = OreState:AddOre(Ore)
	Ore:SetAttribute("LastMined", workspace:GetServerTimeNow())
	task.delay(Settings.OreDespawnTime, function()
		DeleteOre(OreID, false)
	end)
	return OreID
end
--// Randomly select a Rarity
--// Returns a string of the rarity
local function GetRandomRarity() -- Weighted random selection ensures rarer ores appear less frequently without hardcoding spawn limits
	local total = 0
	for _, chance in pairs(RarityChances) do total += chance end
	local RandomNumber = math.random(1,total)
	local cumulative = 0
	for rarity, chance in pairs(RarityChances) do
		cumulative += chance
		if RandomNumber <= cumulative then return rarity end
	end
	return "VeryCommon"
end
------------------------------------| Game Initialization |------------------------------------
local function Init()
	--// Init OreRarityTable
	local OreRarityTable = OresByRarity
	for oreName, oreInfo in pairs(OreData) do
		if not OreRarityTable[oreInfo.Rarity] then -- Ore rarity group doesn't exist?
			OreRarityTable[oreInfo.Rarity] = {} -- Create rarity group
		end
		table.insert(OreRarityTable[oreInfo.Rarity], oreName)
	end

	--// Init OreSpawnLocations
	for _, SpawnLocation in pairs(OreSpawnLocations) do
		table.insert(World.SpawnSlots, {['SpawnLocation'] = SpawnLocation, SpawnedOre = nil})
	end
	
	--// Make Tools for ore
	for _, Ore in pairs(OreDropTemplates:GetChildren()) do
		local OreClone = Ore:Clone()
		local OreTool = Instance.new("Tool")
		local root = OreClone:FindFirstChild("root")
		if not root then 
			warn("Ore model " .. Ore.Name .. " is missing a 'root' part!")
			warn("Ore Drop must be a model, has 1 part/mesh named root, and is not anchored.")
			continue
		end
		root.Name = "Handle"
		root.Anchored = false
		root.Parent = OreTool
		root.CanCollide = false
		root.Massless = true
		OreClone:Destroy()
		
		OreTool.Name = Ore.Name
		OreTool.RequiresHandle = true
		OreTool.CanBeDropped = false
		OreTool.Parent = OresTools_Folder
	end
	
	--// Hide Spawn loactions
	for _, SpawnLocation in pairs(OreSpawnLocations) do
		SpawnLocation.Transparency = 1
		SpawnLocation.CanCollide = false
	end
end
local Success, ErrorMsg = pcall(Init) --// pcall prevents partial initialization from crashing the server
if not Success then
	warn("Error during initialization: " .. ErrorMsg)
end
--// Drop ores at the ore's position
--// Player: Player that will own the ores
--// Ore: Ore model
local function DropOres(Player:Player, Ore:Model)
	local Data_ForOre = OreData[Ore.Name:split("Ore")[1]]
	local OreDropTemplate = OreDropTemplates[Ore.Name]
	if not OreDropTemplate then 
		warn("No Ore Drop Template found in 'OreDropTemplate' folder")
		warn("Consider adding a model for this ore")
		return 
	end
	
	for i = 1, Data_ForOre.DropAmount do
		local DropOre_Clone = OreDropTemplate:Clone()
		local Position = Ore.PrimaryPart.Position + Vector3.new(math.random(2,5), math.random(2,5), math.random(2,5))
		DropOre_Clone.Parent = workspace
		DropOre_Clone.root.CanCollide = true
		DropOre_Clone.root.Anchored = false
		DropOre_Clone:PivotTo(CFrame.new(Position))
		
		DropOre_Clone:SetAttribute("Owner", Player.UserId)
		DropOre_Clone:SetAttribute("PickedUp", false)

		
		local pp = Instance.new("ProximityPrompt")
		pp.Parent = DropOre_Clone.root
		pp.ActionText = "Pick Up"
		pp.ObjectText = Ore.Name:split("Ore")[1]
		pp.RequiresLineOfSight = false
		pp.HoldDuration = 0.1
		pp.KeyboardKeyCode = Enum.KeyCode.F
		pp.MaxActivationDistance = Settings.MaxPickupDistance
		
		pp.Triggered:Connect(function(Player)
			if DropOre_Clone:GetAttribute("PickedUp") then return end
			if DropOre_Clone:GetAttribute("Owner") ~= Player.UserId then return end -- make sure player owns the ore

			if not Player.Character or not Player.Character:FindFirstChild("HumanoidRootPart") then return end
			-- Distance is rechecked server-side to prevent exploiters from triggering prompts remotely
			local Distance = (Player.Character.HumanoidRootPart.Position - DropOre_Clone.root.Position).Magnitude
			if Distance > Settings.MaxPickupDistance + 5 then return end
			DropOre_Clone:SetAttribute("PickedUp", true)
			DropOre_Clone:Destroy()
			local OreTool = OresTools_Folder:FindFirstChild(Ore.Name)
			if not OreTool then return end
			OreTool:Clone().Parent = Player.Backpack
		end)
		
		Debris:AddItem(DropOre_Clone, Settings.OreDropsDespawnTime)
	end
end

--// Mine Ore
--// Use this function to mine an ore, after checking pickaxe equipped, cooldown, etc...
--// Player: Player mining the ore
--// OreID: number
--// PickaxeData: table
local function MineOre(Player:Player, OreID:number, PickaxeData) 
	local Ore:Model = OreState.ByID[OreID]
	if not Ore then return end
	if not Player.Character or not Player.Character:FindFirstChild("HumanoidRootPart") then return end
	-- Distance is rechecked server-side to prevent exploiters from triggering prompts remotely
	local Distance = (Player.Character.HumanoidRootPart.Position - Ore.PrimaryPart.Position).Magnitude
	if Distance > Settings.MaxDistanceToOre + 5 then return end
	local Health = Ore:GetAttribute("OreHealth")
	local NewHealth = math.max(0, Health - PickaxeData.Damage)
	if NewHealth == 0 then
		if Player:FindFirstChild("leaderstats") and Player.leaderstats:FindFirstChild("Cash") then --Make sure leaderstats and cash exists
			Player.leaderstats.Cash.Value += OreData[Ore.Name:split("Ore")[1]].CashReward
			DropOres(Player, Ore)
		else
			warn("Please make sure players has a 'Cash' int value in leaderstats!")
		end
		DeleteOre(OreID, true)
	end
	Ore:SetAttribute("OreHealth", NewHealth)
	Ore:SetAttribute("LastMined", workspace:GetServerTimeNow())
end
--// Attempt to spawn an ore
local function AttemptToSpawnOre()
	local RandomRarity = GetRandomRarity()
	local OreRarityTable = OresByRarity
	local OresList = OreRarityTable[RandomRarity]
	if not OresList then return end --[[There is no Ore with Rarity 'RandomRarity']]
	local RandomOre = OresList[math.random(1, #OresList)]
	local OreData_ForOre = OreData[RandomOre]

	local OreName = RandomOre.."Ore"
	local OreTemplate = OreTemplates:FindFirstChild(OreName)
	if not OreTemplate then 
		warn("There is no Ore named '".. OreName .."' found in OreTemplates!")
		warn("Please add your model for this ore in OreTemplates folder.")
		return
	end
	local Ore:Model = OreTemplate:Clone()
	Ore.Parent = workspace
	local PrimaryPart = Ore.PrimaryPart
	if not PrimaryPart then
		warn("Ore model '".. OreName .."' has no set PrimaryPart")
		warn("Please set a PrimaryPart for your Ore model(s).")
		return
	end
	local OreID = RegisterOre(Ore)
	local SpawnSlot = World:GetRandomSpawnSlot(OreID)
	if not SpawnSlot then 
		warn("No avaliable spawn locations!")
		warn("Consider increasing the number of spawn locations or decreasing the number of maximum spawnable ores in settings.")
		return
	end
	local BaseCFrame = SpawnSlot.SpawnLocation.CFrame
	local RandomAngle = math.rad(math.random(0, 360))

	Ore:PivotTo(
		BaseCFrame * CFrame.Angles(0, RandomAngle, 0)
	)

	Ore:SetAttribute("OreHealth", OreData_ForOre.Health) -- Health is stored as an attribute to allow easy debugging and future UI integration

	local Prompt = Instance.new("ProximityPrompt")
	Prompt.Parent = PrimaryPart
	Prompt.ActionText = "Mine"
	Prompt.ObjectText = OreName
	Prompt.RequiresLineOfSight = false
	Prompt.HoldDuration = 0
	Prompt.MaxActivationDistance = Settings.MaxDistanceToOre
	Prompt.Triggered:Connect(function(Player)
		--// Check if player has a pickaxe equipped
		local EquippedTool = Player.Character:FindFirstChildOfClass("Tool")
		-- Checks intentionally fails silently to avoid revealing internal validation logic to exploiters
		if not EquippedTool then return end
		if EquippedTool.Name:split(" ")[2] ~= "Pickaxe" then return end

		if Ore:GetAttribute("Owner") then --// Check if ore is already 'claimed'
			if Ore:GetAttribute("Owner") ~= Player.UserId then
				print("Cannot mine this ore, owner is '".. Ore:GetAttribute("Owner") .."'")
				return
			end
		end
		Ore:SetAttribute("Owner",  Player.UserId) --// claim ownership

		local Data = PickaxesData[EquippedTool.Name]
		if not Data then 
			warn("No pickaxe data found in 'PickaxesData' for pickaxe '".. EquippedTool.Name .."'!")
			warn("Consider adding data for this pickaxe or remove it.")
			return 
		end
		if not CooldownManager:CanMine(Player) then return end

		if Data.Tier < OreData_ForOre.MinRequiredTier then return end
		Prompt.Enabled = false
		task.delay(Data.Cooldown, function()
			Prompt.Enabled = true
		end)
		CooldownManager:StartCooldown(Player, Data.Cooldown)

		MineOre(Player, OreID, Data)
	end)
end	

task.spawn(function()
	while true do
		task.wait(Settings.SpawnOreCooldown)

		if OreState.SpawnedOres >= Settings.MaxOres then --// Max ores spawned?
			continue       --// skip spawning a new ore
		end

		AttemptToSpawnOre()
	end
end)
