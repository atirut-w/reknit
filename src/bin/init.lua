--!lua
-- System V-style init

--- Perform a system call
---@param call string
---@vararg any
local function syscall(call, ...)
  local result, err = coroutine.yield("syscall", call, ...)
  if not result and err then error(call..": "..err) end
  return result, err
end

---@param fmt string
---@vararg any
local function printf(fmt, ...)
  syscall("write", 1, string.format(fmt, ...))
end

if syscall("getpid") ~= 1 then
  printf("Reknit must be run as process 1\n")
  syscall("exit", 1)
end

printf("init: Reknit is starting\n")

--- Execute a command
---@param cmd string
---@return integer
local function exec(cmd, tty)
  local pid, errno = syscall("fork", function()
    if tty then
      local fd, err = syscall("open", "/dev/"..tty, "rw")
      if not fd then syscall("exit", err) end

      for i=0, 2, 1 do
        syscall("dup2", fd, i)
      end

      syscall("close", fd)
    end

    local _, errno = syscall("execve", "/bin/sh.lua", {
      "-c",
      cmd,
      [0] = "[init_worker]"
    })

    if errno then
      printf("init: execve failed: %d\n", errno)
      syscall("exit", 1)
    end
  end)

  if not pid then
    printf("init: fork failed: %d\n", errno)
    return nil, errno

  else
    return pid
  end
end

-- Load a script and execute it with Reknit's environment.
-- Only used internally, mostly for security reasons.
local function exec_script(file)
  local okay, emsg
  if dofile then
    pcall(dofile, file)

  else
    local fd, err = syscall("open", file, "r")
    if not fd then
      printf("open '%s' failed: %d\n", file, err)
      return nil, err
    end

    local data = syscall("read", fd, "a")
    syscall("close", fd)

    local ok, lerr = load(data, "="..file, "t", _G)
    if not ok then
      printf("Load failed - %s\n", lerr)
      return

    else
      okay, emsg = pcall(ok)
    end
  end

  if not okay and emsg then
    printf("Execution failed - %s\n", emsg)
    return
  end

  return true
end

-- Load /lib/package.lua - because where else do you do it?
-- Environments propagate to process children in certain
-- Cynosure 2 configurations, and this is the only real way to
-- ensure that every process has access to the 'package' library.
--
-- This may change in the future.
assert(exec_script("/lib/package.lua"))

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

        entry.index = #init_table + 1
        init_table[#init_table + 1] = entry
        init_table[entry.id] = entry -- for 'start' and 'stop'
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
--- A buffer of IPC entries, in case a lot of them get sent at once.
---@type integer[]
local telinit = {}

local Runlevel = -1

--- Start a service described by that entry
---@param entry InitEntry
local function start_service(entry)
  if active_entries[entry.id] then return true end
  printf("init: Starting '%s'\n", entry.id)
  local pid, errno = exec(entry.command)

  if not pid then
    printf("init: Could not fork for entry %s: %d\n", entry.id, errno)
    return nil, errno

  elseif entry.action == "once" then
    active_entries[pid] = entry

  elseif entry.action == "wait" then
    syscall("wait", pid)

  elseif entry.action == "respawn" then
    respawn_entries[pid] = entry
  end

  -- for 'stop'
  active_entries[entry.id] = pid

  return true
end

--- Stop a service described by that entry
---@param entry InitEntry
local function stop_service(entry)
  local pid = active_entries[entry.id]
  printf("init: Stopping '%s'\n", entry.id)
  if pid then
    if syscall("kill", pid, "SIGTERM") then
      active_entries[pid] = nil
      respawn_entries[pid] = nil
      active_entries[entry.id] = nil
      return true
    end
  end
end

--- Switch to a new runlevel
---@param runlevel integer
local function switch_runlevel(runlevel)
  printf("init: Switch to runlevel %d\n", runlevel)
  Runlevel = runlevel

  for id, entry in pairs(active_entries) do
    if type(id) == "number" then
      if not entry.runlevels[runlevel] then
        stop_service(entry)
      end
    end
  end

  for _, entry in pairs(init_table) do
    if entry.runlevels[runlevel] then
      start_service(entry)
    end
  end
end

switch_runlevel(1) -- Single user mode

local valid_actions = {
  runlevel = true,
  start = true,
  stop = true,
  status = true,
}

local evt, err = syscall("open", "/proc/events", "rw")
if not evt then
  -- The weird formatting here is so it'll fit into 80 character lines.
  printf("init: \27[91mWARNING: Failed to open /proc/events (%d) - %s",
    err, "telinit responses will not work\27[m\n")
end

local gettys = {}
local function check_gettys()
  local fd, derr = syscall("opendir", "/dev")
  if not fd then
    printf("init: \27[91mERROR: Failed to open /dev (%d)\27[m\n", derr)
    syscall("exit", 1)
  end

  local ttys = {}
  repeat
    local dent = syscall("readdir", fd)
    if dent and dent.name:sub(1,3) == "tty" then
      ttys[#ttys+1] = dent.name
    end
  until not dent

  syscall("close", fd)

  for i=1, #ttys, 1 do
    local name = ttys[i]

    local exists = false
    for _, v in pairs(gettys) do
      if v == name then
        exists = true
        break
      end
    end

    if not exists then
      local pid = exec("/bin/login.lua", name)
      if pid then
        gettys[pid] = name
      end
    end
  end
end

while true do
  check_gettys()

  local sig, id, req, a = coroutine.yield(0.5)

  local pid = syscall("waitany")
  if pid and gettys[pid] then gettys[pid] = nil end
  if pid and respawn_entries[pid] then
    local entry = respawn_entries[pid]

    respawn_entries[pid] = nil
    active_entries[pid] = nil

    local npid, errno = exec(entry.command)
    if not npid then
      printf("init: Could not fork for entry %s: %d\n", entry.id, errno)

    else
      active_entries[npid] = entry
      respawn_entries[npid] = entry
    end
  end

  if sig == "telinit" then
    if type(id) ~= "number" then
      printf("init: Cannot respond to non-numeric PID %s\n", tostring(id))

    elseif not syscall("kill", id, "SIGEXIST") then
      printf("init: Cannot respond to nonexistent process %d\n", id)

    elseif type(req) ~= "string" or not valid_actions[req] then
      printf("init: Got bad telinit %s\n", tostring(req))
      syscall("ioctl", evt, "send", id, "bad-signal", req)

    else
      if req == "runlevel" and arg and type(arg) ~= "number" then
        printf("init: Got bad runlevel argument %s\n", tostring(arg))

      elseif req ~= "runlevel" and type(arg) ~= "string" then
        printf("init: Got bad %s argument %s\n", req, tostring(arg))

      else
        telinit[#telinit+1] = {req = req, from = id, arg = a}
      end
    end
  end

  if #telinit > 0 then
    local request = table.remove(telinit, 1)

    if request.req == "runlevel" then
      if not request.arg then
        syscall("ioctl", evt, "send", request.from, "response", "runlevel",
          Runlevel)

      elseif request.arg ~= Runlevel then
        switch_runlevel(request.arg)
        syscall("ioctl", evt, "send", request.from, "response", "runlevel",
          true)
      end

    elseif request.req == "start" then
      if active_entries[request.arg] then
        syscall("ioctl", evt, "send", request.from, "response", "start",
          start_service(active_entries[request.arg]))
      end

    elseif request.req == "stop" then
      if active_entries[request.arg] then
        syscall("ioctl", evt, "send", request.from, "response", "stop",
          stop_service(active_entries[request.arg]))
      end
    end
  end
end
