--!strict
--[[
	Build — small helpers for assembling the world out of parts.

	Everything the player walks on is generated at runtime from the tables in
	Worlds, so there is no hand-built map to keep in sync with the config.
]]

local RunService = game:GetService("RunService")

local Palette = require(game:GetService("ReplicatedStorage").Shared.Config.Palette)
local Audio = require(game:GetService("ReplicatedStorage").Shared.Config.Audio)
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
	--[[
		Drop the prop's texture and take the colour from `color` instead.

		A tint multiplies a texture, so it can move a hue but can never take
		one out: the paving model is painted a strong orange, and asking for
		grey stone gave orange stone, because grey multiplied into orange is
		orange. Every path in the game was a bright orange one for that reason.
		Without the texture the model is a flat colour, which is what a
		storybook prop wants anyway.
	]]
	untextured: boolean?,
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
--[[
	How far a model may be scaled up before its texture stops being a texture.

	A `SpecialMesh` texture does not repeat when the mesh is scaled, it
	stretches, so a model of a surface drawn at four times its own size is a
	model of that surface with everything on it four times too big. Past this
	it stops reading as the thing it is a picture of: a shingle panel became a
	chequerboard, lap siding became a barcode, a garage door became a salmon
	rectangle with three lines on it, and a seven stud turf panel over a whole
	property became bands forty studs wide.

	Every one of those shipped, and none of them was noticed from the source,
	because a call asking for a hundred-and-eighty stud wall looks perfectly
	reasonable next to a prop table you are not reading at the same time. So it
	says so, out loud, while the world is being built.
]]
local MAX_STRETCH = 4.5

--[[
	Says so when a prop is being asked to cover more than it can.

	Studio only. This is a note to whoever is building the world, not something
	a player's server should spend its output on, and by the time a place is
	published every one of these has either been fixed or deliberately kept.
]]
local function warnIfStretched(options: MeshOptions, scale: Vector3)
	if not RunService:IsStudio() then
		return
	end
	local worst = math.max(scale.X, scale.Y, scale.Z)
	if worst <= MAX_STRETCH then
		return
	end
	warn(string.format(
		"[Build] %s (%s) is drawn at %.0fx its own size — its texture will stretch, not tile. "
			.. "A surface this size wants a plain part with a material.",
		options.name or options.prop,
		options.prop,
		worst
	))
end

function Build.mesh(options: MeshOptions): Part
	local def = Props.get(options.prop)
	--[[
		The colour the caller asked for, if any.

		Kept separately from the part's own colour because of what happens
		below: a textured mesh pays no attention to the colour of the part it
		hangs on, so for most of this world `color = ...` was doing nothing at
		all. Thirty-five of the sixty-three places that build a mesh name a
		palette colour, and every one of them was silently ignored — which is
		why the orangery's ceiling was a teal and pink fan rather than the roof
		colour it asks for.
	]]
	local tint = options.color or (def and def.color)
	local part = Build.part({
		name = options.name or options.prop,
		size = options.collisionSize or options.size,
		cframe = options.cframe,
		color = tint or Color3.fromRGB(255, 255, 255),
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
	if def.texture and not options.untextured then
		mesh.TextureId = def.texture
	end
	local scale = Vector3.new(
		options.size.X / def.native.X,
		options.size.Y / def.native.Y,
		options.size.Z / def.native.Z
	)
	mesh.Scale = scale
	warnIfStretched(options, scale)

	--[[
		Stand the model on the same ground as the box under it.

		A `SpecialMesh` is centred on its part, so when the collision box is
		shorter than the model it draws — which is the whole point of passing a
		`collisionSize` — the model sinks by half the difference. The riding
		mower was the loud case: a box two and a half studs tall carrying a
		six-stud mower, so a third of it was underground and it read as a red
		puddle rather than a machine you sit on.

		Lifting the mesh by half the difference puts the two bases on the same
		plane. Where the heights already agree, which is most callers, this is
		zero and nothing moves.
	]]
	local collision = options.collisionSize
	if collision then
		mesh.Offset = Vector3.new(0, (options.size.Y - collision.Y) * 0.5, 0)
	end

	--[[
		The tint goes on the mesh, and only when there is a texture to tint.

		`VertexColor` multiplies the texture rather than replacing it, so it is
		normalised to its brightest channel first: a mid-tone palette colour
		multiplied straight through would come out as mud, which is not what
		"paint this roof the roof colour" means. Normalised, it carries the hue
		and leaves the texture's own light and shade alone.

		An untextured mesh is left to the part's colour, which it does honour —
		tinting there as well would apply the same colour twice.
	]]
	if tint and mesh.TextureId ~= "" then
		local brightest = math.max(tint.R, tint.G, tint.B, 0.001)
		mesh.VertexColor = Vector3.new(tint.R, tint.G, tint.B) / brightest
	end

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

	--[[
		A lap course is painted, not modelled.

		It used to be the siding model stretched the length of the wall, which
		the comment here defended as costing one part instead of sixty. It did,
		and the part it cost was the house: that model's texture is a course of
		blocks about two and a half studs wide, and a texture does not repeat
		when a mesh is scaled, it stretches. On The House's hundred-and-eighty
		stud frontage every block came out a hundred and eighty studs long, so
		the wall was five flat bands of alternating cream and tan — a barcode,
		from every angle, at every distance.

		Lap siding really is horizontal bands, so the courses were never the
		problem and the part count stays exactly what it was. Each course is
		simply a plain part now, and the lap line comes from geometry instead
		of from a picture: alternate courses stand a little further out, so the
		lip of each casts a real shadow on the one below in the low sun this
		game is lit by.
	]]
	for index = 0, boards - 1 do
		local y = centre.Y - size.Y * 0.5 + boardHeight * (index + 0.5)
		-- Barely apart: the shadow line does the describing, and two shades a
		-- long way apart is what made the barcode read as stripes.
		local shade = if index % 2 == 0 then Palette.house.siding else Palette.house.sidingShade
		local proud = if index % 2 == 0 then thickness else thickness * 0.7
		Build.part({
			name = "Board",
			size = Vector3.new(
				math.abs(along.X) * width + math.abs(facing.X) * proud,
				boardHeight * 0.98,
				math.abs(along.Z) * width + math.abs(facing.Z) * proud
			),
			cframe = CFrame.new(Vector3.new(centre.X, y, centre.Z)),
			color = Palette.color(shade),
			material = Enum.Material.SmoothPlastic,
			parent = folder,
		})
	end

	return folder
end

--[[
	A pitched roof with overhanging eaves and a gable at each end.

	Every roof in the game was one flat slab carrying the shingle model
	stretched across it. Two things were wrong with that and they compounded:
	the model's texture is a panel of shingles about a stud across, so scaled to
	a sixty by a hundred and eighty stud roof it became a coarse green
	chequerboard visible from the far end of the property — and a flat slab has
	no roofline at all, so the building underneath read as a shed however good
	its walls were.

	The slope is what makes a house look like a house from across a lawn, so it
	is built as geometry: two sloped faces meeting at a ridge, wedges closing
	the triangle at each end, and the eaves standing proud of the walls so the
	building throws a shadow onto its own siding.

	`run` is measured from the ridge to the eave along the short axis, which is
	the axis the roof slopes down. `rise` is how far the ridge stands above the
	eaves — together they set the pitch.
]]
function Build.gableRoof(
	parent: Instance,
	centre: Vector3,
	width: number,
	depth: number,
	eaveY: number,
	rise: number,
	overhang: number,
	color: Color3,
	trimColor: Color3,
	wallColor: Color3
): Folder
	local folder = Build.folder("Roof", parent)

	-- The ridge runs along whichever axis is longer, because a house is not
	-- roofed across its length.
	local alongX = width >= depth
	local span = if alongX then depth else width
	local ridgeLength = (if alongX then width else depth) + overhang * 2
	local run = span * 0.5 + overhang
	local slope = math.sqrt(run * run + rise * rise)
	local pitch = math.atan2(rise, run)
	local thickness = 1.6

	for _, side in { -1, 1 } do
		-- Centre of a sloped face sits half way up the rise and half way out
		-- along the run, tilted so its long edge lands on the eave.
		local midOut = side * run * 0.5
		local position = centre + Vector3.new(
			if alongX then 0 else midOut,
			eaveY + rise * 0.5,
			if alongX then midOut else 0
		)
		local turn = if alongX
			then CFrame.Angles(side * pitch, 0, 0)
			else CFrame.Angles(0, 0, -side * pitch)
		Build.part({
			name = "Pitch",
			size = if alongX
				then Vector3.new(ridgeLength, thickness, slope)
				else Vector3.new(slope, thickness, ridgeLength),
			cframe = CFrame.new(position) * turn,
			color = color,
			material = Enum.Material.Slate,
			parent = folder,
		})
	end

	--[[
		The triangle of wall between the two slopes at each end.

		Without it you can see straight through the roof into the house from
		either end, which is the one angle a flat slab never gave away. Two
		right-angled wedges back to back make the isosceles triangle a gable
		actually is.
	]]
	local gableHalf = span * 0.5
	for _, end_ in { -1, 1 } do
		for _, half in { -1, 1 } do
			local wedge = Instance.new("WedgePart")
			wedge.Name = "Gable"
			wedge.Anchored = true
			wedge.CanCollide = true
			wedge.Color = wallColor
			wedge.Material = Enum.Material.SmoothPlastic
			wedge.TopSurface = Enum.SurfaceType.Smooth
			wedge.BottomSurface = Enum.SurfaceType.Smooth
			wedge.Size = Vector3.new(1.2, rise, gableHalf)
			-- A wedge slopes down along +Z from its top edge, so the half that
			-- falls away from the ridge is turned to face outward.
			local outward = if alongX then Vector3.new(end_ * (width * 0.5), 0, 0) else Vector3.new(0, 0, end_ * (depth * 0.5))
			local sideways = if alongX
				then Vector3.new(0, 0, half * gableHalf * 0.5)
				else Vector3.new(half * gableHalf * 0.5, 0, 0)
			--[[
				A wedge spans its own Z and slopes down along it, so it only
				needs turning when the gable it fills spans world X instead.

				This had the test the wrong way round, which turned each gable
				a quarter of the way round its own centre: instead of closing
				the triangle at the end of the roof they stood across it, and
				every house had two teal fins sticking out into the air above
				its eaves.
			]]
			local spin = if alongX then 0 else math.pi * 0.5
			wedge.CFrame = CFrame.new(centre + outward + sideways + Vector3.new(0, eaveY + rise * 0.5, 0))
				* CFrame.Angles(0, spin + (if half > 0 then 0 else math.pi), 0)
			wedge.Parent = folder
		end
	end

	--- A capping board along the ridge, which is what stops the two faces
	--- meeting in a visible seam.
	Build.part({
		name = "Ridge",
		size = if alongX
			then Vector3.new(ridgeLength, 1.1, 2.2)
			else Vector3.new(2.2, 1.1, ridgeLength),
		cframe = CFrame.new(centre + Vector3.new(0, eaveY + rise + 0.3, 0)),
		color = trimColor,
		material = Enum.Material.SmoothPlastic,
		parent = folder,
	})

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
		-- A rail is a bar. The railing model squashed to half a stud wide and
		-- drawn out the length of a run is not a railing, it is its texture
		-- smeared along a stick.
		Build.part({
			name = "Rail",
			size = Vector3.new(0.55, 0.7, length),
			cframe = CFrame.lookAt(mid, mid + direction),
			color = Palette.color(Palette.fence.rail),
			material = Enum.Material.WoodPlanks,
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
		--[[
			Per-block variation, so the hedge does not read as one extrusion.

			The height wobble was already here and was not enough on its own:
			every block faced the same way, so the leaf texture landed in the
			same place on each and a hedge came out as a row of identical
			panels — a green chequerboard the length of the run. Turning each
			block a different way costs nothing and is what breaks the repeat,
			because it is the repeat rather than the shape that gives it away.
		]]
		local wobble = ((index % 3) - 1) * 0.6
		--[[
			Only a half turn and a few degrees either side of it, though. A
			block is longer along the run than it is thick, so turning one a
			quarter of the way round would stand it across the hedge and open
			a gap in the wall it is part of. A half turn leaves the footprint
			exactly where it was and still lands the texture somewhere else.
		]]
		local flip = if index % 2 == 0 then 0 else math.pi
		local spin = math.rad(90) + flip + (((index * 37) % 13) / 13 - 0.5) * math.rad(16)
		Build.mesh({
			prop = "Hedge",
			name = "Hedge",
			size = Vector3.new(length / blocks + 1.2, height + wobble, depth + 1),
			collisionSize = Vector3.new(length / blocks + 0.6, height + wobble, depth),
			cframe = CFrame.lookAt(
				at + Vector3.new(0, (height + wobble) * 0.5, 0),
				at + direction + Vector3.new(0, (height + wobble) * 0.5, 0)
			) * CFrame.Angles(0, spin, 0),
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

	Build.part({
		name = "Retaining",
		size = Vector3.new(2.2, brickHeight, length),
		cframe = CFrame.lookAt(mid + Vector3.new(0, brickHeight * 0.5, 0), mid + direction + Vector3.new(0, brickHeight * 0.5, 0)),
		color = Palette.color(Palette.house.brick),
		material = Enum.Material.Brick,
		parent = folder,
	})

	--[[
		The mesh itself: a translucent dark panel plus posts, which reads as
		chain-link at play distance without thousands of wire parts.

		The panel used to be the bush model — a cylinder of leaves — squashed
		to two fifths of a stud thick and pulled the length of the run, so the
		top of every retaining wall in the game had a strip of flattened
		shrubbery along it. A plain panel in metal is both what was intended
		and what it now is.
	]]
	Build.part({
		name = "Mesh",
		size = Vector3.new(0.4, meshHeight, length),
		cframe = CFrame.lookAt(
			mid + Vector3.new(0, brickHeight + meshHeight * 0.5, 0),
			mid + direction + Vector3.new(0, brickHeight + meshHeight * 0.5, 0)
		),
		color = Palette.color(Palette.rgb(58, 84, 58)),
		material = Enum.Material.Metal,
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
				-- Flat stone colour rather than the model's own orange paint.
				untextured = true,
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

--[[
	A noise that belongs to a place.

	Parented to a part, a `Sound` is heard from where that part is and fades as
	you walk away, which is the whole difference between this and the cues the
	client plays flat in your own ears. A tree coming down should carry across
	the lawn and a sprinkler should not be audible from the road.

	Returns the sound so the caller can start, stop or re-pitch it — a sprinkler
	holds on to its loop and turns it on and off with the water.
]]
function Build.sound(parent: BasePart, cueName: string, autoPlay: boolean?): Sound?
	local def = Audio.get(cueName)
	if not def then
		return nil
	end

	--[[
		One sound per cue per part, replayed rather than replaced.

		A tree takes twelve chops to fell and a stump three grinds, and each of
		those used to hang another `Sound` on the same part — a dozen instances
		on one trunk, all identical, none of them ever collected until the tree
		itself was destroyed. Playing an already-playing sound restarts it from
		the top, which is exactly what a second chop should sound like.
	]]
	local existing = parent:FindFirstChild(cueName)
	if existing and existing:IsA("Sound") then
		if autoPlay then
			existing:Play()
		end
		return existing
	end

	local sound = Instance.new("Sound")
	sound.Name = cueName
	sound.SoundId = def.id
	sound.Volume = def.volume
	sound.Looped = def.looped == true
	sound.PlaybackSpeed = def.speed or 1
	-- Rolls off over the cue's own range, so a chop and a falling tree can
	-- carry different distances without every caller repeating the numbers.
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMaxDistance = def.range or 80
	sound.RollOffMinDistance = 8
	sound.Parent = parent

	if autoPlay then
		sound:Play()
	end
	return sound
end

--[[
	Plays a one-shot at a point and cleans up after itself.

	A felled tree is destroyed a moment after it lands, and a sound goes with
	the instance it hangs on — so the noise of it landing needs somewhere to
	live that outlasts the thing that made it.
]]
function Build.soundAt(position: Vector3, cueName: string, parent: Instance)
	local def = Audio.get(cueName)
	if not def then
		return
	end

	local anchor = Instance.new("Part")
	anchor.Name = `Sound_{cueName}`
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = parent

	local sound = Build.sound(anchor, cueName, true)
	local life = if sound then sound.TimeLength + 0.5 else 3
	game:GetService("Debris"):AddItem(anchor, math.max(life, 3))
end

return Build
