import 'dart:async';

import 'package:flutter/material.dart';

import '../app_container.dart';
import '../managers/settings/definitions.dart' as defs;
import 'settings_screen.dart';

/// What an agent-mode install shows on its own display.
///
/// There is no dashboard here by definition, and the device this runs on is
/// usually a projector or a media box whose screen shows something else
/// entirely. So this is deliberately a status card and nothing more: enough
/// to tell someone who does look at it what this app is, that it is working,
/// and where to reach it - the remote admin address being the one fact worth
/// reading off a screen. Settings stay reachable for the same reason they do
/// on a panel: turning agent mode back off has to be possible from here.
class AgentScreen extends StatefulWidget {
  const AgentScreen({super.key, required this.container});

  final AppContainer container;

  @override
  State<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends State<AgentScreen> {
  AppContainer get c => widget.container;

  Timer? _tick;
  Map<String, Object?> _info = const {};

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    // Slow on purpose: nothing here changes fast, and an agent should not
    // spend a wakeup a second on a screen nobody is reading.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final r = await c.commands.execute('getDeviceInfo', const {});
    if (!mounted || !r.ok || r.data is! Map) return;
    setState(() => _info = (r.data as Map).cast<String, Object?>());
  }

  String get _address {
    final ip = '${_info['ip'] ?? ''}';
    if (ip.isEmpty) return 'no address yet';
    return 'http://$ip:${c.settings.get(defs.remotePort)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = c.settings.get(defs.deviceName);
    final remoteOn = c.settings.get(defs.remoteEnabled);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Card(
              margin: const EdgeInsets.all(24),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.dns_outlined, color: theme.colorScheme.primary),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            name.isEmpty ? 'Kiosk Satellite' : name,
                            style: theme.textTheme.titleLarge,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Agent mode: this device is managed here and reports to '
                      'Home Assistant, but shows no dashboard.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const Divider(height: 32),
                    _row(theme, 'Version', '${_info['appVersion'] ?? ''}'),
                    _row(
                      theme,
                      'Remote admin',
                      remoteOn ? _address : 'off',
                    ),
                    _row(theme, 'Address', '${_info['ip'] ?? ''}'),
                    const SizedBox(height: 20),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.tonalIcon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => SettingsScreen(container: c),
                          ),
                        ),
                        icon: const Icon(Icons.settings_outlined),
                        label: const Text('Settings'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(ThemeData theme, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 140,
          child: Text(label, style: theme.textTheme.labelLarge),
        ),
        Expanded(
          child: SelectableText(
            value.isEmpty ? '—' : value,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      ],
    ),
  );
}
