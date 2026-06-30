local SOURCE = "https://api.github.com/repos/R15ofc/v10-ravager-avionics/contents"
local CACHE_BUST = "v2"

local args = { ... }
local role = args[1]

local FILES = {
  { source = "v10av/config.lua", target = "/v10av/config.lua", overwrite = false },
  { source = "v10av/lib.lua", target = "/v10av/lib.lua", overwrite = true },
  { source = "v10av/display.lua", target = "/v10av/display.lua", overwrite = true },
  { source = "v10av/engine.lua", target = "/v10av/engine.lua", overwrite = true },
  { source = "v10av/audio/ack.dfpwm", target = "/v10av/audio/ack.dfpwm", overwrite = true, binary = true },
  { source = "v10av/audio/engine_off.dfpwm", target = "/v10av/audio/engine_off.dfpwm", overwrite = true, binary = true },
  { source = "v10av/audio/engine_on.dfpwm", target = "/v10av/audio/engine_on.dfpwm", overwrite = true, binary = true },
  { source = "v10av/audio/link.dfpwm", target = "/v10av/audio/link.dfpwm", overwrite = true, binary = true },
  { source = "v10av/audio/warning.dfpwm", target = "/v10av/audio/warning.dfpwm", overwrite = true, binary = true },
}

local function ensure_dir(path)
  local dir = fs.getDir(path)
  if dir and dir ~= "" and not fs.exists(dir) then
    fs.makeDir(dir)
  end
end

local function backup(path)
  if not fs.exists(path) then
    return nil
  end
  local candidate = path .. ".bak"
  local index = 1
  while fs.exists(candidate) do
    index = index + 1
    candidate = path .. ".bak" .. tostring(index)
  end
  fs.copy(path, candidate)
  return candidate
end

local function fetch(path, binary)
  local url = SOURCE .. "/" .. path .. "?ref=main&" .. CACHE_BUST
  local handle, err = http.get(url, {
    ["Accept"] = "application/vnd.github.raw",
    ["User-Agent"] = "ComputerCraft",
  }, binary == true)
  if not handle then
    error("download failed: " .. url .. " (" .. tostring(err) .. ")")
  end
  local code = handle.getResponseCode and handle.getResponseCode() or 200
  local body = handle.readAll()
  handle.close()
  if code < 200 or code >= 300 then
    error("download failed: " .. url .. " (HTTP " .. tostring(code) .. ")")
  end
  return body or ""
end

local function write_file(path, body, do_backup, binary)
  ensure_dir(path)
  if do_backup and fs.exists(path) then
    local saved = backup(path)
    if saved then
      print("backup " .. path .. " -> " .. saved)
    end
  end
  local handle = fs.open(path, binary and "wb" or "w")
  if not handle then
    error("cannot write " .. path)
  end
  handle.write(body or "")
  handle.close()
  print("wrote " .. path)
end

local function startup_body(selected_role)
  return [[
local role = "]] .. selected_role .. [["
local path = "/v10av/" .. role .. ".lua"
if shell then
  shell.run(path)
else
  dofile(path)
end
]]
end

if not http then
  error("HTTP API is disabled")
end

if role ~= "display" and role ~= "engine" then
  print("Usage:")
  print("  install.lua display")
  print("  install.lua engine")
  return
end

print("Installing V-10 avionics: " .. role)

for _, file in ipairs(FILES) do
  if file.overwrite or not fs.exists(file.target) then
    write_file(file.target, fetch(file.source, file.binary), file.overwrite, file.binary)
  else
    print("kept " .. file.target)
  end
end

write_file("/startup.lua", startup_body(role), true)
print("Done. Run: reboot")
