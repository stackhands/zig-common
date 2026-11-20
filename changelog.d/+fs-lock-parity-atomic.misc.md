A differential parity test compares atomicWrite, replaceContents and
appendLine with the Python tempfile-plus-replace pattern and the append
mode of open, covering the umask in the mode bits, symlink targets and
read-only parent directories.
