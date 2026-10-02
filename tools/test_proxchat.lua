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
local W = {time = 0, pos = {}, names = {}, calls = {}, ccalls = {}, removed = {}, dropSay = 0}
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
	api.GetLocalPlayer = function() return me end
	api.GetPlayerTransform = function(p) if not W.pos[p] then return nil end return {pos = deep(W.pos[p])} end
	api.GetCameraTransform = function() return {pos = api.VecAdd(W.pos[me], Vec(0, 1.7, 0))} end
	api.GetPlayerName = function(p) return W.names[p] end
	api.GetRemovedPlayers = function() local r = W.removed; return r end
	api.SetBool = function(k, v) env.reg[k] = v and true or false end
	api.GetBool = function(k) return env.reg[k] == true end
	api.HasFile = function(f) return f == "MOD/fonts/pangolin.ttf" and not NO_FONT_FILE end
	api.SetInt = function(k, v) env.reg[k] = math.floor(v) end
	api.GetInt = function(k) return tonumber(env.reg[k]) or 0 end
	api.SetString = function(k, v) env.reg[k] = tostring(v) end
	api.SetFloat = function(k, v) env.reg[k] = tonumber(v) end
	api.GetFloat = function(k) return tonumber(env.reg[k]) or 0 end
	api.GetString = function(k) local v = env.reg[k]; if v == nil then return "" end return tostring(v) end
	api.ClearKey = function(k) for key in pairs(env.reg) do if key == k or key:sub(1, #k + 1) == k .. "." then env.reg[key] = nil end end end
	api.GetTime = function() return W.time end
	api.LoadSound = function(path) env.loads[#env.loads + 1] = path; return #env.loads end
	api.PlaySound = function(h, pos, vol, reg, pitch) env.sounds[#env.sounds + 1] = {h = h, pos = pos, vol = vol, pitch = pitch} end
	api.ServerCall = function(name, ...) W.calls[#W.calls + 1] = {name = name:match("^server%.(.+)$"), args = deep({...}), n = select("#", ...)} end
	api.ClientCall = function(p, name, ...) W.ccalls[#W.ccalls + 1] = {p = p, name = name:match("^client%.(.+)$"), args = deep({...}), n = select("#", ...)} end
	api.Players = function()
		local list, i = {}, 0
		for _, m in ipairs(MACHINES) do if W.pos[m.me] then list[#list + 1] = m.me end end
		return function() i = i + 1; return list[i] end
	end
	api.InputPressed = function(k) return env.keys[k] == true end
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
	for _, f in ipairs({"UiPush", "UiPop", "UiTranslate", "UiAlign", "UiColor", "UiRoundedRect", "UiRoundedRectOutline", "UiFont",
		"UiTextShadow", "UiScale", "UiRect", "UiRotate", "UiWindow"}) do api[f] = function() end end
	api.UiWordWrap = function(w) env.wrap = w end
	api.UiMakeInteractive = function() env.interactive = true end
	api.UiText = function(s) env.texts[#env.texts + 1] = s end
	api.UiGetTextSize = function(s)
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
	api.TransformToLocalPoint = function(t, p) return api.VecSub(p, t.pos) end
	api.TransformToParentVec = function(t, v) return v end
	api.QueryRaycast = function() return false, 0 end
	env.spawned, env.deleted = {}, {}
	api.Spawn = function(xml, t, static) env.spawned[#env.spawned + 1] = {xml = xml, t = t, static = static}; return {900 + #env.spawned} end
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
		env.shared = {}
	else
		env.shared = setmetatable({}, {
			__index = function(_, k) return deep(HOST.shared[k]) end,                  -- a fresh copy each read
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
		for _, m in ipairs(MACHINES) do
			if c.p == 0 or c.p == m.me then m.client[c.name](unpack(c.args, 1, c.n)) end
		end
	end
	W.removed = {}
	for _, m in ipairs(MACHINES) do
		m.client.tick(dt)
		m.texts, m.interactive, m.fieldCalled, m.mcount, m.bcount = {}, false, false, {}, {}
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
local clipsOk, nWhisper = #P2.loads == 32, 0
for _, p in ipairs(P2.loads) do
	local f = io.open(MODDIR .. p:gsub("^MOD/", ""), "rb")
	if f then f:close() else clipsOk = false; print("     missing clip " .. p) end
	if p:find("whisper") then nWhisper = nWhisper + 1 end
end
check(clipsOk and nWhisper == 12, "all 32 clips load from snd/ and exist (12 whisper / Robot-whisper)")
check(P2.shared.pcMsgs ~= P2.shared.pcMsgs and type(P2.shared.pcMsgs) == "table", "mock: every client read of shared is a fresh copy")
check(drawn(P2, "^Proximity Chat %- Enter: talk to players near you %(Tab: Whisper / Global%)") ~= nil, "intro hint on screen")

-- ================================================================== the input line: modes, chips, Tab
press(P2, "return")
check(P2.PC.c.typing and P2.interactive, "Enter opens the line (UiMakeInteractive: cursor)")
step()
check(P2.interactive and P2.focused, "while typing: interactive, the field has the keyboard")
check(P1.PC.isTyping(2) and P1.reg["proxchat.typing.2"] == true, "the server knows P2 types (PC.isTyping, registry proxchat.typing.2)")
check(drawn(P2, "^Speak: $") and drawn(P2, "^Speak$") and drawn(P2, "^Whisper$") and drawn(P2, "^Global$"), "the line: 'Speak:' and the three mode chips (Speak / Whisper / Global)")
check(drawn(P2, "^Chat$") and drawn(P2, "^Settings$") and not drawn(P2, "^Proximity$"), "the window: one history ('Chat'), a Settings button, no history tabs")
check(drawn(P1, "...", true) ~= nil and not drawn(P3, "^%.%.%.$"), "P1 (4 m) sees P2's '...' typing bubble, P3 (26 m) does not")
press(P2, "tab")
check(P2.PC.mode() == "w" and drawn(P2, "^Whisper %(8 m%): $"), "Tab: 'Whisper (8 m):' (the same frame)")
step()
check(P1.PC.s.typing[2] == "w" and P2.reg["savegame.mod.pcmode"] == "w", "the server knows P2 whispers; the mode is saved as P2's default")
press(P2, "tab")
check(P2.PC.mode() == "g" and drawn(P2, "^Global: $"), "Tab: 'Global:'")
typeText(P2, "\t"); step()
check(P2.PC.mode() == "p" and P2.PC.c.text == "" and drawn(P2, "^Speak: $"), "a Tab returned by the field: back to Speak (no tab character typed)")
P2.keys.tab = true; typeText(P2, "\t")
check(P2.PC.mode() == "w", "the Tab key and a field Tab in one frame move one mode, not two")
P2.hover = {104, 34, 3}; P2.keys.lmb = true; step()                -- (press on the 3rd chip: Global)
P2.release = true; step()                                       -- (its release: ignored)
P2.hover = nil
check(P2.PC.mode() == "g" and drawn(P2, "^Global: $"), "clicking the Global chip (press fires, release de-duplicated)")
P2.hover = {104, 34, 1}; P2.release = true; step(); P2.hover = nil
check(P2.PC.mode() == "p", "a release alone on the Nearby chip also works (UiBlankButton fallback)")
P2.hover = {104, 34, 2}; step(); P2.hover = nil
check(P2.PC.mode() == "p", "hovering a chip does not change the mode")

-- ================================================================== nearby: typing, sending, hearing
typeText(P2, "hellp")
typeText(P2, "\bo there")
check(P2.PC.c.text == "hello there", "UiTextInput returns the edited text, Backspace works (" .. P2.PC.c.text .. ")")
press(P2, "return")
check(not P2.PC.c.typing, "Enter says it and closes the line")
step()
local m = P1.shared.pcMsgs[#P1.shared.pcMsgs]
check(m and m.text == "hello there" and m.ch == "p" and m.p == 2 and m.name == "P2", "the message is shared as nearby")
check(hasLine(P1, "p", "hello there") and hasLine(P5, "p", "hello there") and hasLine(P2, "p", "hello there"), "P1 (4 m), P5 (10 m) and P2 itself have it")
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
check(lastLine(P1, "p").text == "second line" and not P2.PC.c.typing, "a newline returned by the field sends too")
waitRate()
say(P2, "please HELP me NOW")
check(lastLine(P1, "p").text == "please HELP me NOW", "P1 hears the whole shout")
local l3 = lastLine(P3, "p")
check(l3 and l3.text:find(" HELP ", 1, true) and l3.text:find(" NOW", 1, true) and garbled(l3.text) and l3.far and l3.shout, "P3 (26 m) reads the shouted words, the rest only in part: " .. tostring(l3 and l3.text))
check(#hist(P4) == 0, "P4 (56 m) hears nothing")
waitRate()
say(P2, "everyone come HERE!!")
check(lastLine(P3, "p").text:find(" HERE!!$") and garbled(lastLine(P3, "p").text), "a word ending in !! is shouted too")
waitRate()
P1.sounds = {}
say(P2, "come here now!")
check(lastLine(P3, "p").text:find(" now!$") and garbled(lastLine(P3, "p").text), "a single ! is enough: that word is shouted")
steps(60)
local nPlain, vPlain = soundsFrom(P1, 4, "babble")
local nShout, vShout = soundsFrom(P1, 4, "shout")
check(nPlain >= 2 and nShout >= 1 and vPlain <= 0.751 and vShout <= 0.801,
	string.format("shout volume: the shouted word at %.2f (cfg 0.8), the rest of the message stays at %.2f (a ! no longer raises it)", vShout, vPlain))
W.pos[4] = Vec(8, 0, 0); steps(5)
-- the event API: the host's registry gets every message (proxchat.said.*) for other mods (titans...)
local said = P1.reg["proxchat.said.last"]
local sk = "proxchat.said." .. (said % 16) .. "."
check(said and said >= 3 and P1.reg[sk .. "player"] == 2 and P1.reg[sk .. "mode"] == "speak" and P1.reg[sk .. "shout"] == true
	and P1.reg[sk .. "text"] == "come here now!" and P1.reg[sk .. "radius"] == 55 and P1.reg[sk .. "wordsRadius"] == 40
	and math.abs(P1.reg[sk .. "x"] - 4) < 0.01 and P1.reg[sk .. "lobby"] == false,
	"API: the host's registry has the event (proxchat.said.<n>: player 2, speak, shouted, at x = 4, words to 40 m, babble to 55 m)")
local pk = "proxchat.said." .. ((said - 1) % 16) .. "."
check(P1.reg[pk .. "text"] == "everyone come HERE!!" and P1.reg[pk .. "radius"] == 55, "API: the one before it is kept too (a ring of 16)")
check(P2.reg["proxchat.said.last"] == nil, "API: host only (clients do not run the server)")
check(#hist(P4) == 1 and lastLine(P4, "p").text == "come here now!", "P4 walked over while P2's last bubble was up: it shows, in full, and joins P4's history (older ones: no)")
waitRate()
say(P2, "now you are close")
check(lastLine(P4, "p").text == "now you are close", "P4 near P2 now: hears the new message")
W.pos[4] = Vec(60, 0, 0); steps(5)
check(lastLine(P4, "p").text == "now you are close", "P4 walked away: its history keeps what it heard")

-- ================================================================== whisper (5 m, no shouting, breathy)
steps(60 * 10)                                                   -- (the last bubbles and babble are over)
press(P2, "return"); press(P2, "tab")
check(P2.PC.mode() == "w", "P2 switches to whisper")
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
P1.server.pc_voice(2, 6)                                         -- (P2 picks Robot)
steps(2)
waitRate()
P1.sounds = {}
P2.PC.say("robot whisper", "w"); step(); steps(60)
local nr = soundsFrom(P1, 4, "rwhisper")
check(nr >= 3 and soundsFrom(P1, 4, "MOD/snd/whisper") == 0, "the Robot voice whispers with the crushed hiss clips (rwhisper, " .. nr .. ")")
P1.server.pc_voice(2, 5)
local q = {}
P1.PC.babbleSay(2, "abc", 1, "whisper"); q[1] = P1.PC.c.babble.queue[2].pitch
P1.PC.babbleSay(2, "abc", 5, "whisper"); q[2] = P1.PC.c.babble.queue[2].pitch
P1.PC.c.babble.queue[2] = nil
check(q[1] > 1.1 and q[2] < 0.9, string.format("the voice's pitch still shifts the whisper (Squeaky %.2f, Deep %.2f)", q[1], q[2]))

-- ================================================================== everyone
waitRate()
press(P3, "return"); press(P3, "tab"); press(P3, "tab")
check(P3.PC.mode() == "g" and drawn(P3, "^Global: $"), "P3: Tab twice = Global")
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
check(modes(P1) == "p p p p p p w w g", "P1's history: nearby, whispers, everyone, in order: " .. modes(P1))
check(modes(P5) == "p p p p p p w w g", "P5 (10 m): the Speak lines, the whispers garbled (its buffer), Global: " .. modes(P5))
check(modes(P3) == "p p p p p p g", "P3 (26 m, the buffer): every Speak line as far as it made it out, and Global: " .. modes(P3))
check(modes(P4) == "p p g", "P4: the bubble it walked into, what it heard while close, Global: " .. modes(P4))
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
check(P3.PC.c.bubbles[2].mumble and lastLine(P3, "p").text ~= "meet me at the tower", "P3 (26 m): no words in the history")
local function letters(t) local n = 0 for _ in t:gmatch("[a-z]") do n = n + 1 end return n end
local G = P3.PC.garble
local g0 = G("meet me at the tower!", 0, 7, 0)
check(letters(g0) == 0 and g0:find("!$") and select(2, g0:gsub(" ", " ")) == 4 and P3.PC.utf8Len(g0) == 21, "garble at 0: every letter a glyph; spaces, punctuation and length stay: " .. g0)
check(G("meet me at the tower!", 1, 7, 0) == "meet me at the tower!", "garble at 1: the message")
local function shown(t) local o, i = {}, 0 for ch in t:gmatch(P3.PC.UTF8_CHAR) do i = i + 1; if ch:find("[a-z]") then o[i] = true end end return o end
local a3, a6, sub = shown(G("meet me at the tower now", 0.3, 9, 0)), shown(G("meet me at the tower now", 0.6, 9, 5)), true
for i in pairs(a3) do if not a6[i] then sub = false end end
check(sub, "closer only adds letters (the same ones stay)")
check(G("come HERE now", 0, 9, 0, true):find(" HERE ", 1, true) ~= nil, "garble keeps shouted words readable")
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
check(b3 and not b3.mumble and b3.text == "meet me at the tower" and lastLine(P3, "p").text == "meet me at the tower" and #hist(P3) == n3,
	"P3 walks into range while the bubble is up: the words show; its garbled history line becomes the words")
steps(5)
check(#hist(P3) == n3, "... the same line, not a second one")
W.pos[3] = Vec(30, 0, 0)
waitRate()
say(P2, "/s the KEY is here")
check(lastLine(P3, "p").text:find(" KEY ", 1, true) and garbled(lastLine(P3, "p").text) and #hist(P3) == n3 + 1, "a shout from 26 m: the shouted word, the rest in part")
W.pos[3] = Vec(20, 0, 0); step(); step()
check(lastLine(P3, "p").text == "the KEY is here" and not lastLine(P3, "p").far and #hist(P3) == n3 + 1, "closer: that history line is completed (not a second one)")
W.pos[3] = Vec(44, 0, 0)                                            -- (40 m: past the buffer, within shouting)
waitRate()
say(P2, "/s please HELP me NOW")
local b40 = P3.PC.c.bubbles[2]
local X = "\226\172\154"
check(b40 and P3.PC.bubbleText(2, b40, W.time) == string.rep(X, 6) .. " HELP " .. string.rep(X, 2) .. " NOW" and not b40.text:find("...", 1, true),
	"35-40 m: the shouted words in place, every other word as boxes (no '...')")
-- the shouts' own buffer, 40-55 m: the shouted words garbled (more of them closer), the rest boxes
W.pos[3] = Vec(58, 0, 0)                                            -- (54 m)
waitRate()
say(P2, "/s come HERE RIGHT NOW")
local bs5 = P3.PC.c.bubbles[2]
local function upper(t) local n = 0 for _ in t:gmatch("[A-Z]") do n = n + 1 end return n end
local t54 = bs5 and P3.PC.bubbleText(2, bs5, W.time) or ""
check(bs5 and bs5.level == "shoutmumble" and bs5.shout and not bs5.hidden and garbled(t54) and letters(t54) == 0 and garbled(lastLine(P3, "p").text),
	"54 m: a red bubble with the shout garbled, a history line too: " .. t54)
W.pos[3] = Vec(50, 0, 0); step(); step()                            -- (46 m)
local t46 = P3.PC.bubbleText(2, bs5, W.time)
check(upper(t46) > upper(t54) and letters(t46) == 0 and upper(t46) < 12, "46 m: more of the shouted words, still not all; 'come' stays boxes: " .. t46)
W.pos[3] = Vec(44, 0, 0); step(); step()                            -- (40 m)
check(bs5.level == "shout" and P3.PC.bubbleText(2, bs5, W.time):find(" HERE RIGHT NOW$") and lastLine(P3, "p").text:find(" HERE RIGHT NOW$"),
	"40 m (within 40): the shouted words read in full; the same history line")
W.pos[3] = Vec(64, 0, 0)                                            -- (60 m: beyond 55)
waitRate()
say(P2, "/s ANYONE THERE")
check(P3.PC.c.bubbles[2] and P3.PC.c.bubbles[2].hidden and lastLine(P3, "p").text ~= "ANYONE THERE", "beyond 55 m: no shout at all")
-- the history keeps the most the listener made out
W.pos[3] = Vec(38, 0, 0)                                            -- (34 m: the buffer's far end)
waitRate()
say(P2, "/s we should climb the tower together")
local nh = #hist(P3)
local h34 = lastLine(P3, "p").text
W.pos[3] = Vec(31, 0, 0); step(); step()                            -- (27 m: closer)
local h27 = lastLine(P3, "p").text
W.pos[3] = Vec(38, 0, 0); step(); step()                            -- (back to 34 m)
local h34b = lastLine(P3, "p").text
local bb = P3.PC.c.bubbles[2]
check(#hist(P3) == nh and letters(h27) > letters(h34) and h34b == h27 and letters(P3.PC.bubbleText(2, bb, W.time)) < letters(h27),
	string.format("history: the most made out (34 m: %s, 27 m: %s, back at 34 m it keeps %s; the bubble shows less again)", h34, h27, h34b))
-- walking in on a message said out of earshot, while its bubble is up
W.pos[3] = Vec(44, 0, 0)                                            -- (40 m: beyond the buffer)
waitRate()
say(P2, "/s quietly now nobody hears this")
local bh = P3.PC.c.bubbles[2]
local nh2 = #hist(P3)
check(bh and bh.hidden and lastLine(P3, "p").text ~= "quietly now nobody hears this", "out of earshot: the bubble is kept, hidden, no history line")
W.pos[3] = Vec(34, 0, 0); step(); step()                            -- (30 m: into the buffer)
check(not bh.hidden and bh.mumble and #hist(P3) == nh2 + 1 and garbled(lastLine(P3, "p").text), "walking into the buffer while it is up: the bubble shows, garbled, and a history line starts")
W.pos[3] = Vec(24, 0, 0); step(); step()                            -- (20 m: in range)
check(bh.text == "quietly now nobody hears this" and lastLine(P3, "p").text == "quietly now nobody hears this" and #hist(P3) == nh2 + 1, "... and in range the words show; the same history line")
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
check(drawn(P2, "^Speech bubbles$") and drawn(P2, "^Babble volume$") and drawn(P2, "^25%%$"), "Settings: speech bubbles and babble volume, Off to 100%")
P2.hover = {90, 36, 3}; P2.keys.lmb = true; step(); P2.hover = nil          -- (speech bubbles: 50%)
P2.hover = {90, 36, 6}; P2.keys.lmb = true; step(); P2.hover = nil          -- (babble: Off)
check(P2.PC.c.bubbleLevel == 3 and P2.reg["savegame.mod.pcbubbles"] == 3 and P2.PC.c.babbleLevel == 1 and P2.reg["savegame.mod.pcbabblevol"] == 1,
	"picking bubbles 50% and babble Off (saved)")
P2.hover = {90, 36, 5}; P2.keys.lmb = true; step()
P2.hover = {90, 36, 10}; P2.keys.lmb = true; step(); P2.hover = nil
check(P2.PC.c.bubbleLevel == 5 and P2.PC.c.babbleLevel == 5, "... and back to 100%")
P2.hover = {120, 40, 6}; P2.keys.lmb = true; step(); P2.hover = nil          -- (your own bubble: Hide)
check(P2.PC.c.hideOwn and P2.reg["savegame.mod.pchideown"] == true, "your own bubble: Hide (saved)")
P2.hover = {120, 40, 5}; P2.keys.lmb = true; step(); P2.hover = nil          -- (Show)
check(not P2.PC.c.hideOwn, "... and Show")
press(P2, "esc"); step()
check(P2.PC.page() == "chat" and not drawn(P2, "^Chat$"), "Esc: closed (next time it opens on the history)")
P2.PC.setMode("p")

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
check(lastLine(P1, "w").text == "just us" and not hasLine(P5, "w", "just us") and P2.PC.mode() == "p", "/w <text>: one whisper, the mode stays nearby")
waitRate()
say(P2, "/g to all at once")
check(lastLine(P4, "g").text == "to all at once" and P2.PC.mode() == "p", "/g <text> goes to everyone, the mode stays")
say(P2, "/w")
check(P2.PC.mode() == "w" and lastLine(P2).text:find("Whisper", 1, true), "/w alone sets the whisper mode: " .. lastLine(P2).text)
say(P2, "/g")
check(P2.PC.mode() == "g", "/g alone: everyone")
say(P2, "/p")
check(P2.PC.mode() == "p" and P2.reg["savegame.mod.pcmode"] == "p", "/p alone: nearby (saved)")
waitRate()
say(P2, "//slash")
check(lastLine(P1, "p").text == "/slash", "//text sends a line starting with /")
say(P2, "/frobnicate")
check(lastLine(P2).text:find("Unknown command", 1, true) ~= nil, "unknown command echoed")
say(P2, "/help")
check(lastLine(P2).text:find("/s /w /g", 1, true) ~= nil, "/help lists commands")
say(P2, "/g"); say(P2, "/s")
check(P2.PC.mode() == "p" and P2.PC.page() ~= "settings", "/s switches to Speak (Settings is /settings)")
say(P2, "/hint"); step()
check(P2.PC.c.hideHint and not drawn(P2, "^Enter: chat$") and not drawn(P2, "^Proximity Chat %- Enter"), "/hint hides the hint (saved)")
say(P2, "/hint")
say(P2, "/mute")
check(lastLine(P2).text:find("Nobody is muted", 1, true) ~= nil, "/mute alone: who is muted")
say(P2, "/clear")
check(#hist(P2) == 0, "/clear empties your history")

-- ================================================================== bounds, scrolling, sanitizing
waitRate()
say(P2, "one"); say(P2, "two")
check(hasLine(P1, "p", "one") and not hasLine(P1, "p", "two"), "rate limit: a second line within 0.45 s is held back...")
steps(45)
check(hasLine(P1, "p", "two"), "... and gets in with the resend (not lost)")
for i = 1, 40 do waitRate(); P2.PC.say("line " .. i, "p"); step() end
for i = 1, 25 do waitRate(); P3.PC.say("g" .. i, "g"); step() end
step()
local h1 = hist(P1)
check(#h1 == 50 and h1[#h1].text == "g25" and h1[1].text == "line 16", "the history keeps the last 50 lines (both modes together)")
check(#P1.shared.pcMsgs <= 30, "shared keeps at most 30 messages (" .. #P1.shared.pcMsgs .. ")")
check(#hist(P3, "p") == 0 or lastLine(P3, "p").text ~= "line 40", "P3 (26 m) still got none of the nearby lines")
steps(60 * 32, 1 / 60)
check(#P1.shared.pcMsgs == 0 and #hist(P1) == 50, "shared messages expire (30 s); local histories stay")
press(P1, "return")
P1.values.mousewheel = 1; step()
P1.keys.pgup = true; step()
check(P1.PC.c.scroll == 5 and drawn(P1, "newer below", true), "wheel / PgUp scroll back (" .. P1.PC.c.scroll .. ")")
press(P1, "esc")
check(P1.PC.c.scroll == 0, "closing resets the scroll")
waitRate()
P2.PC.say("a\1b\127c   ", "p"); step()
check(lastLine(P1, "p").text == "a b c", "control bytes stripped, trimmed: '" .. lastLine(P1, "p").text .. "'")
waitRate()
P2.PC.say(string.rep("\208\150", 100), "p"); step()
local got = lastLine(P1, "p").text
check(P1.PC.utf8Len(got) == 90 and #got == 180, "90 characters, cut on a character boundary (" .. #got .. " bytes)")

-- ================================================================== every language
local PC = P1.PC
check(PC.isShout("\208\159\208\158\208\156\208\158\208\147\208\152\208\162\208\149") and not PC.isShout("\208\191\208\190\208\188\208\190\209\137\209\140"), "Cyrillic: ПОМОГИТЕ shouts, помощь does not")
check(PC.isShout("\206\148\206\145") and PC.isShout("\228\189\160\229\165\189\239\188\129\239\188\129"), "Greek capitals shout; Chinese ending in ！！ shouts")
check(#PC.babbleSyllables("\228\189\160\229\165\189\229\144\151") == 3 and PC.chatFont("\228\189\160\229\165\189\229\144\151") == "bold_sc.ttf", "Chinese: a syllable per character, the Chinese font")
check(#PC.babbleSyllables("\227\129\147\227\130\147\227\129\171\227\129\161\227\129\175") == 5 and PC.chatFont("\227\129\147\227\130\147\227\129\171\227\129\161\227\129\175") == "bold_jp.ttf", "Japanese: a syllable per kana, the Japanese font")
check(PC.chatFont("\236\149\136\235\133\149") == "bold_sc.ttf", "Korean: a font with Hangul")
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
P2.PC.say("\208\191\208\190\208\188\208\190\208\179\208\184\209\130\208\181 \208\159\208\158\208\156\208\158\208\147\208\152\208\162\208\149", "p"); step()
check(lastLine(P3, "p").text:find(" \208\159\208\158\208\156\208\158\208\147\208\152\208\162\208\149$") and lastLine(P3, "p").text:find("\226\172\154", 1, true), "P3 at 26 m reads the Cyrillic shouted word, the rest in part")
waitRate()
P2.PC.say("\208\159\208\158\208\156\208\158\208\147\208\152\208\162\208\149", "w"); step()
check(lastLine(P1, "w").text == "\208\159\208\158\208\156\208\158\208\147\208\152\208\162\208\149" and lastLine(P3, "w") == nil, "a Cyrillic CAPS whisper stays a whisper (P3 gets nothing)")

-- ================================================================== registry integration (another mod / game mode)
local hookLobby = P1.PC.hooks.inLobby
P1.reg["proxchat.lobby"] = true; step(); step()
check(P2.PC.mode() == "g", "a game sets proxchat.lobby: everyone hears everything")
P1.reg["proxchat.lobby"] = false; step(); step()
check(P2.PC.mode() == "p", "proxchat.lobby back to false: own mode again")
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
P2.hover = {104, 34, 2}; P2.keys.lmb = true; step(); P2.hover = nil
check(P2.PC.mode() == "g", "lobby: the Whisper chip is disabled")
waitRate()
typeText(P2, "lobby hello"); press(P2, "return"); step()
check(lastLine(P4, "g").text == "lobby hello" and P1.shared.pcMsgs[#P1.shared.pcMsgs].ch == "g", "lobby: everything is everyone")
waitRate()
P2.PC.say("sneaky", "w"); step()
check(P1.shared.pcMsgs[#P1.shared.pcMsgs].ch == "g", "lobby: the server turns a whisper into everyone")
P1.PC.hooks.inLobby = nil
step(); step()
check(P2.PC.mode() == "p", "out of the lobby: back to the player's own mode")
P4.PC.hooks.everyoneHears = function(speaker) return true end
waitRate()
P2.PC.say("radio check", "p"); step()
check(lastLine(P4, "p").text == "radio check" and lastLine(P3, "p").text ~= "radio check", "everyoneHears hook: P4 hears nearby lines far away, P3 does not")
waitRate()
P2.PC.say("radio whisper", "w"); step()
check(lastLine(P4, "w") == nil, "... but whispers still need 5 m")
P4.PC.hooks.everyoneHears = nil
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
P1.server.pc_voice(3, 4)
W.removed = {3}
HOST.server.tick(0)
check(not P1.PC.isTyping(3) and P1.shared.pcVoice[3] == nil and P1.reg["proxchat.typing.3"] == false, "a player who leaves is cleaned up (typing, voice)")
W.removed = {}
waitRate()
P2.PC.say("before you came", "g"); step()
waitRate()
P2.PC.say("nearby before you came", "p"); step()
W.pos[7] = Vec(6, 0, 0)
local P7 = addMachine(7, false)
step()
check(hasLine(P7, "g", "before you came") and #hist(P7, "p") == 0, "a joiner gets recent everyone lines, not old nearby talk")

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
check(otext("Speak / Whisper / Global") and otext("Not picked"), "Options: explains the keys; no voice picked yet")
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
waitRate(); say(P2, "/s COME BACK HERE")
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
check(not hasLine(P1, "p", "lost on the way"), "a message lost on the way: not there yet")
steps(40)
check(hasLine(P1, "p", "lost on the way") and #P2.PC.c.outbox == 0, "... resent and confirmed: everyone has it, the outbox is empty")
local nAll = #hist(P1)
HOST.server.pc_say(2, "p", "lost on the way", P2.PC.c.seq)                -- (a late duplicate of the resend)
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
P1.PC.receive({id = 990002, p = 2, name = "P2", ch = "p", text = "said long ago", t = now0 - 20})
check(hasLine(P1, "p", "said long ago") and (not P1.PC.c.bubbles[2] or P1.PC.c.bubbles[2].full ~= "said long ago") and #P1.sounds == 0,
	"20 s late: in the history only (no bubble, no babble)")
P1.PC.receive({id = 990003, p = 2, name = "P2", ch = "p", text = "a bit late this one", t = now0 - 3})
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
check(not hasLine(P1, "p", "can you hear me") and not P1.PC.c.bubbles[2] and hasLine(P5, "p", "can you hear me"),
	"/mute p2: nothing of P2's (bubble, history) - only for P1")
say(P1, "/mute")
check(lastLine(P1).text:find("Muted (only for you): P2", 1, true) ~= nil, "/mute lists who is muted")
say(P1, "/unmute all")
waitRate(); say(P2, "/s and now")
check(hasLine(P1, "p", "and now"), "/unmute all: heard again")
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
P1.PC.setBubbleLevel(1); P1.PC.setBabbleLevel(1)
P1.sounds = {}
waitRate(); say(P2, "/s can you see this")
steps(30)
check(hasLine(P1, "p", "can you see this") and #(P1.PC.c.bubbleRects or {}) == 0 and #P1.sounds == 0,
	"bubbles Off and babble Off: only the chat line (no bubble, no sound)")
P1.PC.setBubbleLevel(2); P1.PC.setBabbleLevel(2)
P1.sounds = {}
waitRate(); say(P2, "/s and now at a quarter")
steps(40)
local nq, vq = soundsFrom(P1, 4, "babble")
check(#(P1.PC.c.bubbleRects or {}) >= 1 and drawn(P1, "^and now at a quarter$") and nq >= 2 and vq <= 0.75 * 0.25 + 1e-6,
	string.format("bubbles 25%% (still drawn, the text too) and babble 25%% (vol %.3f)", vq))
P1.PC.setBubbleLevel(5); P1.PC.setBabbleLevel(5)

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
check(LD(4, 35) == 1 and math.abs(LD(35, 35) - 0.35) < 1e-9 and math.abs(LD(55, 55) - 0.35) < 1e-9 and LD(20, 35) > LD(30, 35) and LD(20, 35) > 0.6,
	string.format("loudness: full up close, gently down to 35%% at the edge of the reach (20 m of 35: %.2f, 30 m: %.2f)", LD(20, 35), LD(30, 35)))
check(LD(45, 55) > LD(30, 35), "a shout 45 m away is louder than speech 30 m away (each by its own reach)")

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
check(Lnear and Lfar and math.abs(Lnear.right - (1920 - 8)) < 1 and Lnear.s > Lfar.s,
	string.format("on the edge: right at the border (8 px), still sized by distance (4 m: %.2f, 30 m: %.2f)", Lnear.s, Lfar.s))
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
check(#names == 3 and names[1]:find("^Whisperer %(") and names[2]:find("^Speaker %(") and names[3]:find("^Shouter %(") and names[1] ~= names[2]:gsub("Speaker", "Whisperer"),
	"history: Whisperer / Speaker / Shouter, each in another voice: " .. table.concat(names, ", "))
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
check((not bw or bw.hidden) and bs and bs.mumble and bh and bh.level == "shout" and P1.PC.bubbleText(DH, bh, 0) == L2[2],
	"from 28 m: no whisper, the speaker garbled, the shouter readable (all shouted)")
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
check(D2 and #D2.list == 1 and D2.list[1].kind == "p" and D2.byP[DS] and math.abs(D2.list[1].pos[3] + 3) < 0.01 and #P1.spawned == nsp + 1,
	"/dummy 2: just the speaker, 3 m in front of you")
W.pos[1] = Vec(0, 0, 6)
say(P1, "/dummy 3")
say(P1, "/dummy 2")                                                          -- (again: moved to the new spot)
local D3 = P1.PC.c.dummy
check(#D3.list == 2 and D3.list[1].kind == "p" and D3.list[2].kind == "s" and math.abs(D3.byP[DS].pos[3] - 3) < 0.01 and P1.deleted[nsp + 901],
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

print(string.format("\n%d checks, %d failed", NCHECK, FAILED))
if FAILED > 0 then os.exit(1) end
