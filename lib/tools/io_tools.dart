import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart' hide ZipFile;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/tools/io_extensions.dart';
import 'package:zip_flutter/zip_flutter.dart';

import '../foundation/app.dart';

Future<double> getFolderSize(Directory path) async {
  double total = 0;
  for (var f in path.listSync(recursive: true)) {
    if (FileSystemEntity.typeSync(f.path) == FileSystemEntityType.file) {
      total += File(f.path).lengthSync() / 1024 / 1024;
    }
  }
  return total;
}

Future<bool> exportComic(String id, String name,
    [List<String>? epNames]) async {
  try {
    name = sanitizeFileName(name);
    var data = ExportComicData(
      id,
      downloadManager.path!,
      name,
      epNames,
      downloadManager.getDirectory(id),
    );
    var res = await compute(runningExportComic, data);
    if (!res) {
      return false;
    }

    if (App.isMobile) {
      var params =
          SaveFileDialogParams(sourceFilePath: '${data.path}$pathSep$name.zip');
      await FlutterFileDialog.saveFile(params: params);
    } else {
      final FileSaveLocation? result =
          await getSaveLocation(suggestedName: '$name.zip');

      if (result != null) {
        const String mimeType = 'application/zip';
        final XFile textFile =
            XFile('${data.path}$pathSep$name.zip', mimeType: mimeType);
        await textFile.saveTo(result.path);
      }
    }

    var file = File('${data.path}$pathSep$name.zip');
    file.delete();
    return true;
  } catch (e) {
    return false;
  }
}

Future<bool> exportComics(List<DownloadedItem> comics) async {
  try {
    var exportDatas = <ExportComicData>[];
    for (var comic in comics) {
      var id = comic.id;
      var name = sanitizeFileName(comic.name);
      var path = downloadManager.path;
      var epNames = comic.eps;
      exportDatas.add(ExportComicData(
        id,
        path!,
        name,
        epNames,
        downloadManager.getDirectory(id),
      ));
    }
    await Isolate.run(() => runningExportComics(exportDatas));
    if (App.isMobile) {
      var params = SaveFileDialogParams(
          sourceFilePath: '${downloadManager.path}/comics.zip');
      await FlutterFileDialog.saveFile(params: params);
    } else {
      final FileSaveLocation? result =
          await getSaveLocation(suggestedName: 'comics.zip');

      if (result != null) {
        const String mimeType = 'application/zip';
        final XFile textFile =
            XFile('${downloadManager.path}/comics.zip', mimeType: mimeType);
        await textFile.saveTo(result.path);
      }
    }
    var file = File('${downloadManager.path}/comics.zip');
    if (file.existsSync()) {
      file.delete();
    }
    return true;
  } catch (e) {
    return false;
  }
}

Future<bool> exportPdf(String pdfPath) async {
  try {
    if (App.isMobile) {
      var params = SaveFileDialogParams(sourceFilePath: pdfPath);
      await FlutterFileDialog.saveFile(params: params);
    } else {
      final FileSaveLocation? result = await getSaveLocation(
        suggestedName: File(pdfPath).name,
        acceptedTypeGroups: [const XTypeGroup(label: 'pdf', extensions: ['pdf'])],
      );

      if (result != null) {
        const String mimeType = 'application/pdf';
        final XFile textFile = XFile(pdfPath, mimeType: mimeType);
        await textFile.saveTo(result.path);
      }
    }
    if (File(pdfPath).existsSync()) {
      File(pdfPath).delete();
    }
    return true;
  } catch (e) {
    return false;
  }
}

class ExportComicData {
  String id;
  String path;
  String name;
  String directory;
  List<String>? epNames;

  ExportComicData(this.id, this.path, this.name, this.epNames, this.directory);
}

Future<bool> runningExportComic(ExportComicData data) async {
  final fileName = '${data.path}/${data.name}.zip';
  try {
    final path = Directory("${data.path}/${data.directory}");
    var zipFile = ZipFile.open(fileName);
    String? currentDirName;

    void walk(String path) {
      for (var entry in Directory(path).listSync()) {
        if (entry is Directory) {
          var index = int.parse(entry.name) - 1;
          currentDirName = sanitizeFileName(
              data.epNames?.elementAtOrNull(index) ?? "Chapter ${index + 1}");
          walk(entry.path);
        } else {
          var filePathInZip = sanitizeFileName(data.name);
          if (currentDirName != null) {
            filePathInZip += "/$currentDirName";
          }
          filePathInZip += "/${entry.name}";
          zipFile.addFile(filePathInZip, entry.path);
        }
      }
    }

    walk(path.path);
    zipFile.close();
    return true;
  } catch (e, s) {
    LogManager.addLog(LogLevel.error, "IO", "$e\n$s");
    return false;
  }
}

Future<bool> runningExportComics(List<ExportComicData> datas) async {
  try {
    var result = "${datas.first.path}/comics.zip";
    if (File(result).existsSync()) {
      File(result).deleteSync();
    }
    var zipFile = ZipFile.open(result);
    for (var data in datas) {
      final directory = Directory('${data.path}/${data.directory}');

      String? currentDirName;

      void walk(String path) {
        for (var entry in Directory(path).listSync()) {
          if (entry is Directory) {
            var index = int.parse(entry.name) - 1;
            currentDirName = sanitizeFileName(
                data.epNames?.elementAtOrNull(index) ?? "Chapter ${index + 1}");
            walk(entry.path);
          } else {
            var filePathInZip = sanitizeFileName(data.name);
            if (currentDirName != null) {
              filePathInZip += "/$currentDirName";
            }
            filePathInZip += "/${entry.name}";
            zipFile.addFile(filePathInZip, entry.path);
          }
        }
      }

      walk(directory.path);
    }
    zipFile.close();
    return true;
  } catch (e, s) {
    LogManager.addLog(LogLevel.error, "IO", "$e\n$s");
    return false;
  }
}

Future<void> eraseCache() async {
  return CacheManager().clear();
}

Future<void> copyDirectory(Directory source, Directory destination) async {
  try {
    List<FileSystemEntity> contents = source.listSync();
    for (FileSystemEntity content in contents) {
      String newPath = destination.path +
          Platform.pathSeparator +
          content.path.split(Platform.pathSeparator).last;

      if (content is File) {
        content.copySync(newPath);
      } else if (content is Directory) {
        Directory newDirectory = Directory(newPath);
        newDirectory.createSync();
        copyDirectory(content.absolute, newDirectory.absolute);
      }
    }
  } catch (e, s) {
    LogManager.addLog(LogLevel.error, "IO", "$e\n$s");
    rethrow;
  }
}

/// move all files and directories from source to destination
Future<void> moveDirectory(Directory source, Directory destination) async {
  try {
    source = source.absolute;
    destination = destination.absolute;
    List<FileSystemEntity> contents = source.listSync();
    for (FileSystemEntity content in contents) {
      if (content is File) {
        await content
            .rename(destination.path + Platform.pathSeparator + content.name);
      } else if (content is Directory) {
        Directory newDirectory =
            Directory(destination.path + Platform.pathSeparator + content.name);
        newDirectory.createSync(recursive: true);
        await moveDirectory(content, newDirectory);
      }
    }
    await source.deleteIgnoreError(recursive: true);
  } catch (e, s) {
    LogManager.addLog(LogLevel.error, "IO", "$e\n$s");
    rethrow;
  }
}

///检查下载目录是否可用, 不可用则重置
Future<void> checkDownloadPath() async {
  var path = appdata.settings[22];
  if (path != "") {
    var directory = Directory(path);
    if (!directory.existsSync()) {
      appdata.settings[22] = "";
      appdata.updateSettings();
    }
  }
}

Future<String?> _exportData(String path, String appdataString,
    String? downloadPath, String outPath) async {
  var encode = ZipFile.open(outPath);
  try {
    var filePath = "$path${pathSep}appdata";
    var file = File(filePath);
    if (file.existsSync()) {
      file.deleteSync();
    }
    file.createSync();
    file.writeAsStringSync(appdataString);
    encode.addFile(file.uri.pathSegments.last, file.path);
    var localFavorite = File("$path${pathSep}local_favorite.db");
    var history = File("$path${pathSep}history.db");
    if (!localFavorite.existsSync()) {
      localFavorite.createSync();
    }
    if (!history.existsSync()) {
      history.createSync();
    }
    encode.addFile(
        localFavorite.name, localFavorite.path.replaceAll("\\", "/"));
    encode.addFile(history.name, history.path);
    encode.addFile('cookies.db', "$path/cookies.db");
    await for (var entry in Directory("$path/comic_source").list()) {
      if (entry is File) {
        encode.addFile('comic_source/${entry.name}', entry.path);
      }
    }
    if (downloadPath != null) {
      downloadPath = downloadPath.replaceAll('\\', '/');
      var sourceFolder =
          downloadPath.substring(0, downloadPath.lastIndexOf('/'));
      void walk(String path) {
        for (var entry in Directory(path).listSync()) {
          if (entry is Directory) {
            walk(entry.path);
          } else {
            var filePathInZip = entry.path.replaceFirst(sourceFolder, "");
            if (filePathInZip.startsWith('/') ||
                filePathInZip.startsWith('\\')) {
              filePathInZip = filePathInZip.substring(1);
            }
            encode.addFile(filePathInZip, entry.path);
          }
        }
      }

      walk(downloadPath);
    }
    return null;
  } catch (e) {
    return e.toString();
  } finally {
    encode.close();
  }
}

Future<String> exportDataToFile(bool includeDownload, String outPath) async {
  var path = App.dataPath;
  try {
    var appdataString = const JsonEncoder().convert(appdata.toJson());
    var downloadPath = includeDownload ? DownloadManager().path : null;
    var res = await compute<List<String?>, String?>(
        (message) =>
            _exportData(message[0]!, message[1]!, message[2], message[3]!),
        [path, appdataString, downloadPath, outPath]);

    if (res != null) {
      throw Exception(res);
    }
  } catch (e, s) {
    LogManager.addLog(LogLevel.error, "IO", "$e\n$s");
    rethrow;
  }
  return outPath;
}

Future<bool> runExportData(bool includeDownload) async {
  try {
    var outPath = '${App.cachePath}/userdata.picadata';
    if (App.isDesktop) {
      final FileSaveLocation? result =
          await getSaveLocation(suggestedName: 'userData.picadata');
      if (result == null) {
        return true;
      }
      outPath = result.path;
    }
    if (await File(outPath).exists()) {
      await File(outPath).delete();
    }
    await exportDataToFile(includeDownload, outPath);

    var dialog = showLoadingDialog(
      App.globalContext!,
      barrierDismissible: false,
      allowCancel: false,
    );

    if (App.isMobile) {
      var params = SaveFileDialogParams(sourceFilePath: outPath);
      await FlutterFileDialog.saveFile(params: params);
      File(outPath).delete();
    }

    dialog.close();
  } catch (e, s) {
    LogManager.addLog(LogLevel.error, "IO", "$e\n$s");
    return false;
  }
  return true;
}

/// 导入用户数据。
///
/// [filePath] 仅 WebDAV 同步时传入；为 null 时弹出文件选择器。
///
/// 旧实现在任何一步出错都会把异常抛给调用方（而调用方没有 catch），
/// 导致加载对话框永远关不掉，看起来就是"导入时卡死/闪退"。
/// 现在所有步骤都做了防护：坏文件、旧版本备份、损坏的子数据库
/// 最多只是返回 false，不会让 App 卡在不可取消的弹窗里。
Future<bool> importData([String? filePath]) async {
  final enableCheck = filePath != null;
  final path = (await getApplicationSupportDirectory()).path;

  // 1. 选择文件
  try {
    if (filePath == null) {
      if (App.isMobile) {
        filePath = await FlutterFileDialog.pickFile(
            params: const OpenFileDialogParams());
      } else {
        const XTypeGroup typeGroup = XTypeGroup(label: 'data');
        final XFile? file =
            await openFile(acceptedTypeGroups: <XTypeGroup>[typeGroup]);
        filePath = file?.path;
      }
    }
  } catch (e, s) {
    LogManager.addLog(
        LogLevel.error, "importData", "failed to pick file: $e\n$s");
    return false;
  }
  if (filePath == null) {
    LogManager.addLog(LogLevel.error, "importData", "filePath is null");
    return false;
  }

  // 2. 基本校验：存在、非空、且真的是 zip（.picadata 就是 zip）
  try {
    final file = File(filePath);
    if (!await file.exists() || await file.length() < 4) {
      LogManager.addLog(
          LogLevel.error, "importData", "not a valid file: $filePath");
      return false;
    }
    var header = <int>[];
    final raf = await file.open();
    try {
      header = await raf.read(4);
    } finally {
      await raf.close();
    }
    if (header.length < 4 || header[0] != 0x50 || header[1] != 0x4B) {
      LogManager.addLog(
          LogLevel.error, "importData", "not a zip archive: $filePath");
      return false;
    }
  } catch (e, s) {
    LogManager.addLog(
        LogLevel.error, "importData", "failed to check file: $e\n$s");
    return false;
  }

  final downloadPath = DownloadManager().path;
  if (downloadPath == null) {
    LogManager.addLog(LogLevel.error, "importData", "download path is null");
    return false;
  }

  // 3. 解压到独立的临时目录，先校验内容再动现有数据
  final tempDir = "$path/dataTemp_${DateTime.now().millisecondsSinceEpoch}";
  try {
    SingleInstanceCookieJar.instance?.dispose();
  } catch (e, s) {
    LogManager.addLog(
        LogLevel.error, "importData", "failed to dispose cookie jar: $e\n$s");
  }
  try {
    DownloadManager().dispose();
  } catch (e, s) {
    LogManager.addLog(LogLevel.error, "importData",
        "failed to dispose download manager: $e\n$s");
  }

  String? data;
  try {
    data = await compute(_importDataTask, <String>[
      path,
      filePath,
      tempDir,
      downloadPath,
      appdata.settings[46],
      enableCheck ? "1" : "0",
    ]);
  } catch (e, s) {
    LogManager.addLog(LogLevel.error, "importData", "$e\n$s");
    data = null;
  } finally {
    // 清理临时目录和旧版本残留，任何清理失败都不能影响返回值
    await Directory(tempDir).deleteIgnoreError(recursive: true);
    await Directory("$path/dataTemp").deleteIgnoreError(recursive: true);
    await _restoreAfterImport();
  }

  if (data == null || data.isEmpty) {
    return false;
  }

  // 4. 解析并校验 appdata
  Map<String, dynamic> json;
  try {
    final decoded = const JsonDecoder().convert(data);
    if (decoded is! Map<String, dynamic>) {
      LogManager.addLog(LogLevel.error, "importData", "appdata is not a map");
      return false;
    }
    if (decoded["settings"] is! List) {
      LogManager.addLog(LogLevel.error, "importData", "appdata has no settings");
      return false;
    }
    json = decoded;
  } catch (e, s) {
    LogManager.addLog(
        LogLevel.error, "importData", "failed to decode appdata: $e\n$s");
    return false;
  }

  try {
    final settings = json["settings"] as List;
    final rawVersion = settings.elementAtOrNull(46);
    final fileVersion = int.tryParse("$rawVersion") ?? 1;
    final appVersion = int.tryParse(appdata.settings[46]) ?? 0;
    if (enableCheck && fileVersion <= appVersion) {
      LogManager.addLog(
          LogLevel.info,
          "Appdata",
          "The data file version is $fileVersion, while the app data version is "
              "$appVersion\nStop importing data");
      return false;
    }
  } catch (e) {
    // 版本号解析失败时按最新版本处理，继续导入
  }

  bool dataReadRes;
  try {
    dataReadRes = appdata.readDataFromJson(json);
  } catch (e, s) {
    LogManager.addLog(
        LogLevel.error, "Appdata", "readDataFromJson failed: $e\n$s");
    dataReadRes = false;
  }
  if (!dataReadRes) {
    LogManager.addLog(
        LogLevel.error, "Appdata", "appdata.readDataFromJson(json) failed");
    return false;
  }

  // 5. 合并历史与本地收藏：这些子库可能来自旧版本，失败不影响导入结果
  try {
    await LocalFavoritesManager().readData();
    LocalFavoritesManager().updateUI();
  } catch (e, s) {
    LogManager.addLog(
        LogLevel.error, "importData", "failed to read local favorites: $e\n$s");
  }
  try {
    await HistoryManager().tryUpdateDb();
  } catch (e, s) {
    LogManager.addLog(
        LogLevel.error, "importData", "failed to read history: $e\n$s");
  }
  return true;
}

/// 导入结束后把被 dispose 的服务重新拉起来，每一步都单独兜底。
Future<void> _restoreAfterImport() async {
  try {
    await ComicSource.reload();
  } catch (e, s) {
    LogManager.addLog(
        LogLevel.error, "importData", "failed to reload comic source: $e\n$s");
  }
  try {
    SingleInstanceCookieJar.instance?.init();
  } catch (e, s) {
    LogManager.addLog(
        LogLevel.error, "importData", "failed to init cookie jar: $e\n$s");
  }
  try {
    await DownloadManager().init();
  } catch (e, s) {
    LogManager.addLog(LogLevel.error, "importData",
        "failed to init download manager: $e\n$s");
  }
}

/// 纯 Dart 的 zip 解压（逐条解压，内存只占用单个文件）。
///
/// 之所以不用 zip_flutter：它的原生实现在 100MB 级别的备份上会踩坏堆，
/// 进程直接被 SIGABRT 杀掉，日志里是
/// `Scudo ERROR: invalid chunk state when deallocating address`。
void _extractZip(String zipPath, String dest) {
  final input = InputFileStream(zipPath);
  try {
    final archive = ZipDecoder().decodeBuffer(input);
    for (final entry in archive) {
      if (!entry.isFile) {
        continue;
      }
      final name = entry.name.replaceAll('\\', '/');
      if (name.isEmpty ||
          name.startsWith('/') ||
          name.split('/').contains('..')) {
        continue;
      }
      final out = File('$dest/$name');
      out.parent.createSync(recursive: true);
      final content = entry.content;
      if (content is List<int>) {
        out.writeAsBytesSync(content, flush: true);
      }
      // 注意：不要调用 entry.closeSync()，它会关掉共享的输入流，
      // 下一条会读到错位的数据并抛 "Filter error, bad data"。
    }
  } finally {
    try {
      input.closeSync();
    } catch (e) {
      // ignore
    }
  }
}

/// 在独立 isolate 里解压并应用备份，返回 appdata 的 JSON 文本。
///
/// 返回空字符串表示因版本检查而跳过；内容不合法时抛异常，由调用方捕获。
Future<String> _importDataTask(List<String> args) async {
  final path = args[0];
  final filePath = args[1];
  final tempDir = args[2];
  final downloadPath = args[3];
  final currentVersion = args[4];
  final enableCheck = args[5] == "1";

  final temp = Directory(tempDir);
  if (temp.existsSync()) {
    temp.deleteSync(recursive: true);
  }
  // 用纯 Dart 的 archive 解压：zip_flutter 的原生实现在大备份上会触发
  // Scudo 堆损坏（Fatal signal 6 / invalid chunk state），导致直接闪退。
  _extractZip(filePath, tempDir);

  final appdataFile = File("$tempDir/appdata");
  if (!appdataFile.existsSync()) {
    throw Exception("Invalid backup: appdata not found");
  }
  final jsonString = appdataFile.readAsStringSync();
  final decoded = const JsonDecoder().convert(jsonString);
  if (decoded is! Map<String, dynamic> || decoded["settings"] is! List) {
    throw Exception("Invalid backup: appdata format error");
  }
  final settings = decoded["settings"] as List;
  final rawVersion = settings.elementAtOrNull(46);
  final fileVersion = int.tryParse("$rawVersion") ?? 1;
  final appVersion = int.tryParse(currentVersion) ?? 0;
  if (enableCheck && fileVersion <= appVersion) {
    return "";
  }

  // 旧版本可能把内容放在别的目录名里，统一归到 download 下
  final downloadDir = Directory("$tempDir/download");
  for (var item in temp.listSync()) {
    if (item is Directory &&
        item.name != "comic_source" &&
        item.name != "download") {
      downloadDir.createSync(recursive: true);
      item.renameSync("${downloadDir.path}/${item.name}");
    }
  }

  final localFavorite = File("$tempDir/localFavorite");
  if (localFavorite.existsSync()) {
    localFavorite.copySync("$path/localFavorite");
  } else {
    final legacyFavorite = File("$tempDir/local_favorite.db");
    if (legacyFavorite.existsSync()) {
      legacyFavorite.copySync("$path/local_favorite_temp.db");
    }
  }

  final history = File("$tempDir/history.db");
  if (history.existsSync()) {
    history.copySync("$path/history_temp.db");
  }

  final comicSource = Directory("$tempDir/comic_source");
  if (comicSource.existsSync()) {
    final current = Directory("$path/comic_source");
    if (current.existsSync()) {
      current.deleteSync(recursive: true);
    }
    comicSource.renameSync("$path/comic_source");
  }

  final cookies = File("$tempDir/cookies.db");
  if (cookies.existsSync()) {
    cookies.copySync("$path/cookies.db");
  }

  final downloadData = Directory("$tempDir/download");
  if (downloadData.existsSync()) {
    final target = Directory(downloadPath);
    if (target.existsSync()) {
      target.deleteSync(recursive: true);
    }
    target.createSync(recursive: true);
    await moveDirectory(downloadData, target);
  }

  return jsonString;
}

void saveLog(String log) async {
  var path = (await getTemporaryDirectory()).path;
  var file = File("$path${pathSep}logs.txt");
  file.writeAsStringSync(log);
  if (App.isMobile) {
    var params =
        SaveFileDialogParams(sourceFilePath: "$path${pathSep}logs.txt");
    await FlutterFileDialog.saveFile(params: params);
  } else {
    final String? directoryPath = await getDirectoryPath();
    if (directoryPath != null) {
      await file.copy("$directoryPath${pathSep}logs.txt");
    }
  }
}

Future<void> exportStringDataAsFile(String data, String fileName) async {
  if (App.isMobile) {
    var cachePath = (await getApplicationCacheDirectory()).path;
    var file = File("$cachePath$pathSep$fileName");
    if (!file.existsSync()) {
      file.createSync();
    }
    file.writeAsStringSync(data);
    var params = SaveFileDialogParams(sourceFilePath: file.path);
    await FlutterFileDialog.saveFile(params: params);
  } else {
    final FileSaveLocation? result =
        await getSaveLocation(suggestedName: fileName);
    if (result == null) {
      return;
    }

    final Uint8List fileData =
        Uint8List.fromList(const Utf8Encoder().convert(data));
    const String mimeType = 'text/plain';
    final XFile textFile =
        XFile.fromData(fileData, mimeType: mimeType, name: fileName);
    await textFile.saveTo(result.path);
  }
}

Future<String?> getDataFromUserSelectedFile(List<String> extensions) async {
  String? filePath;
  if (App.isMobile) {
    var params = const OpenFileDialogParams();
    filePath = await FlutterFileDialog.pickFile(params: params);
  } else {
    XTypeGroup typeGroup = XTypeGroup(
      label: 'data',
      extensions: extensions,
    );
    final XFile? file =
        await openFile(acceptedTypeGroups: <XTypeGroup>[typeGroup]);
    filePath = file?.path;
  }
  if (filePath == null) {
    return null;
  }
  return File(filePath).readAsStringSync();
}

extension FileExtension on File {
  String get name => uri.pathSegments.last;
}

String bytesLengthToReadableSize(int size) {
  if (size < 1024) {
    return "$size B";
  } else if (size < 1024 * 1024) {
    return "${(size / 1024).toStringAsFixed(2)} KB";
  } else if (size < 1024 * 1024 * 1024) {
    return "${(size / 1024 / 1024).toStringAsFixed(2)} MB";
  } else {
    return "${(size / 1024 / 1024 / 1024).toStringAsFixed(2)} GB";
  }
}
