import 'package:flutter_test/flutter_test.dart';
import 'package:fotufilm_flutter/model/settings.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// Settings kept in `data`, as the platform store hands them back.
Future<AppSettings> _kept(Map<String, Object> data) {
  SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.withData({
    for (final MapEntry(:key, :value) in data.entries) '${AppSettings.prefix}$key': value,
  });
  return AppSettings.load();
}

void main() {
  test('reads back what it keeps', () async {
    final settings = await _kept({});
    settings
      ..set('lastPhotoExport', {'type': 'image/jpeg', 'quality': 90})
      ..set('photoQuality', 'fast');
    final again = await AppSettings.load();
    expect(again.get<Map>('lastPhotoExport'), {'type': 'image/jpeg', 'quality': 90});
    expect(again.get<String>('photoQuality'), 'fast');
    expect(again.isStored('photoQuality'), isTrue);
  });

  // The React browser editor kept these keys in localStorage as plain JSON, which the web store
  // decodes: the Export dialog failed on the map where the text was expected.
  test('reads the earlier browser editor\'s values', () async {
    final settings = await _kept({
      'lastPhotoExport': <String, dynamic>{'type': 'image/jpeg', 'size': 'full', 'quality': 90},
      'photoHDR': true,
      'couplerReach': 1.5,
      'photoQuality': 'fast',
    });
    expect(settings.get<Map>('lastPhotoExport'), containsPair('type', 'image/jpeg'));
    expect(settings.get<bool>('photoHDR'), isTrue);
    expect(settings.get<num>('couplerReach'), 1.5);
    expect(settings.get<String>('photoQuality'), 'fast');
  });

  test('a value of another type reads as the default', () async {
    final settings = await _kept({'photoQuality': '{"mode": "fast"}', 'lastPhotoExport': '"png"'});
    expect(settings.get<String>('photoQuality'), 'accurate');
    expect(settings.get<Map>('lastPhotoExport'), isNull);
  });
}
