import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/tools/io_extensions.dart';
import 'package:sqlite3/sqlite3.dart';

/// 磁盘缓存管理器（图片、网络响应共用）。
///
/// 旧实现在缓存变大后会把 App 拖死，原因都集中在 [checkCache] 被高频调用：
///
/// 1. 每关闭一张图片都会 `await checkCache()`，而 [checkCache] 每次都用
///    `compute` 新开一个 isolate 去遍历整个缓存目录统计大小。缓存文件越多，
///    这次遍历越慢，于是每翻一页都要多花几十到几百毫秒，而且 isolate 会随
///    翻页速度堆积，最终 ANR 或被系统杀掉。
/// 2. 统计大小是异步回调，整理循环里读到的却是旧值，还可能读到 null
///    （`_currentSize!` 直接抛异常）。
/// 3. 整理时按 `ORDER BY expires` 每轮取 10 条，但 `expires` 上没有索引，
///    每一轮都是全表扫描 + 排序。
/// 4. 退出条件依赖目录大小；一旦目录里存在数据库没登记的“孤儿文件”
///    （进程被杀在“建文件”和“写库”之间就会产生），大小永远降不下去，
///    循环就永远退不出来。
/// 5. `count > 2000` 这条硬编码上限和用户设置的大小限制无关。按每页
///    400~600KB 计算，2000 条正好约 1GB —— 这就是“设置 10GB 也没用、
///    到 1GB 左右就开始闪退”的直接原因。
///
/// 现在的做法：
/// * 目录大小只在启动时统计一次，之后随写入/删除增量维护；
/// * 只有确实超限或到了清理周期才真正干活，并做了节流，不再在翻页路径上
///   做全目录遍历；
/// * `expires` 上建索引，按过期时间批量删除；
/// * 目录与数据库不一致时做一次对账，清掉孤儿文件；
/// * 所有循环都有次数上限，异常一律吞掉并复位状态，不会永久卡住整理逻辑。
class CacheManager {
  static String get cachePath => '${App.cachePath}/cache';

  static CacheManager? instance;

  late Database _db;

  /// 已缓存字节数，由启动时的统计和之后的写入/删除增量维护。
  int _currentSize = 0;

  /// 是否已经统计过一次目录大小。
  bool _sizeKnown = false;

  late final Future<void> _sizeFuture;

  int _limitSize = 2 * 1024 * 1024 * 1024;

  /// 缓存大小限制，单位字节。
  int get limitSize => _limitSize;

  /// 当前缓存大小，单位字节。启动时统计完成前为 0。
  int get currentSize => _currentSize;

  int dir = 0;

  /// 一次 [checkCache] 最多处理的批次数，剩下的留到下一次，
  /// 避免一次性删除大量文件长时间占用主线程。
  static const int _maxBatchesPerRun = 8;

  /// 每批处理的记录数。
  static const int _trimBatch = 32;

  /// 两次“按大小整理”之间的最小间隔。
  static const Duration _trimInterval = Duration(seconds: 3);

  /// 两次“清理过期记录”之间的最小间隔。
  static const Duration _purgeInterval = Duration(minutes: 10);

  /// 条目数硬上限，防止几 KB 的小图片把目录塞满 inode。
  static const int _maxEntries = 20000;

  DateTime _lastTrimTime = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastPurgeTime = DateTime.fromMillisecondsSinceEpoch(0);

  bool _isChecking = false;

  CacheManager._create() {
    Directory(cachePath).createSync(recursive: true);
    _db = sqlite3.open('${App.dataPath}/cache.db');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS cache (
        key TEXT PRIMARY KEY NOT NULL,
        dir TEXT NOT NULL,
        name TEXT NOT NULL,
        expires INTEGER NOT NULL,
        type TEXT
      )
    ''');
    // 旧版本的表中没有 type 字段，需要添加
    try {
      _db.execute('ALTER TABLE cache ADD COLUMN type TEXT');
    } catch (e) {
      // ignore
    }
    // 整理时要按 expires 取最旧的记录，没有索引就只能全表扫描 + 排序
    _db.execute(
        'CREATE INDEX IF NOT EXISTS idx_cache_expires ON cache(expires)');
    _sizeFuture = _refreshSize();
  }

  factory CacheManager() => instance ??= CacheManager._create();

  /// 设置缓存大小限制，单位 MB。
  void setLimitSize(int size) {
    final limit = (size <= 0 ? 1 : size) * 1024 * 1024;
    if (limit == _limitSize) {
      return;
    }
    _limitSize = limit;
    // 限制变小后立刻整理一次，不等下一次翻页
    _lastTrimTime = DateTime.fromMillisecondsSinceEpoch(0);
    unawaited(checkCache(force: true));
  }

  void setType(String key, String? type) {
    _db.execute('''
      UPDATE cache
      SET type = ?
      WHERE key = ?
    ''', [type, key]);
  }

  String? getType(String key) {
    var res = _db.select('''
      SELECT type FROM cache
      WHERE key = ?
    ''', [key]);
    if (res.isEmpty) {
      return null;
    }
    return res.first[0];
  }

  Future<void> writeCache(String key, Uint8List data,
      [int duration = 7 * 24 * 60 * 60 * 1000]) async {
    dir = (dir + 1) % 100;
    final dirName = dir.toString();
    var name = md5.convert(Uint8List.fromList(key.codeUnits)).toString();
    var file = File('$cachePath/$dirName/$name');
    while (await file.exists()) {
      name = md5.convert(Uint8List.fromList(name.codeUnits)).toString();
      file = File('$cachePath/$dirName/$name');
    }
    await file.create(recursive: true);
    await file.writeAsBytes(data);
    _insert(key, dirName, name,
        DateTime.now().millisecondsSinceEpoch + duration);
    _accountWrite(data.length);
    await checkCache();
  }

  Future<CachingFile> openWrite(String key) async {
    dir = (dir + 1) % 100;
    final dirName = dir.toString();
    var name = md5.convert(Uint8List.fromList(key.codeUnits)).toString();
    var file = File('$cachePath/$dirName/$name');
    while (await file.exists()) {
      name = md5.convert(Uint8List.fromList(name.codeUnits)).toString();
      file = File('$cachePath/$dirName/$name');
    }
    await file.create(recursive: true);
    return CachingFile._(key, dirName, name, file);
  }

  Future<String?> findCache(String key) async {
    var res = _db.select('''
      SELECT * FROM cache
      WHERE key = ?
    ''', [key]);
    if (res.isEmpty) {
      return null;
    }
    var row = res.first;
    var dir = row[1] as String;
    var name = row[2] as String;
    var file = File('$cachePath/$dir/$name');
    if (await file.exists()) {
      return file.path;
    }
    return null;
  }

  /// 整理缓存。
  ///
  /// 不在超限、也没有过期记录要清时，这里只做两次时间比较，几乎不耗时，
  /// 因此可以安全地在每次写完缓存后调用。
  ///
  /// [force] 为 true 时忽略节流，立即检查（例如用户刚把限制调小）。
  Future<void> checkCache({bool force = false}) async {
    if (_isChecking) {
      return;
    }
    _isChecking = true;
    try {
      if (!_sizeKnown) {
        // 首次调用时等启动阶段的统计完成，之后再也不会进这里
        await _sizeFuture;
      }
      final now = DateTime.now();
      final overLimit = _currentSize > _limitSize;
      final trimDue =
          force || (overLimit && now.difference(_lastTrimTime) >= _trimInterval);
      final purgeDue =
          force || now.difference(_lastPurgeTime) >= _purgeInterval;
      if (!trimDue && !purgeDue) {
        return;
      }
      if (purgeDue) {
        _lastPurgeTime = now;
        await _removeExpired();
        await _enforceMaxEntries();
      }
      if (trimDue || _currentSize > _limitSize) {
        _lastTrimTime = now;
        await _trimToLimit();
      }
    } catch (e, s) {
      // 整理失败不能影响业务，更不能把 _isChecking 卡在 true 上
      debugPrint('CacheManager: failed to trim cache: $e\n$s');
    } finally {
      _isChecking = false;
    }
  }

  Future<void> delete(String key) async {
    var res = _db.select('''
      SELECT dir, name FROM cache
      WHERE key = ?
    ''', [key]);
    if (res.isEmpty) {
      return;
    }
    await _deleteFile(res.first[0] as String, res.first[1] as String);
    _deleteKeys([key]);
  }

  Future<void> clear() async {
    await Directory(cachePath).deleteIgnoreError(recursive: true);
    Directory(cachePath).createSync(recursive: true);
    _db.execute('''
      DELETE FROM cache
    ''');
    _currentSize = 0;
    _sizeKnown = true;
  }

  Future<void> deleteKeyword(String keyword) async {
    var res = _db.select('''
      SELECT key, dir, name FROM cache
      WHERE key LIKE ?
    ''', ['%$keyword%']);
    if (res.isEmpty) {
      return;
    }
    final keys = <String>[];
    for (var row in res) {
      keys.add(row[0] as String);
      await _deleteFile(row[1] as String, row[2] as String);
    }
    _deleteKeys(keys);
  }

  // ---------------------------------------------------------------------------
  // 内部实现
  // ---------------------------------------------------------------------------

  /// 启动时统计一次目录大小。
  Future<void> _refreshSize() async {
    try {
      _currentSize = await _directorySize();
    } catch (e) {
      _currentSize = 0;
    }
    _sizeKnown = true;
    if (_currentSize > _limitSize) {
      // 启动时就已经超限，在后台整理一次，不阻塞初始化流程
      scheduleMicrotask(() {
        unawaited(checkCache(force: true));
      });
    }
  }

  Future<int> _directorySize() async {
    try {
      if (!Directory(cachePath).existsSync()) {
        return 0;
      }
      return await compute(_calcDirectorySize, cachePath);
    } catch (e) {
      debugPrint('CacheManager: failed to calculate cache size: $e');
      return _currentSize;
    }
  }

  void _insert(String key, String dirName, String name, int expires) {
    _db.execute('''
      INSERT OR REPLACE INTO cache (key, dir, name, expires) VALUES (?, ?, ?, ?)
    ''', [key, dirName, name, expires]);
  }

  void _accountWrite(int bytes) {
    if (!_sizeKnown) {
      return;
    }
    _currentSize += bytes;
    if (_currentSize < 0) {
      _currentSize = 0;
    }
  }

  void _accountDelete(int bytes) {
    if (!_sizeKnown) {
      return;
    }
    _currentSize -= bytes;
    if (_currentSize < 0) {
      _currentSize = 0;
    }
  }

  /// 删除一个缓存文件，并从总大小里扣掉它。
  Future<void> _deleteFile(String dirName, String name) async {
    final file = File('$cachePath/$dirName/$name');
    try {
      if (await file.exists()) {
        final length = await file.length();
        await file.delete();
        _accountDelete(length);
      }
    } catch (e) {
      // 文件可能已被系统清理或被占用，忽略即可
    }
  }

  void _deleteKeys(List<String> keys) {
    if (keys.isEmpty) {
      return;
    }
    // 分片，避免 SQL 变量数量超限
    const chunkSize = 200;
    for (var i = 0; i < keys.length; i += chunkSize) {
      final end = i + chunkSize < keys.length ? i + chunkSize : keys.length;
      final part = keys.sublist(i, end);
      final placeholders = List.filled(part.length, '?').join(',');
      _db.execute('DELETE FROM cache WHERE key IN ($placeholders)', part);
    }
  }

  /// 清除所有已过期的记录。
  Future<void> _removeExpired() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final res = _db.select('''
      SELECT key, dir, name FROM cache
      WHERE expires < ?
      LIMIT 512
    ''', [now]);
    if (res.isEmpty) {
      return;
    }
    final keys = <String>[];
    for (var row in res) {
      keys.add(row[0] as String);
      await _deleteFile(row[1] as String, row[2] as String);
    }
    _deleteKeys(keys);
  }

  /// 删除最旧的一批记录，返回是否删掉了东西。
  Future<bool> _removeOldestBatch(int limit) async {
    final res = _db.select('''
      SELECT key, dir, name FROM cache
      ORDER BY expires ASC
      LIMIT ?
    ''', [limit]);
    if (res.isEmpty) {
      return false;
    }
    final keys = <String>[];
    for (var row in res) {
      keys.add(row[0] as String);
      await _deleteFile(row[1] as String, row[2] as String);
    }
    _deleteKeys(keys);
    return true;
  }

  /// 按大小删除最旧的记录，直到降到限制以内。
  ///
  /// 一轮最多处理 [_maxBatchesPerRun] 批，剩下的等下一次调用，
  /// 保证单次调用不会长时间占用 UI 线程；循环本身有硬上限，
  /// 目录里存在孤儿文件时也不会无限循环。
  Future<void> _trimToLimit() async {
    var reconciled = false;
    var batches = 0;
    while (_currentSize > _limitSize) {
      if (!_sizeKnown) {
        return;
      }
      if (batches >= _maxBatchesPerRun) {
        return;
      }
      batches++;
      final removed = await _removeOldestBatch(_trimBatch);
      if (removed) {
        // 让出事件循环，避免连续删除文件把主线程卡住
        await Future<void>.delayed(Duration.zero);
        continue;
      }
      if (reconciled) {
        // 数据库里没有记录了，目录却还是超限：剩下的不是缓存文件，放弃
        return;
      }
      reconciled = true;
      // 目录里有数据库没登记的孤儿文件，做一次对账再重新统计
      await _reconcileOrphans();
      _currentSize = await _directorySize();
    }
  }

  /// 条目数兜底，避免大量小文件把目录塞爆。
  Future<void> _enforceMaxEntries() async {
    var guard = 0;
    while (_count() > _maxEntries) {
      if (++guard > 64) {
        return;
      }
      final removed = await _removeOldestBatch(_trimBatch);
      if (!removed) {
        return;
      }
      await Future<void>.delayed(Duration.zero);
    }
  }

  int _count() {
    final res = _db.select('SELECT COUNT(*) FROM cache');
    if (res.isEmpty) {
      return 0;
    }
    return res.first[0] as int;
  }

  /// 删除目录里没有数据库记录的孤儿文件（进程被杀、写文件后没来得及写库等）。
  Future<int> _reconcileOrphans() async {
    final directory = Directory(cachePath);
    if (!directory.existsSync()) {
      _db.execute('DELETE FROM cache');
      return 0;
    }
    final known = <String>{};
    for (var row in _db.select('SELECT dir, name FROM cache')) {
      known.add('${row[0]}/${row[1]}');
    }
    var deleted = 0;
    for (var entity
        in directory.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      var relative = entity.path;
      if (relative.startsWith(cachePath)) {
        relative = relative.substring(cachePath.length);
        if (relative.startsWith('/') || relative.startsWith('\\')) {
          relative = relative.substring(1);
        }
      }
      relative = relative.replaceAll('\\', '/');
      if (known.contains(relative)) {
        continue;
      }
      try {
        await entity.delete();
        deleted++;
      } catch (e) {
        // 忽略单个文件的删除失败
      }
    }
    return deleted;
  }
}

/// 供 `compute` 调用，在独立 isolate 里统计目录大小。
int _calcDirectorySize(String path) {
  var total = 0;
  final directory = Directory(path);
  if (!directory.existsSync()) {
    return 0;
  }
  for (var entity in directory.listSync(recursive: true, followLinks: false)) {
    if (entity is File) {
      try {
        total += entity.lengthSync();
      } catch (e) {
        // 文件可能刚刚被删除
      }
    }
  }
  return total;
}

class CachingFile {
  CachingFile._(this.key, this.dir, this.name, this.file);

  final String key;

  final String dir;

  final String name;

  final File file;

  final List<int> _buffer = [];

  Future<void> writeBytes(List<int> data) async {
    _buffer.addAll(data);
    if (_buffer.length > 1024 * 1024) {
      await file.writeAsBytes(_buffer, mode: FileMode.append);
      _buffer.clear();
    }
  }

  Future<void> close() async {
    if (_buffer.isNotEmpty) {
      await file.writeAsBytes(_buffer, mode: FileMode.append);
      _buffer.clear();
    }
    final manager = CacheManager();
    var size = 0;
    try {
      size = await file.length();
    } catch (e) {
      // 忽略
    }
    manager._insert(
        key,
        dir,
        name,
        DateTime.now().millisecondsSinceEpoch + 7 * 24 * 60 * 60 * 1000);
    manager._accountWrite(size);
    await manager.checkCache();
  }

  Future<void> cancel() async {
    await file.deleteIgnoreError();
  }

  void reset() {
    _buffer.clear();
    if (file.existsSync()) {
      file.deleteSync();
    }
  }
}
