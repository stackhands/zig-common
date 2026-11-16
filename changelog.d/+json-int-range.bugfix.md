`json.toPy` returns `error.Encoding` for an integer that does not fit an `i64`, which `json.loads` keeps exact, instead of a rounded float; a number with a fraction or an exponent is still a float.
