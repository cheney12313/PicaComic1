import 'dart:convert';
import 'dart:io';

/// 单次读盘大小。解压过程中常驻内存只有这一个缓冲区，
/// 与备份体积、条目数量都无关。
const int _zipChunkSize = 256 * 1024;

/// zip 中央目录里的一条记录。
class _ZipEntry {
  final String name;
  final int method;
  final int compressedSize;
  final int uncompressedSize;
  final int localOffset;

  const _ZipEntry(this.name, this.method, this.compressedSize,
      this.uncompressedSize, this.localOffset);
}

int _u16(List<int> b, int o) => b[o] | (b[o + 1] << 8);

int _u32(List<int> b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

int _u64(List<int> b, int o) => _u32(b, o) + (_u32(b, o + 4) * 0x100000000);

/// 流式解压 zip 到 [dest]，全程不把单个条目读进内存。
///
/// 旧实现用 `ZipDecoder().decodeBuffer()`，它有两个致命问题：
/// 1. 构造每个条目时就把该条目的压缩数据整段读入内存
///    （archive 3.6.1 `zip_file.dart:78`），所有条目累计下来等于
///    整个备份的大小 —— GB 级备份必然把 isolate 撑爆，表现为"闪退"；
/// 2. 找不到 EOCD 时逐字节向前扫整个文件，未导出完/损坏的备份
///    表现为"卡在导入界面"。
///
/// 这里自己解析中央目录，再按条目分块解压：内存占用恒定，损坏的备份
/// 会在极短时间内抛出可读的异常，由调用方转成"导入失败"提示。
///
/// [onProgress] 按已解压字节数回调（done / total），调用频率被节流到
/// 每 100ms 一次左右，避免大备份上每 256KB 就往主 isolate 发一条消息。
Future<void> extractZipStreaming(String zipPath, String dest,
    {void Function(int done, int total)? onProgress}) async {
  final raf = await File(zipPath).open();
  try {
    final length = await raf.length();
    if (length < 22) {
      throw const FormatException("备份文件太小，不是有效的 zip");
    }

    // 1. 读取文件尾部，从后向前找 EOCD（最多回退 64KB + 注释长度）
    final tailLen = length < 22 + 0xFFFF ? length : 22 + 0xFFFF;
    final tailStart = length - tailLen;
    await raf.setPosition(tailStart);
    final tail = await raf.read(tailLen);

    var eocdAt = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (_u32(tail, i) != 0x06054b50) {
        continue;
      }
      final commentLen = _u16(tail, i + 20);
      if (i + 22 + commentLen <= tail.length) {
        eocdAt = i;
        break;
      }
    }
    if (eocdAt < 0) {
      throw const FormatException(
          "备份文件不完整：找不到 zip 目录记录，导出可能被中断");
    }

    var entries = _u16(tail, eocdAt + 10);
    var cdSize = _u32(tail, eocdAt + 12);
    var cdOffset = _u32(tail, eocdAt + 16);

    // 2. zip64：>4GB 的备份（带下载内容）必须走这里
    if (entries == 0xFFFF ||
        cdSize == 0xFFFFFFFF ||
        cdOffset == 0xFFFFFFFF) {
      final eocdAbs = tailStart + eocdAt;
      if (eocdAbs < 20) {
        throw const FormatException("备份文件不完整：zip64 目录缺失");
      }
      await raf.setPosition(eocdAbs - 20);
      final locator = await raf.read(20);
      if (locator.length == 20 && _u32(locator, 0) == 0x07064b50) {
        final z64Pos = _u64(locator, 8);
        if (z64Pos + 56 <= length) {
          await raf.setPosition(z64Pos);
          final z64 = await raf.read(56);
          if (z64.length == 56 && _u32(z64, 0) == 0x06064b50) {
            entries = _u64(z64, 32);
            cdSize = _u64(z64, 40);
            cdOffset = _u64(z64, 48);
          }
        }
      }
    }

    // 3. 目录本身要落在文件范围内，并且不能大到离谱
    if (cdOffset < 0 || cdSize <= 0 || cdOffset + cdSize > length) {
      throw const FormatException("备份文件不完整：zip 目录越界，导出可能被中断");
    }
    if (entries > 2000000 || cdSize > 128 * 1024 * 1024) {
      throw const FormatException("备份文件异常：zip 目录过大");
    }

    await raf.setPosition(cdOffset);
    final cd = await raf.read(cdSize);
    if (cd.length < cdSize) {
      throw const FormatException("备份文件不完整：zip 目录读取不完整");
    }

    // 4. 解析中央目录
    final list = <_ZipEntry>[];
    var p = 0;
    while (p + 46 <= cd.length) {
      if (_u32(cd, p) != 0x02014b50) {
        break;
      }
      final method = _u16(cd, p + 10);
      var compSize = _u32(cd, p + 20);
      var uncompSize = _u32(cd, p + 24);
      final nameLen = _u16(cd, p + 28);
      final extraLen = _u16(cd, p + 30);
      final commentLen = _u16(cd, p + 32);
      var localOffset = _u32(cd, p + 42);
      if (p + 46 + nameLen + extraLen > cd.length) {
        break;
      }
      final name =
          utf8.decode(cd.sublist(p + 46, p + 46 + nameLen), allowMalformed: true);

      // zip64 扩展字段（id = 0x0001）按「未压缩、压缩、偏移」顺序补齐
      if (compSize == 0xFFFFFFFF ||
          uncompSize == 0xFFFFFFFF ||
          localOffset == 0xFFFFFFFF) {
        final ex = cd.sublist(
            p + 46 + nameLen, p + 46 + nameLen + extraLen);
        var q = 0;
        while (q + 4 <= ex.length) {
          final id = _u16(ex, q);
          final size = _u16(ex, q + 2);
          if (id == 0x0001) {
            var r = q + 4;
            if (uncompSize == 0xFFFFFFFF && r + 8 <= ex.length) {
              uncompSize = _u64(ex, r);
              r += 8;
            }
            if (compSize == 0xFFFFFFFF && r + 8 <= ex.length) {
              compSize = _u64(ex, r);
              r += 8;
            }
            if (localOffset == 0xFFFFFFFF && r + 8 <= ex.length) {
              localOffset = _u64(ex, r);
            }
            break;
          }
          q += 4 + size;
        }
      }

      list.add(_ZipEntry(name, method, compSize, uncompSize, localOffset));
      p += 46 + nameLen + extraLen + commentLen;
    }
    if (list.isEmpty && entries > 0) {
      throw const FormatException("备份文件异常：zip 目录为空");
    }

    // 5. 逐条流式解压
    //
    // 先滤掉目录项和不安全的路径，再按「实际要解压的条目」统计总字节数，
    // 这样百分比才会真正走到 100%。
    final todo = <_ZipEntry>[];
    var totalBytes = 0;
    for (final entry in list) {
      final name = entry.name.replaceAll('\\', '/');
      if (name.isEmpty ||
          name.endsWith('/') ||
          name.startsWith('/') ||
          name.split('/').contains('..')) {
        continue;
      }
      todo.add(entry);
      totalBytes += entry.uncompressedSize > 0
          ? entry.uncompressedSize
          : entry.compressedSize;
    }

    var doneBytes = 0;
    var lastReport = 0;
    void report({bool force = false}) {
      if (onProgress == null) {
        return;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      if (!force && now - lastReport < 100) {
        return;
      }
      lastReport = now;
      onProgress(doneBytes, totalBytes);
    }

    report(force: true);
    for (final entry in todo) {
      final name = entry.name.replaceAll('\\', '/');
      if (entry.localOffset + 30 > length) {
        throw FormatException("备份文件不完整：条目 $name 越界");
      }
      await raf.setPosition(entry.localOffset);
      final local = await raf.read(30);
      if (local.length < 30 || _u32(local, 0) != 0x04034b50) {
        throw FormatException("备份文件损坏：条目 $name 的头记录无效");
      }
      final dataStart =
          entry.localOffset + 30 + _u16(local, 26) + _u16(local, 28);
      if (dataStart + entry.compressedSize > length) {
        throw FormatException(
            "备份文件不完整：条目 $name 的数据被截断，导出可能被中断");
      }
      final out = File('$dest/$name');
      await out.parent.create(recursive: true);
      final base = doneBytes;
      await _extractEntry(raf, dataStart, entry, out, (written) {
        doneBytes = base + written;
        report();
      });
      // 条目结束也走节流：几万个小文件的备份否则会把端口塞满消息
      report();
    }
    // 收尾对齐到 100%，避免末尾条目大小未知时停在 99%
    doneBytes = totalBytes;
    report(force: true);
  } finally {
    await raf.close();
  }
}

/// 解压单条目：分块读、分块 inflate、分块落盘。
///
/// 落盘用 [RandomAccessFile.writeFrom] 并逐块 await —— 不能用 IOSink：
/// 它只是把数据塞进异步队列，喂得比写得快时整条流会滞留在内存里
/// （实测 800MB 的单条目会让峰值涨到 700MB 以上）。
Future<void> _extractEntry(RandomAccessFile src, int dataStart, _ZipEntry entry,
    File out, void Function(int written) onWritten) async {
  final dst = await out.open(mode: FileMode.writeOnly);
  var written = 0;
  try {
    await src.setPosition(dataStart);
    var remaining = entry.compressedSize;

    if (entry.method == 0) {
      // stored：直接搬运
      while (remaining > 0) {
        final chunk = await src.read(
            remaining > _zipChunkSize ? _zipChunkSize : remaining);
        if (chunk.isEmpty) {
          throw FormatException("条目 ${entry.name} 读取不完整");
        }
        await dst.writeFrom(chunk);
        written += chunk.length;
        remaining -= chunk.length;
        onWritten(written);
      }
    } else if (entry.method == 8) {
      // deflate：同步 inflate，输出立刻写盘
      final filter = RawZLibFilter.inflateFilter(raw: true);
      while (remaining > 0) {
        final chunk = await src.read(
            remaining > _zipChunkSize ? _zipChunkSize : remaining);
        if (chunk.isEmpty) {
          throw FormatException("条目 ${entry.name} 读取不完整");
        }
        remaining -= chunk.length;
        filter.process(chunk, 0, chunk.length);
        List<int>? outChunk;
        while ((outChunk = filter.processed(flush: false)) != null) {
          await dst.writeFrom(outChunk!);
          written += outChunk.length;
        }
        onWritten(written);
      }
      List<int>? tail;
      while ((tail = filter.processed(flush: true, end: true)) != null) {
        await dst.writeFrom(tail!);
        written += tail.length;
      }
      onWritten(written);
    } else {
      throw FormatException(
          "不支持的压缩方式 ${entry.method}（条目 ${entry.name}）");
    }

    if (entry.uncompressedSize > 0 && written != entry.uncompressedSize) {
      throw FormatException(
          "条目 ${entry.name} 解压后大小不符（$written/${entry.uncompressedSize}），备份已损坏");
    }
  } finally {
    await dst.close();
  }
}
