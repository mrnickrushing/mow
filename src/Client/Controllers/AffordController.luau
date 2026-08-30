--!strict
--[[
	AffordController — "You can now afford Power!"

	The moment a purchase comes into reach is the moment a player wants to know
	about it, and it is not a moment they can see: cash climbs a fraction at a
	time while they are looking at the ground, and the shop is behind a menu.
	Without this, most upgrades get bought some minutes after they could have
	been, which makes the whole ladder feel slower than it is.

	Announced once per thing, not once per frame the money is there. Each
	upgrade level and each tool is its own announcement, so a player who spends
	back down and climbs again is not told twice about the same purchase.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ToolUpgrades = require(Shared.Config.ToolUpgrades)
local Tools = require(Shared.Config.Tools)
local Upgrades = require(Shared.Config.Upgrades)
local PlayerState = require(script.Parent.Parent.PlayerState)
local Hud = require(script.Parent.Parent.UI.Hud)
local Journal = require(script.Parent.Parent.UI.Journal)

local AffordController = {}

local announced: { [string]: boolean } = {}
--- Cash at the last check, so a run resetting can be told from money spent.
local lastCash = 0

--[[
	Whether something is worth announcing yet.

	Only the next level of a line counts, and only the cheapest tool the player
	does not own. Announcing every affordable purchase at once would be a wall
	of toasts the first time somebody sells a full bag.
]]
local function check()
	local state = PlayerState.get()

	-- A fresh run zeroes the cash and the loadout, so everything is news again.
	if state.cash < lastCash * 0.5 and state.cash < 1 then
		table.clear(announced)
	end
	lastCash = state.cash

	for _, def in Upgrades.list do
		local level = state.upgrades[def.id] or 0
		local cost = Upgrades.costAt(def, level)
		if cost and state.cash >= cost then
			local key = `upgrade:{def.id}:{level}`
			if not announced[key] then
				announced[key] = true
				Hud.toast("afford", `You can now afford {def.name}!`)
			end
		end
	end

	-- The equipped tool's own three slots, by the tool's own names — "You can
	-- now afford Throttle!" tells the player to open the book.
	for toolId in state.ownedTools do
		if toolId == state.equippedTool then
			for _, slot in ToolUpgrades.treeFor(toolId) do
				local level = state.upgrades[slot.key] or 0
				local cost = ToolUpgrades.costAt(slot, level)
				if cost and state.cash >= cost then
					local key = `slot:{slot.key}:{level}`
					if not announced[key] then
						announced[key] = true
						Hud.toast("afford", `You can now afford {slot.name}!`)
					end
				end
			end
		end
	end

	-- Tools are the larger jump, so the cheapest one still missing is the one
	-- worth naming; the rest will announce themselves in turn.
	for _, tool in Tools.list do
		if tool.cost > 0 and not state.ownedTools[tool.id] then
			if state.cash >= tool.cost then
				local key = `tool:{tool.id}`
				if not announced[key] then
					announced[key] = true
					Hud.toast("afford", `You can now afford the {tool.name}!`)
				end
			end
			break
		end
	end
end

function AffordController.start()
	PlayerState.Changed:Connect(function()
		check()
		-- The HUD's journal icon carries the same red dot as the book's own
		-- Upgrades tab, and for the same reason.
		Hud.setJournalBadge(Journal.somethingAffordable())
	end)
end

return AffordController
