A differential parity test compares sys.describeErrno and sys.errnoText
with os.strerror for every errno the kernel names, and the OSError framing
with quotes, non-UTF-8 and newlines in the path against Python's repr.
