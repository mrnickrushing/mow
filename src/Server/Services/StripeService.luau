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
local Stripe = require(Shared.Stripe)
local DataService = require(script.Parent.DataService)
local RunState = require(script.Parent.RunState)
local EconomyService = require(script.Parent.EconomyService)
local QuestService = require(script.Parent.QuestService)
local TileService = require(script.Parent.TileService)

local StripeService = {}

local stripes: { [Player]: Stripe.State } = {}

local function bank(player: Player, stripe: Stripe.State)
	local length = Stripe.length(stripe)
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

--- Records a cut tile against the player's current stripe.
local function onCut(player: Player, tileIndex: number)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end

	local look = root.CFrame.LookVector
	local heading = math.sqrt(look.X * look.X + look.Z * look.Z)
	if heading < 1e-3 then
		return
	end
	local dirX, dirZ = look.X / heading, look.Z / heading

	local atX, atZ = root.Position.X, root.Position.Z
	local now = os.clock()
	local existing: Stripe.State? = stripes[player]

	if existing and not Stripe.continues(existing, dirX, dirZ, now) then
		-- Turned past the drift, or stopped for a moment: bank what was there
		-- and start again from here.
		bank(player, existing)
		existing = nil
	end

	local stripe = existing or Stripe.new(dirX, dirZ, atX, atZ, now)
	stripes[player] = stripe

	Stripe.record(stripe, atX, atZ, tileIndex, now)
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
				if now - stripe.lastAt > Stripe.IDLE_TIMEOUT then
					bank(player, stripe)
					stripes[player] = nil
				end
			end
		end
	end)
end

return StripeService
