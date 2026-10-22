-- apicheck.lua - tells a game mod's maker when their mod sets a proxchat.* key wrongly (API.md), instead of the chat
-- quietly ignoring it (the user, 2026-10-11: "give helpful debug messages when the mod does something wrong").
-- A problem: DebugPrint "Proximity Comms: <key>: <what is wrong> - <the fix>" (on that machine's screen), the server
-- log hook (PC.log) and proxchat.problem (the last one, for a mod to read). Each problem once (the same key with the
-- same wrong value is not said again), at most PROBLEM_MAX in a session.
-- Checked: a key the chat doesn't read (a typo: "did you mean"), a player key named by something else than a player id,
-- a bool set as text that reads false, and the values the parsers refuse (ranges, devices, effects, avoid rectangles:
-- PC.problem from their readers). Included last (main.lua): the readers call PC.problem through a guard.

PC.PROBLEM_MAX = 20
PC.PROBLEM_EVERY = 2                                                   -- s between two scans of the keys (each machine)
-- the keys under proxchat. the chat reads or writes (lower case; API.md, and hostroom: voice.lua's own)
PC.API_KEYS = {version = true, alive = true, lobby = true, block = true, open = true, typing = true, ranges = true, device = true,
	tx = true, effects = true, channel = true, hearall = true, walls = true, said = true, avoid = true, hidebubbles = true,
	hostroom = true, problem = true, close = true, key = true, talking = true, team = true, noping = true, noglobal = true, aim = true, pingskip = true, pingcolor = true, pingto = true}   -- (pingto: API 14's, gone in 15 - kept known
	--  so a mod still setting it isn't told off on its players' screens; ignored)
-- the ones that hold one key per player: proxchat.<name>.<player id>
PC.API_PER_PLAYER = {typing = true, tx = true, channel = true, hearall = true, talking = true, team = true, pingcolor = true, pingto = true}
-- the bools (SetBool): a text in them that doesn't read true is a mistake
PC.API_BOOLS = {"lobby", "block", "walls", "hideBubbles", "noping", "noglobal"}

PC.problems = PC.problems or {seen = {}, n = 0, scanT = -1e9}

-- say one problem (once); key: the full registry key, why: what is wrong and how to fix it
function PC.problem(key, why)
	local P = PC.problems
	local id = key .. "\n" .. why
	if P.seen[id] then return end
	P.seen[id] = true
	P.n = P.n + 1
	if P.n > PC.PROBLEM_MAX then return end
	local msg = "Proximity Comms: " .. key .. ": " .. why
	if P.n == PC.PROBLEM_MAX then msg = msg .. " (no more of these this session)" end
	if DebugPrint then DebugPrint(msg) end
	PC.log(msg)
	SetString(PC.cfg.reg .. ".problem", msg)
end

-- a value as the message shows it (quoted, cut short)
function PC.problemValue(v)
	v = tostring(v)
	if #v > 60 then v = v:sub(1, 57) .. "..." end
	return '"' .. v .. '"'
end

-- the edit distance of two short strings (the "did you mean" of a typo)
function PC.editDistance(a, b)
	local prev = {}
	for j = 0, #b do prev[j] = j end
	for i = 1, #a do
		local cur = {[0] = i}
		for j = 1, #b do
			local cost = a:sub(i, i) == b:sub(j, j) and 0 or 1
			cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
		end
		prev = cur
	end
	return prev[#b]
end

-- the API key nearest to a wrong one (at most 2 edits away), or nil
function PC.nearestKey(k)
	local best, bd = nil, 3
	for name in pairs(PC.API_KEYS) do
		local d = PC.editDistance(k:lower(), name)
		if d < bd then best, bd = name, d end
	end
	return best and (best == "hidebubbles" and "hideBubbles" or best)
end

-- (every machine, every PROBLEM_EVERY s) the keys under proxchat. on this machine
function PC.apiCheckTick()
	local P, reg = PC.problems, PC.cfg.reg
	local now = GetTime()
	if now - P.scanT < PC.PROBLEM_EVERY then return end
	P.scanT = now
	local ok, keys = pcall(ListKeys, reg)
	if not ok or type(keys) ~= "table" then return end
	for _, k in ipairs(keys) do
		local low = k:lower()
		if not PC.API_KEYS[low] then
			local near = PC.nearestKey(k)
			PC.problem(reg .. "." .. k, "the chat doesn't read this key" .. (near and (" - did you mean " .. reg .. "." .. near .. "?")
				or " (API.md lists the keys)"))
		elseif PC.API_PER_PLAYER[low] then
			local okP, ps = pcall(ListKeys, reg .. "." .. k)
			if okP and type(ps) == "table" then
				for _, q in ipairs(ps) do
					if not q:match("^%d+$") then
						PC.problem(reg .. "." .. k .. "." .. q, "the last part must be a player id (a number from GetAllPlayers()), not "
							.. PC.problemValue(q))
					end
				end
			end
		end
	end
	for _, b in ipairs(PC.API_BOOLS) do
		local key = reg .. "." .. b
		local v = GetString(key)
		if v ~= "" and not GetBool(key) and v ~= "0" and v ~= "false" then
			PC.problem(key, PC.problemValue(v) .. " reads as false - set it with SetBool(\"" .. key .. "\", true)")
		end
	end
end
