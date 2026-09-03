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
local Grid = require(Shared.Grid)
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
local equipRemote: RemoteEvent
local trailerRemote: RemoteEvent

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
	--- Tools kept across runs, so the book knows not to offer one twice.
	permanentTools: { [string]: boolean },
	upgrades: { [string]: number },
	walkSpeed: number,
	dumpRadius: number,
	hasPortableTrailer: boolean,
	rentalSecondsLeft: number,
	rentalToolId: string,
	--- Worlds this player has finished, which is what the level select locks on.
	worldsBeaten: { [string]: boolean },
	bestTimes: { [string]: number },
	showIntro: boolean,
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
		--- Per world, in seconds. The map cards show it as a personal best.
		bestTimes = if profile then profile.bestTimes else {},
		--- True until the opening has been watched once.
		showIntro = profile ~= nil and not profile.introSeen,
		cash = run.cash,
		tips = EconomyService.tips(player),
		earned = run.earned,
		bagWeight = BagService.weight(player),
		bagCapacity = BagService.capacity(player),
		bagValue = BagService.baseValue(player) * Balance.cashMultiplier(run.upgrades, mods),
		cashMultiplier = Balance.cashMultiplier(run.upgrades, mods),
		fuel = run.fuel,
		fuelCapacity = Balance.fuelCapacity(run.upgrades),
		equippedTool = run.equippedTool,
		ownedTools = run.ownedTools,
		permanentTools = if profile then profile.permanentTools else {},
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
		tips = EconomyService.tips(player),
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

--[[
	There is no dump remote any more.

	It was described as "the Empty Bag product's path", and the product does
	not use it: `MonetizationService` calls `BagService.dump` directly on the
	server when the receipt clears. Nothing on the client fired it either — the
	only reference left was the server connecting a handler to it.

	What it did do was sell a whole bag the instant it was called, which skips
	the pour. That pause is deliberate: "the pause while it pours is the moment
	the trip was for". So the only thing this remote could still be used for
	was a hand-written client skipping it.
]]
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

--------------------------------------------------------------------
-- The portable trailer
--------------------------------------------------------------------

--[[
	Haul level 1 reads "unlocks the portable trailer" on the shed board, the
	Journal reads back "portable, N studs", and the earn-rate model shortens
	every walk to the trailer the moment it is owned. None of that was true.
	`PlaceTrailer` was declared in Remotes, created as a live RemoteEvent, and
	connected on neither side, so ninety dollars bought a wider dump radius and
	a sentence — the same shape of bug as the Instant Dump pass above, which is
	why that one has a paragraph and this one now has a handler.

	Parking is the whole feature: press the key, the trailer arrives behind
	you. It is the property's only trailer, so it moves for the whole team.
]]
local PARK_COOLDOWN = 2
--- Far enough back that the trailer never lands on the player who called it,
--- close enough that they are still inside the base twelve-stud dump radius.
local PARK_BEHIND = 9
--- Checked well clear of the ground plate, so only walls and buildings block.
local PARK_PROBE_HEIGHT = 8
local PARK_PROBE = Vector3.new(14, 12, 18)

local lastPark: { [Player]: number } = {}

local parkOverlap = OverlapParams.new()
parkOverlap.FilterType = Enum.RaycastFilterType.Exclude

local function onPlaceTrailer(player: Player)
	local run = RunState.find(player)
	local trailer = WorldService.trailerPart
	local grid = WorldService.grid
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not run or not trailer or not grid or not root or not root:IsA("BasePart") then
		return
	end

	if not Balance.hasPortableTrailer(run.upgrades) then
		EconomyService.notify(player, "stall", "Buy Haul in your book to park the trailer where you stand", nil)
		return
	end

	local now = os.clock()
	if now - (lastPark[player] or -math.huge) < PARK_COOLDOWN then
		return
	end

	local at = root.Position - root.CFrame.LookVector * PARK_BEHIND
	local tx, tz = Grid.worldToTile(grid, at.X, at.Z)
	if not Grid.inBounds(grid, tx, tz) then
		EconomyService.notify(player, "stall", "Too far off the property to park the trailer", nil)
		return
	end

	-- Quarter-turned to match the way `buildTrailer` parks it along the kerb.
	local ground = WorldService.tilePointToWorld(tx, tz)
	local target = CFrame.new(ground + Vector3.new(0, 2, 0)) * CFrame.Angles(0, math.rad(90), 0)

	parkOverlap.FilterDescendantsInstances = if character then { trailer, character } else { trailer }
	local probe = CFrame.new(ground + Vector3.new(0, PARK_PROBE_HEIGHT, 0))
	for _, part in workspace:GetPartBoundsInBox(probe, PARK_PROBE, parkOverlap) do
		if part.CanCollide and part.Anchored then
			EconomyService.notify(player, "stall", "No room to park the trailer here", nil)
			return
		end
	end

	lastPark[player] = now
	trailer.CFrame = target
	EconomyService.notifyAll("quest", `{player.DisplayName} parked the trailer`, nil)
end

function PlayerService.start()
	playerState = Remotes.event(Remotes.PLAYER_STATE)
	equipRemote = Remotes.event(Remotes.EQUIP)
	trailerRemote = Remotes.event(Remotes.PLACE_TRAILER)

	--[[
		The opening is watched once and then never again.

		Marked from the client rather than on arrival, because a player who
		joins and leaves inside the first four seconds has not seen it, and
		nothing about that should cost them the story.
	]]
	Remotes.event(Remotes.INTRO_DONE).OnServerEvent:Connect(function(player: Player)
		DataService.withProfile(player, function(profile)
			profile.introSeen = true
		end)
		PlayerService.push(player)
	end)

	equipRemote.OnServerEvent:Connect(onEquip)
	trailerRemote.OnServerEvent:Connect(onPlaceTrailer)

	Players.PlayerRemoving:Connect(function(player: Player)
		lastPark[player] = nil
	end)

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
