--!strict
--[[
	AtmosphereService — the amber autumn afternoon.

	More of the reference look comes from lighting than from geometry: a low warm
	sun, heavy orange haze, a saturating colour grade and big soft cartoon
	clouds. Get this wrong and the most detailed house in the world still reads
	as the wrong game.

	Applied on the server so it replicates to everyone and survives a rejoin.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Palette = require(ReplicatedStorage:WaitForChild("Shared").Config.Palette)
local Types = require(ReplicatedStorage:WaitForChild("Shared").Types)

local AtmosphereService = {}

--[[
	The haze is tuned for a lot this many tiles across.

	Every number below it was chosen by eye on The House, which is ninety-six
	tiles square, and on that lot it is right: the far fence sits in amber and
	the edge of the world is hidden, which is the whole job of it.

	The Mansion is a hundred and forty-four tiles across — half again as far in
	every direction — and the same haze put its far half behind a wall of
	orange. Six acres you cannot see across do not read as six acres; they read
	as a small garden in bad weather.

	So the haze thins in proportion to the lot rather than being a constant. The
	House is unchanged by definition, being the size this was tuned at.
]]
local TUNED_FOR_TILES = 96

local function child<T>(className: string, name: string, parent: Instance): T
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing :: any
	end
	local created = Instance.new(className :: any)
	created.Name = name
	created.Parent = parent
	return created :: any
end

function AtmosphereService.start()
	--[[
		Afternoon, with the sun on the front of the house.

		These were 16.9 and 24, chosen for the length of the shadows, and the
		shadow they threw longest was the one over everything the player looks
		at. Measured, that sun points (-0.96, 0.28, 0.01): every property in
		this game is entered from the road at low Z and faces the player back
		down it, so every building's frontage has a normal of (0, 0, -1) — and
		the light landing on that face came to `max(-0.01, 0)`, which is
		nothing at all. The House's cream siding, its teal trim, the Mansion's
		limestone and its portico were all lit by ambient alone and read as
		flat grey slabs, whatever colour they had been painted.

		A southern latitude swings the sun's arc round to the near side of the
		sky. At -30 and quarter past three it points (-0.44, 0.40, -0.80):
		four fifths of full strength on the frontages, a little under half on
		the side walls — so a building has a lit face and a shaded one, which
		is what makes it read as solid — and enough height left for the
		shadows on the lawn to still be long.
	]]
	Lighting.ClockTime = 15.2
	Lighting.GeographicLatitude = -30
	Lighting.Brightness = 2.2
	Lighting.ExposureCompensation = 0.05
	Lighting.Ambient = Palette.color(Palette.sky.ambient)
	Lighting.OutdoorAmbient = Palette.color(Palette.sky.outdoorAmbient)
	Lighting.ColorShift_Top = Palette.color(Palette.sky.tint)
	Lighting.ColorShift_Bottom = Palette.color(Palette.sky.fog)
	Lighting.EnvironmentDiffuseScale = 0.6
	Lighting.EnvironmentSpecularScale = 0.3
	Lighting.GlobalShadows = true
	-- Technology is not scriptable at runtime (writing it throws "lacking
	-- capability RobloxScript" and aborts the whole server boot). It is set to
	-- ShadowMap once, in default.project.json, where Studio can apply it.
	Lighting.FogColor = Palette.color(Palette.sky.fog)

	-- The haze is what turns the horizon amber and hides the edge of the lot.
	local atmosphere: Atmosphere = child("Atmosphere", "MowAtmosphere", Lighting)
	atmosphere.Offset = 0.28
	atmosphere.Color = Palette.color(Palette.sky.fog)
	atmosphere.Decay = Palette.color(Palette.rgb(196, 116, 58))
	atmosphere.Glare = 0.45

	-- Depth is per-world; until one loads, the lot this was tuned on.
	AtmosphereService.applyWorld(nil)

	-- No Sky object on purpose. One with blank skybox textures renders black,
	-- and Roblox's own procedural sky at this hour, seen through the atmosphere
	-- above, already gives the amber gradient we are after.
	local staleSky = Lighting:FindFirstChildOfClass("Sky")
	if staleSky then
		staleSky:Destroy()
	end

	--[[
		A nudge towards the storybook look, not a shove.

		This was saturation at plus a quarter and contrast at plus a sixth, on
		top of a palette that is already vivid and an exposure lifted by a
		fifth. Everything on screen came out at the top of its channel: the
		lawn was fluorescent, the paths were neon, and the leaves were a single
		flat red with no shading left in them to tell one from the next. A
		picture with nothing between the brightest thing in it and the second
		brightest has no depth, and that reads as cheap however good the models
		are. Backed off far enough to leave the palette room to be seen.
	]]
	local grade: ColorCorrectionEffect = child("ColorCorrectionEffect", "MowGrade", Lighting)
	grade.Brightness = 0.0
	grade.Contrast = 0.07
	--[[
		Enough saturation to keep the lawn a lawn.

		Cut to almost nothing when the grade was backed off, which was right
		for the leaves and wrong for the grass: with the light no longer doing
		the saturating, the greens went flat. This sits between the two — the
		palette reads as itself, and nothing is pinned at the top of its
		channel.
	]]
	grade.Saturation = 0.18
	grade.TintColor = Palette.color(Palette.rgb(250, 248, 246))
	grade.Enabled = true

	local bloom: BloomEffect = child("BloomEffect", "MowBloom", Lighting)
	bloom.Intensity = 0.3
	bloom.Size = 20
	bloom.Threshold = 1.7
	bloom.Enabled = true

	local sun: SunRaysEffect = child("SunRaysEffect", "MowSunRays", Lighting)
	sun.Intensity = 0.06
	sun.Spread = 0.42
	sun.Enabled = true

	-- Big, soft, low-lying cloud cover to match the cartoon skyline.
	local clouds: Clouds = child("Clouds", "MowClouds", Workspace.Terrain)
	clouds.Cover = 0.62
	clouds.Density = 0.5
	clouds.Color = Palette.color(Palette.sky.cloud)
	clouds.Enabled = true
end

--[[
	Sets how far you can see, for the world now loaded.

	Called again on every load, because a run can move between properties of
	very different sizes and the haze has to move with them. `nil` restores the
	tuning lot's own settings, which is what a server sitting in the lobby with
	nothing loaded should look like.
]]
function AtmosphereService.applyWorld(world: Types.WorldDef?)
	local tiles = if world then math.max(world.gridWidth, world.gridDepth) else TUNED_FOR_TILES
	-- Never thicker than the tuning, only thinner: a world smaller than The
	-- House should not end up in a fog bank.
	local reach = math.max(tiles / TUNED_FOR_TILES, 1)

	Lighting.FogStart = 180 * reach
	Lighting.FogEnd = 1400 * reach

	local atmosphere = Lighting:FindFirstChild("MowAtmosphere")
	if atmosphere and atmosphere:IsA("Atmosphere") then
		atmosphere.Density = 0.38 / reach
		atmosphere.Haze = 2.4 / reach
	end
end

return AtmosphereService
