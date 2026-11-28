import 'dart:typed_data';

import '../data/backup/data_version_service.dart';
import '../data/revisions/revision_service.dart';
import '../domain/models/restore_inspection.dart';
import '../domain/models/restore_point.dart';
import '../domain/models/result.dart';
import '../domain/models/revision_models.dart';
import '../domain/rules/package_budget.dart';
import '../domain/rules/time_format.dart';
import '../domain/rules/time_policy.dart';
import 'repository_integrity.dart';
import 'settings_service.dart';
import 'undo_service.dart';

/// 保存导出文件的动作：暂存压缩包并交给系统保存，返回用户选定的位置。
typedef SavePackage = Future<String?> Function({
  required String fileName,
  required Future<void> Function(String path) writePackage,
});

/// 一次数据完整性检查。
typedef IntegrityCheck = Future<RepositoryIntegrityResult> Function(
  RevisionService revisions,
);

/// 用户选中的数据包文件；大小用来在读取之前拒绝超过上限的包。
class RestorePackageFile {
  const RestorePackageFile({
    required this.name,
    required this.size,
    required this.read,
  });

  final String name;
  final int? size;
  final Future<Uint8List> Function() read;
}

/// 恢复确认框的内容：来源、影响与回退说明。
///
/// 本机版本恢复与数据包恢复都经这一份说明；页面只把它交给确认框，不再自己拼
/// 每一步的来源与影响。
class RestorePrompt {
  const RestorePrompt({
    required this.title,
    required this.sourceLines,
    required this.impactLines,
    required this.rollbackLine,
  });

  final String title;
  final List<String> sourceLines;
  final List<String> impactLines;
  final String rollbackLine;
}

/// 恢复流程需要界面配合的动作：选包、确认、拒绝后的处理与失败说明。
///
/// 业务顺序留在 [DataVersionFlows.restorePackage]，这里只把需要页面上下文的部分
/// 交给调用方：文件选择器、两个弹框、进度显示与失败记录。
class RestoreHost {
  const RestoreHost({
    required this.isActive,
    required this.pickFile,
    required this.confirm,
    required this.reject,
    required this.describeUnexpected,
    required this.describeReason,
    this.onStatus,
  });

  /// 页面是否还在树上；离开之后不再开始读摘要、确认与整库替换。
  final bool Function() isActive;

  /// 选一个数据包；用户取消时返回空。
  final Future<RestorePackageFile?> Function() pickFile;

  /// 展示确认框；用户确认返回真。
  final Future<bool> Function(RestorePrompt prompt) confirm;

  /// 包被拒时就地说明原因；返回真表示用户选择重新选包。
  final Future<bool> Function(String message, {required bool allowReselect})
  reject;

  /// 程序错误：写进本机诊断记录并给出界面说明；界面不在时用 [fallback]。
  final String Function(
    Object error,
    StackTrace stack, {
    required String action,
    required String kind,
    required String kept,
    required String next,
    required String fallback,
  })
  describeUnexpected;

  /// 可预期的失败：补上保留状态与下一步并写进诊断记录。
  final String Function(
    FailureReason reason, {
    required String kind,
    required String kept,
    required String next,
  })
  describeReason;

  /// 读包、校验与恢复期间的就地说明。
  final void Function(String message)? onStatus;
}

/// 数据版本页的业务顺序：导出、备份、导入、命名、比较、恢复、裁剪、清理、
/// 恢复点与完整性检查。
///
/// 页面只保留确认框与渲染：先做什么、失败时保留什么、结果文案与影响说明都在
/// 这里。整库恢复的选包之后的预检、摘要、确认说明与替换也在这里，页面只选择
/// 文件、显示确认框与进度。应用的装配在 `AppScopeState.dataVersionFlows`。
class DataVersionFlows {
  DataVersionFlows({
    required this.versions,
    required this.revisions,
    required this.undo,
    required this.settings,
    required this.clock,
    required this.integrityCheck,
    required this.savePackage,
  });

  final DataVersionService versions;
  final RevisionService revisions;
  final UndoService undo;
  final SettingsService settings;
  final Clock clock;
  final IntegrityCheck integrityCheck;
  final SavePackage savePackage;

  /// 导出文件名带上当天日期；两类数据包各一个前缀。
  String get currentDataFileName =>
      'zhixin-current-${compactDate(clock())}.zip';
  String get repositoryFileName =>
      'zhixin-repository-${compactDate(clock())}.zip';

  Stream<DataVersionOverview> watchOverview() => versions.watchOverview();

  Future<List<RevisionConflict>> conflicts() => revisions.conflicts();

  Future<RevisionCommit?> keepLocal(int conflictId) =>
      revisions.keepLocal(conflictId);

  Future<bool> dismissConflict(int conflictId) =>
      revisions.dismissConflict(conflictId);

  Future<RevisionDetails?> details(int commitId) => revisions.details(commitId);

  Future<RevisionDiff> compare(int from, int to) => revisions.compare(from, to);

  Future<RevisionRestorePreview> previewRestore(int target) =>
      revisions.previewRestore(target);

  Future<({RevisionCommit commit, String? cacheWarning})> restoreVersion(
    int target, {
    required int expectedHead,
  }) => revisions.restore(target, expectedHead: expectedHead);

  Future<RevisionUndoResult> undoCommit(int commitId) =>
      undo.undoCommit(commitId);

  Future<RevisionRef> name(
    int commitId, {
    required String label,
    String? note,
  }) => revisions.name(commitId, label: label, note: note);

  Future<void> deleteName(String label) => revisions.deleteName(label);

  Future<List<String>> historyBlockers({required bool clearing}) =>
      revisions.historyBlockers(clearing: clearing);

  Future<RevisionRetentionResult> prune({required int retentionDays}) =>
      revisions.prune(retentionDays: retentionDays);

  Future<void> clearHistory() => revisions.clearHistory();

  Future<RepositoryIntegrityResult> checkIntegrity() =>
      integrityCheck(revisions);

  Future<String?> exportCurrent() => savePackage(
    fileName: currentDataFileName,
    writePackage: versions.exportCurrentData,
  );

  Future<String?> backupRepository() => savePackage(
    fileName: repositoryFileName,
    writePackage: versions.backupRepository,
  );

  Future<int> currentHead() => versions.currentHead();

  Future<Result<String?>> importCurrent(
    Uint8List bytes, {
    required int expectedHead,
  }) => versions.importCurrentData(bytes, expectedHead: expectedHead);

  Future<int> retentionDays() => settings.revisionRetentionDays();

  Future<void> saveRetentionDays(int days) =>
      settings.saveRevisionRetentionDays(days);

  Future<Uint8List> readRestorePoint(RestorePoint point) =>
      versions.readRestorePoint(point);

  Future<void> deleteRestorePoint(RestorePoint point) =>
      versions.deleteRestorePoint(point);

  /// 本机版本恢复的确认说明：来源是目标提交，影响按预览的差异条数写。
  RestorePrompt versionRestorePrompt({
    required RevisionCommit commit,
    required RevisionRestorePreview preview,
  }) => RestorePrompt(
    title: '恢复到本机版本',
    sourceLines: [
      '来源：${_timeText(commit.createdAt)} 的提交 #${commit.id}'
          '（${commit.action}）。',
    ],
    impactLines: [
      '把这个版本的内容写回当前数据：新增 ${preview.diff.insertCount} 处、'
          '修改 ${preview.diff.updateCount} 处、删除 ${preview.diff.deleteCount} 处。',
      '恢复只改有差异的行；目标版本太早、提交明细已经被清理时，整库替换。',
      '恢复会追加一条提交，提交历史保留。',
    ],
    rollbackLine: '恢复前的版本留在提交历史里，恢复后可以在这一页回到恢复前。',
  );

  /// 整库恢复的确认说明：来源是文件或外部来源，影响说明写出当前库的规模。
  RestorePrompt packageRestorePrompt({
    required RestoreInspection inspection,
    required RestoreSummary summary,
    String? origin,
    String? fileName,
  }) => RestorePrompt(
    title: '从数据包恢复',
    sourceLines: [
      if (origin != null)
        '来源：$origin'
      else if (fileName != null)
        '文件：$fileName',
      ..._packageLines(inspection),
    ],
    impactLines: ['当前库会被整个替换，提交历史、命名版本与附件都以数据包为准。', _summaryLine(summary)],
    rollbackLine:
        '恢复前会自动把当前状态保存为一份恢复点；恢复完成后，'
        '可以在数据版本页的“恢复点”里回到恢复前。',
  );

  /// 整库恢复成功之后的提示；图片缓存重建失败时把提醒接在后面。
  String restoreSuccessMessage(String? cacheWarning) => cacheWarning == null
      ? '恢复完成；恢复前的状态已保存为恢复点，可在数据版本页回到恢复前'
      : '恢复完成；恢复前的状态已保存为恢复点。$cacheWarning';

  /// 整库恢复的完整顺序：选包、预检、读当前库摘要、确认、替换。
  ///
  /// 包被拒时用户可以直接在主按钮上重新选择，不必退出这一页重来；预检期间与
  /// 恢复期间的进度交给 [RestoreHost.onStatus] 就地显示，只有最终结果由调用方
  /// 提示。预检产物一路带到恢复入口，同一次恢复只解包与校验一次。
  /// 返回结果提示；用户取消或预检不通过时返回空。
  Future<String?> restorePackage({
    required RestoreHost host,
    Uint8List? preset,
    String? origin,
  }) async {
    Uint8List? bytes = preset;
    String? fileName;
    while (true) {
      if (bytes == null) {
        final picked = await host.pickFile();
        if (picked == null) return null;
        fileName = picked.name;
        // 超过上限的包不读进内存：先看文件大小，再决定是否读取。
        if (picked.size case final size? when size > dataPackageMaxBytes) {
          final message = dataPackageTooLargeMessage(size);
          host.onStatus?.call(message);
          if (await host.reject(message, allowReselect: preset == null)) {
            fileName = null;
            continue;
          }
          return null;
        }
        host.onStatus?.call('正在读取数据包…');
        bytes = await picked.read();
      }

      host.onStatus?.call('正在校验数据包…');
      final Result<RestoreInspection> inspected;
      try {
        inspected = await versions.inspectRestorePackage(bytes);
      } catch (error, stack) {
        final message = host.describeUnexpected(
          error,
          stack,
          action: '校验数据包',
          kind: 'restore_inspect',
          kept: '当前数据没有改动',
          next: '可以换一个数据包再试',
          fallback: '数据包不能恢复，当前数据没有改动。',
        );
        host.onStatus?.call(message);
        if (await host.reject(message, allowReselect: preset == null)) {
          bytes = null;
          fileName = null;
          continue;
        }
        return null;
      }

      switch (inspected) {
        case Success(:final value):
          if (!host.isActive()) return null;
          final summary = await versions.currentRestoreSummary();
          if (!host.isActive()) return null;
          final confirmed = await host.confirm(
            packageRestorePrompt(
              inspection: value,
              summary: summary,
              origin: origin,
              fileName: fileName,
            ),
          );
          if (!confirmed || !host.isActive()) {
            host.onStatus?.call('已取消恢复');
            return null;
          }

          host.onStatus?.call('正在恢复…');
          final Result<String?> restored;
          try {
            restored = await versions.restoreInspected(value);
          } catch (error, stack) {
            return host.describeUnexpected(
              error,
              stack,
              action: '恢复数据包',
              kind: 'restore_apply',
              kept: '当前数据保留',
              next: '可以检查数据包后重试',
              fallback: '恢复失败，当前数据没有改动。',
            );
          }
          switch (restored) {
            case Success(:final value):
              return restoreSuccessMessage(value);
            case Failure(:final reason):
              return host.describeReason(
                reason,
                kind: 'restore_apply',
                kept: '当前数据保留',
                next: '可以检查数据包后重试',
              );
          }
        case Failure(:final reason):
          final message = host.describeReason(
            reason,
            kind: 'restore_inspect',
            kept: '当前数据没有改动',
            next: '可以换一个数据包再试',
          );
          host.onStatus?.call(message);
          if (await host.reject(message, allowReselect: preset == null)) {
            bytes = null;
            fileName = null;
            continue;
          }
          return null;
      }
    }
  }

  List<String> _packageLines(RestoreInspection inspection) {
    final exported = _exportedAt(inspection.exportedAt);
    final suffix = exported.isEmpty ? '' : '，导出于 $exported';
    return switch (inspection.kind) {
      RestorePackageKind.repository => [
        '版本库备份：HEAD ${inspection.head ?? 0}，'
            '${inspection.commitCount} 条提交，${inspection.namedCount} 个命名版本'
            '$suffix。',
      ],
      RestorePackageKind.currentData => [
        '当前数据包（schema v${inspection.schemaVersion}）'
            '${inspection.rowCount == 0 ? '' : '，共 ${inspection.rowCount} 条业务记录'}'
            '$suffix。',
      ],
    };
  }

  String _summaryLine(RestoreSummary summary) =>
      '当前库：HEAD ${summary.head}，${summary.commitCount} 条提交，'
      '${summary.namedCount} 个命名版本。';

  String _exportedAt(String value) {
    final parsed = DateTime.tryParse(value);
    return parsed == null ? '' : shortTime(parsed.toLocal(), now: clock());
  }

  String _timeText(DateTime? time) =>
      time == null ? '时间未知' : shortTime(time, now: clock());
}
