--!lua
-- ULOS 2's gettyd

local sys = require("syscalls")

local function printf(fmt, ...)
  io.write(string.format(fmt, ...))
end

local function login(lgi, tty)
  local pid, errno = sys.fork(function()
    if tty then
      local fd, err = sys.open("/dev/"..tty, "rw")
      if not fd then sys.exit(err) end

      for i=0, 2, 1 do
        sys.dup2(fd, i)
      end

      sys.close(fd)
    end

    local _, errno = sys.execve(lgi, {
      [0] = "login"
    })

    if errno then
      printf("gettyd: execve failed: %d\n", errno)
      sys.exit(1)
    end
  end)
  if not pid then
    printf("gettyd: fork failed: %d\n", errno)
    return nil, errno

  else
    return pid
  end
end

local gettys = {}
local function check_gettys()
  local fd, derr = sys.opendir("/dev")
  if not fd then
    printf("gettyd: \27[91mERROR: Failed to open /dev (%d)\27[m\n", derr)
    os.exit(1)
  end

  local ttys = {}
  repeat
    local dent = sys.readdir(fd)
    if dent and dent.name:sub(1,3) == "tty" then
      ttys[#ttys+1] = dent.name
    end
  until not dent

  sys.close(fd)

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
      local pid = login("/bin/login.lua", name)
      if pid then
        gettys[pid] = name
      end
    end
  end
end

while true do
  check_gettys()

  local sig, id, req, a = coroutine.yield(0.5)

  local pid = sys.waitany()
  if pid and gettys[pid] then gettys[pid] = nil end
end
