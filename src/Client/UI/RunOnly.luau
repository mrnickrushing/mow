--!strict
--[[
	RunOnly — chrome that belongs to a run, hidden while you are in the lobby.

	Standing in the lobby, the screen carried a bag reading 25 / 0, a clock
	frozen at 0:00, a rate of "0.02$ / clipping", a crosshair over the grass,
	an eight-slot hotbar holding nothing, and the word PICK UP with nothing to
	pick up. None of it is wrong exactly — it is instrumentation for a run,
	shown to somebody who has not started one — but a screenful of dials all
	reading zero is what a broken game looks like, and it buries the two
	things the lobby actually wants you to read: your money, and the pad.

	Registered elements are hidden until the server says a round is running.

	Deliberately `Visible` on inner frames and never `ScreenGui.Enabled`: the
	opening cutscene hides chrome by switching `Enabled` off and remembering
	what it switched, so anything else touching that same property would be
	turned back on when the story ends.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Remotes)

local RunOnly = {}

local watched: { GuiObject } = {}
--[[
	Registered elements that a second rule is currently keeping down.

	The phone layout drops the objective panel and the rail's captions, and
	`Visible` on those is already owned by this module — a phone that hid one
	would have it handed back the moment the round started. A suppressed
	element is hidden whatever the round is doing.
]]
local suppressed: { [GuiObject]: boolean } = {}
--[[
	The named pieces of chrome, and which of them are currently allowed up.

	The first run brings the HUD in a piece at a time — the completion bar and
	the tool button, then the bag, then the hotbar and the rail, then the rest
	— which needs a way to say "these and no others" from outside the modules
	that build them. `gate` is that: `nil` for the normal state, where every
	piece is allowed, or a set of the names that are.

	Names rather than references because the four steps are written as lists of
	words in one place, and a step that reads `{ "hero", "tool" }` is a step
	somebody can check against the handoff.
]]
local named: { [string]: { GuiObject } } = {}
local nameOf: { [GuiObject]: string } = {}
--[[
	Pieces whose `Visible` this module may set when it is gating.

	Most named chrome is already registered with `add` and hidden in the lobby
	with everything else. Two kinds are not: the rail, which carries the money
	and belongs on screen in the lobby, and the pieces whose visibility the
	HUD's own refresh owns and which therefore have to ask rather than be told.
	The first kind is listed here; the second is not, and asks.
]]
local gated: { [GuiObject]: boolean } = {}
local gate: { [string]: boolean }? = nil
--- Called after the gate changes, for owners whose own rule decides whether a
--- piece is up as well — the rail's captions are off on a phone whatever the
--- gate says, and this module cannot know that.
local gateWatchers: { () -> () } = {}
local running = false

local function held(object: GuiObject): boolean
	if suppressed[object] then
		return true
	end
	local allowed = gate
	if not allowed then
		return false
	end
	local name = nameOf[object]
	return name ~= nil and not allowed[name]
end

local function apply()
	for _, object in watched do
		object.Visible = running and not held(object)
	end
	for object in gated do
		object.Visible = not held(object)
	end
end

--[[
	Whether a run is under way.

	For the elements that cannot simply be registered because something else
	already owns their `Visible` — the tool button is shown or hidden by the
	HUD's refresh according to what you are holding, five times a second, and
	would win every argument. Those ask instead.
]]
function RunOnly.isRunning(): boolean
	return running
end

--- Hides this element until a run is actually under way.
function RunOnly.add(object: GuiObject)
	table.insert(watched, object)
	object.Visible = running and not held(object)
end

--- Keeps `object` hidden even during a run, for as long as `on` holds.
function RunOnly.suppress(object: GuiObject, on: boolean)
	suppressed[object] = on
	object.Visible = running and not held(object)
end

--[[
	Gives a piece of chrome a name the first run can hold it back by.

	More than one object can wear the same name — "rail" is three tiles and two
	captions — and `gated` says whether this module may hide it directly or
	whether its owner will ask.
]]
function RunOnly.piece(name: string, object: GuiObject, direct: boolean?)
	local list = named[name]
	if not list then
		list = {}
		named[name] = list
	end
	table.insert(list, object)
	nameOf[object] = name
	if direct then
		gated[object] = true
	end
end

--[[
	Allows only the named pieces up. `nil` releases them all.

	Anything registered with `add` is shown or hidden here and then; the two
	that are not — the tool button and the fuel gauge, whose visibility the
	HUD's own refresh owns five times a second — ask `permits` instead.
]]
function RunOnly.reveal(names: { string }?)
	if names then
		local allowed: { [string]: boolean } = {}
		for _, name in names do
			allowed[name] = true
		end
		gate = allowed
	else
		gate = nil
	end
	apply()
	for _, watcher in gateWatchers do
		watcher()
	end
end

--- Runs `fn` whenever the reveal gate changes.
function RunOnly.onGate(fn: () -> ())
	table.insert(gateWatchers, fn)
end

--- Whether this piece may be on screen: a run is under way and nothing is
--- holding it back.
function RunOnly.permits(object: GuiObject): boolean
	return running and not held(object)
end

--- Whether a rule other than the run itself is keeping this piece down. The
--- toasts ask this rather than `permits`, because they belong in the lobby.
function RunOnly.isHeld(object: GuiObject): boolean
	return held(object)
end

function RunOnly.start()
	Remotes.event(Remotes.ROUND_STATE).OnClientEvent:Connect(function(state: any)
		if type(state) ~= "table" then
			return
		end
		local phase = (state :: any).phase
		local now = phase ~= nil and phase ~= "lobby"
		if now ~= running then
			running = now
			apply()
		end
	end)
end

return RunOnly
