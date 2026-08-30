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

type Piece = {
	shape: "block" | "cylinder" | "sphere",
	size: Vector3,
	at: CFrame,
	color: Color3,
	material: Enum.Material?,
}

local function piece(
	shape: "block" | "cylinder" | "sphere",
	size: Vector3,
	at: CFrame,
	color: Color3,
	material: Enum.Material?
): Piece
	return { shape = shape, size = size, at = at, color = color, material = material }
end

--- A tube running forward from the camera. Roblox cylinders stand on their end,
--- so the rotation is what turns one into a barrel rather than a bollard.
local function tube(length: number, radius: number, z: number, color: Color3): Piece
	return piece(
		"cylinder",
		Vector3.new(radius * 2, length, radius * 2),
		CFrame.new(0, 0, z) * CFrame.Angles(math.rad(90), 0, 0),
		color
	)
end

local BARREL_DARK = rgb(58, 40, 30)
local BARREL_GREY = rgb(150, 150, 152)
local HOUSING = rgb(232, 168, 44)
local GLOVE = rgb(150, 168, 132)
local SKIN = rgb(226, 178, 140)
local METAL = rgb(176, 178, 182)
local WOOD = rgb(146, 104, 62)

--[[
	The silhouette for a tool category.

	Deliberately coarse. At the bottom corner of a phone screen a blower needs to
	read as "long tube" and a rake as "pole with a head on it" — detail beyond
	that is invisible and costs parts on every frame.
]]
local function shapesFor(tool: Types.ToolDef): { Piece }
	local category = tool.category

	if category == "Blower" then
		return {
			-- Two tones down the barrel: the near half dark, the far half grey,
			-- which is what gives the tube any sense of length at all.
			tube(2.0, 0.17, -1.05, BARREL_GREY),
			tube(2.2, 0.19, 0.85, BARREL_DARK),
			piece("block", Vector3.new(0.5, 0.44, 0.7), CFrame.new(0, -0.05, 1.9), HOUSING),
			piece("cylinder", Vector3.new(0.46, 0.5, 0.46), CFrame.new(0, -0.3, 1.6), BARREL_DARK),
		}
	elseif category == "Hand" then
		return {
			piece("block", Vector3.new(0.52, 0.24, 0.66), CFrame.new(0, 0, 0.15), GLOVE),
			piece("block", Vector3.new(0.5, 0.2, 0.3), CFrame.new(0, 0.02, -0.32), SKIN),
			piece("block", Vector3.new(0.2, 0.22, 0.34), CFrame.new(-0.3, -0.02, 0.1), GLOVE),
		}
	elseif category == "Rake" then
		return {
			tube(2.6, 0.08, 0.2, WOOD),
			piece("block", Vector3.new(0.9, 0.1, 0.16), CFrame.new(0, -0.08, -1.05), METAL),
			piece("block", Vector3.new(0.85, 0.32, 0.06), CFrame.new(0, -0.28, -1.05), METAL),
		}
	elseif category == "Trimmer" or category == "Saw" or category == "Chainsaw" then
		return {
			tube(2.4, 0.09, 0.1, BARREL_DARK),
			piece("block", Vector3.new(0.4, 0.34, 0.62), CFrame.new(0, 0, 1.2), HOUSING),
			piece("block", Vector3.new(0.34, 0.1, 0.7), CFrame.new(0, -0.06, -1.1), METAL),
		}
	elseif category == "HedgeTrimmer" then
		return {
			piece("block", Vector3.new(0.42, 0.36, 0.8), CFrame.new(0, 0, 0.9), HOUSING),
			piece("block", Vector3.new(0.16, 0.1, 1.9), CFrame.new(0, -0.04, -0.5), METAL),
		}
	end

	-- Mowers and everything on wheels: a handlebar, since the machine itself is
	-- under the camera rather than in front of it.
	return {
		tube(1.9, 0.07, 0.55, METAL),
		piece("block", Vector3.new(1.5, 0.12, 0.12), CFrame.new(0, 0.55, -0.35), BARREL_DARK),
		piece("block", Vector3.new(0.34, 0.3, 0.4), CFrame.new(0, 0.1, 1.35), HOUSING),
	}
end

--------------------------------------------------------------------
-- Build
--------------------------------------------------------------------

local function ensureContainer(): Folder
	local existing = container
	if existing then
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
	for _, spec in shapesFor(tool) do
		local part = Instance.new("Part")
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Size = spec.size
		part.Color = spec.color
		part.Material = spec.material or Enum.Material.SmoothPlastic

		if spec.shape == "cylinder" then
			local mesh = Instance.new("CylinderMesh")
			mesh.Parent = part
		elseif spec.shape == "sphere" then
			part.Shape = Enum.PartType.Ball
		end

		part.Parent = folder
		table.insert(parts, { part = part, offset = spec.at })
	end
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
