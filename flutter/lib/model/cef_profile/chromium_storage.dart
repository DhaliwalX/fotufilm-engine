// What a Chromium profile's localStorage and IndexedDB LevelDB databases hold, from their live
// entries (leveldb.dart). Keys follow Chromium's encodings: components/services/storage/
// dom_storage (localStorage) and content/browser/indexed_db/indexed_db_leveldb_coding.cc.
import 'dart:typed_data';

import 'v8_value.dart';

/// Each origin's localStorage items.
Map<String, Map<String, String>> localStorageItems(Map<String, Uint8List> entries) {
  final origins = <String, Map<String, String>>{};
  for (final MapEntry(:key, :value) in entries.entries) {
    // "_" origin NUL, then the item's name, each string led by its encoding.
    if (!key.startsWith('_')) continue;
    final split = key.indexOf('\x00');
    if (split < 0 || split + 1 >= key.length) continue;
    final name = _storageString(key.substring(split + 1).codeUnits);
    if (name == null) continue;
    final text = _storageString(value);
    if (text == null) continue;
    (origins[key.substring(1, split)] ??= {})[name] = text;
  }
  return origins;
}

/// 0 then UTF-16LE, or 1 then Latin-1.
String? _storageString(List<int> bytes) {
  if (bytes.isEmpty) return null;
  final body = bytes.sublist(1);
  return switch (bytes.first) {
    0 => String.fromCharCodes([
        for (var k = 0; k + 1 < body.length; k += 2) body[k] | body[k + 1] << 8,
      ]),
    1 => String.fromCharCodes(body),
    _ => null,
  };
}

/// Each database's object stores, by name, and the values their records hold. A record whose
/// value cannot be read (moved to a blob, or of a kind the editor never stored) is left out.
Map<String, Map<String, List<Object?>>> indexedDbRecords(Map<String, Uint8List> entries) {
  final databases = <int, String>{};
  final stores = <(int, int), String>{};
  final records = <(int, int), List<Object?>>{};
  for (final MapEntry(:key, :value) in entries.entries) {
    final bytes = key.codeUnits;
    final prefix = _prefix(bytes);
    if (prefix == null) continue;
    final (database, store, index, at) = prefix;
    if (database == 0 && store == 0 && index == 0) {
      // Database names: 201, the origin, the name; the value is the database's id.
      if (at < bytes.length && bytes[at] == 201) {
        final reader = _KeyReader(bytes, at + 1);
        reader.string();
        final name = reader.string();
        if (name != null) databases[_KeyReader(value, 0).varint()] = name;
      }
    } else if (store == 0 && index == 0) {
      // An object store's metadata: 50, the store's id, then 0 for its name.
      if (at < bytes.length && bytes[at] == 50) {
        final reader = _KeyReader(bytes, at + 1);
        final id = reader.varint();
        if (reader.at == bytes.length - 1 && bytes[reader.at] == 0) {
          stores[(database, id)] = _utf16be(value, 0, value.length);
        }
      }
    } else if (index == 1) {
      try {
        final record = readIndexedDbValue(value);
        if (record != null) (records[(database, store)] ??= []).add(record);
      } on Object {
        // Left out.
      }
    }
  }
  final result = <String, Map<String, List<Object?>>>{};
  records.forEach((id, values) {
    final (database, store) = id;
    final databaseName = databases[database], storeName = stores[id];
    if (databaseName == null || storeName == null) return;
    (result[databaseName] ??= {})[storeName] = values;
  });
  return result;
}

/// The database, object store and index ids that lead every key, and where the rest begins:
/// one byte of their lengths, then each little-endian.
(int, int, int, int)? _prefix(List<int> bytes) {
  if (bytes.isEmpty) return null;
  final lengths = bytes[0];
  final sizes = [(lengths >> 5) + 1, ((lengths >> 2) & 7) + 1, (lengths & 3) + 1];
  var at = 1;
  final ids = <int>[];
  for (final size in sizes) {
    if (at + size > bytes.length) return null;
    var id = 0;
    for (var k = 0; k < size; k++) {
      id |= bytes[at + k] << (8 * k);
    }
    ids.add(id);
    at += size;
  }
  return (ids[0], ids[1], ids[2], at);
}

String _utf16be(List<int> bytes, int from, int to) => String.fromCharCodes([
      for (var k = from; k + 1 < to; k += 2) bytes[k] << 8 | bytes[k + 1],
    ]);

class _KeyReader {
  _KeyReader(this.bytes, this.at);
  final List<int> bytes;
  int at;

  int varint() {
    var value = 0, shift = 0;
    while (true) {
      final byte = bytes[at++];
      value |= (byte & 0x7f) << shift;
      if (byte < 0x80) return value;
      shift += 7;
    }
  }

  /// A varint count of UTF-16 units, then the units big-endian.
  String? string() {
    final length = varint();
    if (at + 2 * length > bytes.length) return null;
    final text = _utf16be(bytes, at, at + 2 * length);
    at += 2 * length;
    return text;
  }
}
