import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../app_scope.dart';
import '../domain/models/memory.dart';
import '../domain/models/memory_draft.dart' show memoryContentLimit;
import 'date_time_dialogs.dart';
import 'format.dart';
import 'zhixin_dialog.dart';
import 'zhixin_select.dart';

/// 记忆编辑框返回的草稿：类型、正文与有效期。
class MemoryDraft {
  const MemoryDraft({
    required this.kind,
    required this.content,
    this.validUntil,
  });

  final MemoryKind kind;
  final String content;
  final DateTime? validUntil;
}

/// 记一条或修改一条记忆的弹窗；记忆页与记忆查找页共用这一份。
///
/// 类别只有情景、语义、程序三项（ADR-0051 决定第 1 条）：情景是发生过的一件事，
/// 语义是稳定的事实与限制，程序是该怎么做的做法。用户手写不从内容推断程序类，
/// 新建时默认语义。
class MemoryDialog extends StatefulWidget {
  const MemoryDialog({super.key, this.memory});

  /// 为空时是新建；有值时按原有内容填好，保存后走修改。
  final Memory? memory;

  @override
  State<MemoryDialog> createState() => _MemoryDialogState();
}

class _MemoryDialogState extends State<MemoryDialog> {
  /// 新建时默认语义：用户手写的偏好与限制按内容归语义（ADR-0051 第 1 条）。
  late MemoryKind _kind = widget.memory?.kind ?? MemoryKind.semantic;
  late final TextEditingController _content = TextEditingController(
    text: widget.memory?.content ?? '',
  );
  DateTime? _until;
  String? _contentError;

  @override
  void initState() {
    super.initState();
    _until = widget.memory?.validUntil;
  }

  @override
  void dispose() {
    _content.dispose();
    super.dispose();
  }

  Future<void> _pickUntil() async {
    final now = AppScope.of(context).timePolicy.now;
    final picked = await showZhixinDatePicker(
      context: context,
      initialDate: _until != null && _until!.isBefore(now)
          ? now
          : _until ?? now,
      firstDate: now,
      lastDate: DateTime(now.year + 10, now.month, now.day),
    );
    if (mounted && picked != null) setState(() => _until = picked);
  }

  void _save() {
    final content = _content.text.trim();
    if (content.isEmpty) {
      setState(() => _contentError = '先写一句要记住的内容再保存。');
      return;
    }
    // 写入上限在步骤 5 之前保持 200 字，与工具写入和提示词的单条截断同一个
    // 常量；表的 CHECK 放到 2000 字是为步骤 5 的总预算预留（ADR-0051）。
    if (content.runes.length > memoryContentLimit) {
      setState(() => _contentError = '一条记忆最多 $memoryContentLimit 字，长内容请拆成几条。');
      return;
    }
    Navigator.of(context)
        .pop(MemoryDraft(kind: _kind, content: content, validUntil: _until));
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return ZhixinDialogLayout(
      title: Text(widget.memory == null ? '记一条' : '修改记忆'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZhixinSelect<MemoryKind>(
            value: _kind,
            label: '类型',
            options: {
              for (final kind in MemoryKind.values)
                if (kind != MemoryKind.unknown) kind: kind.label,
            },
            onChange: (value) {
              if (value != null) setState(() => _kind = value);
            },
          ),
          SizedBox(height: theme.space.gap),
          forui.FTextField(
            control: .managed(
              controller: _content,
              onChange: (_) {
                if (_contentError != null) {
                  setState(() => _contentError = null);
                }
              },
            ),
            minLines: 2,
            maxLines: 4,
            label: const Text('内容'),
          ),
          if (_contentError != null)
            Padding(
              padding: EdgeInsets.only(top: theme.space.xs),
              child: Text(
                _contentError!,
                style: theme.text.bodySmall.copyWith(color: theme.colors.error),
              ),
            ),
          SizedBox(height: theme.space.gap),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '有效期',
                style: theme.text.labelMedium.copyWith(
                  color: theme.colors.onSurfaceVariant,
                ),
              ),
              SizedBox(height: theme.space.xs),
              Wrap(
                spacing: theme.space.xs,
                runSpacing: theme.space.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  forui.FButton(
                    variant: forui.FButtonVariant.outline,
                    size: forui.FButtonSizeVariant.sm,
                    mainAxisSize: MainAxisSize.min,
                    onPress: _pickUntil,
                    prefix: const Icon(FLucideIcons.calendarDays, size: 16),
                    child: Text(
                      _until == null ? '长期有效' : '有效至 ${dateText(_until)}',
                    ),
                  ),
                  if (_until != null)
                    forui.FButton(
                      variant: forui.FButtonVariant.ghost,
                      size: forui.FButtonSizeVariant.sm,
                      mainAxisSize: MainAxisSize.min,
                      onPress: () => setState(() => _until = null),
                      child: const Text('改回长期'),
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
      actions: [
        cancelZhixinButton(context),
        forui.FButton(
          mainAxisSize: MainAxisSize.min,
          onPress: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
