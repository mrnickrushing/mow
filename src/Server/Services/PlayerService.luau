--!strict
--[[
	PlayerService — keeps each client's view of itself up to date, applies
	upgrade-derived character stats, and handles selling at the trailer.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local GameConfig = require(Shared.Config.GameConfig)
local Remotes = require(Shared.Remotes)
local Tools = require(Shared.Config.Tools)
local BagService = require(script.Parent.BagService)
local WorldService = require(script.Parent.WorldService)
local BoostService = require(script.Parent.BoostService)
local DataService = require(script.Parent.DataService)
local RunState = require(script.Parent.RunState)
local EconomyService = require(script.Parent.EconomyService)

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
	--- Worlds this player has finished, which is what the level select locks on.
	worldsBeaten: { [string]: boolean },
}

function PlayerService.buildState(player: Player): StatePayload?
	local run = RunState.find(player)
	if not run then
		return nil
	end

	local mods = EconomyService.modifiers(player)
	local profile = DataService.get(player)

	return {
		worldsBeaten = if profile then profile.worldsBeaten else {},
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

--- True when the player is close enough to the trailer to empty the bag into
--- it. The radius grows with the Haul line, which is what those levels buy.
function PlayerService.canDump(player: Player): boolean
	local run = RunState.find(player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local trailer = WorldService.trailerPart
	if not run or not root or not root:IsA("BasePart") or not trailer then
		return false
	end

	--[[
		Instant Dump sells from anywhere, which is the whole of what it sells.

		The pass was on the board at 599 Robux with "Sell your bag from
		anywhere on the property" written under it, and nothing anywhere read
		it: it reached no modifier and this function still measured the
		distance to the trailer. Charging for a thing that does nothing is the
		one bug worth fixing before any of the scenery.
	]]
	if EconomyService.modifiers(player).instantDump then
		return true
	end

	local radius = Balance.dumpRadius(run.upgrades)
	local offset = root.Position - trailer.Position
	return offset.X * offset.X + offset.Z * offset.Z <= radius * radius
end

--[[
	The pour. While a player stands in trailer range, their bag streams out at
	a rate that empties any bag in a couple of seconds, and each sip is sent
	down as a `tally` so the client's gold counter climbs with the stream.

	Nothing is pressed and nothing is held: walking up with a full bag is the
	whole interaction, and the pause while it pours is the moment the trip was
	for.
]]
local function stepPour(elapsed: number)
	for _, player in Players:GetPlayers() do
		if BagService.weight(player) > 0 and PlayerService.canDump(player) then
			local capacity = math.max(BagService.capacity(player), 1)
			local sip = capacity / GameConfig.BAG_EMPTY_SECONDS * elapsed
			local paid = BagService.sellUpTo(player, sip)
			if paid > 0 then
				EconomyService.notify(player, "tally", "", paid)
				PlayerService.pushLive(player)
			end
		end
	end
end

--- The DUMP remote is only the Empty Bag product's path now; the trailer
--- pours on its own.
local function onDump(player: Player)
	if BagService.weight(player) <= 0 then
		return
	end
	if not PlayerService.canDump(player) then
		EconomyService.notify(player, "tooFar", "Empty your bag at the trailer", nil)
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
			local elapsed = task.wait(1 / PUSH_HZ)
			stepPour(elapsed)
			for _, player in Players:GetPlayers() do
				PlayerService.pushLive(player)
			end
		end
	end)
end

return PlayerService
