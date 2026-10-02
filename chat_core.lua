-- chat_core.lua - Proximity Chat for Teardown v2 multiplayer: text chat with three speaking MODES,
-- speech bubbles and an Animal-Crossing-style "babble" voice. Works in any level / game mode; reusable
-- by #include in other mods. Source of truth: teardown-mods/proxchat/mods/proximity chat/chat_core.lua.
--
-- MODES (chosen on the input line; they decide how OTHERS hear your message)
--   "p" Speak, the default: a speech bubble over your head and a babble voice played in 3D at
--     you (quieter and echoing with distance), heard within cfg.chatR (20 m). ALL-CAPS words or a word
--     ending in "!" are shouted and reach cfg.shoutR (45 m), where only the shouted words get through.
--     The BUFFER chatR-cfg.mumbleR (20-30 m): the babble and a bubble with the message GARBLED
--     (PC.garble: letters as mysterious glyphs; the closer, the more real letters show, up to
--     cfg.garbleMax; shouted words readable), on the screen edge in the speaker's direction when off
--     screen; no history line. Coming within range while the bubble is up shows the words and adds
--     the line (a far shout's line is completed instead).
--   "w" Whisper: heard within cfg.whisperR (5 m); its buffer to cfg.whisperMumbleR (8 m) is garbled
--     the same way; beyond it nothing at all. CAPS stay a whisper (no shout reach). A pale lavender bubble; a breathy babble
--     (whisper0-7.ogg: noise through vowel formants; Robot: rwhisper0-3, a crushed hiss), quiet, at
--     your head, no echo; the voice's pitch still shifts it a little.
--   "g" Global: every player gets the line in their chat - a plain chat line only: no bubble, no babble
--     (only Speak and Whisper make bubbles and babble).
--   Lobby (PC.hooks.inLobby() true on the server): everything said is Global.
--   Your last mode is kept as your default next time (savegame.mod.pcmode).
--
-- BUBBLES are drawn in cfg.bubbleFont (Pangolin, a thick marker-hand font shipped in fonts/, OFL)
--   when that file exists and has every letter of the message (Latin incl. Vietnamese, Cyrillic);
--   anything else (Greek, CJK, Arabic, Thai...) uses the game font for its script (PC.chatFont). The
--   window stays in the game fonts.
--
-- HISTORY: ONE list per player of everything THEY received: every Global line, plus the Speak /
--   Whisper lines they were in range of at the moment each arrived (only the shouted words from
--   20-45 m), so every player's history is different. Lines are tagged [global] / [speak] / [whisper]
--   (whispers in lavender). Bounded to cfg.keepHist.
--
-- THE WINDOW: Enter opens the input line and the chat window (interactive: mouse cursor). The line
--   shows the mode ("Speak:", "Whisper:", "Global:") and three mode chips at its
--   right end; Tab or a click on a chip changes the mode. Enter says it, Esc closes. The window shows
--   the history (wheel / PgUp / PgDn scroll) and, right-aligned in its header, a "Settings" button:
--   the Settings page has the voice picker (a click picks: synced so others hear it, saved, a preview
--   only you hear), the hint on/off, keep the window open; "Back" returns.
--   With the window closed the newest lines fade out in a feed. No hotkeys besides Enter (a host mod
--   may set PC.cfg.windowKey to pin the window with a key).
--   Clicks fire on the mouse PRESS (UiIsMouseInRect + InputPressed("lmb")), with UiBlankButton (fires
--   on release) as a de-duplicated fallback: one click is one action (UiBlankButton alone missed
--   clicks in Tall Order's lobby).
-- COMMANDS (echoed locally): /s /w /g [text] (Speak / Whisper / Global: set the mode, or say one line
--   in it; /p = /s), /voice [name|n], /settings, /hint, /window, /clear, /help, //text sends "/text".
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
--   PC.say(text, mode)                client: say something as the local player (mode "p" / "w" / "g")
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
--                                     whispers still need 5 m
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
		chatR = 20,              -- m: who hears you (nearby)
		shoutR = 45,             -- m: who hears your shouted words (nearby only)
		whisperR = 5,            -- m: who hears a whisper
		mumbleR = 30,            -- m: Speak's buffer beyond chatR: the babble and the message garbled
		whisperMumbleR = 8,      -- m: Whisper's buffer beyond whisperR (nothing beyond it)
		garbleMax = 0.75,        -- share of the letters revealed at the buffer's inner edge (0 at its outer edge)
		life = 9,                -- s a bubble / a feed line stays
		maxLen = 90,             -- characters per message
		keepShared = 30,         -- messages in shared.pcMsgs
		sharedLife = 12,         -- s a message stays in shared (clients copy it on arrival)
		keepHist = 50,           -- lines in the local history
		rate = 0.45,             -- s between two messages of one player
		sndDir = "MOD/snd/",
		bubbleFont = "MOD/fonts/pangolin.ttf", -- the speech bubbles' font ("" = the game fonts)
		bubbleSize = 32,         -- its size (Pangolin is a bit small for its size; the game fonts use 30)
		windowKey = "",          -- a hotkey that pins the chat window ("" = none; /window does it)
		reg = "proxchat",        -- registry prefix
		save = "savegame.mod.pc",-- persistent settings: pcvoice, pcmode, pchidehint
		babbleMax = 45,          -- syllables per message
		babbleVol = 0.75,
		shoutVol = 0.8,          -- shouted words (shout clips, already a little louder than babble)
		globalVol = 0.35,        -- the voice preview (Settings): this much of the voice's volume, at the listener
		globalMaxSyl = 14,       -- the voice preview: at most this many syllables
		whisperVol = 0.45,       -- whisper babble: this much of the voice's volume, at the speaker
		echoFrom = 6,            -- m: farther voices echo
		winW = 1000, winH = 400, -- the chat window (and the input line's width)
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
PC.BABBLE_SETS = {voice = 8, shout = 8, robot = 4, whisper = 8, rwhisper = 4}
PC.CLIP_FILE = {voice = "babble", shout = "shout", robot = "robot", whisper = "whisper", rwhisper = "rwhisper"}

-- the modes: id, prompt on the input line, chip label, history tag, colour
PC.MODES = {
	{"p", "Speak: ", "Speak", "[speak]", {1, 0.82, 0.3}},
	{"w", "Whisper: ", "Whisper", "[whisper]", {0.78, 0.78, 0.9}},
	{"g", "Global: ", "Global", "[global]", {0.55, 0.8, 1}},
}
function PC.modeInfo(m)
	for _, x in ipairs(PC.MODES) do if x[1] == m then return x end end
	return PC.MODES[1]
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

-- a word is shouted: 2+ cased letters and none lower case, or (any script) it ends in "!" / "！"
function PC.isShout(w)
	if w:find("!%s*$") or w:find("\239\188\129%s*$") then return true end
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

-- ---- the buffer range: a message half heard. Each letter becomes a mysterious glyph unless it is
-- revealed: a fixed share of the letters (frac, 0-1) chosen per message (seed), so walking closer
-- uncovers more of the same message. Spaces and punctuation stay (the shape of the sentence shows);
-- keepShouts leaves shouted words readable. With several PC.GARBLE glyphs they shimmer with tick.
-- The glyph: ⬚ (U+2B1A). Our Pangolin has it (added by tools/add_box_glyph.py); of the game's fonts
-- only the CJK ones do, so without Pangolin a garbled bubble falls back to bold_sc.ttf (PC.scriptOf
-- counts ⬚ as "cjk"; that font has Latin and Cyrillic too).
PC.GARBLE = {"\226\172\154"}
local function hash01(a, b, c)
	return ((a * 73856093 + b * 19349663 + c * 83492791) % 1000003) / 1000003
end
function PC.garble(text, frac, seed, tick, keepShouts)
	local out, i = {}, 0
	for sp, w in text:gmatch("(%s*)(%S+)") do
		out[#out + 1] = sp
		if keepShouts and PC.isShout(w) then
			out[#out + 1] = w
			for _ in w:gmatch(PC.UTF8_CHAR) do i = i + 1 end
		else
			for ch in w:gmatch(PC.UTF8_CHAR) do
				i = i + 1
				if (#ch == 1 and ch:find("%p")) or hash01(seed, i, 0) < frac then
					out[#out + 1] = ch
				else
					out[#out + 1] = PC.GARBLE[math.floor(hash01(seed, i, tick + 1) * #PC.GARBLE) + 1]
				end
			end
		end
	end
	return table.concat(out)
end

-- what a bubble shows now: in the buffer range the message garbled, more of it revealed the closer
-- the listener is (up to cfg.garbleMax just outside the range)
function PC.bubbleText(p, b, now)
	if b.level ~= "mumble" and b.level ~= "shout" then return b.text end
	local cfg = PC.cfg
	local inner = b.whisper and cfg.whisperR or cfg.chatR
	local outer = b.whisper and cfg.whisperMumbleR or cfg.mumbleR
	local d = PC.distTo(p)
	if b.level == "shout" and not (d and d <= outer) then return b.text end   -- (farther: "HELP ... NOW")
	local f = d and math.max(0, math.min(1, (outer - d) / (outer - inner))) or 0
	return PC.garble(b.full, f * cfg.garbleMax, b.id or 0, math.floor(now * 3), b.level == "shout")
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

-- a mode from the network: "p", "w" or "g" ("g" only in the lobby)
function PC.validMode(m)
	if PC.inLobby() then return "g" end
	if m == "g" or m == "w" then return m end
	return "p"
end

-- a player says something: sanitized, rate-limited, then published (whole table: one sync)
function server.pc_say(p, ch, text)
	local s = PC.S()
	p = tonumber(p)
	if not p then return end
	text = PC.clean(text)
	if text == "" then return end
	ch = PC.validMode(ch)
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
		hist = {}, n = 0, seen = 0, typing = false, text = "", focus = false, pinned = false,
		page = "chat", bubbles = {}, scroll = 0, t0 = GetTime(),
		hideHint = GetBool(cfg.save .. "hidehint"),
		voiceTries = 0, voiceT = 0,
		babble = {clips = {}, queue = {}, echoes = {}},
	}
	local m = GetString(cfg.save .. "mode")                       -- (the last mode used)
	c.mode = (m == "w" or m == "g") and m or "p"
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
		if msg.ch == "g" then PC.addHist({ch = "g", p = msg.p, name = msg.name, text = msg.text, shout = #PC.shoutWords(msg.text) > 0}) end
	end
end

function PC.C()
	if not PC.c then PC.clientInit() end
	return PC.c
end

function PC.lobby() return shared.pcLobby == true end

-- the input line's mode: "p" Speak, "w" Whisper, "g" Global (the lobby: always "g")
function PC.mode()
	if PC.lobby() then return "g" end
	return PC.C().mode
end

function PC.setMode(m)
	local c = PC.C()
	if PC.lobby() then return end                                   -- (the lobby is Global only)
	if m ~= "g" and m ~= "w" then m = "p" end
	if c.mode == m then return end
	c.mode = m
	SetString(PC.cfg.save .. "mode", m)                             -- (your default next time)
	if c.typing then ServerCall("server.pc_typing", GetLocalPlayer(), true, m) end
end

-- Tab: Speak -> Whisper -> Global -> Speak
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

function PC.distTo(p)
	local ok1, a = pcall(GetPlayerTransform, GetLocalPlayer())
	local ok2, b = pcall(GetPlayerTransform, p)
	if not (ok1 and ok2 and a and b and a.pos and b.pos) then return nil end
	return VecLength(VecSub(a.pos, b.pos))
end

-- what the local player hears of p's message NOW: text, far, level, distance. Levels: "full" (Speak
-- within chatR, Whisper within whisperR), "shout" (only the shouted words, within shoutR: far = true),
-- "mumble" (the buffer just beyond: chatR-mumbleR / whisperR-whisperMumbleR: the babble and a garbled
-- bubble, no words, no history line). nil = nothing.
PC.LEVEL = {mumble = 1, shout = 2, full = 3}
function PC.heard(p, text, mode)
	if p == GetLocalPlayer() then return text, false, "full", 0 end
	local cfg = PC.cfg
	if mode == "w" then
		local d = PC.distTo(p)
		if d and d <= cfg.whisperR then return text, false, "full", d end
		if d and d <= cfg.whisperMumbleR then return "...", true, "mumble", d end
		return nil
	end
	if PC.hooks.everyoneHears and PC.hooks.everyoneHears(p) then return text, false, "full", 0 end
	local d = PC.distTo(p)
	if not d then return nil end
	if d <= cfg.chatR then return text, false, "full", d end
	if d <= cfg.shoutR then
		local sw = PC.shoutWords(text)
		if #sw > 0 then return table.concat(sw, " ... "), true, "shout", d end
	end
	if d <= cfg.mumbleR then return "...", true, "mumble", d end
	return nil
end

-- a new message from the server: each client records what it heard, now
function PC.receive(m)
	local c = PC.C()
	local me = GetLocalPlayer()
	local heard, far
	if m.ch == "g" then
		heard = m.text
		PC.addHist({ch = "g", p = m.p, name = m.name, text = m.text, shout = #PC.shoutWords(m.text) > 0, me = m.p == me})
		-- (Global: a chat line only - no bubble, no babble)
	else
		local mode = (m.ch == "w") and "w" or "p"
		local level, d
		heard, far, level, d = PC.heard(m.p, m.text, mode)
		if heard then
			local whisper = mode == "w"
			local mumble = level == "mumble"
			local shout = not whisper and not mumble and #PC.shoutWords(heard) > 0   -- (CAPS stay a whisper)
			local entry
			if not mumble then
				entry = {ch = mode, p = m.p, name = m.name, text = heard, shout = shout, far = far, me = m.p == me}
				PC.addHist(entry)
			end
			c.bubbles[m.p] = {text = heard, t = GetTime(), shout = shout, whisper = whisper, mumble = mumble,
				full = m.text, mode = mode, level = level, name = m.name, entry = entry, id = m.id}
			-- the babble: all of it, except beyond the buffer where only the shouted words carry
			local inBuffer = d <= (whisper and PC.cfg.whisperMumbleR or PC.cfg.mumbleR)
			PC.babbleSay(m.p, (level == "shout" and not inBuffer) and heard or m.text, nil, whisper and "whisper" or nil)
			if mumble then heard, far = nil, nil end                           -- (the hook: no words heard)
		end
	end
	if PC.hooks.onMessage then PC.hooks.onMessage(m, heard) end
end

-- a bubble heard only in part (garbled in the buffer, or only the shouted words) shows the words once
-- the listener comes within range while it is still up; the history gets the line then
function PC.revealBubbles(now)
	local c, cfg = PC.C(), PC.cfg
	for p, b in pairs(c.bubbles) do
		if b.level and b.level ~= "full" then
			local text, far, level = PC.heard(p, b.full, b.mode)
			if text and PC.LEVEL[level] > PC.LEVEL[b.level] then
				b.text, b.level, b.mumble = text, level, false
				b.shout = not b.whisper and #PC.shoutWords(text) > 0
				b.t = math.max(b.t, now - cfg.life + 4)                    -- (up at least 4 s more)
				if b.entry then
					b.entry.text, b.entry.far, b.entry.shout = text, far, b.shout
				else
					b.entry = {ch = b.mode, p = p, name = b.name, text = text, shout = b.shout, far = far}
					PC.addHist(b.entry)
				end
			end
		end
	end
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
	PC.revealBubbles(now)
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

-- a message as syllables: {variant hash, pause after, pitch factor, shouted}
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
	return out
end

-- start babbling text for player p. how: nil = in the world at the speaker (nearby: shouts, echo),
-- "whisper" = breathy clips at the speaker, quiet, no echo, no shouting; "flat" = at the listener
-- (the voice preview in Settings), short and quiet
function PC.babbleSay(p, text, voice, how)
	local B = PC.C().babble
	local cfg = PC.cfg
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
		for _, s in ipairs(syl) do s[4] = false end               -- (CAPS stay a whisper)
	end
	q.vol, q.shoutVol = vol, shoutVol
	B.queue[p] = q
end

-- farther voices: quieter (on top of the engine's 3D falloff) and echoing. No reverb API: the echo is
-- 1-3 delayed, fainter repeats of each syllable from a few metres beside the speaker. Shouted
-- syllables lose less with distance (they are meant to carry: they start quieter up close instead).
function PC.babbleDistance(pos, vol, shout)
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
	return vol * (1 - (shout and 0.2 or 0.5) * f), echoes
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
				if q.how == "flat" then
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
					if q.how then
						PlaySound(clip, pos, base, false, pitch)            -- (flat / whisper: no echo)
					else
						local vol, echoes = PC.babbleDistance(pos, base, s[4])
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

-- ---- typing, modes, commands
function PC.setTyping(on)
	local c = PC.C()
	c.typing = on and true or false
	c.text, c.send, c.tab, c.scroll = "", nil, nil, 0
	c.focus = c.typing
	c.page = "chat"                                               -- (opens / closes on the history)
	ServerCall("server.pc_typing", GetLocalPlayer(), c.typing, PC.mode())
end

function PC.scrollBy(n)
	local c = PC.C()
	if c.page ~= "chat" then return end
	c.scroll = math.max(0, math.min(math.max(0, #c.hist - 1), c.scroll + n))
end

function PC.say(text, mode)
	text = PC.clean(text)
	if text == "" then return end
	ServerCall("server.pc_say", GetLocalPlayer(), mode or PC.mode(), text)
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
		PC.modeCommand("p", rest)
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
	elseif cmd == "clear" then
		c.hist = {}
		c.scroll = 0
	elseif cmd == "help" or cmd == "h" or cmd == "?" then
		local key = PC.keyName() ~= "" and (PC.keyName() .. ": chat window. ") or ""
		PC.system("Enter: chat. Tab or the chips on the line: Speak / Whisper / Global. Settings (window header): voice and more. " .. key .. "CAPS or ! shouts farther (Speak only).")
		PC.system("/s /w /g [text]   /voice [name]   /settings   /hint   /window (keep open)   /clear")
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
	local info = (not e.sys) and PC.modeInfo(e.ch) or nil
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
		elseif e.shout then UiColor(1, 0.45, 0.35, a)
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
	local kx = math.abs(dx) > 1e-3 and ((dx > 0 and (W - 110 - cx) or (cx - 110)) / math.abs(dx)) or 1e9
	local ky = math.abs(dy) > 1e-3 and ((dy > 0 and (H - 60 - cy) or (cy - 130)) / math.abs(dy)) or 1e9
	local k = math.min(kx, ky)
	return cx + dx * k, cy + dy * k
end

-- a speech bubble over player p, with a thin black outline. small: the "..." of someone typing;
-- whisper: a bit smaller, pale lavender; mumble: a garbled message from the buffer range - kept on
-- the screen edge in their direction when they are off screen
function PC.bubble(p, text, shout, a, small, whisper, mumble)
	local okT, tr = pcall(GetPlayerTransform, p)
	if not (okT and tr and tr.pos) then return end
	local head = VecAdd(tr.pos, Vec(0, 2.25, 0))
	local x, y, d = UiWorldToPixel(head)
	local scale
	if d and d > 0 and x >= 0 and x <= UiWidth() and y >= 0 and y <= UiHeight() then
		scale = math.max(0.55, math.min(1.1, 9 / math.max(1, d)))
	elseif mumble then
		x, y = PC.edgePoint(head)
		scale = 0.8
	else
		return
	end
	UiPush()
	UiTranslate(x, y)
	if shout then UiTranslate(math.random(-2, 2), math.random(-2, 2)) end      -- (shaking with anger)
	UiScale(scale * (shout and 1.15 or 1) * (small and 0.75 or (whisper and 0.88 or 1)))
	UiFont(PC.bubbleFont(text))
	local vis = PC.chatVisual(text)
	UiWordWrap(640)
	local tw, th = UiGetTextSize(vis)
	local w = math.min(640, tw or 200) + 30
	local h = (th or 28) + 22
	local k = 2                                                              -- (the outline)
	UiAlign("left top")
	UiTranslate(-w / 2, -h - 14)
	UiColor(0, 0, 0, 0.9 * a)
	UiPush(); UiTranslate(-k, -k); UiRoundedRect(w + 2 * k, h + 2 * k, 10 + k); UiPop()
	UiPush(); UiTranslate(w / 2 - 9, h); UiRotate(45); UiTranslate(-k, -k); UiRect(13 + 2 * k, 13 + 2 * k); UiPop()
	if whisper then UiColor(0.86, 0.87, 1, a) else UiColor(1, 1, 1, a) end
	UiRoundedRect(w, h, 10)
	UiPush(); UiTranslate(w / 2 - 9, h); UiRotate(45); UiRect(13, 13); UiPop()   -- the tail (covers the outline at its root)
	if shout then UiColor(0.9, 0.1, 0.05, a); UiRoundedRectOutline(w, h, 10, 4) end
	UiTranslate(15, 11)
	if whisper then UiColor(0.2, 0.2, 0.38, mumble and 0.85 * a or a)
	else UiColor(shout and 0.6 or 0.08, 0.05, shout and 0.03 or 0.1, mumble and 0.85 * a or a) end
	UiText(vis)
	UiPop()
end

function PC.drawBubbles()
	local c, cfg = PC.C(), PC.cfg
	local now = GetTime()
	local me = GetLocalPlayer()
	local third = GetBool("game.thirdperson")
	for p, b in pairs(c.bubbles) do
		if p ~= me or third then PC.bubble(p, PC.bubbleText(p, b, now), b.shout, math.max(0, math.min(1, (cfg.life - (now - b.t)) / 1.2)), false, b.whisper, b.mumble) end
	end
	for p, mode in pairs(shared.pcTyping or {}) do
		if (mode == "p" or mode == "w") and p ~= me and not c.bubbles[p] then
			local d = PC.distTo(p)
			if d and d <= (mode == "w" and cfg.whisperR or cfg.chatR) then PC.bubble(p, "...", false, 0.75, true, mode == "w") end
		end
	end
end

-- a small two-way switch on the Settings page; returns the new value when clicked, else nil
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
	local bw, bh, gap = 300, 52, 12
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
	}
	for k, r in ipairs(rows) do
		UiPush()
		UiTranslate(0, (k - 1) * 48)
		UiPush()
		UiTranslate(0, 20)
		UiAlign("left middle")
		UiFont("regular.ttf", 22)
		UiColor(1, 1, 1, 0.85)
		UiText(r[2])
		UiPop()
		UiTranslate(520, 0)
		local v = PC.toggle(r[1], r[3], r[4], r[5])
		if v ~= nil then r[6](v) end
		UiPop()
	end
	UiPop()
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
		UiText("Nothing yet. Speak: " .. cfg.chatR .. " m (CAPS or ! carry to " .. cfg.shoutR .. " m), Whisper: " .. cfg.whisperR .. " m, Global: all players.")
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
function PC.drawWindow()
	local c, cfg = PC.C(), PC.cfg
	local W, H = cfg.winW, cfg.winH
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
	local cw, chh, cg = 104, 34, 6
	local chipsW = 3 * cw + 2 * cg
	UiPush()
	UiTranslate(24, UiHeight() - 146)
	UiAlign("left top")
	UiColor(0, 0, 0, 0.75)
	UiRoundedRect(W, 54, 8)
	-- the chips (first: a click changes the prompt this frame)
	UiPush()
	UiTranslate(W - 10 - chipsW, 10)
	for i, x in ipairs(PC.MODES) do
		local dim = PC.lobby() and x[1] ~= "g"
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
	local info = PC.modeInfo(m)
	local col = info[5]
	UiColor(col[1], col[2], col[3], 0.95)
	UiRoundedRectOutline(W, 54, 8, 2)
	local label = (m == "w") and ("Whisper (" .. cfg.whisperR .. " m): ") or info[2]
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
	UiText(PC.lobby() and "Enter: say it   Esc: close   Settings: your voice and more   /help"
		or "Enter: say it   Tab / chips: Speak, Whisper, Global   Esc: close   Settings: your voice and more   /help")
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
		UiText("Proximity Chat - Enter: talk to players near you (Tab: Whisper / Global)" .. key .. "   /help   (hide: /hint)")
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
