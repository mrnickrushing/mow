--!strict
--[[
	ShopController — the counter in the lobby opens the shop.

	The Stand was built as furniture and left as furniture: a counter with a
	sign on it and no way to buy anything, in a yard whose one argument for
	having a building in it at all was that buying a mower should happen at a
	counter rather than at a button in the corner of a screen. A counter you
	cannot buy at is the button plus an obstruction.

	The prompt is made by `LobbyService` on the worktop and marked with a
	`MowShop` attribute. Watched from here rather than answered on the server,
	because the store is a screen the player already opens for themselves with
	G and with the HUD pill — a second way into the same window does not need
	a remote, and one that went through the server would open it a round trip
	later than the two that do not.
]]

local ProximityPromptService = game:GetService("ProximityPromptService")

local Intro = require(script.Parent.Parent.UI.Intro)
local Store = require(script.Parent.Parent.UI.Store)

local ShopController = {}

function ShopController.start()
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt)
		if prompt:GetAttribute("MowShop") ~= true then
			return
		end
		--[[
			Dead while the opening is running, like every other way in.

			The intro takes the camera and hides the screen, and a player can
			still walk during it — so without this, somebody who wanders into
			the counter four seconds into their first session gets the store
			over the top of the story, and it is still there afterwards
			because the intro only puts back what it took away.
		]]
		if Intro.isPlaying() then
			return
		end
		Store.setOpen(true)
	end)
end

return ShopController
