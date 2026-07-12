with open('lib/screens/file_picker_screen.dart', 'r') as f:
    content = f.read()

# Replace Isolate.run for WholeDB
old_whole_iso = """        try {
          final archiveFormat = format;
          final archiveData = await Isolate.run<List<int>?>(() {
            if (archiveFormat == 'tar') {
              return TarEncoder().encode(archive);
            } else {
              return ZipEncoder().encode(archive);
            }
          });"""
new_whole_iso = """        try {
          final archiveFormat = format;
          final archiveData = await Isolate.run<List<int>?>(() {
            if (archiveFormat == 'tar') {
              return TarEncoder().encode(archive);
            } else {
              return ZipEncoder().encode(archive);
            }
          });"""

# This was catching the archive object inside the closure!
# Archive contains ArchiveFiles, which might not be sendable?
# Let's check Archive's implementation in archive package if needed, but it's simpler to just not use isolate if it fails or manually pass the archive if possible.
# Actually, the problem is that `archive` (an instance of `Archive` from package `archive`) is being captured by the closure, and it contains things that are not sendable across isolate boundaries. Let's write the whole encoding outside the isolate or just convert it first.

# Oh, wait, the error is:
# Illegal argument in isolate message: object is unsendable - Library:'dart:async' Class: _AsyncCompleter@5048458
# The closure captures `archive`. The `archive` object captures `archiveFiles`.
# Somewhere in `Archive` or `ArchiveFile`, it might have a completer? Unlikely.
# Wait, look at the error log: `_pathController in Instance of '_FilePickerScreenState'`
# It's capturing the State object!
# How?
# In `_exportWholeDb`:
# final archive = Archive();
# void addNodeToArchive(Node n, String basePath) { ... }
# for (final child in rootNode!.children) { addNodeToArchive(child, ''); }
#
# Then:
# final archiveFormat = format;
# final archiveData = await Isolate.run<List<int>?>(() { return TarEncoder().encode(archive); });
#
# Wait, `archive` was instantiated locally. Why does it capture `State`?
# Ah! `archive` is a local variable, but if the closure captures `archive`, that's fine.
# But does `ArchiveFile` somehow capture state? No.
# Wait, the error trace:
#  <- _pathController in Instance of '_FilePickerScreenState' (from package:mlocate_explorer/screens/file_picker_screen.dart)
#  <- Context num_variables: 4 <- Closure: () => List<int> (from package:mlocate_explorer/screens/file_picker_screen.dart)
#  <- computation in Instance of '_RemoteRunner<List<int>?>' (from dart:isolate)

# "Context num_variables: 4".
# The closure captures 4 variables. What are they?
# Looking at the code:
# final archiveFormat = format;
# final archiveData = await Isolate.run<List<int>?>(() {
#   if (archiveFormat == 'tar') {
#     return TarEncoder().encode(archive);
#   } else {
#     return ZipEncoder().encode(archive);
#   }
# });
# Variables captured: `archiveFormat`, `archive`.
# Is `archive` or `archiveFormat` capturing the State?
# No, but dart closures capture the *entire lexical scope* up to where the variables are defined.
# If `archive` or `archiveFormat` is in a scope that also holds `this` (the State object), the closure might capture `this` implicitly.
# To prevent capturing `this`, we can move the encoding function *completely outside* of the State class as a top-level static function.
