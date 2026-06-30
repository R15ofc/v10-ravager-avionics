local lib = dofile("/v10av/lib.lua")
local config = lib.load_config()

local protocol = config.protocol or "v10_avionics_v1"
local aircraft = config.aircraft_id or "v10-ravager"
local engine_side = config.engine and config.engine.side or "front"
local analog = config.engine and config.engine.analog ~= false
local on_value = config.engine and config.engine.on_value or 15
local off_value = config.engine and config.engine.off_value or 0
local interval = config.engine and config.engine.status_interval or 0.25

lib.write_engine(engine_side, analog, on_value)

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
  engine_on = true,
  last_command = "boot-on",
  last_display = nil,
  last_message_key = nil,
  altitude_called = {},
  low_altitude_last = 0,
  boot_time = lib.now(),
}

local function apply_engine(next_value, command, silent)
  local changed = state.engine_on ~= (next_value == true)
  state.engine_on = next_value == true
  state.last_command = command or "set"
  lib.write_engine(engine_side, analog, state.engine_on and on_value or off_value)
  if changed and not silent then
    if state.engine_on then
      lib.play_pattern(speaker, config, "engine_on")
      lib.play_pattern(speaker, config, "warming_up")
    else
      lib.play_pattern(speaker, config, "engine_off")
    end
  end
  return changed
end

local function altitude_alerts()
  return config.altitude_alerts or {}
end

local function process_altitude_alerts(telemetry)
  local alerts = altitude_alerts()
  if alerts.enabled == false or telemetry.altitude == nil then
    return
  end

  local altitude = tonumber(telemetry.altitude)
  if not altitude then
    return
  end

  local reset_above = tonumber(alerts.reset_above) or 120
  if altitude >= reset_above then
    state.altitude_called = {}
    return
  end

  local thresholds = alerts.thresholds or { 100, 50, 40, 30, 20 }
  for index = #thresholds, 1, -1 do
    local threshold = thresholds[index]
    local level = tonumber(threshold)
    if level and altitude <= level and not state.altitude_called[level] then
      state.altitude_called[level] = true
      lib.play_pattern(speaker, config, "altitude_" .. tostring(level))
      return
    end
  end

  local low_altitude = tonumber(alerts.low_altitude) or 20
  if altitude <= low_altitude then
    local now = lib.now()
    local repeat_after = tonumber(alerts.low_altitude_repeat) or 6.0
    if now - state.low_altitude_last >= repeat_after then
      state.low_altitude_last = now
      lib.play_pattern(speaker, config, "low_altitude")
    end
  end
end

local function make_packet(kind, telemetry)
  telemetry.engine_on = state.engine_on
  telemetry.engine_side = engine_side
  telemetry.audio = lib.audio_status(speaker, config, "link")
  telemetry.uptime = lib.now() - state.boot_time
  telemetry.last_command = state.last_command
  telemetry.altitude_alerts = altitude_alerts().enabled ~= false
  return {
    aircraft = aircraft,
    role = "engine",
    type = kind or "status",
    telemetry = telemetry,
  }
end

local function packet(kind)
  local telemetry = lib.read_telemetry(config)
  return make_packet(kind, telemetry)
end

local function broadcast_status()
  local telemetry = lib.read_telemetry(config)
  process_altitude_alerts(telemetry)
  lib.send(nil, protocol, make_packet("status", telemetry))
end

local function handle(sender, message)
  if type(message) ~= "table" or message.aircraft ~= aircraft then
    return
  end
  if message.type ~= "command" then
    return
  end

  state.last_display = sender
  local message_key = tostring(sender) .. ":" .. tostring(message.command) .. ":" .. tostring(message.time or "")
  if message.time and state.last_message_key == message_key then
    lib.send(sender, protocol, packet("ack"))
    return
  end
  state.last_message_key = message_key

  if message.command == "set_engine" then
    local changed = apply_engine(message.value == true, "remote")
    if not changed then
      lib.play_pattern(speaker, config, "ack")
    end
    lib.send(sender, protocol, packet("ack"))
  elseif message.command == "toggle_engine" then
    apply_engine(not state.engine_on, "remote-toggle")
    lib.send(sender, protocol, packet("ack"))
  elseif message.command == "ping" then
    lib.send(sender, protocol, packet("pong"))
  elseif message.command == "sound" then
    lib.play_pattern(speaker, config, message.pattern or "ack")
  end
end

lib.play_pattern(speaker, config, "link")

print("V-10 engine node")
print("ID: " .. os.getComputerID())
print("Engine side: " .. engine_side)
print("Speaker: " .. tostring(speaker ~= nil))
print("Audio: " .. lib.audio_status(speaker, config, "link"))

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
