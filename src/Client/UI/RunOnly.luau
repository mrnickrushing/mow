--!strict
--[[
	RunOnly — chrome that belongs to a run, hidden while you are in the lobby.

	Standing in the lobby, the screen carried a bag reading 25 / 0, a clock
	frozen at 0:00, a rate of "0.02$ / clipping", a crosshair over the grass,
	an eight-slot hotbar holding nothing, and the word PICK UP with nothing to
	pick up. None of it is wrong exactly — it is instrumentation for a run,
	shown to somebody who has not started one — but a screenful of dials all
	reading zero is what a broken game looks like, and it buries the two
	things the lobby actually wants you to read: your money, and the pad.

	Registered elements are hidden until the server says a round is running.

	Deliberately `Visible` on inner frames and never `ScreenGui.Enabled`: the
	opening cutscene hides chrome by switching `Enabled` off and remembering
	what it switched, so anything else touching that same property would be
	turned back on when the story ends.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Remotes)

local RunOnly = {}

local watched: { GuiObject } = {}
local running = false

local function apply()
	for _, object in watched do
		object.Visible = running
	end
end

--- Hides this element until a run is actually under way.
function RunOnly.add(object: GuiObject)
	table.insert(watched, object)
	object.Visible = running
end

function RunOnly.start()
	Remotes.event(Remotes.ROUND_STATE).OnClientEvent:Connect(function(state: any)
		if type(state) ~= "table" then
			return
		end
		local phase = (state :: any).phase
		local now = phase ~= nil and phase ~= "lobby"
		if now ~= running then
			running = now
			apply()
		end
	end)
end

return RunOnly
