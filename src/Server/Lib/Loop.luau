--!strict
--[[
	Loop — a server tick that survives its own mistakes.

	Six services run a `task.spawn(function() while true do ... end end)` and
	not one of them caught anything. An error in any single iteration does not
	skip that iteration: it unwinds the whole loop, and the loop never runs
	again for the life of the server. There is one line in the log to say so
	and nothing on anyone's screen.

	What that meant per loop, when it happened:

	  RunService     the round never ends — no win, no loss, the clock freezes
	  PlayerService  nobody can sell at the trailer and the HUD stops moving
	  DataService    no autosaves, and the session lock stops being refreshed
	  BoostService   rentals never expire
	  Stripe / AutoCollect   a bonus or a paid pass quietly stops working

	None of those are "one player's problem": a public server holds fifty
	people, and one bad tick for one of them took the subsystem away from all
	of them. It was reproduced this session by handing one player's bag a
	debris id that does not exist — the pour loop died on the next push and
	the trailer stopped paying anyone.

	Each iteration now runs under `pcall`. A failure is reported with the
	loop's name and the loop carries on to the next tick.
]]

local Loop = {}

--- Seconds between repeat reports of the same failing loop, so a body that
--- throws every tick does not flood the log at 30 Hz.
local REPORT_EVERY = 30
--- Breathing room after a failure, in case the body threw before reaching
--- its own wait — otherwise a persistently failing loop would spin hot.
local FAILURE_PAUSE = 1

--[[
	Runs `body` while `keepGoing()` holds. `body` is one iteration and is
	expected to do its own `task.wait`, so any cadence — fixed, variable, or
	per-player — fits. A sprinkler runs while its head is still in the world;
	the round tick runs for the life of the server.
]]
function Loop.whileTrue(name: string, keepGoing: () -> boolean, body: () -> ())
	task.spawn(function()
		local lastReport = -math.huge
		local suppressed = 0
		while keepGoing() do
			local ok, err = pcall(body :: any)
			if not ok then
				local now = os.clock()
				if now - lastReport >= REPORT_EVERY then
					local extra = if suppressed > 0 then ` ({suppressed} more since last report)` else ""
					warn(`[Loop:{name}] iteration failed, continuing{extra}: {tostring(err)}`)
					lastReport = now
					suppressed = 0
				else
					suppressed += 1
				end
				task.wait(FAILURE_PAUSE)
			end
		end
	end)
end

local function always(): boolean
	return true
end

--- Runs `body` for the life of the server.
function Loop.forever(name: string, body: () -> ())
	Loop.whileTrue(name, always, body)
end

return Loop
