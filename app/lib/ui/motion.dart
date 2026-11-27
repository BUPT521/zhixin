import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

/// 动效的几档时长与曲线；页面与公共组件只从这里取，不再各写一套数字。
///
/// 动效只用来说明“内容换了”“这一块展开了”“选中项移到了这里”“这一下按到了”，
/// 不做装饰：除底栏、页签与换周按整幅页宽滑入滑出之外，其余位移不超过 24 像素，
/// 不弹跳、不循环；缩放用于控件的按下反馈，只改绘制，不改版面。系统打开
/// “减少动态效果”时，[ZhixinMotionContext.motionOf]
/// 把时长归零，界面直接到终态。
class ZhixinMotion {
  const ZhixinMotion();

  /// 按下、描边、选中色这类控件自身的状态变化。
  Duration get fast => const Duration(milliseconds: 120);

  /// 分段滑块、内容淡入、展开收起。
  Duration get standard => const Duration(milliseconds: 200);

  /// 整栏切换这类一次换掉大半屏的变化。
  Duration get emphasized => const Duration(milliseconds: 260);

  /// 生成中的三点提示走完一轮的时长；它只在生成期间循环。
  Duration get streaming => const Duration(milliseconds: 900);

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

  /// 过渡结束后再回填：读取可以立刻发起，结果要等路由、底栏与调用方传入的
  /// 页签动画结束后再交给界面。
  ///
  /// 先等过当前这一帧再判断：切栏动画在状态变化之后的下一帧才开始，直接读
  /// 状态会读到“已经结束”，回填于是又落进动画里。读不到过渡时不多等。
  /// 祖先要在这一帧之内取好：等完这一帧，这块内容可能已经卸载。
  Future<void> afterTransition({Animation<double>? contentTransition}) async {
    final route = ModalRoute.of(this)?.animation;
    final tabs = TabTransition.allOf(this);
    await SchedulerBinding.instance.endOfFrame;
    final pending = <Animation<double>>[
      ?_running(route),
      for (final tab in tabs) ?_running(tab),
      ?_running(contentTransition),
    ];
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

  /// 当前内容外面套着的全部切换动画。
  ///
  /// 底栏、页签与换周各有一层，内层不是唯一的等待对象：换栏时页签那一层停着，
  /// 但它上面的底栏正在滑，数据回填要等最外层走完。
  static List<Animation<double>> allOf(BuildContext context) {
    final found = <Animation<double>>[];
    context.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is TabTransition) found.add(widget.animation);
      return true;
    });
    return found;
  }

  @override
  bool updateShouldNotify(TabTransition oldWidget) =>
      oldWidget.animation != animation;
}

/// 二级页面的统一路由过渡：新页淡入并从右侧推入一段距离，旧页不动。
///
/// 缩放类过渡要给整页做快照，也不符合整页只做透明度与位移的口径，这里只用
/// 透明度与位移（缩放只留给 [PressScale] 的按下反馈）。时长与曲线取自
/// [ZhixinMotion]；系统要求减少动态效果时直接显示终态。
/// 在 `ThemeData.pageTransitionsTheme` 里配置一次，页面不再各写一套。
class ZhixinPageTransitionsBuilder extends PageTransitionsBuilder {
  const ZhixinPageTransitionsBuilder();

  /// 新页从右侧推入的距离，按像素给；按百分比给在平板上会变成大半屏。
  static const double distance = 24;

  @override
  Duration get transitionDuration => const ZhixinMotion().emphasized;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (context.reduceMotion) return child;
    final move = animation.drive(CurveTween(curve: const ZhixinMotion().move));
    final fade = animation.drive(CurveTween(curve: const ZhixinMotion().enter));
    return AnimatedBuilder(
      animation: move,
      child: FadeTransition(opacity: fade, child: child),
      builder: (context, child) => Transform.translate(
        offset: Offset((1 - move.value) * distance, 0),
        child: child,
      ),
    );
  }
}

/// 安卓二级页面的路由过渡：交给系统的预测性返回。
///
/// 手势进行中由 [PredictiveBackPageTransitionsBuilder] 跟着手指展示返回预览，
/// 普通推入用它自己的回退过渡，时长与曲线由框架决定。系统要求减少动态效果时
/// 直接显示终态，也不注册手势监听，返回手势仍然可以退出页面。
class ZhixinAndroidPageTransitionsBuilder extends PageTransitionsBuilder {
  const ZhixinAndroidPageTransitionsBuilder();

  static const _predictive = PredictiveBackPageTransitionsBuilder();

  @override
  Duration get transitionDuration => _predictive.transitionDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (context.reduceMotion) return child;
    return _predictive.buildTransitions(
      route,
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }
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
  }) : _sliver = false;

  const FadeIn.sliver({
    super.key,
    required this.child,
    this.trigger,
    this.playOnInit = true,
  }) : rise = false,
       _sliver = true;

  final Widget child;
  final Object? trigger;
  final bool playOnInit;

  /// 为假时只淡入，不移动；用在居中的转圈与空态这类位置固定的内容。
  final bool rise;
  final bool _sliver;

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
    if (widget._sliver) {
      return SliverFadeTransition(opacity: curved, sliver: widget.child);
    }
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
  }) : _sliver = false;

  const ExpandReveal.sliver({
    super.key,
    required this.visible,
    required this.child,
  }) : animateOnInit = false,
       _sliver = true;

  final bool visible;
  final Widget child;
  final bool _sliver;

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
    if (widget._sliver) {
      return AnimatedBuilder(
        animation: _controller,
        child: SliverFadeTransition(
          opacity: _fade,
          sliver: SliverIgnorePointer(
            ignoring: !widget.visible,
            sliver: widget.child,
          ),
        ),
        // 每一行从正常高度开始布局，避免展开初期一次构建大量被压缩的行。
        builder: (context, child) => _controller.isDismissed && !widget.visible
            ? const SliverToBoxAdapter()
            : child!,
      );
    }
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

/// 按下时放大、松开与取消时回位的反馈，用在页内页签这类按下就切换的入口。
///
/// 放大只改绘制，不改布局：按下期间相邻元素的位置与整块内容的排版都不变，因此
/// 不会因为按下而抖动，被按的那一项周围也不会空出一块。不能切换的当前项传
/// [enabled] 为假，按下去不放大，免得看起来像会切到别处。系统要求减少动态效果
/// 时不做过渡，按下与松开立即到终态。
class PressScale extends StatefulWidget {
  const PressScale({
    super.key,
    required this.child,
    this.enabled = true,
    this.scale = 1.06,
  });

  final Widget child;

  /// 为假时忽略按下，按下去保持原尺寸。
  final bool enabled;

  /// 按下时的倍率；默认 1.06，再大就会压到相邻的图标与文字。
  final double scale;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  /// 正在按下的那一根手指；松开或取消之前不再接受第二根，避免多指把尺寸来回切换。
  int? _pointer;

  void _down(PointerDownEvent event) {
    if (!widget.enabled || _pointer != null) return;
    setState(() => _pointer = event.pointer);
  }

  void _up(PointerEvent event) {
    if (event.pointer != _pointer) return;
    setState(() => _pointer = null);
  }

  @override
  void didUpdateWidget(covariant PressScale oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 按下期间这一项变成了当前项：不再有切换动作，立刻回位。
    if (oldWidget.enabled && !widget.enabled) _pointer = null;
  }

  @override
  Widget build(BuildContext context) {
    const motion = ZhixinMotion();
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _down,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: AnimatedScale(
        scale: _pointer == null ? 1 : widget.scale,
        duration: context.motionOf(motion.fast),
        curve: motion.move,
        child: widget.child,
      ),
    );
  }
}

/// 底栏与页面内页签用的常驻页面栈：换页时新页从切换方向滑入，
/// 旧页向相反方向滑出，其余页面保持原状态（输入、筛选与滚动位置都不丢）。
///
/// 每一页都按同一层结构包起来，结构不随切换变化，否则切页时其余页面的状态
/// 会被重建。位移只移动包在重绘边界外的一层，动画期间不重画整页内容；非当前
/// 页关掉 [TickerMode]，隐藏的转圈与生成中提示暂停而不是销毁；没有参与本次
/// 切换的页面连语义一起隐藏，点击与读屏不会落到看不见的页面上。
///
/// 位移取整幅页宽：切到更靠右的一页时新页从右侧进来、旧页向左出去，切回左边
/// 时方向相反；两页在切换途中首尾相接，同一时刻只有一半屏幕在换内容。
///
/// 传入 [onSwipe] 之后，这一层还接左右划动：拖动途中两页跟着手指走，松手按
/// 划过的比例与划过时的速度决定切过去还是退回原处；到头的页面没有相邻的一页，
/// 手指往外划时不跟着动。调用方收到 [onSwipe] 之后要把 [index] 换成传过去的
/// 那一页，位移才能在划到的位置落定。页面里能横向滚动的内容先接走横拖，两者
/// 之间由手势竞技场裁决。
class TabSlideStack extends StatefulWidget {
  const TabSlideStack({
    super.key,
    required this.index,
    required this.children,
    this.onSwipe,
  });

  final int index;
  final List<Widget> children;

  /// 左右划到相邻一页时要去的那一页；为空时这一层不接划动，只按 [index] 切换。
  final ValueChanged<int>? onSwipe;

  @override
  State<TabSlideStack> createState() => _TabSlideStackState();
}

class _TabSlideStackState extends State<TabSlideStack>
    with SingleTickerProviderStateMixin {
  /// 划过整幅页宽的这个比例就切到相邻的一页。
  static const double _commitProgress = 0.35;

  /// 划过的比例不够时，同方向划得比这个速度（逻辑像素每秒）快也切过去。
  static const double _commitVelocity = 300;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: 1,
  );

  /// 这一趟切换里滑入与滑出的两页；不在切换途中时都为空。
  int? _entering;
  int? _leaving;

  /// 新页进入的方向：正数从右侧进入（切到更靠右的一页），负数从左侧进入。
  double _direction = 1;

  /// 手指是否还按在屏上。
  bool _dragging = false;

  /// 手指累计横移，向右为正；松手之后归零。
  double _dragDx = 0;

  /// 划动松手之后要去的那一页，等调用方把 [TabSlideStack.index] 换过来确认。
  int? _swipeTarget;

  /// 划动没到比例就松了手，正在退回原处；落回原位时由 [_settle] 收掉两页。
  bool _returning = false;

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener(_settle);
  }

  /// 播完把滑出去的旧页撤下：它已经移到屏外，语义不该再留在树上。
  void _settle(AnimationStatus status) {
    if (_returning && status == AnimationStatus.dismissed) {
      // 划动没到比例就松了手：退回原位，重新按当前页排版。
      setState(() {
        _returning = false;
        _entering = null;
        _leaving = null;
      });
      // 原位对应进度 1，下一次切换仍然从 0 播到 1。
      _controller.value = 1;
      return;
    }
    if (status != AnimationStatus.completed || _leaving == null) return;
    setState(() {
      _entering = null;
      _leaving = null;
    });
  }

  @override
  void didUpdateWidget(covariant TabSlideStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index == widget.index) return;
    // 划动松手之后调用方把 [TabSlideStack.index] 换成了手指选中的那一页：这一趟
    // 位移已经在播，或者已经停在目标位置，不重新播一次。
    if (widget.index == _swipeTarget) {
      _swipeTarget = null;
      if (_controller.isAnimating) return;
      setState(() {
        _entering = null;
        _leaving = null;
      });
      _controller.value = 1;
      return;
    }
    _returning = false;
    _dragging = false;
    _dragDx = 0;
    _entering = widget.index;
    _leaving = oldWidget.index;
    _direction = widget.index > oldWidget.index ? 1 : -1;
    final duration = context.motionOf(const ZhixinMotion().emphasized);
    if (duration == Duration.zero) {
      _entering = null;
      _leaving = null;
      _controller.value = 1;
      return;
    }
    _controller.duration = duration;
    _controller.forward(from: 0);
  }

  /// 页宽：划动按整幅页宽换算进度。
  double get _pageWidth => context.size?.width ?? 0;

  /// 横拖超过系统的最小距离之后从这里开始；已经有一趟位移在播时不接新的划动，
  /// 免得两段位移叠在一起。
  void _onDragStart(DragStartDetails details) {
    if (_leaving != null || _controller.value < 1) return;
    setState(() {
      _dragging = true;
      _dragDx = 0;
      _entering = widget.index;
      _leaving = widget.index;
    });
  }

  /// 划向的那一页：手指左移看右边一页，右移看左边一页；到头的一侧留在当前页。
  int _targetOf(double dx) {
    if (dx == 0) return widget.index;
    final target = widget.index + (dx < 0 ? 1 : -1);
    if (target < 0 || target >= widget.children.length) return widget.index;
    return target;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    _dragDx += details.delta.dx;
    final target = _targetOf(_dragDx);
    setState(() {
      _entering = target;
      if (target != widget.index) _direction = target > widget.index ? 1 : -1;
    });
  }

  void _onDragCancel() => _onDragEnd(DragEndDetails());

  void _onDragEnd(DragEndDetails details) {
    if (!_dragging) return;
    final target = _entering ?? widget.index;
    final width = _pageWidth;
    final progress = width <= 0 ? 0.0 : (_dragDx.abs() / width).clamp(0.0, 1.0);
    final velocity = details.primaryVelocity ?? 0;
    final moving = target != widget.index;
    // 划过的比例到了就切过去；比例不够时，同方向划得够快也算。切到更靠右的
    // 一页要手指往左划，所以划动方向与前进方向相反。
    final ahead = target > widget.index ? 1 : -1;
    final commit =
        moving &&
        (progress >= _commitProgress || -velocity * ahead >= _commitVelocity);
    setState(() {
      _dragging = false;
      _dragDx = 0;
      if (!moving) {
        _entering = null;
        _leaving = null;
      }
    });
    if (!moving) return;
    // 退回原处与切过去都从手指停下的进度接着走，不回到起点重来。
    final full = context.motionOf(const ZhixinMotion().emphasized);
    if (commit) {
      _swipeTarget = target;
      final remaining = full * (1 - progress);
      if (remaining > Duration.zero) {
        _controller.value = progress;
        _controller.animateTo(1, duration: remaining);
      }
      widget.onSwipe?.call(target);
      return;
    }
    _returning = true;
    final duration = full * progress;
    if (duration == Duration.zero) {
      // 进度归零会触发 dismissed，由 [_settle] 收尾。
      _controller.value = 0;
      return;
    }
    _controller.value = progress;
    _controller.animateBack(0, duration: duration);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = const ZhixinMotion().move;
    final stack = LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final entering = _entering ?? widget.index;
        // 拖动途中按手指的位移算进度，不套过渡曲线：手指停在哪里，页面就停在
        // 哪里；到头的页面没有相邻的一页，不跟手，按原位画。
        final drag = _dragging && entering != widget.index && width > 0
            ? (_dragDx.abs() / width).clamp(0.0, 1.0)
            : null;
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final t = drag ?? curve.transform(_controller.value);
            final leaving = _leaving;
            return Stack(
              fit: StackFit.expand,
              children: [
                for (var i = 0; i < widget.children.length; i++)
                  _TabLayer(
                    active: i == widget.index,
                    visible: i == entering || i == leaving,
                    dx: i == entering
                        ? (1 - t) * width * _direction
                        : i == leaving
                        ? -t * width * _direction
                        : 0,
                    animation: _controller,
                    child: widget.children[i],
                  ),
              ],
            );
          },
        );
      },
    );
    if (widget.onSwipe == null) return stack;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      onHorizontalDragCancel: _onDragCancel,
      child: stack,
    );
  }
}

class _TabLayer extends StatelessWidget {
  const _TabLayer({
    required this.active,
    required this.visible,
    required this.dx,
    required this.animation,
    required this.child,
  });

  final bool active;

  /// 是否参与本次切换；不参与时保留状态，但不布局、不绘制，也不占语义。
  final bool visible;

  /// 本栏相对原位的水平位移，正数向右。
  final double dx;

  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) => _TabStage(
    visible: visible,
    // 滑出的那一栏还在画面上，但它已经不是当前页：控件查找、读屏与测试按
    // 原来的口径只看得到当前栏。
    onstage: active,
    child: ExcludeFocus(
      excluding: !active,
      child: TickerMode(
        enabled: active,
        // 子树放进重绘边界：动画期间每帧只移动这一层，不重画页面内容。
        child: Transform.translate(
          offset: Offset(dx, 0),
          child: RepaintBoundary(
            child: TabTransition(animation: animation, child: child),
          ),
        ),
      ),
    ),
  );
}

/// 一栏在页面栈里的显隐：控制是否布局、绘制，以及控件查找能否看到它。
///
/// 与 [Offstage] 的区别是多了 [onstage]：滑出的那一栏仍然布局与绘制，但已经
/// 不是当前页，控件查找、读屏与测试和 [IndexedStack] 一样只看得到当前栏。
class _TabStage extends Offstage {
  const _TabStage({
    required this.onstage,
    required bool visible,
    required super.child,
  }) : super(offstage: !visible);

  final bool onstage;

  @override
  _TabStageElement createElement() => _TabStageElement(this);
}

class _TabStageElement extends SingleChildRenderObjectElement {
  _TabStageElement(_TabStage super.widget);

  @override
  void debugVisitOnstageChildren(ElementVisitor visitor) {
    if ((widget as _TabStage).onstage) super.debugVisitOnstageChildren(visitor);
  }
}

/// 同一块位置换了内容时按先后次序左右滑动：新的从对应一侧进来，旧的出去。
///
/// 换周这类内容由数据决定、不是常驻页面的切换用它：[identity] 变了才播，
/// [order] 变大表示新的在右边。旧内容在新内容播完之前留在树上继续绘制，播完
/// 再回收；期间它不参与控件查找、读屏与焦点，控件查找只看得到新内容。
///
/// 新旧两块同时在树上，内容里如果有共享的 [GlobalKey] 会在这一段时间里冲突，
/// 这类内容不要用它；每份内容各建各的 key 的，不受影响。
class SlideSwap extends StatefulWidget {
  const SlideSwap({
    super.key,
    required this.identity,
    required this.order,
    required this.child,
  });

  /// 内容的身份；同一个身份重建不播放。
  final Object identity;

  /// 新旧内容的次序，只用来判断方向。
  final num order;

  final Widget child;

  @override
  State<SlideSwap> createState() => _SlideSwapState();
}

class _SlideSwapState extends State<SlideSwap>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: 1,
  )..addStatusListener(_settle);

  /// 正在滑出的旧内容；不在切换途中时为空。
  Widget? _previous;
  Object? _previousIdentity;

  /// 新内容进入的方向：正数从右侧进入（次序变大），负数从左侧进入。
  double _direction = 1;

  void _settle(AnimationStatus status) {
    if (status != AnimationStatus.completed || _previous == null) return;
    setState(() {
      _previous = null;
      _previousIdentity = null;
    });
  }

  @override
  void didUpdateWidget(covariant SlideSwap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity == widget.identity) return;
    _direction = widget.order >= oldWidget.order ? 1 : -1;
    final duration = context.motionOf(const ZhixinMotion().emphasized);
    if (duration == Duration.zero) {
      _previous = null;
      _previousIdentity = null;
      _controller.value = 1;
      return;
    }
    _previous = oldWidget.child;
    _previousIdentity = oldWidget.identity;
    _controller.duration = duration;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = const ZhixinMotion().move;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final leaving = _previous;
            final moving = leaving != null && _controller.value < 1;
            final t = curve.transform(_controller.value);
            return Stack(
              fit: StackFit.expand,
              children: [
                // 两块走同一层结构，只差身份与位移：换内容时旧的那块按 key
                // 原样留在树上继续画，不重新挂载，订阅与滚动位置都不重来。
                if (moving)
                  _layer(
                    identity: _previousIdentity!,
                    onstage: false,
                    dx: -t * width * _direction,
                    child: leaving,
                  ),
                _layer(
                  identity: widget.identity,
                  onstage: true,
                  dx: (moving ? 1 - t : 0) * width * _direction,
                  child: widget.child,
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _layer({
    required Object identity,
    required bool onstage,
    required double dx,
    required Widget child,
  }) => KeyedSubtree(
    key: ValueKey(identity),
    child: _TabStage(
      visible: true,
      onstage: onstage,
      child: ExcludeFocus(
        excluding: !onstage,
        child: Transform.translate(
          offset: Offset(dx, 0),
          child: RepaintBoundary(
            child: TabTransition(animation: _controller, child: child),
          ),
        ),
      ),
    ),
  );
}
