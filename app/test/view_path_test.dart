import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/managers/home_assistant/home_assistant_manager.dart';

void main() {
  test('view paths lose their outer slashes and keep a query', () {
    expect(normalizeViewPath(' /lovelace/kitchen/ '), 'lovelace/kitchen');
    expect(
      normalizeViewPath('/cameras/0/?camera=garage'),
      'cameras/0?camera=garage',
    );
    expect(normalizeViewPath('local/page.html#top'), 'local/page.html#top');
    expect(normalizeViewPath('/'), '');
    expect(normalizeViewPath('?x=1'), '');
    expect(viewRoute('cameras/0?camera=garage'), 'cameras/0');
    expect(viewRoute('local/page.html#top'), 'local/page.html');
    expect(viewRoute('lovelace/0'), 'lovelace/0');
  });
}
