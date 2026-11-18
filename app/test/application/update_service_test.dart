import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/update_service.dart';
import 'package:zhixin/data/cloud/server_client.dart';

import '../support/fake_server.dart';

String _sha256Of(String text) => sha256.convert(utf8.encode(text)).toString();

Map<String, Object?> _release({
  String platform = 'android',
  String version = '0.2.0',
  int build = 3,
  String? url,
  String? sha256,
  String signature = '',
  String minVersion = '',
  String notes = '',
}) => {
  'platform': platform,
  'version': version,
  'build': build,
  'url': url ?? 'https://example.test/zhixin-$version.apk',
  'sha256': sha256 ?? _sha256Of('zhixin-$version'),
  'signature': signature,
  if (minVersion.isNotEmpty) 'min_version': minVersion,
  if (notes.isNotEmpty) 'notes': notes,
};

/// 固定测试向量的公钥与签名：签名对象是 [sha256] 的小写十六进制字符串。
const _publicKey = 'A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=';
const _signedSha =
    '70248747c7a1f9260ad35da8de214707a737e8bec4c83cea33284b563a534c54';
const _signature =
    'uMue4GLdwOj+kjMRptW2enuFxEee147uLv9by9octtcpOmUs8YOo+LvdLkwkKbsXJNu3Z'
    'BGCivyZVPualz00CA==';

void main() {
  late FakeServer server;
  late List<({String kind, Object error})> failures;

  setUp(() {
    server = FakeServer();
    failures = [];
  });

  UpdateService service({
    String currentVersion = '0.1.1',
    int currentBuild = 2,
    String? publicKey,
    String platform = 'android',
    bool enabled = true,
  }) => UpdateService(
    serverBaseUrl: () async => 'http://server.test',
    currentVersion: currentVersion,
    currentBuild: currentBuild,
    platform: platform,
    publicKeyBase64: publicKey,
    enabled: enabled,
    clientFactory: (baseUrl) =>
        ServerClient(baseUrl: baseUrl, httpClient: server.client),
    recordFailure: (error, stack, {required kind}) {
      failures.add((kind: kind, error: error));
    },
  );

  test('取当前平台里更新的版本，显示说明且不必须更新', () async {
    server.releases.add(_release(notes: '登录与云端备份', minVersion: '0.1.0'));
    final updates = service();
    addTearDown(updates.dispose);

    final update = await updates.ensureChecked();
    expect(update, isNotNull);
    expect(update!.release.version, '0.2.0');
    expect(update.release.build, 3);
    expect(update.release.notes, '登录与云端备份');
    expect(update.mandatory, isFalse);
    expect(update.signature, ReleaseSignatureState.notProvided);
    expect(updates.notice.value, same(update));
    expect(failures, isEmpty);
  });

  test('低于 min_version 时标为必须更新', () async {
    server.releases.add(_release(minVersion: '0.2.0'));
    final updates = service();
    addTearDown(updates.dispose);

    final update = await updates.ensureChecked();
    expect(update, isNotNull);
    expect(update!.mandatory, isTrue);
  });

  test('不是 https 或 sha256 不合法的条目被忽略并记一条诊断', () async {
    server.releases.addAll([
      _release(url: 'http://example.test/zhixin.apk'),
      _release(sha256: ''),
      _release(sha256: _sha256Of('uppercase').toUpperCase()),
      _release(version: '0.1.0', build: 1),
    ]);
    final updates = service();
    addTearDown(updates.dispose);

    expect(await updates.ensureChecked(), isNull);
    expect(updates.notice.value, isNull);
    expect(failures, hasLength(3));
    expect(
      failures.every((entry) => entry.kind == 'app_update_manifest'),
      isTrue,
    );
  });

  test('只取当前平台的条目，别的平台不影响提示', () async {
    server.releases.add(_release(platform: 'ios'));
    final updates = service(platform: 'android');
    addTearDown(updates.dispose);

    expect(await updates.ensureChecked(), isNull);
    expect(failures, isEmpty);
  });

  test('版本不高于当前版本时不提示更新', () async {
    server.releases.addAll([
      _release(version: '0.1.1', build: 2),
      _release(version: '0.1.0', build: 9),
    ]);
    final updates = service();
    addTearDown(updates.dispose);

    expect(await updates.ensureChecked(), isNull);
  });

  test('签名校验通过时记录已校验，签名失败时不提示', () async {
    server.releases.add(
      _release(version: '0.2.0', sha256: _signedSha, signature: _signature),
    );
    final verified = service(publicKey: _publicKey);
    addTearDown(verified.dispose);
    final update = await verified.ensureChecked();
    expect(update, isNotNull);
    expect(update!.signature, ReleaseSignatureState.verified);
    expect(update.signatureLabel, contains('已用内置公钥校验'));

    final broken = service(publicKey: _publicKey);
    addTearDown(broken.dispose);
    server.releases
      ..clear()
      ..add(
        _release(
          version: '0.2.0',
          sha256: _signedSha,
          signature: _signature.substring(0, _signature.length - 4),
        ),
      );
    expect(await broken.ensureChecked(), isNull);
    expect(
      failures.any((entry) => entry.kind == 'app_update_manifest'),
      isTrue,
    );
  });

  test('清单带签名但没有配置公钥时跳过签名校验', () async {
    server.releases.add(
      _release(version: '0.2.0', sha256: _signedSha, signature: _signature),
    );
    final updates = service();
    addTearDown(updates.dispose);

    final update = await updates.ensureChecked();
    expect(update, isNotNull);
    expect(update!.signature, ReleaseSignatureState.skippedNoKey);
    expect(update.signatureLabel, contains('跳过签名校验'));
  });

  test('关闭的检查不发请求，关闭提示之后不再出现', () async {
    server.releases.add(_release());
    final disabled = service(enabled: false);
    addTearDown(disabled.dispose);
    expect(await disabled.ensureChecked(), isNull);

    final updates = service();
    addTearDown(updates.dispose);
    expect(await updates.ensureChecked(), isNotNull);
    updates.dismiss();
    expect(updates.notice.value, isNull);
    expect(await updates.ensureChecked(), isNull);
  });
}
