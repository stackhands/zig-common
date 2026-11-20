`fsx.copyTo` creates its temporary file in the destination parent directory
for nested targets, avoiding cross-device rename failures.
