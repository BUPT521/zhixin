import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'theme.dart';

/// 一行里的按钮与输入框：按钮宽度取其中最宽的一个（不少于一个控件的 44），
/// 短标签也占同样宽度，按钮标签切换前后整行不重新排布；输入框取 [trailing]
/// 之后剩下的宽度，与按钮同高。
///
/// 按钮去掉自身的左右留白，改由这里按 [padding] 给出，各按钮的边到文字距离
/// 一致；相邻两个之间按 [spacing] 留出间隔。
class RhsRow extends StatefulWidget {
  const RhsRow({
    required this.leading,
    required this.trailing,
    this.spacing = 8,
    this.padding = 12,
    super.key,
  });

  /// 占满剩余宽度的控件，例如查找框；再窄也先保住一个控件的高度。
  final Widget leading;

  /// 靠右的按钮，按最长的一个定宽。
  final List<Widget> trailing;

  final double spacing;
  final double padding;

  @override
  State<RhsRow> createState() => _RhsRowState();
}

class _RhsRowState extends State<RhsRow> {
  /// 每个按钮量到的内容宽度加上两边的留白；有新的更宽的按钮时整行一起变宽。
  final _extents = <int, double>{};
  double _width = ZhixinSpace.controlHeight;

  @override
  void initState() {
    super.initState();
    _reset();
  }

  @override
  void didUpdateWidget(RhsRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trailing.length != widget.trailing.length ||
        oldWidget.padding != widget.padding) {
      _reset();
    }
  }

  void _reset() {
    _extents.clear();
    _width = ZhixinSpace.controlHeight;
  }

  void _measured(int index, double content) {
    final extent = content + widget.padding * 2;
    final current = _extents[index];
    if (current != null && (current - extent).abs() < 0.5) return;
    _extents[index] = extent;
    final widest = _extents.values.reduce((a, b) => a > b ? a : b);
    if (widest > _width) {
      if (mounted) {
        setState(() => _width = widest);
      } else {
        _width = widest;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final trailing = widget.trailing;
    return Row(
      children: [
        Expanded(child: widget.leading),
        for (final (index, child) in trailing.indexed) ...[
          SizedBox(width: widget.spacing),
          SizedBox(
            width: _width,
            height: ZhixinSpace.controlHeight,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.padding),
              child: _Measured(
                onMeasure: (content) => _measured(index, content),
                child: child,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 量一个子组件的自然宽度，在布局结束后交给 [onMeasure]；子组件不受外层宽度
/// 约束，按内容自己的宽度渲染，外层再按量到的宽度给它定宽。
class _Measured extends StatelessWidget {
  const _Measured({required this.child, required this.onMeasure});

  final Widget child;
  final ValueChanged<double> onMeasure;

  @override
  Widget build(BuildContext context) => _ReportSize(
    onMeasure: onMeasure,
    child: OverflowBox(
      alignment: AlignmentDirectional.topStart,
      minWidth: 0,
      maxWidth: double.infinity,
      child: child,
    ),
  );
}

/// 布局之后把子组件的宽度报给上层，尺寸没变就不再报。
class _ReportSize extends SingleChildRenderObjectWidget {
  const _ReportSize({required this.onMeasure, required Widget super.child});

  final ValueChanged<double> onMeasure;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderReportSize(onMeasure);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderReportSize renderObject,
  ) {
    renderObject.onMeasure = onMeasure;
  }
}

class _RenderReportSize extends RenderProxyBox {
  _RenderReportSize(this.onMeasure);

  ValueChanged<double> onMeasure;
  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    final width = size.width;
    if (width == double.infinity || width == _reported) return;
    _reported = width;
    final report = onMeasure;
    // 布局过程中不能重建，报告挪到这一帧结束之后。
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => report(width));
    } else {
      report(width);
    }
  }
}

/// [RhsRow] 里按钮的样式：去掉按钮自身的左右留白与最小宽度，宽度由外层给定，
/// 文字居中；高度仍是 [ZhixinSpace.controlHeight]。
forui.FButtonStyleDelta fittedButtonStyle() => forui.FButtonStyleDelta.delta(
  contentStyle: forui.FButtonContentStyleDelta.delta(
    padding: const forui.EdgeInsetsGeometryDelta.value(EdgeInsets.zero),
    constraints: const BoxConstraints(minWidth: 0, minHeight: 44),
  ),
);
