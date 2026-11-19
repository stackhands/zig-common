`fsx.openRegular` now reports `error.NotRegularFile` for FIFOs, sockets, and device nodes, and `sys.describe` renders that as `not a regular file` instead of `[Errno 22] Invalid argument`.
