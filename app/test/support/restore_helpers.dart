import 'dart:typed_data';

import 'package:zhixin/data/backup/data_version_service.dart';
import 'package:zhixin/domain/models/result.dart';

/// 先预检再恢复，结果形状与原来的整库恢复入口相同。
///
/// 恢复入口只接受预检产物，这样同一次恢复只解包一次、只跑一次完整性校验；
/// 用例要走“拿到字节就恢复”的路径时用这一段，预检失败按同一个 [Result]
/// 返回，成功再交给 [DataVersionService.restoreInspected]。
Future<Result<String?>> restoreFromBytes(
  DataVersionService service,
  Uint8List bytes,
) async {
  final inspected = await service.inspectRestorePackage(bytes);
  final inspection = inspected.valueOrNull;
  if (inspection == null) return Failure<String?>(inspected.failureOrNull!);
  return service.restoreInspected(inspection);
}
