--!strict
--[[
	ShedController — the keys that open the journal and the Robux store.

	It used to fling the journal open whenever the player neared the shed, but
	buying now happens at boards standing in the world, and a book leaping into
	your face as you walk up to one is the opposite of helpful. The journal is
	for reading — quests, the collection, prices at a distance — and it opens
	when asked.
]]

local ContextActionService = game:GetService("ContextActionService")

local Journal = require(script.Parent.Parent.UI.Journal)
local Store = require(script.Parent.Parent.UI.Store)

local ShedController = {}

local ACTION_NAME = "MowAllTheLawns_Shop"

function ShedController.start()
	ContextActionService:BindAction(ACTION_NAME, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			Journal.toggle()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.B, Enum.KeyCode.Tab, Enum.KeyCode.ButtonY)

	ContextActionService:BindAction("MowAllTheLawns_Store", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			Store.toggle()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.G, Enum.KeyCode.ButtonSelect)
end

return ShedController
