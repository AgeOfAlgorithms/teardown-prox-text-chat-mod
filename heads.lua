-- TALKING HEADS (a prototype, Oct 2026): a player's head bobs while they talk - a typed line: exactly as long as its
-- babble (PC.babbleLength); a spoken one: from the moment their helper hears them start until the line is said
-- (voice.lua: "started talking", kind s, relayed by the server to the players near enough; live words too). Each
-- machine bobs the heads it sees. The speaker's own head too (seen in third person).
-- The game animates player bodies in its own client.postUpdate (data/script/playerbody.lua -> player_locomotion.lua);
-- ours runs in client.postUpdate too and sticks (seen in-game 2026-10-05: /bob; in client.render it did nothing).
-- The head BOBBLES like someone talking: every cfg.bobStep s a new small random angle about each axis, snapped to
-- quickly (cfg.bobSnap) - quick and jerky, not smooth. (A turn about one axis looked like a head shake - the bone's
-- axes are not the character's; smooth sine waves about all three looked like a dance-like head wobble.)
-- /bob: your own head bobbles 4 s (look in third person). Voice / chat dummies have no skeleton: they do not bobble.
do
	local defaults = {
		-- by mode (the user, 2026-10-06: whisper and speak livelier, yell more dramatic and faster):
		bobAmp = {w = 6, s = 11, y = 18},                              -- degrees
		bobStep = {w = {0.08, 0.16}, s = {0.07, 0.15}, y = {0.045, 0.09}},   -- s between two new random angles
		bobSnap = {w = 0.04, s = 0.035, y = 0.022},                    -- s to get most of the way to a new angle
		bobAxes = {1, 0.7, 0.5}, -- each axis' share of the amplitude
		bobFar = 60,             -- m: farther heads are not nodded (too small to see)
	}
	for k, v in pairs(defaults) do if PC.cfg[k] == nil then PC.cfg[k] = v end end
end

-- player p bobs for dur s (longer if already bobbing) in mode's style ("w", "s", "y": cfg.bobAmp / bobStep / bobSnap)
function PC.bobStart(p, dur, mode)
	local c = PC.C()
	c.bob = c.bob or {}
	local now = GetTime()
	mode = (mode == "w" or mode == "y") and mode or "s"
	local b = c.bob[p]
	if b and b.untilT > now then
		b.untilT = math.max(b.untilT, now + dur)
		if PC.cfg.bobAmp[mode] > PC.cfg.bobAmp[b.mode] then b.mode = mode end   -- (the livelier style wins)
	else
		c.bob[p] = {t0 = now, untilT = now + dur, mode = mode, cur = {0, 0, 0}, tgt = {0, 0, 0}, nextT = now, lastT = now}
	end
end

-- (chat_core's PC.receive) a TYPED line said near enough to see: its speaker bobs exactly as long as its babble.
-- (A spoken line bobbed while it was said - "started talking" until the line: nothing more after it.)
function PC.bobSaid(p, mode, text, voice)
	local cfg = PC.cfg
	if voice or type(p) ~= "number" or PC.isDummy(p) or PC.isVoiceDummy(p) or mode == "g" or mode == "d" then return end
	local d = PC.distTo(p)
	if p ~= GetLocalPlayer() and not (d and d <= cfg.bobFar) then return end
	PC.bobStart(p, PC.babbleLength(p, text, mode), mode)
end

-- the bobble now: degrees about each axis, or nil when it is over. Every cfg.bobStep s a new random angle per axis
-- (within the amplitude, eased out over the last 0.2 s), and the head snaps toward it (cfg.bobSnap)
function PC.bobAngles(b, now)
	if now >= b.untilT then return nil end
	local cfg = PC.cfg
	local ease = math.max(0, math.min(1, (b.untilT - now) / 0.2))
	local amp, step = cfg.bobAmp[b.mode], cfg.bobStep[b.mode]
	if now >= b.nextT then
		for k = 1, 3 do b.tgt[k] = (math.random() * 2 - 1) * amp * cfg.bobAxes[k] end
		b.nextT = now + step[1] + math.random() * (step[2] - step[1])
	end
	local f = 1 - math.exp(-math.max(0, now - b.lastT) / cfg.bobSnap[b.mode])
	b.lastT = now
	for k = 1, 3 do b.cur[k] = b.cur[k] + (b.tgt[k] * ease - b.cur[k]) * f end
	return b.cur[1], b.cur[2], b.cur[3]
end

-- (main.lua: client.postUpdate, after the game's own body animation) turn each bobbling head; live words keep their
-- speaker bobbling
function PC.bobApply()
	local c, cfg = PC.c, PC.cfg
	if not c then return end
	local now = GetTime()
	for p, t in pairs(c.talking or {}) do                              -- (others talking: from "started" to their line)
		if now - t.t > 16 then c.talking[p] = nil else PC.bobStart(p, 0.3, t.ch) end
	end
	for p, l in pairs(c.live or {}) do                                 -- (live words: talking too - for players who came
		if not PC.isVoiceDummy(p) and PC.voiceLiveOf and PC.voiceLiveOf(p) and now - l.t < 1.5 then   -- near after it began)
			PC.bobStart(p, 0.3, l.ch)
		end
	end
	local own = c.voice and c.voice.talking                            -- (your own: your helper heard you start)
	if own and now - own.t < 16 then PC.bobStart(GetLocalPlayer(), 0.3, PC.voiceMode and PC.voiceMode() or PC.mode()) end
	if not c.bob or not (RotateBone and GetPlayerAnimator and QuatEuler) then return end
	for p, b in pairs(c.bob) do
		local ax, ay, az = PC.bobAngles(b, now)
		if not ax then
			c.bob[p] = nil
		else
			local ok, anim = pcall(GetPlayerAnimator, p)
			if ok and anim and anim ~= 0 then pcall(RotateBone, anim, "head", QuatEuler(ax, ay, az), 1) end
		end
	end
end

-- /bob [w|s|y]: your own head bobbles 4 s in that mode's style (Speak unless given; to see it: third person)
function PC.bobCommand(arg)
	local a = (arg or ""):lower():sub(1, 1)
	local mode = (a == "w" or a == "y") and a or "s"
	PC.bobStart(GetLocalPlayer(), 4, mode)
	PC.system("Your head bobbles for 4 s as in " .. PC.modeInfo(mode)[3] .. " (look at yourself in third person). /bob w, /bob s, /bob y.")
end
