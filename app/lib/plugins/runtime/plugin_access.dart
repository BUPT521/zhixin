/// 插件访问应用能力的四个门面：网络、读数据、提交草稿、调用模型。
///
/// 插件只拿到 [PluginAccess]，不直接访问网络客户端、数据库或模型客户端；每次
/// 调用先按清单核对权限，未声明时在调用点抛出 [PluginPermissionDenied]，不做
/// 静默降级。本期没有接入真实实现，声明了权限的调用会得到
/// [PluginCapabilityUnavailable]，等 M3 再接上具体能力。
library;

import 'plugin_manifest.dart';

/// 插件调用了没有声明的权限；调用点直接失败，不退回默认行为。
final class PluginPermissionDenied implements Exception {
  const PluginPermissionDenied({
    required this.pluginId,
    required this.permission,
    this.detail = '',
  });

  final String pluginId;
  final PluginPermission permission;

  /// 具体被拒绝的域名、数据范围或写入类型；没有细分时为空。
  final String detail;

  @override
  String toString() => detail.isEmpty
      ? '插件 $pluginId 没有声明${permission.label}权限，调用已拒绝'
      : '插件 $pluginId 的${permission.label}权限不包含 $detail，调用已拒绝';
}

/// 权限已经声明，但对应的能力本期还没有接入；运行时给出同一个失败类型。
final class PluginCapabilityUnavailable implements Exception {
  const PluginCapabilityUnavailable({
    required this.pluginId,
    required this.permission,
  });

  final String pluginId;
  final PluginPermission permission;

  @override
  String toString() => '插件 $pluginId 已声明${permission.label}权限，但这项能力还没有接入';
}

/// 插件传入门面的参数不完整或格式不对；这类错误与权限无关，属于插件自身的问题。
final class PluginArgumentError implements Exception {
  const PluginArgumentError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 网络访问的后端；由应用层实现，本期不接入真实请求。
abstract interface class PluginNetworkBackend {
  /// 请求一个清单已放行的地址；返回值由应用层决定，插件按自己的格式解析。
  Future<Object?> fetch(Uri url);
}

/// 读取数据的后端；按范围名称读取，本期只保留接口。
abstract interface class PluginDataReadBackend {
  Future<Object?> read({
    required String scope,
    required Map<String, Object?> query,
  });
}

/// 提交草稿的后端；由应用服务校验并写入，形成一条可以撤销的提交。
abstract interface class PluginDraftSubmitBackend {
  /// 返回这次提交的说明或编号，供插件在界面上引用。
  Future<String> submit({
    required String writeType,
    required Map<String, Object?> draft,
  });
}

/// 调用模型的后端；插件不能自己发模型请求。
abstract interface class PluginModelCallBackend {
  Future<String> complete({required String prompt});
}

/// 四个门面共用的权限守卫。
///
/// 先看清单有没有声明这项权限，再看这次调用的细分项（域名、数据范围、写入
/// 类型）在不在声明里，最后取已经接入的后端；三处失败各给一个固定类型，不
/// 静默降级。四个门面原先各写一遍这段判断，改一处时另外三处仍按旧规则放行。
T pluginAccessGuard<T extends Object>(
  PluginManifest manifest,
  PluginPermission permission,
  T? backend, {
  bool allowed = true,
  String detail = '',
}) {
  if (!manifest.permissions.allows(permission)) {
    throw PluginPermissionDenied(pluginId: manifest.id, permission: permission);
  }
  if (!allowed) {
    throw PluginPermissionDenied(
      pluginId: manifest.id,
      permission: permission,
      detail: detail,
    );
  }
  final value = backend;
  if (value == null) {
    throw PluginCapabilityUnavailable(
      pluginId: manifest.id,
      permission: permission,
    );
  }
  return value;
}

/// 网络访问门面：先核对清单声明的域名，再交给应用层实现。
final class PluginNetworkAccess {
  const PluginNetworkAccess({required this.manifest, this.backend});

  final PluginManifest manifest;
  final PluginNetworkBackend? backend;

  Future<Object?> fetch(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) {
      throw PluginArgumentError('地址无法解析：$url');
    }
    final host = uri.host.toLowerCase();
    final declared = manifest.permissions;
    final backend = pluginAccessGuard(
      manifest,
      PluginPermission.network,
      this.backend,
      allowed: declared.networkDomains.any(
        (domain) => host == domain || host.endsWith('.$domain'),
      ),
      detail: '域名 $host',
    );
    return backend.fetch(uri);
  }
}

/// 读取数据门面：先核对数据范围，再交给应用层实现。
final class PluginDataReadAccess {
  const PluginDataReadAccess({required this.manifest, this.backend});

  final PluginManifest manifest;
  final PluginDataReadBackend? backend;

  Future<Object?> read({
    required String scope,
    Map<String, Object?> query = const {},
  }) async {
    final backend = pluginAccessGuard(
      manifest,
      PluginPermission.readData,
      this.backend,
      allowed: manifest.permissions.readDataScopes.contains(scope),
      detail: '数据范围 $scope',
    );
    return backend.read(scope: scope, query: query);
  }
}

/// 提交草稿门面：先核对写入类型，再交给应用服务校验与写入。
final class PluginDraftSubmitAccess {
  const PluginDraftSubmitAccess({required this.manifest, this.backend});

  final PluginManifest manifest;
  final PluginDraftSubmitBackend? backend;

  Future<String> submit({
    required String writeType,
    required Map<String, Object?> draft,
  }) async {
    final backend = pluginAccessGuard(
      manifest,
      PluginPermission.submitDraft,
      this.backend,
      allowed: manifest.permissions.writeTypes.contains(writeType),
      detail: '写入类型 $writeType',
    );
    return backend.submit(writeType: writeType, draft: draft);
  }
}

/// 调用模型门面：清单没有声明时拒绝，插件不能自行拿到模型客户端。
final class PluginModelCallAccess {
  const PluginModelCallAccess({required this.manifest, this.backend});

  final PluginManifest manifest;
  final PluginModelCallBackend? backend;

  Future<String> complete(String prompt) async {
    final backend = pluginAccessGuard(
      manifest,
      PluginPermission.callModel,
      this.backend,
    );
    return backend.complete(prompt: prompt);
  }
}

/// 插件拿到的全部访问入口；运行时按清单创建一份，插件不能自己换掉清单。
final class PluginAccess {
  PluginAccess({
    required PluginManifest manifest,
    PluginNetworkBackend? network,
    PluginDataReadBackend? dataRead,
    PluginDraftSubmitBackend? draftSubmit,
    PluginModelCallBackend? modelCall,
  }) : network = PluginNetworkAccess(manifest: manifest, backend: network),
       readData = PluginDataReadAccess(manifest: manifest, backend: dataRead),
       submitDraft = PluginDraftSubmitAccess(
         manifest: manifest,
         backend: draftSubmit,
       ),
       callModel = PluginModelCallAccess(
         manifest: manifest,
         backend: modelCall,
       );

  final PluginNetworkAccess network;
  final PluginDataReadAccess readData;
  final PluginDraftSubmitAccess submitDraft;
  final PluginModelCallAccess callModel;
}
