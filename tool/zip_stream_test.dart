// 流式解压的独立验证脚本（不依赖 Flutter）：
//   dart run tool/zip_stream_test.dart <zip> <dest>
// 输出耗时、峰值内存、解压出的文件数与总大小，并校验进度回调：
// 必须单调不减、首个值接近 0、最后一个值等于 100%。
import 'dart:io';

import '../lib/tools/zip_stream.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: dart run tool/zip_stream_test.dart <zip> <dest>');
    exit(2);
  }
  final zip = args[0];
  final dest = args[1];

  final dir = Directory(dest);
  if (dir.existsSync()) {
    dir.deleteSync(recursive: true);
  }

  final samples = <double>[];
  double? lastPercent;
  var monotonic = true;
  final sw = Stopwatch()..start();
  try {
    await extractZipStreaming(zip, dest, onProgress: (done, total) {
      if (total <= 0) {
        return;
      }
      final percent = done / total * 100;
      if (lastPercent != null && percent < lastPercent! - 0.001) {
        monotonic = false;
      }
      lastPercent = percent;
      if (samples.length < 200) {
        samples.add(percent);
      }
    });
  } catch (e) {
    sw.stop();
    stdout.writeln('FAILED after ${sw.elapsedMilliseconds}ms: $e');
    stdout.writeln('peakRss=${ProcessInfo.maxRss ~/ (1024 * 1024)}MB');
    exit(1);
  }
  sw.stop();

  var count = 0;
  var total = 0;
  for (final e in dir.listSync(recursive: true)) {
    if (e is File) {
      count++;
      total += e.lengthSync();
    }
  }
  stdout.writeln('OK files=$count bytes=$total '
      'time=${sw.elapsedMilliseconds}ms '
      'peakRss=${ProcessInfo.maxRss ~/ (1024 * 1024)}MB');
  stdout.writeln('progress samples=${samples.length} '
      'first=${samples.isEmpty ? "-" : samples.first.toStringAsFixed(1)}% '
      'last=${lastPercent == null ? "-" : lastPercent!.toStringAsFixed(1)}% '
      'monotonic=$monotonic');
  final preview = samples.take(6).map((e) => e.toStringAsFixed(0)).join(',');
  stdout.writeln('head: $preview');
  if (samples.isNotEmpty && samples.length < 200) {
    stdout.writeln('all: ${samples.map((e) => e.toStringAsFixed(0)).join(",")}');
  }
}
