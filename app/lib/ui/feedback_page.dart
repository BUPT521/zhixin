/// 应用内反馈页：正文必填，联系邮箱可选，可以附带本机诊断摘要；不要求登录。
///
/// 字段长度与格式先按服务端口径在本地核对一次，最终以服务端为准；成功后显示
/// 回执编号与时间，限流与网络失败保留已填写的内容并给重试。诊断摘要只提交
/// 用户在页面上看过的几行（启动次数与最近几条错误的来源、时间与摘要），不自动
/// 上传整份诊断记录（ADR-0025）。
library;

import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import '../application/feedback_service.dart';
import '../domain/models/server_models.dart';
import '../domain/models/diagnostics.dart';
import '../domain/rules/text.dart';
import '../domain/rules/time_format.dart';
import '../platform/app_info.dart';
import 'failure_feedback.dart';
import 'theme.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';

/// 反馈正文与服务端口径一致：去掉两端空白后 1 至 4000 字。
const int feedbackContentLimit = 4000;

/// 诊断摘要只包含最近几条错误，服务端按 65536 字节限制长度。
const int feedbackDiagnosticsEntries = 5;

class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key, this.submit});

  /// 提交实现；测试换成固定回执或固定异常，生产走账号服务里的反馈入口。
  final FeedbackSubmitter? submit;

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  final _content = TextEditingController();
  final _contact = TextEditingController();

  bool _includeDiagnostics = false;
  bool _sending = false;

  /// 最近一次提交没通过时就地说明；[retryable] 为真时给“重试”按钮。
  String? _error;
  bool _retryable = false;

  /// 成功之后的回执；提交新的一条之前一直显示。
  ServerFeedbackReceipt? _receipt;

  CrashSummary? _summary;
  bool _summaryLoaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_summaryLoaded) return;
    _summaryLoaded = true;
    try {
      _summary = AppScope.of(context).crashLog.summary();
    } catch (_) {
      // 读不到本机诊断时按没有摘要处理，反馈本身照常可以提交。
    }
  }

  @override
  void dispose() {
    _content.dispose();
    _contact.dispose();
    super.dispose();
  }

  /// 页面上预览、开关打开时提交的那几行诊断摘要。
  String get _diagnosticsText {
    final summary = _summary;
    if (summary == null) return '';
    final lines = <String>['启动次数：${summary.launches}'];
    if (summary.crashes.isEmpty) {
      lines.add('本机诊断里没有记录到错误。');
      return lines.join('\n');
    }
    lines.add(
      '最近 ${summary.crashes.length} 条错误（最多带 $feedbackDiagnosticsEntries 条）：',
    );
    for (final entry in summary.crashes.take(feedbackDiagnosticsEntries)) {
      final message = truncateCodePoints(entry.message, 120);
      lines.add('${formatDateTime(entry.at)} · ${entry.kind} · $message');
    }
    return lines.join('\n');
  }

  /// 提交前的本地核对；不合法时返回给用户看的一句话。
  String? _validate() {
    final content = _content.text.trim();
    final length = content.runes.length;
    if (length == 0) return '请先写反馈内容';
    if (length > feedbackContentLimit) {
      return '反馈内容最多 $feedbackContentLimit 字，请精简之后再提交';
    }
    final contact = _contact.text.trim();
    if (contact.isNotEmpty && !looksLikeEmailAddress(contact)) {
      return '联系邮箱格式不正确，请检查或留空';
    }
    return null;
  }

  Future<void> _submit() async {
    if (_sending) return;
    final invalid = _validate();
    if (invalid != null) {
      setState(() {
        _error = invalid;
        _retryable = false;
      });
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
      _retryable = false;
    });
    final draft = FeedbackDraft(
      content: _content.text.trim(),
      contact: _contact.text.trim(),
      diagnostics: _includeDiagnostics ? _diagnosticsText : '',
      appVersion: appVersion,
    );
    try {
      final receipt = await (widget.submit ?? _defaultSubmit)(draft);
      if (!mounted) return;
      setState(() {
        _receipt = receipt;
        _error = null;
        // 提交成功之后清空输入，回执留在页面上；联系邮箱也清掉，避免带到下一条。
        _content.clear();
        _contact.clear();
      });
    } on ServerProblem catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _problemMessage(error);
        _retryable = error.code == 'offline';
      });
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _error = describeFailure(
          context,
          error,
          stack,
          action: '提交反馈',
          kind: 'feedback_submit',
          kept: '已经填写的内容还在',
          next: '可以再试一次',
        );
        _retryable = true;
      });
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<ServerFeedbackReceipt> _defaultSubmit(FeedbackDraft draft) =>
      AppScope.of(context).accountServices.feedback.submit(draft);

  /// 服务端拒绝时按契约的 `code` 说明；限流带上服务端给的等待秒数。
  String _problemMessage(ServerProblem error) => switch (error.code) {
    'rate_limited' =>
      error.retryAfterSeconds == null
          ? '提交过于频繁，可以稍后再试；已经填写的内容还在'
          : '提交过于频繁，请 ${error.retryAfterSeconds} 秒后再试；已经填写的内容还在',
    'offline' => '无法连接服务端，反馈没有提交；已经填写的内容还在，检查网络后可以重试',
    'invalid_request' => '服务端没有接受这次反馈，请检查正文与联系邮箱',
    'payload_too_large' => '反馈内容超过服务端允许的大小，请精简之后再提交',
    'unavailable' || 'upstream_failed' => '服务端暂时不可用，反馈没有提交；可以稍后再试',
    _ => '服务端没有完成这次提交；已经填写的内容还在',
  };

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return DetailScaffold(
      header: const ZhixinHeader(title: Text('反馈'), showBack: true),
      child: ListView(
        padding: theme.space.pageInsets(top: theme.space.lg),
        children: [
          if (_receipt != null) ...[
            _receiptCard(theme, _receipt!),
            SizedBox(height: theme.space.md),
          ],
          const SectionHeading(
            title: '问题与建议',
            subtitle: '写清遇到的情况与期望的结果；不要求登录，也不绑定账号。',
            first: true,
          ),
          forui.FCard(
            child: Padding(
              padding: EdgeInsets.all(theme.space.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  forui.FTextField(
                    control: .managed(controller: _content),
                    enabled: !_sending,
                    minLines: 5,
                    maxLines: 12,
                    label: const Text('正文'),
                    hint: '例如：在记录页按“下一步”没有反应，重开之后仍然一样',
                  ),
                  SizedBox(height: theme.space.gap),
                  forui.FTextField(
                    control: .managed(controller: _contact),
                    enabled: !_sending,
                    keyboardType: TextInputType.emailAddress,
                    label: const Text('联系邮箱（可选）'),
                    hint: 'you@example.com',
                    description: const Text('可以不填；填写时只用于回复这条反馈。'),
                  ),
                  SizedBox(height: theme.space.gap),
                  forui.FSwitch(
                    label: const Text('附带本机诊断摘要'),
                    description: const Text(
                      '只提交下面预览的几行：启动次数与最近几条错误的来源、时间与摘要；'
                      '不含学习内容、文件路径与密钥，也不上传整份诊断记录。',
                    ),
                    value: _includeDiagnostics,
                    onChange: (value) {
                      if (_sending) return;
                      setState(() => _includeDiagnostics = value);
                    },
                  ),
                  if (_includeDiagnostics) ...[
                    SizedBox(height: theme.space.sm),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colors.surfaceContainerHigh,
                        borderRadius: theme.radius.card,
                      ),
                      child: Padding(
                        padding: EdgeInsets.all(theme.space.md),
                        child: Text(
                          _diagnosticsText,
                          style: theme.text.bodySmall,
                        ),
                      ),
                    ),
                  ],
                  SizedBox(height: theme.space.md),
                  Text(
                    '提交时会自动附带版本 $appVersionLabel 与平台 android。',
                    style: theme.text.bodySmall.copyWith(
                      color: theme.colors.onSurfaceVariant,
                    ),
                  ),
                  SizedBox(height: theme.space.md),
                  forui.FButton(
                    onPress: _sending ? null : _submit,
                    child: Text(_sending ? '正在提交' : '提交反馈'),
                  ),
                ],
              ),
            ),
          ),
          if (_error != null) ...[
            SizedBox(height: theme.space.sm),
            InlineNotice(
              message: _error!,
              onRetry: _retryable && !_sending ? _submit : null,
            ),
          ],
          SizedBox(height: theme.space.md),
          Text(
            '反馈由维护者按保留期查看；删除账号不影响已经提交的反馈，'
            '因为它本来就不属于账号。',
            style: theme.text.bodySmall,
          ),
        ],
      ),
    );
  }

  /// 提交成功的回执：编号与时间，下面说明维护者怎么处理。
  Widget _receiptCard(
    ZhixinTheme theme,
    ServerFeedbackReceipt receipt,
  ) => forui.FCard(
    child: Padding(
      padding: EdgeInsets.all(theme.space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(FLucideIcons.circleCheck, color: theme.colors.primary),
              SizedBox(width: theme.space.sm),
              Text('反馈已提交', style: theme.text.titleSmall),
            ],
          ),
          SizedBox(height: theme.space.sm),
          Text('回执编号：${receipt.id}', style: theme.text.bodyMedium),
          Text(
            '提交时间：${receipt.createdAt == null ? '服务端暂未给出' : formatDateTime(receipt.createdAt!)}',
            style: theme.text.bodyMedium,
          ),
          SizedBox(height: theme.space.sm),
          Text(
            '如果填了联系邮箱，维护者可能按这个地址追问；没有填时只作为记录保留。',
            style: theme.text.bodySmall.copyWith(
              color: theme.colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );
}
