# Reknit
A SysVinit-inspired init system for the Cynosure 2 kernel

# Using Reknit
Simply copy `init.lua` into anywhere on your filesystem that have Cynosure 2 installed, preferably in `/sbin/init.lua`, and pass the parameter `init=path/to/init.lua` to the kernel.

Example configuration for CLDR:
```cfg
flags init=path/to/init.lua
```

## `inittab` file
Reknit use almost the exact same format as SysVinit. Each line is a service, and each service is a list of parameters.

Service syntax:
```
id:runlevels:action:path
```

Example:
```
shell:0:respawn:/bin/sh.lua
```

- `id` can be however long you want. At the moment, it is not used.
- `runlevels` is a number where each digit indicates at what level the action should be executed. Again, not used at the moment.
- `action` defines the behaviour of the service. At the moment, 3 actions are supported:
  - `once`: the service will be executed only once without Reknit waiting for it to finish.
  - `wait`: the service will be executed and Reknit will wait for it to finish.
  - `respawn`: the service will be executed and Reknit will respawn it if it dies.
