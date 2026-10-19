-- VOICE (a prototype, Oct 2026). Real voice, speech-to-text and translation come from KOETAMA, a companion app (the
-- "helper" below; github.com/AgeOfAlgorithms/koetama). Its PROTOCOL.md ("protocol 2": "The objects", "Real voices",
-- "Translation", "Transport: files") is the contract for this file. Without Koetama this file does one thing: once a
-- second it asks whether the helper's "on" file is there (one HasFile).
-- A script has no microphone, no network and no file writes, so the two talk through files, on each player's own PC:
--
-- GAME -> KOETAMA: the FEED, savegame.mod.pcvx.f = the lower-case hex of one JSON object (PC.voiceFeed; the game writes
-- savegame.xml within a frame). Written every cfg.voiceFeed s while there are voices or a voice room, cfg.voiceFeedIdle s
-- otherwise, at once when a line is queued for translation or the talk key changes (PC.voiceFeedNow: at most one
-- extra write a frame), and once more when nothing is left (listen "off", no room, no speakers), then not at all:
--   {"type":"feed","seq":n,"session":sid,"ack":n,"ping":n,"volume":0..1,"listen":"off"|"always"|"push_to_talk",
--    "talk_key":bool,"lang":"en","live":bool,"me":id,"speakers":[...],
--    "room":"<32 hex>","key":"<64 hex>","to":[ids],"region":"",          (only with a room)
--    "to_translate":[{"id","text"}]}                                     (only while lines wait for a translation)
--     seq / session / ack / ping: the link (a new session each level start; ack = the last message read; Koetama
--              answers ping n with the file pcvx_p<n % 1000>)
--     listen   "off" without Koetama; "push_to_talk" (talk_key true while the key is held) or "always" (its speech
--              detector finds each line). Below: THE TALK KEY
--     speakers {"id","gain","azimuth","elevation","muffle"} per voice this player hears now (PC.voiceHear: the chat's
--              ranges, buffer and walls); real players (PC.voicePlayers) only with a room; the voice dummies add
--              "test_voice": 1..3 and "talking": bool (ids PC.VDUMMY + 0..2)
--              A real player's entry carries "volume" (0..2, this player's own setting for them, PC.playerVolume) only
--              when it is not 1: Koetama multiplies it on top of everything (distance, walls, their devices)
--     room / key: shared.pcVoiceRoom, the first room a player's Koetama made (server.pc_room); to: who gets MY voice
--              now (PC.voiceTo); region: the host's "Voice server"
--     to_translate: the lines waiting for a translation (TRANSLATION; what into is Koetama's own setting)
-- THE VOICE MODE of every player is known to every game (server.pc_vmode -> shared.pcVMode[p]: "w" / "s" / "y" / "g",
-- the player's choice; the lobby overrides it): a listener works out how loud a real player is with it (PC.voiceHear).
--
-- KOETAMA -> GAME: files next to the mod's folder (PC.VOICE_IO = "MOD/../pcvx_"; a script can ask HasFile and Spawn a
-- prefab file):
--   pcvx_on          Koetama runs (removed when it stops). With pcvx_v5 / pcvx_v6 next to it: a Koetama before 0.4.0,
--                    "too outdated" (PC.voiceHelper)
--   pcvx_p<n>        its answer to ping n: it is alive (an "on" file left by a crash is not)
--   pcvx_t<n>.xml    object n (1, 2, ... per session): a prefab <body tags="pcvx j=<hex of a JSON object>"/>; the script
--                    Spawns it, reads j, deletes what it made, acks n (PC.voiceReadMsg) and acts on its type
--                    (PC.voiceMessage): "hello" (first each session; its features: no "translate" = the Translate tab
--                    says "too outdated"), "speech" (kind "start": the player started talking - their head bobs at once,
--                    PC.voiceTalk; "live": the words so far, only ever growing; "final": the finished line, maybe "" =
--                    nothing made out; times = each UNIT's start in s after the line's audio began, ago = how long ago
--                    that was - kept inside the mod as 4 hex digits per unit in 1/100 s, PC.voiceTimesHex), "room" (a voice
--                    room: never shown or said, forwarded to the host, PC.voiceRoomOffer), "voice" (the voice server's
--                    state, PC.voiceNetTick), "translation" (PC.trReply), "translations_status" (PC.trStatus: into + the pairs). Unknown
--                    types: acked and ignored. With word times each listener gets only what was said while they were in
--                    reach (PC.voiceCut): arriving mid-sentence "... the rest", walking away "the start ...".
-- What the player said (the helper's transcript) is then SAID like a typed line, in the current mode,
-- flagged as voice (PC.say(text, mode, true)): the same ranges, history and proxchat.said event; no babble.
-- LIVE words go to the server (server.pc_live, at most every cfg.voiceLiveEvery s) and from there ONLY to the
-- players near enough (ClientCall client.pc_live; the mode's outer range + whisperSlack): instead of the "..."
-- over the speaker's head, the words so far, for players within the mode's words range ("..." in its buffer).
-- Whisper, Speak and Yell alike (a whisper stays private: its words go only to who is near, never into
-- shared); not for Global or the dead (no bubbles there). The finished line replaces them; gone after
-- cfg.voiceLiveLife s without news.
--
-- TRANSLATION: what chat is translated into is the player's setting in Koetama's window ("Translate chat into"); the
-- Translate tab next to Voice shows it (Koetama's translations_status: into, and each pair's state).
-- Every FULL line another player says that goes into this player's history or a bubble - typed, or spoken once
-- finished (never live words), any mode, Global and the dead's channels too - is sent to Koetama (the feed's
-- to_translate) while Koetama runs and translates (not while it says it is off). Koetama translates on this PC (Mozilla's
-- models) and answers with a "translation"; it shows under the original in the history, the feed and its bubble, in its
-- own colour (PC.TR_COLOR). A line heard garbled from a buffer is translated too, and its translation garbled as much
-- (chat_core's PC.trShare / PC.trShown: the same share of its letters shows; walking closer reveals more of both).
--
-- /dummy voice: three VOICE dummies in a row (whisperer, speaker, yeller; green heads), separate from the
-- chat's test dummies (/dummy): they talk in turns of cfg.voiceTurn s - the helper plays a recorded voice
-- for each - so you can walk around them and check direction, the three ranges and the walls.
-- /dummy voice 1 / 2 / 3: one of them 3 m ahead; /dummy voice clear (or /dummy clear): gone.
-- JSON and hex for the link: PC.jsonEncode / PC.jsonDecode / PC.hexEncode / PC.hexDecode (below).

PC.VDUMMY = 2000                                                      -- (speaker ids PC.VDUMMY + 0..2)
PC.VOICE_FEED = "savegame.mod.pcvx.f"
PC.VOICE_IO = "MOD/../pcvx_"
PC.PROTOCOL = 2                                                       -- (Koetama's game protocol this file speaks)

-- ---- JSON AND HEX (protocol 2: the feed is the hex of a JSON object, so is each message's j tag). Small, PUC Lua 5.1.
--   PC.jsonEncode(v) -> string. Strings (invalid UTF-8 bytes become U+FFFD), finite numbers (whole ones without ".0";
--     not finite: null), booleans, PC.JSON_NULL / nil -> null, tables: an ARRAY when marked with PC.jsonArray(t) or
--     t[1] ~= nil (an empty one must be marked to come out as []), else an object (string keys, sorted, "type" first).
--   PC.jsonDecode(s) -> the value, or nil for anything malformed (never raises). Arrays come back marked
--     (PC.jsonArray), null as PC.JSON_NULL (so arrays have no holes), \uXXXX (surrogate pairs too) as UTF-8.
--   PC.hexEncode(s) -> lower-case hex; PC.hexDecode(h) -> the bytes, or nil (odd length, not hex; either case is read).
PC.JSON_NULL = setmetatable({}, {__tostring = function() return "null" end})
local JSON_ARRAY = {__jsonArray = true}
function PC.jsonArray(t) return setmetatable(t or {}, JSON_ARRAY) end
function PC.jsonIsArray(t) return type(t) == "table" and getmetatable(t) == JSON_ARRAY end

local HEX_OF, BYTE_OF = {}, {}
for b = 0, 255 do
	local h, ch = string.format("%02x", b), string.char(b)
	HEX_OF[ch] = h
	local hi, lo = h:sub(1, 1), h:sub(2, 2)
	for _, x in ipairs({hi, hi:upper()}) do for _, y in ipairs({lo, lo:upper()}) do BYTE_OF[x .. y] = ch end end
end
function PC.hexEncode(s) return (tostring(s):gsub(".", HEX_OF)) end
function PC.hexDecode(h)
	if type(h) ~= "string" or #h % 2 == 1 or h:find("[^%x]") then return nil end
	return (h:gsub("%x%x", BYTE_OF))
end

local JSON_ESC = {['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t"}
for b = 0, 31 do
	local ch = string.char(b)
	if not JSON_ESC[ch] then JSON_ESC[ch] = string.format("\\u%04x", b) end
end
local BAD_UTF8 = "\239\191\189"                                         -- (U+FFFD)
-- one run of non-ASCII bytes (a lead byte and its continuation bytes): itself when it is one valid UTF-8 character
local function utf8Seq(m)
	local c, n = m:byte(1), #m
	local len = (c >= 0xC2 and c <= 0xDF and 2) or (c >= 0xE0 and c <= 0xEF and 3) or (c >= 0xF0 and c <= 0xF4 and 4) or 0
	if len == 0 then return string.rep(BAD_UTF8, n) end
	if n > len then return utf8Seq(m:sub(1, len)) .. string.rep(BAD_UTF8, n - len) end
	if n < len then return string.rep(BAD_UTF8, n) end
	local b2 = m:byte(2)
	if (c == 0xE0 and b2 < 0xA0) or (c == 0xED and b2 > 0x9F) or (c == 0xF0 and b2 < 0x90) or (c == 0xF4 and b2 > 0x8F) then
		return string.rep(BAD_UTF8, n)                                     -- (overlong, a surrogate, past U+10FFFF)
	end
	return m
end
local strCache, strCacheN = {}, 0                                       -- (the feed repeats its strings 20 times a second)
local function jsonStr(s)
	local e = strCache[s]
	if e then return e end
	e = s
	if e:find("[\128-\255]") then e = e:gsub("[\128-\255][\128-\191]*", utf8Seq) end
	e = '"' .. e:gsub('[%z\1-\31"\\]', JSON_ESC) .. '"'
	if strCacheN >= 128 then strCache, strCacheN = {}, 0 end
	strCache[s], strCacheN = e, strCacheN + 1
	return e
end
local function jsonNum(n)
	if n ~= n or n == math.huge or n == -math.huge then return "null" end
	if n == math.floor(n) and math.abs(n) < 1e15 then return string.format("%.0f", n) end
	return string.format("%.14g", n)
end
local function keyOrder(a, b)
	if a == "type" then return b ~= "type" end
	if b == "type" then return false end
	return a < b
end
local function jsonEnc(v, out, depth)
	local t = type(v)
	if t == "string" then out[#out + 1] = jsonStr(v)
	elseif t == "number" then out[#out + 1] = jsonNum(v)
	elseif t == "boolean" then out[#out + 1] = v and "true" or "false"
	elseif t ~= "table" or v == PC.JSON_NULL or depth > 32 then out[#out + 1] = "null"
	elseif getmetatable(v) == JSON_ARRAY or v[1] ~= nil then
		out[#out + 1] = "["
		for i = 1, #v do
			if i > 1 then out[#out + 1] = "," end
			jsonEnc(v[i], out, depth + 1)
		end
		out[#out + 1] = "]"
	else
		local keys = {}
		for k in pairs(v) do if type(k) == "string" then keys[#keys + 1] = k end end
		table.sort(keys, keyOrder)
		out[#out + 1] = "{"
		for i, k in ipairs(keys) do
			if i > 1 then out[#out + 1] = "," end
			out[#out + 1] = jsonStr(k)
			out[#out + 1] = ":"
			jsonEnc(v[k], out, depth + 1)
		end
		out[#out + 1] = "}"
	end
end
function PC.jsonEncode(v)
	local out = {}
	jsonEnc(v, out, 0)
	return table.concat(out)
end

local function utf8Char(cp)
	if cp < 0x80 then return string.char(cp) end
	if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
	if cp < 0x10000 then return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64) end
	return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64, 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end
local JSON_UNESC = {['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t"}
local function jsonSkip(s, i) return s:find("[^ \t\r\n]", i) or #s + 1 end
local function jsonDecStr(s, i)                                         -- (s[i] is the opening quote) -> string, next i
	local out = {}
	i = i + 1
	while true do
		local j = s:find('[%z\1-\31"\\]', i)
		if not j then return nil end
		out[#out + 1] = s:sub(i, j - 1)
		local ch = s:sub(j, j)
		if ch == '"' then return table.concat(out), j + 1 end
		if ch ~= "\\" then return nil end                                  -- (a raw control character)
		local e = s:sub(j + 1, j + 1)
		if e == "u" then
			local h = s:match("^%x%x%x%x", j + 2)
			if not h then return nil end
			local cp = tonumber(h, 16)
			i = j + 6
			if cp >= 0xD800 and cp <= 0xDBFF then                          -- (a surrogate pair: one character)
				local h2 = s:match("^\\u(%x%x%x%x)", i)
				local lo = h2 and tonumber(h2, 16)
				if lo and lo >= 0xDC00 and lo <= 0xDFFF then
					cp, i = 0x10000 + (cp - 0xD800) * 1024 + (lo - 0xDC00), i + 6
				else
					cp = 0xFFFD
				end
			elseif cp >= 0xDC00 and cp <= 0xDFFF then
				cp = 0xFFFD
			end
			out[#out + 1] = utf8Char(cp)
		elseif JSON_UNESC[e] then
			out[#out + 1] = JSON_UNESC[e]
			i = j + 2
		else
			return nil
		end
	end
end
local jsonDec
local function jsonDecNum(s, i)
	local _, e = s:find("^-?%d+", i)
	if not e then return nil end
	local _, f = s:find("^%.%d+", e + 1)
	if f then e = f end
	local _, x = s:find("^[eE][-+]?%d+", e + 1)
	if x then e = x end
	local n = tonumber(s:sub(i, e))
	if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
	return n, e + 1
end
jsonDec = function(s, i, depth)                                         -- -> value, next i (nil: malformed)
	if depth > 64 then return nil end
	i = jsonSkip(s, i)
	local c = s:sub(i, i)
	if c == '"' then return jsonDecStr(s, i) end
	if c == "{" then
		local obj = {}
		i = jsonSkip(s, i + 1)
		if s:sub(i, i) == "}" then return obj, i + 1 end
		while true do
			if s:sub(i, i) ~= '"' then return nil end
			local k, v
			k, i = jsonDecStr(s, i)
			if not k then return nil end
			i = jsonSkip(s, i)
			if s:sub(i, i) ~= ":" then return nil end
			v, i = jsonDec(s, i + 1, depth + 1)
			if v == nil then return nil end
			obj[k] = v
			i = jsonSkip(s, i)
			c = s:sub(i, i)
			if c == "}" then return obj, i + 1 end
			if c ~= "," then return nil end
			i = jsonSkip(s, i + 1)
		end
	end
	if c == "[" then
		local arr, n = PC.jsonArray({}), 0
		i = jsonSkip(s, i + 1)
		if s:sub(i, i) == "]" then return arr, i + 1 end
		while true do
			local v
			v, i = jsonDec(s, i, depth + 1)
			if v == nil then return nil end
			n = n + 1
			arr[n] = v
			i = jsonSkip(s, i)
			c = s:sub(i, i)
			if c == "]" then return arr, i + 1 end
			if c ~= "," then return nil end
			i = i + 1
		end
	end
	if s:sub(i, i + 3) == "true" then return true, i + 4 end
	if s:sub(i, i + 4) == "false" then return false, i + 5 end
	if s:sub(i, i + 3) == "null" then return PC.JSON_NULL, i + 4 end
	return jsonDecNum(s, i)
end
function PC.jsonDecode(s)
	if type(s) ~= "string" then return nil end
	local ok, v, i = pcall(jsonDec, s, 1, 0)
	if not ok or v == nil or jsonSkip(s, i) <= #s then return nil end
	return v
end

do
	local defaults = {
		voiceFeed = 0.05,        -- s between two feed writes while there are voices to hear
		voiceFeedIdle = 0.2,     -- ... while only the helper is there
		voiceCheck = 1,          -- s between two looks for the helper's "on" file
		voiceRetry = 15,         -- ... after a helper that did not answer (a file left by a crash)
		voicePing = 2,           -- s between two pings
		voicePongWait = 3,       -- s without an answer after a ping: the helper is gone
		voiceTurn = 5,           -- s a voice dummy talks before the next one does
		voiceGap = 0.7,          -- s of silence between two turns
		voiceWhisper = 0.55,     -- a whispering dummy's loudness (the same recording, quieter)
		voiceBufferMuffle = 0.85,-- muffle at the outer edge of a mode's buffer
		voiceWallMuffle = 0.75,  -- muffle through a wall
		voiceAroundMuffle = 0.3, -- muffle round a corner (a way round the wall was found)
		voiceLiveEvery = 0.25,   -- s between two live-words updates sent to the server
		voiceLiveLife = 4,       -- s live words stay up without news (the helper stopped mid-line)
		voiceLogEvery = 0.1,     -- s between two samples of the distance to each speaker (PC.voiceSample)
		voiceLogKeep = 40,       -- s of them kept (a line is at most ~15 s, then sent)
		voiceDummyLag = 0.6,     -- s a voice dummy's words show after it said them (as the helper's passes would)
		voiceLiveMax = 160,      -- characters of live words kept (the end of the line)
		voiceLiveShow = 70,      -- characters of live words shown in a bubble (the end, after "…")
		voiceToSlack = 5,        -- m past my voice mode's buffer that still get my voice (the feed's "to": PROTOCOL.md)
		voiceRoomEvery = 1,      -- s between two offers of the helper's voice room to the host, until shared shows a room
		voiceRoomTries = 30,     -- ... at most this many (a guest's is taken only while the host has no room of its own)
		voiceRoomGrace = 2,      -- s after a session starts before a guest's room is taken (the host's own Koetama first)
		voiceModeEvery = 1,      -- s between two sends of my voice mode to the host, until shared shows it
		talkKey = "b",           -- the talk key's default (push to talk; + Tab: Whisper / Speak / Yell); Voice page: Talk key
		talkShow = 0.3,          -- s the talk-mode strip stays after the key is let go (fading)
		talkAnim = 0.3,          -- s of the mode switch animation
		voiceDeadGain = 0.85,    -- how loud the dead of your channel are to you (the ghost radio: any distance)
		trMax = 16,              -- lines waiting for a translation in the feed at most (more: the oldest go)
		trBytes = 400,           -- bytes of text a line to translate has at most (PROTOCOL.md)
		trWait = 10,             -- s a line waits for its translation before it is dropped
		trLen = 300,             -- characters of a translation kept
		trPerSpeaker = 6,        -- lines of one speaker asked for translation at once at most, then one per cfg.trWindow s
		trWindow = 2,            --   (a token bucket: a flood costs every listener's Koetama CPU; more: not translated)
		trSame = 30,             -- s a line already asked (the same text) is not asked again; its translation is reused
		trCacheMax = 64,         -- translations kept for reuse
	}
	for k, v in pairs(defaults) do
		if PC.cfg[k] == nil then PC.cfg[k] = v end
	end
end

-- the languages the helper writes: {code it gets, name, group}. Its models (the helper's engine/asr.py): GigaAM v3 for
-- Russian, SenseVoice for Chinese / Cantonese / Japanese / Korean, Parakeet v3 for the rest. Groups by the models'
-- published error rates (PROJECT.md, Voice chat: languages): 1 supported (under ~8 % of the words wrong), 2 beta
-- (8-16 %), 3 experimental (about one word in five wrong: they work, but we do not call them supported).
-- "auto": the helper finds the language itself, even several in one line.
PC.VOICE_LANGS = {
	{"en", "English", 1}, {"es", "Español", 1}, {"fr", "Français", 1}, {"de", "Deutsch", 1}, {"it", "Italiano", 1},
	{"pt", "Português", 1}, {"nl", "Nederlands", 1}, {"pl", "Polski", 1}, {"uk", "Українська", 1}, {"ru", "Русский", 1},
	{"zh", "中文 (普通话)", 1}, {"yue", "粵語", 1}, {"ja", "日本語", 1}, {"ko", "한국어", 1}, {"auto", "Auto (guess)", 1},
	{"cs", "Čeština", 2}, {"sk", "Slovenčina", 2}, {"ro", "Română", 2}, {"hr", "Hrvatski", 2}, {"bg", "Български", 2},
	{"fi", "Suomi", 2}, {"sv", "Svenska", 2}, {"hu", "Magyar", 2},
	{"da", "Dansk", 3}, {"et", "Eesti", 3}, {"lv", "Latviešu", 3}, {"lt", "Lietuvių", 3}, {"sl", "Slovenščina", 3},
	{"el", "Ελληνικά", 3}, {"mt", "Malti", 3},
}
PC.VOICE_GROUPS = {"Supported", "Beta: less accurate", "Experimental: many words come out wrong"}

-- a language's name as the Voice page shows it: beta and experimental ones say so
function PC.voiceLangLabel(i)
	local l = PC.VOICE_LANGS[i]
	return l[2] .. (l[3] == 2 and " (beta)" or (l[3] == 3 and " (experimental)" or ""))
end

PC.VDUMMY_LINES = {   -- (engine/make_dummy_lines.py in proximity-voice-chat-STT-engine: the clips' scripts,
                      --  each word's start from Parakeet on the clip, 4 hex digits in 1/100 s; dur: the clip)
	{text = "I am the whisperer. Stay close, or you will not hear me at all. One, two, three, four, five, six, seven, eight, nine, ten.",
	 w = "000000100020004000c80100015001680180019001a801c801e00200025f02be031d037c03db043a049904f8055705b6", dur = 15.57},
	{text = "I am the speaker. This is my normal voice, and it carries a fair distance. Monday, Tuesday, Wednesday, Thursday, Friday, Saturday, Sunday.",
	 w = "000000180028003800a000c000d800f0011801580168017801a801b801e0025002b00310037003d004280490", dur = 13.50},
	{text = "I am the yeller! You can hear me from far away! Red, orange, yellow, green, blue, purple, black and white!",
	 w = "000000100018002800700088009800b000c800d800f00138017801c002000240028002c002e002f8", dur = 8.86},
}

-- ---- TIMED WORDS. A line's units: runs of letters between spaces, each CJK / kana / Hangul character on its own
-- (the helper splits the same way: engine/asr.py units()). Each unit has a start time; a listener's game keeps
-- its distance to every speaker over the last cfg.voiceLogKeep s (PC.voiceSample) and shows a unit only if it
-- was in reach of the line's mode when the unit was said.
function PC.voiceUnits(text)
	local out, cur, sep = {}, nil, ""
	for ch in (text or ""):gmatch(PC.UTF8_CHAR) do
		if ch:find("^%s$") then
			cur, sep = nil, sep .. ch
		else
			local sc = #ch > 1 and PC.scriptOf(PC.utf8Code(ch)) or "base"
			if sc == "cjk" or sc == "kana" or sc == "hangul" then
				out[#out + 1] = {s = sep, w = ch}
				cur, sep = nil, ""
			elseif cur then
				cur.w = cur.w .. ch
			else
				cur = {s = sep, w = ch}
				out[#out + 1] = cur
				sep = ""
			end
		end
	end
	return out
end

-- units i..j as text (the first one's space dropped)
function PC.voiceJoin(us, i, j)
	local out = {}
	for k = i, j do out[#out + 1] = (k > i and us[k].s or "") .. us[k].w end
	return table.concat(out)
end

-- the w tag: seconds per unit, or nil (not hex, not whole)
function PC.voiceTimes(hex)
	if type(hex) ~= "string" or hex == "" or #hex % 4 ~= 0 or hex:find("[^%x]") then return nil end
	local out = {}
	for k = 1, #hex, 4 do out[#out + 1] = tonumber(hex:sub(k, k + 3), 16) / 100 end
	return out
end

-- a text's units with their times, when the times fit it (else units, nil)
function PC.voiceTimed(text, hex)
	local us = PC.voiceUnits(text)
	local times = PC.voiceTimes(hex)
	if times and #times ~= #us then times = nil end
	return us, times
end

-- the same garbling for a spoken line's live words and its finished line
function PC.voiceSeed(p, utt) return (tonumber(p) or 0) * 7919 + (tonumber(utt) or 0) end

-- who hears everything anyway (yourself, the dead, a game's everyoneHears): no cut
function PC.voiceHearsAll(p, mode)
	if p == GetLocalPlayer() or PC.dead() then return true end
	return mode ~= "w" and PC.hooks.everyoneHears and PC.hooks.everyoneHears(p) or false
end

-- (client) the server's clock now: shared.pcNow is published only once a second (it saves traffic), so count on from
-- its last change with this machine's own clock (off by the network's delay, not by up to a second)
function PC.serverNow()
	local sn = shared.pcNow or 0
	local c = PC.c
	if not c then return sn end
	if c.snSeen ~= sn then c.snSeen, c.snAt = sn, GetTime() end
	return sn + (GetTime() - c.snAt)
end

-- (client, from voiceTick every cfg.voiceLogEvery s) the distance to every player and voice dummy, on the server's
-- clock (PC.serverNow, as word times are). Walls count (PC.hearDist) only for a speaker whose words are coming in
-- (its wall checks run then anyway); the plain distance otherwise - no rays for players who are quiet.
function PC.voiceSample(now)
	local c, cfg = PC.C(), PC.cfg
	if now - (c.logT or -1e9) < cfg.voiceLogEvery then return end
	c.logT = now
	c.reach = c.reach or {}
	local t = PC.serverNow()
	local me = GetLocalPlayer()
	local function put(q, d)
		local r = c.reach[q]
		if not r then r = {t = {}, d = {}}; c.reach[q] = r end
		r.t[#r.t + 1], r.d[#r.d + 1] = t, d or false
		if #r.t > 1 and t - r.t[1] > cfg.voiceLogKeep then table.remove(r.t, 1); table.remove(r.d, 1) end
	end
	for _, q in ipairs(PC.allPlayers()) do
		if q ~= me then put(q, (c.live and c.live[q]) and PC.hearDist(q) or PC.distTo(q)) end
	end
	local vo = c.voice
	for _, d in ipairs(vo and vo.list or {}) do put(d.p, PC.hearDist(d.p)) end
	if PC.devSample then PC.devSample(put) end                          -- (devices.lua: the devices)
end

-- the distance to p at server time T (the nearest sample within 0.35 s; just after the newest one: that one), or nil
function PC.voiceDistAt(p, T)
	local r = PC.c and PC.c.reach and PC.c.reach[p]
	if not (r and #r.t > 0) then return nil end
	local lo, hi = 1, #r.t
	while hi - lo > 1 do
		local mid = math.floor((lo + hi) / 2)
		if r.t[mid] <= T then lo = mid else hi = mid end
	end
	local k = math.abs(r.t[lo] - T) <= math.abs(r.t[hi] - T) and lo or hi
	if math.abs(r.t[k] - T) > 0.35 and not (T > r.t[#r.t] and T - r.t[#r.t] < 1.5) then return nil end
	if T > r.t[#r.t] then k = #r.t end
	return r.d[k] or nil
end

-- what this player heard of a timed line by p in mode: the units said while in reach, "..." for each stretch
-- missed, and how clearly each was heard when said. -> text (nil: nothing), clear (every unit within the mode's
-- words range: no garbling), fracs (the share of letters revealed, per letter of text in PC.garble's order: 1 for a
-- unit said while in range, the buffer's share at that distance otherwise)
function PC.voiceHeard(p, us, times, start, mode)
	if PC.voiceHearsAll(p, mode) then return PC.voiceJoin(us, 1, #us), true, nil end
	local inner, outer = PC.rangeOf(mode)
	return PC.voiceHeardIn(p, us, times, start, inner, outer)
end

-- the same from any distance log (key: a player, or "dev:<device>": devices.lua) with the ranges inner / outer
function PC.voiceHeardIn(key, us, times, start, inner, outer)
	local out, fr, gap, any, clear = {}, {}, false, false, true
	local function letters(w, f) for _ in w:gmatch(PC.UTF8_CHAR) do fr[#fr + 1] = f end end
	for i, u in ipairs(us) do
		local d = PC.voiceDistAt(key, start + times[i])
		if d and d <= outer then
			if gap then
				out[#out + 1] = (#out > 0 and " ... " or "... ") .. u.w
				letters("...", 1)
				gap = false
			else
				out[#out + 1] = (#out > 0 and u.s or "") .. u.w
			end
			local f = d <= inner and 1 or math.max(0, math.min(1, (outer - d) / math.max(0.5, outer - inner))) * PC.cfg.garbleMax
			if f < 1 then clear = false end
			letters(u.w, f)
			any = true
		else
			gap = true
		end
	end
	if not any then return nil end
	if gap then out[#out + 1] = " ..."; letters("...", 1) end
	return table.concat(out), clear, fr
end

-- (chat_core's PC.receive) a spoken line from the server with word times: what this player heard of it (PC.voiceHeard:
-- text, clear, fracs). Times that do not fit the text (or no start): all of it, as clearly as from here now.
function PC.voiceCut(m, mode)
	local us, times = PC.voiceTimed(m.text, m.vw)
	if not (times and tonumber(m.vs)) then
		local inner = PC.rangeOf(mode)
		local d = PC.hearDist(m.p)
		return m.text, (d or 0) <= inner, nil
	end
	return PC.voiceHeard(m.p, us, times, tonumber(m.vs), mode)
end

local function has(path)
	local ok, v = pcall(HasFile, path)
	return ok and v == true
end

function PC.voice()
	local c = PC.C()
	if not c.voice then
		local cfg = PC.cfg
		local sid = GetInt(cfg.save .. "vxsid") % 1000000 + 1             -- (a new session number each level start)
		SetInt(cfg.save .. "vxsid", sid)
		ClearKey(cfg.save .. "vxtr1"); ClearKey(cfg.save .. "vxtr2")     -- (the old Translate tab's rules: Koetama's now)
		c.voice = {list = {}, byP = {}, seq = 0, feedT = -1e9, on = false, cur = 0, talkUntil = 0, nextT = 0,
			volume = HasKey(cfg.save .. "vxvol") and math.max(0, math.min(1, GetFloat(cfg.save .. "vxvol"))) or 1,
			textOn = true,       -- (what you say is always written while your helper runs - no switch: the user, 2026-10-06,
			                     --  "not fair to other players" - they hear you, so they get your words too)
			lang = PC.voiceLangIndex(GetString(cfg.save .. "vxlang")),
			liveOn = not GetBool(cfg.save .. "vxnolive"),
			ptt = not GetBool(cfg.save .. "vxalwayson"),           -- (push to talk; false: always on)
			talkKey = PC.validTalkKey(GetString(cfg.save .. "vxkey")) or cfg.talkKey,
			-- (the voice's mode is the input line's: one mode for both since 2026-10-11)
			vmode = PC.TALK_MODE_I[c.mode] and c.mode
				or (PC.TALK_MODE_I[GetString(cfg.save .. "vxmode")] and GetString(cfg.save .. "vxmode")) or "s",
			held = false, heldT = -1e9, modeT = -1e9, modeFrom = nil, binding = false,
			live = nil, liveSentT = -1e9, liveDirty = false,
			sid = sid, ack = 0, sayQ = {}, sayT = 0,
			tr = {reqs = {}, nextId = 0, status = {}, into = nil},   -- (TRANSLATION, below; into: Koetama's setting)
			h = {on = false, alive = false, failed = false, ping = 0, pingT = -1e9, checkT = -1e9, sinceT = 0}}
	end
	return c.voice
end

-- voices to hear, or a helper to talk to? (the Settings page shows the voice rows then)
function PC.voiceOn()
	local c = PC.c
	return c ~= nil and c.voice ~= nil and (#c.voice.list > 0 or c.voice.h.alive)
end

function PC.voiceHelperAlive()
	local c = PC.c
	return c ~= nil and c.voice ~= nil and c.voice.h.alive
end

function PC.isVoiceDummy(p) return type(p) == "number" and p >= PC.VDUMMY and p < PC.VDUMMY + #PC.DUMMY_KINDS end

function PC.voiceDummyOf(p)
	local c = PC.c
	return c and c.voice and c.voice.byP[p] or nil
end

-- Settings: the voice volume (0..1), saved; the helper applies it
function PC.setVoiceVolume(v, save)
	local vo = PC.voice()
	vo.volume = math.max(0, math.min(1, tonumber(v) or 1))
	if save ~= false then SetFloat(PC.cfg.save .. "vxvol", vo.volume) end
end

-- Settings: write what I say in the chat (the helper listens to the microphone and transcribes), saved

-- the language the player speaks: an index into PC.VOICE_LANGS (English when unknown)
function PC.voiceLangIndex(code)
	for i, l in ipairs(PC.VOICE_LANGS) do
		if l[1] == code then return i end
	end
	return 1
end

-- the Voice page: a language from the list (an index; wraps), saved; the helper gets it in the feed
function PC.setVoiceLang(i)
	local vo = PC.voice()
	vo.lang = ((i - 1) % #PC.VOICE_LANGS) + 1
	SetString(PC.cfg.save .. "vxlang", PC.VOICE_LANGS[vo.lang][1])
	vo.feedT = -1e9                                                    -- (the helper hears of it now)
end

-- Settings: live words while I talk (Off: only the finished line - less CPU for the helper), saved
function PC.setVoiceLiveOn(on)
	local vo = PC.voice()
	vo.liveOn = on and true or false
	SetBool(PC.cfg.save .. "vxnolive", not vo.liveOn)
	vo.feedT = -1e9
end

-- the Voice page: its own tab in the chat window (the "Voice" button in the header), shown only while the helper is
-- connected (or voice dummies are around): a player without the helper never sees voice settings
-- (the language list: its buttons, 5 to a row)
local LANG_COLS, LANG_W, LANG_H, LANG_GAP = 5, 182, 32, 8

function PC.voicePageHeight(base)
	local vo = PC.voice()
	if vo.picking then
		local h = 68 + 34
		for g = 1, #PC.VOICE_GROUPS do
			local n = 0
			for _, l in ipairs(PC.VOICE_LANGS) do if l[3] == g then n = n + 1 end end
			h = h + 26 + math.ceil(n / LANG_COLS) * (LANG_H + LANG_GAP - 2) + 8
		end
		return math.max(base, h + 16)
	end
	local box = vo.h.alive and 0 or ((vo.h.outdated and PC.KOETAMA_OLD_H or PC.KOETAMA_BOX_H) + 16)
	return math.max(base, 90 + 40 * #PC.voiceRows() + 60 + box)
end

-- ---- KOETAMA NEEDED: without it (not running: a mod cannot see whether it is installed) the Voice page starts with
-- a notice and a link to its page: the address with a button over it, which runs the game's "game.openurl" command
-- (as its menu opens the changelog); a controller: A on the highlighted link does the same.
PC.KOETAMA_URL = "https://github.com/AgeOfAlgorithms/koetama"
PC.KOETAMA_BOX_H = 120

function PC.openKoetama()
	if Command then pcall(Command, "game.openurl", PC.KOETAMA_URL) end
end

-- Koetama runs but is older than 0.4.0 (its pcvx_v5 / pcvx_v6 files: it can't read protocol 2), or its hello lacks a
-- feature the page needs: it has to be updated (its window's "Check for updates")
PC.KOETAMA_OLD_H = 60

function PC.drawKoetamaOld(W, text)
	UiPush()
	UiAlign("left top")
	UiColor(1, 0.55, 0.2, 0.1)
	UiRoundedRect(W, PC.KOETAMA_OLD_H, 10)
	UiColor(1, 0.55, 0.2, 0.75)
	UiRoundedRectOutline(W, PC.KOETAMA_OLD_H, 10, 2)
	UiTranslate(16, PC.KOETAMA_OLD_H / 2)
	UiAlign("left middle")
	UiFont("bold.ttf", 24)
	UiColor(1, 1, 1, 0.95)
	UiText(text or PC.KOETAMA_OLD)
	UiPop()
end

-- the notice (PC.KOETAMA_BOX_H tall) at the cursor, W wide; what = "translation" on the Translate page
function PC.drawKoetamaNeeded(W, what)
	local c = PC.C()
	local tr = what == "translation"
	UiPush()
	UiAlign("left top")
	UiColor(1, 0.55, 0.2, 0.1)
	UiRoundedRect(W, PC.KOETAMA_BOX_H, 10)
	UiColor(1, 0.55, 0.2, 0.75)
	UiRoundedRectOutline(W, PC.KOETAMA_BOX_H, 10, 2)
	UiTranslate(16, 12)
	UiFont("bold.ttf", 24)
	UiColor(1, 1, 1, 0.95)
	UiText(tr and "Koetama is required for translation" or "Koetama is required for voice chat")
	UiTranslate(0, 32)
	UiFont("regular.ttf", 19)
	UiColor(1, 1, 1, 0.72)
	UiText(tr and "A free app for your PC: it translates what other players say, on your own PC (Mozilla's models). Keep it"
		or "A free app for your PC: it hears your microphone and writes what you say into this chat. Keep it")
	UiTranslate(0, 22)
	UiText("running while you play - these settings come on by themselves.  Get it here:")
	UiTranslate(0, 28)
	if PC.navFocus() then                                              -- (a controller: A opens it)
		PC.navMark(470, 26)
		if c.navAct and c.navAct.accept then PC.openKoetama() end
	end
	-- (a button over the address: a click runs the game's own "game.openurl", as its menu opens the changelog - the
	--  "[[url]]" text link did nothing in-game, 2026-10-10)
	UiFont("bold.ttf", 22)
	local lw, lh = UiGetTextSize(PC.KOETAMA_URL)
	local over = UiIsMouseInRect(lw, lh)
	UiColor(1, over and 0.82 or 0.7, over and 0.5 or 0.35, 1)
	UiText(PC.KOETAMA_URL)
	if over then
		UiPush()
		UiTranslate(0, lh - 2)
		UiRect(lw, 2)                                                  -- (underlined while the mouse is on it)
		UiPop()
	end
	if UiBlankButton(lw, lh) then PC.openKoetama() end
	UiPop()
end

function PC.drawVoicePage(W, H)
	local vo = PC.voice()
	if vo.picking and (not vo.h.alive or GetTime() - (vo.pickT or 0) > 0.5) then vo.picking = false end   -- (left: closed)
	UiPush()
	UiTranslate(16, 68)
	UiAlign("left top")
	if vo.picking then
		vo.pickT = GetTime()
		PC.drawVoiceLangs(W)
	else
		if vo.h.alive then
			UiFont("regular.ttf", 20)
			UiColor(1, 1, 1, 0.6)
			local region = PC.VOICE_REGIONS[PC.voiceRegionIndex(vo.region or "")][2]
			local net = not vo.room and "waiting for the session's voice room"
				or (vo.net == "connected" and ("connected (" .. region .. ")")
				or (vo.net == "unreachable" and "can't be reached - check your internet connection or firewall" or "connecting..."))
			if vo.net == "unreachable" then UiColor(1, 0.6, 0.45, 0.95) end
			UiText("Koetama is connected.   Voice server: " .. net)
			UiTranslate(0, 34)
			if PC.koetamaNewer(vo) then
				PC.drawKoetamaOld(W - 32, PC.KOETAMA_NEWER)
				UiTranslate(0, PC.KOETAMA_OLD_H + 16)
			end
		elseif vo.h.outdated then
			PC.drawKoetamaOld(W - 32)
			UiTranslate(0, PC.KOETAMA_OLD_H + 16)
		else
			PC.drawKoetamaNeeded(W - 32)
			UiTranslate(0, PC.KOETAMA_BOX_H + 16)
		end
		PC.drawRows(PC.voiceRows())
	end
	UiPop()
end

-- the Voice page's language list (from the "Language I speak" row): the groups, a button per language; a click picks
-- it and goes back, so does "< Cancel"
function PC.drawVoiceLangs(W)
	local vo, c = PC.voice(), PC.C()
	local pick, back = nil, false
	if not vo.pickArmed and not InputDown("lmb") then vo.pickArmed = true end   -- (the click that opened it, let go:
	local live = c.typing and vo.pickArmed                                       --  its release must not pick)
	UiPush()
	UiFont("regular.ttf", 20)
	UiColor(1, 1, 1, 0.6)
	UiText("The language you speak (the helper writes it):")
	UiPush()
	UiTranslate(W - 32 - 130, -4)
	local hv = live and UiIsMouseInRect(130, 30)
	back = live and PC.clicked("vl_back", 130, 30, hv)
	UiColor(1, 1, 1, hv and 0.18 or 0.08)
	UiRoundedRect(130, 30, 8)
	UiTranslate(65, 15)
	UiAlign("center middle")
	UiFont("regular.ttf", 20)
	UiColor(1, 1, 1, 0.85)
	UiText("< Cancel")
	UiPop()
	UiTranslate(0, 34)
	for g, title in ipairs(PC.VOICE_GROUPS) do
		UiFont("bold.ttf", 18)
		UiColor(1, 0.82, 0.3, g == 1 and 0.95 or (g == 2 and 0.75 or 0.55))
		UiText(title)
		UiTranslate(0, 26)
		local k = 0
		for i, l in ipairs(PC.VOICE_LANGS) do
			if l[3] == g then
				UiPush()
				UiTranslate((k % LANG_COLS) * (LANG_W + LANG_GAP), math.floor(k / LANG_COLS) * (LANG_H + LANG_GAP - 2))
				local hover = live and UiIsMouseInRect(LANG_W, LANG_H)
				if live and PC.clicked("vl" .. i, LANG_W, LANG_H, hover) then pick = i end
				local on = i == vo.lang
				if on then UiColor(1, 0.82, 0.3, 0.3) elseif hover then UiColor(1, 1, 1, 0.16) else UiColor(1, 1, 1, 0.07) end
				UiRoundedRect(LANG_W, LANG_H, 8)
				if on then UiColor(1, 0.82, 0.3, 0.95); UiRoundedRectOutline(LANG_W, LANG_H, 8, 2) end
				UiTranslate(LANG_W / 2, LANG_H / 2)
				UiAlign("center middle")
				UiColor(1, 1, 1, g == 3 and 0.75 or 0.95)
				PC.text(l[2], 20, false)
				UiPop()
				k = k + 1
			end
		end
		UiTranslate(0, math.ceil(k / LANG_COLS) * (LANG_H + LANG_GAP - 2) + 8)
	end
	UiPop()
	if pick then PC.setVoiceLang(pick) end
	if pick or back then vo.picking = false end
end

-- the Voice page's rows
-- (without Koetama: the same rows, greyed out - off - under the notice saying it is needed; the players' own volumes
-- stay usable: they scale their babble too)
function PC.voiceRows()
	local rows = {}
	local vo, c = PC.voice(), PC.C()
	rows[#rows + 1] = {"set_x", "Voice volume", "slider", vo.volume, PC.setVoiceVolume}
	do
		rows[#rows + 1] = {"set_pt", "Microphone", vo.ptt, "Push to talk", "Always on", PC.setVoicePtt, w = 170}
		rows[#rows + 1] = {"set_tk", vo.ptt and "Talk key (hold it to talk)" or "Talk key (+ Tab: mode)", "cycle",
			vo.binding and "Press a key...  (Esc: keep)" or PC.talkKeyName(), PC.startTalkBind}
		rows[#rows + 1] = {"set_tm", "My voice (talk key + Tab)", PC.TALK_MODE_I[vo.vmode],
			function(i) PC.setVoiceMode(PC.TALK_MODES[i]) end, labels = {"Whisper", "Speak", "Yell", "Global"}}
		rows[#rows + 1] = {"set_l", "Language I speak", "cycle", PC.voiceLangLabel(vo.lang),
			function() vo.picking, vo.pickT, vo.pickArmed = true, GetTime(), false end,              -- (opens the list: PC.drawVoiceLangs)
			step = function(d) PC.setVoiceLang(vo.lang + d) end}                                    -- (a controller: steps through it)
		rows[#rows + 1] = {"set_v2", "Live words while I talk", vo.liveOn, "On", "Off", PC.setVoiceLiveOn}
	end
	-- PLAYERS: each other player's volume, 0-150 % (a tick at 100 %), only for you (PC.playerVolume) - its own subsection (the user,
	-- 2026-10-15); greyed out with the rest without Koetama (/volume still sets it: their babble)
	local others = PC.otherPlayers()
	rows[#rows + 1] = {"set_ph", "Players", "heading", "their volume, only for you", player = true}
	if #others == 0 then rows[#rows + 1] = {"set_pn", "No one else here yet.", "note", player = true} end
	for _, o in ipairs(others) do
		local q = o.p
		local top = PC.PVOL_MAX
		rows[#rows + 1] = {"set_pv" .. q, o.name .. (c.muted[q] and "  (muted)" or ""), "slider", PC.playerVolume(q) / top,
			function(v, done) PC.setPlayerVolume(q, v * top, done) end,
			function(v) return string.format("%d%%", math.floor(v * top * 100 + 0.5)) end,
			sw = PC.PVOL_W, reset = function() PC.setPlayerVolume(q, 1) end, size = 20, player = true,
			mark = 1 / top, steps = math.floor(top * 20 + 0.5)}
	end
	if not vo.h.alive then                                             -- (no Koetama: the whole page grey, the players too -
		for _, r in ipairs(rows) do r.off = true end                   --  the user, 2026-10-15; /volume still sets them)
	end
	return rows
end
PC.PVOL_W = 340                                                     -- (a player's slider: room for its Reset button)

-- ---- TRANSLATION (PROTOCOL.md "Translation"). What chat is translated into is the player's own setting in Koetama's
-- window ("Translate chat into"), not this mod's (2026-10-09; the Translate tab's two rules went): the game sends only the
-- lines it shows (to_translate; PC.trWant) and shows the translations that come back. Koetama says its setting in
-- translations_status (PC.trStatus): "into" (a language code, "" = off) and the pairs in use with their state; the
-- Translate tab shows that. Models download the first time Koetama sees a language.

-- a language code's own name (Koetama's languages, PC.VOICE_LANGS; another code: itself)
function PC.trName(code)
	for _, l in ipairs(PC.VOICE_LANGS) do
		if l[1] == code then return l[2] end
	end
	return tostring(code or "")
end

-- text cut to at most cfg.trBytes bytes, between letters (a UTF-8 letter is never split)
function PC.trCut(text)
	local max = PC.cfg.trBytes
	if #text <= max then return text end
	local n = 0
	for ch in text:gmatch(PC.UTF8_CHAR) do
		if n + #ch > max then break end
		n = n + #ch
	end
	return text:sub(1, n)
end

-- Koetama translates: it runs, and its hello (once it came) names "translate"
function PC.trOn(vo)
	vo = vo or (PC.c and PC.c.voice)
	if not (vo and vo.h.alive) then return false end
	return not (vo.h.hello and not vo.h.hello.features.translate)
end

-- the Translate tab says "too outdated": a Koetama before 0.4.0, or one whose hello lacks "translate"
function PC.trOld(vo)
	vo = vo or PC.voice()
	return vo.h.outdated or (vo.h.alive and vo.h.hello ~= nil and not vo.h.hello.features.translate) or false
end

-- lines go to Koetama: it translates, and its setting is not off (into "": off; nil: not said yet - sent anyway, Koetama
-- answers "" while it is off)
function PC.trSend(vo)
	return PC.trOn(vo) and vo.tr.into ~= ""
end

-- (chat_core: a history entry e, and its bubble b, shown - in full or garbled from a buffer) another player's line:
-- translated while Koetama runs and translates. Each entry is asked once (e.trId); the reply goes onto both
-- (PC.trReply). The whole line is asked (b.full: a garbled entry's text is boxes); a garbled line's translation is
-- garbled as much where it is drawn (PC.trShown).
function PC.trWant(e, b)
	local c = PC.c
	local vo = c and c.voice
	if not PC.trSend(vo) or e.trId or e.sys or e.p == nil or e.p == GetLocalPlayer() then return end
	local text = PC.trCut((b and b.full) or e.text or "")
	if text == "" then return end
	local tr = vo.tr
	-- FLOODS (2026-10-09): each line costs every listener's Koetama CPU. A line already translated (the same text, into
	-- the same language) reuses its translation; one asked in the last cfg.trSame s is not asked again; at most
	-- cfg.trPerSpeaker lines a speaker per cfg.trWindow s; a speaker who is no player here (an id made up) none (the
	-- local test dummies count)
	local now, cfg = GetTime(), PC.cfg
	tr.cache, tr.asked, tr.per = tr.cache or {}, tr.asked or {}, tr.per or {}
	local ck = (tr.into or "?") .. "|" .. text
	local hit = tr.cache[ck]
	if hit then
		e.trId = -1
		if hit.text ~= "" then
			e.tr, e.trT = hit.text, now
			if b then b.tr, b.trT = hit.text, now end
		end
		return
	end
	if tr.asked[ck] and now - tr.asked[ck] < cfg.trSame then e.trId = -1; return end
	local p = e.p
	local local_ = PC.isDummy(p) or PC.isVoiceDummy(p)
	if not local_ then
		local real = false
		for _, q in ipairs(PC.allPlayers()) do if q == p then real = true; break end end
		if not real then return end
	end
	local per = tr.per[p] or {n = cfg.trPerSpeaker, t = now}
	per.n, per.t = math.min(cfg.trPerSpeaker, per.n + (now - per.t) / cfg.trWindow), now
	tr.per[p] = per
	if per.n < 1 then return end
	per.n = per.n - 1
	tr.asked[ck] = now
	tr.nextId = tr.nextId + 1
	e.trId = tr.nextId
	tr.reqs[#tr.reqs + 1] = {id = tr.nextId, text = text, t = GetTime(), e = e, b = b, ck = ck}
	while #tr.reqs > PC.cfg.trMax do table.remove(tr.reqs, 1) end     -- (the oldest go first)
	PC.voiceFeedNow(vo)                                                -- (Koetama gets it at once)
end

-- (a "translation" object) the translation of request id; "" (or the line unchanged): nothing to show. Exactly one reply per
-- id: the request leaves the feed either way.
function PC.trReply(id, text)
	local vo = PC.voice()
	local reqs = vo.tr.reqs
	local r
	for i = 1, #reqs do
		if reqs[i].id == id then r = table.remove(reqs, i); break end
	end
	if not r then return end                                           -- (dropped meanwhile: too late)
	text = PC.clean(text or "", PC.cfg.trLen)
	if text == r.text then text = "" end
	local tr = vo.tr
	if r.ck then                                                       -- (kept for the same line again: no second ask)
		tr.cache = tr.cache or {}
		tr.cacheN = (tr.cacheN or 0) + 1
		if tr.cacheN > PC.cfg.trCacheMax then tr.cache, tr.cacheN = {}, 1 end
		tr.cache[r.ck] = {text = text}
	end
	if text == "" then return end
	local now = GetTime()
	r.e.tr, r.e.trT = text, now
	if r.b then r.b.tr, r.b.trT = text, now end
end

-- (a "translations_status" object) Koetama's setting and the pairs in use: into (a language code; "" = off) and a list of
-- {from, to, state, progress}; state ready, downloading (progress 0..1), loading, unavailable or error. The list replaces
-- what was known (it names every pair in use); pct: 0..100. A list that is not one, or an into that is not a short code:
-- left as it was. Turned off: the lines still waiting are dropped.
function PC.trStatus(obj)
	local tr = PC.voice().tr
	if type(obj) ~= "table" then return end
	local into = obj.into
	if type(into) == "string" and (into == "" or into:find("^[%w%-]+$")) and #into <= 16 then
		tr.into = into
		if into == "" then tr.reqs = {} end
	end
	local list = obj.translations
	if type(list) ~= "table" then return end
	local st = {}
	for _, it in ipairs(list) do
		if type(it) == "table" and type(it.from) == "string" and type(it.to) == "string" and type(it.state) == "string"
			and it.state:find("^%a+$") then
			local n = type(it.progress) == "number" and it.progress or nil
			st[it.from .. ">" .. it.to] = {state = it.state:lower(), pct = n and math.max(0, math.min(100, n * 100)) or nil}
		end
	end
	tr.status = st
end

-- the feed's to_translate ({id, text} each), or nil (Koetama doesn't translate, its setting is off, or nothing waits)
function PC.trFeed(vo)
	if not PC.trSend(vo) or #vo.tr.reqs == 0 then return nil end
	local reqs = PC.jsonArray({})
	for i, r in ipairs(vo.tr.reqs) do reqs[i] = {id = r.id, text = r.text} end
	return reqs
end

-- (each tick) lines without a reply for cfg.trWait s are dropped
function PC.trTick(vo, now)
	local reqs = vo.tr.reqs
	for i = #reqs, 1, -1 do
		if now - reqs[i].t > PC.cfg.trWait then table.remove(reqs, i) end
	end
	if (vo.tr.askedT or 0) <= now - 5 then                             -- (old "asked" marks and idle speakers go, every 5 s)
		vo.tr.askedT = now
		for k, t in pairs(vo.tr.asked or {}) do if now - t > PC.cfg.trSame then vo.tr.asked[k] = nil end end
		for p, per in pairs(vo.tr.per or {}) do if now - per.t > PC.cfg.trWindow * PC.cfg.trPerSpeaker then vo.tr.per[p] = nil end end
	end
end

-- the pairs in use, "from>to" each, in order
function PC.trPairs(vo)
	local keys = {}
	for k in pairs((vo or PC.voice()).tr.status) do keys[#keys + 1] = k end
	table.sort(keys)
	return keys
end

-- a pair's state for the Translate tab: text, colour, download percent (or nil)
local TR_DIM, TR_OK, TR_BUSY, TR_BAD = {1, 1, 1, 0.7}, {0.5, 0.95, 0.55, 0.95}, {1, 0.82, 0.3, 0.95}, {1, 0.5, 0.4, 0.95}
function PC.trPairState(key)
	local st = PC.voice().tr.status[key]
	local f, t = key:match("^(.-)>(.*)$")
	local names = PC.trName(f) .. " → " .. PC.trName(t)
	if not st then return names, TR_DIM end
	if st.state == "ready" then return names .. ": ready", TR_OK end
	if st.state == "downloading" then
		local pct = math.floor((st.pct or 0) + 0.5)
		return names .. ": downloading the models " .. pct .. "%", TR_BUSY, pct
	end
	if st.state == "loading" then return names .. ": loading the models...", TR_BUSY end
	if st.state == "unavailable" then return names .. ": no translation model for this pair", TR_BAD end
	return names .. ": error (Koetama's window says more)", TR_BAD
end

-- the Translate page: its own tab next to Voice, a status page. Koetama translates: what into (its setting), each pair in
-- use with its state (a bar while downloading), and where to change it; off: says so. Without Koetama: the notice saying
-- it is needed (as the Voice page); an old Koetama (or one whose hello lacks "translate"): "too outdated".
PC.TR_PAIR_H = 34
PC.TR_HINT = "Choose the language in Koetama's window (Translate chat into)"
PC.TR_OFF = "Translation is off: choose a language in Koetama's window"

function PC.translatePageHeight(base)
	local vo = PC.voice()
	local body
	if PC.trOn(vo) then body = 34 + 44 + #PC.trPairs(vo) * PC.TR_PAIR_H + 40 + 60
	else body = (PC.trOld(vo) and PC.KOETAMA_OLD_H or PC.KOETAMA_BOX_H) + 16 end
	return math.max(base, 68 + body)
end

-- one pair's row at the cursor: its state, a small bar before it while downloading
function PC.drawTrPair(key)
	local text, col, pct = PC.trPairState(key)
	UiPush()
	if pct then
		UiPush()
		UiTranslate(0, 7)
		UiColor(1, 1, 1, 0.12)
		UiRoundedRect(200, 10, 5)
		UiColor(col[1], col[2], col[3], 0.9)
		if pct > 0 then UiRoundedRect(math.max(10, 200 * pct / 100), 10, 5) end
		UiPop()
		UiTranslate(214, 0)
	end
	UiColor(col[1], col[2], col[3], col[4])
	PC.text(text, 20, false)
	UiPop()
end

function PC.drawTranslatePage(W, H)
	local vo = PC.voice()
	UiPush()
	UiTranslate(16, 68)
	UiAlign("left top")
	if PC.trOn(vo) then
		UiFont("regular.ttf", 20)
		UiColor(1, 1, 1, 0.6)
		UiText("Koetama is connected. What other players say is translated on your PC, under the original.")
		UiTranslate(0, 34)
		local into = vo.tr.into
		if into == "" then
			UiColor(1, 0.82, 0.3, 0.95)
			UiFont("bold.ttf", 24)
			UiText(PC.TR_OFF)
		else
			UiColor(1, 1, 1, 0.95)
			if into then
				PC.text("Koetama translates chat into " .. PC.trName(into), 24, true)
			else
				UiFont("bold.ttf", 24)
				UiText("Waiting for Koetama to say what it translates chat into...")
			end
		end
		UiTranslate(0, 44)
		for _, key in ipairs(PC.trPairs(vo)) do
			PC.drawTrPair(key)
			UiTranslate(0, PC.TR_PAIR_H)
		end
		UiTranslate(0, 6)
		UiFont("regular.ttf", 20)
		UiColor(1, 1, 1, 0.75)
		if into ~= "" then UiText(PC.TR_HINT) end
		UiTranslate(0, 34)
		UiFont("regular.ttf", 18)
		UiColor(1, 1, 1, 0.5)
		UiText("Lines in other languages (also within a line) are translated. Each language's models (about 35 MB a")
		UiTranslate(0, 24)
		UiText("direction; a pair without English needs two) download the first time Koetama sees that language.")
	elseif PC.trOld(vo) then
		PC.drawKoetamaOld(W - 32)
	else
		PC.drawKoetamaNeeded(W - 32, "translation")
	end
	UiPop()
end

-- ---- THE TALK KEY (Oct 2026). Push to talk (the default): only what the player says while the talk key is held
-- becomes a line (the feed's listen "push_to_talk", talk_key true while held: the helper keeps the microphone open and
-- ends the line 0.25 s after the key is let go). "Always on" (the Voice page; a controller player's choice: no key to
-- hold): the helper's speech detector finds each line (listen "always"). Either way, the talk key held + Tab switches the voice's mode:
-- Whisper -> Speak -> Yell -> Global (Global: what you say goes to everyone as a chat line only - no bubble, no
-- babble, and your voice itself is not played to anyone), with Teardown's map (Tab) off meanwhile,
-- and with the chat window closed a strip at the bottom of the screen shows the mode (PC.drawTalk). The voice has
-- its own mode, saved (the typed line keeps its own; in the lobby both are Global). The key: B unless rebound on the
-- Voice page (any key Teardown's own controls don't use: they are read from its keymap, options.input.keymap).
-- Nothing of this works while the player types (letters go into the line) or without the helper.
PC.TALK_MODES = {"w", "s", "y", "g"}
PC.TALK_MODE_I = {w = 1, s = 2, y = 3, g = 4}
-- keys the talk key can never be: the chat's and the game's fixed ones (the tool groups are the digits)
PC.TALK_KEY_BAD = {esc = true, ["return"] = true, tab = true, backspace = true, delete = true, any = true, lmb = true,
	rmb = true, pause = true, uparrow = true, downarrow = true, pgup = true, pgdown = true}

-- a key name the talk key may be (lower case), or nil
function PC.validTalkKey(k)
	k = tostring(k or ""):lower()
	if k == "" or PC.TALK_KEY_BAD[k] or k:find("^%d$") or not k:find("^[%w_]+$") then return nil end
	return k
end

-- the Teardown control a key is bound to ("jump", "map", ...), or nil
function PC.gameKeyUse(k)
	local ok, keys = pcall(ListKeys, "options.input.keymap")
	if not ok or type(keys) ~= "table" then return nil end
	for _, action in ipairs(keys) do
		if GetString("options.input.keymap." .. action):lower() == k then return action end
	end
	return nil
end

function PC.talkKeyName()
	return PC.voice().talkKey:upper()
end

-- the voice's mode: "w" / "s" / "y" / "g" (the lobby: always "g", everyone hears everything there)
function PC.voiceMode()
	if PC.lobby() then return "g" end
	return PC.voice().vmode
end

function PC.setVoiceMode(m)
	local vo = PC.voice()
	if not PC.TALK_MODE_I[m] or vo.vmode == m then return end
	vo.modeFrom, vo.modeT = vo.vmode, GetTime()
	vo.vmode = m
	vo.vmodeT = 0                                                      -- (the host hears of it at once: shared.pcVMode)
	SetString(PC.cfg.save .. "vxmode", m)
	PC.setMode(m)                                                      -- (and the input line's: one mode for both)
end

-- talk key + Tab: Whisper -> Speak -> Yell -> Global -> Whisper
function PC.nextVoiceMode()
	local vo = PC.voice()
	PC.setVoiceMode(PC.TALK_MODES[PC.TALK_MODE_I[vo.vmode] % #PC.TALK_MODES + 1])
end

-- the Voice page: push to talk (true) or always on (false), saved; the helper hears of it now
function PC.setVoicePtt(on)
	local vo = PC.voice()
	vo.ptt = on and true or false
	SetBool(PC.cfg.save .. "vxalwayson", not vo.ptt)
	vo.feedT = -1e9
end

-- a new talk key: true, or false and why (also said in the chat)
function PC.setTalkKey(k)
	local vo = PC.voice()
	local key = PC.validTalkKey(k)
	local why
	if not key then
		why = "That key can't be the talk key."
	else
		local use = PC.gameKeyUse(key)
		if use then why = key:upper() .. " is Teardown's \"" .. use .. "\" key - pick another." end
	end
	if why then PC.system(why); return false, why end
	vo.talkKey = key
	SetString(PC.cfg.save .. "vxkey", key)
	PC.system("Talk key: " .. key:upper() .. ".")
	return true
end

-- a key is being bound (or was, this frame): the chat leaves Enter, Esc, Tab and the arrows alone
function PC.keyCaptured()
	local vo = PC.c and PC.c.voice
	return vo ~= nil and (vo.binding or vo.bindEndT == GetTime())
end

-- the Voice page's "Talk key" button: the next key pressed is the new one (Esc: keep the old one)
function PC.startTalkBind()
	local vo, c = PC.voice(), PC.C()
	vo.binding, vo.bindT, vo.bindText, vo.bindArmed = true, GetTime(), c.text, false
end

-- each frame (before the feed is written): the key held or not, Tab, the map, a key being bound
function PC.talkTick(vo, now)
	local c = PC.C()
	if vo.binding then
		if not vo.bindArmed and not InputDown("lmb") then vo.bindArmed = true end   -- (the click on the button, let go)
		local k = (vo.bindArmed and InputLastPressedKey) and tostring(InputLastPressedKey() or ""):lower() or ""
		if not c.typing or now - vo.bindT > 10 or k == "esc" then
			vo.binding = false
		elseif k ~= "" and not k:find("mb$") then                       -- (mouse buttons: still waiting)
			PC.setTalkKey(k)
			vo.binding = false
		end
		if not vo.binding then vo.bindEndT, vo.bindEat = now, 3 end
	end
	if vo.bindEat and vo.bindEat > 0 then                                  -- (the key typed nothing into the line: the
		vo.bindEat = vo.bindEat - 1                                        --  field takes it in this frame's draw)
		if c.typing then c.text = vo.bindText or c.text end
	end
	local free = vo.h.alive and not c.typing and not c.nav and not (PC.hooks.blockKeys and PC.hooks.blockKeys())
	local held = (free and InputDown(vo.talkKey)) and true or false
	if held ~= vo.held then
		vo.held, vo.heldT = held, now
		SetBool(PC.cfg.reg .. ".talking." .. GetLocalPlayer(), held)    -- (API 8: a game ignores the talk key meanwhile)
		if vo.ptt then vo.feedT = -1e9 end                                 -- (the helper hears of it at once)
	end
	if held then
		SetBool("game.disablemap", true)                                 -- (Tab is the map's key: not while switching)
		vo.mapOff = true
		if InputPressed("tab") then PC.nextVoiceMode() end
	elseif vo.mapOff then
		vo.mapOff = false
		SetBool("game.disablemap", false)
	end
end

-- a 0..1 ease (fast, then settling)
local function easeOut(x)
	x = math.max(0, math.min(1, x))
	return 1 - (1 - x) * (1 - x) * (1 - x)
end

-- the talk-mode strip at the bottom of the screen while the talk key is held (the chat window closed): the three
-- modes, the voice's one lit; a switch slides the light over and pops the new name. Your helper hearing you: the
-- dot pulses.
function PC.drawTalk()
	local c = PC.c
	local vo = c and c.voice
	if not (vo and vo.h.alive) or PC.windowOpen() or PC.lobby() then return end
	local now = GetTime()
	local a = vo.held and 1 or (1 - (now - vo.heldT) / PC.cfg.talkShow)
	if a <= 0 then return end
	local s = math.min(UiWidth() / 1920, UiHeight() / 1080)
	local cw, ch, gap = 150, 44, 8                                     -- (one mode's cell)
	local n = #PC.TALK_MODES
	local w = n * cw + (n - 1) * gap + 72
	local h = ch + 46
	local k = easeOut((now - vo.modeT) / PC.cfg.talkAnim)
	local cur = PC.TALK_MODE_I[vo.vmode]
	local from = PC.TALK_MODE_I[vo.modeFrom or vo.vmode] or cur
	local pos = from + (cur - from) * k                                  -- (the light, sliding)
	local col = PC.modeInfo(vo.vmode)[5]
	c.talkShown = {mode = vo.vmode, k = k, a = a}                        -- (for the tests)
	UiPush()
	UiTranslate(UiWidth() / 2, UiHeight() - 150 * s)
	UiScale(s)
	UiTranslate(-w / 2, -h / 2 + (vo.held and 0 or 10 * (1 - a)))
	UiAlign("left top")
	UiColor(0, 0, 0, 0.62 * a)
	UiRoundedRect(w, h, 14)
	UiColor(col[1], col[2], col[3], 0.55 * a)
	UiRoundedRectOutline(w, h, 14, 2)
	-- the microphone dot, in the mode's colour; red and pulsing while your helper hears you talk
	UiPush()
	UiTranslate(34, 8 + ch / 2)
	local talking = vo.talking ~= nil
	local r = 9 + (talking and 3 * math.abs(math.sin(now * 9)) or 0)
	if talking then UiColor(1, 0.35, 0.3, a) else UiColor(col[1], col[2], col[3], a) end
	UiTranslate(-r, -r)
	UiRoundedRect(2 * r, 2 * r, r)
	UiPop()
	UiTranslate(60, 8)
	-- the light under the current mode (sliding between cells on a switch)
	UiPush()
	UiTranslate((pos - 1) * (cw + gap), 0)
	UiColor(col[1], col[2], col[3], 0.3 * a)
	UiRoundedRect(cw, ch, 10)
	UiColor(col[1], col[2], col[3], 0.95 * a)
	UiRoundedRectOutline(cw, ch, 10, 2)
	UiPop()
	for i, m in ipairs(PC.TALK_MODES) do
		local info = PC.modeInfo(m)
		local on = i == cur
		local mc = info[5]
		UiPush()
		UiTranslate((i - 1) * (cw + gap) + cw / 2, ch / 2)
		UiAlign("center middle")
		if on and k < 1 then UiScale(1 + 0.35 * math.sin(k * math.pi)) end   -- (the new mode pops)
		UiFont(on and "bold.ttf" or "regular.ttf", on and 26 or 22)
		if on then UiColor(1, 1, 1, a) else UiColor(mc[1], mc[2], mc[3], 0.5 * a) end
		UiText(info[3])
		UiPop()
	end
	UiTranslate((n * cw + (n - 1) * gap) / 2, ch + 12)
	UiAlign("center top")
	UiFont("regular.ttf", 18)
	UiColor(1, 1, 1, 0.6 * a)
	local what = vo.ptt and (talking and "Talking" or "Push to talk") or "Always on"
	if vo.vmode == "g" then what = what .. " - Global: everyone reads it, no one hears it" end
	UiText(what .. "   " .. PC.talkKeyName() .. " + Tab: change")
	UiPop()
end

-- ---- live words: what a player says, shown while they still talk
-- (client) the helper's words so far: kept for our own line on screen, and sent to the server (throttled)
function PC.voiceLive(utt, text, w, ago)
	local vo = PC.voice()
	local c = PC.C()
	if text ~= "" then c.liveSeen = c.liveSeen or {}; c.liveSeen[GetLocalPlayer()] = utt end
	vo.live = {u = utt, text = text, t = GetTime(), w = w, start = ago and (GetTime() - ago) or nil}
	vo.liveDirty = true
end

function PC.voiceLiveSend(now)
	local vo = PC.voice()
	if not vo.liveDirty or now - vo.liveSentT < PC.cfg.voiceLiveEvery then return end
	vo.liveDirty, vo.liveSentT = false, now
	local mode = PC.voiceMode()
	if mode == "g" or PC.dead() then return end                        -- (the lobby and the dead's channel: no bubbles)
	local l = vo.live
	PC.call("pc_live", l and l.u or 0, l and l.text or "", mode, l and l.w or "",
		(l and l.start) and (now - l.start) or -1)
end

-- (client) the player started (on) or stopped talking - the helper heard a line begin / end: the server tells the
-- players near enough, whose games bob this player's head the whole time (heads.lua). Your own: vo.talking.
function PC.voiceTalk(on, utt)
	local vo = PC.voice()
	if on then vo.talking = {u = utt, t = GetTime()} elseif not vo.talking then return else vo.talking = nil end
	local mode = PC.voiceMode()
	if mode == "g" or PC.dead() then return end
	PC.call("pc_talk", on and true or false, mode)
end

-- (server) p talks (on) or has stopped: to the players near enough for the mode (as live words go), remembered to
-- tell the same ones when it stops; it also stops when p's line is said (PC.voiceLiveDone) or after 20 s
function server.pc_talk(p, tok, on, ch)
	p = PC.who(p, tok)
	if not p or not PC.allow(p, "talk", 6, 6) then return end
	PC.talkSet(p, on, ch)
end

-- (server) p talks now or not (server.pc_talk; the host itself: a line said, live words gone stale)
function PC.talkSet(p, on, ch)
	local s, cfg = PC.S(), PC.cfg
	s.talk = s.talk or {}
	local old = s.talk[p]
	if old then
		for q in pairs(old.to) do ClientCall(q, "client.pc_talk", p, false) end
		s.talk[p] = nil
	end
	ch = PC.validMode(ch)
	if not on or ch == "g" or (s.chan[p] and not PC.inLobby()) then return end
	local to = {}
	local lobby = PC.inLobby()
	local _, outer = PC.rangeOf(ch)
	local okT, tr = pcall(GetPlayerTransform, p)
	for _, q in ipairs(PC.allPlayers()) do
		local okQ, tq = pcall(GetPlayerTransform, q)
		if q ~= p and (lobby or (okT and okQ and tr and tq and VecLength(VecSub(tq.pos, tr.pos)) <= outer + cfg.whisperSlack)) then
			to[q] = true
			ClientCall(q, "client.pc_talk", p, true, ch)
		end
	end
	s.talk[p] = {to = to, at = s.time}
end

-- (client) player p talks now (from the server), or not
function client.pc_talk(p, on, ch)
	local c = PC.C()
	p = tonumber(p)
	if not p or p ~= p then return end
	c.talking = c.talking or {}
	c.talking[p] = on and {t = GetTime(), ch = PC.validMode(ch)} or nil
end

-- (server) a player's live words, sent ONLY to the players near enough to make anything out (ClientCall
-- client.pc_live, as a whisper's line is): the mode's outer range + whisperSlack m, or everyone in the
-- lobby. Never in shared (a whisper must stay private), and no traffic to players too far away. "" clears.
-- The server remembers who got them, to clear them there when the line is said or the words go stale.
function server.pc_live(p, tok, utt, text, ch, w, ago)
	local s, cfg = PC.S(), PC.cfg
	p, utt = PC.who(p, tok), PC.finite(utt) or 0
	if not p or not PC.allow(p, "live", 8, 8) then return end
	utt = math.floor(math.max(0, math.min(1e9, utt)))
	ago = PC.finite(ago)
	s.live = s.live or {}
	ch = PC.validMode(ch)
	-- (word times: 4 hex digits a unit, a unit at least a character: longer than the text could need - none)
	if type(w) ~= "string" or #w > 4 * 4 * cfg.voiceLiveMax then w = "" end
	text = PC.clean(PC.arg(text, 12 * 4 * cfg.voiceLiveMax + 16), 4 * cfg.voiceLiveMax)   -- (live words: the line so far - its newest
	if text == "" or ch == "g" or (s.chan[p] and not PC.inLobby()) then  --  part is kept below, not its start)
		PC.voiceLiveDone(p)
		return
	end
	local us, times = PC.voiceTimed(text, w)
	local start = (times and tonumber(ago) and tonumber(ago) >= 0) and (s.time - math.min(120, tonumber(ago))) or nil
	if PC.utf8Len(text) > cfg.voiceLiveMax then                         -- (the end of a long line: whole units, and their times)
		local i = 1
		while i < #us and PC.utf8Len(PC.voiceJoin(us, i, #us)) > cfg.voiceLiveMax do i = i + 1 end
		text = PC.voiceJoin(us, i, #us)
		local cut = {}
		for k = i, #us do cut[#cut + 1] = times and string.format("%04x", math.floor(times[k] * 100 + 0.5)) or nil end
		w = times and table.concat(cut) or nil
	end
	if not (times and start) then w, start = nil, nil end
	local old = s.live[p]
	local to = {}
	local lobby = PC.inLobby()
	local _, outer = PC.rangeOf(ch)
	local dv, dk, devQ = nil, nil, {}                                  -- (through a device: devices.lua)
	if PC.devLine and not lobby then dv, dk, devQ = PC.devLine(p, ch, start or (s.time - 5)) end
	local okT, tr = pcall(GetPlayerTransform, p)
	for _, q in ipairs(PC.allPlayers()) do
		if q ~= p then
			local okQ, tq = pcall(GetPlayerTransform, q)
			if lobby or devQ[q] or (okT and okQ and tr and tq and VecLength(VecSub(tq.pos, tr.pos)) <= outer + cfg.whisperSlack) then
				to[q] = true
				ClientCall(q, "client.pc_live", p, utt, text, ch, w, start, dv, dk)
			end
		end
	end
	if old then                                                        -- (walked out of reach meanwhile: theirs go)
		for q in pairs(old.to) do
			if not to[q] then ClientCall(q, "client.pc_live", p, utt, "", ch) end
		end
	end
	s.live[p] = {u = utt, ch = ch, at = s.time, to = to}
end

-- (server, every tick from chat_core) live words without news for cfg.voiceLiveLife s go; a finished line
-- (server.pc_say with voice) clears them at once (PC.voiceLiveDone)
function PC.voiceServerTick()
	local s = PC.S()
	for p, t in pairs(s.talk or {}) do                                 -- (talking without an end for 20 s: over)
		if s.time - t.at > 20 then PC.talkSet(p, false) end
	end
	if not s.live then return end
	for p, l in pairs(s.live) do
		if s.time - l.at > PC.cfg.voiceLiveLife then PC.voiceLiveDone(p) end
	end
end

function PC.voiceLiveDone(p)
	local s = PC.S()
	if s.talk and s.talk[p] then PC.talkSet(p, false) end              -- (the line is said: talking is over)
	local l = s.live and s.live[p]
	if not l then return end
	s.live[p] = nil
	for q in pairs(l.to) do ClientCall(q, "client.pc_live", p, l.u, "", l.ch) end
end

-- (client) live words of player p from the server ("" clears them); they also go after cfg.voiceLiveLife s.
-- w, start: the units' times and when the line began (server clock) - this player sees only what it was in reach for
function client.pc_live(p, utt, text, ch, w, start, dv, dk)
	local c = PC.C()
	c.live = c.live or {}
	p = tonumber(p)
	if not p or p ~= p then return end
	if not text or text == "" then
		c.live[p] = nil
	else
		local us, times = PC.voiceTimed(text, w)
		c.live[p] = {u = tonumber(utt) or 0, text = text, ch = PC.validMode(ch), t = GetTime(), us = us,
			times = tonumber(start) and times or nil, start = tonumber(start), dv = dv, dk = dk}
		c.liveSeen = c.liveSeen or {}                                     -- (its finished line then goes soon: PC.bubbleLife)
		c.liveSeen[p] = tonumber(utt) or 0
	end
end

-- (client) player p's live words, or nil
function PC.voiceLiveOf(p)
	local c = PC.c
	local l = c and c.live and c.live[p]
	if l and l.text ~= "" and GetTime() - l.t <= PC.cfg.voiceLiveLife then return l end
	return nil
end

-- the end of a line, at most n characters, "…" in front when cut
function PC.voiceTail(text, n)
	local len = PC.utf8Len(text)
	if len <= n then return text end
	local out, i = {}, 0
	for chr in text:gmatch(PC.UTF8_CHAR) do
		i = i + 1
		if i > len - n then out[#out + 1] = chr end
	end
	return "…" .. table.concat(out)
end

-- what this player has heard of p's live words (l): the cut by its distance log, worked out at most every 0.2 s;
-- untimed words: all of them
function PC.voiceLiveSeen(p, l)
	if not (l.times and l.start) then return l.text end
	local now = GetTime()
	if not l.seenT or now - l.seenT >= 0.2 or l.seenFor ~= l.text then
		local clear
		l.seen, clear, l.seenFr = PC.voiceHeard(p, l.us, l.times, l.start, l.ch)
		l.seenT, l.seenFor = now, l.text
	end
	return l.seen, l.seenFr
end

-- (client, from chat_core's PC.drawBubbles) a full speech bubble over each speaker with the words so far, filling chunk
-- by chunk and always showing its newest lines: only what this player was in reach for ("..." before / between), in
-- the mode's buffer garbled as a typed line is (walking closer reveals letters); in reach but nothing heard yet: the
-- small "...". Your own in third person (Settings: your own bubble). The finished line then takes its place, already
-- at its end, and goes after cfg.voiceHold s. None with Settings' "Bubbles for spoken lines: Hide". Returns the
-- speakers drawn (no typing "..." for them then).
function PC.voiceLiveBubbles(add, me)
	local c, cfg = PC.C(), PC.cfg
	local done = {}
	if c.hideVoiceBubbles then return done end
	for p in pairs(c.live or {}) do
		local l = PC.voiceLiveOf(p)
		if l and p ~= me and not c.muted[p] and not (c.bubbles[p] and not c.bubbles[p].hidden)
			and (PC.lobby() or PC.channelOf(p) == "") then
			local d = PC.voiceHearsAll(p, l.ch) and 0 or PC.hearDist(p)
			local inner, outer = PC.rangeOf(l.ch)
			local whisper = l.ch == "w"
			if d and d <= outer then
				local seen, fr = PC.voiceLiveSeen(p, l)
				if seen then
					local text, far = seen, false
					local garbled = false
					for _, f in ipairs(fr or {}) do if f < 1 then garbled = true; break end end
					if fr then                                              -- (timed: each word exactly as heard when said -
						if garbled then                                     --  clear stays clear, garbled stays garbled)
							text, far = PC.garble(text, 0, PC.voiceSeed(p, l.u), math.floor(GetTime() * 3), fr), true
						end
					elseif d > inner then                                   -- (untimed words: by where you are now)
						text, far = PC.garble(text, PC.fracAt(d, l.ch) or 0, PC.voiceSeed(p, l.u), math.floor(GetTime() * 3)), true
					end
					-- (one bubble between a talker and the megaphone they carry: the fuller one, the megaphone's when equal -
					--  devices.lua's PC.devLiveWins)
					if not (PC.devLiveWins and PC.devLiveWins(p, far and 1 or 2)) then
						add(PC.bubbleLayout(p, text, l.ch == "y", 1, false, whisper, far, nil, true))
					end
				elseif not (PC.devLiveWins and PC.devLiveWins(p, 0.5)) then
					add(PC.bubbleLayout(p, "...", l.ch == "y", 0.75, true, whisper))
				end
				done[p] = true
			end
		end
	end
	local vo = c.voice
	local own = vo and vo.live
	if own and own.text ~= "" and vo.textOn and GetTime() - own.t < cfg.voiceLiveLife and GetBool("game.thirdperson") and not c.hideOwn
		and not (c.bubbles[me] and not c.bubbles[me].hidden) and PC.voiceMode() ~= "g" and not PC.dead() then
		add(PC.bubbleLayout(me, own.text, PC.voiceMode() == "y", 1, false, PC.voiceMode() == "w", false, nil, true))
		done[me] = true
	end
	return done
end

-- (client) our own live words, above the chat's hint line: what the helper is hearing right now
function PC.voiceDrawOwn(L)
	local c = PC.c
	local vo = c and c.voice
	local l = vo and vo.live
	if not (l and l.text ~= "" and vo.textOn and GetTime() - l.t < PC.cfg.voiceLiveLife) then return end
	UiPush()
	UiTranslate(L and L.x or 24, L and (L.inY - 4) or (UiHeight() - 150))   -- (above the input line)
	UiAlign("left bottom")
	UiColor(0, 0, 0, 0.55)
	local text = "Speaking: " .. PC.voiceTail(l.text, 90)
	local w = PC.textWidth(text, 22)
	UiRoundedRect(w + 24, 34, 8)
	UiTranslate(12, -7)
	UiColor(0.75, 1, 0.8, 0.95)
	PC.text(text, 22)
	UiPop()
end

-- a voice dummy starts its line: its words show as a real speaker's would (the helper's passes: every 1 s, what
-- was said cfg.voiceDummyLag s before), then the finished line is "said" (to this player only: the dummies are
-- local), cut and garbled by where this player was while each word was said
function PC.voiceDummyBegin(d)
	local line = PC.VDUMMY_LINES[d.idx]
	if not line then return end
	d.utt = (d.utt or 0) + 1
	d.sayT, d.start = GetTime(), PC.serverNow() + 0.08              -- (the clip starts ~one feed write later)
	d.us, d.times = PC.voiceTimed(line.text, line.w)
	d.shown, d.saying = 0, true
end

function PC.voiceDummyWords(d)
	if not d.saying then return end
	local c, cfg = PC.C(), PC.cfg
	c.live = c.live or {}
	local el = GetTime() - d.sayT
	if d.talking then
		local pass = math.floor(el)                                  -- (a pass each whole second)
		local n = 0
		for k, t in ipairs(d.times or {}) do if t <= pass - cfg.voiceDummyLag then n = k end end
		n = math.min(n, #d.us - 1)                                    -- (never the last word until the line is done)
		if n > d.shown then
			d.shown = n
			local us, times = {}, {}
			for k = 1, n do us[k], times[k] = d.us[k], d.times[k] end
			local dv, dk
			if PC.txOf then dv, dk = PC.txOf(PC.devWorld(), d.p, d.kind) end   -- (through a device: devices.lua)
			c.live[d.p] = {u = d.utt, text = PC.voiceJoin(d.us, 1, n), ch = d.kind, us = us, times = times, start = d.start, t = GetTime(),
				dv = dv, dk = dk}
			c.liveSeen = c.liveSeen or {}
			c.liveSeen[d.p] = d.utt
		elseif c.live[d.p] then
			c.live[d.p].t = GetTime()
		end
	else
		d.saying = false
		c.live[d.p] = nil
		local line = PC.VDUMMY_LINES[d.idx]
		c.vdN = (c.vdN or 0) + 1
		local dv, dk
		if PC.txOf then dv, dk = PC.txOf(PC.devWorld(), d.p, d.kind) end
		PC.receive({id = 2000000 + c.vdN, p = d.p, name = d.name, ch = d.kind, text = line.text, v = true, vw = line.w,
			vs = d.start, vu = d.utt, t = shared.pcNow, dv = dv, dk = dk})
	end
end

function PC.voiceDummyRemove(d)
	local vo = PC.voice()
	local c = PC.C()
	if c.live then c.live[d.p] = nil end
	if c.reach then c.reach[d.p] = nil end
	for _, e in ipairs(d.ents) do pcall(Delete, e) end
	vo.byP[d.p] = nil
	PC.C().walls[d.p] = nil
	for i = #vo.list, 1, -1 do if vo.list[i] == d then table.remove(vo.list, i) end end
end

function PC.voiceDummyClear()
	local vo = PC.voice()
	vo.testDevs, vo.testTx = nil, nil                                  -- (/dummy voice walkie / megaphone / pa: their devices)
	local n = #vo.list
	while vo.list[1] do PC.voiceDummyRemove(vo.list[1]) end
	return n
end

-- voice dummy kind i (PC.DUMMY_KINDS) at pos, on the ground; one already there of that kind is replaced
-- (it faces the local player: a megaphone dummy's horn points at them)
function PC.voiceDummySpawn(i, pos)
	local vo = PC.voice()
	local kind = PC.DUMMY_KINDS[i]
	local old = vo.byP[PC.VDUMMY + i - 1]
	if old then PC.voiceDummyRemove(old) end
	local okR, hit, dist = pcall(QueryRaycast, VecAdd(pos, Vec(0, 2, 0)), Vec(0, -1, 0), 6)
	if okR and hit then pos = Vec(pos[1], pos[2] + 2 - dist, pos[3]) end
	-- the chat dummies' box figure with a green head (client-side, static, just for looks)
	local xml = '<body tags="nocull" dynamic="false"><voxbox tags="nocull" size="5 9 3" pos="-0.25 0 -0.15" color="0.3 0.33 0.45"/>'
		.. '<voxbox tags="nocull" size="6 7 4" pos="-0.3 0.9 -0.2" color="' .. kind[3] .. '"/><voxbox tags="nocull" size="4 4 4" pos="-0.2 1.6 -0.2" color="0.45 0.85 0.5"/></body>'
	local okS, ents = pcall(Spawn, xml, Transform(pos), true)
	local d = {p = PC.VDUMMY + i - 1, idx = i, kind = kind[1], name = kind[2], pos = pos, ents = okS and ents or {}, talking = false}
	local me = PC.speakerPos(GetLocalPlayer())
	d.facing = me and VecNormalize(Vec(me[1] - pos[1], 0, me[3] - pos[3])) or Vec(0, 0, 1)   -- (a megaphone dummy's horn: at you)
	vo.byP[d.p] = d
	vo.list[#vo.list + 1] = d
	vo.cur, vo.nextT = 0, 0                                           -- (a new set: the turns start over)
	table.sort(vo.list, function(u, v) return u.idx < v.idx end)
	return d
end

-- /dummy voice [1|2|3|clear]
function PC.voiceDummyCommand(arg)
	local cfg = PC.cfg
	arg = (arg or ""):lower()
	if arg == "clear" or arg == "off" or arg == "remove" then
		PC.system(PC.voiceDummyClear() > 0 and "The voice dummies are gone." or "No voice dummies to clear.")
		return
	end
	local cam = GetCameraTransform()
	local okF, fwd = pcall(TransformToParentVec, cam, Vec(0, 0, -1))
	fwd = okF and fwd or Vec(0, 0, -1)
	fwd = VecNormalize(Vec(fwd[1], 0, fwd[3]))
	local me, right = PC.speakerPos(GetLocalPlayer()) or cam.pos, VecCross(fwd, Vec(0, 1, 0))
	local i = tonumber(arg)
	if PC.devParse and (arg == "walkie" or arg == "megaphone" or arg == "pa") then   -- (devices.lua: through a test device)
		PC.voiceDummyClear()
		local vo = PC.voice()
		local far = arg == "megaphone" and 45 or 50
		local d = PC.voiceDummySpawn(2, VecAdd(me, VecScale(fwd, far)))
		local what
		-- the devices, only on this machine (as a game's proxchat.device.*), and the dummy talking into them (proxchat.tx)
		if arg == "walkie" then                                         -- (a walkie each, channel "test")
			d.name = "Speaker (walkie)"
			vo.testDevs = {["test walkie dummy"] = {kind = "radio", chan = "test", at = {t = "player", p = d.p}},
				["test walkie you"] = {kind = "radio", chan = "test", at = {t = "player", p = GetLocalPlayer()}}}
			vo.testTx = {[d.p] = "test"}
			what = "talks into its walkie-talkie; you hear it from yours (channel \"test\")"
		elseif arg == "megaphone" then                                  -- (a loudspeaker it holds, pointed at you)
			d.name = "Speaker (megaphone)"
			vo.testDevs = {["test megaphone"] = {kind = "loudspeaker", chan = "testmega", at = {t = "player", p = d.p}}}
			vo.testTx = {[d.p] = "testmega"}
			what = "talks through a megaphone pointed at you - walk behind it: quieter, and its words reach less far"
		else                                                            -- (four PA speakers around you, 3 m up)
			d.name = "Speaker (PA)"
			local pts = {}
			for k = 0, 3 do
				local a = k * math.pi / 2
				pts[#pts + 1] = VecAdd(me, Vec(8 * math.cos(a), 3, 8 * math.sin(a)))
			end
			vo.testDevs = {["test pa"] = {kind = "pa", chan = "testpa", at = {t = "pos", pts = pts}}}
			vo.testTx = {[d.p] = "testpa"}
			what = "talks on a PA whose four speakers stand around you"
		end
		PC.system("A voice dummy " .. far .. " m ahead " .. what .. ". Start Koetama first. /dummy voice clear removes it.")
	elseif arg == "" then
		PC.voiceDummyClear()
		for k = 1, #PC.DUMMY_KINDS do
			PC.voiceDummySpawn(k, VecAdd(VecAdd(me, VecScale(fwd, 3)), VecScale(right, (k - 2) * 2.5)))
		end
		PC.system("Three voice dummies (green heads; left to right: whisperer, speaker, yeller) talk in turns through the voice helper - "
			.. "start it first. Walk around them: whisper " .. cfg.whisperR .. " m, speech " .. cfg.chatR .. " m, yells " .. cfg.shoutR
			.. " m, muffled beyond. /dummy voice clear removes them.")
	elseif i and PC.DUMMY_KINDS[i] then
		PC.voiceDummySpawn(i, VecAdd(me, VecScale(fwd, 3)))
		PC.system("The " .. PC.DUMMY_KINDS[i][2]:lower() .. " voice dummy stands in front of you (it talks through the voice helper). /dummy voice clear removes it.")
	else
		PC.system("/dummy voice: three voice dummies.  /dummy voice 1: whisperer, 2: speaker, 3: yeller.  /dummy voice walkie / megaphone / pa: "
			.. "one far away, through that.  /dummy voice clear: remove them.")
	end
end

-- how the local player hears a speaker p standing at pos (feet) in mode: gain, azimuth, elevation, muffle
function PC.voiceHear(p, pos, mode)
	local cfg = PC.cfg
	local head = VecAdd(pos, Vec(0, 1.7, 0))
	local d = PC.distTo(p) or VecLength(VecSub(head, PC.listenerHead()))
	local dEff = PC.hearDist(p) or d
	local wallM = 0
	local w = PC.C().walls[p]
	if w and w.blocked and shared.pcWalls then
		local round = w.around and w.around <= d / cfg.wallFactor
		wallM = round and cfg.voiceAroundMuffle or cfg.voiceWallMuffle
	end
	local inner, outer = PC.rangeOf(mode)
	local gain = PC.loudness(dEff, outer + cfg.soundGrace, inner)
	if dEff >= outer + cfg.soundGrace then gain = 0 end
	if mode == "w" then gain = gain * cfg.voiceWhisper end
	local x = math.max(0, math.min(1, (dEff - inner) / math.max(0.5, outer - inner)))
	local muffle = math.max(wallM, x * cfg.voiceBufferMuffle)
	-- (the direction from the listener's HEAD - where every distance is measured from, and Koetama's listener position - in
	--  the camera's axes: panning follows where the player looks; in third person the camera is not where they hear)
	local l = TransformToLocalPoint(Transform(PC.listenerHead(), GetCameraTransform().rot), head)
	local flat = math.sqrt(l[1] * l[1] + l[3] * l[3])
	local az, el = 0, 0
	if flat > 1e-6 or math.abs(l[2]) > 1e-6 then
		az = math.deg(math.atan2(l[1], -l[3]))
		el = math.deg(math.atan2(l[2], flat))
	end
	return gain, az, el, muffle
end

-- ---- REAL VOICES (PROTOCOL.md "Real voices"). Players' voices travel between
-- their helpers through a relay, in a ROOM: a name and a key every player of the session gets. A script has no good
-- random numbers, so a helper makes the room (a "room" object); the host keeps the first one offered this session and
-- publishes it (shared.pcVoiceRoom); every game puts that one into its feed. The game never carries audio: it tells
-- its helper who gets this player's voice (PC.voiceTo) and how loud every other player is here (PC.voicePlayers).

-- (client) the voice server as Koetama last said (its "voice" objects: vo.vstate off / connecting / connected /
-- unreachable), while it runs and there is a room: "connected", "unreachable", "connecting"; a line in the chat when it
-- can't be reached, and when it is again
PC.VOICE_STATES = {off = true, connecting = true, connected = true, unreachable = true}
function PC.voiceNetTick(vo, now)
	if not (vo.h.alive and vo.room) then vo.net = nil; return end
	local net = (vo.vstate == "connected" or vo.vstate == "unreachable") and vo.vstate or "connecting"
	if net == "unreachable" and vo.net ~= "unreachable" then
		PC.system("Koetama can't reach the voice server: voices won't be heard (check your internet connection or firewall).")
	elseif net == "connected" and vo.net == "unreachable" then
		PC.system("Koetama reached the voice server again.")
	end
	vo.net = net
end

-- (client) do real voices reach this player? Koetama runs and the session has a voice room (else a spoken line is
-- babbled to them like a typed one: chat_core's PC.receive)
function PC.hearsRealVoices()
	local c = PC.c
	return c ~= nil and c.voice ~= nil and c.voice.h.alive and shared.pcVoiceRoom ~= nil and c.voice.net ~= "unreachable"
end

-- a room and key as the helper makes them: 32 and 64 lower-case hex digits
function PC.validRoom(room, key)
	return type(room) == "string" and type(key) == "string" and #room == 32 and #key == 64
		and not room:find("[^0-9a-f]") and not key:find("[^0-9a-f]")
end

-- (client) the helper's room for this session (a "room" object). The host's own game writes it into the host's registry
-- (proxchat.hostroom: only scripts on the host can; its room always wins - PC.voiceHostSettingsTick); a guest's game
-- offers it to the host until shared shows a room (taken only while the host has none: server.pc_room)
function PC.voiceRoomOffer(room, key)
	local vo = PC.voice()
	if not PC.validRoom(room, key) then return end
	if PC.isHost() then
		SetString(PC.cfg.reg .. ".hostroom", room .. ":" .. key)
		return
	end
	if shared.pcVoiceRoom then return end
	vo.roomWant = {id = room, key = key, tries = 0, t = -1e9}
end

-- where a session's voice room should live: the host picks (Settings, "Voice server"); "" = wherever the relay puts
-- it (near the first player to join it). The relay's regions (Cloudflare's location hints); South America, Africa and
-- the Middle East have no rooms of their own (one nearby is used). A change moves everyone to a new room there.
PC.VOICE_REGIONS = {
	{"", "Auto"}, {"wnam", "North America West"}, {"enam", "North America East"}, {"sam", "South America"},
	{"weur", "Europe West"}, {"eeur", "Europe East"}, {"apac", "Asia-Pacific"}, {"apac-ne", "Northeast Asia"},
	{"apac-se", "Southeast Asia"}, {"oc", "Oceania"}, {"afr", "Africa"}, {"me", "Middle East"},
}

-- a region's index in PC.VOICE_REGIONS (Auto when unknown)
function PC.voiceRegionIndex(code)
	for i, r in ipairs(PC.VOICE_REGIONS) do
		if r[1] == code then return i end
	end
	return 1
end

-- (server) a new session: no room yet, nobody's voice mode known; the host's region as saved
function PC.voiceServerInit()
	local s = PC.S()
	s.voiceRoom = nil
	shared.pcVoiceRoom = nil
	shared.pcVMode = {}
	s.regionSeen = GetString(PC.cfg.save .. "vxregion")
	shared.pcVoiceRegion = PC.VOICE_REGIONS[PC.voiceRegionIndex(s.regionSeen)][1]
end

-- (server, each tick: chat_core's PC.hostSettingsTick) the host's own choices from the host's registry (2026-10-09: not
-- ServerCalls - any game could claim the host's id): the region (savegame.mod.pcvxregion, saved for the next session by
-- the host's game) and the host's own Koetama room (proxchat.hostroom = "<room>:<key>"), which wins over a guest's
function PC.voiceHostSettingsTick()
	local s = PC.S()
	local r = GetString(PC.cfg.save .. "vxregion")
	if r ~= s.regionSeen then
		s.regionSeen = r
		shared.pcVoiceRegion = PC.VOICE_REGIONS[PC.voiceRegionIndex(r)][1]
	end
	local hr = GetString(PC.cfg.reg .. ".hostroom")
	if hr ~= "" and hr ~= s.hostRoomSeen then
		s.hostRoomSeen = hr
		local room, key = hr:match("^(%x+):(%x+)$")
		if PC.validRoom(room, key) and not (s.voiceRoom and s.voiceRoom.id == room and s.voiceRoom.key == key) then
			s.voiceRoom = {id = room, key = key, host = true}
			shared.pcVoiceRoom = {id = room, key = key}
			PC.log("proxchat voice room from the host")
		end
	end
end

-- player p is the host (the server's own player, or IsPlayerHost)
function PC.isHostPlayer(p)
	p = tonumber(p)
	if not p then return false end
	if IsPlayerHost then return IsPlayerHost(p) == true end
	return p == 1
end

-- (client, the host) the next / previous region (Settings): into the host's own registry (PC.voiceHostSettingsTick)
function PC.stepVoiceRegion(d)
	if not PC.isHost() then return end
	local i = PC.voiceRegionIndex(shared.pcVoiceRegion or "")
	SetString(PC.cfg.save .. "vxregion", PC.VOICE_REGIONS[(i - 1 + d) % #PC.VOICE_REGIONS + 1][1])
end

-- the Settings page's host row (chat_core's drawSettings)
function PC.voiceHostRows(rows)
	local i = PC.voiceRegionIndex(shared.pcVoiceRegion or "")
	rows[#rows + 1] = {"set_rg", "Voice server (host)", "cycle", PC.VOICE_REGIONS[i][2], function() PC.stepVoiceRegion(1) end,
		step = PC.stepVoiceRegion}
end

-- (server) a GUEST's helper offers a room (the host's own comes through its registry: PC.voiceHostSettingsTick, and
-- always wins). Taken only from a real player with their token, only while the session has no room, and not in its
-- first cfg.voiceRoomGrace s (the host's Koetama first); the first such one is kept, published to every player
function server.pc_room(p, tok, room, key)
	local s = PC.S()
	p = PC.who(p, tok)
	if not p or not PC.allow(p, "room", 2, 3) then return end
	if s.voiceRoom or s.time < PC.cfg.voiceRoomGrace then return end
	if not PC.validRoom(room, key) then
		PC.log("proxchat voice room refused p=" .. tostring(p))
		return
	end
	s.voiceRoom = {id = room, key = key, from = p}
	shared.pcVoiceRoom = {id = room, key = key}
	PC.log("proxchat voice room from p=" .. tostring(p))                -- (never the key in a log)
end

-- (server) player p's voice mode ("w" / "s" / "y" / "g", their choice: the lobby overrides it in every game)
function server.pc_vmode(p, tok, m)
	p = PC.who(p, tok)
	if not p or not PC.TALK_MODE_I[m] or not PC.allow(p, "vmode", 4, 6) then return end
	if (shared.pcVMode or {})[p] ~= m then PC.setShared("pcVMode", p, m) end
end

-- (server, chat_core's serverTick) a player left: their voice mode goes
function PC.voiceForget(p)
	if (shared.pcVMode or {})[p] ~= nil then PC.setShared("pcVMode", p, nil) end
end

-- (client) who gets my voice now, a list of player ids (PC.jsonArray): the players within my voice mode's whole range (its buffer too) +
-- cfg.voiceToSlack m, by the plain distance as the server picks who gets a typed line (walls only make a voice sound
-- farther: the listener's own gain - PC.voiceHear - handles them, and nobody who could hear it is left out), and every
-- dead player (the dead hear everyone, as they read every line: their own game makes it as loud as their camera is
-- near); everyone in the lobby; nobody in Global. Dead: the players in my channel, at any distance (a ghost radio).
function PC.voiceTo()
	local vo, me = PC.voice(), GetLocalPlayer()
	local lobby = PC.lobby()
	local chans = shared.pcChan or {}
	local mine = not lobby and chans[me] or ""
	local out = PC.jsonArray({})
	if not lobby and mine == "" and vo.vmode == "g" then return out end
	local _, outer = PC.rangeOf(vo.vmode)
	for _, q in ipairs(PC.allPlayers()) do
		if q ~= me then
			local theirs = chans[q] or ""
			local take
			if lobby then take = true
			elseif mine ~= "" then take = theirs == mine                   -- (dead: my channel only)
			elseif theirs ~= "" then take = true                           -- (the dead hear the living)
			else
				local d = PC.distTo(q)
				take = d ~= nil and d <= outer + PC.cfg.voiceToSlack
			end
			if take then out[#out + 1] = q end
		end
	end
	return out
end

-- x rounded to d decimals (the feed stays short)
local function rnd(x, d)
	local m = 10 ^ d
	return math.floor(x * m + 0.5) / m
end

-- (client) every other real player whose voice I could hear, as feed speakers ({id = their player id, ...}): gain,
-- direction and muffle as for the voice dummies (PC.voiceHear: their voice mode's ranges, the buffer, walls) at their
-- head, from my camera (dead and spectating: where I watch from); not one in Global, muted (/mute) or out of earshot
-- (gain 0). The dead: to the living, never heard; to the dead of their channel, clear at cfg.voiceDeadGain whatever
-- the distance (a ghost radio), and not to other channels (teams). The lobby: everyone, full and clear.
function PC.voicePlayers(parts)
	local c, me = PC.C(), GetLocalPlayer()
	local lobby = PC.lobby()
	local vm = c.vmodes or {}
	local chans = shared.pcChan or {}
	local mine = chans[me] or ""
	for _, q in ipairs(PC.allPlayers()) do
		local n0 = #parts
		if q ~= me and not c.muted[q] then
			if lobby then
				parts[#parts + 1] = PC.voiceSpeaker(q, 1, 0, 0, 0)
			else
				local m, chan, pos = vm[q], chans[q] or "", PC.speakerPos(q)
				if chan ~= "" then
					if chan == mine then
						local e = PC.voiceSpeaker(q, PC.cfg.voiceDeadGain, 0, 0, 0)
						e.effects = PC.fxFor and PC.fxFor("d", q) or nil       -- (a game's "dead" effects: a ghost)
						parts[#parts + 1] = e
					end
				elseif m and m ~= "g" and pos then
					local gain, az, el, muffle = PC.voiceHear(q, pos, m)
					local via = PC.devVia and PC.devVia(q, m) or nil      -- (through devices: devices.lua)
					if gain > 0 or via then
						local e = gain > 0 and PC.voiceSpeaker(q, gain, az, el, muffle) or {id = q}   -- (only via: no position, no gain)
						if gain > 0 and PC.fxFor then e.effects = PC.fxFor(m, q) end
						e.via = via
						parts[#parts + 1] = e
					end
				end
			end
		end
		if #parts > n0 then                                            -- (my own volume for this player, 0..2, only when
			local v = rnd(PC.playerVolume(q), 2)                       --  not 1: Koetama multiplies it on everything,
			if v ~= 1 then parts[#parts].volume = v end                --  their device voices too)
		end
	end
end

-- one feed speaker
function PC.voiceSpeaker(id, gain, az, el, muffle)
	return {id = id, gain = rnd(gain, 3), azimuth = rnd(az, 1), elevation = rnd(el, 1), muffle = rnd(muffle, 2)}
end

-- the feed as written into the savegame: the hex of its JSON
function PC.voiceFeedString(f) return PC.hexEncode(PC.jsonEncode(f)) end

-- the feed (PROTOCOL.md "Game -> Koetama: the feed"). off: the last write when nothing is left - listen off, no room,
-- no translations, no speakers
function PC.voiceFeed(vo, off)
	local sp = PC.jsonArray({})
	local room = not off and vo.room or nil
	if not off then
		for _, d in ipairs(vo.list) do
			local gain, az, el, muffle = PC.voiceHear(d.p, d.pos, d.kind)
			local via = PC.devVia and PC.devVia(d.p, d.kind) or nil        -- (through devices: devices.lua)
			local e = (via and gain <= 0) and {id = d.p} or PC.voiceSpeaker(d.p, gain, az, el, muffle)
			if e.gain and PC.fxFor then e.effects = PC.fxFor(d.kind, d.p) end
			e.via = via
			e.test_voice, e.talking = d.idx, d.talking and true or false
			sp[#sp + 1] = e
		end
		if room then PC.voicePlayers(sp) end                         -- (no room: no real voices)
	end
	local placed = false                                               -- (a device with a position: Koetama needs my ears)
	for _, e in ipairs(sp) do
		for _, v in ipairs(e.via or {}) do if v.position or v.positions then placed = true end end
	end
	vo.seq = vo.seq + 1
	local listen = "off"
	if vo.h.alive and vo.textOn then listen = vo.ptt and "push_to_talk" or "always" end
	local f = {type = "feed", seq = vo.seq, session = vo.sid, ack = vo.ack, ping = vo.h.ping, volume = rnd(vo.volume, 2),
		listen = listen, talk_key = (listen == "push_to_talk" and vo.held) and true or false,
		lang = PC.VOICE_LANGS[vo.lang][1], live = vo.liveOn and true or false, me = GetLocalPlayer(), speakers = sp}
	if room then f.room, f.key, f.to, f.region = room.id, room.key, PC.voiceTo(), vo.region or "" end
	if room and PC.devTransmit then f.transmit = PC.devTransmit() end   -- (my voice into a device now: devices.lua)
	if placed and PC.devListener then f.listener = PC.devListener() end
	if not off then f.to_translate = PC.trFeed(vo) end                  -- (translation: the lines waiting)
	SetString(PC.VOICE_FEED, PC.voiceFeedString(f))
end

-- (a line queued for translation; also usable for anything else Koetama must hear of now) the feed written at once -
-- at most one such extra write a frame (more in the same frame: the next regular write, made due now)
function PC.voiceFeedNow(vo)
	if not (vo.on or vo.h.on or #vo.list > 0) then return end
	local now = GetTime()
	if vo.nowT == now then vo.feedT = -1e9; return end
	vo.nowT, vo.feedT, vo.on = now, now, true
	PC.voiceFeed(vo)
end

-- a feed that says "nothing" (listen off, no room, no speakers, nothing to translate): a decoded feed string
function PC.voiceFeedOff(s)
	local f = PC.jsonDecode(PC.hexDecode(s) or "")
	if type(f) ~= "table" or f.type ~= "feed" then return false end
	local function none(x) return x == nil or x == PC.JSON_NULL or (type(x) == "table" and x[1] == nil) end
	return (f.listen == nil or f.listen == "off") and (f.room == nil or f.room == PC.JSON_NULL) and none(f.speakers)
		and none(f.to_translate)
end

PC.KOETAMA_OLD = "Your Koetama is too outdated. Please update it from the app."
-- Koetama speaks a NEWER protocol than this file (its hello's "protocol" > PC.PROTOCOL): this mod is the old one. Voice
-- chat carries on (a newer protocol may still mostly fit), with a notice in the chat once and on the Voice page.
PC.KOETAMA_NEWER = "This Proximity Comms is older than your Koetama: update the mod (restart the game to get Workshop updates)."
function PC.koetamaNewer(vo)
	local hello = vo and vo.h and vo.h.hello
	return hello ~= nil and hello.protocol ~= nil and hello.protocol > PC.PROTOCOL
end

-- is the helper there? Its "on" file starts the feed (but "on" with pcvx_v5 / pcvx_v6: a Koetama before 0.4.0, which
-- can't read protocol 2 - too old); then it must answer every ping (a file left by a crashed helper does not).
function PC.voiceHelper(vo, now)
	local h, cfg = vo.h, PC.cfg
	if not h.on then
		if now - h.checkT >= (h.failed and cfg.voiceRetry or cfg.voiceCheck) then
			h.checkT = now
			-- (a Koetama before 0.4.0 writes pcvx_v5 / pcvx_v6, the old feed versions it reads; 0.4.0 deletes them.
			--  An old one can't read this feed, so it would never answer: the Voice page tells the player to update it)
			local on = has(PC.VOICE_IO .. "on")
			local old = on and (has(PC.VOICE_IO .. "v5") or has(PC.VOICE_IO .. "v6"))
			if old and not h.outdated then PC.system(PC.KOETAMA_OLD) end
			h.outdated = old
			if on and not old then h.on, h.pingT, h.sinceT, h.pongT, h.hello = true, -1e9, now, nil, nil end
		end
		return
	end
	if now - h.pingT >= cfg.voicePing then
		h.ping, h.pingT, h.ponged = h.ping + 1, now, false
	end
	if not h.ponged and has(PC.VOICE_IO .. "p" .. (h.ping % 1000)) then
		h.ponged, h.pongT, h.failed = true, now, false
		if not h.alive then
			h.alive = true
			PC.system("Koetama connected: voice chat is on (hold " .. PC.talkKeyName() .. " to talk; the Voice page has its settings).")
		end
	end
	if now - (h.pongT or h.sinceT) > cfg.voicePing + cfg.voicePongWait then
		if h.alive then PC.system("Koetama disconnected: voice chat is off.") end
		h.on, h.alive, h.failed, h.checkT, h.hello = false, false, true, now, nil
		vo.sayQ, vo.vstate = {}, nil
		vo.tr.reqs, vo.tr.status, vo.tr.asked, vo.tr.into = {}, {}, {}, nil   -- (no translations will come; a new Koetama
	end                                                                       --  says its setting again)
end

-- an object Koetama wrote (pcvx_t<n>.xml): Spawn the prefab, read its j tag (hex of JSON), delete what it made ->
-- the object (a table with a string "type"), or nil
function PC.voiceReadMsg(path)
	local ok, ents = pcall(Spawn, path, Transform(Vec(0, -500, 0)), true)
	if not ok or type(ents) ~= "table" then return nil end
	local j = ""
	for i = 1, #ents do
		if j == "" then
			local okT, t = pcall(GetTagValue, ents[i], "j")
			if okT and type(t) == "string" then j = t end
		end
	end
	for i = 1, #ents do pcall(Delete, ents[i]) end
	local obj = PC.jsonDecode(PC.hexDecode(j) or "")
	if type(obj) ~= "table" or type(obj.type) ~= "string" then return nil end
	return obj
end

-- a speech object's word times (times: seconds per unit, ago: seconds) as the mod keeps them: 4 hex digits per unit in
-- 1/100 s, and ago - both nil unless both are there and the times fit the text's units
function PC.voiceTimesHex(text, times, ago)
	ago = type(ago) == "number" and ago or nil
	if type(times) ~= "table" or not ago or ago ~= ago or times[1] == nil then return nil, nil end
	local out = {}
	for i, t in ipairs(times) do
		if type(t) ~= "number" or t ~= t then return nil, nil end
		out[i] = string.format("%04x", math.max(0, math.min(65535, math.floor(t * 100 + 0.5))))
	end
	local w = table.concat(out)
	local _, fit = PC.voiceTimed(text, w)
	if not fit then return nil, nil end
	return w, math.max(0, math.min(120, ago))
end

-- (client) act on one object from Koetama (PROTOCOL.md "Koetama -> game"); an unknown type is ignored
function PC.voiceMessage(vo, obj)
	local t = obj.type
	if t == "hello" then
		local feats = {}
		if type(obj.features) == "table" then
			for _, f in ipairs(obj.features) do if type(f) == "string" then feats[f] = true end end
		end
		vo.h.hello = {app = type(obj.app) == "string" and obj.app or "", version = type(obj.version) == "string" and obj.version or "",
			protocol = tonumber(obj.protocol), features = feats}
		if PC.koetamaNewer(vo) and vo.h.newerSaid ~= vo.h.hello.protocol then
			vo.h.newerSaid = vo.h.hello.protocol                          -- (said once per protocol number, not per reconnect)
			PC.system(PC.KOETAMA_NEWER)
		end
	elseif t == "speech" then
		if not vo.textOn then return end
		local kind, utt = obj.kind, tonumber(obj.utt) or 0
		local text = type(obj.text) == "string" and obj.text or ""
		if kind == "start" then
			PC.voiceTalk(true, utt)                                      -- (talking: no words yet)
		elseif kind == "live" then
			local w, ago = PC.voiceTimesHex(text, obj.times, obj.ago)
			PC.voiceLive(utt, text, w, ago)                              -- (the words so far)
		elseif kind == "final" then
			PC.voiceTalk(false, utt)
			if vo.live then PC.voiceLive(utt, "") end                    -- (the line is done: the live words go)
			local w, ago = PC.voiceTimesHex(text, obj.times, obj.ago)
			if text ~= "" then PC.voiceSay(text, w, ago, utt) end
		end
	elseif t == "room" then
		PC.voiceRoomOffer(obj.room, obj.key)                             -- (a voice room: never shown, never said)
	elseif t == "voice" then
		if PC.VOICE_STATES[obj.state] then vo.vstate = obj.state end    -- (the voice server's link: PC.voiceNetTick)
	elseif t == "translation" then
		local id = tonumber(obj.id)
		if id then PC.trReply(id, type(obj.text) == "string" and obj.text or "") end   -- (under its line, never said)
	elseif t == "translations_status" then
		PC.trStatus(obj)                                                 -- (into + the pairs' state: the Translate tab)
	end
end

-- say what the player spoke: like a typed line in the current mode, flagged as voice; a long one in
-- pieces of at most cfg.maxLen characters, cut between words
function PC.voiceSay(text, w, ago, utt)
	local vo, cfg = PC.voice(), PC.cfg
	local us, times = PC.voiceTimed(tostring(text), w)
	local start = (times and ago) and (GetTime() - ago) or nil
	local i0 = 1
	local function push(i1)
		if i1 < i0 then return end
		local hx = nil
		if times and start then
			local t = {}
			for k = i0, i1 do t[#t + 1] = string.format("%04x", math.floor(times[k] * 100 + 0.5)) end
			hx = table.concat(t)
		end
		vo.sayQ[#vo.sayQ + 1] = {text = PC.voiceJoin(us, i0, i1), w = hx, start = hx and start or nil, u = utt}
		i0 = i1 + 1
	end
	for k = 1, #us do
		if k > i0 and PC.utf8Len(PC.voiceJoin(us, i0, k)) > cfg.maxLen then push(k - 1) end
	end
	push(#us)
end

function PC.voiceTick(now)
	local c = PC.c
	if not c then return end
	local cfg = PC.cfg
	if not c.voiceChecked then                                          -- (a feed left on by an earlier session: off)
		c.voiceChecked = true
		local old = GetString(PC.VOICE_FEED)
		if old ~= "" and not PC.voiceFeedOff(old) then                  -- (also any older protocol's feed)
			SetString(PC.VOICE_FEED, PC.voiceFeedString({type = "feed", seq = 0, session = 0, ack = 0, ping = 0, volume = 1,
				listen = "off", talk_key = false, lang = "en", live = true, me = GetLocalPlayer(), speakers = PC.jsonArray({})}))
		end
	end
	local vo = PC.voice()
	-- a controller: the microphone always on unless the player chose push to talk (the user, 2026-10-12: open mic is
	-- what controller players expect; a pad has no button to spare). Not saved: the Voice page's choice is.
	if vo.ptt and PC.pad and PC.pad() and not HasKey(PC.cfg.save .. "vxalwayson") then
		vo.ptt, vo.feedT = false, -1e9
	end
	PC.voiceHelper(vo, now)
	PC.talkTick(vo, now)
	-- the session's voice room and every player's voice mode, read once a tick (a client's shared read is a fresh copy)
	vo.room = shared.pcVoiceRoom
	vo.region = shared.pcVoiceRegion
	PC.voiceNetTick(vo, now)
	c.vmodes = shared.pcVMode or {}
	local me = GetLocalPlayer()
	if c.vmodes[me] ~= vo.vmode and now >= (vo.vmodeT or 0) then    -- (my voice mode: to the host until shared shows it)
		vo.vmodeT = now + cfg.voiceModeEvery
		PC.call("pc_vmode", vo.vmode)
	end
	local rw = vo.roomWant                                             -- (the helper's room: offered until a room is there)
	if rw then
		if vo.room then
			vo.roomWant = nil
		elseif now >= rw.t then
			rw.tries, rw.t = rw.tries + 1, now + cfg.voiceRoomEvery
			if rw.tries > cfg.voiceRoomTries then vo.roomWant = nil elseif PC.C().tok then PC.call("pc_room", rw.id, rw.key)
			else rw.tries = rw.tries - 1 end                                 -- (no token yet: not a try)
		end
	end
	-- an object from the helper: the next number, read once, then acked in the feed (unreadable or unknown: acked too)
	if vo.h.alive and has(PC.VOICE_IO .. "t" .. (vo.ack + 1) .. ".xml") then
		local obj = PC.voiceReadMsg(PC.VOICE_IO .. "t" .. (vo.ack + 1) .. ".xml")
		vo.ack = vo.ack + 1
		vo.feedT = -1e9                                                  -- (the ack goes out now)
		if obj then PC.voiceMessage(vo, obj) end
	end
	PC.trTick(vo, now)
	PC.voiceLiveSend(now)
	if vo.sayQ[1] and now >= vo.sayT and #c.outbox < cfg.outboxMax then
		local q = table.remove(vo.sayQ, 1)
		PC.say(q.text, PC.voiceMode(), true, q.w and q or nil)
		vo.sayT = now + cfg.rate + 0.1
	end
	PC.voiceSample(now)
	if #vo.list == 0 and not vo.h.on then
		if vo.on then vo.on = false; PC.voiceFeed(vo, true) end           -- (once: nobody to hear, nobody to tell)
		return
	end
	-- the dummies talk in turns, each its whole line (the helper starts its clip over on each turn)
	if #vo.list > 0 then
		if now >= vo.nextT then
			vo.cur = vo.cur % #vo.list + 1
			local line = PC.VDUMMY_LINES[vo.list[vo.cur].idx]
			vo.talkUntil = now + (line and line.dur + 0.3 or cfg.voiceTurn)
			vo.nextT = vo.talkUntil + cfg.voiceGap
			PC.voiceDummyBegin(vo.list[vo.cur])
		end
		for i, d in ipairs(vo.list) do
			d.talking = (i == vo.cur and now < vo.talkUntil)
			PC.voiceDummyWords(d)
		end
	end
	if now - vo.feedT >= ((#vo.list > 0 or vo.room) and cfg.voiceFeed or cfg.voiceFeedIdle) then   -- (a room: real voices)
		vo.feedT, vo.on = now, true
		PC.voiceFeed(vo)
	end
end

-- a name over each voice dummy; "(( name ))" while it talks
function PC.voiceDraw()
	local c = PC.c
	local vo = c and c.voice
	if not vo then return end
	for _, d in ipairs(vo.list) do
		local x, y, dist = UiWorldToPixel(VecAdd(d.pos, Vec(0, 2.25, 0)))
		if dist and dist > 0 and dist < 80 then
			local col = PC.modeInfo(d.kind)[5]
			UiPush()
			UiTranslate(x, y)
			UiAlign("center middle")
			UiFont("bold.ttf", 22)
			UiTextShadow(0, 0, 0, 0.8, 1.5)
			UiColor(col[1], col[2], col[3], d.talking and 1 or 0.55)
			UiText(d.talking and ("(( " .. d.name .. " ))") or d.name)
			UiPop()
		end
	end
end
