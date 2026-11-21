library pica_settings;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/built_in/picacg.dart';
import 'package:pica_comic/comic_source/built_in/jm.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/ui_mode.dart';
import 'package:pica_comic/main.dart';
import 'package:pica_comic/network/app_dio.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/pages/logs_page.dart';
import 'package:pica_comic/tools/extensions.dart';
import 'package:pica_comic/tools/io_tools.dart';
import 'package:url_launcher/url_launcher_string.dart';
import '../../comic_source/comic_source.dart';
import '../../foundation/app.dart';
import '../../foundation/local_favorites.dart';
import '../../network/cookie_jar.dart';
import '../../network/download.dart';
import '../../network/eh_network/eh_main_network.dart';
import '../../network/http_client.dart';
import '../../network/http_proxy.dart';
import '../../network/jm_network/jm_network.dart';
import '../../network/nhentai_network/nhentai_main_network.dart';
import '../../network/update.dart';
import '../../network/webdav.dart';
import '../../tools/background_service.dart';
import '../../tools/debug.dart';
import '../welcome_page.dart';
import 'package:pica_comic/tools/translations.dart';

part "reading_settings.dart";
part "picacg_settings.dart";
part "network_setting.dart";
part "multi_pages_filter.dart";
part "local_favorite_settings.dart";
part "jm_settings.dart";
part "hi_settings.dart";
part "ht_settings.dart";
part "explore_settings.dart";
part "eh_settings.dart";
part "nh_settings.dart";
part "comic_source_settings.dart";
part "blocking_keyword_page.dart";
part "app_settings.dart";
part 'components.dart';

class SettingsPage extends StatefulWidget {
  static void open([int initialPage = -1]) {
    App.globalTo(() => SettingsPage(initialPage: initialPage));
  }

  const SettingsPage({this.initialPage = -1, super.key});

  final int initialPage;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> implements PopEntry{
  int currentPage = -1;

  ColorScheme get colors => Theme.of(context).colorScheme;

  bool get enableTwoViews => !UiMode.m1(context);

  final categories = <String>["浏览", "漫画源", "阅读", "外观", "本地收藏", "APP", "网络", "关于"];

  final icons = <IconData>[
    Icons.explore,
    Icons.source,
    Icons.book,
    Icons.color_lens,
    Icons.collections_bookmark_rounded,
    Icons.apps,
    Icons.public,
    Icons.info
  ];

  double offset = 0;

  late final HorizontalDragGestureRecognizer gestureRecognizer;

  ModalRoute? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ModalRoute<dynamic>? nextRoute = ModalRoute.of(context);
    if (nextRoute != _route) {
      _route?.unregisterPopEntry(this);
      _route = nextRoute;
      _route?.registerPopEntry(this);
    }
  }

  @override
  void initState() {
    currentPage = widget.initialPage;
    gestureRecognizer = HorizontalDragGestureRecognizer(debugOwner: this)
      ..onUpdate = ((details) => setState(() => offset += details.delta.dx))
      ..onEnd = (details) async {
        if (details.velocity.pixelsPerSecond.dx.abs() > 1 &&
            details.velocity.pixelsPerSecond.dx >= 0) {
          setState(() {
            Future.delayed(const Duration(milliseconds: 300), () => offset = 0);
            currentPage = -1;
          });
        } else if (offset > MediaQuery.of(context).size.width / 2) {
          setState(() {
            Future.delayed(const Duration(milliseconds: 300), () => offset = 0);
            currentPage = -1;
          });
        } else {
          int i = 10;
          while (offset != 0) {
            setState(() {
              offset -= i;
              i *= 10;
              if (offset < 0) {
                offset = 0;
              }
            });
            await Future.delayed(const Duration(milliseconds: 10));
          }
        }
      }
      ..onCancel = () async {
        int i = 10;
        while (offset != 0) {
          setState(() {
            offset -= i;
            i *= 10;
            if (offset < 0) {
              offset = 0;
            }
          });
          await Future.delayed(const Duration(milliseconds: 10));
        }
      };
    super.initState();
  }

  @override
  dispose() {
    super.dispose();
    gestureRecognizer.dispose();
    App.temporaryDisablePopGesture = false;
    _route?.unregisterPopEntry(this);
  }

  @override
  Widget build(BuildContext context) {
    if (currentPage != -1 && !enableTwoViews) {
      canPop.value = false;
      App.temporaryDisablePopGesture = true;
    } else {
      canPop.value = true;
      App.temporaryDisablePopGesture = false;
    }
    return Material(
      child: buildBody(),
    );
  }

  Widget buildBody() {
    if (enableTwoViews) {
      return Row(
        children: [
          SizedBox(
            width: 320,
            height: double.infinity,
            child: buildLeft(),
          ),
          Container(
            height: double.infinity,
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: context.colorScheme.outlineVariant,
                  width: 0.6,
                ),
              ),
            ),
          ),
          Expanded(child: buildRight())
        ],
      );
    } else {
      return Stack(
        children: [
          Positioned.fill(child: buildLeft()),
          Positioned(
            left: offset,
            width: MediaQuery.of(context).size.width,
            height: MediaQuery.of(context).size.height,
            child: Listener(
              onPointerDown: handlePointerDown,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                reverseDuration: const Duration(milliseconds: 300),
                switchInCurve: Curves.fastOutSlowIn,
                switchOutCurve: Curves.fastOutSlowIn,
                transitionBuilder: (child, animation) {
                  var tween = Tween<Offset>(
                      begin: const Offset(1, 0), end: const Offset(0, 0));

                  return SlideTransition(
                    position: tween.animate(animation),
                    child: child,
                  );
                },
                child: currentPage == -1
                    ? const SizedBox(
                        key: Key("1"),
                      )
                    : buildRight(),
              ),
            ),
          )
        ],
      );
    }
  }

  void handlePointerDown(PointerDownEvent event) {
    if (event.position.dx < 20) {
      gestureRecognizer.addPointer(event);
    }
  }

  Widget buildLeft() {
    return Material(
      child: Column(
        children: [
          SizedBox(
            height: MediaQuery.of(context).padding.top,
          ),
          SizedBox(
            height: 56,
            child: Row(children: [
              const SizedBox(
                width: 8,
              ),
              Tooltip(
                message: "Back",
                child: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => App.globalBack(),
                ),
              ),
              const SizedBox(
                width: 24,
              ),
              Text(
                "设置".tl,
                style: Theme.of(context).textTheme.headlineSmall,
              )
            ]),
          ),
          const SizedBox(
            height: 4,
          ),
          Expanded(
            child: buildCategories(),
          )
        ],
      ),
    );
  }

  Widget buildCategories() {
    Widget buildItem(String name, int id) {
      final bool selected = id == currentPage;

      Widget content = AnimatedContainer(
        key: ValueKey(id),
        duration: const Duration(milliseconds: 300),
        width: double.infinity,
        height: 48,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        decoration: BoxDecoration(
            color: selected ? colors.primaryContainer : null,
            borderRadius: BorderRadius.circular(16)
        ),
        child: Row(children: [
          Icon(icons[id]),
          const SizedBox(
            width: 16,
          ),
          Text(
            name,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const Spacer(),
          if (selected) const Icon(Icons.arrow_right)
        ]),
      );

      return Padding(
        padding: enableTwoViews
            ? const EdgeInsets.fromLTRB(16, 0, 16, 0)
            : EdgeInsets.zero,
        child: InkWell(
          onTap: () => setState(() => currentPage = id),
          borderRadius: BorderRadius.circular(16),
          child: content,
        ).paddingVertical(4),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: categories.length,
      itemBuilder: (context, index) => buildItem(categories[index].tl, index),
    );
  }

  Widget buildReadingSettings() {
    return const Placeholder();
  }

  /// 打开自定义 Material 取色器；选完颜色后立即应用到全局主题
  Future<void> showCustomColorPicker() async {
    final stored = int.tryParse(appdata.settings[90]) ?? 0;
    final initial = stored != 0
        ? HSVColor.fromColor(Color(stored))
        : HSVColor.fromColor(Theme.of(context).colorScheme.primary);
    final result = await showDialog<_CustomColorResult>(
      context: context,
      builder: (context) => _CustomColorDialog(initial: initial),
    );
    if (result == null) {
      return;
    }
    if (result.reset) {
      // 重置：清掉自定义色，恢复跟随系统的动态取色
      appdata.settings[90] = "0";
      appdata.settings[27] = "0";
    } else if (result.color != null) {
      appdata.settings[90] = result.color!.toARGB32().toString();
      appdata.settings[27] = customThemeColorIndex.toString();
    } else {
      return;
    }
    appdata.updateSettings();
    MyApp.updater?.call();
    setState(() {});
  }

  Widget buildAppearanceSettings() => Column(
        children: [
          ListTile(
            leading: const Icon(Icons.color_lens),
            title: Text("主题选择".tl),
            trailing: Select(
              key: ValueKey("themeColor-${appdata.settings[27]}"),
              initialValue: int.parse(appdata.settings[27]),
              values: [
                "dynamic",
                "red",
                "pink",
                "purple",
                "indigo",
                "blue",
                "cyan",
                "teal",
                "green",
                "lime",
                "yellow",
                "amber",
                "orange",
                "自定义".tl,
              ],
              onChange: (i) {
                if (i == customThemeColorIndex) {
                  // 选「自定义」时直接打开取色器
                  showCustomColorPicker();
                  return;
                }
                appdata.settings[27] = i.toString();
                appdata.updateSettings();
                MyApp.updater?.call();
              },
              width: 140,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: Text("自定义 Material 取色".tl),
            subtitle: Text(
              int.parse(appdata.settings[27]) == customThemeColorIndex
                  ? "#${(int.tryParse(appdata.settings[90]) ?? 0).toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}"
                  : "用自定义颜色生成整套 Material 3 配色".tl,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: Color(int.tryParse(appdata.settings[90]) ?? 0) ==
                            const Color(0)
                        ? Theme.of(context).colorScheme.primary
                        : Color(int.parse(appdata.settings[90])),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.arrow_forward_ios, size: 16),
              ],
            ),
            onTap: showCustomColorPicker,
          ),
          ListTile(
            leading: const Icon(Icons.dark_mode),
            title: Text("深色模式".tl),
            trailing: Select(
              initialValue: int.parse(appdata.settings[32]),
              values: ["跟随系统".tl, "禁用".tl, "启用".tl],
              onChange: (i) {
                appdata.settings[32] = i.toString();
                appdata.updateSettings();
                MyApp.updater?.call();
              },
              width: 140,
            ),
          ),
          if (appdata.settings[32] == "0" || appdata.settings[32] == "2")
            ListTile(
              leading: const Icon(Icons.remove_red_eye),
              title: Text("纯黑色模式".tl),
              trailing: Switch(
                value: appdata.settings[84] == "1",
                onChanged: (i) {
                  setState(() {
                    appdata.settings[84] = i ? "1" : "0";
                  });
                  appdata.updateSettings();
                  MyApp.updater?.call();
                },
              ),
            ),
          if (App.isAndroid)
            ListTile(
              leading: const Icon(Icons.smart_screen_outlined),
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("高刷新率模式".tl),
                  const SizedBox(
                    width: 2,
                  ),
                  InkWell(
                    borderRadius: const BorderRadius.all(Radius.circular(18)),
                    onTap: () => showDialogMessage(
                        context,
                        "高刷新率模式".tl,
                        "${"尝试强制设置高刷新率".tl}\n${"可能不起作用".tl}"),
                    child: const Icon(
                      Icons.info_outline,
                      size: 18,
                    ),
                  )
                ],
              ),
              trailing: Switch(
                value: appdata.settings[38] == "1",
                onChanged: (b) {
                  setState(() {
                    appdata.settings[38] = b ? "1" : "0";
                  });
                  appdata.updateSettings();
                  if (b) {
                    try {
                      FlutterDisplayMode.setHighRefreshRate();
                    } catch (e) {
                      // ignore
                    }
                  } else {
                    try {
                      FlutterDisplayMode.setLowRefreshRate();
                    } catch (e) {
                      // ignore
                    }
                  }
                },
              ),
            )
        ],
      );

  Widget buildAppSettings() {
    return Column(
      children: [
        ListTile(
          title: Text("日志".tl),
        ),
        ListTile(
          leading: const Icon(Icons.bug_report),
          title: const Text("Logs"),
          trailing: const Icon(Icons.arrow_right),
          onTap: () => context.to(() => const LogsPage()),
        ),
        ListTile(
          title: Text("更新".tl),
        ),
        ListTile(
          leading: const Icon(Icons.update),
          title: Text("检查更新".tl),
          subtitle: Text("${"当前:".tl} $appVersion"),
          onTap: () {
            findUpdate(context);
          },
        ),
        SwitchSetting(
          title: "启动时检查更新".tl,
          settingsIndex: 2,
          icon: const Icon(Icons.security_update),
        ),
        ListTile(
          title: Text("数据".tl),
        ),
        if (App.isDesktop || App.isAndroid)
          ListTile(
            leading: const Icon(Icons.folder),
            title: Text("设置下载目录".tl),
            trailing: const Icon(Icons.arrow_right),
            onTap: () => setDownloadFolder(),
          ),
        ListTile(
          leading: const Icon(Icons.sd_storage_outlined),
          title: Text("缓存大小限制".tl),
          subtitle: Text('${bytesLengthToReadableSize(CacheManager().currentSize)}'
                         ' / '
                         '${bytesLengthToReadableSize(CacheManager().limitSize)}'),
          onTap: setCacheLimit,
          trailing: const Icon(Icons.arrow_right),
        ),
        // ListTile(
        //   leading: const Icon(Icons.sd_storage_outlined),
        //   title: Text("设置缓存限制".tl),
        //   onTap: setCacheLimit,
        //   trailing: const Icon(Icons.arrow_right),
        // ),
        ListTile(
          leading: const Icon(Icons.delete_outline),
          title: Text("清除缓存".tl),
          onTap: () {
            CacheManager().clear().then((value) {
              if(mounted) {
                setState(() {});
              }
            });
          },
        ),
        ListTile(
          leading: const Icon(Icons.delete_forever),
          title: Text("删除所有数据".tl),
          trailing: const Icon(Icons.arrow_right),
          onTap: () => clearUserData(context),
        ),
        ListTile(
          leading: const Icon(Icons.sim_card_download),
          title: Text("导出用户数据".tl),
          trailing: const Icon(Icons.arrow_right),
          onTap: () => exportDataSetting(context),
        ),
        ListTile(
          leading: const Icon(Icons.data_object),
          title: Text("导入用户数据".tl),
          trailing: const Icon(Icons.arrow_right),
          onTap: () => importDataSetting(context),
        ),
        ListTile(
          leading: const Icon(Icons.sync),
          title: Text("数据同步".tl),
          trailing: const Icon(Icons.arrow_right),
          onTap: () => syncDataSettings(context),
        ),
        ListTile(
          title: Text("隐私".tl),
        ),
        if (App.isAndroid)
          ListTile(
            leading: const Icon(Icons.screenshot),
            title: Text("阻止屏幕截图".tl),
            subtitle: Text("需要重启App以应用更改".tl),
            trailing: Switch(
              value: appdata.settings[12] == "1",
              onChanged: (b) {
                b ? appdata.settings[12] = "1" : appdata.settings[12] = "0";
                setState(() {});
                appdata.writeData();
              },
            ),
          ),
        SwitchSetting(
          title: "需要身份验证".tl,
          subTitle: "如果系统中未设置任何认证方法请勿开启".tl,
          settingsIndex: 13,
          icon: const Icon(Icons.security),
        ),
        ListTile(
          title: Text("其它".tl),
        ),
        ListTile(
          title: Text("语言".tl),
          leading: const Icon(Icons.language),
          trailing: Select(
            initialValue: ["", "cn", "tw", "en"].indexOf(appdata.settings[50]),
            values: const ["System", "中文(简体)", "中文(繁體)", "English"],
            onChange: (value) {
              appdata.settings[50] = ["", "cn", "tw", "en"][value];
              appdata.updateSettings();
              MyApp.updater?.call();
            },
          ),
        ),
        ListTile(
          title: Text("下载并行".tl),
          leading: const Icon(Icons.download),
          trailing: Select(
            initialValue: ["1", "2", "4", "6", "8", "16"].indexOf(appdata.settings[79]),
            values: const ["1", "2", "4", "6", "8", "16"],
            onChange: (value) {
              appdata.settings[79] = ["1", "2", "4", "6", "8", "16"][value];
              appdata.updateSettings();
            },
          ),
        ),
        if(App.isAndroid)
          ListTile(
            title: Text("应用链接".tl),
            subtitle: Text("在系统设置中管理APP支持的链接".tl),
            leading: const Icon(Icons.link),
            trailing: const Icon(Icons.arrow_right),
            onTap: (){
              const MethodChannel("pica_comic/settings").invokeMethod("link");
            },
          ),
        if(kDebugMode)
          const ListTile(
            title: Text("Debug"),
            onTap: debug,
          ),
        Padding(padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom))
      ],
    );
  }

  Widget buildAbout() {
    return Column(
      children: [
        SizedBox(
          height: 130,
          width: double.infinity,
          child: Center(
            child: Container(
              width: 156,
              height: 156,
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20)),
              child: const Image(
                image: AssetImage("images/app_icon_no_bg.png"),
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
        ),
        const Text(
          "V$appVersion",
          style: TextStyle(fontSize: 16),
        ),
        Text("Pica Comic是一个完全免费的漫画阅读APP".tl),
        Text("仅用于学习交流".tl),
        const SizedBox(
          height: 16,
        ),
        ListTile(
          leading: const Icon(Icons.code),
          title: Text("项目地址".tl),
          onTap: () => launchUrlString("https://github.com/Pacalini/PicaComic",
              mode: LaunchMode.externalApplication),
          trailing: const Icon(Icons.open_in_new),
        ),
        ListTile(
          leading: const Icon(Icons.comment_outlined),
          title: Text("问题反馈 (Github)".tl),
          onTap: () => launchUrlString(
              "https://github.com/Pacalini/PicaComic/issues",
              mode: LaunchMode.externalApplication),
          trailing: const Icon(Icons.open_in_new),
        ),
        // ListTile(
        //   leading: const Icon(Icons.email),
        //   title: Text("EMAIL_ME_PLACEHOLDER".tl),
        //   onTap: () => launchUrlString("mailto://example@foo.bar",
        //       mode: LaunchMode.externalApplication),
        //   trailing: const Icon(Icons.arrow_right),
        // ),
        // ListTile(
        //   leading: const Icon(Icons.telegram),
        //   title: Text("JOIN_GROUP_PLACEHOLDER".tl),
        //   onTap: () => launchUrlString("https://t.me/example",
        //       mode: LaunchMode.externalApplication),
        //   trailing: const Icon(Icons.arrow_right),
        // ),
        Padding(padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom))
      ],
    );
  }

  Widget buildRight() {
    final Widget body = switch (currentPage) {
      -1 => const SizedBox(),
      0 => buildExploreSettings(context, false),
      1 => const ComicSourceSettings(),
      2 => const ReadingSettings(false),
      3 => buildAppearanceSettings(),
      4 => const LocalFavoritesSettings(),
      5 => buildAppSettings(),
      6 => const NetworkSettings(),
      7 => buildAbout(),
      _ => throw UnimplementedError()
    };

    if (currentPage != -1) {
      return Material(
        child: CustomScrollView(
          primary: false,
          slivers: [
            SliverAppBar(
                title: Text(categories[currentPage].tl),
                automaticallyImplyLeading: false,
                scrolledUnderElevation: enableTwoViews ? 0 : null,
                leading: enableTwoViews
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => setState(() => currentPage = -1),
                      )),
            SliverToBoxAdapter(
              child: body,
            )
          ],
        ),
      );
    }

    return body;
  }

  var canPop = ValueNotifier(true);

  @override
  ValueListenable<bool> get canPopNotifier => canPop;

  @override
  void onPopInvokedWithResult(bool didPop, result) {
    if (currentPage != -1) {
      setState(() {
        currentPage = -1;
      });
    }
  }

  @override
  void onPopInvoked(bool didPop) {
    if (currentPage != -1) {
      setState(() {
        currentPage = -1;
      });
    }
  }
}

/// 自定义 Material 取色的颜色选择对话框：
/// HSV 三滑杆 + 预览 + 十六进制 + 预设色块 + 从图片取色 + 重置
class _CustomColorDialog extends StatefulWidget {
  const _CustomColorDialog({required this.initial});

  final HSVColor initial;

  @override
  State<_CustomColorDialog> createState() => _CustomColorDialogState();
}

/// 取色对话框的结果：reset=true 表示重置；否则用 color
class _CustomColorResult {
  const _CustomColorResult(this.color, {this.reset = false});

  final Color? color;
  final bool reset;
}

class _CustomColorDialogState extends State<_CustomColorDialog> {
  late HSVColor _hsv = widget.initial;
  bool _pickingImage = false;

  /// 预设色块
  static const _presets = <Color>[
    Color(0xFFE53935),
    Color(0xFFD81B60),
    Color(0xFF8E24AA),
    Color(0xFF5E35B1),
    Color(0xFF3949AB),
    Color(0xFF1E88E5),
    Color(0xFF00ACC1),
    Color(0xFF00897B),
    Color(0xFF43A047),
    Color(0xFF7CB342),
    Color(0xFFFDD835),
    Color(0xFFFB8C00),
    Color(0xFF6D4C41),
    Color(0xFF546E7A),
  ];

  Future<void> _pickFromImage() async {
    if (_pickingImage) {
      return;
    }
    setState(() => _pickingImage = true);
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'image',
            extensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp'],
          ),
        ],
      );
      if (file == null) {
        return;
      }
      final bytes = await file.readAsBytes();
      final color = await compute(_dominantColorOfImage, bytes);
      if (!mounted || color == null) {
        return;
      }
      setState(() => _hsv = HSVColor.fromColor(color));
    } catch (_) {
      if (mounted) {
        showToast(message: "取色失败，换张图片试试".tl);
      }
    } finally {
      if (mounted) {
        setState(() => _pickingImage = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _hsv.toColor();
    final hex = color
        .toARGB32()
        .toRadixString(16)
        .padLeft(8, "0")
        .substring(2)
        .toUpperCase();
    return AlertDialog(
      title: Text("自定义 Material 取色".tl),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 64,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  "#$hex",
                  style: const TextStyle(
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              _slider(
                label: "色相".tl,
                value: _hsv.hue,
                max: 360,
                onChanged: (v) => setState(() => _hsv = _hsv.withHue(v)),
              ),
              _slider(
                label: "饱和度".tl,
                value: _hsv.saturation,
                max: 1,
                onChanged: (v) =>
                    setState(() => _hsv = _hsv.withSaturation(v)),
              ),
              _slider(
                label: "亮度".tl,
                value: _hsv.value,
                max: 1,
                onChanged: (v) => setState(() => _hsv = _hsv.withValue(v)),
              ),
              const SizedBox(height: 8),
              Text(
                "预设色块".tl,
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final c in _presets)
                    InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () => setState(() => _hsv = HSVColor.fromColor(c)),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _hsv.toColor().toARGB32() == c.toARGB32()
                                ? Theme.of(context).colorScheme.onSurface
                                : Theme.of(context)
                                    .colorScheme
                                    .outlineVariant,
                            width: _hsv.toColor().toARGB32() == c.toARGB32()
                                ? 2
                                : 1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _pickingImage ? null : _pickFromImage,
                    icon: _pickingImage
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.image_outlined, size: 18),
                    label: Text("从图片取色".tl),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.pop(
                      context,
                      const _CustomColorResult(null, reset: true),
                    ),
                    icon: const Icon(Icons.restart_alt, size: 18),
                    label: Text("重置".tl),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text("取消".tl),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, _CustomColorResult(color)),
          child: Text("确定".tl),
        ),
      ],
    );
  }

  Widget _slider({
    required String label,
    required double value,
    required double max,
    required void Function(double) onChanged,
  }) {
    return Row(
      children: [
        SizedBox(width: 56, child: Text(label)),
        Expanded(
          child: Slider(
            value: value,
            max: max,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

/// 取图片的主色（在后台 isolate 里跑）：
/// 缩到 48x48，跳过灰/黑/白，用「饱和度加权 + 色相向量平均」得到主色相，
/// 再固定成一套适合做 Material 种子的颜色。
Color? _dominantColorOfImage(Uint8List bytes) {
  try {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return null;
    }
    final small = img.copyResize(decoded, width: 48, height: 48);
    double sumX = 0;
    double sumY = 0;
    double weight = 0;
    for (final p in small) {
      final r = p.r.toDouble() / 255.0;
      final g = p.g.toDouble() / 255.0;
      final b = p.b.toDouble() / 255.0;
      final hsv = HSVColor.fromColor(Color.fromARGB(255, (r * 255).round(),
          (g * 255).round(), (b * 255).round()));
      // 跳过接近灰/黑/白的像素
      if (hsv.saturation < 0.18 || hsv.value < 0.15 || hsv.value > 0.98) {
        continue;
      }
      final rad = hsv.hue * math.pi / 180.0;
      final w = hsv.saturation;
      sumX += math.cos(rad) * w;
      sumY += math.sin(rad) * w;
      weight += w;
    }
    if (weight <= 0) {
      return null;
    }
    var hue = math.atan2(sumY, sumX) * 180.0 / math.pi;
    if (hue < 0) {
      hue += 360;
    }
    return HSVColor.fromAHSV(1, hue, 0.55, 0.78).toColor();
  } catch (_) {
    return null;
  }
}
