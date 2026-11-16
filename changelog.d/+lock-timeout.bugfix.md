`state.lockExclusive` measures its deadline on the monotonic clock, so a signal that cuts a sleep short does not expire the wait.
