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
local MowEconomyService = require(script.Parent.EconomyService)

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
			warn("[Matchmaking] could not reserve a server; playing here instead")
			sending = false
			MowRunService.startFromLobby(worldId, partySize)
			return
		end

		local options = Instance.new("TeleportOptions")
		options.ReservedServerAccessCode = code
		options:SetTeleportData({ worldId = worldId, partySize = partySize })

		local sent = pcall(function()
			TeleportService:TeleportAsync(game.PlaceId, team, options)
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

	for _, player in Players:GetPlayers() do
		beginFrom(player)
	end
	Players.PlayerAdded:Connect(beginFrom)

	--[[
		A run server has one job, so when the run is over it hands everyone
		back to a public server, which is a lobby. Teleporting with no
		reservation is what makes it a public one.
	]]
	task.spawn(function()
		local wasRunning = false
		while true do
			task.wait(2)
			local phase = MowRunService.phase()
			if phase == "running" then
				wasRunning = true
			elseif wasRunning and phase == "lobby" then
				wasRunning = false
				local players = Players:GetPlayers()
				if #players > 0 and canTeleport() then
					pcall(function()
						TeleportService:TeleportAsync(game.PlaceId, players)
					end)
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
