A differential fuzz compares logs.gunzip over a run-time corpus with
Python's gzip module: the header flags, multi-member streams, truncated
and damaged members, trailing garbage and trailing zero padding.
