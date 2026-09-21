import 'package:flutter/material.dart';

import '../app_container.dart';
import '../l10n/messages.dart';
import '../managers/settings/definitions.dart' as defs;

/// What the panel opens on launch: a Home Assistant dashboard, chosen with the
/// picker below this card, or a custom page such as the theater panel's own
/// web app (URL-1).
///
/// The custom address is written to browser.custom_start_url, and the browser
/// manager makes it the start URL; this card never writes browser.start_url
/// itself, so there is one place that keeps the two in step.
class StartPageCard extends StatefulWidget {
  const StartPageCard({super.key, required this.container, this.onChanged});

  final AppContainer container;

  /// Called after the choice changes, so the page can show or hide the
  /// dashboard picker.
  final VoidCallback? onChanged;

  @override
  State<StartPageCard> createState() => _StartPageCardState();
}

class _StartPageCardState extends State<StartPageCard> {
  late final TextEditingController _url;
  String? _error;

  AppContainer get c => widget.container;

  @override
  void initState() {
    super.initState();
    final remembered = c.settings.get(defs.customStartUrl);
    _url = TextEditingController(
      text: remembered.isNotEmpty
          ? remembered
          : (c.settings.get(defs.startPage) == 'custom'
                ? c.settings.get(defs.startUrl)
                : ''),
    );
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _choose(String mode) async {
    await c.settings.set(defs.startPage, mode);
    if (!mounted) return;
    setState(() => _error = null);
    widget.onChanged?.call();
  }

  /// Stores the address if it is a web page. False, with the reason shown
  /// under the field, if it is not.
  Future<bool> _save() async {
    final text = _url.text.trim();
    // Empty is a valid stored value (no custom page yet) but not something
    // to save from here.
    final problem = text.isEmpty
        ? 'Enter a full http:// or https:// address'
        : defs.validateCustomStartUrl(text);
    if (problem != null) {
      setState(() => _error = haText(context, problem));
      return false;
    }
    setState(() => _error = null);
    await c.settings.set(defs.customStartUrl, text);
    return true;
  }

  Future<void> _openNow() async {
    if (!await _save()) return;
    await c.commands.execute('loadStartUrl', const {});
  }

  @override
  Widget build(BuildContext context) {
    final mode = c.settings.get(defs.startPage);
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              haText(context, 'Start page'),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              haText(
                context,
                'The page this panel opens on launch and returns to on Go '
                'to dashboard.',
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(
                  value: 'ha',
                  label: Text(haText(context, 'Home Assistant dashboard')),
                ),
                ButtonSegment(
                  value: 'custom',
                  label: Text(haText(context, 'Custom URL')),
                ),
              ],
              selected: {mode},
              showSelectedIcon: false,
              onSelectionChanged: (s) => _choose(s.first),
            ),
            if (mode == 'custom') ...[
              const SizedBox(height: 16),
              TextField(
                controller: _url,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: haText(context, 'Custom page address'),
                  hintText: 'http://',
                  errorText: _error,
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton(
                  onPressed: _openNow,
                  child: Text(haText(context, 'Open now')),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
