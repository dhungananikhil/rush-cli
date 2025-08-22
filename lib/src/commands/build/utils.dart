import 'dart:convert';
import 'dart:io' show Directory, File, FileMode, Platform, Process;

import 'package:archive/archive.dart';
import 'package:get_it/get_it.dart';
import 'package:path/path.dart' as p;

import 'package:rush_cli/src/config/config.dart';
import 'package:rush_cli/src/services/file_service.dart';
import 'package:rush_cli/src/services/logger.dart';
import 'package:rush_cli/src/utils/file_extension.dart';

class BuildUtils {
  static final _fs = GetIt.I<FileService>();
  static final _lgr = GetIt.I<Logger>();

  static Future<void> unzip(String zipFilePath, String outputDirPath) async {
    final archive =
        ZipDecoder().decodeBytes(await zipFilePath.asFile().readAsBytes());
    for (final el in archive.files) {
      if (el.isFile) {
        final bytes = el.content as List<int>;
        try {
          final file = p.join(outputDirPath, el.name).asFile(true);
          await file.writeAsBytes(bytes);
        } catch (e) {
          _lgr.parseAndLog('error: $e');
          rethrow;
        }
      }
    }
  }

  static Future<void> extractAars(Iterable<String> aars) async {
    for (final aar in aars) {
      final String dist;

      // Extract local AARs in .rush/build/extracted-aars dir, whereas remote AARs
      // in their original location under {aar_basename} dir.
      if (p.isWithin(_fs.localDepsDir.path, aar)) {
        dist = p.join(_fs.buildAarsDir.path, p.basenameWithoutExtension(aar));
      } else {
        dist = p.join(p.dirname(aar), p.basenameWithoutExtension(aar));
      }
      await unzip(aar, dist);
    }
  }

  static String _extractedAarDir(String aarPath) {
    if (p.isWithin(_fs.localDepsDir.path, aarPath)) {
      return p.join(_fs.buildAarsDir.path, p.basenameWithoutExtension(aarPath));
    }
    return p.join(p.dirname(aarPath), p.basenameWithoutExtension(aarPath));
  }

  /// Classpath string separator.
  static String get cpSeparator => Platform.isWindows ? ';' : ':';

  /// Copies extension's assets to the raw directory.
  static Future<void> copyAssets(Config config) async {
    final assets = config.assets;
    if (assets.isEmpty) {
      return;
    }

    final assetsDir = p.join(_fs.cwd, 'assets');
    final assetsDestDir = p.join(_fs.buildRawDir.path, 'assets').asDir(true);

    for (final el in assets) {
      final asset = p.join(assetsDir, el).asFile();
      if (await asset.exists()) {
        await asset.copy(p.join(assetsDestDir.path, el));
      } else {
        throw Exception('Asset $el does not exist');
      }
    }
  }

  /// Copies LICENSE file if there's any.
  static Future<void> copyLicense(Config config) async {
    // Pattern to match URL
    final urlPattern = RegExp(
        r'https?:\/\/(www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()!@:%_\+.~#?&\/\/=]*)',
        dotAll: true);

    final File license;
    if (config.license != '' && !urlPattern.hasMatch(config.license)) {
      license = p.join(_fs.cwd, config.license).asFile();
    } else {
      return;
    }

    final dest = p.join(_fs.buildRawDir.path, 'aiwebres').asDir(true);
    if (await license.exists()) {
      await license.copy(p.join(dest.path, 'LICENSE'));
    }
  }

  static File resourceFromExtractedAar(String aarPath, String resourceName) {
    final dist = _extractedAarDir(aarPath);
    return p.join(dist, resourceName).asFile();
  }

  static Future<void> copyAarLibsAndRes(Iterable<String> aars) async {
    for (final aar in aars) {
      final dist = _extractedAarDir(aar);

      final jniDir = p.join(dist, 'jni').asDir();
      if (await jniDir.exists()) {
        final destRoot = p.join(_fs.buildRawDir.path, 'lib').asDir(true);
        for (final file in jniDir.listSync(recursive: true).whereType<File>()) {
          final relPath = p.relative(file.path, from: jniDir.path);
          final dest = p.join(destRoot.path, relPath).asFile(true);
          await dest.writeAsBytes(await file.readAsBytes());
        }
      }

      final resDir = p.join(dist, 'res').asDir();
      if (await resDir.exists()) {
        final destRoot = p.join(_fs.buildRawDir.path, 'res').asDir(true);
        for (final file in resDir.listSync(recursive: true).whereType<File>()) {
          final relPath = p.relative(file.path, from: resDir.path);
          final dest = p.join(destRoot.path, relPath).asFile(true);
          await dest.writeAsBytes(await file.readAsBytes());
        }
      }

      final rTxt = p.join(dist, 'R.txt').asFile();
      if (await rTxt.exists()) {
        final dest = p.join(_fs.buildRawDir.path, 'R.txt').asFile(true);
        await dest.writeAsString(await rTxt.readAsString(),
            mode: FileMode.append);
      }
    }
  }

  static Future<String> javaHomeDir() async {
    final javaHomeEnv = Platform.environment['JAVA_HOME'];
    if (javaHomeEnv != null) {
      return javaHomeEnv;
    }

    final process = await Process.run(
        Platform.isWindows ? 'where' : 'which', ['java'],
        runInShell: true);
    var exe = process.stdout.toString().trim();
    if (LineSplitter.split(exe).length > 1) {
      exe = LineSplitter.split(exe).first;
    }

    try {
      exe = await exe.asFile().resolveSymbolicLinks();
    } catch (_) {}
    return p.dirname(p.dirname(exe));
  }

  static String javaExe([bool getJavac = false]) {
    final javaHome = Platform.environment['JAVA_HOME'];
    if (javaHome != null) {
      return p.join(javaHome, 'bin', getJavac ? 'javac' : 'java');
    }
    return getJavac ? 'javac' : 'java';
  }
}
