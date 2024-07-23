--!lua
-- telinit: tell reknit to do things

local args = ...

local sys = require("syscalls")

local function usage()
  io.stderr:write([[
usage: telinit MESSAGE [ARGUMENT]
Tell Reknit to do something.  Valid MESSAGEs are:
  runlevel [LEVEL]
    Either request or set the current runlevel.
  rescan
    Rescan /etc/inittab.

Copyright (c) 2024 ULOS Developers under the GNU GPLv3.
]])
  os.exit(1)
end

if #args == 0 then usage() end

local fd, err = sys.open("/proc/events", "rw")
if not fd then
  io.stderr:write("telinit: failed to open /proc/events ("..tostring(err)..")\n")
  os.ecit(1)
end

sys.ioctl(fd, "send", 1, "telinit", sys.getpid(), args[1], tonumber(args[2]) or args[2])

for i=1, 5 do
  local sig, typ, status = coroutine.yield(0.5)
  if sig == "response" then
    io.write(tostring(status) .. "\n")
    os.exit(0)
  elseif sig == "bad-signal" then
    io.stderr:write("telinit: reknit says bad signal '"..typ.."'\n")
    os.exit(1)
  end
end

io.write("telinit: response signal timed out\n")
