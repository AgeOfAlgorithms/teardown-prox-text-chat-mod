-- chat_core.lua - Proximity Chat for Teardown v2 multiplayer: text chat with two channels, speech
-- bubbles and an Animal-Crossing-style "babble" voice. Works in any level / game mode; reusable by
-- #include in other mods. Source of truth: teardown-mods/proxchat/mods/proximity chat/chat_core.lua.
--
-- CHANNELS
--   Proximity ("p", the default): a speech bubble over the speaker's head and a babble voice played in
--     3D at the speaker (quieter and echoing with distance). Only players within cfg.chatR (20 m) hear
--     it; ALL-CAPS words or a word ending in "!!" are shouted and reach cfg.shoutR (45 m), where only
--     the shouted words get through ("HELP ... NOW").
--     Each client decides what IT heard from the distance at the moment the message arrives and keeps
--     that in its own Proximity history, so every player has a different Proximity history.
--   Global ("g"): everyone gets the line, no bubble. Its babble is short, quiet and plays at the
--     listener (not in the world: the speaker can be anywhere, and a 3D sound from far away would be
--     silent or misleading); /mute turns it off.
--   Lobby (PC.hooks.inLobby() true on the server): everything said is Global.
--
-- THE WINDOW: Enter opens a line AND the chat window (interactive: mouse cursor, clickable tabs); Enter
--   says it, Esc closes both. Three tabs: Proximity, Global, Voice. Tab (or a click on a tab header)
--   goes to the next tab; on Proximity / Global it also picks the channel you send to ("Say (nearby):"
--   / "Say (everyone):"); the Voice tab lists the voices as buttons (yours highlighted): a click picks
--   one (synced so others hear it, saved as your default, a short preview only you hear) and keeps the
--   channel you were typing in. Wheel / PgUp / PgDn scroll. With the window closed the newest lines
--   fade out in a feed. No other hotkeys: /window pins the window open (read-only while not typing);
--   a mod that wants a hotkey for that sets PC.cfg.windowKey (default none).
--   Clicks fire on the mouse PRESS (UiIsMouseInRect + InputPressed("lmb")), with UiBlankButton (fires
--   on release) as a fallback and de-duplicated: one click is one pick (UiBlankButton alone missed
--   clicks in-game in Tall Order's lobby).
-- COMMANDS (echoed locally): /voice [name|number], /g <text>, /p <text>, /mute, /hint, /window,
--   /clear, /help, //text sends "/text".
--
-- API (every name lives in the PC table; ServerCall targets are server.pc_*; shared keys are pc*;
-- registry keys proxchat.*; persistent settings savegame.mod.pc*)
--   #include "chat_core.lua"          in a #version 2 script; copy snd/ (babble0-7, shout0-7, robot0-3)
--   PC.cfg.<key> = value              optional overrides, set before PC.serverInit / PC.clientInit
--                                     (keys: see the defaults below, e.g. chatR, shoutR, windowKey, sndDir)
--   PC.serverInit()                   in server.init
--   PC.serverTick(dt)                 in server.tick
--   PC.clientInit()                   in client.init
--   PC.clientTick(dt)                 in client.tick (receives messages, plays the babble)
--   PC.draw()                         in client.draw (bubbles, window / feed, typing line, keys)
--   PC.isTyping(p)                    server: any player; client: the local player. Skip your own keys
--                                     while it is true. Other scripts: GetBool("proxchat.typing." .. p)
--   PC.say(text, ch)                  client: say something as the local player (ch "p" or "g")
--   PC.system(text)                   client: a local line in the current tab (only this player sees it)
--   PC.history(ch)                    client: the local history of "p" or "g" (entries: name, text, p,
--                                     ch, shout, far, sys, t); bounded to cfg.keepHist
--   PC.setVoice(i)                    client: pick voice i of PC.VOICES for the local player (synced,
--                                     saved, previewed) - what a click in the Voice tab does
--   PC.view() / PC.setView(v)         client: the window tab, "p" / "g" / "v"
--   PC.clicked(id, w, h)              client: a press-firing, de-duplicated click on a w x h rect at the
--                                     cursor (for your own buttons while UiMakeInteractive is on)
--   Hooks (all optional; define them in PC.hooks):
--   PC.hooks.inLobby()                server: true = everyone hears everything (Global only)
--   PC.hooks.everyoneHears(speaker)   client: true = the local player hears this speaker's proximity
--                                     messages in full wherever they are (spectators, radios...)
--   PC.hooks.blockKeys()              client: true = Enter (and cfg.windowKey) do nothing
--   PC.hooks.onMessage(msg, heard)    client: a message arrived; heard = what was heard or nil
--   PC.hooks.log(line)                server: diagnostics
--
-- Engine notes (see the teardown-modding skill, "Multiplayer social features"):
--   - Text entry is the engine's UiTextInput used as a real field (pass the current text, focus = true
--     for one frame, get the edited text back). Verified in-game in Tall Order.
--   - On clients every read of `shared` hands out a fresh copy: never compare shared tables by
--     identity; messages are matched by id, and each tick reads shared.pcMsgs once.
--   - Text is UTF-8: counted, cased and cut as characters; fonts per script; Arabic shaped, RTL laid out.

PC = PC or {}
PC.cfg = PC.cfg or {}
PC.hooks = PC.hooks or {}

do
	local defaults = {
		chatR = 20,              -- m: who hears you (proximity)
		shoutR = 45,             -- m: who hears your shouted words
		life = 9,                -- s a bubble / a feed line stays
		maxLen = 90,             -- characters per message
		keepShared = 30,         -- messages in shared.pcMsgs
		sharedLife = 12,         -- s a message stays in shared (clients copy it on arrival)
		keepHist = 50,           -- lines per local history tab
		rate = 0.45,             -- s between two messages of one player
		sndDir = "MOD/snd/",
		windowKey = "",          -- a hotkey that pins the chat window ("" = none; /window does it)
		reg = "proxchat",        -- registry prefix
		save = "savegame.mod.pc",-- persistent settings: pcvoice, pchidehint, pcmuteglobal
		babbleMax = 45,          -- syllables per message
		babbleVol = 0.75,
		globalVol = 0.35,        -- Global babble: this much of the voice's volume, at the listener
		globalMaxSyl = 14,       -- Global babble: at most this many syllables
		echoFrom = 6,            -- m: farther voices echo
		winW = 900, winH = 400,  -- the chat window
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
PC.BABBLE_SETS = {voice = 8, shout = 8, robot = 4}
PC.CLIP_FILE = {voice = "babble", shout = "shout", robot = "robot"}

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

-- a word is shouted: 2+ cased letters and none lower case, or (any script) it ends in "!!" / "！！"
function PC.isShout(w)
	if w:find("!!%s*$") or w:find("\239\188\129\239\188\129%s*$") then return true end
	local n, low = 0, false
	for ch in w:gmatch(PC.UTF8_CHAR) do
		local k = PC.utf8Case(ch)
		if k == "upper" or k == "lower" then n = n + 1 end
		if k == "lower" then low = true end
	end
	return n >= 2 and not low
end

-- the shouted words of a message (heard farther)
function PC.shoutWords(text)
	local out = {}
	for w in text:gmatch("%S+") do
		if PC.isShout(w) then out[#out + 1] = w end
	end
	return out
end

-- sanitize: ASCII control bytes only (never %c: it would eat UTF-8), trimmed, cfg.maxLen characters
function PC.clean(text)
	if type(text) ~= "string" then return "" end
	text = text:gsub("[%z\1-\31\127]", " ")
	text = text:gsub("^%s+", "")
	text = text:gsub("%s+$", "")
	return PC.utf8Head(text, PC.cfg.maxLen)
end

-- ---- display: which of the game's fonts has this text's script
function PC.scriptOf(c)
	if c < 0x250 or (c >= 0x1E00 and c <= 0x1EFF) or (c >= 0x370 and c <= 0x52F) then return "base" end
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
function PC.serverInit()
	PC.s = {time = 0, typing = {}, last = {}, n = 0, pruneT = 0, lobby = false}
	ClearKey(PC.cfg.reg)
	shared.pcMsgs = {}
	shared.pcVoice = {}
	shared.pcTyping = {}
	shared.pcLobby = false
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

-- a player says something: sanitized, rate-limited, then published (whole table: one sync)
function server.pc_say(p, ch, text)
	local s = PC.S()
	p = tonumber(p)
	if not p then return end
	text = PC.clean(text)
	if text == "" then return end
	ch = (ch == "g" or PC.inLobby()) and "g" or "p"
	if s.time - (s.last[p] or -10) < PC.cfg.rate then return end              -- (no spamming)
	s.last[p] = s.time
	s.n = s.n + 1
	local list = {}
	for _, m in ipairs(shared.pcMsgs or {}) do
		if s.time - m.t < PC.cfg.sharedLife then list[#list + 1] = m end
	end
	local name = GetPlayerName(p)
	if type(name) ~= "string" or name == "" then name = "Player " .. p end
	list[#list + 1] = {id = s.n, p = p, name = name, ch = ch, text = text, t = s.time}
	while #list > PC.cfg.keepShared do table.remove(list, 1) end
	shared.pcMsgs = list
	PC.log(string.format("proxchat say p=%d ch=%s len=%d", p, ch, #text))
end

function PC.publishTyping()
	local t = {}
	for p, ch in pairs(PC.S().typing) do t[p] = ch end
	shared.pcTyping = t
end

-- typing state (the server ignores your mod keys meanwhile; the "..." over your head for proximity)
function server.pc_typing(p, on, ch)
	local s = PC.S()
	p = tonumber(p)
	if not p then return end
	s.typing[p] = on and (ch == "g" and "g" or "p") or nil
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
	for _, p in ipairs(PC.removedPlayers()) do
		s.last[p] = nil
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
		hist = {g = {}, p = {}}, n = 0, seen = 0, channel = "p", typing = false, text = "", focus = false,
		pinned = false, unread = {g = 0, p = 0}, bubbles = {}, scroll = 0, t0 = GetTime(),
		hideHint = GetBool(cfg.save .. "hidehint"), muteGlobal = GetBool(cfg.save .. "muteglobal"),
		voiceTries = 0, voiceT = 0,
		babble = {clips = {}, queue = {}, echoes = {}},
		view = "p",                                                 -- the window tab: "p", "g" or "v"
	}
	local v = GetInt(cfg.save .. "voice")
	if PC.VOICES[v] then c.voiceWant = v end                    -- (the Mod Manager option / last /voice)
	for set, n in pairs(PC.BABBLE_SETS) do
		c.babble.clips[set] = {}
		for i = 1, n do c.babble.clips[set][i] = LoadSound(cfg.sndDir .. PC.CLIP_FILE[set] .. (i - 1) .. ".ogg") end
	end
	PC.c = c
	-- joining: recent Global lines go into the history; proximity talk from before you came is not heard
	for _, m in ipairs(shared.pcMsgs or {}) do
		if m.id > c.seen then c.seen = m.id end
		if m.ch == "g" then PC.addHist("g", {p = m.p, name = m.name, text = m.text, shout = #PC.shoutWords(m.text) > 0}, true) end
	end
end

function PC.C()
	if not PC.c then PC.clientInit() end
	return PC.c
end

function PC.lobby() return shared.pcLobby == true end

-- the channel the local player types in
function PC.channel()
	if PC.lobby() then return "g" end
	return PC.C().channel
end

-- the window tab: "p" / "g" (the channel's history) or "v" (the voices). In the lobby "p" shows as "g".
function PC.view()
	local v = PC.C().view
	if v == "v" then return "v" end
	return PC.channel()
end

PC.VIEWS = {"p", "g", "v"}

function PC.setView(v)
	local c = PC.C()
	if v == "v" then
		c.view = "v"
		c.scroll = 0
	elseif v == "p" or v == "g" then
		if PC.lobby() and v == "p" then return end
		c.view = v
		PC.setChannel(v)
	end
end

-- Tab: Proximity -> Global -> Voice -> Proximity (the lobby skips Proximity)
function PC.nextView()
	local cur = PC.view()
	local order = PC.lobby() and {"g", "v"} or PC.VIEWS
	local k = 1
	for i, v in ipairs(order) do if v == cur then k = i end end
	PC.setView(order[k % #order + 1])
end

function PC.windowOpen()
	local c = PC.C()
	return c.typing or c.pinned
end

function PC.history(ch) return PC.C().hist[ch] end

-- add a line to a local history tab (bounded); quiet = no unread count
function PC.addHist(ch, e, quiet)
	local c = PC.C()
	c.n = c.n + 1
	e.n = c.n
	e.ch = ch
	e.t = e.t or GetTime()
	local h = c.hist[ch]
	h[#h + 1] = e
	while #h > PC.cfg.keepHist do table.remove(h, 1) end
	local viewing = PC.windowOpen() and PC.view() == ch
	if viewing and c.scroll > 0 then c.scroll = math.min(c.scroll + 1, #h - 1) end   -- (the view stays put)
	if not quiet and not viewing then c.unread[ch] = c.unread[ch] + 1 end
end

-- a local line only this player sees (command results)
function PC.system(text)
	PC.addHist(PC.channel(), {sys = true, text = text}, true)
end

function PC.distTo(p)
	local ok1, a = pcall(GetPlayerTransform, GetLocalPlayer())
	local ok2, b = pcall(GetPlayerTransform, p)
	if not (ok1 and ok2 and a and b and a.pos and b.pos) then return nil end
	return VecLength(VecSub(a.pos, b.pos))
end

-- what the local player hears of p's proximity message NOW: all of it (yourself, within chatR), only
-- the shouted words (within shoutR; far = true), or nothing (nil)
function PC.heard(p, text)
	if p == GetLocalPlayer() then return text, false end
	if PC.hooks.everyoneHears and PC.hooks.everyoneHears(p) then return text, false end
	local d = PC.distTo(p)
	if not d then return nil end
	if d <= PC.cfg.chatR then return text, false end
	if d <= PC.cfg.shoutR then
		local sw = PC.shoutWords(text)
		if #sw > 0 then return table.concat(sw, " ... "), true end
	end
	return nil
end

-- a new message from the server: each client records what it heard, now
function PC.receive(m)
	local c = PC.C()
	local me = GetLocalPlayer()
	local heard, far
	if m.ch == "g" then
		heard = m.text
		PC.addHist("g", {p = m.p, name = m.name, text = m.text, shout = #PC.shoutWords(m.text) > 0, me = m.p == me})
		if m.p == me or not c.muteGlobal then PC.babbleSay(m.p, m.text, nil, true) end
	else
		heard, far = PC.heard(m.p, m.text)
		if heard then
			local shout = #PC.shoutWords(heard) > 0
			PC.addHist("p", {p = m.p, name = m.name, text = heard, shout = shout, far = far, me = m.p == me})
			c.bubbles[m.p] = {text = heard, t = GetTime(), shout = shout}
			PC.babbleSay(m.p, heard)
		end
	end
	if PC.hooks.onMessage then PC.hooks.onMessage(m, heard) end
end

function PC.clientTick(dt)
	local c = PC.C()
	local me = GetLocalPlayer()
	local now = GetTime()
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
	for p, b in pairs(c.bubbles) do
		if now - b.t > PC.cfg.life then c.bubbles[p] = nil end
	end
	PC.babbleTick()
end

-- ---- the babble voice (Animal Crossing style)
function PC.voiceOf(p)
	local c = PC.c
	if c and c.voiceWant and p == GetLocalPlayer() then return c.voiceWant end
	local v = (shared.pcVoice or {})[p]
	if v and PC.VOICES[v] then return v end
	return (p * 37) % 5 + 1                                       -- (no pick yet: one of the first five)
end

-- a message as syllables: {variant hash, pause after, pitch factor, shouted}; second result: has "!"
function PC.babbleSyllables(text)
	local caps = {}                                               -- byte index -> in a shouted word
	for s0, w in text:gmatch("()(%S+)") do
		if PC.isShout(w) then
			for k = s0, s0 + #w - 1 do caps[k] = true end
		end
	end
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
			pair, angry = ch, caps[i] or false
			flush(0)
		elseif k == "letter" then                                 -- other scripts: two letters a syllable
			pair = pair .. ch:lower()
			nch = nch + 1
			angry = angry or caps[i] or false
			if nch >= 2 then flush(0); nch = 0 end
		elseif k == "space" then flush(0.05); nch = 0
		elseif k == "pause" then flush(0.16); nch = 0 end
		if #out >= PC.cfg.babbleMax then break end
	end
	flush(0)
	if text:find("%?%s*$") or text:find("\239\188\159%s*$") or text:find("\216\159%s*$") then   -- ? / ？ / ؟ rises
		for k = math.max(1, #out - 2), #out do out[k][3] = 1 + 0.08 * (k - #out + 3) end
	end
	return out, text:find("!") ~= nil
end

-- start babbling text for player p. flat = at the listener (Global, previews), short and quiet
function PC.babbleSay(p, text, voice, flat)
	local B = PC.C().babble
	local cfg = PC.cfg
	local v = PC.VOICES[voice or PC.voiceOf(p)] or PC.VOICES[3]
	local syl, loud = PC.babbleSyllables(text)
	if flat then while #syl > cfg.globalMaxSyl do table.remove(syl) end end
	local vol = (loud and 1 or cfg.babbleVol) * v[5]
	local shoutVol = v[5]
	if flat then vol, shoutVol = vol * cfg.globalVol, shoutVol * cfg.globalVol end
	B.queue[p] = {syl = syl, k = 1, nextT = GetTime(), pitch = v[2], step = v[3], set = v[4], vol = vol, shoutVol = shoutVol, flat = flat}
end

-- farther voices: quieter (on top of the engine's 3D falloff) and echoing. No reverb API: the echo is
-- 1-3 delayed, fainter repeats of each syllable from a few metres beside the speaker.
function PC.babbleDistance(pos, vol)
	local cfg = PC.cfg
	local cam = GetCameraTransform().pos
	local d = VecLength(VecSub(pos, cam))
	local f = math.max(0, math.min(1, (d - cfg.echoFrom) / (cfg.shoutR - cfg.echoFrom)))
	local echoes = {}
	if f > 0.05 then
		local n = f > 0.55 and 3 or (f > 0.2 and 2 or 1)
		local away = VecNormalize(VecSub(pos, cam))
		for k = 1, n do
			local side = VecNormalize(VecCross(away, Vec(0, 1, 0)))
			local offset = VecAdd(VecScale(side, (math.random() < 0.5 and -1 or 1) * (2 + 4 * math.random())), VecScale(away, 3 + 3 * k))
			echoes[k] = {delay = k * (0.08 + 0.14 * f), vol = vol * (0.25 + 0.35 * f) * 0.6 ^ (k - 1), offset = offset}
		end
	end
	return vol * (1 - 0.5 * f), echoes
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
			local s = q.syl[q.k]
			if not s then
				B.queue[p] = nil
			else
				local pos
				if q.flat then
					pos = GetCameraTransform().pos
				else
					local okT, tr = pcall(GetPlayerTransform, p)
					if okT and tr and tr.pos then pos = VecAdd(tr.pos, Vec(0, 1.7, 0)) end
				end
				if pos then
					local set = (s[4] and q.set == "voice") and "shout" or q.set
					local clips = B.clips[set]
					local clip = clips[s[1] % #clips + 1]
					local jitter = s[4] and (1.04 + 0.16 * math.random()) or (0.94 + 0.12 * math.random())
					local pitch = q.pitch * s[3] * jitter
					local base = s[4] and q.shoutVol or q.vol
					if q.flat then
						PlaySound(clip, pos, base, false, pitch)
					else
						local vol, echoes = PC.babbleDistance(pos, base)
						PlaySound(clip, pos, vol, false, pitch)
						for _, e in ipairs(echoes) do
							B.echoes[#B.echoes + 1] = {t = now + e.delay, clip = clip, pos = VecAdd(pos, e.offset), vol = e.vol, pitch = pitch * 0.97}
						end
					end
				end
				q.k = q.k + 1
				q.nextT = now + q.step * (s[4] and 0.85 or 1) + s[2]
			end
		end
	end
end

-- ---- typing, channels, commands
function PC.setTyping(on)
	local c = PC.C()
	c.typing = on and true or false
	c.text, c.send, c.tab, c.scroll = "", nil, nil, 0
	c.focus = c.typing
	if c.typing then
		c.view = c.channel                                          -- (opens on the tab you type in)
		c.unread[PC.channel()] = 0
	end
	ServerCall("server.pc_typing", GetLocalPlayer(), c.typing, PC.channel())
end

-- the channel you send to (the window shows its tab)
function PC.setChannel(ch)
	local c = PC.C()
	if PC.lobby() then return end                                   -- (the lobby is Global only)
	if ch ~= "g" then ch = "p" end
	c.view = ch
	c.unread[ch] = 0
	if c.channel == ch then return end
	c.channel = ch
	c.scroll = 0
	if c.typing then ServerCall("server.pc_typing", GetLocalPlayer(), true, ch) end
end

function PC.scrollBy(n)
	local c = PC.C()
	local h = c.hist[PC.view()]
	if not h then return end
	c.scroll = math.max(0, math.min(math.max(0, #h - 1), c.scroll + n))
end

function PC.say(text, ch)
	text = PC.clean(text)
	if text == "" then return end
	ServerCall("server.pc_say", GetLocalPlayer(), ch or PC.channel(), text)
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
	PC.babbleSay(GetLocalPlayer(), "Hello there, how are you?", i, true)   -- (a preview, only for you)
end

-- the optional window hotkey (PC.cfg.windowKey, default none), upper case for hints
function PC.keyName()
	return (PC.cfg.windowKey or ""):upper()
end

-- a click on a w x h rect at the cursor (align left top). Fires on the mouse PRESS; UiBlankButton
-- (which fires on release) is the fallback, and the release of a click whose press already fired for
-- the same id is ignored, so one click is one action.
function PC.clicked(id, w, h, inside)
	local c = PC.C()
	if inside == nil then inside = UiIsMouseInRect(w, h) end      -- (pass it when you already asked)
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

function PC.command(text)
	local c = PC.C()
	local cmd, rest = text:match("^/(%S*)%s*(.-)%s*$")
	cmd, rest = (cmd or ""):lower(), rest or ""
	if cmd == "voice" or cmd == "v" then
		if rest == "" then
			local names = {}
			for i, v in ipairs(PC.VOICES) do names[i] = i .. " " .. v[1] end
			PC.system("Voices: " .. table.concat(names, ", ") .. ". Yours: " .. PC.VOICES[PC.voiceOf(GetLocalPlayer())][1] .. ". Type /voice <name> or pick one in the Voice tab (Tab).")
		else
			local i = PC.findVoice(rest)
			if not i then
				PC.system("No voice called \"" .. rest .. "\". Type /voice to list them.")
			else
				PC.setVoice(i)
				PC.system("Your voice is now " .. PC.VOICES[i][1] .. ".")
			end
		end
	elseif cmd == "g" or cmd == "a" or cmd == "all" or cmd == "global" then
		if rest ~= "" then PC.say(rest, "g") else PC.setChannel("g"); PC.system("You now talk to everyone (Global).") end
	elseif cmd == "p" or cmd == "n" or cmd == "l" or cmd == "near" or cmd == "nearby" or cmd == "local" or cmd == "proximity" then
		if PC.lobby() then PC.system("In the lobby everyone hears everything.")
		elseif rest ~= "" then PC.say(rest, "p")
		else PC.setChannel("p"); PC.system("You now talk to players near you (Proximity).") end
	elseif cmd == "mute" then
		c.muteGlobal = not c.muteGlobal
		SetBool(PC.cfg.save .. "muteglobal", c.muteGlobal)
		PC.system(c.muteGlobal and "Global messages are silent now (no babble). /mute again to hear them." or "Global messages babble again.")
	elseif cmd == "hint" then
		c.hideHint = not c.hideHint
		SetBool(PC.cfg.save .. "hidehint", c.hideHint)
		PC.system(c.hideHint and "Hint hidden. /hint shows it again." or "Hint shown.")
	elseif cmd == "window" or cmd == "w" then
		c.pinned = not c.pinned
		PC.system(c.pinned and "The chat window stays open (Enter to use it). /window again to close it." or "The chat window closes when you stop typing.")
	elseif cmd == "clear" then
		c.hist[PC.channel()] = {}
		c.scroll = 0
	elseif cmd == "help" or cmd == "h" or cmd == "?" then
		local key = PC.keyName() ~= "" and (PC.keyName() .. ": chat window. ") or ""
		PC.system("Enter: chat + window. Tab: Proximity / Global / Voice tab. " .. key .. "CAPS or a word ending in !! shouts (heard farther).")
		PC.system("/voice [name]   /g <text> everyone   /p <text> nearby   /mute   /hint   /window (keep open)   /clear")
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
	PC.say(text, PC.channel())
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

-- keys that change what is drawn (before drawing, so this frame already shows it): Tab, scrolling,
-- the optional window hotkey (never while typing: then letters go into the line)
function PC.preKeys()
	local c = PC.C()
	if c.typing then
		UiMakeInteractive()
		if InputPressed("tab") then PC.nextView() end
		local wheel = InputValue and InputValue("mousewheel") or 0
		if wheel > 0 then PC.scrollBy(1) elseif wheel < 0 then PC.scrollBy(-1) end
		if InputPressed("pgup") then PC.scrollBy(4) elseif InputPressed("pgdown") then PC.scrollBy(-4) end
	elseif not (PC.hooks.blockKeys and PC.hooks.blockKeys()) then
		local wk = (PC.cfg.windowKey or ""):lower()
		if wk ~= "" and InputPressed(wk) then
			c.pinned = not c.pinned
			c.scroll = 0
			if c.pinned then c.view = c.channel; c.unread[PC.channel()] = 0 end
		end
	end
end

-- keys after the field (it may have taken Enter / Tab): Enter opens / says it, Esc cancels
function PC.keys()
	local c = PC.C()
	if c.typing then
		UiMakeInteractive()
		if c.tab and not InputPressed("tab") then PC.nextView() end   -- (once: preKeys took a Tab key press)
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
local function pcLinePrefix(e, tag)
	if e.sys then return "" end
	return (e.name or "?") .. ((tag and e.ch == "g") and " (all)" or "") .. ": "
end

-- one history line at the cursor (align left top); returns its height. tag: mark Global lines (feed)
function PC.drawLine(e, w, size, a, tag, measureOnly)
	UiPush()
	UiWordWrap(w)
	local prefix = pcLinePrefix(e, tag)
	local pw = prefix ~= "" and PC.textWidth(prefix, size) or 0
	local tw = math.max(120, w - pw)
	UiFont(PC.chatFont(e.text, true), size)
	UiWordWrap(tw)
	local vis = PC.chatVisual(e.text)
	local _, th = UiGetTextSize(vis)
	th = math.max(th or size, size)
	if not measureOnly then
		if prefix ~= "" then
			if e.ch == "g" then UiColor(0.55, 0.8, 1, a) else UiColor(1, 0.82, 0.3, a) end
			PC.text(prefix, size)
			UiTranslate(pw, 0)
		end
		if e.sys then UiColor(0.6, 0.95, 0.85, a)
		elseif e.shout then UiColor(1, 0.45, 0.35, a)
		elseif e.far then UiColor(0.85, 0.85, 0.85, 0.8 * a)
		else UiColor(1, 1, 1, a) end
		UiFont(PC.chatFont(e.text, true), size)
		UiWordWrap(tw)
		UiText(vis)
	end
	UiPop()
	return th
end

-- a speech bubble over player p (small: the "..." of someone typing)
function PC.bubble(p, text, shout, a, small)
	local okT, tr = pcall(GetPlayerTransform, p)
	if not (okT and tr and tr.pos) then return end
	local x, y, d = UiWorldToPixel(VecAdd(tr.pos, Vec(0, 2.25, 0)))
	if not (d and d > 0) then return end
	UiPush()
	UiTranslate(x, y)
	if shout then UiTranslate(math.random(-2, 2), math.random(-2, 2)) end      -- (shaking with anger)
	UiScale(math.max(0.55, math.min(1.1, 9 / math.max(1, d))) * (shout and 1.15 or 1) * (small and 0.8 or 1))
	UiFont(PC.chatFont(text), 30)
	local vis = PC.chatVisual(text)
	UiWordWrap(640)
	local tw, th = UiGetTextSize(vis)
	local w = math.min(640, tw or 200) + 30
	local h = (th or 28) + 22
	UiAlign("left top")
	UiTranslate(-w / 2, -h - 14)
	UiColor(1, 1, 1, 0.92 * a)
	UiRoundedRect(w, h, 10)
	UiPush(); UiTranslate(w / 2 - 9, h); UiRotate(45); UiRect(13, 13); UiPop()   -- the tail
	if shout then UiColor(0.9, 0.1, 0.05, a); UiRoundedRectOutline(w, h, 10, 4) end
	UiTranslate(15, 11)
	UiColor(shout and 0.6 or 0.08, 0.05, shout and 0.03 or 0.1, a)
	UiText(vis)
	UiPop()
end

function PC.drawBubbles()
	local c, cfg = PC.C(), PC.cfg
	local now = GetTime()
	local me = GetLocalPlayer()
	local third = GetBool("game.thirdperson")
	for p, b in pairs(c.bubbles) do
		if p ~= me or third then PC.bubble(p, b.text, b.shout, math.max(0, math.min(1, (cfg.life - (now - b.t)) / 1.2))) end
	end
	for p, ch in pairs(shared.pcTyping or {}) do
		if ch == "p" and p ~= me and not c.bubbles[p] then
			local d = PC.distTo(p)
			if d and d <= cfg.chatR then PC.bubble(p, "...", false, 0.75, true) end
		end
	end
end

-- the Voice tab: the voices as buttons, yours highlighted; a click picks one (while typing: the window
-- is interactive then)
function PC.drawVoices(W, H)
	local c = PC.C()
	local cur = PC.voiceOf(GetLocalPlayer())
	local bw, bh, gap = 280, 64, 12
	UiPush()
	UiTranslate(14, 66)
	UiFont("regular.ttf", 22)
	UiColor(1, 1, 1, 0.85)
	UiText("Your voice: " .. PC.VOICES[cur][1] .. " - everyone hears your messages babble in it.")
	UiTranslate(0, 40)
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
		UiFont("bold.ttf", 28)
		UiColor(1, 1, 1, on and 1 or 0.75)
		UiText(v[1])
		UiPop()
	end
	UiTranslate(0, 2 * (bh + gap) + 8)
	UiFont("regular.ttf", 18)
	UiColor(1, 1, 1, 0.5)
	UiText(c.typing and "Click a voice to pick it (you hear a preview; saved as your default). Or type /voice <name>."
		or "Press Enter, then click a voice. Or type /voice <name>.")
	UiPop()
end

-- the chat window: tabs Proximity / Global / Voice; the history of the tab's channel, or the voices
function PC.drawWindow()
	local c, cfg = PC.C(), PC.cfg
	local view = PC.view()
	local W, H = cfg.winW, cfg.winH
	UiPush()
	UiTranslate(24, UiHeight() - 160 - H)
	UiAlign("left top")
	UiColor(0, 0, 0, 0.6)
	UiRoundedRect(W, H, 10)
	local tabs = {{"p", "Proximity"}, {"g", "Global"}, {"v", "Voice"}}
	for i, t in ipairs(tabs) do
		local on = view == t[1]
		local dim = PC.lobby() and t[1] == "p"
		UiPush()
		UiTranslate(12 + (i - 1) * 190, 10)
		local hover = c.typing and not dim and UiIsMouseInRect(180, 40)
		if c.typing and not dim and PC.clicked("tab" .. t[1], 180, 40, hover) then PC.setView(t[1]) end
		if on then UiColor(1, 0.82, 0.3, 0.25) elseif hover then UiColor(1, 1, 1, 0.14) else UiColor(1, 1, 1, 0.07) end
		UiRoundedRect(180, 40, 8)
		if on then UiColor(1, 0.82, 0.3, 0.9); UiRoundedRectOutline(180, 40, 8, 2) end
		UiTranslate(90, 20)
		UiAlign("center middle")
		UiFont("bold.ttf", 24)
		UiColor(1, 1, 1, dim and 0.3 or (on and 1 or 0.6))
		local label = t[2]
		if not on and c.unread[t[1]] and c.unread[t[1]] > 0 then label = label .. " (" .. c.unread[t[1]] .. ")" end
		UiText(label)
		UiPop()
	end
	view = PC.view()                                              -- (a click may have changed it)
	UiPush()
	UiTranslate(W - 14, 30)
	UiAlign("right middle")
	UiFont("regular.ttf", 18)
	UiColor(1, 1, 1, 0.45)
	if c.typing then UiText("Tab: next tab   Wheel: scroll")
	elseif PC.keyName() ~= "" then UiText(PC.keyName() .. ": close") end
	UiPop()
	if view == "v" then
		PC.drawVoices(W, H)
		UiPop()
		return
	end
	local ch = view
	c.unread[ch] = 0
	local h = c.hist[ch]
	local top, y, w = 62, H - 12, W - 28
	if #h == 0 then
		UiPush()
		UiTranslate(14, top + 6)
		UiFont("regular.ttf", 22)
		UiColor(1, 1, 1, 0.45)
		UiText(ch == "p" and ("Nothing heard nearby yet. Players within " .. cfg.chatR .. " m hear you; CAPS carry to " .. cfg.shoutR .. " m.") or "No messages to everyone yet.")
		UiPop()
	end
	for i = #h - c.scroll, 1, -1 do
		local e = h[i]
		local lh = PC.drawLine(e, w, 24, 1, false, true)
		if y - lh < top then break end
		y = y - lh
		UiPush()
		UiTranslate(14, y)
		PC.drawLine(e, w, 24, 1, false)
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
	UiPop()
end

-- window closed: the newest lines of both tabs fade out in a feed
function PC.drawFeed()
	local c, cfg = PC.C(), PC.cfg
	local now = GetTime()
	local items = {}
	for _, ch in ipairs({"p", "g"}) do
		for _, e in ipairs(c.hist[ch]) do
			if now - e.t < cfg.life then items[#items + 1] = e end
		end
	end
	table.sort(items, function(a, b) return a.n < b.n end)
	UiPush()
	UiAlign("left top")
	UiTextShadow(0, 0, 0, 0.85, 1.5)
	local y = UiHeight() - 160
	local shown = 0
	for i = #items, 1, -1 do
		if shown >= cfg.feedLines then break end
		local e = items[i]
		local a = math.max(0, math.min(1, (cfg.life - (now - e.t)) / 1.5))
		y = y - PC.drawLine(e, cfg.winW, 28, a, true, true)
		UiPush()
		UiTranslate(30, y)
		PC.drawLine(e, cfg.winW, 28, a, true)
		UiPop()
		y = y - 8
		shown = shown + 1
	end
	UiPop()
end

-- the line being typed
function PC.drawTyping()
	local c, cfg = PC.C(), PC.cfg
	local ch = PC.channel()
	local W = cfg.winW
	UiPush()
	UiTranslate(24, UiHeight() - 146)
	UiAlign("left top")
	UiColor(0, 0, 0, 0.75)
	UiRoundedRect(W, 54, 8)
	if ch == "g" then UiColor(0.55, 0.8, 1, 0.95) else UiColor(1, 0.82, 0.3, 0.95) end
	UiRoundedRectOutline(W, 54, 8, 2)
	UiFont("bold.ttf", 28)
	local label = ch == "g" and "Say (everyone): " or "Say (nearby): "
	local lw = UiGetTextSize(label) or 160
	UiPush()
	UiTranslate(14, 27)
	UiAlign("left middle")
	UiText(label)
	UiPop()
	UiTranslate(14 + lw, 0)
	UiColor(1, 1, 1, 1)
	UiFont(PC.chatFont(c.text), 28)
	PC.field(W - 28 - lw, 54)
	UiPop()
	UiPush()
	UiTranslate(30, UiHeight() - 86)
	UiAlign("left top")
	UiFont("regular.ttf", 18)
	UiColor(1, 1, 1, 0.5)
	UiText("Enter: say it   Tab: " .. (PC.lobby() and "Global / Voice" or "Proximity / Global / Voice") .. "   Esc: close   /help: commands")
	UiPop()
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
		UiText("Proximity Chat - Enter: talk to players near you (Tab: everyone / your voice)" .. key .. "   /help   (hide: /hint)")
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
	if PC.windowOpen() then PC.drawWindow() else PC.drawFeed() end
	if c.typing then PC.drawTyping() else PC.drawHint() end
	UiPop()
	PC.keys()
end
