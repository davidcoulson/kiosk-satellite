import 'dart:async';

import 'package:flutter/material.dart';

import '../app_container.dart';
import '../core/events.dart';
import '../l10n/messages.dart';
import '../managers/home_assistant/custom_pages.dart';
import '../managers/settings/definitions.dart';
import 'kit.dart';
import 'mdi_icon.dart';
import 'settings_screen.dart' show SettingTile;
import 'settings_search.dart';

/// The custom pages guide on the docs site.
const customPagesDocsUrl = 'https://kiosksatellite.com/docs/custom-pages/';

/// Settings > Home Assistant > Custom Pages: the Share Home Assistant
/// connection switch, then the person's own HTML pages, in Home Assistant's
/// /local/ or on another server, each with the name the dashboard pickers
/// show. Tapping a page edits it, Add page opens the same dialog empty. The
/// page follows changes made in the remote admin while it is open.
class CustomPagesCard extends StatefulWidget {
  const CustomPagesCard({super.key, required this.container});

  final AppContainer container;

  @override
  State<CustomPagesCard> createState() => _CustomPagesCardState();
}

class _CustomPagesCardState extends State<CustomPagesCard> {
  AppContainer get c => widget.container;
  StreamSubscription<SettingChanged>? _echo;

  @override
  void initState() {
    super.initState();
    _echo = c.bus.on<SettingChanged>().listen((e) {
      if ((e.key == haCustomPages.key || e.key == haCustomPagesSocket.key) &&
          mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _echo?.cancel();
    super.dispose();
  }

  Future<void> _edit([CustomPage? page]) async {
    await showCustomPageDialog(context, c, page: page);
    if (mounted) setState(() {});
  }

  Future<void> _remove(CustomPage page) async {
    await c.commands.execute('haRemoveCustomPage', {'path': page.path});
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final pages = parseCustomPages(c.settings.get(haCustomPages));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsCard(
          children: [
            SettingTile(
              container: c,
              def: haCustomPagesSocket,
              onChanged: () => setState(() {}),
            ),
          ],
        ),
        SectionHeading(haText(context, 'Custom Pages')),
        SearchLandingTarget(
          id: 'x:custom_pages',
          child: SettingsCard(
            children: [
              if (pages.isEmpty)
                HintRow(
                  haText(
                    context,
                    'Add HTML pages from the Home Assistant www folder or '
                    'another server to pick them like a dashboard.',
                  ),
                ),
              for (final page in pages)
                SettingsRow(
                  leading: MdiIcon(
                    name: customPageIcon,
                    size: 24,
                    color: scheme.primary,
                    fallback: Icons.code,
                  ),
                  title: Text(page.name),
                  subtitle: Text(
                    page.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: haText(context, 'Remove'),
                    onPressed: () => _remove(page),
                  ),
                  onTap: () => _edit(page),
                ),
              ListTile(
                leading: Icon(Icons.add_circle_outline, color: scheme.primary),
                title: Text(
                  haText(context, 'Add page'),
                  style: TextStyle(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onTap: () => _edit(),
              ),
            ],
          ),
        ),
        SettingsCard(
          children: [
            SearchLandingTarget(
              id: 'x:custom_pages_docs',
              child: ListTile(
                title: Text(haText(context, 'Custom page guide')),
                subtitle: Text(
                  haText(
                    context,
                    'How to build a page that talks to Home Assistant.',
                  ),
                ),
                trailing: const Icon(Icons.open_in_new),
                onTap: () {
                  Navigator.of(context).popUntil((route) => route.isFirst);
                  c.commands.execute('showLinkPage', {
                    'url': customPagesDocsUrl,
                  });
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Why Save & Validate refused, in the kiosk's language (see
/// HomeAssistantManager.saveCustomPage for the codes).
String customPageError(BuildContext context, String code) {
  if (code.startsWith('status:')) {
    return l10n(context).haCustomPageStatus(code.substring('status:'.length));
  }
  return switch (code) {
    'name' => haText(context, 'Enter a name.'),
    'path' => haText(
      context,
      'Enter a path under /local/ or an http or https URL.',
    ),
    'duplicate' => haText(context, 'Another page already uses this path.'),
    'not_found' => haText(context, 'Home Assistant has no file at this path.'),
    'url_not_found' => haText(context, 'The server has no page at this URL.'),
    'url_unreachable' => haText(context, 'Could not reach the server.'),
    _ when code.startsWith('url_status:') => l10n(
      context,
    ).haCustomPageUrlStatus(code.substring('url_status:'.length)),
    _ => haText(context, 'Could not reach Home Assistant.'),
  };
}

/// Add a custom page or change [page]. Save & Validate asks Home
/// Assistant for the page first: a 200 saves and closes, anything else
/// shows why and keeps the dialog open. Answers true when it saved.
Future<bool> showCustomPageDialog(
  BuildContext context,
  AppContainer container, {
  CustomPage? page,
}) async {
  final name = TextEditingController(text: page?.name ?? '');
  final path = TextEditingController(text: page?.path ?? '/local/');
  var saving = false;
  String? error;

  final route = DialogRoute<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        final scheme = Theme.of(ctx).colorScheme;
        Future<void> save() async {
          setDialogState(() {
            saving = true;
            error = null;
          });
          final result = await container.commands.execute('haSaveCustomPage', {
            'name': name.text,
            'path': path.text,
            if (page != null) 'original': page.path,
          });
          if (!ctx.mounted) return;
          if (result.ok) {
            Navigator.pop(ctx, true);
            return;
          }
          setDialogState(() {
            saving = false;
            error = customPageError(ctx, result.error ?? '');
          });
        }

        return AlertDialog(
          title: Text(
            page == null
                ? haText(ctx, 'Add custom page')
                : haText(ctx, 'Edit custom page'),
          ),
          content: SizedBox(
            width: 480,
            child: EdgeFade(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 16,
                  children: [
                    LabeledField(
                      label: haText(ctx, 'Name'),
                      child: TextField(
                        controller: name,
                        enabled: !saving,
                        autofocus: page == null,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: const InputDecoration(),
                      ),
                    ),
                    LabeledField(
                      label: haText(ctx, 'Path or URL'),
                      helper: haText(
                        ctx,
                        'A file in the Home Assistant www folder, such as '
                        '/local/dashboard.html, or the URL of a page on '
                        'another server.',
                      ),
                      child: TextField(
                        controller: path,
                        enabled: !saving,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        enableSuggestions: false,
                        onSubmitted: (_) => saving ? null : save(),
                        decoration: const InputDecoration(),
                      ),
                    ),
                    if (error != null)
                      Text(
                        error!,
                        style: Theme.of(
                          ctx,
                        ).textTheme.bodyMedium?.copyWith(color: scheme.error),
                      ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(ctx, false),
              child: Text(haText(ctx, 'Cancel')),
            ),
            FilledButton(
              onPressed: saving ? null : save,
              child: saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    )
                  : Text(haText(ctx, 'Save & Validate')),
            ),
          ],
        );
      },
    ),
  );
  final saved = await Navigator.of(context, rootNavigator: true).push(route);
  await route.completed;
  name.dispose();
  path.dispose();
  return saved ?? false;
}
