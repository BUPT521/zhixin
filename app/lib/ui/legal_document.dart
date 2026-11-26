import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import 'failure_feedback.dart';
import 'legal_texts.dart';
import 'markdown_text.dart';
import 'navigation.dart';
import 'theme.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';

/// 应用内的用户须知或隐私政策正文。
///
/// 正文与 `docs/用户须知与隐私政策草稿.md` 同步，草稿定稿时两处一起改。用户
/// 须知页底部可以再打开隐私政策；用户还没有同意时，这一页底部给一个同意入口，
/// 同意之后恢复联网功能。
class LegalDocumentPage extends StatefulWidget {
  const LegalDocumentPage.terms({super.key, this.allowAgree = true})
    : title = userTermsTitle,
      text = userTermsText,
      showsPrivacyLink = true;

  const LegalDocumentPage.privacy({super.key})
    : title = privacyPolicyTitle,
      text = privacyPolicyText,
      showsPrivacyLink = false,
      allowAgree = false;

  final String title;
  final String text;

  /// 用户须知页底部给一个跳到隐私政策的入口。
  final bool showsPrivacyLink;

  /// 还没同意时是否在页底给同意入口；引导第一步自己带勾选框，打开文档时为假。
  final bool allowAgree;

  @override
  State<LegalDocumentPage> createState() => _LegalDocumentPageState();
}

class _LegalDocumentPageState extends State<LegalDocumentPage> {
  bool _agreeing = false;
  bool _agreedNow = false;
  String? _error;

  Future<void> _agree() async {
    if (_agreeing) return;
    setState(() {
      _agreeing = true;
      _error = null;
    });
    try {
      await AppScope.of(context).agreeToTerms();
      if (!mounted) return;
      setState(() => _agreedNow = true);
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _error = describeFailure(
          context,
          error,
          stack,
          action: '保存用户须知的同意状态',
          kind: 'onboarding_consent',
          kept: '仍然只在本机使用',
          next: '可以再点一次同意',
        );
      });
    } finally {
      if (mounted) setState(() => _agreeing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final canAgree = widget.allowAgree && !AppScope.of(context).networkAllowed;
    return DetailScaffold(
      header: ZhixinHeader(title: Text(widget.title), showBack: true),
      child: ListView(
        padding: theme.space.pageInsets(bottom: 48),
        children: [
          MarkdownText(widget.text),
          SizedBox(height: theme.space.lg),
          if (widget.showsPrivacyLink) ...[
            forui.FButton(
              variant: forui.FButtonVariant.outline,
              mainAxisSize: MainAxisSize.min,
              onPress: () => openPrivacyPolicy(context),
              child: const Text('查看隐私政策'),
            ),
            SizedBox(height: theme.space.lg),
          ],
          if (canAgree)
            forui.FCard(
              child: Padding(
                padding: EdgeInsets.all(theme.space.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _agreedNow
                          ? '已经同意当前版本，可以返回继续使用；匿名使用统计、'
                                '更新检查与登录已恢复。'
                          : '你现在只在本机使用，匿名使用统计、更新检查与登录都已停用。'
                                '同意之后恢复这些联网功能，学习记录不受影响。',
                      style: theme.text.bodyMedium,
                    ),
                    if (_error case final error?) ...[
                      SizedBox(height: theme.space.sm),
                      InlineNotice(message: error),
                    ],
                    if (!_agreedNow) ...[
                      SizedBox(height: theme.space.md),
                      forui.FButton(
                        mainAxisSize: MainAxisSize.max,
                        onPress: _agreeing ? null : _agree,
                        child: Text(_agreeing ? '正在保存…' : '同意并恢复联网'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
