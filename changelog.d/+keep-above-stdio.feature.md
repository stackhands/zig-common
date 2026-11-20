`sys.keepAboveStdio` moves an open descriptor in slots 0, 1 or 2 to 3
or above with `FD_CLOEXEC` set and closes the original slot, returning
descriptors already at 3 or above unchanged; `proc.run` uses it for its
child setup and exec-failure pipe.
