--!strict
--[[
	AdminService — the owner's own commands.

	A way to hand yourself cash while testing, and a few other things that are
	tedious to reach by playing. Every one of them is a cheat, so the whole
	file is written around one question: who is allowed.

	Two rules make that safe, and neither is optional.

	The first is that this is keyed on `UserId` and never on a name. A display
	name is not identity — it can be changed, and on Roblox it can be set to
	somebody else's outright, so a check against the string "unclenickrush"
	hands the economy to whoever fancies typing it. A `UserId` is issued once
	and belongs to one account for ever.

	The second is that every command runs on the server and reads its
	arguments as data. The client is told what happened; it is never asked
	what should happen. There is no remote here a player could fire, because
	a remote that grants cash is a remote that grants cash to everybody who
	finds it.

	Commands come from a small panel only the owner is shown. Chat was the
	obvious home for them and it does not work here; the note above the
	remote says why.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Util.Format)
local Remotes = require(Shared.Remotes)
local EconomyService = require(script.Parent.EconomyService)
local DataService = require(script.Parent.DataService)
local RunService = require(script.Parent.RunService)
local RunState = require(script.Parent.RunState)
local PlayerService = require(script.Parent.PlayerService)
local DefaultData = require(script.Parent.Parent.Lib.DefaultData)
local Tools = require(Shared.Config.Tools)

local AdminService = {}

--[[
	Who may use these, by account id.

	1213625298 is UncleNickRush, who owns the experience. Add an id to this
	table to add an admin; there is deliberately no way to do it from inside
	the game, because a command that grants admin is the only command worth
	stealing.
]]
local ADMINS: { [number]: string } = {
	[1213625298] = "UncleNickRush",
	-- Playtesters. Ids resolved through users.roblox.com on 2026-09-05; the
	-- names are a reminder of who, never the thing that is checked.
	[8772161919] = "zacksigma472",
	[5481735034] = "Whisk2626",
}

--- The most one command may hand over. Not a security control — an admin can
--- simply run it again — but it keeps a slipped keystroke from writing a
--- number the rest of the game's formatting was never meant to hold.
local MOST_AT_ONCE = 1e9

function AdminService.isAdmin(player: Player): boolean
	return ADMINS[player.UserId] ~= nil
end

local function tell(player: Player, message: string)
	EconomyService.notify(player, "reward", message, nil)
end

--------------------------------------------------------------------
-- What the commands do
--------------------------------------------------------------------

local function amountFrom(text: string?, fallback: number): number?
	if text == nil or text == "" then
		return fallback
	end
	local n = tonumber((text:gsub("[,_]", "")))
	if n == nil or n ~= n or n <= 0 then
		return nil
	end
	return math.min(math.floor(n), MOST_AT_ONCE)
end

--[[
	Run cash, which only exists inside a run.

	`awardRaw` rather than `award`: the multiplier stack is part of what is
	being tested, and a command that quietly hands over two and a half times
	what was asked for is a command you cannot use to test anything.
]]
local function giveCash(player: Player, arg: string?): string
	local amount = amountFrom(arg, 10000)
	if not amount then
		return `"{arg}" is not an amount.`
	end
	if RunService.phase() == "lobby" then
		return "Run cash only exists inside a run — start one first, or use /tips."
	end
	local paid = EconomyService.awardRaw(player, amount)
	if paid <= 0 then
		return "No run to pay into."
	end
	return `Added {Format.cash(paid)}.`
end

--- Tips are the profile's own currency and survive the run, so this works
--- anywhere, including standing in the lobby.
local function giveTips(player: Player, arg: string?): string
	local amount = amountFrom(arg, 500)
	if not amount then
		return `"{arg}" is not an amount.`
	end
	EconomyService.awardTips(player, amount)
	return `Added {amount} tips.`
end

--[[
	Every tool, for good. The long way round is buying fifteen of them.

	It writes the run as well as the profile, which it did not, and that made
	it look broken. `permanentTools` is what a *new* run is built from, so
	unlocking everything and then looking at the hotbar showed the one tool
	you started with — the change did not appear until the run ended and
	another began. Pressing a button called "Unlock every tool" and watching
	nothing happen is indistinguishable from a command that does not work,
	and it was reported as one.

	Buying a tool permanently already does the whole thing: profile, then the
	run in hand, then a push so the client redraws. This does the same, for
	all of them at once. `resetProgress` was already reaching into the run to
	take tools away, so the asymmetry was only ever in this direction.
]]
local function giveTools(player: Player): string
	local granted = 0
	DataService.withProfile(player, function(profile)
		for _, tool in Tools.list do
			if not profile.permanentTools[tool.id] then
				profile.permanentTools[tool.id] = true
				granted += 1
			end
		end
	end)

	local run = RunState.find(player)
	if run then
		for _, tool in Tools.list do
			run.ownedTools[tool.id] = true
		end
	end
	PlayerService.push(player)

	return `Unlocked {granted} tools for good.`
end

--[[
	Puts the account back to a new player's, so the owner can test as one.

	Every other command here adds something, and two of them add permanently:
	`tools` writes `permanentTools`, which survives the run, the session and
	the server, and there was no way at all to take it back. So the owner
	tries something once, and from then on every run starts holding sixteen
	tools with a hundred thousand in the bank — which is exactly the state you
	cannot test an early game from.

	It clears what the game gives out and leaves alone what it sold: receipts
	stay, because those record real Robux and a reset must never be a refund
	that hands the same purchase out twice.
]]
local function resetProgress(player: Player): string
	local fresh = DefaultData.template()
	DataService.withProfile(player, function(profile)
		profile.permanentTools = {}
		profile.tips = fresh.tips
		profile.tokens = fresh.tokens
		profile.stats = fresh.stats
		profile.worldsBeaten = {}
		profile.bestTimes = {}
		profile.questProgress = {}
		profile.questsDone = {}
		profile.dailyStreak = fresh.dailyStreak
		profile.dailyLastClaim = fresh.dailyLastClaim
		profile.firstCompletionClaimed = false
	end)
	-- The run in hand is holding the tools too, so it is emptied to match.
	local run = RunState.find(player)
	if run then
		table.clear(run.ownedTools)
		run.ownedTools[Tools.STARTER_ID] = true
		run.equippedTool = Tools.STARTER_ID
		run.cash = 0
		table.clear(run.upgrades)
	end
	PlayerService.applyCharacterStats(player)
	return "Reset to a new player: no tools, no tips, no upgrades. Purchases kept."
end

type Command = {
	name: string,
	help: string,
	run: (Player, string?) -> string,
}

local COMMANDS: { Command } = {
	{
		name = "cash",
		help = "/cash [amount] — run cash, default 10,000. Only inside a run.",
		run = giveCash,
	},
	{
		name = "tips",
		help = "/tips [amount] — tips, default 500. Works anywhere.",
		run = giveTips,
	},
	{
		name = "tools",
		help = "/tools — unlock every tool permanently.",
		run = function(player: Player, _arg: string?): string
			return giveTools(player)
		end,
	},
	{
		name = "reset",
		help = "/reset — back to a new player. Keeps anything bought with Robux.",
		run = function(player: Player, _arg: string?): string
			return resetProgress(player)
		end,
	},
	{
		name = "rich",
		help = "/rich — cash, tips and every tool, in one go.",
		run = function(player: Player, _arg: string?): string
			local parts = { giveTips(player, "5000"), giveTools(player) }
			if RunService.phase() ~= "lobby" then
				table.insert(parts, 1, giveCash(player, "100000"))
			end
			return table.concat(parts, " ")
		end,
	},
}

--------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------

local byName: { [string]: Command } = {}
for _, command in COMMANDS do
	byName[command.name] = command
end

--[[
	One place where a typed line becomes an action, whichever chat sent it.

	`what` arrives without its slash. Everything after the first space is the
	argument, read as text and never executed.
]]
local function dispatch(player: Player, what: string)
	if not AdminService.isAdmin(player) then
		return
	end
	local name, rest = what:match("^(%a+)%s*(.*)$")
	if not name then
		return
	end
	local command = byName[name:lower()]
	if not command then
		return
	end
	local ok, result = pcall(command.run, player, if rest == "" then nil else rest)
	tell(player, if ok then result else `That did not work: {result}`)
end

--[[
	A remote, because chat is not a door that opens here.

	The obvious way to do this is a slash command, and it was tried twice.
	`TextChatCommand` is the documented modern route, and this experience
	runs `LegacyChatService`, which never triggers one — the commands
	registered and were silently never called. So the old chat's own
	`Player.Chatted` was wired instead, and that does not see them either:
	both chat systems treat a leading slash as a command of their own and
	swallow anything they do not recognise before a game script is told.

	Typing `/tips 750` produced nothing, twice, with no error to chase —
	which is the worst way for a cheat to fail, because it looks exactly
	like a cheat that is working on something you cannot see.

	So the panel talks straight to the server. This is not less safe: the
	`UserId` check below runs on the server before anything happens, so a
	player who finds this remote and fires it by hand is refused the same
	way they would be refused in chat. What the client controls is whether
	a button is drawn, and that was never the thing worth protecting.
]]
local remote: RemoteEvent

local function onRequest(player: Player, name: any, arg: any)
	if type(name) ~= "string" then
		return
	end
	-- Arguments arrive from a client, so they are read as text and nothing
	-- else; `dispatch` looks the name up in a fixed table rather than
	-- calling anything it was handed.
	local suffix = if type(arg) == "string" or type(arg) == "number" then tostring(arg) else ""
	dispatch(player, `{name} {suffix}`)
end

local function greet(player: Player)
	if not AdminService.isAdmin(player) then
		return
	end
	task.delay(5, function()
		if player.Parent and remote then
			remote:FireClient(player, "admin", ADMINS[player.UserId])
		end
	end)
end

function AdminService.start()
	remote = Remotes.event(Remotes.ADMIN)
	remote.OnServerEvent:Connect(onRequest)

	for _, player in Players:GetPlayers() do
		greet(player)
	end
	Players.PlayerAdded:Connect(greet)

end

return AdminService
