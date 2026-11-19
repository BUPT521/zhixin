/// 发布清单的 Ed25519 公钥（PEM，SubjectPublicKeyInfo 格式）。
///
/// 官方构建使用 [defaultReleasePublicKeyPem]，构建时可通过
/// `--dart-define=RELEASE_PUBLIC_KEY_PEM="-----BEGIN PUBLIC KEY-----…"` 覆盖。
/// 清单里的 `signature` 由配对的私钥生成，见 app/README.md 的“发布清单签名”。
///
/// 私钥由发版人保管，CI 从仓库 Secret 读取。
const String defaultReleasePublicKeyPem = '''
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAS63pfXe08lhGy8oA2I9MI9zWvzDTZnd1G0IRo5OWuWI=
-----END PUBLIC KEY-----
''';

/// 实际使用的公钥：构建参数优先，没有时用内置常量。
const String releasePublicKeyPem = String.fromEnvironment(
  'RELEASE_PUBLIC_KEY_PEM',
  defaultValue: defaultReleasePublicKeyPem,
);
