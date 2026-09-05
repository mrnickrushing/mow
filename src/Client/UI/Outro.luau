--!strict
--[[
	Outro — what you watch on the way back to the lobby.

	Walking out through the grate ends the run, and what happened next was
	nothing: the world stayed exactly as it was, the HUD went on showing a
	finished property, and after a wait the screen went black for a teleport.
	Three quarters of a minute of standing in a garden you have no further
	business in, then a hard cut.

	So the last thing you do on a property now plays as a shot. The camera
	lifts off the lawn and pulls back over the whole estate, the letterbox
	comes in, and the run's own numbers are read out over it while the server
	arranges the trip home. It is the same furniture the opening uses, for the
	same reason — a cutscene is how a game says "this bit is over" — and it
	covers exactly the dead time that used to be a wait.

	There is deliberately no skip. The bars are not in the way of anything:
	behind them the run is finished and the teleport is already coming.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Util.Format)
local Remotes = require(Shared.Remotes)
local Theme = require(script.Parent.Theme)

local Outro = {}

local player = Players.LocalPlayer
local gui: ScreenGui
local topBar: Frame
local bottomBar: Frame
local title: TextLabel
local caption: TextLabel

local playing = false
local blur: BlurEffect? = nil
local hidden: { [ScreenGui]: boolean } = {}

local FADE = 0.5
--- How long each line holds. Shorter than the opening's: this is a curtain
--- call, not a story, and the teleport is not going to wait for it.
local SECONDS_PER_LINE = 2.6

local function tween(object: Instance, seconds: number, goal: { [string]: any })
	TweenService:Create(object, TweenInfo.new(seconds, Enum.EasingStyle.Quad), goal):Play()
end

--------------------------------------------------------------------
-- Chrome
--------------------------------------------------------------------

--- Everything else on screen goes away, and comes back if the teleport never
--- happens and the player is left standing in a lobby.
local function setChromeVisible(visible: boolean)
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return
	end
	if visible then
		for screen in hidden do
			if screen.Parent then
				screen.Enabled = true
			end
		end
		table.clear(hidden)
		return
	end
	for _, screen in playerGui:GetChildren() do
		if screen:IsA("ScreenGui") and screen ~= gui and screen.Enabled then
			hidden[screen] = true
			screen.Enabled = false
		end
	end
end

local function setBlur(on: boolean)
	if on then
		if blur and blur.Parent then
			return
		end
		local effect = Instance.new("BlurEffect")
		effect.Name = "MowOutroBlur"
		effect.Size = 0
		effect.Parent = Lighting
		blur = effect
		TweenService:Create(effect, TweenInfo.new(FADE * 2), { Size = 14 }):Play()
		return
	end
	local effect = blur
	blur = nil
	if effect and effect.Parent then
		local fade = TweenService:Create(effect, TweenInfo.new(FADE), { Size = 0 })
		fade.Completed:Connect(function()
			effect:Destroy()
		end)
		fade:Play()
	end
end

--------------------------------------------------------------------
-- Build
--------------------------------------------------------------------

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "MowOutro"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Enabled = false
	-- Above the opening, because if both ever ran the later one is the truth.
	gui.DisplayOrder = 55
	gui.Parent = player:WaitForChild("PlayerGui")

	topBar = Instance.new("Frame")
	topBar.Name = "TopBar"
	topBar.Size = UDim2.new(1, 0, 0.16, 0)
	topBar.Position = UDim2.new(0, 0, -0.16, 0)
	topBar.BackgroundColor3 = Color3.new(0, 0, 0)
	topBar.BorderSizePixel = 0
	topBar.Parent = gui

	bottomBar = Instance.new("Frame")
	bottomBar.Name = "BottomBar"
	bottomBar.Size = UDim2.new(1, 0, 0.16, 0)
	bottomBar.Position = UDim2.new(0, 0, 1, 0)
	bottomBar.BackgroundColor3 = Color3.new(0, 0, 0)
	bottomBar.BorderSizePixel = 0
	bottomBar.Parent = gui

	title = Theme.text({
		name = "Title",
		text = "",
		size = UDim2.new(0.9, 0, 0, 96),
		position = UDim2.new(0.5, 0, 0.3, 0),
		anchor = Vector2.new(0.5, 0.5),
		parent = gui,
		align = Enum.TextXAlignment.Center,
		color = Color3.fromRGB(255, 255, 255),
		textSize = 66,
	})
	title.TextTransparency = 1
	local titleSize = Instance.new("UITextSizeConstraint")
	titleSize.MaxTextSize = 66
	titleSize.MinTextSize = 26
	titleSize.Parent = title
	local titleStroke = title:FindFirstChildOfClass("UIStroke")
	if titleStroke then
		titleStroke.Thickness = 4
		titleStroke.Transparency = 0
	end

	caption = Theme.text({
		name = "Caption",
		text = "",
		size = UDim2.new(0.86, 0, 0, 120),
		position = UDim2.new(0.5, 0, 0.74, 0),
		anchor = Vector2.new(0.5, 0.5),
		parent = gui,
		align = Enum.TextXAlignment.Center,
		color = Color3.fromRGB(255, 255, 255),
		textSize = 46,
	})
	caption.TextWrapped = true
	caption.TextTransparency = 1
	local captionSize = Instance.new("UITextSizeConstraint")
	captionSize.MaxTextSize = 46
	captionSize.MinTextSize = 20
	captionSize.Parent = caption
	local captionStroke = caption:FindFirstChildOfClass("UIStroke")
	if captionStroke then
		captionStroke.Thickness = 4
		captionStroke.Transparency = 0
	end
end

--------------------------------------------------------------------
-- The shot
--------------------------------------------------------------------

--[[
	Up and back off the property, looking at the whole of it.

	Framed on the world folder rather than on a fixed point, so it is the
	property the player just finished that fills the shot whichever one that
	was. If the world has already been torn down there is nothing to look at
	and the camera is left where it is; the bars and the lines still play.
]]
local function flyOff()
	local camera = Workspace.CurrentCamera
	local world = Workspace:FindFirstChild("MowWorld")
	if not camera or not world then
		return
	end

	local low, high = Vector3.new(math.huge, 0, math.huge), Vector3.new(-math.huge, 0, -math.huge)
	local found = false
	for _, part in world:GetChildren() do
		if part:IsA("BasePart") and part.Name:match("^Ground%d+$") then
			found = true
			low = Vector3.new(math.min(low.X, part.Position.X), 0, math.min(low.Z, part.Position.Z))
			high = Vector3.new(math.max(high.X, part.Position.X), 0, math.max(high.Z, part.Position.Z))
		end
	end
	if not found then
		return
	end

	local middle = (low + high) * 0.5
	local span = math.max(high.X - low.X, high.Z - low.Z, 200)

	camera.CameraType = Enum.CameraType.Scriptable
	local start = CFrame.lookAt(middle + Vector3.new(0, span * 0.28, span * 0.62), middle)
	camera.CFrame = start
	TweenService:Create(camera, TweenInfo.new(#{ 1, 2, 3, 4 } * SECONDS_PER_LINE, Enum.EasingStyle.Linear), {
		CFrame = CFrame.lookAt(middle + Vector3.new(span * 0.18, span * 0.55, span * 0.95), middle),
	}):Play()
end

--------------------------------------------------------------------
-- Playing
--------------------------------------------------------------------

--[[
	Rolls the outro. `won` decides the headline; the rest is the same shot
	either way, because running out of time is still the end of the run and
	still wants covering while the server sends you home.
]]
function Outro.play(won: boolean, worldName: string, elapsed: number)
	if playing or not gui then
		return
	end
	playing = true
	gui.Enabled = true
	setChromeVisible(false)
	setBlur(true)
	flyOff()

	tween(topBar, FADE, { Position = UDim2.new(0, 0, 0, 0) })
	tween(bottomBar, FADE, { Position = UDim2.new(0, 0, 0.84, 0) })

	title.Text = if won then worldName else "Out of time"
	tween(title, FADE, { TextTransparency = 0 })

	local lines: { string } = if won
		then {
			`Cleared in {Format.clock(elapsed)}.`,
			"Every last leaf of it.",
			"Load her up. That one's done.",
			"Heading back to the yard…",
		}
		else {
			"The light went before the work did.",
			"Some of it will still be there tomorrow.",
			"Heading back to the yard…",
		}

	task.spawn(function()
		for _, line in lines do
			if not playing then
				return
			end
			caption.Text = line
			tween(caption, FADE, { TextTransparency = 0 })
			local held = 0
			while held < SECONDS_PER_LINE - FADE do
				if not playing then
					return
				end
				held += task.wait(0.1)
			end
			tween(caption, FADE, { TextTransparency = 1 })
			task.wait(FADE)
		end
		-- The last line stays up: whatever is left of the wait is spent on
		-- "heading back" rather than on an empty black bar.
		if playing then
			caption.Text = lines[#lines]
			tween(caption, FADE, { TextTransparency = 0 })
		end
	end)
end

--[[
	Puts everything back.

	Only reached when the trip home does not happen — a teleport that fails,
	or a single-server test where the lobby is the same place. Leaving the
	bars up in that case would strand the player behind a curtain.
]]
function Outro.finish()
	if not playing then
		return
	end
	playing = false
	setBlur(false)
	tween(topBar, FADE, { Position = UDim2.new(0, 0, -0.16, 0) })
	tween(bottomBar, FADE, { Position = UDim2.new(0, 0, 1, 0) })
	tween(title, FADE, { TextTransparency = 1 })
	tween(caption, FADE, { TextTransparency = 1 })

	local camera = Workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Custom
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			camera.CameraSubject = humanoid
		end
	end

	task.delay(FADE, function()
		if not playing then
			setChromeVisible(true)
			if gui then
				gui.Enabled = false
			end
		end
	end)
end

function Outro.start()
	build()

	--[[
		Driven off the phase, which is the moment the run actually ended
		rather than the moment this client happened to touch the grate. On a
		team, everybody watches it — the run is over for all of them.
	]]
	local last = ""
	Remotes.event(Remotes.ROUND_STATE).OnClientEvent:Connect(function(state: any)
		if type(state) ~= "table" then
			return
		end
		local phase = tostring(state.phase)
		if phase == last then
			return
		end
		last = phase

		if phase == "won" or phase == "lost" then
			Outro.play(
				phase == "won",
				tostring(state.worldName or "That one"),
				if type(state.elapsed) == "number" then state.elapsed else 0
			)
		elseif playing then
			-- Back in a lobby without having been teleported anywhere.
			Outro.finish()
		end
	end)
end

return Outro
