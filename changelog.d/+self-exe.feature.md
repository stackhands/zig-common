`fsx.selfExe` reads this program's own path from /proc/self/exe, answering a
failed, empty or truncated read with null so each caller can choose what
that means.
