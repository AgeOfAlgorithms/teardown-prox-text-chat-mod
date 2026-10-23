-- DEVICES (Oct 2026): walkie-talkies, loudspeakers (a megaphone) and PA systems a GAME declares, what a player says into
-- them, and how each voice sounds (Koetama's PROTOCOL.md "Devices" and "Sound effects"). Included after voice.lua;
-- chat_core.lua and voice.lua call it through guarded hooks (PC.dev*, PC.txOf, PC.fx*). The chat's own modes stay
-- Whisper / Speak / Yell / Global (the user, 2026-10-09: the device modes come only from game mods, never from the chat
-- line): nothing here happens until a game sets these, from its SERVER script on the host, every tick -
--   proxchat.device.<name> = "<kind> [channel=<c>] at=<where> [range=<near>,<far>] [signal=0..1] [reverb=0..1]"
--       kind radio (a walkie-talkie: "Private") | loudspeaker (a megaphone, a horn) | pa (a PA's speakers); channel
--       defaults to private / megaphone / pa; where: player:<p> (carried: at p's chest), body:<handle> (moves with a
--       body), x,y,z or x,y,z;x,y,z;... (up to 16: a PA's speakers). range: its own (Koetama's loudness [near, far]; its
--       text: words to far / (1 + the kind's buffer), garbled to far), else the kind's (cfg.privateR / megaR / paR and
--       buffers). "" removes it.
--   proxchat.tx.<p> = "<channel>": p talks into that channel's devices NOW (the walkie's button held, at the PA
--       microphone, a megaphone raised) - their voice and their lines (typed or spoken; not Global) also come out of
--       every device of the channel. A walkie p carries never plays p (it can't receive while it sends); a loudspeaker
--       p carries does (a megaphone, pointing where p looks: Koetama's "facing", "back" 0.15 - and its words reach
--       less far behind it the same way, PC.hornFactor). "" = none.
--   proxchat.ranges also sets the kinds' ranges (private=, megaphone=, pa=) and reach= (Private's: a walkie plays a
--       talker only within this distance of them; 0 = any) - chat_core's PC.parseRanges.
--   proxchat.effects.<mode> = "pitch=4 wobble=0.3 band=300,3000 ..." Koetama's effects for whisper, speak, yell, dead,
--       private (walkies), megaphone (loudspeakers), pa, over the preset; "" = the defaults. proxchat.effects.player.<p>:
--       one player's own (a robot character), over the mode's, on their voice and their devices.
-- The host turns these into shared.pcDev / pcDevN, pcTx, pcFx / pcFxN (PC.devServerTick); every game works out positions
-- itself each frame (player and body handles are the same on every machine).
-- TEXT: the host sends a line also to the players near a device of the talker's channel (its far + cfg.devSlack), with
-- the channel and kind (client.pc_near / pc_whisper / pc_live: dv, dk); each game shows it in a bubble OVER each device
-- it can hear (at most cfg.devBubbles, the nearest; a PA: one, over its nearest speaker; a carried one: over its
-- carrier's head), in the device's style, revealed by the device's range as a talker's bubble is by theirs (a spoken
-- line with word times: each word as heard from the device when said - PC.voiceSample logs "dev:<name>"). The listener's
-- own walkie: as the own-bubble rule (third person only). VOICE: the feed's speakers get "via" (PC.devVia), the talker's
-- feed "transmit" (PC.devTransmit), effects (PC.fxFor). Lobby: none of this; the dead talk only to their channel.

PC.KIND_ID = {radio = "pr", loudspeaker = "m", pa = "pa"}            -- (a kind's id for its ranges and effects)
PC.KIND_CHAN = {radio = "private", loudspeaker = "megaphone", pa = "pa"}   -- (a kind's default channel)
PC.KIND_LABEL = {radio = "walkie", loudspeaker = "loudspeaker", pa = "PA"}
-- names in proxchat.effects.<name> -> ids
PC.FX_NAME = {whisper = "w", speak = "s", yell = "y", shout = "y", dead = "d", private = "pr", radio = "pr", walkie = "pr",
	megaphone = "m", loudspeaker = "m", pa = "pa"}

do
	local defaults = {
		privateR = 6,            -- m: a walkie's words (around the walkie that plays it)
		privateBuf = 0.5,        --   its buffer, a share as Whisper's: garbled to 9 m
		privateNear = 1,         -- m: a walkie at full loudness within this (Koetama's range [near, far])
		privateReach = 0,        -- m: a walkie plays a talker only within this distance of them (0: any distance)
		megaR = 60,              -- m: a loudspeaker's words
		megaBuf = 1 / 3,         --   garbled to 80 m
		megaNear = 8,
		paR = 45,                -- m: a PA's words around each of its speakers
		paBuf = 1 / 3,           --   garbled to 60 m
		paNear = 10,
		hornBack = 0.15,         -- a carried loudspeaker's (megaphone's) loudness straight behind it (Koetama's "back")
		devSlack = 10,           -- m past a device's far the host still sends a line to (room to walk in while it is up)
		devBubbles = 3,          -- device bubbles a line gets at most (the nearest devices)
		bigBubbleMin = 0.9,      -- a loudspeaker's / PA's bubble: never smaller than this (others: 0.55 far off, by distance)
		bigBubbleBoost = 1.25,   --   and this much bigger than a voice's at the same distance
		devMaxVia = 8,           -- via entries per speaker (Koetama: at most 8)
		devMaxPts = 16,          -- positions per device (Koetama: at most 16)
		devMax = 64,             -- devices read from the registry at most
	}
	for k, v in pairs(defaults) do
		if PC.cfg[k] == nil then PC.cfg[k] = v end
	end
end

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end

-- ---- RANGES (proxchat.ranges, PC.cfg; shared.pcRanges carries them)
PC.DEV_RANGE_LIMITS = {pr = {2, 40}, m = {5, 200}, pa = {5, 200}}
function PC.applyDevRanges(pr, mg, pa, reach)
	local cfg = PC.cfg
	if pr then cfg.privateR = pr end
	if mg then cfg.megaR = mg end
	if pa then cfg.paR = pa end
	if reach then cfg.privateReach = reach end
	cfg.privateMumbleR = cfg.privateR * (1 + cfg.privateBuf)
	cfg.megaMumbleR = cfg.megaR * (1 + cfg.megaBuf)
	cfg.paMumbleR = cfg.paR * (1 + cfg.paBuf)
end
PC.applyDevRanges()

-- (server) set them for everyone (nil: keep that one)
function PC.setDevRanges(pr, mg, pa, reach)
	local function r(x, id)
		x = tonumber(x)
		if not x then return nil end
		local L = PC.DEV_RANGE_LIMITS[id]
		return clamp(math.floor(x + 0.5), L[1], L[2])
	end
	reach = tonumber(reach)
	PC.applyDevRanges(r(pr, "pr"), r(mg, "m"), r(pa, "pa"), reach and clamp(math.floor(reach + 0.5), 0, 100000) or nil)
	if PC.publishRanges then PC.publishRanges() end
end

-- a device's text ranges (words, garbled to) and Koetama's loudness range (near, far): its own range= or its kind's
function PC.devRanges(dev)
	local cfg = PC.cfg
	local id = PC.KIND_ID[dev.kind]
	local buf = id == "pr" and cfg.privateBuf or (id == "pa" and cfg.paBuf or cfg.megaBuf)
	if dev.far then return dev.far / (1 + buf), dev.far, dev.near, dev.far end
	if id == "pr" then return cfg.privateR, cfg.privateMumbleR, cfg.privateNear, cfg.privateMumbleR end
	if id == "pa" then return cfg.paR, cfg.paMumbleR, cfg.paNear, cfg.paMumbleR end
	return cfg.megaR, cfg.megaMumbleR, cfg.megaNear, cfg.megaMumbleR
end

-- a channel name: lower case, no spaces, at most 24 characters ("" = none)
function PC.tidyChan(s)
	s = PC.utf8Head(PC.clean(tostring(s or "")), 24):lower()
	return (s:gsub("%s+", ""))
end

-- ---- PARSING (the host; pure functions, tested offline)
-- "player:3", "body:812", "1,2,3" or "1,2,3;4,5,6" -> {t = "player", p} / {t = "body", h} / {t = "pos", pts}, or nil
function PC.devParseAt(v)
	v = tostring(v or "")
	local p = v:match("^player:(%d+)$")
	if p then return {t = "player", p = tonumber(p)} end
	local h = v:match("^body:(%d+)$")
	if h then return {t = "body", h = tonumber(h)} end
	local pts = {}
	for part in (v .. ";"):gmatch("([^;]*);") do
		if part ~= "" then
			local x, y, z = part:match("^(%-?[%d%.]+),(%-?[%d%.]+),(%-?[%d%.]+)$")
			x, y, z = tonumber(x), tonumber(y), tonumber(z)
			if not (x and y and z) then return nil end
			if #pts < PC.cfg.devMaxPts then pts[#pts + 1] = Vec(x, y, z) end
		end
	end
	if #pts == 0 then return nil end
	return {t = "pos", pts = pts}
end

-- one proxchat.device.<name> string -> {kind, chan, at, near, far (only when given), signal, reverb}, or nil; and what
-- was wrong (nil: nothing; with a device: a part that was skipped), for PC.problem
PC.DEV_AT_FORMS = 'at=player:<id>, at=body:<handle> or at=x,y,z (several places: x,y,z;x,y,z)'
function PC.devParse(s)
	if type(s) ~= "string" then return nil, "not a text" end
	local words = {}
	for w in s:gmatch("%S+") do words[#words + 1] = w end
	local kind = (words[1] or ""):lower()
	if kind == "megaphone" then kind = "loudspeaker" elseif kind == "walkie" or kind == "private" then kind = "radio" end
	if not PC.KIND_ID[kind] then
		return nil, 'starts with "' .. (words[1] or "") .. '", not the kind: radio (walkie), loudspeaker (megaphone) or pa'
	end
	local d = {kind = kind, chan = PC.KIND_CHAN[kind]}
	local bad, badAt = {}, nil
	for i = 2, #words do
		local k, v = words[i]:match("^(%a+)=(.*)$")
		k = k and k:lower()
		if k == "channel" then
			local ch = PC.tidyChan(v)
			if ch ~= "" then d.chan = ch end
		elseif k == "at" then
			d.at = PC.devParseAt(v)
			if not d.at then badAt = v end
		elseif k == "range" then
			local a, b = v:match("^([%d%.]+),([%d%.]+)$")
			a, b = tonumber(a), tonumber(b)
			if a and b and b > a then d.near, d.far = clamp(a, 0, 500), clamp(b, a + 0.5, 1000)
			else bad[#bad + 1] = 'range="' .. v .. '" is not near,far in metres (far bigger)' end
		elseif k == "signal" and tonumber(v) then
			d.signal = clamp(tonumber(v), 0, 1)
		elseif k == "reverb" and tonumber(v) then
			d.reverb = clamp(tonumber(v), 0, 1)
		elseif k == "signal" or k == "reverb" then
			bad[#bad + 1] = k .. '="' .. v .. '" is not a number 0..1'
		else
			bad[#bad + 1] = '"' .. words[i] .. '" is not channel=, at=, range=, signal= or reverb='
		end
	end
	if not d.at then
		return nil, (badAt and ('at="' .. badAt .. '" is not ') or "no at=: give ") .. PC.DEV_AT_FORMS
	end
	return d, bad[1] and table.concat(bad, "; ") or nil
end

-- Koetama's effects, from "key=value ..." -> a table for the feed's "effects", or nil (nothing valid). 0..1 values,
-- pitch -12..12, robot Hz 0..2000, band "lo,hi" Hz, echo "s" or "s,feedback"; "off", "false", "null", "no" or 0 switch
-- one off (false). Unknown keys and bad values are skipped (and told: the second value, for PC.problem).
PC.FX_UNIT = {drive = true, compress = true, static = true, crackle = true, squelch = true, horn = true, lofi = true,
	wobble = true, reverb = true, hum = true}
PC.FX_KEYS = "pitch, robot, band, echo, drive, compress, static, crackle, squelch, horn, lofi, wobble, reverb, hum"
function PC.fxParse(s)
	if type(s) ~= "string" then return nil, "not a text" end
	local out, any, bad = {}, false, {}
	for k, v in s:gmatch("([%a_]+)%s*=%s*([^%s]+)") do
		k, v = k:lower(), v:lower()
		local off = v == "off" or v == "false" or v == "null" or v == "no" or tonumber(v) == 0
		local val
		if off and (PC.FX_UNIT[k] or k == "pitch" or k == "robot" or k == "band" or k == "echo") then
			val = false
		elseif PC.FX_UNIT[k] then
			val = tonumber(v) and clamp(tonumber(v), 0, 1)
		elseif k == "pitch" then
			val = tonumber(v) and clamp(tonumber(v), -12, 12)
		elseif k == "robot" then
			val = tonumber(v) and clamp(tonumber(v), 0, 2000)
		elseif k == "band" then
			local a, b = v:match("^([%d%.]+),([%d%.]+)$")
			a, b = tonumber(a), tonumber(b)
			if a and b and b > a then val = PC.jsonArray({clamp(a, 20, 20000), clamp(b, 20, 20000)}) end
		elseif k == "echo" then
			local a, b = v:match("^([%d%.]+),([%d%.]+)$")
			if a and tonumber(a) and tonumber(b) then
				val = PC.jsonArray({clamp(tonumber(a), 0, 2), clamp(tonumber(b), 0, 0.9)})
			elseif tonumber(v) then
				val = clamp(tonumber(v), 0, 2)
			end
		end
		if val ~= nil then out[k], any = val, true
		elseif PC.FX_UNIT[k] or k == "pitch" or k == "robot" or k == "band" or k == "echo" then
			bad[#bad + 1] = k .. '="' .. v .. '" is not a value it takes'
		else
			bad[#bad + 1] = '"' .. k .. '" is not an effect (' .. PC.FX_KEYS .. ')'
		end
	end
	if not any and not bad[1] then bad[1] = "no name=value pairs" end
	return any and out or nil, bad[1] and table.concat(bad, "; ") or nil
end

-- ---- THE HOST: the registry -> shared, every tick (each part published only when it changed)
function PC.devServerTick()
	local s, cfg = PC.S(), PC.cfg
	local reg = cfg.reg
	s.dw = s.dw or {devs = {}, tx = {}}
	local dw = s.dw
	dw.lobby, dw.chan = PC.inLobby(), s.chan
	-- devices
	local okK, keys = pcall(ListKeys, reg .. ".device")
	local raw = {}
	if okK and type(keys) == "table" then
		table.sort(keys)
		for _, k in ipairs(keys) do
			local v = GetString(reg .. ".device." .. k)
			if v ~= "" and #raw < cfg.devMax then raw[#raw + 1] = {k, v}
			elseif v ~= "" and PC.problem then
				PC.problem(reg .. ".device", "more than " .. cfg.devMax .. " devices: the ones after " .. raw[#raw][1] .. " (by name) are ignored")
			end
		end
	end
	local sig = {}
	for i, kv in ipairs(raw) do sig[i] = kv[1] .. "=" .. kv[2] end
	sig = table.concat(sig, "\n")
	if sig ~= s.devSig then
		s.devSig = sig
		local devs, copy = {}, {}
		for _, kv in ipairs(raw) do
			local d, why = PC.devParse(kv[2])
			if d then devs[kv[1]] = d; copy[kv[1]] = d end
			if why and PC.problem then
				PC.problem(reg .. ".device." .. kv[1], PC.problemValue(kv[2]) .. ": " .. why .. (d and " (skipped; the device works)" or " - ignored"))
			end
		end
		dw.devs = devs
		s.devN = (s.devN or 0) + 1
		shared.pcDev = copy
		shared.pcDevN = s.devN
	end
	-- who talks into a channel now (proxchat.tx.<p>), with a log: a spoken line can end after the button is let go
	local tx, changed = {}, false
	for _, q in ipairs(PC.allPlayers()) do
		local v = PC.tidyChan(GetString(reg .. ".tx." .. q))
		if v ~= "" then tx[q] = v end
		if tx[q] ~= dw.tx[q] then
			changed = true
			s.txLog = s.txLog or {}
			local log = s.txLog[q] or {}
			log[#log + 1] = {t = s.time, ch = tx[q] or ""}
			while #log > 1 and s.time - log[2].t > 60 do table.remove(log, 1) end
			s.txLog[q] = log
		end
	end
	for q in pairs(dw.tx) do if not tx[q] then changed = true end end
	if changed then
		dw.tx = tx
		local t = {}
		for q, v in pairs(tx) do t[q] = v end
		shared.pcTx = t
	end
	-- sound effects per mode and per player
	local fxRaw = {}
	local okF, fk = pcall(ListKeys, reg .. ".effects")
	if okF and type(fk) == "table" then
		table.sort(fk)
		for _, k in ipairs(fk) do
			if k == "player" then
				local okP, pk = pcall(ListKeys, reg .. ".effects.player")
				if okP and type(pk) == "table" then
					table.sort(pk)
					for _, q in ipairs(pk) do
						local v = GetString(reg .. ".effects.player." .. q)
						if v ~= "" and tonumber(q) then fxRaw[#fxRaw + 1] = {"p", tonumber(q), v, "player." .. q} end
					end
				end
			else
				local v = GetString(reg .. ".effects." .. k)
				local id = PC.FX_NAME[k:lower()]
				if v ~= "" and id then fxRaw[#fxRaw + 1] = {"m", id, v, k}
				elseif v ~= "" and PC.problem then
					PC.problem(reg .. ".effects." .. k, "not a mode or device (whisper, speak, yell, dead, radio, megaphone, pa; "
						.. "one player: effects.player.<id>) - ignored")
				end
			end
		end
	end
	local fs = {}
	for i, e in ipairs(fxRaw) do fs[i] = e[1] .. e[2] .. "=" .. e[3] end
	fs = table.concat(fs, "\n")
	if fs ~= s.fxSig then
		s.fxSig = fs
		local fx = {modes = {}, players = {}}
		for _, e in ipairs(fxRaw) do
			local v, why = PC.fxParse(e[3])
			if why and PC.problem then
				PC.problem(reg .. ".effects." .. e[4], PC.problemValue(e[3]) .. ": " .. why .. (v and " (skipped; the rest is used)" or " - ignored"))
			end
			if v then
				if e[1] == "m" then fx.modes[e[2]] = v else fx.players[e[2]] = v end
			end
		end
		s.fxN = (s.fxN or 0) + 1
		shared.pcFx = fx
		shared.pcFxN = s.fxN
	end
end

-- (server) the channel p talked into at any moment since t0 (the tx log), or nil
function PC.txDuring(p, t0)
	local s = PC.S()
	local log = s.txLog and s.txLog[p]
	if not log then return nil end
	local best
	for i, e in ipairs(log) do
		local nextT = log[i + 1] and log[i + 1].t or math.huge
		if e.ch ~= "" and nextT >= t0 then best = e.ch end
	end
	return best
end

-- ---- THE CLIENT: shared -> c.dw, once a tick (the device list only when its number changed), plus the local test
-- devices and talk of /dummy voice walkie / megaphone / pa (voice.lua: vo.testDevs, vo.testTx)
function PC.devClientTick(now)
	local c = PC.C()
	local dw = c.dw or {devs = {}, tx = {}}
	local n = shared.pcDevN or 0
	if n ~= c.devN then
		c.devN = n
		c.devShared = shared.pcDev or {}
	end
	local vo = c.voice
	local function merged(base, extra)
		if not (extra and next(extra)) then return base end
		local m = {}
		for k, d in pairs(base) do m[k] = d end
		for k, d in pairs(extra) do m[k] = d end
		return m
	end
	dw.devs = merged(c.devShared or {}, vo and vo.testDevs)
	dw.tx = merged(shared.pcTx or {}, vo and vo.testTx)
	dw.lobby, dw.chan = PC.lobby(), shared.pcChan or {}
	local fn = shared.pcFxN or 0
	if fn ~= c.fxN then
		c.fxN = fn
		c.fx = shared.pcFx or {}
	end
	c.dw = dw
	PC.devBubbleTick(now)
end

-- the device world of this side: the host's server (s.dw) or this game (c.dw)
function PC.devWorld(server)
	if server then return PC.S().dw or {devs = {}, tx = {}} end
	local c = PC.c
	return (c and c.dw) or {devs = {}, tx = {}}
end

-- a channel's kind: its first device's (nil: no device on it)
function PC.chanKind(dw, ch)
	local best
	for name, d in pairs(dw.devs) do
		if d.chan == ch and (not best or name < best) then best = name end
	end
	return best and dw.devs[best].kind or nil
end

-- q's transmission now: channel, kind - or nil (not talking into a device; Global; the lobby; the dead). tx: a channel to
-- use instead of the registry's tx.<q> (the host, for a spoken line said while the button was held)
function PC.txOf(dw, q, mode, tx)
	if dw.lobby or mode == "g" or mode == "d" then return nil end
	if (dw.chan or {})[q] then return nil end                         -- (the dead talk only to their channel)
	local t = tx or dw.tx[q]
	if not t or t == "" then return nil end
	local kind = PC.chanKind(dw, t)
	if not kind then return nil end                                    -- (a channel with no device: nowhere)
	return t, kind
end

-- the devices q's transmission comes out of: a list of {name, dev} (the channel's, without a walkie q carries), or nil
function PC.devTargets(dw, q, chan)
	local list = {}
	for name, d in pairs(dw.devs) do
		if d.chan == chan and not (d.kind == "radio" and d.at and d.at.t == "player" and d.at.p == q) then
			list[#list + 1] = {name = name, dev = d}
		end
	end
	if #list == 0 then return nil end
	table.sort(list, function(a, b) return a.name < b.name end)
	return list
end

-- a device's points now (feet + 1.3 m for a carried one; a body's centre)
function PC.devPoints(dev)
	local at = dev.at
	if not at then return {} end
	if at.t == "pos" then return at.pts end
	if at.t == "player" then
		local f = PC.speakerPos(at.p)
		return f and {VecAdd(f, Vec(0, 1.3, 0))} or {}
	end
	if at.t == "body" then
		if IsHandleValid then
			local okV, valid = pcall(IsHandleValid, at.h)
			if not (okV and valid) then return {} end
		end
		local okB, lo, hi = pcall(GetBodyBounds, at.h)
		if okB and type(lo) == "table" and type(hi) == "table" then return {VecScale(VecAdd(lo, hi), 0.5)} end
		local okT, t = pcall(GetBodyTransform, at.h)
		if okT and type(t) == "table" and t.pos then return {t.pos} end
	end
	return {}
end

-- the point of a device nearest to pos, and its distance (nil: none)
function PC.devNearest(dev, pos)
	local best, bd
	for _, pt in ipairs(PC.devPoints(dev)) do
		local d = VecLength(VecSub(pt, pos))
		if not bd or d < bd then best, bd = pt, d end
	end
	return best, bd
end

-- Private's reach (cfg.privateReach > 0): a walkie plays talker q only that close to them
function PC.reachOk(q, kind, pt)
	local r = PC.cfg.privateReach or 0
	if kind ~= "radio" or r <= 0 or not pt then return true end
	local f = PC.speakerPos(q)
	return f ~= nil and VecLength(VecSub(VecAdd(f, Vec(0, 1.3, 0)), pt)) <= r
end

-- ---- A CARRIED LOUDSPEAKER (a megaphone) points where its carrier looks (a voice dummy: at the local player); how much
-- of its reach a point gets: 1 ahead, cfg.hornBack straight behind (as Koetama's loudspeaker "facing" / "back")
function PC.facingOf(p)
	local vd = PC.voiceDummyOf and PC.voiceDummyOf(p)
	if vd then return vd.facing end
	if GetPlayerEyeTransform then
		local ok, t = pcall(GetPlayerEyeTransform, p)
		if ok and type(t) == "table" then
			local okV, v = pcall(TransformToParentVec, t, Vec(0, 0, -1))
			if okV and v then return v end
		end
	end
	return nil
end

function PC.hornFactor(p, at)
	local fw = PC.facingOf(p)
	local f = PC.speakerPos(p)
	if not (fw and f) then return 1 end
	at = at or PC.listenerHead()
	local to = VecSub(at, VecAdd(f, Vec(0, 1.3, 0)))
	local l, lf = VecLength(to), VecLength(fw)
	if l < 0.5 or lf < 1e-6 then return 1 end
	local cos = (to[1] * fw[1] + to[2] * fw[2] + to[3] * fw[3]) / (l * lf)
	local back = PC.cfg.hornBack
	return back + (1 - back) * (1 + cos) / 2
end

local function carried(dev) return dev.at and dev.at.t == "player" and dev.at.p or nil end

-- who is near q's transmission (a set; never q): within a device's far + slack (a walkie: within Private's reach of q).
-- The host (text: cfg.devSlack) and the talker's game (voice: "transmit")
function PC.devHearers(dw, q, chan, slack, posOf)
	local out = {}
	local tg = chan and PC.devTargets(dw, q, chan)
	if not tg then return out end
	for _, r in ipairs(PC.allPlayers()) do
		local pos = r ~= q and posOf(r)
		if pos then
			for _, t in ipairs(tg) do
				local pt, d = PC.devNearest(t.dev, pos)
				local _, outer = PC.devRanges(t.dev)
				if d and d <= outer + slack and PC.reachOk(q, t.dev.kind, pt) then out[r] = true; break end
			end
		end
	end
	return out
end

-- (host, server.pc_say / pc_live) a line of p in mode ch: the channel and kind it goes out on, and who near a device
-- gets it. vs: a spoken line's start (server clock): the button may have been let go before its end arrives
function PC.devLine(p, ch, vs)
	local dw = PC.devWorld(true)
	local tx = vs and PC.txDuring(p, vs - 0.5) or nil
	local chan, kind = PC.txOf(dw, p, ch, tx)
	if not chan then return nil, nil, {} end
	local function posOf(r)
		local ok, t = pcall(GetPlayerTransform, r)
		return ok and t and VecAdd(t.pos, Vec(0, 1.7, 0)) or nil
	end
	return chan, kind, PC.devHearers(dw, p, chan, PC.cfg.devSlack, posOf)
end

-- ---- SOUND EFFECTS: a mode's or kind's (proxchat.effects.<name>) with the player's own over it
-- (proxchat.effects.player.<p>); nil: the defaults (a device's preset; plain for a voice)
function PC.fxFor(id, p)
	local c = PC.c
	local fx = c and c.fx
	if not fx then return nil end
	local a = fx.modes and fx.modes[id]
	local b = p and fx.players and fx.players[p]
	if not a and not b then return nil end
	local out = {}
	for k, v in pairs(a or {}) do out[k] = v end
	for k, v in pairs(b or {}) do out[k] = v end
	return out
end

-- ---- VOICE (the feed)
local function rnd(x, d) local m = 10 ^ d; return math.floor(x * m + 0.5) / m end
local function vecOut(v) return PC.jsonArray({rnd(v[1], 2), rnd(v[2], 2), rnd(v[3], 2)}) end

-- how muffled a point is from here (the walls logic, chat_core's PC.wallStateAt), and how far it sounds
function PC.devMuffle(key, pt, reach)
	local cfg = PC.cfg
	local d = VecLength(VecSub(pt, PC.listenerHead()))
	local w = PC.wallStateAt and PC.wallStateAt(key, pt, reach)
	if not (w and w.blocked) then return 0, d end
	local through = d / cfg.wallFactor
	if w.around and w.around <= through then return cfg.voiceAroundMuffle, math.max(d, w.around) end
	return cfg.voiceWallMuffle, through
end

-- (listener) where q's voice also comes out for me: the speaker's "via" (a JSON array), or nil
function PC.devVia(q, mode)
	local cfg = PC.cfg
	local dw = PC.devWorld()
	local chan = PC.txOf(dw, q, mode)
	local tg = chan and PC.devTargets(dw, q, chan)
	if not tg then return nil end
	local me = PC.listenerHead()
	local list = {}
	for _, t in ipairs(tg) do
		local dev = t.dev
		local _, _, near, far = PC.devRanges(dev)
		local reach = far + cfg.voiceToSlack
		local pts = {}
		for _, pt in ipairs(PC.devPoints(dev)) do
			local d = VecLength(VecSub(pt, me))
			if d <= reach and PC.reachOk(q, dev.kind, pt) then pts[#pts + 1] = {pt = pt, d = d} end
		end
		if #pts > 0 then
			table.sort(pts, function(a, b) return a.d < b.d end)
			local e = {device = dev.kind, range = PC.jsonArray({rnd(near, 1), rnd(far, 1)}), signal = dev.signal}
			if dev.kind == "pa" and #pts > 1 then
				e.positions = PC.jsonArray({})
				for i = 1, math.min(#pts, cfg.devMaxPts) do e.positions[i] = vecOut(pts[i].pt) end
			else
				e.position = vecOut(pts[1].pt)
			end
			if dev.kind == "loudspeaker" and carried(dev) then              -- (a megaphone: it points where they look)
				local fw = PC.facingOf(carried(dev))
				if fw and VecLength(fw) > 1e-6 then e.facing = vecOut(VecNormalize(fw)) end
			end
			local muffle = PC.devMuffle("dev:" .. t.name, pts[1].pt, reach)
			if muffle > 0 then e.muffle = rnd(muffle, 2) end
			local fx = PC.fxFor(PC.KIND_ID[dev.kind], q)
			if dev.reverb then fx = fx or {}; if fx.reverb == nil then fx.reverb = dev.reverb end end
			e.effects = fx
			list[#list + 1] = {e = e, d = pts[1].d}
		end
	end
	if #list == 0 then return nil end
	table.sort(list, function(a, b) return a.d < b.d end)
	local out = PC.jsonArray({})
	for i = 1, math.min(#list, cfg.devMaxVia) do out[i] = list[i].e end
	return out
end

-- the listener's ears for the feed (positions in "via" need it): the character's head (PC.listenerHead: where the mod
-- measures every distance from, its walls rays too), with the camera's axes (panning follows the look)
function PC.devListener()
	local cam = GetCameraTransform()
	local function dir(v)
		local ok, r = pcall(TransformToParentVec, cam, v)
		return vecOut(ok and r or v)
	end
	return {position = vecOut(PC.listenerHead()), forward = dir(Vec(0, 0, -1)), right = dir(Vec(1, 0, 0)), up = dir(Vec(0, 1, 0))}
end

-- (talker) who my voice also goes to through a device now (the feed's "transmit"), or nil (not transmitting): the
-- players near a device of my channel (far + cfg.voiceToSlack); not the dead (they hear everyone through "to" anyway)
function PC.devTransmit()
	local me = GetLocalPlayer()
	local dw = PC.devWorld()
	local chan = PC.txOf(dw, me, PC.voiceMode())
	if not chan then return nil end
	local set = PC.devHearers(dw, me, chan, PC.cfg.voiceToSlack, function(r)
		local f = PC.speakerPos(r)
		return f and VecAdd(f, Vec(0, 1.7, 0)) or nil
	end)
	local ids = {}
	for r in pairs(set) do if not (dw.chan or {})[r] then ids[#ids + 1] = r end end
	table.sort(ids)
	return PC.jsonArray(ids)
end

-- ---- TEXT (client). A line q said into a channel (m.dv, m.dk from the host): a bubble over each device in reach
-- (c.devB[name]), and its history line when the talker's own bubble gave none (or less)
function PC.devOf(name) return PC.devWorld().devs[name] end

-- how far a device "sounds" from here: walls, and a megaphone's horn
function PC.devHearDist(name, dev, pt)
	local _, _, _, far = PC.devRanges(dev)
	local _, d = PC.devMuffle("dev:" .. name, pt, far + PC.cfg.soundGrace)
	if dev.kind == "loudspeaker" and carried(dev) then d = d / math.max(0.05, PC.hornFactor(carried(dev))) end
	return d
end

-- how this player hears a device bubble's line NOW: level ("full" / "mumble" / nil), share of letters, distance
function PC.devHeardNow(b)
	local dev = PC.devOf(b.key)
	if not dev then return nil end
	local pt = PC.devNearest(dev, PC.listenerHead())
	if not pt then return nil end
	local d = PC.devHearDist(b.key, dev, pt)
	local inner, outer = PC.devRanges(dev)
	if d <= inner then return "full", 1, d end
	if d <= outer then return "mumble", clamp((outer - d) / math.max(0.5, outer - inner), 0, 1) * PC.cfg.garbleMax, d end
	return nil, 0, d
end

local function hasWords(b) return b.level == "full" or b.level == "mumble" end

-- PC.receive's hook: the device part of a line. mode: its mode; b: the talker's own bubble (nil: none). Returns true when
-- this player gets anything of it through a device.
function PC.devReceive(m, mode, b)
	local c, cfg = PC.C(), PC.cfg
	if not m.dv or m.p == GetLocalPlayer() then return false end
	local tg = PC.devTargets(PC.devWorld(), m.p, m.dv)
	if not tg then return false end
	local spoken = m.v == true
	local direct = b and b.level == "full"
	local here = PC.listenerHead()
	local cand = {}
	for _, t in ipairs(tg) do
		local pt, d = PC.devNearest(t.dev, here)
		local _, outer = PC.devRanges(t.dev)
		if d and d <= outer + cfg.devSlack and PC.reachOk(m.p, t.dev.kind, pt)
			then
			cand[#cand + 1] = {t = t, d = d}
		end
	end
	table.sort(cand, function(x, y) return x.d < y.d end)
	local timed = spoken and m.vw ~= nil and tonumber(m.vs) ~= nil
	local made = {}
	for i = 1, math.min(#cand, cfg.devBubbles) do
		local t = cand[i].t
		local nb = {key = t.name, kind = t.dev.kind, p = m.p, id = m.id, t = GetTime(), full = m.text, mode = mode, name = m.name,
			level = "none", hidden = true, bestF = -1, voice = spoken, holder = carried(t.dev),
			seed = m.vu and PC.voiceSeed and PC.voiceSeed(m.p, m.vu) or m.id,
			liveHold = spoken and m.vu ~= nil and c.liveSeen ~= nil and c.liveSeen[m.p] == m.vu or nil}
		nb.scrollT = nb.t
		if timed then                                                    -- (each word as heard from the device when said)
			local us, times = PC.voiceTimed(m.text, m.vw)
			local text, clear, fr
			if times then
				local inner, outer = PC.devRanges(t.dev)
				text, clear, fr = PC.voiceHeardIn("dev:" .. t.name, us, times, tonumber(m.vs), inner, outer)
			end
			if text then
				nb.fixed, nb.hidden, nb.full = true, false, text
				if clear then nb.level, nb.text = "full", text else nb.level, nb.text, nb.mumble, nb.fracs = "mumble", "...", true, fr end
				made[#made + 1] = nb
			end
		else
			made[#made + 1] = nb
		end
	end
	if #made == 0 then return false end
	c.devB = c.devB or {}
	for _, nb in ipairs(made) do
		c.devB[nb.key] = nb
		PC.devUpdate(nb, true)
	end
	-- a typed line (or a spoken one babbled to a player without real voices) babbles from the nearest device heard
	local spokenHeard = spoken and PC.hearsRealVoices and PC.hearsRealVoices()
	if not spokenHeard and not direct and not (m.t and shared.pcNow and shared.pcNow - m.t > cfg.lateAge) then
		for _, nb in ipairs(made) do
			if hasWords(nb) then PC.devBabble(nb, m.text); break end
		end
	end
	return true
end

-- the history entry the talker's own bubble made for this message (same id), if any
function PC.devDirectEntry(b)
	local c = PC.C()
	for _, t in ipairs({c.bubbles, c.prevBubbles}) do
		local tb = t[b.p]
		if tb and tb.id == b.id and tb.entry then return tb.entry end
	end
	return nil
end

-- a device bubble's level (typed lines: by the distance to the device now, as a talker's bubble by the distance to them);
-- its history line: the talker's own when that one heard all of it, else this one (one line a message: c.devEntry[id])
function PC.devUpdate(b, fresh)
	local c = PC.C()
	if not b.fixed then
		local level, f = PC.devHeardNow(b)
		if level and PC.LEVEL[level] > PC.LEVEL[b.level] then
			b.level, b.hidden = level, false
			b.mumble = level == "mumble"
			b.text = level == "full" and b.full or "..."
			b.bestF = -1
			if not fresh and level == "full" then b.t = math.max(b.t, GetTime() - PC.bubbleLife(b) + PC.cfg.revealHold) end
		end
		if b.level == "mumble" and (f or 0) > b.bestF + 1e-6 then b.bestF = f end
	end
	if b.hidden or not hasWords(b) then return end
	local direct = PC.devDirectEntry(b)
	if direct and not direct.far then return end                       -- (the talker's own line heard it all)
	local htext, far = PC.histText(b), b.level ~= "full"
	c.devEntry = c.devEntry or {}
	local e = direct or c.devEntry[b.id]
	if e then
		if e.far or not far then
			e.text, e.far, e.via = htext, far, b.kind
			e.trF, e.trSeed = PC.trShare(b, b.bestF), b.seed or 0
		end
	else
		e = {ch = b.mode, p = b.p, name = b.name, text = htext, far = far, me = false, voice = b.voice, via = b.kind,
			shout = b.mode == "y", trF = PC.trShare(b, b.bestF), trSeed = b.seed or 0}
		PC.addHist(e)
	end
	c.devEntry[b.id] = e
	if PC.trWant then PC.trWant(e, b) end                                -- (garbled lines too: their translation garbled as much)
end

-- (each tick) device bubbles: reveal by distance, gone with their time or their device
function PC.devBubbleTick(now)
	local c = PC.C()
	for key, b in pairs(c.devB or {}) do
		local gone = now - b.t > PC.bubbleLife(b) + (b.extra or 0) or not PC.devOf(key)   -- (its device string cleared: at once)
		if gone then c.devB[key] = nil else PC.devUpdate(b) end
	end
end

-- ONE BUBBLE between a talker and the megaphone they carry (a loudspeaker at player:<talker>): the fuller of the two
-- (PC.LEVEL: full > garbled > nothing), the megaphone's when they are equal - for finished and typed lines (PC.devCovers
-- for the talker's own bubble, PC.devDrawBubbles for the megaphone's, both from these two levels) and for live words
-- (PC.devLiveWins / PC.devLiveFlush: the talker's live bubble, "..." counting 0.5, against the megaphone's).
-- the level at which this player sees the talker's own bubble of message id now (0: not shown), as drawBubbles decides
function PC.ownShownLevel(p, id)
	local c = PC.C()
	if p == GetLocalPlayer() then return 0 end
	for _, t in ipairs({c.bubbles, c.prevBubbles}) do
		local b = t[p]
		if b and b.id == id then
			if b.hidden or (b.voice and c.hideVoiceBubbles) or not PC.inReach(p, b) then return 0 end
			return PC.LEVEL[b.level] or 0
		end
	end
	return 0
end

-- the level at which this player sees a megaphone bubble now (0: not shown)
function PC.megaShownLevel(db)
	local c = PC.C()
	if db.hidden or (db.voice and c.hideVoiceBubbles) or not PC.devHeardNow(db) then return 0 end
	return PC.LEVEL[db.level] or 0
end

-- (chat_core's drawBubbles) the talker's own bubble b is left out while their megaphone's shows the line at least as fully
function PC.devCovers(p, b)
	local c = PC.c
	for _, db in pairs(c and c.devB or {}) do
		if db.p == p and db.id == b.id and db.holder == p then
			local m = PC.megaShownLevel(db)
			if m > 0 and m >= (PC.LEVEL[b.level] or 0) then return true end
		end
	end
	return false
end

-- the babble of a typed line from a device (band-passed clips: radio for a walkie, horn for a loudspeaker or PA)
function PC.devBabble(b, text)
	local dev = PC.devOf(b.key)
	if not dev then return end
	local key = "dev:" .. b.key
	PC.babbleSay(b.p, text, nil, b.kind == "radio" and "radio" or "horn", key)
	local q = PC.C().babble.queue[key]
	if not q then return end
	q.at = function() return (PC.devNearest(dev, PC.listenerHead())) end
	local _, _, near, far = PC.devRanges(dev)
	q.near, q.far = near, far
	if b.mode == "w" then q.vol, q.shoutVol = q.vol * 0.55, q.shoutVol * 0.55 end
end

-- where a device bubble goes, in the world over the device: {pos = the device (its distance), top = where the bubble
-- points}. A carried one: over its carrier's head, as their own bubbles are. The listener's OWN walkie: as the own-bubble
-- rule (third person, Settings' "Your own bubble"); in first person none (the chat's feed shows the line). nil: none.
-- big: a loudspeaker's or a PA's - heard from far off, its bubble was too small to read (the user, 2026-10-22: "the speech
-- bubbles from speakerphone should be bigger than others"): PC.bubbleLayout sizes it up (cfg.bigBubbleMin / Boost)
function PC.devAnchor(dev, pt)
	local big = dev.kind == "loudspeaker" or dev.kind == "pa"
	local holder = carried(dev)
	if holder then
		if holder == GetLocalPlayer() and not (GetBool("game.thirdperson") and not PC.C().hideOwn) then return nil end
		local f = PC.speakerPos(holder)
		return f and {pos = pt, top = VecAdd(f, Vec(0, 2.25, 0)), big = big} or nil
	end
	return {pos = pt, big = big}
end

-- (chat_core's drawBubbles) the device bubbles, each in its device's style, over the device; in reach only
function PC.devDrawBubbles(add, now)
	local c = PC.C()
	c.devShown = {}
	for key, b in pairs(c.devB or {}) do
		local own = b.holder == b.p and PC.ownShownLevel(b.p, b.id) or 0   -- (the talker's own, fuller: theirs only)
		if not b.hidden and not (b.voice and c.hideVoiceBubbles) and not c.muted[b.p] and own <= PC.megaShownLevel(b) then
			local level, f = PC.devHeardNow(b)
			local dev = PC.devOf(key)
			local pt = dev and PC.devNearest(dev, PC.listenerHead())
			local anchor = level and pt and PC.devAnchor(dev, pt)
			if anchor then
				local text = b.text
				if b.level == "mumble" then
					text = b.fixed and PC.garble(b.full, 0, b.seed or 0, math.floor(now * 3), b.fracs)
						or PC.garble(b.full, f or 0, b.seed or 0, math.floor(now * 3))
				end
				local life = PC.bubbleLife(b) + (b.extra or 0)
				local a = math.max(0, math.min(1, (life - (now - b.t)) / 1.2))
				local L = PC.bubbleLayout(b.p, text, false, a, false, b.mode == "w", b.level == "mumble", b.scrollT or b.t, b.liveHold,
					PC.trShown(b.tr, PC.trShare(b, f), b.seed or 0, math.floor(now * 3)), b.trT, anchor)
				if L then
					b.extra = math.max(b.extra or 0, L.scrollTime)
					L.dev = b.kind
					c.devShown[#c.devShown + 1] = {key = key, kind = b.kind, text = text, at = anchor.top or anchor.pos}   -- (the tests)
					add(L)
				end
			end
		end
	end
end

-- (voice.lua's live bubbles) a talker's live words over the devices of their channel (l.dv): only the words said while
-- this player was in reach of the device. A talker's own megaphone's is held back (c.megaLive[p]) for voice.lua to weigh
-- against the talker's live bubble (PC.devLiveWins), then added by PC.devLiveFlush if it won
function PC.devLiveBubbles(add)
	local c = PC.C()
	c.megaLive = {}
	if c.hideVoiceBubbles then return end
	local me = GetLocalPlayer()
	local dw = PC.devWorld()
	for p in pairs(c.live or {}) do
		local live = PC.voiceLiveOf(p)
		local tg = live and live.dv and p ~= me and not c.muted[p] and PC.devTargets(dw, p, live.dv)
		for _, t in ipairs(tg or {}) do
			local pt = PC.devNearest(t.dev, PC.listenerHead())
			local inner, outer = PC.devRanges(t.dev)
			local d = pt and PC.devHearDist(t.name, t.dev, pt)
			local anchor = d and d <= outer and PC.reachOk(p, t.dev.kind, pt) and PC.devAnchor(t.dev, pt)
			if anchor then
				local text, fr = live.text, nil
				if live.times and live.start then
					local _
					text, _, fr = PC.voiceHeardIn("dev:" .. t.name, live.us, live.times, live.start, inner, outer)
				elseif d > inner then
					text = PC.garble(text, clamp((outer - d) / math.max(0.5, outer - inner), 0, 1) * PC.cfg.garbleMax, PC.voiceSeed(p, live.u), math.floor(GetTime() * 3))
				end
				if text then
					local garbled = false
					for _, f in ipairs(fr or {}) do if f < 1 then garbled = true; break end end
					if garbled then text = PC.garble(text, 0, PC.voiceSeed(p, live.u), math.floor(GetTime() * 3), fr) end
					local far = garbled or d > inner
					local L = PC.bubbleLayout(p, PC.voiceTail(text, PC.cfg.voiceLiveShow), false, 1, false, live.ch == "w", far,
						nil, true, nil, nil, anchor)
					if L then
						L.dev = t.dev.kind
						if carried(t.dev) == p then                         -- (its talker's megaphone: weighed first)
							local level = far and 1 or 2
							if not c.megaLive[p] or level > c.megaLive[p].level then c.megaLive[p] = {L = L, level = level} end
						else
							add(L)
						end
					end
				end
			end
		end
	end
end

-- (voice.lua) the talker p's live bubble would show at level own (2 words, 1 garbled, 0.5 "..."): true when their
-- megaphone's live bubble wins (at least as full) and theirs is left out; else the megaphone's is dropped
function PC.devLiveWins(p, own)
	local c = PC.c
	local m = c and c.megaLive and c.megaLive[p]
	if not m then return false end
	if m.level >= own then return true end
	c.megaLive[p] = nil
	return false
end

-- (chat_core's drawBubbles, after voice.lua's live bubbles) the megaphones' live bubbles that won
function PC.devLiveFlush(add)
	local c = PC.c
	for _, m in pairs(c and c.megaLive or {}) do add(m.L) end
	if c then c.megaLive = {} end
end

-- (PC.voiceSample) the distance to each device near enough to matter (walls and the horn: only for a channel someone
-- talks into now); put(key, d)
function PC.devSample(put)
	local c = PC.C()
	local dw = PC.devWorld()
	local busy = {}
	for _, l in pairs(c.live or {}) do if l.dv then busy[l.dv] = true end end
	for _, ch in pairs(dw.tx) do busy[ch] = true end
	local here = PC.listenerHead()
	for name, dev in pairs(dw.devs) do
		local pt, d = PC.devNearest(dev, here)
		local _, outer = PC.devRanges(dev)
		if pt and d <= outer + 40 then
			put("dev:" .. name, busy[dev.chan] and PC.devHearDist(name, dev, pt) or d)
		end
	end
end
