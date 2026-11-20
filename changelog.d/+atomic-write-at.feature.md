`atomic.atomicWriteAt` writes through an open directory descriptor with
the exact mode the caller names, umask aside, for the metrics writers
that hold their directory pinned.
