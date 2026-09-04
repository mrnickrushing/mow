--!strict
--[[
	Prices — the price to put on a label.

	The live figure the server fetched if there is one, and the number from the
	config if there is not. Everything that draws a price goes through here so
	there is one answer to the question rather than one per screen.

	See `PriceService` for why the config number cannot be trusted on its own.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Prices = {}

local folder: Instance? = nil

local function prices(): Instance?
	if folder and folder.Parent then
		return folder
	end
	folder = ReplicatedStorage:FindFirstChild("MowPrices")
	return folder
end

--[[
	What this item costs, in Robux.

	`fallback` is the configured price and is returned whenever the live one is
	not there yet — a client that has only just joined, or a server whose fetch
	failed. It is never blank, because a store with no prices in it is worse
	than one with slightly stale prices.
]]
function Prices.robux(id: number, fallback: number): number
	local holder = prices()
	if not holder then
		return fallback
	end
	local live = holder:GetAttribute(`p{id}`)
	if type(live) == "number" and live > 0 then
		return live
	end
	return fallback
end

--- Fires when a price changes, so a panel already on screen can redraw rather
--- than showing the fallback until it is next opened.
function Prices.onChanged(callback: () -> ()): RBXScriptConnection?
	local holder = prices()
	if not holder then
		return nil
	end
	return holder.AttributeChanged:Connect(function()
		callback()
	end)
end

return Prices
