`state.createPrivateAt` creates a private file through an open directory
descriptor at an exact mode without ever replacing an existing name, the
never-clobber shape the tools' new-file writers need.
