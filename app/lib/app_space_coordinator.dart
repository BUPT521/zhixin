import 'app_composition.dart';
import 'domain/models/server_models.dart' show ServerProblem;
import 'platform/app_paths.dart';

/// 空间切换与清空：换库、删掉当前空间、清空本机学习数据与云端数据。
///
/// 空间由应用根部切换（设备目录不变，数据目录换一份），这里只把页面上的动作
/// 翻成应用根的回调，并在换空间之前按顺序关掉这一份装配。测试不管理空间时，
/// 清空只删本机库与附件。
class AppSpaceCoordinator {
  AppSpaceCoordinator(this._composition);

  final AppComposition _composition;

  /// 是否管理多空间；由应用根部把换空间回调传进来时才算。
  bool get managesSpaces => _composition.managesSpaces;

  /// 当前本机空间的标识。
  String get spaceId => _composition.spaceId;

  /// 全部本机空间；不管理空间的装配为空。
  AppSpaces? get spaces => _composition.spaces;

  /// 设备级目录：空间标识、引导状态与诊断都写在这里，换空间时不变。
  AppPaths get devicePaths => _composition.devicePaths;

  /// 换到另一个本机空间；应用根部负责关旧库、换目录与重建整棵树。
  Future<void> changeSpace(
    String id, {
    bool adoptLocal = false,
    bool deleteCurrent = false,
    String? label,
  }) async => _composition.changeSpace?.call(
    id,
    adoptLocal: adoptLocal,
    deleteCurrent: deleteCurrent,
    label: label,
  );

  /// 清空数据：先停自动同步并清云端，再按是否管理空间删掉整个空间或只删本机库。
  ///
  /// 云端清理失败时按原样恢复自动同步开关再抛出：账号凭据失效（
  /// `invalid_credentials`）时用户还要能继续登录，开关停在关上的状态会让下一次
  /// 登录之后的数据一直不推。
  Future<void> clearAllData({required String password}) async {
    final sync = _composition.sync!;
    await sync.withSyncPaused(() async {
      final account = _composition.account;
      final autoSync = await account.autoSync();
      if (autoSync) await account.setAutoSync(false);
      try {
        await account.clearCloudData(password: password);
      } on ServerProblem catch (error) {
        if (autoSync && error.code == 'invalid_credentials') {
          await account.setAutoSync(true);
        }
        rethrow;
      }
      if (managesSpaces) {
        await changeSpace(spaceId, deleteCurrent: true);
      } else {
        await _composition.dataVersions.resetAllData();
        await sync.clearState(forgetPosition: true);
      }
    });
  }

  /// 删掉一个本机空间：当前空间连同数据目录一起换掉，其余空间直接删目录。
  Future<void> deleteLocalSpace(String id) async {
    if (id == spaceId) {
      await changeSpace(id, deleteCurrent: true);
    } else {
      await spaces!.delete(id);
    }
  }

  /// 换空间之前关掉这一份装配；多次调用返回同一个 Future。
  Future<void> closeSpace() => _composition.close();

  /// 是否正在关闭；关闭期间后台维护不再开始新的步骤。
  bool get closing => _composition.closing;
}
