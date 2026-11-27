import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pica_comic/foundation/app.dart';

/// App 普通页面用的系统栏样式：状态栏/导航栏透明，图标跟随主题深浅反色。
SystemUiOverlayStyle appOverlayStyle([BuildContext? context]) {
  final ctx = context ?? App.globalContext;
  final dark = ctx != null
      ? Theme.of(ctx).brightness == Brightness.dark
      : WidgetsBinding.instance.platformDispatcher.platformBrightness ==
          Brightness.dark;
  return (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
      .copyWith(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
    statusBarBrightness: dark ? Brightness.dark : Brightness.light,
    systemNavigationBarIconBrightness:
        dark ? Brightness.light : Brightness.dark,
  );
}

/// 退出沉浸页面（阅读器/看图页）后恢复正常系统栏，并重新下发一次样式。
///
/// `setEnabledSystemUIMode` 会清掉状态栏的深浅色外观标记，图标会被重置成
/// 默认的白色。之后如果不重新下发样式，浅色主题下主界面就会留下白色图标，
/// 看起来就是"状态栏没跟着主题切换"。
Future<void> restoreSystemBars([BuildContext? context]) async {
  // 先算好样式再切模式：await 之后 context 可能已经失效
  final style = appOverlayStyle(context);
  await SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.manual,
    overlays: SystemUiOverlay.values,
  );
  SystemChrome.setSystemUIOverlayStyle(style);
}
