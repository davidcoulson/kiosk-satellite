import '../../ui/mdi_icon.dart';

/// The dashboard list a `lovelace/dashboards/list` answer amounts to.
///
/// Every listed dashboard counts: YAML-mode dashboards read over
/// `lovelace/config` exactly like storage ones, and filtering to storage
/// silently dropped every YAML dashboard from the view selects (issue
/// where only the default dashboard's views and Map survived). The API
/// omits the default dashboard, so a `lovelace` entry is prepended,
/// unless a dashboard is already registered on that url_path (the
/// auto-created storage default, or a YAML override), which used to
/// duplicate the default's views in the options.
List<Map<String, Object?>> dashboardsFromWsList(List<dynamic> result) {
  final dashboards = <Map<String, Object?>>[
    for (final d in result.whereType<Map>())
      if ('${d['url_path'] ?? ''}'.isNotEmpty)
        {
          'url_path': d['url_path'],
          'title': d['title'],
          if (d['icon'] is String) 'icon': d['icon'],
        },
  ];
  if (!dashboards.any((d) => d['url_path'] == 'lovelace')) {
    dashboards.insert(0, {'url_path': 'lovelace', 'title': 'Default'});
  }
  return dashboards;
}

/// [entries] with `icon_path`, the SVG path data of each entry's `icon`,
/// added where the icon resolves. The remote admin draws Home Assistant's
/// icons from these, so it needs no icon set of its own.
Future<List<Map<String, Object?>>> withIconPaths(
  List<Map<String, Object?>> entries,
) async => [
  for (final e in entries)
    {
      ...e,
      if (e['icon'] is String) 'icon_path': await MdiIcons.path('${e['icon']}'),
    },
];
