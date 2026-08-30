--!strict
--[[
	ShopService — every purchase the player can make with in-game currency.

	Tools, upgrade levels and zone unlocks all funnel through one validated
	entry point. The client sends what it wants to buy and nothing else: no
	price, no resulting level, no "I can afford this". Prices come from config
	and the deduction happens here, so a forged request buys nothing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Util.Format)
local Properties = require(Shared.Config.Properties)
local RateLimiter = require(Shared.Util.RateLimiter)
local Remotes = require(Shared.Remotes)
local Tools = require(Shared.Config.Tools)
local Types = require(Shared.Types)
local Upgrades = require(Shared.Config.Upgrades)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local PlayerService = require(script.Parent.PlayerService)
local QuestService = require(script.Parent.QuestService)
local WorldService = require(script.Parent.WorldService)

local ShopService = {}

local Players = game:GetService("Players")
local limiters: { [Player]: RateLimiter.RateLimiter } = {}

--- Purchases are deliberate actions; a few per second is generous.
local PURCHASE_HZ = 6

export type Result = {
	ok: boolean,
	reason: string?,
}

local function fail(reason: string): Result
	return { ok = false, reason = reason }
end

local OK: Result = { ok = true }

local function limiterFor(player: Player): RateLimiter.RateLimiter
	local limiter = limiters[player]
	if not limiter then
		limiter = RateLimiter.new(PURCHASE_HZ, PURCHASE_HZ)
		limiters[player] = limiter
	end
	return limiter
end

--------------------------------------------------------------------
-- Prices
--------------------------------------------------------------------

--- Cost of the next level of an upgrade line, or nil when maxed or unknown.
function ShopService.upgradeCost(player: Player, upgradeId: string): number?
	local profile = DataService.get(player)
	local def = Upgrades.get(upgradeId)
	if not profile or not def then
		return nil
	end
	return Upgrades.costAt(def, profile.upgrades[upgradeId] or 0)
end

--- Cost of a zone on the property currently loaded.
function ShopService.zoneCost(zoneId: string): number?
	local property = WorldService.property
	if not property then
		return nil
	end
	local zone = Properties.zone(property, zoneId)
	return if zone then zone.cost else nil
end

--------------------------------------------------------------------
-- Purchases
--------------------------------------------------------------------

function ShopService.buyTool(player: Player, toolId: string): Result
	local profile = DataService.get(player)
	if not profile then
		return fail("Still loading your save")
	end

	local tool = Tools.get(toolId)
	if not tool then
		return fail("No such tool")
	end
	if profile.ownedTools[toolId] then
		return fail("You already own that")
	end

	if tool.currency == "Tips" then
		if not EconomyService.spendTips(player, tool.cost) then
			return fail("Not enough tips")
		end
	else
		if not EconomyService.spend(player, tool.cost) then
			return fail("Not enough cash")
		end
	end

	profile.ownedTools[toolId] = true
	-- Equip it immediately: nobody buys a mower in order to keep holding shears.
	profile.equippedTool = toolId
	QuestService.advance(player, "tool", 1, toolId)

	EconomyService.notify(player, "purchase", `Bought {tool.name}`, tool.cost)
	PlayerService.push(player)
	return OK
end

function ShopService.buyUpgrade(player: Player, upgradeId: string): Result
	local profile = DataService.get(player)
	if not profile then
		return fail("Still loading your save")
	end

	local def = Upgrades.get(upgradeId)
	if not def then
		return fail("No such upgrade")
	end

	local level = profile.upgrades[upgradeId] or 0
	local cost = Upgrades.costAt(def, level)
	if not cost then
		return fail("Already at maximum")
	end
	if not EconomyService.spend(player, cost) then
		return fail("Not enough cash")
	end

	profile.upgrades[upgradeId] = level + 1
	QuestService.advance(player, "upgrade", 1, upgradeId)

	-- Walk speed and bag capacity both come from upgrades, so the character and
	-- the client's numbers have to be refreshed the moment one is bought.
	PlayerService.applyCharacterStats(player)
	EconomyService.notify(player, "purchase", `{def.name} level {level + 1}`, cost)
	PlayerService.push(player)
	return OK
end

function ShopService.buyZone(player: Player, zoneId: string): Result
	local profile = DataService.get(player)
	local property = WorldService.property
	if not profile or not property then
		return fail("Still loading")
	end

	local zone: Types.ZoneDef? = Properties.zone(property, zoneId)
	if not zone then
		return fail("No such zone")
	end

	local owned = profile.unlockedZones[property.id]
	if not owned then
		owned = {}
		profile.unlockedZones[property.id] = owned
	end
	if owned[zoneId] then
		return fail("You already own that zone")
	end

	-- Earned zones are not for sale. Without this, the shop would happily sell
	-- the rooftop for nothing and skip the front yard it is meant to reward.
	local kind = Properties.unlockKind(zone :: Types.ZoneDef)
	if kind ~= "cash" then
		return fail(
			if kind == "completion"
				then "Finish the zone this one sits above first"
				else "This one opens some other way — go and find it"
		)
	end

	local cost = (zone :: Types.ZoneDef).cost
	if cost > 0 and not EconomyService.spend(player, cost) then
		return fail("Not enough cash")
	end

	owned[zoneId] = true
	QuestService.advance(player, "zone", 1, zoneId)
	EconomyService.notify(player, "purchase", `Unlocked {(zone :: Types.ZoneDef).name}`, cost)
	PlayerService.push(player)
	return OK
end

--[[
	Grants a zone without charging for it.

	Used by the completion gate and the hidden button. Returns false when the
	player already had it, so callers can stay quiet rather than announcing the
	same unlock every time a condition is re-checked.
]]
function ShopService.grantZone(player: Player, zoneId: string, message: string): boolean
	local profile = DataService.get(player)
	local property = WorldService.property
	if not profile or not property then
		return false
	end

	local zone = Properties.zone(property, zoneId)
	if not zone then
		return false
	end

	local owned = profile.unlockedZones[property.id]
	if not owned then
		owned = {}
		profile.unlockedZones[property.id] = owned
	end
	if owned[zoneId] then
		return false
	end

	owned[zoneId] = true
	QuestService.advance(player, "zone", 1, zoneId)
	EconomyService.notify(player, "reward", message, nil)
	PlayerService.push(player)
	return true
end

--------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------

local function onPurchase(player: Player, kind: any, id: any)
	if type(kind) ~= "string" or type(id) ~= "string" then
		return
	end
	if not limiterFor(player):tryConsume() then
		return
	end

	local result: Result
	if kind == "tool" then
		result = ShopService.buyTool(player, id)
	elseif kind == "upgrade" then
		result = ShopService.buyUpgrade(player, id)
	elseif kind == "zone" then
		result = ShopService.buyZone(player, id)
	else
		return
	end

	if not result.ok and result.reason then
		EconomyService.notify(player, "denied", result.reason, nil)
	end
end

--- Adds a prompt to each zone sign so a zone can be bought where it is,
--- not only at the shed.
local function attachZonePrompts()
	local property = WorldService.property
	if not property then
		return
	end

	for zoneId, post in WorldService.zoneSigns do
		local zone = Properties.zone(property, zoneId)
		if zone and Properties.unlockKind(zone) == "cash" then
			local prompt = Instance.new("ProximityPrompt")
			prompt.ActionText = `Unlock {Format.cash(zone.cost)}`
			prompt.ObjectText = zone.name
			prompt.MaxActivationDistance = 18
			prompt.HoldDuration = 0.35
			prompt.RequiresLineOfSight = false
			prompt.Parent = post

			prompt.Triggered:Connect(function(player)
				local result = ShopService.buyZone(player, zoneId)
				if not result.ok and result.reason then
					EconomyService.notify(player, "denied", result.reason, nil)
				end
			end)
		end
	end
end

function ShopService.start()
	local purchase = Remotes.event(Remotes.PURCHASE)
	purchase.OnServerEvent:Connect(onPurchase)

	Players.PlayerRemoving:Connect(function(player)
		limiters[player] = nil
	end)

	if WorldService.isLoaded() then
		attachZonePrompts()
	end
	WorldService.Loaded:Connect(attachZonePrompts)
end

return ShopService
