import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';
import 'workspace_widgets.dart';
import 'zhixin_icon_button.dart';

/// 讨论页顶部的查找条：输入关键词、看命中数，跳到上一处或下一处。
///
/// 匹配由页面在本地完成，这里只负责输入与操作；[failure] 表示这次读取消息
/// 没有完成，重试入口就地给出，输入区与时间线都不受影响。
class DiscussionSearchBar extends StatelessWidget {
  const DiscussionSearchBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.query,
    required this.matchCount,
    required this.matchIndex,
    required this.loading,
    required this.failure,
    required this.onSubmitted,
    required this.onPrevious,
    required this.onNext,
    required this.onRetry,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// 输入框里当前的文字；用来区分空查询与“没有找到”。
  final String query;

  /// 命中的消息条数与当前是第几处（从 0 起，没有命中时为 -1）。
  final int matchCount;
  final int matchIndex;

  final bool loading;
  final String? failure;

  final ValueChanged<String> onSubmitted;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onRetry;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final trimmed = query.trim();
    final hasMatches = matchCount > 0;
    return Padding(
      key: const ValueKey('discussion-search-bar'),
      padding: theme.space.pageInsets(
        top: theme.space.xs,
        bottom: theme.space.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: forui.FTextField(
                  key: const ValueKey('discussion-search-field'),
                  control: .managed(controller: controller),
                  focusNode: focusNode,
                  textInputAction: TextInputAction.search,
                  onSubmit: onSubmitted,
                  hint: '在这条讨论里查找',
                ),
              ),
              SizedBox(width: theme.space.xs),
              if (hasMatches)
                Padding(
                  padding: EdgeInsets.only(right: theme.space.xs),
                  child: Text(
                    '${matchIndex + 1}/$matchCount',
                    key: const ValueKey('discussion-search-count'),
                    style: theme.text.labelLarge,
                  ),
                ),
              ZhixinIconButton(
                key: const ValueKey('discussion-search-previous'),
                tooltip: '上一处',
                onPressed: hasMatches ? onPrevious : null,
                icon: FLucideIcons.chevronUp,
              ),
              ZhixinIconButton(
                key: const ValueKey('discussion-search-next'),
                tooltip: '下一处',
                onPressed: hasMatches ? onNext : null,
                icon: FLucideIcons.chevronDown,
              ),
              ZhixinIconButton(
                key: const ValueKey('discussion-search-close'),
                tooltip: '关闭查找',
                onPressed: onClose,
                icon: FLucideIcons.x,
              ),
            ],
          ),
          Padding(
            padding: EdgeInsets.only(top: theme.space.xs),
            child: _status(theme, trimmed, hasMatches),
          ),
        ],
      ),
    );
  }

  /// 空查询、读取中、读取失败与没有命中各用一条说明；命中时只留计数。
  Widget _status(ZhixinTheme theme, String trimmed, bool hasMatches) {
    final failure = this.failure;
    if (failure != null) {
      return InlineNotice(message: failure, onRetry: onRetry);
    }
    if (loading) {
      return Text('正在查找…', style: theme.text.bodySmall);
    }
    if (trimmed.isEmpty) {
      return Text('输入关键词，只在本条讨论的消息里查找。', style: theme.text.bodySmall);
    }
    if (!hasMatches) {
      return Text(
        '没有找到「$trimmed」；可以换一个词再试。',
        key: const ValueKey('discussion-search-empty'),
        style: theme.text.bodySmall,
      );
    }
    return const SizedBox.shrink();
  }
}
