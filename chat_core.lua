-- chat_core.lua - Proximity Babble Chat for Teardown v2 multiplayer: text chat with four speaking
-- MODES, speech bubbles and an Animal-Crossing-style "babble" voice. Works in any level / game mode;
-- reusable by #include in other mods. Source of truth: teardown-mods/proxchat/mods/proximity chat/chat_core.lua.
--
-- MODES (chosen on the input line; they decide how OTHERS hear your message; Tab / the chips go Whisper,
-- Speak, Yell, Global). Each of Whisper, Speak and Yell has a range (the words; PC.rangeOf) and a BUFFER beyond it where the message comes through
-- GARBLED (PC.garble: letters as mysterious glyphs; the closer, the more real letters show, up to
-- cfg.garbleMax). The history line holds the most of it you made out (it only gains letters); coming
-- within range while the bubble is up shows the words and completes that line. A Speak / Yell message
-- said out of earshot is kept, hidden, for its bubble's life: walking into the buffer or range while
-- it is up shows it (no babble then). Not a whisper: it is private to who was within its reach.
--   "s" Speak, the default: a speech bubble over your head and a babble voice played at you (quieter
--     and echoing with distance). Words within cfg.chatR (25 m), garbled to cfg.mumbleR (35 m).
--   "w" Whisper: words within cfg.whisperR (8 m), garbled to cfg.whisperMumbleR (12 m), nothing beyond.
--     A pale lavender bubble; a breathy babble (whisper0-7.ogg: noise through vowel formants; Robot:
--     rwhisper0-3, a crushed hiss), quiet, at your head, no echo; the voice's pitch still shifts it.
--   "y" Yell (/y; the code calls it shout): words within cfg.shoutR (40 m), garbled to cfg.shoutMumbleR
--     (55 m). An orange bubble and the raised-voice clips (shout0-7.ogg), a little louder.
--   "g" Global: every player gets the line in their chat - a plain chat line only: no bubble, no babble.
--   Lobby (PC.hooks.inLobby() true on the server): everything said is Global.
--   Your last mode is kept as your default next time (savegame.mod.pcmode).
--
-- BUBBLES are drawn in cfg.bubbleFont (Pangolin, a thick marker-hand font shipped in fonts/, OFL)
--   when that file exists and has every letter of the message (Latin incl. Vietnamese, Cyrillic);
--   anything else (Greek, CJK, Arabic, Thai...) uses the game font for its script (PC.chatFont). The
--   window stays in the game fonts. A bubble shows only while the listener is within its message's
--   reach (PC.inReach: buffer included). At most 2 bubbles a speaker (c.bubbles: the newest, c.prevBubbles: the
--   one before it, stacked above). Bubbles never cover each other (PC.layoutBubbles): lowest first,
--   an overlapping one is raised above, with a thin line down to its speaker. A message written all in capitals shakes (PC.allCaps), in any
--   mode; nothing else does. A bubble shows
--   cfg.bubbleLines lines; a longer message scrolls down inside it (clipped, a thin bar on the right) and
--   the bubble stays up that much longer (b.extra).
--
-- DISTANCES: the host sets them for everyone on the Settings page (PC.rangeBar: whisper, speak, yell;
--   each buffer a share of its range: cfg.whisperBuf / speakBuf / shoutBuf), shared.pcRanges; a map may
--   SetString("proxchat.ranges", "w,s,sh"). PC.applyRanges sets cfg.whisperR .. shoutMumbleR.
--
-- HISTORY: ONE list per player of everything THEY received: every Global line, plus the Speak /
--   Whisper / Yell lines they were in range (or a buffer) of, so every player's history is different.
--   Lines are tagged [global] / [speak] / [whisper] / [yell] (whispers lavender, yells orange).
--   Bounded to cfg.keepHist.
--
-- THE WINDOW: Enter opens the input line and the chat window (interactive: mouse cursor). The line
--   shows the mode ("Whisper:", "Speak:", "Yell:", "Global:") and four mode chips at its
--   right end; Tab or a click on a chip changes the mode. Enter says it, Esc closes. The window shows
--   the history (wheel / PgUp / PgDn scroll) and, right-aligned in its header, a "Settings" button:
--   the Settings page has the voice picker (a click picks: synced so others hear it, saved, a preview
--   only you hear), the hint on/off, keep the window open, speech bubbles (Off / 25-100 % solid; the text
--   stays readable) and babble volume (a 0-100 % slider, savegame.mod.pcvolume); "Back" returns.
--   With the window closed the newest lines fade out in a feed. No hotkeys besides Enter (a host mod
--   may set PC.cfg.windowKey to pin the window with a key).
--   Clicks fire on the mouse PRESS (UiIsMouseInRect + InputPressed("lmb")), with UiBlankButton (fires
--   on release) as a de-duplicated fallback: one click is one action (UiBlankButton alone missed
--   clicks in Tall Order's lobby).
-- COMMANDS (echoed locally): /s /w /y /g [text] (Speak / Whisper / Yell / Global: set the mode, or say one line
--   in it; /p = /s), /voice [name|n], /settings, /hint, /window, /clear, /mute [name], /unmute name|all, /dummy [1|2|3|clear]
--   (local test speakers), /help, //text sends "/text".
--
-- (copy fonts/ too for the bubble font; without it the bubbles use the game fonts)
-- API (every name lives in the PC table; ServerCall targets are server.pc_*; shared keys are pc*;
-- registry keys proxchat.*; persistent settings savegame.mod.pc*)
--   #include "chat_core.lua"          in a #version 2 script; copy snd/ (babble0-7, shout0-7, robot0-3,
--                                     whisper0-7, rwhisper0-3)
--   PC.cfg.<key> = value              optional overrides: set PC = {cfg = {...}} before the include, or
--                                     PC.cfg.x before init (keys: the defaults below)
--   PC.serverInit()                   in server.init
--   PC.serverTick(dt)                 in server.tick
--   PC.clientInit()                   in client.init
--   PC.clientTick(dt)                 in client.tick (receives messages, plays the babble)
--   PC.draw()                         in client.draw (bubbles, window / feed, input line, keys)
--   PC.isTyping(p)                    server: any player; client: the local player. Skip your own keys
--                                     while it is true. Other scripts: GetBool("proxchat.typing." .. p)
--                                     (host: every player; any machine: its own player)
--   PC.say(text, mode)                client: say something as the local player (mode "w" / "s" / "y" / "g"; "p" = "s", the old id)
--   PC.mode() / PC.setMode(m)         client: the input line's mode (setMode saves it)
--   PC.system(text)                   client: a local line in the history (only this player sees it)
--   PC.history([mode])                client: the history (entries: name, text, p, ch = mode or "sys",
--                                     shout, far, sys, t); with a mode: only those lines (a copy)
--   PC.setVoice(i)                    client: pick voice i of PC.VOICES (synced, saved, previewed)
--   PC.page() / PC.setPage(pg)        client: the window page, "chat" or "settings"
--   PC.clicked(id, w, h)              client: a press-firing, de-duplicated click on a w x h rect at the
--                                     cursor (for your own buttons while UiMakeInteractive is on)
--   Hooks (all optional; define them in PC.hooks):
--   PC.hooks.inLobby()                server: true = everyone hears everything (Global only)
--   PC.hooks.everyoneHears(speaker)   client: true = the local player hears this speaker's NEARBY
--                                     messages in full wherever they are (spectators, radios...);
--                                     whispers still need cfg.whisperR
--   PC.hooks.blockKeys()              client: true = Enter (and cfg.windowKey) do nothing
--   PC.hooks.onMessage(msg, heard)    client: a message arrived; heard = what was heard or nil
--   PC.hooks.log(line)                server: diagnostics
--   Registry switches a game sets on the host, every tick: proxchat.walls (bool, when set: walls muffle
--   voices or not, over the host's setting; PC.hearDist) and proxchat.channel.<p> (a name, "dead": p talks only to that channel and hears everyone). Every
--   machine, every tick: proxchat.version (PC.API_VERSION) and proxchat.alive (GetTime()).
--
-- Engine notes (see the teardown-modding skill, "Multiplayer social features"):
--   - Text entry is the engine's UiTextInput used as a real field (pass the current text, focus = true
--     for one frame, get the edited text back). Verified in-game in Tall Order.
--   - On clients every read of `shared` hands out a fresh copy: never compare shared tables by
--     identity; messages are matched by id, and each tick reads shared.pcMsgs once.
--   - Text is UTF-8: counted, cased and cut as characters; fonts per script; Arabic shaped, RTL laid out.
--   - Delivery: a client numbers its messages and resends the oldest unconfirmed one (PC.pump) until
--     shared.pcAck[p] shows it (the server ignores a number it has taken). shared.pcNow (server time,
--     each second) lets a lagging client time a late message from when it was said.
--   - Whispers never go into shared: the server sends each only to the players near enough
--     (ClientCall "client.pc_whisper"), so other games never have the text.
--   - Sanitizing (PC.clean, also names): no invisible / direction-changing characters, at most
--     cfg.maxMarks accents a letter.

PC = PC or {}
PC.cfg = PC.cfg or {}
PC.hooks = PC.hooks or {}

do
	local defaults = {
		chatR = 25,              -- m: who hears you (nearby)
		shoutR = 40,             -- m: who hears your shouts
		shoutMumbleR = 55,       -- m: the shouts' buffer beyond shoutR (garbled; nothing beyond)
		whisperR = 8,            -- m: who hears a whisper
		mumbleR = 35,            -- m: Speak's buffer beyond chatR: the babble and the message garbled
		whisperMumbleR = 12,     -- m: Whisper's buffer beyond whisperR (nothing beyond it)
		bubbleW = 320,           -- px: a bubble's text wraps at this width
		bubbleLines = 3,         -- lines a bubble shows; longer messages scroll down inside it
		scrollHold = 1.5,        -- s before a long message starts scrolling
		scrollLine = 1.8,        -- s per line while it scrolls (the bubble stays up that much longer)
		revealHold = 1,          -- s a bubble stays up at least once it is fully revealed (no other reveal extends it)
		whisperBuf = 0.5,        -- each buffer as a share of its range: whisper 8 -> 12 m, speech 25 -> 35 m,
		speakBuf = 0.4,          --   shout 40 -> 55 m (the host's distance bar keeps these shares)
		shoutBuf = 0.375,
		rangeMin = 2, rangeMax = 80,  -- m: the host's distance bar
		wallFactor = 0.5,        -- walls on (proxchat.walls): through a wall / floor / roof a voice carries this share as far
		wallBeam = 0.4,          -- m: the beam's 3 x 3 rays, this far apart (up / down / sideways)
		wallEvery = 0.25,        -- s: a speaker's beam re-checked this often while it matters
		pathEvery = 1.0,         -- s: the way round asked again at most this often (unless an end moved:)
		pathMove = 1.0,          -- m: ... or when the listener or the speaker moved this far
		pathTarget = 0.5,        -- m: the way round must end this close to the speaker's head
		pathMax = 2,             -- searches for a way round running at once (each machine; more speakers wait)
		garbleMax = 0.75,        -- share of the letters revealed at the buffer's inner edge (0 at its outer edge)
		dummyType = 1.5,         -- s the test dummy (/dummy) shows "..." before each line
		dummyShow = 4.5,         -- s after the last of them spoke, before the next line
		dummyGap = 2,            -- s between the dummies' turns (whisperer, speaker, shouter)
		life = 9,                -- s a feed line stays
		lifeMin = 2.5,           -- s a bubble stays: lifeMin + lifePerChar a character, at most lifeMax (+ scrolling)
		lifePerChar = 0.1,
		lifeMax = 12,
		maxLen = 90,             -- characters per message
		keepShared = 30,         -- messages in shared.pcMsgs
		sharedLife = 30,         -- s a message stays in shared (clients copy it on arrival; a lagging client still gets it)
		lateAge = 2,             -- s: a message older than this on arrival is timed from when it was said, no babble
		resendT = 0.6,           -- s between resends of a message the server has not confirmed yet
		resendFor = 8,           -- s before an unconfirmed message is given up (a line in your history says so)
		outboxMax = 4,           -- messages waiting to be confirmed at most (more: "slow down")
		whisperSlack = 2,        -- m the server adds to whisperMumbleR when it picks who gets a whisper
		maxMarks = 2,            -- combining marks (accents) a letter may carry (no "zalgo" towers)
		nameLen = 24,            -- characters of a player name
		keepHist = 50,           -- lines in the local history
		rate = 0.45,             -- s between two messages of one player
		sndDir = "MOD/snd/",
		bubbleFont = "MOD/fonts/pangolin.ttf", -- the speech bubbles' font ("" = the game fonts)
		bubbleSize = 32,         -- its size (Pangolin is a bit small for its size; the game fonts use 30)
		windowKey = "",          -- a hotkey that pins the chat window ("" = none; /window does it)
		reg = "proxchat",        -- registry prefix
		save = "savegame.mod.pc",-- persistent settings: pcvoice, pcmode, pchidehint, pchideown, pcbubbles, pcvolume
		babbleMax = 45,          -- syllables per message
		babbleVol = 0.75,
		shoutVol = 0.8,          -- Yell (the shout clips, already a little louder than babble)
		globalVol = 0.35,        -- the voice preview (Settings): this much of the voice's volume, at the listener
		globalMaxSyl = 14,       -- the voice preview: at most this many syllables
		whisperVol = 0.45,       -- whisper babble: this much of the voice's volume, at the speaker
		echoFrom = 6,            -- m: farther voices echo
		soundNear = 5,           -- m: farther voices are played this far away in their direction (PC.soundPos)
		soundGrace = 1.5,        -- m the babble carries past the bubble's reach (fading to nothing there)
		soundFar = 0.35,         -- the distance curve's value at a message's reach (1 up close; the buffer then fades it to 0; PC.loudness)
		winW = 1000, winH = 400, -- the chat window (and the input line's width), before uiScale
		uiScale = 0.8,           -- the chat window, feed, input line and hint, scaled from the bottom-left corner
		countFrom = 60,          -- characters typed from which the input line shows "n/maxLen"
		feedLines = 6,
		hintIntro = 15,          -- s the longer hint shows after loading
	}
	for k, v in pairs(defaults) do
		if PC.cfg[k] == nil then PC.cfg[k] = v end
	end
end

-- name, pitch, s per syllable, clip set, volume
PC.VOICES = {
	{"Squeaky", 1.45, 0.062, "voice", 1.0},
	{"Chirpy", 1.2, 0.068, "voice", 1.0},
	{"Plain", 1.0, 0.075, "voice", 1.0},
	{"Low", 0.82, 0.082, "voice", 1.0},
	{"Deep", 0.64, 0.092, "voice", 1.0},
	{"Robot", 1.0, 0.07, "robot", 0.35},          -- (square waves are loud: 35 %)
}
-- the Settings levels for speech bubbles (opacity): Off, 25 %, 50 %, 75 %, 100 % (the babble volume is a slider)
PC.LEVELS = {0, 0.25, 0.5, 0.75, 1}
PC.LEVEL_NAMES = {"Off", "25%", "50%", "75%", "100%"}
PC.BABBLE_SETS = {voice = 8, shout = 8, robot = 4, whisper = 8, rwhisper = 4}
PC.CLIP_FILE = {voice = "babble", shout = "shout", robot = "robot", whisper = "whisper", rwhisper = "rwhisper"}

-- the modes, in Tab / chip order: id, prompt on the input line, chip label, history tag, colour
PC.MODES = {
	{"w", "Whisper: ", "Whisper", "[whisper]", {0.78, 0.78, 0.9}},
	{"s", "Speak: ", "Speak", "[speak]", {1, 0.82, 0.3}},
	{"y", "Yell: ", "Yell", "[yell]", {1, 0.58, 0.28}},
	{"g", "Global: ", "Global", "[global]", {0.55, 0.8, 1}},
}
-- what a player in a channel says (proxchat.channel.<p> = "dead", "dead red"...): only that channel
-- hears it - not a mode on the line. The tag and the prompt show the channel's name (PC.channelInfo)
PC.DEAD = {"d", "Dead: ", "Dead", "[dead]", {0.62, 0.62, 0.68}}
function PC.channelInfo(chan)
	if not chan or chan == "" or chan == "dead" then return PC.DEAD end
	local label = chan:sub(1, 1):upper() .. chan:sub(2)
	return {"d", label .. ": ", label, "[" .. chan .. "]", PC.DEAD[5]}
end
function PC.modeInfo(m)
	if m == "d" then return PC.DEAD end
	for _, x in ipairs(PC.MODES) do if x[1] == m then return x end end
	return PC.MODES[2]                                             -- (Speak)
end

-- ============================================================================ text in any language
-- Chat text is UTF-8: letters are counted, cased and cut as characters, not bytes (Lua's %a / upper()
-- only know A-Z; a byte cut can split a letter in half).
PC.UTF8_CHAR = "[%z\1-\127\194-\244][\128-\191]*"

function PC.utf8Code(ch)
	local b1 = ch:byte(1)
	if not b1 then return 0 end
	if b1 < 0x80 then return b1 end
	if b1 < 0xE0 then return (b1 - 0xC0) * 64 + ((ch:byte(2) or 0x80) - 0x80) end
	if b1 < 0xF0 then return ((b1 - 0xE0) * 64 + ((ch:byte(2) or 0x80) - 0x80)) * 64 + ((ch:byte(3) or 0x80) - 0x80) end
	return (((b1 - 0xF0) * 64 + ((ch:byte(2) or 0x80) - 0x80)) * 64 + ((ch:byte(3) or 0x80) - 0x80)) * 64 + ((ch:byte(4) or 0x80) - 0x80)
end

function PC.utf8Char(c)
	if c < 0x80 then return string.char(c) end
	if c < 0x800 then return string.char(0xC0 + math.floor(c / 64), 0x80 + c % 64) end
	if c < 0x10000 then return string.char(0xE0 + math.floor(c / 4096), 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64) end
	return string.char(0xF0 + math.floor(c / 262144), 0x80 + math.floor(c / 4096) % 64, 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64)
end

-- what a character is for speech: "letter", "cjk" (a syllable by itself), "space", "pause" (punctuation
-- that pauses: . , ! ? and their CJK / Arabic / Devanagari forms), "other" (symbols, marks)
function PC.utf8Kind(ch)
	local c = PC.utf8Code(ch)
	if c < 0x80 then
		if ch:match("^[%w]$") then return "letter" end
		if ch == " " or ch == "\t" then return "space" end
		if ch:match("^[%.,;:!%?]$") then return "pause" end
		return "other"
	end
	if c == 0xA1 or c == 0xBF or c == 0x60C or c == 0x61B or c == 0x61F or c == 0x964 or c == 0x965 then return "pause" end
	if c == 0x3000 then return "space" end
	if (c >= 0x3001 and c <= 0x3002) or (c >= 0xFF01 and c <= 0xFF0F) or (c >= 0xFF1A and c <= 0xFF1F) then return "pause" end
	if (c >= 0x80 and c <= 0xBF) or (c >= 0x2000 and c <= 0x2BFF) or (c >= 0x3003 and c <= 0x303F) or (c >= 0xFE00 and c <= 0xFE0F) then return "other" end
	if c >= 0x300 and c <= 0x36F then return "other" end                       -- combining accents
	if (c >= 0x1100 and c <= 0x11FF) or (c >= 0x3040 and c <= 0x9FFF) or (c >= 0xAC00 and c <= 0xD7AF) or (c >= 0xF900 and c <= 0xFAFF) or c >= 0x20000 then
		return "cjk"
	end
	return "letter"
end

-- "upper" / "lower" for cased letters (Latin incl. extended and Vietnamese, Greek, Cyrillic, Armenian);
-- "none" for letters of scripts without case; "other" for non-letters
function PC.utf8Case(ch)
	local k = PC.utf8Kind(ch)
	if k ~= "letter" and k ~= "cjk" then return "other" end
	local c = PC.utf8Code(ch)
	if c < 0x80 then
		if c >= 65 and c <= 90 then return "upper" elseif c >= 97 and c <= 122 then return "lower" end
		return "none"                                                     -- digits
	end
	if c >= 0xC0 and c <= 0xDE and c ~= 0xD7 then return "upper" end
	if c >= 0xDF and c <= 0xFF and c ~= 0xF7 then return "lower" end
	if c >= 0x100 and c <= 0x17F then return (c % 2 == 0) and "upper" or "lower" end
	if c >= 0x386 and c <= 0x3AB then return "upper" end
	if c >= 0x3AC and c <= 0x3CE then return "lower" end
	if c >= 0x400 and c <= 0x42F then return "upper" end
	if c >= 0x430 and c <= 0x45F then return "lower" end
	if (c >= 0x460 and c <= 0x4FF) or (c >= 0x500 and c <= 0x52F) or (c >= 0x1E00 and c <= 0x1EFF) then return (c % 2 == 0) and "upper" or "lower" end
	if c >= 0x531 and c <= 0x556 then return "upper" end
	if c >= 0x561 and c <= 0x587 then return "lower" end
	return "none"
end

-- the first n characters (never a letter cut in half)
function PC.utf8Head(s, n)
	local out, k = {}, 0
	for ch in s:gmatch(PC.UTF8_CHAR) do
		k = k + 1
		if k > n then break end
		out[k] = ch
	end
	return table.concat(out)
end

function PC.utf8Len(s)
	local k = 0
	for _ in s:gmatch(PC.UTF8_CHAR) do k = k + 1 end
	return k
end

-- ---- the buffer range: a message half heard. Each letter becomes a mysterious glyph unless it is
-- revealed: a fixed share of the letters (frac, 0-1) chosen per message (seed), so walking closer
-- uncovers more of the same message. Spaces and punctuation stay (the shape of the sentence shows).
-- With several PC.GARBLE glyphs they shimmer with tick.
-- The glyph: ⬚ (U+2B1A). Our Pangolin has it (added by tools/add_box_glyph.py); of the game's fonts
-- only the CJK ones do, so without Pangolin a garbled bubble falls back to bold_sc.ttf (PC.scriptOf
-- counts ⬚ as "cjk"; that font has Latin and Cyrillic too).
PC.GARBLE = {"\226\172\154"}
local function hash01(a, b, c)
	return ((a * 73856093 + b * 19349663 + c * 83492791) % 1000003) / 1000003
end
function PC.garble(text, frac, seed, tick)
	local out, i = {}, 0
	for sp, w in text:gmatch("(%s*)(%S+)") do
		out[#out + 1] = sp
		for ch in w:gmatch(PC.UTF8_CHAR) do
			i = i + 1
			if (#ch == 1 and ch:find("%p")) or hash01(seed, i, 0) < frac then
				out[#out + 1] = ch
			else
				out[#out + 1] = PC.GARBLE[math.floor(hash01(seed, i, tick + 1) * #PC.GARBLE) + 1]
			end
		end
	end
	return table.concat(out)
end

-- a message written all in capitals (2+ cased letters, none lower case, any script): its bubble shakes
function PC.allCaps(text)
	local n = 0
	for ch in (text or ""):gmatch(PC.UTF8_CHAR) do
		local k = PC.utf8Case(ch)
		if k == "lower" then return false end
		if k == "upper" then n = n + 1 end
	end
	return n >= 2
end

-- a mode's range: where its words are heard (inner) and where its buffer ends (outer)
function PC.rangeOf(mode)
	local cfg = PC.cfg
	if mode == "w" then return cfg.whisperR, cfg.whisperMumbleR end
	if mode == "y" then return cfg.shoutR, cfg.shoutMumbleR end
	return cfg.chatR, cfg.mumbleR
end

-- what a bubble shows now: in the buffer range the message garbled, more of it revealed the closer
-- the listener is (up to cfg.garbleMax just outside the range)
function PC.bubbleText(p, b, now)
	if b.level ~= "mumble" then return b.text end
	return PC.garble(b.full, PC.bufferF(p, b) or 0, b.id or 0, math.floor(now * 3))
end

-- the listener is within the farthest reach of this bubble's message (its buffer included): beyond it
-- the bubble is not shown (it shows again on coming back while it is up)
function PC.inReach(p, b)
	local cfg = PC.cfg
	if p == GetLocalPlayer() then return true end
	if PC.dead() then return true end                                 -- (the dead hear everyone)
	if not b.whisper and PC.hooks.everyoneHears and PC.hooks.everyoneHears(p) then return true end
	local d = PC.hearDist(p)
	if not d then return false end
	local _, reach = PC.rangeOf(b.mode)
	return d <= reach
end

-- how long a bubble stays (before any scrolling time): short messages go sooner
function PC.bubbleLife(b)
	local cfg = PC.cfg
	return math.min(cfg.lifeMax, cfg.lifeMin + PC.utf8Len(b.full or b.text or "") * cfg.lifePerChar)
end

-- the share of the letters revealed now (0 at the buffer's outer edge, cfg.garbleMax at its inner one);
-- nil beyond the buffer
function PC.bufferF(p, b)
	local cfg = PC.cfg
	local inner, outer = PC.rangeOf(b.mode)
	local d = PC.hearDist(p)
	if not (d and d <= outer) then return nil end
	return math.max(0, math.min(1, (outer - d) / (outer - inner))) * cfg.garbleMax
end

-- the history line of a bubble: the most of it this player ever made out
function PC.histText(b)
	if b.level == "full" then return b.full end
	return PC.garble(b.full, math.max(0, b.bestF or 0), b.id or 0, 0)
end

-- characters removed outright: zero-width ones, direction overrides / isolates, line and paragraph
-- separators, the BOM
local function pcStripped(c)
	return (c >= 0x200B and c <= 0x200F) or (c >= 0x2028 and c <= 0x202E) or (c >= 0x2060 and c <= 0x206F) or c == 0xFEFF
end
-- generic combining marks (stacked into "zalgo" towers); the vowel marks of Arabic, Hebrew, Thai,
-- Devanagari... are not in these ranges and are kept
local function pcMark(c)
	return (c >= 0x300 and c <= 0x36F) or (c >= 0x483 and c <= 0x489) or (c >= 0x1AB0 and c <= 0x1AFF)
		or (c >= 0x1DC0 and c <= 0x1DFF) or (c >= 0x20D0 and c <= 0x20FF) or (c >= 0xFE20 and c <= 0xFE2F)
end

-- sanitize: ASCII control bytes (never %c: it would eat UTF-8), invisible / direction-changing
-- characters, more than cfg.maxMarks accents on a letter; trimmed, cfg.maxLen characters
function PC.clean(text)
	if type(text) ~= "string" then return "" end
	local out, run = {}, 0
	for ch in text:gmatch(PC.UTF8_CHAR) do
		local c = PC.utf8Code(ch)
		if pcStripped(c) then
		elseif pcMark(c) then
			run = run + 1
			if run <= PC.cfg.maxMarks then out[#out + 1] = ch end
		else
			run = 0
			out[#out + 1] = ch
		end
	end
	text = table.concat(out)
	text = text:gsub("[%z\1-\31\127]", " ")
	text = text:gsub("^%s+", "")
	text = text:gsub("%s+$", "")
	return PC.utf8Head(text, PC.cfg.maxLen)
end

-- a player's name, cleaned like a message and at most cfg.nameLen characters
function PC.cleanName(name, p)
	name = PC.utf8Head(PC.clean(name), PC.cfg.nameLen)
	if name == "" then name = "Player " .. tostring(p) end
	return name
end

-- ---- display: which of the game's fonts has this text's script
function PC.scriptOf(c)
	if c < 0x250 or (c >= 0x1E00 and c <= 0x1EFF) or (c >= 0x370 and c <= 0x52F) then return "base" end
	if c == 0x2B1A then return "cjk" end                                  -- (⬚, PC.GARBLE: only the CJK fonts have it)
	if (c >= 0x3040 and c <= 0x30FF) or (c >= 0x31F0 and c <= 0x31FF) then return "kana" end
	if (c >= 0x1100 and c <= 0x11FF) or (c >= 0x3000 and c <= 0x303F) or (c >= 0x3130 and c <= 0x318F) or (c >= 0x3400 and c <= 0x9FFF)
		or (c >= 0xAC00 and c <= 0xD7AF) or (c >= 0xF900 and c <= 0xFAFF) or (c >= 0xFF00 and c <= 0xFFEF) then return "cjk" end
	if c >= 0x2000 and c <= 0x2BFF then return "base" end
	return "wide"                                                         -- Arabic, Hebrew, Thai, Devanagari...
end

function PC.chatFont(text, bold)
	local kana, cjk, wide = false, false, false
	for ch in (text or ""):gmatch(PC.UTF8_CHAR) do
		local s = PC.scriptOf(PC.utf8Code(ch))
		if s == "kana" then kana = true elseif s == "cjk" then cjk = true elseif s == "wide" then wide = true end
	end
	if wide then return "arial.ttf" end                                   -- (the game's widest font; no bold)
	if kana then return bold == false and "regular_jp.ttf" or "bold_jp.ttf" end
	if cjk then return bold == false and "regular_sc.ttf" or "bold_sc.ttf" end
	return bold == false and "regular.ttf" or "bold.ttf"
end

-- the characters cfg.bubbleFont (Pangolin) has, as code point ranges (a font with other letters: list them)
PC.BUBBLE_CHARS = {
	{0x20, 0x7E}, {0xA0, 0x131}, {0x134, 0x148}, {0x14A, 0x17E}, {0x1A0, 0x1A1}, {0x1AF, 0x1B0},   -- Latin
	{0x1FA, 0x21B}, {0x259, 0x259}, {0x1E9E, 0x1E9E}, {0x1EA0, 0x1EF9},                         -- (+ Vietnamese)
	{0x400, 0x45F}, {0x490, 0x49D}, {0x4A0, 0x4A5}, {0x4AA, 0x4AB}, {0x4AE, 0x4B1}, {0x4B6, 0x4BB}, -- Cyrillic
	{0x4C0, 0x4C2}, {0x4CF, 0x4D9}, {0x4E2, 0x4E9}, {0x4EE, 0x4F9},
	{0x2010, 0x2010}, {0x2012, 0x2015}, {0x2018, 0x201A}, {0x201C, 0x201E}, {0x2020, 0x2022},     -- punctuation
	{0x2026, 0x2026}, {0x2030, 0x2030}, {0x2039, 0x203A}, {0x20AB, 0x20AE}, {0x20B4, 0x20B4},
	{0x20BD, 0x20BD}, {0x2116, 0x2116}, {0x2122, 0x2122},
	{0x2B1A, 0x2B1A},                                                                         -- (⬚: added, PC.GARBLE)
}

-- the font and size of a speech bubble with this text
function PC.bubbleFont(text, bold)
	local f = PC.cfg.bubbleFont
	if f and f ~= "" then
		if PC.bubbleFontOk == nil then
			local ok, has = pcall(HasFile, f)
			PC.bubbleFontOk = ok and has == true
		end
		if PC.bubbleFontOk then
			local all = true
			for ch in (text or ""):gmatch(PC.UTF8_CHAR) do
				local c, found = PC.utf8Code(ch), false
				for _, r in ipairs(PC.BUBBLE_CHARS) do
					if c >= r[1] and c <= r[2] then found = true; break end
				end
				if not found then all = false; break end
			end
			if all then return f, PC.cfg.bubbleSize end
		end
	end
	return PC.chatFont(text, bold), 30
end

-- ---- display: Arabic joining and right-to-left order
-- Arabic letter -> {isolated, final, initial, medial} presentation forms (initial / medial nil: the
-- letter joins only to the one before it)
PC.AR = {
	[0x621] = {0xFE80}, [0x622] = {0xFE81, 0xFE82}, [0x623] = {0xFE83, 0xFE84}, [0x624] = {0xFE85, 0xFE86},
	[0x625] = {0xFE87, 0xFE88}, [0x626] = {0xFE89, 0xFE8A, 0xFE8B, 0xFE8C}, [0x627] = {0xFE8D, 0xFE8E},
	[0x628] = {0xFE8F, 0xFE90, 0xFE91, 0xFE92}, [0x629] = {0xFE93, 0xFE94}, [0x62A] = {0xFE95, 0xFE96, 0xFE97, 0xFE98},
	[0x62B] = {0xFE99, 0xFE9A, 0xFE9B, 0xFE9C}, [0x62C] = {0xFE9D, 0xFE9E, 0xFE9F, 0xFEA0}, [0x62D] = {0xFEA1, 0xFEA2, 0xFEA3, 0xFEA4},
	[0x62E] = {0xFEA5, 0xFEA6, 0xFEA7, 0xFEA8}, [0x62F] = {0xFEA9, 0xFEAA}, [0x630] = {0xFEAB, 0xFEAC}, [0x631] = {0xFEAD, 0xFEAE},
	[0x632] = {0xFEAF, 0xFEB0}, [0x633] = {0xFEB1, 0xFEB2, 0xFEB3, 0xFEB4}, [0x634] = {0xFEB5, 0xFEB6, 0xFEB7, 0xFEB8},
	[0x635] = {0xFEB9, 0xFEBA, 0xFEBB, 0xFEBC}, [0x636] = {0xFEBD, 0xFEBE, 0xFEBF, 0xFEC0}, [0x637] = {0xFEC1, 0xFEC2, 0xFEC3, 0xFEC4},
	[0x638] = {0xFEC5, 0xFEC6, 0xFEC7, 0xFEC8}, [0x639] = {0xFEC9, 0xFECA, 0xFECB, 0xFECC}, [0x63A] = {0xFECD, 0xFECE, 0xFECF, 0xFED0},
	[0x641] = {0xFED1, 0xFED2, 0xFED3, 0xFED4}, [0x642] = {0xFED5, 0xFED6, 0xFED7, 0xFED8}, [0x643] = {0xFED9, 0xFEDA, 0xFEDB, 0xFEDC},
	[0x644] = {0xFEDD, 0xFEDE, 0xFEDF, 0xFEE0}, [0x645] = {0xFEE1, 0xFEE2, 0xFEE3, 0xFEE4}, [0x646] = {0xFEE5, 0xFEE6, 0xFEE7, 0xFEE8},
	[0x647] = {0xFEE9, 0xFEEA, 0xFEEB, 0xFEEC}, [0x648] = {0xFEED, 0xFEEE}, [0x649] = {0xFEEF, 0xFEF0}, [0x64A] = {0xFEF1, 0xFEF2, 0xFEF3, 0xFEF4},
	-- Persian / Urdu
	[0x67E] = {0xFB56, 0xFB57, 0xFB58, 0xFB59}, [0x686] = {0xFB7A, 0xFB7B, 0xFB7C, 0xFB7D}, [0x698] = {0xFB8A, 0xFB8B},
	[0x6A9] = {0xFB8E, 0xFB8F, 0xFB90, 0xFB91}, [0x6AF] = {0xFB92, 0xFB93, 0xFB94, 0xFB95}, [0x6CC] = {0xFBFC, 0xFBFD, 0xFBFE, 0xFBFF},
}
PC.LAMALEF = {[0x622] = {0xFEF5, 0xFEF6}, [0x623] = {0xFEF7, 0xFEF8}, [0x625] = {0xFEF9, 0xFEFA}, [0x627] = {0xFEFB, 0xFEFC}}

function PC.arTransparent(c) return (c >= 0x610 and c <= 0x61A) or (c >= 0x64B and c <= 0x65F) or c == 0x670 end
function PC.joinsNext(c) return (PC.AR[c] and PC.AR[c][3] ~= nil) or c == 0x640 end   -- (0x640: the tatweel)
function PC.joinsPrev(c) return PC.AR[c] ~= nil or c == 0x640 end
function PC.isRTL(c) return (c >= 0x590 and c <= 0x8FF) or (c >= 0xFB1D and c <= 0xFDFF) or (c >= 0xFE70 and c <= 0xFEFF) end
function PC.isStrongL(c)
	if c < 0x80 then return (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57) end
	if PC.isRTL(c) then return false end
	local k = PC.utf8Kind(PC.utf8Char(c))
	return k ~= "other" and k ~= "space" and k ~= "pause"
end

-- the text as it must be drawn left to right (Arabic joined, right-to-left runs reversed); the stored
-- message stays in logical order
function PC.chatVisual(text)
	if not text or not text:find("[\214-\223]") then return text end      -- (no Hebrew / Arabic: unchanged)
	local AR, cs = PC.AR, {}
	for ch in text:gmatch(PC.UTF8_CHAR) do cs[#cs + 1] = PC.utf8Code(ch) end
	local out = {}
	local i = 1
	while i <= #cs do
		local c = cs[i]
		if AR[c] then
			local p = i - 1
			while p >= 1 and PC.arTransparent(cs[p]) do p = p - 1 end
			local n = i + 1
			while n <= #cs and PC.arTransparent(cs[n]) do n = n + 1 end
			local fromPrev = p >= 1 and PC.joinsNext(cs[p])
			if c == 0x644 and n <= #cs and PC.LAMALEF[cs[n]] then              -- lam + alef: one ligature
				out[#out + 1] = PC.LAMALEF[cs[n]][fromPrev and 2 or 1]
				for k = i + 1, n - 1 do out[#out + 1] = cs[k] end
				i = n + 1
			else
				local toNext = n <= #cs and PC.joinsNext(c) and PC.joinsPrev(cs[n])
				local f = AR[c]
				local form
				if fromPrev and toNext then form = f[4] elseif fromPrev then form = f[2] elseif toNext then form = f[3] end
				out[#out + 1] = form or f[1]
				i = i + 1
			end
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	-- runs: R (right to left), L (left to right), N (spaces / punctuation: take the side they are in)
	local runs = {}
	for _, c in ipairs(out) do
		local t = PC.isRTL(c) and "R" or (PC.isStrongL(c) and "L" or "N")
		local last = runs[#runs]
		if last and last.t == t then last.c[#last.c + 1] = c else runs[#runs + 1] = {t = t, c = {c}} end
	end
	local base = "L"
	for _, r in ipairs(runs) do if r.t ~= "N" then base = r.t; break end end
	for k, r in ipairs(runs) do
		if r.t == "N" then
			local before = runs[k - 1] and runs[k - 1].t or base
			local after = runs[k + 1] and runs[k + 1].t or base
			r.t = (before == after) and before or base
		end
	end
	local merged = {}
	for _, r in ipairs(runs) do
		local last = merged[#merged]
		if last and last.t == r.t then for _, c in ipairs(r.c) do last.c[#last.c + 1] = c end else merged[#merged + 1] = {t = r.t, c = r.c} end
	end
	local order = {}
	if base == "R" then for k = #merged, 1, -1 do order[#order + 1] = merged[k] end else order = merged end
	local s = {}
	for _, r in ipairs(order) do
		if r.t == "R" then for k = #r.c, 1, -1 do s[#s + 1] = PC.utf8Char(r.c[k]) end
		else for k = 1, #r.c do s[#s + 1] = PC.utf8Char(r.c[k]) end end
	end
	return table.concat(s)
end

-- draw chat text: the right font, joined and in visual order
function PC.text(text, size, bold)
	UiFont(PC.chatFont(text, bold), size)
	UiText(PC.chatVisual(text))
end

function PC.textWidth(text, size, bold)
	UiFont(PC.chatFont(text, bold), size)
	return UiGetTextSize(PC.chatVisual(text)) or 0
end

-- ============================================================================ server
-- "the chat runs here": proxchat.version (the API's version) and proxchat.alive (GetTime() of the last
-- tick), on every machine, every tick (the server's ClearKey at its start wipes them: set again at once)
PC.API_VERSION = 2
function PC.heartbeat()
	local reg = PC.cfg.reg
	SetInt(reg .. ".version", PC.API_VERSION)
	SetFloat(reg .. ".alive", GetTime())
end

function PC.serverInit()
	PC.s = {time = 0, typing = {}, last = {}, seq = {}, n = 0, pruneT = 0, lobby = false, chan = {}, walls = nil,
		wallsHost = GetBool(PC.cfg.save .. "wallson")}               -- (walls: off unless the host turned them on)
	ClearKey(PC.cfg.reg)
	shared.pcMsgs = {}
	shared.pcVoice = {}
	shared.pcTyping = {}
	shared.pcLobby = false
	shared.pcChan = {}
	shared.pcWalls = PC.s.wallsHost
	shared.pcWallsBy = "host"
	shared.pcAck = {}
	shared.pcNow = 0
	-- the distances: the host's last choice, else the defaults (a map can set proxchat.ranges, see serverTick)
	PC.defaultRanges = PC.defaultRanges or {PC.cfg.whisperR, PC.cfg.chatR, PC.cfg.shoutR}
	local w, sp, sh = GetString(PC.cfg.save .. "ranges"):match("^([%d%.]+),([%d%.]+),([%d%.]+)$")
	if w then PC.setRanges(w, sp, sh, false) else PC.setRanges(PC.defaultRanges[1], PC.defaultRanges[2], PC.defaultRanges[3], false) end
end

function PC.S()
	if not PC.s then PC.serverInit() end
	return PC.s
end

function PC.inLobby()
	return (PC.hooks.inLobby and PC.hooks.inLobby()) and true or false
end

function PC.log(s)
	if PC.hooks.log then PC.hooks.log(s) end
end

-- a mode from the network: "s", "w", "y" or "g" ("g" only in the lobby; "p" = "s", the old id)
function PC.validMode(m)
	if PC.inLobby() then return "g" end
	if m == "g" or m == "w" or m == "y" then return m end
	return "s"
end

-- the distances (words reach) for whisper, speech and shout; each buffer follows as its share
function PC.applyRanges(w, sp, sh)
	local cfg = PC.cfg
	cfg.whisperR, cfg.chatR, cfg.shoutR = w, sp, sh
	cfg.whisperMumbleR = w * (1 + cfg.whisperBuf)
	cfg.mumbleR = sp * (1 + cfg.speakBuf)
	cfg.shoutMumbleR = sh * (1 + cfg.shoutBuf)
end

-- whole metres, rangeMin..rangeMax, whisper < speech < shout (1 m apart at least); nil if not numbers
function PC.cleanRanges(w, sp, sh)
	local cfg = PC.cfg
	w, sp, sh = tonumber(w), tonumber(sp), tonumber(sh)
	if not (w and sp and sh) then return nil end
	local function r(x, lo, hi) return math.max(lo, math.min(hi, math.floor(x + 0.5))) end
	w = r(w, cfg.rangeMin, cfg.rangeMax - 2)
	sp = r(sp, w + 1, cfg.rangeMax - 1)
	sh = r(sh, sp + 1, cfg.rangeMax)
	return w, sp, sh
end

-- server: set the distances for everyone (shared.pcRanges); save: the host's choice for next time
function PC.setRanges(w, sp, sh, save)
	local s, cfg = PC.S(), PC.cfg
	w, sp, sh = PC.cleanRanges(w, sp, sh)
	if not w then return end
	PC.applyRanges(w, sp, sh)
	s.rangeN = (s.rangeN or 0) + 1
	shared.pcRanges = {w = w, p = sp, s = sh, n = s.rangeN}
	if save then SetString(cfg.save .. "ranges", w .. "," .. sp .. "," .. sh) end
	PC.log(string.format("proxchat ranges whisper=%d speak=%d yell=%d", w, sp, sh))
end

-- the host switched walls on / off in Settings (saved; a game that sets proxchat.walls decides instead)
function server.pc_walls(p, on)
	p = tonumber(p)
	local okH, host = pcall(IsPlayerHost, p)
	if not (p and okH and host) then return end
	PC.S().wallsHost = on and true or false
	SetBool(PC.cfg.save .. "wallson", on and true or false)
end

-- the host moved the distance bar (or pressed Reset)
function server.pc_ranges(p, w, sp, sh)
	p = tonumber(p)
	local okH, host = pcall(IsPlayerHost, p)
	if not (p and okH and host) then return end
	PC.setRanges(w, sp, sh, true)
end

-- every player (server)
-- every player id (the engine's GetAllPlayers; Players() is only a helper in script/include/player.lua,
-- which this mod does not include - relying on it left whispers with no one to go to)
function PC.allPlayers()
	local out = {}
	if GetAllPlayers then
		for _, q in ipairs(GetAllPlayers() or {}) do out[#out + 1] = q end
	elseif Players then
		for q in Players() do out[#out + 1] = q end
	end
	return out
end

-- confirm player p's message seq (the client resends until shared.pcAck shows it)
local function pcAck(p, seq)
	PC.S().seq[p] = seq
	local t = {}
	for k, v in pairs(shared.pcAck or {}) do t[k] = v end
	t[p] = seq
	shared.pcAck = t
end

-- a player says something: sanitized, rate-limited, then published (whole table: one sync). seq: the
-- client's number for it - a resend of one already taken is ignored, a taken one is confirmed in
-- shared.pcAck. Whispers are not published: the server sends them only to the players near enough
-- (ClientCall), so nobody else's game ever has the text.
function server.pc_say(p, ch, text, seq)
	local s = PC.S()
	local cfg = PC.cfg
	p, seq = tonumber(p), tonumber(seq)
	if not p then return end
	if seq and seq <= (s.seq[p] or 0) then return end                     -- (a resend of one already taken)
	text = PC.clean(text)
	if text == "" then
		if seq then pcAck(p, seq) end
		return
	end
	ch = PC.validMode(ch)
	if s.time - (s.last[p] or -10) < cfg.rate then return end            -- (no spamming: the resend gets in later)
	s.last[p] = s.time
	if seq then pcAck(p, seq) end
	s.n = s.n + 1
	local name = PC.cleanName(GetPlayerName(p), p)
	local chan = not PC.inLobby() and s.chan[p] or nil
	if chan then
		-- a channel (the dead, a team's dead) talks to itself only, whatever the mode: sent to its
		-- players alone, never in shared
		for _, q in ipairs(PC.allPlayers()) do
			if q == p or s.chan[q] == chan then ClientCall(q, "client.pc_dead", s.n, p, name, text, chan) end
		end
	elseif ch == "w" then
		local okT, tr = pcall(GetPlayerTransform, p)
		for _, q in ipairs(PC.allPlayers()) do
			local okQ, tq = pcall(GetPlayerTransform, q)
			if q == p or s.chan[q] or (okT and okQ and tr and tq and VecLength(VecSub(tq.pos, tr.pos)) <= cfg.whisperMumbleR + cfg.whisperSlack) then
				ClientCall(q, "client.pc_whisper", s.n, p, name, text)       -- (the near ones, and every channel: the dead hear everyone)
			end
		end
	else
		local list = {}
		for _, m in ipairs(shared.pcMsgs or {}) do
			if s.time - m.t < cfg.sharedLife then list[#list + 1] = m end
		end
		list[#list + 1] = {id = s.n, p = p, name = name, ch = ch, text = text, t = s.time}
		while #list > cfg.keepShared do table.remove(list, 1) end
		shared.pcMsgs = list
	end
	PC.publishSaid(p, ch, text, chan or "")
	PC.log(string.format("proxchat say p=%d ch=%s len=%d%s", p, ch, #text, chan and (" channel=" .. chan) or ""))
end

-- ---- the event API for other mods (server / host): every accepted message is written to the registry,
-- which all scripts on the host share (mods cannot call each other). A ring of the last 16:
--   proxchat.said.last              int: the newest event number (counts up, never resets in a session)
--   proxchat.said.<n % 16>.player   int: who spoke
--   ... .mode   "whisper" / "speak" / "yell" / "global"       ... .yell  bool: mode == "yell"
--   ... .x .y .z  where the speaker stood (feet)       ... .text   string
--   ... .radius   m: how far anyone hears anything (the babble): whisper 12, speak 35, yell 55, global 0 (defaults; the host may change them)
--   ... .wordsRadius  m: how far the words are heard: whisper 8, speak 25, yell 40
--   ... .lobby   bool: said while the game's lobby was up (proxchat.lobby)
--   ... .channel  the speaker's channel ("dead", "dead red"...: only it heard), else ""
--   ... .time     GetTime() on the host when it was said (a line from before this level: larger than now)
-- Read it each tick from your server script: for n = seen + 1 .. last (at most 16 back), then seen = last.
PC.SAID_RING = 16
function PC.publishSaid(p, ch, text, channel)
	local s, cfg = PC.S(), PC.cfg
	local base = cfg.reg .. ".said."
	s.said = math.max(s.said or 0, GetInt(base .. "last")) + 1
	local k = base .. (s.said % PC.SAID_RING) .. "."
	local mode = ch == "w" and "whisper" or (ch == "g" and "global" or (ch == "y" and "yell" or "speak"))
	local shout = mode == "yell"
	local okT, tr = pcall(GetPlayerTransform, p)
	local pos = okT and tr and tr.pos or Vec(0, 0, 0)
	SetInt(k .. "player", p)
	SetString(k .. "mode", mode)
	SetBool(k .. "yell", shout)
	SetString(k .. "text", text)
	SetFloat(k .. "x", pos[1]); SetFloat(k .. "y", pos[2]); SetFloat(k .. "z", pos[3])
	SetFloat(k .. "radius", mode == "global" and 0 or (mode == "whisper" and cfg.whisperMumbleR or (shout and cfg.shoutMumbleR or cfg.mumbleR)))
	SetFloat(k .. "wordsRadius", mode == "global" and 0 or (mode == "whisper" and cfg.whisperR or (shout and cfg.shoutR or cfg.chatR)))
	SetBool(k .. "lobby", PC.hooks.inLobby and PC.hooks.inLobby() or false)
	SetString(k .. "channel", channel or "")
	SetFloat(k .. "time", GetTime())                                   -- (the host's level clock: how old it is)
	SetInt(base .. "last", s.said)                                    -- (last: the event is complete)
end

function PC.publishTyping()
	local t = {}
	for p, ch in pairs(PC.S().typing) do t[p] = ch end
	shared.pcTyping = t
end

-- typing state (the server ignores your mod keys meanwhile; the "..." over your head nearby / whisper)
function server.pc_typing(p, on, ch)
	local s = PC.S()
	p = tonumber(p)
	if not p then return end
	s.typing[p] = on and PC.validMode(ch) or nil
	SetBool(PC.cfg.reg .. ".typing." .. p, on and true or false)
	PC.publishTyping()
end

function server.pc_voice(p, v)
	p, v = tonumber(p), tonumber(v)
	if not p or not v or not PC.VOICES[v] then return end
	local t = {}
	for k, x in pairs(shared.pcVoice or {}) do t[k] = x end
	t[p] = v
	shared.pcVoice = t
end

function PC.removedPlayers()
	local out = {}
	if GetRemovedPlayers then
		for _, p in ipairs(GetRemovedPlayers() or {}) do out[#out + 1] = p end
	elseif PlayersRemoved then
		for p in PlayersRemoved() do out[#out + 1] = p end
	end
	return out
end

function PC.serverTick(dt)
	local s = PC.S()
	dt = dt or 0
	s.time = s.time + dt
	local lobby = PC.inLobby()
	if lobby ~= s.lobby then s.lobby = lobby; shared.pcLobby = lobby end
	PC.heartbeat()
	-- a game's switches (set every tick by it): walls, and who talks only to the dead
	-- walls: the game's word for its map (proxchat.walls true / false, when it sets it), else the host's
	-- Settings (off unless turned on)
	local by = HasKey(PC.cfg.reg .. ".walls") and "game" or "host"
	local walls
	if by == "game" then walls = GetBool(PC.cfg.reg .. ".walls") else walls = s.wallsHost end
	if walls ~= s.walls or by ~= s.wallsBy then
		s.walls, s.wallsBy = walls, by
		shared.pcWalls, shared.pcWallsBy = walls, by
	end
	local chan, changed = {}, false
	for _, q in ipairs(PC.allPlayers()) do
		local v = GetString(PC.cfg.reg .. ".channel." .. q)
		v = PC.utf8Head(PC.clean(v), 24):lower()                      -- (a name from a game: tidy, short, any case)
		if v ~= "" then chan[q] = v end
		if chan[q] ~= s.chan[q] then changed = true end
	end
	for q in pairs(s.chan) do if not chan[q] then changed = true end end
	if changed then
		s.chan = chan
		local t = {}
		for q, v in pairs(chan) do t[q] = v end
		shared.pcChan = t
	end
	-- a map or game mode may set its distances: SetString("proxchat.ranges", "whisper,speak,yell")
	local reg = GetString(PC.cfg.reg .. ".ranges")
	if reg ~= "" and reg ~= s.regRanges then
		s.regRanges = reg
		local w, sp, sh = reg:match("^%s*([%d%.]+)%s*,%s*([%d%.]+)%s*,%s*([%d%.]+)%s*$")
		if w then PC.setRanges(w, sp, sh, false) end
	end
	for _, p in ipairs(PC.removedPlayers()) do
		s.last[p], s.seq[p] = nil, nil
		if (shared.pcAck or {})[p] then
			local t = {}
			for k, v in pairs(shared.pcAck) do if k ~= p then t[k] = v end end
			shared.pcAck = t
		end
		SetBool(PC.cfg.reg .. ".typing." .. p, false)
		if s.typing[p] then s.typing[p] = nil; PC.publishTyping() end
		local vs = shared.pcVoice or {}
		if vs[p] then
			local t = {}
			for k, x in pairs(vs) do if k ~= p then t[k] = x end end
			shared.pcVoice = t
		end
	end
	-- old messages leave the shared table once a second (clients copied them on arrival)
	s.pruneT = s.pruneT - dt
	if s.pruneT > 0 then return end
	s.pruneT = 1
	shared.pcNow = s.time                                                -- (clients tell late messages by it)
	local msgs = shared.pcMsgs or {}
	if #msgs == 0 then return end
	local list = {}
	for _, m in ipairs(msgs) do
		if s.time - m.t < PC.cfg.sharedLife then list[#list + 1] = m end
	end
	if #list ~= #msgs then shared.pcMsgs = list end
end

-- server: any player; client: the local player
function PC.isTyping(p)
	if PC.s and p then return PC.s.typing[p] ~= nil end
	if PC.c and (p == nil or p == GetLocalPlayer()) then return PC.c.typing end
	return false
end

-- ============================================================================ client
function PC.clientInit()
	local cfg = PC.cfg
	local c = {
		hist = {}, n = 0, seen = 0, typing = false, text = "", focus = false, pinned = false,
		page = "chat", bubbles = {}, prevBubbles = {}, scroll = 0, t0 = GetTime(),
		hideHint = GetBool(cfg.save .. "hidehint"),
		hideOwn = GetBool(cfg.save .. "hideown"),
		voiceTries = 0, voiceT = 0,
		outbox = {}, seq = 0, muted = {}, names = {},
		bubbleLevel = PC.LEVELS[GetInt(cfg.save .. "bubbles")] and GetInt(cfg.save .. "bubbles") or #PC.LEVELS,
		babbleVolume = PC.savedVolume(),
		babble = {clips = {}, queue = {}, echoes = {}},
		walls = {},                                   -- (per speaker: the beam and the way round, PC.wallState)
	}
	local m = GetString(cfg.save .. "mode")                       -- (the last mode used)
	c.mode = (m == "w" or m == "g" or m == "y") and m or "s"        -- (an old save's "p": Speak)
	local v = GetInt(cfg.save .. "voice")
	if PC.VOICES[v] then c.voiceWant = v end                    -- (Settings / Options / /voice)
	for set, n in pairs(PC.BABBLE_SETS) do
		c.babble.clips[set] = {}
		for i = 1, n do c.babble.clips[set][i] = LoadSound(cfg.sndDir .. PC.CLIP_FILE[set] .. (i - 1) .. ".ogg") end
	end
	PC.c = c
	-- joining: recent Global lines go into the history; Speak / Whisper from before you came is not heard
	for _, msg in ipairs(shared.pcMsgs or {}) do
		if msg.id > c.seen then c.seen = msg.id end
		if msg.ch == "g" then PC.addHist({ch = "g", p = msg.p, name = msg.name, text = msg.text}) end
	end
end

function PC.C()
	if not PC.c then PC.clientInit() end
	return PC.c
end

function PC.lobby() return shared.pcLobby == true end

-- the input line's mode: "w" Whisper, "s" Speak, "y" Yell, "g" Global (the lobby: always "g")
function PC.mode()
	if PC.lobby() then return "g" end
	return PC.C().mode
end

function PC.setMode(m)
	local c = PC.C()
	if PC.lobby() then return end                                   -- (the lobby is Global only)
	if m ~= "g" and m ~= "w" and m ~= "y" then m = "s" end
	if c.mode == m then return end
	c.mode = m
	SetString(PC.cfg.save .. "mode", m)                             -- (your default next time)
	if c.typing then ServerCall("server.pc_typing", GetLocalPlayer(), true, m) end
end

-- Tab: Whisper -> Speak -> Yell -> Global -> Whisper
function PC.nextMode()
	local cur = PC.mode()
	for i, x in ipairs(PC.MODES) do
		if x[1] == cur then PC.setMode(PC.MODES[i % #PC.MODES + 1][1]); return end
	end
end

function PC.page() return PC.C().page end

function PC.setPage(pg)
	local c = PC.C()
	c.page = (pg == "settings") and "settings" or "chat"
	c.scroll = 0
end

function PC.windowOpen()
	local c = PC.C()
	return c.typing or c.pinned
end

-- the history; with a mode, only its lines (a copy)
function PC.history(mode)
	local h = PC.C().hist
	if not mode then return h end
	local out = {}
	for _, e in ipairs(h) do if e.ch == mode then out[#out + 1] = e end end
	return out
end

-- add a line to the local history (bounded)
function PC.addHist(e)
	local c = PC.C()
	c.n = c.n + 1
	e.n = c.n
	e.ch = e.ch or "sys"
	e.t = e.t or GetTime()
	local h = c.hist
	h[#h + 1] = e
	while #h > PC.cfg.keepHist do table.remove(h, 1) end
	if PC.windowOpen() and c.scroll > 0 then c.scroll = math.min(c.scroll + 1, #h - 1) end   -- (the view stays put)
end

-- a local line only this player sees (command results)
function PC.system(text)
	PC.addHist({sys = true, ch = "sys", text = text})
end

-- where speaker p stands (feet): a player, or the local test dummy (/dummy); nil = unknown
function PC.speakerPos(p)
	local c = PC.c
	if PC.isDummy(p) then local d = PC.dummyOf(p); return d and d.pos or nil end
	local ok, tr = pcall(GetPlayerTransform, p)
	return ok and tr and tr.pos or nil
end

function PC.distTo(p)
	local a, b = PC.speakerPos(GetLocalPlayer()), PC.speakerPos(p)
	if not (a and b) then return nil end
	return VecLength(VecSub(a, b))
end

-- WALLS (off by default; the host's Settings can turn them on, and a game that sets proxchat.walls true /
-- false decides for its map instead -> shared.pcWalls). How far a voice SOUNDS (PC.hearDist):
--   1. a beam, every cfg.wallEvery s per speaker: 9 parallel rays from the listener's head toward the
--      speaker's on a 3 x 3 grid cfg.wallBeam m apart (up / down / sideways of the straight line), against
--      the static world above the debris size, glass not counting. One ray clear = no wall: the
--      distance. (A pole, a railing, a low wall, a doorway on the line leaves a ray clear.)
--   2. all 9 blocked (a wall, a floor, a roof): the way ROUND - the engine's path planner, "flying" (the
--      shortest way through the air: a door to the side, a window, over the wall, down a corridor),
--      asynchronous, no longer than the message could carry. Found: its length (heard round the corner,
--      a little quieter). None (sealed off): THROUGH the wall - the distance / cfg.wallFactor (muffled).
--      Until the planner answers, through the wall. The shorter of the two counts. Cost: only while a
--      speaker has a message up / types / babbles; a search at most every cfg.pathEvery s per speaker,
--      cfg.pathMax at once, the engine's own background planner (its robots use it).
function PC.beamBlocked(a, b)
	local d = VecSub(b, a)
	local len = VecLength(d)
	if len < 1 then return false end
	local dir = VecScale(d, 1 / len)
	local side = VecCross(dir, Vec(0, 1, 0))
	if VecLength(side) < 0.1 then side = Vec(1, 0, 0) else side = VecNormalize(side) end
	local up = VecNormalize(VecCross(side, dir))
	local o = PC.cfg.wallBeam
	for i = 0, 8 do
		local k = (i + 4) % 9                                       -- (the straight ray first: most often the clear one)
		local off = VecAdd(VecScale(side, (k % 3 - 1) * o), VecScale(up, (math.floor(k / 3) - 1) * o))
		QueryRequire("physical static large")
		if not QueryRaycast(VecAdd(a, off), dir, len, 0, true) then return false end
	end
	return true
end

-- the way round (step 2): one path planner per speaker, re-asked when either end moved cfg.pathMove m
-- or every cfg.pathEvery s; w.around = the length found, false = none, nil = not known yet
function PC.pathAsk(w, a, b, maxLen)
	local cfg = PC.cfg
	local now = GetTime()
	if w.busy or not (CreatePathPlanner and PathPlannerQuery and GetPathState and GetPathLength) then return end
	local busy = 0
	for _, o in pairs(PC.C().walls) do if o.busy then busy = busy + 1 end end
	if busy >= cfg.pathMax then return end                           -- (a crowd behind walls: one after another)
	if w.pathT and now - w.pathT < cfg.pathEvery and VecLength(VecSub(a, w.pathA)) < cfg.pathMove
		and VecLength(VecSub(b, w.pathB)) < cfg.pathMove then return end
	if not w.planner then
		local ok, id = pcall(CreatePathPlanner)
		if not ok or not id then return end
		w.planner = id
	end
	QueryRequire("physical static large")
	if pcall(PathPlannerQuery, w.planner, a, b, maxLen, cfg.pathTarget, "flying") then
		w.busy, w.pathT, w.pathA, w.pathB = true, now, a, b
	end
end

function PC.pathPoll(w)
	if not w.busy then return end
	local ok, st = pcall(GetPathState, w.planner)
	if not ok or st == "busy" then return end
	w.busy = false
	if st == "done" then
		local okL, len = pcall(GetPathLength, w.planner)
		w.around = okL and len or false
	else
		w.around = false                                              -- (fail / idle: no way round within reach)
	end
end

-- the farthest p's voice carries right now (+ cfg.soundGrace): its bubbles', its "...", its babble's
-- mode; Yell when nothing is known
function PC.speakerReach(p)
	local c = PC.C()
	local best = 0
	local function add(mode) if mode then local _, r = PC.rangeOf(mode); best = math.max(best, r) end end
	for _, t in ipairs({c.bubbles, c.prevBubbles}) do if t[p] then add(t[p].mode) end end
	add((shared.pcTyping or {})[p])
	local q = c.babble.queue[p]
	if q then add(q.how == "whisper" and "w" or (q.how == "shout" and "y" or "s")) end
	if best == 0 then add("y") end
	return best + PC.cfg.soundGrace
end

-- step 1 + 2 for speaker p (nil: walls off, or nobody to hear). Beyond the farthest p's voice carries
-- now (PC.speakerReach) nothing is checked; the way round is searched no longer than that
function PC.wallState(p)
	if not shared.pcWalls or p == GetLocalPlayer() or PC.isDummy(p) then return nil end
	local c = PC.C()
	local feet = PC.speakerPos(p)
	if not feet then return nil end
	local w = c.walls[p]
	if not w then w = {t = -1e9}; c.walls[p] = w end
	local now = GetTime()
	local a, b = PC.listenerHead(), VecAdd(feet, Vec(0, 1.7, 0))
	local reach = PC.speakerReach(p)
	if VecLength(VecSub(b, a)) > reach then                          -- (too far to hear anyway: no rays, no search)
		w.blocked, w.around = false, nil
		return w
	end
	if now - w.t >= PC.cfg.wallEvery then
		w.t = now
		w.blocked = PC.beamBlocked(a, b)
		if w.blocked then
			PC.pathAsk(w, a, b, reach)                               -- (no way round longer than this voice carries)
		else
			w.around = nil
		end
	end
	PC.pathPoll(w)
	return w
end

-- how far p sounds: the distance; with a wall in the way the way round, or through it (see WALLS)
function PC.hearDist(p)
	local d = PC.distTo(p)
	if not d then return nil end
	local w = PC.wallState(p)
	if not (w and w.blocked) then return d end
	local through = d / PC.cfg.wallFactor
	if w.around then return math.max(d, math.min(through, w.around)) end
	return through
end

-- CHANNELS (proxchat.channel.<p> = a name, set by a game on the host -> shared.pcChan): "dead", or
-- "dead red" / "dead blue" for teams. What a player in a channel says reaches only that channel (the
-- server sends it to them alone: client.pc_dead), and players in any channel hear everyone in full
-- (spectators). Nobody sees a bubble or a "..." of theirs, nor hears their babble. The lobby (everyone
-- hears everything) comes first.
function PC.channelOf(p) return (shared.pcChan or {})[p] or "" end
function PC.dead() return not PC.lobby() and PC.channelOf(GetLocalPlayer()) ~= "" end

-- what the local player hears of p's message NOW: text, far, level, distance. Levels: "full" (within
-- the mode's range: PC.rangeOf), "mumble" (in its buffer: the babble and a garbled bubble, the history
-- line as much as was made out). nil = nothing (yet: PC.updateBubble).
PC.LEVEL = {none = 0, mumble = 1, full = 2}
function PC.heard(p, text, mode)
	if p == GetLocalPlayer() then return text, false, "full", 0 end
	if PC.dead() then return text, false, "full", PC.distTo(p) or 0 end
	if mode ~= "w" and PC.hooks.everyoneHears and PC.hooks.everyoneHears(p) then return text, false, "full", 0 end
	local d = PC.hearDist(p)
	if not d then return nil end
	local inner, outer = PC.rangeOf(mode)
	if d <= inner then return text, false, "full", d end
	if d <= outer then return "...", true, "mumble", d end
	return nil
end

-- a new message from the server: each client records what it heard, now
function PC.receive(m)
	local c = PC.C()
	local me = GetLocalPlayer()
	local heard, far
	if m.p and m.name then
		if c.muted[m.p] and c.muted[m.p] ~= m.name then c.muted[m.p] = nil end   -- (another player with that number now)
		c.names[m.p] = m.name
		if c.muted[m.p] then return end                                       -- (/mute: nothing of theirs)
	end
	-- late (the client lagged): timed from when it was said, no babble
	local age = (m.t and shared.pcNow) and math.max(0, shared.pcNow - m.t) or 0
	local late = age > PC.cfg.lateAge
	if m.ch == "g" or m.ch == "d" then
		heard = m.text
		PC.addHist({ch = m.ch, chan = m.chan, p = m.p, name = m.name, text = m.text, me = m.p == me})
		-- (Global, and the dead to the dead: a chat line only - no bubble, no babble)
	else
		local mode = (m.ch == "w" or m.ch == "y") and m.ch or "s"
		local whisper = mode == "w"
		local level, d
		heard, far, level, d = PC.heard(m.p, m.text, mode)
		-- kept for its bubble's life even out of earshot (hidden): walking in while it is up shows it.
		-- Not a whisper: it is private - only who was within whisperMumbleR when it was said gets it.
		if heard or not whisper then
			local b = {t = GetTime() - (late and age or 0), full = m.text, mode = mode, name = m.name, id = m.id, whisper = whisper,
				level = "none", hidden = true, bestF = -1}
			b.scrollT = b.t                                                  -- (the scroll's clock: fixed, a reveal never restarts it)
			if not (late and age >= PC.bubbleLife(b)) then                  -- (so late its bubble is over: the history only)
				local old = c.bubbles[m.p]                                   -- (2 bubbles a speaker at most: the newest and the one
				if old and not old.hidden then c.prevBubbles[m.p] = old end  --  before it; a third pushes the oldest out)
				c.bubbles[m.p] = b
			end
			PC.updateBubble(m.p, b, b.t, true)
		end
		-- the babble: also cfg.soundGrace m past the bubble's reach (the bubble goes a little before the sound)
		local dd = d or PC.hearDist(m.p)
		local _, outer = PC.rangeOf(mode)
		local inGrace = not heard and dd and m.p ~= me and dd <= outer + PC.cfg.soundGrace
		if (heard or inGrace) and not late then
			PC.babbleSay(m.p, m.text, nil, whisper and "whisper" or (mode == "y" and "shout" or nil))
		end
		if level == "mumble" then heard, far = nil, nil end              -- (the hook: no words heard)
	end
	if PC.hooks.onMessage and not PC.isDummy(m.p) then PC.hooks.onMessage(m, heard) end
end

-- a bubble not fully heard follows the listener while it is up: out of earshot it stays hidden; in the
-- buffer it shows (garbled); in range the words show. Its history line is added when it is first
-- heard and always holds the most the listener made out (PC.histText): it only ever gains letters.
-- fresh: the message just arrived (no extra time on screen).
function PC.updateBubble(p, b, now, fresh)
	local cfg = PC.cfg
	local text, _, level = PC.heard(p, b.full, b.mode)
	local changed = false
	if text and PC.LEVEL[level] > PC.LEVEL[b.level] then
		b.level, b.text, b.hidden = level, text, false
		b.mumble = level == "mumble"
		b.shout = b.mode == "y"
		b.bestF = -1                                                         -- (a new level: its own best share)
		if not fresh and level == "full" then
			b.t = math.max(b.t, now - PC.bubbleLife(b) + PC.cfg.revealHold)   -- (fully revealed: up at least 1 s more)
		end
		changed = true
	end
	if b.level == "mumble" then
		local f = PC.bufferF(p, b) or 0
		if f > b.bestF + 1e-6 then b.bestF, changed = f, true end
	end
	if changed and not b.hidden then
		local htext, far = PC.histText(b), b.level ~= "full"
		if b.entry then
			b.entry.text, b.entry.far, b.entry.shout = htext, far, b.shout
		else
			b.entry = {ch = b.mode, p = p, name = b.name, text = htext, shout = b.shout, far = far, me = p == GetLocalPlayer()}
			PC.addHist(b.entry)
		end
	end
end

function PC.revealBubbles(now)
	local c = PC.C()
	for _, tbl in ipairs({c.bubbles, c.prevBubbles}) do
		for p, b in pairs(tbl) do
			if b.level ~= "full" then PC.updateBubble(p, b, now) end
		end
	end
end

function PC.clientTick(dt)
	local c = PC.C()
	local me = GetLocalPlayer()
	local now = GetTime()
	-- your typing state in THIS game's registry too: the server's copy (every player) is only in the
	-- host's, so a game's client script on a guest's machine reads its own player's here
	if c.typing ~= c.regTyping then
		c.regTyping = c.typing
		SetBool(PC.cfg.reg .. ".typing." .. me, c.typing and true or false)
	end
	PC.heartbeat()
	-- the chosen voice reaches the server (re-sent until shared shows it, 6 s at most)
	if c.voiceWant then
		local vs = shared.pcVoice or {}
		if vs[me] == c.voiceWant then
			c.voiceWant = nil
		elseif now >= c.voiceT then
			c.voiceTries = c.voiceTries + 1
			if c.voiceTries > 12 then
				c.voiceWant = nil
			else
				c.voiceT = now + 0.5
				ServerCall("server.pc_voice", me, c.voiceWant)
			end
		end
	end
	-- new messages (by id: shared hands out fresh copies on clients)
	local msgs = shared.pcMsgs or {}
	for _, m in ipairs(msgs) do
		if m.id > c.seen then
			c.seen = m.id
			PC.receive(m)
		end
	end
	for _, tbl in ipairs({c.bubbles, c.prevBubbles}) do
		for p, b in pairs(tbl) do
			if now - b.t > PC.bubbleLife(b) + (b.extra or 0) then tbl[p] = nil end
		end
	end
	local rg = shared.pcRanges
	if rg and rg.n and rg.n ~= c.rangesN then                         -- (the host's distances)
		c.rangesN = rg.n
		PC.applyRanges(rg.w, rg.p, rg.s)
		c.rangesWant = nil
	end
	PC.pump(now)
	PC.dummyTick(now)
	PC.revealBubbles(now)
	PC.babbleTick()
end

-- ---- the test dummies: /dummy puts three figures in a row in front of you - a whisperer, a speaker
-- and a shouter; /dummy 1 / 2 / 3 one of them (moved if it exists); /dummy clear removes them. Only
-- for you (client-side, no server, not synced). They say the same line at the same
-- moment (the shouter in Shout mode, in CAPS), line after line, the voices rotating, so you can walk back
-- and forth and compare the bubbles and the babble at every distance. They take turns, cfg.dummyGap s
-- apart: the whisperer, then the speaker, then the shouter; then the next line. Each line: "..." typing for
-- cfg.dummyType s, then the message as if a player said it (PC.receive).
PC.DUMMY = 1000                                                       -- (speaker ids PC.DUMMY + 0..2)
PC.DUMMY_KINDS = {                                                    -- mode, name, torso colour; left to right
	{"w", "Whisperer", "0.6 0.6 0.9"},
	{"s", "Speaker", "0.9 0.65 0.25"},
	{"y", "Yeller", "0.85 0.15 0.1"},
}
PC.DUMMY_LINES = {                                                    -- {said, shouted}
	{"hello there, we are the test dummies", "HELLO THERE, WE ARE THE TEST DUMMIES"},
	{"did you find the key yet?", "DID YOU FIND THE KEY YET?"},
	{"the secret door is behind the painting", "THE SECRET DOOR IS BEHIND THE PAINTING"},
	{"this is a really long message to show how the speech bubble wraps when someone has a lot to say at once",
		"THIS IS A REALLY LONG MESSAGE TO SHOW HOW THE SPEECH BUBBLE WRAPS WHEN SOMEONE HAS A LOT TO SAY AT ONCE"},
	{"Привет, как дела?", "ПРИВЕТ, КАК ДЕЛА?"},
	{"你好，我们一起爬吧", "你好！我们一起爬吧！"},
	{"مرحبا يا صديقي", "مرحبا! يا! صديقي!"},
	{"Γεια σου φίλε", "ΓΕΙΑ ΣΟΥ ΦΙΛΕ"},
}

function PC.isDummy(p) return type(p) == "number" and p >= PC.DUMMY and p < PC.DUMMY + #PC.DUMMY_KINDS end

function PC.dummyOf(p)
	local c = PC.c
	return c and c.dummy and c.dummy.byP[p] or nil
end

-- where you stand and which way you look (flat), for placing dummies
local function dummyFrame()
	local cam = GetCameraTransform()
	local okF, fwd = pcall(TransformToParentVec, cam, Vec(0, 0, -1))
	fwd = okF and fwd or Vec(0, 0, -1)
	fwd = VecNormalize(Vec(fwd[1], 0, fwd[3]))
	return PC.speakerPos(GetLocalPlayer()) or cam.pos, fwd, VecCross(fwd, Vec(0, 1, 0))
end

-- remove one dummy (its figure, bubble and babble)
function PC.dummyRemove(d)
	local c = PC.C()
	for _, e in ipairs(d.ents) do pcall(Delete, e) end
	c.bubbles[d.p], c.prevBubbles[d.p], c.babble.queue[d.p] = nil, nil, nil
	local dm = c.dummy
	dm.byP[d.p] = nil
	for i = #dm.list, 1, -1 do if dm.list[i] == d then table.remove(dm.list, i) end end
	if #dm.list == 0 then c.dummy = nil end
end

-- dummy kind i (PC.DUMMY_KINDS) at pos, on the ground; one already there of that kind is replaced
function PC.dummySpawn(i, pos)
	local c = PC.C()
	local kind = PC.DUMMY_KINDS[i]
	c.dummy = c.dummy or {list = {}, byP = {}, k = 0, round = 0, startT = GetTime() + 0.5, nextT = 0}
	local dm = c.dummy
	local old = dm.byP[PC.DUMMY + i - 1]
	if old then PC.dummyRemove(old); c.dummy = c.dummy or dm end
	local okR, hit, dist = pcall(QueryRaycast, VecAdd(pos, Vec(0, 2, 0)), Vec(0, -1, 0), 6)
	if okR and hit then pos = Vec(pos[1], pos[2] + 2 - dist, pos[3]) end
	-- a box figure (legs, body, head); client-side, static, just for looks. nocull (as the game's own
	-- multiplayer pickups): small shapes are otherwise faded out at a distance
	local xml = '<body tags="nocull" dynamic="false"><voxbox tags="nocull" size="5 9 3" pos="-0.25 0 -0.15" color="0.3 0.33 0.45"/>'
		.. '<voxbox tags="nocull" size="6 7 4" pos="-0.3 0.9 -0.2" color="' .. kind[3] .. '"/><voxbox tags="nocull" size="4 4 4" pos="-0.2 1.6 -0.2" color="0.95 0.8 0.65"/></body>'
	local okS, ents = pcall(Spawn, xml, Transform(pos), true)
	local d = {p = PC.DUMMY + i - 1, idx = i, kind = kind[1], name = kind[2], pos = pos, ents = okS and ents or {}, voice = i}
	dm.byP[d.p] = d
	dm.list[#dm.list + 1] = d
	table.sort(dm.list, function(u, v) return u.idx < v.idx end)        -- (they speak in kind order)
	return d
end

-- /dummy [1|2|3|clear]: all three in a row (a fresh set) / the whisperer, speaker or shouter 3 m in
-- front of you (moved there if it exists) / remove them all
function PC.dummyCommand(arg)
	local c, cfg = PC.C(), PC.cfg
	arg = (arg or ""):lower()
	if arg == "clear" or arg == "off" or arg == "remove" then
		if c.dummy then
			while c.dummy do PC.dummyRemove(c.dummy.list[1]) end
			PC.system("The test dummies are gone.")
		else
			PC.system("No test dummies to clear.")
		end
		return
	end
	local me, fwd, right = dummyFrame()
	local i = tonumber(arg)
	if arg == "" then
		if c.dummy then while c.dummy do PC.dummyRemove(c.dummy.list[1]) end end
		for k = 1, #PC.DUMMY_KINDS do
			PC.dummySpawn(k, VecAdd(VecAdd(me, VecScale(fwd, 3)), VecScale(right, (k - 2) * 2.5)))
		end
		PC.system("Three test dummies in front of you (left to right: whisperer, speaker, yeller) say the same lines. Walk back and forth: whisper "
			.. cfg.whisperR .. " m (garbled to " .. cfg.whisperMumbleR .. "), speech " .. cfg.chatR .. " m (garbled to " .. cfg.mumbleR
			.. "), yells " .. cfg.shoutR .. " m (garbled to " .. cfg.shoutMumbleR .. "). /dummy clear removes them.")
	elseif i and PC.DUMMY_KINDS[i] then
		PC.dummySpawn(i, VecAdd(me, VecScale(fwd, 3)))
		PC.system("The " .. PC.DUMMY_KINDS[i][2]:lower() .. " dummy stands in front of you. /dummy clear removes the dummies.")
	else
		PC.system("/dummy: all three test dummies.  /dummy 1: whisperer, 2: speaker, 3: yeller.  /dummy clear: remove them.")
	end
end

function PC.dummyTick(now)
	local c, cfg = PC.C(), PC.cfg
	local dm = c.dummy
	if not dm then return end
	-- a new line: each dummy gets its turn, cfg.dummyGap s apart (whisperer, speaker, shouter); it types
	-- for cfg.dummyType s before its own
	if not dm.lineT or now >= dm.nextT then
		local wait = 0
		for _, d in ipairs(dm.list) do                                -- (a long line still scrolling: let it finish)
			local b = c.bubbles[d.p]
			if b and (b.extra or 0) > 0 then wait = math.max(wait, (b.scrollT or b.t) + cfg.scrollHold + b.extra + 2.5 - now) end
		end
		if wait > 0 then dm.nextT = now + wait; return end
		if now < dm.startT then return end
		dm.k = dm.k % #PC.DUMMY_LINES + 1
		if dm.k == 1 then dm.round = dm.round + 1 end
		dm.lineT = now
		for i, d in ipairs(dm.list) do
			d.sayAt = now + cfg.dummyType + (i - 1) * cfg.dummyGap
			d.typing, d.said = false, false
		end
		dm.nextT = now + cfg.dummyType + (#dm.list - 1) * cfg.dummyGap + cfg.dummyShow
	end
	local line = PC.DUMMY_LINES[dm.k]
	for _, d in ipairs(dm.list) do
		if d.sayAt and not d.said then
			if not d.typing and now >= d.sayAt - cfg.dummyType then
				d.typing = true
				local cur = c.bubbles[d.p]                                -- (the "..." shows only with no bubble up:
				if cur and not cur.hidden then c.prevBubbles[d.p] = cur end   --  its last line moves up as the older one)
				c.bubbles[d.p] = nil
			end
			if now >= d.sayAt then
				d.typing, d.said = false, true
				d.voice = (dm.round + d.idx - 2) % #PC.VOICES + 1        -- (each round shifts the voices)
				dm.n = (dm.n or 0) + 1
				PC.receive({id = 1000000 + dm.n, p = d.p, name = d.name .. " (" .. PC.VOICES[d.voice][1] .. ")",
					ch = d.kind, text = d.kind == "y" and line[2] or line[1]})
			end
		end
	end
end

-- ---- the babble voice (Animal Crossing style)
function PC.voiceOf(p)
	local c = PC.c
	if c and c.voiceWant and p == GetLocalPlayer() then return c.voiceWant end
	if PC.isDummy(p) then local d = PC.dummyOf(p); return d and d.voice or 3 end
	local v = (shared.pcVoice or {})[p]
	if v and PC.VOICES[v] then return v end
	return (p * 37) % 5 + 1                                       -- (no pick yet: one of the first five)
end

-- a message as syllables: {variant hash, pause after, pitch factor, shouted (set by babbleSay)}
function PC.babbleSyllables(text)
	local out, pair, angry = {}, "", false
	local function flush(pause)
		if pair ~= "" then
			local h = 0
			for i = 1, #pair do h = (h * 31 + pair:byte(i)) % 997 end
			out[#out + 1] = {h, 0, 1, angry}
			pair, angry = "", false
		end
		if pause > 0 and #out > 0 then out[#out][2] = math.max(out[#out][2], pause) end
	end
	local nch = 0
	for i, ch in text:gmatch("()(" .. PC.UTF8_CHAR .. ")") do
		local k = PC.utf8Kind(ch)
		if k == "cjk" then                                        -- Chinese / Japanese / Korean: one each
			flush(0); nch = 0
			pair = ch
			flush(0)
		elseif k == "letter" then                                 -- other scripts: two letters a syllable
			pair = pair .. ch:lower()
			nch = nch + 1
			if nch >= 2 then flush(0); nch = 0 end
		elseif k == "space" then flush(0.05); nch = 0
		elseif k == "pause" then flush(0.16); nch = 0 end
		if #out >= PC.cfg.babbleMax then break end
	end
	flush(0)
	if text:find("%?%s*$") or text:find("\239\188\159%s*$") or text:find("\216\159%s*$") then   -- ? / ？ / ؟ rises
		for k = math.max(1, #out - 2), #out do out[k][3] = 1 + 0.08 * (k - #out + 3) end
	end
	return out
end

-- start babbling text for player p. how: nil = Speak, in the world at the speaker (echo with distance);
-- "shout" = the same with the raised-voice clips, a little louder, farther; "whisper" = breathy clips at
-- the speaker, quiet, no echo; "flat" = at the listener (the voice preview in Settings), short and quiet
function PC.babbleSay(p, text, voice, how)
	local c = PC.C()
	local B = c.babble
	local cfg = PC.cfg
	local lv = how == "flat" and 1 or c.babbleVolume                    -- (Settings: babble volume; the preview always plays)
	if lv == 0 then return end
	local v = PC.VOICES[voice or PC.voiceOf(p)] or PC.VOICES[3]
	local syl = PC.babbleSyllables(text)
	local q = {syl = syl, k = 1, nextT = GetTime(), pitch = v[2], step = v[3], set = v[4], how = how}
	local vol = cfg.babbleVol * v[5]
	local shoutVol = cfg.shoutVol * v[5]
	if how == "flat" then
		while #syl > cfg.globalMaxSyl do table.remove(syl) end
		vol, shoutVol = vol * cfg.globalVol, shoutVol * cfg.globalVol
	elseif how == "whisper" then
		q.set = (v[4] == "robot") and "rwhisper" or "whisper"
		q.pitch = 1 + (v[2] - 1) * 0.6                            -- (the voice still shifts it a little)
		q.step = v[3] * 1.1
		vol = cfg.whisperVol
		shoutVol = vol
	end
	for _, s in ipairs(syl) do s[4] = how == "shout" end          -- (Shout: every syllable raised)
	q.vol, q.shoutVol = vol * lv, shoutVol * lv
	B.queue[p] = q
end

-- how a voice carries: past cfg.soundNear the syllable is played that far away IN THE SPEAKER'S
-- DIRECTION (PC.soundPos), so the game's own distance fade is the same for every speaker and ours sets
-- the loudness: full near, falling gently with distance, then fading smoothly to nothing across the
-- buffer and cfg.soundGrace m past it (speech chatR-mumbleR, shouts shoutR-shoutMumbleR,
-- whispers whisperR-whisperMumbleR): the bubble goes a little before the sound does. The game's fade on top of ours made far
-- shouts with a readable bubble almost silent. Speech echoes more the farther it carries (1-3 delayed,
-- fainter repeats from beside and behind the speaker's direction).
function PC.loudness(d, reach, inner)
	local cfg = PC.cfg
	local t = math.max(0, math.min(1, (d - cfg.soundNear) / math.max(1, reach - cfg.soundNear)))
	local loud = 1 - (1 - cfg.soundFar) * t ^ 1.5
	-- across the buffer (inner .. reach) it fades smoothly to nothing: no sudden drop at the edge
	if inner and d > inner then
		local x = math.min(1, (d - inner) / math.max(0.5, reach - inner))
		loud = loud * (1 - x * x * (3 - 2 * x))
	end
	return loud
end

function PC.soundPos(pos, cam)
	local d = VecLength(VecSub(pos, cam))
	if d <= PC.cfg.soundNear then return pos end
	return VecAdd(cam, VecScale(VecSub(pos, cam), PC.cfg.soundNear / d))
end

-- where the listener's head is: their character, not the camera (in third person the camera swings
-- around as you turn, nearer to or farther from a speaker without you moving)
function PC.listenerHead()
	local feet = PC.speakerPos(GetLocalPlayer())
	return feet and VecAdd(feet, Vec(0, 1.7, 0)) or GetCameraTransform().pos
end

-- mul: the distance through walls counts this many times (PC.wallMul)
function PC.babbleDistance(pos, vol, shout, reach, inner, mul)
	local cfg = PC.cfg
	local cam = GetCameraTransform().pos
	local d = VecLength(VecSub(pos, PC.listenerHead())) * (mul or 1)   -- (loudness by your distance; direction from the camera)
	reach = reach or (shout and cfg.shoutMumbleR or cfg.mumbleR)
	inner = inner or (shout and cfg.shoutR or cfg.chatR)
	local f = math.max(0, math.min(1, (d - cfg.echoFrom) / math.max(1, reach - cfg.echoFrom)))
	local loud = vol * PC.loudness(d, reach, inner)
	local echoes = {}
	if f > 0.05 then
		local n = f > 0.55 and 3 or (f > 0.2 and 2 or 1)
		local away = VecNormalize(VecSub(pos, cam))
		for k = 1, n do
			local side = VecNormalize(VecCross(away, Vec(0, 1, 0)))
			local offset = VecAdd(VecScale(side, (math.random() < 0.5 and -1 or 1) * (2 + 4 * math.random())), VecScale(away, 3 + 3 * k))
			echoes[k] = {delay = k * (0.08 + 0.14 * f), vol = loud * (0.3 + 0.4 * f) * 0.6 ^ (k - 1), offset = offset}
		end
	end
	return loud, echoes
end

-- how much farther p sounds than p is (PC.hearDist / the distance): 1 without a wall in the way
function PC.wallMul(p)
	if PC.isDummy(p) then return 1 end
	local d = PC.distTo(p)
	if not d or d < 0.5 then return 1 end
	return (PC.hearDist(p) or d) / d
end

function PC.babbleTick()
	local B = PC.C().babble
	local now = GetTime()
	for i = #B.echoes, 1, -1 do
		local e = B.echoes[i]
		if now >= e.t then
			PlaySound(e.clip, e.pos, e.vol, false, e.pitch)
			table.remove(B.echoes, i)
		end
	end
	for p, q in pairs(B.queue) do
		if now >= q.nextT then
			local function gap(x) return q.step * (x[4] and 0.85 or 1) + x[2] end
			-- a slow frame can be past several syllables: skip to the last one due (the babble keeps time
			-- with the bubble instead of dragging on at one syllable a frame)
			while q.syl[q.k] and q.syl[q.k + 1] and now >= q.nextT + gap(q.syl[q.k]) do
				q.nextT = q.nextT + gap(q.syl[q.k])
				q.k = q.k + 1
			end
			local s = q.syl[q.k]
			if not s then
				B.queue[p] = nil
			else
				local pos
				if q.how == "flat" then
					pos = GetCameraTransform().pos
				else
					local feet = PC.speakerPos(p)
					if feet then pos = VecAdd(feet, Vec(0, 1.7, 0)) end
				end
				if pos then
					local set = (s[4] and q.set == "voice") and "shout" or q.set
					local clips = B.clips[set]
					local clip = clips[s[1] % #clips + 1]
					local jitter = s[4] and (1.04 + 0.16 * math.random()) or (0.94 + 0.12 * math.random())
					local pitch = q.pitch * s[3] * jitter
					local base = s[4] and q.shoutVol or q.vol
					local cam = GetCameraTransform().pos
					if q.how == "flat" then
						PlaySound(clip, pos, base, false, pitch)            -- (the preview: at the listener)
					elseif q.how == "whisper" then                          -- (no echo; quiet toward its reach)
						local d = VecLength(VecSub(pos, PC.listenerHead())) * PC.wallMul(p)
						local v = base * PC.loudness(d, PC.cfg.whisperMumbleR + PC.cfg.soundGrace, PC.cfg.whisperR)
						if v > 0 then PlaySound(clip, PC.soundPos(pos, cam), v, false, pitch) end   -- (walked out of earshot: silent)
					else
						local vol, echoes = PC.babbleDistance(pos, base, s[4], (s[4] and PC.cfg.shoutMumbleR or PC.cfg.mumbleR) + PC.cfg.soundGrace, s[4] and PC.cfg.shoutR or PC.cfg.chatR, PC.wallMul(p))
						if vol > 0 then PlaySound(clip, PC.soundPos(pos, cam), vol, false, pitch) end
						for _, e in ipairs(vol > 0 and echoes or {}) do
							B.echoes[#B.echoes + 1] = {t = now + e.delay, clip = clip, pos = PC.soundPos(VecAdd(pos, e.offset), cam), vol = e.vol, pitch = pitch * 0.97}
						end
					end
				end
				q.k = q.k + 1
				q.nextT = math.max(q.nextT + gap(s), now - 0.1)          -- (on a fixed schedule, not from this frame)
			end
		end
	end
end

-- ---- typing, modes, commands
function PC.setTyping(on)
	local c = PC.C()
	c.typing = on and true or false
	c.text, c.send, c.tab, c.scroll = "", nil, nil, 0
	c.focus = c.typing
	c.page = "chat"                                               -- (opens / closes on the history)
	c.regTyping = c.typing                                        -- (this game's registry at once: no key of the first
	SetBool(PC.cfg.reg .. ".typing." .. GetLocalPlayer(), c.typing)  --  letter slips through to a game; see clientTick)
	ServerCall("server.pc_typing", GetLocalPlayer(), c.typing, PC.mode())
end

function PC.scrollBy(n)
	local c = PC.C()
	if c.page ~= "chat" then return end
	c.scroll = math.max(0, math.min(math.max(0, #c.hist - 1), c.scroll + n))
end

-- say something: into the outbox, sent now and resent until the server confirms it (PC.pump)
function PC.say(text, mode)
	local c = PC.C()
	if mode == "p" then mode = "s" end                            -- (the old id for Speak)
	text = PC.clean(text)
	if text == "" then return end
	if #c.outbox >= PC.cfg.outboxMax then
		PC.system("Slow down: your last messages are still being sent.")
		return
	end
	c.seq = c.seq + 1
	c.outbox[#c.outbox + 1] = {seq = c.seq, ch = mode or PC.mode(), text = text, t0 = GetTime(), sentT = -1e9}
	PC.pump(GetTime())
end

-- the oldest unconfirmed message: (re)sent every cfg.resendT, given up after cfg.resendFor
function PC.pump(now)
	local c, cfg = PC.C(), PC.cfg
	local ack = (shared.pcAck or {})[GetLocalPlayer()] or 0
	while c.outbox[1] and c.outbox[1].seq <= ack do table.remove(c.outbox, 1) end
	local m = c.outbox[1]
	if not m then return end
	if now - m.t0 > cfg.resendFor then
		table.remove(c.outbox, 1)
		PC.system("Not sent (no answer from the host): " .. m.text)
		return
	end
	if now - m.sentT >= cfg.resendT then
		m.sentT = now
		ServerCall("server.pc_say", GetLocalPlayer(), m.ch, m.text, m.seq)
	end
end

-- a whisper from the server: only the players near enough get one (it is never in shared)
function client.pc_whisper(id, p, name, text)
	PC.receive({id = id, p = p, name = name, ch = "w", text = text})
end

-- what a dead player said: only the dead get it (never in shared)
function client.pc_dead(id, p, name, text, chan)
	PC.receive({id = id, p = p, name = name, ch = "d", text = text, chan = chan})
end

function PC.findVoice(s)
	local n = tonumber(s)
	if n and PC.VOICES[n] then return n end
	s = s:lower()
	for i, v in ipairs(PC.VOICES) do if v[1]:lower() == s then return i end end
	for i, v in ipairs(PC.VOICES) do if v[1]:lower():sub(1, #s) == s then return i end end
	return nil
end

function PC.setVoice(i)
	local c = PC.C()
	if not PC.VOICES[i] then return end
	c.voiceWant, c.voiceTries, c.voiceT = i, 0, 0
	SetInt(PC.cfg.save .. "voice", i)
	PC.babbleSay(GetLocalPlayer(), "Hello there, how are you?", i, "flat")   -- (a preview, only for you)
end

-- the babble volume saved (0..1, savegame.mod.pcvolume); before the slider it was a level 1-5 (pcbabblevol)
function PC.savedVolume()
	local cfg = PC.cfg
	if HasKey(cfg.save .. "volume") then return math.max(0, math.min(1, GetFloat(cfg.save .. "volume"))) end
	return PC.LEVELS[GetInt(cfg.save .. "babblevol")] or 1
end

-- Settings: speech bubbles' opacity (1 = Off .. 5 = 100 %) and the babble's volume (0..1), saved
function PC.setBubbleLevel(i)
	local c = PC.C()
	if not PC.LEVELS[i] then return end
	c.bubbleLevel = i
	SetInt(PC.cfg.save .. "bubbles", i)
end

function PC.setBabbleVolume(v, save)
	local c = PC.C()
	v = math.max(0, math.min(1, tonumber(v) or 1))
	c.babbleVolume = v
	if save ~= false then SetFloat(PC.cfg.save .. "volume", v) end
	if v == 0 then c.babble.queue, c.babble.echoes = {}, {} end
end

function PC.setHideOwn(on)
	local c = PC.C()
	c.hideOwn = on and true or false
	SetBool(PC.cfg.save .. "hideown", c.hideOwn)
end

function PC.setHideHint(on)
	local c = PC.C()
	c.hideHint = on and true or false
	SetBool(PC.cfg.save .. "hidehint", c.hideHint)
end

-- the optional window hotkey (PC.cfg.windowKey, default none), upper case for hints
function PC.keyName()
	return (PC.cfg.windowKey or ""):upper()
end

-- a click on a w x h rect at the cursor (align left top). Fires on the mouse PRESS; UiBlankButton
-- (which fires on release) is the fallback, and the release of a click whose press already fired for
-- the same id is ignored, so one click is one action. inside: pass it when you already asked.
function PC.clicked(id, w, h, inside)
	local c = PC.C()
	if inside == nil then inside = UiIsMouseInRect(w, h) end
	local press = inside and InputPressed("lmb")
	local release = UiBlankButton and UiBlankButton(w, h) or false
	if press then
		c.press = {id = id, t = GetTime()}
		return true
	end
	if release then
		if c.press and c.press.id == id and GetTime() - c.press.t < 2 then
			c.press = nil
			return false
		end
		return true
	end
	return false
end

function PC.modeCommand(m, rest)
	local info = PC.modeInfo(m)
	if PC.lobby() and m ~= "g" then PC.system("In the lobby everyone hears everything."); return end
	if rest ~= "" then
		PC.say(rest, m)
	else
		PC.setMode(m)
		PC.system("Mode: " .. info[2]:gsub(":%s*$", "") .. ". Tab on the input line changes it.")
	end
end

-- /mute [name], /unmute name|all: hide a player's messages (bubbles, babble, typing, history) - only
-- for you. Names are those of players who have said something; the start of a name is enough.
function PC.muteCommand(on, arg)
	local c = PC.C()
	local me = GetLocalPlayer()
	if arg == "" then
		if not on then PC.system("/unmute <name> or /unmute all."); return end
		local names = {}
		for _, n in pairs(c.muted) do names[#names + 1] = n end
		table.sort(names)
		PC.system(#names > 0 and ("Muted (only for you): " .. table.concat(names, ", ") .. ". /unmute <name> or /unmute all.")
			or "Nobody is muted. /mute <name> hides a player's messages, only for you.")
		return
	end
	if not on and arg:lower() == "all" then
		c.muted = {}
		PC.system("Nobody is muted now.")
		return
	end
	local want, exact, part = arg:lower(), {}, {}
	for q, n in pairs(c.names) do
		if q ~= me then
			local l = n:lower()
			if l == want then exact[#exact + 1] = q elseif l:sub(1, #want) == want then part[#part + 1] = q end
		end
	end
	local hits = #exact > 0 and exact or part
	if #hits == 0 then PC.system("No player called \"" .. arg .. "\" has said anything yet."); return end
	if #hits > 1 then
		local names = {}
		for _, q in ipairs(hits) do names[#names + 1] = c.names[q] end
		PC.system("\"" .. arg .. "\" could be: " .. table.concat(names, ", ") .. ". Type more of the name.")
		return
	end
	local q = hits[1]
	if on then
		c.muted[q] = c.names[q]
		c.bubbles[q], c.prevBubbles[q], c.babble.queue[q] = nil, nil, nil
		PC.system(c.names[q] .. " is muted (only for you). /unmute " .. c.names[q] .. " to hear them again.")
	else
		c.muted[q] = nil
		PC.system(c.names[q] .. " is not muted any more.")
	end
end

function PC.command(text)
	local c = PC.C()
	local cmd, rest = text:match("^/(%S*)%s*(.-)%s*$")
	cmd, rest = (cmd or ""):lower(), rest or ""
	if cmd == "voice" or cmd == "v" then
		if rest == "" then
			local names = {}
			for i, v in ipairs(PC.VOICES) do names[i] = i .. " " .. v[1] end
			PC.system("Voices: " .. table.concat(names, ", ") .. ". Yours: " .. PC.VOICES[PC.voiceOf(GetLocalPlayer())][1] .. ". Type /voice <name> or use Settings.")
		else
			local i = PC.findVoice(rest)
			if not i then
				PC.system("No voice called \"" .. rest .. "\". Type /voice to list them.")
			else
				PC.setVoice(i)
				PC.system("Your voice is now " .. PC.VOICES[i][1] .. ".")
			end
		end
	elseif cmd == "g" or cmd == "a" or cmd == "all" or cmd == "global" or cmd == "everyone" then
		PC.modeCommand("g", rest)
	elseif cmd == "s" or cmd == "speak" or cmd == "p" or cmd == "n" or cmd == "near" or cmd == "nearby" or cmd == "local" or cmd == "proximity" or cmd == "say" then
		PC.modeCommand("s", rest)
	elseif cmd == "y" or cmd == "yell" or cmd == "shout" or cmd == "sh" then
		PC.modeCommand("y", rest)
	elseif cmd == "w" or cmd == "whisper" then
		PC.modeCommand("w", rest)
	elseif cmd == "settings" or cmd == "options" then
		PC.setTyping(true)                                        -- (the window is interactive while typing)
		PC.setPage("settings")
	elseif cmd == "hint" then
		PC.setHideHint(not c.hideHint)
		PC.system(c.hideHint and "Hint hidden. /hint shows it again." or "Hint shown.")
	elseif cmd == "window" then
		c.pinned = not c.pinned
		PC.system(c.pinned and "The chat window stays open (Enter to use it). /window again to close it." or "The chat window closes when you stop typing.")
	elseif cmd == "mute" or cmd == "unmute" then
		PC.muteCommand(cmd == "mute", rest)
	elseif cmd == "dummy" then
		PC.dummyCommand(rest)
	elseif cmd == "clear" then
		c.hist = {}
		c.scroll = 0
	elseif cmd == "help" or cmd == "h" or cmd == "?" then
		local key = PC.keyName() ~= "" and (PC.keyName() .. ": chat window. ") or ""
		PC.system("Enter: chat. Tab or the chips on the line: Whisper / Speak / Yell / Global. Settings (window header): voice and more. " .. key)
		PC.system("/s /w /y /g [text]   /voice [name]   /settings   /hint   /window (keep open)   /clear   /mute [name]   /dummy [1|2|3|clear] (test speakers)")
	else
		PC.system("Unknown command /" .. cmd .. ". Type /help.")
	end
end

-- a line from the input: a command (local), "//..." (a line starting with "/"), or a message
function PC.submit(text)
	text = PC.clean(text)
	if text == "" then return end
	if text:sub(1, 2) == "//" then
		text = text:sub(2)
	elseif text:sub(1, 1) == "/" then
		PC.command(text)
		return
	end
	PC.say(text, PC.mode())
end

-- the text field (cursor at the box's top left; font and colour set before). The game's UiTextInput as
-- its spawn menu uses it: pass the current text, get the edited text back; focus = true for ONE frame
-- requests the keyboard, again if the field lost it while the line is open.
function PC.field(w, h)
	local c = PC.C()
	if not c.typing or not UiTextInput then return end
	local t, active = UiTextInput(c.text, w, h, c.focus or false)
	c.focus = (active == false)
	if type(t) == "string" then
		if t:find("[\r\n]") then c.send = true end                   -- (Enter taken by the field)
		if t:find("\t") then c.tab = true end                         -- (Tab taken by the field)
		c.text = PC.utf8Head((t:gsub("[%z\1-\31\127]", "")), PC.cfg.maxLen)
	end
end

-- keys that change what is drawn (before drawing, so this frame already shows it): Tab (the mode),
-- scrolling, the optional window hotkey (never while typing: then letters go into the line)
function PC.preKeys()
	local c = PC.C()
	if c.typing then
		UiMakeInteractive()
		if InputPressed("tab") then PC.nextMode() end
		local wheel = InputValue and InputValue("mousewheel") or 0
		if wheel > 0 then PC.scrollBy(1) elseif wheel < 0 then PC.scrollBy(-1) end
		if InputPressed("pgup") then PC.scrollBy(4) elseif InputPressed("pgdown") then PC.scrollBy(-4) end
	elseif not (PC.hooks.blockKeys and PC.hooks.blockKeys()) then
		local wk = (PC.cfg.windowKey or ""):lower()
		if wk ~= "" and InputPressed(wk) then
			c.pinned = not c.pinned
			c.scroll = 0
			c.page = "chat"
		end
	end
end

-- keys after the field (it may have taken Enter / Tab): Enter opens / says it, Esc closes
function PC.keys()
	local c = PC.C()
	if c.typing then
		UiMakeInteractive()
		if c.tab and not InputPressed("tab") then PC.nextMode() end   -- (once: preKeys took a Tab key press)
		c.tab = nil
		if InputPressed("return") or c.send then
			local text = c.text
			PC.setTyping(false)
			PC.submit(text)
		elseif InputPressed("esc") or InputPressed("pause") then
			PC.setTyping(false)
		end
	elseif not (PC.hooks.blockKeys and PC.hooks.blockKeys()) then
		if InputPressed("return") then
			PC.setTyping(true)
			UiMakeInteractive()
		end
	end
end

-- ---- drawing
-- one history line at the cursor (align left top): [tag] Name: text. Returns its height.
function PC.drawLine(e, w, size, a, measureOnly)
	UiPush()
	UiWordWrap(w)
	local info = (not e.sys) and (e.ch == "d" and PC.channelInfo(e.chan) or PC.modeInfo(e.ch)) or nil
	local whisper = e.ch == "w"
	local tag = info and (info[4] .. " ") or ""
	local tagSize = size - 6
	local tagW = 0
	if tag ~= "" then
		UiFont("regular.ttf", tagSize)
		tagW = UiGetTextSize(tag) or 0
	end
	local prefix = e.sys and "" or ((e.name or "?") .. ": ")
	local pw = prefix ~= "" and PC.textWidth(prefix, size) or 0
	local tw = math.max(120, w - tagW - pw)
	UiFont(PC.chatFont(e.text), size)
	UiWordWrap(tw)
	local vis = PC.chatVisual(e.text)
	local _, th = UiGetTextSize(vis)
	th = math.max(th or size, size)
	if not measureOnly then
		local fa = whisper and 0.92 * a or a
		if tag ~= "" then
			local col = info[5]
			UiColor(col[1], col[2], col[3], 0.85 * fa)
			UiPush()
			UiTranslate(0, 4)
			UiFont("regular.ttf", tagSize)
			UiText(tag)
			UiPop()
			UiTranslate(tagW, 0)
		end
		if prefix ~= "" then
			local col = info[5]
			UiColor(col[1], col[2], col[3], fa)
			PC.text(prefix, size)
			UiTranslate(pw, 0)
		end
		if e.sys then UiColor(0.6, 0.95, 0.85, a)
		elseif e.shout then UiColor(1, 0.62, 0.32, a)
		elseif whisper then UiColor(0.8, 0.82, 1, fa)                    -- (lavender: readable, still not a Speak line)
		elseif e.far then UiColor(0.85, 0.85, 0.85, 0.8 * a)
		else UiColor(1, 1, 1, a) end
		UiFont(PC.chatFont(e.text), size)
		UiWordWrap(tw)
		UiText(vis)
	end
	UiPop()
	return th
end

-- where a bubble goes for a speaker off screen: on the screen edge, in the speaker's direction
function PC.edgePoint(pos)
	local lp = TransformToLocalPoint(GetCameraTransform(), pos)          -- (camera: x right, y up, -z ahead)
	local dx, dy = lp[1], -lp[2]
	local l = math.sqrt(dx * dx + dy * dy)
	if l < 1e-3 then dx, dy, l = 0, 1, 1 end                              -- (right behind: the bottom)
	dx, dy = dx / l, dy / l
	local W, H = UiWidth(), UiHeight()
	local cx, cy = W / 2, H / 2
	local kx = math.abs(dx) > 1e-3 and (cx / math.abs(dx)) or 1e9      -- (to the very edge: the layout then keeps
	local ky = math.abs(dy) > 1e-3 and (cy / math.abs(dy)) or 1e9      --  the whole bubble on screen)
	local k = math.min(kx, ky)
	return cx + dx * k, cy + dy * k
end

-- a speech bubble over player p, measured but not drawn yet. small: the "..." of someone typing (nil
-- when they are off screen); whisper: a bit smaller, pale lavender; mumble: a garbled message from the
-- buffer range. A speaker off screen gets the bubble on the screen edge on their side; every bubble is
-- kept wholly on screen (PC.EDGE_MARGIN px).
PC.EDGE_MARGIN = 8
-- a bubble text's font, shaped form and size, measured once and kept (every frame re-measuring every
-- bubble cost the most of the drawing; a garbled text changes only when a letter turns)
PC.measured, PC.measuredN = {}, 0
function PC.measure(text)
	local cfg = PC.cfg
	local key = cfg.bubbleW .. "|" .. text
	local m = PC.measured[key]
	if m then return m end
	local font, size = PC.bubbleFont(text)
	local vis = PC.chatVisual(text)
	UiPush()
	UiFont(font, size)
	UiWordWrap(cfg.bubbleW)
	local tw, th = UiGetTextSize(vis)
	local _, lh = UiGetTextSize("Ag")
	UiPop()
	m = {font = font, size = size, vis = vis, tw = tw, th = th or 28, lh = lh or 28}
	if PC.measuredN >= 200 then PC.measured, PC.measuredN = {}, 0 end
	PC.measured[key], PC.measuredN = m, PC.measuredN + 1
	return m
end

function PC.bubbleLayout(p, text, shout, a, small, whisper, mumble, t0)
	local feet = PC.speakerPos(p)
	if not feet then return nil end
	local head = VecAdd(feet, Vec(0, 2.25, 0))
	local x, y, d = UiWorldToPixel(head)
	local dist = VecLength(VecSub(VecAdd(feet, Vec(0, 1.7, 0)), PC.listenerHead()))   -- (from your character, not the camera)
	-- sized by the real distance between you and the speaker, the same on screen and docked: UiWorldToPixel's
	-- depth (along the view) shrinks toward the screen edges, and the camera (third person) swings around
	-- as you turn - both changed the size when turning on the spot
	local scale, docked = math.max(0.55, math.min(1.1, 9 / math.max(1, dist))), false
	if d and d > 0 and x >= 0 and x <= UiWidth() and y >= 0 and y <= UiHeight() then
	elseif small then
		return nil                                                        -- (the typing "...": only over a speaker you see)
	else
		x, y = PC.edgePoint(head)                                         -- (off screen: on the edge, the speaker's side)
		docked = true
	end
	local s = scale * (shout and 1.15 or 1) * (small and 0.75 or (whisper and 0.88 or 1))
	local cfg = PC.cfg
	local mt = PC.measure(text)
	local font, size, vis, tw, th, lh = mt.font, mt.size, mt.vis, mt.tw, mt.th, mt.lh
	-- a long message: cfg.bubbleLines lines visible, scrolling down at reading pace from t0
	local vh, off, scrollTime = th, 0, 0
	if th > cfg.bubbleLines * lh + 1 then
		vh = cfg.bubbleLines * lh
		local speed = lh / cfg.scrollLine
		scrollTime = (th - vh) / speed
		off = t0 and math.max(0, math.min(th - vh, (GetTime() - t0 - cfg.scrollHold) * speed)) or 0
	end
	local w = math.min(cfg.bubbleW, tw or 200) + 30
	local h = vh + 22
	-- the whole bubble stays on screen (a speaker near the edge, or pinned to it)
	local M = PC.EDGE_MARGIN
	local halfW, up = (w / 2 + 2) * s, (h + 16) * s
	local x0, y0 = x, y
	x = math.max(M + halfW, math.min(UiWidth() - M - halfW, x))
	y = math.max(M + up, math.min(UiHeight() - M, y))
	docked = docked or math.abs(x - x0) > 1 or math.abs(y - y0) > 1      -- (not over its speaker: no line to them)
	return {p = p, x = x, y = y, s = s, w = w, h = h, th = th, vh = vh, off = off, scrollTime = scrollTime,
		vis = vis, font = font, size = size, a = a, shout = shout, whisper = whisper, mumble = mumble, lift = 0, docked = docked, dist = dist,
		left = x - (w / 2 + 2) * s, right = x + (w / 2 + 2) * s, top = y - (h + 16) * s, bottom = y - 4 * s}
end

-- draw a laid-out bubble (thin black outline), raised by L.lift px; a raised one gets a thin line down
-- to the speaker's head
function PC.bubbleDraw(L)
	local a, s, w, h = L.a, L.s, L.w, L.h
	local ab = a * (L.op or 1)                                           -- (the bubble itself: the opacity setting)
	if L.docked then                                                     -- (on the screen edge: no line)
	elseif L.lift > 0 then                                               -- (raised: a line down to the speaker)
		UiPush()
		UiTranslate(L.x - 1, L.bottom - L.lift)
		UiColor(0, 0, 0, 0.55 * ab)
		UiRect(2, L.lift)
		UiPop()
	elseif L.lift < 0 and L.top - L.lift > L.bottom then                 -- (put below: a line up to the speaker)
		UiPush()
		UiTranslate(L.x - 1, L.bottom)
		UiColor(0, 0, 0, 0.55 * ab)
		UiRect(2, L.top - L.lift - L.bottom)
		UiPop()
	end
	UiPush()
	UiTranslate(L.x, L.y - L.lift)
	if L.shake then UiTranslate(math.random(-2, 2), math.random(-2, 2)) end    -- (ALL CAPS: shaking)
	UiScale(s)
	UiFont(L.font, L.size)
	UiWordWrap(PC.cfg.bubbleW)
	local k = 2                                                              -- (the outline)
	UiAlign("left top")
	UiTranslate(-w / 2, -h - 14)
	UiColor(0, 0, 0, 0.9 * ab)
	UiPush(); UiTranslate(-k, -k); UiRoundedRect(w + 2 * k, h + 2 * k, 10 + k); UiPop()
	UiPush(); UiTranslate(w / 2 - 9, h); UiRotate(45); UiTranslate(-k, -k); UiRect(13 + 2 * k, 13 + 2 * k); UiPop()
	if L.whisper then UiColor(0.86, 0.87, 1, ab) else UiColor(1, 1, 1, ab) end
	UiRoundedRect(w, h, 10)
	UiPush(); UiTranslate(w / 2 - 9, h); UiRotate(45); UiRect(13, 13); UiPop()   -- the tail (covers the outline at its root)
	if L.shout then UiColor(0.96, 0.45, 0.12, ab); UiRoundedRectOutline(w, h, 10, 4) end
	UiTranslate(15, 11)
	if L.th > L.vh + 1 then                                               -- (scrolling: a bar on the right)
		UiPush()
		UiTranslate(w - 24, 0)
		UiColor(0, 0, 0, 0.12 * a)
		UiRect(3, L.vh)
		UiColor(0, 0, 0, 0.45 * a)
		UiTranslate(0, L.vh * L.off / L.th)
		UiRect(3, L.vh * L.vh / L.th)
		UiPop()
	end
	if L.whisper then UiColor(0.2, 0.2, 0.38, L.mumble and 0.85 * a or a)
	else UiColor(L.shout and 0.62 or 0.08, L.shout and 0.24 or 0.05, L.shout and 0.04 or 0.1, L.mumble and 0.85 * a or a) end
	if L.th > L.vh + 1 then
		UiPush()
		UiWindow(w - 30, L.vh, true)                                      -- (clipped to the visible lines)
		UiTranslate(0, -L.off)
		UiText(L.vis)
		UiPop()
	else
		UiText(L.vis)
	end
	UiPop()
end

-- no bubble hides another: lowest on screen first, each one that would overlap one already placed is
-- raised just above it (straight up, a line down to its speaker); with no room left above, it goes
-- below the others instead (a line up). c.bubbleRects: the result.
function PC.layoutBubbles(list)
	table.sort(list, function(u, v)
		if u.y ~= v.y then return u.y > v.y end                        -- (lowest speaker first; a speaker's newest
		if (u.age or 1) ~= (v.age or 1) then return (u.age or 1) < (v.age or 1) end   --  bubble first: nearest the head)
		return u.p < v.p
	end)
	local placed = {}
	local M = PC.EDGE_MARGIN
	for _, L in ipairs(list) do
		local down = false                                                -- (no room above: below the others instead)
		for _ = 1, 3 * #list + 2 do
			local moved = false
			for _, P in ipairs(placed) do
				if L.left < P.right and L.right > P.left and L.top - L.lift < P.bottom and L.bottom - L.lift > P.top then
					local up = L.bottom - P.top + 4
					if not down and L.top - up < M then down = true end
					L.lift = down and math.min(L.lift, L.top - P.bottom - 4) or up
					moved = true
				end
			end
			if not moved then break end
		end
		L.lift = math.max(L.bottom - (UiHeight() - M), math.min(L.lift, L.top - M))   -- (on screen whatever happens)
		placed[#placed + 1] = {p = L.p, left = L.left, right = L.right, top = L.top - L.lift, bottom = L.bottom - L.lift}
	end
	PC.C().bubbleRects = placed
	return list
end

-- one bubble right away (no overlap handling)
function PC.bubble(p, text, shout, a, small, whisper, mumble)
	local L = PC.bubbleLayout(p, text, shout, a, small, whisper, mumble)
	if L then PC.bubbleDraw(L) end
end

function PC.drawBubbles()
	local c, cfg = PC.C(), PC.cfg
	local op = PC.LEVELS[c.bubbleLevel]                                  -- (Settings: speech bubbles)
	if op == 0 then c.bubbleRects = {}; return end
	local now = GetTime()
	local me = GetLocalPlayer()
	local third = GetBool("game.thirdperson")
	local list = {}
	local function add(L) if L then list[#list + 1] = L end end
	for age, tbl in ipairs({c.bubbles, c.prevBubbles}) do              -- (the newest, then the one before it)
		for p, b in pairs(tbl) do
			if (p ~= me or (third and not c.hideOwn)) and not b.hidden and PC.inReach(p, b) then
				local L = PC.bubbleLayout(p, PC.bubbleText(p, b, now), b.shout, math.max(0, math.min(1, (PC.bubbleLife(b) + (b.extra or 0) - (now - b.t)) / 1.2)), false, b.whisper, b.mumble, b.scrollT or b.t)
				if L then
					b.extra = math.max(b.extra or 0, L.scrollTime)
					L.age = age
					L.shake = PC.allCaps(b.full)
				end
				add(L)
			end
		end
	end
	for p, mode in pairs(shared.pcTyping or {}) do
		if (mode == "s" or mode == "w" or mode == "y") and p ~= me and not c.muted[p] and not (c.bubbles[p] and not c.bubbles[p].hidden)
			and (PC.lobby() or PC.channelOf(p) == "") then                    -- (a channel - the dead: no "..." for anyone)
			local d = PC.hearDist(p)
			if d and d <= (PC.rangeOf(mode)) then add(PC.bubbleLayout(p, "...", mode == "y", 0.75, true, mode == "w")) end
		end
	end
	local dm = c.dummy
	for _, du in ipairs(dm and dm.list or {}) do                       -- (a dummy typing before its turn)
		if du.typing then
			local d = not (c.bubbles[du.p] and not c.bubbles[du.p].hidden) and PC.distTo(du.p)
			local dmode = du.kind
			if d and d <= (PC.rangeOf(dmode)) then add(PC.bubbleLayout(du.p, "...", dmode == "y", 0.75, true, dmode == "w")) end
		end
	end
	-- drawn farthest speaker first (each with its line): a nearer speaker's bubble covers the lines of
	-- bubbles raised above it from farther away; a speaker's older bubble before its newest
	local order = {}
	for i, L in ipairs(PC.layoutBubbles(list)) do order[i] = L end
	table.sort(order, function(u, v)
		if math.abs((u.dist or 0) - (v.dist or 0)) > 1e-3 then return (u.dist or 0) > (v.dist or 0) end
		if (u.age or 1) ~= (v.age or 1) then return (u.age or 1) > (v.age or 1) end
		return u.p < v.p
	end)
	PC.drawOrder = order
	for _, L in ipairs(order) do L.op = op; PC.bubbleDraw(L) end
end

-- a small two-way switch on the Settings page; returns the new value when clicked, else nil
-- a row of choices on the Settings page (one selected); returns the clicked one's index, else nil
function PC.choice(id, cur, labels)
	local c = PC.C()
	local out = nil
	for j, label in ipairs(labels) do
		local on = j == cur
		UiPush()
		UiTranslate((j - 1) * 98, 0)
		local hover = c.typing and UiIsMouseInRect(90, 36)
		if c.typing and PC.clicked(id .. j, 90, 36, hover) then out = j end
		if on then UiColor(1, 0.82, 0.3, 0.3) elseif hover then UiColor(1, 1, 1, 0.16) else UiColor(1, 1, 1, 0.07) end
		UiRoundedRect(90, 36, 8)
		if on then UiColor(1, 0.82, 0.3, 0.95); UiRoundedRectOutline(90, 36, 8, 2) end
		UiTranslate(45, 18)
		UiAlign("center middle")
		UiFont(on and "bold.ttf" or "regular.ttf", 20)
		UiColor(1, 1, 1, on and 1 or 0.7)
		UiText(label)
		UiPop()
	end
	return out
end

function PC.toggle(id, value, yes, no)
	local c = PC.C()
	local out = nil
	for j = 1, 2 do
		local on = (j == 1) == value
		UiPush()
		UiTranslate((j - 1) * 130, 0)
		local hover = c.typing and UiIsMouseInRect(120, 40)
		if c.typing and PC.clicked(id .. j, 120, 40, hover) then out = (j == 1) end
		if on then UiColor(1, 0.82, 0.3, 0.3) elseif hover then UiColor(1, 1, 1, 0.16) else UiColor(1, 1, 1, 0.07) end
		UiRoundedRect(120, 40, 8)
		if on then UiColor(1, 0.82, 0.3, 0.95); UiRoundedRectOutline(120, 40, 8, 2) end
		UiTranslate(60, 20)
		UiAlign("center middle")
		UiFont(on and "bold.ttf" or "regular.ttf", 22)
		UiColor(1, 1, 1, on and 1 or 0.7)
		UiText(j == 1 and yes or no)
		UiPop()
	end
	return out
end

-- the Settings page: the voice picker (a click picks + previews) and the switches
function PC.drawSettings(W, H)
	local c = PC.C()
	local cur = PC.voiceOf(GetLocalPlayer())
	local bw, bh, gap = 300, 38, 6
	UiPush()
	UiTranslate(16, 68)
	UiFont("regular.ttf", 22)
	UiColor(1, 1, 1, 0.85)
	UiText("Your voice: " .. PC.VOICES[cur][1] .. " - click one: everyone hears you in it, you hear a preview.")
	UiTranslate(0, 34)
	for i, v in ipairs(PC.VOICES) do
		UiPush()
		UiTranslate(((i - 1) % 3) * (bw + gap), math.floor((i - 1) / 3) * (bh + gap))
		local hover = c.typing and UiIsMouseInRect(bw, bh)
		if c.typing and PC.clicked("voice" .. i, bw, bh, hover) then
			PC.setVoice(i)
			cur = i
		end
		local on = i == cur
		if on then UiColor(1, 0.82, 0.3, 0.3) elseif hover then UiColor(1, 1, 1, 0.16) else UiColor(1, 1, 1, 0.07) end
		UiRoundedRect(bw, bh, 8)
		if on then UiColor(1, 0.82, 0.3, 0.95); UiRoundedRectOutline(bw, bh, 8, 3) end
		UiTranslate(bw / 2, bh / 2)
		UiAlign("center middle")
		UiFont("bold.ttf", 26)
		UiColor(1, 1, 1, on and 1 or 0.75)
		UiText(v[1])
		UiPop()
	end
	UiTranslate(0, 2 * (bh + gap) + 6)
	local rows = {
		{"set_h", "\"Enter: chat\" hint on screen", not c.hideHint, "Show", "Hide", function(v) PC.setHideHint(not v) end},
		{"set_w", "Keep the chat window open", c.pinned, "Yes", "No", function(v) c.pinned = v end},
		{"set_o", "Your own bubble (third person)", not c.hideOwn, "Show", "Hide", function(v) PC.setHideOwn(not v) end},
		{"set_b", "Speech bubbles", c.bubbleLevel, PC.setBubbleLevel},
		{"set_v", "Babble volume", "slider", c.babbleVolume, PC.setBabbleVolume},
	}
	if PC.isHost() then                                               -- (the host: walls, for everyone)
		local byGame = shared.pcWallsBy == "game"
		rows[#rows + 1] = {"set_m", byGame and "Walls muffle voices (by the game)" or "Walls muffle voices (host)",
			shared.pcWalls == true, "On", "Off", function(v) if not byGame then ServerCall("server.pc_walls", GetLocalPlayer(), v) end end}
	end
	for k, r in ipairs(rows) do
		UiPush()
		UiTranslate(0, (k - 1) * 40)
		UiPush()
		UiTranslate(0, 20)
		UiAlign("left middle")
		UiFont("regular.ttf", 22)
		UiColor(1, 1, 1, 0.85)
		UiText(r[2])
		UiPop()
		UiTranslate(400, 0)
		if r[3] == "slider" then                                          -- (0 .. 100 %, live while dragged, saved when let go)
			local v, done = PC.slider(r[1], r[4], 400)
			if v then r[5](v, done) end
		elseif type(r[3]) == "number" then                                -- (a level: Off .. 100 %)
			local i = PC.choice(r[1], r[3], PC.LEVEL_NAMES)
			if i then r[4](i) end
		else
			local v = PC.toggle(r[1], r[3], r[4], r[5])
			if v ~= nil then r[6](v) end
		end
		UiPop()
	end
	if PC.isHost() then
		UiTranslate(0, #rows * 40 + 10)
		PC.rangeBar(W)
	end
	UiPop()
end

-- a 0..1 slider w px wide (a 36 px tall row): press anywhere on it and drag; snaps to 5 %. Returns
-- the new value while dragging (nil when untouched) and true once let go.
function PC.slider(id, value, w)
	local c = PC.C()
	local out, done = nil, false
	local hover = c.typing and UiIsMouseInRect(w, 36)
	if c.typing and not c.sdrag and PC.clicked(id, w, 36, hover) then c.sdrag = id end
	if c.sdrag == id then
		local mx = UiGetMousePos()
		out = math.floor(math.max(0, math.min(1, mx / w)) * 20 + 0.5) / 20
		if not (c.typing and InputDown("lmb")) then c.sdrag, done = nil, true end
	end
	local v = out or value
	UiPush()
	UiAlign("left top")
	UiTranslate(0, 12)
	UiColor(1, 1, 1, hover and 0.14 or 0.08)
	UiRoundedRect(w, 12, 6)
	UiColor(1, 0.82, 0.3, 0.6)
	if v > 0 then UiRoundedRect(math.max(12, w * v), 12, 6) end
	UiTranslate(w * v - 8, -10)
	UiColor(0, 0, 0, 0.8)
	UiRoundedRect(16, 32, 5)
	UiTranslate(2, 2)
	UiColor(1, 0.82, 0.3, (hover or c.sdrag == id) and 1 or 0.85)
	UiRoundedRect(12, 28, 4)
	UiPop()
	UiPush()
	UiTranslate(w + 18, 18)
	UiAlign("left middle")
	UiFont("bold.ttf", 20)
	UiColor(1, 1, 1, 0.9)
	UiText(v == 0 and "Off" or string.format("%d%%", math.floor(v * 100 + 0.5)))
	UiPop()
	return out, done
end

-- the history page: everything this player received, newest at the bottom
function PC.drawHistory(W, H)
	local c, cfg = PC.C(), PC.cfg
	local h = c.hist
	local top, y, w = 66, H - 12, W - 28
	if #h == 0 then
		UiPush()
		UiTranslate(14, top + 6)
		UiFont("regular.ttf", 22)
		UiColor(1, 1, 1, 0.45)
		UiText("Nothing yet. Whisper: " .. cfg.whisperR .. " m, Speak: " .. cfg.chatR .. " m, Yell: " .. cfg.shoutR .. " m, Global: all players.")
		UiPop()
	end
	for i = #h - c.scroll, 1, -1 do
		local e = h[i]
		local lh = PC.drawLine(e, w, 24, 1, true)
		if y - lh < top then break end
		y = y - lh
		UiPush()
		UiTranslate(14, y)
		PC.drawLine(e, w, 24, 1)
		UiPop()
		y = y - 6
	end
	if c.scroll > 0 then
		UiPush()
		UiTranslate(W - 14, H - 6)
		UiAlign("right bottom")
		UiFont("regular.ttf", 16)
		UiColor(1, 0.82, 0.3, 0.8)
		UiText("(" .. c.scroll .. " newer below: PgDn)")
		UiPop()
	end
end

-- the chat window: a header (title, and right-aligned the Settings / Back button), then the history
-- or the Settings page
function PC.isHost()
	local ok, h = pcall(IsPlayerHost, GetLocalPlayer())
	return ok and h == true
end

-- the host's distance bar (Settings): 0..rangeMax m, a knob each for whisper, speech and yell (how far
-- the words carry); each range shaded, its buffer lighter. Dragging a knob and letting go sends it.
PC.RANGE_KINDS = {{"Whisper", {0.78, 0.78, 0.95}, "whisperBuf"}, {"Speak", {1, 0.82, 0.3}, "speakBuf"}, {"Yell", {1, 0.58, 0.28}, "shoutBuf"}}
function PC.rangeBar(W)
	local c, cfg = PC.C(), PC.cfg
	local bw = W - 64
	local vals = c.dragVals or c.rangesWant or {cfg.whisperR, cfg.chatR, cfg.shoutR}
	UiPush()
	UiAlign("left middle")
	UiFont("regular.ttf", 22)
	UiColor(1, 1, 1, 0.85)
	UiPush(); UiTranslate(0, 14); UiText("Distances (host: for everyone) - drag a knob"); UiPop()
	UiPush()                                                          -- (Reset: the defaults; styled like the header button)
	UiAlign("left top")                                               -- (the rect, its click area and its text share one box,
	UiTranslate(bw - 110, -1)                                         --  centred on the label's line)
	local hoverR = c.typing and UiIsMouseInRect(110, 30)
	if c.typing and PC.clicked("rangeReset", 110, 30, hoverR) then
		local d = PC.defaultRanges or {8, 25, 40}
		c.rangesWant = {d[1], d[2], d[3]}
		ServerCall("server.pc_ranges", GetLocalPlayer(), d[1], d[2], d[3])
	end
	UiColor(1, 1, 1, hoverR and 0.2 or 0.1)
	UiRoundedRect(110, 30, 8)
	UiColor(1, 1, 1, 0.45)
	UiRoundedRectOutline(110, 30, 8, 1.5)
	UiTranslate(55, 15)
	UiAlign("center middle")
	UiFont("bold.ttf", 20)
	UiColor(1, 1, 1, 0.95)
	UiText("Reset")
	UiPop()
	UiTranslate(0, 50)                                                -- (the bar)
	UiAlign("left top")
	UiColor(1, 1, 1, 0.08)
	UiRect(bw, 12)
	for i = 3, 1, -1 do                                               -- (yell under speech under whisper)
		local k = PC.RANGE_KINDS[i]
		local r = vals[i]
		local col = k[2]
		UiColor(col[1], col[2], col[3], 0.25)
		UiRect(math.min(bw, r * (1 + cfg[k[3]]) / cfg.rangeMax * bw), 12)
		UiColor(col[1], col[2], col[3], 0.6)
		UiRect(math.min(bw, r / cfg.rangeMax * bw), 12)
	end
	for i, k in ipairs(PC.RANGE_KINDS) do                             -- (the knobs)
		UiPush()
		UiTranslate(vals[i] / cfg.rangeMax * bw - 8, -10)
		local hover = c.typing and UiIsMouseInRect(16, 32)
		if c.typing and not c.drag and PC.clicked("knob" .. i, 16, 32, hover) then
			c.drag, c.dragVals = i, {vals[1], vals[2], vals[3]}
		end
		local col = k[2]
		UiColor(0, 0, 0, 0.8)
		UiRoundedRect(16, 32, 5)
		UiTranslate(2, 2)
		UiColor(col[1], col[2], col[3], (hover or c.drag == i) and 1 or 0.85)
		UiRoundedRect(12, 28, 4)
		UiPop()
	end
	if c.drag then
		if c.typing and InputDown("lmb") then
			local mx = UiGetMousePos()
			local v = mx / bw * cfg.rangeMax
			local lo = c.drag == 1 and cfg.rangeMin or c.dragVals[c.drag - 1] + 1
			local hi = c.drag == 3 and cfg.rangeMax or c.dragVals[c.drag + 1] - 1
			c.dragVals[c.drag] = math.max(lo, math.min(hi, math.floor(v + 0.5)))
		else                                                          -- (let go: send it)
			local v = c.dragVals
			c.rangesWant = {v[1], v[2], v[3]}
			c.drag, c.dragVals = nil, nil
			ServerCall("server.pc_ranges", GetLocalPlayer(), v[1], v[2], v[3])
		end
	end
	UiTranslate(0, 30)                                                -- (what they are)
	UiFont("regular.ttf", 20)
	UiColor(1, 1, 1, 0.75)
	local function f(x) return string.format("%d", math.floor(x + 0.5)) end
	UiText(string.format("Whisper %s m (garbled to %s)    Speak %s m (to %s)    Yell %s m (to %s)",
		f(vals[1]), f(vals[1] * (1 + cfg.whisperBuf)), f(vals[2]), f(vals[2] * (1 + cfg.speakBuf)), f(vals[3]), f(vals[3] * (1 + cfg.shoutBuf))))
	UiPop()
end

function PC.drawWindow()
	local c, cfg = PC.C(), PC.cfg
	local W, H = cfg.winW, cfg.winH
	if c.page == "settings" and PC.isHost() then H = H + 150 end      -- (room for the host's walls row and distance bar)
	UiPush()
	UiTranslate(24, UiHeight() - 160 - H)
	UiAlign("left top")
	UiColor(0, 0, 0, 0.6)
	UiRoundedRect(W, H, 10)
	-- the header button first (a click switches the page this frame)
	UiPush()
	UiTranslate(W - 162, 10)
	local hover = c.typing and UiIsMouseInRect(150, 40)
	if c.typing and PC.clicked("header", 150, 40, hover) then PC.setPage(c.page == "settings" and "chat" or "settings") end
	local settings = c.page == "settings"
	UiColor(1, 1, 1, hover and 0.2 or 0.1)
	UiRoundedRect(150, 40, 8)
	UiColor(1, 1, 1, 0.45)
	UiRoundedRectOutline(150, 40, 8, 1.5)
	UiTranslate(75, 20)
	UiAlign("center middle")
	UiFont("bold.ttf", 22)
	UiColor(1, 1, 1, c.typing and 0.95 or 0.45)
	UiText(settings and "< Back" or "Settings")
	UiPop()
	UiPush()
	UiTranslate(16, 30)
	UiAlign("left middle")
	UiFont("bold.ttf", 24)
	UiColor(1, 1, 1, 0.9)
	UiText(settings and "Settings" or "Chat")
	UiPop()
	if not settings then
		UiPush()
		UiTranslate(W - 180, 30)
		UiAlign("right middle")
		UiFont("regular.ttf", 18)
		UiColor(1, 1, 1, 0.45)
		if c.typing then UiText("Wheel / PgUp: scroll")
		elseif PC.keyName() ~= "" then UiText(PC.keyName() .. ": close")
		else UiText("Enter: chat") end
		UiPop()
	end
	UiPush()
	UiTranslate(12, 56)
	UiColor(1, 1, 1, 0.12)
	UiRect(W - 24, 2)
	UiPop()
	if settings then PC.drawSettings(W, H) else PC.drawHistory(W, H) end
	UiPop()
end

-- window closed: the newest lines fade out in a feed
function PC.drawFeed()
	local c, cfg = PC.C(), PC.cfg
	local now = GetTime()
	UiPush()
	UiAlign("left top")
	UiTextShadow(0, 0, 0, 0.85, 1.5)
	local y = UiHeight() - 160
	local shown = 0
	for i = #c.hist, 1, -1 do
		if shown >= cfg.feedLines then break end
		local e = c.hist[i]
		if now - e.t >= cfg.life then break end
		local a = math.max(0, math.min(1, (cfg.life - (now - e.t)) / 1.5))
		y = y - PC.drawLine(e, cfg.winW, 28, a, true)
		UiPush()
		UiTranslate(30, y)
		PC.drawLine(e, cfg.winW, 28, a)
		UiPop()
		y = y - 8
		shown = shown + 1
	end
	UiPop()
end

-- the input line: the mode as the prompt, the field, the mode chips at the right end
function PC.drawTyping()
	local c, cfg = PC.C(), PC.cfg
	local W = cfg.winW
	local cw, chh, cg = 100, 34, 6
	local chipsW = #PC.MODES * cw + (#PC.MODES - 1) * cg
	UiPush()
	UiTranslate(24, UiHeight() - 146)
	UiAlign("left top")
	UiColor(0, 0, 0, 0.75)
	UiRoundedRect(W, 54, 8)
	-- the chips (first: a click changes the prompt this frame)
	UiPush()
	UiTranslate(W - 10 - chipsW, 10)
	for i, x in ipairs(PC.MODES) do
		local dim = (PC.lobby() and x[1] ~= "g") or PC.dead()
		UiPush()
		UiTranslate((i - 1) * (cw + cg), 0)
		local hover = (not dim) and UiIsMouseInRect(cw, chh)
		if not dim and PC.clicked("mode" .. x[1], cw, chh, hover) then PC.setMode(x[1]) end
		local on = x[1] == PC.mode()
		local cc = x[5]
		if on then UiColor(cc[1], cc[2], cc[3], 0.35) elseif hover then UiColor(1, 1, 1, 0.16) else UiColor(1, 1, 1, 0.07) end
		UiRoundedRect(cw, chh, 17)
		if on then UiColor(cc[1], cc[2], cc[3], 0.95); UiRoundedRectOutline(cw, chh, 17, 2) end
		UiTranslate(cw / 2, chh / 2)
		UiAlign("center middle")
		UiFont(on and "bold.ttf" or "regular.ttf", 18)
		UiColor(1, 1, 1, dim and 0.25 or (on and 1 or 0.65))
		UiText(x[3])
		UiPop()
	end
	UiPop()
	local m = PC.mode()
	local info = PC.dead() and PC.channelInfo(PC.channelOf(GetLocalPlayer())) or PC.modeInfo(m)
	local col = info[5]
	UiColor(col[1], col[2], col[3], 0.95)
	UiRoundedRectOutline(W, 54, 8, 2)
	local label = info[2]
	UiFont("bold.ttf", 28)
	local lw = UiGetTextSize(label) or 160
	UiPush()
	UiTranslate(14, 27)
	UiAlign("left middle")
	UiText(label)
	UiPop()
	UiTranslate(14 + lw, 0)
	UiColor(1, 1, 1, 1)
	UiFont(PC.chatFont(c.text), 28)
	PC.field(W - 38 - lw - chipsW, 54)
	UiPop()
	UiPush()
	UiTranslate(30, UiHeight() - 86)
	UiAlign("left top")
	UiFont("regular.ttf", 18)
	UiColor(1, 1, 1, 0.5)
	UiText(PC.dead() and "Enter: say it (only the dead hear you)   Esc: close   Settings: your voice and more   /help"
		or PC.lobby() and "Enter: say it   Esc: close   Settings: your voice and more   /help"
		or "Enter: say it   Tab / chips: Whisper, Speak, Yell, Global   Esc: close   Settings: your voice and more   /help")
	UiPop()
	-- the character limit: a count once it gets close, red when full
	local n = PC.utf8Len(c.text)
	if n >= cfg.countFrom then
		UiPush()
		UiTranslate(24 + W, UiHeight() - 86)
		UiAlign("right top")
		UiFont("bold.ttf", 20)
		if n >= cfg.maxLen then UiColor(1, 0.35, 0.3, 1) else UiColor(1, 1, 1, 0.7) end
		UiText(n .. "/" .. cfg.maxLen)
		UiPop()
	end
end

function PC.drawHint()
	local c, cfg = PC.C(), PC.cfg
	if c.hideHint then return end
	local intro = GetTime() - c.t0 < cfg.hintIntro
	local key = PC.keyName() ~= "" and ("   " .. PC.keyName() .. ": chat window") or ""
	UiPush()
	UiTranslate(30, UiHeight() - 136)
	UiAlign("left top")
	UiTextShadow(0, 0, 0, 0.6, 1)
	if intro then
		UiFont("regular.ttf", 22)
		UiColor(1, 1, 1, 0.8)
		UiText("Proximity Babble Chat - Enter: talk to players near you (Tab: Whisper / Speak / Yell / Global)" .. key .. "   /help   (hide: /hint)")
	else
		UiFont("regular.ttf", 18)
		UiColor(1, 1, 1, 0.35)
		UiText("Enter: chat" .. key)
	end
	UiPop()
end

function PC.draw()
	local c = PC.C()
	PC.preKeys()
	UiPush()
	PC.drawBubbles()
	UiPush()
	UiTranslate(0, UiHeight())                                          -- (the chat UI scales from the bottom-left corner)
	UiScale(PC.cfg.uiScale)
	UiTranslate(0, -UiHeight())
	if PC.windowOpen() then PC.drawWindow() else PC.drawFeed() end
	if c.typing then PC.drawTyping() else PC.drawHint() end
	UiPop()
	UiPop()
	PC.keys()
end
