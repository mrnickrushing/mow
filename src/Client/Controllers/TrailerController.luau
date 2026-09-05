--!strict
--[[
	TrailerController — calling the portable trailer to where you are standing.

	The Haul upgrade's own shop line is "Level 1 unlocks the portable trailer",
	and until now nothing on either side of the wire listened for it: the
	`PlaceTrailer` remote was created every session and never connected. The
	key below is the missing half of a feature the shed was already selling.

	Like the seat button, this one exists only while it means something — the
	prompt appears when the upgrade is owned, and not before, so a player who
	has not bought it is never told about a key that would only refuse them.
]]

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Remotes)
local PlayerState = require(script.Parent.Parent.PlayerState)
local Theme = require(script.Parent.Parent.UI.Theme)

local TrailerController = {}

local ACTION_NAME = "MowAllTheLawns_Trailer"
local TOUCH_ACTION = "MowAllTheLawns_TrailerTouch"

local remote: RemoteEvent
local touchBound = false

local function onPark(_, inputState)
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	remote:FireServer()
	return Enum.ContextActionResult.Sink
end

--- The on-screen button, for the tablets that have no T key to press.
local function refreshTouchButton()
	if not UserInputService.TouchEnabled then
		return
	end
	local owned = PlayerState.get().hasPortableTrailer
	if owned == touchBound then
		return
	end
	touchBound = owned
	if owned then
		ContextActionService:BindAction(TOUCH_ACTION, onPark, true)
		ContextActionService:SetTitle(TOUCH_ACTION, "Trailer")
		Theme.dressActionButton(TOUCH_ACTION)
	else
		pcall(function()
			ContextActionService:UnbindAction(TOUCH_ACTION)
		end)
	end
end

function TrailerController.start()
	remote = Remotes.event(Remotes.PLACE_TRAILER)

	ContextActionService:BindAction(ACTION_NAME, onPark, false, Enum.KeyCode.T, Enum.KeyCode.DPadDown)

	PlayerState.Changed:Connect(refreshTouchButton)
	refreshTouchButton()
end

return TrailerController
