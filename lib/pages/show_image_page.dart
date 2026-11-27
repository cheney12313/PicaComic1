import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:pica_comic/foundation/image_loader/cached_image.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/tools/save_image.dart';
import 'package:pica_comic/tools/system_ui.dart';
import 'package:pica_comic/tools/translations.dart';

/// 看图页的状态栏样式：跟随 App 主题（浅色主题深色图标 / 深色主题白色图标）。
///
/// 图标颜色和页面工具栏一致，系统把状态栏收起来的那一小段时间里也不会出现
/// 白图标压在浅色工具栏上；系统收起的动画时长本身是 OS 控制的，App 改不了。
SystemUiOverlayStyle _imageViewerOverlayStyle(BuildContext context) =>
    appOverlayStyle(context);

/// 隐藏顶部系统状态栏，看图页进入时使用。
///
/// 用和阅读器完全相同的 immersiveSticky：这台机器上 manual（只收状态栏）
/// 会走系统那段很慢的滑出动画，一秒钟还没收干净；阅读器里同一套沉浸模式
/// 是"点一下就没"，所以这里直接对齐阅读器。
void prepareImageViewerStatusBar() {
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
}

/// 恢复系统状态栏（看图页退出时使用）。
///
/// 与 main.dart 启动时的默认状态保持一致（manual + 全部 overlay），
/// 并重新下发一次主题相关样式：切模式会把状态栏图标重置成默认的白色。
void restoreImageViewerStatusBar() {
  restoreSystemBars();
}

/// 看图页期间隐藏系统状态栏，退出时恢复。
///
/// 隐藏动作在点击封面/头像的那一刻就发起（见调用点的
/// prepareImageViewerStatusBar），这里只是兜底，保证直接打开这个页面时
/// 也能正确沉浸。
mixin _ImmersiveStatusBar<T extends StatefulWidget> on State<T> {
  @override
  void initState() {
    super.initState();
    prepareImageViewerStatusBar();
  }

  @override
  void dispose() {
    restoreImageViewerStatusBar();
    super.dispose();
  }
}

/// 状态栏隐藏后 padding.top 会变成 0，但刘海/挖孔的高度还在 viewPadding 里。
/// 这里把它补回 padding，免得工具栏顶进摄像头区域。
class _CutoutSafe extends StatelessWidget {
  const _CutoutSafe({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    var mediaQuery = MediaQuery.of(context);
    if (mediaQuery.padding.top < mediaQuery.viewPadding.top) {
      mediaQuery = mediaQuery.copyWith(
        padding: mediaQuery.padding.copyWith(top: mediaQuery.viewPadding.top),
      );
    }
    return MediaQuery(data: mediaQuery, child: child);
  }
}

class ShowImagePage extends StatefulWidget {
  const ShowImagePage(this.url, {super.key});

  final String url;

  @override
  State<ShowImagePage> createState() => _ShowImagePageState();
}

class _ShowImagePageState extends State<ShowImagePage>
    with _ImmersiveStatusBar {
  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _imageViewerOverlayStyle(context),
      child: _CutoutSafe(
        child: Scaffold(
          appBar: AppBar(
            title: Text("图片".tl),
          ),
          body: PhotoView(
            minScale: PhotoViewComputedScale.contained * 0.9,
            imageProvider: CachedImageProvider(widget.url),
            loadingBuilder: (context, event) {
              return Container(
                decoration: const BoxDecoration(color: Colors.black),
                child: const Center(
                  child: CircularProgressIndicator(),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class ShowImagePageWithHero extends StatefulWidget {
  const ShowImagePageWithHero(this.url, this.tag, {super.key});

  final String url;

  final String tag;

  @override
  State<ShowImagePageWithHero> createState() => _ShowImagePageWithHeroState();
}

class _ShowImagePageWithHeroState extends State<ShowImagePageWithHero>
    with _ImmersiveStatusBar {
  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _imageViewerOverlayStyle(context),
      child: _CutoutSafe(
        child: Scaffold(
          appBar: AppBar(
            title: Text("图片".tl),
            actions: [
              Tooltip(
                message: "保存".tl,
                child: IconButton(
                  icon: const Icon(Icons.download),
                  onPressed: () async{
                    var file = await ImageManager().getFile(widget.url);
                    if(file != null){
                      saveImage(file);
                    }
                  }
              ))
            ],
          ),
          body: Hero(
            tag: widget.tag,
            child: PhotoView(
              minScale: PhotoViewComputedScale.contained * 0.9,
              imageProvider: CachedImageProvider(widget.url),
              loadingBuilder: (context, event) {
                return Container(
                  decoration: const BoxDecoration(color: Colors.black),
                  child: const Center(
                    child: CircularProgressIndicator(),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
