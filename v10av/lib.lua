local lib = {}

local function pcall_value(fn, ...)
  local ok, value = pcall(fn, ...)
  if ok then
    return value
  end
  return nil
end

local function number_or_nil(value)
  value = tonumber(value)
  if value == nil or value ~= value then
    return nil
  end
  return value
end

function lib.load_config()
  local ok, config = pcall(dofile, "/v10av/config.lua")
  if not ok then
    error("bad config: " .. tostring(config))
  end
  if type(config) ~= "table" then
    error("bad config: expected table")
  end
  return config
end

function lib.open_modems()
  if not peripheral or not rednet then
    return {}
  end
  local opened = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      if not rednet.isOpen(name) then
        rednet.open(name)
      end
      table.insert(opened, name)
    end
  end
  return opened
end

function lib.wrap_first(kind)
  if not peripheral then
    return nil, nil
  end
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == kind then
      return peripheral.wrap(name), name
    end
  end
  return nil, nil
end

function lib.wrap_side(side, kind)
  if not peripheral or not side then
    return nil
  end
  if kind and peripheral.getType(side) ~= kind then
    return nil
  end
  return peripheral.wrap(side)
end

function lib.send(target, protocol, packet)
  if not rednet then
    return false
  end
  if target then
    rednet.send(target, packet, protocol)
  else
    rednet.broadcast(packet, protocol)
  end
  return true
end

function lib.format_number(value, decimals)
  if value == nil then
    return "--"
  end
  local fmt = "%." .. tostring(decimals or 1) .. "f"
  return string.format(fmt, value)
end

function lib.now()
  if os.epoch then
    return os.epoch("utc") / 1000
  end
  return os.clock()
end

function lib.read_ship()
  local data = {}
  if type(ship) ~= "table" then
    return data
  end

  local velocity = pcall_value(ship.getVelocity)
  if type(velocity) == "table" then
    local x = number_or_nil(velocity.x or velocity[1]) or 0
    local y = number_or_nil(velocity.y or velocity[2]) or 0
    local z = number_or_nil(velocity.z or velocity[3]) or 0
    data.speed = math.sqrt(x * x + y * y + z * z)
    data.vertical_speed = y
  end

  local position = pcall_value(ship.getWorldspacePosition) or pcall_value(ship.getPosition)
  if type(position) == "table" then
    data.altitude = number_or_nil(position.y or position[2])
  end

  data.mass = number_or_nil(pcall_value(ship.getMass))
  data.id = pcall_value(ship.getId) or pcall_value(ship.getSlug)

  local pitch = number_or_nil(pcall_value(ship.getPitch))
  if pitch then
    data.aoa = pitch
    data.aoa_source = "pitch"
  end

  return data
end

local gps_last = nil

function lib.read_gps(config)
  local timeout = config.telemetry and config.telemetry.gps_timeout or 0.05
  if not gps or not gps.locate then
    return {}
  end
  local x, y, z = gps.locate(timeout)
  if not x then
    return {}
  end
  local now = lib.now()
  local data = { altitude = y }
  if gps_last then
    local dt = now - gps_last.t
    if dt > 0 then
      local dx = x - gps_last.x
      local dy = y - gps_last.y
      local dz = z - gps_last.z
      data.speed = math.sqrt(dx * dx + dy * dy + dz * dz) / dt
      data.vertical_speed = dy / dt
    end
  end
  gps_last = { x = x, y = y, z = z, t = now }
  return data
end

function lib.merge(base, extra)
  base = base or {}
  for key, value in pairs(extra or {}) do
    if value ~= nil then
      base[key] = value
    end
  end
  return base
end

function lib.read_telemetry(config)
  local data = {
    time = lib.now(),
  }
  lib.merge(data, lib.read_ship())
  local gps_data = lib.read_gps(config)
  if data.speed == nil then
    data.speed = gps_data.speed
  end
  if data.vertical_speed == nil then
    data.vertical_speed = gps_data.vertical_speed
  end
  if data.altitude == nil then
    data.altitude = gps_data.altitude
  end
  return data
end

local dfpwm_checked = false
local dfpwm_module = nil

local function get_dfpwm()
  if dfpwm_checked then
    return dfpwm_module
  end
  dfpwm_checked = true
  if type(require) ~= "function" then
    return nil
  end
  local ok, module = pcall(require, "cc.audio.dfpwm")
  if ok and type(module) == "table" and type(module.make_decoder) == "function" then
    dfpwm_module = module
  end
  return dfpwm_module
end

local function clamp_volume(value)
  value = tonumber(value) or 1.0
  if value < 0 then
    return 0
  elseif value > 3 then
    return 3
  end
  return value
end

local function audio_file(config, pattern)
  local speaker_config = config.speaker or {}
  if speaker_config.audio_enabled == false then
    return nil
  end
  local base = speaker_config.audio_path or "/v10av/audio"
  return fs.combine(base, pattern .. ".dfpwm")
end

local function play_dfpwm(speaker, config, pattern, volume)
  if not fs or not os or not speaker or type(speaker.playAudio) ~= "function" then
    return false
  end

  local dfpwm = get_dfpwm()
  local path = audio_file(config, pattern)
  if not dfpwm or not path or not fs.exists(path) then
    return false
  end

  local handle = fs.open(path, "rb")
  if not handle then
    return false
  end

  local decoder = dfpwm.make_decoder()
  if type(speaker.stop) == "function" then
    speaker.stop()
  end

  while true do
    local chunk = handle.read(16 * 1024)
    if not chunk then
      break
    end
    local buffer = decoder(chunk)
    local ok, played = pcall(speaker.playAudio, buffer, volume)
    if not ok then
      handle.close()
      return false
    end
    while not played do
      os.pullEvent("speaker_audio_empty")
      ok, played = pcall(speaker.playAudio, buffer, volume)
      if not ok then
        handle.close()
        return false
      end
    end
  end
  handle.close()
  return true
end

function lib.audio_status(speaker, config, pattern)
  if not speaker then
    return "no speaker"
  end
  if type(speaker.playAudio) ~= "function" then
    return "no playAudio"
  end
  if not get_dfpwm() then
    return "no dfpwm"
  end
  local path = audio_file(config, pattern or "link")
  if not path or not fs.exists(path) then
    return "missing audio"
  end
  return "dfpwm"
end

function lib.play_pattern(speaker, config, pattern)
  if not speaker then
    return false
  end
  local volume = clamp_volume(config.speaker and config.speaker.volume or 1.0)

  return play_dfpwm(speaker, config, pattern, volume)
end

function lib.write_engine(side, analog, value)
  if analog and redstone.setAnalogOutput then
    redstone.setAnalogOutput(side, value)
  else
    redstone.setOutput(side, value > 0)
  end
end

return lib
