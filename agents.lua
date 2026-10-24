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
--   proxchat.agent.<id>.at          where it is: player:<id>, body:<handle> or x,y,z (devices.lua's PC.devParseAt);
--                                   none: nowhere (it hears only events or everything; its replies go to everyone)
--   proxchat.agent.<id>.hears       near (default: lines said within the line's mode range of it - Whisper 8 m, Speak 25,
--                                   Yell 40), named (near, and its name in the line), all (every line but the dead's),
--                                   none (only the mod's events)
--   proxchat.agent.<id>.mode        how far its replies carry: whisper / speak (default) / yell / global
--   proxchat.agent.<id>.functions   its functions, a JSON array of {name, description, parameters (JSON Schema)}
--   proxchat.agent.<id>.state       what it should know now, sent with each line (up to 2 KB)
--   proxchat.agent.<id>.max_words   the longest reply (default 80); .character false: not a character (a director)
--   proxchat.agent.<id>.event       a line for it to hear from the game ("the alarm went off"): read and cleared
--   proxchat.agent.<id>.forget      true: its conversation starts over (read and cleared)
-- THE CHAT SETS (host): proxchat.agents (off / ready / busy / budget / error - "off": no Koetama, or the host hasn't
-- allowed its language model for Teardown), proxchat.agent.<id>.reply / .replyn (its last line, a counter) and .error;
-- function calls in a ring of 16: proxchat.agentcall.last (a counter) and proxchat.agentcall.<n % 16>.n / .agent /
-- .name / .args (JSON) / .arg.<parameter> (each plain value as text); the mod answers each with
-- SetString(proxchat.agentcall.<k>.result, "ok: ..." or "error: ..."), which the chat sends back to the model.
--
-- HOW: the host's server hears every line said (server.pc_say -> PC.agentHear) and hands an agent's to the host's own
-- game (client.pc_agentline); that game reads the definitions, writes them and the lines into Koetama's feed
-- (PC.agentFeed), reads the replies (PC.agentReply), says them through the host (server.pc_agentsay: the players in
-- the reply's reach get it, client.pc_agentsay) and writes the calls for the mod.

do
	local defaults = {
		agentLineLife = 60,      -- s a line waits for its reply before it is dropped
		agentLinesMax = 32,      -- lines waiting at most (the oldest go)
		agentSendFor = 5,        -- s the definitions go in the feed after a hello or a change
		agentRead = 0.25,        -- s between reads of the mods' keys (the host)
		agentReplyMax = 600,     -- characters of a reply said
	}
	for k, v in pairs(defaults) do
		if PC.cfg[k] == nil then PC.cfg[k] = v end
	end
end
PC.AGENT_CALLS = 16                                                  -- (the calls' ring)
PC.AGENT_HEARS = {near = true, named = true, all = true, none = true}
PC.AGENT_MODES = {whisper = "w", w = "w", speak = "s", s = "s", yell = "y", shout = "y", y = "y", global = "g", g = "g"}

-- an agent id as Koetama takes it: 1-64 of A-Z a-z 0-9 _ . : -
function PC.agentIdOk(id)
	return type(id) == "string" and #id >= 1 and #id <= 64 and id:find("^[%w_%.:%-]+$") ~= nil
end

local function base(id) return PC.cfg.reg .. ".agent." .. id end

-- where an agent is now: its middle (for distances) and the top of it (where its bubble points), or nil
function PC.agentPos(at)
	local spec = PC.devParseAt and PC.devParseAt(at)
	if not spec then return nil end
	if spec.t == "player" then
		local ok, t = pcall(GetPlayerTransform, spec.p)
		if not (ok and t and t.pos) then return nil end
		return VecAdd(t.pos, Vec(0, 1, 0)), VecAdd(t.pos, Vec(0, 2.25, 0))
	elseif spec.t == "body" then
		if GetBodyBounds then
			local ok, lo, hi = pcall(GetBodyBounds, spec.h)
			if ok and lo and hi then
				local mid = VecScale(VecAdd(lo, hi), 0.5)
				return mid, Vec(mid[1], hi[2] + 0.35, mid[3])
			end
		end
		local ok, t = pcall(GetBodyTransform, spec.h)
		if not (ok and t and t.pos) then return nil end
		return t.pos, VecAdd(t.pos, Vec(0, 0.8, 0))
	end
	local p = spec.pts[1]
	return p, VecAdd(p, Vec(0, 0.35, 0))
end

-- ---- THE HOST'S SERVER: the agents, who hears what, the replies said

-- (server) the agents from the registry (every 0.5 s): {name, at, mode, hears}; their name, place and mode in
-- shared.pcAgents for every game (the bubbles)
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
			local a = {name = name ~= "" and name or id, at = GetString(b .. ".at"),
				mode = PC.AGENT_MODES[GetString(b .. ".mode"):lower()] or "s", hears = PC.AGENT_HEARS[hears] and hears or "near"}
			list[id] = a
			pub[id] = {name = a.name, at = a.at, mode = a.mode}
			sig[#sig + 1] = id .. "|" .. a.name .. "|" .. a.at .. "|" .. a.mode
		end
	end
	s.agents = list
	table.sort(sig)
	local str = table.concat(sig, "\n")
	if str ~= s.agentsSig then s.agentsSig = str; shared.pcAgents = pub end
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

-- (server.pc_say) player p said text in mode ch (chan: a channel - the dead talk to no agent): the agents that hear it
-- get it, on the host's own game
function PC.agentHear(p, ch, text, chan)
	local s = PC.S()
	if chan or not s.agents or next(s.agents) == nil then return end
	local host = hostId()
	if not host then return end
	local okT, tr = pcall(GetPlayerTransform, p)
	local name = PC.nameOf(p)
	for id, a in pairs(s.agents) do
		local hear = a.hears == "all"
		if (a.hears == "near" or (a.hears == "named" and PC.agentNamed(text, a.name))) and ch ~= "g" and okT and tr and tr.pos then
			local pos = PC.agentPos(a.at)
			hear = pos ~= nil and VecLength(VecSub(pos, tr.pos)) <= PC.rangeOf(ch) + 1   -- (+1: from the feet to its middle)
		end
		if hear then ClientCall(host, "client.pc_agentline", id, p, name, text) end
	end
end

-- (the host's game) an agent's reply: said to the players in its reach (its mode's, the buffer and a slack; global, or
-- nowhere: everyone; the dead: everyone), and its last line for the mod
function server.pc_agentsay(p, tok, id, text)
	local s, cfg = PC.S(), PC.cfg
	p = PC.who(p, tok)
	if not p then return end
	local okH, isHost = pcall(IsPlayerHost, p)
	if not (okH and isHost == true) then return end
	local a = s.agents and type(id) == "string" and s.agents[id]
	if not a then return end
	text = PC.clean(PC.arg(text), cfg.agentReplyMax)
	if text == "" then return end
	s.agentN = (s.agentN or 0) + 1
	local pos = PC.agentPos(a.at)
	local _, outer = PC.rangeOf(a.mode)
	for _, q in ipairs(PC.allPlayers()) do
		local to = a.mode == "g" or not pos or s.chan[q] ~= nil
		if not to then
			local okQ, tq = pcall(GetPlayerTransform, q)
			to = okQ and tq and tq.pos and VecLength(VecSub(tq.pos, pos)) <= outer + cfg.speakSlack
		end
		if to then ClientCall(q, "client.pc_agentsay", id, a.name, text, a.mode, s.agentN) end
	end
	SetString(base(id) .. ".reply", text)
	SetInt(base(id) .. ".replyn", s.agentN)
end

-- ---- EVERY GAME: an agent's reply, shown

-- (client) agent id (name) says text in mode: in the chat, and a bubble over it - garbled from its mode's buffer, as a
-- typed line is (fixed as heard when it came)
function client.pc_agentsay(id, name, text, mode, n)
	local c = PC.C()
	if type(id) ~= "string" or type(text) ~= "string" or text == "" then return end
	mode = (mode == "w" or mode == "y" or mode == "g") and mode or "s"
	name = type(name) == "string" and name ~= "" and name or id
	local a = (shared.pcAgents or {})[id]
	local pos = a and PC.agentPos(a.at)
	local shown, far = text, false
	if pos and mode ~= "g" and not PC.dead() then
		local inner, outer = PC.rangeOf(mode)
		local head = PC.listenerHead()
		local d = head and VecLength(VecSub(head, pos)) or 0
		if d > outer then return end                                   -- (sent with the slack, walked off since)
		if d > inner then
			shown, far = PC.garble(text, PC.fracAt(d, mode) or 0, (tonumber(n) or 0) + 7919, 0), true
		end
	end
	PC.addHist({ch = mode, name = name, text = shown, far = far, agent = id})
	if pos then
		c.agentB = c.agentB or {}
		c.agentB[id] = {text = shown, t = GetTime(), mode = mode, far = far}
	end
end

-- (chat_core's drawBubbles) the agents' bubbles over them, for their time (as a typed line's), fading at the end
function PC.agentBubbles(add, now)
	local c, cfg = PC.C(), PC.cfg
	for id, b in pairs(c.agentB or {}) do
		local life = math.min(cfg.lifeMax, cfg.lifeMin + PC.utf8Len(b.text) * cfg.lifePerChar) + (b.extra or 0)
		if now - b.t > life then
			c.agentB[id] = nil
		else
			local a = (shared.pcAgents or {})[id]
			local pos, top = a and PC.agentPos(a.at)
			if pos then
				local L = PC.bubbleLayout("agent:" .. id, b.text, b.mode == "y", math.max(0, math.min(1, (life - (now - b.t)) / 1.2)),
					false, b.mode == "w", b.far, b.t, false, nil, nil, {pos = pos, top = top})
				if L then
					b.extra = math.max(b.extra or 0, L.scrollTime)
					add(L)
				end
			end
		end
	end
end

-- ---- THE HOST'S GAME: the definitions, the lines and calls, Koetama's feed

local function A()
	local c = PC.C()
	if not c.agent then
		c.agent = {defs = {}, lines = {}, results = {}, forget = {}, pending = {}, n = 0, sentAt = -1e9, readT = -1e9,
			callN = GetInt(PC.cfg.reg .. ".agentcall.last")}
	end
	return c.agent
end

-- (client.pc_agentline / events) a line for agent id waits in the feed until its reply (the host's game; with the host's
-- language model on)
local function queue(id, text, from)
	local vo, st = PC.c and PC.c.voice, A()
	if not (vo and vo.llm and vo.h and vo.h.alive) then return end
	text = PC.utf8Head(tostring(text or ""), 400)
	while #text > 400 do text = PC.utf8Head(text, PC.utf8Len(text) - 1) end
	if text == "" then return end
	st.n = st.n + 1
	local state = GetString(base(id) .. ".state")
	if #state > 2048 then state = state:sub(1, 2048):gsub("[\128-\191]*$", ""):gsub("[\192-\255]$", "") end
	st.lines[#st.lines + 1] = {id = st.n, agent = id, text = text, from = from, state = state ~= "" and state or nil, t = GetTime()}
	while #st.lines > PC.cfg.agentLinesMax do table.remove(st.lines, 1) end
	if PC.voiceFeedNow then PC.voiceFeedNow(vo) end
end

-- (server.pc_agentline -> the host's game) player p (name) said text near agent id
function client.pc_agentline(id, p, name, text)
	if not PC.isHost() or not PC.agentIdOk(id) or type(text) ~= "string" then return end
	queue(id, text, {id = tostring(tonumber(p) or 0), name = type(name) == "string" and name or "?"})
end

-- (the host's game, each tick) the mods' agents (definitions, events, forgets), the calls' results, the status key
function PC.agentTick(now)
	if not PC.isHost() then return end
	local c, reg, cfg = PC.C(), PC.cfg.reg, PC.cfg
	local vo, st = c.voice, A()
	local on = vo and vo.llm and vo.h and vo.h.alive
	local state = on and (st.state or "ready") or "off"
	if GetString(reg .. ".agents") ~= state then SetString(reg .. ".agents", state) end
	for i = #st.lines, 1, -1 do                                        -- (lines no reply came for)
		if now - st.lines[i].t > cfg.agentLineLife then table.remove(st.lines, i) end
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
			local sig = persona .. "\0" .. fns .. "\0" .. mw .. "\0" .. ch
			local d = st.defs[id]
			if not d or d.sig ~= sig then
				local def = {id = id, version = (d and d.def.version or 0) + 1, persona = persona, character = ch ~= "0" and ch ~= "false",
					max_words = math.max(1, math.min(1000, math.floor(tonumber(mw) or 80)))}
				if fns ~= "" then
					local list = PC.jsonDecode(fns)
					if type(list) == "table" and getmetatable(list) ~= nil then def.functions = list
					elseif PC.problem then
						PC.problem(b .. ".functions", "is not a JSON array of {name, description, parameters} - the agent has no functions")
					end
				end
				st.defs[id] = {sig = sig, def = def}
				st.sentAt = now                                          -- (a change: in the feed for a few seconds)
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

-- (voice.lua's hello) Koetama's hello: the definitions go again (it keeps them only for its session)
function PC.agentHello(vo)
	vo.llm = vo.h.hello and vo.h.hello.features.llm == true or false
	A().sentAt = GetTime()
end

-- (voice.lua's PC.voiceFeed) the agents' fields of the feed (the host's game, its language model on)
function PC.agentFeed(vo, f)
	if not (vo.llm and PC.c and PC.c.agent) then return end
	local st, now = A(), GetTime()
	if now - st.sentAt < PC.cfg.agentSendFor then
		local defs = PC.jsonArray({})
		for _, d in pairs(st.defs) do if #defs < 32 then defs[#defs + 1] = d.def end end
		if #defs > 0 then f.agents = defs end
	end
	local lines = PC.jsonArray({})
	for _, l in ipairs(st.lines) do
		if #lines < 8 then lines[#lines + 1] = {id = l.id, agent = l.agent, text = l.text, from = l.from, state = l.state} end
	end
	if #lines > 0 then f.to_agent = lines end
	local res = PC.jsonArray({})
	for _, r in ipairs(st.results) do res[#res + 1] = {call = r.call, result = r.result} end
	if #res > 0 then f.agent_results = res end
	local fg = PC.jsonArray({})
	for _, x in ipairs(st.forget) do fg[#fg + 1] = x.id end
	if #fg > 0 then f.agent_forget = fg end
end

-- (voice.lua's message handler) an agent_reply: its lines answered; the words said (through the host); each call
-- written for the mod (the ring); an error for the mod. A follow-up reply (to the same lines) ends their results
function PC.agentReply(obj)
	local st, reg = A(), PC.cfg.reg
	local ids = {}
	for _, x in ipairs(type(obj.ids) == "table" and obj.ids or {}) do if tonumber(x) then ids[tonumber(x)] = true end end
	for i = #st.lines, 1, -1 do if ids[st.lines[i].id] then table.remove(st.lines, i) end end
	for i = #st.results, 1, -1 do                                      -- (the follow-up came: their results are read)
		for _, x in ipairs(st.results[i].ids or {}) do if ids[x] then table.remove(st.results, i); break end end
	end
	local id = obj.agent
	if not PC.agentIdOk(id) then return end
	local err = type(obj.error) == "string" and obj.error or ""
	SetString(base(id) .. ".error", err)
	if err ~= "" then return end
	local text = type(obj.text) == "string" and obj.text or ""
	if text ~= "" then PC.call("pc_agentsay", id, text) end
	local idList = {}
	for x in pairs(ids) do idList[#idList + 1] = x end
	for _, call in ipairs(type(obj.calls) == "table" and obj.calls or {}) do
		if type(call) == "table" and type(call.name) == "string" and type(call.call) == "string" then
			st.callN = st.callN + 1
			local k = st.callN % PC.AGENT_CALLS
			local b = reg .. ".agentcall." .. k
			ClearKey(b)
			SetInt(b .. ".n", st.callN)
			SetString(b .. ".agent", id)
			SetString(b .. ".name", call.name)
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
