--!strict
--[[
	PlayerService — keeps each client's view of itself up to date, applies
	upgrade-derived character stats, and handles selling at the trailer.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Remotes = require(Shared.Remotes)
local Tools = require(Shared.Config.Tools)
local BagService = require(script.Parent.BagService)
local BoostService = require(script.Parent.BoostService)
local DataService = require(script.Parent.DataService)
local RunState = require(script.Parent.RunState)
local EconomyService = require(script.Parent.EconomyService)
local WorldService = require(script.Parent.WorldService)

local PlayerService = {}

local playerState: RemoteEvent
local dumpRemote: RemoteEvent
local equipRemote: RemoteEvent

--- How often full state is pushed to each client, in Hz.
local PUSH_HZ = 5

export type StatePayload = {
	cash: number,
	tips: number,
	earned: number,
	bagWeight: number,
	bagCapacity: number,
	bagValue: number,
	--- Everything stacked: upgrades, passes and any boost running.
	cashMultiplier: number,
	fuel: number,
	fuelCapacity: number,
	equippedTool: string,
	ownedTools: { [string]: boolean },
	upgrades: { [string]: number },
	walkSpeed: number,
	dumpRadius: number,
	hasPortableTrailer: boolean,
	rentalSecondsLeft: number,
	rentalToolId: string,
}

function PlayerService.buildState(player: Player): StatePayload?
	local run = RunState.find(player)
	if not run then
		return nil
	end

	local mods = EconomyService.modifiers(player)

	return {
		cash = run.cash,
		tips = run.tips,
		earned = run.earned,
		bagWeight = BagService.weight(player),
		bagCapacity = BagService.capacity(player),
		bagValue = BagService.baseValue(player) * Balance.cashMultiplier(run.upgrades, mods),
		cashMultiplier = Balance.cashMultiplier(run.upgrades, mods),
		fuel = run.fuel,
		fuelCapacity = Balance.fuelCapacity(run.upgrades),
		equippedTool = run.equippedTool,
		ownedTools = run.ownedTools,
		upgrades = run.upgrades,

		walkSpeed = Balance.walkSpeed(run.upgrades, mods),
		dumpRadius = Balance.dumpRadius(run.upgrades),
		hasPortableTrailer = Balance.hasPortableTrailer(run.upgrades),
		rentalSecondsLeft = BoostService.rentalSecondsLeft(player),
		rentalToolId = BoostService.rentedTool(player) or "",
	}
end

--- Pushes the full state, including the tables that rarely change.
function PlayerService.push(player: Player)
	local state = PlayerService.buildState(player)
	if state then
		playerState:FireClient(player, state)
	end
end

--[[
	Pushes only the fast-moving numbers.

	Cash and bag weight change several times a second; owned tools and upgrade
	levels change a handful of times an hour. Sending the latter at the former's
	rate would waste most of the per-client bandwidth budget on unchanged tables.
]]
function PlayerService.pushLive(player: Player)
	local run = RunState.find(player)
	if not run then
		return
	end
	local mods = EconomyService.modifiers(player)
	playerState:FireClient(player, {
		partial = true,
		cash = run.cash,
		tips = run.tips,
		earned = run.earned,
		bagWeight = BagService.weight(player),
		bagCapacity = BagService.capacity(player),
		bagValue = BagService.baseValue(player) * Balance.cashMultiplier(run.upgrades, mods),
		cashMultiplier = Balance.cashMultiplier(run.upgrades, mods),
		fuel = run.fuel,
		rentalSecondsLeft = BoostService.rentalSecondsLeft(player),
	})
end

function PlayerService.pushAll()
	for _, player in Players:GetPlayers() do
		PlayerService.push(player)
	end
end

--------------------------------------------------------------------
-- Character
--------------------------------------------------------------------

--- Applies walk speed from the player's upgrades to their humanoid.
function PlayerService.applyCharacterStats(player: Player)
	local run = RunState.find(player)
	local character = player.Character
	if not run or not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = Balance.walkSpeed(run.upgrades, EconomyService.modifiers(player))
	end
end

--------------------------------------------------------------------
-- Selling
--------------------------------------------------------------------

--- True when the player is close enough to a trailer to sell.
function PlayerService.canDump(player: Player): boolean
	local run = RunState.find(player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local trailer = WorldService.trailerPart
	if not run or not root or not root:IsA("BasePart") or not trailer then
		return false
	end

	local radius = Balance.dumpRadius(run.upgrades)
	local offset = root.Position - trailer.Position
	return offset.X * offset.X + offset.Z * offset.Z <= radius * radius
end

local function onDump(player: Player)
	if BagService.weight(player) <= 0 then
		return
	end
	if not PlayerService.canDump(player) then
		EconomyService.notify(player, "tooFar", "Get closer to the trailer", nil)
		return
	end
	BagService.dump(player)
	PlayerService.push(player)
end

--------------------------------------------------------------------
-- Equipping
--------------------------------------------------------------------

local function onEquip(player: Player, toolId: any)
	if type(toolId) ~= "string" then
		return
	end
	local run = RunState.find(player)
	if not run or not run.ownedTools[toolId] or not Tools.get(toolId) then
		return
	end
	run.equippedTool = toolId
	PlayerService.push(player)
end

--------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------

function PlayerService.start()
	playerState = Remotes.event(Remotes.PLAYER_STATE)
	dumpRemote = Remotes.event(Remotes.DUMP)
	equipRemote = Remotes.event(Remotes.EQUIP)

	dumpRemote.OnServerEvent:Connect(onDump)
	equipRemote.OnServerEvent:Connect(onEquip)

	local function hookCharacter(player: Player)
		player.CharacterAdded:Connect(function()
			-- Wait a beat for the humanoid to exist before touching it.
			task.defer(function()
				PlayerService.applyCharacterStats(player)
			end)
		end)
	end

	for _, player in Players:GetPlayers() do
		hookCharacter(player)
	end
	Players.PlayerAdded:Connect(hookCharacter)

	DataService.ProfileLoaded:Connect(function(player: Player)
		PlayerService.applyCharacterStats(player)
		PlayerService.push(player)
	end)

	BoostService.Changed:Connect(function(player: Player)
		PlayerService.applyCharacterStats(player)
		PlayerService.push(player)
	end)

	-- Numbers that move constantly go out often and cheaply; the heavy tables
	-- (owned tools, upgrade levels, unlocked zones) only go out when they change.
	task.spawn(function()
		while true do
			task.wait(1 / PUSH_HZ)
			for _, player in Players:GetPlayers() do
				PlayerService.pushLive(player)
			end
		end
	end)
end

return PlayerService
