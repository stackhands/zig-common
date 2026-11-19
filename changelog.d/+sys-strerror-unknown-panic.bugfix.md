Fix `sys.strerror` to avoid panicking on unnamed `linux.E` values by using `std.enums.tagName` with an `"Unknown error N"` fallback.
