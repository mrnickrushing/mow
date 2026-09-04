--!strict
--[[
	PriceService — what these things actually cost, asked rather than assumed.

	Every price in `Monetization` is a number written down when the item was
	created on the dashboard, and the store drew its labels straight from those
	numbers. That works exactly as long as nothing else is allowed to change a
	price, and something is: Roblox's managed pricing sets its own, and it had
	already done it to all forty-five of them. The Riding Mower said 599 in the
	shop and cost 540 at the till; every item in the game was listed ten per
	cent high. Nobody would have reported it, because the surprise is in the
	player's favour and it happens after they have already decided.

	A written-down price cannot be right anyway. Managed pricing is regional —
	the same product is a different number of Robux in different places — so
	there is no single figure the config could hold that is true for everybody.
	The only correct answer is the one Roblox gives when asked.

	So the server asks, once, and hands the answers to every client through
	attributes on a folder. `GetProductInfo` is a web call, which is why this
	does not happen on the client: forty-five of them per player joining is
	forty-five that Roblox will eventually start refusing. Here it is forty-five
	per server.

	The config numbers stay exactly where they are and remain the fallback. If
	the fetch fails the store shows what it always showed, which is wrong by ten
	per cent rather than blank — a store with no prices in it is worse than a
	store with slightly stale ones.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Loop = require(Shared.Util.Loop)
local Monetization = require(Shared.Config.Monetization)

local PriceService = {}

--- How often to ask again. Prices move when a human changes them or when
--- managed pricing retunes, neither of which happens on the scale of a round,
--- so this is slow on purpose: a server lives about ninety minutes and this
--- gives it four looks in that time.
local REFRESH = 20 * 60

--- Between calls, so a server booting does not fire forty-five web requests
--- into the same instant and get throttled for it.
local SPACING = 0.08

local folder: Folder

--- One attribute per id, named for the id. Attributes replicate on their own
--- and survive a late joiner reading them, which a RemoteEvent broadcast at
--- startup would not.
local function publish(id: number, price: number)
	folder:SetAttribute(`p{id}`, price)
end

local function fetchOne(id: number, infoType: Enum.InfoType): number?
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfo(id, infoType)
	end)
	if not ok or type(info) ~= "table" then
		return nil
	end
	local price = (info :: any).PriceInRobux
	--[[
		A free item and an unanswerable one both look like nothing here.

		`PriceInRobux` is nil for an item that is not for sale, and this is
		asked about items that are. Treating that as a price of zero would put
		"FREE" on a paid product, so it is left alone and the config value
		stands instead.
	]]
	if type(price) ~= "number" or price <= 0 then
		return nil
	end
	return price
end

local function refresh()
	local live, missing = 0, 0
	for _, pass in Monetization.passes do
		local price = fetchOne(pass.id, Enum.InfoType.GamePass)
		if price then
			publish(pass.id, price)
			live += 1
		else
			missing += 1
		end
		task.wait(SPACING)
	end
	for _, product in Monetization.products do
		local price = fetchOne(product.id, Enum.InfoType.Product)
		if price then
			publish(product.id, price)
			live += 1
		else
			missing += 1
		end
		task.wait(SPACING)
	end
	folder:SetAttribute("ready", true)
	if missing > 0 then
		warn(`[Prices] {live} live, {missing} fell back to the configured price`)
	end
end

function PriceService.start()
	folder = Instance.new("Folder")
	folder.Name = "MowPrices"
	folder.Parent = ReplicatedStorage

	Loop.forever("Prices.refresh", function()
		refresh()
		task.wait(REFRESH)
	end)
end

return PriceService
