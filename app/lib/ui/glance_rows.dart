import 'dart:convert';

import 'package:flutter/material.dart';

import '../app_container.dart';
import '../l10n/messages.dart';
import '../managers/settings/definitions.dart';
import 'entity_picker.dart';
import 'kit.dart';

/// At a Glance's entities, the card under their own Entities heading: the
/// picks in order (icon, name, displayed value) with up, down and remove,
/// and Add entities, which opens the entity picker for several. Tapping a pick
/// edits its name and what it displays. Mirrored on the remote (rows.js).
class GlanceRows extends StatefulWidget {
  const GlanceRows({
    super.key,
    required this.container,
    required this.def,
    required this.onChanged,
  });

  final AppContainer container;
  final SettingDef<Object> def;
  final VoidCallback onChanged;

  @override
  State<GlanceRows> createState() => _GlanceRowsState();
}

class _GlanceRowsState extends State<GlanceRows> {
  AppContainer get c => widget.container;

  @override
  void initState() {
    super.initState();
    if (PickCatalog.of('entities').value == null) {
      loadEntityCatalog(c.commands);
    }
  }

  List<Map<String, Object?>> _picks() {
    try {
      final decoded = jsonDecode(c.settings.get(screensaverGlanceEntities));
      if (decoded is! List) return [];
      return [
        for (final item in decoded)
          if (item is Map) item.cast<String, Object?>(),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<Map<String, Object?>> picks) async {
    await c.settings.setFromJson(
      screensaverGlanceEntities.key,
      jsonEncode(picks),
    );
    if (mounted) setState(() {});
    widget.onChanged();
  }

  Future<void> _add() async {
    final picks = _picks();
    final ids = await showItemMultiPicker(
      context,
      title: widget.def.localizedTitle(context),
      spec: entitySpec(context, c.commands),
      selected: [for (final p in picks) '${p['entity_id']}'],
      max: screensaverGlanceMax,
    );
    if (ids == null) return;
    // Kept picks keep their own name and value; new ones start plain.
    await _save([
      for (final id in ids)
        picks.firstWhere(
          (p) => p['entity_id'] == id,
          orElse: () => {
            'entity_id': id,
            'name': PickCatalog.of('entities').value?.find(id)?.name ?? id,
          },
        ),
    ]);
  }

  /// A pick's own name (empty for Home Assistant's) and what it displays,
  /// its state or one attribute (issue #132).
  Future<void> _edit(int index) async {
    final picks = _picks();
    final entity = picks[index];
    final id = '${entity['entity_id']}';
    final controller = TextEditingController(
      text: '${entity['custom_name'] ?? ''}',
    );
    var attribute = entity['attribute'] as String? ?? '';
    final route = DialogRoute<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('${entity['name'] ?? id}'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 16,
              children: [
                LabeledField(
                  label: screensaverText(context, 'Name'),
                  child: TextField(
                    controller: controller,
                    decoration: InputDecoration(
                      hintText: '${entity['name'] ?? ''}',
                      helperText: screensaverText(
                        context,
                        'Leave empty to use the Home Assistant name.',
                      ),
                    ),
                  ),
                ),
                LabeledField(
                  label: screensaverText(context, 'Displayed value'),
                  child: ChoiceBox(
                    text: attribute.isEmpty
                        ? screensaverText(context, 'State')
                        : attribute,
                    onTap: () async {
                      final picked = await showEntityValuePicker(
                        context,
                        c,
                        entityId: id,
                        current: attribute,
                      );
                      if (picked != null) {
                        setDialogState(() => attribute = picked);
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(screensaverText(context, 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(screensaverText(context, 'Save')),
            ),
          ],
        ),
      ),
    );
    final submitted = await Navigator.of(context).push(route);
    final name = controller.text.trim();
    await route.completed;
    controller.dispose();
    if (submitted != true) return;
    if (name.isEmpty) {
      entity.remove('custom_name');
    } else {
      entity['custom_name'] = name;
    }
    if (attribute.isEmpty) {
      entity.remove('attribute');
    } else {
      entity['attribute'] = attribute;
    }
    await _save(picks);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final picks = _picks();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, p) in picks.indexed)
          PickListRow(
            specKey: 'entities',
            value: '${p['entity_id']}',
            name: (p['custom_name'] ?? p['name']) as String?,
            detail: p['attribute'] as String?,
            onTap: () => _edit(i),
            trailing: OrderActions(
              first: i == 0,
              last: i == picks.length - 1,
              onUp: () => _save(picks..insert(i - 1, picks.removeAt(i))),
              onDown: () => _save(picks..insert(i + 1, picks.removeAt(i))),
              onRemove: () => _save(picks..removeAt(i)),
            ),
          ),
        if (picks.length < screensaverGlanceMax)
          ListTile(
            leading: Icon(
              Icons.add_circle_outline,
              color: theme.colorScheme.primary,
            ),
            title: Text(
              haText(context, 'Add entities'),
              style: TextStyle(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            onTap: _add,
          ),
      ],
    );
  }
}
