`logs.gzipInPlace` writes the archive under a temporary name and renames it into place, so a crash does not leave a partial `.gz` at the final name.
