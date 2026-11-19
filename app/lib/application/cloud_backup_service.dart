import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../data/cloud/server_client.dart';
import '../data/backup/data_version_service.dart';
import '../data/db/app_database.dart' show zhixinSchemaVersion;
import '../domain/rules/time_policy.dart';
import 'account_service.dart';

/// 云端整库备份：上传本机版本库快照、列出、下载与删除。
///
/// 备份内容就是“备份版本库”生成的那个 zip；恢复仍走本机已有的预检、确认与
/// 恢复点流程，服务端只保存字节，不解析内容。每份备份计入服务端的保留份数，
/// 上传新的一份时服务端会删除最旧的一份。
class CloudBackupService {
  CloudBackupService({
    required this.account,
    required this.versions,
    required this.filesDir,
    required this.clock,
  });

  final AccountService account;
  final DataVersionService versions;
  final String filesDir;
  final Clock clock;

  /// 列出云端备份，新的在前；没有登录时抛出 [AccountSignedOut]。
  Future<List<ServerBackup>> list() =>
      account.call((client, token) => client.backupList(token));

  /// 上传当前版本库：先生成本机快照，再按哈希上传，最后删掉临时文件。
  Future<ServerBackup> upload() async {
    final file = File(
      p.join(filesDir, 'cloud_backup_${clock().millisecondsSinceEpoch}.zip'),
    );
    try {
      await versions.backupRepository(file.path);
      final bytes = await file.readAsBytes();
      final sha = sha256.convert(bytes).toString();
      return await account.call(
        (client, token) => client.backupUpload(
          token,
          bytes: bytes,
          sha256: sha,
          schemaVersion: zhixinSchemaVersion,
          deviceName: account.deviceName,
        ),
      );
    } finally {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {
        // 临时文件删不掉不影响这次备份，下次启动再清理。
      }
    }
  }

  /// 下载一份备份的原始字节；下载后交给本机版本库恢复流程预检。
  Future<Uint8List> download(String id) async {
    final response = await account.call(
      (client, token) => client.backupDownload(token, id),
    );
    final bytes = response.bodyBytes;
    final expected = response.headers['x-content-sha256'];
    if (expected != null &&
        expected.isNotEmpty &&
        sha256.convert(bytes).toString() != expected) {
      throw const FormatException('云端备份下载不完整，校验值不一致');
    }
    return bytes;
  }

  Future<void> delete(String id) =>
      account.call((client, token) => client.backupDelete(token, id));

  /// 删除该账号的全部云端备份，账号与同步序列保留。
  Future<void> deleteAll({required String password}) => account.call(
    (client, token) => client.deleteAllBackups(token, password: password),
  );
}
