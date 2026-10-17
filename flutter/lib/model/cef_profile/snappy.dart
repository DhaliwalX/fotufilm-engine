// Snappy's block format (github.com/google/snappy, format_description.txt), the compression
// LevelDB tables and Chromium's IndexedDB values use: a varint length, then literals and copies.
import 'dart:typed_data';

Uint8List snappyDecompress(Uint8List input) {
  var i = 0;
  int varint() {
    var value = 0, shift = 0;
    while (true) {
      final byte = input[i++];
      value |= (byte & 0x7f) << shift;
      if (byte < 0x80) return value;
      shift += 7;
    }
  }

  int little(int bytes) {
    var value = 0;
    for (var k = 0; k < bytes; k++) {
      value |= input[i++] << (8 * k);
    }
    return value;
  }

  final out = Uint8List(varint());
  var o = 0;
  while (i < input.length) {
    final tag = input[i++];
    switch (tag & 3) {
      case 0:
        var length = tag >> 2;
        length = (length < 60 ? length : little(length - 59)) + 1;
        out.setRange(o, o + length, input, i);
        i += length;
        o += length;
        continue;
      case 1:
        final length = ((tag >> 2) & 7) + 4;
        _copy(out, o, ((tag >> 5) << 8) | input[i++], length);
        o += length;
      case 2:
        final length = (tag >> 2) + 1;
        _copy(out, o, little(2), length);
        o += length;
      default:
        final length = (tag >> 2) + 1;
        _copy(out, o, little(4), length);
        o += length;
    }
  }
  if (o != out.length) throw const FormatException('Truncated snappy block');
  return out;
}

/// A copy may overlap what it writes (a run), so it goes byte by byte.
void _copy(Uint8List out, int at, int offset, int length) {
  if (offset <= 0 || offset > at) throw const FormatException('Bad snappy copy');
  for (var k = 0; k < length; k++) {
    out[at + k] = out[at - offset + k];
  }
}
