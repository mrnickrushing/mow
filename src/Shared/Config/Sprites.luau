--!strict
--[[
	Sprites — the flat images the game draws, as opposed to the models.

	There is one, and it earns its own file rather than squatting in the mesh
	catalogue: a particle needs a picture, not a model, and `Props` is meshes.

	The sprinkler used to spray Roblox's default particle texture. It looked
	passable, which is exactly why it survived several passes of replacing
	everything else — it is still the engine's art rather than this game's, and
	it is the same soft blob every other Roblox game sprays. This one is drawn
	for the job: a round droplet with a bright rim and a highlight up and to the
	left, where this game's sun is.
]]

local Sprites = {}

export type Sprite = {
	id: string,
}

local sprites: { [string]: Sprite } = {
	WaterDroplet = { id = "rbxassetid://122928242511273" },
}

Sprites.all = sprites

--- The sprite by name, or nil when nothing answers to it.
function Sprites.get(name: string): Sprite?
	return sprites[name]
end

return Sprites
