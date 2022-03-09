--!lua
-- System V-style init

--- Perform a system call
---@param call string
---@vararg any
local function syscall(call, ...)
  return coroutine.yield("syscall", call, ...)
end

---@param fmt string
---@vararg any
local function printf(fmt, ...)
  syscall("write", 1, string.format(fmt, ...))
end

--- Fork a new process and execute an executable
---@param path string
---@return integer
local function exec(path)
  local pid = syscall("fork", function()
    local _, errno = syscall("execve", path, {}, {})
    if errno then
      printf("Could not execute %s: %d\n", path, errno)
    end
  end)
  return pid
end

---@class InitEntry
---@field id string
---@field runlevels integer[]
---@field action string
---@field command string

---@class WatchEntry
---@field entry InitEntry
---@field pid integer

---@type InitEntry[]
local init_entries = {}
---@type WatchEntry[]
local watchlist = {}

do
  local fd, errno = syscall("open", "/etc/inittab", "r")
  if not fd then
    printf("Failed to open /etc/inittab: %s\n", errno)
    syscall("exit", 1)
  end
  ---@type string
  local content = syscall("read", fd, "a")
  syscall("close", fd)

  for line in content:gmatch("[^\r\n]+") do
    if line:sub(1, 1) == ":" then goto continue end

    local id, runlevels, action, command = line:match("^([^:]+):([^:]+):([^:]+):(.+)$")
    if id and runlevels and action and command then
      local entry = {
        id = id,
        runlevels = {},
        action = action,
        command = command
      }
      for runlevel in runlevels:gmatch("%d") do
        entry.runlevels[tonumber(runlevel)] = true
      end
      table.insert(init_entries, entry)
    end

    ::continue::
  end
end

for _, entry in ipairs(init_entries) do
  if entry.action == "once" then
    exec(entry.command)
  elseif entry.action == "wait" then
    syscall("wait", exec(entry.command))
  elseif entry.action == "respawn" then
    local watch = {
      entry = entry,
      pid = exec(entry.command)
    }
    table.insert(watchlist, watch)
  else
    printf("Unknown action for '%s': %s\n", entry.id, entry.action)
  end
end

while true do
  local sig, pid = coroutine.yield(0)

  if sig == "process_exit" then
    for _, watch in ipairs(watchlist) do
      if watch.pid == pid then
        watch.pid = exec(watch.entry.command)
        break
      end
    end
  end
end
