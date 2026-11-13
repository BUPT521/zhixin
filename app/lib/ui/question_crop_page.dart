import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'failure_feedback.dart';
import 'theme.dart';
import 'zhixin_header.dart';
import 'zhixin_toast.dart';

/// 取图之后让用户框住一道题，只保存框内的区域。
///
/// 系统图片选择器只提供预览，不能往里加框选；这一步放在取图之后、存图之前，
/// 首页提问、讨论页与「贴一道题」共用同一个页面。框选交互使用
/// `crop_your_image` 的 [Crop]，裁剪与编码在它自己的 compute 里完成；相机拍糊
/// 时不必退出重来，页面右上角的重拍会回到相机换一张。
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
  final CropController _controller = CropController();

  Uint8List? _bytes;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await File(widget.sourcePath).readAsBytes();
      if (!mounted) return;
      setState(() => _bytes = bytes);
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

  Future<void> _confirm() async {
    if (_bytes == null || _saving) return;
    setState(() => _saving = true);
    _controller.crop();
  }

  Future<void> _onCropped(CropResult result) async {
    if (!mounted) return;
    switch (result) {
      case CropSuccess(:final croppedImage):
        try {
          final bytes = await _finalize(croppedImage);
          if (bytes.isEmpty) throw const FormatException('裁剪结果为空');
          final name = 'crop-${DateTime.now().millisecondsSinceEpoch}.jpg';
          final target = File(p.join(widget.outputDir, name));
          await target.parent.create(recursive: true);
          await target.writeAsBytes(bytes, flush: true);
          if (!mounted) return;
          Navigator.of(context).pop(QuestionCropResult.confirmed(target.path));
        } catch (error) {
          if (!mounted) return;
          setState(() => _saving = false);
          debugPrint('题目图片裁剪失败：$error');
          showToast(context, '裁剪失败，可以再试一次或者取消');
        }
      case CropFailure(:final cause):
        if (!mounted) return;
        setState(() => _saving = false);
        debugPrint('题目图片裁剪失败：$cause');
        showToast(context, '裁剪失败，可以再试一次或者取消');
    }
  }

  /// 统一裁剪结果的格式：JPEG、长边不超过 1600，写进记录的文件大小可控。
  static Future<Uint8List> _finalize(Uint8List source) {
    return Isolate.run(() {
      final decoded = img.decodeImage(source);
      if (decoded == null) throw const FormatException('图片无法解码');
      var cropped = decoded;
      final longest = math.max(cropped.width, cropped.height);
      if (longest > 1600) {
        cropped = cropped.width >= cropped.height
            ? img.copyResize(cropped, width: 1600)
            : img.copyResize(cropped, height: 1600);
      }
      return Uint8List.fromList(img.encodeJpg(cropped, quality: 88));
    });
  }

  /// 退出框选页回到相机；取图与再次进入框选由调用方接着完成。
  void _retake() {
    Navigator.of(context).pop(const QuestionCropResult.retake());
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return forui.FScaffold(
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
              onPressed: _saving || _bytes == null ? null : _retake,
            ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                widget.allowRetake
                    ? '拖动四角框住一道题，框外的部分不会保存；拍糊了就点右上角重拍。'
                    : '拖动四角框住一道题，框外的部分不会保存。',
                style: theme.text.bodySmall.copyWith(
                  color: theme.colors.onSurfaceVariant,
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
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
    final bytes = _bytes;
    if (bytes == null) {
      return const Center(child: forui.FCircularProgress());
    }
    return Crop(
      image: bytes,
      controller: _controller,
      onCropped: _onCropped,
      interactive: true,
      baseColor: theme.colors.card,
      maskColor: const Color(0x73000000),
      progressIndicator: const forui.FCircularProgress(),
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
              onPress: _saving || _bytes == null ? null : _confirm,
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
