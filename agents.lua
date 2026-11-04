-- agents.lua - AGENTS: AI characters a mod puts in the world (2026-10-24: "a dog that follows my commands (function calls),
-- and NPCs I can have conversations with"). The HOST's Koetama asks the host's large language model (Koetama's
-- PROTOCOL.md "Large language models: agents", docs/agents-guide.md); only the chat talks to Koetama, so the chat is the
-- bridge for every mod: a mod defines its agents with registry keys on the host, players talk to them as to anyone
-- (typed or spoken lines said near them), their replies show as speech bubbles over them and in the chat, and their
-- function calls go to the mod, which checks each, acts, and answers.
--
-- A MOD SETS (server script, host; API.md "Agents"):
--   proxchat.agent.<id>.persona     who it is (the system prompt; up to 8 KB) - the agent exists while this is set
--   proxchat.agent.<id>.name        its name in bubbles and the chat (default: the id)
--   proxchat.agent.<id>.at          where it is: player:<id>, body:<handle> or x,y,z (devices.lua's PC.devParseAt), and
--                                   +x,y,z after it: an offset (a body's: in the body's own frame - its head on a rig);
--                                   none: nowhere (it hears only events or everything; its replies go to everyone)
--   proxchat.agent.<id>.hears       near (default: lines said within the line's mode range of it - Whisper 8 m, Speak 25,
--                                   Yell 40), named (near, and its name in the line), engaged (named, and anything near
--                                   from a player it answered in the last cfg.agentEngaged s), all (every line but the
--                                   dead's), none (only the mod's events)
--   proxchat.agent.<id>.hearagents  (API 20) N, 1 to 50: it hears the other agents' lines too (by its .hears), up to N agent
--                                   lines in a row - a player's line or a mod's .event starts the count over (each agent
--                                   line answering one counts one more; .say is 1), so agents talk among themselves for
--                                   a while and stop. 0 / unset: players only. An agent's line reaches them after a
--                                   pause to read it (cfg.agentPause*)
--   proxchat.agent.<id>.mode       how far its replies carry: whisper / speak (default) / yell / global
--   proxchat.agent.<id>.functions   its functions, a JSON array of {name, description, parameters (JSON Schema)}
--   proxchat.agent.<id>.state       what it should know now, sent with each line (up to 2 KB)
--   proxchat.agent.<id>.max_words   the longest reply (default 80); .character false: not a character (a director)
--   proxchat.agent.<id>.stream      false: no live words (by default its words show as the model writes them - Koetama's
--                                   "stream", 2026-10-24: live words from its speaker number, as a talking player's)
--   proxchat.agent.<id>.event       a line for it to hear from the game ("the alarm went off"): read and cleared
--   proxchat.agent.<id>.note        what it should know with the next line it gets (a player's or an event), exactly once:
--                                   read and cleared when that line goes (no request of its own)
--   proxchat.agent.<id>.say         it says this without the model (scripted lines, a fallback): read and cleared,
--                                   delivered as a reply; the model hears of it with its next line ("[you said: ...]")
--   proxchat.agent.<id>.forget      true: its conversation starts over (read and cleared)
--   proxchat.agent.<id>.criteria    (API 19) what the mod wants each turn of players' lines scored on before the agent
--                                   answers: a JSON array of {name, description}, at most 8 (names a-z 0-9 _). Koetama
--                                   asks the model for a score 0-1 on each; the chat writes them (.scores.<name>, .scorefrom,
--                                   .scorelines, .scoretext, then the counter .scoren); the mod judges (its own weights and
--                                   checks) and writes .decide = "<scoren> answer" or "<scoren> skip"; skip = no reply
--                                   (.skipn counts it), those lines come with its next answered turn. No decision in 3 s:
--                                   it answers. Notes ride along as context; a mod's .event and function results are never
--                                   scored. Only with a Koetama that scores (proxchat.agentscores true: "agent_scores")
-- THE CHAT SETS (host): proxchat.agents (off / ready / busy / budget / error - "off": no Koetama, or the host hasn't
-- allowed its language model for Teardown), proxchat.agent.<id>.reply / .replyn (its last line, a counter) with
-- .replyfrom / .replylines (the players, and the line ids, it answered) and .heard (how many players got it), .live,
-- .error (a code: budget, queue_full, failed, ... - Koetama 0.5.10) and .why (what went wrong, in words: for logs),
-- the scores above and .skipn (API 19: turns the mod skipped, a counter), proxchat.agentscores (the host's Koetama scores);
-- function calls in a ring of 16: proxchat.agentcall.last (a counter) and proxchat.agentcall.<n % 16>.n / .agent /
-- .name / .args (JSON) / .arg.<parameter> (each plain value as text) / .from (the players whose lines it answers, ids
-- separated by spaces; "" for game events alone) / .lines (those lines' ids); the mod answers each with
-- SetString(proxchat.agentcall.<k>.result, "ok: ..." or "error: ..."), which the chat sends back to the model.
--
-- HOW: the host's server hears every line said (server.pc_say -> PC.agentHear) and hands an agent's to the host's own
-- game (client.pc_agentline); that game reads the definitions, writes them and the lines into Koetama's feed
-- (PC.agentFeed), reads the replies (PC.agentReply), says them through the host (server.pc_agentsay) and writes the
-- calls for the mod.
-- KOETAMA 0.5.10 (2026-10-24): "agents_known" says which definitions (and versions) it has - only the missing or older
-- ones go in the feed (before it comes: for a few seconds after each hello and change, as with an older Koetama);
-- "received" says which lines and results it has - they stop being sent (and still wait for their reply); an
-- "unknown_agent" error: the definition and those lines go again (new ids), once; "cancelled": nothing.
-- AN AGENT SPEAKS AS ANYONE DOES (the user, 2026-10-24: "Why shouldn't the NPC characters share the same prox comm
-- features as other players?"): each agent gets a speaker number (PC.AGENT_P0 + k, proxchat.agent.<id>.player for the
-- mod) and its reply is an ordinary line from it (PC.deliver): its bubble over it (PC.speakerPos: the top of it), heard
-- in its mode's range, garbled across the buffer, muffled by walls, its babble from where it is (proxchat.agent.<id>.voice:
-- one of the chat's voices), in the chat log, translated, muted with /mute <name>, and a proxchat.said event (.agent set).
-- An agent hears only players, unless its mod lets it hear agents (.hearagents, API 20; the user, 2026-11-04: "I want
-- agents to be able to have conversations by themselves") - counted, so their talk ends unless a player or the mod
-- speaks: no endless talk spending the host's model budget. Their ids in .replyfrom / a call's .from are then speaker
-- numbers (.player, 3000..) too.

do
	local defaults = {
		agentMax = 64,           -- agents at most (speaker numbers PC.AGENT_P0 ..)
		agentLineLife = 60,      -- s a line waits for its reply before it is dropped
		agentLinesMax = 32,      -- lines waiting at most (the oldest go)
		agentSendFor = 5,        -- s the definitions go in the feed after a hello or a change
		agentRead = 0.25,        -- s between reads of the mods' keys (the host)
		agentReplyMax = 600,     -- characters of a reply said
		agentEngaged = 30,       -- s a player it answered (or who named it) stays heard by an agent that hears "engaged"
		agentPauseMin = 1,       -- s an agent's line waits before other agents hear it (time to read it): at least,
		agentPausePerChar = 0.04,--  per character,
		agentPauseMax = 4,       --  at most
		agentHearAgentsMax = 50, -- .hearagents at most
	}
	for k, v in pairs(defaults) do
		if PC.cfg[k] == nil then PC.cfg[k] = v end
	end
end
PC.AGENT_CALLS = 16                                                  -- (the calls' ring)
PC.AGENT_P0 = 3000                                                   -- (agents' speaker numbers: 3000.. - the test dummies are
                                                                     --  1000.., the voice dummies 2000..)
PC.AGENT_HEARS = {near = true, named = true, engaged = true, all = true, none = true}
PC.AGENT_MODES = {whisper = "w", w = "w", speak = "s", s = "s", yell = "y", shout = "y", y = "y", global = "g", g = "g"}

-- an agent id as Koetama takes it: 1-64 of A-Z a-z 0-9 _ . : -
function PC.agentIdOk(id)
	return type(id) == "string" and #id >= 1 and #id <= 64 and id:find("^[%w_%.:%-]+$") ~= nil
end

local function base(id) return PC.cfg.reg .. ".agent." .. id end

-- a usable point: three finite numbers, not the huge ones an empty body's bounds give (+-3.4e38)
local function okV(v)
	if type(v) ~= "table" then return false end
	for i = 1, 3 do
		local x = v[i]
		if type(x) ~= "number" or x ~= x or math.abs(x) > 1e7 then return false end
	end
	return true
end

-- the place of an at= (without its offset), and whether a body's bounds were empty
local function placeOf(spec, off)
	if spec.t == "player" then
		local ok, t = pcall(GetPlayerTransform, spec.p)
		if not (ok and t and t.pos) then return nil end
		if off then local p = VecAdd(t.pos, off); return p, VecAdd(p, Vec(0, 0.35, 0)) end
		return VecAdd(t.pos, Vec(0, 1, 0)), VecAdd(t.pos, Vec(0, 2.25, 0))
	elseif spec.t == "body" then
		local okT, t = pcall(GetBodyTransform, spec.h)
		if off then                                                     -- (an offset: in the body's own frame)
			if not (okT and t and t.pos and TransformToParentPoint) then return nil end
			local p = TransformToParentPoint(t, off)
			return p, VecAdd(p, Vec(0, 0.35, 0))
		end
		local empty = false
		if GetBodyBounds then
			local ok, lo, hi = pcall(GetBodyBounds, spec.h)
			if ok and okV(lo) and okV(hi) and lo[1] <= hi[1] and lo[2] <= hi[2] and lo[3] <= hi[3] then
				local mid = VecScale(VecAdd(lo, hi), 0.5)
				return mid, Vec(mid[1], hi[2] + 0.35, mid[3])
			end
			empty = ok                                                  -- (bounds, but none to speak of: no voxels left)
		end
		if not (okT and t and t.pos) then return nil, nil, empty end
		return t.pos, VecAdd(t.pos, Vec(0, 0.8, 0)), empty
	end
	local p = spec.pts[1]
	if off then p = VecAdd(p, off) end
	return p, VecAdd(p, Vec(0, 0.35, 0))
end

-- where an agent is now: its middle (for distances) and the top of it (where its bubble points), or nil. at: its at=,
-- with "+x,y,z" an offset. Can't be found now: where it was last (never nowhere while it was somewhere once). id: say a
-- body with no voxels left to the mod (once - the host)
PC.agentLast = PC.agentLast or {}
function PC.agentPos(at, id)
	at = tostring(at or "")
	local spec, off = at, nil
	local b, o = at:match("^(.-)%+(%-?[%d%.]+,%-?[%d%.]+,%-?[%d%.]+)$")
	if b then
		local x, y, z = o:match("^(.-),(.-),(.-)$")
		spec, off = b, Vec(tonumber(x), tonumber(y), tonumber(z))
	end
	local parsed = PC.devParseAt and PC.devParseAt(spec)
	local pos, top, empty
	if parsed then pos, top, empty = placeOf(parsed, off) end
	if empty and id and PC.problem then
		PC.problem(PC.cfg.reg .. ".agent." .. id .. ".at", PC.problemValue(at) .. ": the body has no voxels left (it was destroyed?) - " ..
			"using its position; anchor the agent to a body that can't be emptied (unbreakable), or to its rig: body:<handle>+x,y,z")
	end
	if okV(pos) and okV(top) then
		PC.agentLast[at] = {pos, top}
		return pos, top
	end
	local last = PC.agentLast[at]
	if last then return last[1], last[2] end
	return nil
end

-- an agent's speaker number?
function PC.isAgentP(p)
	return type(p) == "number" and p >= PC.AGENT_P0 and p < PC.AGENT_P0 + PC.cfg.agentMax
end

-- (every game, the host's server too) shared.pcAgents by speaker number, read every 0.5 s (a read of shared on a client
-- is a copy): p -> {id, name, at, mode}
function PC.agentByP(p)
	local c = PC.agentCache or {t = -1e9}
	PC.agentCache = c
	local now = GetTime()
	if now - c.t >= 0.5 or now < c.t then
		c.t, c.byP = now, {}
		for id, a in pairs(shared.pcAgents or {}) do
			if type(a) == "table" and type(a.p) == "number" then c.byP[a.p] = {id = id, name = a.name, at = a.at, mode = a.mode} end
		end
	end
	return c.byP[p]
end

-- agent p's "feet": where its speech bubble hangs 2.25 m above (the top of it - PC.speakerPos, PC.speakerFeet); nil: nowhere
function PC.agentFeet(p)
	local a = PC.agentByP(p)
	if not a then return nil end
	local _, top = PC.agentPos(a.at)                                   -- (not "a and PC.agentPos(...)": that keeps one value)
	return top and VecSub(top, Vec(0, 2.25, 0)) or nil
end

function PC.agentName(p)
	local a = PC.agentByP(p)
	return a and a.name or "?"
end

-- ---- THE HOST'S SERVER: the agents, who hears what, the replies said

-- (server) the agents from the registry (every 0.5 s): {name, at, mode, hears, p}; their name, place, mode and speaker
-- number in shared.pcAgents for every game, their babble voice in shared.pcVoice
function PC.agentServerTick()
	local s = PC.S()
	if s.time - (s.agentReadT or -1e9) < 0.5 then return end
	s.agentReadT = s.time
	local ok, ids = pcall(ListKeys, PC.cfg.reg .. ".agent")
	local list, pub, sig = {}, {}, {}
	for _, id in ipairs(ok and type(ids) == "table" and ids or {}) do
		if PC.agentIdOk(id) and GetString(base(id) .. ".persona") ~= "" then
			local b = base(id)
			local name = PC.utf8Head(PC.clean(GetString(b .. ".name")), 32)
			local hears = GetString(b .. ".hears"):lower()
			s.agentP = s.agentP or {}
			if not s.agentP[id] then                                      -- (its speaker number, for the session)
				s.agentNext = (s.agentNext or 0) + 1
				if s.agentNext <= PC.cfg.agentMax then s.agentP[id] = PC.AGENT_P0 + s.agentNext - 1 end
			end
			local p = s.agentP[id]
			if p then
				local a = {name = name ~= "" and name or id, at = GetString(b .. ".at"), p = p,
					mode = PC.AGENT_MODES[GetString(b .. ".mode"):lower()] or "s", hears = PC.AGENT_HEARS[hears] and hears or "near",
					hearAgents = math.max(0, math.min(PC.cfg.agentHearAgentsMax, math.floor(tonumber(GetString(b .. ".hearagents")) or 0)))}
				if a.at ~= "" then PC.agentPos(a.at, id) end              -- (a body with no voxels left: said to the mod)
				list[id] = a
				pub[id] = {name = a.name, at = a.at, mode = a.mode, p = p}
				sig[#sig + 1] = id .. "|" .. a.name .. "|" .. a.at .. "|" .. a.mode
				if GetInt(b .. ".player") ~= p then SetInt(b .. ".player", p) end   -- (for the mod: the said events, ...)
				local vn = GetString(b .. ".voice")
				local v = vn ~= "" and PC.findVoice and PC.findVoice(vn) or nil
				if v and (shared.pcVoice or {})[p] ~= v then PC.setShared("pcVoice", p, v) end
			end
		end
	end
	s.agents = list
	table.sort(sig)
	local str = table.concat(sig, "\n")
	if str ~= s.agentsSig then s.agentsSig = str; shared.pcAgents = pub; PC.agentCache = nil end
end

local function hostId()
	for _, q in ipairs(PC.allPlayers()) do
		local ok, h = pcall(IsPlayerHost, q)
		if ok and h == true then return q end
	end
	return nil
end

-- its name said in a line ("Rex, sit" - any case, a whole word)
function PC.agentNamed(text, name)
	local t, n = " " .. tostring(text):lower() .. " ", tostring(name):lower()
	if n == "" then return false end
	local i = 1
	while true do
		local a, b = t:find(n, i, true)
		if not a then return false end
		if not t:sub(a - 1, a - 1):find("[%w]") and not t:sub(b + 1, b + 1):find("[%w]") then return true end
		i = a + 1
	end
end

-- (PC.deliver) speaker p said text in mode ch (chan: a channel - the dead talk to no agent): the agents that hear it
-- get it, on the host's own game. p a player: depth 0; p an agent (its id: by): depth = its line's count of agent
-- lines in a row (1..) - only the others whose .hearagents reaches it hear it
function PC.agentHear(p, ch, text, chan, depth, by)
	local s = PC.S()
	if chan or not s.agents or next(s.agents) == nil then return end
	local host = hostId()
	if not host then return end
	depth = depth or 0
	local feet = PC.speakerFeet(p)
	local name = PC.nameOf(p)
	s.agentEng = s.agentEng or {}
	for id, a in pairs(s.agents) do
		if depth == 0 or (id ~= by and a.hearAgents >= depth) then
			local hear = a.hears == "all"
			local named = (a.hears == "named" or a.hears == "engaged") and PC.agentNamed(text, a.name)
			local eng = s.agentEng[id] and s.agentEng[id][p]
			local engaged = a.hears == "engaged" and eng ~= nil and s.time - eng <= PC.cfg.agentEngaged
			if (a.hears == "near" or named or engaged) and ch ~= "g" and feet then
				local pos = PC.agentPos(a.at)
				hear = pos ~= nil and VecLength(VecSub(pos, feet)) <= PC.rangeOf(ch) + 1   -- (+1: from the feet to its middle)
			end
			if hear then
				if named then s.agentEng[id] = s.agentEng[id] or {}; s.agentEng[id][p] = s.time end   -- (named it: engaged)
				ClientCall(host, "client.pc_agentline", id, p, name, text, depth)
			end
		end
	end
end

-- (the host's game) an agent's reply: a line from its speaker number, as a player's (PC.deliver: the players in its
-- mode's reach, everything a line gets), and its last line for the mod (.heard: how many players got it). from: the
-- players whose lines it answered (ids, spaces between) - engaged with it now; text "": only that (a reply of calls).
-- depth: its count of agent lines in a row (1: it answers a player or the game; PC.agentHear)
function server.pc_agentsay(p, tok, id, text, from, depth)
	local s, cfg = PC.S(), PC.cfg
	p = PC.who(p, tok)
	if not p then return end
	local okH, isHost = pcall(IsPlayerHost, p)
	if not (okH and isHost == true) then return end
	local a = s.agents and type(id) == "string" and s.agents[id]
	if not a then return end
	s.agentEng = s.agentEng or {}
	for q in tostring(type(from) == "string" and from or ""):gmatch("%d+") do
		q = PC.validId(q) or (PC.isAgentP(tonumber(q)) and tonumber(q)) or nil   -- (a player, or an agent it answered)
		if q then s.agentEng[id] = s.agentEng[id] or {}; s.agentEng[id][q] = s.time end
	end
	text = PC.clean(PC.arg(text), cfg.agentReplyMax)
	if text == "" then return end
	depth = math.max(1, math.min(1000, math.floor(PC.finite(depth) or 1)))
	local n = PC.deliver(a.p, a.name, a.mode, text, {agent = id, depth = depth})
	ClearKey(base(id) .. ".live")
	SetString(base(id) .. ".reply", text)
	SetInt(base(id) .. ".replyn", s.n)
	SetInt(base(id) .. ".heard", n or 0)
end

-- (the host's game) a streaming agent's words so far: live words from its speaker number (client.pc_live, as a talking
-- player's) to the players in its mode's reach - its bubble growing, a live line in their chat - until its reply, which
-- takes their place (PC.receive). Global: none (as for players). .live for the mod (cleared by the reply)
function server.pc_agentlive(p, tok, id, utt, text)
	local s, cfg = PC.S(), PC.cfg
	p = PC.who(p, tok)
	if not p then return end
	local okH, isHost = pcall(IsPlayerHost, p)
	if not (okH and isHost == true) then return end
	local a = s.agents and type(id) == "string" and s.agents[id]
	utt = PC.finite(utt)
	if not a or not utt or a.mode == "g" then return end
	text = PC.clean(PC.arg(text), cfg.agentReplyMax)
	if text == "" then                                                 -- (its reply ended without words, or failed: the live
		for _, q in ipairs(PC.allPlayers()) do                          --  words go everywhere, and .live)
			ClientCall(q, "client.pc_live", a.p, math.floor(utt), "", a.mode)
		end
		ClearKey(base(id) .. ".live")
		return
	end
	local feet = PC.speakerFeet(a.p)
	local _, outer = PC.rangeOf(a.mode)
	local reach = outer + (a.mode == "w" and cfg.whisperSlack or (a.mode == "y" and cfg.shoutSlack or cfg.speakSlack))
	for _, q in ipairs(PC.allPlayers()) do
		local okQ, tq = pcall(GetPlayerTransform, q)
		if s.chan[q] or (a.mode ~= "w" and s.hearAll[q]) or (feet and okQ and tq and VecLength(VecSub(tq.pos, feet)) <= reach) then
			ClientCall(q, "client.pc_live", a.p, math.floor(utt), text, a.mode)
		end
	end
	SetString(base(id) .. ".live", text)
end

-- ---- THE HOST'S GAME: the definitions, the lines and calls, Koetama's feed

local function A()
	local c = PC.C()
	if not c.agent then
		c.agent = {defs = {}, lines = {}, results = {}, forget = {}, pending = {}, n = 0, sentAt = -1e9, readT = -1e9,
			callN = GetInt(PC.cfg.reg .. ".agentcall.last"), lineFrom = {}, saidNotes = {}, liveOn = {}, utt = {},
			scorePending = {}, decisions = {}, scoreN = 0, lineDepth = {}, later = {}}
	end
	return c.agent
end

-- (client.pc_agentline / events) a line for agent id waits in the feed until its reply (the host's game; with the host's
-- language model on). Before it, as events in the same turn: what the agent said without the model (.say) and the
-- mod's note (.note), each once. raw: a note itself. depth: an agent's line's count (PC.agentHear; 0: a player's, an event)
local function queue(id, text, from, raw, depth)
	local vo, st = PC.c and PC.c.voice, A()
	if not (vo and vo.llm and vo.h and vo.h.alive) then return end
	text = PC.utf8Head(tostring(text or ""), 400)
	while #text > 400 do text = PC.utf8Head(text, PC.utf8Len(text) - 1) end
	if text == "" then return end
	if not raw then
		for _, said in ipairs(st.saidNotes[id] or {}) do queue(id, "you said: " .. said, nil, true) end
		st.saidNotes[id] = nil
		local note = GetString(base(id) .. ".note")
		if note ~= "" then
			ClearKey(base(id) .. ".note")
			for line in (note .. "\n"):gmatch("([^\n]*)\n") do if line ~= "" then queue(id, line, nil, true) end end
		end
	end
	st.n = st.n + 1
	st.lineFrom[st.n] = from and from.id or ""                       -- (who each line was from: a reply's .replyfrom, a
	st.lineFrom[st.n - 300] = nil                                    --  call's .from - the newest 300)
	if not raw then st.lineDepth[st.n] = depth or 0 end              -- (its reply's count: PC.agentReplyDepth; notes don't count)
	st.lineDepth[st.n - 300] = nil
	local state = GetString(base(id) .. ".state")
	if #state > 2048 then state = state:sub(1, 2048):gsub("[\128-\191]*$", ""):gsub("[\192-\255]$", "") end
	st.lines[#st.lines + 1] = {id = st.n, agent = id, text = text, from = from, state = state ~= "" and state or nil, t = GetTime(),
		context = raw or nil}                                          -- (a note: what it should know, no reason to answer)
	while #st.lines > PC.cfg.agentLinesMax do table.remove(st.lines, 1) end
	if PC.voiceFeedNow then PC.voiceFeedNow(vo) end
end

-- (server.pc_agentline -> the host's game) player p (name) said text near agent id
function client.pc_agentline(id, p, name, text, depth)
	if not PC.isHost() or not PC.agentIdOk(id) or type(text) ~= "string" then return end
	local from = {id = tostring(tonumber(p) or 0), name = type(name) == "string" and name or "?"}
	depth = math.max(0, math.floor(PC.finite(depth) or 0))
	if depth == 0 then queue(id, text, from); return end
	local cfg, st = PC.cfg, A()                                         -- (another agent's line: after a pause to read it)
	local wait = math.max(cfg.agentPauseMin, math.min(cfg.agentPauseMax, PC.utf8Len(text) * cfg.agentPausePerChar))
	st.later[#st.later + 1] = {due = GetTime() + wait, id = id, text = text, from = from, depth = depth}
end

-- a reply's count of agent lines in a row, from the lines it answers (ids: a set): the lowest of theirs + 1 (a player
-- in the turn starts it over); 1 when none is known
function PC.agentReplyDepth(ids)
	local st, d = A(), nil
	for x in pairs(ids) do
		local ld = st.lineDepth[x]
		if ld and (not d or ld < d) then d = ld end
	end
	return (d or 0) + 1
end

-- (the host's game, each tick) the mods' agents (definitions, events, forgets), the calls' results, the status key
function PC.agentTick(now)
	if not PC.isHost() then return end
	local c, reg, cfg = PC.C(), PC.cfg.reg, PC.cfg
	local vo, st = c.voice, A()
	local on = vo and vo.llm and vo.h and vo.h.alive
	local state = on and (st.state or "ready") or "off"
	if GetString(reg .. ".agents") ~= state then SetString(reg .. ".agents", state) end
	local scores = on and vo.h.hello ~= nil and vo.h.hello.features.agent_scores == true or false   -- (API 19)
	if GetBool(reg .. ".agentscores") ~= scores then SetBool(reg .. ".agentscores", scores) end
	for id, sp in pairs(st.scorePending) do                            -- (a mod's decision on a scored turn: at once)
		local key = base(id) .. ".decide"
		local dv = GetString(key)
		if dv ~= "" then
			ClearKey(key)
			local n, what = dv:match("^%s*(%d+)%s+(%a+)%s*$")
			if tonumber(n) == sp.n and (what == "answer" or what == "skip") then
				st.decisions[#st.decisions + 1] = {agent = id, turn = sp.turn, answer = what == "answer", ids = sp.ids, t = now}
				st.scorePending[id] = nil
				if on and PC.voiceFeedNow then PC.voiceFeedNow(vo) end
			elseif PC.problem and n and tonumber(n) ~= sp.n then
				PC.problem(key, "names turn " .. n .. " - the scores waiting are turn " .. sp.n .. " (.scoren)")
			elseif PC.problem then
				PC.problem(key, "is \"" .. dv .. "\" - write \"<scoren> answer\" or \"<scoren> skip\"")
			end
		end
	end
	for i = #st.lines, 1, -1 do                                        -- (lines no reply came for)
		if now - st.lines[i].t > cfg.agentLineLife then table.remove(st.lines, i) end
	end
	while #st.later > cfg.agentLinesMax do table.remove(st.later, 1) end
	local i = 1
	while st.later[i] do                                               -- (other agents' lines, read: now for the model, in
		local l = st.later[i]                                           --  the order said)
		if GetTime() >= l.due then table.remove(st.later, i); queue(l.id, l.text, l.from, nil, l.depth) else i = i + 1 end
	end
	for i = #st.decisions, 1, -1 do                                    -- (decisions no reply came for)
		if now - st.decisions[i].t > cfg.agentLineLife then table.remove(st.decisions, i) end
	end
	for k, pc in pairs(st.pending) do                                  -- (a mod answered a call)
		local key = reg .. ".agentcall." .. k .. ".result"
		local r = GetString(key)
		if r ~= "" then
			if #r > 1000 then r = r:sub(1, 1000) end
			st.results[#st.results + 1] = {call = pc.call, result = r, ids = pc.ids}
			st.pending[k] = nil
			ClearKey(key)
			if on and PC.voiceFeedNow then PC.voiceFeedNow(vo) end
		end
	end
	if now - st.readT < cfg.agentRead then return end
	st.readT = now
	local ok, ids = pcall(ListKeys, reg .. ".agent")
	local seen = {}
	for _, id in ipairs(ok and type(ids) == "table" and ids or {}) do
		local b = base(id)
		local persona = GetString(b .. ".persona")
		if PC.agentIdOk(id) and persona ~= "" then
			seen[id] = true
			local fns = GetString(b .. ".functions")
			local mw = GetString(b .. ".max_words")
			local ch = GetString(b .. ".character")
			local stream = GetString(b .. ".stream")
			local crit = GetString(b .. ".criteria")
			local sig = persona .. "\0" .. fns .. "\0" .. mw .. "\0" .. ch .. "\0" .. stream .. "\0" .. crit
			local d = st.defs[id]
			if not d or d.sig ~= sig then
				local def = {id = id, version = (d and d.def.version or 0) + 1, persona = persona, character = ch ~= "0" and ch ~= "false",
					stream = stream ~= "0" and stream ~= "false",
					max_words = math.max(1, math.min(1000, math.floor(tonumber(mw) or 80)))}
				if crit ~= "" then def.criteria = PC.agentCriteria(crit, b) end   -- (API 19)
				if fns ~= "" then
					local list = PC.jsonDecode(fns)
					if type(list) == "table" and getmetatable(list) ~= nil then def.functions = list
					elseif PC.problem then
						PC.problem(b .. ".functions", "is not a JSON array of {name, description, parameters} - the agent has no functions")
					end
				end
				st.defs[id] = {sig = sig, def = def}
				st.sentAt = now                                          -- (a change: in the feed for a few seconds - at once)
				if on and PC.voiceFeedNow then PC.voiceFeedNow(vo) end
			end
			local sy = GetString(b .. ".say")
			if sy ~= "" then                                             -- (it says this without the model; the model hears of it
				ClearKey(b .. ".say")                                     --  with its next line)
				for line in (sy .. "\n"):gmatch("([^\n]*)\n") do
					if line ~= "" then
						PC.call("pc_agentsay", id, line, "", 1)              -- (an agent line - others hearing agents hear it)
						st.saidNotes[id] = st.saidNotes[id] or {}
						table.insert(st.saidNotes[id], line)
						while #st.saidNotes[id] > 3 do table.remove(st.saidNotes[id], 1) end
					end
				end
			end
			local ev = GetString(b .. ".event")
			if ev ~= "" then
				ClearKey(b .. ".event")
				for line in (ev .. "\n"):gmatch("([^\n]*)\n") do if line ~= "" then queue(id, line, nil) end end
			end
			if GetBool(b .. ".forget") then
				ClearKey(b .. ".forget")
				st.forget[#st.forget + 1] = {id = id, t = now}
			end
		end
	end
	for id in pairs(st.defs) do if not seen[id] then st.defs[id] = nil end end
	for i = #st.forget, 1, -1 do if now - st.forget[i].t > 3 then table.remove(st.forget, i) end end
end

-- (voice.lua's hello) Koetama's hello: the definitions go again (it keeps them only for its session); what it knows is
-- unknown until its agents_known
function PC.agentHello(vo)
	vo.llm = vo.h.hello and vo.h.hello.features.llm == true or false
	local st = A()
	st.sentAt, st.known = GetTime(), nil
	st.scorePending, st.decisions = {}, {}                           -- (a new Koetama numbers its turns afresh: the old
end                                                                  --  ones' decisions would land on its new turns)

-- (voice.lua) agents_known: the definitions Koetama has, {id, version} each (it replaces what was known)
function PC.agentKnown(obj)
	local known = {}
	for _, a in ipairs(type(obj.agents) == "table" and obj.agents or {}) do
		if type(a) == "table" and PC.agentIdOk(a.id) and tonumber(a.version) then known[a.id] = tonumber(a.version) end
	end
	A().known = known
end

-- (voice.lua) received: the lines and results Koetama has (ids, call ids): no longer sent, still waiting for their reply
function PC.agentReceived(obj)
	local st = A()
	local got, calls = {}, {}
	for _, x in ipairs(type(obj.to_agent) == "table" and obj.to_agent or {}) do if tonumber(x) then got[tonumber(x)] = true end end
	for _, x in ipairs(type(obj.agent_results) == "table" and obj.agent_results or {}) do if type(x) == "string" then calls[x] = true end end
	for _, l in ipairs(st.lines) do if got[l.id] then l.received = true end end
	for _, r in ipairs(st.results) do if calls[r.call] then r.received = true end end
	local turns = {}
	for _, x in ipairs(type(obj.agent_decisions) == "table" and obj.agent_decisions or {}) do if tonumber(x) then turns[tonumber(x)] = true end end
	for _, x in ipairs(st.decisions) do if turns[x.turn] then x.received = true end end
end

-- (voice.lua's PC.voiceFeed) the agents' fields of the feed (the host's game, its language model on)
function PC.agentFeed(vo, f)
	if not (vo.llm and PC.c and PC.c.agent) then return end
	local st, now = A(), GetTime()
	local defs = PC.jsonArray({})                                    -- (what Koetama lacks, or has older; before its
	for _, d in pairs(st.defs) do                                    --  agents_known: for a few seconds after a change)
		local want
		if st.known then local kv = st.known[d.def.id]; want = kv == nil or kv < d.def.version
		else want = now - st.sentAt < PC.cfg.agentSendFor end
		if want and #defs < 32 then defs[#defs + 1] = d.def end
	end
	if #defs > 0 then f.agents = defs end
	local lines = PC.jsonArray({})
	for _, l in ipairs(st.lines) do                                  -- (not those Koetama said it received)
		if #lines < 8 and not l.received then lines[#lines + 1] = {id = l.id, agent = l.agent, text = l.text, from = l.from, state = l.state, context = l.context} end
	end
	if #lines > 0 then f.to_agent = lines end
	local res = PC.jsonArray({})
	for _, r in ipairs(st.results) do if not r.received then res[#res + 1] = {call = r.call, result = r.result} end end
	if #res > 0 then f.agent_results = res end
	local dec = PC.jsonArray({})                                     -- (API 19: the mods' decisions on scored turns)
	for _, x in ipairs(st.decisions) do
		if not x.received and #dec < 32 then dec[#dec + 1] = {agent = x.agent, turn = x.turn, answer = x.answer} end
	end
	if #dec > 0 then f.agent_decisions = dec end
	local fg = PC.jsonArray({})
	for _, x in ipairs(st.forget) do fg[#fg + 1] = x.id end
	if #fg > 0 then f.agent_forget = fg end
end

-- (API 19) a mod's .criteria (JSON) as Koetama takes them: [{name, description}], at most 8, names a-z 0-9 _ (at most
-- 32, each once), descriptions cut to 300 bytes; nil (and the mod told) when it isn't that
function PC.agentCriteria(text, b)
	local list = PC.jsonDecode(text)
	local bad
	if type(list) ~= "table" or getmetatable(list) == nil or #list == 0 or #list > 8 then bad = "is not a JSON array of 1 to 8 {name, description}" end
	local out, seen = PC.jsonArray({}), {}
	for _, c in ipairs(not bad and list or {}) do
		local n, d = type(c) == "table" and c.name, type(c) == "table" and c.description
		if type(n) ~= "string" or not n:find("^[a-z0-9_]+$") or #n > 32 or seen[n] then bad = "has a bad or repeated name (a-z 0-9 _, at most 32)"; break end
		if type(d) ~= "string" or d == "" then bad = "has a criterion without a description"; break end
		d = PC.utf8Head(d, 300)
		while #d > 300 do d = PC.utf8Head(d, PC.utf8Len(d) - 1) end
		seen[n] = true
		out[#out + 1] = {name = n, description = d}
	end
	if bad then
		if PC.problem then PC.problem(b .. ".criteria", bad .. " - nothing is scored") end
		return nil
	end
	return out
end

-- (voice.lua's message handler, API 19) agent_scores: a turn of players' lines scored on the mod's criteria; it waits for
-- the mod's decision (.decide). The keys first, the counter .scoren last
function PC.agentScores(obj)
	local st = A()
	local id = obj.agent
	if not (PC.agentIdOk(id) and st.defs[id] and tonumber(obj.turn)) then return end
	local ids = {}
	for _, x in ipairs(type(obj.ids) == "table" and obj.ids or {}) do if tonumber(x) then ids[#ids + 1] = tonumber(x) end end
	table.sort(ids)
	local b = base(id)
	ClearKey(b .. ".scores")
	for k, v in pairs(type(obj.scores) == "table" and obj.scores or {}) do
		if type(k) == "string" and k:find("^[a-z0-9_]+$") and tonumber(v) then
			SetFloat(b .. ".scores." .. k, math.max(0, math.min(1, tonumber(v))))
		end
	end
	local want, from, seenFrom, text, ls = {}, {}, {}, {}, {}
	for _, x in ipairs(ids) do want[x] = true; ls[#ls + 1] = tostring(x) end
	for _, l in ipairs(st.lines) do
		if want[l.id] then
			local f = st.lineFrom[l.id]
			if f and f ~= "" and not seenFrom[f] then seenFrom[f] = true; from[#from + 1] = f end
			text[#text + 1] = l.from and ((l.from.name or "?") .. ": " .. l.text) or ("[" .. l.text .. "]")
		end
	end
	st.scoreN = st.scoreN + 1
	st.scorePending[id] = {n = st.scoreN, turn = tonumber(obj.turn), ids = ids}
	SetString(b .. ".scorefrom", table.concat(from, " "))
	SetString(b .. ".scorelines", table.concat(ls, " "))
	SetString(b .. ".scoretext", table.concat(text, "\n"))
	SetInt(b .. ".scoren", st.scoreN)
end

-- (voice.lua's message handler) an agent_reply: its lines answered; the words said (through the host); each call
-- written for the mod (the ring); an error for the mod. A follow-up reply (to the same lines) ends their results
function PC.agentReply(obj)
	local st, reg = A(), PC.cfg.reg
	if obj.final == false then                                       -- (a streaming agent's words so far: live words, as a
		local id, text = obj.agent, type(obj.text) == "string" and obj.text or ""   --  talking player's; its lines wait for
		if PC.agentIdOk(id) and text ~= "" then                       --  the final reply)
			st.utt[id] = st.utt[id] or 1
			st.liveOn[id] = true
			PC.call("pc_agentlive", id, st.utt[id], text)
		end
		return
	end
	if PC.agentIdOk(obj.agent) then
		local id = obj.agent
		local final = type(obj.text) == "string" and obj.text or ""
		if st.liveOn[id] and (final == "" or (type(obj.error) == "string" and obj.error ~= "")) then
			PC.call("pc_agentlive", id, st.utt[id] or 1, "")           -- (no words to take the live words' place: they go)
		end
		st.liveOn[id] = nil
		st.utt[id] = (st.utt[id] or 1) + 1                             -- (its next reply: new live words)
	end
	local ids = {}
	for _, x in ipairs(type(obj.ids) == "table" and obj.ids or {}) do if tonumber(x) then ids[tonumber(x)] = true end end
	local answered = {}
	for i = #st.lines, 1, -1 do if ids[st.lines[i].id] then table.insert(answered, 1, table.remove(st.lines, i)) end end
	local function done(x) for _, i in ipairs(x.ids or {}) do if ids[i] then return true end end end
	for i = #st.decisions, 1, -1 do if done(st.decisions[i]) then table.remove(st.decisions, i) end end   -- (its turn is over:
	for k, sp in pairs(st.scorePending) do if done(sp) then st.scorePending[k] = nil end end            --  answered, skipped,
	                                                                                                      --  timed out, failed)
	for i = #st.results, 1, -1 do                                      -- (the follow-up came: their results are read)
		for _, x in ipairs(st.results[i].ids or {}) do if ids[x] then table.remove(st.results, i); break end end
	end
	local id = obj.agent
	if not PC.agentIdOk(id) then return end
	local err = type(obj.error) == "string" and obj.error or ""
	local why = type(obj.why) == "string" and obj.why or ""
	if err == "cancelled" then return end                            -- (our own agent_forget dropped them: nothing)
	if err == "unknown_agent" or err:find("^no agent") then          -- (Koetama lost it: the definition and the lines again,
		if st.known then st.known[id] = nil end                       --  under new ids - once)
		st.sentAt = GetTime()
		local again = false
		for _, l in ipairs(answered) do
			if not l.retried then
				st.n = st.n + 1
				l.id, l.received, l.retried, again = st.n, nil, true, true
				st.lines[#st.lines + 1] = l
			end
		end
		if again then
			local vo = PC.c and PC.c.voice
			if vo and PC.voiceFeedNow then PC.voiceFeedNow(vo) end         -- (at once)
			return
		end
		err = "unknown_agent"
	end
	SetString(base(id) .. ".error", err)
	SetString(base(id) .. ".why", why)
	if err ~= "" then return end
	if obj.skipped == true then                                      -- (API 19: the mod skipped a scored turn - nothing said,
		SetInt(base(id) .. ".skipn", GetInt(base(id) .. ".skipn") + 1) --  and it isn't engaged with them for it)
		return
	end
	local text = type(obj.text) == "string" and obj.text or ""
	local idList = {}
	for x in pairs(ids) do idList[#idList + 1] = x end
	table.sort(idList)
	local from, seenFrom = {}, {}                                    -- (the players whose lines it answers, in order)
	for _, x in ipairs(idList) do
		local f = st.lineFrom[x]
		if f and f ~= "" and not seenFrom[f] then seenFrom[f] = true; from[#from + 1] = f end
	end
	local fromS, linesS = table.concat(from, " "), table.concat(idList, " ")
	if text ~= "" then
		SetString(base(id) .. ".replyfrom", fromS)
		SetString(base(id) .. ".replylines", linesS)
	end
	if text ~= "" or fromS ~= "" then PC.call("pc_agentsay", id, text, fromS, PC.agentReplyDepth(ids)) end   -- (said; who it
	                                                                                                           --  answered: engaged)
	for _, call in ipairs(type(obj.calls) == "table" and obj.calls or {}) do
		if type(call) == "table" and type(call.name) == "string" and type(call.call) == "string" then
			st.callN = st.callN + 1
			local k = st.callN % PC.AGENT_CALLS
			local b = reg .. ".agentcall." .. k
			ClearKey(b)
			SetInt(b .. ".n", st.callN)
			SetString(b .. ".agent", id)
			SetString(b .. ".name", call.name)
			SetString(b .. ".from", fromS)
			SetString(b .. ".lines", linesS)
			local args = type(call.args) == "table" and call.args or {}
			SetString(b .. ".args", PC.jsonEncode(args))
			for key, v in pairs(args) do                                -- (plain values, each as text: easy for Lua)
				if type(key) == "string" and key:find("^[%w_]+$") and (type(v) == "string" or type(v) == "number" or type(v) == "boolean") then
					SetString(b .. ".arg." .. key, tostring(v))
				end
			end
			st.pending[k] = {call = call.call, ids = idList}
			SetInt(reg .. ".agentcall.last", st.callN)
		end
	end
end

-- (voice.lua's message handler) agent_status: ready / busy / budget / error (proxchat.agents for the mods)
function PC.agentStatus(obj)
	local s = obj.state
	if s == "ready" or s == "busy" or s == "budget" or s == "error" then A().state = s end
end
