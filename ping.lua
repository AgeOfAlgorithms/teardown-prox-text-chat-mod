-- ping.lua - PINGS (the user, 2026-10-20): the middle mouse button, or L1 + R1 together on a controller, puts a pin where
-- the crosshair points, for cfg.pingLife s. Only the pinger's team sees it; dead players can't ping.
-- TEAMS (the game tells a mod nothing about them: a game mode keeps its teams in its own script's shared table):
--   1. proxchat.team.<p> - a team name a game mod sets on the host (API.md);
--   2. else the colour a game mode forces on the player: the game's team modes colour every player in their team's
--      colour every tick (data/script/mp/lib/teams.lua: SetPlayerColor) - the same colour is the same team;
--   3. else no team: every player without one sees it (sandbox, free for all - the user, 2026-10-20: "Everyone").
-- DEAD: in a channel (proxchat.channel.<p>: a game's dead) or no health left. A game turns pings off with
-- proxchat.noping (a free-for-all mode where pins would give players away).
-- THE BUTTONS (2026-10-20): every pad button has a job in play, and a mod can't take one from the game. L1 / R1 are the
-- tool scroll up / down, so both at once step back and forth to the same tool: nothing stays changed (long L3 left the
-- zoom on, R3 is the scoreboard toggle, the D-pad switches tools). Pad only: a quick up-and-down mouse wheel is no chord.
-- REACH (the user, 2026-10-21: "let the mod decide how far the ping message reaches"): a game mod sets it in
-- proxchat.ranges, "ping=<m>", apart from the talk modes' distances. A teammate within it of where the pinger stood sees
-- the pin in full; in the buffer beyond (cfg.pingBuf more, as Speak's) it fades out with the distance; past that nothing.
-- By the listener's distance NOW (walking in shows it, walking away fades it). Not set: the whole map (Witch Hunt, a
-- hidden-role mode, wants pins only for the people around). The dead (a channel) see every ping, as they hear everyone.
-- The host checks every ping (a real player with their token, alive, at most cfg.pingRate a second, a point within
-- reach of them) and sends it to the team alone - with a reach, only the teammates within it, the buffer and
-- cfg.pingSlack (room to walk in) - by client.pc_ping, never in shared.

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
		pingBuf = 0.4,           -- a ping's reach (proxchat.ranges "ping=<m>"): its buffer beyond it, a share (as Speak's)
		pingSlack = 15,          -- m past the buffer the host still sends a pin to (room to walk in while it is up)
	}
	for k, v in pairs(defaults) do
		if PC.cfg[k] == nil then PC.cfg[k] = v end
	end
end
PC.PING_CHORD = 0.2                                                  -- s: L1 and R1 count as pressed together within this
PC.PING_COLOR = {1, 0.82, 0.3}                                       -- (a pin without a team colour: the chat's yellow)
PC.PING_SOUND = "ui/hud/location.ogg"                                -- (the game's map-marker sound)

-- ---- the host

-- (server, from proxchat.ranges "ping=<m>") how far a ping reaches; nil: the whole map
function PC.setPingRange(m)
	m = PC.finite(m)
	if not m or m <= 0 then
		if PC.problem then PC.problem(PC.cfg.reg .. ".ranges", "ping=" .. tostring(m) .. " is no distance - to turn pings off, SetBool(\"proxchat.noping\", true)") end
		return
	end
	PC.S().pingR = math.min(m, 2000)
end

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

-- a player pings the point x, y, z: checked, then sent to their team (themselves too)
function server.pc_ping(p, tok, x, y, z)
	local cfg = PC.cfg
	p = PC.who(p, tok)
	if not p then return end
	x, y, z = PC.finite(x), PC.finite(y), PC.finite(z)
	if not (x and y and z) then return end
	if GetBool(cfg.reg .. ".noping") or PC.pingDead(p) then return end
	local okT, tr = pcall(GetPlayerTransform, p)
	if not (okT and tr and tr.pos) then return end
	if VecLength(VecSub(Vec(x, y, z), tr.pos)) > cfg.pingMax + 10 then return end   -- (from where they stand, give or take
	if not PC.allow(p, "ping", cfg.pingRate, cfg.pingBurst) then return end         --  the camera: no pins across the map)
	local s = PC.S()
	local team, col = PC.teamOf(p)
	local colS = col and string.format("%.3f,%.3f,%.3f", col[1], col[2], col[3]) or ""
	local reachS, sendTo = "", nil                                       -- (a reach: where the pinger stood, inner, outer)
	if s.pingR then
		local outer = s.pingR * (1 + cfg.pingBuf)
		reachS = string.format("%.2f,%.2f,%.2f,%g,%g", tr.pos[1], tr.pos[2], tr.pos[3], s.pingR, outer)
		sendTo = outer + cfg.pingSlack
	end
	for _, q in ipairs(PC.allPlayers()) do
		if PC.teamOf(q) == team then
			local near = q == p or not sendTo or s.chan[q] ~= nil             -- (the dead see every ping)
			if not near then
				local okQ, tq = pcall(GetPlayerTransform, q)
				near = okQ and tq and tq.pos and VecLength(VecSub(tq.pos, tr.pos)) <= sendTo
			end
			if near then ClientCall(q, "client.pc_ping", p, x, y, z, colS, reachS) end
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

-- (client) a pin from the host: player p at x, y, z; col "r,g,b" ("": the chat's yellow); reach "fx,fy,fz,inner,outer"
-- (where the pinger stood, the distances: PC.pingSeen; "": the whole map)
function client.pc_ping(p, x, y, z, colS, reachS)
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
	local pg = {p = p, pos = Vec(x, y, z), t = GetTime(), col = col, name = PC.nameOf(p), fresh = true}
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

-- (client) where this player's crosshair points: the first thing on the camera's ray within cfg.pingMax (not their own
-- body, nor the vehicle they sit in); nil: nothing there (the sky)
function PC.pingAim()
	local me = GetLocalPlayer()
	local cam
	if GetPlayerCameraTransform then
		local ok, t = pcall(GetPlayerCameraTransform)
		if ok and t and t.pos then cam = t end
	end
	cam = cam or GetCameraTransform()
	local dir = TransformToParentVec(cam, Vec(0, 0, -1))
	if QueryRejectAnimator and GetPlayerAnimator then
		local ok, a = pcall(GetPlayerAnimator, me)
		if ok and a and a ~= 0 then QueryRejectAnimator(a) end
	end
	if QueryRejectVehicle and GetPlayerVehicle then
		local ok, v = pcall(GetPlayerVehicle, me)
		if ok and v and v ~= 0 then QueryRejectVehicle(v) end
	end
	local hit, dist = QueryRaycast(cam.pos, dir, PC.cfg.pingMax)
	if not hit then return nil end
	return VecAdd(cam.pos, VecScale(dir, dist))
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
	c.pings[#c.pings + 1] = {p = GetLocalPlayer(), pos = at, t = GetTime(), col = PC.PING_COLOR, name = "Ping size", preview = true}
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
	local at = PC.pingAim()
	if at then PC.call("pc_ping", at[1], at[2], at[3]) end
end

-- a pin's opacity at age s: full for cfg.pingLife s, then fading out over cfg.pingFade s (eased: slow at first)
function PC.pingAlpha(age)
	local cfg = PC.cfg
	if age <= cfg.pingLife then return 1 end
	local f = math.min(1, (age - cfg.pingLife) / cfg.pingFade)
	return 1 - f * f
end

-- one pin at opacity a (age s): a ring on the spot with a stem up to the distance and the pinger's name; off screen, on
-- the screen's edge in its direction (no stem). It pops in (big, then settles: it catches the eye); size scales it
local function drawPin(pg, a, age, size, head)
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
	UiImageBox("ui/common/circle_filled_20x20.png", 10, 10, 0, 0)
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
	UiColor(col[1], col[2], col[3], a)
	if not pg.preview then UiText(string.format("%d m", math.floor(dist + 0.5))) end
	UiTranslate(0, -22)
	UiFont(PC.chatFont(pg.name), 20)
	UiColor(1, 1, 1, 0.9 * a)
	UiText(pg.name)
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
