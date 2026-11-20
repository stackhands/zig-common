`logs.gunzip` treats bytes that are all zero after the last member as
padding, as gzip -d and Python's gzip do, instead of refusing them as
another damaged member.
