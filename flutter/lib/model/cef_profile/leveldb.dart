// A LevelDB directory read once, as Chromium leaves its localStorage and IndexedDB on disk
// (github.com/google/leveldb, doc/table_format.md and doc/log_format.md): every table and log
// it holds, each key at its newest sequence number, deleted keys left out. Keys are kept as
// Latin-1 strings, one character per byte, so binary keys compare and slice losslessly.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'snappy.dart';

typedef LevelDbEntry = ({String key, int sequence, Uint8List? value});

/// The live entries of the database in `directory`.
Map<String, Uint8List> readLevelDb(Directory directory) {
  final entries = <LevelDbEntry>[];
  for (final file in directory.listSync().whereType<File>()) {
    final name = file.uri.pathSegments.last;
    if (name.endsWith('.ldb') || name.endsWith('.sst')) {
      entries.addAll(tableEntries(file.readAsBytesSync()));
    } else if (name.endsWith('.log') && name != 'LOG') {
      entries.addAll(logEntries(file.readAsBytesSync()));
    }
  }
  return liveEntries(entries);
}

/// Each key's newest entry, without the deleted ones.
Map<String, Uint8List> liveEntries(Iterable<LevelDbEntry> entries) {
  final newest = <String, LevelDbEntry>{};
  for (final entry in entries) {
    final kept = newest[entry.key];
    if (kept == null || entry.sequence > kept.sequence) newest[entry.key] = entry;
  }
  return {
    for (final entry in newest.values)
      if (entry.value != null) entry.key: entry.value!,
  };
}

class _Reader {
  _Reader(this.bytes, [this.at = 0]);
  final Uint8List bytes;
  int at;

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

  int little(int count) {
    var value = 0;
    for (var k = 0; k < count; k++) {
      value |= bytes[at++] << (8 * k);
    }
    return value;
  }

  Uint8List take(int count) {
    final slice = Uint8List.sublistView(bytes, at, at + count);
    at += count;
    return slice;
  }
}

String _key(List<int> bytes) => latin1.decode(bytes);

// Tables -----------------------------------------------------------------------------------

const _tableMagic = [0x57, 0xfb, 0x80, 0x8b, 0x24, 0x75, 0x47, 0xdb];

/// A sorted table's entries: its index names the data blocks; each key is the user key and an
/// eight-byte tag, the sequence number over the entry's type (0 deleted, 1 a value).
List<LevelDbEntry> tableEntries(Uint8List file) {
  if (file.length < 48) throw const FormatException('Not a LevelDB table');
  for (var k = 0; k < 8; k++) {
    if (file[file.length - 8 + k] != _tableMagic[k]) {
      throw const FormatException('Not a LevelDB table');
    }
  }
  final footer = _Reader(file, file.length - 48);
  footer
    ..varint()
    ..varint(); // the metaindex: filters only
  final index = _block(file, footer.varint(), footer.varint());
  final entries = <LevelDbEntry>[];
  for (final (_, handle) in _blockEntries(index)) {
    final at = _Reader(handle);
    for (final (key, value) in _blockEntries(_block(file, at.varint(), at.varint()))) {
      if (key.length < 8) continue;
      final tag = _Reader(key, key.length - 8).little(8);
      entries.add((
        key: _key(Uint8List.sublistView(key, 0, key.length - 8)),
        sequence: tag >> 8,
        value: (tag & 0xff) == 1 ? value : null,
      ));
    }
  }
  return entries;
}

/// A block's contents, inflated when its trailer says it is snappy-compressed.
Uint8List _block(Uint8List file, int offset, int size) {
  final contents = Uint8List.sublistView(file, offset, offset + size);
  return switch (file[offset + size]) {
    0 => contents,
    1 => snappyDecompress(contents),
    _ => throw const FormatException('Unknown LevelDB block compression'),
  };
}

/// Prefix-compressed entries, up to the restart array at the block's end.
List<(Uint8List, Uint8List)> _blockEntries(Uint8List block) {
  final restarts = _Reader(block, block.length - 4).little(4);
  final end = block.length - 4 - 4 * restarts;
  final reader = _Reader(block);
  final entries = <(Uint8List, Uint8List)>[];
  var previous = Uint8List(0);
  while (reader.at < end) {
    final shared = reader.varint(), unshared = reader.varint(), length = reader.varint();
    final key = Uint8List(shared + unshared)
      ..setRange(0, shared, previous)
      ..setRange(shared, shared + unshared, reader.take(unshared));
    entries.add((key, reader.take(length)));
    previous = key;
  }
  return entries;
}

// Logs -------------------------------------------------------------------------------------

const _logBlock = 32768;

/// A log's write batches: records laid in 32 KiB blocks, a long one in fragments.
List<LevelDbEntry> logEntries(Uint8List file) {
  final entries = <LevelDbEntry>[];
  final pending = BytesBuilder(copy: false);
  var at = 0;
  while (at + 7 <= file.length) {
    final left = _logBlock - at % _logBlock;
    if (left < 7) {
      at += left;
      continue;
    }
    final length = file[at + 4] | file[at + 5] << 8, type = file[at + 6];
    if (type == 0 && length == 0) {
      at += left; // the block's zero padding
      continue;
    }
    if (at + 7 + length > file.length) break; // a torn last write
    final fragment = Uint8List.sublistView(file, at + 7, at + 7 + length);
    at += 7 + length;
    switch (type) {
      case 1:
        pending.clear();
        entries.addAll(_batch(fragment));
      case 2:
        pending
          ..clear()
          ..add(fragment);
      case 3:
        pending.add(fragment);
      case 4:
        pending.add(fragment);
        entries.addAll(_batch(pending.takeBytes()));
    }
  }
  return entries;
}

/// A write batch: its first sequence number, its count, then each put or delete in turn.
List<LevelDbEntry> _batch(Uint8List batch) {
  if (batch.length < 12) return const [];
  final reader = _Reader(batch);
  var sequence = reader.little(8);
  final count = reader.little(4);
  final entries = <LevelDbEntry>[];
  for (var k = 0; k < count && reader.more; k++) {
    final type = batch[reader.at++];
    final key = _key(reader.take(reader.varint()));
    final value = type == 1 ? Uint8List.fromList(reader.take(reader.varint())) : null;
    entries.add((key: key, sequence: sequence++, value: value));
  }
  return entries;
}
