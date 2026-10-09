/// The entity list the entity picker shows: what each row needs, and the
/// filters a picker opens with, kept apart from the fetching so they can
/// be tested on their own.
library;

/// A light level sensor (issue #911): the illuminance device class, or a
/// reading in lux from a template or custom sensor that sets the unit and
/// no class.
bool isIlluminanceEntity(Map<String, Object?> entity) =>
    entity['device_class'] == 'illuminance' || entity['unit'] == 'lx';

/// [entities] narrowed to [domains] (all when empty) and [deviceClass]
/// (`illuminance` also takes readings in lux).
List<Map<String, Object?>> filterEntities(
  List<Map<String, Object?>> entities, {
  List<String> domains = const [],
  String? deviceClass,
}) => [
  for (final e in entities)
    if ((domains.isEmpty || domains.contains(e['domain'])) &&
        (deviceClass == null ||
            (deviceClass == 'illuminance'
                ? isIlluminanceEntity(e)
                : e['device_class'] == deviceClass)))
      e,
];

/// Domains whose state is only when the entity was last used (a TTS
/// engine, a button, a scene): a timestamp, not something to show.
const _lastUsedDomains = {
  'ai_task',
  'button',
  'conversation',
  'event',
  'image',
  'input_button',
  'notify',
  'scene',
  'stt',
  'tts',
  'wake_word',
};

/// [entity] as the picker lists it: no state for a domain whose state is
/// only when it was last used.
Map<String, Object?> withPickerState(Map<String, Object?> entity) =>
    _lastUsedDomains.contains(entity['domain'])
    ? {...entity, 'state': null}
    : entity;

/// "binary_sensor" as "Binary sensor": the domain's name when Home
/// Assistant's own translation for it is not at hand.
String domainTitleFallback(String domain) {
  final words = domain.split('_').where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return domain;
  final text = words.join(' ');
  return text[0].toUpperCase() + text.substring(1);
}

/// A state as a row shows it when Home Assistant's formatting is not at
/// hand: the number with its unit, or the word with a capital.
String formatStateFallback(String state, String? unit) {
  if (unit != null && unit.isNotEmpty && double.tryParse(state) != null) {
    return '$state $unit';
  }
  final words = state.replaceAll('_', ' ');
  return words.isEmpty ? words : words[0].toUpperCase() + words.substring(1);
}

/// The icon Home Assistant draws for an entity that sets none: by device
/// class where one says more, else by domain.
String defaultEntityIcon(String domain, String? deviceClass) {
  final byClass =
      _classIcons['$domain.$deviceClass'] ?? _classIcons[deviceClass];
  return byClass ?? _domainIcons[domain] ?? 'mdi:bookmark';
}

const _domainIcons = {
  'air_quality': 'mdi:air-filter',
  'alarm_control_panel': 'mdi:shield',
  'assist_satellite': 'mdi:account-voice',
  'automation': 'mdi:robot',
  'binary_sensor': 'mdi:radiobox-blank',
  'button': 'mdi:button-pointer',
  'calendar': 'mdi:calendar',
  'camera': 'mdi:video',
  'climate': 'mdi:thermostat',
  'conversation': 'mdi:forum-outline',
  'counter': 'mdi:counter',
  'cover': 'mdi:window-shutter',
  'date': 'mdi:calendar',
  'datetime': 'mdi:calendar-clock',
  'device_tracker': 'mdi:account',
  'event': 'mdi:eye-check',
  'fan': 'mdi:fan',
  'humidifier': 'mdi:air-humidifier',
  'image': 'mdi:image',
  'input_boolean': 'mdi:toggle-switch-outline',
  'input_button': 'mdi:button-pointer',
  'input_datetime': 'mdi:calendar-clock',
  'input_number': 'mdi:ray-vertex',
  'input_select': 'mdi:format-list-bulleted',
  'input_text': 'mdi:form-textbox',
  'lawn_mower': 'mdi:robot-mower',
  'light': 'mdi:lightbulb',
  'lock': 'mdi:lock',
  'media_player': 'mdi:cast',
  'notify': 'mdi:message',
  'number': 'mdi:ray-vertex',
  'person': 'mdi:account',
  'remote': 'mdi:remote',
  'scene': 'mdi:palette',
  'script': 'mdi:script-text',
  'select': 'mdi:format-list-bulleted',
  'sensor': 'mdi:eye',
  'siren': 'mdi:bullhorn',
  'stt': 'mdi:microphone-message',
  'sun': 'mdi:white-balance-sunny',
  'switch': 'mdi:toggle-switch-variant',
  'text': 'mdi:form-textbox',
  'time': 'mdi:clock',
  'timer': 'mdi:timer-outline',
  'todo': 'mdi:clipboard-list',
  'tts': 'mdi:speaker-message',
  'update': 'mdi:package-up',
  'vacuum': 'mdi:robot-vacuum',
  'valve': 'mdi:valve',
  'wake_word': 'mdi:chat-sleep',
  'water_heater': 'mdi:thermometer',
  'weather': 'mdi:weather-partly-cloudy',
  'zone': 'mdi:map-marker-radius',
};

const _classIcons = {
  'apparent_power': 'mdi:flash',
  'aqi': 'mdi:air-filter',
  'atmospheric_pressure': 'mdi:thermometer-lines',
  'battery': 'mdi:battery',
  'carbon_dioxide': 'mdi:molecule-co2',
  'carbon_monoxide': 'mdi:molecule-co',
  'current': 'mdi:current-ac',
  'distance': 'mdi:arrow-left-right',
  'duration': 'mdi:progress-clock',
  'energy': 'mdi:lightning-bolt',
  'gas': 'mdi:meter-gas',
  'humidity': 'mdi:water-percent',
  'illuminance': 'mdi:brightness5',
  'moisture': 'mdi:water-percent',
  'monetary': 'mdi:cash',
  'pm25': 'mdi:blur',
  'power': 'mdi:flash',
  'precipitation': 'mdi:weather-rainy',
  'pressure': 'mdi:gauge',
  'signal_strength': 'mdi:wifi',
  'speed': 'mdi:speedometer',
  'temperature': 'mdi:thermometer',
  'timestamp': 'mdi:clock',
  'voltage': 'mdi:sine-wave',
  'water': 'mdi:water',
  'weight': 'mdi:weight',
  'wind_speed': 'mdi:weather-windy',
  'binary_sensor.door': 'mdi:door',
  'binary_sensor.garage_door': 'mdi:garage',
  'binary_sensor.window': 'mdi:window-closed',
  'binary_sensor.motion': 'mdi:motion-sensor',
  'binary_sensor.occupancy': 'mdi:home',
  'binary_sensor.presence': 'mdi:home',
  'binary_sensor.opening': 'mdi:square-outline',
  'binary_sensor.connectivity': 'mdi:check-network-outline',
  'binary_sensor.plug': 'mdi:power-plug',
  'binary_sensor.power': 'mdi:power',
  'binary_sensor.smoke': 'mdi:smoke-detector',
  'binary_sensor.moisture': 'mdi:water',
  'binary_sensor.lock': 'mdi:lock',
  'binary_sensor.problem': 'mdi:alert-circle',
  'binary_sensor.sound': 'mdi:music-note',
  'binary_sensor.vibration': 'mdi:vibrate',
  'binary_sensor.light': 'mdi:brightness5',
  'binary_sensor.battery': 'mdi:battery',
  'binary_sensor.running': 'mdi:play',
  'binary_sensor.update': 'mdi:package-up',
  'cover.garage': 'mdi:garage',
  'cover.door': 'mdi:door',
  'cover.window': 'mdi:window-closed',
  'cover.blind': 'mdi:blinds',
  'cover.curtain': 'mdi:curtains',
  'cover.awning': 'mdi:awning-outline',
  'media_player.tv': 'mdi:television',
  'media_player.speaker': 'mdi:speaker',
  'media_player.receiver': 'mdi:audio-video',
  'switch.outlet': 'mdi:power-plug',
};

/// The entity domains a service can act on, from its `target` in
/// `get_services`: null when it takes no entity, empty when it takes any.
List<String>? serviceEntityDomains(Map<Object?, Object?> service) {
  final target = service['target'];
  if (target is! Map) return null;
  final filters = target['entity'];
  if (filters is! List || filters.isEmpty) return const [];
  final domains = <String>{};
  for (final filter in filters) {
    final d = filter is Map ? filter['domain'] : null;
    // A filter by integration or device class alone reaches any domain.
    if (d is! List || d.isEmpty) return const [];
    domains.addAll(d.map((e) => '$e'));
  }
  return domains.toList();
}

/// Home Assistant's services as the service picker lists them, from
/// `get_services`: one row per service with its name from [names] (Home
/// Assistant's translation, keyed `domain.service`), the one the server
/// sent, or the service id made readable, under its domain's title.
List<Map<String, Object?>> serviceRows(
  Map<Object?, Object?> services, {
  Map<String, String> names = const {},
  Map<String, String> titles = const {},
}) => [
  for (final d in services.entries)
    if (d.value is Map)
      for (final s in (d.value as Map).entries)
        _serviceRow(
          '${d.key}',
          '${s.key}',
          s.value is Map ? s.value as Map : const {},
          names,
          titles,
        ),
];

Map<String, Object?> _serviceRow(
  String domain,
  String service,
  Map<Object?, Object?> info,
  Map<String, String> names,
  Map<String, String> titles,
) {
  final id = '$domain.$service';
  final sent = info['name'];
  return {
    'id': id,
    'domain': domain,
    'service': service,
    'name':
        names[id] ??
        (sent is String && sent.isNotEmpty
            ? sent
            : domainTitleFallback(service)),
    'domain_title': titles[domain] ?? domainTitleFallback(domain),
    'icon': defaultEntityIcon(domain, null),
    'entity_domains': serviceEntityDomains(info),
  };
}
