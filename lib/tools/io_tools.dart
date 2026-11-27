import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart' hide ZipFile, ZLibDecoder;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
import 'package:pica_comic/tools/zip_stream.dart';
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
      if (downloadPath.endsWith('/')) {
        downloadPath = downloadPath.substring(0, downloadPath.length - 1);
      }
      // 备份包内固定以 download/ 作为顶层目录, 与导入端约定一致.
      // 不能再用“下载目录的上一级”作基准: 下载目录可被设置为 /sdcard/xxx,
      // 那样会生成 xxx/... 的路径, 导入时会被整体塞进 download/ 多套一层.
      final base = downloadPath;
      final out = outPath.replaceAll('\\', '/');
      void walk(String path) {
        for (var entry in Directory(path).listSync()) {
          if (entry is Directory) {
            walk(entry.path);
          } else {
            final filePath = entry.path.replaceAll('\\', '/');
            // 输出文件恰好位于下载目录内时跳过, 否则会边写边读自身
            if (filePath == out) {
              continue;
            }
            var relative = filePath.substring(base.length);
            if (relative.startsWith('/')) {
              relative = relative.substring(1);
            }
            if (relative.isEmpty) {
              continue;
            }
            encode.addFile('download/$relative', entry.path);
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

/// 导入的四个阶段。文案见 [ImportStage.label]，由调用方负责本地化。
class ImportProgress {
  const ImportProgress(this.stage, this.done, this.total);

  final ImportStage stage;
  final int done;
  final int total;

  /// 本阶段进度 0~1；total 未知（例如 SAF 拿不到文件大小）时为 null，
  /// 此时界面按"不确定进度"转圈。
  ///
  /// 为什么不用全局加权进度：各阶段耗时差别太大（13GB 的复制要一分钟，
  /// 写入只要几百毫秒），固定权重会让复制阶段几十秒都停在 2%，看着像卡死。
  /// 现在每个阶段各自从 0 走到 100%，界面同时显示阶段名。
  double? get fraction => total > 0 ? (done / total).clamp(0.0, 1.0) : null;
}

enum ImportStage {
  /// 系统文件选择器把所选文件复制进应用缓存（只有走选择器时才有）
  copying,
  extracting,
  applying,
  merging;

  String get label {
    switch (this) {
      case ImportStage.copying:
        return "正在读取备份文件";
      case ImportStage.extracting:
        return "正在解压数据";
      case ImportStage.applying:
        return "正在写入数据";
      case ImportStage.merging:
        return "正在合并历史记录";
    }
  }
}

/// 导入用户数据。
///
/// [filePath] 仅 WebDAV 同步时传入；为 null 时弹出文件选择器。
/// [onProgress] 覆盖全流程：复制 → 解压 → 写入 → 合并。
///
/// 旧实现在任何一步出错都会把异常抛给调用方（而调用方没有 catch），
/// 导致加载对话框永远关不掉，看起来就是"导入时卡死/闪退"。
/// 现在所有步骤都做了防护：坏文件、旧版本备份、损坏的子数据库
/// 最多只是返回 false，不会让 App 卡在不可取消的弹窗里。
Future<bool> importData([String? filePath,
    void Function(ImportProgress progress)? onProgress]) async {
  final enableCheck = filePath != null;
  final path = (await getApplicationSupportDirectory()).path;
  var pickedCopy = false;

  // 1. 选择文件
  try {
    if (filePath == null) {
      if (App.isMobile) {
        // Android 走自己的 SAF 通道：复制阶段就能拿到字节进度。
        // flutter_file_dialog 把复制藏在插件里，13GB 要静默几十秒。
        filePath = await _pickBackupFile(
            (done, total) => onProgress
                ?.call(ImportProgress(ImportStage.copying, done, total)));
        // 只有我们自己复制进缓存的文件才删，其它平台的插件路径不碰
        pickedCopy = Platform.isAndroid && filePath != null;
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
  final pickedPath = filePath;

  try {
    return await _importFromFile(pickedPath, path,
        enableCheck: enableCheck, onProgress: onProgress);
  } finally {
    // 缓存副本是我们自己复制进来的，导入一结束就删：
    // GB 级的备份留在 cache 里会把用户的存储吃光。
    if (pickedCopy) {
      await File(pickedPath).deleteIgnoreError();
    }
  }
}

/// 校验 → 解压到临时目录 → 写入 → 合并。拆出来只是为了用 finally 清理缓存副本。
Future<bool> _importFromFile(
    String filePath, String path,
    {required bool enableCheck,
    void Function(ImportProgress progress)? onProgress}) async {
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
    data = await _runImportTask(<String>[
      path,
      filePath,
      tempDir,
      downloadPath,
      appdata.settings[46],
      enableCheck ? "1" : "0",
    ], onProgress: onProgress);
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
  onProgress?.call(const ImportProgress(ImportStage.merging, 0, 4));
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

  // 5. 合并：先写 appdata，再合并历史与本地收藏
  onProgress?.call(const ImportProgress(ImportStage.merging, 1, 4));
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
  onProgress?.call(const ImportProgress(ImportStage.merging, 2, 4));

  // 这些子库可能来自旧版本，失败不影响导入结果
  try {
    await LocalFavoritesManager().readData();
    LocalFavoritesManager().updateUI();
  } catch (e, s) {
    LogManager.addLog(
        LogLevel.error, "importData", "failed to read local favorites: $e\n$s");
  }
  onProgress?.call(const ImportProgress(ImportStage.merging, 3, 4));
  try {
    await HistoryManager().tryUpdateDb();
  } catch (e, s) {
    LogManager.addLog(
        LogLevel.error, "importData", "failed to read history: $e\n$s");
  }
  onProgress?.call(const ImportProgress(ImportStage.merging, 4, 4));
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

/// Android 侧的备份选择通道：选完文件由原生分块复制并回传字节进度。
const _filePickChannel = MethodChannel('pica_comic/filePick');

void Function(int done, int total)? _copyProgress;

/// 让用户选一个备份文件并复制到应用缓存，返回缓存路径；取消返回 null。
///
/// Android 用自己的 SAF 实现，复制阶段能回传进度；其它平台退回
/// flutter_file_dialog（它的复制在插件内部，拿不到进度）。
Future<String?> _pickBackupFile(
    void Function(int done, int total)? onProgress) async {
  if (!Platform.isAndroid) {
    return FlutterFileDialog.pickFile(params: const OpenFileDialogParams());
  }
  _copyProgress = onProgress;
  _filePickChannel.setMethodCallHandler((call) async {
    if (call.method == "progress") {
      final args = call.arguments;
      if (args is Map) {
        _copyProgress?.call((args["done"] as num?)?.toInt() ?? 0,
            (args["total"] as num?)?.toInt() ?? 0);
      }
    }
    return null;
  });
  try {
    return await _filePickChannel.invokeMethod<String>("pickAndCopy");
  } finally {
    _copyProgress = null;
  }
}

/// 旧的 zip_flutter / archive 解压路径在大备份上会闪退，这里统一走流式实现。
Future<void> _extractZip(String zipPath, String dest,
        {void Function(int done, int total)? onProgress}) =>
    extractZipStreaming(zipPath, dest, onProgress: onProgress);

/// 在独立 isolate 里跑导入任务，并把解压进度回传到主 isolate。
///
/// 不用 `compute`：它只能拿到最终返回值，没法把中间进度传回来。
/// 这里的消息协议只有两种：
/// - `[done, total]`：解压字节进度；
/// - `String`：任务结果（空串表示因版本检查而跳过）。
///
/// 出错时 isolate 内的异常走 onError 端口，进程不会因为 isolate 崩掉而
/// 留下一个永远关不掉的加载框 —— 任何一条路径都把 completer 收口。
Future<String?> _runImportTask(List<String> args,
    {void Function(ImportProgress progress)? onProgress}) async {
  final messages = ReceivePort();
  final errors = ReceivePort();
  final exits = ReceivePort();
  final completer = Completer<String?>();
  Isolate? isolate;

  messages.listen((msg) {
    if (completer.isCompleted) {
      return;
    }
    if (msg is Map) {
      if (msg["t"] == "p") {
        onProgress?.call(ImportProgress(
          _stageFromName(msg["s"] as String?),
          (msg["d"] as num?)?.toInt() ?? 0,
          (msg["n"] as num?)?.toInt() ?? 0,
        ));
        return;
      }
      if (msg["t"] == "r") {
        final value = msg["v"];
        completer.complete(value is String ? value : null);
        return;
      }
    }
    completer.complete(null);
  });

  errors.listen((msg) {
    if (completer.isCompleted) {
      return;
    }
    final text = msg is List && msg.isNotEmpty ? "${msg[0]}" : "$msg";
    LogManager.addLog(LogLevel.error, "importData", "isolate error: $text");
    completer.completeError(Exception(text));
  });

  // isolate 退出时若还没收到结果（例如被系统杀掉），稍等一下再收口，
  // 免得结果消息和退出消息跨端口竞争时被误判成失败。
  exits.listen((_) async {
    await Future.delayed(const Duration(milliseconds: 300));
    if (!completer.isCompleted) {
      LogManager.addLog(
          LogLevel.error, "importData", "import isolate exited without result");
      completer.complete(null);
    }
  });

  try {
    isolate = await Isolate.spawn(
      _importDataTaskEntry,
      <Object>[messages.sendPort, args],
      onError: errors.sendPort,
      onExit: exits.sendPort,
      errorsAreFatal: true,
    );
    return await completer.future;
  } finally {
    isolate?.kill(priority: Isolate.immediate);
    messages.close();
    errors.close();
    exits.close();
  }
}

/// isolate 入口：跑 [_importDataTask]，进度通过 [SendPort] 回传。
///
/// 消息协议（Map）：
/// - `{"t": "p", "s": 阶段名, "d": 已完成, "n": 总量}`：进度
/// - `{"t": "r", "v": 结果}`：最终结果
void _importDataTaskEntry(List<Object> args) async {
  final port = args[0] as SendPort;
  final input = args[1] as List<String>;
  final result = await _importDataTask(input, (stage, done, total) {
    port.send(<String, Object>{
      "t": "p",
      "s": stage.name,
      "d": done,
      "n": total,
    });
  });
  port.send(<String, Object>{"t": "r", "v": result});
}

/// 阶段名反查回枚举；名字对不上（版本不一致）时按解压中处理。
ImportStage _stageFromName(String? name) => ImportStage.values.firstWhere(
    (stage) => stage.name == name,
    orElse: () => ImportStage.extracting);

/// 在独立 isolate 里解压并应用备份，返回 appdata 的 JSON 文本。
///
/// 返回空字符串表示因版本检查而跳过；内容不合法时抛异常，由调用方捕获。
Future<String> _importDataTask(List<String> args,
    [void Function(ImportStage stage, int done, int total)? onProgress]) async {
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
  // 流式解压：内存占用与备份体积无关，GB 级备份也不会撑爆 isolate。
  await _extractZip(filePath, tempDir,
      onProgress: (done, total) =>
          onProgress?.call(ImportStage.extracting, done, total));

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

  // 后面几步是纯文件操作，也报一下，免得解压完 100% 卡住不动
  onProgress?.call(ImportStage.applying, 0, 4);

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

  onProgress?.call(ImportStage.applying, 1, 4);
  final localFavorite = File("$tempDir/localFavorite");
  if (localFavorite.existsSync()) {
    localFavorite.copySync("$path/localFavorite");
  } else {
    final legacyFavorite = File("$tempDir/local_favorite.db");
    if (legacyFavorite.existsSync()) {
      legacyFavorite.copySync("$path/local_favorite_temp.db");
    }
  }

  onProgress?.call(ImportStage.applying, 2, 4);
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

  onProgress?.call(ImportStage.applying, 3, 4);
  final downloadData = Directory("$tempDir/download");
  if (downloadData.existsSync()) {
    final target = Directory(downloadPath);
    if (target.existsSync()) {
      target.deleteSync(recursive: true);
    }
    target.createSync(recursive: true);
    // 临时目录位于应用私有空间 (/data), 目标目录通常在公共存储 (/sdcard),
    // 两者不是同一个文件系统, rename 会抛 EXDEV, 所以只能复制后删除.
    await copyDirectory(downloadData, target);
    await downloadData.deleteIgnoreError(recursive: true);
  }
  onProgress?.call(ImportStage.applying, 4, 4);

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
