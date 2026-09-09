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
local Monetization = require(Shared.Config.Monetization)
local Remotes = require(Shared.Remotes)
local BoostService = require(script.Parent.BoostService)
local Loop = require(Shared.Util.Loop)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)

local RewardService = {}

local rewards = Monetization.rewards
local SECONDS_PER_DAY = 86400

local rewardRemote: RemoteEvent

--- Seconds of play accumulated this session, per player.
local sessionPlaytime: { [Player]: number } = {}
local nextPlaytimeReward: { [Player]: number } = {}
local nextFreeRental: { [Player]: number } = {}

--[[
	Tell the client where the three free loops have got to.

	Sent on join and again each time one of them pays out, rather than on
	every five-second tick: the two numbers are countdowns, and a countdown
	the client can run itself needs a starting point and not a stream. A
	minute of drift on an eight-minute timer would be worth the traffic to
	avoid; a second of it is not.
]]
local function push(player: Player)
	if not rewardRemote then
		return
	end
	local profile = DataService.get(player)
	local elapsed = sessionPlaytime[player] or 0
	rewardRemote:FireClient(player, {
		streak = if profile then profile.dailyStreak else 0,
		streakOf = #rewards.dailyStreak,
		streakTips = rewards.dailyStreak[math.clamp(
			if profile then profile.dailyStreak else 1,
			1,
			#rewards.dailyStreak
		)],
		nextTips = math.max((nextPlaytimeReward[player] or rewards.playtimeInterval) - elapsed, 0),
		nextRental = math.max((nextFreeRental[player] or rewards.freeRentalInterval) - elapsed, 0),
	})
end

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

	local paid = false
	if elapsed >= (nextPlaytimeReward[player] or rewards.playtimeInterval) then
		nextPlaytimeReward[player] = elapsed + rewards.playtimeInterval
		EconomyService.awardTips(player, rewards.playtimeTips)
		EconomyService.notify(player, "reward", `Still going — {rewards.playtimeTips} tips`, nil)
		paid = true
	end

	if elapsed >= (nextFreeRental[player] or rewards.freeRentalInterval) then
		nextFreeRental[player] = elapsed + rewards.freeRentalInterval
		BoostService.grantRental(player, rewards.freeRentalToolId, rewards.freeRentalSeconds)
		paid = true
	end

	if paid then
		push(player)
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
	rewardRemote = Remotes.event(Remotes.REWARDS)

	DataService.ProfileLoaded:Connect(function(player: Player)
		claimDaily(player)
		sessionPlaytime[player] = 0
		nextPlaytimeReward[player] = rewards.playtimeInterval
		nextFreeRental[player] = rewards.freeRentalInterval
		push(player)
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
