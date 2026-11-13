import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import 'package:image_picker/image_picker.dart';

import '../app_scope.dart';
import 'capture_entry.dart';
import 'failure_feedback.dart';
import 'voice_input_button.dart';
import 'zhixin_dialog.dart';
import 'zhixin_toast.dart';

/// 从记录页录入题目原文与出处。
class QuestionCaptureButton extends StatelessWidget {
  const QuestionCaptureButton({
    super.key,
    required this.onOpenLearning,
    required this.onOpenDiscussion,
  });

  final Future<void> Function(int questionId) onOpenLearning;
  final Future<void> Function(int conversationId) onOpenDiscussion;

  @override
  Widget build(BuildContext context) => forui.FButton(
    variant: forui.FButtonVariant.secondary,
    mainAxisSize: MainAxisSize.min,
    onPress: () => _capture(context),
    prefix: const Icon(FLucideIcons.imagePlus),
    child: const Text('贴一道题'),
  );

  Future<void> _capture(BuildContext context) async {
    final scope = AppScope.of(context);
    final draft = await showZhixinDialog<_CaptureDraft>(
      context: context,
      builder: (_) => const _CaptureSheet(),
    );
    if (draft == null || !context.mounted) return;

    final paths = await persistCaptureImages(
      draft.photos,
      scope.paths.imagesDir,
    );
    // 图片已经复制进应用目录，缓存里的那张不用再留。
    await deleteTemporaryCaptures(draft.photos);
    if (draft.photos.isNotEmpty && paths.isEmpty) {
      if (!context.mounted) return;
      if (draft.stem.isEmpty) {
        showToast(context, '图片保存失败，请填写题目文字后再保存');
        return;
      }
      showToast(context, '图片保存失败，题目文字已保存');
    }

    try {
      if (draft.stem.isEmpty) {
        // 没有文字时先开一条讨论：图片就是原文，可以直接在讨论里开始作答。
        final result = await scope.chat.discussion.reply(imagePaths: paths);
        if (!context.mounted) return;
        await onOpenDiscussion(result.userMessage.conversationId);
        return;
      }
      final id = await scope.chat.learning.capture(
        stem: draft.stem,
        sourceRef: draft.sourceRef,
        contextText: draft.contextText,
        imagePaths: paths,
      );
      if (!context.mounted) return;
      await onOpenLearning(id);
    } catch (error, stack) {
      try {
        await scope.cleanupAttachmentPaths(paths);
      } catch (_) {
        // 后续启动仍会清理失去引用的图片；清理失败不替代保存错误。
      }
      if (!context.mounted) return;
      final message = describeFailure(
        context,
        error,
        stack,
        action: '保存这道题',
        kind: 'question_capture',
        kept: '还没有写入题目',
        next: '可以再试一次',
      );
      showToast(context, message);
    }
  }
}

class _CaptureDraft {
  const _CaptureDraft({
    required this.stem,
    this.sourceRef,
    this.contextText,
    this.photos = const [],
  });

  final String stem;
  final String? sourceRef;
  final String? contextText;
  final List<XFile> photos;
}

class _CaptureSheet extends StatefulWidget {
  const _CaptureSheet();

  @override
  State<_CaptureSheet> createState() => _CaptureSheetState();
}

class _CaptureSheetState extends State<_CaptureSheet> {
  final _stem = TextEditingController();
  final _source = TextEditingController();
  final _context = TextEditingController();
  final List<XFile> _photos = [];

  /// 取图与框选是一段异步流程，期间再点一次会同时开两个相机。
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    // 语音输入直接写 controller，不经过 onChanged；统一在这里刷新“有没有文字”。
    _stem.addListener(_onStemChanged);
  }

  void _onStemChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _stem.removeListener(_onStemChanged);
    _stem.dispose();
    _source.dispose();
    _context.dispose();
    super.dispose();
  }

  Future<void> _pick(ImageSource source) async {
    if (_picking) return;
    if (_photos.length >= 2) {
      showToast(context, '最多添加两张图片，请先移除一张');
      return;
    }
    setState(() => _picking = true);
    try {
      final picked = await pickQuestionImage(context, source);
      if (picked != null && mounted) {
        setState(() => _photos.add(picked));
      }
    } catch (error) {
      if (!mounted) return;
      showToast(context, captureErrorText(error));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _choosePhoto() async {
    final source = await chooseCaptureSource(context);
    if (source == null || !mounted) return;
    await _pick(source);
  }

  bool get _hasText => _stem.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final canSave = _hasText || _photos.isNotEmpty;
    return ZhixinDialogLayout(
      title: const Text('贴一道题'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          forui.FTextField(
            control: .managed(controller: _stem),
            minLines: 3,
            maxLines: 8,
            label: const Text('题目内容（文字或图片）'),
            hint: '填写关键条件和问题',
            suffixBuilder: (_, style, _) => VoiceInputButton(
              controller: _stem,
              style: style.clearButtonStyle,
            ),
          ),
          if (_hasText) ...[
            forui.FTextField(
              control: .managed(controller: _source),
              label: const Text('出处（可选）'),
              hint: '教材第 82 页第 8 题',
            ),
            const SizedBox(height: 8),
            forui.FTextField(
              control: .managed(controller: _context),
              label: const Text('材料摘录（可选）'),
            ),
          ] else if (_photos.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '上传图片会先存成一条讨论，在讨论里可以直接开始作答；'
                  '写下文字后还可以填写出处和材料摘录。',
                  style: context.zhixin.text.bodySmall,
                ),
              ),
            ),
          const SizedBox(height: 8),
          if (_photos.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: CapturePhotoStrip(
                photos: _photos,
                onRemove: (index) => setState(() => _photos.removeAt(index)),
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              forui.FButton(
                variant: forui.FButtonVariant.ghost,
                mainAxisSize: MainAxisSize.min,
                onPress: _picking ? null : _choosePhoto,
                prefix: const Icon(FLucideIcons.imagePlus),
                child: const Text('添加图片'),
              ),
              if (_photos.isNotEmpty)
                Text(
                  '${_photos.length}/2',
                  style: context.zhixin.text.bodySmall,
                ),
            ],
          ),
          if (!canSave)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '填写题目文字或添加图片后保存。',
                  style: context.zhixin.text.bodySmall,
                ),
              ),
            ),
        ],
      ),
      actions: [
        forui.FButton(
          variant: forui.FButtonVariant.ghost,
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        forui.FButton(
          mainAxisSize: MainAxisSize.min,
          onPress: canSave
              ? () {
                  final stem = _stem.text.trim();
                  Navigator.of(context).pop(
                    _CaptureDraft(
                      stem: stem,
                      sourceRef: _source.text.trim().isEmpty
                          ? null
                          : _source.text.trim(),
                      contextText: _context.text.trim().isEmpty
                          ? null
                          : _context.text.trim(),
                      photos: List<XFile>.of(_photos),
                    ),
                  );
                }
              : null,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
