--!strict
--[[
	RewardService — the free counterweights to the Robux shop.

	Daily streaks, playtime cash and a free two-minute riding mower every half
	hour. These exist so progression never depends on spending: a player who buys
	nothing still gets a steady drip and the occasional taste of the good gear,
	which is also the most honest advertisement the rentals have.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Util.Format)
local Monetization = require(Shared.Config.Monetization)
local BoostService = require(script.Parent.BoostService)
local Loop = require(Shared.Util.Loop)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)

local RewardService = {}

local rewards = Monetization.rewards
local SECONDS_PER_DAY = 86400

--- Seconds of play accumulated this session, per player.
local sessionPlaytime: { [Player]: number } = {}
local nextPlaytimeReward: { [Player]: number } = {}
local nextFreeRental: { [Player]: number } = {}

--------------------------------------------------------------------
-- Daily streak
--------------------------------------------------------------------

local function claimDaily(player: Player)
	DataService.withProfile(player, function(profile)
		local now = os.time()
		local sinceLast = now - profile.dailyLastClaim

		if profile.dailyLastClaim > 0 and sinceLast < SECONDS_PER_DAY then
			return
		end

		-- A gap of more than two days breaks the streak; one day of slack means
		-- a player in a different timezone is not punished for playing "late".
		if profile.dailyLastClaim > 0 and sinceLast > SECONDS_PER_DAY * 2 then
			profile.dailyStreak = 0
		end

		profile.dailyStreak += 1
		profile.dailyLastClaim = now

		local table_ = rewards.dailyStreak
		local index = math.min(profile.dailyStreak, #table_)
		local amount = table_[index]

		EconomyService.awardTips(player, amount)
		EconomyService.notify(
			player,
			"reward",
			`Day {profile.dailyStreak} streak — {amount} tips`,
			nil
		)
	end)
end

--------------------------------------------------------------------
-- Playtime
--------------------------------------------------------------------

local function tick(player: Player, delta: number)
	local elapsed = (sessionPlaytime[player] or 0) + delta
	sessionPlaytime[player] = elapsed

	DataService.withProfile(player, function(profile)
		profile.playtime += delta
	end)

	if elapsed >= (nextPlaytimeReward[player] or rewards.playtimeInterval) then
		nextPlaytimeReward[player] = elapsed + rewards.playtimeInterval
		EconomyService.awardTips(player, rewards.playtimeTips)
		EconomyService.notify(player, "reward", `Still going — {rewards.playtimeTips} tips`, nil)
	end

	if elapsed >= (nextFreeRental[player] or rewards.freeRentalInterval) then
		nextFreeRental[player] = elapsed + rewards.freeRentalInterval
		BoostService.grantRental(player, rewards.freeRentalToolId, rewards.freeRentalSeconds)
	end
end

--------------------------------------------------------------------
-- Completion
--------------------------------------------------------------------

--- Paid the first time a player is on a server that reaches 100%.
function RewardService.awardFirstCompletion(player: Player)
	DataService.withProfile(player, function(profile)
		if profile.firstCompletionClaimed then
			return
		end
		profile.firstCompletionClaimed = true
		EconomyService.awardTips(player, rewards.firstCompletionTips)
		EconomyService.notify(
			player,
			"reward",
			`First clean sweep of a property — {rewards.firstCompletionTips} tips`,
			nil
		)
	end)
end

function RewardService.start()
	DataService.ProfileLoaded:Connect(function(player: Player)
		claimDaily(player)
		sessionPlaytime[player] = 0
		nextPlaytimeReward[player] = rewards.playtimeInterval
		nextFreeRental[player] = rewards.freeRentalInterval
	end)

	Players.PlayerRemoving:Connect(function(player)
		sessionPlaytime[player] = nil
		nextPlaytimeReward[player] = nil
		nextFreeRental[player] = nil
	end)

		local step = 5
	Loop.forever("Reward.playtime", function()
		task.wait(step)
		for _, player in Players:GetPlayers() do
			if DataService.get(player) then
				tick(player, step)
			end
		end
	end)

	-- Group members get a small permanent edge that costs nothing to have.
	if rewards.groupId ~= 0 then
		EconomyService.addModifierSource(function(player: Player)
			local ok, inGroup = pcall(function()
				return player:IsInGroup(rewards.groupId)
			end)
			if ok and inGroup then
				return { cashBoost = rewards.groupBonusMultiplier }
			end
			return {}
		end)
	end
end

return RewardService
