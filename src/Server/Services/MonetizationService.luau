--!strict
--[[
	MonetizationService — gamepasses and developer products.

	Every id lives in Shared/Config/Monetization as a placeholder. Until a real
	id is pasted in, this service treats the entry as unconfigured and skips it
	entirely, so the game runs and can be played start to finish with nothing
	set up. See docs/MONETIZATION.md.

	Gamepass ownership is cached per session because MarketplaceService calls are
	network round trips and the multiplier stack asks several times a second.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Monetization = require(Shared.Config.Monetization)
local Remotes = require(Shared.Remotes)
local Tools = require(Shared.Config.Tools)
local BagService = require(script.Parent.BagService)
local BoostService = require(script.Parent.BoostService)
local DataService = require(script.Parent.DataService)
local DefaultData = require(script.Parent.Parent.Lib.DefaultData)
local EconomyService = require(script.Parent.EconomyService)
local FuelService = require(script.Parent.FuelService)
local PlayerService = require(script.Parent.PlayerService)
local RunService = require(script.Parent.RunService)
local RunState = require(script.Parent.RunState)
local SweepService = require(script.Parent.SweepService)

local MonetizationService = {}

--- passKey -> owned, per player. Rebuilt on join and on a fresh purchase.
local owned: { [Player]: { [string]: boolean } } = {}

local function ownedTable(player: Player): { [string]: boolean }
	local table_ = owned[player]
	if not table_ then
		table_ = {}
		owned[player] = table_
	end
	return table_
end

function MonetizationService.owns(player: Player, passKey: string): boolean
	return ownedTable(player)[passKey] == true
end

--- Asks Roblox about one pass and caches the answer.
local function refreshPass(player: Player, key: string)
	local def = Monetization.passByKey[key]
	if not def or not Monetization.isConfigured(def.id) then
		return
	end
	local ok, result = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, def.id)
	end)
	if ok then
		ownedTable(player)[key] = result == true
	end
end

local function refreshAllPasses(player: Player)
	for _, def in Monetization.passes do
		refreshPass(player, def.key)
	end
end

--------------------------------------------------------------------
-- Products
--------------------------------------------------------------------

--- Applies a product's effect. Returns false to leave the receipt unprocessed
--- so Roblox retries later rather than the player losing what they paid for.
--[[
	Unlocks a tool bought with Robux.

	`toolRun` puts it in the player's hands for the run in progress; the receipt
	is still honoured if the run has already ended, because the tool then comes
	back on the next fresh loadout the moment it is recorded — which only the
	permanent kind does. A run unlock bought as the timer runs out is the one
	case a player can lose value, so it is the run state that is written first
	and the tool equipped immediately, leaving no window where the purchase went
	through and nothing happened.
]]
local function grantTool(player: Player, def: Monetization.ProductDef): boolean
	local toolId = def.toolId
	local tool = if toolId then Tools.get(toolId) else nil
	if not toolId or not tool then
		return false
	end

	if def.kind == "toolPermanent" then
		DataService.withProfile(player, function(profile)
			profile.permanentTools[toolId] = true
		end)
	end

	local run = RunState.find(player)
	if run then
		run.ownedTools[toolId] = true
		run.equippedTool = toolId
	end

	EconomyService.notify(
		player,
		"reward",
		if def.kind == "toolPermanent"
			then `{tool.name} unlocked for good`
			else `{tool.name} unlocked for this run`,
		nil
	)
	return true
end

local function grantProduct(player: Player, key: string): boolean
	local def = Monetization.productByKey[key]
	if not def then
		return false
	end

	-- A profile that has not loaded cannot be credited safely; refusing the
	-- receipt makes Roblox retry rather than silently eating the purchase.
	if not DataService.get(player) then
		return false
	end

	if def.kind == "rental" then
		BoostService.grantRental(player, def.toolId :: string, def.seconds :: number)
	elseif def.kind == "cashBoost" then
		BoostService.grantCashBoost(player, def.multiplier :: number, def.seconds :: number)
	elseif def.kind == "serverBoost" then
		BoostService.grantServerBoost(player, def.multiplier :: number, def.seconds :: number)
	elseif def.kind == "fuel" then
		FuelService.refill(player)
		EconomyService.notify(player, "reward", "Tank filled", nil)
	elseif def.kind == "bag" then
		BagService.dump(player)
	elseif def.kind == "sweep" then
		SweepService.sweep(player, def.fraction or 0.05)
	elseif def.kind == "roundTime" then
		RunService.extend(def.seconds or 600)
		EconomyService.notifyAll("reward", `{player.DisplayName} added time to the round`, nil)
	elseif def.kind == "toolRun" or def.kind == "toolPermanent" then
		if not grantTool(player, def) then
			return false
		end
	else
		return false
	end

	PlayerService.push(player)
	return true
end

MonetizationService.grantProduct = grantProduct

--------------------------------------------------------------------
-- Prompting
--------------------------------------------------------------------

local function onPromptPurchase(player: Player, kind: any, key: any)
	if type(kind) ~= "string" or type(key) ~= "string" then
		return
	end

	if kind == "pass" then
		local def = Monetization.passByKey[key]
		if def and Monetization.isConfigured(def.id) then
			MarketplaceService:PromptGamePassPurchase(player, def.id)
		else
			EconomyService.notify(player, "denied", "That is not available yet", nil)
		end
	elseif kind == "product" then
		local def = Monetization.productByKey[key]
		if def and Monetization.isConfigured(def.id) then
			MarketplaceService:PromptProductPurchase(player, def.id)
		else
			EconomyService.notify(player, "denied", "That is not available yet", nil)
		end
	end
end

--------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------

function MonetizationService.start()
	local prompt = Remotes.event(Remotes.PROMPT_PURCHASE)
	prompt.OnServerEvent:Connect(onPromptPurchase)

	Players.PlayerRemoving:Connect(function(player)
		owned[player] = nil
	end)

	for _, player in Players:GetPlayers() do
		task.spawn(refreshAllPasses, player)
	end
	Players.PlayerAdded:Connect(function(player)
		task.spawn(refreshAllPasses, player)
	end)

	-- A pass bought mid-session has to take effect without a rejoin.
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, wasPurchased)
		if not wasPurchased then
			return
		end
		local def = Monetization.passById[passId]
		if def then
			ownedTable(player)[def.key] = true
			PlayerService.applyCharacterStats(player)
			PlayerService.push(player)
			EconomyService.notify(player, "reward", `{def.name} unlocked`, nil)
		end
	end)

	--[[
		Turning Robux into goods, exactly once.

		Roblox retries `ProcessReceipt` until it is told the purchase was
		granted. That is the right behaviour — it is how a purchase survives a
		server dying mid-grant — but it means the same receipt arrives more than
		once, and granting on each arrival hands out a second lot of goods for
		one payment.

		So every receipt id a player has been paid for is remembered on their
		profile, checked before granting and recorded after. A repeat is
		answered `PurchaseGranted` without granting anything: from Roblox's side
		the purchase is settled, which is true, and it stops asking.

		A profile that has not loaded is refused rather than granted. It cannot
		be credited safely and it cannot remember the receipt either, so the
		only safe answer is to let Roblox ask again.
	]]
	MarketplaceService.ProcessReceipt = function(receipt)
		local player = Players:GetPlayerByUserId(receipt.PlayerId)
		if not player then
			-- They left before it landed. Not granted, so do not consume it.
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local def = Monetization.productById[receipt.ProductId]
		if not def then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local profile = DataService.get(player)
		if not profile then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local receiptId = tostring(receipt.PurchaseId)
		for _, seen in profile.receipts do
			if seen == receiptId then
				-- Already paid for. Settled, so Roblox can stop asking.
				return Enum.ProductPurchaseDecision.PurchaseGranted
			end
		end

		local ok, granted = pcall(grantProduct, player, def.key)
		if not (ok and granted) then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		--[[
			Recorded after the grant, not before.

			If the server dies between the two, the receipt is unrecorded and
			Roblox asks again, which pays the player twice for one purchase.
			Recording first would instead risk swallowing a purchase that never
			landed, and a player who paid and got nothing is the worse failure
			of the two by a distance.
		]]
		table.insert(profile.receipts, receiptId)
		while #profile.receipts > DefaultData.RECEIPT_MEMORY do
			table.remove(profile.receipts, 1)
		end
		DataService.save(player)

		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	-- Passes reach the rest of the game through the multiplier stack, so nothing
	-- else needs to know MarketplaceService exists.
	EconomyService.addModifierSource(function(player: Player): Balance.Modifiers
		local table_ = ownedTable(player)
		return {
			doubleCash = table_.doubleCash,
			doubleBag = table_.doubleBag,
			fastFeet = table_.fastFeet,
			infiniteFuel = table_.infiniteFuel,
			instantDump = table_.instantDump,
			vip = table_.vip,
		}
	end)
end

return MonetizationService
