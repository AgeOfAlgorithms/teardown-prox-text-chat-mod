# Proximity Chat (Teardown mod)

Text chat for Teardown multiplayer that works in **any level or game mode**. Players near you see what
you say as a **speech bubble** over your head and hear you **babble** in your own cartoon voice, from
where you stand. Three ways to speak:

| mode | who gets it |
|---|---|
| **Speak** | players within 20 m: a speech bubble, plus babble from your position. From 20 to 30 m they hear the babble and see a "..." bubble, and the words appear if they come closer while it's up. WRITE IN CAPS (or end a word with `!`) to shout: shouted words carry to 45 m, and only those words get through. |
| **Whisper** | players within 5 m: a pale lavender bubble and a breathy babble ("..." from 5 to 8 m) |
| **Global** | every player: a plain chat line, with no bubble and no babble |

The chat window keeps **your own history**: every Global line, plus the Speak lines and whispers you
were close enough to hear when they were said. Every player's history is different.

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

- **Enter**: open the chat line and the chat window. Enter again sends; **Esc** closes.
- **Tab** while typing, or click **Speak / Whisper / Global** at the end of the line, to choose
  how you speak. Your last choice is remembered.
- **Settings** (button at the top right of the chat window): pick your voice (Squeaky, Chirpy, Plain,
  Low, Deep, Robot; click to hear it), the hint, and keeping the window open.
- **Commands:**
  - `/s`, `/w` and `/g` choose the mode (Speak, Whisper, Global), or say one line in it: `/w psst`.
  - `/voice` lists the voices; `/voice robot` picks one.
  - `/hint`, `/window`, `/clear`, `/help`.

## For game-mode makers

Mods can't call each other's functions, but the registry is shared. Your mod can use these keys:

```lua
SetBool("proxchat.lobby", true)          -- server: your lobby is up, everyone hears everything (false after)
SetBool("proxchat.block", true)          -- client: Enter must not open the chat (your own text input is up)
GetBool("proxchat.typing." .. player)    -- true while that player types: ignore your own keys then
```

You can also `#include "chat_core.lua"` in your own script. Its API is documented at the top of that
file.

## Development

- `tools/test_proxchat.lua`: offline test with a mocked engine. Run
  `luajit -joff tools/test_proxchat.lua ./`; all checks must pass.
- `tools/babble_sounds.py`: makes the voice clips in `snd/`. Needs numpy, scipy and ffmpeg. Run
  `python tools/babble_sounds.py snd`.

MIT License.
