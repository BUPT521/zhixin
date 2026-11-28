import 'account_service.dart';

/// 一次登录或注册的结果：成功、输入不合规，或意外失败。
///
/// 输入不合规与可预期的格式错误直接带一句给用户看的说明；其余异常保留原始
/// 错误与调用栈，由界面写进本机诊断记录之后再显示统一说明。
sealed class AccountLoginResult {
  const AccountLoginResult();
}

final class AccountSignedIn extends AccountLoginResult {
  const AccountSignedIn(this.snapshot);

  final AccountSnapshot snapshot;
}

final class AccountInputRejected extends AccountLoginResult {
  const AccountInputRejected(this.message);

  final String message;
}

final class AccountLoginFailed extends AccountLoginResult {
  const AccountLoginFailed(this.error, this.stack);

  final Object error;
  final StackTrace stack;
}

/// 登录与注册的业务顺序：校验邮箱与密码，再交给账号服务。
///
/// 账号页与首次启动引导共用同一份表单，表单只保留输入、进行中状态与结果提示；
/// 校验顺序、格式错误的处理与成功之后返回哪份账号快照都在这里。
class AccountLoginFlow {
  const AccountLoginFlow({required this.account});

  final AccountService account;

  /// 输入不合规时返回要显示的说明；为空表示可以提交。
  static String? inputProblem({
    required String identifier,
    required String password,
  }) {
    if (identifier.trim().isEmpty || password.isEmpty) {
      return '填写邮箱与密码后再继续';
    }
    if (password.length < 8) return '密码至少 8 位';
    return null;
  }

  Future<AccountLoginResult> submit({
    required String identifier,
    required String password,
    required bool register,
  }) async {
    final problem = inputProblem(identifier: identifier, password: password);
    if (problem != null) return AccountInputRejected(problem);
    try {
      final snapshot = register
          ? await account.register(identifier: identifier, password: password)
          : await account.login(identifier: identifier, password: password);
      return AccountSignedIn(snapshot);
    } on FormatException catch (error) {
      return AccountInputRejected(error.message);
    } catch (error, stack) {
      return AccountLoginFailed(error, stack);
    }
  }
}
