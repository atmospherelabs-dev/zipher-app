import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  for (final synchronous in [false, true]) {
    final mode = synchronous ? 'sync' : 'async';

    test('$mode extraction keeps chained links inside a disposable fixture',
        () async {
      final fixture = Directory.systemTemp.createTempSync('zipher-archive-');
      addTearDown(() => fixture.deleteSync(recursive: true));
      final output = path.join(fixture.path, 'output');
      final outside = Directory(path.join(fixture.path, 'outside'))
        ..createSync();
      final sentinel = File(path.join(outside.path, 'sentinel.txt'))
        ..writeAsStringSync('unchanged');
      // Both apparent link targets stay below output. Resolving the first
      // link changes the second link's parent, so lexical checks alone fail.
      Directory(path.join(output, 'foo')).createSync(recursive: true);
      Directory(path.join(output, 'x')).createSync();
      final archive = Archive()
        ..addFile(ArchiveFile.symlink('foo/a', '../x'))
        ..addFile(ArchiveFile.symlink('foo/a/b', '../../outside'))
        ..addFile(ArchiveFile.string('foo/a/b/sentinel.txt', 'replaced'));

      if (synchronous) {
        extractArchiveToDiskSync(archive, output);
      } else {
        await extractArchiveToDisk(archive, output);
      }

      expect(sentinel.readAsStringSync(), 'unchanged');
      expect(
        FileSystemEntity.typeSync(path.join(output, 'foo/a/b'),
            followLinks: false),
        isNot(FileSystemEntityType.link),
      );
    }, skip: Platform.isWindows);

    test('$mode extraction preserves ordinary ZIP content', () async {
      final fixture = Directory.systemTemp.createTempSync('zipher-archive-');
      addTearDown(() => fixture.deleteSync(recursive: true));
      final original = Archive()
        ..addFile(ArchiveFile.string('nested/content.txt', 'ordinary content'));
      final archive = ZipDecoder().decodeBytes(ZipEncoder().encode(original));
      if (synchronous) {
        extractArchiveToDiskSync(archive, fixture.path);
      } else {
        await extractArchiveToDisk(archive, fixture.path);
      }
      expect(
          File(path.join(fixture.path, 'nested/content.txt'))
              .readAsStringSync(),
          'ordinary content');
    });
  }
}
