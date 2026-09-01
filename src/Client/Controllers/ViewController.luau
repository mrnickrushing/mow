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
local Tools = require(Shared.Config.Tools)
local Props = require(Shared.Config.Props)
local Types = require(Shared.Types)
local MowController = require(script.Parent.MowController)
local PlayerState = require(script.Parent.Parent.PlayerState)

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
		return {
			prop = "RakeTool",
			size = Vector3.new(1.0, 0.5, 3.0),
			at = CFrame.new(0, -0.1, -0.5) * CFrame.Angles(math.rad(-8), 0, 0),
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

function ViewController.start()
	-- Locked rather than merely zoomed in, so the player cannot scroll out to a
	-- third-person view the viewmodel was never drawn for.
	player.CameraMode = Enum.CameraMode.LockFirstPerson
	player.CameraMinZoomDistance = 0.5
	player.CameraMaxZoomDistance = 0.5

	player.CharacterAdded:Connect(function()
		player.CameraMode = Enum.CameraMode.LockFirstPerson
	end)

	RunService.RenderStepped:Connect(step)
end

--- True when the player is on a device with no mouse to lock, which is what
--- decides whether the on-screen action button is drawn.
function ViewController.isTouch(): boolean
	return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
end

return ViewController
