--!strict
--[[
	Build — small helpers for assembling the world out of parts.

	Everything the player walks on is generated at runtime from the tables in
	Properties, so there is no hand-built map to keep in sync with the config.
]]

local Palette = require(game:GetService("ReplicatedStorage").Shared.Config.Palette)

local Build = {}

export type PartOptions = {
	name: string?,
	size: Vector3,
	cframe: CFrame,
	color: Color3?,
	material: Enum.Material?,
	transparency: number?,
	anchored: boolean?,
	canCollide: boolean?,
	castShadow: boolean?,
	parent: Instance?,
}

function Build.part(options: PartOptions): Part
	local part = Instance.new("Part")
	part.Name = options.name or "Part"
	part.Size = options.size
	part.CFrame = options.cframe
	part.Anchored = if options.anchored == nil then true else options.anchored
	part.CanCollide = if options.canCollide == nil then true else options.canCollide
	part.CastShadow = if options.castShadow == nil then true else options.castShadow
	part.Color = options.color or Color3.fromRGB(160, 160, 160)
	part.Material = options.material or Enum.Material.SmoothPlastic
	part.Transparency = options.transparency or 0
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = options.parent
	return part
end

--- A box centred on `centre` with its base at `baseY`.
function Build.box(
	name: string,
	centre: Vector3,
	size: Vector3,
	color: Color3,
	material: Enum.Material,
	parent: Instance?
): Part
	return Build.part({
		name = name,
		size = size,
		cframe = CFrame.new(centre + Vector3.new(0, size.Y * 0.5, 0)),
		color = color,
		material = material,
		parent = parent,
	})
end

function Build.folder(name: string, parent: Instance): Folder
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

--- A billboard sign that stays readable from across the lawn.
function Build.billboard(adornee: BasePart, size: UDim2, offsetY: number, maxDistance: number): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Name = "Sign"
	gui.Adornee = adornee
	gui.Size = size
	gui.StudsOffsetWorldSpace = Vector3.new(0, offsetY, 0)
	gui.MaxDistance = maxDistance
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.Parent = adornee
	return gui
end

function Build.label(parent: Instance, text: string, size: UDim2, position: UDim2, scale: number): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = size
	label.Position = position
	label.Text = text
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.35
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.RichText = true
	label.Parent = parent
	local constraint = Instance.new("UITextSizeConstraint")
	constraint.MaxTextSize = math.floor(28 * scale)
	constraint.Parent = label
	return label
end

function Build.prompt(parent: BasePart, actionText: string, objectText: string, distance: number): ProximityPrompt
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = actionText
	prompt.ObjectText = objectText
	prompt.MaxActivationDistance = distance
	prompt.HoldDuration = 0
	prompt.RequiresLineOfSight = false
	prompt.Parent = parent
	return prompt
end

--------------------------------------------------------------------
-- Autumn dressing
--------------------------------------------------------------------

--[[
	A wall of horizontal lap siding.

	Built as overlapping boards rather than one flat face: the shadow line under
	each board is most of what makes a cream box read as a house.
]]
function Build.sidingWall(
	parent: Instance,
	centre: Vector3,
	size: Vector3,
	facing: Vector3,
	boardHeight: number
): Folder
	local folder = Build.folder("Wall", parent)
	local boards = math.max(math.floor(size.Y / boardHeight), 1)
	local along = Vector3.new(facing.Z, 0, -facing.X)
	local width = math.abs(along.X) * size.X + math.abs(along.Z) * size.Z
	local thickness = 1.2

	for index = 0, boards - 1 do
		local y = centre.Y - size.Y * 0.5 + boardHeight * (index + 0.5)
		local shade = if index % 2 == 0 then Palette.house.siding else Palette.house.sidingShade
		Build.part({
			name = "Board",
			size = Vector3.new(
				math.abs(along.X) * width + math.abs(facing.X) * thickness,
				boardHeight * 0.94,
				math.abs(along.Z) * width + math.abs(facing.Z) * thickness
			),
			cframe = CFrame.new(Vector3.new(centre.X, y, centre.Z)),
			color = Palette.color(shade),
			material = Enum.Material.WoodPlanks,
			parent = folder,
		})
	end

	return folder
end

--[[
	A picket fence: pointed uprights on two rails.

	The reference leans on this heavily — it is the boundary of nearly every
	zone — so it is worth building properly rather than as a thin line.
]]
function Build.picketFence(
	parent: Instance,
	from: Vector3,
	to: Vector3,
	height: number,
	lattice: boolean
): Folder
	local folder = Build.folder("Fence", parent)
	local delta = to - from
	local length = delta.Magnitude
	if length < 1 then
		return folder
	end

	local direction = delta.Unit
	local spacing = 1.6
	local count = math.max(math.floor(length / spacing), 1)

	for index = 0, count - 1 do
		local at = from + direction * (length * (index + 0.5) / count)
		local shade = if index % 3 == 0 then Palette.fence.picketShade else Palette.fence.picket
		Build.part({
			name = "Picket",
			size = Vector3.new(1.25, height, 0.5),
			cframe = CFrame.lookAt(at + Vector3.new(0, height * 0.5, 0), at + direction + Vector3.new(0, height * 0.5, 0))
				* CFrame.Angles(0, math.rad(90), 0),
			color = Palette.color(shade),
			material = Enum.Material.WoodPlanks,
			canCollide = false,
			castShadow = false,
			parent = folder,
		})
		-- The pointed cap that stops a fence reading as a row of posts.
		Build.part({
			name = "Cap",
			size = Vector3.new(1.25, 0.9, 0.5),
			cframe = CFrame.lookAt(
				at + Vector3.new(0, height + 0.2, 0),
				at + direction + Vector3.new(0, height + 0.2, 0)
			) * CFrame.Angles(0, math.rad(90), 0) * CFrame.Angles(0, 0, math.rad(45)),
			color = Palette.color(Palette.fence.picket),
			material = Enum.Material.WoodPlanks,
			canCollide = false,
			castShadow = false,
			parent = folder,
		})
	end

	for _, ratio in { 0.32, 0.72 } do
		local mid = from + direction * (length * 0.5) + Vector3.new(0, height * ratio, 0)
		Build.part({
			name = "Rail",
			size = Vector3.new(0.55, 0.7, length),
			cframe = CFrame.lookAt(mid, mid + direction),
			color = Palette.color(Palette.fence.rail),
			material = Enum.Material.Wood,
			canCollide = false,
			castShadow = false,
			parent = folder,
		})
	end

	if lattice then
		-- A diamond crosshatch panel above the pickets, as on the reference's
		-- side gates.
		local panels = math.max(math.floor(length / 4), 1)
		for index = 0, panels - 1 do
			local at = from + direction * (length * (index + 0.5) / panels) + Vector3.new(0, height + 2.6, 0)
			for _, angle in { 42, -42 } do
				Build.part({
					name = "Lattice",
					size = Vector3.new(0.4, 6.5, 0.4),
					cframe = CFrame.lookAt(at, at + direction) * CFrame.Angles(0, 0, math.rad(angle)),
					color = Palette.color(Palette.fence.lattice),
					material = Enum.Material.WoodPlanks,
					canCollide = false,
					castShadow = false,
					parent = folder,
				})
			end
		end
	end

	return folder
end

--- Irregular flagstone paving, the surface most of the reference is laid with.
function Build.flagstone(parent: Instance, centre: Vector3, size: Vector2, tile: number, rng: Random): Folder
	local folder = Build.folder("Paving", parent)
	local cols = math.max(math.floor(size.X / tile), 1)
	local rows = math.max(math.floor(size.Y / tile), 1)

	for row = 0, rows - 1 do
		for col = 0, cols - 1 do
			local jitterX = (rng:NextNumber() - 0.5) * tile * 0.16
			local jitterZ = (rng:NextNumber() - 0.5) * tile * 0.16
			local shade = if rng:NextNumber() < 0.4 then Palette.ground.stoneDark else Palette.ground.stone
			Build.part({
				name = "Slab",
				size = Vector3.new(tile * 0.92, 0.5, tile * 0.92),
				cframe = CFrame.new(
					centre.X - size.X * 0.5 + tile * (col + 0.5) + jitterX,
					centre.Y,
					centre.Z - size.Y * 0.5 + tile * (row + 0.5) + jitterZ
				) * CFrame.Angles(0, rng:NextNumber() * 0.12, 0),
				color = Palette.color(shade),
				material = Enum.Material.Slate,
				canCollide = false,
				castShadow = false,
				parent = folder,
			})
		end
	end

	return folder
end

--- A hollow rectangle of fence posts and rails around a tile-space rect.
function Build.fence(
	parent: Instance,
	minX: number,
	minZ: number,
	maxX: number,
	maxZ: number,
	height: number,
	color: Color3,
	spacing: number
)
	local function rail(from: Vector3, to: Vector3)
		local delta = to - from
		local length = delta.Magnitude
		if length < 0.1 then
			return
		end
		Build.part({
			name = "Rail",
			size = Vector3.new(0.35, 0.35, length),
			cframe = CFrame.lookAt(from + delta * 0.5 + Vector3.new(0, height * 0.7, 0), to + Vector3.new(0, height * 0.7, 0)),
			color = color,
			material = Enum.Material.Wood,
			canCollide = false,
			castShadow = false,
			parent = parent,
		})
	end

	local corners = {
		Vector3.new(minX, 0, minZ),
		Vector3.new(maxX, 0, minZ),
		Vector3.new(maxX, 0, maxZ),
		Vector3.new(minX, 0, maxZ),
	}
	for index, corner in corners do
		local nextCorner = corners[index % #corners + 1]
		rail(corner, nextCorner)

		local delta = nextCorner - corner
		local length = delta.Magnitude
		local posts = math.max(math.floor(length / spacing), 1)
		for step = 0, posts - 1 do
			local at = corner + delta * (step / posts)
			Build.part({
				name = "Post",
				size = Vector3.new(0.5, height, 0.5),
				cframe = CFrame.new(at + Vector3.new(0, height * 0.5, 0)),
				color = color,
				material = Enum.Material.Wood,
				canCollide = false,
				castShadow = false,
				parent = parent,
			})
		end
	end
end

return Build
