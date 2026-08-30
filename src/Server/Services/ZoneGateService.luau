--!strict
--[[
	ZoneGateService — the zones you earn instead of buy.

	Two kinds. A `completion` zone opens once the zone it sits above is finished,
	which is how the rooftop is reached: clear the front yard and the porch
	stairs open. A `button` zone opens by finding a switch hidden somewhere else
	on the map, which is how the garage is reached.

	Both exist so that some of the property is opened by playing rather than by
	paying. A map where every door has a price tag is a shop, not a place.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Properties = require(Shared.Config.Properties)
local Types = require(Shared.Types)
local Build = require(script.Parent.Parent.Lib.Build)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local ShopService = require(script.Parent.ShopService)
local WorldService = require(script.Parent.WorldService)

local ZoneGateService = {}

--- How often completion gates are re-checked, in seconds.
local CHECK_INTERVAL = 2

local container: Folder? = nil
local rng = Random.new()

--------------------------------------------------------------------
-- Buttons
--------------------------------------------------------------------

--[[
	Hides a switch for `zone` somewhere inside `zone.buttonIn`.

	Placed at a random spot each round, so a returning player has to look rather
	than walk straight to a memorised corner.
]]
local function placeButton(property: Types.PropertyDef, zone: Types.ZoneDef, parent: Instance)
	local hostId = zone.buttonIn
	if not hostId then
		return
	end
	local host = Properties.zone(property, hostId)
	if not host then
		return
	end

	local r = host.rect
	local tx = rng:NextInteger(r.x, r.x + r.w - 1)
	local tz = rng:NextInteger(r.z, r.z + r.d - 1)
	local at = WorldService.tilePointFlat(tx, tz) + Vector3.new(0, host.elevation or 0, 0)

	local post = Build.part({
		name = `Switch_{zone.id}`,
		size = Vector3.new(2.4, 5, 1.2),
		cframe = CFrame.new(at + Vector3.new(0, 2.5, 0)),
		color = Color3.fromRGB(70, 74, 78),
		material = Enum.Material.Metal,
		canCollide = false,
		parent = parent,
	})

	local button = Build.part({
		name = "Button",
		size = Vector3.new(1.6, 1.6, 0.6),
		cframe = CFrame.new(at + Vector3.new(0, 3.6, -0.7)),
		color = Color3.fromRGB(214, 60, 52),
		material = Enum.Material.Neon,
		canCollide = false,
		parent = post,
	})

	local gui = Build.billboard(post, UDim2.fromScale(7, 2.2), 5, 120)
	Build.label(gui, `Opens the {zone.name}`, UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), 1.1)

	local prompt = Build.prompt(button, "Press", `{zone.name} Switch`, 12)
	prompt.Triggered:Connect(function(player: Player)
		local granted = ShopService.grantZone(player, zone.id, `You found the switch — the {zone.name} is open`)
		if not granted then
			EconomyService.notify(player, "denied", `The {zone.name} is already open for you`, nil)
		end
	end)
end

--------------------------------------------------------------------
-- Completion gates
--------------------------------------------------------------------

--- True once a zone holds no debris at all.
local function isZoneClear(zoneId: string): boolean
	local state = WorldService.zones[zoneId]
	if not state then
		return false
	end
	return state.totalUnits <= 0 or state.remainingUnits <= 0
end

--[[
	Opens any completion-gated zone whose prerequisite is now clear.

	Granted per player rather than server-wide, so a player who joins after the
	front yard was finished still has to clear one themselves. Checked on a timer
	rather than driven from the cut signal, because a zone can also be finished
	by a Clean Sweep or another player.
]]
local function checkGates()
	local property = WorldService.property
	if not property then
		return
	end

	for _, zone in property.zones do
		if Properties.unlockKind(zone) == "completion" and zone.requires then
			if isZoneClear(zone.requires :: string) then
				local required = Properties.zone(property, zone.requires :: string)
				local requiredName = if required then required.name else zone.requires
				for _, player in Players:GetPlayers() do
					if DataService.get(player) then
						ShopService.grantZone(
							player,
							zone.id,
							`{requiredName} is clear — the {zone.name} is open`
						)
					end
				end
			end
		end
	end
end

--------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------

function ZoneGateService.generate(property: Types.PropertyDef)
	if container then
		container:Destroy()
	end
	local world = WorldService.container()
	if not world then
		return
	end
	container = Build.folder("ZoneGates", world)
	local parent = container :: Folder

	for _, zone in property.zones do
		if Properties.unlockKind(zone) == "button" then
			placeButton(property, zone, parent)
		end
	end
end

function ZoneGateService.start()
	WorldService.Loaded:Connect(ZoneGateService.generate)

	local property = WorldService.property
	if property then
		ZoneGateService.generate(property)
	end

	task.spawn(function()
		while true do
			task.wait(CHECK_INTERVAL)
			checkGates()
		end
	end)
end

return ZoneGateService
