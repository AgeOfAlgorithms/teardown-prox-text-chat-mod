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
local W = {time = 0, pos = {}, names = {}, calls = {}, removed = {}}
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
	api.SetInt = function(k, v) env.reg[k] = math.floor(v) end
	api.GetInt = function(k) return tonumber(env.reg[k]) or 0 end
	api.SetString = function(k, v) env.reg[k] = tostring(v) end
	api.GetString = function(k) local v = env.reg[k]; if v == nil then return "" end return tostring(v) end
	api.ClearKey = function(k) for key in pairs(env.reg) do if key == k or key:sub(1, #k + 1) == k .. "." then env.reg[key] = nil end end end
	api.GetTime = function() return W.time end
	api.LoadSound = function(path) env.loads[#env.loads + 1] = path; return #env.loads end
	api.PlaySound = function(h, pos, vol, reg, pitch) env.sounds[#env.sounds + 1] = {h = h, pos = pos, vol = vol, pitch = pitch} end
	api.ServerCall = function(name, ...) W.calls[#W.calls + 1] = {name = name:match("^server%.(.+)$"), args = deep({...}), n = select("#", ...)} end
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
		"UiTextShadow", "UiScale", "UiRect", "UiRotate"}) do api[f] = function() end end
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
	api.UiWorldToPixel = function() return 500, 300, 10 end
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
	for _, c in ipairs(calls) do HOST.server[c.name](unpack(c.args, 1, c.n)) end
	HOST.server.tick(dt)
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
check(drawn(P2, "^Proximity Chat %- Enter: talk to players near you %(Tab: whisper / everyone%)") ~= nil, "intro hint on screen")

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
check(P2.PC.mode() == "w" and drawn(P2, "^Whisper %(5 m%): $"), "Tab: 'Whisper (5 m):' (the same frame)")
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
check(#hist(P3) == 0 and #hist(P4) == 0, "P3 (26 m) and P4 (56 m) did not get it, not even in history")
check(P1.PC.c.bubbles[2] and P1.PC.c.bubbles[2].text == "hello there" and not P1.PC.c.bubbles[2].whisper, "P1 has a normal speech bubble over P2")
check(drawn(P1, "^%[speak%] $") and drawn(P1, "^P2: $") and drawn(P1, "^hello there$"), "P1's feed: '[speak] P2: hello there'")
P1.sounds, P4.sounds = {}, {}
steps(60)
local nb = soundsFrom(P1, 4, "babble")
check(nb >= 4, "P1 hears the babble at P2's head (" .. nb .. " syllables)")
check(#P4.sounds == 0, "P4 hears no babble")
waitRate()
press(P2, "return"); typeText(P2, "second line\n"); step(); step()
check(lastLine(P1, "p").text == "second line" and not P2.PC.c.typing, "a newline returned by the field sends too")
waitRate()
say(P2, "please HELP me NOW")
check(lastLine(P1, "p").text == "please HELP me NOW", "P1 hears the whole shout")
local l3 = lastLine(P3, "p")
check(l3 and l3.text == "HELP ... NOW" and l3.far and l3.shout, "P3 (26 m) hears only the shouted words: " .. tostring(l3 and l3.text))
check(#hist(P4) == 0, "P4 (56 m) hears nothing")
waitRate()
say(P2, "everyone come HERE!!")
check(lastLine(P3, "p").text == "HERE!!", "a word ending in !! is shouted too")
W.pos[4] = Vec(8, 0, 0); steps(5)
check(#hist(P4) == 0, "P4 walked over later: still has not heard the old messages")
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
check(lw and lw.text == "psst the SECRET plan" and not lw.shout and P1.shared.pcMsgs[#P1.shared.pcMsgs].ch == "w", "P1 (4 m) gets the whole whisper; CAPS stay a whisper (no shout)")
check(not hasLine(P5, "w", "psst the SECRET plan") and not hasLine(P3, "w", "psst the SECRET plan") and #hist(P5, "w") == 0, "P5 (10 m) and P3 (26 m) get nothing, not even history")
check(hasLine(P2, "w", "psst the SECRET plan"), "the whisperer has it")
check(P1.PC.c.bubbles[2] and P1.PC.c.bubbles[2].whisper and not P1.PC.c.bubbles[2].shout, "P1 sees a whisper bubble (small, faint)")
check(drawn(P1, "^%[whisper%] $") ~= nil, "P1's feed marks it [whisper]")
steps(60)
local nw, vw = soundsFrom(P1, 4, "MOD/snd/whisper")
local nOther = #P1.sounds - nw
check(nw >= 4 and vw <= 0.451 and nOther == 0, string.format("whisper babble: breathy clips at P2's head, quiet (%d syllables, vol %.2f), no echo, no shout clips", nw, vw))
check(#P5.sounds == 0, "P5 (10 m) hears no whisper babble")
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
check(modes(P1) == "p p p p p w w g", "P1's history: nearby, whispers, everyone, in order: " .. modes(P1))
check(modes(P5) == "p p p p p g", "P5 (10 m): the nearby lines, no whispers: " .. modes(P5))
check(modes(P3) == "p p g", "P3 (26 m): two shouts and everyone: " .. modes(P3))
check(modes(P4) == "p g", "P4: what it heard while close + everyone: " .. modes(P4))
local n1 = #hist(P1)
steps(120)
check(#hist(P1) == n1, "no message is received twice although every shared read is a new table")
press(P1, "return"); step()
check(drawn(P1, "^%[speak%] $") and drawn(P1, "^%[whisper%] $") and drawn(P1, "^%[global%] $") and drawn(P1, "^psst the SECRET plan$") and drawn(P1, "^hi all$"),
	"P1's window shows one history with [speak] / [whisper] / [global] tags")
press(P1, "esc"); step()
check(not P1.PC.c.typing and not drawn(P1, "^Chat$") and not drawn(P1, "^Say "), "Esc closes the line and the window")

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
P2.hover = {300, 52, 6}; P2.keys.lmb = true; step()             -- (Robot)
P2.release = true; step()
P2.hover = nil
P2.PC.setVoice = setVoice0
steps(30)
check(picks == 1 and P1.shared.pcVoice[2] == 6 and P2.reg["savegame.mod.pcvoice"] == 6, "click Robot: one pick, synced to the server, saved as the default")
check(drawn(P2, "^Your voice: Robot", false) ~= nil, "Robot shown as yours")
local prev = 0
for _, s in ipairs(P2.sounds) do if math.abs(s.pos[1] - 4) < 0.01 and math.abs(s.pos[2] - 1.7) < 0.01 then prev = prev + 1 end end
check(prev >= 3, "a short preview at the listener (" .. prev .. " syllables)")
P2.hover = {300, 52, 2}; P2.release = true; step(); P2.hover = nil; steps(5)
check(P1.shared.pcVoice[2] == 2, "a release alone picks too (Chirpy)")
P2.hover = {300, 52, 4}; step(); P2.hover = nil; steps(5)
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
check(lastLine(P2).text:find("Unknown command", 1, true) ~= nil, "/mute is gone (Global has no babble to mute)")
say(P2, "/clear")
check(#hist(P2) == 0, "/clear empties your history")

-- ================================================================== bounds, scrolling, sanitizing
waitRate()
say(P2, "one"); say(P2, "two")
check(hasLine(P1, "p", "one") and not hasLine(P1, "p", "two"), "rate limit: a second line within 0.45 s is dropped")
for i = 1, 40 do waitRate(); P2.PC.say("line " .. i, "p"); step() end
for i = 1, 25 do waitRate(); P3.PC.say("g" .. i, "g"); step() end
step()
local h1 = hist(P1)
check(#h1 == 50 and h1[#h1].text == "g25" and h1[1].text == "line 16", "the history keeps the last 50 lines (both modes together)")
check(#P1.shared.pcMsgs <= 30, "shared keeps at most 30 messages (" .. #P1.shared.pcMsgs .. ")")
check(#hist(P3, "p") == 0 or lastLine(P3, "p").text ~= "line 40", "P3 (26 m) still got none of the nearby lines")
steps(60 * 14, 1 / 60)
check(#P1.shared.pcMsgs == 0 and #hist(P1) == 50, "shared messages expire; local histories stay")
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
check(PC.chatFont("\217\133\216\177\216\173\216\168\216\167") == "arial.ttf" and PC.chatFont("hello") == "bold.ttf" and PC.chatFont("hello", false) == "regular.ttf", "Arabic: arial.ttf; Latin: bold.ttf (whispers: regular)")
check(PC.chatVisual("\216\168\216\168") == "\239\186\144\239\186\145", "Arabic joined and laid right to left")
check(PC.chatVisual("\217\132\216\167") == "\239\187\187", "Arabic lam + alef ligature")
check(PC.chatVisual("hi \215\169\215\156\215\149\215\157") == "hi \215\157\215\149\215\156\215\169", "Hebrew right to left inside English")
check(PC.utf8Head("\208\150\208\150\208\150", 2) == "\208\150\208\150", "utf8Head never splits a letter")
waitRate()
P2.PC.say("\208\191\208\190\208\188\208\190\208\179\208\184\209\130\208\181 \208\159\208\158\208\156\208\158\208\147\208\152\208\162\208\149", "p"); step()
check(lastLine(P3, "p").text == "\208\159\208\158\208\156\208\158\208\147\208\152\208\162\208\149", "P3 at 26 m hears only the Cyrillic shouted word")
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
O.frame("Close")
check(O.closed, "Options: Close")
local P8 = addMachine(8, false, O.reg)
W.pos[8] = Vec(0, 0, -3)
steps(30)
check(P1.shared.pcVoice[8] == 6 and P8.PC.c.hideHint and not drawn(P8, "Enter: chat", true), "the Options settings are used in game (voice synced, hint hidden)")

print(string.format("\n%d checks, %d failed", NCHECK, FAILED))
if FAILED > 0 then os.exit(1) end
