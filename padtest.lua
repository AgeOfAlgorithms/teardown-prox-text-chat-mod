-- padtest.lua - /padtest (a diagnostic, 2026-10-12): which of the game's ACTIONS a controller's buttons arrive as, with the
-- chat closed and open. A script sees actions, not buttons, and data/input_settings.xml has two gamepad layouts ("player":
-- R1 = scroll_down like D-pad down, L2 / R2 = grab / usetool; "menu": R1 = menu_next, L2 / R2 = rmb / lmb, the right stick
-- up / down / left / right, the left stick a cursor); which one is active while the chat is open is the question. Also:
-- L3 + R3 is the game's photomode shortcut in both. On screen: the actions held, the last presses (with whether the window
-- was open), the device, the sticks' values; each press also goes to log.txt as a spawned body "pcpad a=<action> w=<0/1>
-- i=<0/1>" (w: the window open, i: typing).
PC.PAD_ACTIONS = {"lmb", "rmb", "mmb", "scroll_up", "scroll_down", "usetool", "grab", "vehicle_raise", "vehicle_lower",
	"pause", "up", "left", "down", "right", "crouch", "jump", "interact", "flashlight", "map", "scoreboard", "handbrake",
	"vehicle_action", "camera_view", "menu_left", "menu_right", "menu_up", "menu_down", "menu_next", "menu_prev",
	"menu_accept", "menu_cancel", "zoom", "tool_group_prev", "tool_group_next", "photomode",
	"extra0", "extra1", "extra2", "extra3", "extra4", "extra5", "extra6"}
PC.PAD_VALUES = {"mousex", "mousey", "camerax", "cameray", "mousewheel"}
-- (2026-10-12, the first test: L2 / R2 gave no press with the chat open - maybe only a value: read these as values too,
--  and log when one goes past 0.5)
PC.PAD_TRIGGERS = {"lmb", "rmb", "usetool", "grab", "up", "down", "left", "right", "menu_up", "menu_down", "menu_left", "menu_right"}

function PC.padTestToggle()
	local c = PC.C()
	c.padTest = not c.padTest
	c.padLog = {}
	PC.system(c.padTest and "Pad test on: press every button with the chat closed, then open (both sticks) and again. /padtest to stop."
		or "Pad test off.")
end

-- (client, every frame while on) note the presses; log each one
function PC.padTestSample()
	local c = PC.C()
	if not c.padTest then return end
	local win, typing = PC.windowOpen() and 1 or 0, c.typing and 1 or 0
	for _, a in ipairs(PC.PAD_ACTIONS) do
		local ok, pressed = pcall(InputPressed, a)
		if ok and pressed then
			table.insert(c.padLog, 1, {a = a, t = GetTime(), w = win, i = typing, nav = c.nav and 1 or 0})
			while #c.padLog > 14 do table.remove(c.padLog) end
			if Spawn then
				local okS, hs = pcall(Spawn, "<body tags='pcpad a=" .. a .. " w=" .. win .. " i=" .. typing .. "'/>",
					Transform(Vec(0, -500, 0)))
				if okS and type(hs) == "table" then for _, h in ipairs(hs) do Delete(h) end end
			end
		end
	end
	-- (the second test: the D-pad gave no action at all - so the raw name of whatever was pressed, InputLastPressedKey)
	local okK, key = pcall(InputLastPressedKey)
	key = (okK and type(key) == "string") and key or ""
	local newKey = key ~= "" and key ~= c.padKey                       -- (once per press: it stays while held)
	c.padKey = key
	if newKey then
		table.insert(c.padLog, 1, {a = "key: " .. key, t = GetTime(), w = win, i = typing, nav = c.nav and 1 or 0})
		while #c.padLog > 14 do table.remove(c.padLog) end
		if Spawn then
			local safe = key:gsub("[^%w_%-]", "_")
			local okS, hs = pcall(Spawn, "<body tags='pcpadk k=" .. safe .. " w=" .. win .. "'/>", Transform(Vec(0, -500, 0)))
			if okS and type(hs) == "table" then for _, h in ipairs(hs) do Delete(h) end end
		end
	end
	c.padHigh = c.padHigh or {}
	for _, a in ipairs(PC.PAD_TRIGGERS) do
		local ok, x = pcall(InputValue, a)
		local high = ok and type(x) == "number" and math.abs(x) > 0.5
		if high and not c.padHigh[a] then
			table.insert(c.padLog, 1, {a = a .. " (value)", t = GetTime(), w = win, i = typing, nav = c.nav and 1 or 0})
			while #c.padLog > 14 do table.remove(c.padLog) end
			if Spawn then
				local okS, hs = pcall(Spawn, "<body tags='pcpadv a=" .. a .. " w=" .. win .. "'/>", Transform(Vec(0, -500, 0)))
				if okS and type(hs) == "table" then for _, h in ipairs(hs) do Delete(h) end end
			end
		end
		c.padHigh[a] = high
	end
end

local function deviceName()
	if not LastInputDevice then return "?" end
	local d = LastInputDevice()
	if d == (UI_DEVICE_GAMEPAD or 2) then return "gamepad (" .. d .. ")" end
	if d == UI_DEVICE_MOUSE then return "mouse+keyboard (" .. d .. ")" end
	if d == UI_DEVICE_TOUCHSCREEN then return "touchscreen (" .. d .. ")" end
	return tostring(d)
end

-- (client draw) the panel, at the screen's top right (the chat docks elsewhere by default)
function PC.padTestDraw()
	local c = PC.C()
	if not c.padTest then return end
	UiPush()
	local W, H = 520, 640
	UiTranslate(UiWidth() - W - 20, 20)
	UiAlign("left top")
	UiColor(0, 0, 0, 0.75)
	UiRoundedRect(W, H, 10)
	UiTranslate(16, 14)
	UiFont("bold.ttf", 22)
	UiColor(1, 0.82, 0.3, 1)
	UiText("PAD TEST   (/padtest to stop)")
	UiTranslate(0, 30)
	UiFont("regular.ttf", 18)
	UiColor(1, 1, 1, 0.9)
	UiText("device: " .. deviceName() .. "   window: " .. (PC.windowOpen() and "OPEN" or "closed")
		.. (c.typing and " (typing)" or "") .. (c.nav and " (nav)" or ""))
	UiTranslate(0, 24)
	local held = {}
	for _, a in ipairs(PC.PAD_ACTIONS) do
		local ok, down = pcall(InputDown, a)
		if ok and down then held[#held + 1] = a end
	end
	UiText("held: " .. (held[1] and table.concat(held, ", ") or "-"))
	UiTranslate(0, 24)
	local vals = {}
	for _, v in ipairs(PC.PAD_VALUES) do
		local ok, x = pcall(InputValue, v)
		vals[#vals + 1] = v .. " " .. ((ok and type(x) == "number") and string.format("%.2f", x) or "?")
	end
	UiText(table.concat(vals, "   "))
	UiTranslate(0, 24)
	local tv = {}
	for _, v in ipairs({"lmb", "rmb", "usetool", "grab"}) do
		local ok, x = pcall(InputValue, v)
		tv[#tv + 1] = v .. " " .. ((ok and type(x) == "number") and string.format("%.2f", x) or "?")
	end
	UiText("triggers: " .. table.concat(tv, "   "))
	UiTranslate(0, 24)
	local mx, my = UiGetMousePos()
	UiText(string.format("cursor %d, %d", mx or -1, my or -1))
	UiTranslate(0, 34)
	UiFont("bold.ttf", 18)
	UiText("last presses (newest first):")
	UiTranslate(0, 26)
	UiFont("regular.ttf", 18)
	local now = GetTime()
	for _, e in ipairs(c.padLog or {}) do
		UiColor(1, 1, 1, e.w == 1 and 1 or 0.65)
		UiText(string.format("%-16s %s%s%s   %.1f s ago", e.a, e.w == 1 and "[window open]" or "[closed]",
			e.i == 1 and " typing" or "", e.nav == 1 and " nav" or "", now - e.t))
		UiTranslate(0, 24)
	end
	UiPop()
end
