--!strict
--[[
	StripeService — the Clean Stripe bonus.

	Cutting in long straight parallel lines is how a lawn actually gets striped,
	and it is the one place in a genre with almost no skill expression where
	doing it properly pays. Hold a heading, keep cutting, and a completed run
	banks cash and a tip.

	A stripe breaks when the player turns past STRIPE_MAX_DRIFT or stops cutting,
	which is what makes wandering aimlessly cost something without ever punishing
	it outright.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Format = require(Shared.Util.Format)
local GameConfig = require(Shared.Config.GameConfig)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local QuestService = require(script.Parent.QuestService)
local TileService = require(script.Parent.TileService)

local StripeService = {}

export type Run = {
	--- Heading of the run, as a unit vector in tile space.
	dirX: number,
	dirZ: number,
	tiles: number,
	--- Tiles already counted, so a wide deck does not inflate the run.
	seen: { [number]: boolean },
	lastAt: number,
}

local runs: { [Player]: Run } = {}

--- A stripe lapses if no cutting happens for this long.
local IDLE_TIMEOUT = 1.2
local MAX_DRIFT_COS = math.cos(math.rad(GameConfig.STRIPE_MAX_DRIFT))

local function bank(player: Player, run: Run)
	if run.tiles < GameConfig.STRIPE_MIN_TILES then
		return
	end

	local profile = DataService.get(player)
	if not profile then
		return
	end

	local bonus = Balance.stripeBonus(run.tiles, profile.upgrades, EconomyService.modifiers(player))
	EconomyService.awardRaw(player, bonus)
	EconomyService.awardTips(player, GameConfig.STRIPE_TIP_REWARD)

	DataService.withProfile(player, function(p)
		p.stats.stripes += 1
	end)

	QuestService.advance(player, "stripe", 1)
	EconomyService.notify(player, "stripe", `Clean stripe — {run.tiles} tiles, {Format.cash(bonus)}`, bonus)
end

local function reset(player: Player, dirX: number, dirZ: number)
	runs[player] = { dirX = dirX, dirZ = dirZ, tiles = 0, seen = {}, lastAt = os.clock() }
end

--- Records a cut tile against the player's current run.
local function onCut(player: Player, tileIndex: number)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end

	local look = root.CFrame.LookVector
	local length = math.sqrt(look.X * look.X + look.Z * look.Z)
	if length < 1e-3 then
		return
	end
	local dirX, dirZ = look.X / length, look.Z / length

	local run = runs[player]
	local now = os.clock()

	if not run then
		reset(player, dirX, dirZ)
		run = runs[player]
	elseif now - run.lastAt > IDLE_TIMEOUT then
		-- Stopped cutting for a moment: bank whatever was there and start over.
		bank(player, run)
		reset(player, dirX, dirZ)
		run = runs[player]
	else
		local alignment = run.dirX * dirX + run.dirZ * dirZ
		if alignment < MAX_DRIFT_COS then
			bank(player, run)
			reset(player, dirX, dirZ)
			run = runs[player]
		end
	end

	local current = run :: Run
	current.lastAt = now

	-- Count each tile once, so a wide deck does not multiply the run length.
	if not current.seen[tileIndex] then
		current.seen[tileIndex] = true
		current.tiles += 1
	end
end

function StripeService.start()
	TileService.Cut:Connect(function(player: Player, tileIndex: number)
		onCut(player, tileIndex)
	end)

	Players.PlayerRemoving:Connect(function(player)
		runs[player] = nil
	end)

	-- Bank runs that simply stop, rather than only ones that end in a turn.
	task.spawn(function()
		while true do
			task.wait(0.5)
			local now = os.clock()
			for player, run in runs do
				if now - run.lastAt > IDLE_TIMEOUT then
					bank(player, run)
					runs[player] = nil
				end
			end
		end
	end)
end

return StripeService
