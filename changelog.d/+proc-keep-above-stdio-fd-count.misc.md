Add a descriptor count around the `proc` paths that call `sys.keepAboveStdio`, checking `/proc/self/fd` before and after so a leaked descriptor fails the test.
