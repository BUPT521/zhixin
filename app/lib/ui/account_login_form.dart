import 'dart:async';

import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import '../application/account_service.dart';
import 'account_dialogs.dart';
import 'failure_feedback.dart';
import 'theme.dart';
import 'workspace_widgets.dart';

/// 登录与注册表单：账号页与首次启动引导共用这一份。
///
/// 表单只做邮箱与密码的输入、校验与提交，登录成功之后由调用方决定后面的界面；
/// 账号页用它显示登录卡，引导第二步用它登录或注册。校验口径（两项都不能为空、
/// 密码至少 8 位）、错误说明与登录之后的同步调度都在这里，调用方不再各写一遍。
class AccountLoginForm extends StatefulWidget {
  const AccountLoginForm({
    super.key,
    required this.identifier,
    this.onSignedIn,
    this.onForgotPassword,
    this.showServerAddress = false,
    this.onSaveServerAddress,
  });

  /// 登录方式输入框的控制器；账号页的“忘记密码”也要用同一个邮箱，所以由页面
  /// 持有，切到重设表单时输入的内容不丢。
  final TextEditingController identifier;

  /// 登录或注册成功之后调用；引导据此进入第三步，账号页据此刷新账号状态。
  ///
  /// 登录会触发换空间时，整棵界面子树在调用登录的过程中重建，表单所在的页面
  /// 已经卸载，这时不再调用。
  final Future<void> Function(AccountSnapshot snapshot, {required bool register})?
  onSignedIn;

  /// 提供时显示“忘记密码”按钮；引导里跳账号页，账号页里切到重设表单。
  final VoidCallback? onForgotPassword;

  /// 是否在表单下方折叠“使用自建服务”：引导里默认收起，账号页不显示这一块，
  /// 服务地址仍由设置页的开发者模式调整。
  final bool showServerAddress;

  /// 保存“使用自建服务”里填的实例地址；为空时不显示这一块的修改入口。
  ///
  /// 首次启动引导直接选实例，不再先让用户去设置里打开开发者模式，调用方传入
  /// 只核对实例就绪与 schema 的保存动作。
  final Future<void> Function(String address)? onSaveServerAddress;

  @override
  State<AccountLoginForm> createState() => _AccountLoginFormState();
}

class _AccountLoginFormState extends State<AccountLoginForm> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  /// 折叠区里显示的当前服务地址；读不到时留空，只影响这一行说明。
  String? _serverAddress;
  bool _addressStarted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_addressStarted) return;
    _addressStarted = true;
    if (widget.showServerAddress) unawaited(_loadServerAddress());
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _loadServerAddress() async {
    final scope = AppScope.of(context);
    try {
      // 引导显示得比开库早，服务在就绪之后才读得到；读失败只留空这一行。
      await scope.ready;
      final address = await scope.accountServices.account.serverBaseUrl();
      if (!mounted) return;
      setState(() => _serverAddress = address);
    } catch (_) {
      // 服务地址只用于说明与修改，读不到不影响登录。
    }
  }

  Future<void> _submit({required bool register}) async {
    if (_busy) return;
    final identifier = widget.identifier.text.trim();
    final password = _password.text;
    if (identifier.isEmpty || password.isEmpty) {
      setState(() => _error = '填写邮箱与密码后再继续');
      return;
    }
    if (password.length < 8) {
      setState(() => _error = '密码至少 8 位');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final scope = AppScope.of(context);
    try {
      await scope.ready;
      final account = scope.accountServices.account;
      final result = register
          ? await account.register(identifier: identifier, password: password)
          : await account.login(identifier: identifier, password: password);
      // 登录会换空间：换完之后整棵子树连同这一页一起重建，收尾交给应用根部与
      // 调用方原来所在的页面，这里不再读已经卸载的界面。
      if (!mounted) return;
      _password.clear();
      if (!scope.managesSpaces) {
        await scope.accountServices.sync.schedule(
          delay: const Duration(seconds: 1),
        );
      }
      await widget.onSignedIn?.call(result, register: register);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _error = describeFailure(
          context,
          error,
          stack,
          action: register ? '注册' : '登录',
          kind: 'account_login',
          kept: '本机记录没有改动',
          next: '可以检查邮箱、密码与服务地址后重试',
        );
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editServerAddress() async {
    final onSave = widget.onSaveServerAddress;
    if (onSave == null) return;
    final saved = await editZhixinServerAddress(
      context,
      serverBaseUrl: _serverAddress ?? '',
      onSave: onSave,
    );
    if (saved == true) await _loadServerAddress();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        forui.FTextField(
          control: .managed(controller: widget.identifier),
          keyboardType: TextInputType.emailAddress,
          label: const Text('邮箱'),
          enabled: !_busy,
        ),
        SizedBox(height: theme.space.gap),
        forui.FTextField(
          control: .managed(controller: _password),
          obscureText: true,
          label: const Text('密码（至少 8 位）'),
          enabled: !_busy,
          onSubmit: (_) => _submit(register: false),
        ),
        SizedBox(height: theme.space.md),
        Wrap(
          spacing: theme.space.sm,
          runSpacing: theme.space.sm,
          children: [
            forui.FButton(
              mainAxisSize: MainAxisSize.min,
              onPress: _busy ? null : () => _submit(register: false),
              child: const Text('登录'),
            ),
            forui.FButton(
              variant: forui.FButtonVariant.outline,
              mainAxisSize: MainAxisSize.min,
              onPress: _busy ? null : () => _submit(register: true),
              child: const Text('注册'),
            ),
            if (widget.onForgotPassword case final onForgotPassword?)
              forui.FButton(
                variant: forui.FButtonVariant.ghost,
                mainAxisSize: MainAxisSize.min,
                onPress: _busy ? null : onForgotPassword,
                child: const Text('忘记密码'),
              ),
          ],
        ),
        if (_error case final error?) ...[
          SizedBox(height: theme.space.md),
          InlineNotice(message: error),
        ],
        if (widget.showServerAddress) ...[
          SizedBox(height: theme.space.md),
          forui.FAccordion(
            style: const .delta(
              titlePadding: .value(EdgeInsets.symmetric(vertical: 4)),
              childPadding: .value(EdgeInsets.only(bottom: 4)),
              dividerStyle: .delta(color: Colors.transparent),
            ),
            children: [
              forui.FAccordionItem(
                title: Text('使用自建服务', style: theme.text.bodyMedium),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _serverAddress == null
                          ? '正在读取当前服务地址…'
                          : '当前实例：$_serverAddress',
                      style: theme.text.bodySmall.copyWith(
                        color: theme.colors.onSurfaceVariant,
                      ),
                    ),
                    SizedBox(height: theme.space.sm),
                    forui.FButton(
                      variant: forui.FButtonVariant.outline,
                      size: forui.FButtonSizeVariant.sm,
                      mainAxisSize: MainAxisSize.min,
                      onPress: _busy ? null : _editServerAddress,
                      child: const Text('修改服务地址'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
