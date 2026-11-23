import 'dart:io';

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
///
/// 上传与下载都不把整包读进内存：上传先分块算哈希再从文件流发送，下载边收边写
/// 临时文件并在流上核对校验值。临时文件在成功与失败路径上都会删除。
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

  /// 上传当前版本库：先生成本机快照，再按文件流上传，最后删掉临时文件。
  Future<ServerBackup> upload() async {
    await _sweepTemporaryFiles();
    final file = File(
      p.join(filesDir, 'cloud_backup_${clock().millisecondsSinceEpoch}.zip'),
    );
    try {
      await versions.backupRepository(file.path);
      final sha = await _sha256OfFile(file);
      return await account.call(
        (client, token) => client.backupUpload(
          token,
          file: file,
          sha256: sha,
          schemaVersion: zhixinSchemaVersion,
          deviceName: account.deviceName,
        ),
      );
    } finally {
      await _deleteQuietly(file);
    }
  }

  /// 下载一份备份到临时文件，边收边核对校验值。
  ///
  /// 返回的临时文件归调用方所有，用完要删除；校验值不一致、超时或写入失败时
  /// 这里已经删掉，调用方拿到的失败路径上没有残留文件。
  Future<File> download(String id) async {
    await _sweepTemporaryFiles();
    final file = File(
      p.join(filesDir, 'cloud_download_${clock().millisecondsSinceEpoch}.zip'),
    );
    try {
      await account.call(
        (client, token) => client.backupDownloadTo(token, id, file),
      );
      return file;
    } catch (_) {
      await _deleteQuietly(file);
      rethrow;
    }
  }

  Future<void> delete(String id) =>
      account.call((client, token) => client.backupDelete(token, id));

  /// 删除该账号的全部云端备份，账号与同步序列保留。
  Future<void> deleteAll({required String password}) => account.call(
    (client, token) => client.deleteAllBackups(token, password: password),
  );

  /// 在文件上分块算 SHA-256，不在内存里读整包。
  Future<String> _sha256OfFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  /// 删除上次中断留下的临时包，上传与下载都先清一次再生成新文件。
  Future<void> _sweepTemporaryFiles() async {
    try {
      final directory = Directory(filesDir);
      if (!await directory.exists()) return;
      await for (final entity in directory.list()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.startsWith('cloud_backup_') ||
            name.startsWith('cloud_download_')) {
          await _deleteQuietly(entity);
        }
      }
    } catch (_) {
      // 清理失败不影响这次备份，下次再试。
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 临时文件删不掉不影响这次备份，下次启动再清理。
    }
  }
}
