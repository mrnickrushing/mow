--!strict
--[[
	StripeService — the Clean Stripe bonus.

	Cutting in long straight parallel lines is how a lawn actually gets striped,
	and it is the one place in a genre with almost no skill expression where
	doing it properly pays. Hold a heading, keep cutting, and a completed stripe
	banks cash and a tip.

	A stripe breaks when the player turns past STRIPE_MAX_DRIFT or stops cutting,
	which is what makes wandering aimlessly cost something without ever punishing
	it outright.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local DebrisConfig = require(Shared.Config.Debris)
local Format = require(Shared.Util.Format)
local GameConfig = require(Shared.Config.GameConfig)
local DataService = require(script.Parent.DataService)
local RunState = require(script.Parent.RunState)
local EconomyService = require(script.Parent.EconomyService)
local QuestService = require(script.Parent.QuestService)
local TileService = require(script.Parent.TileService)

local StripeService = {}

export type Stripe = {
	--- Heading of the stripe, as a unit vector in tile space.
	dirX: number,
	dirZ: number,
	tiles: number,
	--- Tiles already counted, so a wide deck does not inflate the stripe.
	seen: { [number]: boolean },
	lastAt: number,
}

local stripes: { [Player]: Stripe } = {}

--- A stripe lapses if no cutting happens for this long.
local IDLE_TIMEOUT = 1.2
local MAX_DRIFT_COS = math.cos(math.rad(GameConfig.STRIPE_MAX_DRIFT))

local function bank(player: Player, stripe: Stripe)
	if stripe.tiles < GameConfig.STRIPE_MIN_TILES then
		return
	end

	local run = RunState.find(player)
	if not run then
		return
	end

	local bonus = Balance.stripeBonus(stripe.tiles, run.upgrades, EconomyService.modifiers(player))
	EconomyService.awardRaw(player, bonus)
	EconomyService.awardTips(player, GameConfig.STRIPE_TIP_REWARD)

	DataService.withProfile(player, function(p)
		p.stats.stripes += 1
	end)

	QuestService.advance(player, "stripe", 1)
	EconomyService.notify(player, "stripe", `Clean stripe — {stripe.tiles} tiles, {Format.cash(bonus)}`, bonus)
end

local function reset(player: Player, dirX: number, dirZ: number)
	stripes[player] = { dirX = dirX, dirZ = dirZ, tiles = 0, seen = {}, lastAt = os.clock() }
end

--- Records a cut tile against the player's current stripe.
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

	local stripe = stripes[player]
	local now = os.clock()

	if not stripe then
		reset(player, dirX, dirZ)
		stripe = stripes[player]
	elseif now - stripe.lastAt > IDLE_TIMEOUT then
		-- Stopped cutting for a moment: bank whatever was there and start over.
		bank(player, stripe)
		reset(player, dirX, dirZ)
		stripe = stripes[player]
	else
		local alignment = stripe.dirX * dirX + stripe.dirZ * dirZ
		if alignment < MAX_DRIFT_COS then
			bank(player, stripe)
			reset(player, dirX, dirZ)
			stripe = stripes[player]
		end
	end

	local current = stripe :: Stripe
	current.lastAt = now

	-- Count each tile once, so a wide deck does not multiply the stripe length.
	if not current.seen[tileIndex] then
		current.seen[tileIndex] = true
		current.tiles += 1
	end
end

function StripeService.start()
	--[[
		A stripe is a mown stripe.

		The bonus counted any tile cut in a straight line, so raking a tidy
		row of leaves striped just as well as mowing did — which made the
		one piece of skill in the game say nothing about mowing. Stripes are
		cut in grass; everything else is tidying up.
	]]
	TileService.Cut:Connect(function(player: Player, tileIndex: number, debrisId: number)
		if debrisId ~= DebrisConfig.Grass then
			return
		end
		onCut(player, tileIndex)
	end)

	Players.PlayerRemoving:Connect(function(player)
		stripes[player] = nil
	end)

	-- Bank runs that simply stop, rather than only ones that end in a turn.
	task.spawn(function()
		while true do
			task.wait(0.5)
			local now = os.clock()
			for player, stripe in stripes do
				if now - stripe.lastAt > IDLE_TIMEOUT then
					bank(player, stripe)
					stripes[player] = nil
				end
			end
		end
	end)
end

return StripeService
