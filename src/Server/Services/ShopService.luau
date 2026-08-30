--!strict
--[[
	ShopService — the tools and upgrades you buy during a run.

	Everything here is spent from run cash and lasts until the run ends. Sections
	are no longer sold: gates open by clearing what came before them, or by
	finding a switch, which is RunService's business rather than the shop's.

	The client sends only what it wants to buy — no price, no resulting level, no
	claim that it can afford it. Prices come from config and the deduction
	happens here, so a forged request buys nothing.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RateLimiter = require(Shared.Util.RateLimiter)
local Remotes = require(Shared.Remotes)
local Tools = require(Shared.Config.Tools)
local Upgrades = require(Shared.Config.Upgrades)
local EconomyService = require(script.Parent.EconomyService)
local PlayerService = require(script.Parent.PlayerService)
local QuestService = require(script.Parent.QuestService)
local RunState = require(script.Parent.RunState)
local WorldService = require(script.Parent.WorldService)

local ShopService = {}

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

--- Cost of the next level of an upgrade line, or nil when maxed or unknown.
function ShopService.upgradeCost(player: Player, upgradeId: string): number?
	local run = RunState.find(player)
	local def = Upgrades.get(upgradeId)
	if not run or not def then
		return nil
	end
	return Upgrades.costAt(def, run.upgrades[upgradeId] or 0)
end

--------------------------------------------------------------------
-- Purchases
--------------------------------------------------------------------

function ShopService.buyTool(player: Player, toolId: string): Result
	local run = RunState.find(player)
	if not run then
		return fail("The run has not started")
	end

	local tool = Tools.get(toolId)
	if not tool then
		return fail("No such tool")
	end
	if run.ownedTools[toolId] then
		return fail("You already have that")
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

	run.ownedTools[toolId] = true
	-- Equip it immediately: nobody buys a mower in order to keep holding shears.
	run.equippedTool = toolId

	QuestService.advance(player, "tool", 1, toolId)
	EconomyService.notify(player, "purchase", `Bought {tool.name}`, tool.cost)
	PlayerService.push(player)
	return OK
end

function ShopService.buyUpgrade(player: Player, upgradeId: string): Result
	local run = RunState.find(player)
	if not run then
		return fail("The run has not started")
	end

	local def = Upgrades.get(upgradeId)
	if not def then
		return fail("No such upgrade")
	end

	local level = run.upgrades[upgradeId] or 0
	local cost = Upgrades.costAt(def, level)
	if not cost then
		return fail("Already at maximum")
	end
	if not EconomyService.spend(player, cost) then
		return fail("Not enough cash")
	end

	run.upgrades[upgradeId] = level + 1

	-- Walk speed and bag capacity both come from upgrades, so the character and
	-- the client's numbers have to be refreshed the moment one is bought.
	PlayerService.applyCharacterStats(player)
	QuestService.advance(player, "upgrade", 1, upgradeId)
	EconomyService.notify(player, "purchase", `{def.name} level {level + 1}`, cost)
	PlayerService.push(player)
	return OK
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
	else
		return
	end

	if not result.ok and result.reason then
		EconomyService.notify(player, "denied", result.reason, nil)
	end
end

function ShopService.start()
	-- The upgrade stations in front of the shed are the same purchase with a
	-- walk attached: the world fires who pressed which board.
	WorldService.StationTried:Connect(function(player: Player, upgradeId: string)
		local result = ShopService.buyUpgrade(player, upgradeId)
		if not result.ok then
			EconomyService.notify(player, "denied", result.reason or "That did not work", nil)
		end
	end)

	local purchase = Remotes.event(Remotes.PURCHASE)
	purchase.OnServerEvent:Connect(onPurchase)

	Players.PlayerRemoving:Connect(function(player)
		limiters[player] = nil
	end)
end

return ShopService
