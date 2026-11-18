/// 应用内更新检查：读公开发布清单，按平台取一项，比较版本之后下载安装包，
/// 核对 https、SHA-256 与签名，三项都通过才报告有更新。
///
/// 网络读取、下载、哈希与验签都拆成可注入的函数，单元测试不需要真的联网；
/// 生产路径用 [ServerClient] 读清单、用独立 HTTP 客户端下载安装包。检查本身
/// 不提示、不改界面：调用方按 [UpdateCheckResult] 决定是否弹窗，失败时把原因
/// 交给本机诊断记录（`kind` 为 `update_check`），不打扰用户。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

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
  download,
  hashMismatch,
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
    UpdateFailure.download => '下载安装包失败，检查更新没有完成',
    UpdateFailure.hashMismatch => '安装包哈希与发布清单不一致，不提示更新',
    UpdateFailure.signatureMismatch => '发布清单签名没有通过，不提示更新',
    UpdateFailure.unexpected => '检查更新时出现异常，可以稍后再试',
    null => '',
  };
}

/// 读发布清单：参数是服务地址，返回该实例给出的清单项。
typedef ReleaseFetcher = Future<List<ServerRelease>> Function(String baseUrl);

/// 下载安装包：参数已经核对过是 https 地址。
typedef ReleaseDownloader = Future<Uint8List> Function(Uri url);

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
    ReleaseDownloader? downloadPackage,
    ReleaseSignatureChecker? verifySignature,
    this.recordFailure,
    this.timeout = const Duration(seconds: 30),
    this.tempDirectory,
  }) : _fetchReleases =
           fetchReleases ?? ((baseUrl) => _fetchReleasesFrom(baseUrl, timeout)),
       _downloadPackage =
           downloadPackage ?? ((url) => _downloadFromNetwork(url, timeout)),
       _verifySignature = verifySignature ?? verifyReleaseSignature;

  /// 账号页保存的服务地址；没有登录或没有自定义时是编译时的默认地址。
  final Future<String> Function() serverBaseUrl;

  /// 当前应用的版本串 `0.1.1-dev+2`；由调用方从 `platform/app_info.dart` 传入。
  final String appVersion;

  /// 内置的 Ed25519 公钥 PEM；为空时清单带签名按验签失败处理。
  final String publicKeyPem;

  /// 清单里按这个平台取一项；安装包只发布 android。
  final String platform;

  /// 失败时写一条本机诊断；启动检查不向界面抛错。
  final void Function(Object error, StackTrace stack, {required String kind})?
  recordFailure;

  final Duration timeout;

  /// 下载安装包的临时目录；留空用系统临时目录，测试可以指定。
  final Directory? tempDirectory;

  final ReleaseFetcher _fetchReleases;
  final ReleaseDownloader _downloadPackage;
  final ReleaseSignatureChecker _verifySignature;

  /// 走完版本、https、哈希与签名四步；任何一步不通过都返回不提示。
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

    final String actual;
    try {
      actual = await _downloadAndHash(uri);
    } catch (error, stack) {
      _record(error, stack);
      return const UpdateCheckResult.failed(UpdateFailure.download);
    }
    if (actual != expected) {
      _recordReason(UpdateFailure.hashMismatch);
      return const UpdateCheckResult.failed(UpdateFailure.hashMismatch);
    }

    final signature = release.signature.trim();
    if (signature.isNotEmpty) {
      var valid = false;
      try {
        valid = await _verifySignature(
          publicKeyPem: publicKeyPem,
          sha256Hex: expected,
          signatureBase64: signature,
        );
      } catch (error, stack) {
        _record(error, stack);
      }
      if (!valid) {
        _recordReason(UpdateFailure.signatureMismatch);
        return const UpdateCheckResult.failed(UpdateFailure.signatureMismatch);
      }
    }

    final minimum = ReleaseVersion.tryParse(release.minVersion, 0);
    final requiredUpdate = minimum != null && current.compareTo(minimum) < 0;
    return UpdateCheckResult.updateAvailable(
      release,
      requiredUpdate: requiredUpdate,
    );
  }

  /// 下载到临时文件之后再算哈希：确认落盘的内容与清单一致，临时文件用完即删。
  Future<String> _downloadAndHash(Uri url) async {
    final bytes = await _downloadPackage(url);
    final parent = tempDirectory ?? Directory.systemTemp;
    final directory = await parent.createTemp('zhixin_update_');
    final file = File(p.join(directory.path, 'release.package'));
    try {
      await file.writeAsBytes(bytes, flush: true);
      final digest = await sha256.bind(file.openRead()).first;
      return digest.toString();
    } finally {
      try {
        await directory.delete(recursive: true);
      } catch (_) {
        // 临时文件删不掉不影响结论；系统清理临时目录时会带走。
      }
    }
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
    UpdateFailure.hashMismatch => '安装包哈希与发布清单不一致',
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

/// 生产路径的安装包下载：单独用短连接，失败由调用方按诊断记下。
Future<Uint8List> _downloadFromNetwork(Uri url, Duration timeout) async {
  final client = http.Client();
  try {
    final response = await client.get(url).timeout(timeout);
    if (response.statusCode != 200) {
      throw HttpException('下载安装包返回 HTTP ${response.statusCode}');
    }
    return response.bodyBytes;
  } finally {
    client.close();
  }
}
