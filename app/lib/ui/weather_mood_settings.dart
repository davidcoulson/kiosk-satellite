import 'dart:async';

import 'package:flutter/material.dart';

import '../app_container.dart';
import '../core/events.dart';
import '../l10n/messages.dart';
import '../managers/settings/definitions.dart' as defs;
import 'entity_picker.dart';

/// Weather Mood's weather entity: the entity picker's row, weather only.
class WeatherMoodEntityRow extends StatefulWidget {
  const WeatherMoodEntityRow({super.key, required this.container});

  final AppContainer container;

  @override
  State<WeatherMoodEntityRow> createState() => _WeatherMoodEntityRowState();
}

class _WeatherMoodEntityRowState extends State<WeatherMoodEntityRow> {
  StreamSubscription<SettingChanged>? _sub;

  AppContainer get c => widget.container;

  @override
  void initState() {
    super.initState();
    _sub = c.bus.on<SettingChanged>().listen((event) {
      if (event.key == defs.screensaverWeatherEntity.key && mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PickRow(
      title: defs.screensaverWeatherEntity.localizedTitle(context),
      description: defs.screensaverWeatherEntity.localizedDescription(context),
      spec: entitySpec(context, c.commands, domains: const ['weather']),
      value: c.settings.get(defs.screensaverWeatherEntity).trim(),
      allowClear: true,
      onPick: (id) => c.settings.set(defs.screensaverWeatherEntity, id ?? ''),
    );
  }
}
