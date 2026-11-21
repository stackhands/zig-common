`gzipInPlace` refused to compress a log whose name, well within the
reference compressor's own limit, no longer fit a filesystem's 255-byte
limit on one path component once its temporary file's pid and random
suffix were added on. That suffix alone already makes the temporary
name unique, so the original name is left off a temporary name that
would otherwise overflow, and a name that reference tool would have
compressed compresses here too.
