import '../data/cloud/release_signature.dart';
import '../data/cloud/server_client.dart';
import '../domain/rules/version.dart';

/// 一次检查结果的持有者：页面订阅它，得到更新时重建一次提示。
///
/// 应用层不依赖 Flutter，所以这里只用最少的监听列表，而不是 Flutter 的通知器。
class UpdateNotice {
  AppUpdate? _value;
  final List<void Function()> _listeners = [];

  AppUpdate? get value => _value;

  set value(AppUpdate? next) {
    if (_value == next) return;
    _value = next;
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  void addListener(void Function() listener) {
    if (!_listeners.contains(listener)) _listeners.add(listener);
  }

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void dispose() => _listeners.clear();
}

/// 发布清单里签名一项的核对结果；界面在更新详情里说明它是哪一种。
enum ReleaseSignatureState {
  /// 清单没有提供签名，只按 https 与 sha256 过滤。
  notProvided,

  /// 清单提供了签名，用内置公钥校验通过。
  verified,

  /// 清单提供了签名，但构建时没有注入公钥；跳过签名校验。
  skippedNoKey,
}

/// 一次可提示的更新：清单条目、是否必须更新与签名核对结果。
class AppUpdate {
  const AppUpdate({
    required this.release,
    required this.mandatory,
    required this.signature,
  });

  final ServerRelease release;

  /// 当前版本低于清单要求的 `min_version`。
  final bool mandatory;
  final ReleaseSignatureState signature;

  String get signatureLabel => switch (signature) {
    ReleaseSignatureState.notProvided => '清单未提供签名，只校验 https 与 sha256',
    ReleaseSignatureState.verified => '已用内置公钥校验签名',
    ReleaseSignatureState.skippedNoKey => '未配置发布公钥，跳过签名校验',
  };
}

/// AOT 正式构建的标记；debug 构建与测试都不是正式包（与 ServerClient 一致）。
const bool _isReleaseBuild = bool.fromEnvironment('dart.vm.product');

/// 更新检查：读一次发布清单，按平台取一条可用的更新，结果放在 [notice] 里由
/// 设置页显示。本机只提示、不下载也不安装。
///
/// 只接受 https 且 sha256 为 64 位小写十六进制的条目；清单带签名时按内置公钥
/// 校验，签名不通过就不提示。debug 构建默认不检查，避免开发时反复请求；需要
/// 在开发包上验证时用 `--dart-define=ZHIXIN_UPDATE_CHECK_IN_DEBUG=true`。
class UpdateService {
  UpdateService({
    required this.serverBaseUrl,
    required this.currentVersion,
    required this.currentBuild,
    this.platform = 'android',
    this.publicKeyBase64,
    this.clientFactory,
    this.recordFailure,
    bool? enabled,
  }) : enabled =
           enabled ??
           (_isReleaseBuild ||
               const bool.fromEnvironment(
                 'ZHIXIN_UPDATE_CHECK_IN_DEBUG',
                 defaultValue: false,
               ));

  /// 读当前服务地址；没有登录时用的是编译时默认地址。
  final Future<String> Function() serverBaseUrl;

  /// 当前版本与构建号；来自构建元数据 [appBuildName] 与 [appBuildNumber]。
  final String currentVersion;
  final int currentBuild;
  final String platform;

  /// 测试或构建时注入的发布公钥；为空时读 [zhixinReleasePublicKey]。
  final String? publicKeyBase64;
  final ServerClient Function(String baseUrl)? clientFactory;
  final void Function(Object error, StackTrace stack, {required String kind})?
  recordFailure;
  final bool enabled;

  /// 最近一次检查的结果；为空表示没有更新、检查还没完成或已经被关闭。
  final UpdateNotice notice = UpdateNotice();

  Future<AppUpdate?>? _pending;
  bool _finished = false;
  bool _dismissed = false;
  ServerClient? _ownedClient;

  AppUpdate? get current => notice.value;

  bool get checked => _finished;

  /// 启动后与打开设置页时都调这里；一次运行里只检查一遍，已经关闭的提示不再出现。
  Future<AppUpdate?> ensureChecked() {
    if (!enabled || _dismissed) return Future.value(notice.value);
    if (_finished) return Future.value(notice.value);
    final pending = _pending;
    if (pending != null) return pending;
    final future = _check();
    _pending = future;
    return future;
  }

  /// 用户关闭提示；本次运行不再显示。
  void dismiss() {
    _dismissed = true;
    notice.value = null;
  }

  void dispose() {
    _ownedClient?.dispose();
    _ownedClient = null;
    notice.dispose();
  }

  Future<AppUpdate?> _check() async {
    try {
      final base = (await serverBaseUrl()).trim();
      if (base.isEmpty) return null;
      final client =
          clientFactory?.call(base) ??
          (_ownedClient = ServerClient(baseUrl: base));
      final releases = await client.releases();
      final update = _pick(releases);
      if (!_dismissed) notice.value = update;
      return update;
    } catch (error, stack) {
      // 更新检查失败不影响使用，只在本机诊断里留一条。
      recordFailure?.call(error, stack, kind: 'app_update_check');
      return null;
    } finally {
      _finished = true;
      _pending = null;
    }
  }

  AppUpdate? _pick(List<ServerRelease> releases) {
    AppUpdate? best;
    for (final release in releases) {
      if (release.platform != platform) continue;
      final invalid = _invalidReason(release);
      if (invalid != null) {
        _recordManifest('${release.version}（构建 ${release.build}）$invalid，已忽略');
        continue;
      }
      final signature = _checkSignature(release);
      if (signature == null) continue;
      final newer = isReleaseNewer(
        version: release.version,
        build: release.build,
        currentVersion: currentVersion,
        currentBuild: currentBuild,
      );
      if (!newer) continue;
      final candidate = AppUpdate(
        release: release,
        mandatory: isBelowMinimumVersion(currentVersion, release.minVersion),
        signature: signature,
      );
      if (best == null ||
          isReleaseNewer(
            version: candidate.release.version,
            build: candidate.release.build,
            currentVersion: best.release.version,
            currentBuild: best.release.build,
          )) {
        best = candidate;
      }
    }
    return best;
  }

  /// 签名一项的核对结果；清单提供了签名且校验不通过时返回 null，表示这条
  /// 不提示更新。
  ReleaseSignatureState? _checkSignature(ServerRelease release) {
    if (release.signature.trim().isEmpty) {
      return ReleaseSignatureState.notProvided;
    }
    final key = (publicKeyBase64 ?? zhixinReleasePublicKey).trim();
    if (key.isEmpty) return ReleaseSignatureState.skippedNoKey;
    final verified = verifyReleaseSignature(
      sha256: release.sha256.trim(),
      signature: release.signature,
      publicKeyBase64: key,
    );
    if (!verified) {
      _recordManifest('${release.version}（构建 ${release.build}）的签名校验失败，已忽略');
      return null;
    }
    return ReleaseSignatureState.verified;
  }

  /// 地址必须是 https、主机非空，sha256 必须是 64 位小写十六进制；
  /// 返回不满足的原因，满足时返回 null。
  String? _invalidReason(ServerRelease release) {
    final url = Uri.tryParse(release.url.trim());
    if (url == null || url.scheme != 'https' || url.host.isEmpty) {
      return '的安装包地址不是 https';
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(release.sha256.trim())) {
      return '的 sha256 缺失或不是 64 位小写十六进制';
    }
    return null;
  }

  void _recordManifest(String detail) {
    recordFailure?.call(
      FormatException('发布清单条目$detail'),
      StackTrace.current,
      kind: 'app_update_manifest',
    );
  }
}
