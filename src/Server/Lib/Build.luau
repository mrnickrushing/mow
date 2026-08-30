--!strict
--[[
	Build — small helpers for assembling the world out of parts.

	Everything the player walks on is generated at runtime from the tables in
	Properties, so there is no hand-built map to keep in sync with the config.
]]

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
