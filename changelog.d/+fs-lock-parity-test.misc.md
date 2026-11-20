A differential parity test compares the library's path normalization,
makedirs errnos, copy and move effects, realpath results and lock
outcomes with Python's own os.path, os.makedirs, os.replace,
realpath and fcntl.flock calls, from a probe built in the CI test job.
