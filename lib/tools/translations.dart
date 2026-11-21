import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/log.dart';

extension AppTranslation on String {
  String _translate() {
    var locale = App.locale;
    var key = "${locale.languageCode}_${locale.countryCode}";
    if (locale.languageCode == "en") {
      key = "en_US";
    }
    return (translations[key]?[this]) ?? this;
  }

  String get tl => _translate();

  String get tlEN => translations["en_US"]?[this] ?? this;

  String tlParams(Map<String, String> values) {
    var res = _translate();
    for (var entry in values.entries) {
      res = res.replaceFirst("@${entry.key}", entry.value);
    }
    return res;
  }

  /// 默认空表：即使翻译资源加载失败，也不会让整个 UI 抛
  /// LateInitializationError（之前首屏直接白屏/报错就是这个原因）。
  static Map<String, Map<String, String>> translations = {};

  static Future<void> init() async {
    try {
      var data = await rootBundle.load("assets/translation.json");
      // ByteData 可能是更大 buffer 的切片，必须按 offset/length 取，
      // 否则解码出来的是脏数据，jsonDecode 会直接抛异常
      var bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      var json = jsonDecode(utf8.decode(bytes));
      translations = {
        for (var e in json.entries) e.key: Map<String, String>.from(e.value)
      };
    } catch (e, s) {
      LogManager.addLog(
          LogLevel.error, "Translation", "failed to load translations: $e\n$s");
    }
  }
}

extension ListTranslation on List<String> {
  List<String> _translate() {
    return List.generate(length, (index) => this[index].tl);
  }

  List<String> get tl => _translate();
}
