// A browser reads no folders: the library and the opened folder are desktop features.
import 'library_model.dart';

const libraryFilesAvailable = false;

Future<List<FileRow>> listFolder(String folder, {bool recursive = true}) async =>
    throw UnsupportedError('Folders are read on the desktop.');

String renameFile(String path, String name) =>
    throw UnsupportedError('Files are renamed on the desktop.');

bool isFolder(String path) => false;

bool isFile(String path) => false;

String fileProblem(Object error) => '$error';
