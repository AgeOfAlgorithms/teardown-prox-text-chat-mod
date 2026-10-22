# Proximity Comms: Text and Voice Chat (Teardown mod)

(Called Proximity Babble Chat until October 2026.)

Text and voice chat for Teardown multiplayer that works in **any level or game mode**, on keyboard or
controller. Players near you see what
you say as a **speech bubble** over your head and hear you **babble** in your own cartoon voice, from
where you stand. Four ways to be heard:

| mode | who gets it |
|---|---|
| **Whisper** | private (only sent to the players near enough) - players within 8 m: a pale lavender bubble and a breathy babble (⬚ boxes from 8 to 12 m). Walking up to someone mid-whisper shows nothing. |
| **Speak** | players within 25 m: a speech bubble, plus babble from your position. From 25 to 35 m they hear the babble and see the message as ⬚ boxes, with more real letters the closer they are. Their chat history keeps the most they made out, and the whole line appears if they come within 25 m while it's up. Walking toward someone who is mid-sentence shows their bubble too. |
| **Yell** | players within 40 m: an orange bubble and a raised voice (⬚ boxes from 40 to 55 m). |
| **Global** | every player: a plain chat line, with no bubble and no babble |

Only Global lines go to every player's game. A Whisper, Speak or Yell line is sent only to the players near
enough to hear it, plus a margin so they can walk in while the bubble is up (by default up to 14, 55 and 80 m).

A message written in ALL CAPS makes its bubble shake, whatever the mode.

**Voice chat** comes with the free [Koetama](https://github.com/AgeOfAlgorithms/koetama) app (Windows /
Linux), which runs next to the game. Players who run it hear each other's real voices from where they stand
(louder up close, the same Whisper / Speak / Yell / Global modes), see what is said as live captions in the
bubbles and the chat, and can have chat lines translated into their language (experimental). Players without
it keep the text chat and still see everyone's captions. The **Voice** and **Translate** pages in the chat
window have its settings.

The chat window keeps **your own history**: every Global line, plus the Whisper, Speak and Yell lines
you were close enough to hear when they were said. Every player's history is different.

Bubbles are drawn in the hand-lettered Pangolin font (Latin and Cyrillic; SIL Open Font License, see
`fonts/OFL.txt`). Every language works: the right game font for each script, Arabic and Hebrew drawn right to left, and
babble for every alphabet.

## Install

- **Workshop:** subscribe, then enable it in the Mod Manager. It's a **global mod**, so it runs in every
  level.
- **From this repo:** clone or copy this folder into `Documents/Teardown/mods/proximity chat/`.

**Multiplayer:** the host enables it for the session (Multiplayer → Global mods). Players who join get
it automatically from the Workshop. Teardown only allows Workshop mods in multiplayer, not local
copies.

**Not compatible with other chat mods** such as Easy Chat: turn them off when you use this one.

## Use

- **Enter**: open the chat line and the chat window. Enter again sends; **Esc** closes. A message can
  be up to 90 characters; a count shows from 60.
- **Up / Down** on the chat line: your last 10 sent lines (commands too) come back, to send again or edit.
- **Tab** while typing, or click the mode buttons at the end of the line, to choose how you speak: the
  chosen one shows its full name, the others are short (**Wsp / Spk / Yel / Glb**). Your last choice is
  remembered.
- **Settings** (button at the top right of the chat window, or Options in the Mod Manager): pick your
  voice (Squeaky, Chirpy, Plain, Low, Deep, Robot; click to hear it), the hint, keeping the window
  open, your own bubble (third person: Show / Hide), how solid speech bubbles are (Off, 25 % to 100 %; the text stays readable), the babble
  volume (a slider, Off to 100 %), and the chat itself: where it sits (any corner or the middle of any edge),
  its width and height, and its text size (70 % to 170 %).
- **Controller:** click the **left stick twice (L3 twice)** to open the chat with the **quick-chat wheel**.
  - **Left stick**: aim at a slot on the wheel (the direction you push picks it, and it stays picked).
    **X** opens a folder or adds the line to your message, then goes back to the main wheel, so a sentence
    can span folders: Questions "Where?", then Objects "Vehicle". **Y** takes the last added line back.
    **A** sends the message and closes (so does L3 twice).
  - The main wheel has 8 folders: Callouts, Questions, Replies, Objects, Players (a list of the others in the
    session), Insults, Social and Teardown, 8 lines each. `/wheel` changes them (see Commands).
  - **B**: back out of a folder; on the main wheel, cancel. **Hold B** to cancel from anywhere (the message
    is dropped).
  - **R1 / L1**: switch between the chat and the Translate, Voice and Settings pages (D-pad to move and
    change, A to press there). **L2 / R2**: the talk mode, round (Whisper, Speak, Yell, Global).
    **Right stick** up / down: scroll the history.
  - Lines sent from a controller show a small four-dot mark (the face buttons) before the name.
  - With Koetama running, a controller player's microphone is always on (it only sends while they talk),
    unless they choose push to talk on the Voice page.
- **Ping:** the **middle mouse button** (on a controller **L1 + R1** together) puts a pin where your crosshair
  points, with your name and its distance, for 5 seconds, then it fades out. Only your team sees it (in the game's
  team modes, the players in your colour; with no teams, everyone). Dead players can't ping. **Ping size** in
  Settings (50 % to 200 %) sets how big pins are on your screen.
- **Commands:**
  - `/s`, `/w`, `/y` and `/g` choose the mode (Speak, Whisper, Yell, Global), or say one line in it:
    `/w psst`, `/y over here`.
  - `/voice` lists the voices; `/voice robot` picks one.
  - `/mute <name>` hides a player's messages, only for you (`/unmute <name>`, `/unmute all`;
    `/mute` alone lists who is muted).
  - `/volume <name> <0-150>` sets one player's volume, only for you (100 is normal): their voice in Koetama
    and the babble of their typed lines. `/volume <name>` shows it, `/volume` lists who is not at 100 %. The start of a
    name is enough; `#<number>` picks one of two alike. The Voice page has the same as a slider per player, with Reset.
    It is remembered by the player's name, so a friend's level carries over to the next session.
  - `/wheel` shows the quick-chat wheel; `/wheel 2` lists folder 2; `/wheel 2.3 <text>` changes its 3rd line
    (a text ending in `/` makes it a folder); `/wheel 2.3 reset` and `/wheel reset` bring the defaults back.
  - `/hint`, `/window`, `/clear`, `/help`.
  - `/dummy`: three test figures in front of you (a whisperer, a speaker and a yeller) take turns on the same
    lines, 2 s apart, in every voice and several languages. Walk back and forth to see and hear
    every range. Only you see them. `/dummy 1`, `/dummy 2` and `/dummy 3` put just the whisperer,
    speaker or yeller in front of you (moved there if it is already out); `/dummy clear` removes them.

A bubble shows three lines; a longer message scrolls down inside it at reading pace (a thin bar shows
where it is) and the bubble stays up until it has finished. When a speaker is off screen, their bubble sits on the screen edge on their side, and a bubble always
stays wholly on screen. A bubble is only shown while you are within its reach (speech 35 m, a yell 55 m, a whisper 12 m): walk
away and it goes, walk back while it is up and it is there again. A player shows at most two bubbles: their newest message, with the one before it above it.
Bubbles never cover each other: when two would overlap, the higher one is raised above the other and
a thin line connects it to its speaker.

**Distances.** The host can change how far each mode carries: Settings has a bar with a knob each for
whisper, speak and yell (defaults 8, 25 and 40 m). The garbled zones follow at the same share (+50 %,
+40 %, +37.5 %). Reset brings the defaults back, and the host's choice is remembered. The other players see the
host's distances on their own Settings page (they cannot change them).

**Walls.** Walls, floors and roofs muffle voices: through a wall a voice sounds twice as far away,
unless there is a way around (an open door, a window, a corridor), which it then takes. Off by default;
the host can turn it on in Settings ("Walls muffle voices"). A map or game mode can decide for itself.

## For mod makers

Your map or game mode can work with the chat through a few registry keys (mods can't call each
other's functions): put the chat in lobby mode, keep Enter free for your own UI, ignore keys while a
player types, set the distances for your map, let dead players talk only to each other, make walls
muffle voices, and react to every message said (monsters that hear yelling, guards that notice
whispers, answers typed in chat).

```lua
SetBool("proxchat.lobby", true)          -- server: everyone hears everything while your lobby is up
SetBool("proxchat.block", true)          -- client: Enter must not open the chat (your own text input is up)
SetBool("proxchat.open", true)           -- client: open the chat now (your UI has the keys: a lobby, a "Chat" button)
SetBool("proxchat.close", true)          -- client: close the chat now (a round starts, a cutscene)
GetString("proxchat.key.open")           -- the chat's keys, for your hints: "Enter"; proxchat.key.pad: "L3 twice"
GetBool("proxchat.talking." .. me)       -- the voice chat's talk key is held: ignore it (proxchat.key.talk: which key)
GetBool("proxchat.typing." .. player)    -- true while that player types: ignore your own keys then
SetString("proxchat.ranges", "8,25,40")  -- server: your map's distances (whisper, speak, yell in m)
SetString("proxchat.channel." .. p, "dead")  -- server: p talks only to that channel (the dead), hears everyone
SetBool("proxchat.walls", true)          -- server: walls muffle voices on your map (false: they don't), over the host's setting
GetInt("proxchat.version")               -- any machine: the chat runs here (proxchat.alive: its last tick)
GetInt("proxchat.said.last")             -- host: chat events, proxchat.said.<n % 16>.player / mode / text / x y z / radius ...
```

**[API.md](API.md)** documents every key, where it can be read and written, and has example code
for each. When your mod sets a key wrongly, the chat says so on screen once (the key, what is wrong, the fix).

## Development

- `tools/test_proxchat.lua`: offline test with a mocked engine. Run
  `luajit -joff tools/test_proxchat.lua ./`; all checks must pass.
- `tools/babble_sounds.py`: makes the voice clips in `snd/`. Needs numpy, scipy and ffmpeg. Run
  `python tools/babble_sounds.py snd`.

MIT License.
