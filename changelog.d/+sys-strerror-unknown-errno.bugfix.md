`sys.strerror` returns `Unknown error N` for non-Linux `linux.E` tags such as
`NSRNODATA` through `NSRCNAMELOOP`, matching glibc and Python's `os.strerror`.
