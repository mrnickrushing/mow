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
	--- Distinct tiles cut on this stripe. Proof that work happened; not the
	--- stripe's length, which is `along`.
	tiles: number,
	seen: { [number]: boolean },
	--- Where the stripe began, and the furthest the player has since got along
	--- its heading, in studs.
	startX: number,
	startZ: number,
	along: number,
	lastAt: number,
}

--[[
	How long the stripe is, in tiles.

	This used to be the count of distinct tiles cut, guarded by a comment
	saying that counting each tile once stopped a wide deck inflating the
	stripe. It does not: a deck eleven tiles across cuts eleven *distinct*
	tiles abreast, so every one of them counted, and the length of a stripe
	became the area the mower covered. A Gas Push Mower — the third rung of
	the ladder, sixty dollars — met the six-tile minimum inside a single cut
	tick, which is to say the one mechanic in the game that rewards holding a
	line stopped asking you to hold one at all the moment you bought it, and
	paid the widest tools a second time for ground the clippings had already
	paid them for.

	A stripe is a distance. This is how far the player has driven along the
	heading they started on, which is the same number for every tool.
]]
local function lengthOf(stripe: Stripe): number
	if stripe.tiles <= 0 then
		return 0
	end
	return math.floor(stripe.along / GameConfig.TILE_SIZE) + 1
end

local stripes: { [Player]: Stripe } = {}

--- A stripe lapses if no cutting happens for this long.
local IDLE_TIMEOUT = 1.2
local MAX_DRIFT_COS = math.cos(math.rad(GameConfig.STRIPE_MAX_DRIFT))

local function bank(player: Player, stripe: Stripe)
	local length = lengthOf(stripe)
	if length < GameConfig.STRIPE_MIN_TILES then
		return
	end

	local run = RunState.find(player)
	if not run then
		return
	end

	local bonus = Balance.stripeBonus(length, run.upgrades, EconomyService.modifiers(player))
	EconomyService.awardRaw(player, bonus)
	EconomyService.awardTips(player, GameConfig.STRIPE_TIP_REWARD)

	DataService.withProfile(player, function(p)
		p.stats.stripes += 1
	end)

	QuestService.advance(player, "stripe", 1)
	EconomyService.notify(player, "stripe", `Clean stripe — {length} tiles, {Format.cash(bonus)}`, bonus)
end

local function reset(player: Player, dirX: number, dirZ: number, atX: number, atZ: number)
	stripes[player] = {
		dirX = dirX,
		dirZ = dirZ,
		tiles = 0,
		seen = {},
		startX = atX,
		startZ = atZ,
		along = 0,
		lastAt = os.clock(),
	}
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

	local atX, atZ = root.Position.X, root.Position.Z
	local stripe = stripes[player]
	local now = os.clock()

	if not stripe then
		reset(player, dirX, dirZ, atX, atZ)
		stripe = stripes[player]
	elseif now - stripe.lastAt > IDLE_TIMEOUT then
		-- Stopped cutting for a moment: bank whatever was there and start over.
		bank(player, stripe)
		reset(player, dirX, dirZ, atX, atZ)
		stripe = stripes[player]
	else
		local alignment = stripe.dirX * dirX + stripe.dirZ * dirZ
		if alignment < MAX_DRIFT_COS then
			bank(player, stripe)
			reset(player, dirX, dirZ, atX, atZ)
			stripe = stripes[player]
		end
	end

	local current = stripe :: Stripe
	current.lastAt = now

	-- How far along the heading the player has got since the stripe began.
	-- Kept as a maximum, so backing up does not shorten a stripe already cut.
	local along = (atX - current.startX) * current.dirX + (atZ - current.startZ) * current.dirZ
	current.along = math.max(current.along, along)

	-- Each tile once, so standing still on one cannot pass for work done.
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
