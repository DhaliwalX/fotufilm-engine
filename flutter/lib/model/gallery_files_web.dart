// A browser keeps no gallery: there is no folder, and nothing here is reached without one.
import 'dart:typed_data';

String? galleryFolder() => null;

List<Map<String, dynamic>> readRecords(String folder) => const [];
Object? readRecord(String path) => null;
void writeRecord(String path, Object? record) => throw UnsupportedError('No gallery');
bool isFile(String path) => false;
Future<String> copyInto(String folder, String from, String name) =>
    throw UnsupportedError('No gallery');
String moveInto(String folder, String from) => throw UnsupportedError('No gallery');
Future<void> writeBytes(String path, Uint8List bytes) => throw UnsupportedError('No gallery');
Future<Uint8List?> readBytes(String path) async => null;
void removeFile(String path) {}
void removeFolder(String path, {bool onlyEmpty = false}) {}
