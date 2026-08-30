--!strict
--[[
	EconomyService — the only place cash and tips change hands.

	Every award and every spend goes through here so that multipliers are applied
	once, lifetime earnings stay accurate for property unlocks, and the client is
	told about the change without each caller remembering to push state.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Types = require(Shared.Types)
local Remotes = require(Shared.Remotes)
local RunState = require(script.Parent.RunState)

local EconomyService = {}

local notify: RemoteEvent

--- Set by MonetizationService and BoostService; read when building modifiers.
export type ModifierSource = (Player) -> Balance.Modifiers
local modifierSources: { ModifierSource } = {}

--- Registers a source of multipliers (passes, boosts, server events).
function EconomyService.addModifierSource(source: ModifierSource)
	table.insert(modifierSources, source)
end

--- The merged modifier set for a player, from every registered source.
function EconomyService.modifiers(player: Player): Balance.Modifiers
	local merged: Balance.Modifiers = {}
	for _, source in modifierSources do
		local mods = source(player)
		merged.doubleCash = merged.doubleCash or mods.doubleCash
		merged.doubleBag = merged.doubleBag or mods.doubleBag
		merged.fastFeet = merged.fastFeet or mods.fastFeet
		merged.infiniteFuel = merged.infiniteFuel or mods.infiniteFuel
		merged.vip = merged.vip or mods.vip
		-- Timed boosts multiply rather than override, so two stack.
		merged.cashBoost = (merged.cashBoost or 1) * (mods.cashBoost or 1)
		merged.serverBoost = (merged.serverBoost or 1) * (mods.serverBoost or 1)
		merged.sectionBoost = (merged.sectionBoost or 0) + (mods.sectionBoost or 0)
	end
	return merged
end

function EconomyService.stats(player: Player): Types.PlayerStats?
	local run = RunState.find(player)
	if not run then
		return nil
	end
	return Balance.stats(run.upgrades, run.equippedTool, EconomyService.modifiers(player))
end

--------------------------------------------------------------------
-- Cash
--------------------------------------------------------------------

--- Awards cash that has ALREADY had multipliers applied.
function EconomyService.awardRaw(player: Player, amount: number): number
	if amount <= 0 then
		return 0
	end
	local run = RunState.find(player)
	if not run then
		return 0
	end
	run.cash += amount
	run.earned += amount
	return amount
end

--- Applies the player's multiplier stack, then awards the result.
function EconomyService.award(player: Player, baseAmount: number): number
	local run = RunState.find(player)
	if not run or baseAmount <= 0 then
		return 0
	end
	local multiplier = Balance.cashMultiplier(run.upgrades, EconomyService.modifiers(player))
	return EconomyService.awardRaw(player, baseAmount * multiplier)
end

--- Deducts `amount` if the player can afford it.
function EconomyService.spend(player: Player, amount: number): boolean
	local run = RunState.find(player)
	if not run or amount < 0 or run.cash < amount then
		return false
	end
	run.cash -= amount
	return true
end

function EconomyService.canAfford(player: Player, amount: number): boolean
	local run = RunState.find(player)
	return run ~= nil and run.cash >= amount
end

--------------------------------------------------------------------
-- Tips
--------------------------------------------------------------------

function EconomyService.awardTips(player: Player, amount: number)
	local run = RunState.find(player)
	if run and amount > 0 then
		run.tips += amount
	end
end

function EconomyService.spendTips(player: Player, amount: number): boolean
	local run = RunState.find(player)
	if not run or amount < 0 or run.tips < amount then
		return false
	end
	run.tips -= amount
	return true
end

--------------------------------------------------------------------
-- Feedback
--------------------------------------------------------------------

--- Sends a transient message to one player's HUD.
function EconomyService.notify(player: Player, kind: string, message: string, value: number?)
	if notify then
		notify:FireClient(player, kind, message, value)
	end
end

function EconomyService.notifyAll(kind: string, message: string, value: number?)
	if not notify then
		return
	end
	for _, player in Players:GetPlayers() do
		notify:FireClient(player, kind, message, value)
	end
end

function EconomyService.start()
	notify = Remotes.event(Remotes.NOTIFY)
end

return EconomyService
