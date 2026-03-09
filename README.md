# mlocate_explorer

A Flutter application designed to parse and explore `mlocate.db` files.

## Current State

The application currently features:
- **File Selection:** Users can select an `mlocate.db` file from their device using the native file picker (powered by the `file_picker` package).
- **Database Parsing:** The core `MlocateDBParser` reads and interprets the `mlocate.db` binary format. It successfully verifies the magic number, parses the file header, configuration block, and extracts directories and file entries into a nested `Node` structure.
- **User Interface:** The UI currently displays the parsed top-level directories and file entries in a basic list format using Flutter's `ListView`.

While the data is parsed into a hierarchical tree structure, the UI currently only displays the first level of children in a flat list. The `flutter_treeview` package is included in the project's dependencies for potential future implementation of a fully interactive tree-based explorer.

## Getting Started

To run the application, ensure you have Flutter installed and run:

```bash
flutter run
```
