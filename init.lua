--[[
Mineysocket
Copyright (C) 2019 Robert Lieback <robertlieback@zetabyte.de>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU Lesser General Public License as published by
the Free Software Foundation; either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU Lesser General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
--]]

mineysocket = {}  -- global namespace

-- configuration
mineysocket.host_ip = minetest.settings:get("mineysocket.host_ip")
mineysocket.host_port = minetest.settings:get("mineysocket.host_port")

-- Workaround for bug, where default values return only nil
if not mineysocket.host_ip then
  mineysocket.host_ip = "127.0.0.1"
end
if not mineysocket.host_port then
  mineysocket.host_port = 29999
end

mineysocket.debug = true  -- set to true to show all log levels
mineysocket.max_clients = 1000

-- Global variables
mineysocket.chatcommands = {}

-- Load external libs
local ie
if minetest.request_insecure_environment then
  ie = minetest.request_insecure_environment()
end
if not ie then
  error("mineysocket has to be added to the secure.trusted_mods in minetest.conf")
end

local luasocket = ie.require("socket.core")
if not luasocket then
  error("luasocket is not installed or was not found...")
end
mineysocket.json = ie.require("cjson")
if not mineysocket.json then
  error("lua-cjson is not installed or was not found...")
end

-- setup network server
local server, err = luasocket.tcp()
if not server then
  minetest.log("action", err)
  error("exit")
end

local bind, err = server:bind(mineysocket.host_ip, mineysocket.host_port)
if not bind then
  error("mineysocket: " .. err)
end
local listen, err = server:listen(mineysocket.max_clients)
if not listen then
  error("mineysocket: Socket listen error: " .. err)
end
minetest.log("action", "mineysocket: " .. "listening on " .. mineysocket.host_ip .. ":" .. tostring(mineysocket.host_port))

server:settimeout(0)
mineysocket.host_ip, mineysocket.host_port = server:getsockname()
if not mineysocket.host_ip or not mineysocket.host_port then
  error("mineysocket: Couldn't open server port!")
end

mineysocket["socket_clients"] = {}  -- a table with all connected clients with there options

-- receive network data and process them
minetest.register_globalstep(function(dtime)
  mineysocket.receive()
end)


-- Clean shutdown
minetest.register_on_shutdown(function()
  minetest.log("action", "mineysocket: Closing port...")
  for clientid, client in pairs(mineysocket["socket_clients"]) do
    mineysocket["socket_clients"][clientid].socket:close()
  end
  server:close()
end)


-- receive data from clients
mineysocket.receive = function()
  local data, ip, port, clientid, client, err
  local result = false

  -- look for new client connections
  client, err = server:accept()
  if client then
    ip, port = client:getpeername()
    clientid = ip .. ":" .. port
    mineysocket.log("action", "New connection from " .. ip .. " " .. port)

    client:settimeout(0)
    -- register the new client
    if not mineysocket["socket_clients"][clientid] then
      mineysocket["socket_clients"][clientid] = {}
      mineysocket["socket_clients"][clientid].socket = client
      mineysocket["socket_clients"][clientid].last_message = minetest.get_server_uptime()
      mineysocket["socket_clients"][clientid].buffer = ""
      mineysocket["socket_clients"][clientid].eom = nil

      if ip == "127.0.0.1" then  -- skip authentication for 127.0.0.1
        mineysocket["socket_clients"][clientid].auth = true
        mineysocket["socket_clients"][clientid].playername = "localhost"
        mineysocket["socket_clients"][clientid].events = {}
      else
        mineysocket["socket_clients"][clientid].auth = false
      end
    end
  else
    if err ~= "timeout" then
      mineysocket.log("error", "Connection error \"" .. err .. "\"")
      client:close()
    end
  end

  -- receive data
  for clientid, client in pairs(mineysocket["socket_clients"]) do
    local complete_data, err, data = mineysocket["socket_clients"][clientid].socket:receive("*a")
    -- there are never complete_data, cause we don't receive lines
    -- Note: err is "timeout" every time when there are no client data, cause we set timeout to 0 and
    -- we don't want to wait and block lua/minetest for clients to send data
    if err ~= "timeout" then
      mineysocket["socket_clients"][clientid].socket:close()
      -- cleanup
      if err == "closed" then
        -- remove this client from any chatcommand subscription lists
        for cmd, entry in pairs(mineysocket.chatcommands) do
          if entry.clients[clientid] then
            entry.clients[clientid] = nil
          end
        end
        mineysocket["socket_clients"][clientid] = nil
        mineysocket.log("action", "Connection to ".. clientid .." was closed")
        return
      else
        mineysocket.log("action", err)
      end
    end
    if data and data ~= "" then
      -- store time of the last message for cleanup of old connection
      mineysocket["socket_clients"][clientid].last_message = minetest.get_server_uptime()

      if not string.find(data, "\n") then
        -- fill a buffer and wait for the linebreak
        if not mineysocket["socket_clients"][clientid].buffer then
          mineysocket["socket_clients"][clientid].buffer = data
        else
          mineysocket["socket_clients"][clientid].buffer = mineysocket["socket_clients"][clientid].buffer .. data
        end
        if mineysocket["socket_clients"][clientid].auth == false then  -- limit buffer size for unauthenticated connections
          if mineysocket["socket_clients"][clientid].buffer and string.len(mineysocket["socket_clients"][clientid].buffer) + string.len(data) > 10 then
            mineysocket["socket_clients"][clientid].buffer = nil
          end
        end
        mineysocket.receive()
        return
      else
        -- append to buffer
        if not mineysocket["socket_clients"][clientid].buffer then
          mineysocket["socket_clients"][clientid].buffer = data
        else
          mineysocket["socket_clients"][clientid].buffer = mineysocket["socket_clients"][clientid].buffer .. data
        end

        -- for unauthenticated clients, limit buffer size if we still don't have a newline yet
        if mineysocket["socket_clients"][clientid].auth == false then
          local buf = mineysocket["socket_clients"][clientid].buffer or ""
          if not string.find(buf, "\n", 1, true) and string.len(buf) > 10 then
            mineysocket["socket_clients"][clientid].buffer = nil
            return
          end
        end

        -- process all complete commands in the buffer, line by line
        local buf = mineysocket["socket_clients"][clientid].buffer or ""
        while true do
          local nl_pos = string.find(buf, "\n", 1, true)
          if not nl_pos then
            break
          end

          -- detect and set EOM if needed based on first seen newline (\n or \r\n)
          local used_eom = "\n"
          local line_end = nl_pos - 1
          if nl_pos > 1 and string.sub(buf, nl_pos - 1, nl_pos - 1) == "\r" then
            used_eom = "\r\n"
            line_end = nl_pos - 2
          end
          if mineysocket["socket_clients"][clientid].eom == nil then
            mineysocket["socket_clients"][clientid].eom = used_eom
          end

          local line = ""
          if line_end >= 1 then
            line = string.sub(buf, 1, line_end)
          end

          -- log and process a single command line (without EOM)
          if line ~= "" then
            mineysocket.log("action", "Received: \n" .. line)
          end
          mineysocket.process_command(line, clientid)

          -- remove processed line (including newline) from buffer and continue
          buf = string.sub(buf, nl_pos + 1)
        end
        -- keep remainder (incomplete line) in buffer
        mineysocket["socket_clients"][clientid].buffer = buf
      end
    end
  end
end


-- run lua code send by the client
function run_lua(input, clientid, ip, port)
  local start_time, err
  local output = {}

  start_time = minetest.get_server_uptime()

  -- log the (shortend) code
  if string.len(input["lua"]) > 120 then
    mineysocket.log("action", "execute: " .. string.sub(input["lua"], 0, 120) .. " ...", ip, port)
  else
    mineysocket.log("action", "execute: " .. input["lua"], ip, port)
  end

  -- run
  local f, syntaxError = loadstring(input["lua"])
  -- todo: is there a way to get also warning like "Undeclared global variable ... accessed at ..."?

  if f then
    local status, result1, result2, result3, result4, result5 = pcall(f, clientid)  -- Get the clientid with "...". Example: "mineysocket.send(..., output)"
    -- is there a more elegant way for unlimited results?

    if status then
      output["result"] = { result1, result2, result3, result4, result5 }
      if mineysocket.debug then
        local json_output = mineysocket.json.encode(output)
        if string.len(json_output) > 120 then
          mineysocket.log("action", string.sub(json_output, 0, 120) .. " ..." .. " in " .. (minetest.get_server_uptime() - start_time) .. " seconds", ip, port)
        else
          mineysocket.log("action", json_output .. " in " .. (minetest.get_server_uptime() - start_time) .. " seconds", ip, port)
        end
      end
      return output
    else
      err = result1
    end
  else
    err = syntaxError
  end

  -- send lua errors
  if err then
    output["error"] = err
    mineysocket.log("error", "Error " .. err .. " in command", ip, port)
    return output
  end
end


-- process a single command line (without trailing newline)
mineysocket.process_command = function(line, clientid)
  -- detect peer info for logging and auth decisions
  local ip, port = nil, nil
  if mineysocket["socket_clients"][clientid] and mineysocket["socket_clients"][clientid].socket then
    ip, port = mineysocket["socket_clients"][clientid].socket:getpeername()
  end

  -- simple alive check
  if line == "ping" then
    mineysocket["socket_clients"][clientid].socket:send("pong" .. (mineysocket["socket_clients"][clientid].eom or "\n"))
    return
  end

  if not line or line == "" then
    return
  end

  -- parse data as json
  local status, input = pcall(mineysocket.json.decode, line)
  if not status then
    local err = input
    minetest.log("error", "mineysocket: " .. mineysocket.json.encode({ error = err }))
    mineysocket.log("error", "JSON-Error: " .. tostring(err), ip, port)
    mineysocket.send(clientid, mineysocket.json.encode({ error = "JSON decode error - " .. tostring(err) }))
    return
  end

  local result = false
  -- is it a known client, or do we need authentication?
  if mineysocket["socket_clients"][clientid].auth == true then
    -- commands:
    if input["lua"] then
      result = run_lua(input, clientid, ip, port)
    end

    if input["register_event"] then
      result = mineysocket.register_event(clientid, input["register_event"])
    end

    if input["unregister_event"] then
      result = mineysocket.unregister_event(clientid, input["unregister_event"])
    end

    if input["register_chatcommand"] then
      result = mineysocket.register_chatcommand(clientid, input["register_chatcommand"])
    end

    if input["playername"] and input["password"] then
      result = mineysocket.authenticate(input, clientid, ip, port, mineysocket["socket_clients"][clientid].socket)
    end

    if input["id"] and result ~= false then
      result["id"] = input["id"]
    end

    if result ~= false then
      mineysocket.send(clientid, mineysocket.json.encode(result))
    else
      mineysocket.send(clientid, mineysocket.json.encode({ error = "Unknown command" }))
    end

  else
    -- we need authentication
    if input["playername"] and input["password"] then
      mineysocket.send(clientid, mineysocket.json.encode(mineysocket.authenticate(input, clientid, ip, port, mineysocket["socket_clients"][clientid].socket)))
    else
      mineysocket.send(clientid, mineysocket.json.encode({ error = "Unknown command" }))
    end
  end
end


-- authenticate clients
mineysocket.authenticate = function(input, clientid, ip, port, socket)
    local player = minetest.get_auth_handler().get_auth(input["playername"])

    -- we skip authentication for 127.0.0.1 and just accept everything
    if ip == "127.0.0.1" then
      mineysocket.log("action", "Player '" .. input["playername"] .. "' connected successful", ip, port)
      mineysocket["socket_clients"][clientid].playername = input["playername"]
      return { result = { "auth_ok", clientid }, id = "auth" }
    else
      -- others need a valid playername and password
      if player and minetest.check_password_entry(input["playername"], player['password'], input["password"]) and minetest.check_player_privs(input["playername"], { server = true }) then
        mineysocket.log("action", "Player '" .. input["playername"] .. "' authentication successful", ip, port)
        mineysocket["socket_clients"][clientid].auth = true
        mineysocket["socket_clients"][clientid].playername = input["playername"]
        mineysocket["socket_clients"][clientid].events = {}
        return { result = { "auth_ok", clientid }, id = "auth" }
      else
        mineysocket.log("error", "Wrong playername ('" .. input["playername"] .. "') or password", ip, port)
        mineysocket["socket_clients"][clientid].auth = false
        return { error = "authentication error", id = "auth" }
      end
    end
end


-- send data to the client
mineysocket.send = function(clientid, data)
  local data = data .. mineysocket["socket_clients"][clientid]["eom"]  -- eom is the terminator
  local size = string.len(data)

  local chunk_size = 4096

  if size < chunk_size then
    -- we send in one package
    mineysocket["socket_clients"][clientid].socket:send(data)
  else
    -- we split into multiple packages
    for i = 0, math.floor(size / chunk_size) do
      mineysocket["socket_clients"][clientid].socket:send(
        string.sub(data, i * chunk_size, chunk_size + (i * chunk_size) - 1)
      )
      luasocket.sleep(0.001)  -- Or buffer fills to fast
      -- todo: Protocol change, that every chunked message needs a response before sending the next
    end
  end
end

-- register for event
mineysocket.register_event = function(clientid, eventname)
  mineysocket["socket_clients"][clientid].events[#mineysocket["socket_clients"][clientid].events+1] = eventname
  return { result = "ok" }
end

-- unregister for event
mineysocket.unregister_event = function(clientid, eventname)
  for index, value in pairs(mineysocket["socket_clients"][clientid].events) do
    if value == eventname then
      table.remove( mineysocket["socket_clients"][clientid].events, index )
      break
    end
  end
  return { result = "ok" }
end


-- send event data to clients, who are registered for this event
mineysocket.send_event = function(data)
  for clientid, values in pairs(mineysocket["socket_clients"]) do
    local client_events = mineysocket["socket_clients"][clientid].events

    for _, event_data in ipairs(client_events) do
        local registered_event_name = event_data["event"]
        local received_event_name = data["event"][1]

        if registered_event_name == received_event_name then
            mineysocket.log("action", "Sending event: " .. received_event_name)
            mineysocket.send(clientid, mineysocket.json.encode(data))
            break
        end
    end
  end
end


-- Register (or subscribe to existing) chat command
mineysocket.register_chatcommand = function(clientid, definition)
  -- definition can be a string (command name) or table
  local cmd
  local params
  local description
  local privs

  if type(definition) == "string" then
    cmd = definition
  elseif type(definition) == "table" then
    cmd = definition.name or definition.command or definition.cmd
    params = definition.params
    description = definition.description
    privs = definition.privs
  end

  if not cmd or cmd == "" then
    return { error = "invalid chatcommand name" }
  end

  -- Normalize values / defaults
  params = params or "<params>"
  description = description or ("Mineysocket dynamic command '/" .. cmd .. "'")
  privs = privs or { server = true }  -- default to server priv to avoid abuse

  local existing = mineysocket.chatcommands[cmd]
  if not existing then
    -- First time registration with Minetest API
    mineysocket.chatcommands[cmd] = {
      clients = { [clientid] = true },
      def = { params = params, description = description, privs = privs }
    }
    minetest.register_chatcommand(cmd, {
      params = params,
      description = description,
      privs = privs,
      func = function(name, param)
        mineysocket.send_event({ event = { "chatcommand_" .. cmd, name, param } })
        return true, "Command received"
      end
    })
    mineysocket.log("action", "Registered new chatcommand '/" .. cmd .. "' via client " .. clientid)
  end
  return { result = "ok" }
end


-- BEGIN global event registration
minetest.register_on_shutdown(function()
  mineysocket.send_event({ event = { "shutdown" } })
end)
minetest.register_on_player_hpchange(function(player, hp_change, reason)
  mineysocket.send_event({ event = { "player_hpchanged", player:get_player_name(), hp_change, reason } })
end, false)
minetest.register_on_dieplayer(function(player, reason)
  mineysocket.send_event({ event = { "player_died", player:get_player_name(), reason } })
end)
minetest.register_on_respawnplayer(function(player)
  mineysocket.send_event({ event = { "player_respawned", player:get_player_name() } })
end)
minetest.register_on_joinplayer(function(player)
  mineysocket.send_event({ event = { "player_joined", player:get_player_name() } })
end)
minetest.register_on_leaveplayer(function(player, timed_out)
  mineysocket.send_event({ event = { "player_left", player:get_player_name(), timed_out } })
end)
minetest.register_on_auth_fail(function(name, ip)
  mineysocket.send_event({ event = { "auth_failed", name, ip } })
end)
minetest.register_on_cheat(function(player, cheat)
  mineysocket.send_event({ event = { "player_cheated", player:get_player_name(), cheat } })
end)
minetest.register_on_chat_message(function(name, message)
  mineysocket.send_event({ event = { "chat_message", name, message } })
end)
-- END global event registration


-- just a logging function
mineysocket.log = function(level, text, ip, port)
  if mineysocket.debug or level ~= "action" then
    if text then
      if ip and port then
        minetest.log(level, "mineysocket: " .. text .. " from " .. ip .. ":" .. port)
      else
        minetest.log(level, "mineysocket: " .. ": " .. text)
      end
    end
  end
end
