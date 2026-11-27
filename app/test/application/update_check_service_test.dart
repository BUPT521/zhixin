import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/update_check_service.dart';
import 'package:zhixin/data/cloud/release_verification.dart';
import 'package:zhixin/domain/models/server_models.dart';

/// 更新检查的拒绝与接受：版本、https、哈希格式与签名四步，任一不通过都不提示。
///
/// 检查阶段不下载安装包，安装包由系统浏览器在用户确认后下载，所以这些用例都
/// 不涉及对安装包地址的请求。
void main() {
  final hash = releaseSha256Hex(utf8.encode('zhixin apk bytes'));

  ServerRelease release({
    String version = '0.2.0',
    int build = 3,
    String url = 'https://example.test/zhixin.apk',
    String? sha256,
    String signature = 'c2lnbmF0dXJl',
    String minVersion = '0.1.0',
    String platform = 'android',
  }) => ServerRelease(
    platform: platform,
    version: version,
    build: build,
    url: url,
    sha256: sha256 ?? hash,
    signature: signature,
    minVersion: minVersion,
    notes: '登录、云端备份与同步',
  );

  UpdateCheckService service({
    List<ServerRelease> Function()? releases,
    bool failFetch = false,
    bool signatureValid = true,
    bool useRealSignatureCheck = false,
    String publicKeyPem = '内置公钥',
    List<String>? diagnostics,
  }) => UpdateCheckService(
    serverBaseUrl: () async => 'http://server.test',
    appVersion: '0.1.1-dev+2',
    publicKeyPem: publicKeyPem,
    fetchReleases: (_) async {
      if (failFetch) throw const ServerProblem.offline('测试断网');
      return releases?.call() ?? <ServerRelease>[];
    },
    verifySignature: useRealSignatureCheck
        ? verifyReleaseSignature
        : ({
            required publicKeyPem,
            required sha256Hex,
            required signatureBase64,
          }) async => signatureValid,
    recordFailure: (error, stack, {required kind}) => diagnostics?.add(kind),
  );

  test('清单为空时不提示更新', () async {
    final result = await service().check();
    expect(result.status, UpdateCheckStatus.upToDate);
    expect(result.hasUpdate, isFalse);
  });

  test('清单里没有 android 项时不提示更新', () async {
    final result = await service(releases: () => [release(platform: 'ios')])
        .check();
    expect(result.status, UpdateCheckStatus.upToDate);
  });

  test('构建号更高时提示可选更新，并带上版本名与更新说明', () async {
    final result = await service(
      releases: () => [release(version: '0.1.1', build: 3)],
    ).check();
    expect(result.status, UpdateCheckStatus.updateAvailable);
    expect(result.belowMinimum, isFalse);
    expect(result.release?.version, '0.1.1');
    expect(result.release?.build, 3);
    expect(result.release?.notes, '登录、云端备份与同步');
  });

  test('构建号更低或相同时不提示更新', () async {
    final lower = await service(
      releases: () => [release(version: '0.1.1', build: 1)],
    ).check();
    expect(lower.status, UpdateCheckStatus.upToDate);

    final same = await service(
      releases: () => [release(version: '0.1.1', build: 2)],
    ).check();
    expect(same.status, UpdateCheckStatus.upToDate);
  });

  test('版本低于 min_version 时标记为低于建议的最低版本', () async {
    final result = await service(
      releases: () => [
        release(version: '0.2.0', build: 1, minVersion: '0.2.0'),
      ],
    ).check();
    expect(result.status, UpdateCheckStatus.updateAvailable);
    expect(result.belowMinimum, isTrue);
  });

  test('检查阶段不下载安装包：安装包地址不可解析也仍提示更新', () async {
    // 清单地址是不可解析的域名；检查只读清单并验签，不对安装包地址发请求，
    // 所以这里仍然拿到 updateAvailable。
    final result = await service(
      releases: () => [release(url: 'https://example.invalid/zhixin.apk')],
    ).check();
    expect(result.status, UpdateCheckStatus.updateAvailable);
    expect(result.release?.url, 'https://example.invalid/zhixin.apk');
  });

  test('下载地址不是 https 时不提示', () async {
    final result = await service(
      releases: () => [release(url: 'http://example.test/zhixin.apk')],
    ).check();
    expect(result.status, UpdateCheckStatus.failed);
    expect(result.failure, UpdateFailure.insecureUrl);
  });

  test('清单签名不通过时不提示', () async {
    final result = await service(
      releases: () => [release()],
      signatureValid: false,
    ).check();
    expect(result.status, UpdateCheckStatus.failed);
    expect(result.failure, UpdateFailure.signatureMismatch);
  });

  test('公钥为空而清单带签名时按验签失败处理，不提示', () async {
    final result = await service(
      releases: () => [release()],
      publicKeyPem: '',
      useRealSignatureCheck: true,
    ).check();
    expect(result.status, UpdateCheckStatus.failed);
    expect(result.failure, UpdateFailure.signatureMismatch);
  });

  test('清单没有签名时拒绝更新', () async {
    final result = await service(
      releases: () => [release(signature: '')],
      signatureValid: false,
    ).check();
    expect(result.status, UpdateCheckStatus.failed);
    expect(result.failure, UpdateFailure.signatureMismatch);
  });

  test('读取发布清单失败时返回失败并写一条诊断', () async {
    final diagnostics = <String>[];
    final result = await service(
      failFetch: true,
      diagnostics: diagnostics,
    ).check();
    expect(result.status, UpdateCheckStatus.failed);
    expect(result.failure, UpdateFailure.network);
    expect(diagnostics, contains('update_check'));
  });

  test('清单版本名无法解析时不提示', () async {
    final result = await service(releases: () => [release(version: 'latest')])
        .check();
    expect(result.status, UpdateCheckStatus.failed);
    expect(result.failure, UpdateFailure.invalidReleaseVersion);
  });

  test('清单缺少合法的 sha256 时不提示', () async {
    final result = await service(
      releases: () => [release(sha256: 'not-a-hash')],
    ).check();
    expect(result.status, UpdateCheckStatus.failed);
    expect(result.failure, UpdateFailure.missingHash);
  });

  test('版本名更高而构建号更低时仍然提示更新', () async {
    final result = await service(
      releases: () => [release(version: '0.2.0', build: 0)],
    ).check();
    expect(result.status, UpdateCheckStatus.updateAvailable);
  });
}
