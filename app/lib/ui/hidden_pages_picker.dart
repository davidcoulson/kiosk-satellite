import 'dart:convert';

import 'package:flutter/material.dart';

import '../managers/settings/definitions.dart';
import '../managers/settings/settings_manager.dart';

/// Picks which settings pages this panel leaves out of its own list.
///
/// A wall panel carries every page whether or not the feature is used, and
/// the list is scrolled standing up. Hiding the ones a given panel will
/// never open is the difference between a menu you scan and one you search.
///
/// Modelled on the ESPHome entity exclusion row: a summary that says what
/// the setting currently does, and a dialog of checkboxes behind it.
class HiddenPagesRow extends StatelessWidget {
  const HiddenPagesRow({
    super.key,
    required this.settings,
    required this.pages,
    required this.hostCategory,
    required this.onChanged,
  });

  final SettingsManager settings;

  /// Every page, as (category, title) in the order the list shows them.
  final List<(String, String)> pages;

  /// The page this control lives on. Never offered: a control behind the
  /// thing it controls needs Remote Admin to undo, which is exactly the
  /// trip hiding pages is meant to save.
  final String hostCategory;

  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final hidden = decodeHiddenPages(settings.get(uiHiddenPages));
    final hiddenTitles = [
      for (final (category, title) in pages)
        if (hidden.contains(category)) title,
    ];
    return ListTile(
      title: Text(uiHiddenPages.title),
      subtitle: Text(
        hiddenTitles.isEmpty
            ? 'Every page is listed'
            : hiddenTitles.length <= 3
            ? 'Hidden: ${hiddenTitles.join(', ')}'
            : '${hiddenTitles.length} pages hidden',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final picked = await showDialog<Set<String>>(
          context: context,
          builder: (_) => _PagePicker(
            pages: [
              for (final page in pages)
                if (page.$1 != hostCategory) page,
            ],
            selected: hidden,
          ),
        );
        if (picked == null) return;
        await settings.set(uiHiddenPages, jsonEncode(picked.toList()..sort()));
        onChanged();
      },
    );
  }
}

class _PagePicker extends StatefulWidget {
  const _PagePicker({required this.pages, required this.selected});

  final List<(String, String)> pages;
  final Set<String> selected;

  @override
  State<_PagePicker> createState() => _PagePickerState();
}

class _PagePickerState extends State<_PagePicker> {
  late final Set<String> _selected = {...widget.selected};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(uiHiddenPages.title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
              child: Text(
                'Ticked pages are left out of this panel\'s settings list. '
                'The features keep working, search still finds them, and '
                'Remote Admin is unchanged.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final (category, title) in widget.pages)
                    CheckboxListTile(
                      value: _selected.contains(category),
                      title: Text(title),
                      dense: true,
                      onChanged: (on) => setState(() {
                        if (on == true) {
                          _selected.add(category);
                        } else {
                          _selected.remove(category);
                        }
                      }),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selected),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
