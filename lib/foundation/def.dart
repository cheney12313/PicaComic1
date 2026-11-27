import 'package:flutter/material.dart';

typedef ActionFunc = void Function();

enum ComicType {
  picacg,
  ehentai,
  jm,
  hitomi,
  htManga,
  htFavorite,
  nhentai,
  other;

  @override
  toString() => name;
}

const String webUA =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36";

//App版本
const appVersion = "4.3";

//定义宽屏设备的临界值
const changePoint = 600;
const changePoint2 = 1300;

/// 主题色设置里「自定义 Material 取色」的下标：
/// 0 = 跟随系统动态取色，1..12 = 预设色，13 = 自定义
const int customThemeColorIndex = 13;

List<MaterialAccentColor> get colors => [
  Colors.redAccent,
  Colors.pinkAccent,
  Colors.purpleAccent,
  Colors.indigoAccent,
  Colors.blueAccent,
  Colors.cyanAccent,
  Colors.tealAccent,
  Colors.greenAccent,
  Colors.limeAccent,
  Colors.yellowAccent,
  Colors.amberAccent,
  Colors.orangeAccent,
];

const builtInSources = [
  "picacg",
  "ehentai",
  "jm",
  "hitomi",
  "htmanga",
  "nhentai"
];