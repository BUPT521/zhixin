import 'package:material_ui/material_ui.dart';

/// 动效的几档时长与曲线；页面与公共组件只从这里取，不再各写一套数字。
///
/// 动效只用来说明“内容换了”“这一块展开了”“选中项移到了这里”，不做装饰：
/// 位移不超过 8 像素，不缩放、不弹跳、不循环。系统打开“减少动态效果”时，
/// [ZhixinMotionContext.motionOf] 把时长归零，界面直接到终态。
class ZhixinMotion {
  const ZhixinMotion();

  /// 按下、描边、选中色这类控件自身的状态变化。
  Duration get fast => const Duration(milliseconds: 120);

  /// 分段滑块、内容淡入、展开收起。
  Duration get standard => const Duration(milliseconds: 200);

  /// 整栏切换这类一次换掉大半屏的变化。
  Duration get emphasized => const Duration(milliseconds: 260);

  /// 位置与尺寸变化：起步快、收尾慢，停下时不过冲。
  Curve get move => Curves.easeOutCubic;

  /// 内容进入。
  Curve get enter => Curves.easeOut;

  /// 新内容进入时自下而上移动的距离。
  double get rise => 6;
}

extension ZhixinMotionContext on BuildContext {
  /// 系统要求减少动态效果时为真；测试与无障碍设置都从这里读。
  bool get reduceMotion => MediaQuery.maybeDisableAnimationsOf(this) ?? false;

  /// 按“减少动态效果”换算后的时长：打开时为零，否则原样返回。
  Duration motionOf(Duration duration) =>
      reduceMotion ? Duration.zero : duration;
}

/// 子组件首次出现、或 [trigger] 变化时淡入，并自下而上移动几个像素。
///
/// 只播放新内容的进入，不保留旧内容做淡出：旧内容里可能带着 GlobalKey
/// 或正在输入的状态，两份同时留在树里会冲突；内容替换本身已经足够说明
/// 发生了切换。[playOnInit] 为假时首次出现不播放，只在 [trigger] 变化时播放，
/// 用在页面常驻、但要提示“这一块换了”的地方。
class FadeIn extends StatefulWidget {
  const FadeIn({
    super.key,
    required this.child,
    this.trigger,
    this.playOnInit = true,
    this.rise = true,
  });

  final Widget child;
  final Object? trigger;
  final bool playOnInit;

  /// 为假时只淡入，不移动；用在居中的转圈与空态这类位置固定的内容。
  final bool rise;

  @override
  State<FadeIn> createState() => _FadeInState();
}

class _FadeInState extends State<FadeIn> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: widget.playOnInit ? 0 : 1,
  );
  late final CurvedAnimation _curved = CurvedAnimation(
    parent: _controller,
    curve: const ZhixinMotion().enter,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (widget.playOnInit) _play();
  }

  @override
  void didUpdateWidget(covariant FadeIn oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trigger != widget.trigger) _play();
  }

  void _play() {
    const motion = ZhixinMotion();
    final duration = context.motionOf(motion.standard);
    if (duration == Duration.zero) {
      _controller.value = 1;
      return;
    }
    _controller.duration = duration;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const motion = ZhixinMotion();
    final curved = _curved;
    final fade = FadeTransition(opacity: curved, child: widget.child);
    if (!widget.rise) return fade;
    return AnimatedBuilder(
      animation: curved,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, (1 - curved.value) * motion.rise),
        child: child,
      ),
      child: fade,
    );
  }
}

/// 可以展开与收起的一块内容：高度平滑变化，内容同时淡入淡出。
///
/// 收起时子组件会在动画结束后移出树，不再参与布局与语义；展开时重新建出来。
/// 用在“显示已完成”“显示全部计划”和首页读到活动之后插入的活动卡。
class ExpandReveal extends StatefulWidget {
  const ExpandReveal({
    super.key,
    required this.visible,
    required this.child,
    this.animateOnInit = false,
  });

  final bool visible;
  final Widget child;

  /// 为真时首次以展开状态出现也播放一次展开。
  final bool animateOnInit;

  @override
  State<ExpandReveal> createState() => _ExpandRevealState();
}

class _ExpandRevealState extends State<ExpandReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: widget.visible && !widget.animateOnInit ? 1 : 0,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (widget.visible && widget.animateOnInit) _run(true);
  }

  @override
  void didUpdateWidget(covariant ExpandReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) _run(widget.visible);
  }

  void _run(bool show) {
    const motion = ZhixinMotion();
    final duration = context.motionOf(motion.standard);
    if (duration == Duration.zero) {
      _controller.value = show ? 1 : 0;
      return;
    }
    _controller.duration = duration;
    show ? _controller.forward() : _controller.reverse();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const motion = ZhixinMotion();
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final t = _controller.value;
        if (t == 0 && !widget.visible) return const SizedBox.shrink();
        // 展开的整个过程与展开之后用同一层结构，子组件的状态不会因为
        // 动画结束而被重建。
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: motion.move.transform(t),
            child: Opacity(opacity: Curves.easeIn.transform(t), child: child),
          ),
        );
      },
    );
  }
}

/// 底部三栏用的常驻页面栈：切换时新栏淡入并上移几个像素，
/// 其余栏目保持原状态（输入、筛选与滚动位置都不丢）。
class FadeIndexedStack extends StatefulWidget {
  const FadeIndexedStack({
    super.key,
    required this.index,
    required this.children,
  });

  final int index;
  final List<Widget> children;

  @override
  State<FadeIndexedStack> createState() => _FadeIndexedStackState();
}

class _FadeIndexedStackState extends State<FadeIndexedStack>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: 1,
  );
  late final CurvedAnimation _curved = CurvedAnimation(
    parent: _controller,
    curve: const ZhixinMotion().move,
  );

  @override
  void didUpdateWidget(covariant FadeIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index == widget.index) return;
    const motion = ZhixinMotion();
    final duration = context.motionOf(motion.emphasized);
    if (duration == Duration.zero) {
      _controller.value = 1;
      return;
    }
    _controller.duration = duration;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 每一栏都包同一层结构，只有当前栏读动画值；结构不随切换变化，
    // 否则切栏时其余栏目的状态会被重建。
    return IndexedStack(
      index: widget.index,
      children: [
        for (var i = 0; i < widget.children.length; i++)
          _TabFade(
            animation: _curved,
            active: i == widget.index,
            child: widget.children[i],
          ),
      ],
    );
  }
}

class _TabFade extends AnimatedWidget {
  const _TabFade({
    required Animation<double> animation,
    required this.active,
    required this.child,
  }) : super(listenable: animation);

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    const motion = ZhixinMotion();
    final t = active ? (listenable as Animation<double>).value : 1.0;
    return Opacity(
      opacity: Curves.easeOut.transform((t * 1.4).clamp(0.0, 1.0)),
      child: Transform.translate(
        offset: Offset(0, (1 - t) * motion.rise * 1.5),
        child: child,
      ),
    );
  }
}
