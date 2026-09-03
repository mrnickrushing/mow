--!strict
--[[
	MatchmakingService — a fresh server for every team.

	The lobby used to start the run where it stood, which meant one property per
	server and everybody in it playing the same one. Two teams on the same
	server could not have two different runs, and a team of three could not have
	a lawn to itself.

	So the pads no longer start a run: they reserve a server and send that team
	to it. Every reservation is its own instance of this same place, which is why
	the code has to know which of the two it is running as.

	  * A public server is a lobby. It builds the yard, runs the pads, and never
	    begins a run of its own.
	  * A reserved server is a run. It never builds the yard; it reads the
	    property and the team size out of the teleport that brought its players
	    here, plays that, and sends everyone back to a public server when the
	    run is over.

	Teleports do not work in Studio, and a place file opened from disk has no
	place id to reserve against, so both fall back to starting the run in place.
	That keeps a Studio play test a complete game rather than a lobby that
	cannot leave.
]]

local Players = game:GetService("Players")
local RobloxRunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local MowRunService = require(script.Parent.RunService)
local Loop = require(script.Parent.Parent.Lib.Loop)
local MowEconomyService = require(script.Parent.EconomyService)
local Worlds = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Config.Worlds)

local MatchmakingService = {}

--- Set once a team has been sent, so a stuck countdown cannot send them twice.
local sending = false
--- Set once a reserved server has been told what to play.
local started = false

--[[
	Whether this server is one a team was sent to.

	A reserved server has a private server id and no owner: a VIP server has
	both, and a public server has neither. Only the first is a run.
]]
function MatchmakingService.isRunServer(): boolean
	return game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0
end

--- True when this server can actually reserve and teleport.
local function canTeleport(): boolean
	return not RobloxRunService:IsStudio() and game.PlaceId ~= 0
end

--[[
	Sends one team to a server of their own.

	The players who are not on a pad stay where they are, which is the point:
	the lobby keeps running for everyone still choosing.
]]
function MatchmakingService.send(team: { Player }, worldId: string, partySize: number): boolean
	if sending or #team == 0 then
		return false
	end

	if not canTeleport() then
		-- Studio, or a place file with no id: play it here instead.
		MowRunService.startFromLobby(worldId, partySize)
		return true
	end

	sending = true
	task.spawn(function()
		local ok, code = pcall(function()
			return TeleportService:ReserveServer(game.PlaceId)
		end)

		if not ok or type(code) ~= "string" then
			--[[
				A failed reservation leaves the team in the lobby.

				This used to fall back to starting the run here, which is the
				right answer in Studio, where there is one player and nowhere
				else to go, and quite wrong on a live lobby: it would convert
				the room everyone else was still choosing in into somebody
				else's run and drag them all along. Better to say it did not
				work and let them press the pad again.
			]]
			warn("[Matchmaking] could not reserve a server for the team")
			sending = false
			for _, player in team do
				if player.Parent then
					MowEconomyService.notify(
						player,
						"denied",
						"No lawn free just now — try the pad again",
						nil
					)
				end
			end
			return
		end

		--[[
			Who is actually still here.

			`team` was gathered from the pads before `ReserveServer`, which is
			a web call — so anybody can have left the game in between, and
			`TeleportAsync` given a player who is gone throws for the whole
			list. One person closing the tab would have stranded the other
			three in the lobby, watching a countdown they had finished.

			The party size goes with them rather than the number the pads
			counted, so the run they arrive in owes waves for the team that
			turned up.
		]]
		local going: { Player } = {}
		for _, player in team do
			if player.Parent then
				table.insert(going, player)
			end
		end
		if #going == 0 then
			sending = false
			return
		end

		local options = Instance.new("TeleportOptions")
		options.ReservedServerAccessCode = code
		options:SetTeleportData({ worldId = worldId, partySize = math.min(partySize, #going) })

		local sent = pcall(function()
			TeleportService:TeleportAsync(game.PlaceId, going, options)
		end)
		if not sent then
			warn("[Matchmaking] the teleport failed; the team stays in the lobby")
		end

		-- Released either way: a failed send must not wedge the pads shut.
		task.wait(3)
		sending = false
	end)
	return true
end

--[[
	What a reserved server plays, and where its players go afterwards.

	The property arrives with the players rather than being chosen here: it is
	in the teleport data of whoever was sent, which every one of them carries.
]]
--[[
	A teleport can fail after it has been accepted.

	`TeleportAsync` returning without error only means Roblox took the request;
	a player can still bounce back with a reason a moment later. Without this
	they would simply be standing in the lobby again with no idea why, watching
	a countdown they had already finished. Roblox puts them back on its own —
	the least this can do is say what happened.
]]
function MatchmakingService.watchFailures()
	TeleportService.TeleportInitFailed:Connect(function(player, result, message)
		warn(`[Matchmaking] teleport failed for {player.Name}: {result.Name} {message}`)
		sending = false
		if player.Parent then
			MowEconomyService.notify(
				player,
				"denied",
				"Could not find you a lawn — try the pad again",
				nil
			)
		end
	end)
end

function MatchmakingService.startRunServer()
	local function beginFrom(player: Player)
		if started then
			return
		end
		local ok, data = pcall(function()
			return player:GetJoinData().TeleportData
		end)
		if not ok or type(data) ~= "table" then
			return
		end
		local worldId = (data :: any).worldId
		if type(worldId) ~= "string" then
			return
		end
		started = true
		MowRunService.startFromLobby(worldId, tonumber((data :: any).partySize) or 1)
	end

	--[[
		A run server plays exactly what it was sent to play.

		The idle backstop that starts a world on a quiet server belongs to the
		lobby's public server, not here: on a reserved one it is the thing that
		would start a second run around a team that never managed to leave.
		The one case it was covering — a reservation that arrives with no
		usable teleport data — is handled below, deliberately and once.
	]]
	MowRunService.setAutoStart(false)

	for _, player in Players:GetPlayers() do
		beginFrom(player)
	end
	Players.PlayerAdded:Connect(beginFrom)

	-- A reservation that arrived with nothing to play falls back to the
	-- starter world rather than sitting empty.
	task.delay(45, function()
		if not started and #Players:GetPlayers() > 0 then
			started = true
			MowRunService.startFromLobby(Worlds.STARTER_ID, #Players:GetPlayers())
		end
	end)

	--[[
		A run server has one job, so when the run is over it hands everyone
		back to a public server, which is a lobby. Teleporting with no
		reservation is what makes it a public one.
	]]
		local wasRunning = false
	Loop.forever("Matchmaking.return", function()
		task.wait(2)
		local phase = MowRunService.phase()
		if phase == "running" then
			wasRunning = true
		elseif wasRunning and phase == "lobby" then
			wasRunning = false
			--[[
				Keep trying to hand them back, and never start a new run.

				A reserved server has no lobby in it, so a team whose
				return teleport failed would sit in an empty world until
				the idle backstop began another run — on a server nobody
				else can join, forever. The send is retried a few times,
				and if it will not go they are told, because a stuck
				player who knows they are stuck can rejoin.
			]]
			local sent = false
			for attempt = 1, 4 do
				local players = Players:GetPlayers()
				if #players == 0 then
					sent = true
					break
				end
				if not canTeleport() then
					break
				end
				sent = pcall(function()
					TeleportService:TeleportAsync(game.PlaceId, players)
				end)
				if sent then
					break
				end
				warn(`[Matchmaking] return teleport failed (attempt {attempt})`)
				task.wait(5)
			end
			if not sent then
				for _, player in Players:GetPlayers() do
					MowEconomyService.notify(
						player,
						"denied",
						"Could not get you back to the lobby — please rejoin",
						nil
					)
				end
			end
		end
	end)

	--[[
		A server nobody arrived at is a reservation that went nowhere.

		Roblox closes an empty server on its own, but only after a wait; this
		is here so a reservation that failed to deliver anybody does not sit
		holding a world nobody is in.
	]]
	task.delay(120, function()
		if #Players:GetPlayers() == 0 then
			started = true
		end
	end)
end

return MatchmakingService
