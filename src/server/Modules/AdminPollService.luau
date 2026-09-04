-- [ACTIVE] AdminPollService
--[[
	Admin polls: this server or every server (MessagingService).
	One active poll at a time. Players vote once (can change). Counts sync live.
]]

local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AdminAllowlist = require(script.Parent:WaitForChild("AdminAllowlist"))
local AdminPollConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("AdminPollConfig"))

local M = {}

type VoteMap = { [number]: number }

type ActivePoll = {
	id: string,
	question: string,
	options: { string },
	scope: "server" | "global",
	endsAt: number,
	localVotes: VoteMap,
	foreignByJob: { [string]: VoteMap },
	voteDirty: boolean,
	endToken: number,
}

local startRE: RemoteEvent? = nil
local updateRE: RemoteEvent? = nil
local voteRE: RemoteEvent? = nil
local createRF: RemoteFunction? = nil
local messagingReady = false
local active: ActivePoll? = nil
local endToken = 0
local lastGlobalPublish = 0

local function getRemotesFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if folder and folder:IsA("Folder") then
		return folder
	end
	local created = Instance.new("Folder")
	created.Name = "Remotes"
	created.Parent = ReplicatedStorage
	return created
end

local function ensureEvent(name: string): RemoteEvent
	local folder = getRemotesFolder()
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local ev = Instance.new("RemoteEvent")
	ev.Name = name
	ev.Parent = folder
	return ev
end

local function ensureFunction(name: string): RemoteFunction
	local folder = getRemotesFolder()
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA("RemoteFunction") then
		return existing
	end
	local rf = Instance.new("RemoteFunction")
	rf.Name = name
	rf.Parent = folder
	return rf
end

local function cleanText(raw: any, maxLen: number): string?
	if typeof(raw) ~= "string" then
		return nil
	end
	local trimmed = string.gsub(raw, "[%c]", " ")
	trimmed = string.gsub(trimmed, "^%s*(.-)%s*$", "%1")
	trimmed = string.gsub(trimmed, "%s+", " ")
	if trimmed == "" then
		return nil
	end
	if #trimmed > maxLen then
		trimmed = string.sub(trimmed, 1, maxLen)
	end
	return trimmed
end

local function totalsFor(poll: ActivePoll): ({ number }, number)
	local counts = table.create(#poll.options, 0)
	local seen: { [number]: number } = {}
	for _, foreign in poll.foreignByJob do
		for userId, choice in foreign do
			if typeof(choice) == "number" and choice >= 1 and choice <= #poll.options then
				seen[userId] = choice
			end
		end
	end
	for userId, choice in poll.localVotes do
		if typeof(choice) == "number" and choice >= 1 and choice <= #poll.options then
			seen[userId] = choice
		end
	end
	local total = 0
	for _, choice in seen do
		counts[choice] += 1
		total += 1
	end
	return counts, total
end

local function publicPayload(poll: ActivePoll, includeCounts: boolean): { [string]: any }
	local payload: { [string]: any } = {
		id = poll.id,
		question = poll.question,
		options = poll.options,
		scope = poll.scope,
		endsAt = poll.endsAt,
	}
	if includeCounts then
		local counts, total = totalsFor(poll)
		payload.counts = counts
		payload.total = total
	end
	return payload
end

local function fireStart(poll: ActivePoll)
	if not startRE then
		return
	end
	startRE:FireAllClients(publicPayload(poll, true))
end

local function fireUpdate(poll: ActivePoll)
	if not updateRE then
		return
	end
	local counts, total = totalsFor(poll)
	updateRE:FireAllClients({
		id = poll.id,
		counts = counts,
		total = total,
		endsAt = poll.endsAt,
	})
end

local function encodeVoteMap(votes: VoteMap): { { u: number, o: number } }
	local list = {}
	for userId, choice in votes do
		table.insert(list, { u = userId, o = choice })
	end
	return list
end

local function decodeVoteMap(raw: any): VoteMap
	local map: VoteMap = {}
	if typeof(raw) ~= "table" then
		return map
	end
	for _, row in raw do
		if typeof(row) == "table" and typeof(row.u) == "number" and typeof(row.o) == "number" then
			map[row.u] = math.floor(row.o)
		end
	end
	return map
end

local function publishGlobal(kind: string, extra: { [string]: any })
	if not messagingReady then
		return
	end
	local body = extra
	body.kind = kind
	body.originJobId = game.JobId
	task.spawn(function()
		local ok, err = pcall(function()
			MessagingService:PublishAsync(AdminPollConfig.MESSAGING_TOPIC, body)
		end)
		if not ok then
			warn("[AdminPollService] publish failed:", err)
		end
	end)
end

local function scheduleEnd(poll: ActivePoll)
	endToken += 1
	poll.endToken = endToken
	local token = endToken
	local delaySec = math.max(0.2, poll.endsAt - Workspace:GetServerTimeNow())
	task.delay(delaySec, function()
		if token ~= endToken or not active or active.id ~= poll.id then
			return
		end
		fireUpdate(poll)
		task.delay(AdminPollConfig.END_HOLD_SEC + 0.4, function()
			if token ~= endToken then
				return
			end
			if active and active.id == poll.id then
				active = nil
			end
		end)
	end)
end

local function beginPoll(question: string, options: { string }, scope: "server" | "global", fromNetwork: boolean, idOverride: string?, endsAtOverride: number?)
	local now = Workspace:GetServerTimeNow()
	local poll: ActivePoll = {
		id = idOverride or HttpService:GenerateGUID(false),
		question = question,
		options = options,
		scope = scope,
		endsAt = endsAtOverride or (now + AdminPollConfig.DURATION_SEC),
		localVotes = {},
		foreignByJob = {},
		voteDirty = false,
		endToken = 0,
	}
	active = poll
	fireStart(poll)
	scheduleEnd(poll)
	if scope == "global" and not fromNetwork then
		publishGlobal("start", {
			id = poll.id,
			question = poll.question,
			options = poll.options,
			endsAt = poll.endsAt,
		})
	end
end

local function applyRemoteStart(data: any)
	if typeof(data) ~= "table" then
		return
	end
	if typeof(data.originJobId) == "string" and data.originJobId == game.JobId then
		return
	end
	local question = cleanText(data.question, AdminPollConfig.MAX_QUESTION)
	if not question then
		return
	end
	if typeof(data.id) ~= "string" or data.id == "" then
		return
	end
	local options: { string } = {}
	if typeof(data.options) == "table" then
		for _, opt in data.options do
			local cleaned = cleanText(opt, AdminPollConfig.MAX_OPTION)
			if cleaned then
				table.insert(options, cleaned)
			end
		end
	end
	if #options < AdminPollConfig.MIN_OPTIONS then
		return
	end
	local endsAt = data.endsAt
	if typeof(endsAt) ~= "number" then
		endsAt = Workspace:GetServerTimeNow() + AdminPollConfig.DURATION_SEC
	end
	if endsAt <= Workspace:GetServerTimeNow() + 0.5 then
		return
	end
	beginPoll(question, options, "global", true, data.id, endsAt)
end

local function applyRemoteVotes(data: any)
	local poll = active
	if not poll or poll.scope ~= "global" then
		return
	end
	if typeof(data) ~= "table" then
		return
	end
	if typeof(data.id) ~= "string" or data.id ~= poll.id then
		return
	end
	if typeof(data.originJobId) ~= "string" or data.originJobId == game.JobId then
		return
	end
	poll.foreignByJob[data.originJobId] = decodeVoteMap(data.votes)
	fireUpdate(poll)
end

function M.createFromAdmin(sender: Player, payload: any): (boolean, string)
	if not AdminAllowlist.isPlayerAllowed(sender) then
		return false, "You are not allowed to use admin commands."
	end
	if typeof(payload) ~= "table" then
		return false, "Invalid poll."
	end
	local question = cleanText(payload.question, AdminPollConfig.MAX_QUESTION)
	if not question then
		return false, "Enter a question."
	end
	local scope = payload.scope
	if scope ~= "global" then
		scope = "server"
	end
	local options: { string } = {}
	if typeof(payload.options) == "table" then
		for _, opt in payload.options do
			local cleaned = cleanText(opt, AdminPollConfig.MAX_OPTION)
			if cleaned then
				table.insert(options, cleaned)
			end
			if #options >= AdminPollConfig.MAX_OPTIONS then
				break
			end
		end
	end
	if #options < AdminPollConfig.MIN_OPTIONS then
		return false, "Need at least two options."
	end
	beginPoll(question, options, scope :: "server" | "global", false)
	if scope == "global" then
		return true, "Global poll sent."
	end
	return true, "Server poll sent."
end

local function onVote(player: Player, pollId: any, choice: any)
	local poll = active
	if not poll then
		return
	end
	if Workspace:GetServerTimeNow() >= poll.endsAt then
		return
	end
	if typeof(pollId) ~= "string" or pollId ~= poll.id then
		return
	end
	if typeof(choice) ~= "number" then
		return
	end
	local index = math.floor(choice)
	if index < 1 or index > #poll.options then
		return
	end
	poll.localVotes[player.UserId] = index
	poll.voteDirty = true
	fireUpdate(poll)
end

function M.start()
	startRE = ensureEvent(AdminPollConfig.START_REMOTE)
	updateRE = ensureEvent(AdminPollConfig.UPDATE_REMOTE)
	voteRE = ensureEvent(AdminPollConfig.VOTE_REMOTE)
	createRF = ensureFunction(AdminPollConfig.CREATE_REMOTE)

	createRF.OnServerInvoke = function(sender: Player, payload: any)
		local ok, resultOk, msg = pcall(function()
			return M.createFromAdmin(sender, payload)
		end)
		if not ok then
			warn("[AdminPollService] create failed:", resultOk)
			return { ok = false, message = "Poll failed. Check server output." }
		end
		return { ok = resultOk == true, message = tostring(msg or "") }
	end

	voteRE.OnServerEvent:Connect(function(player: Player, pollId: any, choice: any)
		onVote(player, pollId, choice)
	end)

	Players.PlayerRemoving:Connect(function(player)
		local poll = active
		if not poll then
			return
		end
		if poll.localVotes[player.UserId] ~= nil then
			poll.localVotes[player.UserId] = nil
			poll.voteDirty = true
			fireUpdate(poll)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(AdminPollConfig.GLOBAL_SYNC_SEC)
			local poll = active
			if not poll or poll.scope ~= "global" then
				continue
			end
			if Workspace:GetServerTimeNow() >= poll.endsAt then
				continue
			end
			if not poll.voteDirty then
				continue
			end
			if os.clock() - lastGlobalPublish < AdminPollConfig.GLOBAL_SYNC_SEC * 0.8 then
				continue
			end
			poll.voteDirty = false
			lastGlobalPublish = os.clock()
			publishGlobal("votes", {
				id = poll.id,
				votes = encodeVoteMap(poll.localVotes),
			})
		end
	end)

	local ok, err = pcall(function()
		MessagingService:SubscribeAsync(AdminPollConfig.MESSAGING_TOPIC, function(packet)
			if typeof(packet) ~= "table" or typeof(packet.Data) ~= "table" then
				return
			end
			local data = packet.Data
			if data.kind == "start" then
				applyRemoteStart(data)
			elseif data.kind == "votes" then
				applyRemoteVotes(data)
			end
		end)
		messagingReady = true
	end)
	if not ok then
		warn("[AdminPollService] MessagingService subscribe failed:", err)
	end
end

return M
