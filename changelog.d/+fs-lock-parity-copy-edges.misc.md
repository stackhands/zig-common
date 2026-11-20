A differential parity test covers copyTo and moveAcross edges against
shutil and os: cross-device moves and their copy fallback, a read-only
destination, a symlinked destination, a write stopped by the file-size
limit and a source removed after its descriptor was opened.
