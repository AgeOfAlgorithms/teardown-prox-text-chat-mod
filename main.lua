#version 2
-- Proximity Chat (global mod, Teardown v2 multiplayer): text chat with three speaking modes (nearby,
-- whisper, everyone), speech bubbles and a babble voice, in any level or game mode. Everything lives in chat_core.lua (namespaced:
-- the PC table, server.pc_*, shared.pc*, registry proxchat.*), so it cannot clash with the level's own
-- scripts (each script has its own Lua state anyway) and other mods can #include the same file.
-- This mod does not touch tools, player parameters or the level.
#include "chat_core.lua"

-- Working with any game mode (mods cannot call each other; the registry is shared by every script):
--   a game sets   SetBool("proxchat.lobby", true)   while its lobby / menu is up: everything said is heard by
--                                                    everyone ("everyone" mode only), back to false after
--   a game sets   SetBool("proxchat.block", true)    while Enter must not open the chat (its own text input)
--   a game reads  GetBool("proxchat.typing." .. p)    true while player p types (ignore its own keys then)
PC.hooks.inLobby = function() return GetBool("proxchat.lobby") end
PC.hooks.blockKeys = function() return GetBool("proxchat.block") end

function server.init()
	PC.serverInit()
end

function server.tick(dt)
	PC.serverTick(dt)
end

function client.init()
	PC.clientInit()
end

function client.tick(dt)
	PC.clientTick(dt)
end

function client.draw()
	PC.draw()
end
