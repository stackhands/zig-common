The wait after a closed pipe now sees a set cancel flag. The call kills the group and returns `error.Canceled`. It used to run until the deadline and return `error.TimedOut`.
