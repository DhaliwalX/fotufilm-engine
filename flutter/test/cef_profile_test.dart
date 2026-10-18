import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fotufilm_flutter/model/cef_profile/chromium_storage.dart';
import 'package:fotufilm_flutter/model/cef_profile/leveldb.dart';
import 'package:fotufilm_flutter/model/cef_profile/profile_import.dart';
import 'package:fotufilm_flutter/model/cef_profile/snappy.dart';
import 'package:fotufilm_flutter/model/cef_profile/v8_value.dart';
import 'package:fotufilm_flutter/model/cef_profile_io.dart';
import 'package:fotufilm_flutter/model/settings.dart';

// Byte-level fixtures in the formats Chromium writes, built here rather than copied from a
// profile.

List<int> varint(int value) {
  final out = <int>[];
  while (value >= 0x80) {
    out.add(value & 0x7f | 0x80);
    value >>= 7;
  }
  return out..add(value);
}

List<int> little(int value, int bytes) => [for (var k = 0; k < bytes; k++) (value >> (8 * k)) & 0xff];

/// Snappy with literals only, which every decoder must read.
List<int> snappyLiterals(List<int> data) => [...varint(data.length), (data.length - 1) << 2, ...data];

List<int> batch(int sequence, List<(String, List<int>?)> writes) => [
      ...little(sequence, 8),
      ...little(writes.length, 4),
      for (final (key, value) in writes) ...[
        value == null ? 0 : 1,
        ...varint(key.length),
        ...latin1.encode(key),
        if (value != null) ...[...varint(value.length), ...value],
      ],
    ];

/// One log record, or fragments across the 32 KiB block when `split` names where to cut.
List<int> logRecord(List<int> payload, {int? split}) {
  List<int> fragment(int type, List<int> data) =>
      [0, 0, 0, 0, data.length & 0xff, data.length >> 8, type, ...data];
  if (split == null) return fragment(1, payload);
  return [...fragment(2, payload.sublist(0, split)), ...fragment(4, payload.sublist(split))];
}

List<int> internalKey(String key, int sequence, int type) =>
    [...latin1.encode(key), ...little(sequence << 8 | type, 8)];

/// A block of entries without prefix sharing, and its one restart.
List<int> block(List<(List<int>, List<int>)> entries) => [
      for (final (key, value) in entries) ...[0, ...varint(key.length), ...varint(value.length), ...key, ...value],
      ...little(0, 4),
      ...little(1, 4),
    ];

Uint8List table(List<(List<int>, List<int>)> entries, {bool compressed = false}) {
  final data = block(entries);
  final stored = compressed ? snappyLiterals(data) : data;
  final out = <int>[...stored, compressed ? 1 : 0, 0, 0, 0, 0];
  final index = block([(entries.last.$1, [...varint(0), ...varint(stored.length)])]);
  final indexAt = out.length;
  out.addAll([...index, 0, 0, 0, 0, 0]);
  final metaAt = out.length;
  out.addAll([...block([]), 0, 0, 0, 0, 0]);
  final footer = [...varint(metaAt), ...varint(8), ...varint(indexAt), ...varint(index.length)];
  out
    ..addAll(footer)
    ..addAll(List.filled(40 - footer.length, 0))
    ..addAll([0x57, 0xfb, 0x80, 0x8b, 0x24, 0x75, 0x47, 0xdb]);
  return Uint8List.fromList(out);
}

List<int> oneByte(String text) => [0x22, ...varint(text.length), ...latin1.encode(text)];

/// An IndexedDB record: its version, Blink 21's envelope and trailer header, V8 16, the value.
List<int> idbValue(List<int> v8) => [
      ...varint(5),
      0xff, 21, 0xfe, ...List.filled(12, 0),
      0xff, 16,
      ...v8,
    ];

List<int> v8Object(Map<String, List<int>> properties) => [
      0x6f,
      for (final MapEntry(:key, :value) in properties.entries) ...[...oneByte(key), ...value],
      0x7b, ...varint(properties.length),
    ];

List<int> utf16be(String text) => [for (final unit in text.codeUnits) ...[unit >> 8, unit & 0xff]];

void main() {
  test('snappy reads literals and overlapping copies', () {
    expect(utf8.decode(snappyDecompress(Uint8List.fromList([9, 0x08, 97, 98, 99, 0x09, 3]))),
        'abcabcabc');
  });

  test('a log keeps each key at its newest write, fragments joined and deletes applied', () {
    final long = List.filled(40000, 7);
    final first = batch(10, [('a', [1]), ('b', [2]), ('gone', [3])]);
    final second = batch(13, [('a', [4]), ('gone', null), ('long', long)]);
    final log = <int>[...logRecord(first)];
    // The second record crosses into the next 32 KiB block.
    final split = 32768 - log.length - 7;
    log.addAll(logRecord(second, split: split));
    final live = liveEntries(logEntries(Uint8List.fromList(log)));
    expect(live.keys.toSet(), {'a', 'b', 'long'});
    expect(live['a'], [4]);
    expect(live['long']!.length, 40000);
  });

  test('a table reads plain and snappy blocks, and a newer log write wins', () {
    for (final compressed in [false, true]) {
      final entries = tableEntries(table([
        (internalKey('k1', 1, 1), [10]),
        (internalKey('k2', 2, 1), [20]),
        (internalKey('k3', 3, 0), []),
      ], compressed: compressed));
      final live = liveEntries([
        ...entries,
        ...logEntries(Uint8List.fromList(logRecord(batch(9, [('k2', [21])])))),
      ]);
      expect(live, {'k1': [10], 'k2': [21]});
    }
  });

  test('a serialized value reads objects, strings, numbers and arrays', () {
    final value = readIndexedDbValue(Uint8List.fromList(idbValue(v8Object({
      'key': oneByte('folder/photo.arw'),
      'name': [0x63, ...varint(4), 0xe9, 0x00, 0x41, 0x00], // "éA", two-byte
      'rating': [0x49, ...varint(6)], // 3, zigzag
      'added': [0x4e, ...(ByteData(8)..setFloat64(0, 1.5e12, Endian.little)).buffer.asUint8List()],
      'list': [0x41, ...varint(2), 0x54, 0x30, 0x24, 0, 2],
    }))));
    expect(value, {
      'key': 'folder/photo.arw',
      'name': 'éA',
      'rating': 3,
      'added': 1.5e12,
      'list': [true, null],
    });
    // A value Blink moved out to a blob file.
    expect(readSerializedValue(Uint8List.fromList([0xff, 0x11, 0x01, 4, 0])), isNull);
  });

  test('localStorage items and IndexedDB records come back by origin, database and store', () {
    final items = localStorageItems({
      'VERSION': Uint8List.fromList([49]),
      '_fotufilm://app\x00\x01fotufilm.panelWidths': Uint8List.fromList([1, ...latin1.encode('{"film":240}')]),
      '_fotufilm://app\x00\x00${String.fromCharCodes([0x6b, 0, 0x65, 0, 0x79, 0])}':
          Uint8List.fromList([0, 0x68, 0, 0x69, 0]),
    });
    expect(items, {
      'fotufilm://app': {'fotufilm.panelWidths': '{"film":240}', 'key': 'hi'},
    });

    String key(List<int> bytes) => latin1.decode(bytes);
    final records = indexedDbRecords({
      key([0, 0, 0, 0, 201, ...varint(3), ...utf16be('app'), ...varint(5), ...utf16be('libdb')]):
          Uint8List.fromList(varint(1)),
      key([0, 1, 0, 0, 50, ...varint(3), 0]): Uint8List.fromList(utf16be('photos')),
      key([0, 1, 3, 1, 1, ...varint(1), ...utf16be('a')]):
          Uint8List.fromList(idbValue(v8Object({'key': oneByte('a')}))),
      key([0, 1, 3, 2, 1, ...varint(1), ...utf16be('a')]): Uint8List.fromList([1]),
    });
    expect(records, {
      'libdb': {
        'photos': [
          {'key': 'a'},
        ],
      },
    });
  });

  test("the previous app's profile is planned in this app's keys and never replaces what is kept", () {
    final plan = planProfileImport({
      'fotufilm.setting.halationModel': '"layered"',
      'fotufilm.editPresets': '{"presets":[],"sections":["filmStock"]}',
      'fotufilm.library.tileSize': '200',
      'fotufilm.panelWidths': '{"film":236,"inspector":340}',
      'other': '1',
    }, {
      'folders': [
        {
          'id': 'f1',
          'name': 'Trips',
          'handle': {'kind': 'directory', 'hostPath': '/photos/Trips', 'name': 'Trips'},
          'added': 5.0,
        },
      ],
      'photos': [
        {'key': 'f1/a.arw', 'rating': 4, 'edit': '{"version":1,"edit":{}}'},
        {'key': 'f1/b.arw', 'rating': 0},
        {'key': 'sha256:abc', 'edit': 'kept'},
        {'key': 'gone/c.arw', 'edit': 'lost'},
      ],
    });
    expect(plan.settings, {
      'halationModel': 'layered',
      'editPresets': {'presets': [], 'sections': ['filmStock']},
      'library.tileSize': 200,
      'panelWidths': {'film': 236, 'inspector': 340},
    });
    expect(plan.folders, [
      {'id': 'f1', 'path': '/photos/Trips', 'name': 'Trips', 'added': 5, 'negative': false},
    ]);
    expect(plan.records, {
      'f1/a.arw': {'rating': 4, 'edit': true},
    });
    expect(plan.keptEdits, {'sha256:abc': 'kept'});
    expect(plan.pendingEdits, {
      'f1/a.arw': {'path': '/photos/Trips/a.arw', 'edit': '{"version":1,"edit":{}}'},
    });

    final settings = AppSettings.memory()
      ..set('halationModel', 'clump')
      ..set('library.records', {
        'f1/a.arw': {'rating': 2},
      });
    applyProfileImport(settings, plan);
    expect(settings.get<String>('halationModel'), 'clump');
    expect(settings.get<num>('library.tileSize'), 200);
    expect(settings.get<Map>('library.records'), {
      'f1/a.arw': {'rating': 2, 'edit': true},
    });
    expect(settings.get<List>('library.folders'), hasLength(1));
    expect(settings.get<String>('keptEdit:sha256:abc'), 'kept');
    expect((settings.get<Map>('cefProfile.pendingEdits'))?.keys, ['f1/a.arw']);
  });
}
