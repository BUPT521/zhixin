import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import '../application/account_service.dart';
import '../domain/models/model_api_key.dart';
import 'format.dart';
import 'theme.dart';
import 'workspace_widgets.dart';
import 'zhixin_dialog.dart';
import 'zhixin_header.dart';
import 'zhixin_toast.dart';

class ModelApiKeysPage extends StatefulWidget {
  const ModelApiKeysPage({super.key});

  @override
  State<ModelApiKeysPage> createState() => _ModelApiKeysPageState();
}

class _ModelApiKeysPageState extends State<ModelApiKeysPage> {
  List<ModelApiKey>? _keys;
  String? _error;

  /// 当前实例的服务地址；页面据此写出密钥要调的接口地址。
  String _serverBaseUrl = '';
  bool _busy = false;
  bool _issuing = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _loadServerAddress();
    _refresh();
  }

  /// 读当前实例地址；读不到时调用地址这一块先不显示，密钥列表照常。
  Future<void> _loadServerAddress() async {
    final account = AppScope.of(context).accountServices.account;
    try {
      final base = await account.serverBaseUrl();
      if (mounted) setState(() => _serverBaseUrl = base);
    } catch (_) {
      // 地址只是说明，读取失败不影响申请与撤销密钥。
    }
  }

  Future<void> _refresh() => _run(() async {});

  Future<void> _run(
    Future<void> Function() action, {
    bool issuing = false,
  }) async {
    if (_busy) return;
    final account = AppScope.of(context).accountServices.account;
    setState(() {
      _busy = true;
      _issuing = issuing;
      _error = null;
    });
    var actionCompleted = false;
    try {
      await action();
      actionCompleted = true;
      if (!mounted) return;
      final keys = await account.apiKeys();
      if (mounted) setState(() => _keys = keys);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error = account.apiKeyErrorMessage(
          error,
          issuing: issuing && !actionCompleted,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _issuing = false;
        });
      }
    }
  }

  Future<void> _issue() async {
    final account = AppScope.of(context).accountServices.account;
    final input = await showZhixinDialog<({String name, String password})>(
      context: context,
      builder: (_) => const _IssueKeyDialog(),
    );
    if (input == null || !mounted) return;
    await _run(() async {
      final key = await account.createApiKey(
        name: input.name,
        password: input.password,
      );
      if (mounted) await _showIssuedKey(key);
    }, issuing: true);
  }

  Future<void> _showIssuedKey(String key) async {
    await showZhixinDialog<void>(
      context: context,
      builder: (context) => ZhixinDialogLayout(
        title: const Text('API Key 已签发'),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('完整密钥只显示这一次，请复制后妥善保管。'),
            SizedBox(height: context.zhixin.space.gap),
            SelectableText(key),
          ],
        ),
        actions: [
          cancelZhixinButton(context, label: '完成'),
          forui.FButton(
            mainAxisSize: MainAxisSize.min,
            onPress: () async {
              try {
                await Clipboard.setData(ClipboardData(text: key));
                if (context.mounted) showToast(context, '已复制 API Key');
              } catch (_) {
                if (context.mounted) showToast(context, '复制失败，可以选择密钥文本后复制');
              }
            },
            child: const Text('复制 API Key'),
          ),
        ],
      ),
    );
  }

  Future<void> _revoke([ModelApiKey? key]) async {
    final account = AppScope.of(context).accountServices.account;
    final confirmed = await confirmZhixin(
      context: context,
      title: key == null ? '撤销全部 API Key' : '撤销 API Key',
      content: Text(
        key == null
            ? '所有有效密钥都会立即失效，使用这些密钥的工具将无法继续调用模型。'
            : '“${key.name}”会立即失效，使用这把密钥的工具将无法继续调用模型。',
      ),
      confirmLabel: '撤销',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _run(
      key == null
          ? account.revokeAllApiKeys
          : () => account.revokeApiKey(key.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final keys = _keys;
    return PopScope(
      canPop: !_issuing,
      child: DetailScaffold(
        header: const ZhixinHeader(title: Text('知新 API Key'), showBack: true),
        child: ListView(
          padding: theme.space.pageInsets(),
          children: [
            const SectionHeading(
              title: '模型代理密钥',
              subtitle: '供脚本和第三方工具调用知新模型，与当前账号共用额度。密钥一直有效，直到撤销。',
              first: true,
            ),
            Wrap(
              spacing: theme.space.sm,
              runSpacing: theme.space.sm,
              children: [
                forui.FButton(
                  mainAxisSize: MainAxisSize.min,
                  onPress: _busy ? null : _issue,
                  child: const Text('申请 API Key'),
                ),
                forui.FButton(
                  mainAxisSize: MainAxisSize.min,
                  variant: forui.FButtonVariant.outline,
                  onPress: _busy ? null : _refresh,
                  child: const Text('刷新列表'),
                ),
                if (keys?.any((key) => !key.revoked) ?? false)
                  forui.FButton(
                    mainAxisSize: MainAxisSize.min,
                    variant: forui.FButtonVariant.destructive,
                    onPress: _busy ? null : () => _revoke(),
                    child: const Text('撤销全部'),
                  ),
              ],
            ),
            SizedBox(height: theme.space.gap),
            if (_busy) const Center(child: forui.FCircularProgress(size: .sm)),
            if (_error case final error?)
              Padding(
                padding: EdgeInsets.only(top: theme.space.sm),
                child: InlineNotice(message: error),
              ),
            if (keys?.isEmpty ?? false) const Text('还没有 API Key'),
            if (keys != null)
              for (final (index, key) in keys.indexed) ...[
                if (index > 0) SizedBox(height: theme.space.sm),
                forui.FTile(
                  title: Text(key.name),
                  subtitle: Text(
                    '${key.prefix}… · ${key.revoked ? '已撤销' : '有效'}\n'
                    '创建于 ${shortTime(key.createdAt.toLocal())}\n'
                    '${switch (key.lastUsedAt) {
                      final time? => '最近使用 ${shortTime(time.toLocal())}',
                      null => '尚未使用',
                    }}',
                  ),
                  suffix: key.revoked
                      ? null
                      : forui.FButton(
                          mainAxisSize: MainAxisSize.min,
                          variant: forui.FButtonVariant.ghost,
                          onPress: _busy ? null : () => _revoke(key),
                          child: const Text('撤销'),
                        ),
                ),
              ],
            if (_serverBaseUrl.isNotEmpty) ...[
              const SectionHeading(
                title: '调用地址',
                subtitle:
                    '把密钥写进请求头 Authorization: Bearer <API Key>；地址随“知新服务地址”变化。',
              ),
              _endpointCard(theme),
            ],
          ],
        ),
      ),
    );
  }

  /// 脚本要填的两个接口地址，与当前实例的“知新服务地址”一致。
  Widget _endpointCard(ZhixinTheme theme) {
    final chatUrl = AccountService.responsesEndpoint(_serverBaseUrl);
    final embeddingUrl =
        '${AccountService.embeddingsEndpoint(_serverBaseUrl)}/embeddings';
    final muted = theme.text.bodySmall.copyWith(
      color: theme.colors.onSurfaceVariant,
    );
    return forui.FCard(
      child: Padding(
        padding: EdgeInsets.all(theme.space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('对话接口', style: theme.text.titleSmall),
            SizedBox(height: theme.space.xs),
            SelectableText(chatUrl, style: muted),
            SizedBox(height: theme.space.md),
            Text('嵌入接口', style: theme.text.titleSmall),
            SizedBox(height: theme.space.xs),
            SelectableText(embeddingUrl, style: muted),
            SizedBox(height: theme.space.gap),
            Align(
              alignment: Alignment.centerLeft,
              child: forui.FButton(
                mainAxisSize: MainAxisSize.min,
                variant: forui.FButtonVariant.outline,
                onPress: () => _copyAddress(chatUrl),
                child: const Text('复制对话地址'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copyAddress(String value) async {
    try {
      await Clipboard.setData(ClipboardData(text: value));
      if (mounted) showToast(context, '已复制对话地址');
    } catch (_) {
      if (mounted) showToast(context, '复制失败，可以长按地址手动复制');
    }
  }
}

class _IssueKeyDialog extends StatefulWidget {
  const _IssueKeyDialog();

  @override
  State<_IssueKeyDialog> createState() => _IssueKeyDialogState();
}

class _IssueKeyDialogState extends State<_IssueKeyDialog> {
  final _name = TextEditingController();
  final _password = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final password = _password.text;
    if (name.isEmpty || name.runes.length > 64 || password.isEmpty) {
      setState(() => _error = '请输入 1 至 64 个字符的密钥名称和当前密码');
      return;
    }
    Navigator.of(context).pop((name: name, password: password));
  }

  @override
  Widget build(BuildContext context) => ZhixinDialogLayout(
    title: const Text('申请 API Key'),
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        forui.FTextField(
          control: .managed(controller: _name),
          label: const Text('密钥名称'),
          hint: '例如：本机脚本',
        ),
        SizedBox(height: context.zhixin.space.gap),
        forui.FTextField(
          control: .managed(controller: _password),
          label: const Text('当前密码'),
          obscureText: true,
          onSubmit: (_) => _submit(),
        ),
        if (_error case final error?)
          Padding(
            padding: EdgeInsets.only(top: context.zhixin.space.sm),
            child: InlineNotice(message: error),
          ),
      ],
    ),
    actions: [
      cancelZhixinButton(context),
      forui.FButton(
        mainAxisSize: MainAxisSize.min,
        onPress: _submit,
        child: const Text('确认申请'),
      ),
    ],
  );
}
