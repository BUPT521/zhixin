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
///
/// 入口放在记录页标题栏的右侧，与安排页的“这周能做什么”同一种写法：次要
/// 按钮、`sm` 尺寸、图标在前。
class QuestionCaptureButton extends StatelessWidget {
  const QuestionCaptureButton({
    super.key,
    required this.onOpenLearning,
    required this.onOpenDiscussion,
  });

  final Future<void> Function(String questionId) onOpenLearning;
  final Future<void> Function(String conversationId) onOpenDiscussion;

  @override
  Widget build(BuildContext context) => forui.FButton(
    variant: forui.FButtonVariant.secondary,
    size: forui.FButtonSizeVariant.sm,
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
    // 图片没存进去时，帖子本身仍可以只靠题目文字保存；回执要等文字写入
    // 成功之后再给，不能先一步说已经保存。
    final imagesFailed = draft.photos.isNotEmpty && paths.isEmpty;
    if (imagesFailed && draft.stem.isEmpty) {
      if (!context.mounted) return;
      showToast(context, '图片没有存进去，先保存题目文字');
      return;
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
      if (imagesFailed) showToast(context, '图片没有存进去，题目文字已经保存');
      await onOpenLearning(id);
    } catch (error, stack) {
      try {
        await scope.data.versions.cleanupAttachmentPaths(paths);
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

  bool get _hasText => _stem.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final canSave = _hasText || _photos.isNotEmpty;
    return ZhixinDialogLayout(
      title: const Text('贴一道题'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 拍照与相册放在最上面：录入题目默认先点选，不必先展开“添加图片”
          // 再选来源，键盘输入排在后面。
          Row(
            children: [
              Expanded(
                child: forui.FButton(
                  key: const ValueKey('capture-take-photo'),
                  mainAxisSize: MainAxisSize.max,
                  onPress: _picking ? null : () => _pick(ImageSource.camera),
                  prefix: const Icon(FLucideIcons.camera),
                  child: const Text('拍照'),
                ),
              ),
              SizedBox(width: theme.space.sm),
              Expanded(
                child: forui.FButton(
                  key: const ValueKey('capture-pick-gallery'),
                  variant: forui.FButtonVariant.secondary,
                  mainAxisSize: MainAxisSize.max,
                  onPress: _picking ? null : () => _pick(ImageSource.gallery),
                  prefix: const Icon(FLucideIcons.images),
                  child: const Text('相册'),
                ),
              ),
            ],
          ),
          SizedBox(height: theme.space.gap),
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
          if (!_hasText && _photos.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: theme.space.sm),
              child: Text(
                '上传图片会先存成一条讨论，在讨论里可以直接开始作答；'
                '写下文字后还可以填写出处和材料摘录。',
                style: theme.text.bodySmall,
              ),
            ),
          // 输入第一个字之后才出现的出处与摘录：补上间距，按高度展开，不再
          // 让一块表单突然顶出来。
          ExpandReveal(
            visible: _hasText,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: theme.space.gap),
                forui.FTextField(
                  control: .managed(controller: _source),
                  label: const Text('出处（可选）'),
                  hint: '教材第 82 页第 8 题',
                ),
                SizedBox(height: theme.space.gap),
                forui.FTextField(
                  control: .managed(controller: _context),
                  label: const Text('材料摘录（可选）'),
                ),
              ],
            ),
          ),
          if (_photos.isNotEmpty) ...[
            SizedBox(height: theme.space.gap),
            CapturePhotoStrip(
              photos: _photos,
              onRemove: (index) => setState(() => _photos.removeAt(index)),
            ),
            Padding(
              padding: EdgeInsets.only(top: theme.space.xs),
              child: Text(
                '已添加 ${_photos.length}/2 张图片',
                style: theme.text.bodySmall,
              ),
            ),
          ],
          if (!canSave)
            Padding(
              padding: EdgeInsets.only(top: theme.space.xs),
              child: Text('填写题目文字或添加图片后保存。', style: theme.text.bodySmall),
            ),
        ],
      ),
      actions: [
        cancelZhixinButton(context),
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
