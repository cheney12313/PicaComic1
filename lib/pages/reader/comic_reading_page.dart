library pica_reader;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/components/custom_slider.dart';
import 'package:pica_comic/components/scrollable_list/src/item_positions_listener.dart';
import 'package:pica_comic/components/scrollable_list/src/scrollable_positioned_list.dart';
import 'package:pica_comic/components/window_frame.dart';
import 'package:pica_comic/foundation/image_loader/base_image_provider.dart';
import 'package:pica_comic/foundation/image_loader/file_image_loader.dart';
import 'package:pica_comic/foundation/image_loader/stream_image_provider.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/foundation/page_translation/batch_translation.dart';
import 'package:pica_comic/foundation/page_translation/page_translation_service.dart';
import 'package:pica_comic/foundation/page_translation/translation_settings.dart';
import 'package:pica_comic/pages/settings/translation_settings_page.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/network/eh_network/eh_models.dart';
import 'package:pica_comic/network/eh_network/get_gallery_id.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/network/htmanga_network/htmanga_main_network.dart';
import 'package:pica_comic/network/jm_network/jm_models.dart';
import 'package:pica_comic/network/nhentai_network/nhentai_main_network.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/comic_page.dart';
import 'package:pica_comic/tools/keep_screen_on.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/tools/save_image.dart';
import 'package:pica_comic/tools/system_ui.dart';
import 'package:pica_comic/tools/time.dart';
import 'package:pica_comic/network/jm_network/jm_network.dart';
import '../../foundation/app.dart';
import '../../foundation/ui_mode.dart';
import '../../network/hitomi_network/hitomi_models.dart';
import '../../tools/key_down_event.dart';
import 'package:pica_comic/network/picacg_network/methods.dart';
import 'package:pica_comic/tools/translations.dart';

import '../jm/jm_comments_page.dart';


part 'eps_view.dart';
part 'image_view.dart';
part 'image.dart';
part 'touch_control.dart';
part 'reading_logic.dart';
part 'tool_bar.dart';
part 'reading_type.dart';
part 'reading_settings.dart';

part 'reading_data.dart';

/// 阅读器工具栏 / 状态栏的底色。
///
/// 就是当前主题的 surface：工具栏保持和 App 其它页面一致的样子，
/// 不因为"使用深色背景"而单独变黑——深色背景只管正文区域。
Color readerChromeColor([BuildContext? context]) {
  final ctx = context ?? App.globalContext;
  if (ctx != null) {
    return Theme.of(ctx).colorScheme.surface;
  }
  final dark = WidgetsBinding.instance.platformDispatcher.platformBrightness ==
      Brightness.dark;
  return dark ? const Color(0xFF1C1C1E) : const Color(0xFFF7F9FF);
}

/// 底色深不深（决定状态栏图标反成白色还是黑色）。
///
/// 不看"使用深色背景"：那个只影响正文，状态栏压在工具栏上，
/// 图标颜色必须跟工具栏底色走，否则浅色工具栏上会出现看不见的白图标。
bool chromeIsDark([BuildContext? context]) =>
    readerChromeColor(context).computeLuminance() < 0.5;

/// 按工具栏底色深浅生成系统栏样式（状态栏图标反色）。
///
/// [chrome] 是状态栏底色：大部分 ROM 在 edge-to-edge 下会忽略它，
/// 但只要有一层系统状态栏被画出来，它就得和工具栏同色，不能留成透明。
SystemUiOverlayStyle readerOverlayStyle(bool dark, [Color? chrome]) {
  final color = chrome ?? Colors.transparent;
  return (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
      .copyWith(
    statusBarColor: color,
    systemNavigationBarColor: color,
    statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
    statusBarBrightness: dark ? Brightness.dark : Brightness.light,
    systemNavigationBarIconBrightness:
        dark ? Brightness.light : Brightness.dark,
  );
}

SystemUiOverlayStyle? _lastReaderOverlayStyle;

/// 应用阅读器系统栏样式（去重，避免每次 build 都调平台通道）。
///
/// [force] 用在刚切换过 SystemUiMode 的时候：`setEnabledSystemUIMode`
/// 会清掉状态栏的深浅色外观标记（图标被重置成白色），这时哪怕样式没变
/// 也必须重新下发一次，否则浅色主题下会一直是白色图标——深色模式下看不出来，
/// 一切到浅色就变成"状态栏不跟着主题走"。
void applyReaderOverlayStyle([BuildContext? context, bool force = false]) {
  final style = readerOverlayStyle(
    chromeIsDark(context),
    readerChromeColor(context),
  );
  if (!force && _lastReaderOverlayStyle == style) {
    return;
  }
  _lastReaderOverlayStyle = style;
  SystemChrome.setSystemUIOverlayStyle(style);
}

/// 显示系统状态栏（工具栏出现时调用）。
///
/// 用 manual + 只开 top：部分 ROM（MIUI/HyperOS）从 immersive 切回 edgeToEdge
/// 时不会自动恢复状态栏，manual 是明确的显式请求；底部导航栏保持隐藏，
/// 免得工具栏弹出时阅读区高度被二次挤压。
///
/// 切换模式会把状态栏图标外观重置成默认值，所以切换完要强制重发一次样式，
/// 让图标颜色和工具栏底色一起变。
Future<void> showReaderSystemBars() async {
  await SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.manual,
    overlays: const [SystemUiOverlay.top],
  );
  applyReaderOverlayStyle(null, true);
}

/// 隐藏系统栏（回到沉浸阅读）。
void hideReaderSystemBars() {
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
}






///阅读器
class ComicReadingPage extends StatelessWidget {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  final ReadingData readingData;

  late final History? history = HistoryManager().findSync(readingData.id);

  final int initialPage;

  final int initialEp;

  ReadingType get type => readingData.type;

  ComicReadingPage(this.readingData, this.initialPage, this.initialEp,
      {super.key}) {
    StateController.put(ComicReadingPageLogic(
        initialEp,
        readingData,
        initialPage,
        () => _updateHistory(
            StateController.find<ComicReadingPageLogic>(), false)));
  }

  ComicReadingPage.picacg(
      String target, this.initialEp, List<String> eps, String title,
      {super.key, this.initialPage = 1})
      : readingData = PicacgReadingData(title, target, eps) {
    StateController.put(ComicReadingPageLogic(
        initialEp,
        readingData,
        initialPage,
        () => _updateHistory(
            StateController.find<ComicReadingPageLogic>(), false)));
  }

  ComicReadingPage.ehentai(Gallery gallery, {super.key, this.initialPage = 1})
      : initialEp = 1,
        readingData = EhReadingData(gallery) {
    StateController.put(ComicReadingPageLogic(
        1,
        readingData,
        initialPage,
        () => _updateHistory(
            StateController.find<ComicReadingPageLogic>(), false)));
  }

  ComicReadingPage.jmComic(JmComicInfo comic, this.initialEp,
      {super.key, this.initialPage = 1})
      : readingData = JmReadingData(
          comic.name,
          comic.id,
          comic.series.values.toList(),
          comic.epNames,
        ) {
    StateController.put(ComicReadingPageLogic(
        initialEp,
        readingData,
        initialPage,
        () => _updateHistory(
            StateController.find<ComicReadingPageLogic>(), false)));
  }

  ComicReadingPage.hitomi(HitomiComic comic, String link,
      {super.key, this.initialPage = 1})
      : initialEp = 1,
        readingData = HitomiReadingData(
          comic.title,
          comic.target,
          comic.files,
          link,
        ) {
    StateController.put(ComicReadingPageLogic(
        initialEp,
        readingData,
        initialPage,
        () => _updateHistory(
            StateController.find<ComicReadingPageLogic>(), false)));
  }

  ComicReadingPage.htmanga(String target, String title,
      {super.key, this.initialPage = 1})
      : initialEp = 1,
        readingData = HtReadingData(title, target) {
    StateController.put(ComicReadingPageLogic(
        initialEp,
        readingData,
        initialPage,
        () => _updateHistory(
            StateController.find<ComicReadingPageLogic>(), false)));
  }

  ComicReadingPage.nhentai(String target, String title,
      {super.key, this.initialPage = 1})
      : initialEp = 1,
        readingData = NhentaiReadingData(title, target) {
    StateController.put(ComicReadingPageLogic(
        initialEp,
        readingData,
        initialPage,
        () => _updateHistory(
            StateController.find<ComicReadingPageLogic>(), false)));
  }

  _updateHistory(ComicReadingPageLogic? logic, bool updateMePage) {
    if (readingData.hasEp) {
      if (logic!.order == 1 && logic.index == 1) {
        history?.ep = 0;
        history?.page = 0;
      } else {
        if (logic.order == readingData.eps?.length &&
            logic.index == logic.length) {
          history?.ep = 0;
          history?.page = 0;
        } else {
          history?.ep = logic.order;
          history?.page = logic.index;
        }
      }
    } else {
      if (logic!.index == 1) {
        history?.ep = 0;
        history?.page = 0;
      } else {
        history?.ep = 1;
        history?.page = logic.index;
      }
    }
    history!.maxPage = logic.length;
    HistoryManager().saveReadHistory(history!, updateMePage);
  }

  bool get useDarkBackground => appdata.appSettings.useDarkBackground;

  @override
  Widget build(BuildContext context) {
    // 状态栏/导航栏图标跟随阅读器背景反色（沉浸模式下同样生效）
    applyReaderOverlayStyle(context);
    return StateBuilder<ComicReadingPageLogic>(initState: (logic) {
      // 进入阅读器先沉浸：系统状态栏隐藏，点屏幕弹出工具栏时再一起显示
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      applyReaderOverlayStyle(context);
      if (appdata.settings[14] == "1") {
        setKeepScreenOn();
      }
      if (appdata.settings[76] == "1") {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight
        ]);
      } else if (appdata.settings[76] == "2") {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown
        ]);
      }
      //进入阅读器时清除内存中的缓存, 并且增大限制
      BaseImageProvider.clearCache();
      BaseImageProvider.setCacheSizeLimit(100 * 1024 * 1024);
      logic.openEpsView = openEpsDrawer;
      logic.restartTranslation = () => translateChapter(logic);
      if (useDarkBackground) {
        Future.microtask(() =>
            StateController.findOrNull<WindowFrameController>()
                ?.setDarkTheme());
      }
    }, dispose: (logic) {
      // 退出阅读器后让主界面重新决定系统栏样式
      _lastReaderOverlayStyle = null;
      //清除缓存并减小最大缓存
      BaseImageProvider.clearCache();
      BaseImageProvider.setCacheSizeLimit(50 * 1024 * 1024);
      logic.clearPhotoViewControllers();
      logic.translationBatch?.cancel();
      // 退出阅读器：恢复正常系统栏并重新下发 App 的主题样式
      // （切 UI mode 会重置状态栏图标外观，否则主界面会留下白色图标）
      restoreSystemBars();
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      if (logic.listenVolume != null) {
        logic.listenVolume!.stop();
      }
      if (appdata.settings[14] == "1") {
        cancelKeepScreenOn();
      }
      logic.runningAutoPageTurning = false;
      ComicImage.clear();
      StateController.remove<ComicReadingPageLogic>();
      // 更新本地收藏
      LocalFavoritesManager().onReadEnd(readingData.favoriteId, readingData.favoriteType);
      // 保存历史记录
      if (history != null) {
        _updateHistory(logic, true);
      }
      // 退出全屏
      if (logic.isFullScreen) {
        logic.fullscreen();
      }
      if (!DownloadManager().isDownloading) {
        ImageManager.clearTasks();
      }
      // 更新漫画详情页面
      Future.microtask(() {
        if (BaseComicPage.tagsStack.isNotEmpty) {
          BaseComicPage.tagsStack.last.updateHistory(history);
        }
      });
      if (appdata.settings[76] != "0") {
        SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      }
      if (useDarkBackground) {
        Future.microtask(() =>
            StateController.findOrNull<WindowFrameController>()?.resetTheme());
      }
    }, builder: (logic) {
      return DefaultTextStyle.merge(
        style: TextStyle(
          color: useDarkBackground ? Colors.white : null,
          fontSize: 16,
        ),
        child: AnnotatedRegion<SystemUiOverlayStyle>(
          value: readerOverlayStyle(
            chromeIsDark(context),
            readerChromeColor(context),
          ),
          child: Scaffold(
          backgroundColor: useDarkBackground ? Colors.black : null,
          endDrawerEnableOpenDragGesture: false,
          key: _scaffoldKey,
          endDrawer: Drawer(
            child: buildEpsView(),
          ),
          floatingActionButton: buildEpChangeButton(logic),
          body: StateBuilder<ComicReadingPageLogic>(builder: (logic) {
            if (logic.isLoading) {
              history?.readEpisode.add(logic.order);
              loadInfo(logic);
              return const Center(
                child: CircularProgressIndicator(),
              );
            } else if (logic.urls.isNotEmpty) {
              if (logic.readingMethod ==
                      ReadingMethod.topToBottomContinuously &&
                  !logic.haveUsedInitialPage &&
                  initialPage != 0) {
                Future.microtask(() {
                  logic.jumpToPage(initialPage);
                  logic.haveUsedInitialPage = true;
                });
              }
              //监听音量键
              if (appdata.settings[7] == "1") {
                if (logic.listenVolume == null) {
                  logic.listenVolume = ListenVolumeController(
                      () => logic.jumpToLastPage(),
                      () => logic.jumpToNextPage());
                  logic.listenVolume!.listenVolumeChange();
                }
              } else if (logic.listenVolume != null) {
                logic.listenVolume!.stop();
                logic.listenVolume = null;
              }

              if (appdata.settings[9] == "4") {
                logic.scrollManager ??= ScrollManager(logic);
              }

              var body = Listener(
                onPointerMove: TapController.onPointerMove,
                onPointerUp: TapController.onTapUp,
                onPointerDown: TapController.onTapDown,
                behavior: HitTestBehavior.translucent,
                onPointerCancel: TapController.onTapCancel,
                child: Stack(
                  children: [
                    buildComicView(
                      logic,
                      context,
                      readingData.id,
                    ),
                    if (MediaQuery.of(context).platformBrightness ==
                            Brightness.dark &&
                        appdata.appSettings.reduceBrightnessInDarkMode)
                      Positioned(
                        top: 0,
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: IgnorePointer(
                          child: ColoredBox(
                            color: Colors.black.withOpacity(0.2),
                          ),
                        ),
                      ),

                    if (appdata.appSettings.showPageInfoInReader)
                      buildPageInfoText(logic, context),

                    //底部工具栏
                    buildBottomToolBar(logic, context, readingData.hasEp),

                    ...buildButtons(logic, context),

                    //顶部工具栏
                    buildTopToolBar(logic, context),
                  ],
                ),
              );

              return KeyboardListener(
                focusNode: logic.focusNode,
                autofocus: true,
                onKeyEvent: logic.handleKeyboard,
                child: body,
              );
            } else {
              return buildErrorView(logic, context);
            }
          }),),
        ),
      );
    });
  }

  Widget buildErrorView(ComicReadingPageLogic logic, BuildContext context) {
    return SafeArea(
        child: Stack(
      children: [
        Positioned(
          left: 8,
          top: 12,
          child: IconButton(
            icon: const Icon(
              Icons.arrow_back,
            ),
            onPressed: () => App.globalBack(),
          ),
        ),
        Positioned(
          top: MediaQuery.of(App.globalContext!).size.height / 2 - 80,
          left: 0,
          right: 0,
          child: const Align(
            alignment: Alignment.topCenter,
            child: Icon(
              Icons.error_outline,
              size: 60,
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: MediaQuery.of(App.globalContext!).size.height / 2 - 10,
          child: Align(
            alignment: Alignment.topCenter,
            child: Text(
              logic.errorMessage ?? "未知错误".tl,
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: MediaQuery.of(App.globalContext!).size.height / 2 + 30,
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 250,
              height: 40,
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        logic.change();
                      },
                      child: Text("重试".tl),
                    ),
                  ),
                  const SizedBox(
                    width: 8,
                  ),
                  Expanded(
                      child: FilledButton(
                    onPressed: () {
                      if (!readingData.hasEp) {
                        showToast(message: "没有其它章节".tl);
                        return;
                      }
                      if (MediaQuery.of(context).size.width > 600) {
                        showSideBar(
                          context,
                          buildEpsView(),
                          title: null,
                          useSurfaceTintColor: true,
                          addTopPadding: true,
                          width: 400,
                        );
                      } else {
                        showModalBottomSheet(
                          context: context,
                          useSafeArea: false,
                          builder: (context) {
                            return buildEpsView();
                          },
                        );
                      }
                    },
                    child: Text("切换章节".tl),
                  )),
                ],
              ),
            ),
          ),
        ),
      ],
    ));
  }

  void loadInfo(ComicReadingPageLogic logic) async {
    logic.urls = [];
    var res = await readingData.loadEp(logic.order);
    if (res.error) {
      logic.errorMessage = res.errorMessage;
    } else {
      logic.urls = res.data;
    }
    logic.isLoading = false;
    // 开着翻译时, 换章也要整章翻译
    translateChapter(logic);
    logic.update();
  }

  Widget buildEpsView() {
    return EpsView(readingData);
  }

  void openEpsDrawer() {
    var context = App.globalContext!;
    if (MediaQuery.of(context).size.width > 600) {
      showSideBar(
        context,
        buildEpsView(),
        title: null,
        useSurfaceTintColor: true,
        width: 400,
        addTopPadding: true,
      );
    } else {
      showModalBottomSheet(
        context: context,
        useSafeArea: false,
        builder: (context) {
          return buildEpsView();
        },
      );
    }
  }

  /// Used when [ComicReadingPageLogic.readingMethod] is [ReadingMethod.topToBottomContinuously].
  ///
  /// Select a image form screen, to share or download
  Future<int?> selectImage() async {
    var logic = StateController.find<ComicReadingPageLogic>();
    var items = logic.itemScrollListener.itemPositions.value.toList();
    if (items.length == 1) {
      return items[0].index;
    }
    int? res;
    await showDialog(
        context: App.globalContext!,
        builder: (context) {
          return SimpleDialog(
            title: Text("选择屏幕上的图片".tl),
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 400,
                ),
                child: Column(
                  children: [
                    for (var item in items)
                      ListTile(
                        title: Text((item.index + 1).toString()),
                        onTap: () {
                          res = item.index;
                          App.globalBack();
                        },
                        trailing: const Icon(Icons.arrow_right),
                      )
                  ],
                ),
              )
            ],
          );
        });
    return res;
  }

  String getImageKey(int index) {
    var logic = StateController.find<ComicReadingPageLogic>();
    if (type == ComicType.ehentai) {
      return "${readingData.id}${index + 1}";
    }
    return type == ReadingType.hitomi
        ? (readingData as HitomiReadingData).images[index].hash
        : logic.urls[index];
  }

  Future<File> _getFileFromStream(Stream<DownloadProgress> stream) async {
    await for (var event in stream) {
      if (event.finished) {
        return event.getFile();
      }
    }
    throw "failed";
  }

  /// 整本开启/关闭翻译. 开启后从当前页开始在后台依次翻译本章每一页,
  /// 之后翻到的章节也会继续翻译.
  void toggleTranslation(ComicReadingPageLogic logic) {
    if (logic.translateAll) {
      logic.translateAll = false;
      logic.translationBatch?.cancel();
      logic.translationBatch = null;
      logic.update();
      showToast(message: "已关闭翻译".tl);
      return;
    }
    var problem = PageTranslationService.instance.problem;
    if (problem != null) {
      showToast(message: translationProblemMessage(problem));
      if (problem != TranslationProblem.unsupported) {
        App.globalTo(() => const TranslationSettingsPage());
      }
      return;
    }
    logic.translateAll = true;
    translateChapter(logic);
    logic.update();
    if (logic.urls.isNotEmpty) {
      showToast(
          message: "${"正在翻译本章".tl}: ${logic.urls.length} ${"页".tl}");
    }
  }

  /// 在后台把本章每一页依次翻译完, 替换掉另一章的进度.
  void translateChapter(ComicReadingPageLogic logic) {
    logic.translationBatch?.cancel();
    logic.translationBatch = null;
    if (!logic.translateAll || logic.urls.isEmpty) return;
    var ep = logic.order;
    var urls = List.of(logic.urls);
    var service = PageTranslationService.instance;
    var batch = BatchTranslation(
      pages: BatchTranslation.orderFrom(urls.length, logic.index - 1),
      translatePage: (page) => service.translateInBackground(
          readingData.loadImage(ep, page, urls[page]),
          readingData.translationKey(ep, page)),
    );
    logic.translationBatch = batch;
    batch.run().then((_) {
      if (batch.isCancelled || logic.translationBatch != batch) return;
      if (batch.stopReason != null) {
        showToast(
            message: "${"翻译连续失败, 已停止".tl}: ${batch.stopReason}");
      } else if (batch.failed > 0) {
        showToast(
            message:
                "${"本章翻译完成".tl}, ${"失败".tl}: ${batch.failed} ${"页".tl}");
      } else {
        showToast(message: "本章翻译完成".tl);
      }
    });
  }

  /// 长按翻译按钮: 针对当前页的操作.
  void showTranslationMenu(ComicReadingPageLogic logic) {
    var service = PageTranslationService.instance;
    var index = logic.index - 1;
    var pageKey = index >= 0 && index < logic.urls.length
        ? readingData.translationKey(logic.order, index)
        : null;
    var status = pageKey == null ? null : service.statusOf(pageKey);
    showDialog<void>(
      context: App.globalContext!,
      builder: (context) => SimpleDialog(
        title: Text("翻译".tl),
        children: [
          if (status?.state == PageTranslationState.failed)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                "${"这一页翻译失败".tl}: ${status!.message ?? ""}",
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (status?.state == PageTranslationState.noText)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text("这一页没有需要翻译的文字".tl),
            ),
          if (logic.translationBatch case var batch?)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                "${"本章已翻译".tl}: ${batch.finished} / ${batch.total}"
                "${batch.failed > 0 ? ", ${"失败".tl}: ${batch.failed}" : ""}",
              ),
            ),
          if (logic.translateAll && pageKey != null)
            SimpleDialogOption(
              onPressed: () async {
                Navigator.of(context).pop();
                await service.forget(pageKey);
                // 丢掉内存里的副本, 让这一页重新加载
                BaseImageProvider.clearCache();
                PaintingBinding.instance.imageCache.clear();
                PaintingBinding.instance.imageCache.clearLiveImages();
                logic.update();
              },
              child: Text("重新翻译这一页".tl),
            ),
          SimpleDialogOption(
            onPressed: () {
              Navigator.of(context).pop();
              App.globalTo(() => const TranslationSettingsPage());
            },
            child: Text("翻译设置".tl),
          ),
        ],
      ),
    );
  }

  void share() async {
    var logic = StateController.find<ComicReadingPageLogic>();
    int? index = logic.index - 1;
    if (logic.readingMethod == ReadingMethod.topToBottomContinuously) {
      index = await selectImage();
    }
    if (index == null) {
      return;
    }

    var file = await _getFileFromStream(
        readingData.loadImage(logic.order, index, logic.urls[index]));

    shareImage(file);
  }

  Future<String?> _persistentCurrentImage() async {
    var logic = StateController.find<ComicReadingPageLogic>();
    int? index = logic.index - 1;
    if (logic.readingMethod == ReadingMethod.topToBottomContinuously) {
      index = await selectImage();
    }
    if (index == null) {
      return null;
    }

    var file = await _getFileFromStream(
        readingData.loadImage(logic.order, index, logic.urls[index]));

    return persistentCurrentImage(file);
  }

  void saveCurrentImage() async {
    var logic = StateController.find<ComicReadingPageLogic>();
    int? index = logic.index - 1;
    if (logic.readingMethod == ReadingMethod.topToBottomContinuously) {
      index = await selectImage();
    }
    if (index == null) {
      return;
    }

    var file = await _getFileFromStream(
        readingData.loadImage(logic.order, index, logic.urls[index]));

    saveImage(file);
  }

  Widget? buildEpChangeButton(ComicReadingPageLogic logic) {
    if (!readingData.hasEp) return null;
    switch (logic.showFloatingButtonValue) {
      case -1:
        return FloatingActionButton(
          onPressed: () => logic.jumpToLastChapter(),
          child: const Icon(Icons.arrow_back_ios_outlined),
        );
      case 0:
        return null;
      case 1:
        return Hero(
            tag: "FAB",
            child: StateBuilder<ComicReadingPageLogic>(
              id: "FAB",
              // 用 Builder 拿一个层级在本页内的 context：
              // 传 App.globalContext 时依赖注册在 Navigator 上，
              // 主题切换后这里的底色/图标色会停在旧配色。
              builder: (logic) => Builder(builder: (context) {
                return Container(
                  width: 58,
                  height: 58,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(16)),
                  child: Stack(
                    children: [
                      Positioned.fill(
                          child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () => logic.jumpToNextChapter(),
                          borderRadius: BorderRadius.circular(16),
                          child: Center(
                              child: Icon(
                            Icons.arrow_forward_ios,
                            size: 24,
                            color: Theme.of(context).colorScheme.onPrimaryContainer,
                          )),
                        ),
                      )),
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        height: logic.fABValue,
                        child: ColoredBox(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceTint
                              .withOpacity(0.2),
                          child: const SizedBox.expand(),
                        ),
                      )
                    ],
                  ),
                );
              }),
            ));
    }
    return null;
  }
}
