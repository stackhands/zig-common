`json.toPy` refuses a document whose raw non-UTF-8 byte sits in the
member a duplicate key drops, as the consumers decode the whole text
strictly before json.loads.
