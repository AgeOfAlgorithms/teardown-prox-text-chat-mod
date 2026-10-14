-- padui.lua - the chat on a CONTROLLER (2026-10-12, the user's layout; the actions measured with /padtest, padtest.lua):
-- L3 TWICE opens the chat (as Enter) with the QUICK-CHAT WHEEL beside it; while it is open (the game's "menu" layout):
--   R1 / L1 (menu_next / menu_prev)  the highlight: chat (history, line and wheel: ONE selection - the user, 2026-10-12)
--                                    -> Translate -> Voice -> Settings -> chat
--   L2 / R2 (rmb / lmb)              the talk mode down / up (Whisper < Speak < Yell < Global)
--   right stick up / down (up/down)  scrolls the history
--   on the chat: the LEFT STICK aims the wheel: the slot in the direction the stick MOVES the cursor (not where the cursor
--   is - the user, 2026-10-12: a cursor above the wheel picked the top line), chosen and STAYING when the stick is let
--   go; A says it (a typed line: says that), B closes;
--   the pages: the D-pad as before (chat_core's "nav")
-- (The stick's own value, InputValue mousex / mousey, read 0 in-game; the cursor is what the stick moves - padtest's first
--  run. The cursor stays visible: hiding it moved it, which made the highlight jump.)
-- Only for a controller (PC.pad()) opening it: a keyboard's Enter never shows the wheel.
-- FOLDERS (the user, 2026-10-12: "so users can express more things"): a slot is a line or a folder of 8 more; the main
-- wheel is 8 folders (the user's choice, 2026-10-12: two flicks to any line, 8-way aiming stays precise). A on a folder
-- opens it, B goes back up. A slot by its path: "3" (the main wheel's 3rd), "3.5" (the 5th line of folder 3).
-- WORDS: every pick adds its words to the line (the user, 2026-10-12: "all the words should add words"), back on the
-- main wheel for the next: "Where?" + "Vehicle" -> the line "Where? Vehicle"; A with nothing picked (or L3 twice) says
-- the line; B on the main wheel takes the last word back, then closes; B held closes. Players: a LIST of the others in
-- the session (up to 11), the stick or the D-pad up / down, A adds the name.
-- Saved per player: savegame.mod.pcwheel.<path> = the text, or "<name>/" for a folder (its lines under it); unset: the
-- default (PC.WHEEL_TREE). /wheel lists, /wheel <path> <text> sets (a text ending in "/" makes a folder),
-- /wheel <path> reset, /wheel reset.

-- the default wheel: a line, or {folder name, its 8 lines[, "words"]} ("words": they add to the line), or
-- {folder name, "players"} (the session's players, a list); clockwise from the top
PC.WHEEL_TREE = {
	{"Callouts", {"Over here!", "Follow me", "Run!", "Look!", "Help!", "Be quiet", "Wait!", "Watch out!"}},
	{"Questions", {"Who?", "What?", "Where?", "When?", "Why?", "How?", "Correct?", "Ready?"}, "words"},
	{"Replies", {"OK", "Thanks!", "Yes", "Sorry!", "Dunno", "My bad", "No", "No problem"}},
	{"Objects", {"Gun", "Furniture", "Wall", "Ground", "Vehicle", "Tree", "Enemy", "Friend"}, "words"},
	{"Players", "players"},
	{"Insults", {"You suck", "You stink", "Noob", "Loser", "Get good", "Skill issue", "Clown", "Bruh"}},
	{"Social", {"Hi!", "Bye!", "I'm the best", "LOL", "Oops", "Wow!", "Well played", "Let's go!"}},
	{"Teardown", {"Blow it up!", "Get a vehicle", "Grab this", "I need tools", "Check the map", "It will break",
		"Through the wall", "Time's up!"}},
}
PC.WHEEL_DEPTH = 3                                                     -- (folders in folders, at most)
PC.WHEEL_N = 8
PC.WHEEL_R = 210                                                       -- (the wheel's radius, chat units; 150 was small in-game)
PC.WHEEL_STEP = 1.5                                                    -- (px a frame the cursor must move to count as the stick pushed)
PC.WHEEL_PICK = 12                                                     -- (px of recent movement that pick a slot)
PC.WHEEL_KEEP = 0.6                                                    -- (how much of the recent movement each frame keeps)
PC.WHEEL_JUMP = 120                                                    -- (px in one frame: the game placing the cursor, not the stick)
PC.PAD_REPEAT = 0.15                                                   -- (s between scroll steps while the stick is held)
PC.PAD_HOLD = 0.5                                                      -- (s B is held to close the chat, whatever is on the line;
                                                                       --  A held this long sends the line)

function PC.padFocusOrder()
	local t = {"chat"}
	if PC.drawTranslatePage then t[#t + 1] = "translate" end
	if PC.drawVoicePage then t[#t + 1] = "voice" end
	t[#t + 1] = "settings"
	return t
end

-- the default at a path (a list of slot numbers): a line (string), a folder ({name, lines}) or nil
local function wheelDefault(path)
	local list = PC.WHEEL_TREE
	for k, i in ipairs(path) do
		local e = list and list[i]
		if k == #path then return e end
		if type(e) ~= "table" or type(e[2]) ~= "table" then return nil end
		list = e[2]
	end
	return nil
end

-- a slot: its text and whether it is a folder (nil: an empty slot)
function PC.wheelItem(path)
	local v = GetString(PC.cfg.save .. "wheel." .. table.concat(path, "."))
	if v ~= "" then
		if v:sub(-1) == "/" then return v:sub(1, -2), true end
		return v, false
	end
	local d = wheelDefault(path)
	if type(d) == "table" then return d[1], true end
	if type(d) == "string" then return d, false end
	return nil, false
end

-- what a folder's slots do: "lines" (say it), "words" (add it to the line) or "players" (a list of the players). A folder
-- the player made (/wheel ... /): lines.
function PC.wheelKind(path)
	if #path == 0 then return "lines" end
	if GetString(PC.cfg.save .. "wheel." .. table.concat(path, ".")) ~= "" then return "lines" end
	local d = wheelDefault(path)
	if type(d) ~= "table" then return "lines" end
	if d[2] == "players" then return "players" end
	return d[3] == "words" and "words" or "lines"
end

-- the main wheel's slot i (its text)
function PC.wheelLine(i)
	return (PC.wheelItem({i}))
end

-- the path of slot i in the folder open now
function PC.wheelHere(i)
	local c = PC.C()
	local p = {}
	for k, v in ipairs(c.wheelPath or {}) do p[k] = v end
	if i then p[#p + 1] = i end
	return p
end

function PC.padOpen()
	local c = PC.C()
	if not c.typing then PC.setTyping(true, true) end                -- (quiet: the "..." once the stick aims)
	c.padUI, c.padFocus, c.wheelSel, c.wheelLast, c.wheelVec, c.wheelPath, c.listSel = true, "chat", nil, nil, nil, {}, 1
	UiMakeInteractive()
end

function PC.padClose()
	local c = PC.C()
	c.padUI = false
	if c.nav then PC.setNav(false) end
	if c.typing then PC.setTyping(false) end
end

function PC.padSetFocus(f)
	local c = PC.C()
	c.padFocus = f
	if f == "chat" then
		if c.nav then PC.setNav(false) end
		if not c.typing then PC.setTyping(true, true) end
		c.page = "chat"
		c.focus = true                                                 -- (the line may take Steam's keyboard)
		c.wheelLast, c.wheelVec = nil, nil                             -- (the cursor must move before it picks)
	else
		if not c.nav then PC.setNav(true) end
		PC.setPage(f)
		c.navRow = 2                                                   -- (the page's first row, under the header)
	end
end

function PC.padCycle(step)
	local c = PC.C()
	local order = PC.padFocusOrder()
	local at = 1
	for i, f in ipairs(order) do if f == c.padFocus then at = i end end
	PC.padSetFocus(order[(at - 1 + step) % #order + 1])
end

-- the talk mode one step, round (the user, 2026-10-12: R2 on Global -> Whisper)
function PC.padModeStep(step)
	local cur = PC.mode()
	for i, x in ipairs(PC.MODES) do
		if x[1] == cur then
			local j = (i - 1 + step) % #PC.MODES + 1
			PC.setMode(PC.MODES[j][1])
			return
		end
	end
end

local function pressed(...)
	for i = 1, select("#", ...) do
		local ok, p = pcall(InputPressed, select(i, ...))
		if ok and p then return true end
	end
	return false
end

local function value(a)
	local ok, v = pcall(InputValue, a)
	return (ok and type(v) == "number") and v or 0
end

-- the slot (1..8, clockwise from the top) in the direction (x, y) from the wheel's centre (y down)
function PC.wheelSlotAt(x, y)
	local ang = math.deg(math.atan2(x, -y)) % 360                     -- (0 = up, clockwise)
	return math.floor((ang + 360 / PC.WHEEL_N / 2) / (360 / PC.WHEEL_N)) % PC.WHEEL_N + 1
end

-- (each frame on the chat) the direction the stick moves the cursor picks a slot; the pick stays when it stops. The
-- movement: the mouse's own (mousedx / mousedy: may go on at the screen's edge, where the cursor stops), else the
-- cursor's place against the last frame's. A little of the recent movement is kept, so one shaky frame doesn't flip it.
function PC.wheelAim()
	local c = PC.C()
	local dx, dy = value("mousedx"), value("mousedy")
	local src = "mouse"
	local mx, my = UiGetMousePos()
	mx, my = mx or 0, my or 0
	if dx == 0 and dy == 0 then
		local last = c.wheelLast
		dx, dy = last and (mx - last[1]) or 0, last and (my - last[2]) or 0
		src = "cursor"
	end
	c.wheelLast = {mx, my}
	c.wheelRaw = {dx, dy}
	local d2 = dx * dx + dy * dy
	if d2 < PC.WHEEL_STEP * PC.WHEEL_STEP or d2 > PC.WHEEL_JUMP * PC.WHEEL_JUMP then return end   -- (still, or a jump: the pick stays)
	local v = c.wheelVec or {0, 0}
	v = {v[1] * PC.WHEEL_KEEP + dx, v[2] * PC.WHEEL_KEEP + dy}
	c.wheelVec = v
	if v[1] * v[1] + v[2] * v[2] >= PC.WHEEL_PICK * PC.WHEEL_PICK then
		c.wheelSel = PC.wheelSlotAt(v[1], v[2])
		c.wheelSrc = src
	end
end

-- (client, before the chat's own keys) the controller's keys while the pad chat is open. True: the frame's keys taken.
function PC.padKeys()
	local c = PC.C()
	if not c.padUI then return false end
	if not PC.windowOpen() then c.padUI = false; return false end
	if not PC.pad() then return false end                              -- (a keyboard / mouse used meanwhile: theirs)
	if c.typing and c.padFocus ~= "chat" then c.padFocus = "chat" end   -- (Y from a page)
	if c.nav and c.padFocus == "chat" then c.padFocus = c.page end
	local now = GetTime()
	-- B HELD closes the chat from anywhere - a folder, the players, words on the line (the user, 2026-10-12); a tap still
	-- goes back / takes the last word back (it happens first: closing drops the line anyway)
	local okB, bDown = pcall(InputDown, "menu_cancel")
	if okB and bDown then
		c.bDownT = c.bDownT or now
		if now - c.bDownT >= PC.PAD_HOLD then
			c.bDownT = nil
			PC.padClose()
			return true
		end
	else
		c.bDownT = nil
	end
	-- A HELD sends the line (the user, 2026-10-12) - the tap that started it has already added its word / opened its folder
	local okA, aDown = pcall(InputDown, "menu_accept")
	if okA and aDown and c.padFocus == "chat" then
		c.aDownT = c.aDownT or now
		if now - c.aDownT >= PC.PAD_HOLD and not c.aSent then
			c.aSent = true
			if PC.clean(c.text or "") ~= "" then c.send = true end
			return true
		end
	else
		c.aDownT, c.aSent = nil, nil
	end
	if PC.bothSticks and PC.bothSticks() then                          -- (L3 + R3: as Enter - says a typed line, else closes)
		if c.typing and PC.clean(c.text or "") ~= "" then c.send = true else PC.padClose() end
		return true
	end
	if c.padFocus == "chat" and pressed("mmb", "flashlight") then      -- (Y: the settings, as before)
		PC.padSetFocus(PC.drawVoicePage and "voice" or "settings")
		c.navRow = 1
		return true
	end
	if pressed("menu_next") then PC.padCycle(1); return true end
	if pressed("menu_prev") then PC.padCycle(-1); return true end
	if pressed("rmb", "grab") then PC.padModeStep(-1) end
	if pressed("lmb", "usetool") then PC.padModeStep(1) end
	if c.page == "chat" then                                           -- (the right stick: the history)
		local dir = (value("up") > 0.5 and 1) or (value("down") > 0.5 and -1) or 0
		if dir == 0 then c.padScrollT = nil
		elseif not c.padScrollT or now - c.padScrollT >= PC.PAD_REPEAT then
			c.padScrollT = now
			PC.scrollBy(dir)
		end
	end
	if c.padFocus == "chat" then
		UiMakeInteractive()
		PC.wheelAim()
		if c.wheelVec or PC.clean(c.text or "") ~= "" then PC.typingDots() end   -- (the stick aims / a letter: "...")
		local path = c.wheelPath or {}
		local kind = PC.wheelKind(path)
		local typed = PC.clean(c.text or "") ~= ""
		local function addWord(w)                                      -- (a word on the line; back on the main wheel)
			c.text = PC.utf8Head((typed and (c.text .. " ") or "") .. w, PC.cfg.maxLen)
			c.wheelPath, c.wheelSel, c.wheelVec, c.listSel = {}, nil, nil, 1
		end
		if kind == "players" then                                     -- (a list: the stick or the D-pad up / down)
			local list = PC.otherPlayers()
			local n = #list
			local step = (pressed("menu_down") and 1) or (pressed("menu_up") and -1) or 0
			local v = c.wheelVec
			if step == 0 and v and math.abs(v[2]) >= PC.WHEEL_PICK and math.abs(v[2]) > math.abs(v[1]) then
				step, c.wheelVec = (v[2] > 0 and 1 or -1), nil
			end
			c.listSel = math.max(1, math.min(math.max(1, n), (c.listSel or 1) + step))
			if pressed("menu_accept") then
				if list[c.listSel] then addWord(list[c.listSel].name) end
			elseif pressed("menu_cancel") then
				c.wheelSel = table.remove(c.wheelPath)
				c.wheelVec = nil
			end
			return true
		end
		if pressed("menu_accept") then
			local text, folder = nil, false
			if c.wheelSel then text, folder = PC.wheelItem(PC.wheelHere(c.wheelSel)) end
			if text and folder then
				if #path < PC.WHEEL_DEPTH then                        -- (into the folder: nothing picked yet)
					c.wheelPath = PC.wheelHere(c.wheelSel)
					c.wheelSel, c.wheelVec, c.listSel = nil, nil, 1
				end
			elseif text then
				addWord(text)                                          -- (every line adds: A on nothing says them)
			elseif typed then
				c.send = true                                          -- (nothing picked: the line as it is)
			end
		elseif pressed("menu_cancel") then
			if #path > 0 then                                          -- (in a folder: back up, on the folder)
				c.wheelSel = table.remove(c.wheelPath)
				c.wheelVec = nil
			elseif typed then                                          -- (the main wheel: the last word back)
				c.text = (c.text:gsub("%s*%S+%s*$", ""))
			else
				PC.padClose()
			end
		end
		return true
	end
	return false
end

-- one folder's slots, for the chat: "1 Over here!  |  2 Callouts/  ..."
local function wheelList(path)
	local t = {}
	for i = 1, PC.WHEEL_N do
		local p = {}
		for k, v in ipairs(path) do p[k] = v end
		p[#p + 1] = i
		local text, folder = PC.wheelItem(p)
		if text then t[#t + 1] = table.concat(p, ".") .. " " .. text .. (folder and "/" or "") end
	end
	return table.concat(t, "  |  ")
end

-- /wheel: the main wheel; /wheel <path>: a folder's lines (or one line); /wheel <path> <text>: set one (ending in "/":
-- a folder); /wheel <path> reset: back to its default (a folder: with its lines); /wheel reset: everything
function PC.wheelCommand(rest)
	rest = rest or ""
	local save = PC.cfg.save .. "wheel"
	if rest:match("^%s*reset%s*$") then
		ClearKey(save)
		PC.system("Quick-chat wheel: back to the default lines and folders.")
		return
	end
	local ps, text = rest:match("^%s*([%d%.]+)%s*(.-)%s*$")
	local path = {}
	for n in (ps or ""):gmatch("%d+") do path[#path + 1] = tonumber(n) end
	local okPath = ps and #path >= 1 and #path <= PC.WHEEL_DEPTH + 1
	for _, n in ipairs(path) do if n < 1 or n > PC.WHEEL_N then okPath = false end end
	if not okPath then
		PC.system("Quick-chat wheel (clockwise from the top; a name/ is a folder): " .. wheelList({})
			.. "   - /wheel 2 lists folder 2, /wheel 2.5 <text> changes its 5th line, a text ending in / makes a folder")
		return
	end
	local key = save .. "." .. table.concat(path, ".")
	if text == "" then
		local t, folder = PC.wheelItem(path)
		if folder then PC.system("Quick-chat " .. table.concat(path, ".") .. " (" .. t .. "/): " .. wheelList(path))
		else PC.system("Quick-chat " .. table.concat(path, ".") .. ": " .. (t or "(empty)")) end
		return
	end
	if text:lower() == "reset" then
		ClearKey(key)
	else
		local folder = text:sub(-1) == "/"
		local clean = PC.utf8Head(PC.clean(folder and text:sub(1, -2) or text), 40)
		if clean == "" then PC.system("Quick-chat: give it a text.") return end
		SetString(key, clean .. (folder and "/" or ""))
	end
	local t, folder = PC.wheelItem(path)
	PC.system("Quick-chat " .. table.concat(path, ".") .. ": " .. (t or "(empty)") .. (folder and "/" or ""))
end

-- (draw, in the chat's units) the wheel beside the window, on the side with room
function PC.drawWheel(L)
	local c = PC.C()
	if not (c.padUI and PC.windowOpen()) then return end
	local SW = UiWidth() / L.s
	local R = PC.WHEEL_R
	local gap = 24
	local cx = (L.x + L.W + gap + 2 * R <= SW) and (L.x + L.W + gap + R) or (L.x - gap - R)
	local cy = math.max(R + 8, math.min(UiHeight() / L.s - R - 8, L.y + L.H / 2))
	local on = c.padFocus == "chat"
	UiPush()
	UiTranslate(cx, cy)
	UiAlign("center middle")
	UiColor(0, 0, 0, on and 0.75 or 0.5)
	UiRoundedRect(2 * R, 2 * R, R)
	if on then
		UiColor(1, 0.82, 0.3, 0.8)
		UiRoundedRectOutline(2 * R, 2 * R, R, 3)
	end
	local col = PC.modeInfo(PC.mode())[5]
	local path = c.wheelPath or {}
	local inFolder = #path > 0
	local kind = PC.wheelKind(path)
	if kind == "players" then                                           -- (the players: a list in the wheel)
		UiTranslate(0, -R * 0.72)
		UiFont("bold.ttf", 26)
		UiColor(1, 0.82, 0.3, 1)
		UiText(PC.utf8Head((PC.wheelItem(path)) or "Players", 14))
		UiTranslate(0, 40)
		local list = PC.otherPlayers()
		UiFont("regular.ttf", 20)
		if #list == 0 then
			UiColor(1, 1, 1, 0.6)
			UiText("No one else here")
		end
		for i, e in ipairs(list) do
			local sel = on and c.listSel == i
			local name = PC.utf8Head(e.name or "?", 20)
			UiPush()
			UiFont(sel and "bold.ttf" or "regular.ttf", 20)
			local tw = math.max(160, (UiGetTextSize(name) or 60) + 24)
			UiColor(sel and 1 or 0.15, sel and 0.82 or 0.15, sel and 0.3 or 0.18, sel and 0.95 or 0.85)
			UiRoundedRect(tw, 26, 8)
			UiColor(sel and 0.1 or 1, sel and 0.08 or 1, sel and 0.12 or 1, 1)
			PC.noWild()
			UiText(name)
			UiPop()
			UiTranslate(0, 29)
		end
		UiPop()
		return
	end
	local selText, selFolder = nil, false
	if c.wheelSel then selText, selFolder = PC.wheelItem(PC.wheelHere(c.wheelSel)) end
	UiTranslate(0, -16)
	UiFont("bold.ttf", 26)
	if inFolder then                                                    -- (in a folder: its name, the mode under it)
		UiColor(1, 0.82, 0.3, 1)
		UiText(PC.utf8Head((PC.wheelItem(path)) or "", 14))
	else
		UiColor(col[1], col[2], col[3], 1)
		UiText(PC.modeInfo(PC.mode())[3])                               -- (the mode, in its colour, in the middle)
	end
	UiTranslate(0, 30)
	UiFont("regular.ttf", 19)
	UiColor(1, 1, 1, 0.6)
	local typed = PC.clean(c.text or "") ~= ""
	UiText(not on and "R1: here" or (selText and (selFolder and "A: open" or "A: add")
		or (inFolder and "B: back" or (typed and "A: say the line" or "Left stick: aim"))))
	UiTranslate(0, -14)
	if c.padTest and c.wheelRaw then                                    -- (/padtest: this frame's movement, and from where)
		UiTranslate(0, R * 0.32)
		UiFont("regular.ttf", 15)
		UiColor(1, 1, 1, 0.6)
		UiText(string.format("move %.1f, %.1f (%s)", c.wheelRaw[1], c.wheelRaw[2], c.wheelSrc or "-"))
		UiTranslate(0, -R * 0.32)
	end
	for i = 1, PC.WHEEL_N do
		local a = math.rad((i - 1) * 360 / PC.WHEEL_N)
		local x, y = math.sin(a) * R * 0.7, -math.cos(a) * R * 0.7
		local sel = on and c.wheelSel == i
		local text, folder = PC.wheelItem(PC.wheelHere(i))
		if text then
			if folder then text = text .. "  >" end                        -- (a folder: A opens it)
			UiPush()
			UiTranslate(x, y)
			UiFont(sel and "bold.ttf" or "regular.ttf", sel and 25 or 22)
			local tw = (UiGetTextSize(text) or 60) + 20
			UiColor(sel and 1 or 0.15, sel and 0.82 or 0.15, sel and 0.3 or 0.18, sel and 0.95 or 0.85)
			UiRoundedRect(tw, 38, 10)
			if folder and not sel then
				UiColor(1, 0.82, 0.3, 0.6)
				UiRoundedRectOutline(tw, 38, 10, 2)
			end
			UiColor(sel and 0.1 or 1, sel and 0.08 or 1, sel and 0.12 or 1, on and 1 or 0.6)
			PC.noWild()
			UiText(text)
			UiPop()
		end
	end
	UiPop()
end

-- (draw) what the buttons do, under the chat line while the pad chat is open
function PC.padHintText()
	local c = PC.C()
	local inFolder = c.wheelPath and #c.wheelPath > 0
	local where = c.padFocus == "chat" and ("Left stick: aim   A: add / open   Hold A (or A on nothing): send" .. (inFolder and "   B: back"
		or (PC.clean(c.text or "") ~= "" and "   B: last word back" or ""))) or "D-pad: move   A: press"
	return where .. "   R1 / L1: chat, pages   L2 / R2: mode   Right stick: scroll   Hold B: close"
end
