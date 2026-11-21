part of pica_reader;

const double _pi = 3.141592653589793;

/// 阅读器自绘状态栏：按澎湃OS（HyperOS）系统状态栏的实际尺寸/配色复刻。
///
/// 阅读器里系统状态栏是隐藏的（immersiveSticky），这条状态栏画在顶部工具栏内部，
/// 所以它会跟着工具栏一起滑入滑出，也能自己做淡入淡出。
class ReaderStatusBar extends StatefulWidget {
  const ReaderStatusBar({super.key});

  /// 进入阅读器前量到的系统状态栏高度（系统栏隐藏后就取不到了）。
  static double _height = 0;

  /// 在系统栏还可见时调用，记下真实状态栏高度，让自绘栏与刘海/挖孔对齐。
  static void rememberHeight(double height) {
    if (height > 0) {
      _height = height;
    }
  }

  @override
  State<ReaderStatusBar> createState() => _ReaderStatusBarState();
}

class _ReaderStatusBarState extends State<ReaderStatusBar> {
  static const _channel = MethodChannel('pica_comic/battery');

  Timer? _timer;
  String _time = '';
  int? _level;
  bool _charging = false;
  bool _wifi = false;
  bool _cellular = true;
  String _label = '';

  @override
  void initState() {
    super.initState();
    _updateTime();
    _loadStatus();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) {
      _updateTime();
      _loadStatus();
    });
  }

  void _updateTime() {
    final now = DateTime.now();
    final text = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    if (mounted && text != _time) {
      setState(() => _time = text);
    }
  }

  Future<void> _loadStatus() async {
    try {
      final result =
          await _channel.invokeMapMethod<String, dynamic>('status');
      if (!mounted || result == null) {
        return;
      }
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final heightPx = (result['heightPx'] as num?)?.toInt() ?? 0;
      if (heightPx > 0 && dpr > 0) {
        ReaderStatusBar.rememberHeight(heightPx / dpr);
      }
      setState(() {
        _level = (result['level'] as num?)?.toInt();
        _charging = result['charging'] == true;
        _wifi = result['wifi'] == true;
        _cellular = result['cellular'] == true;
        _label = (result['label'] as String?) ?? '';
      });
    } catch (_) {
      // 取不到系统状态就不更新，不影响阅读
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (ReaderStatusBar._height <= 0) {
      final top = MediaQuery.of(context).viewPadding.top;
      if (top > 0) {
        ReaderStatusBar._height = top;
      }
    }
    // 兜底 28dp，避免取不到高度时内容压到刘海
    final height = ReaderStatusBar._height > 0 ? ReaderStatusBar._height : 28.0;
    return SizedBox(
      height: height,
      child: Padding(
        // 顶部再让 3dp：系统状态栏的内容区并不是严格居中，这样能和系统图标齐平
        padding: const EdgeInsets.only(left: 22, right: 22, top: 2),
        child: Row(
          children: [
            Text(
              _time,
              style: const TextStyle(
                fontFamily: 'MiSansStatus',
                fontSize: 15,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.2,
                color: Colors.white,
              ),
            ),
            const Spacer(),
            if (_cellular) _HyperSignalGroup(label: _wifi ? '' : _label),
            if (_cellular && _wifi) const SizedBox(width: 6),
            if (_wifi) const _HyperWifiIcon(),
            if (_cellular || _wifi) const SizedBox(width: 6),
            _HyperBatteryIcon(level: _level, charging: _charging),
            if (_charging) const SizedBox(width: 2.5),
            if (_charging) const _HyperBoltIcon(),
          ],
        ),
      ),
    );
  }
}

/// 信号组：左上角网络制式文字（5G/4G，连 WiFi 时不显示）+ 右下角 4 根竖条。
class _HyperSignalGroup extends StatelessWidget {
  const _HyperSignalGroup({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) {
      return const SizedBox(
        width: 16.5,
        height: 12,
        child: CustomPaint(painter: _HyperSignalBarsPainter()),
      );
    }
    return SizedBox(
      width: 25,
      height: 12,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 4.0, // 相对第一根信号柱左边缘：系统是 -17px
            top: -1.85, // 文字底边在柱子底部上方 25px（系统实测）
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: 'MiSansStatus',
                fontSize: 7.3,
                fontWeight: FontWeight.w700,
                height: 1.0,
                letterSpacing: -0.3,
                color: Color(0xFFE8E8E8),
              ),
            ),
          ),
          const Positioned(
            right: 0,
            bottom: 0,
            child: SizedBox(
              width: 16.5,
              height: 12,
              child: CustomPaint(painter: _HyperSignalBarsPainter()),
            ),
          ),
        ],
      ),
    );
  }
}

/// 4 根圆角竖条：宽 2.5dp、间距 1.85dp、高度 6.2/9.2/12.0/14.8dp，底部对齐。
class _HyperSignalBarsPainter extends CustomPainter {
  const _HyperSignalBarsPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xFFE8E8E8);
    const barW = 2.5;
    const gap = 1.85;
    const heights = <double>[4.0, 6.2, 9.2, 12.0];
    final totalW = heights.length * barW + (heights.length - 1) * gap;
    final left = size.width - totalW;
    for (var i = 0; i < heights.length; i++) {
      final h = heights[i];
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left + i * (barW + gap), size.height - h, barW, h),
          const Radius.circular(1.0),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// WiFi：两段实心扇环 + 下方实心小三角（澎湃OS 的 fan 造型）。
class _HyperWifiIcon extends StatelessWidget {
  const _HyperWifiIcon();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 16.5,
      height: 12,
      child: CustomPaint(painter: _HyperWifiPainter()),
    );
  }
}

class _HyperWifiPainter extends CustomPainter {
  const _HyperWifiPainter();

  // 参数由「系统图标像素 + 扇形模型」拟合得到（IoU 0.95），单位 dp（图标高 12dp）
  static const _cx = 8.32;
  static const _cy = 11.45;

  @override
  void paint(Canvas canvas, Size size) {
    const color = Color(0xFFE8E8E8);
    const center = Offset(_cx, _cy);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // 外环：半径 10.40、线宽 2.53、张角 83.7°
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: 10.40),
      -2.29,
      1.46,
      false,
      stroke..strokeWidth = 2.53,
    );
    // 内环：半径 6.06、线宽 2.49、张角 79.1°
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: 6.06),
      -2.27,
      1.38,
      false,
      stroke..strokeWidth = 2.49,
    );

    // 尖端：圆角扇形（apex 在下方、圆弧朝上）
    const tipR = 0.49; // 圆角半径
    const tipApexY = 12.34;
    const tipSectorR = 3.42;
    const tipHalf = 0.83; // 47.6°
    const apex = Offset(_cx, tipApexY - tipR);
    const sectorR = tipSectorR - tipR;
    final halfIn = math.asin((tipSectorR * math.sin(tipHalf) - tipR) / sectorR);
    final sector = Path()
      ..moveTo(apex.dx, apex.dy)
      ..arcTo(
        Rect.fromCircle(center: apex, radius: sectorR),
        -_pi / 2 - halfIn,
        halfIn * 2,
        false,
      )
      ..close();
    canvas.drawPath(
      sector,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = tipR * 2
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(sector, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 电池：实心横向圆角电池（21.8x12dp）+ 右侧触点 + 内部反色电量数字。
class _HyperBatteryIcon extends StatelessWidget {
  const _HyperBatteryIcon({required this.level, required this.charging});

  final int? level;
  final bool charging;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 26.8,
      height: 14,
      child: CustomPaint(
        painter: _HyperBatteryPainter(level, charging),
      ),
    );
  }
}

class _HyperBatteryPainter extends CustomPainter {
  const _HyperBatteryPainter(this.level, this.charging);

  final int? level;
  final bool charging;

  static const _green = Color(0xFF1DCD3A);
  static const _nub = Color(0xFF6A6C6E);

  @override
  void paint(Canvas canvas, Size size) {
    final text = (level ?? 100).clamp(0, 100).toString();
    final bodyW = text.length >= 3 ? 22.8 : 21.8;
    const bodyH = 12.0;
    final bodyTop = (size.height - bodyH) / 2;
    final bodyColor = charging ? _green : Colors.white;

    // 实心电池
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, bodyTop, bodyW, bodyH),
        const Radius.circular(3.0),
      ),
      Paint()..color = bodyColor,
    );
    // 右侧触点（系统里是灰色）
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(bodyW + 0.8, bodyTop + bodyH / 2 - 2.0, 1.2, 4.0),
        const Radius.circular(0.6),
      ),
      Paint()..color = charging ? _nub : _nub,
    );

    // 电量数字：与电池底色反色
    final numberColor = charging ? Colors.white : const Color(0xFF1B1B1B);
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'MiSansStatus',
          fontSize: 9.2,
          fontWeight: FontWeight.w700,
          height: 1.0,
          letterSpacing: -0.2,
          color: numberColor,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // 数字在电池主体内水平居中（和系统 HyperOS 一致）
    final numberCenterX = bodyW / 2;
    textPainter.paint(
      canvas,
      Offset(
        numberCenterX - textPainter.width / 2,
        // +1.08dp：字体行框的上下留白不对称，补偿后数字在视觉上垂直居中
        bodyTop + (bodyH - textPainter.height) / 2 + 1.08,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant _HyperBatteryPainter oldDelegate) =>
      oldDelegate.level != level || oldDelegate.charging != charging;
}

/// 充电闪电（电池右侧，浅灰白色，尺寸按系统实测 5.2x11.5dp）。
class _HyperBoltIcon extends StatelessWidget {
  const _HyperBoltIcon();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 5.4,
      height: 11.5,
      child: CustomPaint(painter: _HyperBoltPainter()),
    );
  }
}

class _HyperBoltPainter extends CustomPainter {
  const _HyperBoltPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w * 0.62, 0)
      ..lineTo(0, h * 0.58)
      ..lineTo(w * 0.40, h * 0.58)
      ..lineTo(w * 0.22, h)
      ..lineTo(w, h * 0.40)
      ..lineTo(w * 0.58, h * 0.40)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xFFD2D2D3));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
