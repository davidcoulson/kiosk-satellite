import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

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
/// reading off a screen. It is also a QR code, since a projector has no
/// keyboard and an IP and port typed off a wall is the worst part of setting
/// one up: point a phone at it instead. Settings stay reachable for the same
/// reason they do on a panel: turning agent mode back off has to be possible
/// from here.
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

  /// The remote admin's URL, or null before the device has an address.
  /// HTTPS when the admin serves it, since a scanned http:// link to a TLS
  /// port opens nothing.
  String? get _adminUrl {
    final ip = '${_info['ip'] ?? ''}';
    if (ip.isEmpty) return null;
    final scheme = c.settings.get(defs.remoteTls) ? 'https' : 'http';
    return '$scheme://$ip:${c.settings.get(defs.remotePort)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = c.settings.get(defs.deviceName);
    final remoteOn = c.settings.get(defs.remoteEnabled);
    final url = remoteOn ? _adminUrl : null;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: url == null ? 520 : 760),
            child: Card(
              margin: const EdgeInsets.all(24),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: _details(theme, name, remoteOn, url)),
                    if (url != null) ...[
                      const SizedBox(width: 24),
                      _qr(theme, url),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _details(ThemeData theme, String name, bool remoteOn, String? url) =>
      Column(
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
            !remoteOn ? 'off' : (url ?? 'no address yet'),
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
      );

  /// The admin URL as a QR code: dark on white whatever the theme, with a
  /// quiet zone, since phone cameras read that and little else reliably.
  Widget _qr(ThemeData theme, String url) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: QrImageView(
          data: url,
          size: 200,
          semanticsLabel: 'Remote admin: $url',
          backgroundColor: Colors.white,
          eyeStyle: const QrEyeStyle(
            eyeShape: QrEyeShape.square,
            color: Colors.black,
          ),
          dataModuleStyle: const QrDataModuleStyle(
            dataModuleShape: QrDataModuleShape.square,
            color: Colors.black,
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text('Scan to open the remote admin', style: theme.textTheme.bodySmall),
    ],
  );

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
