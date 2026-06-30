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
local buttons = {}
local display_engine_on = true
local pending_engine_on = nil
local pending_until = 0

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

local function fit(text, width)
  text = tostring(text == nil and "--" or text)
  if width <= 0 then
    return ""
  elseif #text <= width then
    return text
  elseif width == 1 then
    return string.sub(text, 1, 1)
  end
  return string.sub(text, 1, width - 1) .. "~"
end

local function draw_button(action, value, x, y, label, bg, min_width, height)
  local width = math.max(min_width or 0, #label)
  local button_height = math.max(1, height or 1)
  local x2 = x + width - 1
  local y2 = y + button_height - 1
  table.insert(buttons, {
    action = action,
    value = value,
    x1 = x,
    y1 = y,
    x2 = x2,
    y2 = y2,
  })
  for row = y, y2 do
    write_at(x, row, string.rep(" ", width), colors.white, bg)
  end
  write_at(x + math.floor((width - #label) / 2), y + math.floor((button_height - 1) / 2), label, colors.white, bg)
  return x2 + 2
end

local function merged_telemetry()
  local data = {}
  if engine_packet and engine_packet.telemetry then
    lib.merge(data, engine_packet.telemetry)
  end
  for key, value in pairs(last_local or {}) do
    if data[key] == nil and value ~= nil then
      data[key] = value
    end
  end
  if pending_engine_on ~= nil and lib.now() <= pending_until then
    data.engine_on = pending_engine_on
    data.last_command = "pending"
  elseif pending_engine_on ~= nil then
    pending_engine_on = nil
  elseif data.engine_on ~= nil then
    display_engine_on = data.engine_on == true
  else
    data.engine_on = display_engine_on
  end
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
  local engine_known = telemetry.engine_on ~= nil
  local engine_on = telemetry.engine_on == true
  local engine_text = engine_known and (engine_on and "ON" or "OFF") or "--"
  local left_value_x = 7
  local right_key_x = math.max(18, math.floor(width / 2) + 1)
  local right_value_x = math.min(width, right_key_x + 6)
  local left_value_width = math.max(1, right_key_x - left_value_x - 1)
  local right_value_width = math.max(1, width - right_value_x + 1)
  buttons = {}

  clear()

  local function row(y, left_key, left_value, left_color, right_key, right_value, right_color)
    if y >= height then
      return
    end
    write_at(1, y, fit(left_key, 5), colors.lightGray)
    write_at(left_value_x, y, fit(left_value, left_value_width), left_color or colors.white)
    if width >= 24 and right_key then
      write_at(right_key_x, y, fit(right_key, 5), colors.lightGray)
      write_at(right_value_x, y, fit(right_value, right_value_width), right_color or colors.white)
    end
  end

  row(1, "ENG", engine_text, engine_on and colors.lime or colors.red, "LINK", linked and ("OK #" .. tostring(target_id)) or "NO DATA", linked and colors.lime or colors.red)
  row(2, "ALT", lib.format_number(telemetry.altitude, 1), colors.white, "CMD", telemetry.last_command or "--", colors.white)
  row(3, "SPD", lib.format_number(telemetry.speed, 1) .. " m/s", colors.white, "V/S", lib.format_number(telemetry.vertical_speed, 1) .. " m/s", colors.white)
  row(4, "AOA", lib.format_number(telemetry.aoa, 1), colors.white, "SIDE", telemetry.engine_side or "--", colors.white)
  row(5, "MASS", lib.format_number(telemetry.mass, 0), colors.white, "SHIP", telemetry.id or "--", colors.white)
  row(6, "UP", lib.format_number(telemetry.uptime, 0) .. " s", colors.white, nil, nil, nil)
  row(7, "RX", linked and (lib.format_number(lib.now() - engine_seen, 1) .. " s") or "--", linked and colors.lime or colors.red, "PC", target_id or "--", colors.white)
  row(8, "ALR", telemetry.altitude_alerts and "ON" or "--", telemetry.altitude_alerts and colors.lime or colors.gray, nil, nil, nil)

  local button_top = height
  if button_top > 1 then
    write_at(1, button_top - 1, fit(status_line, width), colors.gray)
  end

  local button_bg = engine_known and (engine_on and colors.green or colors.red) or colors.gray
  local label = " ENGINE: " .. engine_text .. " "
  draw_button("engine", engine_known and not engine_on or true, 1, button_top, label, button_bg, width, 1)
end

local function send_command(packet, repeat_count)
  repeat_count = repeat_count or (config.display and config.display.command_repeat or 2)
  for _ = 1, repeat_count do
    if target_id then
      lib.send(target_id, protocol, packet)
    end
    lib.send(nil, protocol, packet)
    sleep(0.03)
  end
end

local function set_local_engine(value)
  display_engine_on = value == true
  pending_engine_on = value == true
  pending_until = lib.now() + timeout
  if engine_packet and engine_packet.telemetry then
    engine_packet.telemetry.engine_on = value == true
    engine_packet.telemetry.last_command = "pending"
  end
  status_line = value and "engine on sent" or "engine off sent"
end

local function send_engine(value, already_local)
  if not already_local then
    set_local_engine(value)
  end
  local packet = {
    aircraft = aircraft,
    role = "display",
    type = "command",
    command = "set_engine",
    value = value,
    time = lib.now(),
  }
  send_command(packet)
end

local function toggle_engine()
  local value = not (merged_telemetry().engine_on == true)
  set_local_engine(value)
  draw()
  send_engine(value, true)
end

local function send_sound(pattern)
  send_command({
    aircraft = aircraft,
    role = "display",
    type = "command",
    command = "sound",
    pattern = pattern,
    time = lib.now(),
  }, 1)
  status_line = "sound " .. tostring(pattern) .. " sent"
end

local function find_button(x, y)
  for _, candidate in ipairs(buttons) do
    if x >= candidate.x1 and x <= candidate.x2 and y >= candidate.y1 and y <= candidate.y2 then
      return candidate
    end
  end
  return nil
end

local function handle_packet(sender, message)
  if type(message) ~= "table" or message.aircraft ~= aircraft then
    return false
  end
  if message.role == "engine" and (message.type == "status" or message.type == "ack" or message.type == "pong") then
    target_id = sender
    engine_packet = message
    engine_seen = lib.now()
    if message.telemetry and message.telemetry.engine_on ~= nil then
      display_engine_on = message.telemetry.engine_on == true
    end
    if message.telemetry and message.telemetry.engine_on == pending_engine_on then
      pending_engine_on = nil
    end
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
    local clicked = find_button(x, y)
    if clicked then
      if clicked.action == "engine" then
        toggle_engine()
      elseif clicked.action == "sound" then
        send_sound(clicked.value)
      end
    else
      local _, height = screen().getSize()
      if y == height then
        toggle_engine()
      end
    end
  elseif event == "mouse_click" and not monitor then
    local y = c
    local _, height = screen().getSize()
    if y == height then
      toggle_engine()
    end
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
