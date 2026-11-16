`state.lockExclusive` with a timeout returns a failing flock's own error, with its errno in `sys.last_errno`, as it does without one, instead of `error.Unexpected`.
