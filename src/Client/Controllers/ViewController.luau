--!strict
--[[
	ViewController — first person, and the tool held out in front of you.

	The reference is played down the barrel: the camera sits behind the player's
	eyes, the tool juts in from the lower right, and a small diamond marks where
	it is pointed. That framing does most of the work of making a leaf blower
	feel like a leaf blower — you are aiming it rather than watching an avatar
	swing it — so the camera is locked rather than offered as a preference.

	The viewmodel is built from parts rather than loaded from a mesh, so it needs
	no uploaded assets and every tool can have a silhouette on the day it is
	added to the config.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Remotes)
local Tools = require(Shared.Config.Tools)
local Props = require(Shared.Config.Props)
local Types = require(Shared.Types)
local MowController = require(script.Parent.MowController)
local PlayerState = require(script.Parent.Parent.PlayerState)
local Intro = require(script.Parent.Parent.UI.Intro)

local ViewController = {}

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

local container: Folder? = nil
local parts: { { part: Part, offset: CFrame } } = {}
local builtFor = ""

--- Where the viewmodel sits relative to the camera: right, low, and angled back
--- across the middle of the screen so the muzzle lands just under the crosshair.
local HOLD = CFrame.new(1.15, -1.0, -0.9) * CFrame.Angles(math.rad(6), math.rad(-9), 0)

--- How far the held tool swings while the player is working. Small on purpose:
--- a viewmodel that moves a lot reads as a camera problem rather than a tool.
local IDLE_BOB = 0.035
local WORK_BOB = 0.13

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

--------------------------------------------------------------------
-- Shapes
--------------------------------------------------------------------

--[[
	The model held in front of the camera, per tool category.

	This used to be a handful of blocks and cylinders bolted together — a rake
	was a tube with two boxes on the end of it, a pair of hands was three boxes.
	It is the one thing on screen every single frame in first person, so it was
	also the most visible collection of rectangles in the game. Each category
	now holds the tool it is actually holding, at the size and angle it reads
	best from behind.
]]
type Held = {
	prop: string,
	size: Vector3,
	at: CFrame,
}

local function held(tool: Types.ToolDef): Held
	local category = tool.category

	if category == "Hand" then
		return { prop = "Gloves", size = Vector3.new(1.1, 0.5, 0.9), at = CFrame.new(0, -0.06, 0.1) }
	elseif category == "Rake" then
		--[[
			Tines down.

			The mesh is authored with its tines on its +Y side, and it was
			hung under the camera the same way up as everything else — so the
			one tool whose whole shape is a hook was carried with the hook
			curling at the sky. A half-turn about its own handle puts the
			tines on the ground side, which is the only way anyone has ever
			held a rake.
		]]
		return {
			prop = "RakeTool",
			size = Vector3.new(1.0, 0.5, 3.0),
			at = CFrame.new(0, -0.1, -0.5) * CFrame.Angles(math.rad(-8), 0, math.pi),
		}
	elseif category == "Blower" then
		return {
			prop = "LeafBlower",
			size = Vector3.new(1.0, 0.9, 2.2),
			at = CFrame.new(0.1, -0.12, -0.35),
		}
	elseif category == "Trimmer" then
		--[[
			The trimmer model stands upright — its shaft is its height — so it
			is sized in its own proportions and pitched forward until the head
			hangs low in front, which is how a trimmer is actually carried.
			The old numbers squashed it four to one into a box shaped like the
			previous model.
		]]
		return {
			prop = "TrimmerTool",
			size = Vector3.new(0.76, 3.2, 0.83),
			at = CFrame.new(0.05, -0.28, -0.62) * CFrame.Angles(math.rad(-64), 0, 0),
		}
	elseif category == "Saw" or category == "Chainsaw" then
		-- In the saw's own proportions: a wide flat blade, not a box.
		return {
			prop = "SawTool",
			size = Vector3.new(0.31, 1.35, 2.6),
			at = CFrame.new(0.05, -0.1, -0.45),
		}
	elseif category == "HedgeTrimmer" then
		return {
			prop = "HedgeTool",
			size = Vector3.new(0.8, 0.9, 2.8),
			at = CFrame.new(0, -0.1, -0.5),
		}
	elseif category == "Grinder" then
		return { prop = "GrinderTool", size = Vector3.new(1.6, 1.2, 2.2), at = CFrame.new(0, -0.35, -0.6) }
	elseif category == "Chipper" then
		return { prop = "ChipperTool", size = Vector3.new(1.6, 1.4, 2.2), at = CFrame.new(0, -0.35, -0.6) }
	end

	-- Mowers and everything on wheels: the handlebar, since the machine itself
	-- is under the camera rather than in front of it.
	return { prop = "Handlebar", size = Vector3.new(2.0, 1.0, 1.6), at = CFrame.new(0, -0.5, -0.3) }
end

--- The folder the held model lives in, hung off the camera.
local function ensureContainer(): Folder
	local existing = container
	if existing and existing.Parent == camera then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "MowViewmodel"
	folder.Parent = camera
	container = folder
	return folder
end

local function clear()
	local folder = container
	if folder then
		folder:ClearAllChildren()
	end
	table.clear(parts)
end

local function build(toolId: string)
	clear()
	builtFor = toolId

	local tool = Tools.get(toolId)
	if not tool then
		return
	end

	local folder = ensureContainer()
	local spec = held(tool)
	local def = Props.get(spec.prop)

	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Size = spec.size
	part.Color = Color3.fromRGB(255, 255, 255)
	part.Material = Enum.Material.SmoothPlastic

	if def then
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.FileMesh
		mesh.MeshId = def.mesh
		if def.texture then
			mesh.TextureId = def.texture
		end
		mesh.Scale = Vector3.new(
			spec.size.X / def.native.X,
			spec.size.Y / def.native.Y,
			spec.size.Z / def.native.Z
		)
		mesh.Parent = part
	end

	part.Parent = folder
	table.insert(parts, { part = part, offset = spec.at })
end

--------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------

local swing = 0

local function step(delta: number)
	camera = Workspace.CurrentCamera

	local state = PlayerState.get()
	if state.equippedTool ~= builtFor then
		build(state.equippedTool)
	end

	if #parts == 0 then
		return
	end

	-- The bob is driven by a running clock rather than by the character's
	-- velocity: reading velocity makes the tool lurch every time the player
	-- clips a kerb, which looks like a bug rather than a footstep.
	local working = MowController.isMowing()
	swing += delta * (if working then 9 else 2.2)
	local amount = if working then WORK_BOB else IDLE_BOB
	local bob = CFrame.new(math.sin(swing * 0.5) * amount * 0.6, math.sin(swing) * amount, 0)
		* CFrame.Angles(math.sin(swing) * amount * 0.4, 0, 0)

	local base = camera.CFrame * HOLD * bob
	for _, entry in parts do
		entry.part.CFrame = base * entry.offset
	end
end

--------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------

--[[
	Turns a player who has just been put somewhere to face what is there.

	Both places that move a player rotate the character to do it — which in a
	first-person camera is not where facing comes from. The camera owns the yaw
	and the character is turned to match it, so the server's rotation is
	overwritten within a frame: in the lobby that left everyone staring at the
	fence behind them with the pads, the boards and the sign all out of shot,
	and on a property it left them facing the road with the whole lot behind
	them. Setting the camera is what actually turns somebody round; measured,
	it moves the character with it.

	Aimed at something standing in the world rather than at a compass
	direction, so it keeps pointing at the right thing if a place is ever laid
	out differently again — which the lobby has been twice.
]]
--[[
	What the camera should be pointed at from where the player is standing,
	or nil while there is nothing to aim at yet.

	Two places, one rule. In the lobby it is the marquee. On a property it is
	whichever way the spawn pad is turned: the server aims that at the middle
	of the section the run starts in, so following it needs no second copy of
	the level layout on the client and it keeps pointing at the right thing if
	a property is ever laid out differently.
]]
local function aimAt(): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return nil
	end

	local lobby = workspace:FindFirstChild("MowLobby")
	local marquee = lobby and lobby:FindFirstChild("StatusBoard", true)
	if marquee and marquee:IsA("BasePart") and (root.Position - marquee.Position).Magnitude <= 400 then
		return marquee.Position
	end

	--[[
		The property, and the reason this branch exists.

		The rotation the server spawns you with does not survive: the camera
		owns the yaw and turns the character to match it within a frame, so a
		run began with the camera still holding the yaw it had in the lobby.
		Measured on The House, that is due south — the road, with the lawn,
		the trailer, the house and every section of the property behind you.
		The lobby had this fixed and the run never did.

		Kept to the pad, so it is the arrival being aimed and not somebody
		walking back past their own spawn twenty minutes later.
	]]
	local world = workspace:FindFirstChild("MowWorld")
	local pad = world and world:FindFirstChild("MowSpawn")
	if pad and pad:IsA("BasePart") and (root.Position - pad.Position).Magnitude <= 40 then
		return root.Position + pad.CFrame.LookVector * 100
	end

	return nil
end

local function faceTheYard()
	task.spawn(function()
		--[[
			Holds the aim through everything that resets it.

			Three things do, and each defeated a simpler version. The lobby
			replicates from the server, so the first attempt has nothing to aim
			at. Roblox's camera module re-asserts its stored yaw while it
			settles after a spawn. And the loading screen hands the camera back
			when it closes, seconds later, undoing whatever was set before it.

			A fourth thing defeated the version after that: stopping on player
			input. `InputChanged` fires for ambient mouse movement, so in
			Studio it stood down before it had aimed even once. There is no
			input test here now — the window is short and almost all of it is
			spent behind the loading screen, so there is very little of it a
			player is awake for.
		]]
		--[[
			Aims until one aim survives a tick, then stops.

			What it is up against was measured rather than guessed. While the
			loading screen still owns the camera every set is dragged straight
			back to the yaw the character spawned with; once the screen lets go,
			a single set holds exactly, unmoved over three seconds. So there is
			no need to know when that moment is, and no need for a threshold: it
			aims, and if the aim is still there on the next tick it was not being
			fought and the job is done.

			The version before this stopped correcting as soon as the camera was
			anywhere in front of the player, which left them resting forty-six
			degrees off with the marquee at the edge of the shot — right about
			the angle the drag happened to abandon them at.

			Because it gives up the moment an aim holds, the longest it can ever
			pull against somebody turning of their own accord is one tick, and
			almost all of the window is spent behind the loading screen where
			there is nobody to pull against.
		]]
		for _ = 1, 166 do
			task.wait(0.15)
			local camera = workspace.CurrentCamera
			if not camera then
				continue
			end
			--[[
				The opening owns the camera while it runs.

				It flies the camera round the house on a tween, so aiming into
				that is both pointless and visible: the shot would stutter
				towards the lobby once every tick. It is left alone, and the
				aim happens again when it hands the camera back below.
			]]
			if Intro.isPlaying() or camera.CameraType ~= Enum.CameraType.Custom then
				continue
			end
			--[[
				Waits to be put somewhere rather than giving up.

				It was a `return`, and that is what defeated every version of
				this: the loop starts the moment the client does, which is
				before anybody has been moved anywhere, so the first thing it
				saw was a player two and a half thousand studs away at the world
				origin — reasonably concluded there was nothing to aim at, and
				quit for good. Waiting instead costs nothing.
			]]
			local target = aimAt()
			if not target then
				continue
			end
			local eye = camera.CFrame.Position
			local flat = Vector3.new(target.X, eye.Y, target.Z)
			local want = flat - eye
			if want.Magnitude < 1 then
				return
			end
			local facing = camera.CFrame.LookVector:Dot(want.Unit)
			-- Already there, and nothing pulled it away: finished.
			if facing > 0.99 then
				return
			end
			camera.CFrame = CFrame.lookAt(eye, flat)
		end
	end)
end

function ViewController.start()
	-- Locked rather than merely zoomed in, so the player cannot scroll out to a
	-- third-person view the viewmodel was never drawn for.
	player.CameraMode = Enum.CameraMode.LockFirstPerson
	player.CameraMinZoomDistance = 0.5
	player.CameraMaxZoomDistance = 0.5

	player.CharacterAdded:Connect(function()
		player.CameraMode = Enum.CameraMode.LockFirstPerson
		faceTheYard()
	end)

	--[[
		Aim again when the opening lets go of the camera.

		A player seeing the story for the first time is aimed at spawn, watches
		the narration through, and is put back down facing
		wherever the last shot drifted to — so the aim at spawn, which does
		hold, is undone by something that happens afterwards. This is that
		moment, told rather than guessed at.
	]]
	Intro.CameraReturned:Connect(faceTheYard)

	--[[
		Aim again on arriving somewhere new.

		Starting a run and coming back from one both move the player without
		reloading the character — deliberately, so that choosing a property
		does not cost you your avatar for a second — so `CharacterAdded` never
		fires for either and nothing was aiming them. Phase is the moment: it
		changes exactly when everybody has been put down somewhere else.
	]]
	local lastPhase = ""
	Remotes.event(Remotes.ROUND_STATE).OnClientEvent:Connect(function(state: any)
		local phase = if typeof(state) == "table" then tostring(state.phase) else ""
		if phase ~= lastPhase then
			lastPhase = phase
			faceTheYard()
		end
	end)

	faceTheYard()

	RunService.RenderStepped:Connect(step)
end

--- True when the player is on a device with no mouse to lock, which is what
--- decides whether the on-screen action button is drawn.
function ViewController.isTouch(): boolean
	return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
end

return ViewController
