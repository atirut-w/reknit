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

--- Execute a command
---@param cmd string
---@return integer
local function exec(cmd)
  local pid, errno = syscall("fork", function()
    local _, errno = syscall("execve", "/bin/sh.lua", {
      "/bin/sh.lua",
      "-c",
      cmd
    })
    if errno then
      printf("execve failed: %d\n", errno)
      syscall("exit", 1)
    end
  end)
  if not pid then
    printf("fork failed: %d\n", errno)
    return nil, errno
  else
    return pid
  end
end

---@class InitEntry
---@field id string
---@field runlevels boolean[]
---@field action string
---@field command string

---@type InitEntry[]
local init_table = {}

--- Load `/etc/inittab`
local function load_inittab()
  local fd, errno = syscall("open", "/etc/inittab", "r")
  if not fd then
    printf("Could not open /etc/inittab: %s\n", (
      (errno == 2 and "No such file or directory") or
      tostring(errno)
    ))
    return
  end
  local inittab = syscall("read", fd, "a")
  syscall("close", fd)

  init_table = {}

  for line in inittab:gmatch("[^\r\n]+") do
    if line:sub(1,1) == ":" then
      -- Comment
    elseif line == "" then
      -- Empty line
    else
      local id, runlevels, action, command = line:match("^([^:]+):([^:]+):([^:]+):(.+)$")
      if not id then
        printf("Bad init entry on line %d\n", line)
      else
        local entry = {
          id = id,
          runlevels = {},
          action = action,
          command = command,
        }
        for runlevel in runlevels:gmatch("%d") do
          entry.runlevels[tonumber(runlevel)] = true
        end
        init_table[#init_table + 1] = entry
      end
    end
  end
end

load_inittab()

--- List of active init entries with their PID as key
---@type InitEntry[]
local active_entries = {}
--- List of init entries to watch for respawn
---@type InitEntry[]
local respawn_entries = {}
--- Cynosure doesn't seem to have IPC yet so this will have to do for now
---@type integer[]
local telinit = {}

--- Switch to a new runlevel
---@param runlevel integer
local function switch_runlevel(runlevel)
  for pid, entry in pairs(active_entries) do
    if not entry.runlevels[runlevel] then
      printf("Would like to kill %d but the kill syscall is not implemented yet. :(\n", pid)
    end
  end

  for i, entry in pairs(init_table) do
    if entry.runlevels[runlevel] then
      if entry.command:sub(1, #"telinit ") == "telinit " then
        table.insert(telinit, tonumber(entry.command:sub(#"telinit " + 1)))
      else
        local pid, errno = exec(entry.command)
  
        if not pid then
          printf("Could not fork for entry %s: %d\n", entry.id, errno)
        elseif entry.action == "once" then
          active_entries[pid] = entry
        elseif entry.action == "wait" then
          syscall("wait", pid)
        elseif entry.action == "respawn" then
          respawn_entries[pid] = entry
        end
      end
    end
  end
end

switch_runlevel(1) -- Single user mode

while true do
  local sig, id = coroutine.yield(0)

  if sig == "process_exit" and respawn_entries[id] then
    local entry = respawn_entries[id]

    respawn_entries[id] = nil
    active_entries[id] = nil

    local pid, errno = exec(entry.command)
    if not pid then
      printf("Could not fork for entry %s: %d\n", entry.id, errno)
    else
      active_entries[pid] = entry
      respawn_entries[pid] = entry
    end
  elseif #telinit > 0 then
    switch_runlevel(table.remove(telinit, 1))
  end
end
