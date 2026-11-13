import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;

import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import 'package:path/path.dart' as p;

import 'failure_feedback.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';
import 'zhixin_toast.dart';

/// 取图之后让用户框住一道题，只保存框内的区域。
///
/// 系统图片选择器只提供预览，不能往里加框选；这一步放在取图之后、存图之前，
/// 首页提问、讨论页与「贴一道题」共用同一个页面。相机拍糊时不必退出重来，
/// 页面右上角的重拍会回到相机换一张。
class QuestionCropPage extends StatefulWidget {
  const QuestionCropPage({
    super.key,
    required this.sourcePath,
    required this.outputDir,
    this.allowRetake = false,
  });

  /// 系统选择器返回的原图路径。
  final String sourcePath;

  /// 裁剪结果写在这个目录里；它属于系统缓存，由系统按需清理。
  final String outputDir;

  /// 是否给出重拍入口；从相册选的图片没有可重拍的相机，传 false。
  final bool allowRetake;

  @override
  State<QuestionCropPage> createState() => _QuestionCropPageState();
}

/// 框选页的结束方式：确认裁剪后给出文件路径，点重拍时要求再拍一张，放弃时为 null。
class QuestionCropResult {
  const QuestionCropResult.confirmed(this.path) : retake = false;

  const QuestionCropResult.retake() : path = null, retake = true;

  /// 裁剪结果文件的路径，只在 [retake] 为 false 时存在。
  final String? path;

  final bool retake;
}

/// 打开框选页；用户取消时返回 null，确认时返回裁剪后文件的路径。
Future<QuestionCropResult?> showQuestionCropPage(
  BuildContext context, {
  required String sourcePath,
  required String outputDir,
  bool allowRetake = false,
}) {
  return Navigator.of(context).push<QuestionCropResult>(
    MaterialPageRoute<QuestionCropResult>(
      fullscreenDialog: true,
      builder: (_) => QuestionCropPage(
        sourcePath: sourcePath,
        outputDir: outputDir,
        allowRetake: allowRetake,
      ),
    ),
  );
}

class _QuestionCropPageState extends State<QuestionCropPage> {
  /// 选框的初始位置：留一点边，整张图默认几乎都选中。
  static const Rect _initialSelection = Rect.fromLTRB(0.06, 0.06, 0.94, 0.94);

  /// 选框四角与最小边长都按屏幕像素算，手指够得着。
  static const double _minSide = 56;
  static const double _handleReach = 32;

  ui.Image? _image;
  Uint8List? _bytes;
  String? _error;
  bool _saving = false;

  /// 选框用归一化坐标保存，换屏幕尺寸时不用重新换算。
  Rect _selection = _initialSelection;
  Rect? _imageRect;
  _DragState? _drag;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final bytes = await File(widget.sourcePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _bytes = bytes;
        _image = frame.image;
      });
    } catch (error, stack) {
      if (!mounted) return;
      setState(
        () => _error = describeFailure(
          context,
          error,
          stack,
          action: '读取这张图片',
          kind: 'question_crop_read',
          kept: '原图还在',
          next: '可以重新拍一张或换一张',
        ),
      );
    }
  }

  Rect _fitRect(ui.Image image, Size viewport) {
    final width = image.width.toDouble();
    final height = image.height.toDouble();
    final scale = math.min(viewport.width / width, viewport.height / height);
    final fitWidth = width * scale;
    final fitHeight = height * scale;
    return Rect.fromLTWH(
      (viewport.width - fitWidth) / 2,
      (viewport.height - fitHeight) / 2,
      fitWidth,
      fitHeight,
    );
  }

  Rect _toScreen(Rect normalized, Rect fit) {
    return Rect.fromLTRB(
      fit.left + normalized.left * fit.width,
      fit.top + normalized.top * fit.height,
      fit.left + normalized.right * fit.width,
      fit.top + normalized.bottom * fit.height,
    );
  }

  Rect _toNormalized(Rect screen, Rect fit) {
    return Rect.fromLTRB(
      (screen.left - fit.left) / fit.width,
      (screen.top - fit.top) / fit.height,
      (screen.right - fit.left) / fit.width,
      (screen.bottom - fit.top) / fit.height,
    );
  }

  void _startDrag(Offset point) {
    final fit = _imageRect;
    final image = _image;
    if (fit == null || image == null) return;
    if (!fit.contains(point)) return;

    final selection = _toScreen(_selection, fit);
    final corners = <(_DragMode, Offset)>[
      (_DragMode.topLeft, selection.topLeft),
      (_DragMode.topRight, selection.topRight),
      (_DragMode.bottomRight, selection.bottomRight),
      (_DragMode.bottomLeft, selection.bottomLeft),
    ];
    for (final (mode, corner) in corners) {
      if ((point - corner).distance <= _handleReach) {
        _drag = _DragState(mode, selection, point);
        return;
      }
    }
    if (selection.contains(point)) {
      _drag = _DragState(_DragMode.move, selection, point);
      return;
    }
    _drag = _DragState(_DragMode.create, selection, point);
    setState(() => _selection = _toNormalized(_minimumAt(point, fit), fit));
  }

  void _updateDrag(Offset point) {
    final drag = _drag;
    final fit = _imageRect;
    if (drag == null || fit == null) return;

    final target = Offset(
      _clampDouble(point.dx, fit.left, fit.right),
      _clampDouble(point.dy, fit.top, fit.bottom),
    );
    final Rect next;
    switch (drag.mode) {
      case _DragMode.move:
        final moved = drag.startSelection.shift(target - drag.startPoint);
        next = _keepInside(moved, fit);
      case _DragMode.create:
        next = _fromAnchor(drag.startPoint, target, fit);
      case _DragMode.topLeft:
      case _DragMode.topRight:
      case _DragMode.bottomLeft:
      case _DragMode.bottomRight:
        next = _resize(drag, target, fit);
    }
    setState(() => _selection = _toNormalized(next, fit));
  }

  Rect _keepInside(Rect rect, Rect fit) {
    final width = math.min(rect.width, fit.width);
    final height = math.min(rect.height, fit.height);
    final left = _clampDouble(rect.left, fit.left, fit.right - width);
    final top = _clampDouble(rect.top, fit.top, fit.bottom - height);
    return Rect.fromLTWH(left, top, width, height);
  }

  /// 从按下的那一点开始拉选框；不足最小边长时朝拖动方向补足。
  Rect _fromAnchor(Offset anchor, Offset target, Rect fit) {
    final dx = target.dx - anchor.dx;
    final dy = target.dy - anchor.dy;
    final minWidth = math.min(_minSide, fit.width);
    final minHeight = math.min(_minSide, fit.height);
    final width = math.max(dx.abs(), minWidth);
    final height = math.max(dy.abs(), minHeight);
    final left = dx >= 0 ? anchor.dx : anchor.dx - width;
    final top = dy >= 0 ? anchor.dy : anchor.dy - height;
    return _keepInside(Rect.fromLTWH(left, top, width, height), fit);
  }

  Rect _minimumAt(Offset point, Rect fit) {
    final width = math.min(_minSide, fit.width);
    final height = math.min(_minSide, fit.height);
    final left = _clampDouble(
      point.dx - width / 2,
      fit.left,
      fit.right - width,
    );
    final top = _clampDouble(
      point.dy - height / 2,
      fit.top,
      fit.bottom - height,
    );
    return Rect.fromLTWH(left, top, width, height);
  }

  Rect _resize(_DragState drag, Offset point, Rect fit) {
    final selection = drag.startSelection;
    final minWidth = math.min(_minSide, fit.width);
    final minHeight = math.min(_minSide, fit.height);
    var left = selection.left;
    var top = selection.top;
    var right = selection.right;
    var bottom = selection.bottom;
    switch (drag.mode) {
      case _DragMode.topLeft:
        left = math.min(point.dx, right - minWidth);
        top = math.min(point.dy, bottom - minHeight);
      case _DragMode.topRight:
        right = math.max(point.dx, left + minWidth);
        top = math.min(point.dy, bottom - minHeight);
      case _DragMode.bottomLeft:
        left = math.min(point.dx, right - minWidth);
        bottom = math.max(point.dy, top + minHeight);
      case _DragMode.bottomRight:
        right = math.max(point.dx, left + minWidth);
        bottom = math.max(point.dy, top + minHeight);
      case _DragMode.move:
      case _DragMode.create:
        break;
    }
    return Rect.fromLTRB(
      _clampDouble(left, fit.left, fit.right),
      _clampDouble(top, fit.top, fit.bottom),
      _clampDouble(right, fit.left, fit.right),
      _clampDouble(bottom, fit.top, fit.bottom),
    );
  }

  Future<void> _confirm() async {
    final bytes = _bytes;
    if (bytes == null || _saving) return;
    setState(() => _saving = true);
    final area = _selection;
    try {
      final cropped = await _cropInBackground(
        bytes,
        area.left,
        area.top,
        area.right,
        area.bottom,
      );
      if (cropped.isEmpty) throw const FormatException('裁剪结果为空');
      final name = 'crop-${DateTime.now().millisecondsSinceEpoch}.jpg';
      final target = File(p.join(widget.outputDir, name));
      await target.parent.create(recursive: true);
      await target.writeAsBytes(cropped, flush: true);
      if (!mounted) return;
      Navigator.of(context).pop(QuestionCropResult.confirmed(target.path));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      debugPrint('题目图片裁剪失败：$error');
      showToast(context, '裁剪失败，可以再试一次或者取消');
    }
  }

  /// 退出框选页回到相机；取图与再次进入框选由调用方接着完成。
  void _retake() {
    Navigator.of(context).pop(const QuestionCropResult.retake());
  }

  /// 在后台 isolate 里裁剪。
  ///
  /// 必须放在静态方法里：实例方法的闭包会把 State 一起带进 isolate，
  /// 而 State 里的 `ui.Image` 不能跨 isolate 传递。
  static Future<Uint8List> _cropInBackground(
    Uint8List bytes,
    double left,
    double top,
    double right,
    double bottom,
  ) {
    return Isolate.run(
      () => cropToJpeg(bytes, Rect.fromLTRB(left, top, right, bottom)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return DetailScaffold(
      header: ZhixinHeader(
        title: const Text('框选题目'),
        prefixes: [
          ZhixinHeaderAction(
            key: const ValueKey('question-crop-cancel'),
            tooltip: '放弃这张图',
            icon: FLucideIcons.x,
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
          ),
        ],
        actions: [
          if (widget.allowRetake)
            ZhixinHeaderAction(
              key: const ValueKey('question-crop-retake'),
              tooltip: '重拍',
              icon: FLucideIcons.camera,
              onPressed: _saving || _image == null ? null : _retake,
            ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: theme.space.pageInsets(
              top: theme.space.xs,
              bottom: theme.space.md,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                widget.allowRetake
                    ? '拖动四角框住一道题，图片模糊时可选择重拍。'
                    : '拖动四角框住一道题，只保留选中的区域。',
                style: theme.text.bodyMedium.copyWith(
                  color: theme.colors.onSurfaceVariant,
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: theme.space.pageInsets(top: 0, bottom: theme.space.md),
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: theme.colors.card,
                  borderRadius: theme.radius.card,
                  border: Border.all(color: theme.colors.outlineVariant),
                ),
                child: _stage(theme),
              ),
            ),
          ),
          _footer(),
        ],
      ),
    );
  }

  Widget _stage(ZhixinTheme theme) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: theme.text.bodyMedium,
              ),
              const SizedBox(height: 16),
              forui.FButton(
                variant: forui.FButtonVariant.ghost,
                mainAxisSize: MainAxisSize.min,
                onPress: () => Navigator.of(context).pop(),
                child: const Text('返回'),
              ),
            ],
          ),
        ),
      );
    }
    final image = _image;
    if (image == null) {
      return const Center(child: forui.FCircularProgress());
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final fit = _fitRect(image, constraints.biggest);
        _imageRect = fit;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) => _startDrag(details.localPosition),
          onPanUpdate: (details) => _updateDrag(details.localPosition),
          onPanEnd: (_) => _drag = null,
          onPanCancel: () => _drag = null,
          child: SizedBox.expand(
            child: CustomPaint(
              painter: _CropPainter(
                image: image,
                imageRect: fit,
                selection: _toScreen(_selection, fit),
                accent: theme.colors.primary,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _footer() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Row(
        children: [
          Expanded(
            child: forui.FButton(
              variant: forui.FButtonVariant.outline,
              mainAxisSize: MainAxisSize.min,
              onPress: _saving ? null : () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: forui.FButton(
              key: const ValueKey('question-crop-confirm'),
              mainAxisSize: MainAxisSize.min,
              onPress: _saving ? null : _confirm,
              prefix: _saving
                  ? const forui.FCircularProgress(
                      size: forui.FCircularProgressSizeVariant.sm,
                    )
                  : const Icon(FLucideIcons.check),
              child: const Text('使用这张图'),
            ),
          ),
        ],
      ),
    );
  }
}

enum _DragMode { move, topLeft, topRight, bottomRight, bottomLeft, create }

class _DragState {
  _DragState(this.mode, this.startSelection, this.startPoint);

  final _DragMode mode;
  final Rect startSelection;
  final Offset startPoint;
}

class _CropPainter extends CustomPainter {
  _CropPainter({
    required this.image,
    required this.imageRect,
    required this.selection,
    required this.accent,
  });

  final ui.Image image;
  final Rect imageRect;
  final Rect selection;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      imageRect,
      Paint()..filterQuality = FilterQuality.medium,
    );

    // 只压暗图片本身，卡片与页面留白保持原样。
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(imageRect)
      ..addRect(selection);
    canvas.drawPath(shade, Paint()..color = const Color(0x73000000));

    canvas.drawRect(
      selection,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = accent,
    );

    final fill = Paint()..color = Colors.white;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = accent;
    for (final corner in [
      selection.topLeft,
      selection.topRight,
      selection.bottomRight,
      selection.bottomLeft,
    ]) {
      canvas.drawCircle(corner, 10, fill);
      canvas.drawCircle(corner, 10, ring);
    }
  }

  @override
  bool shouldRepaint(covariant _CropPainter oldDelegate) =>
      oldDelegate.selection != selection ||
      oldDelegate.imageRect != imageRect ||
      oldDelegate.image != image ||
      oldDelegate.accent != accent;
}

/// 按归一化坐标裁出一块，并编码成 JPEG。
///
/// 长边超过 [maxSide] 时等比缩小，保证写进记录的文件仍符合 1600 像素的约定；
/// 坐标先夹回 0–1，正常拖动不会越界，异常输入也不会得到空图。
Uint8List cropToJpeg(
  Uint8List source,
  Rect area, {
  int quality = 88,
  int maxSide = 1600,
}) {
  final decoded = img.decodeImage(source);
  if (decoded == null) throw const FormatException('图片无法解码');
  final left = _clampInt(
    (area.left * decoded.width).floor(),
    0,
    decoded.width - 1,
  );
  final top = _clampInt(
    (area.top * decoded.height).floor(),
    0,
    decoded.height - 1,
  );
  final right = _clampInt(
    (area.right * decoded.width).ceil(),
    left + 1,
    decoded.width,
  );
  final bottom = _clampInt(
    (area.bottom * decoded.height).ceil(),
    top + 1,
    decoded.height,
  );

  var cropped = img.copyCrop(
    decoded,
    x: left,
    y: top,
    width: right - left,
    height: bottom - top,
  );
  final longest = math.max(cropped.width, cropped.height);
  if (longest > maxSide) {
    if (cropped.width >= cropped.height) {
      cropped = img.copyResize(cropped, width: maxSide);
    } else {
      cropped = img.copyResize(cropped, height: maxSide);
    }
  }
  return img.encodeJpg(cropped, quality: quality);
}

/// 把相机原图压到长边 [maxSide] 以内，作为框选页的输入。
///
/// 应用内相机按传感器能给的最高分辨率出图，整张解码要几十 MB；框选只留一小块，
/// 先压到取图上限，后面的预览、裁剪与保存都不至于占满内存。
Future<Uint8List> shrinkCaptureImage(
  Uint8List source, {
  int maxSide = 2048,
  int quality = 90,
}) {
  return Isolate.run(
    () => _shrinkJpeg(source, maxSide: maxSide, quality: quality),
  );
}

Uint8List _shrinkJpeg(
  Uint8List source, {
  required int maxSide,
  required int quality,
}) {
  final decoded = img.decodeImage(source);
  if (decoded == null) throw const FormatException('图片无法解码');
  var shrunk = decoded;
  final longest = math.max(shrunk.width, shrunk.height);
  if (longest > maxSide) {
    shrunk = shrunk.width >= shrunk.height
        ? img.copyResize(shrunk, width: maxSide)
        : img.copyResize(shrunk, height: maxSide);
  }
  return img.encodeJpg(shrunk, quality: quality);
}

int _clampInt(int value, int lower, int upper) {
  if (value < lower) return lower;
  if (value > upper) return upper;
  return value;
}

double _clampDouble(num value, double lower, double upper) {
  if (value < lower) return lower;
  if (value > upper) return upper;
  return value.toDouble();
}
