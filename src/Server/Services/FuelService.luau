--!strict
--[[
	FuelService — the soft limiter on the powerful gear.

	Gas tools and vehicles burn fuel while they are actually cutting, not while
	they are merely equipped, so nobody is punished for walking to the far side
	of the lot. Running dry sends you to the shed, which is the whole point: it
	keeps the cheap manual tools relevant as a backup and gives the Fuel Tank
	upgrade line something real to buy back.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Tools = require(Shared.Config.Tools)
local RunState = require(script.Parent.RunState)
local Loop = require(Shared.Util.Loop)
local EconomyService = require(script.Parent.EconomyService)

local FuelService = {}

--- Studs within which the shed refuels you.
local REFUEL_RADIUS = 20
--- Fuel restored per second while standing at the shed.
local REFUEL_RATE = 45

--- Warn once per empty, not once per frame.
local warned: { [Player]: boolean } = {}

function FuelService.capacity(player: Player): number
	local run = RunState.find(player)
	if not run then
		return 0
	end
	return Balance.fuelCapacity(run.upgrades)
end

function FuelService.remaining(player: Player): number
	local run = RunState.find(player)
	if not run then
		return 0
	end
	if EconomyService.modifiers(player).infiniteFuel then
		return Balance.fuelCapacity(run.upgrades)
	end
	return run.fuel
end

function FuelService.isEmpty(player: Player): boolean
	return FuelService.remaining(player) <= 0
end

--- Refills the tank to full.
function FuelService.refill(player: Player)
	local run = RunState.find(player)
	if run then
		run.fuel = Balance.fuelCapacity(run.upgrades)
	end
	warned[player] = nil
end

--[[
	Burns fuel for `seconds` of active cutting with `toolId`.

	Returns false when the tank is dry, which is the signal for TileService to
	refuse the cut entirely rather than let a player mow on fumes forever.
]]
function FuelService.consume(player: Player, toolId: string, seconds: number): boolean
	local tool = Tools.get(toolId)
	if not tool or tool.fuelBurn <= 0 then
		return true
	end
	if EconomyService.modifiers(player).infiniteFuel then
		return true
	end

	local run = RunState.find(player)
	if not run then
		return false
	end

	if run.fuel <= 0 then
		if not warned[player] then
			warned[player] = true
			EconomyService.notify(player, "stall", `{tool.name} is out of fuel — refill at the shed`, nil)
		end
		return false
	end

	run.fuel = math.max(run.fuel - tool.fuelBurn * seconds, 0)
	if run.fuel > 0 then
		warned[player] = nil
	end
	return true
end

function FuelService.start()
	Players.PlayerRemoving:Connect(function(player)
		warned[player] = nil
	end)

	-- Standing at the shed tops the tank up, so refuelling costs a walk rather
	-- than a menu.
		local WorldService = require(script.Parent.WorldService)
	Loop.forever("Fuel.shed", function()
		task.wait(0.25)
		local shed = WorldService.shedPart
		if shed then
			for _, player in Players:GetPlayers() do
				local character = player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				if root and root:IsA("BasePart") then
					local offset = root.Position - shed.Position
					if offset.X * offset.X + offset.Z * offset.Z <= REFUEL_RADIUS * REFUEL_RADIUS then
						local run = RunState.find(player)
						if run then
							local capacity = Balance.fuelCapacity(run.upgrades)
							if run.fuel < capacity then
								run.fuel = math.min(run.fuel + REFUEL_RATE * 0.25, capacity)
								warned[player] = nil
							end
						end
					end
				end
			end
		end
	end)
end

return FuelService
