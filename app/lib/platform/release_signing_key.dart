/// 发布清单的 Ed25519 公钥（PEM，SubjectPublicKeyInfo 格式）。
///
/// 发版人用自己的 `release-signing.pub.pem` 内容替换 [defaultReleasePublicKeyPem]
/// 之后再发版，或者在构建时用
/// `--dart-define=RELEASE_PUBLIC_KEY_PEM="-----BEGIN PUBLIC KEY-----…"` 传入；
/// 两种方式取其一，公钥随包内置。清单里的 `signature` 必须用与这把公钥配对的
/// 私钥签名，应用才能验过，见 app/README.md 的“发布清单签名”。
///
/// 私钥只在发版人手里，不进入仓库与本机工程目录；默认留空时清单带签名按验签
/// 失败处理，应用不提示更新。
const String defaultReleasePublicKeyPem = '';

/// 实际使用的公钥：构建参数优先，没有时用内置常量。
const String releasePublicKeyPem = String.fromEnvironment(
  'RELEASE_PUBLIC_KEY_PEM',
  defaultValue: defaultReleasePublicKeyPem,
);
