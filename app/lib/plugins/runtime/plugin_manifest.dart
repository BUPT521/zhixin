/// 插件清单：第一方插件在编译期声明标识、名称、版本、说明、类型与权限。
///
/// 清单随应用一起编译，运行时只按清单注册与显示，不读取远程清单；校验失败时
/// 返回可以直接显示给人看的说明，不做静默修正。形态与权限的取舍见
/// `docs/adr/0010-客户端插件的两种形态与权限.md`。
library;

/// 插件类型：能力插件是可执行的第一方模块，人格插件是一段文本配置。
enum PluginKind {
  capability('capability'),
  persona('persona');

  const PluginKind(this.value);

  final String value;
}

/// 权限的四项：网络访问的域名、可以读取的数据范围、可以提交的写入类型与是否
/// 调用模型。未声明的权限在调用点拒绝，不做静默降级。
enum PluginPermission {
  network('网络访问'),
  readData('读取数据'),
  submitDraft('提交草稿'),
  callModel('调用模型');

  const PluginPermission(this.label);

  final String label;
}

/// 一份清单声明的权限；全部为空表示插件不访问任何应用能力。
///
/// 四项分别保存具体范围而不是一个布尔值：网络只放行清单列出的域名，读取与
/// 写入按范围名称核对，调用模型单独一项。人格插件不得声明其中任何一项。
class PluginPermissions {
  const PluginPermissions({
    this.networkDomains = const [],
    this.readDataScopes = const [],
    this.writeTypes = const [],
    this.callModel = false,
  });

  /// 不做任何访问的权限声明。
  static const none = PluginPermissions();

  /// 可以访问的域名；子域名按后缀放行，例如 `example.com` 包含 `api.example.com`。
  final List<String> networkDomains;

  /// 可以读取的数据范围名称，由应用层的数据门面定义。
  final List<String> readDataScopes;

  /// 可以提交的草稿类型，例如课表导入；草稿由应用服务校验之后才写入。
  final List<String> writeTypes;

  /// 是否允许调用模型。
  final bool callModel;

  bool get isEmpty =>
      networkDomains.isEmpty &&
      readDataScopes.isEmpty &&
      writeTypes.isEmpty &&
      !callModel;

  /// 这一项权限是否有声明；网络、读取与写入按列表是否为空判断。
  bool allows(PluginPermission permission) => switch (permission) {
    PluginPermission.network => networkDomains.isNotEmpty,
    PluginPermission.readData => readDataScopes.isNotEmpty,
    PluginPermission.submitDraft => writeTypes.isNotEmpty,
    PluginPermission.callModel => callModel,
  };

  /// 已经声明的权限项，按四项的固定顺序排列。
  List<PluginPermission> get declared => [
    for (final permission in PluginPermission.values)
      if (allows(permission)) permission,
  ];
}

/// 不可变清单：一个插件一份，运行时不改写。
final class PluginManifest {
  const PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    required this.kind,
    this.permissions = PluginPermissions.none,
  });

  /// 插件标识，也是目录名与设置键的一部分；只用小写字母、数字与连字符。
  final String id;
  final String name;
  final String version;
  final String description;
  final PluginKind kind;
  final PluginPermissions permissions;

  /// 返回全部不合格项；为空表示清单可用。
  List<String> validate() => validatePluginManifest(this);
}

/// 插件标识的规则：小写字母、数字与连字符，以字母或数字开头和结尾。
final RegExp _pluginIdPattern = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');

/// 版本写成三段数字，方便设置页显示与比较。
final RegExp _versionPattern = RegExp(r'^\d+\.\d+\.\d+$');

/// 域名不带协议、路径与空格；通配符与端口也不在清单里声明。
final RegExp _domainPattern = RegExp(r'^[a-z0-9.-]+$');

/// 校验一份清单，返回可以直接显示的错误；为空表示通过。
///
/// 人格插件只影响提示词，不需要任何权限，因此声明了四项中的任意一项都算失败；
/// 能力插件可以声明权限，也可以先声明为空，等真正接入时再补。
List<String> validatePluginManifest(PluginManifest manifest) {
  final errors = <String>[];

  final id = manifest.id;
  if (id.trim().isEmpty) {
    errors.add('插件标识不能为空');
  } else if (!_pluginIdPattern.hasMatch(id)) {
    errors.add('插件标识只能用半角小写字母、数字与连字符，并以字母或数字开头和结尾：$id');
  }

  if (manifest.name.trim().isEmpty) {
    errors.add('插件名称不能为空');
  }

  final version = manifest.version;
  if (version.trim().isEmpty) {
    errors.add('插件版本不能为空');
  } else if (!_versionPattern.hasMatch(version)) {
    errors.add('插件版本写成三段数字，例如 1.0.0：$version');
  }

  if (manifest.description.trim().isEmpty) {
    errors.add('插件说明不能为空');
  }

  if (manifest.kind == PluginKind.persona && !manifest.permissions.isEmpty) {
    final declared = manifest.permissions.declared
        .map((permission) => permission.label)
        .join('、');
    errors.add('人格插件不能声明权限，当前声明了：$declared');
  }

  final permissions = manifest.permissions;
  for (final domain in permissions.networkDomains) {
    if (domain.trim().isEmpty) {
      errors.add('网络访问的域名不能为空');
    } else if (!_domainPattern.hasMatch(domain) ||
        domain.startsWith('.') ||
        domain.endsWith('.')) {
      errors.add('网络访问的域名只写主机名，不带协议、路径或空格：$domain');
    }
  }
  for (final scope in permissions.readDataScopes) {
    if (scope.trim().isEmpty) {
      errors.add('读取数据的范围不能为空');
    }
  }
  for (final writeType in permissions.writeTypes) {
    if (writeType.trim().isEmpty) {
      errors.add('可以提交的写入类型不能为空');
    }
  }

  return errors;
}
