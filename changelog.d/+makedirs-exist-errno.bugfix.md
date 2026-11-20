`atomic.makedirs` reports EEXIST for a final name that exists as a
non-directory, and no longer passes silently when that name is a dangling
link, matching os.makedirs with exist_ok.
