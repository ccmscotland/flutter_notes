import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class ColorPickerDialog extends StatefulWidget {
  final int initialColor;

  const ColorPickerDialog({super.key, required this.initialColor});

  @override
  State<ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<ColorPickerDialog> {
  late int _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialColor;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Choose Color'),
      content: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: AppTheme.notebookColors.map((color) {
          final isSelected = color.value == _selected;
          return GestureDetector(
            onTap: () => setState(() => _selected = color.value),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: isSelected
                    ? Border.all(
                        color: Theme.of(context).colorScheme.onSurface,
                        width: 3,
                      )
                    : null,
              ),
              child: isSelected
                  ? const Icon(Icons.check, color: Colors.white, size: 20)
                  : null,
            ),
          );
        }).toList(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selected),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

Future<int?> showColorPicker(BuildContext context, int initial) =>
    showDialog<int>(
      context: context,
      builder: (_) => ColorPickerDialog(initialColor: initial),
    );
