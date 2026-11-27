import 'package:flutter/material.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/network/base_comic.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/category_comics_page.dart';
import 'package:pica_comic/pages/search_result_page.dart';
import 'package:pica_comic/tools/extensions.dart';
import 'package:pica_comic/tools/translations.dart';

class ExplorePage extends StatefulWidget {
  const ExplorePage({super.key});

  @override
  State<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage>
    with TickerProviderStateMixin {
  late TabController controller;

  /// 上一次停留的标签页, 在设置里调整排序后页面会被重建,
  /// 用它来回到原来那一页, 而不是每次都跳回第一个标签
  static String? _lastPage;

  bool showFB = true;

  double location = 0;

  var pages = appdata.appSettings.explorePages;

  @override
  void initState() {
    // 兼容旧数据: picacg 探索页已拆分为 "PicACG随机" / "PicACG最新"
    appdata.migrateExplorePages();
    pages = appdata.appSettings.explorePages;
    var all = ComicSource.sources.map((e) => e.explorePages).expand((e) => e.map((e) => e.title)).toList();
    pages = pages.where((e) => all.contains(e)).toList();
    if(pages.isEmpty && appdata.appSettings.explorePages.isNotEmpty) {
      if(appdata.appSettings.explorePages.first.isNum) {
        // is odd data, update
        appdata.appSettings.explorePages = all;
        pages = all;
        appdata.updateSettings();
      }
    }
    var initialIndex = 0;
    if (_lastPage != null) {
      var index = pages.indexOf(_lastPage!);
      if (index > 0) {
        initialIndex = index;
      }
    }
    controller = TabController(
      length: pages.length,
      vsync: this,
      initialIndex: initialIndex,
    );
    controller.addListener(_rememberPage);
    super.initState();
  }

  void _rememberPage() {
    if (pages.isEmpty) return;
    var index = controller.index;
    if (index >= 0 && index < pages.length) {
      _lastPage = pages[index];
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void refresh() {
    if (pages.isEmpty) return;
    String currentPageId = pages[controller.index];
    // 漫画列表形式的页面(如 PicACG随机/最新)用的是 ComicsPageLogic,
    // 其余页面用 SimpleController, 这里两种都兼容
    var comicsController =
        StateController.findOrNull<ComicsPageLogic>(tag: currentPageId);
    if (comicsController != null) {
      comicsController.refresh();
      return;
    }
    StateController.findOrNull<SimpleController>(tag: currentPageId)?.refresh();
  }

  Widget buildFAB() => Material(
        color: Colors.transparent,
        child: FloatingActionButton(
          key: const Key("FAB"),
          onPressed: refresh,
          child: const Icon(Icons.refresh),
        ),
      );

  Tab buildTab(String i) {
    return Tab(text: i.tl, key: Key(i));
  }

  Widget buildBody(String i) => _SingleExplorePage(i, key: Key(i));

  @override
  Widget build(BuildContext context) {
    if (pages.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.explore_off_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text("还没有选择探索页面".tl),
            const SizedBox(height: 6),
            Text(
              "可在 设置 - 漫画源 - 发现页标签 中添加".tl,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ],
        ),
      );
    }

    Widget tabBar = Material(
      child: FilledTabBar(
        tabs: pages.map((e) => buildTab(e)).toList(),
        controller: controller,
      ),
    );

    return Stack(
      children: [
        Positioned.fill(
            child: Column(
          children: [
            tabBar,
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: (notifications) {
                  if (notifications.metrics.axis == Axis.horizontal) {
                    if (!showFB) {
                      setState(() {
                        showFB = true;
                      });
                    }
                    return true;
                  }

                  var current = notifications.metrics.pixels;

                  if ((current > location && current != 0) && showFB) {
                    setState(() {
                      showFB = false;
                    });
                  } else if ((current < location || current == 0) && !showFB) {
                    setState(() {
                      showFB = true;
                    });
                  }

                  location = current;
                  return false;
                },
                child: MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  child: TabBarView(
                    controller: controller,
                    children: pages
                        .map((e) => buildBody(e))
                        .toList(),
                  ),
                ),
              ),
            )
          ],
        )),
        Positioned(
          right: 16,
          bottom: 16,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            reverseDuration: const Duration(milliseconds: 150),
            child: showFB ? buildFAB() : const SizedBox(),
            transitionBuilder: (widget, animation) {
              var tween = Tween<Offset>(
                  begin: const Offset(0, 1), end: const Offset(0, 0));
              return SlideTransition(
                position: tween.animate(animation),
                child: widget,
              );
            },
          ),
        )
      ],
    );
  }
}

class _SingleExplorePage extends StatefulWidget {
  const _SingleExplorePage(this.title, {super.key});

  final String title;

  @override
  State<_SingleExplorePage> createState() => _SingleExplorePageState();
}

class _SingleExplorePageState extends StateWithController<_SingleExplorePage> {
  late final ExplorePageData data;

  bool loading = true;

  String? message;

  List<ExplorePagePart>? parts;

  late final String comicSourceKey;

  int key = 0;

  @override
  void initState() {
    super.initState();
    for (var source in ComicSource.sources) {
      for (var d in source.explorePages) {
        if (d.title == widget.title) {
          data = d;
          comicSourceKey = source.key;
          return;
        }
      }
    }
    throw "Explore Page ${widget.title} Not Found!";
  }

  @override
  Widget build(BuildContext context) {
    if (data.loadMultiPart != null) {
      return buildMultiPart();
    } else if (data.loadPage != null) {
      return buildComicList();
    } else if (data.loadMixed != null) {
      return _MixedExplorePage(
        data,
        comicSourceKey,
        key: ValueKey(key),
      );
    } else if (data.overridePageBuilder != null) {
      return Builder(
        builder: (context) {
          return data.overridePageBuilder!(context);
        },
        key: ValueKey(key),
      );
    } else {
      return const Center(
        child: Text("Empty Page"),
      );
    }
  }

  Widget buildComicList() =>
      _ComicList(data.loadPage!, tag.toString(), comicSourceKey);

  void load() async {
    var res = await data.loadMultiPart!();
    loading = false;
    if (mounted) {
      setState(() {
        if (res.error) {
          message = res.errorMessageWithoutNull;
        } else {
          parts = res.data;
        }
      });
    }
  }

  Widget buildMultiPart() {
    if (loading) {
      load();
      return const Center(
        child: CircularProgressIndicator(),
      );
    } else if (message != null) {
      return NetworkError(
        message: message!,
        retry: refresh,
        withAppbar: false,
      );
    } else {
      return buildPage();
    }
  }

  Widget buildPage() {
    return SmoothCustomScrollView(
      slivers: _buildPage().toList(),
    );
  }

  Iterable<Widget> _buildPage() sync* {
    for (var part in parts!) {
      yield* _buildExplorePagePart(part, comicSourceKey);
    }
  }

  @override
  Object? get tag => widget.title;

  @override
  void refresh() {
    message = null;
    if (data.loadMultiPart != null) {
      setState(() {
        loading = true;
      });
    } else if (data.loadPage != null) {
      StateController.findOrNull<ComicsPageLogic>(tag: tag.toString())
          ?.refresh();
    } else {
      setState(() {
        key++;
      });
    }
  }
}

class _ComicList extends ComicsPage<BaseComic> {
  const _ComicList(this.builder, this.tag, this.sourceKey);

  @override
  final String tag;

  final ComicListBuilder builder;

  @override
  final String sourceKey;

  /// 探索页里的列表页(如 PicACG随机)支持顶部下拉刷新
  @override
  bool get pullToRefresh => true;

  @override
  Future<Res<List<BaseComic>>> getComics(int i) {
    return builder(i);
  }

  @override
  String? get title => null;
}

class _MixedExplorePage extends StatefulWidget {
  const _MixedExplorePage(this.data, this.sourceKey, {super.key});

  final ExplorePageData data;

  final String sourceKey;

  @override
  State<_MixedExplorePage> createState() => _MixedExplorePageState();
}

class _MixedExplorePageState
    extends MultiPageLoadingState<_MixedExplorePage, Object> {
  Iterable<Widget> buildSlivers(BuildContext context, List<Object> data) sync* {
    List<BaseComic> cache = [];
    for (var part in data) {
      if (part is ExplorePagePart) {
        if (cache.isNotEmpty) {
          yield SliverGridComics(
            comics: (cache),
            sourceKey: widget.sourceKey,
          );
          yield const SliverToBoxAdapter(child: Divider());
          cache.clear();
        }
        yield* _buildExplorePagePart(part, widget.sourceKey);
        yield const SliverToBoxAdapter(child: Divider());
      } else {
        cache.addAll(part as List<BaseComic>);
      }
    }
    if (cache.isNotEmpty) {
      yield SliverGridComics(
        comics: (cache),
        sourceKey: widget.sourceKey,
      );
    }
  }

  @override
  Widget buildContent(BuildContext context, List<Object> data) {
    return SmoothCustomScrollView(
      slivers: [
        ...buildSlivers(context, data),
        if (haveNextPage) const ListLoadingIndicator().toSliver()
      ],
    );
  }

  @override
  Future<Res<List<Object>>> loadData(int page) async {
    var res = await widget.data.loadMixed!(page);
    if (res.error) {
      return res;
    }
    for (var element in res.data) {
      if (element is! ExplorePagePart && element is! List<BaseComic>) {
        return const Res.error("function loadMixed return invalid data");
      }
    }
    return res;
  }
}

Iterable<Widget> _buildExplorePagePart(
    ExplorePagePart part, String sourceKey) sync* {
  Widget buildTitle(ExplorePagePart part) {
    return SliverToBoxAdapter(
      child: SizedBox(
        height: 60,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 5, 10),
          child: Row(
            children: [
              Text(
                part.title,
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
              ),
              const Spacer(),
              if (part.viewMore != null)
                TextButton(
                  onPressed: () {
                    var context = App.mainNavigatorKey!.currentContext!;
                    if (part.viewMore!.startsWith("search:")) {
                      context.to(
                        () => SearchResultPage(
                          keyword: part.viewMore!.replaceFirst("search:", ""),
                          sourceKey: sourceKey,
                        ),
                      );
                    } else if (part.viewMore!.startsWith("category:")) {
                      var cp = part.viewMore!.replaceFirst("category:", "");
                      var c = cp.split('@').first;
                      String? p = cp.split('@').last;
                      if (p == c) {
                        p = null;
                      }
                      context.to(
                        () => CategoryComicsPage(
                          category: c,
                          categoryKey:
                              ComicSource.find(sourceKey)!.categoryData!.key,
                          param: p,
                        ),
                      );
                    }
                  },
                  child: Text("查看更多".tl),
                )
            ],
          ),
        ),
      ),
    );
  }

  Widget buildComics(ExplorePagePart part) {
    return SliverGridComics(comics: part.comics, sourceKey: sourceKey);
  }

  yield buildTitle(part);
  yield buildComics(part);
}
