-- Proximity Babble Chat options (Mod Manager > Options). A menu script like the game's own speedometer
-- options.lua: plain draw(), no #version line. Settings are this player's own (savegame.mod.pc*):
-- the default voice (also chat window > Settings or /voice <name> in game), the hint, the speech
-- bubbles (Off / opacity) and the babble volume (Off / 25-100 %).
PCO_VOICES = {"Squeaky", "Chirpy", "Plain", "Low", "Deep", "Robot"}

function pcoButton(label, selected, w)
	UiPush()
	if selected then
		UiPush()
		UiColor(0.5, 1, 0.5, 0.2)
		UiImageBox("ui/common/box-solid-6.png", w, 40, 6, 6)
		UiPop()
	end
	local clicked = UiTextButton(label, w, 40)
	UiPop()
	return clicked
end

-- Off / 25 % / 50 % / 75 % / 100 % for a savegame key (1-5; unset = 100 %)
function pcoLevels(key)
	local v = GetInt(key)
	if v < 1 or v > 5 then v = 5 end
	UiPush()
	UiTranslate(-2 * 120, 0)
	for i, name in ipairs({"Off", "25%", "50%", "75%", "100%"}) do
		if pcoButton(name, v == i, 110) then SetInt(key, i) end
		UiTranslate(120, 0)
	end
	UiPop()
end

function draw()
	UiPush()
	UiButtonHoverColor(1, 1, 0.5, 1)
	UiTranslate(UiCenter(), 220)
	UiAlign("center middle")

	UiFont("bold.ttf", 48)
	UiText("Proximity Babble Chat")
	UiTranslate(0, 60)
	UiFont("regular.ttf", 22)
	UiColor(1, 1, 1, 0.7)
	UiText("In game: Enter to chat, Tab: Speak / Whisper / Shout / Global, Settings in the chat window, /help")
	UiColor(1, 1, 1, 1)

	UiFont("regular.ttf", 26)
	UiButtonImageBox("ui/common/box-outline-6.png", 6, 6)

	UiTranslate(0, 80)
	UiText("Your voice")
	UiTranslate(0, 50)
	local v = GetInt("savegame.mod.pcvoice")
	UiPush()
	UiTranslate(-(#PCO_VOICES - 1) * 75, 0)
	for i, name in ipairs(PCO_VOICES) do
		if pcoButton(name, v == i, 140) then SetInt("savegame.mod.pcvoice", i) end
		UiTranslate(150, 0)
	end
	UiPop()
	UiTranslate(0, 34)
	UiFont("regular.ttf", 18)
	UiColor(1, 1, 1, 0.5)
	UiText(v >= 1 and v <= #PCO_VOICES and "Used whenever you play with Proximity Babble Chat (change it in game: chat window > Settings)." or "Not picked: you get one of the first five at random.")
	UiColor(1, 1, 1, 1)
	UiFont("regular.ttf", 26)

	UiTranslate(0, 80)
	UiText("\"Enter: chat\" hint on screen")
	UiTranslate(0, 50)
	local hide = GetBool("savegame.mod.pchidehint")
	UiPush()
	UiTranslate(-110, 0)
	if pcoButton("Show", not hide, 200) then SetBool("savegame.mod.pchidehint", false) end
	UiTranslate(220, 0)
	if pcoButton("Hide", hide, 200) then SetBool("savegame.mod.pchidehint", true) end
	UiPop()

	UiTranslate(0, 80)
	UiText("Your own speech bubble (third person)")
	UiTranslate(0, 50)
	local hideOwn = GetBool("savegame.mod.pchideown")
	UiPush()
	UiTranslate(-110, 0)
	if pcoButton("Show", not hideOwn, 200) then SetBool("savegame.mod.pchideown", false) end
	UiTranslate(220, 0)
	if pcoButton("Hide", hideOwn, 200) then SetBool("savegame.mod.pchideown", true) end
	UiPop()

	UiTranslate(0, 80)
	UiText("Speech bubbles (how solid; the text stays readable)")
	UiTranslate(0, 50)
	pcoLevels("savegame.mod.pcbubbles")

	UiTranslate(0, 80)
	UiText("Babble volume")
	UiTranslate(0, 50)
	pcoLevels("savegame.mod.pcbabblevol")

	UiTranslate(0, 110)
	if UiTextButton("Close", 200, 40) then Menu() end
	UiPop()
end
