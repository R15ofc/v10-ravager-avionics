local lib = dofile("/v10av/lib.lua")
local config = lib.load_config()

local protocol = config.protocol or "v10_avionics_v1"
local aircraft = config.aircraft_id or "v10-ravager"
local engine_side = config.engine and config.engine.side or "front"
local analog = config.engine and config.engine.analog ~= false
local on_value = config.engine and config.engine.on_value or 15
local off_value = config.engine and config.engine.off_value or 0
local interval = config.engine and config.engine.status_interval or 0.25

local speaker = lib.wrap_side(config.speaker and config.speaker.side, "speaker")
if not speaker then
  speaker = lib.wrap_first("speaker")
end

local opened = lib.open_modems()
if #opened == 0 then
  print("No modem found")
else
  print("Modem: " .. table.concat(opened, ", "))
end

local state = {
  engine_on = false,
  last_command = "boot",
  last_display = nil,
  boot_time = lib.now(),
}

local function apply_engine(next_value, command)
  state.engine_on = next_value == true
  state.last_command = command or "set"
  lib.write_engine(engine_side, analog, state.engine_on and on_value or off_value)
  lib.play_pattern(speaker, config, state.engine_on and "engine_on" or "engine_off")
end

local function packet(kind)
  local telemetry = lib.read_telemetry(config)
  telemetry.engine_on = state.engine_on
  telemetry.engine_side = engine_side
  telemetry.uptime = lib.now() - state.boot_time
  telemetry.last_command = state.last_command
  return {
    aircraft = aircraft,
    role = "engine",
    type = kind or "status",
    telemetry = telemetry,
  }
end

local function broadcast_status()
  lib.send(nil, protocol, packet("status"))
end

local function handle(sender, message)
  if type(message) ~= "table" or message.aircraft ~= aircraft then
    return
  end
  if message.type ~= "command" then
    return
  end

  state.last_display = sender

  if message.command == "set_engine" then
    apply_engine(message.value == true, "remote")
    lib.play_pattern(speaker, config, "ack")
    lib.send(sender, protocol, packet("ack"))
  elseif message.command == "toggle_engine" then
    apply_engine(not state.engine_on, "remote-toggle")
    lib.play_pattern(speaker, config, "ack")
    lib.send(sender, protocol, packet("ack"))
  elseif message.command == "ping" then
    lib.send(sender, protocol, packet("pong"))
  elseif message.command == "sound" then
    lib.play_pattern(speaker, config, message.pattern or "ack")
  end
end

apply_engine(false, "boot")
lib.play_pattern(speaker, config, "link")

print("V-10 engine node")
print("ID: " .. os.getComputerID())
print("Engine side: " .. engine_side)
print("Speaker: " .. tostring(speaker ~= nil))

local timer = os.startTimer(interval)
while true do
  local event, a, b, c = os.pullEvent()
  if event == "rednet_message" then
    handle(a, b)
  elseif event == "timer" and a == timer then
    broadcast_status()
    timer = os.startTimer(interval)
  elseif event == "terminate" then
    apply_engine(false, "terminate")
    return
  end
end
