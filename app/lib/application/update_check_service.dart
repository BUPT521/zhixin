/// 应用内更新检查：读公开发布清单，按平台取一项，比较版本，核对 https 与
/// SHA-256 格式，再用内置公钥核对清单签名。
///
/// 检查阶段不下载安装包：清单签名对象是安装包 SHA-256 字符串，验签通过即可
/// 判定有更新；安装包由系统浏览器在用户确认后下载一次，系统安装器在覆盖安装前
/// 核对安装包签名。网络读取与验签都拆成可注入的函数，单元测试不需要真的联网；
/// 生产路径只用 [ServerClient] 读清单。检查本身不提示、不改界面：调用方按
/// [UpdateCheckResult] 决定是否弹窗，失败时把原因交给本机诊断记录（`kind` 为
/// `update_check`），不打扰用户。
library;

import '../data/cloud/release_verification.dart';
import '../data/cloud/server_client.dart';
import '../domain/rules/release_version.dart';

/// 一次检查的结论；界面只在 [UpdateCheckStatus.updateAvailable] 时提示。
enum UpdateCheckStatus { upToDate, updateAvailable, failed }

/// 检查没有通过或没有拿到更新时的原因，用于诊断与手动检查的说明。
enum UpdateFailure {
  network,
  invalidAppVersion,
  invalidReleaseVersion,
  insecureUrl,
  missingHash,
  signatureMismatch,
  unexpected,
}

/// 一次检查的结果：不提示时 [release] 为空，有更新时带上清单项与是否必须更新。
class UpdateCheckResult {
  const UpdateCheckResult.upToDate()
    : status = UpdateCheckStatus.upToDate,
      release = null,
      requiredUpdate = false,
      failure = null;

  /// 清单里有比当前版本更新的安装包。检查阶段不下载安装包；用户确认后由系统
  /// 浏览器打开清单地址下载一次，系统安装器核对安装包签名后覆盖安装。
  const UpdateCheckResult.updateAvailable(
    ServerRelease this.release, {
    required this.requiredUpdate,
  }) : status = UpdateCheckStatus.updateAvailable,
       failure = null;

  const UpdateCheckResult.failed(UpdateFailure this.failure)
    : status = UpdateCheckStatus.failed,
      release = null,
      requiredUpdate = false;

  final UpdateCheckStatus status;
  final ServerRelease? release;
  final bool requiredUpdate;
  final UpdateFailure? failure;

  bool get hasUpdate =>
      status == UpdateCheckStatus.updateAvailable && release != null;

  /// 失败时给手动检查用的一句说明；启动检查不显示它，只写本机诊断。
  String get failureMessage => switch (failure) {
    UpdateFailure.network => '无法连接服务端，检查更新失败',
    UpdateFailure.invalidAppVersion => '当前版本号无法解析，检查更新失败',
    UpdateFailure.invalidReleaseVersion => '发布清单里的版本号无法解析',
    UpdateFailure.insecureUrl => '下载地址不是 https，不提示更新',
    UpdateFailure.missingHash => '发布清单缺少合法的 sha256',
    UpdateFailure.signatureMismatch => '发布清单签名没有通过，不提示更新',
    UpdateFailure.unexpected => '检查更新时出现异常，可以稍后再试',
    null => '',
  };
}

/// 读发布清单：参数是服务地址，返回该实例给出的清单项。
typedef ReleaseFetcher = Future<List<ServerRelease>> Function(String baseUrl);

/// 用内置公钥核对清单签名；失败返回 false。
typedef ReleaseSignatureChecker = Future<bool> Function({
  required String publicKeyPem,
  required String sha256Hex,
  required String signatureBase64,
});

/// 应用内更新检查；一个实例可以重复使用，本次启动只检查一次由调用方控制。
class UpdateCheckService {
  UpdateCheckService({
    required this.serverBaseUrl,
    required this.appVersion,
    required this.publicKeyPem,
    this.platform = 'android',
    ReleaseFetcher? fetchReleases,
    ReleaseSignatureChecker? verifySignature,
    this.recordFailure,
    this.timeout = const Duration(seconds: 30),
  }) : _fetchReleases =
           fetchReleases ?? ((baseUrl) => _fetchReleasesFrom(baseUrl, timeout)),
       _verifySignature = verifySignature ?? verifyReleaseSignature;

  /// 账号页保存的服务地址；没有登录或没有自定义时是编译时的默认地址。
  final Future<String> Function() serverBaseUrl;

  /// 当前应用的版本串 `0.1.1-dev+2`；由调用方从 `platform/app_info.dart` 传入。
  final String appVersion;

  /// 用于验证发布清单的 Ed25519 公钥 PEM。
  final String publicKeyPem;

  /// 清单里按这个平台取一项；安装包只发布 android。
  final String platform;

  /// 失败时写一条本机诊断；启动检查不向界面抛错。
  final void Function(Object error, StackTrace stack, {required String kind})?
  recordFailure;

  final Duration timeout;

  final ReleaseFetcher _fetchReleases;
  final ReleaseSignatureChecker _verifySignature;

  /// 走完版本、https、哈希格式与签名四步；任何一步不通过都返回不提示。
  ///
  /// 检查阶段只读发布清单，不对安装包地址发起请求；安装包由系统浏览器在用户
  /// 确认后下载一次，应用内不安装。
  Future<UpdateCheckResult> check() async {
    try {
      return await _check();
    } catch (error, stack) {
      _record(error, stack);
      return const UpdateCheckResult.failed(UpdateFailure.unexpected);
    }
  }

  Future<UpdateCheckResult> _check() async {
    final current = ReleaseVersion.parseAppVersion(appVersion);
    if (current == null) {
      return const UpdateCheckResult.failed(UpdateFailure.invalidAppVersion);
    }
    final List<ServerRelease> releases;
    try {
      releases = await _fetchReleases(await serverBaseUrl());
    } catch (error, stack) {
      _record(error, stack);
      return const UpdateCheckResult.failed(UpdateFailure.network);
    }
    ServerRelease? release;
    for (final item in releases) {
      if (item.platform == platform) {
        release = item;
        break;
      }
    }
    // 清单为空或没有这个平台，说明还没有对外发布安装包（ADR-0025）。
    if (release == null) return const UpdateCheckResult.upToDate();
    final remote = ReleaseVersion.tryParse(release.version, release.build);
    if (remote == null) {
      _recordReason(UpdateFailure.invalidReleaseVersion);
      return const UpdateCheckResult.failed(
        UpdateFailure.invalidReleaseVersion,
      );
    }
    if (!remote.isNewerThan(current)) return const UpdateCheckResult.upToDate();

    final uri = Uri.tryParse(release.url.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      _recordReason(UpdateFailure.insecureUrl);
      return const UpdateCheckResult.failed(UpdateFailure.insecureUrl);
    }
    final expected = release.sha256.trim().toLowerCase();
    if (!isReleaseSha256Hex(expected)) {
      _recordReason(UpdateFailure.missingHash);
      return const UpdateCheckResult.failed(UpdateFailure.missingHash);
    }

    final signature = release.signature.trim();
    var valid = false;
    try {
      if (signature.isNotEmpty && publicKeyPem.trim().isNotEmpty) {
        valid = await _verifySignature(
          publicKeyPem: publicKeyPem,
          sha256Hex: expected,
          signatureBase64: signature,
        );
      }
    } catch (error, stack) {
      _record(error, stack);
    }
    if (!valid) {
      _recordReason(UpdateFailure.signatureMismatch);
      return const UpdateCheckResult.failed(UpdateFailure.signatureMismatch);
    }

    final minimum = ReleaseVersion.tryParse(release.minVersion, 0);
    final requiredUpdate = minimum != null && current.compareTo(minimum) < 0;
    return UpdateCheckResult.updateAvailable(
      release,
      requiredUpdate: requiredUpdate,
    );
  }

  void _record(Object error, StackTrace stack) {
    recordFailure?.call(error, stack, kind: 'update_check');
  }

  /// 校验不通过不是异常，也要在本机诊断里留一条原因，便于发版时排查。
  void _recordReason(UpdateFailure failure) {
    _record(StateError(_reasonText(failure)), StackTrace.current);
  }

  static String _reasonText(UpdateFailure failure) => switch (failure) {
    UpdateFailure.insecureUrl => '发布清单的下载地址不是 https',
    UpdateFailure.missingHash => '发布清单缺少合法的 sha256',
    UpdateFailure.signatureMismatch => '发布清单签名没有通过',
    UpdateFailure.invalidReleaseVersion => '发布清单里的版本号无法解析',
    _ => '更新检查没有通过',
  };
}

/// 生产路径的清单读取：一次请求就关掉客户端，检查之后不保留连接。
Future<List<ServerRelease>> _fetchReleasesFrom(
  String baseUrl,
  Duration timeout,
) async {
  final client = ServerClient(baseUrl: baseUrl, timeout: timeout);
  try {
    return await client.releases();
  } finally {
    client.dispose();
  }
}
