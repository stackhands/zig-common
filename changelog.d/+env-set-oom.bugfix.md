A failed `Builder.set` no longer keeps a name it did not store. The old call appended the name before it stored the value. The following `Builder.envp` call crashed on the missing value.
