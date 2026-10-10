/// Strips what a crash trace or log line must not carry off the device:
/// URLs, addresses, file paths and Home Assistant entity ids. docs/analytics.md
/// promises exactly this, so the rules live in one place a test can pin.
library;

/// The Home Assistant domains an entity id can start with. Scoped on purpose:
/// a bare `word.word` rule would eat every Dart and Kotlin class name in a
/// stack trace, which is the one thing a crash report is for.
const haDomains = {
  'alarm_control_panel',
  'automation',
  'binary_sensor',
  'button',
  'calendar',
  'camera',
  'climate',
  'cover',
  'device_tracker',
  'event',
  'fan',
  'group',
  'humidifier',
  'image',
  'input_boolean',
  'input_button',
  'input_datetime',
  'input_number',
  'input_select',
  'input_text',
  'lawn_mower',
  'light',
  'lock',
  'media_player',
  'number',
  'person',
  'remote',
  'scene',
  'script',
  'select',
  'sensor',
  'siren',
  'sun',
  'switch',
  'text',
  'timer',
  'todo',
  'update',
  'vacuum',
  'valve',
  'water_heater',
  'weather',
  'zone',
};

final _url = RegExp(
  r'\b[a-z][a-z0-9+.-]*://[^\s"\x27<>)\]]+',
  caseSensitive: false,
);
final _path = RegExp(
  r'(?<![\w/])/(?:data|storage|sdcard|mnt|proc|system|vendor|product|tmp|home)/[^\s"\x27<>)\]]*',
);
final _ipv4 = RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?\b');
final _email = RegExp(r'\b[\w.+-]+@[\w-]+(?:\.[\w-]+)+\b');
final _entity = RegExp('\\b(?:${haDomains.join('|')})\\.[a-z0-9_]+\\b');

/// An entity id from a domain the list above does not know (a custom
/// integration's, such as `variable.` or `var.`): lowercase `domain.object`,
/// not part of a path or a package name, and not a file name. Stack frames
/// are untouched: their class and method names start upper case or with an
/// underscore, and their files sit inside a `package:` path.
final _customEntity = RegExp(
  r'(?<![\w/:.@-])[a-z][a-z0-9_]*\.(?!(?:dart|kt|java|js|mjs|json|so|xml|yaml|yml|md|txt|png|jpg|html|css|apk|log)\b)[a-z0-9_]{2,}\b(?![.:/(\w-])',
);
final _bearer = RegExp(
  r'\b(bearer|token|password|authorization)([=: ]+)(?:bearer\s+)?\S+',
  caseSensitive: false,
);

/// [text] with every URL, address, path, entity id and credential-looking
/// value replaced by a placeholder that says what was there.
String scrubDiagnostics(String text) => text
    .replaceAllMapped(_bearer, (m) => '${m[1]}${m[2]}<redacted>')
    .replaceAll(_url, '<url>')
    .replaceAll(_path, '<path>')
    .replaceAll(_ipv4, '<ip>')
    .replaceAll(_email, '<email>')
    .replaceAll(_entity, '<entity>')
    .replaceAll(_customEntity, '<entity>');

/// [text] cut to [max] characters, keeping the start: the first lines of a
/// trace name the exception and where it was thrown, which is the part that
/// tells crashes apart.
String clipDiagnostics(String text, {int max = 16 * 1024}) =>
    text.length <= max ? text : '${text.substring(0, max)}\n<clipped>';
