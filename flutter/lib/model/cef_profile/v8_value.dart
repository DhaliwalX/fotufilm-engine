// A value as Chromium keeps it in IndexedDB: Blink's envelope (its version, and from version 21
// a trailer header) around V8's structured-clone wire format (v8/src/objects/value-serializer.cc).
// What the editor stored is plain data: objects, arrays, strings, numbers and booleans. Values
// Blink moved out to a blob file come back null, and anything else is a FormatException.
import 'dart:convert';
import 'dart:typed_data';

import 'snappy.dart';

/// The value an IndexedDB record holds, after its leading varint version.
Object? readIndexedDbValue(Uint8List record) {
  final reader = _Reader(record)..varint();
  return readSerializedValue(Uint8List.sublistView(record, reader.at));
}

Object? readSerializedValue(Uint8List bytes) {
  // Blink's value wrapping (IDBValueWrapping): 0x11 then a mode, 1 for a value moved to a blob,
  // 2 for one compressed with snappy.
  if (bytes.length > 2 && bytes[0] == 0xff && bytes[1] == 0x11) {
    if (bytes[2] == 1) return null;
    if (bytes[2] == 2) return readSerializedValue(snappyDecompress(Uint8List.sublistView(bytes, 3)));
  }
  final reader = _Reader(bytes);
  // Blink's version, then V8's, each 0xff and a varint; Blink 21 adds a trailer header.
  while (reader.more && bytes[reader.at] == 0xff) {
    reader.at++;
    reader.varint();
    if (reader.more && bytes[reader.at] == 0xfe) reader.at += 1 + 8 + 4;
  }
  return _ValueReader(reader).value();
}

class _Reader {
  _Reader(this.bytes);
  final Uint8List bytes;
  int at = 0;

  bool get more => at < bytes.length;

  int varint() {
    var value = 0, shift = 0;
    while (true) {
      final byte = bytes[at++];
      value |= (byte & 0x7f) << shift;
      if (byte < 0x80) return value;
      shift += 7;
    }
  }

  Uint8List take(int count) {
    final slice = Uint8List.sublistView(bytes, at, at + count);
    at += count;
    return slice;
  }
}

class _ValueReader {
  _ValueReader(this.r);
  final _Reader r;

  /// Objects and arrays in the order they began, for back references (`^`).
  final _objects = <Object>[];

  int _tag() {
    while (true) {
      final tag = r.bytes[r.at++];
      if (tag != 0) return tag; // padding
    }
  }

  Object? value() {
    final tag = _tag();
    switch (tag) {
      case 0x5f: // _ undefined
      case 0x30: // 0 null
      case 0x2d: // - the hole in a dense array
        return null;
      case 0x54: // T
        return true;
      case 0x46: // F
        return false;
      case 0x49: // I int32, zigzag
        final n = r.varint();
        return (n >> 1) ^ -(n & 1);
      case 0x55: // U uint32
        return r.varint();
      case 0x4e: // N double
        return _double();
      case 0x44: // D date: milliseconds since the epoch
        return _double();
      case 0x22: // " one-byte string
        return latin1.decode(r.take(r.varint()));
      case 0x63: // c two-byte string
        final bytes = r.take(r.varint());
        return String.fromCharCodes(
            Uint16List.view(Uint8List.fromList(bytes).buffer, 0, bytes.length ~/ 2));
      case 0x53: // S UTF-8 string
        return utf8.decode(r.take(r.varint()));
      case 0x6f: // o object
        final object = <String, Object?>{};
        _objects.add(object);
        _properties(object, 0x7b);
        r.varint();
        return object;
      case 0x41: // A dense array
        final list = <Object?>[];
        _objects.add(list);
        final length = r.varint();
        for (var k = 0; k < length; k++) {
          list.add(value());
        }
        _properties(<String, Object?>{}, 0x24);
        r
          ..varint()
          ..varint();
        return list;
      case 0x61: // a sparse array
        final list = <Object?>[];
        _objects.add(list);
        list.length = r.varint();
        final entries = <String, Object?>{};
        _properties(entries, 0x40);
        r
          ..varint()
          ..varint();
        entries.forEach((key, item) {
          final index = int.tryParse(key);
          if (index != null && index < list.length) list[index] = item;
        });
        return list;
      case 0x5e: // ^ back reference
        return _objects[r.varint()];
      default:
        throw FormatException('Unsupported serialized value tag 0x${tag.toRadixString(16)}');
    }
  }

  /// Key and value pairs up to `end`; keys are strings or array indices.
  void _properties(Map<String, Object?> into, int end) {
    while (true) {
      final save = r.at;
      if (_tag() == end) return;
      r.at = save;
      final key = value();
      into['$key'] = value();
    }
  }

  double _double() => ByteData.sublistView(r.take(8)).getFloat64(0, Endian.little);
}
