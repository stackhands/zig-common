`fsx.openRegular` now returns `error.IsDir` for directory paths, so `sys.describe` reports `[Errno 21] Is a directory` instead of `[Errno 22] Invalid argument` for that case.
