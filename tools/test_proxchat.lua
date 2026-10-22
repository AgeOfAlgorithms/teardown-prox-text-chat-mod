-- Offline mock test of Proximity Chat. Run from proxchat/:
--   C:/Users/seann/miniconda3/envs/teardown/Library/bin/luajit.exe -joff tools/test_proxchat.lua
-- Each player is a separate "machine": its own environment (own PC table, server / client tables,
-- registry, sounds, drawn texts), like separate Lua states. Player 1 hosts: its `shared` is the real table.
-- Clients read `shared` through a proxy that DEEP-COPIES on every read (as the engine hands out fresh
-- copies), and their writes to it are errors. ServerCall is queued and delivered on the next step.
-- main.lua is loaded the way the engine does: "#version 2" dropped, #include inlined.
local MODDIR = arg[1] or "mods/proximity chat/"     -- (public repo: the mod is the repo root: luajit tools/test_proxchat.lua ./)
local FAILED, NCHECK = 0, 0
local function check(cond, msg)
	NCHECK = NCHECK + 1
	if cond then print("ok   " .. msg) else FAILED = FAILED + 1; print("FAIL " .. msg) end
end

local function readFile(p)
	local f = assert(io.open(p, "rb"), "missing " .. p)
	local s = f:read("*a")
	f:close()
	return s
end

local function preprocess(path)
	local out = {}
	for line in (readFile(path):gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do
		local inc = line:match('^#include%s+"(.-)"')
		if inc then out[#out + 1] = preprocess(MODDIR .. inc)
		elseif line:match("^#version") then out[#out + 1] = "-- " .. line
		else out[#out + 1] = line end
	end
	return table.concat(out, "\n")
end

local function deep(v)
	if type(v) ~= "table" then return v end
	local t = {}
	for k, x in pairs(v) do t[deep(k)] = deep(x) end
	return t
end

-- ---------------------------------------------------------------- the world
local W = {time = 0, pos = {}, names = {}, calls = {}, ccalls = {}, removed = {}, dropSay = 0, tooMany = {}}
local function Vec(x, y, z) return {x or 0, y or 0, z or 0} end
W.pos[1], W.pos[2], W.pos[3], W.pos[4], W.pos[5] = Vec(0, 0, 0), Vec(4, 0, 0), Vec(30, 0, 0), Vec(60, 0, 0), Vec(14, 0, 0)
for p = 1, 8 do W.names[p] = "P" .. p end

local MACHINES, HOST = {}, nil
local SRC = preprocess(MODDIR .. "main.lua")

local function machine(me, isHost, presetReg, prePC)
	local env = {reg = presetReg or {}, texts = {}, sounds = {}, keys = {}, values = {}, typed = "", focused = false, interactive = false, loads = {},
		mcount = {}, bcount = {}}
	local api = {}
	api.Vec = Vec
	api.VecAdd = function(a, b) return {a[1] + b[1], a[2] + b[2], a[3] + b[3]} end
	api.VecSub = function(a, b) return {a[1] - b[1], a[2] - b[2], a[3] - b[3]} end
	api.VecScale = function(a, s) return {a[1] * s, a[2] * s, a[3] * s} end
	api.VecLength = function(a) return math.sqrt(a[1] ^ 2 + a[2] ^ 2 + a[3] ^ 2) end
	api.VecNormalize = function(a) local l = api.VecLength(a); if l < 1e-9 then return Vec() end return api.VecScale(a, 1 / l) end
	api.VecCross = function(a, b) return {a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1]} end
	api.Transform = function(p) return {pos = p} end
	api.QuatEuler = function(x, y, z) return {x, y, z} end
	env.rotated = {}                                                  -- (heads.lua: RotateBone calls)
	api.GetPlayerAnimator = function(p) return 500 + (p or 0) end
	api.RotateBone = function(a, bone, q, w) env.rotated[#env.rotated + 1] = {a, bone, q} end
	api.GetLocalPlayer = function() return me end
	api.GetPlayerTransform = function(p) if not W.pos[p] then return nil end return {pos = deep(W.pos[p])} end
	api.GetCameraTransform = function() return {pos = api.VecAdd(api.VecAdd(W.pos[me], Vec(0, 1.7, 0)), env.camOffset or Vec(0, 0, 0))} end
	api.GetPlayerName = function(p) return W.names[p] end
	api.GetRemovedPlayers = function() local r = W.removed; return r end
	api.SetBool = function(k, v) env.reg[k] = v and true or false end
	api.GetBool = function(k) return env.reg[k] == true end
	api.HasFile = function(f)
		return ((f == "MOD/fonts/pangolin.ttf" or f == "MOD/fonts/notosanskr-regular.ttf") and not NO_FONT_FILE)
			or (env.files ~= nil and env.files[f] ~= nil)
	end
	api.SetInt = function(k, v) env.reg[k] = math.floor(v) end
	api.GetInt = function(k) return tonumber(env.reg[k]) or 0 end
	api.SetString = function(k, v) env.reg[k] = tostring(v) end
	api.SetFloat = function(k, v) env.reg[k] = tonumber(v) end
	api.GetFloat = function(k) return tonumber(env.reg[k]) or 0 end
	api.HasKey = function(k) return env.reg[k] ~= nil end
	api.GetString = function(k) local v = env.reg[k]; if v == nil then return "" end return tostring(v) end
	api.ListKeys = function(k)
		local out, seen = {}, {}
		for key in pairs(env.reg) do
			if key:sub(1, #k + 1) == k .. "." then
				local child = key:sub(#k + 2):match("^[^%.]+")
				if child and not seen[child] then seen[child] = true; out[#out + 1] = child end
			end
		end
		return out
	end
	api.ClearKey = function(k) for key in pairs(env.reg) do if key == k or key:sub(1, #k + 1) == k .. "." then env.reg[key] = nil end end end
	api.GetTime = function() return W.time end
	env.debug = {}                                                    -- (DebugPrint: apicheck.lua's problems)
	api.DebugPrint = function(s) env.debug[#env.debug + 1] = tostring(s) end
	api.LoadSound = function(path) env.loads[#env.loads + 1] = path; return #env.loads end
	api.PlaySound = function(h, pos, vol, reg, pitch) env.sounds[#env.sounds + 1] = {h = h, pos = pos, vol = vol, pitch = pitch} end
	-- (W.tooMany: calls with more than 8 arguments - noted, not dropped: whether the game has such a limit is unknown)
	api.ServerCall = function(name, ...)
		if select("#", ...) > 8 then W.tooMany[#W.tooMany + 1] = name end
		W.calls[#W.calls + 1] = {name = name:match("^server%.(.+)$"), args = deep({...}), n = select("#", ...)}
	end
	api.ClientCall = function(p, name, ...)
		if select("#", ...) > 8 then W.tooMany[#W.tooMany + 1] = name end
		W.ccalls[#W.ccalls + 1] = {p = p, name = name:match("^client%.(.+)$"), args = deep({...}), n = select("#", ...)}
	end
	api.GetAllPlayers = function()                              -- (the engine's; Players() is only in an include the mod does not use)
		local list = {}
		for _, m in ipairs(MACHINES) do if W.pos[m.me] then list[#list + 1] = m.me end end
		return list
	end
	api.InputPressed = function(k) return env.keys[k] == true end
	api.InputDown = function(k) return (env.held and env.held[k]) == true end
	api.UiGetMousePos = function() return env.mouseX or 0, env.mouseY or 0 end
	api.IsPlayerHost = function(p) if p == nil or p == 0 then return isHost == true end return p == 1 end
	api.IsPlayerValid = function(p) return W.pos[p] ~= nil end
	api.InputValue = function(k) return env.values[k] or 0 end
	api.UiTextInput = function(str, w, h, focus)
		env.fieldCalled = true
		if focus then env.focused = true end
		if not env.focused then return str, false end
		local t = str
		for ch in env.typed:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
			if ch == "\b" then t = t:gsub("[%z\1-\127\194-\244][\128-\191]*$", "") else t = t .. ch end
		end
		env.typed = ""
		return t, true
	end
	for _, f in ipairs({"UiTranslate", "UiAlign", "UiColor", "UiRoundedRect", "UiRoundedRectOutline", "UiFont",
		"UiTextShadow", "UiScale", "UiRect", "UiRotate", "UiWindow"}) do api[f] = function() end end
	-- UiTextDisableWildcards is part of the UI state: UiPush keeps it, UiPop restores it (as the game's own example)
	env.wildOff, env.uiStack, env.wildTexts = false, {}, {}
	api.UiPush = function() env.uiStack[#env.uiStack + 1] = env.wildOff end
	api.UiPop = function() env.wildOff = table.remove(env.uiStack) or false end
	api.UiTextDisableWildcards = function(on) env.wildOff = on == true end
	api.UiWordWrap = function(w) env.wrap = w end
	api.UiMakeInteractive = function() env.interactive = true end
	api.UiText = function(s)
		env.texts[#env.texts + 1] = s
		if not env.wildOff then env.wildTexts[#env.wildTexts + 1] = s end      -- (drawn with UiText's [[...]] markup live)
	end
	api.UiGetTextSize = function(s)
		if not env.wildOff then env.wildSized = (env.wildSized or 0) + 1 end
		local w = #s * 10
		local lines = (env.wrap and env.wrap > 0) and math.max(1, math.ceil(w / env.wrap)) or 1
		return math.min(w, env.wrap or w), 24 * lines
	end
	api.UiHeight = function() return 1080 end
	api.UiWidth = function() return 1920 end
	api.UiWorldToPixel = function()
		if env.offscreen then return -400, 300, -10 end
		if env.pixel then return env.pixel[1], env.pixel[2], 10 end
		return 500, 300, 10
	end
	api.TransformToLocalPoint = function(t, p)                 -- (env.yaw: the camera turned that many degrees to the right)
		local v = api.VecSub(p, t.pos)
		local th = math.rad(env.yaw or 0)
		local fx, fz, rx, rz = math.sin(th), -math.cos(th), math.cos(th), math.sin(th)
		return {v[1] * rx + v[3] * rz, v[2], -(v[1] * fx + v[3] * fz)}
	end
	api.TransformToParentVec = function(t, v) return v end
	-- rays hit W.boxes ({lo = Vec, hi = Vec}: walls, floors, poles); the path planner answers W.pathAround
	-- (a length: "done"; nil: "fail"; W.pathBusy: "busy")
	local function rayBox(o, d, L, b)
		local t0, t1 = 0, L
		for i = 1, 3 do
			if math.abs(d[i]) < 1e-9 then
				if o[i] < b.lo[i] or o[i] > b.hi[i] then return nil end
			else
				local a, c = (b.lo[i] - o[i]) / d[i], (b.hi[i] - o[i]) / d[i]
				if a > c then a, c = c, a end
				t0, t1 = math.max(t0, a), math.min(t1, c)
				if t0 > t1 then return nil end
			end
		end
		return t0
	end
	api.QueryRequire = function() end
	-- (pings, ping.lua: the camera looks along -z; W.health / W.color per player; UiSound noted)
	api.GetPlayerCameraTransform = function() return api.GetCameraTransform() end
	api.GetPlayerHealth = function(p) p = (p == nil or p == 0) and me or p; return (W.health and W.health[p]) or 1 end
	api.GetPlayerColor = function(p)
		local col = W.color and W.color[(p == nil or p == 0) and me or p]
		if col then return true, col[1], col[2], col[3] end
		return false, 1, 1, 1
	end
	api.QueryRejectAnimator = function(a) env.rejected = a end
	api.QueryRejectVehicle = function() end
	api.QueryRejectBody = function(b) env.rejectedBodies = env.rejectedBodies or {}; env.rejectedBodies[#env.rejectedBodies + 1] = b end
	api.GetPlayerVehicle = function() return 0 end
	env.uiSounds = {}
	api.UiSound = function(path) env.uiSounds[#env.uiSounds + 1] = path end
	api.UiImageBox = function() end
	api.QueryRaycast = function(o, d, L)
		env.rays = (env.rays or 0) + 1
		local best
		for _, b in ipairs(W.boxes or {}) do
			local t = rayBox(o, d, L or 1e9, b)
			if t and (not best or t < best) then best = t end
		end
		if best then return true, best, Vec(0, 1, 0), 1 end
		return false, 0
	end
	api.CreatePathPlanner = function() env.planners = (env.planners or 0) + 1; return env.planners end
	api.PathPlannerQuery = function() env.pathAsked = (env.pathAsked or 0) + 1 end
	api.GetPathState = function() if W.pathBusy then return "busy" end return W.pathAround and "done" or "fail" end
	api.GetPathLength = function() return W.pathAround or 0 end
	env.spawned, env.deleted = {}, {}
	api.Spawn = function(xml, t, static)
		if xml:find("tags='pcdiag", 1, true) then                    -- (main.lua's diagnostics: a log line, not a thing)
			env.diag = env.diag or {}
			env.diag[#env.diag + 1] = xml
			if os.getenv("PCDIAG") and xml:find("error", 1, true) then io.stderr:write(xml, "\n") end
			return {}
		end
		if xml:sub(1, 4) == "MOD/" then                             -- (a prefab file: one body carrying the file's tag)
			local tag = env.files and env.files[xml]
			if tag == nil then error("no such prefab " .. xml) end
			env.prefabN = (env.prefabN or 0) + 1
			env.prefabTag = env.prefabTag or {}
			env.prefabTag[5000 + env.prefabN] = tag
			return {5000 + env.prefabN}
		end
		env.spawned[#env.spawned + 1] = {xml = xml, t = t, static = static}
		return {900 + #env.spawned}
	end
	api.GetTagValue = function(h, k)
		local t = env.prefabTag and env.prefabTag[h]
		if type(t) == "table" then return t[k] or "" end
		return (k == "t" and type(t) == "string") and t or ""
	end
	api.Delete = function(h) env.deleted[h] = true end
	-- the mouse: env.hover = {w, h, n} is over the n-th rect of that size drawn this frame;
	-- UiBlankButton fires (on release) there when env.release is set
	local function over(counts, w, h)
		local key = w .. "x" .. h
		counts[key] = (counts[key] or 0) + 1
		local hv = env.hover
		return hv ~= nil and hv[1] == w and hv[2] == h and hv[3] == counts[key]
	end
	api.UiIsMouseInRect = function(w, h) return over(env.mcount, w, h) end
	api.UiBlankButton = function(w, h) return over(env.bcount, w, h) and env.release == true end
	for k, v in pairs(api) do env[k] = v end
	env.server, env.client = {}, {}
	if isHost then
		-- (strict: on the host too a read of shared hands out a copy, so only shared.x = t is kept - the mod must not rely
		--  on writing one key of a shared table, whose effect in the game is not known)
		local raw = {}
		env.sharedRaw = raw
		env.shared = setmetatable({}, {
			__index = function(_, k) return deep(raw[k]) end,
			__newindex = function(_, k, v) raw[k] = deep(v) end,
		})
	else
		env.shared = setmetatable({}, {
			__index = function(_, k) return deep(HOST.sharedRaw[k]) end,               -- a fresh copy each read
			__newindex = function(_, k) error("client wrote shared." .. tostring(k)) end,
		})
	end
	setmetatable(env, {__index = _G})
	env.PC = prePC                                                -- (a host mod's PC.cfg before the include)
	local before = {}
	for k in pairs(env) do before[k] = true end
	local chunk = assert(loadstring(SRC, "main.lua"))
	setfenv(chunk, env)
	chunk()
	local added = {}
	for k in pairs(env) do if not before[k] then added[#added + 1] = k end end
	table.sort(added)
	env.added = added
	env.me = me
	return env
end

local function addMachine(me, isHost, presetReg, prePC)
	local env = machine(me, isHost, presetReg, prePC)
	MACHINES[#MACHINES + 1] = env
	if isHost then HOST = env; env.server.init() end
	env.client.init()
	return env
end

-- one frame on every machine: deliver the queued ServerCalls, server tick, then each client tick + draw
local function step(dt)
	dt = dt or 1 / 60
	W.time = W.time + dt
	local calls = W.calls
	W.calls = {}
	for _, c in ipairs(calls) do
		if c.name == "pc_say" and W.dropSay > 0 then W.dropSay = W.dropSay - 1      -- (a lost message)
		else HOST.server[c.name](unpack(c.args, 1, c.n)) end
	end
	HOST.server.tick(dt)
	local cc = W.ccalls
	W.ccalls = {}
	for _, c in ipairs(cc) do
		if W.clog then W.clog[#W.clog + 1] = c end                        -- (a test watching what the server sent to whom)
		for _, m in ipairs(MACHINES) do
			if c.p == 0 or c.p == m.me then m.client[c.name](unpack(c.args, 1, c.n)) end
		end
	end
	W.removed = {}
	for _, m in ipairs(MACHINES) do
		m.client.tick(dt)
		m.texts, m.interactive, m.fieldCalled, m.mcount, m.bcount, m.wildTexts, m.wildSized = {}, false, false, {}, {}, {}, 0
		m.client.draw()
		if not m.fieldCalled then m.focused = false end
		m.keys, m.values, m.release = {}, {}, nil
	end
end
local function steps(n, dt) for _ = 1, n do step(dt) end end
local function press(m, key) m.keys[key] = true; step() end
local function typeText(m, s) m.typed = s; step() end
local function say(m, s) press(m, "return"); typeText(m, s); press(m, "return"); step() end
local function drawn(m, pat, plain)
	for _, t in ipairs(m.texts) do if t:find(pat, 1, plain) then return t end end
	return nil
end
local function hist(m, ch) return m.PC.history(ch) end
local function lastLine(m, ch) local h = hist(m, ch); return h[#h] end
local function hasLine(m, ch, text)
	for _, e in ipairs(hist(m, ch)) do if e.text == text then return true end end
	return false
end
local function waitRate() steps(30, 1 / 60) end                       -- (0.5 s: past the rate limit)

-- ================================================================== setup
-- P1 host (0 m), P2 (4 m), P5 (14 m: 10 m from P2), P3 (30 m: 26 m from P2), P4 (60 m)
local function clipOf(m, s) return m.loads[s.h] or "?" end
local function soundsFrom(m, x, pat)                              -- sounds at a head at x (y 1.7) whose clip matches pat
	local n, vmax = 0, 0
	for _, s in ipairs(m.sounds) do
		if math.abs(s.pos[1] - x) < 0.01 and math.abs(s.pos[2] - 1.7) < 0.01 and math.abs(s.pos[3]) < 0.01 and (not pat or clipOf(m, s):find(pat)) then
			n = n + 1; vmax = math.max(vmax, s.vol)
		end
	end
	return n, vmax
end
-- sounds of a far speaker (at x on the x axis): played 5 m from the listener's camera, toward the speaker
local function soundsToward(m, x, pat)
	local me = W.pos[m.me]
	local cam = {me[1], me[2] + 1.7, me[3]}
	local n, vmax = 0, 0
	for _, s in ipairs(m.sounds) do
		local d = {s.pos[1] - cam[1], s.pos[2] - cam[2], s.pos[3] - cam[3]}
		local l = math.sqrt(d[1] ^ 2 + d[2] ^ 2 + d[3] ^ 2)
		if math.abs(l - 5) < 0.05 and d[1] * (x - cam[1]) > 0 and (not pat or clipOf(m, s):find(pat)) then
			n = n + 1; vmax = math.max(vmax, s.vol)
		end
	end
	return n, vmax
end
local P1 = addMachine(1, true)
local P2 = addMachine(2, false)
local P3 = addMachine(3, false)
local P4 = addMachine(4, false, {["savegame.mod.pcvoice"] = 5})       -- (the Options pick: Deep)
local P5 = addMachine(5, false)
step()
steps(40)                                                          -- (the host's entropy warm-up: every guest gets its token)
-- (a direct call to a server.pc_* function, as a player's own game makes it: with that player's token)
function TOK(p) return HOST.PC.s.tok[p] end                      -- (a global: the main chunk is at its 200 locals)
check(TOK(1) and TOK(2) and TOK(5) and P2.PC.c.tok == TOK(2) and P5.PC.c.tok == TOK(5) and TOK(2) ~= TOK(5) and #TOK(2) == 32,
	"TRUST: every player's game got its own session token from the host (" .. tostring(TOK(2)) .. ")")

check(P1.added[1] == "PC" and #P1.added == 1 and #P2.added == 1, "namespaced: the only new global is PC (" .. table.concat(P1.added, ",") .. ")")
local names = {}
for k in pairs(P1.server) do names[#names + 1] = k end
table.sort(names)
local okNames = true
for _, k in ipairs(names) do if not (k:match("^pc_") or k == "init" or k == "tick") then okNames = false end end
check(okNames, "server functions are server.pc_* (+ init / tick): " .. table.concat(names, ","))
local sharedOk = true
for k in pairs(P1.shared) do if not k:match("^pc") then sharedOk = false end end
check(sharedOk, "shared keys all start with pc")
local clipsOk, nWhisper, nDev = #P2.loads == 48, 0, 0
for _, p in ipairs(P2.loads) do
	local f = io.open(MODDIR .. p:gsub("^MOD/", ""), "rb")
	if f then f:close() else clipsOk = false; print("     missing clip " .. p) end
	if p:find("whisper") then nWhisper = nWhisper + 1 end
	if p:find("radio") or p:find("horn") then nDev = nDev + 1 end
end
check(clipsOk and nWhisper == 12 and nDev == 16, "all 48 clips load from snd/ and exist (12 whisper / Robot-whisper, 16 device: radio / horn)")
check(P2.shared.pcMsgs ~= P2.shared.pcMsgs and type(P2.shared.pcMsgs) == "table", "mock: every client read of shared is a fresh copy")
check(drawn(P2, "^Proximity Comms %- Enter: talk to players near you %(Tab: Whisper / Speak / Yell / Global%)") ~= nil, "intro hint on screen")

-- ================================================================== the input line: modes, chips, Tab
press(P2, "return")
check(P2.PC.c.typing and P2.interactive, "Enter opens the line (UiMakeInteractive: cursor)")
check(P2.reg["proxchat.typing.2"] == true, "the typing flag is in P2's own registry the same frame the line opens")
step()
check(P2.interactive and P2.focused, "while typing: interactive, the field has the keyboard")
check(P1.PC.isTyping(2) and P1.reg["proxchat.typing.2"] == true, "the server knows P2 types (PC.isTyping, registry proxchat.typing.2)")
check(P2.reg["proxchat.typing.2"] == true and P3.reg["proxchat.typing.2"] ~= true, "P2's own game has it too (a guest's client script can read it); nobody else's")
check(drawn(P2, "^Speak: $") and drawn(P2, "^Speak$") and drawn(P2, "^Wsp$") and drawn(P2, "^Yel$") and drawn(P2, "^Glb$") and not drawn(P2, "^Spk$")
	and not drawn(P2, "^Whisper$"), "the line: 'Speak:' and the four mode chips - the selected one in full (Speak), the others short (Wsp / Yel / Glb)")
local chipOrder = {}
for _, t in ipairs(P2.texts) do if t == "Wsp" or t == "Speak" or t == "Yel" or t == "Glb" then chipOrder[#chipOrder + 1] = t end end
check(table.concat(chipOrder, " ") == "Wsp Speak Yel Glb", "the chips in Tab order: " .. table.concat(chipOrder, " "))
check(drawn(P2, "^Chat$") and drawn(P2, "^Settings$") and not drawn(P2, "^Proximity$"), "the window: one history ('Chat'), a Settings button, no history tabs")
check(drawn(P1, "...", true) ~= nil and not drawn(P3, "^%.%.%.$"), "P1 (4 m) sees P2's '...' typing bubble, P3 (26 m) does not")
press(P2, "tab")
check(P2.PC.mode() == "y" and drawn(P2, "^Yell: $"), "Tab from Speak: 'Yell:' (the same frame)")
step()
check(P1.PC.s.typing[2] == "y" and P2.reg["savegame.mod.pcmode"] == "y", "the server knows P2 yells; the mode is saved as P2's default")
press(P2, "tab")
check(P2.PC.mode() == "g" and drawn(P2, "^Global: $"), "Tab: 'Global:'")
press(P2, "tab")
check(P2.PC.mode() == "w" and drawn(P2, "^Whisper: $"), "Tab: round to 'Whisper:' (no distance in the prompt)")
typeText(P2, "\t"); step()
check(P2.PC.mode() == "s" and P2.PC.c.text == "" and drawn(P2, "^Speak: $"), "a Tab returned by the field: on to Speak (no tab character typed)")
P2.keys.tab = true; typeText(P2, "\t")
check(P2.PC.mode() == "y", "the Tab key and a field Tab in one frame move one mode, not two")
P2.hover = {56, 34, 3}; P2.keys.lmb = true; step()                 -- (press on the Global chip: the 3rd small one, Yell is selected)
P2.release = true; step()                                       -- (its release: ignored - though the chips moved and
                                                                -- the 3rd small one under the mouse is Yell now)
P2.hover = nil
check(P2.PC.mode() == "g" and drawn(P2, "^Global: $") and drawn(P2, "^Global$") and drawn(P2, "^Yel$") and not drawn(P2, "^Glb$"),
	"clicking the Global chip (press fires, release de-duplicated): now it is the full-size one, Yell short")
P2.hover = {56, 34, 2}; P2.release = true; step(); P2.hover = nil
check(P2.PC.mode() == "s", "a release alone on the Speak chip (2nd) also works (UiBlankButton fallback)")
P2.hover = {56, 34, 1}; step(); P2.hover = nil
check(P2.PC.mode() == "s", "hovering a chip does not change the mode")

-- ================================================================== nearby: typing, sending, hearing
-- (what the server sent to whom: W.clog collects the delivered ClientCalls)
function W.sentTo(text)                                         -- {player = the client function} that carried this text
	local to = {}
	for _, c in ipairs(W.clog or {}) do
		for i = 1, c.n do if c.args[i] == text then to[c.p] = c.name end end
	end
	return to
end
function W.inShared(text)
	for _, m in ipairs(HOST.shared.pcMsgs or {}) do if m.text == text then return true end end
	return false
end
typeText(P2, "hellp")
typeText(P2, "\bo there")
check(P2.PC.c.text == "hello there", "UiTextInput returns the edited text, Backspace works (" .. P2.PC.c.text .. ")")
W.clog = {}
press(P2, "return")
check(not P2.PC.c.typing, "Enter says it and closes the line")
step()
do
	local to0 = W.sentTo("hello there")
	check(not W.inShared("hello there") and to0[1] == "pc_near" and to0[2] == "pc_near" and to0[3] == "pc_near" and to0[5] == "pc_near" and to0[4] == nil,
		"Speak is not in shared: the server sends it to the players within 35 + 20 m (P1, P2 itself, P5, P3 at 26 m), not P4 (56 m) (changed 2026-10-07: it was in shared.pcMsgs)")
end
W.clog = nil
check(hasLine(P1, "s", "hello there") and hasLine(P5, "s", "hello there") and hasLine(P2, "s", "hello there"), "P1 (4 m), P5 (10 m) and P2 itself have it")
local BOX = "\226\172\154"
local function garbled(t) return t and t:find(BOX, 1, true) ~= nil end
check(#hist(P4) == 0 and #hist(P3) == 1 and hist(P3)[1].far and garbled(hist(P3)[1].text), "P4 (56 m) got nothing; P3 (26 m, the buffer) a garbled history line: " .. tostring(hist(P3)[1] and hist(P3)[1].text))
check(P1.PC.c.bubbles[2] and P1.PC.c.bubbles[2].text == "hello there" and not P1.PC.c.bubbles[2].whisper, "P1 has a normal speech bubble over P2")
check(drawn(P1, "^%[speak%] $") and drawn(P1, "^P2: $") and drawn(P1, "^hello there$"), "P1's feed: '[speak] P2: hello there'")
P1.sounds, P4.sounds, P3.sounds = {}, {}, {}
steps(60)
local nb = soundsFrom(P1, 4, "babble")
check(nb >= 4, "P1 hears the babble at P2's head (" .. nb .. " syllables)")
check(#P4.sounds == 0, "P4 hears no babble")
check(P3.PC.c.bubbles[2] and P3.PC.c.bubbles[2].mumble and #hist(P3) == 1 and hist(P3)[1].text ~= "hello there", "P3 (26 m, the buffer): a garbled bubble; its history line is what P3 made out, not the words")
local nfar, vfar = soundsToward(P3, 4, "babble")
check(nfar >= 4 and vfar > 0.75 * 0.4, string.format("P3 hears the babble from the buffer: 5 m away in P2's direction, at %.2f (not faded out)", vfar))
waitRate()
press(P2, "return"); typeText(P2, "second line\n"); step(); step()
check(lastLine(P1, "s").text == "second line" and not P2.PC.c.typing, "a newline returned by the field sends too")
check(P2.reg["proxchat.typing.2"] == false, "sent and closed: P2's own game clears its typing flag")
waitRate()
say(P2, "/y please help me now")
local l1 = lastLine(P1, "y")
check(l1 and l1.text == "please help me now" and l1.shout and P1.PC.c.bubbles[2].shout and P2.PC.mode() == "s",
	"/y says one line in Yell (the mode stays Speak): P1 has it, a Yell bubble")
local l3 = lastLine(P3, "y")
check(l3 and l3.text == "please help me now" and not l3.far, "a yell reaches P3 (26 m) in full: Yell carries 40 m")
check(#hist(P4) == 0, "P4 (56 m, past 55) hears nothing")
waitRate()
say(P2, "everyone come HERE!!")
check(lastLine(P3, "s").text ~= "everyone come HERE!!" and garbled(lastLine(P3, "s").text) and not lastLine(P3, "s").shout,
	"no word-level shouting: CAPS and !! in Speak stay Speak (garbled at 26 m)")
steps(150)                                                       -- (the last babble is over)
P1.sounds = {}
say(P2, "/y come here now")
steps(60)
local nPlain = soundsFrom(P1, 4, "babble")
local nShout, vShout = soundsFrom(P1, 4, "shout")
check(nPlain == 0 and nShout >= 4 and vShout <= 0.801, string.format("Yell babbles every syllable in the raised voice (%d, vol %.2f, cfg 0.8)", nShout, vShout))
W.pos[4] = Vec(8, 0, 0); steps(5)
-- the event API: the host's registry gets every message (proxchat.said.*) for other mods (titans...)
local said = P1.reg["proxchat.said.last"]
local sk = "proxchat.said." .. (said % 16) .. "."
check(said and said >= 3 and P1.reg[sk .. "player"] == 2 and P1.reg[sk .. "mode"] == "yell" and P1.reg[sk .. "yell"] == true
	and P1.reg[sk .. "text"] == "come here now" and P1.reg[sk .. "radius"] == 55 and P1.reg[sk .. "wordsRadius"] == 40
	and math.abs(P1.reg[sk .. "x"] - 4) < 0.01 and P1.reg[sk .. "lobby"] == false,
	"API: the host's registry has the event (proxchat.said.<n>: player 2, yell, at x = 4, words to 40 m, babble to 55 m)")
local pk = "proxchat.said." .. ((said - 1) % 16) .. "."
check(P1.reg[pk .. "text"] == "everyone come HERE!!" and P1.reg[pk .. "mode"] == "speak" and P1.reg[pk .. "yell"] == false and P1.reg[pk .. "radius"] == 35,
	"API: the one before it is kept too (a ring of 16): Speak, 35 m")
check(P2.reg["proxchat.said.last"] == nil, "API: host only (clients do not run the server)")
check(#hist(P4) == 1 and lastLine(P4, "y").text == "come here now", "P4 walked over while P2's last bubble was up: it shows, in full, and joins P4's history (older ones: no)")
waitRate()
say(P2, "now you are close")
check(lastLine(P4, "s").text == "now you are close", "P4 near P2 now: hears the new message")
W.pos[4] = Vec(60, 0, 0); steps(5)
check(lastLine(P4, "s").text == "now you are close", "P4 walked away: its history keeps what it heard")

-- ================================================================== whisper (5 m, no shouting, breathy)
steps(60 * 10)                                                   -- (the last bubbles and babble are over)
press(P2, "return"); press(P2, "tab"); press(P2, "tab"); press(P2, "tab")
check(P2.PC.mode() == "w", "P2 switches to whisper (Tab: Yell, Global, Whisper)")
step()
check(drawn(P1, "^%.%.%.$") ~= nil and not drawn(P5, "^%.%.%.$"), "the whisper '...' shows to P1 (4 m), not to P5 (10 m)")
waitRate()
typeText(P2, "psst the SECRET plan")
P1.sounds, P5.sounds = {}, {}
press(P2, "return"); step()
local lw = lastLine(P1, "w")
local inShared = false
for _, m in ipairs(P1.shared.pcMsgs) do if m.text == "psst the SECRET plan" then inShared = true end end
check(lw and lw.text == "psst the SECRET plan" and not lw.shout and not inShared,
	"P1 (4 m) gets the whole whisper; CAPS stay a whisper; the whisper is not in the shared messages (private)")
check(not hasLine(P5, "w", "psst the SECRET plan") and #hist(P5, "w") == 1 and garbled(lastLine(P5, "w").text) and #hist(P3, "w") == 0,
	"P5 (10 m: the whisper buffer) gets only a garbled history line; P3 (26 m) nothing")
check(hasLine(P2, "w", "psst the SECRET plan"), "the whisperer has it")
check(P1.PC.c.bubbles[2] and P1.PC.c.bubbles[2].whisper and not P1.PC.c.bubbles[2].shout, "P1 sees a whisper bubble (small, faint)")
check(drawn(P1, "^%[whisper%] $") ~= nil, "P1's feed marks it [whisper]")
steps(60)
local nw, vw = soundsFrom(P1, 4, "MOD/snd/whisper")
local nOther = #P1.sounds - nw
check(nw >= 4 and vw <= 0.451 and nOther == 0, string.format("whisper babble: breathy clips at P2's head, quiet (%d syllables, vol %.2f), no echo, no shout clips", nw, vw))
check(soundsToward(P5, 4, "whisper") >= 2 and P5.PC.c.bubbles[2] and P5.PC.c.bubbles[2].mumble, "P5 (10 m: the whisper buffer, 8-13 m) hears the breathy babble and gets a garbled bubble")
check(P2.PC.mode() == "w" and P2.reg["savegame.mod.pcmode"] == "w", "the mode sticks for the next line (and is saved)")
P1.server.pc_voice(2, TOK(2), 6)                                         -- (P2 picks Robot)
steps(2)
waitRate()
P1.sounds = {}
P2.PC.say("robot whisper", "w"); step(); steps(60)
local nr = soundsFrom(P1, 4, "rwhisper")
check(nr >= 3 and soundsFrom(P1, 4, "MOD/snd/whisper") == 0, "the Robot voice whispers with the crushed hiss clips (rwhisper, " .. nr .. ")")
P1.server.pc_voice(2, TOK(2), 5)
local q = {}
P1.PC.babbleSay(2, "abc", 1, "whisper"); q[1] = P1.PC.c.babble.queue[2].pitch
P1.PC.babbleSay(2, "abc", 5, "whisper"); q[2] = P1.PC.c.babble.queue[2].pitch
P1.PC.c.babble.queue[2] = nil
check(q[1] > 1.1 and q[2] < 0.9, string.format("the voice's pitch still shifts the whisper (Squeaky %.2f, Deep %.2f)", q[1], q[2]))

-- ================================================================== everyone
waitRate()
press(P3, "return"); press(P3, "tab"); press(P3, "tab")
check(P3.PC.mode() == "g" and drawn(P3, "^Global: $"), "P3: Tab twice from Speak = Global")
typeText(P3, "hi all")
P1.sounds, P4.sounds = {}, {}
press(P3, "return"); step()
for _, M in ipairs({P1, P2, P3, P4, P5}) do
	check(lastLine(M, "g") and lastLine(M, "g").text == "hi all", "P" .. M.me .. " has the everyone line")
end
check(not P1.PC.c.bubbles[3] and not P4.PC.c.bubbles[3], "Global: no bubble")
P4.sounds = {}; P1.sounds = {}
steps(60)
check(#P4.sounds == 0 and #P1.sounds == 0, "Global: no babble either (a plain chat line)")

-- ================================================================== one history per player, different
local function modes(M) local t = {} for _, e in ipairs(hist(M)) do t[#t + 1] = e.ch end return table.concat(t, " ") end
check(modes(P1) == "s s y s y s w w g", "P1's history: nearby, whispers, everyone, in order: " .. modes(P1))
check(modes(P5) == "s s y s y s w w g", "P5 (10 m): the Speak lines, the whispers garbled (its buffer), Global: " .. modes(P5))
check(modes(P3) == "s s y s y s g", "P3 (26 m): the Speak lines as far as it made them out, the shouts, Global: " .. modes(P3))
check(modes(P4) == "y s g", "P4: the bubble it walked into, what it heard while close, Global: " .. modes(P4))
local n1 = #hist(P1)
steps(120)
check(#hist(P1) == n1, "no message is received twice although every shared read is a new table")
press(P1, "return"); step()
check(drawn(P1, "^%[speak%] $") and drawn(P1, "^%[whisper%] $") and drawn(P1, "^%[global%] $") and drawn(P1, "^psst the SECRET plan$") and drawn(P1, "^hi all$"),
	"P1's window shows one history with [speak] / [whisper] / [global] tags")
press(P1, "esc"); step()
check(not P1.PC.c.typing and not drawn(P1, "^Chat$") and not drawn(P1, "^Say "), "Esc closes the line and the window")

-- ================================================================== the buffer range: "..." until you come closer
waitRate()
say(P2, "/s meet me at the tower")
local n3 = #hist(P3)
check(P3.PC.c.bubbles[2].mumble and lastLine(P3, "s").text ~= "meet me at the tower", "P3 (26 m): no words in the history")
local function letters(t) local n = 0 for _ in t:gmatch("[a-z]") do n = n + 1 end return n end
local G = P3.PC.garble
local g0 = G("meet me at the tower!", 0, 7, 0)
check(letters(g0) == 0 and g0:find("!$") and select(2, g0:gsub(" ", " ")) == 4 and P3.PC.utf8Len(g0) == 21, "garble at 0: every letter a glyph; spaces, punctuation and length stay: " .. g0)
check(G("meet me at the tower!", 1, 7, 0) == "meet me at the tower!", "garble at 1: the message")
local function shown(t) local o, i = {}, 0 for ch in t:gmatch(P3.PC.UTF8_CHAR) do i = i + 1; if ch:find("[a-z]") then o[i] = true end end return o end
local a3, a6, sub = shown(G("meet me at the tower now", 0.3, 9, 0)), shown(G("meet me at the tower now", 0.6, 9, 5)), true
for i in pairs(a3) do if not a6[i] then sub = false end end
check(sub, "closer only adds letters (the same ones stay)")
check(g0 == "\226\172\154\226\172\154\226\172\154\226\172\154 \226\172\154\226\172\154 \226\172\154\226\172\154 \226\172\154\226\172\154\226\172\154 \226\172\154\226\172\154\226\172\154\226\172\154\226\172\154!"
	and P3.PC.bubbleFont(g0) == "MOD/fonts/pangolin.ttf" and P3.PC.chatFont(g0) == "bold_sc.ttf",
	"the mystery letters are all U+2B1A, in our Pangolin (without it: bold_sc, the game font that has the glyph)")
local bm = P3.PC.c.bubbles[2]
W.pos[3] = Vec(38, 0, 0); local tFar = P3.PC.bubbleText(2, bm, 0)     -- (34 m)
W.pos[3] = Vec(30, 0, 0); local tNear = P3.PC.bubbleText(2, bm, 0)    -- (26 m)
W.pos[3] = Vec(30, 0, 0)
check(letters(tFar) < letters(tNear) and letters(tNear) < 16 and P3.PC.utf8Len(tNear) == 20,
	string.format("the bubble from 34 m: %s / from 26 m: %s (more letters closer, never all)", tFar, tNear))
W.pos[3] = Vec(20, 0, 0); step(); step()                            -- (16 m from P2)
local b3 = P3.PC.c.bubbles[2]
check(b3 and not b3.mumble and b3.text == "meet me at the tower" and lastLine(P3, "s").text == "meet me at the tower" and #hist(P3) == n3,
	"P3 walks into range while the bubble is up: the words show; its garbled history line becomes the words")
steps(5)
check(#hist(P3) == n3, "... the same line, not a second one")
W.pos[3] = Vec(30, 0, 0)
waitRate()
say(P2, "/s the key is here")
check(garbled(lastLine(P3, "s").text) and #hist(P3) == n3 + 1, "a Speak line from 26 m: garbled")
W.pos[3] = Vec(20, 0, 0); step(); step()
check(lastLine(P3, "s").text == "the key is here" and not lastLine(P3, "s").far and #hist(P3) == n3 + 1, "closer: that history line is completed (not a second one)")
-- Yell's own buffer, 40-55 m: garbled like any buffer (more letters closer)
W.pos[3] = Vec(58, 0, 0)                                            -- (54 m)
waitRate()
say(P2, "/y come here right now")
local bs5 = P3.PC.c.bubbles[2]
local t54 = bs5 and P3.PC.bubbleText(2, bs5, W.time) or ""
check(bs5 and bs5.level == "mumble" and bs5.shout and not bs5.hidden and garbled(t54) and garbled(lastLine(P3, "y").text),
	"54 m: a Yell bubble, garbled, a history line too: " .. t54)
W.pos[3] = Vec(46, 0, 0); step(); step()                            -- (42 m)
local t42 = P3.PC.bubbleText(2, bs5, W.time)
check(letters(t42) > letters(t54) and garbled(t42), "42 m: more of it, still not all: " .. t42)
W.pos[3] = Vec(43, 0, 0); step(); step()                            -- (39 m)
check(bs5.level == "full" and P3.PC.bubbleText(2, bs5, W.time) == "come here right now" and lastLine(P3, "y").text == "come here right now",
	"39 m (within 40): the words in full; the same history line")
W.pos[3] = Vec(64, 0, 0)                                            -- (60 m: beyond 55)
waitRate()
say(P2, "/y anyone there")
check(P3.PC.c.bubbles[2] and P3.PC.c.bubbles[2].hidden and (lastLine(P3, "y") or {}).text ~= "anyone there", "beyond 55 m: no shout at all")
-- the history keeps the most the listener made out
W.pos[3] = Vec(38, 0, 0)                                            -- (34 m: the buffer's far end)
waitRate()
say(P2, "/s we should climb the tower together")
local nh = #hist(P3)
local h34 = lastLine(P3, "s").text
W.pos[3] = Vec(31, 0, 0); step(); step()                            -- (27 m: closer)
local h27 = lastLine(P3, "s").text
W.pos[3] = Vec(38, 0, 0); step(); step()                            -- (back to 34 m)
local h34b = lastLine(P3, "s").text
local bb = P3.PC.c.bubbles[2]
check(#hist(P3) == nh and letters(h27) > letters(h34) and h34b == h27 and letters(P3.PC.bubbleText(2, bb, W.time)) < letters(h27),
	string.format("history: the most made out (34 m: %s, 27 m: %s, back at 34 m it keeps %s; the bubble shows less again)", h34, h27, h34b))
-- walking in on a message said out of earshot, while its bubble is up
W.pos[3] = Vec(44, 0, 0)                                            -- (40 m: beyond the buffer)
waitRate()
say(P2, "/s quietly now nobody hears this")
local bh = P3.PC.c.bubbles[2]
local nh2 = #hist(P3)
check(bh and bh.hidden and lastLine(P3, "s").text ~= "quietly now nobody hears this", "out of earshot: the bubble is kept, hidden, no history line")
W.pos[3] = Vec(34, 0, 0); step(); step()                            -- (30 m: into the buffer)
check(not bh.hidden and bh.mumble and #hist(P3) == nh2 + 1 and garbled(lastLine(P3, "s").text), "walking into the buffer while it is up: the bubble shows, garbled, and a history line starts")
W.pos[3] = Vec(24, 0, 0); step(); step()                            -- (20 m: in range)
check(bh.text == "quietly now nobody hears this" and lastLine(P3, "s").text == "quietly now nobody hears this" and #hist(P3) == nh2 + 1, "... and in range the words show; the same history line")
-- a whisper is private: only who was within its reach (buffer included) when it was said gets it
W.pos[3] = Vec(34, 0, 0)                                            -- (30 m: beyond the whisper's 13 m)
waitRate()
say(P2, "/w only for the ones near me")
W.pos[3] = Vec(7, 0, 0); step(); step()                             -- (3 m: walks right up while it is up)
local bq = P3.PC.c.bubbles[2]
check(not (bq and bq.whisper) and not hasLine(P3, "w", "only for the ones near me") and not garbled((lastLine(P3, "w") or {}).text),
	"a whisper said out of reach: walking up while its bubble is up shows nothing (private)")
W.pos[3] = Vec(30, 0, 0)
W.pos[5] = Vec(14, 0, 0)                                            -- (10 m: the whisper buffer)
waitRate()
say(P2, "/w step closer to hear")
check(P5.PC.c.bubbles[2] and P5.PC.c.bubbles[2].mumble and lastLine(P5, "w").text ~= "step closer to hear", "P5 in the whisper buffer when it was said: garbled")
W.pos[5] = Vec(8, 0, 0); step(); step()                             -- (4 m)
check(lastLine(P5, "w").text == "step closer to hear" and not P5.PC.c.bubbles[2].mumble, "... and stepping closer reveals it (it was within reach)")
W.pos[5] = Vec(14, 0, 0)
W.pos[3] = Vec(30, 0, 0)
W.pos[5] = Vec(15, 0, 0)                                            -- (11 m from P2)
waitRate()
say(P2, "/w quiet now")
local b5 = P5.PC.c.bubbles[2]
check(b5 and b5.mumble and b5.whisper and b5.text == "..." and lastLine(P5).text ~= "quiet now", "a whisper from 11 m (its buffer, 8-13 m): garbled")
W.pos[5] = Vec(14, 0, 0)
waitRate()
say(P2, "/s over here")
P3.offscreen = true; step()
local function garbledDrawn(m) for _, t in ipairs(m.texts) do for _, g in ipairs(m.PC.GARBLE) do if t:find(g, 1, true) then return t end end end end
check(garbledDrawn(P3) ~= nil, "P2 off P3's screen: the garbled bubble is still drawn (on the screen edge): " .. tostring(garbledDrawn(P3)))
P3.offscreen = nil

-- ================================================================== the Settings page
press(P2, "return")
P2.hover = {150, 40, 1}; P2.keys.lmb = true; step()             -- (press on the header button)
P2.release = true; step()                                       -- (its release: ignored, still Settings)
P2.hover = nil
check(P2.PC.page() == "settings" and drawn(P2, "^Settings$") and drawn(P2, "^< Back$") and drawn(P2, "^Squeaky$") and drawn(P2, "^Robot$"), "Settings button: the Settings page (voices, '< Back')")
check(not drawn(P2, "hello there", true), "... the history is not shown meanwhile")
check(not drawn(P2, "^Babble for messages to everyone$") and drawn(P2, "^\"Enter: chat\" hint on screen$") and drawn(P2, "^Keep the chat window open$"), "... with the switches (no Global babble one)")
P2.sounds = {}
local picks, setVoice0 = 0, P2.PC.setVoice
P2.PC.setVoice = function(i) picks = picks + 1; setVoice0(i) end
P2.hover = {300, 38, 6}; P2.keys.lmb = true; step()             -- (Robot)
P2.release = true; step()
P2.hover = nil
P2.PC.setVoice = setVoice0
steps(30)
check(picks == 1 and P1.shared.pcVoice[2] == 6 and P2.reg["savegame.mod.pcvoice"] == 6, "click Robot: one pick, synced to the server, saved as the default")
check(drawn(P2, "^Your voice: Robot", false) ~= nil, "Robot shown as yours")
local prev = 0
for _, s in ipairs(P2.sounds) do if math.abs(s.pos[1] - 4) < 0.01 and math.abs(s.pos[2] - 1.7) < 0.01 then prev = prev + 1 end end
check(prev >= 3, "a short preview at the listener (" .. prev .. " syllables)")
P2.hover = {300, 38, 2}; P2.release = true; step(); P2.hover = nil; steps(5)
check(P1.shared.pcVoice[2] == 2, "a release alone picks too (Chirpy)")
P2.hover = {300, 38, 4}; step(); P2.hover = nil; steps(5)
check(P1.shared.pcVoice[2] == 2, "hovering does not pick")
P2.hover = {120, 40, 2}; P2.keys.lmb = true; step(); P2.hover = nil
check(P2.PC.c.hideHint and P2.reg["savegame.mod.pchidehint"] == true, "switch: hint Hide (saved)")
P2.hover = {120, 40, 3}; P2.keys.lmb = true; step(); P2.hover = nil
check(P2.PC.c.pinned, "switch: keep the window open")
P2.hover = {150, 40, 1}; P2.keys.lmb = true; step(); P2.hover = nil
check(P2.PC.page() == "chat" and drawn(P2, "^Chat$") and drawn(P2, "^Settings$"), "'< Back' returns to the history")
press(P2, "esc"); step()
check(not P2.PC.c.typing and P2.PC.c.pinned and drawn(P2, "^Chat$") and not drawn(P2, "^Say "), "pinned: the window stays after Esc (history page)")
P2.hover = {150, 40, 1}; P2.keys.lmb = true; step(); P2.hover = nil
check(P2.PC.page() == "chat", "pinned but not typing: read-only (no clicks taken from the game)")
say(P2, "/settings"); step()
check(P2.PC.c.typing and P2.PC.page() == "settings", "/settings opens the line on the Settings page")
P2.hover = {120, 40, 1}; P2.keys.lmb = true; step()            -- (hint Show)
P2.hover = {120, 40, 4}; P2.keys.lmb = true; step(); P2.hover = nil   -- (keep open: No)
check(not P2.PC.c.hideHint and not P2.PC.c.pinned, "switches back: shown / not pinned")
check(drawn(P2, "^Speech bubbles$") and drawn(P2, "^Babble volume$") and drawn(P2, "^25%%$") and drawn(P2, "^100%%$"),
	"Settings: speech bubbles (Off to 100%) and the babble volume slider (100%)")
P2.hover = {90, 36, 3}; P2.keys.lmb = true; step(); P2.hover = nil          -- (speech bubbles: 50%)
check(P2.PC.c.bubbleLevel == 3 and P2.reg["savegame.mod.pcbubbles"] == 3, "picking bubbles 50% (saved)")
P2.hover = {400, 36, 1}; P2.keys.lmb = true; P2.held = {lmb = true}; P2.mouseX = 0.41 * 400; step(); P2.hover = nil
check(P2.PC.c.sdrag == "set_v" and math.abs(P2.PC.c.babbleVolume - 0.4) < 1e-9 and drawn(P2, "^40%%$") and P2.reg["savegame.mod.pcvolume"] == nil,
	"the babble slider: pressed and dragged to 41 % -> 40 % (snaps to 5 %), heard at once, not saved yet")
P2.mouseX = -50; step()
check(P2.PC.c.babbleVolume == 0 and drawn(P2, "^Off$"), "dragged past the left end: Off")
P2.held = nil; step()
check(not P2.PC.c.sdrag and P2.reg["savegame.mod.pcvolume"] == 0, "let go: saved (savegame.mod.pcvolume = 0)")
P2.PC.c.babbleVolume = nil; P2.PC.c.babbleVolume = P2.PC.savedVolume()
check(P2.PC.c.babbleVolume == 0, "read back: Off")
P2.hover = {90, 36, 5}; P2.keys.lmb = true; step()
P2.hover = {400, 36, 1}; P2.keys.lmb = true; P2.held = {lmb = true}; P2.mouseX = 999; step(); P2.held = nil; step(); P2.hover = nil
check(P2.PC.c.bubbleLevel == 5 and P2.PC.c.babbleVolume == 1 and P2.reg["savegame.mod.pcvolume"] == 1, "... and back to 100%")
do                                                                           -- (an old 1-5 level carries over)
	local reg = P2.reg
	local keep = reg["savegame.mod.pcvolume"]
	reg["savegame.mod.pcvolume"] = nil; reg["savegame.mod.pcbabblevol"] = 2
	check(P2.PC.savedVolume() == 0.25, "an old Babble volume level (25 %) carries over to the slider")
	reg["savegame.mod.pcbabblevol"] = nil; reg["savegame.mod.pcvolume"] = keep
end
P2.hover = {120, 40, 6}; P2.keys.lmb = true; step(); P2.hover = nil          -- (your own bubble: Hide)
check(P2.PC.c.hideOwn and P2.reg["savegame.mod.pchideown"] == true, "your own bubble: Hide (saved)")
P2.hover = {120, 40, 5}; P2.keys.lmb = true; step(); P2.hover = nil          -- (Show)
check(not P2.PC.c.hideOwn, "... and Show")
press(P2, "esc"); step()
check(P2.PC.page() == "chat" and not drawn(P2, "^Chat$"), "Esc: closed (next time it opens on the history)")
P2.PC.setMode("s")

-- ================================================================== where the chat sits, its size, its text size
;(function()
	local PC2, c2, cf = P2.PC, P2.PC.c, P2.PC.cfg
	local SW, SH = 1920 / cf.uiScale, 1080 / cf.uiScale
	local L = PC2.layout()
	check(L.dock == "bl" and L.x == cf.edge and L.W == cf.winW and L.H == cf.winH and L.inH == 54,
		"by default the chat sits bottom left at its old size (" .. L.W .. " x " .. L.H .. ")")
	check(math.abs(L.inY + L.inH + 6 + 22 - (SH - cf.edgeBottom)) < 1e-6 and L.inY == L.y + L.H + 14,
		"... the window, the input line under it, the help line, ending edgeBottom above the screen's bottom")
	local good = true
	for i, d in ipairs(PC2.DOCKS) do
		PC2.setDock(i)
		local l = PC2.layout()
		local bottom = l.inY + l.inH + 6 + 22
		local xs = d[1]:find("l") and math.abs(l.x - cf.edge) < 1e-6 or (d[1]:find("r") and math.abs(l.x + l.W - (SW - cf.edge)) < 1e-6
			or math.abs(l.x + l.W / 2 - SW / 2) < 1e-6)
		local ys = d[1]:find("t") and math.abs(l.y - cf.edge) < 1e-6 or (d[1]:find("b") and math.abs(bottom - (SH - cf.edgeBottom)) < 1e-6
			or math.abs((l.y + bottom) / 2 - SH / 2) < 1e-6)
		if not (xs and ys and P2.reg["savegame.mod.pcdock"] == d[1]) then good = false end
	end
	check(good, "each of the 8 places (corners, the middle of each edge) puts the block there, and is saved")
	check(PC2.dockIndex("tr") == 5 and PC2.dockIndex("") == 1 and PC2.dockIndex("nonsense") == 1,
		"a saved place reads back; nothing or nonsense: bottom left")
	PC2.setDock(1)
	-- Settings: the place (a click: the next), the size (applied when let go), the text size (at once)
	say(P2, "/settings"); step()
	check(drawn(P2, "^Chat position$") and drawn(P2, "^Bottom left   >$") and drawn(P2, "^Chat width$") and drawn(P2, "^1000 px$")
		and drawn(P2, "^Chat height$") and drawn(P2, "^400 px$") and drawn(P2, "^Chat text size$") and drawn(P2, "^100%%$"),
		"Settings: Chat position (Bottom left), width 1000 px, height 400 px, text size 100 %")
	P2.hover = {300, 36, 1}; P2.keys.lmb = true; step(); P2.hover = nil; step()
	check(c2.dock == 2 and P2.reg["savegame.mod.pcdock"] == "b" and drawn(P2, "^Bottom   >$"), "a click on it: Bottom (saved)")
	P2.hover = {400, 36, 2}; P2.keys.lmb = true; P2.held = {lmb = true}; P2.mouseX = 0.2 * 400; step(); P2.hover = nil
	check(c2.winW == cf.winW and drawn(P2, "^800 px$") and P2.reg["savegame.mod.pcwinw"] == nil,
		"the width slider dragged to 800 px: shown, the window not resized yet (it would move under the mouse)")
	P2.held = nil; step()
	check(c2.winW == 800 and P2.reg["savegame.mod.pcwinw"] == 800, "let go: 800 px wide (saved)")
	check(PC2.layout().W == cf.pageMinW, "... the Settings page stays " .. cf.pageMinW .. " px wide (its rows need it)")
	P2.hover = {400, 36, 3}; P2.keys.lmb = true; P2.held = {lmb = true}; P2.mouseX = 0.75 * 400; step(); P2.held = nil; step(); P2.hover = nil
	check(c2.winH == 800 and P2.reg["savegame.mod.pcwinh"] == 800, "the height slider: 800 px (saved)")
	check(PC2.layout().H == 800, "... and the Settings page grows with it (it is taller than its own minimum)")
	P2.hover = {400, 36, 4}; P2.keys.lmb = true; P2.held = {lmb = true}; P2.mouseX = 999; step(); P2.hover = nil
	check(math.abs(c2.textSize - cf.textMax) < 1e-9 and P2.reg["savegame.mod.pctext"] == nil and drawn(P2, "^170%%$"),
		"the text size slider at the right end: 170 %, at once, not saved yet")
	P2.held = nil; step()
	check(math.abs(P2.reg["savegame.mod.pctext"] - cf.textMax) < 1e-9 and PC2.textPx(24) == 41 and PC2.layout().inH == 74,
		"let go: saved; the history's text 24 -> 41 px, the input line taller (74 px)")
	press(P2, "esc"); step()
	L = PC2.layout()
	check(L.W == 800 and L.H == 800 and math.abs(L.x + L.W / 2 - SW / 2) < 1e-6, "closed: the chat block is 800 x 800, bottom middle")
	-- limits and what was saved before
	PC2.setWinSize(50, 99999)
	check(c2.winW == cf.winMinW and c2.winH == cf.winMaxH, "a size out of range is held to " .. cf.winMinW .. " .. " .. cf.winMaxW .. " x "
		.. cf.winMinH .. " .. " .. cf.winMaxH)
	check(PC2.clampW(0) == cf.winW and PC2.clampH(nil) == cf.winH and PC2.clampText(0) == 1, "nothing saved: the default size and text size")
	PC2.setWinSize(cf.winMaxW, cf.winMaxH); PC2.setDock(6); PC2.setTextSize(cf.textMax)   -- (the biggest window, on top)
	say(P2, "/settings"); step()
	L = PC2.layout()
	check(L.y >= 8 and L.inY + L.inH + 6 + 22 <= SH - 8 + 1e-6, "the biggest window with Settings open still fits on the screen")
	press(P2, "esc"); step()
	PC2.setDock(1); PC2.setWinSize(cf.winW, cf.winH); PC2.setTextSize(1)
	step()
	L = PC2.layout()
	check(L.x == cf.edge and L.W == cf.winW and L.H == cf.winH and L.inH == 54, "set back: bottom left, 1000 x 400, 100 %")
end)()

-- ================================================================== talking heads (heads.lua): a speaker's head nods
;(function()
	local keep = {W.pos[2], W.pos[4]}
	W.pos[2], W.pos[4] = Vec(4, 0, 0), Vec(80, 0, 0)
	waitRate()
	say(P2, "hello there, can you see me nodding"); steps(3)
	local b = P1.PC.c.bob and P1.PC.c.bob[2]
	local blen = P1.PC.babbleLength(2, "hello there, can you see me nodding", "s")
	check(b ~= nil and b.mode == "s" and math.abs(b.untilT - b.t0 - blen) < 1e-6 and blen > 1,
		"a line said 4 m away: its speaker's head bobs exactly as long as its babble (" .. string.format("%.2f s", blen) .. ")")
	local q = P1.PC.c.babble.queue[2]
	local played = 0
	for _, sy in ipairs(q and q.syl or {}) do played = played + q.step * (sy[4] and 0.85 or 1) + sy[2] end
	check(q and math.abs(played - blen) < 1e-6, "... the same length the babble plays (its syllables and gaps)")
	P1.rotated = {}
	local axes = {false, false, false}
	for _ = 1, 30 do
		step(); P1.PC.bobApply()
		local r = P1.rotated[#P1.rotated]
		for k = 1, 3 do if r and math.abs(r[3][k]) > 0.3 then axes[k] = true end end
	end
	local r = P1.rotated[#P1.rotated]
	local inRange = true
	for _, x in ipairs(P1.rotated) do for k = 1, 3 do if math.abs(x[3][k]) > P1.PC.cfg.bobAmp.s + 1e-6 then inRange = false end end end
	check(r and r[1] == 502 and r[2] == "head" and axes[1] and axes[2] and axes[3] and inRange,
		"... its head bobbles (RotateBone on player 2's animator, about all three axes, within " .. P1.PC.cfg.bobAmp.s .. " degrees)")
	steps(math.ceil((blen + 0.5) * 60)); P1.PC.bobApply(); P1.rotated = {}; P1.PC.bobApply()
	check(P1.PC.c.bob[2] == nil and #P1.rotated == 0, "... and stops after that")
	waitRate()
	say(P4, "too far to see"); steps(3)
	check(P1.PC.c.bob[4] == nil, "80 m away: no nod (too small to see)")
	waitRate()
	say(P2, "/g everyone hears this"); steps(3)
	check(P1.PC.c.bob[2] == nil, "a Global line: no nod (it is not said out loud)")
	say(P2, "/bob y"); steps(2)
	check(P2.PC.c.bob[2] and P2.PC.c.bob[2].mode == "y" and lastLine(P2).text:find("bobbles for 4 s as in Yell", 1, true), "/bob y: your own head bobbles 4 s, as in Yell")
	local yAmp, yFast = 0, 0
	for _ = 1, 40 do
		step(); P2.rotated = {}; P2.PC.bobApply()
		local r = P2.rotated[1]
		if r then yAmp = math.max(yAmp, math.abs(r[3][1])) end
	end
	check(yAmp > P2.PC.cfg.bobAmp.s * 0.5 and P2.PC.cfg.bobAmp.y > P2.PC.cfg.bobAmp.s and P2.PC.cfg.bobStep.y[2] < P2.PC.cfg.bobStep.s[1] + 0.03,
		"... a yell bobbles more (to " .. P2.PC.cfg.bobAmp.y .. " degrees) and faster than speech")
	P2.rotated = {}; P2.PC.bobApply(); steps(1); P2.PC.bobApply()
	check(#P2.rotated >= 1 and P2.rotated[1][1] == 502, "... your own head (player 2, seen in third person)")
	W.pos[2], W.pos[4] = keep[1], keep[2]
	steps(math.ceil(5 * 60))
end)()

-- ================================================================== Up / Down: the lines you sent, back on the chat line
;(function()
	P2.PC.c.sent = {}                                                      -- (only this test's lines)
	waitRate(); say(P2, "first line"); steps(2)
	waitRate(); say(P2, "/help"); steps(2); say(P2, "/help"); steps(2)   -- (a command too; the same twice: kept once)
	waitRate(); say(P2, "second line"); steps(2)
	press(P2, "return"); typeText(P2, "half typed")
	press(P2, "uparrow")
	check(P2.PC.c.text == "second line", "Up on the chat line: your latest line back")
	press(P2, "uparrow")
	check(P2.PC.c.text == "/help", "... Up again: the one before (commands too, the same one twice only once)")
	press(P2, "uparrow"); press(P2, "uparrow")
	check(P2.PC.c.text == "first line", "... and before that; the oldest stays")
	press(P2, "downarrow"); press(P2, "downarrow")
	check(P2.PC.c.text == "second line", "Down: back toward the newest")
	press(P2, "downarrow")
	check(P2.PC.c.text == "half typed", "... past the newest: what you were typing")
	press(P2, "uparrow"); press(P2, "return"); steps(2)
	check(lastLine(P2, "s") and lastLine(P2, "s").text == "second line", "a line brought back and Enter: said again")
	press(P2, "return"); press(P2, "uparrow")
	check(P2.PC.c.text == "second line" and #P2.PC.c.sent == 3, "... (said again: not stored twice in a row)")
	press(P2, "esc"); step()
	for k = 1, 12 do P2.PC.remember("line " .. k) end
	check(#P2.PC.c.sent == 10 and P2.PC.c.sent[1] == "line 3" and P2.PC.c.sent[10] == "line 12", "only the last 10 sent lines are kept")
	press(P2, "return")
	press(P2, "esc"); step()
	waitRate(); steps(120)                                                 -- (the line said again: through before the next part)
end)()

-- ================================================================== commands
local nShared = #P1.shared.pcMsgs
say(P2, "/voice")
check(lastLine(P2).sys and lastLine(P2).text:find("Squeaky", 1, true) and lastLine(P2).text:find("Settings", 1, true), "/voice lists the voices (local echo)")
check(#P1.shared.pcMsgs == nShared, "commands are not sent")
say(P2, "/voice robot"); steps(3)
check(P1.shared.pcVoice[2] == 6 and P2.reg["savegame.mod.pcvoice"] == 6 and lastLine(P2).text == "Your voice is now Robot.", "/voice robot: synced, saved, echoed")
check(not hasLine(P1, "sys", "Your voice is now Robot."), "the echo is only local")
say(P2, "/voice 2"); steps(3)
check(P1.shared.pcVoice[2] == 2, "/voice 2 picks Chirpy")
say(P2, "/voice banana")
check(lastLine(P2).text:find("No voice called", 1, true) ~= nil, "unknown voice: a helpful echo")
say(P2, "/voice de"); steps(3)
check(P1.shared.pcVoice[2] == 5, "/voice de picks Deep (prefix)")
check(P1.shared.pcVoice[4] == 5, "P4's default voice from Options reached the server")
waitRate()
say(P2, "/w just us")
check(lastLine(P1, "w").text == "just us" and not hasLine(P5, "w", "just us") and P2.PC.mode() == "s", "/w <text>: one whisper, the mode stays nearby")
waitRate()
say(P2, "/g to all at once")
check(lastLine(P4, "g").text == "to all at once" and P2.PC.mode() == "s", "/g <text> goes to everyone, the mode stays")
say(P2, "/w")
check(P2.PC.mode() == "w" and lastLine(P2).text:find("Whisper", 1, true), "/w alone sets the whisper mode: " .. lastLine(P2).text)
say(P2, "/g")
check(P2.PC.mode() == "g", "/g alone: everyone")
say(P2, "/p")
check(P2.PC.mode() == "s" and P2.reg["savegame.mod.pcmode"] == "s", "/p alone: nearby (saved)")
waitRate()
say(P2, "//slash")
check(lastLine(P1, "s").text == "/slash", "//text sends a line starting with /")
say(P2, "/frobnicate")
check(lastLine(P2).text:find("Unknown command", 1, true) ~= nil, "unknown command echoed")
say(P2, "/help")
local helpSeen = {}
for _, e in ipairs(hist(P2)) do if e.sys and e.text:find("/s /w /y /g", 1, true) then helpSeen.cmds = true end
	if e.sys and e.text:find("^Controller: click L3 twice") then helpSeen.pad = true end end
check(helpSeen.cmds and helpSeen.pad and lastLine(P2).text:find("^Controller") ~= nil, "/help lists commands (and the controller)")
say(P2, "/g"); say(P2, "/s")
check(P2.PC.mode() == "s" and P2.PC.page() ~= "settings", "/s switches to Speak (Settings is /settings)")
say(P2, "/hint"); step()
check(P2.PC.c.hideHint and not drawn(P2, "^Enter: chat$") and not drawn(P2, "^Proximity Comms %- Enter"), "/hint hides the hint (saved)")
say(P2, "/hint")
say(P2, "/mute")
check(lastLine(P2).text:find("Nobody is muted", 1, true) ~= nil, "/mute alone: who is muted")
say(P2, "/clear")
check(#hist(P2) == 0, "/clear empties your history")

-- ================================================================== bounds, scrolling, sanitizing
waitRate()
say(P2, "one"); say(P2, "two")
check(hasLine(P1, "s", "one") and not hasLine(P1, "s", "two"), "rate limit: a second line within 0.45 s is held back...")
steps(45)
check(hasLine(P1, "s", "two"), "... and gets in with the resend (not lost)")
for i = 1, 40 do waitRate(); P2.PC.say("line " .. i, "s"); step() end
for i = 1, 25 do waitRate(); P3.PC.say("g" .. i, "g"); step() end
step()
local h1 = hist(P1)
check(#h1 == 50 and h1[#h1].text == "g25" and h1[1].text == "line 16", "the history keeps the last 50 lines (both modes together)")
check(#P1.shared.pcMsgs <= 30, "shared keeps at most 30 messages (" .. #P1.shared.pcMsgs .. ")")
check(#hist(P3, "s") == 0 or lastLine(P3, "s").text ~= "line 40", "P3 (26 m) still got none of the nearby lines")
steps(60 * 32, 1 / 60)
check(#P1.shared.pcMsgs == 0 and #hist(P1) == 50, "shared messages expire (30 s); local histories stay")
press(P1, "return")
P1.values.mousewheel = 1; step()
P1.keys.pgup = true; step()
check(P1.PC.c.scroll == 5 and drawn(P1, "newer below", true), "wheel / PgUp scroll back (" .. P1.PC.c.scroll .. ")")
press(P1, "esc")
check(P1.PC.c.scroll == 0, "closing resets the scroll")
waitRate()
P2.PC.say("a\1b\127c   ", "s"); step()
check(lastLine(P1, "s").text == "a b c", "control bytes stripped, trimmed: '" .. lastLine(P1, "s").text .. "'")
waitRate()
P2.PC.say(string.rep("\208\150", 100), "s"); step()
local got = lastLine(P1, "s").text
check(P1.PC.utf8Len(got) == 90 and #got == 180, "90 characters, cut on a character boundary (" .. #got .. " bytes)")

-- ================================================================== every language
local PC = P1.PC
check(PC.allCaps("\208\159\208\158\208\156\208\158\208\147\208\152\208\162\208\149") and not PC.allCaps("\208\191\208\190\208\188\208\190\209\137\209\140"), "Cyrillic: ПОМОГИТЕ is all caps, помощь is not")
check(PC.allCaps("\206\148\206\145") and PC.allCaps("WAIT FOR ME!") and not PC.allCaps("wait FOR me") and not PC.allCaps("\228\189\160\229\165\189") and not PC.allCaps("A"),
	"all caps: Greek capitals, 'WAIT FOR ME!'; not mixed case, not Chinese (no case), not a single letter")
check(#PC.babbleSyllables("\228\189\160\229\165\189\229\144\151") == 3 and PC.chatFont("\228\189\160\229\165\189\229\144\151") == "bold_sc.ttf", "Chinese: a syllable per character, the Chinese font")
check(#PC.babbleSyllables("\227\129\147\227\130\147\227\129\171\227\129\161\227\129\175") == 5 and PC.chatFont("\227\129\147\227\130\147\227\129\171\227\129\161\227\129\175") == "bold_jp.ttf", "Japanese: a syllable per kana, the Japanese font")
check(PC.chatFont("\236\149\136\235\133\149") == "MOD/fonts/notosanskr-bold.ttf"
	and PC.chatFont("\236\149\136\235\133\149", false) == "MOD/fonts/notosanskr-regular.ttf"
	and PC.chatFont("hi \236\149\136\226\172\154") == "MOD/fonts/notosanskr-bold.ttf"
	and PC.bubbleFont("\236\149\136\235\133\149") == "MOD/fonts/notosanskr-bold.ttf",
	"Korean: the mod's own Korean font (the game has none with Hangul: its Chinese one drew ?), garbled boxes too")
check(PC.bubbleFont("hey, wait! caf\195\169") == "MOD/fonts/pangolin.ttf" and select(2, PC.bubbleFont("hi")) == 32, "bubbles: Latin in the shipped font (Pangolin, 32)")
check(PC.bubbleFont("dzie\197\132 dobry") == "MOD/fonts/pangolin.ttf" and PC.bubbleFont("\208\191\209\128\208\184\208\178\208\181\209\130") == "MOD/fonts/pangolin.ttf", "bubbles: Polish and Cyrillic in Pangolin too")
check(PC.bubbleFont("\206\179\206\181\206\185\206\177") == "bold.ttf"
	and PC.bubbleFont("\228\189\160\229\165\189") == "bold_sc.ttf" and select(2, PC.bubbleFont("\228\189\160")) == 30, "bubbles: Greek / Chinese: the game fonts (30)")
local okF = PC.bubbleFontOk
PC.bubbleFontOk = nil; NO_FONT_FILE = true
check(PC.bubbleFont("hello") == "bold.ttf" and PC.bubbleFont("hello", false) == "regular.ttf", "bubbles: no fonts/ (an #include without it): the game fonts")
PC.bubbleFontOk = okF; NO_FONT_FILE = nil
check(PC.chatFont("\217\133\216\177\216\173\216\168\216\167") == "arial.ttf" and PC.chatFont("hello") == "bold.ttf" and PC.chatFont("hello", false) == "regular.ttf", "Arabic: arial.ttf; Latin: bold.ttf (whispers: regular)")
check(PC.chatVisual("\216\168\216\168") == "\239\186\144\239\186\145", "Arabic joined and laid right to left")
check(PC.chatVisual("\217\132\216\167") == "\239\187\187", "Arabic lam + alef ligature")
check(PC.chatVisual("hi \215\169\215\156\215\149\215\157") == "hi \215\157\215\149\215\156\215\169", "Hebrew right to left inside English")
check(PC.utf8Head("\208\150\208\150\208\150", 2) == "\208\150\208\150", "utf8Head never splits a letter")
waitRate()
P2.PC.say("\208\191\208\190\208\188\208\190\208\179\208\184\209\130\208\181 \208\159\208\158\208\156\208\158\208\147\208\152\208\162\208\149", "s"); step()
check(lastLine(P3, "s").text:find("\226\172\154", 1, true) ~= nil, "Cyrillic CAPS in Speak are not a shout: garbled at 26 m like the rest")
waitRate()
P2.PC.say("\208\159\208\158\208\156\208\158\208\147\208\152\208\162\208\149", "w"); step()
check(lastLine(P1, "w").text == "\208\159\208\158\208\156\208\158\208\147\208\152\208\162\208\149" and lastLine(P3, "w") == nil, "a Cyrillic CAPS whisper stays a whisper (P3 gets nothing)")

-- ================================================================== registry integration (another mod / game mode)
local hookLobby = P1.PC.hooks.inLobby
P1.reg["proxchat.lobby"] = true; step(); step()
check(P2.PC.mode() == "g", "a game sets proxchat.lobby: everyone hears everything")
P1.reg["proxchat.lobby"] = false; step(); step()
check(P2.PC.mode() == "s", "proxchat.lobby back to false: own mode again")
P2.reg["proxchat.block"] = true
press(P2, "return")
check(not P2.PC.isTyping(), "a game sets proxchat.block: Enter does not open the chat")
P2.reg["proxchat.block"] = false

-- ================================================================== hooks: lobby, everyoneHears, blockKeys, windowKey
P1.PC.hooks.inLobby = function() return true end
step(); step()
check(P2.PC.mode() == "g", "lobby: clients say everything to everyone")
press(P2, "return"); press(P2, "tab")
check(P2.PC.mode() == "g" and drawn(P2, "^Global: $"), "lobby: Tab does not leave Global")
P2.hover = {56, 34, 1}; P2.keys.lmb = true; step(); P2.hover = nil
check(P2.PC.mode() == "g", "lobby: the Whisper chip is disabled")
waitRate()
typeText(P2, "lobby hello"); press(P2, "return"); step()
check(lastLine(P4, "g").text == "lobby hello" and P1.shared.pcMsgs[#P1.shared.pcMsgs].ch == "g", "lobby: everything is everyone")
waitRate()
P2.PC.say("sneaky", "w"); step()
check(P1.shared.pcMsgs[#P1.shared.pcMsgs].ch == "g", "lobby: the server turns a whisper into everyone")
P1.PC.hooks.inLobby = hookLobby                                 -- (back to the registry hook, main.lua's)
step(); step()
check(P2.PC.mode() == "s", "out of the lobby: back to the player's own mode")
P4.PC.hooks.everyoneHears = function(speaker) return true end
waitRate()
P2.PC.say("radio check (no game key)", "s"); step()
check(not hasLine(P4, "s", "radio check (no game key)"), "TRUST: the everyoneHears hook alone (a client's claim) gets nothing from far away")
HOST.reg["proxchat.hearall.4"] = true                               -- (the game's server script says P4 hears everyone)
waitRate()
P2.PC.say("radio check", "s"); step()
check(lastLine(P4, "s").text == "radio check" and lastLine(P3, "s").text ~= "radio check", "everyoneHears hook: P4 hears nearby lines far away, P3 does not")
waitRate()
P2.PC.say("radio whisper", "w"); step()
check(lastLine(P4, "w") == nil, "... but whispers still need 5 m")
P4.PC.hooks.everyoneHears = nil
HOST.reg["proxchat.hearall.4"] = nil
P4.PC.hooks.blockKeys = function() return true end
press(P4, "return")
check(not P4.PC.c.typing, "blockKeys hook: Enter does not open the chat")
P4.PC.hooks.blockKeys = nil
press(P1, "y"); press(P1, "v")
check(not P1.PC.c.pinned and not P1.PC.c.typing, "no hotkeys besides Enter: Y and V do nothing")
local P6 = addMachine(6, false, {["savegame.mod.pcmode"] = "w"}, {cfg = {windowKey = "y"}})   -- (a host mod sets PC.cfg first)
W.pos[6] = Vec(0, 0, 3)
steps(3)
check(P6.PC.mode() == "w", "a player's saved mode is the default next time (whisper)")
press(P6, "y")
check(P6.PC.c.pinned and drawn(P6, "^Y: close$"), "PC.cfg.windowKey = 'y' from a host mod pins the window")
press(P6, "y")
check(not P6.PC.c.pinned, "... and closes it")
steps(60 * 16)
check(drawn(P6, "^Enter: chat   Y: chat window$") ~= nil, "after the intro: 'Enter: chat' (+ the host mod's key)")

-- leaving, joining
press(P3, "return"); step()
P1.server.pc_voice(3, TOK(3), 4)
W.removed = {3}
step()
check(not P1.PC.isTyping(3) and P1.shared.pcVoice[3] == nil and P1.reg["proxchat.typing.3"] == false, "a player who leaves is cleaned up (typing, voice)")
W.removed = {}
waitRate()
P2.PC.say("before you came", "g"); step()
waitRate()
P2.PC.say("nearby before you came", "s"); step()
W.pos[7] = Vec(6, 0, 0)
local P7 = addMachine(7, false)
step()
check(hasLine(P7, "g", "before you came") and #hist(P7, "s") == 0, "a joiner gets recent everyone lines, not old nearby talk")

-- ================================================================== options.lua (Mod Manager)
local function optionsEnv(reg)
	local o = {reg = reg or {}, texts = {}, click = nil}
	local function nop() end
	for _, f in ipairs({"UiPush", "UiPop", "UiTranslate", "UiAlign", "UiFont", "UiColor", "UiButtonHoverColor", "UiButtonImageBox", "UiImageBox"}) do o[f] = nop end
	o.UiCenter = function() return 960 end
	o.UiText = function(s) o.texts[#o.texts + 1] = s end
	o.UiTextButton = function(label)                                -- (clicks the first button with that label)
		if o.click == label and not o.clickUsed then o.clickUsed = true; return true end
		return false
	end
	o.GetInt = function(k) return tonumber(o.reg[k]) or 0 end
	o.SetInt = function(k, v) o.reg[k] = v end
	o.GetBool = function(k) return o.reg[k] == true end
	o.SetBool = function(k, v) o.reg[k] = v end
	o.GetFloat = function(k) return tonumber(o.reg[k]) or 0 end
	o.SetFloat = function(k, v) o.reg[k] = v end
	o.HasKey = function(k) return o.reg[k] ~= nil end
	o.UiRect, o.UiSliderHoverColorFilter, o.UiSliderThumbSize = nop, nop, nop
	o.UiSlider = function(img, axis, cur) if o.slideTo then local v = o.slideTo; o.slideTo = nil; return v, true end return cur, false end
	o.Menu = function() o.closed = true end
	setmetatable(o, {__index = _G})
	local chunk = assert(loadstring(readFile(MODDIR .. "options.lua"), "options.lua"))
	setfenv(chunk, o)
	chunk()
	o.frame = function(click) o.click, o.clickUsed, o.texts = click, false, {}; o.draw(); o.click = nil end
	return o
end
local O = optionsEnv()
O.frame()
local function otext(pat) for _, t in ipairs(O.texts) do if t:find(pat, 1, true) then return t end end end
check(otext("Whisper / Speak / Yell / Global") and otext("Not picked") and otext("100%"), "Options: explains the keys; no voice picked yet; babble volume 100 %")
O.slideTo = 0.6 * 400; O.frame()
check(O.reg["savegame.mod.pcvolume"] == 0.6, "Options: the volume slider saves savegame.mod.pcvolume (60 %)")
O.frame()
check(otext("60%"), "Options: ... and shows it")
O.frame("Robot")
check(O.reg["savegame.mod.pcvoice"] == 6, "Options: picking Robot saves savegame.mod.pcvoice = 6")
O.frame("Hide")
check(O.reg["savegame.mod.pchidehint"] == true, "Options: hide the hint")
O.frame("50%")
check(O.reg["savegame.mod.pcbubbles"] == 3 and otext("Babble volume"), "Options: speech bubbles 50% (and the babble volume row)")
O.frame("Close")
check(O.closed, "Options: Close")
local P8 = addMachine(8, false, O.reg)
W.pos[8] = Vec(0, 0, -3)
steps(30)
check(P1.shared.pcVoice[8] == 6 and P8.PC.c.hideHint and not drawn(P8, "Enter: chat", true), "the Options settings are used in game (voice synced, hint hidden)")

-- ================================================================== long messages scroll inside the bubble
local LONG = string.rep("abcdefghi ", 13)                                 -- (130 characters: the mock wraps it in 5 lines at 320 px)
local now0 = W.time
local L0 = P1.PC.bubbleLayout(2, LONG, false, 1, false, false, false, now0)
local Lmid = P1.PC.bubbleLayout(2, LONG, false, 1, false, false, false, now0 - (1.5 + 0.9))
local Lend = P1.PC.bubbleLayout(2, LONG, false, 1, false, false, false, now0 - 30)
local Lshort = P1.PC.bubbleLayout(2, "short one", false, 1, false, false, false, now0)
check(L0 and L0.th == 120 and L0.vh == 72 and L0.h == 94 and L0.w == 350 and L0.off == 0 and math.abs(L0.scrollTime - 3.6) < 1e-6,
	"a long message shows 3 of its 5 lines in a 320 px wide bubble; the 2 more scroll in 3.6 s")
check(math.abs(Lmid.off - 12) < 1e-6 and Lend.off == 48, "it waits 1.5 s, then scrolls down smoothly (half a line after 0.9 s) and stops at the end")
check(Lshort.scrollTime == 0 and Lshort.vh == Lshort.th, "a short message does not scroll")
waitRate()
P1.PC.cfg.bubbleW = 200                                                   -- (a said message has 90 characters at most: 5 lines at 200 px)
say(P2, "/s " .. string.rep("abcdefghi ", 9))
steps(3)
P1.PC.cfg.bubbleW = 320
local bl = P1.PC.c.bubbles[2]
check(bl and math.abs((bl.extra or 0) - 3.6) < 1e-6, "its bubble stays up longer by the scrolling time")
-- a reveal does not restart the scroll
W.pos[3] = Vec(30, 0, 0)                                                  -- (26 m: P2's buffer)
P3.PC.cfg.bubbleW = 200
waitRate()
say(P2, "/s " .. string.rep("abcdefghi ", 9))
steps(60 * 3)                                                             -- (1.5 s hold + 1.5 s scrolling)
local br = P3.PC.c.bubbles[2]
local before = P3.PC.bubbleLayout(2, P3.PC.bubbleText(2, br, W.time), false, 1, false, false, br.mumble, br.scrollT or br.t)
W.pos[3] = Vec(20, 0, 0); step()                                          -- (16 m: all revealed)
local after = P3.PC.bubbleLayout(2, br.text, false, 1, false, false, false, br.scrollT or br.t)
P3.PC.cfg.bubbleW = 320
W.pos[3] = Vec(30, 0, 0)
check(br.level == "full" and before.off > 10 and after.off >= before.off,
	string.format("revealed mid-scroll: the scroll goes on (%.1f px before, %.1f after), not back to the top", before.off, after.off))

-- ================================================================== the character limit on the input line
press(P2, "return"); step()
typeText(P2, string.rep("a", 50)); step()
check(P2.PC.c.typing and not drawn(P2, "^%d+/90$"), "under 60 characters: no count")
typeText(P2, string.rep("b", 15)); step()
check(drawn(P2, "^65/90$") ~= nil, "from 60 characters the line shows the count (65/90)")
typeText(P2, string.rep("c", 40)); step(); step()
check(P2.PC.utf8Len(P2.PC.c.text) == 90 and drawn(P2, "^90/90$") ~= nil, "the field stops at 90 characters (90/90, red)")
press(P2, "esc"); step()

-- ================================================================== 2 bubbles a speaker at most
waitRate(); say(P2, "/s first one")
waitRate(); say(P2, "/s second one")
waitRate(); say(P2, "/s third one")
step()
local nb, pb = P1.PC.c.bubbles[2], P1.PC.c.prevBubbles[2]
local mine = {}
for _, r in ipairs(P1.PC.c.bubbleRects or {}) do if r.p == 2 then mine[#mine + 1] = r end end
check(nb and nb.full == "third one" and pb and pb.full == "second one" and #mine == 2,
	"three quick messages: the 2 newest show (the first is gone)")
check(mine[1].bottom > mine[2].bottom and mine[1].top >= mine[2].bottom, "the newest nearest the head, the one before it stacked above")
-- a game keeps bubbles off its own panels: proxchat.avoid.<name> = "x y w h" (client, every frame), proxchat.hideBubbles
do
	local function overlaps(R, x, y, w, h) return R.left < x + w and R.right > x and R.top < y + h and R.bottom > y end
	local function any(x, y, w, h) for _, r in ipairs(P1.PC.c.bubbleRects or {}) do if r.p == 2 and overlaps(r, x, y, w, h) then return true end end return false end
	check(any(380, 150, 260, 200), "(the bubbles over P2's head are where the next checks put a panel)")
	P1.reg["proxchat.avoid.board"] = "380 150 260 200"
	step()
	local n = 0
	for _, r in ipairs(P1.PC.c.bubbleRects or {}) do if r.p == 2 then n = n + 1 end end
	check(n == 2 and not any(380, 150, 260, 200) and P1.reg["proxchat.avoid.board"] == nil,
		"a game's keep-out rectangle (proxchat.avoid.board): the bubbles move out of it; the key is used up that frame")
	P1.reg["proxchat.avoid.side"] = "450,0,120,1080"
	step()
	local aside = true
	for _, r in ipairs(P1.PC.c.bubbleRects or {}) do if r.p == 2 and (overlaps(r, 450, 0, 120, 1080) or r.right > 1920 or r.left < 0) then aside = false end end
	check(aside, "... a full-height one: no room above or below - the bubbles go aside, still on screen")
	step()
	check(any(380, 150, 260, 200), "... the game stopped setting it: the bubbles are back over the head the next frame")
	P1.reg["proxchat.hideBubbles"] = true
	step()
	check(#(P1.PC.c.bubbleRects or {}) == 0 and P1.reg["proxchat.hideBubbles"] == nil, "proxchat.hideBubbles: no bubbles this frame (used up)")
	step()
	check(#(P1.PC.c.bubbleRects or {}) >= 2, "... not set again: they are back")
end

-- ================================================================== short messages go sooner
steps(60 * 10)                                                            -- (earlier bubbles gone)
waitRate(); say(P2, "/s hi")
steps(60 * 2.4)
local hiUp = P1.PC.c.bubbles[2] ~= nil
steps(30)
check(hiUp and not P1.PC.c.bubbles[2], "'hi' (2 characters): up for about 2.7 s (2.5 + 0.1 a character), then gone")
waitRate(); say(P2, "/s this one is a good deal longer than that")             -- (40 characters: 6.5 s)
steps(60 * 6.2)
local longUp = P1.PC.c.bubbles[2] ~= nil
steps(30)
check(longUp and not P1.PC.c.bubbles[2], "40 characters: still up at 6.2 s, gone by 6.7 s")
check(math.abs(P1.PC.bubbleLife({full = string.rep("x", 90)}) - 11.5) < 1e-9, "90 characters (the most): 11.5 s (plus any scrolling)")

-- ================================================================== a reveal keeps a bubble up 1 s at most
W.pos[3] = Vec(30, 0, 0)                                                  -- (26 m: P2's buffer)
waitRate(); say(P2, "/s hey you")                                         -- (7 characters: 2.56 s)
steps(60 * 2.3)
W.pos[3] = Vec(20, 0, 0); step()                                          -- (16 m: fully revealed with 0.25 s left)
steps(50)
local heldUp = P3.PC.c.bubbles[2] ~= nil and P3.PC.c.bubbles[2].level == "full"
steps(20)
check(heldUp and not P3.PC.c.bubbles[2], "fully revealed near its end: up 1 s more, then gone")
W.pos[3] = Vec(44, 0, 0)                                                  -- (40 m: out of earshot)
waitRate(); say(P2, "/s hello again")                                     -- (11 characters: 3.6 s)
steps(60 * 3.2)
W.pos[3] = Vec(34, 0, 0); step()                                          -- (30 m: walks into the buffer)
local seen = P3.PC.c.bubbles[2] ~= nil and not P3.PC.c.bubbles[2].hidden
steps(30)
check(seen and not P3.PC.c.bubbles[2], "walking into the buffer late: it shows for what is left of it (no extra time)")
W.pos[3] = Vec(30, 0, 0)

-- ================================================================== out of reach: no bubble
local function shows(M, sp) for _, r in ipairs(M.PC.c.bubbleRects or {}) do if r.p == sp then return true end end return false end
W.pos[3] = Vec(30, 0, 0)                                                  -- (26 m: the buffer)
waitRate(); say(P2, "/s walk away from me and see")
step()
local in26 = shows(P3, 2)
W.pos[3] = Vec(44, 0, 0); step()                                          -- (40 m: beyond the 35 m reach)
local out40 = shows(P3, 2)
W.pos[3] = Vec(32, 0, 0); step()                                          -- (28 m: back while it is up)
check(in26 and not out40 and shows(P3, 2), "walking out of the buffer hides the bubble; coming back while it is up shows it again")
waitRate(); say(P2, "/y come back here")
W.pos[3] = Vec(54, 0, 0); step()                                          -- (50 m: a shout reaches 55)
local sh50 = shows(P3, 2)
W.pos[3] = Vec(62, 0, 0); step()                                          -- (58 m)
check(sh50 and not shows(P3, 2), "a shout's bubble goes beyond 55 m (its buffer's end)")
W.pos[3] = Vec(30, 0, 0); step()

-- ================================================================== multiplayer robustness
-- a lost message is resent until the host confirms it; a resend is taken once
waitRate()
W.dropSay = 1
say(P2, "/s lost on the way")
check(not hasLine(P1, "s", "lost on the way"), "a message lost on the way: not there yet")
steps(40)
check(hasLine(P1, "s", "lost on the way") and #P2.PC.c.outbox == 0, "... resent and confirmed: everyone has it, the outbox is empty")
local nAll = #hist(P1)
HOST.server.pc_say(2, TOK(2), "s", "lost on the way", P2.PC.c.seq)                -- (a late duplicate of the resend)
step()
check(#hist(P1) == nAll, "a duplicate of a message already taken is ignored")
W.dropSay = 1000
say(P2, "/s nobody will get this")
steps(60 * 9)
W.dropSay = 0
check(lastLine(P2).text == "Not sent (no answer from the host): nobody will get this" and #P2.PC.c.outbox == 0, "no answer for 8 s: given up, and the sender is told")
-- late messages (a lagging client): timed from when they were said
local now0 = HOST.shared.pcNow
P1.sounds = {}
P1.PC.receive({id = 990001, p = 3, name = "P3", ch = "g", text = "global news", t = now0 - 20})
P1.PC.receive({id = 990002, p = 2, name = "P2", ch = "s", text = "said long ago", t = now0 - 20})
check(hasLine(P1, "s", "said long ago") and (not P1.PC.c.bubbles[2] or P1.PC.c.bubbles[2].full ~= "said long ago") and #P1.sounds == 0,
	"20 s late: in the history only (no bubble, no babble)")
P1.PC.receive({id = 990003, p = 2, name = "P2", ch = "s", text = "a bit late this one", t = now0 - 3})
local bl3 = P1.PC.c.bubbles[2]
steps(30)
check(bl3 and bl3.full == "a bit late this one" and math.abs((W.time - 0.5 - bl3.t) - 3) < 0.6 and #P1.sounds == 0,
	"3 s late: the bubble shows for what is left of it, no babble")
-- sanitizing: accent towers, invisible and direction-flipping characters, long names
local Z = "a" .. string.rep("\204\129", 12) .. "b"                         -- (a + 12 combining acute accents)
check(P1.PC.clean(Z) == "a\204\129\204\129b", "an accent tower is cut to 2 marks a letter")
check(P1.PC.clean("ab\226\128\174cd\226\128\139e\226\128\168f") == "abcdef", "direction override, zero-width and line separator characters are removed")
check(P1.PC.clean("\217\133\217\143\216\173\217\142\217\133\217\143\216\175") == "\217\133\217\143\216\173\217\142\217\133\217\143\216\175", "Arabic vowel marks are kept")
check(P1.PC.utf8Len(P1.PC.cleanName(string.rep("N", 40), 7)) == 24 and P1.PC.cleanName("", 7) == "Player 7", "names: 24 characters at most; none: 'Player n'")
-- /mute
say(P1, "/mute P")
check(lastLine(P1).text:find("could be", 1, true) ~= nil, "/mute with a name that fits several: asks for more")
say(P1, "/mute Nobody")
check(lastLine(P1).text:find("No player called", 1, true) ~= nil, "/mute someone who has not spoken: says so")
say(P1, "/mute p2")
waitRate(); say(P2, "/s can you hear me")
steps(5)
check(not hasLine(P1, "s", "can you hear me") and not P1.PC.c.bubbles[2] and hasLine(P5, "s", "can you hear me"),
	"/mute p2: nothing of P2's (bubble, history) - only for P1")
say(P1, "/mute")
check(lastLine(P1).text:find("Muted (only for you): P2", 1, true) ~= nil, "/mute lists who is muted")
say(P1, "/unmute all")
waitRate(); say(P2, "/s and now")
check(hasLine(P1, "s", "and now"), "/unmute all: heard again")
-- a low frame rate: the babble keeps time instead of dragging
local function babbleTime(dt)
	P1.PC.babbleSay(2, "one two three four five six seven eight nine ten eleven twelve")
	local t = 0
	while P1.PC.c.babble.queue[2] and t < 20 do step(dt); t = t + dt end
	return t
end
local t60, t5 = babbleTime(1 / 60), babbleTime(1 / 5)
check(t5 <= t60 + 0.45, string.format("at 5 fps the babble ends in time (%.2f s, at 60 fps %.2f s)", t5, t60))
-- the text of a bubble is measured once
local m1 = P1.PC.measure("measure me once")
check(P1.PC.measure("measure me once") == m1, "a bubble's text is measured once and reused")

-- ================================================================== the bubble and babble settings at work
P1.PC.setBubbleLevel(1); P1.PC.setBabbleVolume(0)
P1.sounds = {}
waitRate(); say(P2, "/s can you see this")
steps(30)
check(hasLine(P1, "s", "can you see this") and #(P1.PC.c.bubbleRects or {}) == 0 and #P1.sounds == 0,
	"bubbles Off and babble Off: only the chat line (no bubble, no sound)")
P1.PC.setBubbleLevel(2); P1.PC.setBabbleVolume(0.25)
P1.sounds = {}
waitRate(); say(P2, "/s and now at a quarter")
steps(40)
local nq, vq = soundsFrom(P1, 4, "babble")
check(#(P1.PC.c.bubbleRects or {}) >= 1 and drawn(P1, "^and now at a quarter$") and nq >= 2 and vq <= 0.75 * 0.25 + 1e-6,
	string.format("bubbles 25%% (still drawn, the text too) and babble 25%% (vol %.3f)", vq))
P1.PC.setBubbleLevel(5); P1.PC.setBabbleVolume(1)

-- ================================================================== drawing order: far first
W.pos[3] = Vec(30, 0, 0)
if P3.PC.c.typing then press(P3, "esc"); step() end                    -- (P3's line was left open)
waitRate(); say(P3, "/s from far away")
waitRate(); say(P2, "/s from close by")
step()
local ord = P1.PC.drawOrder or {}
local i2, i3
for i, L in ipairs(ord) do if L.p == 2 then i2 = i elseif L.p == 3 then i3 = i end end
check(i2 and i3 and i3 < i2 and ord[i3].dist > ord[i2].dist, "the farther speaker's bubble (and its line) is drawn first: the nearer one covers it")
waitRate(); say(P2, "/s and a second one")
step()
ord = P1.PC.drawOrder or {}
local old2, new2
for i, L in ipairs(ord) do if L.p == 2 then if L.age == 2 then old2 = i else new2 = i end end end
check(old2 and new2 and old2 < new2, "a speaker's older bubble (raised, with its line) is drawn before the newest: the line goes behind it")

-- ================================================================== your own bubble (third person)
P2.reg["game.thirdperson"] = true
waitRate(); say(P2, "/s look at me")
step()
local ownShown = shows(P2, 2)
P2.PC.setHideOwn(true); step()
check(ownShown and not shows(P2, 2) and shows(P1, 2), "your own bubble shows in third person; Hide removes it for you (others still see it)")
P2.PC.setHideOwn(false); P2.reg["game.thirdperson"] = nil

-- ================================================================== how a voice carries
local LD = P1.PC.loudness
check(LD(4, 35, 25) == 1 and math.abs(LD(20, 35, 25) - 0.77) < 0.01 and LD(25, 35, 25) > LD(28, 35, 25) and LD(28, 35, 25) > LD(32, 35, 25)
	and LD(34, 35, 25) < 0.03 and LD(35, 35, 25) == 0,
	string.format("loudness: full up close, gently lower (20 m: %.2f), then across the buffer smoothly to nothing (25: %.2f, 28: %.2f, 32: %.2f, 34: %.3f, 35: 0)",
		LD(20, 35, 25), LD(25, 35, 25), LD(28, 35, 25), LD(32, 35, 25), LD(34, 35, 25)))
check(LD(45, 55, 40) > LD(30, 35, 25), "a shout 45 m away is louder than speech 30 m away (each by its own reach)")
if P3.PC.c.typing then press(P3, "esc"); step() end
W.pos[3] = Vec(40, 0, 0)                                                  -- (36 m from P2: just past the 35 m bubble reach)
P3.sounds = {}
waitRate(); say(P2, "/s can you hear the murmur")
steps(90)
local ng, vg = soundsToward(P3, 4, "babble")
local b36 = P3.PC.c.bubbles[2]
check(ng >= 2 and vg > 0 and vg < 0.03 and not shows(P3, 2), string.format("36 m: no bubble, but a last faint murmur (%d syllables, vol %.3f) - the sound goes a little after the bubble", ng, vg))
steps(60 * 4)                                                             -- (that babble and its echoes are over)
W.pos[3] = Vec(42, 0, 0)                                                  -- (38 m)
P3.sounds = {}
waitRate(); say(P2, "/s and now nothing")
steps(90)
check(#P3.sounds == 0, "38 m: nothing at all")
W.pos[3] = Vec(30, 0, 0)

-- ================================================================== the host's distances
local C2 = P2.PC.cfg
check(C2.whisperR == 8 and C2.whisperMumbleR == 12 and C2.chatR == 25 and C2.mumbleR == 35 and C2.shoutR == 40 and C2.shoutMumbleR == 55,
	"the default distances: whisper 8 (garbled to 12), speak 25 (35), shout 40 (55)")
if P2.PC.c.typing then press(P2, "esc"); step() end
say(P2, "/settings"); step()
check(P2.PC.page() == "settings" and drawn(P2, "^Distances %(set by the host%)") and drawn(P2, "Speak 25 m %(to 35%)")
	and not drawn(P2, "^Distances %(host") and not drawn(P2, "^Reset$"),
	"a player who is not the host sees the host's distances: no knobs to drag, no Reset")
P2.hover = {16, 32, 2}; P2.keys.lmb = true; P2.held = {lmb = true}; step()  -- (pressing where the Speak knob would be)
P2.hover = nil; P2.mouseX = (P2.PC.cfg.winW - 64) * 30 / 80; step(); step()
P2.held = nil; step(); step(); step()
check(not P2.PC.c.drag and C2.chatR == 25 and drawn(P2, "Speak 25 m %(to 35%)"), "... and dragging on the bar does nothing")
P2.reg["savegame.mod.pcranges"] = "5,10,20"; step(); step()          -- (a guest's own registry: only its own machine's)
check(C2.chatR == 25 and HOST.PC.cfg.chatR == 25, "... and cannot change them (only the host's own registry counts)")
if P1.PC.c.typing then press(P1, "esc"); step() end
say(P1, "/settings"); step()
check(drawn(P1, "^Distances %(host") and drawn(P1, "Speak 25 m %(to 35%)"), "the host's Settings: the distance bar, with what each one is")
local BW = P1.PC.cfg.winW - 64
P1.hover = {16, 32, 2}; P1.keys.lmb = true; P1.held = {lmb = true}; step()  -- (press the Speak knob)
P1.hover = nil
P1.mouseX = BW * 30 / 80; step(); step()                                     -- (drag it to 30 m)
check(P1.PC.c.drag == 2 and P1.PC.c.dragVals[2] == 30 and drawn(P1, "Speak 30 m %(to 42%)"), "dragging the Speak knob: 30 m (garbled to 42)")
P1.held = nil; step(); step(); step()                                        -- (let go: sent, applied everywhere)
check(not P1.PC.c.drag and C2.chatR == 30 and C2.mumbleR == 42 and P1.reg["savegame.mod.pcranges"] == "8,30,40",
	"let go: every player now uses 30 m (and the host's choice is saved)")
check(drawn(P2, "Speak 30 m %(to 42%)") and not drawn(P2, "Speak 25 m"), "... and the other players' Settings show the new distance")
press(P2, "esc"); step()
W.pos[3] = Vec(32, 0, 0)                                                     -- (28 m from P2: was garbled, now in range)
if P3.PC.c.typing then press(P3, "esc"); step() end
waitRate(); say(P2, "/s heard further now")
check(lastLine(P3, "s").text == "heard further now", "28 m away now hears the words")
HOST.reg["proxchat.ranges"] = "6,20,30"; step(); step()
check(C2.whisperR == 6 and C2.chatR == 20 and C2.shoutR == 30 and math.abs(C2.mumbleR - 28) < 1e-9, "a map can set its own: SetString(\"proxchat.ranges\", \"6,20,30\")")
P1.hover = {110, 30, 1}; P1.keys.lmb = true; step(); P1.hover = nil; step(); step()   -- (Reset)
check(C2.whisperR == 8 and C2.chatR == 25 and C2.shoutR == 40 and C2.whisperMumbleR == 12, "Reset: back to the defaults")
press(P1, "esc"); step()
W.pos[3] = Vec(30, 0, 0)

-- ================================================================== only an ALL CAPS message shakes
waitRate(); say(P2, "/y no shaking here")
step()
local shook
for _, L in ipairs(P1.PC.drawOrder or {}) do if L.p == 2 and L.age == 1 then shook = L.shake end end
check(shook == false, "a Yell bubble does not shake")
waitRate(); say(P2, "/s WAIT FOR ME")
step()
for _, L in ipairs(P1.PC.drawOrder or {}) do if L.p == 2 and L.age == 1 then shook = L.shake end end
check(shook == true, "a message in ALL CAPS shakes (any mode)")

-- ================================================================== off screen and at the edges
local function inside(L) return L and L.left >= 0 and L.right <= 1920 and L.top >= 0 and L.bottom <= 1080 end
P1.offscreen = true
local Lsh = P1.PC.bubbleLayout(2, "GRAB THE CHAIN NOW", true, 1, false, false, false, W.time)
local Lwh = P1.PC.bubbleLayout(2, "psst over here", false, 1, false, true, false, W.time)
local Ltd = P1.PC.bubbleLayout(2, "...", false, 1, true, false)
P1.offscreen = nil
check(inside(Lsh) and inside(Lwh) and not Ltd and Lsh.x > 960, "speaker off screen: shout and whisper bubbles too, on the edge on the speaker's side (not the typing dots)")
P1.offscreen = true
local Lnear = P1.PC.bubbleLayout(2, "hello", false, 1, false, false, false, W.time)     -- (P2: 4 m)
local Lfar = P1.PC.bubbleLayout(3, "hello", false, 1, false, false, false, W.time)      -- (P3: 30 m)
P1.offscreen = nil
check(Lnear and Lfar and math.abs(Lnear.right - (1920 - 8 - (P1.PC.TAIL_HALF + 2) * Lnear.s)) < 1 and Lnear.s > Lfar.s,
	string.format("on the edge: 8 px from the border plus room for its tail, still sized by distance (4 m: %.2f, 30 m: %.2f)", Lnear.s, Lfar.s))
check(Lnear.cue == nil, "... beside you, level: no cue")
-- BEHIND you: the bottom edge, no cue, the tail down (2026-10-15); more than 45 degrees below you: "below"
do
local function add(u, v) return {u[1] + v[1], u[2] + v[2], u[3] + v[3]} end
P1.offscreen, P1.yaw = true, 270                                             -- (the camera turned: P2, to the east, behind it)
local Lbh = P1.PC.bubbleLayout(2, "behind you", false, 1, false, false, false, W.time)
P1.offscreen, P1.yaw = nil, nil
check(Lbh and Lbh.cue == nil and math.abs(Lbh.bottom - (1080 - 8)) < 30 and inside(Lbh),
	"a speaker behind you: the bottom edge, no cue (bottom " .. tostring(Lbh and Lbh.bottom) .. ")")
local tside = P1.PC.bubbleTail(Lbh.w, Lbh.h, (Lbh.sx - Lbh.x) / Lbh.s + Lbh.w / 2, (Lbh.sy - Lbh.y) / Lbh.s + Lbh.h + 14)
check(tside == "bottom", "... its tail points down")
local head1 = P1.PC.listenerHead()
local _, ey, cue = P1.PC.edgePoint(add(head1, Vec(0, -20, -2)))           -- (2 m ahead, 20 m down)
check(cue == "below" and ey > 1079, "far below you, ahead: the bottom edge, \"below\"")
local _, ey2, cue2 = P1.PC.edgePoint(add(head1, Vec(0, -10, 6)))          -- (behind, 10 m down: steeper than 45)
check(cue2 == "below" and ey2 > 1079, "below and behind you (steeper than 45 degrees): the bottom edge, \"below\"")
local _, _, cue3 = P1.PC.edgePoint(add(head1, Vec(0, -3, 8)))             -- (behind, 3 m down: shallower than 45)
check(cue3 == nil, "behind and a little below (less than 45 degrees): no cue")
end
P1.pixel = {3, 1076}
local Lc = P1.PC.bubbleLayout(2, string.rep("abcdefghi ", 9), false, 1, false, false, false, W.time)
P1.pixel = {1918, 2}
local Lc2 = P1.PC.bubbleLayout(2, "hello there, top right", false, 1, false, false, false, W.time)
P1.pixel = nil
check(inside(Lc) and inside(Lc2), "a speaker at a corner of the screen: the whole bubble stays on screen")
local Lmid = P1.PC.bubbleLayout(2, "hello there", false, 1, false, false, false, W.time)
local Lon = P1.PC.bubbleLayout(3, "same size", false, 1, false, false, false, W.time)       -- (on screen; the mock's depth is 10 m)
P1.offscreen = true
local Loff = P1.PC.bubbleLayout(3, "same size", false, 1, false, false, false, W.time)      -- (docked)
P1.offscreen = nil
P1.camOffset = Vec(4, 0, 0)                                                 -- (third person, facing away from P5: camera 4 m nearer)
local Lnear5 = P1.PC.bubbleLayout(5, "turning", false, 1, false, false, false, W.time)
local vNear5 = P1.PC.babbleDistance(Vec(14, 1.7, 0), 1)
P1.camOffset = Vec(-4, 0, 0)                                                -- (facing P5: camera 4 m farther)
local Lfar5 = P1.PC.bubbleLayout(5, "turning", false, 1, false, false, false, W.time)
local vFar5 = P1.PC.babbleDistance(Vec(14, 1.7, 0), 1)
P1.camOffset = nil
check(Lnear5 and Lfar5 and math.abs(Lnear5.s - Lfar5.s) < 1e-9 and math.abs(vNear5 - vFar5) < 1e-9,
	string.format("third person: turning swings the camera nearer / farther - the bubble size (%.2f / %.2f) and the loudness stay (by your character)", Lnear5.s, Lfar5.s))
check(Lon and Loff and math.abs(Lon.s - Loff.s) < 1e-9, string.format("a bubble is the same size on screen and docked (by the real distance, not the view depth: %.2f / %.2f)", Lon.s, Loff.s))
check(Lsh.docked and Lc.docked and Lc2.docked and Lmid and not Lmid.docked, "docked bubbles (on the edge, or pushed on screen) are marked: no line to the speaker; one over its speaker is not")

-- ================================================================== the test dummies (/dummy)
waitRate()
say(P1, "/dummy")
local DM = P1.PC.c.dummy
local DW, DS, DH = P1.PC.DUMMY, P1.PC.DUMMY + 1, P1.PC.DUMMY + 2         -- (whisperer, speaker, shouter)
check(DM and #DM.list == 3 and #P1.spawned == 3 and math.abs(DM.list[1].pos[3] + 3) < 0.01
	and math.abs(DM.list[1].pos[1] - DM.list[3].pos[1]) > 4.9, "/dummy: three figures in a row 3 m in front of you, 2.5 m apart")
local _, ncull = P1.spawned[1].xml:gsub('tags="nocull"', "")
check(ncull == 4, "the figures are nocull (body and its 3 boxes): they do not fade out far away")
P1.sounds = {}
steps(60)
check(drawn(P1, "^%.%.%.$") ~= nil and not P1.PC.c.bubbles[DW] and not P1.PC.c.bubbles[DS], "the whisperer shows '...' while it types")
steps(70)                                                                   -- (2.2 s)
local L1 = P1.PC.DUMMY_LINES[1]
local bw, bs, bh = P1.PC.c.bubbles[DW], P1.PC.c.bubbles[DS], P1.PC.c.bubbles[DH]
check(bw and bw.whisper and bw.text == L1[1] and not bs and not bh, "they take turns: the whisperer first")
steps(120)                                                                  -- (4.2 s)
bs, bh = P1.PC.c.bubbles[DS], P1.PC.c.bubbles[DH]
check(bs and not bs.whisper and not bs.shout and bs.text == L1[1] and not bh, "2 s later the speaker")
steps(120)                                                                  -- (6.2 s)
bh = P1.PC.c.bubbles[DH]
check(bh and bh.shout and bh.text == L1[2] and P1.PC.c.bubbles[DW] and P1.PC.c.bubbles[DS], "2 s later the shouter (the first two still up)")
step()
local R = P1.PC.c.bubbleRects or {}
local apart, raised = #R >= 3, 0
for i = 1, #R do
	for j = i + 1, #R do
		local u, v = R[i], R[j]
		if u.left < v.right and u.right > v.left and u.top < v.bottom and u.bottom > v.top then apart = false end
	end
end
for _, r in ipairs(R) do if r.bottom < R[1].bottom then raised = raised + 1 end end
check(apart and raised >= 1, "bubbles on the same spot (the mock draws every head at one pixel): " .. #R .. " stacked (above, or below with no room left), none covers another")
local names = {}
for _, e in ipairs(hist(P1)) do if P1.PC.isDummy(e.p) then names[#names + 1] = e.name end end
check(#names == 3 and names[1]:find("^Whisperer %(") and names[2]:find("^Speaker %(") and names[3]:find("^Yeller %(") and names[1] ~= names[2]:gsub("Speaker", "Whisperer"),
	"history: Whisperer / Speaker / Yeller, each in another voice: " .. table.concat(names, ", "))
steps(60)
local wsnd, ssnd = 0, 0
for _, x in ipairs(P1.sounds) do
	if math.abs(x.pos[3] + 3) < 0.01 then
		local clip = clipOf(P1, x)
		if clip:find("whisper") then wsnd = wsnd + 1 elseif clip:find("shout") then ssnd = ssnd + 1 end
	end
end
check(wsnd >= 2 and ssnd >= 2, string.format("you hear them: whisper clips (%d) and shout clips (%d) from where they stand", wsnd, ssnd))
W.pos[1] = Vec(0, 0, 25)                                                    -- (walk back: 28 m)
steps(60 * 9.5)                                                             -- (the 2nd line: all three have spoken)
bw, bs, bh = P1.PC.c.bubbles[DW], P1.PC.c.bubbles[DS], P1.PC.c.bubbles[DH]
local L2 = P1.PC.DUMMY_LINES[2]
check((not bw or bw.hidden) and bs and bs.mumble and bh and bh.level == "full" and bh.shout and P1.PC.bubbleText(DH, bh, 0) == L2[2],
	"from 28 m: no whisper, the speaker garbled, the yeller (Yell mode) readable")
W.pos[1] = Vec(0, 0, 0)
steps(60 * 11 * 8)
local seen = {}
for _, e in ipairs(hist(P1)) do if e.p == DS then seen[e.text] = true end end
local all = true
for _, l in ipairs(P1.PC.DUMMY_LINES) do if not seen[l[1]] then all = false end end
check(all, "they go through every line")
local others = 0
for _, e in ipairs(hist(P2)) do if P1.PC.isDummy(e.p) then others = others + 1 end end
check(others == 0, "only you have the dummies: nobody else hears them")
say(P1, "/dummy clear")
check(not P1.PC.c.dummy and P1.deleted[901] and P1.deleted[903] and not P1.PC.c.bubbles[DS], "/dummy clear removes them")
local nsp = #P1.spawned
say(P1, "/dummy 2")
local D2 = P1.PC.c.dummy
check(D2 and #D2.list == 1 and D2.list[1].kind == "s" and D2.byP[DS] and math.abs(D2.list[1].pos[3] + 3) < 0.01 and #P1.spawned == nsp + 1,
	"/dummy 2: just the speaker, 3 m in front of you")
W.pos[1] = Vec(0, 0, 6)
say(P1, "/dummy 3")
say(P1, "/dummy 2")                                                          -- (again: moved to the new spot)
local D3 = P1.PC.c.dummy
check(#D3.list == 2 and D3.list[1].kind == "s" and D3.list[2].kind == "y" and math.abs(D3.byP[DS].pos[3] - 3) < 0.01 and P1.deleted[nsp + 901],
	"/dummy 3 adds the shouter; /dummy 2 again moves the speaker (its old figure removed)")
steps(60 * 4.5)
local s2, s3 = P1.PC.c.bubbles[DS], P1.PC.c.bubbles[DH]
check(s2 and s3 and s2.full == P1.PC.DUMMY_LINES[D3.k][1] and s3.full == P1.PC.DUMMY_LINES[D3.k][2] and s3.t - s2.t > 1.9,
	"summoned one by one, they still take turns on the same line (2 s apart)")
say(P1, "/dummy 1")
check(#P1.PC.c.dummy.list == 3 and P1.PC.c.dummy.list[1].kind == "w", "/dummy 1: the whisperer")
say(P1, "/dummy what")
check(lastLine(P1).text:find("/dummy 1: whisperer", 1, true) ~= nil, "/dummy with anything else: how to use it")
say(P1, "/dummy clear")
check(not P1.PC.c.dummy, "/dummy clear removes them all")
say(P1, "/dummy clear")
check(lastLine(P1).text == "No test dummies to clear.", "... and says so when there are none")
W.pos[1] = Vec(0, 0, 0)

-- ================================================================== mode ids: "s" Speak ("p", the old id, still works)
W.clog = {}
waitRate(); P2.PC.say("old id still works", "p"); steps(3)
do
	local oldCh
	for _, c in ipairs(W.clog) do if c.name == "pc_near" and c.args[5] == "old id still works" then oldCh = c.args[4] end end
	check(lastLine(P1, "s").text == "old id still works" and oldCh == "s", "PC.say(text, \"p\"): the old id for Speak still works, sent as \"s\"")
end
W.clog = nil

-- ================================================================== "the chat runs here": version + heartbeat
check(P2.reg["proxchat.version"] == P2.PC.API_VERSION and P2.PC.API_VERSION >= 2 and math.abs(P2.reg["proxchat.alive"] - W.time) < 0.05
	and HOST.reg["proxchat.version"] == P2.PC.API_VERSION, "proxchat.version and proxchat.alive (GetTime) on every machine, every tick")

-- ================================================================== walls (proxchat.walls)
do
	local cfg = P1.PC.cfg
	local keep3, keep4, keep5 = W.pos[3], W.pos[4], W.pos[5]
	W.pos[1], W.pos[2], W.pos[3], W.pos[4], W.pos[5] = Vec(0, 0, 0), Vec(15, 0, 0), Vec(0, 0, 90), Vec(0, 0, -90), Vec(90, 0, 0)
	local wall = {lo = Vec(7, -5, -40), hi = Vec(7.3, 30, 40)}                  -- (a wall between P1 and P2, 15 m apart)
	W.boxes, W.pathAround = {wall}, nil
	check(P1.shared.pcWalls == false and P1.shared.pcWallsBy == "host", "walls are off by default (the host's setting)")
	-- the host's Settings: a row only the host has, On / Off for everyone
	if P1.PC.c.typing then press(P1, "esc"); step() end
	say(P1, "/settings"); step()
	check(drawn(P1, "^Walls muffle voices %(host%)$"), "the host's Settings: Walls muffle voices (host)")
	if P2.PC.c.typing then press(P2, "esc"); step() end
	say(P2, "/settings"); step()
	check(not drawn(P2, "^Walls muffle voices"), "... a guest's Settings: no such row")
	press(P2, "esc"); step()
	P1.hover = {120, 40, 7}; P1.keys.lmb = true; step(); P1.hover = nil; step(); step()   -- (On)
	check(P1.shared.pcWalls == true and P2.shared.pcWalls == true and HOST.reg["savegame.mod.pcwallson"] == true,
		"the host clicks On: walls on for everyone (saved)")
	press(P1, "esc"); step()
	P2.reg["savegame.mod.pcwallson"] = false; P2.PC.setHostWalls(false); steps(2)
	check(P1.shared.pcWalls == true, "... a guest cannot turn them off")
	P1.PC.setHostWalls(false); steps(2)
	check(P1.shared.pcWalls == false and HOST.reg["savegame.mod.pcwallson"] == false, "the host turns them off again")
	waitRate(); say(P2, "/s through the wall")
	check(lastLine(P1, "s").text == "through the wall" and P1.PC.hearDist(2) == 15, "walls off: a wall changes nothing")
	HOST.reg["proxchat.walls"] = true; steps(20)
	check(P1.shared.pcWalls == true and P1.shared.pcWallsBy == "game", "a game sets proxchat.walls = true: on for its map, over the host's Off")
	check(P1.shared.pcWalls == true and math.abs(P1.PC.hearDist(2) - 15 / cfg.wallFactor) < 1e-6 and math.abs(P1.PC.wallMul(2) - 1 / cfg.wallFactor) < 1e-6,
		string.format("walls on, sealed off (no way round): through the wall - sounds %.0f m away, the babble as far", P1.PC.hearDist(2) or -1))
	waitRate(); say(P2, "/s can you hear me")
	local lw = lastLine(P1, "s")
	check(lw.far and garbled(lw.text), "... so 15 m through a wall is the Speak buffer (30 m): garbled - " .. lw.text)
	W.pathAround = 18; steps(70)                                                  -- (a door to the side: 18 m round)
	check(math.abs(P1.PC.hearDist(2) - 18) < 1e-6, string.format("a way round (18 m) is shorter than through: heard as 18 m (%.1f)", P1.PC.hearDist(2) or -1))
	waitRate(); say(P2, "/s round the corner")
	check(lastLine(P1, "s").text == "round the corner" and not lastLine(P1, "s").far, "... round the corner within 25 m: every word")
	W.pathAround = 50; steps(70)
	check(math.abs(P1.PC.hearDist(2) - 30) < 1e-6, "a way round longer than through the wall: through it counts (30 m)")
	W.boxes = {{lo = Vec(7, -5, -0.1), hi = Vec(7.3, 30, 0.1)}}; steps(20)      -- (a pole on the line)
	check(P1.PC.hearDist(2) == 15, "a pole on the line: some rays get by - no wall")
	W.boxes = {{lo = Vec(7, -5, -40), hi = Vec(7.3, 1.5, 40)}}; steps(20)        -- (a low wall, chest high)
	check(P1.PC.hearDist(2) == 15, "a low wall: the top rays go over it - no wall")
	W.boxes = {{lo = Vec(7, -5, -40), hi = Vec(7.3, 30, -0.45)}, {lo = Vec(7, -5, 0.45), hi = Vec(7.3, 30, 40)}}; steps(20)
	check(P1.PC.hearDist(2) == 15, "a doorway on the line: the middle rays go through - no wall")
	W.pos[2] = Vec(3, 6, 0); W.boxes = {{lo = Vec(-40, 3, -40), hi = Vec(40, 3.3, 40)}}; W.pathAround = nil; steps(70)
	local d2 = P1.PC.distTo(2)
	check(math.abs(P1.PC.hearDist(2) - d2 / cfg.wallFactor) < 1e-6, string.format("a floor between them (upstairs, %.1f m): muffled, as %.1f m", d2, P1.PC.hearDist(2) or -1))
	W.pathBusy = true; W.pathAround = 4; steps(70)
	check(math.abs(P1.PC.hearDist(2) - d2 / cfg.wallFactor) < 1e-6, "while the way round is still being searched: through the floor")
	W.pathBusy = nil; steps(2)
	check(math.abs(P1.PC.hearDist(2) - d2) < 1e-6, "found a way round shorter than the distance (the stairs right there): never nearer than the speaker is")
	local asked = P1.pathAsked or 0
	steps(20)
	check((P1.pathAsked or 0) == asked, "nobody moved, less than a second: the way round is not asked again")
	-- a crowd behind walls: at most cfg.pathMax searches at once
	W.pathBusy = true
	local busy = 0
	for q = 2, 5 do P1.PC.c.walls[q] = nil end
	W.pos[3], W.pos[4], W.pos[5] = Vec(3, 6, 2), Vec(3, 6, -2), Vec(5, 6, 0)
	for q = 2, 5 do P1.PC.hearDist(q) end
	for _, o in pairs(P1.PC.c.walls) do if o.busy then busy = busy + 1 end end
	check(busy == cfg.pathMax, string.format("4 speakers behind a floor: %d searches at once (cfg.pathMax %d)", busy, cfg.pathMax))
	W.pathBusy, W.pathAround = nil, nil
	-- out of reach: no rays, no search (a Speak bubble's farthest is 35 + 1.5 m)
	for q = 2, 5 do P1.PC.c.walls[q] = nil end
	W.pos[2] = Vec(60, 0, 0); W.boxes = {{lo = Vec(30, -5, -40), hi = Vec(30.3, 30, 40)}}
	P1.PC.c.bubbles[2] = {mode = "s"}; P1.PC.c.prevBubbles[2] = nil
	local rays0 = P1.rays or 0
	local hd = P1.PC.hearDist(2)
	check((P1.rays or 0) == rays0 and hd == 60 and P1.PC.speakerReach(2) == cfg.mumbleR + cfg.soundGrace,
		"a speaker beyond their voice's reach (60 m, Speak: 36.5): no rays, no search")
	P1.PC.c.bubbles[2] = nil
	W.boxes = nil
	HOST.reg["proxchat.walls"] = false; steps(2)
	check(P1.shared.pcWalls == false and math.abs(P1.PC.hearDist(2) - P1.PC.distTo(2)) < 1e-6, "a game sets proxchat.walls = false: off for its map")
	HOST.reg["proxchat.walls"] = nil; steps(2)
	check(P1.shared.pcWalls == false and P1.shared.pcWallsBy == "host", "the game leaves it to the host again (off)")
	W.pos[1], W.pos[2], W.pos[3], W.pos[4], W.pos[5] = Vec(0, 0, 0), Vec(4, 0, 0), keep3, keep4, keep5
	steps(2)
end

-- ================================================================== the dead talk to the dead (proxchat.channel.<p>)
do
	W.pos[1], W.pos[2], W.pos[3], W.pos[4], W.pos[5] = Vec(0, 0, 0), Vec(4, 0, 0), Vec(6, 0, 0), Vec(60, 0, 0), Vec(14, 0, 0)
	HOST.reg["proxchat.channel.3"] = "dead"; HOST.reg["proxchat.channel.4"] = "dead"
	steps(2)
	check(P3.PC.dead() and P4.PC.dead() and not P1.PC.dead() and P1.PC.channelOf(3) == "dead", "P3 and P4 are dead (the game set proxchat.channel.<p> = \"dead\" on the host)")
	waitRate(); say(P3, "/y boo from beyond")
	local inShared = false
	for _, m in ipairs(P1.shared.pcMsgs) do if m.text == "boo from beyond" then inShared = true end end
	local function heardBoo(M) for _, e in ipairs(hist(M)) do if e.text == "boo from beyond" then return true end end return false end
	check(not heardBoo(P1) and not heardBoo(P2) and not heardBoo(P5) and not inShared,
		"a dead player yells 2 m from the living: they get nothing (it is not even in shared)")
	check(not (P1.PC.c.bubbles[3] and P1.PC.c.bubbles[3].full == "boo from beyond"), "... no bubble over the dead one")
	check(hasLine(P4, "d", "boo from beyond") and hasLine(P3, "d", "boo from beyond"), "the dead (P4, 54 m away) get it, tagged [dead]; so does the speaker")
	local k = "proxchat.said." .. (HOST.reg["proxchat.said.last"] % 16) .. "."
	check(HOST.reg[k .. "text"] == "boo from beyond" and HOST.reg[k .. "channel"] == "dead", "the event says channel = \"dead\" (games: no monster noise)")
	check(math.abs((HOST.reg[k .. "time"] or -1) - W.time) < 0.2, "the event has its time (the host's GetTime when it was said)")
	waitRate(); say(P2, "/s the living speak")
	local l4 = lastLine(P4, "s")
	check(l4 and l4.text == "the living speak" and not l4.far, "the dead hear the living in full from anywhere (P4, 56 m)")
	waitRate(); say(P2, "/w a living secret")
	check(hasLine(P4, "w", "a living secret"), "... whispers too")
	local kk = "proxchat.said." .. (HOST.reg["proxchat.said.last"] % 16) .. "."
	check(HOST.reg[kk .. "channel"] == "", "a living player's event: channel \"\"")
	press(P3, "return"); step()
	local dots = false
	for _, L in ipairs(P1.PC.drawOrder or {}) do if L.p == 3 then dots = true end end
	check(not dots and drawn(P3, "^Dead: $"), "a dead player typing: no \"...\" for the living; their line says \"Dead:\"")
	press(P3, "esc"); step()
	HOST.reg["proxchat.lobby"] = true; steps(2)
	waitRate(); say(P3, "everyone back to the lobby")
	check(hasLine(P1, "g", "everyone back to the lobby"), "in the lobby everyone hears everyone, the dead too")
	HOST.reg["proxchat.lobby"] = false
	-- two teams' dead: each channel to itself (names tidied to lower case)
	HOST.reg["proxchat.channel.3"] = "Dead Red"; HOST.reg["proxchat.channel.4"] = "dead blue"; HOST.reg["proxchat.channel.5"] = "dead red"
	steps(2)
	waitRate(); say(P3, "/s red team only")
	local l5 = lastLine(P5, "d")
	local function got(M) for _, e in ipairs(hist(M)) do if e.text == "red team only" then return true end end return false end
	check(l5 and l5.text == "red team only" and l5.chan == "dead red" and not got(P4) and not got(P1) and not got(P2),
		"two teams' dead (\"dead red\", \"dead blue\"): red's dead hear red's dead only - blue's dead and the living get nothing")
	check(P5.PC.channelInfo(l5.chan)[4] == "[dead red]" and P3.PC.channelInfo(P3.PC.channelOf(3))[2] == "Dead red: ", "the tag and the prompt say the channel: [dead red], \"Dead red:\"")
	HOST.reg["proxchat.channel.5"] = nil
	HOST.reg["proxchat.channel.3"] = ""; HOST.reg["proxchat.channel.4"] = nil
	steps(2)
	check(not P3.PC.dead() and not P4.PC.dead() and P1.PC.channelOf(3) == "", "alive again: the channel cleared")
	W.pos[3], W.pos[4], W.pos[5] = Vec(30, 0, 0), Vec(60, 0, 0), Vec(14, 0, 0)
	steps(2)
end

-- ================================================================== voice (prototype): /dummy voice, the helper's feed
;(function()
	local FEED = "savegame.mod.pcvx.f"
	local cfg = P1.PC.cfg
	-- the feed (protocol 2: the hex of a JSON object), decoded: raw = the object, json = its text; by[test_voice] = the
	-- voice dummies, players[id] = the real players; mic as the old feed had it (0 off, 1 always, 2 / 3 push to talk with
	-- the key up / held); to (a set of ids), toStr; rules ("ja>en,ko>en"); reqs (a list of {id, text})
	function W.feed(m)
		local str = m.reg[FEED]
		if not str then return nil end
		local j = P1.PC.hexDecode(str)
		local o = j and P1.PC.jsonDecode(j)
		if type(o) ~= "table" then return {bad = true, by = {}, players = {}, n = 0, np = 0, talking = {}, to = {}, reqs = {}} end
		local out = {raw = o, json = j, type = o.type, seq = o.seq, vol = o.volume, sid = o.session, ack = o.ack, ping = o.ping,
			listen = o.listen, talkKey = o.talk_key, lang = o.lang, live = o.live and 1 or 0, me = o.me,
			mic = o.listen == "always" and 1 or (o.listen == "push_to_talk" and (o.talk_key and 3 or 2) or 0),
			room = o.room or "", key = o.key or "", region = o.region or "", by = {}, n = 0, talking = {}, players = {}, np = 0,
			to = {}, nto = 0, reqs = {}}
		local tos, rules = {}, {}
		for _, q in ipairs(o.to or {}) do out.to[q] = true; out.nto = out.nto + 1; tos[#tos + 1] = tostring(q) end
		out.toStr = table.concat(tos, ",")
		for _, r in ipairs(o.translations or {}) do rules[#rules + 1] = r.from .. ">" .. r.to end
		out.rules = table.concat(rules, ",")
		for _, r in ipairs(o.to_translate or {}) do out.reqs[#out.reqs + 1] = {id = r.id, text = r.text} end
		for _, x in ipairs(o.speakers or {}) do
			local e = {p = x.id, talk = x.talking, gain = x.gain, az = x.azimuth, el = x.elevation, muffle = x.muffle, tv = x.test_voice,
				vol = x.volume}
			if x.test_voice then
				out.by[x.test_voice] = e
				out.n = out.n + 1
				if x.talking then out.talking[#out.talking + 1] = x.test_voice end
			else
				out.players[e.p] = e; out.np = out.np + 1
			end
		end
		return out
	end
	-- a message file as Koetama writes it: a prefab whose j tag is the hex of the object's JSON
	function W.msg(obj) return {j = P1.PC.hexEncode(P1.PC.jsonEncode(obj))} end
	function W.msgRaw(json) return {j = P1.PC.hexEncode(json)} end
	local feed = W.feed
	local function near(a, b, eps) return math.abs(a - b) <= (eps or 0.02) end
	local wallsReg = HOST.reg["proxchat.walls"]
	HOST.reg["proxchat.walls"] = false
	W.boxes, W.pathAround, W.pathBusy = nil, nil, nil
	W.pos[1] = Vec(0, 0, 0)
	for _, m in ipairs({P1, P2}) do if m.PC.c.typing then press(m, "esc"); step() end end
	steps(2)
	check(P1.reg[FEED] == nil and not P1.PC.voiceOn(), "no voice feed until someone asks for voice")
	local spawned0 = #P1.spawned
	say(P1, "/dummy voice"); steps(6)
	local VO = P1.PC.c.voice
	check(VO and #VO.list == 3 and not P1.PC.c.dummy and #P1.spawned == spawned0 + 3 and P1.spawned[#P1.spawned].xml:find("0.45 0.85 0.5", 1, true) ~= nil
		and lastLine(P1).text:find("voice dummies", 1, true) ~= nil,
		"/dummy voice: three voice dummies (green heads); the chat's own test dummies are not touched")
	local f = feed(P1)
	check(f and f.type == "feed" and f.n == 3 and f.vol == 1 and f.by[1].p == 2000 and f.by[3].p == 2002 and f.np == 0,
		"the feed for the helper (hex of JSON): type, volume, one speaker per voice dummy (test_voice 1..3, ids 2000..2002) (" .. tostring(f and f.json) .. ")")
	check(P1.reg[FEED]:find("^[0-9a-f]+$") ~= nil and f.json:sub(1, 15) == '{"type":"feed",' and f.raw.room == nil and f.raw.to == nil
		and f.raw.region == nil and f.raw.key == nil and f.listen == "off" and f.talkKey == false and f.raw.translations == nil,
		"... lower-case hex, the JSON starts with its type; no room: no room / key / to / region; listen off without Koetama")
	check(f.by[2].talk ~= nil and f.raw.speakers[1].test_voice == 1 and type(f.raw.speakers[1].talking) == "boolean" and f.raw.speakers[1].id == 2000,
		"... each voice dummy has test_voice and talking (true / false)")
	check(near(f.by[2].az, 0, 0.2) and near(f.by[2].el, 0, 0.2) and near(f.by[2].gain, 1) and f.by[2].muffle == 0,
		"the speaker 3 m ahead: straight ahead, full volume, clear")
	check(f.by[1].az < -35 and f.by[1].az > -45 and f.by[3].az > 35 and f.by[3].az < 45 and near(f.by[1].gain, cfg.voiceWhisper) and near(f.by[3].gain, 1),
		"the whisperer to the left (quieter), the yeller to the right")
	check(P2.reg[FEED] == nil, "... only on the machine that asked (the dummies are local)")
	-- turns: one talks at a time, whisperer, speaker, yeller
	local seen, both = {}, false
	local turns = 0                                                       -- (each turn: the dummy's whole line)
	for _, l in ipairs(P1.PC.VDUMMY_LINES) do turns = turns + l.dur + 0.3 + cfg.voiceGap end
	for _ = 1, math.ceil((turns + 1) * 60) do
		step()
		local t = feed(P1).talking
		if #t > 1 then both = true end
		if t[1] and seen[#seen] ~= t[1] then seen[#seen + 1] = t[1] end
	end
	check(not both and #seen >= 3 and seen[1] ~= seen[2] and seen[2] ~= seen[3] and seen[1] ~= seen[3],
		"they talk in turns, one at a time (" .. table.concat(seen, ",") .. ")")
	local seq0 = feed(P1).seq
	steps(60)
	local rate = feed(P1).seq - seq0
	check(rate >= 15 and rate <= 21, "the feed is written about 20 times a second (" .. rate .. ")")
	-- turning the camera: the direction follows
	P1.yaw = 90; steps(6)
	check(near(feed(P1).by[2].az, -90, 0.5), "looking right: the speaker ahead is now on the left (-90)")
	P1.yaw = 180; steps(6)
	check(near(math.abs(feed(P1).by[2].az), 180, 0.5), "turned round: it is behind (180)")
	P1.yaw = nil
	-- distance: the chat's ranges; the buffer muffles
	W.pos[1] = Vec(0, 0, 27); steps(6)                                    -- (30 m from the speaker)
	f = feed(P1)
	check(f.by[1].gain == 0 and f.by[2].gain > 0.02 and f.by[2].gain < cfg.soundFar and f.by[2].muffle > 0.3 and f.by[2].muffle < cfg.voiceBufferMuffle
		and f.by[3].gain > cfg.soundFar and f.by[3].muffle == 0,
		"30 m away: the whisperer silent, the speaker faint and muffled (its buffer), the yeller clear")
	W.pos[1] = Vec(0, 0, 60); steps(6)
	f = feed(P1)
	check(f.by[1].gain == 0 and f.by[2].gain == 0 and f.by[3].gain == 0, "63 m away: nobody")
	-- walls
	W.pos[1] = Vec(0, 0, 7); steps(6)                                     -- (10 m)
	local open = feed(P1).by[2]
	W.boxes = {{lo = Vec(-40, -5, 2), hi = Vec(40, 30, 2.3)}}
	steps(60)
	check(near(feed(P1).by[2].gain, open.gain) and feed(P1).by[2].muffle == 0, "a wall with walls off: no change")
	HOST.reg["proxchat.walls"] = true; steps(90)
	f = feed(P1)
	check(f.by[2].muffle == cfg.voiceWallMuffle and f.by[2].gain < open.gain, "walls on, sealed off: muffled through the wall, and quieter (it sounds farther)")
	W.pathAround = 12; steps(math.ceil((cfg.pathEvery + 1) * 60))
	f = feed(P1)
	check(f.by[2].muffle == cfg.voiceAroundMuffle and f.by[2].gain < open.gain, "a way round (12 m): heard round the corner, a little muffled")
	W.boxes, W.pathAround = nil, nil; steps(90)
	check(feed(P1).by[2].muffle == 0 and near(feed(P1).by[2].gain, open.gain), "the wall gone: clear again")
	HOST.reg["proxchat.walls"] = false; steps(4)
	-- the voice volume: on the Voice page (its own tab: a Voice button in the chat window while there are voices); saved
	say(P1, "/settings"); step()
	check(drawn(P1, "^Voice volume$") == nil, "Settings has no voice rows (they have their own page)")
	P1.PC.setPage("chat"); step()
	check(drawn(P1, "^Voice$") ~= nil, "the chat window has a Voice button while there are voices")
	P1.hover = {120, 40, 1}; P1.keys.lmb = true; step(); P1.hover = nil; step()
	check(P1.PC.page() == "voice" and drawn(P1, "^Voice volume$") ~= nil and drawn(P1, "^Koetama is required for voice chat$") ~= nil
		and drawn(P1, "^https://github%.com/AgeOfAlgorithms/koetama$") ~= nil,
		"... a click: the Voice page: Koetama is required, with its address (a button over it opens it)")
	local vol0 = P1.PC.c.voice.volume
	P1.hover = {400, 36, 1}; P1.keys.lmb = true; P1.held = {lmb = true}; P1.mouseX = 0; step(); P1.held = nil; step(); P1.hover = nil
	check(P1.PC.c.voice.volume == vol0 and P1.PC.c.voice.h.alive == false, "... its rows are greyed out: a click on the volume does nothing")
	press(P1, "esc"); step()
	P1.PC.setVoiceVolume(0.5); steps(6)
	check(feed(P1).vol == 0.5 and P1.reg["savegame.mod.pcvxvol"] == 0.5, "the voice volume goes to the helper and is saved")
	P1.PC.setVoiceVolume(1); steps(6)
	-- next to the chat's dummies
	W.pos[1] = Vec(0, 0, 0)
	say(P1, "/dummy 2"); steps(4)
	check(P1.PC.c.dummy and #P1.PC.c.dummy.list == 1 and #VO.list == 3, "/dummy 2 next to them: the chat's dummy, the voice dummies stay")
	say(P1, "/dummy voice clear"); steps(4)
	f = feed(P1)
	local seqOff = f.seq
	steps(30)
	check(#VO.list == 0 and f.n == 0 and feed(P1).seq == seqOff and P1.PC.c.dummy ~= nil and lastLine(P1).text == "The voice dummies are gone.",
		"/dummy voice clear: gone, the feed says nobody once and stops; the chat's dummy stays")
	say(P1, "/settings"); P1.PC.setPage("chat"); step()
	P1.PC.setPage("voice"); step()
	check(drawn(P1, "^Voice$") ~= nil and P1.PC.page() == "voice" and drawn(P1, "^Koetama is required for voice chat$") ~= nil,
		"... the Voice button and page are always there: without Koetama, the page says it is required")
	press(P1, "esc"); step()
	say(P1, "/dummy voice 2"); steps(6)
	f = feed(P1)
	check(#VO.list == 1 and f.n == 1 and near(f.by[2].az, 0, 0.2) and f.by[2].talk, "/dummy voice 2: just the speaker, 3 m ahead, talking")
	say(P1, "/dummy voice what")
	check(lastLine(P1).text:find("/dummy voice 1: whisperer", 1, true) ~= nil, "/dummy voice with anything else: how to use it")
	say(P1, "/dummy clear"); steps(4)
	check(#VO.list == 0 and not P1.PC.c.dummy and feed(P1).n == 0, "/dummy clear removes both kinds")
	-- a feed left on by an earlier session is switched off at the start
	P2.reg[FEED] = "6|77|1.00|5|0|3|1|en|1|||2|||||2000,1,1,1.000,0.0,0.0,0.00"            -- (an older mod's feed)
	P2.PC.c.voiceChecked = nil; steps(2)
	local f2 = feed(P2)
	check(f2.type == "feed" and f2.listen == "off" and f2.raw.room == nil and f2.np == 0 and f2.n == 0 and f2.me == 2 and f2.seq == 0
		and P2.PC.voiceFeedOff(P2.reg[FEED]), "a feed left on by an earlier session (an older protocol's too) is switched off: listen off, no room, nobody")
	local PC2 = P2.PC
	local function fs(t) return PC2.voiceFeedString(t) end
	local A = PC2.jsonArray
	check(PC2.voiceFeedOff(fs({type = "feed", seq = 3, listen = "off", speakers = A({})})) and PC2.voiceFeedOff(fs({type = "feed"}))
		and not PC2.voiceFeedOff(fs({type = "feed", listen = "off", speakers = A({}), to_translate = {{id = 1, text = "hola"}}}))
		and not PC2.voiceFeedOff(fs({type = "feed", listen = "always", speakers = A({})}))
		and not PC2.voiceFeedOff(fs({type = "feed", listen = "off", speakers = {{id = 2}}}))
		and not PC2.voiceFeedOff(fs({type = "feed", listen = "off", room = string.rep("a", 32)}))
		and not PC2.voiceFeedOff("6|3|1.00|0|0|0|0|en|1|||2|||||") and not PC2.voiceFeedOff("zz"),
		"... an 'off' feed is recognised; one with a line to translate, the microphone, a speaker or a room is not, nor an old or broken one")
	HOST.reg["proxchat.walls"] = wallsReg
	steps(2)
end)()

-- ================================================================== voice (prototype): the helper, and what you say as text
;(function()
	local FEED = "savegame.mod.pcvx.f"
	local IO = "MOD/../pcvx_"
	local cfg = P1.PC.cfg
	local head = W.feed
	-- the helper's side: its "on" file, an answer to each ping, objects numbered from 1 (the first: its hello)
	local HELPER = {on = false, n = 0}
	local function helperStep(m)
		if not HELPER.on then return end
		m.files[IO .. "on"] = true                                   -- (Koetama 0.4.0: no pcvx_v5 / pcvx_v6)
		if HELPER.n == 0 then
			HELPER.n = 1
			m.files[IO .. "t1.xml"] = W.msg({type = "hello", app = "Koetama", version = "0.4.0", protocol = 2, features = {"speech", "voices", "rooms", "translate"}})
		end
		local h = head(m)
		if h and h.ping ~= HELPER.ping then
			if HELPER.ping then m.files[IO .. "p" .. (HELPER.ping % 1000)] = nil end
			HELPER.ping = h.ping
			m.files[IO .. "p" .. (h.ping % 1000)] = true
		end
		if h then for k = 1, h.ack do m.files[IO .. "t" .. k .. ".xml"] = nil end end   -- (acked: deleted)
	end
	local function run(m, n) for _ = 1, n do helperStep(m); step() end end
	local function sendText(m, text)
		HELPER.n = HELPER.n + 1
		m.files[IO .. "t" .. HELPER.n .. ".xml"] = W.msg({type = "speech", kind = "final", utt = 100 + HELPER.n, text = text})
	end
	for _, m in ipairs({P1, P2, P3, P5}) do if m.PC.c.typing then press(m, "esc"); step() end end
	W.pos[1], W.pos[2], W.pos[3] = Vec(0, 0, 0), Vec(4, 0, 0), Vec(30, 0, 0)
	P1.PC.setVoiceMode("s")
	P1.files = {}
	local seq0 = head(P1).seq
	steps(150)
	check(head(P1).seq == seq0 and not P1.PC.voiceOn(), "no helper, no voices: the game writes nothing")
	-- the helper starts
	HELPER.on = true
	run(P1, 150)
	local VO = P1.PC.c.voice
	local h = head(P1)
	check(VO.h.alive and P1.PC.voiceOn() and h.type == "feed" and h.seq > seq0 and h.ping >= 1 and h.mic == 2 and h.sid == VO.sid and h.sid > 0,
		"the helper's file appears: the game feeds it, pings it, and it answers - connected (" .. tostring(h.json) .. ")")
	check(h.listen == "push_to_talk" and h.talkKey == false and h.ack == 1 and VO.h.hello and VO.h.hello.version == "0.4.0"
		and VO.h.hello.features.translate and VO.h.hello.protocol == 2 and P1.files[IO .. "t1.xml"] == nil,
		"... its hello (object 1) read and acked: version, protocol 2, features; listen push_to_talk, the talk key up")
	check(lastLine(P1).text:find("^Koetama connected") ~= nil, "... one line says so")
	local s1 = head(P1).seq
	run(P1, 60)
	local rate = head(P1).seq - s1
	check(rate >= 4 and rate <= 6, "with nobody to hear, the feed is slow (" .. rate .. " a second)")
	say(P1, "/settings"); helperStep(P1); step()
	check(drawn(P1, "^Voice volume$") == nil, "Settings: no voice rows")
	P1.PC.setPage("voice"); helperStep(P1); step()
	check(drawn(P1, "^Voice volume$") ~= nil and drawn(P1, "^Koetama is connected%.   Voice server: ") ~= nil and drawn(P1, "Koetama is required", true) == nil and drawn(P1, "Write what I say", true) == nil,
		"the Voice page: connected; Voice volume - and no switch for writing what you say (always on with the helper: fair to the others)")
	press(P1, "esc"); step()
	-- what you say is a chat line, flagged as spoken: the helper always listens while it runs (push to talk by default: mic 2 while the talk key is up)
	sendText(P1, "my first words")
	run(P1, 30)
	check(head(P1).ack == 2 and P1.files[IO .. "t2.xml"] == nil and lastLine(P1).text == "my first words" and lastLine(P1).voice and head(P1).mic == 2,
		"with the helper the microphone is always wanted (mic 2: push to talk, the key up), and a text from it is said")
	run(P1, 15)
	P2.sounds, P1.sounds = {}, {}
	local spoken0 = #P1.spawned
	sendText(P1, "open sesame, it's me")
	run(P1, 90)
	local l1, l2 = lastLine(P1, "s"), lastLine(P2, "s")
	check(l1 and l1.text == "open sesame, it's me" and l1.voice == true and l2 and l2.text == "open sesame, it's me" and l2.voice == true and head(P1).ack == 3,
		"a text from the helper is said like a typed line (Speak), flagged as spoken, on both machines")
	check(P2.PC.c.bubbles[1] and P2.PC.c.bubbles[1].full == "open sesame, it's me" and #P2.sounds > 0,
		"... with a bubble; P2 has no Koetama (no real voice reaches it): it hears the line babbled")
	check(#P1.sounds == 0, "... the speaker does not babble their own spoken line")
	local last = HOST.reg["proxchat.said.last"]
	local k = "proxchat.said." .. (last % 16) .. "."
	check(HOST.reg[k .. "text"] == "open sesame, it's me" and HOST.reg[k .. "voice"] == true and HOST.reg[k .. "player"] == 1 and HOST.reg[k .. "mode"] == "speak",
		"... and other mods get it as a proxchat.said event with voice = true (a spoken password)")
	check(drawn(P2, "^%[speak%] $") ~= nil and drawn(P2, "spoken") == nil and P1.PC.spokenTag == nil,
		"the history tag of a spoken line is its mode's, as typed: [speak] (no [spoken], the user 2026-10-11)")
	-- one mode for typing and talking (the user, 2026-10-11: "if I select whisper in one, the other one should whisper as well")
	P1.PC.setMode("w")
	local m1 = P1.PC.voiceMode()
	P1.PC.setVoiceMode("y")
	local m2 = P1.PC.mode()
	P1.PC.nextMode()
	local m3 = P1.PC.voiceMode()
	P1.PC.nextVoiceMode()
	local m4 = P1.PC.mode()
	check(m1 == "w" and m2 == "y" and m3 == "g" and m4 == "w" and P1.reg["savegame.mod.pcmode"] == "w" and P1.reg["savegame.mod.pcvxmode"] == "w",
		string.format("the text mode and the voice mode follow each other: %s %s %s %s (both saved)", m1, m2, m3, m4))
	P1.PC.setMode("s")
	check(P1.PC.voiceMode() == "s", "... back to Speak for the tests below")
	waitRate(); say(P1, "typed by hand"); run(P1, 30)
	check(lastLine(P2, "s").text == "typed by hand" and not lastLine(P2, "s").voice and HOST.reg["proxchat.said." .. (HOST.reg["proxchat.said.last"] % 16) .. ".voice"] == false,
		"a typed line is not flagged")
	-- a whisper: private as ever, flagged
	P1.PC.setVoiceMode("w")
	sendText(P1, "psst over here")
	run(P1, 90)
	check(lastLine(P2, "w") and lastLine(P2, "w").text == "psst over here" and lastLine(P2, "w").voice == true and not hasLine(P3, "w", "psst over here"),
		"spoken in Whisper mode: a whisper (4 m away gets it, 30 m away does not)")
	P1.PC.setVoiceMode("s")
	-- a long sentence: in pieces
	local long = ("the secret door is behind the painting in the great hall "):rep(4):gsub("%s+$", "")
	local before = #hist(P2, "s")
	sendText(P1, long)
	run(P1, 400)
	local h2 = hist(P2, "s")
	local pieces, joined = {}, {}
	for i = #h2, math.max(1, before - 3), -1 do                           -- (from the newest back: the history keeps 50 lines)
		if h2[i].voice and h2[i].text ~= "" and long:find(h2[i].text, 1, true) then table.insert(pieces, 1, h2[i]); table.insert(joined, 1, h2[i].text)
		else break end
	end
	local fits = #pieces >= 3
	for _, e in ipairs(pieces) do if P1.PC.utf8Len(e.text) > cfg.maxLen or not e.voice then fits = false end end
	check(fits and table.concat(joined, " ") == long, "a long sentence is said in pieces of at most " .. cfg.maxLen .. " characters, cut between words (" .. #pieces .. ")")
	check(P1.PC.voiceReadMsg(IO .. "nothing.xml") == nil, "a file that is not there: no object")
	P1.files[IO .. "bad.xml"] = {j = "zz"}
	check(P1.PC.voiceReadMsg(IO .. "bad.xml") == nil, "a j tag that is not hex: no object")
	P1.files[IO .. "bad.xml"] = W.msgRaw('{"type":"speech","kind":"final","text":"cut off')
	check(P1.PC.voiceReadMsg(IO .. "bad.xml") == nil, "... not JSON: no object")
	P1.files[IO .. "bad.xml"] = W.msgRaw('{"kind":"final","text":"no type"}')
	check(P1.PC.voiceReadMsg(IO .. "bad.xml") == nil, "... no type: no object")
	P1.files[IO .. "bad.xml"] = W.msgRaw('{"type":"speech","kind":"final","utt":3,"text":"ok"}')
	local okm = P1.PC.voiceReadMsg(IO .. "bad.xml")
	check(okm and okm.type == "speech" and okm.text == "ok" and okm.utt == 3, "... a good one: the object")
	P1.files[IO .. "bad.xml"] = nil
	do                                                                    -- (a listener whose Koetama plays the voice)
		local was = P2.PC.hearsRealVoices
		P2.PC.hearsRealVoices = function() return true end
		run(P1, 60 * 12)
		P2.sounds = {}
		sendText(P1, "can you hear me")
		run(P1, 90)
		check(lastLine(P2, "s") and lastLine(P2, "s").text == "can you hear me" and #P2.sounds == 0,
			"a listener who hears real voices (Koetama, a room): the line, and no babble over the voice")
		P2.PC.hearsRealVoices = was
	end
	-- the language: a row on the Voice page opening the list (supported / beta / experimental), saved, in the feed
	check(head(P1).lang == "en", "the feed says the language the player speaks (English unless chosen)")
	local LANGS = P1.PC.VOICE_LANGS
	local function langAt(code) for i, l in ipairs(LANGS) do if l[1] == code then return i end end end
	local seen, groups, okList = {}, {0, 0, 0}, true
	for _, l in ipairs(LANGS) do
		if seen[l[1]] or not groups[l[3]] then okList = false else seen[l[1]] = true; groups[l[3]] = groups[l[3]] + 1 end
	end
	check(okList and groups[1] == 15 and groups[2] == 8 and groups[3] == 7 and LANGS[1][1] == "en" and not seen.tr and not seen.vi and not seen.ar and not seen.hi,
		"the languages: 14 supported + Auto, 8 beta, 7 experimental; none without a model (Turkish, Vietnamese, Arabic, Hindi gone)")
	check(P1.PC.voiceLangIndex("tr") == 1, "a language saved earlier that has no model now: English")
	say(P1, "/settings"); P1.PC.setPage("voice"); helperStep(P1); step()
	check(drawn(P1, "Language I speak") ~= nil and drawn(P1, "^English   >$") ~= nil, "the Voice page: Language I speak, showing English")
	P1.hover = {300, 36, 2}; P1.keys.lmb = true; P1.held = {lmb = true}; helperStep(P1); step(); P1.hover = nil
	helperStep(P1); step()
	check(P1.PC.c.voice.picking and drawn(P1, "^Supported$") ~= nil and drawn(P1, "^Beta: less accurate$") ~= nil and drawn(P1, "^Experimental: ", false) ~= nil
		and drawn(P1, "^Polski$") ~= nil and drawn(P1, "^粵語$") ~= nil and drawn(P1, "^Ελληνικά$") ~= nil and drawn(P1, "^Language I speak$") == nil,
		"a click on it: the list of languages, in three groups")
	P1.hover = {182, 32, 3}; P1.release = true; helperStep(P1); step(); P1.hover = nil; P1.held = nil   -- (the opening click let go over a language)
	check(P1.PC.c.voice.picking and P1.PC.c.voice.lang == 1, "... letting go of that click over a language does not pick it")
	helperStep(P1); step()
	P1.hover = {182, 32, langAt("ru")}; P1.keys.lmb = true; helperStep(P1); step(); P1.hover = nil; run(P1, 3)
	check(LANGS[P1.PC.c.voice.lang][1] == "ru" and not P1.PC.c.voice.picking and P1.reg["savegame.mod.pcvxlang"] == "ru" and head(P1).lang == "ru"
		and drawn(P1, "^Русский   >$") ~= nil, "a click on Русский: picked, the list closes, saved, sent to the helper")
	P1.hover = {300, 36, 2}; P1.keys.lmb = true; helperStep(P1); step(); P1.hover = nil; helperStep(P1); step()
	P1.hover = {182, 32, langAt("cs")}; P1.keys.lmb = true; helperStep(P1); step(); P1.hover = nil; run(P1, 3)
	check(head(P1).lang == "cs" and drawn(P1, "^Čeština %(beta%)   >$") ~= nil, "a beta language: picked, and the row says (beta)")
	P1.hover = {300, 36, 2}; P1.keys.lmb = true; helperStep(P1); step(); P1.hover = nil; helperStep(P1); step()
	P1.hover = {130, 30, 1}; P1.keys.lmb = true; helperStep(P1); step(); P1.hover = nil; run(P1, 3)
	check(head(P1).lang == "cs" and not P1.PC.c.voice.picking and drawn(P1, "^Language I speak$") ~= nil, "< Cancel: the list closes, the language stays")
	P1.PC.setVoiceLang(langAt("el")); run(P1, 3)
	check(head(P1).lang == "el" and drawn(P1, "^Ελληνικά %(experimental%)   >$") ~= nil, "an experimental language: the row says so")
	P1.hover = {300, 36, 2}; P1.keys.lmb = true; helperStep(P1); step(); P1.hover = nil; helperStep(P1); step()
	press(P1, "esc"); step(); run(P1, 60)
	press(P1, "return"); P1.PC.setPage("voice"); helperStep(P1); step()
	check(not P1.PC.c.voice.picking and drawn(P1, "^Language I speak$") ~= nil, "the window closed with the list open: next time, the Voice page itself")
	press(P1, "esc"); step()
	P1.PC.setVoiceLang(langAt("auto")); run(P1, 3)
	check(head(P1).lang == "auto", "Auto (guess)")
	P1.PC.setVoiceLang(#LANGS + 1); run(P1, 3)
	check(head(P1).lang == "en", "past the last one: round to English again")
	-- live words while I talk: a Settings switch, saved, in the feed
	check(head(P1).live == 1, "live words are on unless switched off")
	say(P1, "/settings"); P1.PC.setPage("voice"); helperStep(P1); step()
	check(drawn(P1, "^Live words while I talk$") ~= nil, "the Voice page: Live words while I talk")
	press(P1, "esc"); step()
	P1.PC.setVoiceLiveOn(false); run(P1, 3)
	check(head(P1).live == 0 and P1.reg["savegame.mod.pcvxnolive"] == true, "switched off: the helper is told (live 0), saved")
	P1.PC.setVoiceLiveOn(true); run(P1, 3)
	check(head(P1).live == 1, "... and on again")
	-- live words: shown over the speaker's head for the players near enough, then replaced by the line
	local KINDS = {s = "start", l = "live", f = "final"}
	local function sendLive(m, kind, utt, text)
		HELPER.n = HELPER.n + 1
		m.files[IO .. "t" .. HELPER.n .. ".xml"] = W.msg({type = "speech", kind = KINDS[kind], utt = utt, text = kind ~= "s" and text or nil})
	end
	P1.PC.setVoiceMode("s")
	W.pos[2], W.pos[3], W.pos[5] = Vec(4, 0, 0), Vec(30, 0, 0), Vec(60, 0, 0)       -- (4 m: hears; 30 m: the buffer; 60 m: nothing)
	run(P1, 60 * 16)                                                       -- (the last lines' bubbles and the feed fade first)
	sendLive(P1, "l", 1, "the treasure lies")
	run(P1, 20)
	local L2 = P2.PC.voiceLiveOf(1)
	check(L2 and L2.text == "the treasure lies" and L2.ch == "s" and L2.u == 1 and HOST.shared.pcLive == nil,
		"live words reach the server and the players near enough (sent to them, never in shared)")
	check(P5.PC.voiceLiveOf(1) == nil and P4.PC.voiceLiveOf(1) == nil, "... and not the players too far away (nothing sent to them)")
	check(drawn(P2, "the treasure lies") ~= nil and drawn(P1, "^Speaking: the treasure lies$") ~= nil,
		"4 m away: the live words over the speaker's head; the speaker sees what the helper hears")
	local g3 = nil
	for _, t in ipairs(P3.texts) do if t:find(P3.PC.GARBLE[1], 1, true) and P3.PC.utf8Len(t) == P3.PC.utf8Len("the treasure lies") then g3 = t end end
	check(drawn(P3, "the treasure lies") == nil and g3 ~= nil and drawn(P5, "^%.%.%.$") == nil,
		"30 m away (the buffer): the words garbled, as a typed line's (" .. tostring(g3) .. "); 60 m: nothing")
	sendLive(P1, "l", 1, "the treasure lies under the old bridge")
	run(P1, 20)
	check(drawn(P2, "the treasure lies under the old bridge") ~= nil, "the next words replace them")
	local long = ("word "):rep(60)
	sendLive(P1, "l", 1, long)
	run(P1, 20)
	local lines, chars = 0, 0
	for _, t in ipairs(P2.texts) do if t:find("^word") and not t:find("[^word ]") then lines = lines + 1; chars = chars + #t end end
	local L2 = P2.PC.voiceLiveOf(1)
	check(lines >= 1 and L2 and P1.PC.utf8Len(L2.text) > P1.PC.cfg.maxLen and P1.PC.utf8Len(L2.text) <= P1.PC.cfg.voiceLiveMax and drawn(P2, "^…") == nil,
		"a long line: its newest " .. P1.PC.cfg.voiceLiveMax .. " characters (whole words; not cut to a typed line's " .. P1.PC.cfg.maxLen
		.. ") in a full speech bubble (" .. (L2 and P1.PC.utf8Len(L2.text) or 0) .. ")")
	sendText(P1, "the treasure lies under the old bridge")      -- (the finished line, without word times)
	run(P1, 60)
	check(lastLine(P2, "s").text == "the treasure lies under the old bridge" and lastLine(P2, "s").voice == true
		and P2.PC.voiceLiveOf(1) == nil and P3.PC.voiceLiveOf(1) == nil and drawn(P1, "^Speaking:") == nil,
		"the finished line is said as before, and the live words are gone everywhere")
	check(P2.PC.c.bubbles[1] and not P2.PC.c.bubbles[1].liveHold, "... a line without word times: a typed line's time on screen")
	-- a finished line with nothing in it (nothing made out): the live words go, nothing is said
	local before = #hist(P2, "s")
	sendLive(P1, "l", 2, "uh")
	run(P1, 20)
	sendLive(P1, "f", 2, "")
	run(P1, 30)
	check(P2.PC.voiceLiveOf(1) == nil and #hist(P2, "s") == before, "an empty finished line: the live words go, nothing is said")
	-- whispers work like the rest, and stay private: their live words go only to who is near enough
	P1.PC.setVoiceMode("w")
	run(P1, 60 * 12)                                                       -- (the last bubbles fade)
	sendLive(P1, "l", 3, "psst over here")
	run(P1, 20)
	local LW = P2.PC.voiceLiveOf(1)
	check(LW and LW.text == "psst over here" and LW.ch == "w" and drawn(P2, "^psst over here$") ~= nil and drawn(P1, "^Speaking: psst over here$") ~= nil,
		"Whisper: 4 m away the live words show (a whisper bubble), as for Speak and Yell")
	check(P3.PC.voiceLiveOf(1) == nil and P5.PC.voiceLiveOf(1) == nil and drawn(P3, "psst") == nil,
		"... 30 m away nothing - not even sent (private)")
	sendLive(P1, "f", 3, "")
	run(P1, 10)
	check(P2.PC.voiceLiveOf(1) == nil, "... and gone when the line ends")
	P1.PC.setVoiceMode("s")
	-- a helper that stops mid-line: the live words go after a while
	sendLive(P1, "l", 4, "and then")
	run(P1, 20)
	check(P2.PC.voiceLiveOf(1) ~= nil, "live words up again")
	P1.PC.c.voice.live = nil                                               -- (the helper stops sending mid-line)
	run(P1, math.ceil((P1.PC.cfg.voiceLiveLife + 1) * 60))
	check(P2.PC.voiceLiveOf(1) == nil and HOST.PC.S().live[1] == nil, "no news for " .. P1.PC.cfg.voiceLiveLife .. " s: gone")
	-- ---- talking: the helper says the player started (kind s, no text) - their head bobs at once, on every machine near
	-- enough, until the line is said (no live words needed: a short line bobs too)
	run(P1, 60 * 14)
	W.pos[2], W.pos[3], W.pos[4], W.pos[5] = Vec(4, 0, 0), Vec(30, 0, 0), Vec(80, 0, 0), Vec(14, 0, 0)
	sendLive(P1, "s", 20, "")
	run(P1, 10)
	P2.PC.bobApply(); P1.PC.bobApply()
	check(P1.PC.c.voice.talking and P1.PC.c.voice.talking.u == 20 and P2.PC.c.talking and P2.PC.c.talking[1] and P2.PC.c.bob[1] and P1.PC.c.bob[1]
		and P3.PC.c.talking and P3.PC.c.talking[1] and not (P4.PC.c.talking and P4.PC.c.talking[1]) and HOST.PC.S().talk[1],
		"started talking (kind s): the head bobs at once - here (third person) and for the players near enough (not 80 m away)")
	run(P1, 60 * 3); P2.PC.bobApply()
	check(P2.PC.c.bob[1] ~= nil, "... and keeps bobbing while they talk (3 s, no words yet)")
	sendLive(P1, "f", 20, "Okay.")
	run(P1, 40); P2.PC.bobApply(); P1.PC.bobApply()
	check(not P2.PC.c.talking[1] and not P1.PC.c.voice.talking and HOST.PC.S().talk[1] == nil and P2.PC.c.bob[1] == nil and P1.PC.c.bob[1] == nil
		and lastLine(P2, "s").text == "Okay.", "the line said: talking over everywhere, the bobbing stops (no babble-long bob after a spoken line)")
	-- ---- timed words: the helper sends each unit's start (w) and how long ago the line began (a); every listener
	-- gets only what was said while they were in reach, garbled as far as they were
	local UNIT_CASES = {{"I really like eating apples", 5}, {"Hello, world!  ok", 3}, {"我们需要 a lever 才能打开这扇门。", 14},
		{"すみません、ロープ", 9}, {"한국어 말", 4}, {"Привет, мир", 2}, {"", 0}, {"  ", 0}}
	local badU = {}
	for _, cs in ipairs(UNIT_CASES) do if #P1.PC.voiceUnits(cs[1]) ~= cs[2] then badU[#badU + 1] = cs[1] end end
	check(#badU == 0, "units split as the helper's (the same cases as its test_helper.py): " .. (#badU == 0 and "all" or table.concat(badU, " | ")))
	local us0 = P1.PC.voiceUnits("Run, 它就在!")
	check(#us0 == 5 and us0[1].w == "Run," and us0[2].w == "它" and us0[2].s == " " and P1.PC.voiceJoin(us0, 1, 3) == "Run, 它就",
		"units keep their spaces: joined back they are the text")
	local function sendTimed(m, kind, utt, text, times, ago)               -- (times: seconds per unit; ago: seconds)
		HELPER.n = HELPER.n + 1
		m.files[IO .. "t" .. HELPER.n .. ".xml"] = W.msg({type = "speech", kind = KINDS[kind], utt = utt, text = text, times = times, ago = ago})
	end
	check(P1.PC.voiceTimesHex("one two", {0.2, 1.234}, 2) == "0014007b" and select(2, P1.PC.voiceTimesHex("one two", {0.2, 1.234}, 2)) == 2
		and P1.PC.voiceTimesHex("one two", {0.2}, 2) == nil and P1.PC.voiceTimesHex("one two", {0.2, 0.5}, nil) == nil
		and P1.PC.voiceTimesHex("one two", nil, 1) == nil and P1.PC.voiceTimesHex("one two", {0.2, "x"}, 1) == nil
		and P1.PC.voiceTimesHex("one", {-1}, 1) == "0000" and P1.PC.voiceTimesHex("one", {1000}, 1) == "ffff",
		"speech times (seconds) are kept as the mod's 1/100 s units: only both with ago, one per unit, numbers, clamped")
	run(P1, 60 * 14)                                                       -- (the last bubbles fade)
	-- P2 near all along; P3 far, comes near after 1.2 s; P5 near, walks away after 1.2 s; P4 in the buffer (30 m)
	W.pos[2], W.pos[3], W.pos[4], W.pos[5] = Vec(4, 0, 0), Vec(60, 0, 0), Vec(30, 0, 0), Vec(4, 0, 0)
	run(P1, 30)
	local el = 0                                                           -- (s since the line began)
	run(P1, 72); el = el + 72 / 60
	W.pos[3], W.pos[5] = Vec(4, 0, 0), Vec(60, 0, 0)
	run(P1, 54); el = el + 54 / 60
	P1.reg["game.thirdperson"] = true
	sendTimed(P1, "l", 9, "one two three four", {0.2, 0.6, 1.4, 1.8}, el)
	run(P1, 20); el = el + 20 / 60
	local l2, l3 = P2.PC.voiceLiveOf(1), P3.PC.voiceLiveOf(1)
	check(l2 and l2.times and #l2.times == 4 and l2.start and P2.PC.voiceLiveSeen(1, l2) == "one two three four" and drawn(P2, "^one two three four$") ~= nil,
		"live words with times: near all along - all of them in the bubble")
	check(l3 and P3.PC.voiceLiveSeen(1, l3) == "... three four" and drawn(P3, "^%.%.%. three four$") ~= nil,
		"... arrived after 1.2 s: only what was said since (\"... three four\")")
	check(P5.PC.voiceLiveOf(1) == nil, "... walked away: no more live words for them")
	check(drawn(P1, "^one two three four$") ~= nil and drawn(P1, "^Speaking: one two three four$") ~= nil,
		"the speaker in third person: their own bubble fills with the words too")
	run(P1, 18); el = el + 18 / 60
	sendTimed(P1, "f", 9, "one two three four five six", {0.2, 0.6, 1.4, 1.8, 2.4, 2.8}, el)
	run(P1, 60)
	local h2, h3, h4, h5 = lastLine(P2, "s"), lastLine(P3, "s"), lastLine(P4, "s"), lastLine(P5, "s")
	check(h2 and h2.text == "one two three four five six" and h2.voice, "the finished line: near all along - all of it")
	local b2 = P2.PC.c.bubbles[1]
	check(b2 and b2.liveHold and P2.PC.bubbleLife(b2) == P2.PC.cfg.voiceHold and P2.PC.voiceLiveOf(1) == nil,
		"... it takes the live bubble's place (same full bubble) and goes after " .. P2.PC.cfg.voiceHold .. " s: its words were read as they came")
	P2.PC.setHideVoiceBubbles(true); step()
	local shown2 = false
	for _, r in ipairs(P2.PC.c.bubbleRects or {}) do if r.p == 1 then shown2 = true end end
	check(not shown2 and P2.reg["savegame.mod.pcnovoicebubbles"] == true and lastLine(P2, "s").text == "one two three four five six",
		"Settings: Bubbles for spoken lines - Hide: no bubble for it (saved); still in the history")
	P2.PC.setHideVoiceBubbles(false); step()
	check(h3 and h3.text == "... three four five six" and h3.voice, "... arrived late: \"... three four five six\"")
	check(h5 and h5.text == "one two ..." and h5.voice and h5.far ~= true, "... walked away: \"one two ...\" (and in the history though out of earshot now)")
	check(h4 and h4.far and h4.text:find(P4.PC.GARBLE[1], 1, true) ~= nil and P4.PC.utf8Len(h4.text) == P4.PC.utf8Len("one two three four five six"),
		"... in the buffer all along: all of it, garbled (" .. tostring(h4 and h4.text) .. ")")
	local before4 = lastLine(P4, "s").text
	W.pos[4] = Vec(4, 0, 0)
	run(P1, 30)
	check(lastLine(P4, "s").text == before4 and lastLine(P4, "s").far,
		"... walking closer afterwards reveals nothing: a spoken word stays as it was heard (unlike a typed line)")
	check(HOST.PC.S().live[1] == nil and P2.PC.voiceLiveOf(1) == nil, "the live words are gone everywhere")
	-- each word as clearly as it was heard when said: P3 close for the start, then in the buffer - the start stays clear,
	-- the rest garbled, live and finished alike (nothing reveals itself when the speaker stops)
	run(P1, 60 * 14)
	W.pos[2], W.pos[3], W.pos[4], W.pos[5] = Vec(4, 0, 0), Vec(4, 0, 0), Vec(60, 0, 0), Vec(60, 0, 0)
	run(P1, 30)
	el = 0
	run(P1, 72); el = el + 72 / 60
	W.pos[3] = Vec(30, 0, 0)
	run(P1, 54); el = el + 54 / 60
	sendTimed(P1, "l", 10, "alpha bravo charlie delta", {0.2, 0.6, 1.4, 1.8}, el)
	run(P1, 20); el = el + 20 / 60
	local live3 = nil
	for _, t in ipairs(P3.texts) do if t:find("^alpha bravo ") then live3 = t end end
	local GL = P3.PC.GARBLE[1]
	check(live3 and live3:find(GL, 1, true) and not live3:find("charlie delta", 1, true),
		"live: the words said while close stay clear, those said from the buffer are garbled (" .. tostring(live3) .. ")")
	run(P1, 18); el = el + 18 / 60
	sendTimed(P1, "f", 10, "alpha bravo charlie delta echo", {0.2, 0.6, 1.4, 1.8, 2.4}, el)
	run(P1, 3)
	local fin3 = nil
	for _, t in ipairs(P3.texts) do if t:find("^alpha bravo ") then fin3 = t end end
	local h3b = lastLine(P3, "s")
	check(fin3 and fin3:find(GL, 1, true) and live3 and fin3:sub(1, #live3) == live3:gsub(GL, GL),
		"finished: the same - the start clear, the rest garbled as it was live (" .. tostring(fin3) .. ")")
	check(h3b and h3b.far and h3b.text:find("^alpha bravo ") and h3b.text:find(GL, 1, true), "... and so in the history")
	W.pos[3] = Vec(4, 0, 0)
	run(P1, 20)
	local fin3b = nil
	for _, t in ipairs(P3.texts) do if t:find("^alpha bravo ") then fin3b = t end end
	check(fin3b and fin3b:gsub(GL, "#") == fin3:gsub(GL, "#") and lastLine(P3, "s").text == h3b.text,
		"... coming back close afterwards changes nothing: garbled words stay garbled, clear ones clear")
	P1.reg["game.thirdperson"] = nil
	W.pos[2], W.pos[3], W.pos[4], W.pos[5] = Vec(4, 0, 0), Vec(30, 0, 0), Vec(60, 0, 0), Vec(14, 0, 0)
	-- a voice dummy says its whole line: its bubble fills chunk by chunk, then the line is in the history
	run(P1, 60 * 14)
	say(P1, "/dummy voice 2"); run(P1, 3)
	local vd = P1.PC.c.voice.list[1]
	run(P1, math.floor(2.5 * 60))
	local vl = P1.PC.voiceLiveOf(vd.p)
	check(vd.talking and vl and vl.text == "I am the speaker." and drawn(P1, "^I am the speaker%.$") ~= nil,
		"a voice dummy talking: after 2 s its bubble shows the words it has said (\"I am the speaker.\")")
	run(P1, math.floor(3 * 60))
	local vl2 = P1.PC.voiceLiveOf(vd.p)
	check(vl2 and #vl2.text > #vl.text and vl2.text:sub(1, #vl.text) == vl.text, "... and more a few seconds later, never taking any back (" .. (vl2 and vl2.text or "?") .. ")")
	run(P1, math.floor((P1.PC.VDUMMY_LINES[2].dur - 5.5 + 0.6) * 60))
	local hd = lastLine(P1, "s")
	check(hd and hd.name == "Speaker" and hd.voice and hd.text == P1.PC.VDUMMY_LINES[2].text and P1.PC.voiceLiveOf(vd.p) == nil,
		"... its line done: said in full, in the history as spoken; the live words gone")
	say(P1, "/dummy voice clear"); run(P1, 3)
	W.pos[2], W.pos[3], W.pos[5] = Vec(4, 0, 0), Vec(30, 0, 0), Vec(14, 0, 0)
	-- the helper stops (while its page is open)
	press(P1, "return"); P1.PC.setPage("voice"); step()
	local wasVoice = P1.PC.page() == "voice"
	HELPER.on = false
	P1.files = {[IO .. "p" .. (HELPER.ping % 1000)] = true}             -- (a crash: its last answer is left behind)
	steps(math.ceil((cfg.voicePing + cfg.voicePongWait + 1) * 60))
	check(not VO.h.alive and not P1.PC.voiceOn() and lastLine(P1).text == "Koetama disconnected: voice chat is off." and head(P1).mic == 0,
		"the helper stops answering: disconnected, the feed says so (mic 0)")
	check(wasVoice and P1.PC.page() == "voice" and drawn(P1, "^Koetama is required for voice chat$") ~= nil and drawn(P1, "^Voice volume$") ~= nil,
		"... the open Voice page stays, now saying Koetama is required (its rows greyed out)")
	press(P1, "esc"); step()
	local s2 = head(P1).seq
	steps(120)
	check(head(P1).seq == s2, "... and the game writes nothing more")
	P1.files = nil
	steps(2)
end)()

-- ================================================================== the talk key (push to talk), the voice's mode, controllers
;(function()
	local FEED = "savegame.mod.pcvx.f"
	local IO = "MOD/../pcvx_"
	local M = P2
	local function head() return W.feed(M) end
	local ping, n = nil, 0
	local function helperStep()
		M.files[IO .. "on"] = true
		local p = M.reg[FEED] and W.feed(M).ping
		if p and p ~= ping then
			if ping then M.files[IO .. "p" .. (ping % 1000)] = nil end
			ping = p
			M.files[IO .. "p" .. (p % 1000)] = true
		end
	end
	local function run(k) for _ = 1, k do helperStep(); step() end end
	local function sendText(text)
		n = n + 1
		M.files[IO .. "t" .. (M.PC.c.voice and M.PC.c.voice.ack or 0) + 1 .. ".xml"] = W.msg({type = "speech", kind = "final", utt = n, text = text})
	end
	local function hold(keys) M.held = keys end
	for _, m in ipairs(MACHINES) do if m.PC.c.typing then press(m, "esc"); step() end end
	W.pos[1], W.pos[2], W.pos[3] = Vec(0, 0, 0), Vec(4, 0, 0), Vec(30, 0, 0)
	M.files = {}
	M.reg["options.input.keymap.jump"] = "space"                        -- (some of Teardown's keymap)
	M.reg["options.input.keymap.camera_view"] = "v"
	M.reg["options.input.keymap.map"] = "tab"
	M.lastKey = ""
	M.InputLastPressedKey = function() return M.lastKey end
	M.device = 1
	M.LastInputDevice = function() return M.device end
	run(90)
	local VO = M.PC.c.voice
	check(VO and VO.h.alive, "P2's helper is connected")
	-- push to talk: the default, B
	check(VO.ptt and VO.talkKey == "b" and head().listen == "push_to_talk" and head().talkKey == false,
		"push to talk is the default, the talk key B; the feed says listen push_to_talk, talk_key false (the key up)")
	local typedMode = M.PC.mode()
	run(3)
	local tk0 = head().seq
	hold({b = true}); helperStep(); step()
	check(head().listen == "push_to_talk" and head().talkKey == true and head().seq == tk0 + 1 and M.reg["game.disablemap"] == true,
		"B held: talk_key true in the feed in that same frame (one write); Teardown's map (Tab) is off meanwhile")
	check(M.reg["proxchat.talking." .. M.me] == true and M.reg["proxchat.key.talk"] == "b",
		"... and games see it: proxchat.talking.<me> true, proxchat.key.talk \"b\" (API 8)")
	check(M.PC.c.talkShown and M.PC.c.talkShown.mode == "s" and drawn(M, "^Speak$") and drawn(M, "^Yell$") and drawn(M, "^Global$")
		and drawn(M, "Push to talk", true), "the window closed: the strip at the bottom shows the modes, Speak lit")
	-- B + Tab: Whisper -> Speak -> Yell -> Global -> Whisper
	local seen = {}
	for _ = 1, 4 do
		M.keys.tab = true; helperStep(); step()
		seen[#seen + 1] = M.PC.voiceMode()
	end
	check(table.concat(seen, " ") == "y g w s" and M.reg["savegame.mod.pcvxmode"] == "s", "B + Tab cycles Yell, Global, Whisper, Speak (saved): " .. table.concat(seen, " "))
	M.keys.tab = true; helperStep(); step()
	check(M.PC.c.talkShown.k < 1 and M.PC.c.talkShown.mode == "y", "a switch animates (the light slides, the name pops)")
	steps(30)
	check(M.PC.c.talkShown.k >= 1, "... for a moment")
	check(M.PC.mode() == "y" and M.reg["savegame.mod.pcmode"] == "y",
		"the typed line follows the voice's mode (one mode for both, 2026-10-11): Yell, from " .. typedMode)
	hold(nil); helperStep(); step()
	check(head().mic == 2 and M.reg["game.disablemap"] == false, "B let go: mic 2, the map back")
	steps(30)
	check(not drawn(M, "^Yell$"), "... and the strip fades away")
	M.keys.tab = true; step()
	check(M.PC.voiceMode() == "y", "Tab alone does not switch the voice's mode")
	-- a line said in Yell, then in Global (to everyone, as text only: no bubble, no babble)
	M.sounds, P1.sounds, P3.sounds = {}, {}, {}
	sendText("over here"); run(30)
	check(lastLine(P1, "y") and lastLine(P1, "y").text == "over here" and lastLine(P1, "y").voice, "a spoken line goes out in the voice's mode (Yell)")
	run(60 * 12)
	hold({b = true}); M.keys.tab = true; helperStep(); step(); hold(nil); helperStep(); step()
	check(M.PC.voiceMode() == "g", "Global")
	P1.sounds, P3.sounds = {}, {}
	sendText("hello everyone"); run(30)
	check(lastLine(P3, "g") and lastLine(P3, "g").text == "hello everyone" and not P3.PC.c.bubbles[2] and not P1.PC.c.bubbles[2]
		and #P1.sounds == 0 and #P3.sounds == 0, "Global by voice: everyone gets the words (30 m too), no bubble, no babble")
	M.PC.setVoiceMode("s")
	-- typing: B is a letter then
	press(M, "return")
	hold({b = true}); helperStep(); step()
	check(head().mic == 2 and not M.PC.c.voice.held, "while typing, B types (no talking)")
	hold(nil); press(M, "esc"); step()
	-- the Voice page: Microphone, Talk key, My voice
	press(M, "return"); M.PC.setPage("voice"); helperStep(); step()
	check(drawn(M, "^Microphone$") and drawn(M, "^Push to talk$") and drawn(M, "^Always on$") and drawn(M, "^Talk key %(hold it to talk%)$")
		and drawn(M, "^B   >$") and drawn(M, "^My voice %(talk key %+ Tab%)$"), "the Voice page: Microphone, Talk key (B), My voice")
	-- rebinding: a click on the key's button, then a key
	M.hover = {300, 36, 1}; M.keys.lmb = true; M.held = {lmb = true}; helperStep(); step(); M.hover = nil; M.held = nil
	helperStep(); step()
	check(VO.binding and drawn(M, "Press a key", true), "Talk key: waiting for a key")
	M.lastKey = "v"; M.typed = "v"; helperStep(); step(); M.lastKey = ""; helperStep(); step()
	check(VO.talkKey == "b" and not VO.binding and lastLine(M).text:find("camera_view", 1, true) and M.PC.c.text == "",
		"V refused: it is Teardown's camera key (said why); nothing typed into the line")
	M.hover = {300, 36, 1}; M.keys.lmb = true; M.held = {lmb = true}; helperStep(); step(); M.hover = nil; M.held = nil
	helperStep(); step()
	M.lastKey = "g"; M.typed = "g"; helperStep(); step(); M.lastKey = ""; helperStep(); step()
	check(VO.talkKey == "g" and M.reg["savegame.mod.pcvxkey"] == "g" and M.PC.c.text == "" and M.PC.c.typing, "G taken (saved); the chat stays open, its line empty")
	M.hover = {300, 36, 1}; M.keys.lmb = true; M.held = {lmb = true}; helperStep(); step(); M.hover = nil; M.held = nil
	helperStep(); step()
	M.lastKey = "esc"; M.keys.esc = true; helperStep(); step(); M.lastKey = ""; helperStep(); step()
	check(VO.talkKey == "g" and not VO.binding and M.PC.c.typing, "Esc: the old key stays, and the chat is not closed by it")
	press(M, "esc"); step()
	hold({g = true}); helperStep(); step()
	check(head().mic == 3, "the new key talks")
	hold(nil); helperStep(); step()
	M.PC.setTalkKey("b")
	-- always on
	M.PC.setVoicePtt(false); run(2)
	check(head().mic == 1 and head().listen == "always" and head().talkKey == false and M.reg["savegame.mod.pcvxalwayson"] == true,
		"Always on: listen always (the helper's speech detector), saved")
	hold({b = true}); M.keys.tab = true; helperStep(); step()
	check(head().mic == 1 and M.PC.voiceMode() == "y" and drawn(M, "Always on", true), "... B + Tab still switches the mode (mic stays 1)")
	hold(nil); helperStep(); step()
	M.PC.setVoicePtt(true); M.PC.setVoiceMode("s"); run(2)
	-- a controller: both sticks are Enter (the chat, on its line), Y the settings - the D-pad moves and changes, B closes
	M.device = 2
	M.keys.zoom = true; helperStep(); step()
	check(not M.PC.windowOpen(), "one L3 click (the game's zoom): nothing")
	steps(30)
	M.keys.zoom = true; helperStep(); step()
	check(not M.PC.windowOpen(), "... another, half a second later: still nothing (not a double click)")
	M.keys.zoom = true; helperStep(); step(); M.keys.zoom = true; helperStep(); step()
	check(M.PC.c.typing and not M.PC.c.nav and M.PC.windowOpen() and M.PC.page() == "chat" and M.interactive,
		"L3 twice: the chat opens on its line, as Enter")
	M.keys.zoom = true; helperStep(); step(); M.keys.zoom = true; helperStep(); step(); step()
	check(not M.PC.c.typing and not M.PC.windowOpen(), "... L3 twice again, nothing typed: closed, as Enter")
	M.keys.zoom = true; helperStep(); step(); M.keys.zoom = true; helperStep(); step()
	M.PC.c.text = "said with the sticks"
	M.keys.zoom = true; helperStep(); step(); M.keys.zoom = true; helperStep(); step(); steps(30)
	local said = false
	for _, e in ipairs(M.PC.history()) do if e.text == "said with the sticks" then said = true end end
	check(said and not M.PC.c.typing, "... with a line typed, L3 twice says it, as Enter")
	M.keys.zoom = true; helperStep(); step(); M.keys.zoom = true; helperStep(); step()
	M.keys.menu_next = true; helperStep(); step(); M.keys.menu_next = true; helperStep(); step()
	check(M.PC.c.nav and M.PC.windowOpen() and M.PC.page() == "voice" and M.interactive and drawn(M, "D-pad: move", true),
		"... then R1, R1: Translate, then the Voice page, for the D-pad")
	run(2)
	local rows = M.PC.c.navN
	check(rows and rows >= 6, "the items: the header and the Voice page's rows (" .. tostring(rows) .. ")")
	-- (R1 lands on the page's first row, Voice volume)
	-- (the players' volumes are their own subsection at the end of the page now, 2026-10-15)
	M.keys.menu_down = true; helperStep(); step()                     -- (then Microphone)
	M.keys.menu_right = true; helperStep(); step(); helperStep(); step()   -- (the feed: written the next frame)
	check(not VO.ptt and head().mic == 1, "D-pad right on Microphone: Always on (mic 1)")
	M.keys.menu_accept = true; helperStep(); step()
	check(VO.ptt, "A: back to push to talk")
	M.keys.scroll_down = true; helperStep(); step()                    -- (the play set's D-pad works too: Talk key)
	M.keys.scroll_down = true; helperStep(); step()                    -- (My voice)
	M.keys.tool_group_next = true; helperStep(); step()
	check(M.PC.voiceMode() == "y", "D-pad right on My voice: Yell")
	M.keys.menu_left = true; helperStep(); step()
	check(M.PC.voiceMode() == "s", "... left: Speak")
	M.keys.menu_down = true; helperStep(); step()                     -- (Language I speak)
	local l0 = VO.lang
	M.keys.menu_right = true; helperStep(); step()
	check(VO.lang == l0 + 1 and not VO.picking, "Language: right steps to the next one (no mouse list)")
	M.keys.menu_left = true; helperStep(); step()
	for _ = 1, 40 do M.keys.menu_down = true; helperStep(); step() end
	check(M.PC.c.navRow == M.PC.c.navN, "down stops at the last item")
	for _ = 1, 40 do M.keys.menu_up = true; helperStep(); step() end
	M.keys.menu_right = true; helperStep(); step()
	check(M.PC.page() == "settings" and drawn(M, "^Squeaky$"), "the header: right switches to Settings")
	M.keys.menu_down = true; helperStep(); step()
	local v0 = M.PC.voiceOf(M.me)
	M.keys.menu_right = true; helperStep(); step(); steps(3)
	check(M.PC.c.voiceWant == v0 % #M.PC.VOICES + 1 or P1.shared.pcVoice[M.me] == v0 % #M.PC.VOICES + 1, "Settings: right on the voices picks the next voice")
	M.keys.flashlight = true; helperStep(); step()
	check(not M.PC.c.nav and M.PC.c.typing and M.PC.page() == "chat", "Y on a page: back to the chat")
	check(drawn(M, "^R1: pages   Right stick: scroll$"), "... whose header says R1 goes to the pages")
	M.keys.menu_prev = true; helperStep(); step()
	check(M.PC.c.nav and not M.PC.c.typing, "L1: the pages again (Settings)")
	M.keys.menu_cancel = true; helperStep(); step()
	check(not M.PC.c.nav and not M.PC.windowOpen() and not M.interactive, "B: closed")
	M.device = 1
	hold({zoom = true}); M.keys.scoreboard = true; helperStep(); step(); hold(nil)
	check(not M.PC.c.nav, "a keyboard's Shift (scoreboard) with zoom does not open it: controllers only")
	M.files, M.LastInputDevice, M.InputLastPressedKey = nil, nil, nil
	steps(2)
end)()

-- ================================================================== real voices: the room, every voice mode, feed version 5
;(function()
	local FEED = "savegame.mod.pcvx.f"
	local IO = "MOD/../pcvx_"
	local M = P3                                                          -- (P3 runs a helper here)
	local feed = W.feed
	local ping = nil
	local function helperStep()
		M.files[IO .. "on"] = true
		local p = M.reg[FEED] and W.feed(M).ping
		if p and p ~= ping then
			if ping then M.files[IO .. "p" .. (ping % 1000)] = nil end
			ping = p
			M.files[IO .. "p" .. (p % 1000)] = true
		end
	end
	local function run(k) for _ = 1, k do helperStep(); step() end end
	local function sendObj(obj)                                           -- (the next object the helper writes)
		local vo = M.PC.c.voice
		M.files[IO .. "t" .. ((vo and vo.ack or 0) + 1) .. ".xml"] = W.msg(obj)
	end
	local function vmodes() return HOST.shared.pcVMode or {} end
	for _, m in ipairs(MACHINES) do if m.PC.c.typing then press(m, "esc"); step() end end
	for _, m in ipairs(MACHINES) do m.PC.setVoiceMode("s") end
	steps(70)
	local allS = true
	for _, m in ipairs(MACHINES) do if vmodes()[m.me] ~= "s" then allS = false end end
	check(allS, "every player's voice mode is known to the host (shared.pcVMode): Speak")
	P5.PC.setVoiceMode("y"); steps(3)
	check(vmodes()[5] == "y" and P1.PC.c.vmodes[5] == "y" and P4.PC.c.vmodes[5] == "y", "a change reaches the host at once, and every game (P5 yells)")
	HOST.server.pc_vmode(5, TOK(5), "shout"); HOST.server.pc_vmode(5, TOK(5), nil); steps(2)
	check(vmodes()[5] == "y", "... a mode that is not one is refused")
	P5.PC.setVoiceMode("s"); steps(3)
	-- the room: P3's helper makes one; positions (P3 talks; the rest around it)
	W.pos[3], W.pos[1], W.pos[2], W.pos[4] = Vec(100, 0, 0), Vec(100, 0, 10), Vec(100, 0, 38), Vec(100, 0, 62)
	W.pos[5], W.pos[6], W.pos[7], W.pos[8] = Vec(100, 0, -14), Vec(100, 0, -50), Vec(0, 0, 0), Vec(0, 0, -3)
	M.files = {}
	run(150)
	local VO = M.PC.c.voice
	local f = feed(M)
	check(VO.h.alive and f and f.type == "feed" and f.raw.translations == nil and f.raw.to_translate == nil and f.raw.room == nil and f.raw.key == nil
		and f.raw.to == nil and f.raw.region == nil and f.me == 3 and f.np == 0,
		"the feed without a room: no room, key, to or region, no translations, me = 3, no real players (" .. tostring(f and f.json) .. ")")
	local ROOM, KEY = string.rep("0123456789abcdef", 2), string.rep("fedcba9876543210", 4)
	HOST.server.pc_room(2, TOK(2), ROOM:upper(), KEY); HOST.server.pc_room(2, TOK(2), ROOM .. "0", KEY); HOST.server.pc_room(2, TOK(2), ROOM, KEY:sub(2))
	HOST.server.pc_room(2, TOK(2), ROOM:sub(1, 31) .. "g", KEY); HOST.server.pc_room(2, TOK(2), ROOM, nil)
	check(HOST.shared.pcVoiceRoom == nil, "a room that is not 32 + 64 lower-case hex digits is refused (upper case, too long, too short, not hex)")
	local n3 = #hist(M)
	sendObj({type = "room", room = "not a room", key = KEY}); run(10)
	sendObj({type = "room", room = ROOM}); run(10)
	sendObj({type = "room", room = ROOM:upper(), key = KEY}); run(10)
	check(VO.roomWant == nil and HOST.shared.pcVoiceRoom == nil and #hist(M) == n3, "a room object that is not a room (bad, no key, upper case): nothing offered, nothing shown")
	sendObj({type = "room", room = ROOM, key = KEY}); run(10)
	local okRoom = true
	for _, m in ipairs(MACHINES) do local r = m.shared.pcVoiceRoom; if not (r and r.id == ROOM and r.key == KEY) then okRoom = false end end
	check(HOST.shared.pcVoiceRoom and HOST.shared.pcVoiceRoom.id == ROOM and HOST.shared.pcVoiceRoom.key == KEY and okRoom and VO.roomWant == nil,
		"a room object {room, key}: offered to the host, kept, published to every player (shared.pcVoiceRoom)")
	local shownRoom = false
	for _, m in ipairs(MACHINES) do for _, e in ipairs(hist(m)) do if (e.text or ""):find(ROOM:sub(1, 8), 1, true) then shownRoom = true end end end
	check(#hist(M) == n3 and not shownRoom and not M.PC.c.voice.talking and M.PC.voiceLiveOf(3) == nil, "... never shown or said (no line, no live words, no talking)")
	local ROOM2, KEY2 = string.rep("a", 32), string.rep("b", 64)
	sendObj({type = "room", room = ROOM2, key = KEY2}); run(10)
	HOST.server.pc_room(5, TOK(5), ROOM2, KEY2); steps(2)
	check(HOST.shared.pcVoiceRoom.id == ROOM and HOST.shared.pcVoiceRoom.key == KEY, "a second room (another helper, or the same one again): the first stays for the session")
	f = feed(M)
	check(f.room == ROOM and f.key == KEY and f.me == 3 and f.raw.region == "" and P1.PC.jsonIsArray(f.raw.to),
		"the feed carries the room, its key, me, to (an array) and region (\"\": Auto)")
	local s0 = f.seq
	run(60)
	local rate = feed(M).seq - s0
	check(rate >= 15 and rate <= 21, "with a room the feed is written 20 times a second (" .. rate .. ")")
	-- to: who gets P3's voice (P1 10 m, P5 14 m, P2 38 m, P6 50 m, P4 62 m, P7 100 m)
	local function to() local t = {} for q in pairs(feed(M).to) do t[#t + 1] = q end table.sort(t) return table.concat(t, ",") end
	check(to() == "1,2,5", "to, Speak (35 + 5 m): P1, P5, P2 - not P6 (50 m), not P3 itself: " .. to())
	-- per-player volume (2026-10-10): a speaker's "volume" only when it is not 1 (P3 hears P1 at 10 m and P5 at 14 m)
	local fv = feed(M)
	check(fv.players[1] and fv.players[5] and fv.players[1].vol == nil and fv.players[5].vol == nil, "per-player volume: 100 % - no \"volume\" on the speakers")
	M.PC.setPlayerVolume(1, 1.5); M.PC.setPlayerVolume(5, 0); run(3)
	fv = feed(M)
	check(fv.players[1] and fv.players[1].vol == 1.5 and fv.players[5] and fv.players[5].vol == 0 and (fv.players[2] == nil or fv.players[2].vol == nil),
		"... P1 at 150 %: volume 1.5; P5 at 0 %: volume 0 (still a speaker: Koetama multiplies); P2 (38 m) untouched: none")
	M.PC.setPlayerVolume(1, 1); M.PC.setPlayerVolume(5, 1); run(3)
	fv = feed(M)
	check(fv.players[1].vol == nil and fv.players[5].vol == nil and M.reg["savegame.mod.pcpvol.5031"] == nil, "... back to 100 %: none again, the saved key cleared")
	M.PC.setVoiceMode("w"); run(8)
	check(to() == "1,5", "to, Whisper (12 + 5 m): P1, P5: " .. to())
	M.PC.setVoiceMode("y"); run(8)
	check(to() == "1,2,5,6", "to, Yell (55 + 5 m): P1, P5, P2, P6 - not P4 (62 m): " .. to())
	M.PC.setVoiceMode("g"); run(8)
	check(to() == "" and vmodes()[3] == "g" and feed(M).json:find('"to":[]', 1, true) ~= nil, "to, Global: nobody - an empty [] (and the host knows P3 is in Global)")
	M.PC.setVoiceMode("s"); run(8)
	HOST.reg["proxchat.lobby"] = true; run(8)
	check(to() == "1,2,4,5,6,7,8", "to, the lobby: everyone else: " .. to())
	HOST.reg["proxchat.lobby"] = false; run(8)
	HOST.reg["proxchat.channel.3"] = "dead"; run(8)
	check(M.PC.dead() and to() == "", "to, dead with no other dead: nobody (the living never hear the dead)")
	HOST.reg["proxchat.channel.7"] = "dead"; HOST.reg["proxchat.channel.4"] = "dead red"; run(8)
	check(to() == "7", "to, dead: the dead of my channel at any distance (P7, 100 m; not P4 in another channel): " .. to())
	HOST.reg["proxchat.channel.3"] = nil; run(8)
	check(to() == "1,2,4,5,7", "to, alive (Speak): the near ones, and every dead player wherever they are (P4, P7): " .. to())
	HOST.reg["proxchat.channel.7"] = nil; HOST.reg["proxchat.channel.4"] = nil; run(8)
	-- the real players as speakers (src 0, id = their player id), as the dummies are heard
	f = feed(M)
	local e1, e5 = f.players[1], f.players[5]
	check(e1 and e5 and e1.talk == nil and e5.talk == nil and e1.tv == nil and f.players[2] == nil and f.players[6] == nil and f.players[4] == nil and f.n == 0,
		"real players in the feed (no test_voice, no talking): P1 (10 m) and P5 (14 m); P2 (38 m), P6, P4 out of earshot - absent")
	check(e1.gain > e5.gain and e5.gain > 0.5 and math.abs(e5.az) < 1 and math.abs(math.abs(e1.az) - 180) < 1 and e1.muffle == 0,
		string.format("... the nearer one louder (P1 %.2f, P5 %.2f); P5 ahead (az %.1f), P1 behind (az %.1f), clear", e1.gain, e5.gain, e5.az, e1.az))
	P2.PC.setVoiceMode("y"); run(8)
	local e2 = feed(M).players[2]
	check(e2 and e2.gain > 0 and e2.muffle == 0, "P2 (38 m) switches to Yell: heard (within 40 m: clear)")
	P1.PC.setVoiceMode("g"); run(8)
	check(feed(M).players[1] == nil, "a player in Global: not in the feed (their voice is heard by no one)")
	P1.PC.setVoiceMode("s"); run(8)
	M.PC.c.muted[5] = "P5"; run(8)
	check(feed(M).players[5] == nil and feed(M).players[1] ~= nil, "a player I muted: not in the feed")
	M.PC.c.muted[5] = nil; run(8)
	HOST.reg["proxchat.channel.5"] = "dead"; run(8)
	check(feed(M).players[5] == nil, "a dead player: not heard by the living (the dead talk to their channel)")
	HOST.reg["proxchat.channel.3"] = "dead"; run(8)
	local d5, l1 = feed(M).players[5], feed(M).players[1]
	check(d5 and math.abs(d5.gain - M.PC.cfg.voiceDeadGain) < 0.001 and M.PC.cfg.voiceDeadGain == 0.85 and d5.az == 0 and d5.muffle == 0,
		"... heard by the dead of the same channel: clear at 85 % (a ghost radio)")
	check(l1 and l1.gain > 0 and math.abs(math.abs(l1.az) - 180) < 1, "... and a dead listener hears the living from where its camera is (P1 behind)")
	HOST.reg["proxchat.channel.5"] = "dead blue"; run(8)
	check(feed(M).players[5] == nil, "... not by the dead of another channel")
	HOST.reg["proxchat.channel.3"] = nil; HOST.reg["proxchat.channel.5"] = nil; run(8)
	HOST.reg["proxchat.lobby"] = true; run(8)
	f = feed(M)
	local lobbyOk = f.np == 7
	for _, e in pairs(f.players) do if not (e.gain == 1 and e.az == 0 and e.el == 0 and e.muffle == 0) then lobbyOk = false end end
	check(lobbyOk, "the lobby: every other player, full and clear (" .. f.np .. ")")
	HOST.reg["proxchat.lobby"] = false; run(8)
	P2.PC.setVoiceMode("s"); run(8)
	-- a player leaves: their voice mode goes
	W.removed = {7}; HOST.server.tick(0); W.removed = {}
	check(vmodes()[7] == nil and vmodes()[6] == "s", "a player who leaves: their voice mode is gone from shared")
	-- typed Speak / Yell: sent only within reach + slack (P2 talks at x = 200; listeners along z)
	W.pos[2], W.pos[3], W.pos[1], W.pos[4] = Vec(200, 0, 0), Vec(200, 0, -5), Vec(200, 0, 30), Vec(200, 0, 50)
	W.pos[5], W.pos[6], W.pos[7] = Vec(200, 0, 70), Vec(200, 0, 90), Vec(0, 0, 0)
	run(60 * 14)                                                          -- (old bubbles fade)
	W.clog = {}
	waitRate(); say(P2, "/s can anyone far hear this")
	local sto = W.sentTo("can anyone far hear this")
	check(sto[2] and sto[3] and sto[1] and sto[4] and not sto[5] and not sto[6] and not sto[7] and not W.inShared("can anyone far hear this"),
		"Speak: sent to P3 (5 m), P1 (30 m), P4 (50 m: within 35 + 20) and the speaker; not P5 (70 m), P6 (90 m); not in shared")
	local b4 = P4.PC.c.bubbles[2]
	local n5 = #hist(P5)
	check(b4 and b4.hidden and not hasLine(P4, "s", "can anyone far hear this") and #hist(P5) == n5, "... P4 (50 m) keeps it hidden; P5 has nothing at all")
	W.pos[4] = Vec(200, 0, 20); step(); step()
	check(hasLine(P4, "s", "can anyone far hear this"), "... P4 walks into range while its bubble is up: the words show")
	local k = "proxchat.said." .. (HOST.reg["proxchat.said.last"] % 16) .. "."
	check(HOST.reg[k .. "text"] == "can anyone far hear this" and HOST.reg[k .. "mode"] == "speak" and HOST.reg[k .. "player"] == 2
		and HOST.reg[k .. "radius"] == 35 and HOST.reg[k .. "wordsRadius"] == 25 and HOST.reg[k .. "channel"] == "",
		"... and other mods still get the proxchat.said event as before")
	W.pos[4] = Vec(200, 0, 50)
	W.clog = {}
	waitRate(); say(P2, "/y can the far ones hear a yell")
	sto = W.sentTo("can the far ones hear a yell")
	check(sto[5] == "pc_near" and sto[4] and not sto[6] and not sto[7] and not W.inShared("can the far ones hear a yell") and HOST.reg["proxchat.said." .. (HOST.reg["proxchat.said.last"] % 16) .. ".mode"] == "yell",
		"Yell: sent to P5 (70 m: within 55 + 25), not P6 (90 m); not in shared; the event says yell")
	W.clog = {}
	waitRate(); say(P2, "/g everyone everywhere")
	local allG = true
	for _, m in ipairs(MACHINES) do if m.me ~= 7 and not hasLine(m, "g", "everyone everywhere") then allG = false end end
	check(allG and W.inShared("everyone everywhere") and next(W.sentTo("everyone everywhere")) == nil, "Global: unchanged - in shared, every player has it, no ClientCall")
	W.clog = nil
	-- a new session (a level start): no room, every voice mode sent again
	HOST.server.init(); run(3)                                         -- (a client's ServerCall("server.init"): nothing happens)
	check(HOST.shared.pcVoiceRoom ~= nil, "TRUST: server.init runs once - a call to it mid-session resets nothing (the room stays)")
	HOST.PC.s = nil; HOST.server.init(); run(70)                       -- (a real level start: a new Lua state)
	check(HOST.shared.pcVoiceRoom == nil and feed(M).room == "" and vmodes()[3] == "s" and vmodes()[1] == "s", "a new session: no room until a helper makes one; every player's voice mode sent again")
	M.files = nil
	steps(2)
end)()

-- ================================================================== Koetama's version, the voice server's region and state
;(function()
	local FEED = "savegame.mod.pcvx.f"
	local IO = "MOD/../pcvx_"
	local M = P2
	for _, m in ipairs(MACHINES) do if m.PC.c.typing then press(m, "esc"); step() end end
	local ping
	local function helperStep()                                           -- (Koetama 0.4.0: it removed pcvx_v5 / pcvx_v6)
		M.files[IO .. "on"] = true
		M.files[IO .. "v5"], M.files[IO .. "v6"] = nil, nil
		local p = M.reg[FEED] and W.feed(M).ping
		if p and p ~= ping then
			if ping then M.files[IO .. "p" .. (ping % 1000)] = nil end
			ping = p
			M.files[IO .. "p" .. (p % 1000)] = true
		end
	end
	local function run(k) for _ = 1, k do helperStep(); step() end end
	local function sendObj(obj)
		local vo = M.PC.c.voice
		M.files[IO .. "t" .. ((vo and vo.ack or 0) + 1) .. ".xml"] = W.msg(obj)
	end
	local function region() return (W.feed(M) or {}).region end
	-- an old Koetama (before 0.4.0): its "on" file and pcvx_v5 (it can't read protocol 2: it would never answer)
	M.files = {}
	M.PC.c.voice = nil
	M.files[IO .. "on"] = true; M.files[IO .. "v5"] = true
	steps(130)
	local VO = M.PC.c.voice
	check(VO and VO.h.outdated and not VO.h.alive and lastLine(M).text == "Your Koetama is too outdated. Please update it from the app.",
		"Koetama running with pcvx_v5 (before 0.4.0): too outdated - said once in the chat, not connected")
	press(M, "return"); M.PC.setPage("voice"); step()
	check(drawn(M, "^Your Koetama is too outdated%. Please update it from the app%.$") ~= nil and drawn(M, "Koetama is required", true) == nil
		and M.PC.c.voice.h.outdated, "... the Voice page says just that (not 'Koetama is required')")
	M.PC.setPage("translate"); step()
	check(drawn(M, "^Your Koetama is too outdated%. Please update it from the app%.$") ~= nil and drawn(M, "Koetama is required", true) == nil
		and drawn(M, "^Translation 1:$") == nil, "... and so does the Translate page (no language pickers: Koetama's window has them)")
	press(M, "esc"); step()
	-- updated: the old files gone
	run(180)
	check(VO.h.alive and not VO.h.outdated, "updated (Koetama 0.4.0 deleted pcvx_v5): connected")
	-- the room, and where it lives: the host picks (Settings, "Voice server"), every player's feed says it
	local ROOM, KEY = string.rep("c", 32), string.rep("d", 64)
	if not HOST.shared.pcVoiceRoom then P1.PC.voiceRoomOffer(ROOM, KEY) end   -- (the host's own: its registry)
	run(10)
	check(region() == "", "a room, no region chosen: Auto (the feed's region is empty)")
	say(P1, "/settings"); steps(2)
	check(drawn(P1, "^Voice server %(host%)$") ~= nil and drawn(P1, "^Auto   >$") ~= nil, "the host's Settings: Voice server, Auto")
	check(drawn(M, "^Voice server %(host%)$") == nil, "... a guest has no such row")
	P1.PC.stepVoiceRegion(1); steps(2); run(6)
	check(HOST.shared.pcVoiceRegion == "wnam" and P1.reg["savegame.mod.pcvxregion"] == "wnam" and region() == "wnam",
		"the host steps it: North America West - saved, and in every player's feed (" .. tostring(region()) .. ")")
	P1.PC.stepVoiceRegion(-2); steps(2); run(6)
	check(HOST.shared.pcVoiceRegion == "me" and region() == "me", "back past Auto: it wraps (Middle East)")
	P2.reg["savegame.mod.pcvxregion"] = "weur"; P2.PC.stepVoiceRegion(1); steps(2)
	check(HOST.shared.pcVoiceRegion == "me", "a guest can't change it")
	P1.reg["savegame.mod.pcvxregion"] = "mars"; steps(2); run(6)
	check(HOST.shared.pcVoiceRegion == "" and region() == "", "an unknown region: Auto")
	press(P1, "esc"); step()
	-- the voice server's state, from Koetama's voice objects
	run(70)
	check(VO.net == "connecting" and M.PC.hearsRealVoices(), "a room, no voice state yet: connecting")
	sendObj({type = "voice", state = "connecting"}); run(3)
	check(VO.net == "connecting" and VO.vstate == "connecting", "voice connecting: connecting")
	sendObj({type = "voice", state = "connected"}); run(3)
	check(VO.net == "connected", "voice connected: connected")
	sendObj({type = "voice", state = "sideways"}); run(3)
	check(VO.net == "connected" and VO.vstate == "connected", "... a state that is not one: ignored (acked)")
	press(M, "return"); M.PC.setPage("voice"); helperStep(); step()
	check(drawn(M, "^Koetama is connected%.   Voice server: connected %(Auto%)$") ~= nil, "the Voice page: Voice server: connected (Auto)")
	press(M, "esc"); step()
	sendObj({type = "voice", state = "unreachable"}); run(3)
	check(VO.net == "unreachable" and not M.PC.hearsRealVoices() and lastLine(M).text:find("^Koetama can't reach the voice server") ~= nil,
		"voice unreachable: said in the chat; spoken lines are babbled again (no real voice arrives)")
	press(M, "return"); M.PC.setPage("voice"); helperStep(); step()
	check(drawn(M, "Voice server: can't be reached", true) ~= nil, "... and the Voice page says so")
	press(M, "esc"); step()
	sendObj({type = "voice", state = "connected"}); run(3)
	check(VO.net == "connected" and lastLine(M).text == "Koetama reached the voice server again.", "reached again: said")
	sendObj({type = "voice", state = "off"}); run(3)
	check(VO.net == "connecting", "voice off (with a room): connecting")
	sendObj({type = "voice", state = "connected"}); run(3)
	M.files = nil
	steps(2)
end)()

-- ================================================================== translation (feed version 6): the Translate tab, requests, replies
;(function()
	local FEED = "savegame.mod.pcvx.f"
	local IO = "MOD/../pcvx_"
	local M = P2                                                          -- (P2 translates; the others talk)
	local helperOn, ping = false, nil
	local function helperStep()
		if not helperOn then return end
		M.files[IO .. "on"] = true
		local p = M.reg[FEED] and W.feed(M).ping
		if p and p ~= ping then
			if ping then M.files[IO .. "p" .. (ping % 1000)] = nil end
			ping = p
			M.files[IO .. "p" .. (p % 1000)] = true
		end
	end
	local function run(k) for _ = 1, k do helperStep(); step() end end
	local function sendObj(obj)                                           -- (the next object Koetama writes)
		local vo = M.PC.c.voice
		M.files[IO .. "t" .. ((vo and vo.ack or 0) + 1) .. ".xml"] = W.msg(obj)
	end
	local function status(list) sendObj({type = "translations_status", translations = list}) end
	local function reqs() return (W.feed(M) or {reqs = {}}).reqs end
	local function reqFor(text)
		for _, r in ipairs(reqs()) do if r.text == text then return r.id end end
		return nil
	end
	local function entry(m, text)
		for _, e in ipairs(hist(m)) do if e.text == text then return e end end
		return nil
	end
	-- what was drawn in which colour: UiText records the last UiColor
	M.colored = {}
	local uiColor0, uiText0 = M.UiColor, M.UiText
	M.UiColor = function(r, g, b, a) M.lastColor = {r, g, b, a} end
	M.UiText = function(s) M.texts[#M.texts + 1] = s; M.colored[#M.colored + 1] = {s, M.lastColor} end
	local function sameCol(col, ref) return col ~= nil and math.abs(col[1] - ref[1]) < 1e-6 and math.abs(col[2] - ref[2]) < 1e-6 and math.abs(col[3] - ref[3]) < 1e-6 end
	local function drawnIn(text, ref)
		for _, x in ipairs(M.colored) do if x[1] == text and sameCol(x[2], ref) then return true end end
		return false
	end
	local function frame() M.colored = {}; helperStep(); step() end
	for _, m in ipairs(MACHINES) do if m.PC.c.typing then press(m, "esc"); step() end end
	W.pos[1], W.pos[2], W.pos[3], W.pos[4], W.pos[5] = Vec(0, 0, 0), Vec(4, 0, 0), Vec(30, 0, 0), Vec(60, 0, 0), Vec(14, 0, 0)
	M.files = {}
	M.PC.c.voice = nil
	M.PC.c.reach = nil                                                    -- (the server started over above: its clock too,
	for _, m in ipairs(MACHINES) do m.PC.c.seen = 0 end                   --  and its message numbers - in the game a new
	                                                                      --  level starts every client over as well)
	run(10)
	local PC = M.PC
	-- ---- the tab without Koetama: the notice and its link (what into: Koetama's own setting, no pickers here)
	check(PC.trSetLang == nil and PC.setTrLang == nil and PC.trRules == nil and PC.TR_LANGS == nil and PC.trName("ja") == "日本語"
		and PC.trName("xx") == "xx", "no translation rules in the mod any more; a code's name: its own (日本語), else the code")
	M.reg["savegame.mod.pcvxtr1"], M.reg["savegame.mod.pcvxtr2"] = "ja>en", "ko>en"   -- (saved by the old Translate tab)
	M.PC.c.voice = nil; PC.voice()
	check(M.reg["savegame.mod.pcvxtr1"] == nil and M.reg["savegame.mod.pcvxtr2"] == nil, "the old tab's saved rules are cleared")
	press(M, "return")
	frame()
	check(drawn(M, "^Translate$") ~= nil and drawn(M, "^Voice$") ~= nil and not PC.voiceHelperAlive(), "the chat window: a Translate button next to Voice (grey: no Koetama)")
	M.hover = {140, 40, 1}; M.keys.lmb = true; frame(); M.hover = nil; frame()
	check(PC.page() == "translate" and drawn(M, "^Koetama is required for translation$") ~= nil
		and drawn(M, "^https://github%.com/AgeOfAlgorithms/koetama$") ~= nil and drawn(M, "^Translation 1:$") == nil
		and drawn(M, "^Translate$") ~= nil, "a click: the Translate page - Koetama is required (with its link), no pickers")
	press(M, "esc"); step()
	waitRate(); say(P1, "/s nobody translates this"); run(5)
	check(#PC.voice().tr.reqs == 0 and entry(M, "nobody translates this") and not entry(M, "nobody translates this").trId, "no Koetama: no line is sent to translate")
	-- ---- Koetama runs: its setting, shown
	helperOn = true
	run(150)
	check(PC.voiceHelperAlive() and W.feed(M).type == "feed" and W.feed(M).raw.translations == nil and W.feed(M).raw.to_translate == nil
		and W.feed(M).raw.translate == nil, "Koetama connected: no translations, nothing to translate in the feed (translate left out: true)")
	press(M, "return"); PC.setPage("translate"); frame()
	check(PC.voice().tr.into == nil and drawn(M, "^Koetama is connected%. ") ~= nil and drawn(M, "Koetama is required", true) == nil
		and drawn(M, "^Waiting for Koetama to say what it translates chat into") ~= nil
		and drawn(M, PC.TR_HINT, true) ~= nil, "the Translate page: connected; into not said yet; the hint where to choose")
	-- into "": off
	sendObj({type = "translations_status", into = "", translations = {}}); run(3); frame()
	check(PC.voice().tr.into == "" and drawn(M, PC.TR_OFF, true) ~= nil and drawn(M, "Translation is off: choose a language in Koetama's window", true) ~= nil
		and drawn(M, PC.TR_HINT, true) == nil, "into \"\": 'Translation is off: choose a language in Koetama's window'")
	press(M, "esc"); step()
	waitRate(); say(P1, "/s off in koetama"); run(5)
	check(#PC.voice().tr.reqs == 0 and not entry(M, "off in koetama").trId and W.feed(M).raw.to_translate == nil, "off: nothing to translate")
	-- into English, each pair in use with its state: a progress bar while downloading
	local nh = #hist(M)
	press(M, "return"); PC.setPage("translate")
	sendObj({type = "translations_status", into = "en", translations = {{from = "ja", to = "en", state = "downloading", progress = 0.42},
		{from = "ko", to = "en", state = "ready"}}}); run(3); frame()
	check(PC.voice().tr.into == "en" and drawn(M, "^Koetama translates chat into English$") ~= nil and drawn(M, PC.TR_HINT, true) ~= nil
		and drawn(M, "Choose the language in Koetama's window (Translate chat into)", true) ~= nil and drawn(M, PC.TR_OFF, true) == nil,
		"into en: 'Koetama translates chat into English', and where to change it")
	check(drawn(M, "^日本語 → English: downloading the models 42%%$") ~= nil and drawn(M, "^한국어 → English: ready$") ~= nil and #hist(M) == nh
		and PC.voice().tr.status["ja>en"].pct == 42, "translations_status: 'downloading the models 42%' (progress 0.42; with a bar) and 'ready' - never a chat line")
	sendObj({type = "translations_status", into = "en", translations = {{from = "ja", to = "en", state = "loading"}}}); run(3); frame()
	check(drawn(M, "^日本語 → English: loading the models%.%.%.$") ~= nil and drawn(M, "^한국어 → English", false) == nil,
		"... loading (the list is the pairs in use: Korean's gone)")
	sendObj({type = "translations_status", into = "en", translations = {{from = "ja", to = "en", state = "unavailable"}}}); run(3); frame()
	check(drawn(M, "^日本語 → English: no translation model for this pair$") ~= nil, "... unavailable")
	sendObj({type = "translations_status", into = "en", translations = {{from = "ja", to = "en", state = "error"}}}); run(3); frame()
	check(drawn(M, "^日本語 → English: error") ~= nil, "... error")
	sendObj({type = "translations_status", into = "ja", translations = {{from = "en", to = "ja", state = "ready"}}}); run(3); frame()
	check(drawn(M, "^Koetama translates chat into 日本語$") ~= nil and drawn(M, "^English → 日本語: ready$") ~= nil, "into ja: '... into 日本語', its own name")
	sendObj({type = "translations_status", into = "en", translations = {{from = "ja", to = "en", state = "downloading", progress = 7}, {from = "ko", state = "error"},
		"junk", {from = "ko", to = "en", state = 5}}}); run(3)
	check(PC.voice().tr.status["ja>en"].pct == 100 and PC.voice().tr.status["ko>en"] == nil, "... progress past 1: 100 %; items that are not one are skipped")
	sendObj({type = "translations_status", into = 5, translations = "ja>en=error"}); run(3)
	check(PC.voice().tr.status["ja>en"].state == "downloading" and PC.voice().tr.into == "en", "... translations that are not a list, an into that is not a string: ignored")
	sendObj({type = "translations_status", into = "<font>", translations = {{from = "ja", to = "en", state = "ready"}}}); run(3)
	check(PC.voice().tr.into == "en" and PC.voice().tr.status["ja>en"].state == "ready", "... an into that is no language code: ignored (the list still read)")
	-- a controller: the header steps to Translate (nothing to pick on it)
	press(M, "esc"); step()
	PC.setNav(true); frame()
	M.keys.menu_left = true; frame(); frame()
	check(PC.page() == "translate" and PC.c.navN == 1, "controller: left on the header from Voice - the Translate page (only the header: " .. tostring(PC.c.navN) .. ")")
	M.keys.menu_cancel = true; frame()
	check(not PC.c.nav, "B closes it")
	run(30)
	-- ---- which lines are asked for
	run(60 * 14)                                                          -- (old bubbles fade)
	waitRate(); say(P1, "/s konnichiwa"); run(3)
	local id1 = reqFor("konnichiwa")
	local e1 = entry(M, "konnichiwa")
	check(id1 and id1 > 0 and e1 and e1.trId == id1 and #reqs() == 1, "another player's typed line, heard in full: in the feed's to_translate as {id, text} (" .. tostring(W.feed(M).json) .. ")")
	waitRate(); say(M, "/s my own words"); run(3)
	check(reqFor("my own words") == nil and #reqs() == 1, "your own line: not asked")
	waitRate(); say(P1, "/w psst secret"); run(3)
	check(reqFor("psst secret") ~= nil, "a whisper heard: asked")
	W.pos[5] = Vec(60, 0, 0)
	waitRate(); say(P5, "/g hola a todos"); run(3)
	check(reqFor("hola a todos") ~= nil, "a Global line from 60 m away: asked")
	-- a typed line from the buffer (garbled): asked too (the whole line); its translation garbled as much as the line
	-- (the same share of its letters), in the bubble and the history; walking into range: both in full, not asked again
	do
	W.pos[2] = Vec(30, 0, 0)
	waitRate(); say(P1, "/s from far away"); run(3)
	local bf = M.PC.c.bubbles[1]
	local idf = reqFor("from far away")
	local ef = bf and bf.entry
	check(bf and bf.level == "mumble" and idf ~= nil and ef and ef.far and ef.trId == idf and #PC.voice().tr.reqs == 4,
		"a typed line heard garbled from the buffer: asked, the whole line (not its boxes)")
	sendObj({type = "translation", id = idf, text = "desde muy lejos aqui"}); run(3)
	local BOXG = PC.GARBLE[1]
	local function nLetters(s) local n = 0; for ch in s:gmatch(PC.UTF8_CHAR) do if ch ~= BOXG and not ch:find("%s") then n = n + 1 end end; return n end
	local th = PC.trHist(ef)
	local share = PC.trShare(bf, PC.bufferF(1, bf))
	local tb = PC.trShown(bf.tr, share, bf.seed or bf.id or 0, 0)
	check(ef.tr == "desde muy lejos aqui" and th ~= ef.tr and th:find(BOXG, 1, true) and nLetters(th) > 0 and #th > 0
		and tb:find(BOXG, 1, true) and share > 0 and share < PC.cfg.garbleMax,
		string.format("... its translation is garbled as much (%.2f of the letters): history '%s', bubble '%s'", share or -1, tostring(th), tostring(tb)))
	-- (the same share of letters shows: over a long text the revealed share is close to it)
	local long = ("abcdefghij "):rep(40)
	local g = PC.trShown(long, 0.4, 7, 0)
	local shown = nLetters(g) / 400
	check(math.abs(shown - 0.4) < 0.08 and PC.trShown("abc", nil, 7) == "abc" and PC.trShare({level = "full"}, 0.3) == nil
		and math.abs(PC.trShare({level = "mumble", fixed = true, fracs = {1, 1, 0, 0.2}}) - 0.55) < 1e-9,
		string.format("trShown reveals that share of the letters (0.4 -> %.2f); in full: unchanged; a spoken line: the mean of its letters'", shown))
	W.pos[2] = Vec(4, 0, 0); run(3)
	check(bf.level == "full" and reqFor("from far away") == nil and ef.trId == idf and PC.trHist(ef) == "desde muy lejos aqui",
		"... walked into range while it is up: the line and its translation in full (not asked again)")
	ef.tr = nil                                                       -- (its two lines out of the way: the history checks below
	end                                                               --  need konnichiwa's line on screen)
	-- spoken: live words never, the finished line (with word times: as heard) yes
	M.client.pc_live(1, 77, "live words here", "s"); run(3)
	check(reqFor("live words here") == nil, "live words: never asked")
	M.client.pc_near(900001, 1, "P1", "s", "spoken and done", nil, true); run(3)
	check(reqFor("spoken and done") ~= nil and entry(M, "spoken and done").voice, "a finished spoken line: asked")
	-- (with word times: P2 was 30 m away a second ago - in the buffer - and is 4 m away now)
	local T0 = PC.serverNow() - 1
	M.client.pc_near(900002, 1, "P1", "s", "timed words", nil, true, "00000032", T0, 78); run(3)
	local et = hist(M)[#hist(M)]
	check(et.voice and et.far and et.text:find(PC.GARBLE[1], 1, true) and et.trId and reqFor("timed words") ~= nil and et.trF and et.trF < 1,
		"a spoken line with word times heard partly from the buffer while it was said (garbled, '" .. et.text .. "'): asked; its translation will show "
		.. string.format("%.2f of its letters", et.trF or -1))
	run(90)
	T0 = PC.serverNow() - 1
	M.client.pc_near(900003, 1, "P1", "s", "clear words", nil, true, "00000032", T0, 79); run(3)
	check(reqFor("clear words") ~= nil and not entry(M, "clear words").far, "... the same, near the whole time (heard clear): asked")
	-- the dead's channel
	HOST.reg["proxchat.channel.1"] = "dead"; HOST.reg["proxchat.channel.2"] = "dead"; run(3)
	waitRate(); say(P1, "boo from beyond"); run(3)
	check(entry(M, "boo from beyond") and entry(M, "boo from beyond").ch == "d" and reqFor("boo from beyond") ~= nil, "a dead player's line to the dead: asked")
	HOST.reg["proxchat.channel.1"] = nil; HOST.reg["proxchat.channel.2"] = nil; run(3)
	-- ---- replies (message x): under the original, in the translation's colour, in the history and the bubble
	press(M, "return"); frame()
	sendObj({type = "translation", id = id1, text = "hello"}); run(3); frame()
	local b1 = M.PC.c.prevBubbles[1] and M.PC.c.prevBubbles[1].full == "konnichiwa" and M.PC.c.prevBubbles[1] or nil
	check(e1.tr == "hello" and reqFor("konnichiwa") == nil and not entry(M, "hello"), "a translation object: the translation goes onto its line; the request leaves the feed; it is not a chat line")
	local oi, ti = nil, nil
	for i, x in ipairs(M.colored) do
		if x[1] == "konnichiwa" and not oi and not sameCol(x[2], PC.TR_BUBBLE_COLOR) and sameCol(x[2], {1, 1, 1}) then oi = i end
		if x[1] == "hello" and sameCol(x[2], PC.TR_COLOR) then ti = i end
	end
	check(oi and ti and ti > oi and drawnIn("hello", PC.TR_COLOR) and not sameCol(PC.TR_COLOR, PC.modeInfo("g")[5]),
		"the history: the translation drawn under its line, in its own colour (pink, not a mode's)")
	local w = 600
	local h0 = PC.drawLine({ch = "s", p = 1, name = "P1", text = "konnichiwa"}, w, 24, 1, true)
	local h1 = PC.drawLine(e1, w, 24, 1, true)
	check(h1 > h0 + 20, "... the line is that much taller (the history's scrolling counts it): " .. h0 .. " -> " .. h1)
	-- its bubble (the newest line of P1 is the spoken one: konnichiwa's bubble is gone or older) - a fresh line to see it
	run(60 * 14)
	waitRate(); say(P1, "/s arigatou"); run(3)
	local id2 = reqFor("arigatou")
	sendObj({type = "translation", id = id2, text = "thank you"}); run(3); frame()
	local b2 = M.PC.c.bubbles[1]
	check(b2 and b2.full == "arigatou" and b2.tr == "thank you" and entry(M, "arigatou").tr == "thank you", "a reply: on the history line and its bubble")
	check(drawnIn("thank you", PC.TR_BUBBLE_COLOR) and drawnIn("thank you", PC.TR_COLOR), "... drawn in the bubble (dark rose on white) and in the history (pink)")
	local Lb
	for _, L in ipairs(M.PC.drawOrder or {}) do if L.p == 1 then Lb = L end end
	local Ln = PC.bubbleLayout(1, "arigatou", false, 1)
	check(Lb and Lb.tr and Ln and Lb.h > Ln.h + 20, "... the bubble grows to hold it (" .. (Ln and Ln.h or 0) .. " -> " .. (Lb and Lb.h or 0) .. ")")
	check(PC.bubbleLife(b2) >= (b2.trT - b2.t) + PC.cfg.lifeMin, "... and stays up long enough to read it")
	press(M, "esc"); frame()
	check(drawnIn("thank you", PC.TR_COLOR), "the window closed: the feed shows it under the line too")
	-- an empty reply: nothing to show; a reply for no request: ignored
	local idw = reqFor("psst secret")
	sendObj({type = "translation", id = idw, text = ""}); run(3)
	check(reqFor("psst secret") == nil and entry(M, "psst secret").tr == nil, "an empty reply (nothing to translate): the request goes, nothing is shown")
	sendObj({type = "translation", id = 99999, text = "stray"}); run(3)
	sendObj({type = "translation", text = "no id"}); run(3)
	check(not entry(M, "stray") and not entry(M, "no id"), "a reply to no request, or without an id: ignored")
	-- limits: at most 16 waiting (the oldest go), each at most 400 bytes (cut between letters)
	local n0 = PC.voice().tr.nextId
	for i = 1, 20 do PC.receive({id = 800000 + i, p = 3 + i % 6, name = "P", ch = "g", text = "line " .. i}) end   -- (6 speakers)
	run(2)
	local rs = reqs()
	check(#rs == 16 and rs[1].text == "line 5" and rs[16].text == "line 20" and rs[16].id == n0 + 20, "at most 16 lines wait in the feed: the oldest are dropped first")
	local long = "a" .. ("é"):rep(250)
	PC.receive({id = 800100, p = 3, name = "P3", ch = "g", text = long}); run(2)
	local last = reqs()[#reqs()]
	check(last and #last.text == 399 and last.text == long:sub(1, 399), "a line of 501 bytes: cut to 399 (the next letter would pass 400 bytes)")
	-- no reply within 10 s: dropped (a late reply then is ignored)
	local idl = reqFor("line 20")
	run(math.ceil((PC.cfg.trWait + 0.5) * 60))
	check(#reqs() == 0, "no reply for " .. PC.cfg.trWait .. " s: the requests are dropped")
	sendObj({type = "translation", id = idl, text = "late"}); run(3)
	check(entry(M, "line 20").tr == nil, "... a reply after that is ignored")
	-- turned off in Koetama's window: the lines waiting are dropped, nothing more is asked
	waitRate(); say(P1, "/s waiting when it goes off"); run(3)
	check(reqFor("waiting when it goes off") ~= nil, "(a line waiting)")
	sendObj({type = "translations_status", into = "", translations = {}}); run(3)
	waitRate(); say(P1, "/s nothing to translate now"); run(3)
	check(W.feed(M).rules == "" and #reqs() == 0 and W.feed(M).raw.to_translate == nil and not entry(M, "nothing to translate now").trId,
		"into \"\" (off in Koetama's window): the waiting line dropped, nothing asked, no to_translate")
	-- Koetama goes: requests, states and its setting forgotten
	sendObj({type = "translations_status", into = "en", translations = {{from = "ja", to = "en", state = "ready"}}}); run(3)
	waitRate(); say(P1, "/s sayonara"); run(3)
	check(reqFor("sayonara") ~= nil, "into en again: asked")
	helperOn = false
	M.files = {[IO .. "p" .. (ping % 1000)] = true}
	steps(math.ceil((PC.cfg.voicePing + PC.cfg.voicePongWait + 1) * 60))
	check(not PC.voiceHelperAlive() and #PC.voice().tr.reqs == 0 and next(PC.voice().tr.status) == nil and PC.voice().tr.into == nil,
		"Koetama gone: the waiting lines, the pairs' state and what it translates into are forgotten")
	M.UiColor, M.UiText = uiColor0, uiText0
	M.files = nil
	steps(2)
end)()

-- ================================================================== protocol 2: JSON and hex
;(function()
	local PC = P1.PC
	local E, D, A, NULL = PC.jsonEncode, PC.jsonDecode, PC.jsonArray, PC.JSON_NULL
	check(E({type = "x", a = 1, b = -2.5, c = true, d = false, e = NULL, f = A({}), g = {1, 2, 3}, h = {}, i = {{k = "v"}}})
		== '{"type":"x","a":1,"b":-2.5,"c":true,"d":false,"e":null,"f":[],"g":[1,2,3],"h":{},"i":[{"k":"v"}]}',
		"encode: an object (type first, then sorted keys), numbers, booleans, null, [] (a marked empty array), {} and nesting")
	check(E(3.0) == "3" and E(-7) == "-7" and E(0.1) == "0.1" and E(-0.25) == "-0.25" and E(123456789012) == "123456789012"
		and E(1 / 0) == "null" and E(-1 / 0) == "null" and E(0 / 0) == "null" and E(1e-7) == "1e-07" and E(2.5e20) == "2.5e+20",
		"encode numbers: whole ones without .0, not finite: null")
	check(E('a"b\\c\n\r\t\b\f' .. "\1\31/") == '"a\\"b\\\\c\\n\\r\\t\\b\\f\\u0001\\u001f/"', "encode: quotes, backslashes and control characters escaped")
	check(E("日本語 é 😀") == '"日本語 é 😀"', "encode: UTF-8 stays as it is")
	check(E("\255a\192") == '"\239\191\189a\239\191\189"' and E("x\228\184") == '"x\239\191\189\239\191\189"'
		and E("\237\160\128") == '"\239\191\189\239\191\189\239\191\189"' and E("\192\128") == '"\239\191\189\239\191\189"'
		and E("\128") == '"\239\191\189"' and E("é\169") == '"é\239\191\189"',
		"encode: bytes that are not UTF-8 (stray, cut short, a surrogate, overlong, a stray continuation) become U+FFFD")
	check(E({1, nil, 3}) == "[1]" and E({[2] = 5}) == "{}" and E({[1] = "a", x = 2}) == '["a"]', "encode: an array is t[1]..t[#t]; non-string keys of an object are left out")
	-- decode
	local v = D('{"a":[1,2,{"b":null}],"c":"x\\u00e9\\u65e5\\ud83d\\ude00","d":-1.5e2,"e":true,"f":false,"g":0.25,"h":{}}')
	check(v and v.a[1] == 1 and v.a[3].b == NULL and v.c == "xé日😀" and v.d == -150 and v.e == true and v.f == false and v.g == 0.25
		and PC.jsonIsArray(v.a) and not PC.jsonIsArray(v.h) and next(v.h) == nil,
		"decode: objects, arrays (marked), null, \\u escapes and a surrogate pair to UTF-8, numbers, booleans")
	local w = D(' \r\n{ "a" : [ ] ,\t"b" : [ 1 , "two" , null ] } ')
	check(w and PC.jsonIsArray(w.a) and #w.a == 0 and w.b[2] == "two" and w.b[3] == NULL and #w.b == 3, "decode: whitespace; an empty array; null keeps its place in an array")
	check(D('"\\"\\\\\\/\\b\\f\\n\\r\\t"') == '"\\/\b\f\n\r\t' and D('"\\ud800x"') == "\239\191\189x" and D('"\\udc00"') == "\239\191\189"
		and D('"\\u0041\\u00DF"') == "Aß" and D('"日本"') == "日本" and D("-0") == 0 and D("12") == 12 and D("1E2") == 100 and D("null") == NULL,
		"decode: every escape; a lone surrogate is U+FFFD; raw UTF-8; numbers at the top")
	local bad = {"", " ", "{", "}", "[1,2", "[1,]", "[,1]", '{"a":}', '{"a" 1}', '{"a":1,}', '{a:1}', "{1:2}", "tru", "nul", "falsey", "1 2",
		'"abc', '"a\nb"', '"\\x"', '"\\u12"', '"\\u12zz"', "-", "1.", ".5", "1e", "+1", "0x10", "NaN", "Infinity", '{"a":1}}', "[1]]", "'a'",
		string.rep("[", 100) .. string.rep("]", 100), "1e999"}
	local badOk, which = true, nil
	for _, b in ipairs(bad) do
		local ok, r = pcall(D, b)
		if not ok or r ~= nil then badOk, which = false, b end
	end
	check(badOk, "decode: malformed input returns nil, never raises (" .. #bad .. " cases" .. (which and ("; failed on " .. which) or "") .. ")")
	check(D(nil) == nil and D(5) == nil and D({}) == nil, "decode: not a string: nil")
	local full = '{"type":"speech","kind":"live","utt":4,"text":"hello \\"there\\" 日本","times":[0.1,0.55],"ago":1.02}'
	local cutOk = true
	for k = 0, #full - 1 do
		local ok, r = pcall(D, full:sub(1, k))
		if not ok or (r ~= nil and k < #full - 1) then cutOk = false end
	end
	check(cutOk and D(full).text == 'hello "there" 日本', "decode: a message cut short anywhere is nil (never raises)")
	math.randomseed(7)
	local chars = {"{", "}", "[", "]", ",", ":", '"', "\\", "u", "d", "8", "0", "1", "-", ".", "e", "t", "n", "a", " ", "\0", "\200", "\31"}
	local fuzzOk = true
	for _ = 1, 3000 do
		local t = {}
		for k = 1, math.random(1, 24) do t[k] = chars[math.random(#chars)] end
		if not pcall(D, table.concat(t)) then fuzzOk = false end
	end
	check(fuzzOk, "decode: 3000 random strings never raise")
	-- round trips
	local obj = {type = "feed", seq = 12, volume = 0.75, listen = "push_to_talk", talk_key = false, lang = "ja", live = true, me = 3,
		speakers = A({{id = 2, gain = 0.812, azimuth = -90.5, elevation = 3.2, muffle = 0.1}, {id = 2001, gain = 1, azimuth = 0, elevation = 0, muffle = 0, test_voice = 2, talking = true}}),
		to = A({}), room = string.rep("ab", 16), translations = {{from = "ja", to = "en"}},
		to_translate = {{id = 7, text = 'こんにちは "quoted" \\ back\nline\t☃ 😀'}}, n = NULL}
	local j1 = E(obj)
	local back = D(j1)
	check(back and E(back) == j1 and back.to_translate[1].text == obj.to_translate[1].text and back.speakers[1].azimuth == -90.5
		and back.speakers[2].talking == true and PC.jsonIsArray(back.to) and back.n == NULL, "round trip: encode -> decode -> encode is the same text, the values the same")
	local hx = PC.hexEncode(j1)
	check(hx:find("^[0-9a-f]+$") and #hx == 2 * #j1 and PC.hexDecode(hx) == j1 and D(PC.hexDecode(hx:upper())).seq == 12, "... and through hex (lower case out, either case in)")
	check(PC.hexEncode("\0\255Az") == "00ff417a" and PC.hexDecode("00FF417a") == "\0\255Az" and PC.hexDecode("") == ""
		and PC.hexDecode("abc") == nil and PC.hexDecode("zz") == nil and PC.hexDecode("0g") == nil and PC.hexDecode(nil) == nil,
		"hex: encode, decode (any case), odd length / not hex: nil")
end)()

-- ================================================================== protocol 2: hello, features, outdated, unknown objects, the immediate write
;(function()
	local FEED = "savegame.mod.pcvx.f"
	local IO = "MOD/../pcvx_"
	local M = P2
	local PC = M.PC
	for _, m in ipairs(MACHINES) do if m.PC.c.typing then press(m, "esc"); step() end end
	W.pos[1], W.pos[2], W.pos[3], W.pos[4], W.pos[5] = Vec(0, 0, 0), Vec(4, 0, 0), Vec(30, 0, 0), Vec(60, 0, 0), Vec(14, 0, 0)
	local ping, extra = nil, {}
	local function helperStep()
		M.files[IO .. "on"] = true
		for k, x in pairs(extra) do M.files[k] = x end
		local p = M.reg[FEED] and W.feed(M).ping
		if p and p ~= ping then
			if ping then M.files[IO .. "p" .. (ping % 1000)] = nil end
			ping = p
			M.files[IO .. "p" .. (p % 1000)] = true
		end
	end
	local function run(k) for _ = 1, k do helperStep(); step() end end
	local function sendObj(obj)
		local vo = PC.c.voice
		M.files[IO .. "t" .. ((vo and vo.ack or 0) + 1) .. ".xml"] = obj.j and obj or W.msg(obj)
	end
	-- outdated: "on" with pcvx_v6 (or v5) is a Koetama before 0.4.0
	M.files = {[IO .. "on"] = true, [IO .. "v6"] = true}
	PC.c.voice = nil
	steps(130)
	local VO = PC.c.voice
	check(VO and VO.h.outdated and not VO.h.on and not VO.h.alive and lastLine(M).text == PC.KOETAMA_OLD and not PC.trOn() and PC.trOld(),
		"pcvx_on with pcvx_v6 (a Koetama before 0.4.0): too outdated - never fed as connected")
	press(M, "return"); PC.setPage("voice"); step()
	check(drawn(M, "^Your Koetama is too outdated%. Please update it from the app%.$") ~= nil, "... the Voice page says so")
	press(M, "esc"); step()
	-- Koetama 0.4.0 (no old files) whose hello lacks "translate"
	M.files = {}
	extra = {}
	sendObj({type = "hello", app = "Koetama", version = "0.4.0", protocol = 2, features = {"speech", "voices", "rooms"}})
	run(150)
	check(VO.h.alive and not VO.h.outdated and VO.h.hello and VO.h.hello.features.speech and not VO.h.hello.features.translate and VO.ack == 1,
		"the old files gone: connected; its hello read (speech, voices, rooms - no translate)")
	sendObj({type = "translations_status", into = "en", translations = {}}); run(3)
	check(not PC.trOn() and PC.trOld() and W.feed(M).raw.to_translate == nil, "a hello without translate: no translation (though it says into en)")
	PC.receive({id = 810001, p = 3, name = "P3", ch = "g", text = "nobody translates me"}); run(2)
	check(#VO.tr.reqs == 0 and W.feed(M).raw.to_translate == nil, "... no line is queued")
	press(M, "return"); PC.setPage("translate"); step()
	check(drawn(M, "^Your Koetama is too outdated%. Please update it from the app%.$") ~= nil and drawn(M, "^Koetama is connected%. ") == nil
		and drawn(M, "Koetama is required", true) == nil and drawn(M, "^Koetama translates chat into") == nil, "... the Translate page says 'too outdated'")
	PC.setPage("voice"); step()
	check(drawn(M, "^Koetama is connected%.   Voice server: ") ~= nil, "... the Voice page: connected (voice works)")
	press(M, "esc"); step()
	-- unknown types and broken objects: acked, nothing happens
	local n0, ack0 = #hist(M), VO.ack
	sendObj({type = "dance", style = "waltz"}); run(2)
	sendObj({j = "not hex"}); run(2)
	sendObj(W.msgRaw('{"type":"speech","kind":"final","text":"broken"')); run(2)
	sendObj({type = "speech", kind = "shout", utt = 1, text = "an unknown kind"}); run(2)
	sendObj({type = "speech", kind = "final", utt = 2, text = 42}); run(2)
	check(VO.ack == ack0 + 5 and W.feed(M).ack == ack0 + 5 and #hist(M) == n0, "an unknown type, a j that is not hex, broken JSON, an unknown speech kind, text not a string: acked, nothing said")
	-- a new hello with translate: translation on
	sendObj({type = "hello", app = "Koetama", version = "0.4.1", protocol = 2, features = {"speech", "voices", "rooms", "translate", "telepathy"}}); run(3)
	check(PC.trOn() and not PC.trOld() and VO.h.hello.version == "0.4.1" and PC.trSend(VO), "a hello with translate (and a feature not known): translation on")
	-- the immediate write: a line queued for translation goes out in the same frame (idle: no room, 5 writes a second)
	HOST.PC.voiceServerInit(); run(70)                                    -- (no room: the slow feed, 5 writes a second)
	check(HOST.shared.pcVoiceRoom == nil and #VO.list == 0 and W.feed(M).raw.room == nil, "(no room, no voice dummies: the slow feed)")
	local s0 = W.feed(M).seq
	PC.receive({id = 810002, p = 3, name = "P3", ch = "g", text = "translate me now"})
	local f1 = W.feed(M)
	check(f1.seq == s0 + 1 and f1.reqs[1] and f1.reqs[#f1.reqs].text == "translate me now", "a line queued for translation: the feed is written at once (same frame)")
	PC.receive({id = 810003, p = 3, name = "P3", ch = "g", text = "and me too"})
	check(W.feed(M).seq == s0 + 1, "... a second one in the same frame: no second extra write")
	step()
	local f2 = W.feed(M)
	check(f2.seq == s0 + 2 and f2.reqs[#f2.reqs].text == "and me too", "... it goes out with the next frame's write")
	-- the "nothing left" feed: Koetama stops
	M.files = {[IO .. "p" .. (ping % 1000)] = true}
	steps(math.ceil((PC.cfg.voicePing + PC.cfg.voicePongWait + 1) * 60))
	local fo = W.feed(M)
	local so = fo.seq
	steps(30)
	check(not VO.h.alive and VO.h.hello == nil and fo.listen == "off" and fo.raw.room == nil and #fo.raw.speakers == 0 and fo.json:find('"speakers":[]', 1, true)
		and fo.raw.to_translate == nil and W.feed(M).seq == so and PC.voiceFeedOff(M.reg[FEED]),
		"Koetama gone: one last feed (listen off, no room, speakers []), then nothing; its hello forgotten")
	M.files = nil
	steps(2)
end)()

-- ================================================================== devices (devices.lua): proxchat.device / tx / effects / ranges, a walkie,
-- a megaphone, a PA - the feed's via, transmit and listener, bubbles over the devices
;(function()
	local FEED = "savegame.mod.pcvx.f"
	local IO = "MOD/../pcvx_"
	local PC1 = P1.PC
	local function near(a, b, eps) return a ~= nil and b ~= nil and math.abs(a - b) <= (eps or 0.02) end
	local function vnear(v, x, y, z) return v ~= nil and near(v[1], x) and near(v[2], y) and near(v[3], z) end
	-- ---- parsing (pure functions)
	local d = PC1.devParse("radio channel=Team1 at=player:3 range=2,10 signal=0.5")
	check(d and d.kind == "radio" and d.chan == "team1" and d.at.t == "player" and d.at.p == 3 and d.near == 2 and d.far == 10 and d.signal == 0.5,
		"device: 'radio channel=Team1 at=player:3 range=2,10 signal=0.5' (channel tidied to lower case)")
	d = PC1.devParse("loudspeaker at=body:812")
	check(d and d.kind == "loudspeaker" and d.chan == "megaphone" and d.at.t == "body" and d.at.h == 812 and d.far == nil,
		"device: a loudspeaker on a body; the channel defaults to megaphone, the range to the kind's")
	d = PC1.devParse("pa at=0,5,0;30,5,0;60,5.5,-2 reverb=0.8")
	check(d and d.kind == "pa" and d.chan == "pa" and d.at.t == "pos" and #d.at.pts == 3 and d.at.pts[3][2] == 5.5 and d.at.pts[3][3] == -2 and d.reverb == 0.8,
		"device: a PA with three speakers (x,y,z;x,y,z;...) and its reverb")
	local d2 = PC1.devParse("radio at=1,2,3")
	check(d2 and d2.chan == "private" and #d2.at.pts == 1 and PC1.devParse("megaphone at=1,2,3").kind == "loudspeaker" and PC1.devParse("walkie at=player:1").kind == "radio",
		"device: a walkie on a spot (channel private); 'megaphone' and 'walkie' are names for loudspeaker and radio")
	check(PC1.devParse("pa channel=x") == nil and PC1.devParse("tv at=1,2,3") == nil and PC1.devParse("radio at=1,2") == nil
		and PC1.devParse("radio at=player:x") == nil and PC1.devParse("") == nil and PC1.devParse(nil) == nil,
		"not a device: no at=, an unknown kind, two numbers, a player that is not a number, empty")
	local many = {}
	for i = 1, 20 do many[i] = i .. ",0,0" end
	check(#PC1.devParse("pa at=" .. table.concat(many, ";")).at.pts == 16, "a PA keeps 16 speakers at most (Koetama's limit)")
	local fx = PC1.fxParse("pitch=-3 reverb=0.7 wobble=0.4 echo=0.25,0.4 band=300,3000 static=off robot=60 nonsense=3 drive=7 hum=0")
	check(fx and fx.pitch == -3 and fx.reverb == 0.7 and fx.wobble == 0.4 and fx.echo[1] == 0.25 and fx.echo[2] == 0.4 and fx.band[1] == 300
		and fx.band[2] == 3000 and fx.static == false and fx.hum == false and fx.robot == 60 and fx.nonsense == nil and fx.drive == 1,
		"effects: 'pitch=-3 reverb=0.7 wobble=0.4 echo=0.25,0.4 band=300,3000 static=off robot=60 ...': each parsed, off = false, unknown skipped, 0..1 clamped")
	local js = PC1.jsonEncode(fx)
	check(js:find('"band":[300,3000]', 1, true) and js:find('"static":false', 1, true) and js:find('"echo":[0.25,0.4]', 1, true),
		"... as JSON: band and echo arrays, off as false (" .. js .. ")")
	check(PC1.fxParse("") == nil and PC1.fxParse("nonsense=1") == nil and PC1.fxParse("pitch=99").pitch == 12 and PC1.fxParse("echo=0.3").echo == 0.3
		and PC1.fxParse("band=3000,300") == nil, "effects: nothing valid -> nil; pitch clamped to 12; echo alone; a band upside down is skipped")
	local r = PC1.parseRanges("8,25,40")
	local r6 = PC1.parseRanges("5,15,30,10,90,50")
	local rk = PC1.parseRanges("private=12 megaphone=100, reach = 150")
	local ra = PC1.parseRanges("radio=7 loudspeaker=70 pa=30")
	check(r.w == 8 and r.s == 25 and r.y == 40 and r.pr == nil and r6.pr == 10 and r6.m == 90 and r6.pa == 50
		and rk.pr == 12 and rk.m == 100 and rk.reach == 150 and rk.w == nil and ra.pr == 7 and ra.m == 70 and ra.pa == 30
		and PC1.parseRanges("8,25") == nil and PC1.parseRanges("") == nil,
		"proxchat.ranges: the old three numbers, six (+ private, megaphone, pa), or key=value in any order (+ reach; radio / loudspeaker too)")
	-- ---- the chat's modes stay four: the devices are only the game's
	for _, m in ipairs(MACHINES) do if m.PC.c.typing then press(m, "esc"); step() end end
	check(#P1.PC.MODES == 4 and #P1.PC.TALK_MODES == 4, "the chat's modes stay Whisper, Speak, Yell, Global (line and voice)")
	say(P2, "/pr hello"); local l1 = lastLine(P2).text
	say(P2, "/m hello"); local l2 = lastLine(P2).text
	say(P2, "/pa hello"); local l3 = lastLine(P2).text
	check(l1 == "Unknown command /pr. Type /help." and l2 == "Unknown command /m. Type /help." and l3 == "Unknown command /pa. Type /help.",
		"no /pr, /m, /pa commands")

	-- ---- the world: P2 talks; the others around it (P1 10 m ahead, P3 50 m ahead, P5 50 m behind, P4 300 m away)
	HOST.reg["proxchat.walls"] = false
	W.boxes = nil
	W.pos[2], W.pos[1], W.pos[3], W.pos[5], W.pos[4] = Vec(500, 0, 0), Vec(500, 0, 10), Vec(500, 0, 50), Vec(500, 0, -50), Vec(500, 0, 300)
	W.pos[6], W.pos[7], W.pos[8] = Vec(-2000, 0, 0), Vec(-2000, 0, 40), Vec(-2000, 0, 80)
	W.facing = {[2] = Vec(0, 0, 1)}                                     -- (P2 looks toward +z: at P1 and P3)
	for _, m in ipairs(MACHINES) do
		m.GetPlayerEyeTransform = function(p) local f = W.pos[p]; return f and {pos = Vec(f[1], f[2] + 1.7, f[3]), fwd = (W.facing or {})[p] or Vec(0, 0, -1)} end
		m.TransformToParentVec = function(t, v) if t.fwd and v[1] == 0 and v[2] == 0 and v[3] == -1 then return t.fwd end return v end
		m.GetBodyTransform = function(h) local b = (W.bodies or {})[h]; if not b then error("no body") end return {pos = b} end
		m.IsHandleValid = function(h) return (W.bodies or {})[h] ~= nil end
		m.PC.setVoiceMode("s"); m.PC.setMode("s")
		m.PC.c.muted = {}
		m.sounds = {}
	end
	steps(60 * 14)                                                        -- (old bubbles fade)
	-- ---- no device: nothing goes anywhere
	HOST.reg["proxchat.tx.2"] = "private"; steps(3)
	W.clog = {}
	waitRate(); say(P2, "nobody has a walkie")
	local sto = W.sentTo("nobody has a walkie")
	check(sto[1] and sto[3] and sto[5] and not sto[4] and next(P4.PC.c.devB or {}) == nil and next(P3.PC.c.devB or {}) == nil,
		"proxchat.tx.2 on a channel with no device: only the usual Speak reach (P1, P3, P5: within 35 + 20 m); no device bubble, never in anyone's ear")
	local k = "proxchat.said." .. (HOST.reg["proxchat.said.last"] % 16) .. "."
	check(HOST.reg[k .. "tx"] == "" and HOST.reg[k .. "device"] == "" and HOST.reg[k .. "mode"] == "speak", "... its event: tx \"\", device \"\"")
	HOST.reg["proxchat.tx.2"] = nil

	-- ---- voices: P2 and P3 run Koetama, a voice room
	local pings = {}
	local function helperStep()
		for _, m in ipairs({P2, P3}) do
			m.files = m.files or {}
			m.files[IO .. "on"] = true
			local f = m.reg[FEED] and W.feed(m)
			local p = f and f.ping
			if p and p ~= pings[m.me] then
				if pings[m.me] then m.files[IO .. "p" .. (pings[m.me] % 1000)] = nil end
				pings[m.me] = p
				m.files[IO .. "p" .. (p % 1000)] = true
			end
		end
	end
	local function run(n) for _ = 1, n do helperStep(); step() end end
	HOST.server.pc_room(2, TOK(2), string.rep("0123456789abcdef", 2), string.rep("fedcba9876543210", 4))
	run(60 * 18)                                                          -- (a Koetama that went away is looked for again after 15 s)
	local function spk(m, id)
		local f = W.feed(m)
		for _, e in ipairs(f.raw.speakers or {}) do if e.id == id then return e, f end end
		return nil, f
	end
	local function txList(m)
		local t = {}
		for _, q in ipairs(W.feed(m).raw.transmit or {}) do t[#t + 1] = q end
		return table.concat(t, ",")
	end
	local function shownAt(m, key)
		for _, s in ipairs(m.PC.c.devShown or {}) do if s.key == key then return s end end
		return nil
	end
	check(P2.PC.c.voice.h.alive and P3.PC.c.voice.h.alive and W.feed(P3).room ~= "", "(P2 and P3 run Koetama; the session has a voice room)")
	HOST.reg["proxchat.tx.2"] = "private"; run(6)
	check(spk(P3, 2) == nil and W.feed(P2).raw.transmit == nil, "voice into a channel with no device: P3 (50 m) hears nothing, P2 transmits to nobody")

	-- ---- walkies (channel team): P2 and P3 carry one
	HOST.reg["proxchat.device.w2"] = "radio channel=team at=player:2"
	HOST.reg["proxchat.device.w3"] = "radio channel=team at=player:3"
	HOST.reg["proxchat.tx.2"] = "team"
	run(8)
	check(HOST.shared.pcDev and HOST.shared.pcDev.w2 and P3.PC.c.dw.devs.w3 and P3.PC.c.dw.devs.w3.chan == "team" and HOST.shared.pcTx[2] == "team",
		"devices and tx reach every game (shared.pcDev, pcTx)")
	local e, f3 = spk(P3, 2)
	local v = e and e.via and e.via[1]
	check(v and v.device == "radio" and vnear(v.position, 500, 1.3, 50) and v.range[1] == 1 and near(v.range[2], 9) and #e.via == 1 and e.gain == nil and e.azimuth == nil,
		"P3 (50 m) hears P2 from P3's own walkie (at P3's chest, range [1, 9]) - only through it (no gain, no direction); P2's walkie doesn't play P2")
	check(txList(P2) == "3" and P1.PC.jsonIsArray(W.feed(P2).raw.transmit), "P2's feed: transmit = [3] (a list: only who is near a walkie of the channel)")
	check(f3.raw.listener and vnear(f3.raw.listener.position, 500, 1.7, 50), "a position in via: the feed has the listener - at P3's head")
	P3.camOffset = Vec(0, 1.2, 4); run(6)                                -- (third person: the camera behind and above)
	f3 = W.feed(P3)
	check(vnear(f3.raw.listener.position, 500, 1.7, 50) and vnear(f3.raw.listener.forward, 0, 0, -1),
		"third person: the listener position is still P3's head (not the camera 4 m behind); forward is the camera's")
	W.pos[1] = Vec(503, 0, 50); P3.camOffset = Vec(0, 0, 4); run(8)
	e = spk(P3, 1)
	check(e and near(e.azimuth, 90, 0.5), "... and direct voices too: P1 3 m to the right of P3's head is at 90 degrees, wherever the camera hangs")
	P3.camOffset = nil; W.pos[1] = Vec(500, 0, 10); run(6)
	-- text through the walkies
	for _, m in ipairs(MACHINES) do m.sounds = {} end
	W.clog = {}
	waitRate(); say(P2, "team check")
	sto = W.sentTo("team check")
	check(sto[3] and sto[1] and sto[5] and not sto[4], "text on the team walkies: to P3 (its walkie), P1 and P5 (the talker's Speak reach + slack); not P4")
	local call
	for _, c in ipairs(W.clog) do if c.p == 3 and c.args[5] == "team check" then call = c end end
	check(call and call.args[11] == "team" and call.args[12] == "radio", "... with its channel and kind (dv = team, dk = radio)")
	k = "proxchat.said." .. (HOST.reg["proxchat.said.last"] % 16) .. "."
	check(HOST.reg[k .. "tx"] == "team" and HOST.reg[k .. "device"] == "radio" and HOST.reg[k .. "mode"] == "speak", "the event: mode speak, tx team, device radio")
	steps(2)
	local bw = P3.PC.c.devB and P3.PC.c.devB.w3
	check(bw and bw.level == "full" and bw.kind == "radio" and lastLine(P3, "s") and lastLine(P3, "s").text == "team check" and lastLine(P3, "s").via == "radio",
		"P3: a walkie bubble with the words; the line in its history")
	check((drawn(P3, "%[speak via walkie%]") or ""):find("via walkie", 1, true), "... tagged [speak via walkie]")
	local nRadio = 0
	for _, s in ipairs(P3.sounds) do if P3.loads[s.h]:find("radio") then nRadio = nRadio + 1 end end
	check(nRadio > 0, "... it babbles from the walkie with the band-passed clips (" .. nRadio .. ")")
	check(shownAt(P3, "w3") == nil, "P3's own walkie, first person: no bubble (as P3's own bubbles: the chat's feed shows the line)")
	P3.reg["game.thirdperson"] = true; step()
	local sh = shownAt(P3, "w3")
	check(sh and sh.kind == "radio" and vnear(sh.at, 500, 2.25, 50), "... third person: over P3's own walkie, above P3's head (walkie style)")
	P3.reg["game.thirdperson"] = nil
	-- someone else's walkie: P5 stands by P4, who carries one
	HOST.reg["proxchat.device.w4"] = "radio channel=team at=player:4"
	W.pos[5] = Vec(502, 0, 300); run(4)
	waitRate(); say(P2, "who is out there")
	steps(2)
	sh = shownAt(P5, "w4")
	check(sh and vnear(sh.at, 500, 2.25, 300) and P5.PC.c.devB.w4.level == "full", "P5 (2 m from P4): the bubble over P4's walkie, above P4's head, in the world")
	local L5
	for _, L in ipairs(P5.PC.drawOrder or {}) do if L.dev == "radio" then L5 = L end end
	check(L5 and not L5.docked and near(L5.x, 500) and near(L5.y, 300), "... a world bubble like any speaker's (on screen where the world point is, not docked)")
	P5.offscreen = true; step()
	L5 = nil
	for _, L in ipairs(P5.PC.drawOrder or {}) do if L.dev == "radio" then L5 = L end end
	check(L5 and L5.docked, "... off screen: on the screen's edge, as speaker bubbles are")
	P5.offscreen = nil
	HOST.reg["proxchat.device.w4"] = nil; W.pos[5] = Vec(500, 0, -50)
	-- a walkie on the floor near P4: its range and buffer
	HOST.reg["proxchat.device.floor"] = "radio channel=team at=500,0.2,303"
	run(4)
	waitRate(); say(P2, "anyone at the gate")
	steps(2)
	local bf = P4.PC.c.devB and P4.PC.c.devB.floor
	sh = shownAt(P4, "floor")
	check(bf and bf.level == "full" and hasLine(P4, "s", "anyone at the gate") and sh and vnear(sh.at, 500, 0.2, 303) and sh.kind == "radio",
		"a walkie on the floor 3 m from P4: P4 reads it over the walkie")
	W.pos[4] = Vec(500, 0, 310.5); steps(2)                                  -- (7.5 m from the walkie: its buffer, 6 .. 9 m)
	waitRate(); say(P2, "can you hear me now")
	steps(2)
	bf = P4.PC.c.devB.floor
	check(bf and bf.level == "mumble" and lastLine(P4, "s").far and lastLine(P4, "s").text:find("\226\172\154", 1, true),
		"7.5 m from the walkie (its buffer, 6 to 9 m): garbled - boxes")
	W.pos[4] = Vec(500, 0, 304); steps(3)
	check(P4.PC.c.devB.floor.level == "full" and lastLine(P4, "s").text == "can you hear me now" and not lastLine(P4, "s").far,
		"... walking up to it while it is up: the words show, the history line completes")
	-- live words through the walkies
	W.clog = {}
	HOST.server.pc_live(2, TOK(2), 7, "rolling out now", "s")
	steps(2)
	local liveTo = {}
	for _, c in ipairs(W.clog) do if c.name == "pc_live" and c.args[3] == "rolling out now" then liveTo[c.p] = c.args[7] end end
	check(liveTo[3] == "team" and liveTo[4] == "team" and P3.PC.c.live[2] and P3.PC.c.live[2].dv == "team",
		"live words on the channel: sent to the players near its walkies too (P3, P4 by the floor one), with the channel")
	local liveL
	for _, L in ipairs(P4.PC.drawOrder or {}) do if L.p == 2 and L.dev == "radio" and not L.docked then liveL = L end end
	check(liveL ~= nil, "... P4 sees them in a walkie bubble over the floor walkie")
	HOST.server.pc_live(2, TOK(2), 7, "", "s"); steps(2)
	-- the device string cleared: its bubble goes at once
	waitRate(); say(P2, "last call"); steps(2)
	check(P4.PC.c.devB.floor ~= nil, "(P4 has a bubble at the floor walkie)")
	HOST.reg["proxchat.device.floor"] = ""
	steps(2)
	check(P4.PC.c.devB.floor == nil and P4.PC.c.dw.devs.floor == nil, "proxchat.device.floor = \"\": the device and its bubble are gone at once")
	W.pos[4] = Vec(500, 0, 300)
	-- a loudspeaker on a body (a car's radio) on the same channel
	W.bodies = {[77] = Vec(500, 1, 60)}
	HOST.reg["proxchat.device.car"] = "loudspeaker channel=team at=body:77 range=3,20"
	run(4)
	local pts = P3.PC.devPoints(P3.PC.c.dw.devs.car)
	check(#pts == 1 and near(pts[1][3], 60), "a device on a body: it is where the body is")
	e = spk(P3, 2)
	local vcar
	for _, x in ipairs(e and e.via or {}) do if x.device == "loudspeaker" then vcar = x end end
	check(vcar and near(vcar.position[3], 60) and vcar.range[1] == 3 and vcar.range[2] == 20 and vcar.facing == nil and #e.via == 2,
		"... via a loudspeaker there with its own range [3, 20], no facing (a fixed horn), next to P3's walkie")
	W.bodies[77] = Vec(500, 1, 120); run(6)
	e = spk(P3, 2)
	check(e and #e.via == 1, "the car drives off (70 m): its loudspeaker drops out of P3's via")
	W.bodies = nil; run(6)
	check(#P3.PC.devPoints(P3.PC.c.dw.devs.car) == 0, "a body that is gone: no position (nothing plays there)")
	HOST.reg["proxchat.device.car"] = nil
	-- effects per mode and per player (proxchat.effects.*)
	HOST.reg["proxchat.effects.private"] = "pitch=-3 reverb=0.7 wobble=0.4"
	HOST.reg["proxchat.effects.speak"] = "band=300,3000"
	HOST.reg["proxchat.effects.player.2"] = "robot=60"
	HOST.reg["proxchat.effects.bogus"] = "pitch=2"
	W.pos[3] = Vec(500, 0, 8); run(8)
	e = spk(P3, 2)
	local vfx, dfx = e and e.via and e.via[1].effects, e and e.effects
	check(vfx and vfx.pitch == -3 and vfx.reverb == 0.7 and vfx.wobble == 0.4 and vfx.robot == 60,
		"effects: the walkies' (proxchat.effects.private: pitch -3, reverb 0.7, wobble 0.4) on their via, with P2's own (robot 60) over them")
	check(dfx and dfx.band and dfx.band[1] == 300 and dfx.robot == 60 and dfx.pitch == nil, "... P2's direct voice (8 m, Speak): Speak's effects (band) and P2's robot")
	HOST.reg["proxchat.effects.private"] = ""; HOST.reg["proxchat.effects.speak"] = ""; HOST.reg["proxchat.effects.player.2"] = ""
	run(4)
	e = spk(P3, 2)
	check(e and e.effects == nil and e.via and e.via[1].effects == nil, "\"\": back to the defaults (no effects given: Koetama's presets)")
	HOST.reg["proxchat.effects.bogus"] = nil
	HOST.reg["proxchat.effects.dead"] = "pitch=-3 reverb=0.7 wobble=0.4"
	HOST.reg["proxchat.channel.2"] = "dead"; HOST.reg["proxchat.channel.3"] = "dead"; run(6)
	e = spk(P3, 2)
	check(e and e.effects and e.effects.reverb == 0.7 and e.via == nil and W.feed(P2).raw.transmit == nil,
		"a 'dead' mode of effects: the dead hear each other as ghosts; no device carries the dead (no via, no transmit)")
	HOST.reg["proxchat.channel.2"] = nil; HOST.reg["proxchat.channel.3"] = nil; HOST.reg["proxchat.effects.dead"] = nil
	W.pos[3] = Vec(500, 0, 50); run(6)
	-- the reach limit, and the ranges
	HOST.reg["proxchat.device.w4"] = "radio channel=team at=player:4"
	HOST.reg["proxchat.ranges"] = "private=12 megaphone=100 pa=50 reach=100"; run(4)
	check(P3.PC.cfg.privateR == 12 and P3.PC.cfg.privateMumbleR == 18 and P3.PC.cfg.megaR == 100 and near(P3.PC.cfg.megaMumbleR, 133.33, 0.01)
		and P3.PC.cfg.paR == 50 and P3.PC.cfg.privateReach == 100 and HOST.shared.pcRanges.pr == 12,
		"proxchat.ranges = 'private=12 megaphone=100 pa=50 reach=100': every game's device ranges (buffers follow: walkies +50 %, the others +1/3)")
	check(txList(P2) == "3", "the walkies' reach (100 m): P2 transmits to P3, not to P4's walkie 300 m away (" .. txList(P2) .. ")")
	waitRate(); say(P2, "only the near ones"); steps(2)
	check(hasLine(P3, "s", "only the near ones") and not hasLine(P4, "s", "only the near ones"), "... and its text: P3 yes, P4 no")
	HOST.reg["proxchat.ranges"] = "8,25,40"; run(4)
	check(P3.PC.cfg.whisperR == 8 and P3.PC.cfg.privateR == 12, "the old three numbers still work, and leave the device ranges as they were")
	HOST.reg["proxchat.ranges"] = "private=6 megaphone=60 pa=45 reach=0"; run(4)
	HOST.reg["proxchat.device.w2"], HOST.reg["proxchat.device.w3"], HOST.reg["proxchat.device.w4"] = nil, nil, nil
	-- ---- a megaphone: a loudspeaker P2 holds, pointing where P2 looks
	HOST.reg["proxchat.device.mega"] = "loudspeaker channel=bullhorn at=player:2"
	HOST.reg["proxchat.tx.2"] = "bullhorn"; run(6)
	e = spk(P3, 2)
	v = e and e.via and e.via[1]
	check(v and v.device == "loudspeaker" and vnear(v.position, 500, 1.3, 0) and v.range[1] == 8 and near(v.range[2], 80, 0.1) and vnear(v.facing, 0, 0, 1) and e.gain == nil,
		"a megaphone (voice): via a loudspeaker at P2's chest, range [8, 80], facing where P2 looks [0,0,1]; P3 at 50 m: only through it")
	check(txList(P2) == "1,3,4,5" or txList(P2) == "1,3,5", "P2 transmits to who is within the megaphone's 80 m + slack: " .. txList(P2))
	for _, m in ipairs(MACHINES) do m.sounds = {} end
	waitRate(); say(P2, "everyone line up")
	steps(2)
	local b3 = P3.PC.c.devB and P3.PC.c.devB.mega
	sh = shownAt(P3, "mega")
	check(b3 and b3.level == "full" and sh and sh.kind == "loudspeaker" and vnear(sh.at, 500, 2.25, 0),
		"P3 50 m ahead of the horn reads it: a loudspeaker bubble over P2 (its holder)")
	local nHorn = 0
	for _, s in ipairs(P3.sounds) do if P3.loads[s.h]:find("horn") then nHorn = nHorn + 1 end end
	check(nHorn > 0, "... it babbles from the horn (" .. nHorn .. ")")
	check(shownAt(P5, "mega") == nil and not hasLine(P5, "s", "everyone line up"), "P5 50 m BEHIND the horn: nothing (its reach shrinks to 15 % behind)")
	run(60 * 14)                                                          -- (the line before is over)
	W.pos[3] = Vec(500, 0, 30); steps(2)
	waitRate(); say(P2, "thirty metres")
	steps(2)
	local direct3, dev3 = false, false
	for _, L in ipairs(P3.PC.drawOrder or {}) do
		if L.p == 2 and L.dev == "loudspeaker" then dev3 = true elseif L.p == 2 and not L.dev then direct3 = true end
	end
	check(P3.PC.c.bubbles[2] and P3.PC.c.bubbles[2].level == "mumble" and dev3 and not direct3,
		"P3 at 30 m (P2's own voice garbled there): only the megaphone's bubble, in full - not a second, garbled one")
	-- one bubble between P2 and its megaphone: the fuller one, the megaphone's when equal - finished lines and live words
	local function overP2(m)
		local n, kind = 0, nil
		for _, L in ipairs(m.PC.drawOrder or {}) do
			if L.p == 2 then n = n + 1; kind = L.dev or "own"; m.lastL = L end
		end
		return n, kind
	end
	local cases = {
		{"in front, 10 m (within both)", Vec(500, 0, 10), "full", "full", "loudspeaker"},
		{"behind and aside, 15 m (within Speak, the horn's shrunk reach garbles)", Vec(507, 0, -13.2), "full", "mumble", "own"},
		{"right behind, 5 m (within both)", Vec(500, 0, -5), "full", "full", "loudspeaker"},
		{"in front, 50 m (beyond Speak, within the horn)", Vec(500, 0, 50), nil, "full", "loudspeaker"},
	}
	for i, cs in ipairs(cases) do
		run(60 * 14)
		W.pos[3] = cs[2]; run(2)
		local text = "one bubble case " .. i
		waitRate(); say(P2, text); steps(2)
		local own, mega = P3.PC.c.bubbles[2], P3.PC.c.devB.mega
		local ownLevel = own and not own.hidden and P3.PC.inReach(2, own) and own.level or nil
		local megaLevel = mega and P3.PC.devHeardNow(mega) and mega.level or nil
		local n, kind = overP2(P3)
		check(ownLevel == cs[3] and megaLevel == cs[4] and n == 1 and kind == cs[5],
			"one bubble, " .. cs[1] .. ": own " .. tostring(ownLevel) .. ", megaphone " .. tostring(megaLevel) .. " -> only the " .. tostring(kind) .. " one (" .. n .. ")")
		local entries = 0
		for _, e in ipairs(hist(P3)) do if e.p == 2 and e.t and e.t > W.time - 1 then entries = entries + 1 end end
		check(entries == 1, "... one history line for it (" .. entries .. ")")
		-- live words, the same place
		run(60 * 14)
		HOST.server.pc_live(2, TOK(2), 50 + i, "live words case " .. i, "s"); steps(3)
		n, kind = overP2(P3)
		check(n == 1 and kind == cs[5], "live words, " .. cs[1] .. ": one bubble, the " .. tostring(kind) .. " one (" .. n .. ")")
		HOST.server.pc_live(2, TOK(2), 50 + i, "", "s"); steps(2)
	end
	W.pos[3] = Vec(500, 0, 50)
	check(near(P3.PC.hornFactor(2), 1, 0.01) and near(P5.PC.hornFactor(2), P5.PC.cfg.hornBack, 0.01), "the horn: full reach ahead, " .. P1.PC.cfg.hornBack .. " straight behind")
	HOST.reg["proxchat.device.mega"] = nil
	-- ---- a PA with speakers
	HOST.reg["proxchat.device.hall"] = "pa at=500,5,40;500,5,90;500,5,160"
	HOST.reg["proxchat.tx.2"] = "pa"; run(6)
	e = spk(P3, 2)
	v = e and e.via and e.via[1]
	check(v and v.device == "pa" and v.positions and #v.positions == 2 and near(v.positions[1][3], 40) and v.facing == nil,
		"a PA: P3 hears it from the two speakers within reach (positions; nearest first), no facing")
	waitRate(); say(P2, "the hall is closing")
	steps(2)
	local bp = P3.PC.c.devB and P3.PC.c.devB.hall
	sh = shownAt(P3, "hall")
	check(bp and bp.level == "full" and sh and sh.kind == "pa" and vnear(sh.at, 500, 5, 40), "... one PA bubble, over its nearest speaker")
	check(drawn(P3, "^PA$") ~= nil, "... with its PA tag")
	check(not hasLine(P4, "s", "the hall is closing"), "P4 (far from every speaker): nothing")
	HOST.reg["proxchat.device.hall"] = nil
	HOST.reg["proxchat.tx.2"] = nil
	-- the lobby: no devices
	HOST.reg["proxchat.device.w3"] = "radio channel=team at=player:3"
	HOST.reg["proxchat.tx.2"] = "team"
	HOST.reg["proxchat.lobby"] = true; run(6)
	e = spk(P3, 2)
	check(e and e.via == nil and W.feed(P2).raw.transmit == nil, "the lobby: everyone hears everyone, no device")
	HOST.reg["proxchat.lobby"] = false
	HOST.reg["proxchat.device.w3"], HOST.reg["proxchat.tx.2"] = nil, nil
	run(6)

	-- ---- voice dummies through their own test devices (test voices take via)
	local VO3 = P3.PC.c.voice
	say(P3, "/dummy voice walkie"); run(4)
	local dm = VO3.list[1]
	check(#VO3.list == 1 and VO3.testDevs and P3.PC.c.dw.devs["test walkie you"] and P3.PC.c.dw.tx[dm.p] == "test" and not HOST.shared.pcDev["test walkie you"],
		"/dummy voice walkie: a voice dummy 50 m away; a walkie each and its talk, only in P3's game")
	e = spk(P3, dm.p)
	v = e and e.via and e.via[1]
	check(e and e.test_voice == 2 and v and v.device == "radio" and vnear(v.position, 500, 1.3, 50) and e.gain == nil,
		"... the test voice's feed entry: via P3's walkie (at P3's chest), no gain - heard only through it")
	P3.reg["game.thirdperson"] = true
	local live = false
	for _ = 1, 60 * 12 do
		run(1)
		for _, L in ipairs(P3.PC.drawOrder or {}) do if L.dev == "radio" and L.p == dm.p and not L.docked then live = true end end
	end
	check(live, "... its words show live in a walkie bubble over P3's walkie (third person)")
	run(60 * 6)
	local dl = lastLine(P3, "s")
	check(dl and dl.p == dm.p and dl.text:find("I am the speaker", 1, true) and not dl.far and dl.via == "radio",
		"... its finished line goes into the history, heard through the walkie: " .. tostring(dl and dl.text))
	P3.reg["game.thirdperson"] = nil
	say(P3, "/dummy voice megaphone"); run(4)
	dm = VO3.list[1]
	e = spk(P3, dm.p)
	v = e and e.via and e.via[1]
	check(v and v.device == "loudspeaker" and vnear(v.facing, 0, 0, 1) and VO3.testDevs["test walkie you"] == nil, "/dummy voice megaphone: its own loudspeaker, its horn pointing at P3 (facing)")
	say(P3, "/dummy voice pa"); run(4)
	e = spk(P3, VO3.list[1].p)
	check(e and e.via and e.via[1].device == "pa" and #e.via[1].positions == 4, "/dummy voice pa: four PA speakers around P3")
	say(P3, "/dummy voice clear"); run(4)
	check(#VO3.list == 0 and VO3.testDevs == nil and VO3.testTx == nil, "/dummy voice clear: gone, with its test devices")
	for _, m in ipairs(MACHINES) do m.files = nil end
	W.facing = nil
	steps(4)
end)()

-- ================================================================== SECURITY (2026-10-09): the audit's attacks, which must now fail
-- (a modified game sends any ServerCall it likes, with any arguments: W.forge queues one as if from such a game)
;(function()
	local function forge(name, ...) W.calls[#W.calls + 1] = {name = name, args = deep({...}), n = select("#", ...)} end
	local function cnt(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n end
	local S = HOST.PC.s
	for _, m in ipairs(MACHINES) do if m.PC.c.typing then press(m, "esc"); step() end; m.PC.c.nav = false end
	for k in pairs(HOST.reg) do
		if k:find("^proxchat%.device%.") or k:find("^proxchat%.tx%.") or k:find("^proxchat%.channel%.") or k:find("^proxchat%.hearall%.") then HOST.reg[k] = nil end
	end
	HOST.reg["proxchat.lobby"], HOST.reg["proxchat.ranges"] = nil, nil
	W.pos[1], W.pos[2], W.pos[3], W.pos[4], W.pos[5] = Vec(0, 0, 0), Vec(4, 0, 0), Vec(30, 0, 0), Vec(60, 0, 0), Vec(14, 0, 0)
	W.pos[6], W.pos[7], W.pos[8] = Vec(300, 0, 0), Vec(400, 0, 0), Vec(500, 0, 0)
	steps(70)
	local function got(m, text) for _, e in ipairs(hist(m)) do if e.text == text then return e end end return nil end

	-- 1. impersonation: P3 speaks as P2 - no token, P3's own token, a guessed one
	waitRate()
	forge("pc_say", 2, nil, "s", "forged without a token", 1)
	forge("pc_say", 2, TOK(3), "s", "forged with P3's own token", 2)
	forge("pc_say", 2, string.rep("0", 32), "g", "forged with a guessed token", 3)
	forge("pc_live", 2, TOK(3), 9, "forged live words", "s", "", -1)
	forge("pc_typing", 2, TOK(3), true, "s")
	forge("pc_vmode", 2, TOK(3), "g")
	forge("pc_voice", 2, TOK(3), 1)
	forge("pc_talk", 2, nil, true, "s")
	steps(3)
	check(not got(P1, "forged without a token") and not got(P1, "forged with P3's own token") and not got(P1, "forged with a guessed token")
		and not (P1.PC.c.live and P1.PC.c.live[2]) and not HOST.PC.isTyping(2) and HOST.reg["proxchat.typing.2"] ~= true
		and HOST.shared.pcVMode[2] ~= "g" and not (P1.PC.c.talking or {})[2],
		"TRUST: nobody speaks as another player - lines, live words, typing, voice mode, talking: refused without that player's token")
	check(TOK(3) ~= TOK(2) and P3.PC.c.tok == TOK(3) and P2.PC.c.tok == TOK(2), "... each game holds only its own token")
	local W0 = W.ccalls
	W.ccalls = {}
	HOST.server.pc_tokreq(2)
	HOST.server.tick(0)
	local toOthers = false
	for _, c in ipairs(W.ccalls) do if c.name == "pc_token" and c.p ~= 2 then toOthers = true end end
	local sentTo2 = false
	for _, c in ipairs(W.ccalls) do if c.name == "pc_token" and c.p == 2 and c.args[2] == TOK(2) then sentTo2 = true end end
	W.ccalls = W0
	check(sentTo2 and not toOthers, "... asking for P2's token (anyone may) sends it to P2's game alone, by ClientCall")
	P3.client.pc_token(2, TOK(2))
	check(P3.PC.c.tok == TOK(3), "... and a game ignores a token addressed to another player")
	waitRate(); P3.PC.say("P3 says this itself", "g"); steps(3)
	check(got(P1, "P3 says this itself") and got(P1, "P3 says this itself").p == 3, "... a player's own lines go through as before")

	-- 2. made-up ids: no rate-limit dodge, no table growth, no stall
	local t0 = os.clock()
	for i = 1, 2000 do forge("pc_say", 100000 + i, TOK(3), "g", "spam " .. i, 1) end
	for i = 1, 3000 do forge("pc_typing", 200000 + i, TOK(3), true, "s"); forge("pc_voice", 300000 + i, TOK(3), 1); forge("pc_vmode", 400000 + i, TOK(3), "s") end
	forge("pc_say", 2.5, TOK(3), "g", "half a player", 1); forge("pc_say", 1e15, TOK(3), "g", "a huge id", 1); forge("pc_say", -1, nil, "g", "minus one", 1)
	local nP2 = #hist(P2)
	step()
	local dtc = os.clock() - t0
	local typingKeys = 0
	for k in pairs(HOST.reg) do if k:find("^proxchat%.typing%.") then typingKeys = typingKeys + 1 end end
	check(#hist(P2) == nP2 and cnt(HOST.shared.pcAck) <= 8 and cnt(HOST.shared.pcTyping) <= 8 and cnt(HOST.shared.pcVoice) <= 8 and cnt(HOST.shared.pcVMode) <= 8
		and typingKeys <= 8 and cnt(S.seq) <= 8 and cnt(S.last) <= 8,
		string.format("TRUST: 2000 lines + 9000 calls from made-up ids (and 2.5, 1e15, -1): nothing said, no table or registry key grows (%.2f s)", dtc))
	local okN = pcall(HOST.server.pc_typing, 0 / 0, "x", true, "s") and pcall(HOST.server.pc_say, 0 / 0, nil, "g", "nan", 1)
		and pcall(HOST.server.pc_live, 2, TOK(2), 0 / 0, "x", "s", "", 0 / 0) and pcall(HOST.server.pc_say, 2, TOK(2), "s", "nan ago", 0 / 0, true, "0000;nan;0")
	check(okN, "... NaN ids, numbers and times: no error")
	check(HOST.server.pc_hearall == nil and HOST.server.pc_ranges == nil and HOST.server.pc_walls == nil and HOST.server.pc_region == nil,
		"TRUST: no ServerCall can claim to hear everything or change the host's settings (pc_hearall, pc_ranges, pc_walls, pc_region are gone)")

	-- 3. the host's settings: only the host's own registry
	local C1 = HOST.PC.cfg
	P3.reg["savegame.mod.pcranges"] = "78,79,80"; P3.reg["savegame.mod.pcwallson"] = true; P3.reg["savegame.mod.pcvxregion"] = "oc"
	P3.PC.setHostRanges(78, 79, 80); P3.PC.setHostWalls(true); P3.PC.stepVoiceRegion(1)
	steps(3)
	check(C1.whisperR == 8 and HOST.shared.pcWalls ~= true and HOST.shared.pcVoiceRegion ~= "oc" and HOST.reg["savegame.mod.pcranges"] ~= "78,79,80",
		"TRUST: a guest can't change the distances, walls or voice server (its own registry is only its own)")
	waitRate(); P1.PC.say("a whisper near P1", "w"); steps(3)
	check(got(P2, "a whisper near P1") and not got(P4, "a whisper near P1") and not got(P3, "a whisper near P1"), "... so a whisper still reaches only 14 m")

	-- 4. the seq mute: a huge number for P2 (refused), and P2's own jump past the window (refused)
	waitRate()
	forge("pc_say", 2, TOK(3), "s", "poison", 1e15); step()
	HOST.server.pc_say(2, TOK(2), "s", "a jump", (S.seq[2] or 0) + 1000); step()
	waitRate(); P2.PC.say("P2 still talks", "s"); steps(40)
	check(got(P1, "P2 still talks") and not got(P1, "poison") and not got(P1, "a jump") and #P2.PC.c.outbox == 0,
		"TRUST: nobody can mute P2 with a message number of 1e15; a number past the window (+1000) is refused; P2's next line arrives")

	-- 5. markup: no [[...]] from players anywhere, no wildcards when drawing player text
	waitRate()
	P2.PC.say("click [[https://evil.example/free;label=FREE]] or [[menu:menu_accept;iconsize=4000,4000]] [[[x]]]", "s"); steps(3)
	local em = lastLine(P1, "s")
	check(em and em.p == 2 and not em.text:find("[[", 1, true), "TRUST: '[[' is neutralised in a line (" .. tostring(em and em.text) .. ")")
	W.names[5] = "[[https://evil.example]] Bob"
	waitRate(); P5.PC.say("a name with markup", "g"); steps(3)
	local en = got(P1, "a name with markup")
	check(en and not en.name:find("[[", 1, true), "... and in a name (" .. tostring(en and en.name) .. ")")
	W.names[5] = "P5"
	check(P1.PC.clean("[[[[a]]") == "[ [ [ [a]]" and P1.PC.clean("[ [") == "[ [", "... '[[' of any length becomes '[ [ ...' (and stays so)")
	press(P1, "return"); step()
	check(#P1.texts > 5 and #P1.wildTexts == 0 and P1.wildSized == 0 and drawn(P1, "FREE", true),
		"... every text the chat draws (window, lines, names, bubbles, input line) is drawn with UiText's wildcards off")
	press(P1, "esc"); step()
	step()
	check(#P1.wildTexts == 0 and drawn(P1, "FREE", true), "... the feed and bubbles too, the window closed")
	if not P4.PC.c.voice or not P4.PC.c.voice.h.alive then
		press(P4, "return"); P4.PC.setPage("voice"); step()
		check(#P4.wildTexts == 0, "... the Voice page too, its Koetama link included (a button, not UiText's link): " ..
			table.concat(P4.wildTexts, " | "))
		press(P4, "esc"); step()
	end

	-- 6. huge text (from a player's own game, with its own token)
	waitRate()
	local seq2 = (S.seq[2] or 0)
	t0 = os.clock()
	local lastId = HOST.shared.pcMsgs[#HOST.shared.pcMsgs].id
	HOST.server.pc_say(2, TOK(2), "g", ("\194" .. string.rep("\128", 50000)):rep(3) .. " hi", seq2 + 1)
	local big = HOST.shared.pcMsgs[#HOST.shared.pcMsgs]
	check(big.id == lastId and HOST.shared.pcAck[2] == seq2 + 1,
		"TRUST: a 150 KB line of 'three characters' (a lead byte + 50000 continuation bytes each): nothing valid in it - nothing said (confirmed, dropped)")
	waitRate()
	HOST.server.pc_say(2, TOK(2), "g", string.rep("a", 5000000), seq2 + 2)
	big = HOST.shared.pcMsgs[#HOST.shared.pcMsgs]
	local dtb = os.clock() - t0
	check(big and #big.text == 90 and dtb < 0.5, string.format("... a 5 MB line: cut to 90 characters before any scan (%.3f s)", dtb))
	t0 = os.clock()
	HOST.server.pc_live(2, TOK(2), 5, "hello", "s", string.rep("0", 8000000), 1)
	HOST.server.pc_live(2, TOK(2), 5, string.rep("b ", 3000000), "s", "", 1)
	dtb = os.clock() - t0
	check(dtb < 0.5, string.format("... live words with an 8 MB word-time string, or 6 MB of text: refused / cut at once (%.3f s)", dtb))
	P2.PC.c.seq = S.seq[2]                                             -- (those two were P2's numbers: its game counts on from them)
	steps(5)

	-- 7. hear everything: only a game's own registry key on the host
	waitRate()
	P1.PC.say("far from P4", "s"); steps(3)
	check(not got(P4, "far from P4"), "TRUST: P4 (60 m) can't ask for every Speak line - only the game's proxchat.hearall.4 on the host could")

	-- 8. the voice room: the host's own wins; a guest's only from a real player with a token, while the host has none
	local ROOMA, KEYA = string.rep("a", 32), string.rep("b", 64)
	local ROOMH, KEYH = string.rep("c", 32), string.rep("d", 64)
	local ROOMG, KEYG = string.rep("e", 32), string.rep("f", 64)
	S.voiceRoom, HOST.shared.pcVoiceRoom, S.hostRoomSeen = nil, nil, nil
	HOST.reg["proxchat.hostroom"] = nil
	forge("pc_room", 999, nil, ROOMA, KEYA); forge("pc_room", 4, TOK(3), ROOMA, KEYA); forge("pc_room", 4, nil, ROOMA, KEYA); steps(2)
	check(HOST.shared.pcVoiceRoom == nil, "TRUST: a room offer from a made-up id, or with someone else's / no token: refused")
	P1.PC.voiceRoomOffer(ROOMH, KEYH); steps(2)
	HOST.server.pc_room(3, TOK(3), ROOMG, KEYG); steps(2)
	check(HOST.shared.pcVoiceRoom and HOST.shared.pcVoiceRoom.id == ROOMH, "... the host's own Koetama room is the session's; a guest's offer then changes nothing")
	S.voiceRoom, HOST.shared.pcVoiceRoom = nil, nil
	HOST.reg["proxchat.hostroom"], S.hostRoomSeen = nil, nil
	HOST.server.pc_room(3, TOK(3), ROOMG, KEYG); steps(2)
	check(HOST.shared.pcVoiceRoom and HOST.shared.pcVoiceRoom.id == ROOMG, "... a host without Koetama: the first real player's (with its token) is taken")
	HOST.server.pc_room(4, TOK(4), ROOMA, KEYA); steps(2)
	check(HOST.shared.pcVoiceRoom.id == ROOMG, "... a second guest's: refused")
	P1.PC.voiceRoomOffer(ROOMH, KEYH); steps(2)
	check(HOST.shared.pcVoiceRoom.id == ROOMH and HOST.shared.pcVoiceRoom.key == KEYH, "... the host's own Koetama comes later: its room wins")
	W.time = W.time + 0.001
	local tA = S.time
	HOST.server.tick(1e9); HOST.server.tick(1e9)
	check(S.time - tA <= 1 / 15 + 1e-9, "TRUST: a forged server.tick can't jump the server's clock (dt clamped; a second tick in a frame adds nothing)")
	S.voiceRoom, HOST.shared.pcVoiceRoom = nil, nil
	HOST.reg["proxchat.hostroom"], S.hostRoomSeen = nil, nil

	-- 9. translation floods (P2 with a Koetama translating into English, faked)
	local VO = P2.PC.voice()
	local was = {VO.h.alive, VO.tr.into, VO.tr.reqs}
	VO.h.alive, VO.tr.into, VO.tr.reqs = true, "en", {}
	VO.tr.per, VO.tr.asked, VO.tr.cache = {}, {}, {}
	for i = 1, 30 do P2.PC.receive({id = 700000 + i, p = 3, name = "P3", ch = "g", text = "flood line " .. i}) end
	local n3 = #VO.tr.reqs
	for i = 1, 5 do P2.PC.receive({id = 700100 + i, p = 4, name = "P4", ch = "g", text = "the same line"}) end
	local nSame = #VO.tr.reqs - n3
	P2.PC.receive({id = 700200, p = 999999, name = "Ghost", ch = "g", text = "from nobody"})
	local nGhost = #VO.tr.reqs - n3 - nSame
	check(n3 == P2.PC.cfg.trPerSpeaker and nSame == 1 and nGhost == 0,
		string.format("TRUST: translation floods - 30 lines of one speaker: %d asked; the same line 5 times: %d; a speaker who is no player: %d", n3, nSame, nGhost))
	local idSame
	for _, r in ipairs(VO.tr.reqs) do if r.text == "the same line" then idSame = r.id end end
	P2.PC.trReply(idSame, "la misma linea")
	local eSame = {p = 5, text = "the same line", ch = "g"}
	P2.PC.trWant(eSame)
	check(eSame.tr == "la misma linea" and eSame.trId == -1, "... a line already translated: its translation reused, not asked again")
	VO.h.alive, VO.tr.into, VO.tr.reqs = was[1], was[2], was[3]

	-- 10. names: invisible ones, the same name twice, /mute #id
	W.names[7] = "\227\133\164\226\128\139 \194\173"                   -- (a Hangul filler, a zero-width space, a soft hyphen)
	check(HOST.PC.nameOf(7) == "Player 7", "TRUST: a name of nothing visible: 'Player 7' (" .. HOST.PC.nameOf(7) .. ")")
	W.names[6] = "P2"
	check(HOST.PC.nameOf(6) == "P2 #6" and HOST.PC.nameOf(2) == "P2 #2", "... two players called P2: each gets its number ('P2 #2', 'P2 #6')")
	W.names[6] = "Р2"                                                   -- (a Cyrillic Р)
	check(HOST.PC.nameOf(6) == "Р2 #6", "... a look-alike (Cyrillic Р) too")
	W.names[6] = "P2"
	W.pos[6] = Vec(6, 0, 0)
	waitRate(); P2.PC.say("I am the real P2", "g"); waitRate(); P6.PC.say("me too", "g"); steps(3)
	press(P1, "return"); typeText(P1, "/mute P2"); press(P1, "return"); step()
	local ml = lastLine(P1).text
	check(ml:find("(#2)", 1, true) and ml:find("(#6)", 1, true) and ml:find("/mute #<number>", 1, true), "... /mute P2 lists both with their numbers: " .. ml)
	press(P1, "return"); typeText(P1, "/mute #6"); press(P1, "return"); step()
	waitRate(); P6.PC.say("muted now", "g"); waitRate(); P2.PC.say("still heard", "g"); steps(3)
	check(not got(P1, "muted now") and got(P1, "still heard"), "... /mute #6 mutes that one, not the real P2")
	press(P1, "return"); typeText(P1, "/unmute all"); press(P1, "return"); step()
	W.names[6], W.names[7], W.pos[6] = "P6", "P7", Vec(300, 0, 0)

	-- 11. rate limits on live words and talking
	W.clog = {}
	for i = 1, 50 do HOST.server.pc_live(2, TOK(2), 600 + i, "live " .. i, "s", "", -1); HOST.server.pc_talk(2, TOK(2), i % 2 == 1, "s") end
	local utts, nl, nt, rcpt = {}, 0, 0, {}
	for _, c in ipairs(W.ccalls) do
		if c.name == "pc_live" and c.args[1] == 2 and c.args[3] ~= "" and not utts[c.args[2]] then utts[c.args[2]] = true; nl = nl + 1 end
		if c.name == "pc_talk" and c.args[1] == 2 and c.args[2] == true then nt = nt + 1; rcpt[c.p] = true end
	end
	local nr = math.max(1, cnt(rcpt))
	check(nl <= 8 and nt / nr <= 6, "TRUST: 50 live-words / talking calls in one frame: at most a burst gets through (" .. nl .. " live lines, " .. (nt / nr) .. " talk starts)")
	W.clog = nil
	HOST.server.pc_live(2, TOK(2), 0, "", "s"); steps(30)

	-- 12. normal flows still: a joiner, a rejoin, whisper, dead channel, lobby
	W.names[9] = "P9"
	W.pos[9] = Vec(2, 0, 0)
	local P9 = addMachine(9, false)
	steps(5)
	check(P9.PC.c.tok == TOK(9) and TOK(9) ~= nil, "a player who joins mid-session gets a token at once")
	waitRate(); P9.PC.say("hi from the new one", "s"); steps(3)
	check(got(P1, "hi from the new one"), "... and is heard")
	local old9 = TOK(9)
	W.removed = {9}; step()
	steps(3)
	check(TOK(9) and TOK(9) ~= old9 and P9.PC.c.tok == TOK(9), "a player who left and came back (the same id): a new token, delivered")
	waitRate(); P9.PC.say("back again", "s"); steps(40)
	check(got(P1, "back again") and #P9.PC.c.outbox == 0, "... heard again")
	P9.PC.c.tok = nil; P9.PC.c.seq = 0                                 -- (its game restarted: no token, counting from 0)
	P9.PC.say("restarted game", "s"); steps(5)
	check(got(P1, "restarted game") and #P9.PC.c.outbox == 0, "a game that restarted asks for its token, and its first line (renumbered past the host's ack) arrives")
	HOST.reg["proxchat.channel.9"] = "dead"; HOST.reg["proxchat.channel.3"] = "dead"; steps(3)
	waitRate(); P9.PC.say("boo, dead", "s"); steps(3)
	check(got(P3, "boo, dead") and not got(P1, "boo, dead"), "the dead channel: only the dead hear the dead")
	HOST.reg["proxchat.channel.9"], HOST.reg["proxchat.channel.3"] = nil, nil
	HOST.reg["proxchat.lobby"] = true; steps(3)
	waitRate(); P2.PC.say("lobby whisper", "w"); steps(3)
	check(got(P4, "lobby whisper"), "the lobby: everyone hears everything")
	HOST.reg["proxchat.lobby"] = nil; steps(3)
	W.pos[9] = nil; W.removed = {9}; step()
	for i, m in ipairs(MACHINES) do if m == P9 then table.remove(MACHINES, i) end end
	steps(3)
	check(TOK(9) == nil and HOST.shared.pcAck[9] == nil, "a player who left: their token and ack gone")
	-- SHA-256 itself (the tokens' one-way function): the standard test vectors
	check(HOST.PC.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
		and HOST.PC.sha256("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
		and HOST.PC.sha256(string.rep("a", 1000)) == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3",
		"SHA-256 matches its test vectors ('abc', '', 1000 x 'a')")
	check(HOST.reg["savegame.mod.pcsecret"] and #HOST.reg["savegame.mod.pcsecret"] == 64, "the host keeps its token secret in its own savegame (for the next session's entropy)")
end)()

-- ================================================================== per-player volume (2026-10-10): the Voice page's
-- sliders (saved by name, restored), /volume, the babble
;(function()
	for _, m in ipairs(MACHINES) do if m.PC.c.typing then press(m, "esc"); step() end end
	HOST.reg["proxchat.walls"] = false
	W.boxes = nil
	for p = 1, 8 do W.pos[p] = Vec(200 + p * 60, 0, 0) end
	W.pos[1], W.pos[2] = Vec(0, 0, 0), Vec(4, 0, 0)
	steps(3)
	local KEY2 = "savegame.mod.pcpvol.5032"                               -- (hex of "P2")
	check(P1.PC.playerVolume(2) == 1 and P1.PC.playerVolume(1) == 1 and P1.PC.playerVolume(P1.PC.DUMMY) == 1,
		"per-player volume: 100 % by default (yourself and the test speakers: always)")
	-- the slider: P1's Voice page, P2's row is the first player row (340 px wide); dragged to 3/4 = 150 %
	press(P1, "return"); P1.PC.setPage("voice"); step()
	check(drawn(P1, "^Players$") and drawn(P1, "^their volume, only for you$") and drawn(P1, "^P2$") and drawn(P1, "^100%%$"),
		"the Voice page: a Players subsection, a row per other player (P2 at 100 %)")
	local pvRow
	for _, r in ipairs(P1.PC.voiceRows()) do if r[1] == "set_pv2" then pvRow = r end end
	check(pvRow and math.abs(pvRow.mark - 1 / 1.5) < 1e-9 and pvRow.steps == 30 and math.abs(pvRow[4] - 1 / 1.5) < 1e-9,
		"... its slider: 0-150 %, a tick at 100 % (2/3 along), 5 % steps; 100 % sits on the tick")
	P1.hover = {340, 36, 1}; P1.mouseX = 340; P1.keys.lmb = true; P1.held = {lmb = true}; step()
	P1.held = nil; step(); P1.hover = nil
	check(P1.PC.playerVolume(2) == 1, "... without Koetama the Players subsection is greyed out like the page: dragging does nothing")
	local VOp = P1.PC.voice()
	VOp.h.alive = true                                                -- (Koetama connected: the page usable)
	P1.hover = {340, 36, 1}; P1.mouseX = 340; P1.keys.lmb = true; P1.held = {lmb = true}; step()
	check(P1.PC.playerVolume(2) == 1.5 and P1.reg[KEY2] == nil and drawn(P1, "^150%%$"), "... with Koetama, dragging it: 150 % at once, not saved yet")
	P1.held = nil; step(); P1.hover = nil
	check(P1.reg[KEY2] == 1.5, "... let go: saved by P2's name (savegame.mod.pcpvol.<hex of the name>)")
	local R = machine(1, false, deep(P1.reg))
	check(R.PC.playerVolume(2) == 1.5 and R.PC.playerVolume(3) == 1, "... restored in a new session (another game with that registry): P2 150 %, P3 100 %")
	W.names[2] = "Somebody else"
	check(R.PC.playerVolume(2) == 1, "... by name: another player with number 2 gets 100 %")
	W.names[2] = "P2"
	P1.hover = {P1.PC.RESET_W, 36, 1}; P1.keys.lmb = true; step(); P1.hover = nil; step()
	check(P1.PC.playerVolume(2) == 1 and P1.reg[KEY2] == nil, "Reset: back to 100 %, the saved key cleared")
	P1.PC.c.muted[3] = "P3"; step()
	check(drawn(P1, "P3  (muted)", true) ~= nil and drawn(P1, "^P2$"), "a muted player shows as muted on the Voice page")
	P1.PC.c.muted[3] = nil
	VOp.h.alive = false
	-- /volume
	W.names[4], W.names[5] = "Bobby", "Bobcat"
	press(P1, "esc"); step()
	say(P1, "/volume bob 50")
	local l = lastLine(P1).text
	check(l:find("could be: Bobby (#4), Bobcat (#5)", 1, true) and l:find("/volume #<number> 50", 1, true) and P1.PC.playerVolume(5) == 1,
		"/volume bob 50: two fit - both listed with their numbers, nothing changed: " .. l)
	say(P1, "/volume bobc 50")
	check(P1.PC.playerVolume(5) == 0.5 and P1.reg["savegame.mod.pcpvol.426f62636174"] == 0.5 and lastLine(P1).text:find("Bobcat: 50%", 1, true),
		"/volume bobc 50: the start of a name, Bobcat at 50 %, saved")
	say(P1, "/volume Bobcat")
	check(lastLine(P1).text:find("Bobcat: 50%", 1, true) and P1.PC.playerVolume(5) == 0.5, "/volume Bobcat alone: shows it (50 %)")
	say(P1, "/volume #4 150%")
	check(P1.PC.playerVolume(4) == 1.5, "/volume #4 150%: by number (and a % sign), Bobby at 150 %")
	say(P1, "/volume bobby 160")
	check(P1.PC.playerVolume(4) == 1.5 and lastLine(P1).text:find("0 to 150", 1, true), "/volume bobby 160: refused (0-150), unchanged")
	say(P1, "/volume nobody 50")
	check(lastLine(P1).text:find("No player called", 1, true), "/volume nobody 50: no such player")
	say(P1, "/volume")
	l = lastLine(P1).text
	check(l:find("Bobby 150%", 1, true) and l:find("Bobcat 50%", 1, true) and not l:find("P2 ", 1, true), "/volume alone: the players not at 100 %: " .. l)
	P1.PC.c.muted[5] = "Bobcat"
	say(P1, "/volume bobcat")
	check(lastLine(P1).text:find("muted", 1, true), "/volume on a muted player says so")
	P1.PC.c.muted[5] = nil
	say(P1, "/help")
	local helpHas = false
	for _, e in ipairs(hist(P1)) do if e.sys and (e.text or ""):find("/volume <name> <0-150>", 1, true) then helpHas = true end end
	check(helpHas, "/help lists /volume")
	say(P1, "/volume bobby 100"); say(P1, "/volume bobcat 100")
	check(P1.reg["savegame.mod.pcpvol.426f626279"] == nil and P1.reg["savegame.mod.pcpvol.426f62636174"] == nil, "/volume ... 100: the keys cleared")
	W.names[4], W.names[5] = "P4", "P5"
	-- the babble of P2's typed line (4 m away), at 100 % and at 50 %
	local function babbleOf(text)
		waitRate(); P1.sounds = {}
		say(P2, "/s " .. text); steps(120)
		local n, v = soundsFrom(P1, 4)
		return n, v
	end
	local n1, v1 = babbleOf("one two three four")
	P1.PC.setPlayerVolume(2, 0.5)
	local n2, v2 = babbleOf("five six seven eight")
	P1.PC.setPlayerVolume(2, 0)
	local n3 = babbleOf("nine ten eleven twelve")
	P1.PC.setPlayerVolume(2, 1)
	check(n1 > 0 and n2 > 0 and math.abs(v2 - v1 * 0.5) < 1e-6 and n3 == 0,
		string.format("babble: P2 at 50 %% plays at half the volume (%.3f vs %.3f); at 0 %% silent (%d sounds)", v2, v1, n3 or -1))
end)()

-- THE CONTROLLER'S CHAT (padui.lua, 2026-10-12): L3 + R3 opens it with the quick-chat wheel; R1 / L1 the highlight,
-- L2 / R2 the mode, the right stick scrolls, the left stick aims the wheel, A says, B closes
;(function()
	local M = P2
	M.device = 2
	M.LastInputDevice = function() return M.device end
	local function press(k) M.keys[k] = true; steps(1) end
	local function sticks() M.keys.zoom = true; steps(1); M.keys.zoom = true; steps(1) end
	waitRate(); M.PC.setMode("s")
	M.mouseX, M.mouseY = 0, 0
	press("zoom"); W.time = W.time + 0.2; press("zoom")
	check(M.PC.c.padUI and M.PC.c.typing and M.PC.c.padFocus == "chat" and drawn(M, "^Callouts  >$") and drawn(M, "^Left stick: aim$"),
		"L3, then L3 0.2 s later: the chat opens with the wheel (history, line and wheel: one selection)")
	check(drawn(M, "R1 / L1: chat, pages", true), "... the line below says what the buttons do")
	press("menu_next")
	check(M.PC.c.padFocus == "translate" and M.PC.c.nav and M.PC.page() == "translate", "R1: Translate")
	press("menu_next"); press("menu_next")
	check(M.PC.c.padFocus == "settings" and M.PC.page() == "settings", "R1, R1: Voice, then Settings")
	press("menu_next")
	check(M.PC.c.padFocus == "chat" and M.PC.c.typing and not M.PC.c.nav, "R1: round to the chat")
	press("menu_prev")
	check(M.PC.c.padFocus == "settings", "L1: back")
	press("menu_next")
	press("lmb")
	check(M.PC.mode() == "y", "R2: the mode up (Yell)")
	press("lmb"); press("lmb")
	check(M.PC.mode() == "w", "R2, R2: Global, then round to Whisper")
	press("rmb")
	check(M.PC.mode() == "g", "L2 on Whisper: round to Global")
	M.PC.setMode("s")
	-- the left stick moves the cursor: the DIRECTION it moves picks the slot, wherever the cursor is
	local function move(dx, dy, frames)
		for _ = 1, frames do M.mouseX, M.mouseY = M.mouseX + dx, M.mouseY + dy; steps(1) end
	end
	local function tapB() M.held = {menu_cancel = true}; M.keys.menu_cancel = true; steps(1); M.held = nil; steps(1) end
	local function heard(text)
		for _, e in ipairs(P1.PC.history()) do if e.p == M.me and e.text == text then return e end end
		return nil
	end
	M.mouseX, M.mouseY = 900, -400; steps(1)                         -- (far up and right of the wheel)
	check(M.PC.c.wheelSel == nil, "the cursor somewhere, not moving: nothing picked")
	move(0, 10, 4)
	check(M.PC.c.wheelSel == 5 and drawn(M, "^X: open$"), "the cursor moving DOWN (though it sits above the wheel): Players (slot 5)")
	move(10, 0, 6)
	check(M.PC.c.wheelSel == 3, "... then moving right: Replies (slot 3)")
	steps(10)
	check(M.PC.c.wheelSel == 3, "... the stick let go (the cursor still): still Replies")
	press("menu_accept")
	check(not M.PC.windowOpen(), "A with nothing on the line: closed (nothing sent)")
	sticks(); M.mouseX, M.mouseY = 0, 0; steps(1); move(10, 0, 6)
	press("interact")
	check(#M.PC.c.wheelPath == 1 and M.PC.c.wheelSel == nil and drawn(M, "^Replies$") and drawn(M, "^Yes$") and drawn(M, "^B: back$"),
		"X: into Replies - its name in the middle, its lines around, nothing picked")
	move(-10, 0, 6)
	check(M.PC.c.wheelSel == 7 and drawn(M, "^X: add$"), "... left: No (X: add)")
	tapB()
	check(#M.PC.c.wheelPath == 0 and M.PC.c.wheelSel == 3 and M.PC.windowOpen(), "... B: back to the main wheel, on the folder (not closed)")
	press("interact"); move(10, 0, 6); press("interact")
	check(M.PC.c.text == "Yes" and M.PC.windowOpen() and #M.PC.c.wheelPath == 0 and drawn(M, "^A: send$"),
		"... into it again, right: Yes - X adds it to the message, back on the main wheel")
	waitRate(); press("menu_accept"); steps(30)
	check(heard("Yes") and not M.PC.windowOpen(), "A: \"Yes\" sent (another player has it), the chat closed")
	-- a sentence across folders: Questions -> Where?, Objects -> Vehicle, a player's name; Y takes the last line back
	sticks()
	M.mouseX, M.mouseY = 0, 0; steps(1)
	move(10, -10, 4); press("interact")                             -- (up-right: Questions)
	move(10, 0, 6)
	check(M.PC.c.wheelSel == 3 and drawn(M, "^X: add$"), "Questions, right: Where? (X: add)")
	press("interact")
	check(M.PC.c.text == "Where?" and #M.PC.c.wheelPath == 0 and M.PC.c.wheelSel == nil, "... X: on the message, back on the main wheel")
	move(10, 10, 4); press("interact"); move(0, 10, 6); press("interact")   -- (down-right: Objects; down: Vehicle)
	check(M.PC.c.text == "Where? Vehicle", "Objects, down: Vehicle - the message is \"Where? Vehicle\"")
	move(0, 10, 6); press("interact")                               -- (down: Players, a list)
	check(M.PC.wheelKind(M.PC.c.wheelPath) == "players" and drawn(M, "^Players$") and drawn(M, "^" .. W.names[1] .. "$"),
		"Players: a list of the others")
	local others = M.PC.otherPlayers()
	press("menu_down")
	check(M.PC.c.listSel == math.min(2, #others), "... D-pad down: the next one")
	press("menu_up"); press("interact")
	check(M.PC.c.text == "Where? Vehicle " .. others[1].name and #M.PC.c.wheelPath == 0, "... X: the name on the message")
	press("mmb")
	check(M.PC.c.text == "Where? Vehicle" and M.PC.windowOpen(), "Y: the last added line back")
	move(0, -10, 6); press("interact"); move(0, -10, 6); press("interact")   -- (Callouts; up: Over here!)
	check(M.PC.c.text == "Where? Vehicle Over here!", "... a two-word line added")
	press("mmb")
	check(M.PC.c.text == "Where? Vehicle", "... Y: the whole line back (not one word)")
	move(0, 10, 6); press("interact")                               -- (into Players again)
	M.held = {menu_cancel = true}
	for _ = 1, 10 do W.time = W.time + 0.06; steps(1) end
	M.held = nil; steps(2)
	check(not M.PC.windowOpen() and not M.PC.c.padUI, "B HELD (in a folder, words on the message): cancelled, nothing sent")
	check(not heard("Where? Vehicle"), "... (the message dropped)")
	sticks()
	check(M.PC.windowOpen() and M.PC.c.text == "", "... the release after the hold was swallowed: the chat opens again fine, empty")
	M.mouseX, M.mouseY = 0, 0; steps(1)
	move(10, -10, 4); press("interact"); move(10, 0, 6); press("interact")   -- (Questions: Where?)
	move(10, 10, 4); press("interact"); move(0, 10, 6); press("interact")    -- (Objects: Vehicle)
	waitRate(); press("menu_accept"); steps(30)
	check(heard("Where? Vehicle") and not M.PC.windowOpen(), "A: \"Where? Vehicle\" sent")
	local mark, typedMark = heard("Where? Vehicle").pad, nil
	for _, e in ipairs(P1.PC.history()) do
		if e.p == M.me and e.text == "typed by hand" then typedMark = e.pad end
	end
	check(mark == true and not typedMark, "... said from the controller: it carries the controller mark (a typed line doesn't)")
	-- B on the main wheel cancels; Enter on a keyboard shows no wheel
	sticks(); tapB()
	check(not M.PC.windowOpen() and not M.PC.c.padUI, "B on the main wheel: cancelled")
	M.device = 1
	press("return")
	check(M.PC.c.typing and not M.PC.c.padUI and not drawn(M, "^Callouts  >$"), "a keyboard's Enter: the chat, no wheel")
	M.keys.esc = true; steps(2)
	-- /wheel
	waitRate(); say(M, "/wheel 3 Yes sir!"); steps(5)
	check(M.PC.wheelLine(3) == "Yes sir!" and M.reg["savegame.mod.pcwheel.3"] == "Yes sir!", "/wheel 3 <text>: a line changed (saved)")
	waitRate(); say(M, "/wheel 2.3 Sprint!"); steps(5)
	check(M.PC.wheelItem({2, 3}) == "Sprint!" and M.reg["savegame.mod.pcwheel.2.3"] == "Sprint!", "/wheel 2.3 <text>: a folder's line changed")
	waitRate(); say(M, "/wheel 1.8 Moods/"); steps(5)
	local t7, f7 = M.PC.wheelItem({1, 8})
	check(t7 == "Moods" and f7 and M.PC.wheelItem({1, 8, 1}) == nil, "/wheel 1.8 Moods/: the line is now an (empty) folder")
	waitRate(); say(M, "/wheel 1.8.1 Happy"); steps(5)
	check(M.PC.wheelItem({1, 8, 1}) == "Happy", "... /wheel 1.8.1 Happy: a line in it")
	waitRate(); say(M, "/wheel 2"); steps(5)
	local listed = false
	for _, e in ipairs(M.PC.history()) do if e.sys and e.text:find("2.3 Sprint!", 1, true) then listed = true end end
	check(listed, "/wheel 2: lists the folder's lines")
	waitRate(); say(M, "/wheel reset"); steps(5)
	check(M.PC.wheelLine(3) == "Replies" and M.PC.wheelItem({3, 3}) == "Yes" and M.PC.wheelItem({2, 3}) == "Where?"
		and M.PC.wheelItem({1, 8}) == "Watch out!", "/wheel reset: the defaults, folders too")
	M.LastInputDevice, M.device, M.mouseX, M.mouseY = nil, nil, nil, nil
end)()

-- proxchat.open (API 7, 2026-10-12): a game opens the chat - as Enter; on a controller with the wheel; cleared; block
-- doesn't stop it; an open chat stays as it is
;(function()
	local M = P2
	waitRate()
	M.reg["proxchat.block"] = true
	M.reg["proxchat.open"] = true; steps(2)
	check(M.PC.c.typing and M.PC.windowOpen() and not M.PC.c.padUI and M.reg["proxchat.open"] == nil and M.interactive,
		"proxchat.open: the chat opens (as Enter, even with proxchat.block), the key cleared")
	check(M.reg["proxchat.typing." .. M.me] == true, "... and proxchat.typing.<me> says so, for the game to step aside")
	M.PC.c.text = "half a line"
	M.reg["proxchat.open"] = true; steps(2)
	check(M.PC.c.typing and M.PC.c.text == "half a line" and M.reg["proxchat.open"] == nil, "... again while open: nothing changes")
	M.keys.esc = true; steps(2)
	M.reg["proxchat.block"] = nil
	M.device = 2
	M.LastInputDevice = function() return M.device end
	M.reg["proxchat.open"] = true; steps(2)
	check(M.PC.c.typing and M.PC.c.padUI and drawn(M, "^Callouts  >$"), "... on a controller: with the quick-chat wheel")
	M.held = {menu_cancel = true}; M.keys.menu_cancel = true; steps(1); M.held = nil; steps(1)
	check(not M.PC.windowOpen(), "... B closes it")
	M.LastInputDevice, M.device = nil, nil
	check(M.reg["proxchat.version"] == 16, "proxchat.version 16")
	-- proxchat.close (API 8): a game closes the chat; the line unsent is dropped
	M.keys["return"] = true; steps(2)
	M.PC.c.text = "never said"
	M.reg["proxchat.close"] = true; steps(2)
	local kept = false
	for _, e in ipairs(M.PC.history()) do if e.text == "never said" then kept = true end end
	check(not M.PC.windowOpen() and not kept and M.reg["proxchat.close"] == nil and M.reg["proxchat.typing." .. M.me] == false,
		"proxchat.close: closed, the unsent line dropped, the key cleared, typing false")
	M.reg["proxchat.close"] = true; steps(2)
	check(not M.PC.windowOpen() and M.reg["proxchat.close"] == nil, "... when closed: nothing, the key cleared")
	-- proxchat.key.*
	check(M.reg["proxchat.key.open"] == "Enter" and M.reg["proxchat.key.pad"] == "L3 twice" and M.reg["proxchat.key.talk"] == "",
		"proxchat.key.open / .pad: the names to show; .talk: \"\" without Koetama")
	-- a controller: the "..." only once the stick aims; the pages count as typing for games, without the "..."
	M.device = 2
	M.LastInputDevice = function() return M.device end
	local function dotsOn() return P1.PC.S().typing[M.me] ~= nil end
	M.keys.zoom = true; steps(1); M.keys.zoom = true; steps(3)
	check(M.PC.c.padUI and M.reg["proxchat.typing." .. M.me] == true and not dotsOn(),
		"a controller opens the chat: typing for games, but no \"...\" over the head yet")
	M.mouseX, M.mouseY = 0, 0; steps(1)
	for _ = 1, 4 do M.mouseX = M.mouseX + 10; steps(1) end
	steps(3)
	check(dotsOn(), "... the left stick aims: the \"...\" shows")
	M.keys.menu_next = true; steps(3)
	check(M.PC.c.nav and M.reg["proxchat.typing." .. M.me] == true and not dotsOn(),
		"... R1 to a page: still typing for games (the D-pad, A, B are the chat's), no \"...\"")
	M.keys.menu_cancel = true; steps(3)
	check(not M.PC.windowOpen() and M.reg["proxchat.typing." .. M.me] == false, "... B: closed, typing false")
	-- the HOST: its server writes the same key (pc_typing false when the pages open) - the client's "busy" still wins
	local H = P1
	H.device = 2
	H.LastInputDevice = function() return H.device end
	H.keys.zoom = true; steps(1); H.keys.zoom = true; steps(3)
	H.keys.menu_next = true; steps(10)
	check(H.PC.c.nav and H.reg["proxchat.typing." .. H.me] == true,
		"on the host, a controller on the chat's pages: proxchat.typing.<me> stays true (the server's false doesn't stick)")
	H.keys.menu_cancel = true; steps(3)
	check(not H.PC.windowOpen() and H.reg["proxchat.typing." .. H.me] == false, "... B: closed, false")
	H.LastInputDevice, H.device = nil, nil
	M.LastInputDevice, M.device, M.mouseX, M.mouseY = nil, nil, nil, nil
end)()

-- A TRANSLATED line: the original smaller (75 %), its translation full size under it (2026-10-16)
do
	local Lp = P1.PC.bubbleLayout(2, "hola amigos", false, 1, false, false, false, W.time)
	local Lt = P1.PC.bubbleLayout(2, "hola amigos", false, 1, false, false, false, W.time, false, "hello friends", W.time)
	check(Lp and Lt and Lt.tr and Lt.size == math.floor(Lp.size * 0.75 + 0.5) and Lt.tr.size == Lp.size,
		string.format("a bubble with a translation: the original at 75 %% (%s of %s), the translation full size (%s)",
			tostring(Lt and Lt.size), tostring(Lp and Lp.size), tostring(Lt and Lt.tr and Lt.tr.size)))
end

-- THE BUBBLE'S TAIL points where it comes from (2026-10-15): the side facing the source, slid along it, off the corners
do
	local PCm = P1.PC
	local function tail(lx, ly) local side, x, y = PCm.bubbleTail(300, 60, lx, ly); return side, x, y end
	local s1, x1, y1 = tail(150, 74)
	check(s1 == "bottom" and x1 == 150 and y1 == 60, "the speaker right under the bubble: the tail at the bottom middle (as before)")
	local s2, x2 = tail(40, 300)
	check(s2 == "bottom" and x2 < 150 and x2 >= 19.2, "the speaker below and to the left: the bottom, slid left (" .. x2 .. ")")
	local s3, _, y3 = tail(-500, 30)
	check(s3 == "left" and y3 == 30, "off to the left (a docked bubble, its speaker behind you on the left): the left side")
	local s4 = tail(900, 10)
	check(s4 == "right", "off to the right: the right side")
	local s5, x5 = tail(-400, -900)
	check(s5 == "top" and x5 == 19.2, "far above and to the left: the top, at its corner's edge (" .. x5 .. ")")
	-- a whole bubble: drawn with the tail where the layout says
	local L = PCm.bubbleLayout(P2.me, "hello", false, 1)
	check(L and L.sx and L.sy, "a bubble's layout keeps where it comes from (sx, sy)")
end

-- A GAME MOD'S MISTAKES (apicheck.lua, 2026-10-11): each a DebugPrint once, saying the key, what is wrong and the fix
;(function()
	local M = P1                                                      -- (the host: every proxchat.* key a game sets)
	local function said(pat)
		for _, d in ipairs(M.debug) do if d:find(pat) then return d end end
		return nil
	end
	local n0 = #M.debug
	M.reg["proxchat.ranges"] = "whisper=8 speek=30"
	M.reg["proxchat.device.walkie1"] = "radoi at=player:1"
	M.reg["proxchat.device.pa1"] = "pa at=1,2"
	M.reg["proxchat.device.mega"] = "megaphone at=player:1 chanel=red"
	M.reg["proxchat.effects.radio"] = "static=0.5 crunch=1"
	M.reg["proxchat.range"] = "8,25,40"
	M.reg["proxchat.channel.Bob"] = "dead"
	M.reg["proxchat.lobby"] = "yes"
	M.reg["proxchat.avoid.hud"] = "left top 300 200"
	steps(200)
	local r = said("proxchat%.ranges:")
	check(r and r:find('"speek" is not a range %(whisper, speak') and r:find("the rest is used"),
		"a wrong range name: said, with the names it takes (the rest still used): " .. tostring(r))
	check(said('proxchat%.device%.walkie1: "radoi at=player:1": starts with "radoi", not the kind: radio'),
		"a device's unknown kind: said, with the kinds")
	check(said('proxchat%.device%.pa1: .*at="1,2" is not at=player:<id>'), "a device's bad place: said, with the forms")
	local mg = said("proxchat%.device%.mega:")
	check(mg and mg:find('"chanel=red" is not channel=') and mg:find("the device works") and M.PC.S().dw.devs.mega ~= nil,
		"a device's unknown part (chanel=): said; the device still works")
	check(said('proxchat%.effects%.radio: .*"crunch" is not an effect %(pitch'), "an unknown effect: said, with the effects")
	check(said("proxchat%.range: the chat doesn't read this key %- did you mean proxchat%.ranges%?"), "a misspelt key: did you mean")
	check(said("proxchat%.channel%.Bob: the last part must be a player id"), "a player key by name, not id: said")
	check(said('proxchat%.lobby: "yes" reads as false %- set it with SetBool'), "a bool set as text: said")
	check(said('proxchat%.avoid%.hud: "left top 300 200" is not "x y width height"'), "a bad avoid rectangle: said")
	check(M.reg["proxchat.problem"] == M.debug[#M.debug], "proxchat.problem holds the last one (a mod can read it)")
	local n1 = #M.debug
	steps(200)
	M.reg["proxchat.avoid.hud"] = "left top 300 200"
	steps(10)
	check(#M.debug == n1, "each said once (" .. (n1 - n0) .. " problems, none again)")
	M.reg["proxchat.device.walkie1"] = "radio at=player:9 signal=lots"
	steps(10)
	check(#M.debug == n1 + 1 and said('signal="lots" is not a number 0..1'), "a new wrong value of the same key: said again")
	for k in pairs(M.reg) do
		if k:find("^proxchat%.") and (k:find("range$") or k:find("ranges") or k:find("%.device%.") or k:find("effects%.radio")
			or k:find("channel%.Bob") or k:find("lobby") or k:find("avoid")) then M.reg[k] = nil end
	end
	-- the cap: a broken mod can't fill the screen
	for i = 1, 40 do M.PC.problem("proxchat.test" .. i, "test") end
	check(#M.debug == M.PC.PROBLEM_MAX and M.debug[#M.debug]:find("no more of these this session"),
		"at most " .. M.PC.PROBLEM_MAX .. " in a session, the last one says so (" .. #M.debug .. ")")
	-- a Koetama with a newer protocol: this mod is the old one (said once, and on the Voice page)
	local vo = P2.PC.voice()
	vo.h.alive = true
	P2.PC.voiceMessage(vo, {type = "hello", app = "Koetama", version = "9.0.0", protocol = P2.PC.PROTOCOL + 1, features = {}})
	P2.PC.voiceMessage(vo, {type = "hello", app = "Koetama", version = "9.0.0", protocol = P2.PC.PROTOCOL + 1, features = {}})
	local nNewer = 0
	for _, e in ipairs(P2.PC.history()) do if e.sys and e.text == P2.PC.KOETAMA_NEWER then nNewer = nNewer + 1 end end
	check(P2.PC.koetamaNewer(vo) and nNewer == 1, "a Koetama with a newer protocol: \"" .. P2.PC.KOETAMA_NEWER .. "\" in the chat, once")
	P2.PC.voiceMessage(vo, {type = "hello", app = "Koetama", version = "0.5.4", protocol = P2.PC.PROTOCOL, features = {}})
	check(not P2.PC.koetamaNewer(vo), "... and not with this protocol")
end)()

-- ================================================================== pings (ping.lua, 2026-10-20): the middle mouse button,
-- L1 + R1 on a controller; a pin where the crosshair points, 5 s, for the pinger's team within their mode's reach (none in
-- Global); not from the dead. (Everyone within Speak's 25 m of each other here; the reach is tested further down.)
;(function()
	local ALL = {P1, P2, P3, P4, P5}
	local BASE = {Vec(0, 0, 0), Vec(4, 0, 0), Vec(10, 0, 0), Vec(16, 0, 0), Vec(20, 0, 0)}
	local function home() for i = 1, 5 do W.pos[i] = Vec(BASE[i][1], BASE[i][2], BASE[i][3]) end end
	home()
	for k in pairs(HOST.reg) do if k:find("^proxchat%.channel%.") or k:find("^proxchat%.team%.") or k:find("^proxchat%.lobby") then HOST.reg[k] = nil end end
	for _, M in ipairs(ALL) do
		if M.PC.c.typing then press(M, "esc") end
		if M.PC.c.nav then M.PC.setNav(false) end
		M.PC.c.pings = nil
	end
	W.boxes = {{lo = Vec(-100, -5, -21), hi = Vec(100, 30, -20)}}    -- (a wall 20 m ahead of everyone: the cameras look along -z)
	W.color, W.health = {}, {}
	steps(3)
	local function pins(M) return M.PC.c.pings or {} end
	local function who(list) local t = {}; for _, M in ipairs(list) do t[#t + 1] = #pins(M) end; return table.concat(t, " ") end
	local function clearPins() for _, M in ipairs(ALL) do M.PC.c.pings = nil end end
	local function nCalls() local n = 0; for _, cl in ipairs(W.clog or {}) do if cl.name == "pc_ping" then n = n + 1 end end; return n end
	-- the middle mouse button: everyone (no teams here) gets P2's pin, on the wall in front of P2's camera
	press(P2, "mmb"); steps(2)
	local pg = pins(P1)[1]
	check(who(ALL) == "1 1 1 1 1" and pg and pg.p == 2 and math.abs(pg.pos[1] - 4) < 1e-6 and math.abs(pg.pos[3] + 20) < 1e-6
		and math.abs(pg.pos[2] - 1.7) < 1e-6 and pg.name == "P2" and P2.rejected == 502,
		"the middle mouse button: a pin where P2's crosshair hits the wall (not P2's own body), for every player - no teams (" .. who(ALL) .. ")")
	check(P1.PC.PING_COLOR == pg.col and pg.col[1] == 1 and pg.col[2] == 1 and pg.col[3] == 1 and pg.mode == "s",
		"... a white ring (no team colour), its centre Speak's (P2's mode)")
	P1.uiSounds = {}; step()
	check(drawn(P1, "^P2$") and drawn(P1, "^20 m$") and #P1.uiSounds == 0, "drawn: the pinger's name and the distance (20 m from P1's head)")
	check(P3.PC.c.pings[1].fresh == nil, "... and its sound played once, when it came")
	steps(math.ceil(5.5 * 60))
	local PA = P1.PC.pingAlpha
	check(#pins(P1) == 1 and PA(4.9) == 1 and PA(5) == 1 and math.abs(PA(6.25) - 0.75) < 1e-9 and PA(7.5) == 0,
		"still there after 5.5 s: in full for 5 s, then fading slowly (eased) over 2.5 s - 75 % at 6.25 s")
	steps(150)
	check(#pins(P1) == 0 and not drawn(P1, "^P2$"), "gone after 7.5 s")
	-- nothing under the crosshair (the sky): no ping
	W.boxes = nil
	W.clog = {}
	waitRate(); press(P2, "mmb"); steps(2)
	check(#pins(P1) == 0 and nCalls() == 0, "nothing under the crosshair (the sky): no ping")
	W.boxes = {{lo = Vec(-100, -5, -21), hi = Vec(100, 30, -20)}}
	-- teams by the colour a game mode forces (mplib's team modes): red P1, P2; blue P3; P4, P5 none
	W.color[1], W.color[2], W.color[3] = {0.8, 0.25, 0.2}, {0.8, 0.25, 0.2}, {0.2, 0.55, 0.8}
	waitRate(); press(P1, "mmb"); steps(2)
	check(who(ALL) == "1 1 0 0 0" and pins(P2)[1].col[1] == 0.8 and pins(P2)[1].col[3] == 0.2,
		"team colours: P1's pin reaches P1 and P2 (red) only, in red (" .. who(ALL) .. ")")
	clearPins()
	waitRate(); press(P4, "mmb"); steps(2)
	check(who(ALL) == "0 0 0 1 1", "a player without a team: every player without one (P4, P5) (" .. who(ALL) .. ")")
	clearPins()
	-- a game's own pin colour (proxchat.pingcolor.<p>) wins over the team colour; 0..255 works too; a wrong one: said, ignored
	HOST.reg["proxchat.pingcolor.1"] = "0.1 0.9 0.3"
	waitRate(); press(P1, "mmb"); steps(2)
	local c1 = pins(P2)[1] and pins(P2)[1].col
	check(who(ALL) == "1 1 0 0 0" and c1 and math.abs(c1[1] - 0.1) < 1e-3 and math.abs(c1[2] - 0.9) < 1e-3 and math.abs(c1[3] - 0.3) < 1e-3,
		"proxchat.pingcolor.1 = \"0.1 0.9 0.3\": P1's pins in green (still only P1's team gets them)")
	clearPins()
	HOST.reg["proxchat.pingcolor.1"] = "255 128 0"
	waitRate(); press(P1, "mmb"); steps(2)
	c1 = pins(P2)[1] and pins(P2)[1].col
	check(c1 and c1[1] == 1 and math.abs(c1[2] - 128 / 255) < 1e-3 and c1[3] == 0, "\"255 128 0\": read as 0..255 (orange)")
	clearPins()
	HOST.PC.problems = {seen = {}, n = 0, scanT = -1e9}; HOST.debug = {}
	HOST.reg["proxchat.pingcolor.1"] = "green"
	waitRate(); press(P1, "mmb"); steps(2)
	c1 = pins(P2)[1] and pins(P2)[1].col
	check(c1 and c1[1] == 0.8 and table.concat(HOST.debug, " "):find('is not "r g b"', 1, true),
		"\"green\": said, and the team colour (red) instead")
	HOST.reg["proxchat.pingcolor.1"] = nil
	clearPins()
	-- proxchat.pingcolor (no player): everyone's pins; a player's own key wins over it
	HOST.reg["proxchat.pingcolor"], HOST.reg["proxchat.pingcolor.4"] = "1 1 1", "0 0 1"
	waitRate(); press(P1, "mmb"); press(P4, "mmb"); steps(2)
	local cw, cb = pins(P2)[1] and pins(P2)[1].col, pins(P5)[1] and pins(P5)[1].col
	check(cw and cw[1] == 1 and cw[2] == 1 and cw[3] == 1 and cb and cb[1] == 0 and cb[3] == 1,
		"proxchat.pingcolor \"1 1 1\": P1's pins white (over its team colour); P4's own pingcolor.4 (blue) wins over it")
	HOST.reg["proxchat.pingcolor"], HOST.reg["proxchat.pingcolor.4"] = nil, nil
	clearPins()
	-- proxchat.pinganon.<p> (API 16): P1's pins show no name, to anyone (P1 too); all else as ever
	HOST.reg["proxchat.pinganon.1"] = true
	waitRate(); press(P1, "mmb"); steps(2)
	check(who(ALL) == "1 1 0 0 0" and pins(P2)[1].name == "" and pins(P1)[1].name == "" and not drawn(P2, "^P1$") and drawn(P2, " m$"),
		"proxchat.pinganon.1: P1's pin with no name, for P2 and P1 alike (the distance still shown; still only P1's team) (" .. who(ALL) .. ")")
	clearPins()
	HOST.reg["proxchat.pinganon.1"] = false
	waitRate(); press(P1, "mmb"); steps(2)
	check(pins(P2)[1] and pins(P2)[1].name == "P1", "... false: the name again")
	HOST.reg["proxchat.pinganon.1"] = nil
	clearPins()
	-- team names from a game mod come first (tidied: case, spaces)
	HOST.reg["proxchat.team.1"], HOST.reg["proxchat.team.3"] = "Alpha", "  ALPHA "
	waitRate(); press(P1, "mmb"); steps(2)
	check(who(ALL) == "1 0 1 0 0", "proxchat.team.<p>: P1 and P3 both 'alpha' - P2 (red, no name) no more (" .. who(ALL) .. ")")
	clearPins()
	HOST.reg["proxchat.team.1"], HOST.reg["proxchat.team.3"] = nil, nil
	W.color = {}
	-- the dead can't ping: no health, or a game's channel; the lobby comes first
	W.health[5] = 0
	W.clog = {}
	waitRate(); press(P5, "mmb"); steps(2)
	check(who(ALL) == "0 0 0 0 0" and nCalls() == 0, "no health left: no ping (" .. who(ALL) .. ")")
	P5.PC.call("pc_ping", 20, 1.7, -20, "s"); steps(2)
	check(who(ALL) == "0 0 0 0 0", "... and a game that asks anyway: the host refuses")
	W.health[5] = nil
	HOST.reg["proxchat.channel.4"] = "dead"; steps(2)
	waitRate(); press(P4, "mmb"); steps(2)
	P4.PC.call("pc_ping", 16, 1.7, -20, "s"); steps(2)
	check(who(ALL) == "0 0 0 0 0", "dead (proxchat.channel.<p>): no ping (" .. who(ALL) .. ")")
	HOST.reg["proxchat.lobby"] = true; steps(2)
	waitRate(); press(P4, "mmb"); steps(2)
	check(#pins(P4) == 1, "... in the lobby, everyone is alive: a ping")
	clearPins()
	HOST.reg["proxchat.lobby"], HOST.reg["proxchat.channel.4"] = nil, nil; steps(2)
	-- proxchat.noping: nobody
	HOST.reg["proxchat.noping"] = true
	waitRate(); P1.keys.mmb = true; P3.keys.mmb = true; steps(3)
	check(who(ALL) == "0 0 0 0 0", "proxchat.noping: nobody can ping")
	HOST.reg["proxchat.noping"] = nil
	-- the chat has the keys (typing): the middle mouse button doesn't ping
	press(P2, "return"); step()
	waitRate(); press(P2, "mmb"); steps(2)
	check(#pins(P1) == 0, "typing: no ping")
	press(P2, "esc"); step()
	-- a controller: L1 + R1 together (scroll_up, scroll_down within 0.2 s); apart, or on the mouse (its wheel), nothing
	P2.LastInputDevice = function() return P2.device end
	P2.device = 2
	waitRate(); P2.keys.scroll_up = true; steps(5); P2.keys.scroll_down = true; steps(3)
	check(#pins(P1) == 1 and pins(P1)[1].p == 2, "a controller: L1, then R1 0.08 s later - a ping")
	clearPins()
	waitRate(); P2.keys.scroll_down = true; steps(1); P2.keys.scroll_up = true; steps(3)
	check(#pins(P1) == 1, "... R1 first works too")
	clearPins()
	waitRate(); P2.keys.scroll_up = true; steps(20); P2.keys.scroll_down = true; steps(3)
	check(#pins(P1) == 0, "... 0.33 s apart (two tool switches): no ping")
	P2.device = 0
	waitRate(); P2.keys.scroll_up = true; steps(1); P2.keys.scroll_down = true; steps(3)
	check(#pins(P1) == 0, "the mouse wheel up and down at once: no ping (a controller's chord only)")
	P2.LastInputDevice, P2.device = nil, nil
	-- the host checks: a forged token, a point far from the pinger, NaN; at most 3 at once, a player's 3 newest pins
	W.clog = {}
	waitRate()
	HOST.server.pc_ping(2, "0123456789abcdef0123456789abcdef", 4, 1.7, -20, "s"); steps(2)
	P2.PC.call("pc_ping", 4, 1.7, -2000, "s"); steps(2)
	P2.PC.call("pc_ping", 0 / 0, 1.7, -20, "s"); steps(2)
	P2.PC.call("pc_ping", 4, 1.7, -20, "g"); steps(2)
	P2.PC.call("pc_ping", 4, 1.7, -20); steps(2)
	check(#pins(P1) == 0 and nCalls() == 0, "the host refuses a wrong token, a point 2 km away, NaN, Global, no mode")
	waitRate(); steps(120)
	for i = 1, 6 do P2.PC.call("pc_ping", i, 1.7, -20, "s") end
	steps(2)
	local nNear = 0                                                    -- (the players within Speak's buffer + the slack)
	for _, q in ipairs(HOST.GetAllPlayers()) do
		if W.pos[q] and math.abs(W.pos[q][1] - 4) + math.abs(W.pos[q][3]) <= HOST.PC.cfg.mumbleR + HOST.PC.cfg.pingSlack then nNear = nNear + 1 end
	end
	check(#pins(P1) == 3 and nCalls() == 3 * nNear, "6 pings in one frame: the host takes 3 (a burst of 3) (" .. #pins(P1) .. ", " .. nCalls() .. " sends)")
	steps(60)
	P2.PC.call("pc_ping", 9, 1.7, -20, "s"); steps(2)
	local xs = {}
	for _, p in ipairs(pins(P1)) do xs[#xs + 1] = p.pos[1] end
	check(#pins(P1) == 3 and table.concat(xs, " ") == "2 3 9", "a 4th pin: the oldest of P2's goes (" .. table.concat(xs, " ") .. ")")
	-- THE REACH IS THE MODE'S (API 15). P2 (at 4) pings in Whisper (8 m, faded to 12): P1 (4 m) in full; P5 (10 m) faded
	-- (the buffer); P3 (26 m) is sent it (room to walk in) but sees nothing; P4 (56 m) isn't sent it. By the distance NOW to
	-- where P2 stood: P3 walking in sees it, P1 walking off sees it fade
	clearPins()
	W.pos[3], W.pos[4], W.pos[5] = Vec(30, 0, 0), Vec(60, 0, 0), Vec(14, 0, 0)
	P2.PC.setMode("w"); steps(2)
	waitRate(); press(P2, "mmb"); steps(2)
	local seen = function(M) local pgx = pins(M)[1]; return pgx and M.PC.pingSeen(pgx) or -1 end
	check(who(ALL) == "1 1 1 0 1" and seen(P1) == 1 and seen(P2) == 1 and math.abs(seen(P5) - 0.5) < 1e-6 and seen(P3) == 0
		and pins(P1)[1].mode == "w", string.format("Whisper (8 m, faded to 12): P1 (4 m) in full, P5 (10 m) faded to %.2f, P3 (26 m) sent but unseen, P4 (56 m) nothing (%s)",
		seen(P5), who(ALL)))
	P3.uiSounds = {}; step()
	check(drawn(P1, "^P2$") and not drawn(P3, "^P2$") and #P3.uiSounds == 0, "... drawn for P1, not for P3 (no sound either)")
	W.pos[3] = Vec(9, 0, 0); step()
	check(seen(P3) == 1 and drawn(P3, "^P2$") and #P3.uiSounds == 1, "P3 walks to 5 m from where P2 stood: the pin shows (its sound now)")
	W.pos[1] = Vec(-6, 0, 0); step()
	local s10 = seen(P1)
	W.pos[1] = Vec(-9, 0, 0); step()
	check(math.abs(s10 - 0.5) < 1e-6 and seen(P1) == 0 and not drawn(P1, "^P2$"),
		string.format("P1 walks away: 10 m - faded to %.2f; 13 m (past Whisper's 12) - gone", s10))
	W.pos[1], W.pos[3] = Vec(0, 0, 0), Vec(30, 0, 0); clearPins()
	-- Yell (40 m, faded to 55): P3 (26 m) in full, P4 (56 m) sent but past it; a "!" in the middle
	P2.PC.setMode("y"); steps(2)
	waitRate(); press(P2, "mmb"); steps(2)
	check(who(ALL) == "1 1 1 1 1" and seen(P3) == 1 and seen(P4) == 0 and pins(P1)[1].mode == "y" and drawn(P1, "^!$"),
		"Yell (40 m, faded to 55): P3 (26 m) in full, P4 (56 m) sent but unseen; a \"!\" in the pin (" .. who(ALL) .. ")")
	clearPins()
	-- a mod's own distances (proxchat.ranges) move the pins' too
	HOST.reg["proxchat.ranges"] = "whisper=20 speak=30 yell=50"; steps(2)
	P2.PC.setMode("w"); steps(2)
	waitRate(); press(P2, "mmb"); steps(2)
	check(seen(P5) == 1 and math.abs(seen(P3) - (30 - 26) / 10) < 1e-6,
		string.format("proxchat.ranges whisper=20: a whispered pin in full at 10 m, %.2f at 26 m (faded to 30)", seen(P3)))
	HOST.reg["proxchat.ranges"] = "whisper=8 speak=25 yell=40"; steps(2); clearPins()
	-- no pings in Global: said (at most every 3 s), nothing sent
	P2.PC.setMode("g"); steps(2)
	W.clog = {}
	local nSaid = function() local n = 0; for _, e in ipairs(hist(P2)) do if e.sys and e.text == P2.PC.NO_GLOBAL_PING then n = n + 1 end end; return n end
	waitRate(); press(P2, "mmb"); steps(2); press(P2, "mmb"); steps(2)
	check(who(ALL) == "0 0 0 0 0" and nCalls() == 0 and nSaid() == 1, "Global: no ping - \"" .. P2.PC.NO_GLOBAL_PING .. "\" (once for two presses)")
	-- the lobby: everyone (everything goes to everyone there), shown as Speak
	HOST.reg["proxchat.lobby"] = true; steps(2)
	waitRate(); press(P2, "mmb"); steps(2)
	check(who(ALL) == "1 1 1 1 1" and seen(P4) == 1 and pins(P4)[1].mode == "s", "the lobby: P4 (56 m) in full too, a Speak pin")
	HOST.reg["proxchat.lobby"] = nil; steps(2); clearPins()
	-- the dead see every ping (they hear everyone)
	P2.PC.setMode("s"); steps(2)
	HOST.reg["proxchat.channel.4"] = "dead"; steps(2)
	waitRate(); press(P2, "mmb"); steps(2)
	check(#pins(P4) == 1 and seen(P4) == 1, "a dead teammate 56 m away sees a Speak pin in full (the dead see every ping)")
	HOST.reg["proxchat.channel.4"] = nil; steps(2); clearPins()
	-- the gone keys (API 10's ping=, API 14's pingto): ignored quietly
	HOST.PC.problems = {seen = {}, n = 0, scanT = -1e9}; HOST.debug = {}
	HOST.reg["proxchat.ranges"], HOST.reg["proxchat.pingto.2"] = "ping=8", "1"; steps(150)
	waitRate(); press(P2, "mmb"); steps(2)
	check(who(ALL) == "1 1 1 0 1" and #HOST.debug == 0, "a mod still setting ping= or pingto: ignored, nothing said (" .. who(ALL) .. ")")
	HOST.reg["proxchat.ranges"], HOST.reg["proxchat.pingto.2"] = "whisper=8 speak=25 yell=40", nil; steps(2)
	home(); clearPins()
	-- a game steers the ray (API 12): proxchat.aim "x y z dx dy dz" (its own camera's view), proxchat.pingskip "body ..."
	-- (bodies the ray passes through); set every frame, read and cleared; unset - the player's camera again
	clearPins()
	P2.rejectedBodies = {}
	waitRate(); P2.reg["proxchat.aim"], P2.reg["proxchat.pingskip"] = "10 5 0 0 0 -2", "123 456"; press(P2, "mmb"); steps(2)
	local pa = pins(P1)[1]
	check(pa and math.abs(pa.pos[1] - 10) < 1e-6 and math.abs(pa.pos[2] - 5) < 1e-6 and math.abs(pa.pos[3] + 20) < 1e-6
		and table.concat(P2.rejectedBodies, " ") == "123 456" and P2.reg["proxchat.aim"] == nil and P2.reg["proxchat.pingskip"] == nil,
		"proxchat.aim: the pin on the game's ray (10, 5, -20), its pingskip bodies passed through, both keys cleared ("
		.. (pa and string.format("%.1f %.1f %.1f", pa.pos[1], pa.pos[2], pa.pos[3]) or "none") .. ")")
	clearPins(); steps(20)
	waitRate(); press(P2, "mmb"); steps(2)
	pa = pins(P1)[1]
	check(pa and math.abs(pa.pos[1] - 4) < 1e-6 and math.abs(pa.pos[2] - 1.7) < 1e-6, "no longer set (0.3 s): the player's own camera again")
	clearPins()
	P2.PC.problems = {seen = {}, n = 0, scanT = -1e9}; P2.debug = {}
	P2.reg["proxchat.aim"], P2.reg["proxchat.pingskip"] = "1 2 3", "12 abc"; step()
	local said = table.concat(P2.debug, " | ")
	check(said:find("proxchat.aim", 1, true) and said:find("x y z dx dy dz", 1, true) and said:find('"abc" is not a body handle', 1, true)
		and P2.reg["proxchat.aim"] == nil, "a wrong aim or skip list: said (what the form is), cleared")
	-- Settings' "Ping size": a slider 50 % .. 200 % (100 % at first); let go - saved, and a preview pin where you aim
	clearPins()
	say(P2, "/settings"); step()
	check(drawn(P2, "^Ping size$") and P2.PC.pingSize() == 1 and drawn(P2, "^100%%$"), "Settings: a 'Ping size' slider, 100 %")
	P2.hover = {400, 36, 5}; P2.keys.lmb = true; P2.held = {lmb = true}; P2.mouseX = 0; step(); P2.hover = nil
	check(P2.PC.pingSize() == 0.5 and drawn(P2, "^50%%$") and P2.reg["savegame.mod.pcpingsize"] == nil and #pins(P2) == 0,
		"dragged to the left end: 50 % at once, not saved yet")
	P2.held = nil; step()
	check(P2.reg["savegame.mod.pcpingsize"] == 0.5 and #pins(P2) == 1 and pins(P2)[1].preview and #pins(P1) == 0,
		"let go: saved; a preview pin where P2 aims - only on P2's screen")
	P2.hover = {400, 36, 5}; P2.keys.lmb = true; P2.held = {lmb = true}; P2.mouseX = 999; step(); P2.held = nil; step(); P2.hover = nil
	check(P2.PC.pingSize() == 2 and P2.reg["savegame.mod.pcpingsize"] == 2 and #pins(P2) == 1, "the right end: 200 % (one preview pin, the new one)")
	press(P2, "esc"); step()
	P2.PC.c.pingSize = nil
	check(P2.PC.pingSize() == 2, "read back from the save")
	P2.PC.setPingSize(1, true); clearPins()
	-- the API checker knows the keys
	HOST.reg["proxchat.team.2"], HOST.reg["proxchat.noping"] = "red", false
	HOST.debug = {}; steps(150)
	local said = table.concat(HOST.debug, " | ")
	check(not said:find("team", 1, true) and not said:find("noping", 1, true), "apicheck: proxchat.team.<p> and proxchat.noping are known keys (" .. said .. ")")
	HOST.reg["proxchat.team.2"], HOST.reg["proxchat.noping"] = nil, nil
	clearPins()
	W.boxes, W.color, W.health, W.clog = nil, nil, nil, nil
end)()

-- ================================================================== proxchat.noglobal (API 11, 2026-10-21): a game turns
-- Global chat off - the host refuses Global lines, the mode drops to Speak (said), Tab / L2 R2 / talk key + Tab skip it;
-- a channel's players (the dead) and the lobby are not affected
;(function()
	W.pos[1], W.pos[2], W.pos[3], W.pos[4], W.pos[5] = Vec(0, 0, 0), Vec(4, 0, 0), Vec(30, 0, 0), Vec(60, 0, 0), Vec(14, 0, 0)
	for k in pairs(HOST.reg) do if k:find("^proxchat%.channel%.") or k:find("^proxchat%.lobby") then HOST.reg[k] = nil end end
	for _, M in ipairs({P1, P2, P3, P4, P5}) do if M.PC.c.typing then press(M, "esc") end end
	steps(2)
	P2.PC.setMode("g"); step()
	check(P2.PC.mode() == "g" and P2.PC.voice().vmode == "g", "Global on: P2 picks Global (typing and talking)")
	HOST.reg["proxchat.noglobal"] = true; steps(3)
	local sysOff = 0
	for _, e in ipairs(hist(P2)) do if e.sys and e.text == P2.PC.NO_GLOBAL then sysOff = sysOff + 1 end end
	check(P2.PC.mode() == "s" and P2.PC.voice().vmode == "s" and sysOff == 1 and P1.PC.noGlobal(),
		"proxchat.noglobal: P2's Global drops to Speak (typing and talking), said once: \"" .. P2.PC.NO_GLOBAL .. "\"")
	P2.PC.setMode("y"); P2.PC.nextMode()
	check(P2.PC.mode() == "w", "Tab from Yell: Whisper (Global skipped)")
	P2.PC.setMode("w"); P2.PC.padModeStep(-1)
	check(P2.PC.mode() == "y", "a controller's L2 from Whisper: Yell (Global skipped, the other way round)")
	P2.PC.setMode("y"); P2.PC.nextVoiceMode()
	check(P2.PC.voice().vmode == "w", "talk key + Tab from Yell: Whisper")
	P2.PC.setMode("g")
	check(P2.PC.mode() == "w", "picking Global (a chip, a game): nothing changes")
	local n1 = #hist(P1)
	waitRate(); say(P2, "/g hello everyone"); steps(2)
	check(#hist(P1) == n1 and lastLine(P2).sys and lastLine(P2).text == P2.PC.NO_GLOBAL, "/g hello: refused on P2's own game, nothing sent")
	waitRate(); P2.PC.call("pc_say", "g", "a sneaky global", 1e6); steps(3)
	check(not hasLine(P1, "g", "a sneaky global") and not hasLine(P4, "g", "a sneaky global"), "a Global line sent anyway (a modified game): the host refuses it")
	-- the dead: their channel works whatever their mode
	HOST.reg["proxchat.channel.3"], HOST.reg["proxchat.channel.4"] = "dead", "dead"; steps(2)
	P4.PC.c.mode = "g"
	waitRate(); say(P4, "boo from the grave"); steps(2)
	check(hasLine(P3, "d", "boo from the grave") and P4.PC.mode() == "g" and not P4.PC.noGlobal(),
		"a dead player (a channel) on Global: their channel still gets it, their mode untouched")
	HOST.reg["proxchat.channel.3"], HOST.reg["proxchat.channel.4"] = nil, nil; steps(2)
	-- the lobby wins
	HOST.reg["proxchat.lobby"] = true; steps(2)
	waitRate(); say(P5, "lobby hello"); steps(2)
	check(hasLine(P4, "g", "lobby hello") and not P1.PC.noGlobal(), "the lobby (proxchat.lobby) wins: everything to everyone")
	HOST.reg["proxchat.lobby"] = nil; steps(3)
	-- the API checker knows the key; off again: Global is back
	HOST.debug = {}; steps(150)
	check(not table.concat(HOST.debug, " "):find("noglobal", 1, true), "apicheck: proxchat.noglobal is a known key")
	HOST.reg["proxchat.noglobal"] = nil; steps(2)
	P2.PC.setMode("g")
	check(P2.PC.mode() == "g" and not P2.PC.noGlobal(), "proxchat.noglobal cleared: Global can be picked again")
	waitRate(); say(P2, "/g back to all"); steps(2)
	check(hasLine(P4, "g", "back to all"), "... and Global lines reach everyone again")
	P2.PC.setMode("s"); step()
end)()

-- (as the game: a ServerCall / ClientCall works only with its function's name as a string LITERAL in the source -
--  "server." .. name was refused in-game 2026-10-10 and every chat line was lost; and the function must exist)
do
	local bad, missing = {}, {}
	for call, rest in SRC:gmatch("([SC][el][ri][ve][en][rt]Call)%s*(%b())") do
		if call == "ServerCall" or call == "ClientCall" then
			local name = call == "ServerCall" and rest:match('^%(%s*"(server%.[%w_]+)"%s*[,)]')
				or rest:match('^%([^,]+,%s*"(client%.[%w_]+)"%s*[,)]')
			if not name then
				bad[#bad + 1] = (call .. rest):sub(1, 60)
			elseif not SRC:find("function " .. name:gsub("%.", "%%.") .. "%(") then
				missing[#missing + 1] = name
			end
		end
	end
	check(#bad == 0, "every ServerCall / ClientCall names its function as a string literal: " .. (#bad == 0 and "all" or table.concat(bad, " | ")))
	check(#missing == 0, "and every such function exists: " .. (#missing == 0 and "all" or table.concat(missing, ", ")))
end

print(string.format("\n%d checks, %d failed", NCHECK, FAILED))
if FAILED > 0 then os.exit(1) end
