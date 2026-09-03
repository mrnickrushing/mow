--!strict
--[[
	Intro — the story the game opens on, once.

	The reference game opens on a scene with a line of narration across it and
	a SKIP in the corner, and it is the thing that tells you why you are about
	to spend forty minutes mowing somebody's lawn. This game opened on a lobby
	with no explanation at all.

	Deliberately small: black bars, a line at a time, a skip. It is a caption
	track over a slow camera move across the property you are about to be sent
	to, rather than anything pre-rendered — there is nothing to upload, nothing
	to stream, and it cannot fall out of step with a world that gets rebuilt.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Remotes)
local Theme = require(script.Parent.Theme)
local PlayerState = require(script.Parent.Parent.PlayerState)

local Intro = {}

local player = Players.LocalPlayer
local doneRemote: RemoteEvent
local gui: ScreenGui
local caption: TextLabel
local topBar: Frame
local bottomBar: Frame
local playing = false
local finished = false

--[[
	The script.

	Short lines, because they are read once by somebody who wants to start
	playing, and every one of them has to earn its four seconds.
]]
local LINES = {
	"Uncle Nick left you the mower.",
	"He left you the truck, and the keys to the shed.",
	"He also left you every customer on this street.",
	"Every lawn. Every weed. Every leaf in the gutter.",
	"And the bills come Friday.",
	"Better get cutting.",
}

local SECONDS_PER_LINE = 3.4
local FADE = 0.45

--------------------------------------------------------------------
-- Build
--------------------------------------------------------------------

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "MowIntro"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Enabled = false
	gui.DisplayOrder = 50
	gui.Parent = player:WaitForChild("PlayerGui")

	--[[
		Letterbox, which is what tells a player this is a cutscene and not a
		bug. They slide in rather than appearing, because a hard cut to black
		bars reads as the game breaking.
	]]
	topBar = Instance.new("Frame")
	topBar.Name = "TopBar"
	topBar.Size = UDim2.new(1, 0, 0.14, 0)
	topBar.Position = UDim2.new(0, 0, -0.14, 0)
	topBar.BackgroundColor3 = Color3.new(0, 0, 0)
	topBar.BorderSizePixel = 0
	topBar.Parent = gui

	bottomBar = Instance.new("Frame")
	bottomBar.Name = "BottomBar"
	bottomBar.Size = UDim2.new(1, 0, 0.14, 0)
	bottomBar.Position = UDim2.new(0, 0, 1, 0)
	bottomBar.BackgroundColor3 = Color3.new(0, 0, 0)
	bottomBar.BorderSizePixel = 0
	bottomBar.Parent = gui

	caption = Theme.text({
		name = "Caption",
		text = "",
		size = UDim2.new(0.86, 0, 0, 90),
		position = UDim2.new(0.5, 0, 0.72, 0),
		anchor = Vector2.new(0.5, 0.5),
		parent = gui,
		align = Enum.TextXAlignment.Center,
		--[[
			White, explicitly.

			`Theme.text` defaults to the palette's body colour, which is a dark
			ink chosen to sit on cream panels. Over a sunlit lawn at midday it
			is a smudge, and a caption nobody can read is worse than no
			caption. The heavy outline the theme adds is exactly right here and
			stays.
		]]
		color = Color3.fromRGB(255, 255, 255),
		textSize = 36,
	})
	caption.TextWrapped = true
	caption.TextTransparency = 1

	local skip = Instance.new("TextButton")
	skip.Name = "Skip"
	skip.Text = "SKIP"
	skip.Size = UDim2.fromOffset(132, 46)
	skip.Position = UDim2.new(1, -26, 1, -26)
	skip.AnchorPoint = Vector2.new(1, 1)
	skip.BackgroundColor3 = Color3.fromRGB(64, 154, 232)
	skip.BorderSizePixel = 0
	skip.AutoButtonColor = true
	skip.Font = Theme.font
	skip.TextColor3 = Color3.fromRGB(252, 250, 244)
	skip.TextSize = 26
	skip.Parent = gui
	Theme.corner(skip, 8)
	Theme.outline(skip, 2)
	skip.Activated:Connect(function()
		Intro.finish()
	end)
end

--------------------------------------------------------------------
-- Playing
--------------------------------------------------------------------

--[[
	A slow drift across whatever property is loaded underneath the lobby.

	The camera is put somewhere deliberately and walked sideways, so the shot
	has motion in it without needing anything animated in the world. If there
	is nothing to look at — no world yet — it simply holds where it is, and the
	captions carry it.
]]
type Shot = { at: Vector3, target: Vector3 }

local function frameShot(): Shot?
	local world = Workspace:FindFirstChild("MowWorld")
	if not world then
		return nil
	end
	local house = world:FindFirstChild("House") or world:FindFirstChild("Station")
	if not house then
		return nil
	end

	--[[
		The middle of the building, not the first brick of it.

		This took the position of whichever part the tree walk happened to
		reach first, which for a house built out of ninety pieces is a window
		frame or a bit of eaves — so the shot was framed on an arbitrary corner
		and pointed at the sky as often as at the property. A bounding box is
		the only honest answer to "where is the house".
	]]
	local low = Vector3.new(math.huge, math.huge, math.huge)
	local high = Vector3.new(-math.huge, -math.huge, -math.huge)
	local found = false
	for _, part in house:GetDescendants() do
		if part:IsA("BasePart") then
			found = true
			low = low:Min(part.Position - part.Size * 0.5)
			high = high:Max(part.Position + part.Size * 0.5)
		end
	end
	if not found then
		return nil
	end

	local centre = (low + high) * 0.5
	local span = math.max(high.X - low.X, high.Z - low.Z)
	-- Stood back by the building's own width, and a little above its roof, so
	-- the whole frontage is in shot whatever property is loaded.
	local at = centre + Vector3.new(-span * 0.55, (high.Y - low.Y) * 0.9, -span * 0.75)
	return { at = at, target = centre }
end

local function tween(object: Instance, seconds: number, goal: { [string]: any })
	TweenService:Create(object, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal):Play()
end

--[[
	Everything else on screen, hidden while this plays and put back after.

	The bag, the quest strip, the cash, the tool button and the joystick were
	all still up over the letterbox, which makes a cutscene look like a bug in
	the HUD. Remembered rather than assumed, so a screen that was already off
	— the journal, say — does not come back on at the end.
]]
local hidden: { [ScreenGui]: boolean } = {}

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

--- True while the opening is on screen, so nothing else opens over it.
function Intro.isPlaying(): boolean
	return playing
end

function Intro.finish()
	if finished then
		return
	end
	finished = true
	playing = false
	setChromeVisible(true)

	if gui then
		gui.Enabled = false
	end
	local camera = Workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Custom
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			camera.CameraSubject = humanoid
		end
	end
	if doneRemote then
		doneRemote:FireServer()
	end
end

function Intro.play()
	if playing or finished or not gui then
		return
	end
	playing = true
	gui.Enabled = true
	setChromeVisible(false)

	tween(topBar, FADE, { Position = UDim2.new(0, 0, 0, 0) })
	tween(bottomBar, FADE, { Position = UDim2.new(0, 0, 0.86, 0) })

	local camera = Workspace.CurrentCamera
	local shot = frameShot()
	if camera and shot then
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = CFrame.lookAt(shot.at, shot.target)
		-- Drifting sideways for the whole of the narration.
		TweenService:Create(
			camera,
			TweenInfo.new(#LINES * SECONDS_PER_LINE, Enum.EasingStyle.Linear),
			{ CFrame = CFrame.lookAt(shot.at + Vector3.new(120, -6, 30), shot.target) }
		):Play()
	end

	task.spawn(function()
		for _, line in LINES do
			if not playing then
				return
			end
			caption.Text = line
			tween(caption, FADE, { TextTransparency = 0 })
			local elapsed = 0
			while elapsed < SECONDS_PER_LINE - FADE do
				if not playing then
					return
				end
				elapsed += task.wait(0.1)
			end
			tween(caption, FADE, { TextTransparency = 1 })
			task.wait(FADE)
		end
		Intro.finish()
	end)
end

--[[
	Waits until there is actually something to point the camera at.

	The opening fires on the first profile push, which beats the world to the
	client: `frameShot` looks for `MowWorld`, does not find it yet, and returns
	nil. `play` guards its camera work with `if camera and shot`, so the whole
	shot was quietly skipped and the six lines ran over Roblox's own camera,
	which at that moment is drifting toward a character the lobby has not
	placed yet. Measured from a cold join, the camera reads `Custom` for the
	entire cutscene and spends the first three seconds pointed at open sky.

	That guard is the right shape — a cutscene with no shot should not pretend
	— it just had nothing behind it. Waiting for the world and for the player
	to be standing somewhere gives it something. If neither arrives, the story
	is skipped rather than played badly, and `introSeen` stays unset so the
	next join gets a proper go at it.
]]
local READY_TIMEOUT = 20

local function ready(): boolean
	if frameShot() == nil then
		return false
	end
	local character = player.Character
	return character ~= nil and character.PrimaryPart ~= nil
end

local function waitThenPlay()
	local deadline = os.clock() + READY_TIMEOUT
	while os.clock() < deadline do
		if finished or playing then
			return
		end
		if ready() then
			Intro.play()
			return
		end
		task.wait(0.2)
	end
end

function Intro.start()
	doneRemote = Remotes.event(Remotes.INTRO_DONE)
	build()

	--[[
		Waits for the profile before deciding.

		`showIntro` is false until a save has actually loaded, so playing on
		the first frame would show the opening to everybody, every time. This
		waits for the server to say one way or the other and then stops
		listening.
	]]
	local connection: RBXScriptConnection? = nil
	connection = PlayerState.Changed:Connect(function()
		if finished or playing then
			return
		end
		--[[
			Only in the yard, never in the middle of a run.

			`introSeen` is set when the opening ends, so a player who is
			teleported to their run before it finishes still has it unset when
			they arrive — and the next profile push would start the story over
			the top of a lawn they are already mowing, with the camera taken
			off them and the HUD hidden.

			The lobby is the one server with a `MowLobby` in it, which is a
			plainer question than asking the round what phase it is in.
		]]
		if not workspace:FindFirstChild("MowLobby") then
			return
		end
		if PlayerState.get().showIntro then
			if connection then
				connection:Disconnect()
			end
			task.spawn(waitThenPlay)
		end
	end)
end

return Intro
