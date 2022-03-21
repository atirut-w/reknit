# Reknit
A SysVinit-inspired init system for the Cynosure 2 kernel.

# Using Reknit
Simply copy `init.lua` into anywhere on your filesystem that has Cynosure 2 installed, preferably in `/sbin/init.lua`, and pass the parameter `init=path/to/init.lua` to the kernel.

Example configuration for CLDR:
```cfg
flags init=path/to/init.lua
```

## Communication
Reknit expects to be sent messages (internally referred to as `telinit`s) in the form of signals.  These should be directly sent through an `ioctl` on `/proc/events`.  For example, to switch to runlevel 2:
```lua
local fd = open("/proc/events", "r")
ioctl(fd, "send", 1, "telinit", getpid(), "runlevel", 2)
close(fd)
-- wait for the "response" signal
```

A few things of note:
- The sent message must always take the form `"telinit", yourpid, "request"[, argument]`.  The second parameter *must* be a valid PID or Reknit will not process the request.  This is so, when e.g. requesting the runlevel, Reknit knows which process to respond to.
- Reknit will always respond through a signal in the form `"response", "request", true|false`.  It is good practice to wait for this signal before continuing.

## Configuration
Reknit's `inittab` file uses almost the exact same format as SysVinit. Each line is a service, and each service is a list of parameters delimited by the colon (`:`).

Service syntax:
```
id:runlevels:action:path
```

Example:
```
shell:0:respawn:/bin/sh.lua
```

- `id` can be however long you want. At the moment, it is not used.
- `runlevels` is a number where each digit indicates at what level(s) the action should be executed.  It can be `0123456789` or if it is not a number Reknit will only start it when instructed to.
- `action` defines the behaviour of the service. At the moment, 3 actions are supported:
  - `once`: the service will be executed only once without Reknit waiting for it to finish.
  - `wait`: the service will be executed and Reknit will wait for it to finish.
  - `respawn`: the service will be executed and Reknit will respawn it if it dies.
