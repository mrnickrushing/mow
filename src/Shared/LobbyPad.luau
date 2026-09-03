--!strict
--[[
	LobbyPad — the one answer to "is this player standing on that pad?"

	The client opens the settings panel when you step onto a pad; the server
	decides which game you joined, and refuses a Confirm that did not come
	from one. Both were answering the same question, separately, and they did
	not agree:

	  server   a square of half-extent (size/2 + 1), and a height check
	  client   a circle of radius (size/2 + 2), and no height check at all

	On a 24-stud pad that is a square reaching 13 against a circle reaching
	14. Stand 13.5 studs from the middle and the panel opens, you press the
	green Confirm, and the server answers "Stand on a pad to set a game up"
	while you are plainly standing on one. Climb anything tall near a pad and
	the panel opens over a game you cannot join.

	Sharing the prefix was half of this fix and it already shipped; sharing
	the shape is the other half. The core takes numbers so the tests can hold
	it to the corners without a running Roblox.
]]

local GameConfig = require(script.Parent.Config.GameConfig)

local LobbyPad = {}

--- Distance between neighbouring pad centres.
LobbyPad.SPACING = 32
--- How wide a single pad is, corner to corner.
LobbyPad.SPAN = 24
--- Clear grass kept between the outermost pad and the hedge line beside it.
LobbyPad.FLANK_CLEARANCE = 10

--[[
	How far the whole row of pads reaches from the middle of the lobby.

	The scenery either side used to be placed against the lawn's own width
	(`halfW - 34`), which was comfortably outside the pads until the lobby was
	shrunk from 260 studs to 160 and that expression quietly moved the hedge
	rows from 96 studs out to 46 — inside a pad row that reaches 60. Eight
	hedge parts ended up standing in the middle of the first pad and eight in
	the last, burying the only two words in the lobby that say what to do.

	Measuring the flanks off the pads instead means shrinking the lawn again
	cannot walk anything back into them.
]]
function LobbyPad.rowReach(slots: number): number
	return (slots - 1) * 0.5 * LobbyPad.SPACING + LobbyPad.SPAN * 0.5
end

--- The x either side of centre where flanking scenery may start.
function LobbyPad.flankX(slots: number): number
	return LobbyPad.rowReach(slots) + LobbyPad.FLANK_CLEARANCE
end

--- Studs past the pad's own edge that still count as standing on it.
local MARGIN = 1
--- How far above a pad still counts, so a roof nearby is not "on" it.
local MAX_RISE = 12

--- True when this instance name is one of the lobby's game pads.
function LobbyPad.isPad(name: string): boolean
	local prefix = GameConfig.LOBBY_PAD_PREFIX
	return string.sub(name, 1, #prefix) == prefix
end

--[[
	True when a point counts as standing on a pad of this size and place.

	Square rather than round, because the pad is square and its glowing edge
	strips are what a player aims at — a circle would leave the four corners
	looking lit but reading as off.
]]
function LobbyPad.covers(
	padX: number,
	padY: number,
	padZ: number,
	padSizeX: number,
	x: number,
	y: number,
	z: number
): boolean
	local reach = padSizeX * 0.5 + MARGIN
	return math.abs(x - padX) <= reach and math.abs(z - padZ) <= reach and math.abs(y - padY) < MAX_RISE
end

--- The same question asked of a real pad part, so neither side re-derives it.
function LobbyPad.partCovers(pad: BasePart, position: Vector3): boolean
	local at = pad.Position
	return LobbyPad.covers(at.X, at.Y, at.Z, pad.Size.X, position.X, position.Y, position.Z)
end

return LobbyPad
