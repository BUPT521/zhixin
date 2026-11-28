import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import '../application/account_login_flow.dart';
import '../application/account_service.dart';
import 'failure_feedback.dart';
import 'theme.dart';
import 'workspace_widgets.dart';

/// 登录与注册表单：账号页与首次启动引导共用这一份。
///
/// 表单只做邮箱与密码的输入、校验与提交，登录成功之后由调用方决定后面的界面；
/// 账号页用它显示登录卡，引导第二步用它登录或注册。登录之后的同步调度由换空间
/// 之后新建的应用根在装配时安排，表单不再自己调度一次。
class AccountLoginForm extends StatefulWidget {
  const AccountLoginForm({
    super.key,
    required this.identifier,
    this.onSignedIn,
    this.onForgotPassword,
  });

  /// 登录方式输入框的控制器；账号页的“忘记密码”也要用同一个邮箱，所以由页面
  /// 持有，切到重设表单时输入的内容不丢。
  final TextEditingController identifier;

  /// 登录或注册成功之后调用；引导据此进入第三步，账号页据此刷新账号状态。
  ///
  /// 登录会触发换空间时，整棵界面子树在调用登录的过程中重建，表单所在的页面
  /// 已经卸载，这时不再调用。
  final Future<void> Function(
    AccountSnapshot snapshot, {
    required bool register,
  })?
  onSignedIn;

  /// 提供时显示“忘记密码”按钮；引导里跳账号页，账号页里切到重设表单。
  final VoidCallback? onForgotPassword;

  @override
  State<AccountLoginForm> createState() => _AccountLoginFormState();
}

class _AccountLoginFormState extends State<AccountLoginForm> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit({required bool register}) async {
    if (_busy) return;
    final identifier = widget.identifier.text.trim();
    final password = _password.text;
    // 输入不合规时不进入进行中状态；提示文字由应用层给，表单不再自己拼。
    final problem = AccountLoginFlow.inputProblem(
      identifier: identifier,
      password: password,
    );
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final scope = AppScope.of(context);
    try {
      await scope.ready;
      final result = await AccountLoginFlow(
        account: scope.accountServices.account,
      ).submit(identifier: identifier, password: password, register: register);
      if (!mounted) return;
      switch (result) {
        case AccountSignedIn(:final snapshot):
          // 登录会换空间：换完之后整棵界面子树连同这一页一起重建，收尾交给
          // 应用根部与调用方原来所在的页面，这里不再读已经卸载的界面。同步调度
          // 由换空间之后新建的应用根在装配时安排（`AppScope` 启动时按网络开关
          // 调度一次）。
          _password.clear();
          await widget.onSignedIn?.call(snapshot, register: register);
        case AccountInputRejected(:final message):
          setState(() => _error = message);
        case AccountLoginFailed(:final error, :final stack):
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
      }
    } on FormatException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
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
          hint: 'name@example.com',
          prefixBuilder: (context, style, variants) =>
              forui.FTextField.prefixIconBuilder(
                context,
                style,
                variants,
                const Icon(FLucideIcons.mail),
              ),
          enabled: !_busy,
        ),
        SizedBox(height: theme.space.md),
        forui.FTextField(
          control: .managed(controller: _password),
          obscureText: true,
          label: const Text('密码（至少 8 位）'),
          prefixBuilder: (context, style, variants) =>
              forui.FTextField.prefixIconBuilder(
                context,
                style,
                variants,
                const Icon(FLucideIcons.lock),
              ),
          enabled: !_busy,
          onSubmit: (_) => _submit(register: false),
        ),
        if (widget.onForgotPassword case final onForgotPassword?) ...[
          // 找回密码贴着密码框，右对齐，和下面的登录、注册分开一行，三个动作
          // 不再挤在同一行里。
          Align(
            alignment: Alignment.centerRight,
            child: forui.FButton(
              variant: forui.FButtonVariant.ghost,
              mainAxisSize: MainAxisSize.min,
              onPress: _busy ? null : onForgotPassword,
              child: const Text('忘记密码'),
            ),
          ),
        ],
        SizedBox(height: theme.space.md),
        Row(
          children: [
            Expanded(
              child: forui.FButton(
                onPress: _busy ? null : () => _submit(register: false),
                child: const Text('登录'),
              ),
            ),
            SizedBox(width: theme.space.sm),
            Expanded(
              child: forui.FButton(
                variant: forui.FButtonVariant.outline,
                onPress: _busy ? null : () => _submit(register: true),
                child: const Text('注册'),
              ),
            ),
          ],
        ),
        if (_error case final error?) ...[
          SizedBox(height: theme.space.md),
          InlineNotice(message: error),
        ],
      ],
    );
  }
}
