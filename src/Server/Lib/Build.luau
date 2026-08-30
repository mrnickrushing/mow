--!strict
--[[
	Build — small helpers for assembling the world out of parts.

	Everything the player walks on is generated at runtime from the tables in
	Worlds, so there is no hand-built map to keep in sync with the config.
]]

local Palette = require(game:GetService("ReplicatedStorage").Shared.Config.Palette)
local Props = require(game:GetService("ReplicatedStorage").Shared.Config.Props)

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

export type MeshOptions = {
	--- A key in the Props catalogue.
	prop: string,
	name: string?,
	--- How big the prop should end up in the world.
	size: Vector3,
	cframe: CFrame,
	--- Collision box, when the prop should be solid to something smaller or
	--- larger than it looks. Defaults to `size`.
	collisionSize: Vector3?,
	color: Color3?,
	transparency: number?,
	canCollide: boolean?,
	castShadow: boolean?,
	parent: Instance?,
}

--[[
	A prop from the catalogue, rendered at the size you ask for.

	The part underneath stays a plain box because that is what the physics and
	the proximity prompts want; the mesh hanging on it is what anybody actually
	sees. `SpecialMesh` ignores the part's size and renders at its own, so the
	scale is worked out here from the mesh's native size — ask for a four-stud
	bin and you get a four-stud bin whatever the artist exported.

	Falls back to a plain coloured part when a prop name is unknown, so a typo
	costs a nice model rather than a missing object in the middle of the lawn.
]]
function Build.mesh(options: MeshOptions): Part
	local def = Props.get(options.prop)
	local part = Build.part({
		name = options.name or options.prop,
		size = options.collisionSize or options.size,
		cframe = options.cframe,
		color = options.color or (def and def.color) or Color3.fromRGB(255, 255, 255),
		material = Enum.Material.SmoothPlastic,
		-- A part carrying a file mesh renders as that mesh rather than as a
		-- box, and transparency applies to the mesh too, so it stays opaque.
		transparency = options.transparency or 0,
		canCollide = options.canCollide,
		castShadow = options.castShadow,
		parent = options.parent,
	})

	if not def then
		return part
	end

	-- The box is only there for collision; the mesh carries the look, so it is
	-- drawn opaque even though the part beneath it is invisible.
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.FileMesh
	mesh.MeshId = def.mesh
	if def.texture then
		mesh.TextureId = def.texture
	end
	mesh.Scale = Vector3.new(
		options.size.X / def.native.X,
		options.size.Y / def.native.Y,
		options.size.Z / def.native.Z
	)
	mesh.Parent = part

	return part
end

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
		-- The lap course is a siding model rather than a painted slab. It is
		-- stretched along the wall rather than tiled, which costs one part
		-- instead of sixty and keeps the lap lines horizontal, because that is
		-- the direction they run in.
		Build.mesh({
			prop = "Siding",
			name = "Board",
			size = Vector3.new(
				math.abs(along.X) * width + math.abs(facing.X) * thickness,
				boardHeight * 0.94,
				math.abs(along.Z) * width + math.abs(facing.Z) * thickness
			),
			cframe = CFrame.new(Vector3.new(centre.X, y, centre.Z)),
			color = Palette.color(shade),
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

	--[[
		Fence panels, not a palisade of little boxes.

		This used to be one box per picket plus a wedge cap on each, which is a
		great many rectangles to say "fence" and still read as a row of blocks.
		One panel model per section says it in a single mesh.
	]]
	local direction = delta.Unit
	local panelWidth = 5
	local count = math.max(math.floor(length / panelWidth + 0.5), 1)
	local span = length / count

	for index = 0, count - 1 do
		local at = from + direction * (span * (index + 0.5))
		Build.mesh({
			prop = "Fence",
			name = "Picket",
			size = Vector3.new(span + 0.2, height, 0.6),
			collisionSize = Vector3.new(span, height, 0.6),
			cframe = CFrame.lookAt(
				at + Vector3.new(0, height * 0.5, 0),
				at + direction + Vector3.new(0, height * 0.5, 0)
			) * CFrame.Angles(0, math.rad(90), 0),
			-- Solid, so the fence is the edge of the property rather than a
			-- picture of one. It was built from non-colliding pickets, which
			-- let a player walk straight through the boundary, across the
			-- apron and off the end of the world. Panels are cheap enough to
			-- collide now that there is one every five studs instead of one
			-- every one and a half.
			castShadow = false,
			parent = folder,
		})
	end

	for _, ratio in { 0.32, 0.72 } do
		local mid = from + direction * (length * 0.5) + Vector3.new(0, height * ratio, 0)
		Build.mesh({
		prop = "Railing",
			name = "Rail",
			size = Vector3.new(0.55, 0.7, length),
			cframe = CFrame.lookAt(mid, mid + direction),
			color = Palette.color(Palette.fence.rail),
			canCollide = false,
			castShadow = false,
			parent = folder,
		})
	end

	--[[
		No lattice.

		The crosshatch above the pickets was a hundred and ninety-two little
		boxes turned forty-two degrees, which is a great deal of geometry to
		spend on a decoration that now sits on top of a fence model that already
		looks like a fence. The argument stays so the callers do not have to
		change, and taller runs simply build a taller panel.
	]]
	if lattice then
		for _, panel in folder:GetChildren() do
			if panel:IsA("BasePart") then
				local mesh = panel:FindFirstChildOfClass("SpecialMesh")
				if mesh then
					mesh.Scale = Vector3.new(mesh.Scale.X, mesh.Scale.Y * 1.35, mesh.Scale.Z)
					panel.Size = Vector3.new(panel.Size.X, panel.Size.Y * 1.35, panel.Size.Z)
				end
			end
		end
	end

	return folder
end

--[[
	Text with every letter its own colour.

	Used for the headline items in the shed. It is deliberately loud: the point
	of a shop display is to be the brightest thing in the room.
]]
function Build.rainbowText(parent: Instance, text: string, size: UDim2, position: UDim2, scale: number): TextLabel
	local hues = {
		"#FF5A4E", "#FF9B32", "#FFD23F", "#7ED957",
		"#4EC3F0", "#7B6CF6", "#E85AC8",
	}
	local pieces = {}
	local index = 0
	for character in text:gmatch(utf8.charpattern) do
		if character == " " then
			table.insert(pieces, " ")
		else
			index += 1
			table.insert(pieces, `<font color="{hues[(index % #hues) + 1]}">{character}</font>`)
		end
	end

	local label = Build.label(parent, table.concat(pieces), size, position, scale)
	label.TextStrokeTransparency = 0.1
	return label
end

--- A blocky hedge, the green wall that borders most of the reference's yards.
function Build.hedge(parent: Instance, from: Vector3, to: Vector3, height: number, depth: number): Folder
	local folder = Build.folder("Hedge", parent)
	local delta = to - from
	local length = delta.Magnitude
	if length < 1 then
		return folder
	end

	local direction = delta.Unit
	local blocks = math.max(math.floor(length / 6), 1)
	for index = 0, blocks - 1 do
		local at = from + direction * (length * (index + 0.5) / blocks)
		-- Slight per-block variation, so the hedge does not read as one extrusion.
		local wobble = ((index % 3) - 1) * 0.6
		Build.mesh({
			prop = "Hedge",
			name = "Hedge",
			size = Vector3.new(length / blocks + 1.2, height + wobble, depth + 1),
			collisionSize = Vector3.new(length / blocks + 0.6, height + wobble, depth),
			cframe = CFrame.lookAt(
				at + Vector3.new(0, (height + wobble) * 0.5, 0),
				at + direction + Vector3.new(0, (height + wobble) * 0.5, 0)
			) * CFrame.Angles(0, math.rad(90), 0),
			parent = folder,
		})
	end
	return folder
end

--- A brick retaining wall topped with chain-link, as along the reference's court.
function Build.chainLinkWall(parent: Instance, from: Vector3, to: Vector3, brickHeight: number, meshHeight: number): Folder
	local folder = Build.folder("CourtWall", parent)
	local delta = to - from
	local length = delta.Magnitude
	if length < 1 then
		return folder
	end

	local direction = delta.Unit
	local mid = from + direction * (length * 0.5)

	Build.mesh({
		prop = "BrickWall",
		name = "Retaining",
		size = Vector3.new(2.2, brickHeight, length),
		cframe = CFrame.lookAt(mid + Vector3.new(0, brickHeight * 0.5, 0), mid + direction + Vector3.new(0, brickHeight * 0.5, 0)),
		color = Palette.color(Palette.house.brick),
		parent = folder,
	})

	-- The mesh itself: a translucent dark panel plus posts, which reads as
	-- chain-link at play distance without thousands of wire parts.
	Build.mesh({
		prop = "Bush",
		name = "Mesh",
		size = Vector3.new(0.4, meshHeight, length),
		cframe = CFrame.lookAt(
			mid + Vector3.new(0, brickHeight + meshHeight * 0.5, 0),
			mid + direction + Vector3.new(0, brickHeight + meshHeight * 0.5, 0)
		),
		color = Palette.color(Palette.rgb(58, 84, 58)),
		transparency = 0.45,
		canCollide = false,
		castShadow = false,
		parent = folder,
	})

	local posts = math.max(math.floor(length / 14), 1)
	for index = 0, posts do
		local at = from + direction * (length * index / posts)
		Build.mesh({
		prop = "Column",
			name = "Post",
			size = Vector3.new(0.9, meshHeight + 1, 0.9),
			cframe = CFrame.new(at + Vector3.new(0, brickHeight + (meshHeight + 1) * 0.5, 0)),
			color = Palette.color(Palette.rgb(72, 96, 72)),
			canCollide = false,
			castShadow = false,
			parent = folder,
		})
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
			-- A flagstone, not a square of grey. Two hundred and thirty of
			-- these make every path in the game, so being a real stone
			-- matters more here than almost anywhere else.
			Build.mesh({
				prop = "Paving",
				name = "Slab",
				size = Vector3.new(tile * 0.98, 0.5, tile * 0.98),
				collisionSize = Vector3.new(tile * 0.92, 0.5, tile * 0.92),
				cframe = CFrame.new(
					centre.X - size.X * 0.5 + tile * (col + 0.5) + jitterX,
					centre.Y,
					centre.Z - size.Y * 0.5 + tile * (row + 0.5) + jitterZ
				) * CFrame.Angles(0, rng:NextNumber() * 0.12, 0),
				color = Palette.color(shade),
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
	--[[
		The boundary of a lot, in fence panels.

		This used to be a thin rail plus one thin post every few studs — a
		hundred and sixty-four little boxes standing in for a fence, and the
		only thing left in the Gas Station that still looked like scaffolding.
		Panels are the same model the picket boundary uses.
	]]
	local function run(from: Vector3, to: Vector3)
		local delta = to - from
		local length = delta.Magnitude
		if length < 1 then
			return
		end
		local direction = delta.Unit
		local count = math.max(math.floor(length / spacing + 0.5), 1)
		local span = length / count

		for index = 0, count - 1 do
			local at = from + direction * (span * (index + 0.5))
			Build.mesh({
				prop = "Fence",
				name = "Picket",
				size = Vector3.new(span + 0.2, height, 0.6),
				collisionSize = Vector3.new(span, height, 0.6),
				cframe = CFrame.lookAt(
					at + Vector3.new(0, height * 0.5, 0),
					at + direction + Vector3.new(0, height * 0.5, 0)
				) * CFrame.Angles(0, math.rad(90), 0),
				castShadow = false,
				parent = parent,
			})
		end
	end

	local corners = {
		Vector3.new(minX, 0, minZ),
		Vector3.new(maxX, 0, minZ),
		Vector3.new(maxX, 0, maxZ),
		Vector3.new(minX, 0, maxZ),
	}
	for index, corner in corners do
		run(corner, corners[index % #corners + 1])
	end
end

return Build
