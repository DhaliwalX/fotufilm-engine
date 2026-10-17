import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fotufilm_flutter/model/library_files.dart';
import 'package:fotufilm_flutter/model/library_model.dart';

LibraryPhoto photo(String path, {int modified = 0, String folder = 'f'}) =>
    LibraryPhoto(folderId: folder, root: '/r', path: path, size: 1, modified: modified);

List<String> names(List<LibraryPhoto> photos) => [for (final p in photos) p.path];

void main() {
  test('names sort naturally, a raw beside its JPEG', () {
    final photos = [photo('IMG_10.jpg'), photo('IMG_9.jpg'), photo('IMG_9.arw'), photo('Photo 2.jpg'), photo('Photo.jpg')];
    expect(names(sortedPhotos([photos], const {}, 'name')),
        ['IMG_9.arw', 'IMG_9.jpg', 'IMG_10.jpg', 'Photo.jpg', 'Photo 2.jpg']);
  });

  test('dates and ratings order, names breaking ties', () {
    final photos = [photo('a.jpg', modified: 2), photo('b.jpg', modified: 3), photo('c.jpg', modified: 2)];
    expect(names(sortedPhotos([photos], const {}, 'newest')), ['b.jpg', 'a.jpg', 'c.jpg']);
    expect(names(sortedPhotos([photos], const {}, 'oldest')), ['a.jpg', 'c.jpg', 'b.jpg']);
    final records = {'f/c.jpg': {'rating': 4}, 'f/b.jpg': {'rating': 1}};
    expect(names(sortedPhotos([photos], records, 'rating')), ['c.jpg', 'b.jpg', 'a.jpg']);
  });

  test('filters narrow by subfolder, name, rating and edit', () {
    final photos = [photo('a.jpg'), photo('roll/b.jpg'), photo('roll/deep/c.jpg'), photo('rolls/d.jpg')];
    final records = {'f/roll/b.jpg': {'rating': 3, 'edit': '{}'}};
    expect(names(filteredPhotos(photos, records, path: 'roll')), ['roll/b.jpg', 'roll/deep/c.jpg']);
    expect(names(filteredPhotos(photos, records, search: 'DEEP')), ['roll/deep/c.jpg']);
    expect(names(filteredPhotos(photos, records, minRating: 2)), ['roll/b.jpg']);
    expect(names(filteredPhotos(photos, records, editedOnly: true)), ['roll/b.jpg']);
  });

  test('the folder tree counts photos in each subfolder and below', () {
    final tree = folderTree([photo('a.jpg'), photo('roll 10/b.jpg'), photo('roll 9/x/c.jpg'), photo('roll 9/d.jpg')]);
    expect(tree['']!.count, 4);
    expect([for (final c in tree['']!.children) c.name], ['roll 9', 'roll 10']);
    expect(tree['roll 9']!.count, 2);
    expect(tree['roll 9/x']!.name, 'x');
  });

  test('clicks, Shift and Command select over the visible order', () {
    final photos = [photo('a.jpg'), photo('b.jpg'), photo('c.jpg'), photo('d.jpg')];
    var s = nextSelection(photos, const LibrarySelection(), 'f/b.jpg');
    expect(s.selected, {'f/b.jpg'});
    s = nextSelection(photos, s, 'f/d.jpg', range: true);
    expect(s.selected, {'f/b.jpg', 'f/c.jpg', 'f/d.jpg'});
    expect(s.anchor, 'f/b.jpg');
    s = nextSelection(photos, s, 'f/c.jpg', toggle: true);
    expect(s.selected, {'f/b.jpg', 'f/d.jpg'});
    expect(steppedKey(photos, 'f/b.jpg', 2), 'f/d.jpg');
    expect(steppedKey(photos, 'f/b.jpg', -10), 'f/a.jpg');
    expect(steppedKey(photos, null, 1), 'f/a.jpg');
    expect(names(menuTargets(photos, s.selected, 'f/d.jpg')), ['b.jpg', 'd.jpg']);
    expect(names(menuTargets(photos, s.selected, 'f/a.jpg')), ['a.jpg']);
  });

  test('one photo opens with its roll, not the folders below', () {
    final folder = [photo('b.jpg'), photo('a.jpg'), photo('sub/c.jpg')];
    final (roll, shown) = openedPhotos([folder.first], folder, const {}, 'name');
    expect(names(roll), ['a.jpg', 'b.jpg']);
    expect(shown, 'f/b.jpg');
    final (chosen, first) = openedPhotos([folder[2], folder[0]], folder, const {}, 'name');
    expect(names(chosen), ['sub/c.jpg', 'b.jpg']);
    expect(first, 'f/sub/c.jpg');
  });

  test('an opened file brings its folder, in name order', () {
    expect(folderItems('/p/b.png', [('b.png', 1, 0), ('a.png', 1, 0), ('c.arw', 1, 0)]),
        ['/p/a.png', '/p/b.png', '/p/c.arw']);
    expect(folderItems('/p/z.png', [('a.png', 1, 0)]), ['/p/z.png']);
    expect(stripPath('/Users/someone/Pictures/a.png'), '~/Pictures/a.png');
  });

  test('names a folder can hold', () {
    expect(nameProblem(''), isNotNull);
    expect(nameProblem('a/b.png'), isNotNull);
    expect(nameProblem('.hidden.png'), isNotNull);
    expect(nameProblem('ok.png'), isNull);
    expect(libraryMediaKind('X.ARW'), 'raw');
    expect(libraryMediaKind('clip.mov'), 'video');
    expect(libraryMediaKind('notes.txt'), isNull);
  });

  test('a folder lists its photos in place, and one is renamed', () async {
    final dir = Directory.systemTemp.createTempSync('library-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    for (final name in ['a.png', 'b.ARW', 'notes.txt', '.hidden.png', 'sub/c.jpg', '.cache/d.jpg']) {
      File('${dir.path}/$name')
        ..createSync(recursive: true)
        ..writeAsStringSync('x');
    }
    final rows = await listFolder(dir.path);
    expect({for (final r in rows) r.$1}, {'a.png', 'b.ARW', 'sub/c.jpg'});
    final top = await listFolder(dir.path, recursive: false);
    expect({for (final r in top) r.$1}, {'a.png', 'b.ARW'});
    final renamed = renameFile('${dir.path}/a.png', 'e.png');
    expect(renamed, '${dir.path}/e.png');
    expect(() => renameFile(renamed, 'b.ARW'), throwsA(isA<FileSystemException>()));
    expect(() => renameFile(renamed, '.e.png'), throwsA(isA<FileSystemException>()));
  });
}
