A differential parity test compares the library's JSON and pytext output
with Python's own json, repr, shlex and text calls, byte for byte, from
a probe built in the CI test job.
