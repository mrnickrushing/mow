--!strict
--[[
	AutoCollectService — the Auto-Collect gamepass.

	Cut debris already goes straight into the bag, so a magnet for clippings
	would do nothing. What actually litters a property is everything you had to
	leave behind: log piles dropped when your bag filled at a tree, and Golden
	Blades you walked past without noticing. This picks both up as you move.

	Owners only. Everyone else keeps using the prompts.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local BagService = require(script.Parent.BagService)
local Loop = require(script.Parent.Parent.Lib.Loop)
local CollectibleService = require(script.Parent.CollectibleService)
local MonetizationService = require(script.Parent.MonetizationService)

local AutoCollectService = {}

--- Studs within which things come to you.
local RADIUS = 26
local RADIUS_SQ = RADIUS * RADIUS
--- Scan interval. Fast enough to feel like a magnet, slow enough to be free.
local INTERVAL = 0.4

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function sweepFor(player: Player, at: Vector3)
	for _, instance in CollectionService:GetTagged("MowPile") do
		if instance:IsA("BasePart") and instance.Parent then
			local offset = instance.Position - at
			if offset.X * offset.X + offset.Z * offset.Z <= RADIUS_SQ then
				local units = instance:GetAttribute("Units")
				local debrisId = instance:GetAttribute("DebrisId")
				if type(units) == "number" and type(debrisId) == "number" and units > 0 then
					local got = BagService.add(player, debrisId, units)
					if got >= units then
						instance:Destroy()
					elseif got > 0 then
						instance:SetAttribute("Units", units - got)
					end
				end
			end
		end
	end

	for _, instance in CollectionService:GetTagged("MowBlade") do
		if instance:IsA("BasePart") and instance.Parent then
			local offset = instance.Position - at
			if offset.X * offset.X + offset.Z * offset.Z <= RADIUS_SQ then
				CollectibleService.collect(instance, player)
			end
		end
	end
end

function AutoCollectService.start()
	Loop.forever("AutoCollect", function()
		task.wait(INTERVAL)
		for _, player in Players:GetPlayers() do
			if MonetizationService.owns(player, "autoCollect") then
				local root = rootOf(player)
				if root then
					sweepFor(player, root.Position)
				end
			end
		end
	end)
end

return AutoCollectService
