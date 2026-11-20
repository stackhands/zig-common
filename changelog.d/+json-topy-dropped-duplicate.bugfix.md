`json.toPy` keeps the last value of a duplicate key without decoding the
members the document drops, as json.loads does, so an undecodable dropped
duplicate no longer fails the document.
