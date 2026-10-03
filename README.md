# Proximity Babble Chat (Teardown mod)

Text chat for Teardown multiplayer that works in **any level or game mode**. Players near you see what
you say as a **speech bubble** over your head and hear you **babble** in your own cartoon voice, from
where you stand. Four ways to be heard:

| mode | who gets it |
|---|---|
| **Whisper** | private (only sent to the players near enough) - players within 8 m: a pale lavender bubble and a breathy babble (⬚ boxes from 8 to 12 m). Walking up to someone mid-whisper shows nothing. |
| **Speak** | players within 25 m: a speech bubble, plus babble from your position. From 25 to 35 m they hear the babble and see the message as ⬚ boxes, with more real letters the closer they are. Their chat history keeps the most they made out, and the whole line appears if they come within 25 m while it's up. Walking toward someone who is mid-sentence shows their bubble too. |
| **Yell** | players within 40 m: an orange bubble and a raised voice (⬚ boxes from 40 to 55 m). |
| **Global** | every player: a plain chat line, with no bubble and no babble |

A message written in ALL CAPS makes its bubble shake, whatever the mode.

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

## Use

- **Enter**: open the chat line and the chat window. Enter again sends; **Esc** closes. A message can
  be up to 90 characters; a count shows from 60.
- **Tab** while typing, or click **Whisper / Speak / Yell / Global** at the end of the line, to choose
  how you speak. Your last choice is remembered.
- **Settings** (button at the top right of the chat window, or Options in the Mod Manager): pick your
  voice (Squeaky, Chirpy, Plain, Low, Deep, Robot; click to hear it), the hint, keeping the window
  open, your own bubble (third person: Show / Hide), how solid speech bubbles are (Off, 25 % to 100 %; the text stays readable) and the babble
  volume (a slider, Off to 100 %).
- **Commands:**
  - `/s`, `/w`, `/y` and `/g` choose the mode (Speak, Whisper, Yell, Global), or say one line in it:
    `/w psst`, `/y over here`.
  - `/voice` lists the voices; `/voice robot` picks one.
  - `/mute <name>` hides a player's messages, only for you (`/unmute <name>`, `/unmute all`;
    `/mute` alone lists who is muted).
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
+40 %, +37.5 %). Reset brings the defaults back, and the host's choice is remembered.

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
GetBool("proxchat.typing." .. player)    -- true while that player types: ignore your own keys then
SetString("proxchat.ranges", "8,25,40")  -- server: your map's distances (whisper, speak, yell in m)
SetString("proxchat.channel." .. p, "dead")  -- server: p talks only to that channel (the dead), hears everyone
SetBool("proxchat.walls", true)          -- server: walls muffle voices on your map (false: they don't), over the host's setting
GetInt("proxchat.version")               -- any machine: the chat runs here (proxchat.alive: its last tick)
GetInt("proxchat.said.last")             -- host: chat events, proxchat.said.<n % 16>.player / mode / text / x y z / radius ...
```

**[API.md](API.md)** documents every key, where it can be read and written, and has example code
for each.

## Development

- `tools/test_proxchat.lua`: offline test with a mocked engine. Run
  `luajit -joff tools/test_proxchat.lua ./`; all checks must pass.
- `tools/babble_sounds.py`: makes the voice clips in `snd/`. Needs numpy, scipy and ffmpeg. Run
  `python tools/babble_sounds.py snd`.

MIT License.
