import 'dart:async';

import 'package:flutter/scheduler.dart';
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

  /// 过渡结束后再回填：读取可以立刻发起，结果回来时若还在切栏或推入页面，
  /// 等这段动画走完再把结果交给界面，回填不会打断动画。
  ///
  /// 先等过当前这一帧再判断：切栏动画在状态变化之后的下一帧才开始，直接读
  /// 状态会读到“已经结束”，回填于是又落进动画里。读不到过渡时不多等。
  Future<void> afterTransition() async {
    final route = ModalRoute.of(this)?.animation;
    final tab = TabTransition.maybeOf(this);
    await SchedulerBinding.instance.endOfFrame;
    final pending = <Animation<double>>[?_running(route), ?_running(tab)];
    if (pending.isEmpty) return;
    await Future.wait(pending.map(_settled));
  }

  /// 正在推进中的动画；已完成或已收起的不算，避免误等一个不会再走的动画。
  static Animation<double>? _running(Animation<double>? animation) {
    if (animation == null) return null;
    final status = animation.status;
    if (status == AnimationStatus.forward ||
        status == AnimationStatus.reverse) {
      return animation;
    }
    return null;
  }

  /// 等一段动画走到终态；动画被 TickerMode 停住时也照样等它回到终态。
  static Future<void> _settled(Animation<double> animation) {
    if (animation.status == AnimationStatus.completed ||
        animation.status == AnimationStatus.dismissed) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    late final AnimationStatusListener listener;
    listener = (status) {
      if (status != AnimationStatus.completed &&
          status != AnimationStatus.dismissed) {
        return;
      }
      animation.removeStatusListener(listener);
      if (!completer.isCompleted) completer.complete();
    };
    animation.addStatusListener(listener);
    return completer.future;
  }
}

/// 把当前栏的切换动画交给子树，页面据此判断切换是否已经落定。
///
/// 只让页面读得到动画本身，不跟着动画逐帧重建：这是一个普通 [InheritedWidget]，
/// 动画值变化不会通知依赖方。
class TabTransition extends InheritedWidget {
  const TabTransition({
    super.key,
    required this.animation,
    required super.child,
  });

  final Animation<double> animation;

  /// 不在底栏里（二级页面、测试）时为假。
  static Animation<double>? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<TabTransition>()?.animation;

  @override
  bool updateShouldNotify(TabTransition oldWidget) =>
      oldWidget.animation != animation;
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
    // 位移只移动这一层；内容放在重绘边界里，动画期间不重画文字与卡片。
    final content = RepaintBoundary(child: widget.child);
    final fade = FadeTransition(opacity: curved, child: content);
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
  late final CurvedAnimation _height = CurvedAnimation(
    parent: _controller,
    curve: const ZhixinMotion().move,
  );
  late final CurvedAnimation _fade = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeIn,
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
    _fade.dispose();
    _height.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      // 收起之后把内容移出树，不再参与布局与语义。
      builder: (context, _) {
        if (_controller.value == 0 && !widget.visible) {
          return const SizedBox.shrink();
        }
        // 高度用框架自带的 SizeTransition，透明度用 FadeTransition：两者都
        // 只改合成与布局，不逐帧重画内容；内容再包一层重绘边界。
        return FadeTransition(
          opacity: _fade,
          child: SizeTransition(
            sizeFactor: _height,
            // 与原来的 Align(topCenter) 一致：收起时内容贴着上边被裁掉。
            alignment: Alignment.topCenter,
            child: RepaintBoundary(child: widget.child),
          ),
        );
      },
    );
  }
}

/// 底部三栏用的常驻页面栈：切换时新栏淡入并上移几个像素，
/// 其余栏目保持原状态（输入、筛选与滚动位置都不丢）。
///
/// 每栏都包同一层结构，结构不随切换变化，否则切栏时其余栏目的状态会被重建。
/// 透明度用 [FadeTransition]、位移只动包在重绘边界外的一层，动画期间不重画
/// 整栏内容；非当前栏关掉 [TickerMode]，隐藏的转圈与生成中提示暂停而不是销毁。
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

  /// 透明度在前七成时间里走完，之后离屏层撤掉，剩下的时间只做位移收尾。
  late final CurvedAnimation _opacity = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0, 0.7, curve: Curves.easeOut),
  );
  late final CurvedAnimation _move = CurvedAnimation(
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
    _move.dispose();
    _opacity.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rise = const ZhixinMotion().rise * 1.5;
    return IndexedStack(
      index: widget.index,
      children: [
        for (var i = 0; i < widget.children.length; i++)
          TabTransition(
            animation: _controller,
            child: _TabLayer(
              active: i == widget.index,
              opacity: i == widget.index ? _opacity : kAlwaysCompleteAnimation,
              move: i == widget.index ? _move : kAlwaysCompleteAnimation,
              rise: rise,
              child: widget.children[i],
            ),
          ),
      ],
    );
  }
}

class _TabLayer extends StatelessWidget {
  const _TabLayer({
    required this.active,
    required this.opacity,
    required this.move,
    required this.rise,
    required this.child,
  });

  final bool active;
  final Animation<double> opacity;
  final Animation<double> move;
  final double rise;
  final Widget child;

  @override
  Widget build(BuildContext context) => TickerMode(
    enabled: active,
    child: FadeTransition(
      opacity: opacity,
      child: AnimatedBuilder(
        animation: move,
        // 子树放进重绘边界：动画期间每帧只移动这一层，不重画页面内容。
        child: RepaintBoundary(child: child),
        builder: (context, child) => Transform.translate(
          offset: Offset(0, (1 - move.value) * rise),
          child: child,
        ),
      ),
    ),
  );
}
