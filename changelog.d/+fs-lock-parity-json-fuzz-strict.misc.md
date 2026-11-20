A differential fuzz compares json.parse, toPy and Value.get against
json.loads on strictly decoded text, the way the consumers read it, with
the writer's own output read back through the same strict reader.
