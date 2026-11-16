`proc.run` returns `error.NoChild` when the child's status is lost because the caller ignores SIGCHLD, instead of reporting a kill by signal 9.
