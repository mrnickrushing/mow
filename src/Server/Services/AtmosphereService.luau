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

local AtmosphereService = {}

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
	-- Late afternoon, sun low enough to throw long shadows across the lawn.
	Lighting.ClockTime = 16.9
	Lighting.GeographicLatitude = 24
	Lighting.Brightness = 2.6
	Lighting.ExposureCompensation = 0.18
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
	Lighting.FogStart = 180
	Lighting.FogEnd = 1400

	-- The haze is what turns the horizon amber and hides the edge of the lot.
	local atmosphere: Atmosphere = child("Atmosphere", "MowAtmosphere", Lighting)
	atmosphere.Density = 0.38
	atmosphere.Offset = 0.28
	atmosphere.Color = Palette.color(Palette.sky.fog)
	atmosphere.Decay = Palette.color(Palette.rgb(196, 116, 58))
	atmosphere.Glare = 0.45
	atmosphere.Haze = 2.4

	-- No Sky object on purpose. One with blank skybox textures renders black,
	-- and Roblox's own procedural sky at this hour, seen through the atmosphere
	-- above, already gives the amber gradient we are after.
	local staleSky = Lighting:FindFirstChildOfClass("Sky")
	if staleSky then
		staleSky:Destroy()
	end

	-- Pushes everything towards the saturated storybook look rather than the
	-- washed-out default, which is most of the difference at a glance.
	local grade: ColorCorrectionEffect = child("ColorCorrectionEffect", "MowGrade", Lighting)
	grade.Brightness = 0.02
	grade.Contrast = 0.16
	grade.Saturation = 0.28
	grade.TintColor = Palette.color(Palette.rgb(255, 240, 224))
	grade.Enabled = true

	local bloom: BloomEffect = child("BloomEffect", "MowBloom", Lighting)
	bloom.Intensity = 0.55
	bloom.Size = 22
	bloom.Threshold = 1.4
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

return AtmosphereService
