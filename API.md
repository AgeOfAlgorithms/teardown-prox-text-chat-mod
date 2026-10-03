# Proximity Babble Chat: API for mod makers

Proximity Babble Chat is a global mod. A host turns it on for a session, and it then runs alongside
any map or game mode. Your mod can work with it through the **registry**, which every script on a
machine shares. Teardown mods can't call each other's functions, so these registry keys are the
whole interface:

| key | type | who writes it | where | what it does |
|---|---|---|---|---|
| [`proxchat.lobby`](#proxchatlobby) | bool | your **server** script | host | while true, everything said goes to everyone |
| [`proxchat.block`](#proxchatblock) | bool | your **client** script | each machine | while true, Enter does not open the chat |
| [`proxchat.typing.<player>`](#proxchattypingplayer) | bool | the chat | host: every player; each machine: its own player | true while that player is typing |
| [`proxchat.ranges`](#proxchatranges) | string | your **server** script | host | sets the Whisper / Speak / Yell distances |
| [`proxchat.said.*`](#proxchatsaid-chat-events) | several | the chat | host | an event for every message said |

Everything here is optional. If the chat isn't enabled, nothing reads the keys you set and every key
you read stays `false` / `0` / `""`, so your mod works the same without it.

## Before you start

- **Server or client.** In Teardown v2 multiplayer the host runs every `server.*` function, and every
  player (the host too) runs the `client.*` functions. The registry is per machine: a value set on
  the host is not visible on a guest's machine. The table above says where each key lives.
- **Set your keys every tick.** When the chat starts on the host, it clears every `proxchat.*` key.
  Scripts start in no fixed order, so a key you set once in `init` may be wiped. Setting it in
  `tick` is cheap and always right.
- **Player ids** are the engine's: `GetAllPlayers()` on the server, `GetLocalPlayer()` on a client.
  (`Players()` is a helper from `script/include/player.lua`; it only exists if you include that
  file.)

---

## `proxchat.lobby`

**Server, bool.** While it is true, the chat is in lobby mode: every message goes to every player
(Global), wherever they stand, and players can't switch to Whisper, Speak or Yell. Use it while your
game shows a lobby or menu and players are spread out or waiting.

```lua
-- your game mode's server script
function server.tick(dt)
	SetBool("proxchat.lobby", gamePhase == "lobby")   -- every tick: back to proximity chat when the round starts
end
```

Every chat event says whether it was said in your lobby (`lobby` field, below).

## `proxchat.block`

**Client, bool.** While it is true on a player's machine, Enter does not open the chat there. Set it
while your own UI needs the keyboard (a text field, a shop with typing, a name entry), so pressing
Enter for your UI doesn't also open the chat line. It doesn't close a chat line that is already open.

```lua
-- your client script
function client.tick(dt)
	SetBool("proxchat.block", nameEntryOpen)   -- every tick, true only while your text field is up
end
```

## `proxchat.typing.<player>`

**Bool, read only.** True while that player has the chat line open. While they type, the keys they
press are meant for the chat, so your mod should ignore them. Otherwise typing "q" in a message would
also fire your Q ability.

- **On the host** (server or client script): every player's state.
- **On any machine** (client script): that machine's own player, `GetLocalPlayer()`.

```lua
-- server: a per-player ability on Q that ignores players who are typing
function server.tick(dt)
	for _, p in ipairs(GetAllPlayers()) do
		if InputPressed("q", p) and not GetBool("proxchat.typing." .. p) then
			useAbility(p)
		end
	end
end
```

```lua
-- client: a local toggle on M that ignores your own typing
function client.tick(dt)
	if InputPressed("m") and not GetBool("proxchat.typing." .. GetLocalPlayer()) then
		musicOn = not musicOn
	end
end
```

```lua
-- server: freeze a player's movement while they type (an AFK-safe chat in a hectic mode)
function server.tick(dt)
	for _, p in ipairs(GetAllPlayers()) do
		if GetBool("proxchat.typing." .. p) then
			SetPlayerParam("walkingSpeed", 0, p)       -- an immediate param: set it every tick
		end
	end
end
```

## `proxchat.ranges`

**Server, string `"whisper,speak,yell"` in metres.** Sets how far each mode's words carry, for
example for a small map or a huge open one. Defaults: `"8,25,40"`.

- The garbled zone past each range follows at the same share: Whisper +50 %, Speak +40 %, Yell
  +37.5 % (so `8,25,40` garbles out to 12, 35 and 55 m).
- Values are rounded to whole metres and kept between 2 and 80 m, with whisper < speak < yell.
- It is applied when the string **changes**. The host can still move the distance bar in the chat's
  Settings afterwards; that wins until your string changes again.

```lua
-- a cramped indoor map: everything carries less
function server.tick(dt)
	SetString("proxchat.ranges", "5,15,30")
end
```

```lua
-- a storm: voices carry less while it lasts, back to normal after
function server.tick(dt)
	SetString("proxchat.ranges", stormActive and "4,12,20" or "8,25,40")
end
```

## `proxchat.said.*`: chat events

**Host only, read only.** Every message is also written to the host's registry as an event, so your
game can react to what players say and where they say it: monsters that hear yelling, guards that
notice whispers, a typed answer to a riddle, a vote. The last 16 events are kept in a ring:

| key | type | value |
|---|---|---|
| `proxchat.said.last` | int | the newest event number (counts up) |
| `proxchat.said.<n % 16>.player` | int | who said it |
| `... .mode` | string | `"whisper"`, `"speak"`, `"yell"` or `"global"` |
| `... .yell` | bool | `mode == "yell"` |
| `... .text` | string | the message (cleaned: no invisible or direction-changing characters) |
| `... .x`, `.y`, `.z` | float | where the speaker stood (feet) |
| `... .radius` | float | m: how far anyone hears anything, the babble included (defaults: whisper 12, speak 35, yell 55; global 0) |
| `... .wordsRadius` | float | m: how far the words are heard clearly (defaults: whisper 8, speak 25, yell 40; global 0) |
| `... .lobby` | bool | said while `proxchat.lobby` was true |

The radii are the distances in use when the message was said, so they follow the host's settings
and `proxchat.ranges`. Whispers are events too: the chat only sends a whisper's text to the players
near enough, but the host's scripts see every event.

### Reading events

Keep the last number you handled, and each tick handle every newer one (at most the 16 the ring
holds):

```lua
local saidSeen = nil

function server.tick(dt)
	local last = GetInt("proxchat.said.last")
	if saidSeen == nil or last < saidSeen then saidSeen = last end   -- (first tick, or the chat restarted)
	for n = math.max(saidSeen + 1, last - 15), last do
		local k = "proxchat.said." .. (n % 16) .. "."
		onChat({
			player = GetInt(k .. "player"),
			mode = GetString(k .. "mode"),
			text = GetString(k .. "text"),
			pos = Vec(GetFloat(k .. "x"), GetFloat(k .. "y"), GetFloat(k .. "z")),
			radius = GetFloat(k .. "radius"),
			wordsRadius = GetFloat(k .. "wordsRadius"),
			lobby = GetBool(k .. "lobby"),
		})
	end
	saidSeen = last
end
```

The examples below are `onChat` functions for that reader.

### Monsters that hear players

```lua
-- every monster within earshot turns toward the speaker; a yell enrages them
function onChat(e)
	if e.mode == "global" or e.lobby then return end
	for _, m in ipairs(monsters) do
		local d = VecLength(VecSub(GetBodyTransform(m.body).pos, e.pos))
		if d <= e.radius then
			m.target = e.pos                  -- go and look
			if e.mode == "yell" then m.angry = true end
		end
	end
end
```

### Guards that notice whispers (stealth)

```lua
-- whispering is quiet, not silent: a guard right next to you still hears it
function onChat(e)
	if e.mode ~= "whisper" then return end
	for _, g in ipairs(guards) do
		local d = VecLength(VecSub(GetBodyTransform(g.body).pos, e.pos))
		if d <= e.wordsRadius * 0.5 then
			raiseAlarm(g, e.player)
		end
	end
end
```

### Answers and commands typed in chat

```lua
-- a riddle: the first player to say the answer (any mode, any case) wins the round
function onChat(e)
	if roundOver then return end
	if e.text:lower():find("echo", 1, true) then
		roundOver = true
		awardPoint(e.player)
	end
end
```

```lua
-- "!ready" in chat marks a player ready while the lobby is up
function onChat(e)
	if e.lobby and e.text:lower() == "!ready" then
		ready[e.player] = true
	end
end
```

---

## Advanced: building the chat into your own mod

`chat_core.lua` can also be included in your own script, if your mod should ship with a chat
instead of relying on the host enabling Proximity Babble Chat. Don't do both: with the global mod
also enabled, players get two chats. For most mods the registry keys above are the better choice.

Copy `chat_core.lua`, `snd/` and `fonts/` into your mod, then:

```lua
#version 2
PC = {cfg = {chatR = 20, maxLen = 120}}   -- optional: overrides, before the include
#include "chat_core.lua"

PC.hooks.inLobby = function() return gamePhase == "lobby" end   -- server
PC.hooks.blockKeys = function() return nameEntryOpen end        -- client

function server.init() PC.serverInit() end
function server.tick(dt) PC.serverTick(dt) end
function client.init() PC.clientInit() end
function client.tick(dt) PC.clientTick(dt) end
function client.draw() PC.draw() end
```

Mode ids in this API are single letters: `"w"` Whisper, `"p"` Speak, `"y"` Yell, `"g"` Global.

| function | side | what |
|---|---|---|
| `PC.say(text, mode)` | client | say something as the local player; `mode` defaults to the line's current mode |
| `PC.mode()` / `PC.setMode(m)` | client | the input line's mode (`setMode` saves it as the player's default) |
| `PC.isTyping(p)` | both | server: any player; client: the local player |
| `PC.system(text)` | client | add a line only the local player sees |
| `PC.history([mode])` | client | the local history, oldest first (entries: `name`, `text`, `p`, `ch`, `far`, `sys`, `t`); with a mode, a filtered copy |
| `PC.setVoice(i)` | client | pick voice `i` (1 Squeaky, 2 Chirpy, 3 Plain, 4 Low, 5 Deep, 6 Robot) |
| `PC.page()` / `PC.setPage(pg)` | client | the chat window's page, `"chat"` or `"settings"` |

| hook (`PC.hooks.*`) | side | what |
|---|---|---|
| `inLobby()` | server | true: everything said goes to everyone (like `proxchat.lobby`) |
| `blockKeys()` | client | true: Enter does not open the chat (like `proxchat.block`) |
| `everyoneHears(speaker)` | client | true: the local player hears this speaker's Speak / Yell in full from anywhere (spectators, radios); whispers still need the whisper range |
| `onMessage(msg, heard)` | client | a message arrived: `msg = {id, p, name, ch, text}`, `heard` = the words this player made out (garbled in the buffer zone), or nil |
| `log(line)` | server | diagnostics |

```lua
-- client: a radio item - while you hold it, you hear your squad from anywhere
PC.hooks.everyoneHears = function(speaker)
	return holdingRadio and sameSquad(GetLocalPlayer(), speaker)
end

-- client: a subtitle log of what you heard, for your own HUD
PC.hooks.onMessage = function(msg, heard)
	if heard then addSubtitle(msg.name .. ": " .. heard) end
end
```

The full option list (`PC.cfg`) and more notes are at the top of `chat_core.lua`.
