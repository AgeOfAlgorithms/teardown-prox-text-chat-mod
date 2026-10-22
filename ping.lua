-- ping.lua - PINGS (the user, 2026-10-20): the middle mouse button, or L1 + R1 together on a controller, puts a pin where
-- the crosshair points, for cfg.pingLife s. Only the pinger's team sees it; dead players can't ping.
-- TEAMS (the game tells a mod nothing about them: a game mode keeps its teams in its own script's shared table):
--   1. proxchat.team.<p> - a team name a game mod sets on the host (API.md);
--   2. else the colour a game mode forces on the player: the game's team modes colour every player in their team's
--      colour every tick (data/script/mp/lib/teams.lua: SetPlayerColor) - the same colour is the same team;
--   3. else no team: every player without one sees it (sandbox, free for all - the user, 2026-10-20: "Everyone").
-- TWO COLOURS (2026-10-21): the ring is the team's / a mod's (proxchat.pingcolor.<p>, else proxchat.pingcolor, else the
-- forced team colour, else white); the centre and the distance are the MODE's (Whisper lavender, Speak yellow, Yell
-- orange - PC.modeInfo), a Whisper pin smaller, a Yell pin with a "!".
-- NO NAME: proxchat.pinganon.<p> (a game's, true every tick - API 16, Witch Hunt: a spirit has no name for humans, so
-- her pins mustn't carry it): p's pins show no name to anyone (the pinger too); all else as ever.
-- DEAD: in a channel (proxchat.channel.<p>: a game's dead) or no health left. A game turns pings off with
-- proxchat.noping (a free-for-all mode where pins would give players away).
-- THE BUTTONS (2026-10-20): every pad button has a job in play, and a mod can't take one from the game. L1 / R1 are the
-- tool scroll up / down, so both at once step back and forth to the same tool: nothing stays changed (long L3 left the
-- zoom on, R3 is the scoreboard toggle, the D-pad switches tools). Pad only: a quick up-and-down mouse wheel is no chord.
-- REACH = THE MODE'S (the user, 2026-10-21: "ping message distances should follow whisper, speak, and yell distances"):
-- a ping goes out in the pinger's mode; a teammate within that mode's range of where the pinger stood sees the pin in
-- full, across its buffer it fades out with the distance, past that nothing (a mod changes it with proxchat.ranges, as
-- the talk). By the listener's distance NOW (walking in shows it, walking away fades it). No pings in Global ("No pings
-- in Global" said; the host refuses one); the lobby: everyone (everything goes to everyone there). The dead (a channel)
-- see every ping, as they hear everyone. (Gone the same day: proxchat.ranges "ping=<m>" and proxchat.pingto.<p>, API 10
-- and 14 - a mod's keys for them are ignored quietly; a hidden witch must take care whom she pings near.)
-- The host checks every ping (a real player with their token, alive, a mode, at most cfg.pingRate a second, a point
-- within reach of them) and sends it to the teammates within the mode's buffer and cfg.pingSlack (room to walk in) - by
-- client.pc_ping, never in shared.

do
	local defaults = {
		pingLife = 5,            -- s a pin stays in full
		pingFade = 2.5,          -- s it then takes to fade out (slowly: the user, 2026-10-20)
		pingSizeMin = 0.5,       -- Settings' "Ping size": 50 % .. 200 % (savegame.mod.pcpingsize)
		pingSizeMax = 2,
		pingMax = 300,           -- m: how far a ping reaches (the crosshair's ray)
		pingRate = 2,            -- pings a second a player may make (a burst of pingBurst)
		pingBurst = 3,
		pingPer = 3,             -- pins of one player at once (a new one pushes their oldest out)
		pingSlack = 15,          -- m past the buffer the host still sends a pin to (room to walk in while it is up)
	}
	for k, v in pairs(defaults) do
		if PC.cfg[k] == nil then PC.cfg[k] = v end
	end
end
PC.PING_CHORD = 0.2                                                  -- s: L1 and R1 count as pressed together within this
PC.PING_COLOR = {1, 1, 1}                                            -- (a ring without a team / mod colour: white - the
                                                                     --  mode's colour is the centre's)
PC.PING_MODE_SIZE = {w = 0.8, s = 1, y = 1.15}                       -- (a Whisper pin smaller, a Yell pin bigger)
PC.NO_GLOBAL_PING = "No pings in Global: switch to Whisper, Speak or Yell."
PC.PING_SOUND = "ui/hud/location.ogg"                                -- (the game's map-marker sound)

-- ---- the host

-- (server) p's team: "t:<name>" (proxchat.team.<p>), "c:<r,g,b>" and that colour (a game's team colour), or nil
function PC.teamOf(p)
	local v = PC.utf8Head(PC.clean(GetString(PC.cfg.reg .. ".team." .. p)), 24):lower()
	if v ~= "" then return "t:" .. v end
	if GetPlayerColor then
		local ok, inuse, r, g, b = pcall(GetPlayerColor, p)
		r, g, b = PC.finite(r), PC.finite(g), PC.finite(b)
		if ok and inuse == true and r and g and b then
			return string.format("c:%.2f,%.2f,%.2f", r, g, b), {r, g, b}
		end
	end
	return nil
end

-- (server) the colour a game gives p's pins (API 13, 2026-10-21: "maybe some mods want different colored pings for
-- different teams" - "shouldn't be restricted to per team"): proxchat.pingcolor.<p> (any player any colour), else
-- proxchat.pingcolor (everyone's pins); "r g b", 0..1 as SetPlayerColor (0..255 too). nil: neither (a wrong one is said
-- and ignored)
local function colorKey(key)
	local v = GetString(key)
	if v == "" then return nil end
	local t = {}
	for x in v:gmatch("[^%s,]+") do t[#t + 1] = PC.finite(x) end
	if #t == 3 and t[1] and t[2] and t[3] and t[1] >= 0 and t[2] >= 0 and t[3] >= 0 then
		local k = (t[1] > 1 or t[2] > 1 or t[3] > 1) and 255 or 1     -- (0..255 given: scaled)
		if t[1] <= k and t[2] <= k and t[3] <= k then return {t[1] / k, t[2] / k, t[3] / k} end
	end
	if PC.problem then PC.problem(key, PC.problemValue(v) .. ' is not "r g b" (0 to 1 each, e.g. "1 0.2 0.2") - ignored') end
	return nil
end

function PC.pingColorOf(p)
	local reg = PC.cfg.reg
	return colorKey(reg .. ".pingcolor." .. p) or colorKey(reg .. ".pingcolor")
end

-- (server) p can't ping now: dead (a game's channel, or no health) - the lobby comes first (nobody is dead there)
function PC.pingDead(p)
	if PC.inLobby() then return false end
	if PC.S().chan[p] then return true end
	if GetPlayerHealth then
		local ok, h = pcall(GetPlayerHealth, p)
		h = ok and PC.finite(h)
		if h and h <= 0 then return true end
	end
	return false
end

-- a player pings the point x, y, z in their mode (w / s / y): checked, then sent to their team (themselves too) within
-- the mode's reach
function server.pc_ping(p, tok, x, y, z, mode)
	local cfg = PC.cfg
	p = PC.who(p, tok)
	if not p then return end
	x, y, z = PC.finite(x), PC.finite(y), PC.finite(z)
	if not (x and y and z) then return end
	local lobby = PC.inLobby()
	if lobby then mode = "s"                                             -- (the lobby: everyone, shown as Speak)
	elseif mode ~= "w" and mode ~= "s" and mode ~= "y" then return end  -- (Global, or none: no ping)
	if GetBool(cfg.reg .. ".noping") or PC.pingDead(p) then return end
	local okT, tr = pcall(GetPlayerTransform, p)
	if not (okT and tr and tr.pos) then return end
	if VecLength(VecSub(Vec(x, y, z), tr.pos)) > cfg.pingMax + 10 then return end   -- (from where they stand, give or take
	if not PC.allow(p, "ping", cfg.pingRate, cfg.pingBurst) then return end         --  the camera: no pins across the map)
	local s = PC.S()
	local anon = GetBool(cfg.reg .. ".pinganon." .. p)                  -- (no name on p's pins: a game's)
	local team, col = PC.teamOf(p)
	col = PC.pingColorOf(p) or col                                       -- (a game's own colour first)
	local colS = col and string.format("%.3f,%.3f,%.3f", col[1], col[2], col[3]) or ""
	local reachS, sendTo = "", nil                                       -- (the mode's reach: where the pinger stood, inner,
	if not lobby then                                                    --  outer; the lobby: everyone)
		local inner, outer = PC.rangeOf(mode)
		reachS = string.format("%.2f,%.2f,%.2f,%g,%g", tr.pos[1], tr.pos[2], tr.pos[3], inner, outer)
		sendTo = outer + cfg.pingSlack
	end
	for _, q in ipairs(PC.allPlayers()) do
		if PC.teamOf(q) == team then
			local near = q == p or not sendTo or s.chan[q] ~= nil             -- (the dead see every ping)
			if not near then
				local okQ, tq = pcall(GetPlayerTransform, q)
				near = okQ and tq and tq.pos and VecLength(VecSub(tq.pos, tr.pos)) <= sendTo
			end
			if near then ClientCall(q, "client.pc_ping", p, x, y, z, colS, reachS, mode, anon) end
		end
	end
end

-- ---- each player's game

-- numbers from a "a,b,c" string (nil: not n finite numbers)
local function numbers(str, n)
	if type(str) ~= "string" or #str > 200 then return nil end
	local t = {}
	for x in str:gmatch("[^,]+") do t[#t + 1] = PC.finite(x) end
	if #t ~= n then return nil end
	for i = 1, n do if not t[i] then return nil end end
	return t
end

-- (client) a pin from the host: player p at x, y, z; col "r,g,b" (the ring; "": white); reach "fx,fy,fz,inner,outer"
-- (where the pinger stood, the mode's distances: PC.pingSeen; "": everyone - the lobby); mode w / s / y (the centre);
-- anon: no name on it (proxchat.pinganon.<p>)
function client.pc_ping(p, x, y, z, colS, reachS, mode, anon)
	local c = PC.C()
	p, x, y, z = PC.finite(p), PC.finite(x), PC.finite(y), PC.finite(z)
	if not (p and x and y and z) then return end
	local rgb = numbers(colS, 3)
	local col = rgb and {math.max(0, math.min(1, rgb[1])), math.max(0, math.min(1, rgb[2])), math.max(0, math.min(1, rgb[3]))} or PC.PING_COLOR
	local reach = numbers(reachS, 5)
	c.pings = c.pings or {}
	local mine = 0
	for i = #c.pings, 1, -1 do
		if c.pings[i].p == p then
			mine = mine + 1
			if mine >= PC.cfg.pingPer then table.remove(c.pings, i) end
		end
	end
	mode = (mode == "w" or mode == "y") and mode or "s"
	local pg = {p = p, pos = Vec(x, y, z), t = GetTime(), col = col, mode = mode, name = anon == true and "" or PC.nameOf(p), fresh = true}
	if reach and reach[4] > 0 and reach[5] >= reach[4] then
		pg.from, pg.inner, pg.outer = Vec(reach[1], reach[2], reach[3]), reach[4], reach[5]
	end
	c.pings[#c.pings + 1] = pg
end

-- (client) how much of pin pg this player sees now: 1 within its reach (or no reach, or their own, or dead - the dead see
-- every ping), less across the buffer by their distance to where the pinger stood, 0 beyond
function PC.pingSeen(pg)
	if not pg.outer or pg.p == GetLocalPlayer() or PC.dead() then return 1 end
	local okT, t = pcall(GetPlayerTransform, GetLocalPlayer())
	if not (okT and t and t.pos) then return 1 end
	local d = VecLength(VecSub(t.pos, pg.from))
	if d <= pg.inner then return 1 end
	if d >= pg.outer then return 0 end
	return (pg.outer - d) / (pg.outer - pg.inner)
end

-- A GAME STEERS THE RAY (API 12, 2026-10-21 - Humans vs Clickers: its monster's view is its own camera, from a head
-- twice a human's height, in a creature model with hit boxes around it; from the player's camera the ray hit those, and
-- the pin landed on the player). Two client keys, set every frame by the game, read and cleared here (as proxchat.avoid):
--   proxchat.aim       "x y z dx dy dz" - the view ray the game draws its own camera with: pings cast along it
--   proxchat.pingskip  "body body ..."  - bodies the ray passes through (its creature model, its hit boxes)
-- What was read counts for PC.PING_STEER_HOLD s (the game's script may run after this one in a frame).
PC.PING_STEER_HOLD = 0.25
PC.PING_SKIP_MAX = 64

local function words(str)
	local t = {}
	for x in tostring(str or ""):gmatch("[^%s,]+") do t[#t + 1] = x end
	return t
end

-- (client, each tick) a game's proxchat.aim / proxchat.pingskip, read and cleared
function PC.pingSteerTick(now)
	local c, reg = PC.C(), PC.cfg.reg
	local key = reg .. ".aim"
	local a = GetString(key)
	if a ~= "" then
		local w, ok = words(a), false
		if #w == 6 then
			local n = {}
			for i = 1, 6 do n[i] = PC.finite(w[i]) end
			if n[1] and n[2] and n[3] and n[4] and n[5] and n[6] then
				local d = Vec(n[4], n[5], n[6])
				local len = VecLength(d)
				if len > 1e-6 then
					c.pingRay, ok = {o = Vec(n[1], n[2], n[3]), d = VecScale(d, 1 / len), t = now}, true
				end
			end
		end
		if not ok and PC.problem then
			PC.problem(key, PC.problemValue(a) .. ' is not "x y z dx dy dz" (where your camera is and the way it looks) - ignored')
		end
		ClearKey(key)
	end
	key = reg .. ".pingskip"
	local sk = GetString(key)
	if sk ~= "" then
		local list, bad = {}, nil
		for _, x in ipairs(words(sk)) do
			local h = tonumber(x)
			if h and h == math.floor(h) and h > 0 then
				if #list < PC.PING_SKIP_MAX then list[#list + 1] = h end
			else bad = bad or x end
		end
		if bad and PC.problem then
			PC.problem(key, PC.problemValue(bad) .. " is not a body handle (body handles separated by spaces) - skipped")
		end
		c.pingSkip = {list = list, t = now}
		ClearKey(key)
	end
end

-- (client) where this player's crosshair points: the first thing on the camera's ray within cfg.pingMax (not their own
-- body, nor the vehicle they sit in, nor a game's pingskip bodies); the ray a game gives in proxchat.aim instead of the
-- camera's; nil: nothing there (the sky)
function PC.pingAim()
	local me = GetLocalPlayer()
	local c, now = PC.C(), GetTime()
	local ray = c.pingRay and now - c.pingRay.t <= PC.PING_STEER_HOLD and c.pingRay or nil
	local cam
	if not ray and GetPlayerCameraTransform then
		local ok, t = pcall(GetPlayerCameraTransform)
		if ok and t and t.pos then cam = t end
	end
	cam = cam or GetCameraTransform()
	local origin = ray and ray.o or cam.pos
	local dir = ray and ray.d or TransformToParentVec(cam, Vec(0, 0, -1))
	if c.pingSkip and now - c.pingSkip.t <= PC.PING_STEER_HOLD then
		for _, b in ipairs(c.pingSkip.list) do pcall(QueryRejectBody, b) end
	end
	if QueryRejectAnimator and GetPlayerAnimator then
		local ok, a = pcall(GetPlayerAnimator, me)
		if ok and a and a ~= 0 then QueryRejectAnimator(a) end
	end
	if QueryRejectVehicle and GetPlayerVehicle then
		local ok, v = pcall(GetPlayerVehicle, me)
		if ok and v and v ~= 0 then QueryRejectVehicle(v) end
	end
	local hit, dist = QueryRaycast(origin, dir, PC.cfg.pingMax)
	if not hit then return nil end
	return VecAdd(origin, VecScale(dir, dist))
end

-- (client) this player can't ping now (its own game's view; the host checks again)
function PC.pingBlocked()
	local c = PC.C()
	if c.typing or c.nav or c.padUI then return true end             -- (the chat has the keys)
	if PC.hooks.blockKeys and PC.hooks.blockKeys() then return true end
	if GetBool(PC.cfg.reg .. ".noping") then return true end         -- (a single-player game's own switch; online the host's)
	if PC.dead() then return true end
	if GetPlayerHealth then
		local ok, h = pcall(GetPlayerHealth)
		h = ok and PC.finite(h)
		if h and h <= 0 then return true end
	end
	return false
end

-- (client) Settings' "Ping size" (a scale of the pins on this player's screen, saved)
function PC.pingSize()
	local c, cfg = PC.C(), PC.cfg
	if not c.pingSize then
		local v = HasKey(cfg.save .. "pingsize") and PC.finite(GetFloat(cfg.save .. "pingsize")) or 1
		c.pingSize = math.max(cfg.pingSizeMin, math.min(cfg.pingSizeMax, v))
	end
	return c.pingSize
end

-- done: let go of the slider - saved, and a preview pin (only for you) where you aim, to see the size on the map
function PC.setPingSize(v, done)
	local c, cfg = PC.C(), PC.cfg
	v = math.max(cfg.pingSizeMin, math.min(cfg.pingSizeMax, PC.finite(v) or 1))
	c.pingSize = math.floor(v * 20 + 0.5) / 20                       -- (5 % steps)
	if not done then return end
	SetFloat(cfg.save .. "pingsize", c.pingSize)
	local at = PC.pingAim()
	if not at then return end
	c.pings = c.pings or {}
	for i = #c.pings, 1, -1 do if c.pings[i].preview then table.remove(c.pings, i) end end
	local m = PC.mode()
	c.pings[#c.pings + 1] = {p = GetLocalPlayer(), pos = at, t = GetTime(), col = PC.PING_COLOR, mode = m == "g" and "s" or m,
		name = "Ping size", preview = true}
end

-- (chat_core's Settings page) its row: the slider, 50 % .. 200 %
function PC.pingRows(rows)
	local cfg = PC.cfg
	local span = cfg.pingSizeMax - cfg.pingSizeMin
	rows[#rows + 1] = {"set_ps", "Ping size", "slider", (PC.pingSize() - cfg.pingSizeMin) / span,
		function(v, done) PC.setPingSize(cfg.pingSizeMin + v * span, done) end,
		function(v) return string.format("%d%%", math.floor((cfg.pingSizeMin + v * span) * 100 + 0.5)) end}
end

-- (client, each tick) the ping buttons: the middle mouse button; on a controller L1 + R1 together (within PC.PING_CHORD
-- s of each other); and old pins go (in full for cfg.pingLife s, then fading for cfg.pingFade s)
function PC.pingTick(now)
	local c = PC.C()
	if c.pings then
		for i = #c.pings, 1, -1 do
			if now - c.pings[i].t > PC.cfg.pingLife + PC.cfg.pingFade then table.remove(c.pings, i) end
		end
	end
	PC.pingSteerTick(now)
	local want = InputPressed("mmb")
	if PC.pad() then
		if InputPressed("scroll_up") then c.pingL1 = now end
		if InputPressed("scroll_down") then c.pingR1 = now end
		if c.pingL1 and c.pingR1 and math.abs(c.pingL1 - c.pingR1) <= PC.PING_CHORD then
			c.pingL1, c.pingR1 = nil, nil
			want = true
		end
	end
	if not want or PC.pingBlocked() then return end
	local mode = PC.mode()
	if mode == "g" and not PC.lobby() then                             -- (no pings in Global: said, at most every 3 s)
		if now - (c.pingNoGlobalT or -1e9) > 3 then
			c.pingNoGlobalT = now
			PC.system(PC.NO_GLOBAL_PING)
		end
		return
	end
	local at = PC.pingAim()
	if at then PC.call("pc_ping", at[1], at[2], at[3], mode) end
end

-- a pin's opacity at age s: full for cfg.pingLife s, then fading out over cfg.pingFade s (eased: slow at first)
function PC.pingAlpha(age)
	local cfg = PC.cfg
	if age <= cfg.pingLife then return 1 end
	local f = math.min(1, (age - cfg.pingLife) / cfg.pingFade)
	return 1 - f * f
end

-- one pin at opacity a (age s): a ring on the spot (the team's / mod's colour) round a centre in the mode's colour - a
-- dot, a "!" for Yell - with a stem up to the distance (the mode's colour) and the pinger's name; off screen, on the
-- screen's edge in its direction (no stem). It pops in (big, then settles: it catches the eye); size scales it, and the
-- mode (PC.PING_MODE_SIZE)
local function drawPin(pg, a, age, size, head)
	size = size * (PC.PING_MODE_SIZE[pg.mode] or 1)
	local mc = PC.modeInfo(pg.mode or "s")[5]
	local W, H = UiWidth(), UiHeight()
	local pop = 1 + 0.8 * math.max(0, 1 - age / 0.25)
	local x, y, d = UiWorldToPixel(pg.pos)
	local m = 40 * size
	local edge = not (d and d > 0 and x >= m and x <= W - m and y >= m and y <= H - m)
	if edge then
		x, y = PC.edgePoint(pg.pos)
		x, y = math.max(m, math.min(W - m, x)), math.max(m, math.min(H - m, y))
	end
	local dist = head and VecLength(VecSub(pg.pos, head)) or 0
	local col = pg.col
	UiPush()
	UiTranslate(x, y)
	UiScale(size)
	UiAlign("center middle")
	UiColor(0, 0, 0, 0.45 * a)                                       -- (a dark halo: readable on snow and sky)
	UiImageBox("ui/common/circle_filled_20x20.png", 34 * pop, 34 * pop, 0, 0)
	UiColor(col[1], col[2], col[3], a)
	UiImageBox("ui/common/circle_hollow_20x20.png", 30 * pop, 30 * pop, 0, 0)
	UiColor(mc[1], mc[2], mc[3], a)
	if pg.mode == "y" then                                           -- (Yell: a "!" in the middle)
		UiPush()
		UiFont("bold.ttf", 22)
		UiText("!")
		UiPop()
	else
		UiImageBox("ui/common/circle_filled_20x20.png", 12, 12, 0, 0)
	end
	if not edge then                                                 -- (the stem up to the label)
		UiPush()
		UiAlign("center bottom")
		UiTranslate(0, -16)
		UiColor(0, 0, 0, 0.45 * a)
		UiRect(4, 26)
		UiColor(col[1], col[2], col[3], a)
		UiRect(2, 25)
		UiPop()
	end
	UiAlign("center bottom")
	UiTranslate(0, edge and -22 or -46)
	PC.noWild()
	UiFont("bold.ttf", 22)
	UiTextShadow(0, 0, 0, 0.8 * a, 2, 0.6)
	UiColor(mc[1], mc[2], mc[3], a)
	if not pg.preview then UiText(string.format("%d m", math.floor(dist + 0.5))) end
	UiTranslate(0, -22)
	if pg.name ~= "" then                                            -- (no name: proxchat.pinganon)
		UiFont(PC.chatFont(pg.name), 20)
		UiColor(1, 1, 1, 0.9 * a)
		UiText(pg.name)
	end
	UiPop()
end

-- (client draw) the pins: they stay, then fade out slowly (PC.pingAlpha); a pin with a reach fades across its buffer too
-- (PC.pingSeen); Settings' "Ping size" scales them
function PC.pingDraw()
	local c = PC.C()
	if not c.pings or #c.pings == 0 then return end
	local now = GetTime()
	local head = PC.listenerHead()
	local size = PC.pingSize()
	for _, pg in ipairs(c.pings) do
		local seen = PC.pingSeen(pg)
		if pg.fresh and seen > 0 then                                    -- (its sound when it first shows: walking into
			pg.fresh = nil                                               --  its reach later, then)
			if UiSound then pcall(UiSound, PC.PING_SOUND) end
		end
		local age = now - pg.t
		local a = PC.pingAlpha(age) * seen
		if a > 0 then drawPin(pg, a, age, size, head) end
	end
end
