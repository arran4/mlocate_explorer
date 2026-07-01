import 'package:flutter/material.dart';
import '../models/node.dart';

class ModifyNodeDialog extends StatefulWidget {
  final Node node;
  final Function(Node) onModified;
  final Function(Node) onDeleted;

  const ModifyNodeDialog({
    super.key,
    required this.node,
    required this.onModified,
    required this.onDeleted,
  });

  @override
  State<ModifyNodeDialog> createState() => _ModifyNodeDialogState();
}

class _ModifyNodeDialogState extends State<ModifyNodeDialog> {
  late TextEditingController _nameController;
  late TextEditingController _sizeController;
  late DateTime? _modifiedTime;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.node.label);
    _sizeController =
        TextEditingController(text: widget.node.sizeOverride?.toString() ?? '');
    _modifiedTime = widget.node.modifiedTime;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _sizeController.dispose();
    super.dispose();
  }

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _modifiedTime ?? DateTime.now(),
      firstDate: DateTime(1970),
      lastDate: DateTime(2101),
    );
    if (picked != null) {
      if (!context.mounted) return;
      final TimeOfDay? timePicked = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(_modifiedTime ?? DateTime.now()),
      );
      if (timePicked != null) {
        setState(() {
          _modifiedTime = DateTime(
            picked.year,
            picked.month,
            picked.day,
            timePicked.hour,
            timePicked.minute,
          );
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Modify Node'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            if (!widget.node.isDir)
              TextField(
                controller: _sizeController,
                decoration: const InputDecoration(labelText: 'Size (bytes)'),
                keyboardType: TextInputType.number,
              ),
            ListTile(
              title: const Text('Modified Time'),
              subtitle: Text(_modifiedTime?.toString() ?? 'None'),
              trailing: const Icon(Icons.calendar_today),
              onTap: () => _selectDate(context),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            widget.onDeleted(widget.node);
            Navigator.of(context).pop();
          },
          child: const Text('Delete', style: TextStyle(color: Colors.red)),
        ),
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            final newLabel = _nameController.text.trim();
            if (newLabel.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Name cannot be empty')),
              );
              return;
            }

            final oldKey = widget.node.key;
            widget.node.label = newLabel;
            final pathParts = oldKey.split('/');
            pathParts.last = newLabel;
            final newKey = pathParts.join('/');
            widget.node.key = newKey;

            if (oldKey != newKey) {
              void updateKeys(Node n) {
                if (n != widget.node) {
                  n.key = newKey + n.key.substring(oldKey.length);
                }
                for (var child in n.children) {
                  updateKeys(child);
                }
              }

              updateKeys(widget.node);
            }

            if (_sizeController.text.isNotEmpty) {
              final parsedSize = int.tryParse(_sizeController.text);
              widget.node.sizeOverride =
                  (parsedSize != null && parsedSize >= 0) ? parsedSize : null;
            } else {
              widget.node.sizeOverride = null;
            }
            widget.node.modifiedTime = _modifiedTime;
            widget.onModified(widget.node);
            Navigator.of(context).pop();
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
