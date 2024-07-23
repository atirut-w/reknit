--!lua
-- SysV-style init, mk2

local function syscall(call, ...)
  local result, err = coroutine.yield("syscall", call, ...)
  return result, err
end

local function printf(fmt, ...)
  syscall("write", 1, string.format(fmt, ...))
end

if syscall("getpid") ~= 1 then
  printf("Reknit must be run as process 1\n")
  syscall("exit", 1)
end

printf("init: Reknit is starting\n")

local function exec_on(cmd, tty)
  local pid, err = syscall("fork", function()
  end)

  if not pid then
    printf("init: fork failed (%d)\n", errno)
    return nil, errno

  else
    return pid
  end
end

local function readfile(file)
  local fd, err = syscall("open", file, "r")
  if not fd then
    printf("%q / %q\n", fd, err)
    printf("init: Could not open %s: %s\n", file, (err == 2 and "No such file or directory") or tostring(err))
    return nil, err
  end

  local data = syscall("read", fd, "a")
  syscall("close", fd)

  return data
end

local function exec_script(file)
  local pok, perr
  if dofile then
    pok, perr = pcall(dofile, file)

  else
    local data, err = readfile(file)
    if not data then
      return nil, err
    end

    local ok, err = load(data, "="..file, "t", _G)
    if not ok then
      printf("init: load() failed - %s\n", err)
      return
    end

    pok, perr = pcall(ok)
  end

  if not pok and perr then
    printf("init: ok() failed - %s\n", perr)
    return
  end

  return true
end

-- Load /lib/package.lua
assert(exec_script("/lib/package.lua"))

local validRunlevels = "[0123456789abcABCsS]"
local currentRunlevel = "s"
local monitor = {}
local kill_queue = {time = 0}

local function read_inittab()
  local inittab = {}
  local data, err = readfile("/etc/inittab")

  if not data then return inittab end

  local ln = 0
  for line in data:gmatch("[^\r\n]+") do
    ln = ln + 1
    if line:sub(1,1) ~= "#" then -- ignore comments
      local id, runlevels, action, process = line:match("^([^:]+):([abcABC1234567890Ss]*):([^:]+):(.*)$")

      if not id then
        printf("init: Bad init entry on line %d\n", ln)
      end

      local entry = {id = id, runlevels = {}, action = action, process = process}
      for rl in runlevels:gmatch("%d") do
        entry.runlevels[tonumber(rl) or rl] = true
      end

      if entry.action == "initdefault" then
        inittab.default = runlevels:sub(1,1)
        inittab.default = tonumber(inittab.default) or inittab.default
      else
        inittab[#inittab+1] = entry
      end
    end
  end

  return inittab
end

local function exec(cmd)
  local pid, err = syscall("fork", function()
    local _, errno = syscall("execve", "/bin/sh.lua", {
      "-c", cmd, [0] = "[init_worker]"
    })
    if errno then
      printf("init: execve failed (%d)\n", errno)
      syscall("exit", 1)
    end
  end)

  if not pid then
    printf("init: fork failed (%d)\n", err)
    return nil, err
  end

  return pid
end

local function process_runlevel(inittab, runlevel)
  local defined = {}
  for i=1, #inittab do
    local entry = inittab[i]
    if entry.runlevels[runlevel] then
      -- TODO ondemand runlevels?
      if entry.action == "once" and runlevel ~= currentRunlevel then
        monitor[entry.id] = exec(entry.process)

      elseif entry.action == "wait" and runlevel ~= currentRunlevel then
        local pid = exec(entry.process)
        if pid then
          syscall("wait", pid)
        end

      elseif entry.action == "respawn" then
        if (not monitor[entry.id]) or (not syscall("kill", monitor[entry.id], "SIGEXIST")) then
          monitor[entry.id] = exec(entry.process)
        end
      end

    elseif monitor[entry.id] then
      syscall("kill", monitor[entry.id], "SIGTERM")
      kill_queue[#kill_queue+1] = monitor[entry.id]
      kill_queue.time = syscall("uptime") + 3
      monitor[entry.id] = nil
    end
  end

  currentRunlevel = runlevel
end

local inittab = read_inittab()

-- pass 1: execute all sysinit scripts
for i=1, #inittab do
  if inittab[i].action == "sysinit" then
    -- AIX 7.1 waits for sysinit entries.
    local pid = exec(entry.process)
    if pid then
      syscall("wait", pid)
    end
  end
end

-- pass 2: execute boot scripts
for i=1, #inittab do
  if inittab[i].action == "boot" then
    exec(inittab[i].process)
  elseif inittab[i].action == "bootwait" then
    local pid = exec(inittab[i].process)
    if pid then
      syscall("wait", pid)
    end
  end
end

-- wait for all the boot processes to settle
repeat local pid = syscall("waitany") until not pid

-- pass 3: enter default runlevel
if not inittab.default then
  currentRunlevel = nil
  repeat
    printf("init: Runlevel? ")
    local input = syscall("read", 0, "l")
    if input:match(validRunlevels) then
      currentRunlevel = input:sub(1,1)
      currentRunlevel = tonumber(currentRunlevel) or currentRunlevel
    end
  until currentRunlevel

  local to_enter = currentRunlevel
  currentRunlevel = -1
  process_runlevel(inittab, to_enter)
else
  currentRunlevel = -1
  process_runlevel(inittab, inittab.default)
end

while true do
  local should_rescan_inittab, newRunlevel = false, currentRunlevel

  local sig, id, req, a = coroutine.yield(0.5)
  repeat
    local pid = syscall("waitany")
    if pid then
      should_rescan_inittab = true
    end
  until not pid

  if kill_queue.time <= syscall("uptime") then
    for i=1, #kill_queue do
      signal("kill", kill_queue[i], "SIGKILL")
      kill_queue[i] = nil
    end
    kill_queue.time = math.huge
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
        syscall("ioctl", evt, "send", id, "bad-signal", req)

      elseif req ~= "runlevel" and type(arg) ~= "string" then
        printf("init: Got bad %s argument %s\n", req, tostring(arg))
        syscall("ioctl", evt, "send", id, "bad-signal", req)

      else
        if req == "runlevel" then
          if not request.arg then
            syscall("ioctl", evt, "send", request.from, "response", "runlevel",
              currentRunlevel)

          elseif request.arg ~= currentRunlevel then
            should_rescan_inittab = true
            newRunlevel = request.arg or newRunlevel
            syscall("ioctl", evt, "send", request.from, "response", "runlevel",
              newRunlevel)
          end

        elseif req == "rescan" then
          should_rescan_inittab = true
          syscall("ioctl", evt, "send", request.from, "response", "rescan", true)
        end
      end
    end
  end

  if should_rescan_inittab then
    inittab = read_inittab()
    process_runlevel(inittab, newRunlevel)
  end
end
