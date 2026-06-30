local lib = dofile("/v10av/lib.lua")
local config = lib.load_config()

local protocol = config.protocol or "v10_avionics_v1"
local aircraft = config.aircraft_id or "v10-ravager"
local timeout = config.display and config.display.link_timeout or 3.0

local monitor = lib.wrap_first("monitor")
local opened = lib.open_modems()

local target_id = nil
local engine_packet = nil
local engine_seen = 0
local last_local = {}
local status_line = "boot"
local button = { x1 = 1, y1 = 1, x2 = 1, y2 = 1 }

local function screen()
  return monitor or term
end

local function setup_screen()
  local s = screen()
  if monitor and monitor.setTextScale then
    monitor.setTextScale(config.display and config.display.monitor_scale or 0.5)
  end
  if s.setBackgroundColor then
    s.setBackgroundColor(colors.black)
  end
  if s.setTextColor then
    s.setTextColor(colors.white)
  end
end

local function clear()
  local s = screen()
  if s.clear then
    s.clear()
  end
  if s.setCursorPos then
    s.setCursorPos(1, 1)
  end
end

local function write_at(x, y, text, fg, bg)
  local s = screen()
  if s.setCursorPos then
    s.setCursorPos(x, y)
  end
  if bg and s.setBackgroundColor then
    s.setBackgroundColor(bg)
  end
  if fg and s.setTextColor then
    s.setTextColor(fg)
  end
  if s.write then
    s.write(tostring(text))
  else
    print(text)
  end
  if s.setBackgroundColor then
    s.setBackgroundColor(colors.black)
  end
  if s.setTextColor then
    s.setTextColor(colors.white)
  end
end

local function merged_telemetry()
  local data = {}
  if engine_packet and engine_packet.telemetry then
    lib.merge(data, engine_packet.telemetry)
  end
  lib.merge(data, last_local)
  return data
end

local function link_ok()
  return target_id ~= nil and (lib.now() - engine_seen) <= timeout
end

local function draw()
  local s = screen()
  local width, height = 51, 19
  if s.getSize then
    width, height = s.getSize()
  end
  local telemetry = merged_telemetry()
  local linked = link_ok()
  local engine_on = telemetry.engine_on == true

  clear()
  write_at(1, 1, "V-10 RAVAGER AVIONICS", colors.cyan)
  write_at(1, 2, string.rep("-", math.min(width, 32)), colors.gray)

  write_at(1, 4, "SPD", colors.lightGray)
  write_at(8, 4, lib.format_number(telemetry.speed, 1) .. " m/s", colors.white)
  write_at(1, 5, "ALT", colors.lightGray)
  write_at(8, 5, lib.format_number(telemetry.altitude, 1), colors.white)
  write_at(1, 6, "V/S", colors.lightGray)
  write_at(8, 6, lib.format_number(telemetry.vertical_speed, 1) .. " m/s", colors.white)
  write_at(1, 7, "AOA", colors.lightGray)
  write_at(8, 7, lib.format_number(telemetry.aoa, 1), colors.white)

  write_at(1, 9, "ENGINE", colors.lightGray)
  write_at(10, 9, engine_on and "ON" or "OFF", engine_on and colors.lime or colors.red)
  write_at(1, 10, "LINK", colors.lightGray)
  write_at(10, 10, linked and ("OK #" .. tostring(target_id)) or "NO DATA", linked and colors.lime or colors.red)
  write_at(1, 11, "CMD", colors.lightGray)
  write_at(10, 11, tostring(telemetry.last_command or "--"), colors.white)
  write_at(1, 12, "UPTIME", colors.lightGray)
  write_at(10, 12, lib.format_number(telemetry.uptime, 0) .. " s", colors.white)
  write_at(1, 13, "MASS", colors.lightGray)
  write_at(10, 13, lib.format_number(telemetry.mass, 0), colors.white)

  local label = engine_on and " STOP ENGINE " or " START ENGINE "
  local bx = 1
  local by = height - 2
  local bw = math.max(#label, 16)
  button = { x1 = bx, y1 = by, x2 = bx + bw - 1, y2 = by }
  write_at(bx, by, string.rep(" ", bw), colors.white, engine_on and colors.red or colors.green)
  write_at(bx + math.floor((bw - #label) / 2), by, label, colors.white, engine_on and colors.red or colors.green)

  write_at(1, height, status_line, colors.gray)
end

local function send_engine(value)
  local packet = {
    aircraft = aircraft,
    role = "display",
    type = "command",
    command = "set_engine",
    value = value,
    time = lib.now(),
  }
  local repeat_count = config.display and config.display.command_repeat or 2
  for _ = 1, repeat_count do
    lib.send(target_id, protocol, packet)
    sleep(0.03)
  end
  status_line = "engine command sent"
end

local function handle_packet(sender, message)
  if type(message) ~= "table" or message.aircraft ~= aircraft then
    return false
  end
  if message.role == "engine" and (message.type == "status" or message.type == "ack" or message.type == "pong") then
    target_id = sender
    engine_packet = message
    engine_seen = lib.now()
    status_line = "engine packet " .. tostring(message.type)
    return true
  end
  return false
end

setup_screen()

print("V-10 display node")
print("ID: " .. os.getComputerID())
print("Monitor: " .. tostring(monitor ~= nil))
print("Modems: " .. table.concat(opened, ", "))

local timer = os.startTimer(0.25)
local ping_timer = os.startTimer(1.0)
while true do
  local event, a, b, c = os.pullEvent()
  if event == "rednet_message" then
    if handle_packet(a, b) then
      draw()
    end
  elseif event == "monitor_touch" then
    local x, y = b, c
    if x >= button.x1 and x <= button.x2 and y >= button.y1 and y <= button.y2 then
      local telemetry = merged_telemetry()
      send_engine(not telemetry.engine_on)
      draw()
    end
  elseif event == "mouse_click" and not monitor then
    send_engine(not (merged_telemetry().engine_on == true))
    draw()
  elseif event == "timer" and a == timer then
    last_local = lib.read_telemetry(config)
    draw()
    timer = os.startTimer(0.25)
  elseif event == "timer" and a == ping_timer then
    lib.send(target_id, protocol, {
      aircraft = aircraft,
      role = "display",
      type = "command",
      command = "ping",
      time = lib.now(),
    })
    ping_timer = os.startTimer(1.0)
  elseif event == "terminate" then
    return
  end
end
