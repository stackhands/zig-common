`state.lockExclusive` and `lockExclusiveCancel` take the timeout as u64
milliseconds, wide enough for the 999_999_999 seconds a flock -w style
caller passes, where a u32 held only about 49 days.
