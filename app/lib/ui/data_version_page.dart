import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../app_scope.dart';
import '../application/prefetch_service.dart';
import '../data/backup/data_version_service.dart';
import '../data/backup/restore_point_store.dart';
import '../data/revisions/revision_models.dart';
import '../data/revisions/revision_service.dart' show RevisionDetails;
import '../domain/models/result.dart';
import '../platform/data_package_export.dart';
import 'copy.dart';
import 'data_version_watcher.dart';
import 'failure_feedback.dart';
import 'format.dart';
import 'live_view.dart';
import 'navigation.dart';
import 'restore_flow.dart';
import 'zhixin_dialog.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';
import 'zhixin_icon_button.dart';
import 'zhixin_menu.dart';
import 'zhixin_select.dart';
import 'zhixin_sheet.dart';
import 'zhixin_toast.dart';

/// 数据版本：提交历史、比较、命名、撤销、整版恢复、留存清理与两类数据包。
class DataVersionPage extends StatefulWidget {
  const DataVersionPage({super.key});

  @override
  State<DataVersionPage> createState() => _DataVersionPageState();
}

class _DataVersionPageState extends State<DataVersionPage>
    with DataVersionWatcher<DataVersionPage> {
  /// 一屏订阅：历史、撤销判断、存储占用与恢复点随写入更新（ADR-0014）。
  Stream<DataVersionOverview>? _stream;
  DataVersionOverview? _view;

  /// 一级界面切进来时已经读好的首屏；有它就先显示内容，不再摆骨架。
  DataVersionOverview? _initial;

  bool _busy = false;
  int _keep = 100;

  /// 提交历史先渲染的条数；点“读取更早的提交”再加一页。
  static const int _historyPageSize = 30;
  int _historyLimit = _historyPageSize;

  /// 恢复过程（读包、校验、写入）的就地说明；只有最终结果才弹提示。
  String? _restoreStatus;

  /// 第一次读取失败时的说明；重新订阅之后清除。
  String? _loadFailure;

  /// 提交历史的定位点：恢复、撤销或导入之后把新增的提交带回视野。
  final _historyKey = GlobalKey();

  /// 下一次整屏结果到达时把提交历史滚进视野；写入追加提交之后置位。
  bool _revealHistory = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 页面一进入就订阅整屏读取，写入之后的重新读取由数据层完成。
    final scope = AppScope.of(context);
    watchDataVersion(scope.dataVersion);
    _stream ??= _createStream();
    // 从“我的”打开时，一级界面切进来之后已经在后台读过一屏。
    _initial ??= scope.prefetch.peek<DataVersionOverview>(
      PrefetchKey.dataVersion,
    );
    _view ??= _initial;
  }

  Stream<DataVersionOverview> _createStream() =>
      AppScope.of(context).data.versions.watchOverview();

  /// 恢复、撤销或清理之后换一条新流：预读的快照可能早于这次写入，不能继续用。
  @override
  void onDataVersionChanged() {
    if (!mounted) return;
    setState(() {
      _initial = null;
      _view = null;
      _loadFailure = null;
      _stream = _createStream();
    });
  }

  /// 重试：换一条新流，首读失败的说明随之清除。
  void _reload() {
    setState(() {
      _loadFailure = null;
      _stream = _createStream();
    });
  }

  /// 结果到达：换掉页面上的历史与恢复点，并清掉失败说明。
  ///
  /// 恢复、撤销与导入追加的提交排在列表最前面；用户停在原来的位置时看不到
  /// 它，会以为操作没有执行，所以这些操作之后把提交历史带回视野。
  void _onView(DataVersionOverview view) {
    _view = view;
    if (_loadFailure != null) setState(() => _loadFailure = null);
    if (!_revealHistory) return;
    _revealHistory = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final anchor = _historyKey.currentContext;
      if (anchor == null) return;
      Scrollable.ensureVisible(
        anchor,
        alignment: 0.05,
        duration: const Duration(milliseconds: 240),
      );
    });
  }

  /// 追加提交之后换一条新流：等新结果到达再滚动，新增的提交已经在列表里。
  void _showAppendedCommit() {
    _revealHistory = true;
    _reload();
  }

  void _onViewError(Object error, StackTrace stack) {
    if (!mounted) return;
    final message = describeFailure(
      context,
      error,
      stack,
      action: '读取数据版本',
      kind: 'data_version_read',
      kept: '本机数据没有改动',
      next: '可以点重试再读一次',
    );
    setState(() => _loadFailure = message);
    showToast(context, message);
  }

  void _report(String message) {
    if (!mounted) return;
    showToast(context, message);
  }

  Future<void> _name([int? commitId]) async {
    final scope = AppScope.of(context);
    final target = commitId ?? _view?.history.head;
    if (target == null || _busy) return;
    final name = TextEditingController();
    final note = TextEditingController();
    final confirmed = await showZhixinAlert<bool>(
      context: context,
      title: '保存命名版本',
      cancelLabel: '取消',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          forui.FTextField(
            control: .managed(controller: name),
            autofocus: true,
            maxLength: 30,
            label: const Text('名称'),
          ),
          SizedBox(height: context.zhixin.space.gap),
          forui.FTextField(
            control: .managed(controller: note),
            maxLength: 60,
            label: const Text('备注（可选）'),
          ),
        ],
      ),
      actions: [
        // 名称为空时保存按钮不可点，用户不会以为点了没反应。
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: name,
          builder: (context, value, _) => forui.FButton(
            mainAxisSize: MainAxisSize.min,
            onPress: value.text.trim().isEmpty
                ? null
                : () => Navigator.of(context).pop(true),
            child: const Text('保存'),
          ),
        ),
      ],
    );
    final label = name.text.trim();
    final memo = note.text.trim();
    name.dispose();
    note.dispose();
    if (confirmed != true || label.isEmpty) return;
    setState(() => _busy = true);
    try {
      await scope.data.revisions.name(target, label: label, note: memo);
      _report('已保存命名版本“$label”');
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '保存命名版本',
          kind: 'data_version_name',
          kept: '提交历史没有改动',
          next: '可以再试一次',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _details(RevisionCommit commit) async {
    final scope = AppScope.of(context);
    try {
      final details = await scope.data.revisions.details(commit.id);
      if (!mounted) return;
      if (details == null) {
        _report('这条提交的明细已经不在本机，提交历史里仍然列着它。');
        return;
      }
      await _showDetails(details);
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '查看提交明细',
          kind: 'data_version_details',
          kept: '提交历史没有改动',
          next: '可以再试一次',
        ),
      );
    }
  }

  Future<void> _showDetails(RevisionDetails details) {
    final commit = details.commit;
    final theme = context.zhixin;
    return showZhixinSheet<void>(
      context: context,
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(
          theme.space.page,
          0,
          theme.space.page,
          theme.space.page,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(commit.action, style: theme.text.titleMedium),
            Text(
              '${_timeText(commit.createdAt)} · ${_actorLabel(commit.actor)} · '
              '${commit.changeCount} 处变化',
              style: theme.text.bodySmall,
            ),
            SizedBox(height: theme.space.md),
            if (details.changes.isEmpty)
              const Text('这次提交没有明细。')
            else
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final change in details.changes)
                        _changeTile(theme, change),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 一条净变化：字段名换成中文，映射不到的内部字段不显示。
  Widget _changeTile(ZhixinTheme theme, RevisionChange change) {
    final before = change.before;
    final after = change.after;
    final keys = <String>{
      ...?before?.keys,
      ...?after?.keys,
    }.where(_fieldLabels.containsKey).toList()..sort();
    return Padding(
      padding: EdgeInsets.only(bottom: theme.space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_tableLabel(change.table)} · ${_opLabel(change.op)}',
            style: theme.text.labelLarge,
          ),
          for (final key in keys) _changeLine(theme, change, key),
        ],
      ),
    );
  }

  /// 明细里的一行：更新写前后值，新增与删除只写一侧。
  Widget _changeLine(ZhixinTheme theme, RevisionChange change, String key) {
    final before = _fieldText(change.table, key, change.before?[key]);
    final after = _fieldText(change.table, key, change.after?[key]);
    final text = change.isUpdate
        ? '${_fieldLabels[key]}：$before → $after'
        : '${_fieldLabels[key]}：${change.isDelete ? before : after}';
    return Text(text, style: theme.text.bodySmall);
  }

  Future<void> _compare(int head, RevisionCommit commit) async {
    final scope = AppScope.of(context);
    final RevisionDiff diff;
    try {
      diff = await scope.data.revisions.compare(commit.id, head);
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '比较当前版本',
          kind: 'data_version_compare',
          kept: '当前数据没有改动',
          next: '可以再试一次',
        ),
      );
      return;
    }
    if (!mounted) return;
    final theme = context.zhixin;
    await showZhixinSheet<void>(
      context: context,
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(
          theme.space.page,
          0,
          theme.space.page,
          theme.space.page,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('与当前版本比较', style: theme.text.titleMedium),
            Text(
              '新增 ${diff.insertCount} · 修改 ${diff.updateCount} · '
              '删除 ${diff.deleteCount}',
              style: theme.text.bodySmall,
            ),
            SizedBox(height: theme.space.md),
            if (diff.isEmpty)
              const Text('两个版本的业务数据一致。')
            else
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final entry in diff.entries) _diffTile(theme, entry),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 比较结果的一行：表与动作之外，只列映射得到中文名的字段。
  Widget _diffTile(ZhixinTheme theme, RevisionDiffEntry entry) {
    final columns = entry.columns
        .map((column) => _fieldLabels[column])
        .whereType<String>()
        .toList(growable: false);
    return Padding(
      padding: EdgeInsets.only(bottom: theme.space.tight),
      child: Text(
        '${_tableLabel(entry.table)} · ${_opLabel(entry.op)} · ${entry.rowKey}'
        '${columns.isEmpty ? '' : '（${columns.join('、')}）'}',
        style: theme.text.bodySmall,
      ),
    );
  }

  Future<void> _restore(RevisionCommit commit) async {
    if (_busy) return;
    final scope = AppScope.of(context);
    setState(() => _busy = true);
    try {
      final preview = await scope.data.revisions.previewRestore(commit.id);
      if (!mounted) return;
      final confirmed = await showRestoreConfirmDialog(
        context,
        title: '恢复到本机版本',
        sourceLines: [
          '来源：${_timeText(commit.createdAt)} 的提交 #${commit.id}'
              '（${commit.action}）。',
        ],
        impactLines: [
          '按这个版本重建当前数据：新增 ${preview.diff.insertCount} 处、'
              '修改 ${preview.diff.updateCount} 处、删除 ${preview.diff.deleteCount} 处。',
          '恢复会追加一条提交，提交历史保留。',
        ],
        rollbackLine: '恢复前的版本留在提交历史里，恢复后可以在这一页回到恢复前。',
      );
      if (!confirmed || !mounted) return;
      final restored = await scope.data.revisions.restore(
        commit.id,
        expectedHead: preview.head,
      );
      if (!mounted) return;
      _showAppendedCommit();
      _report(
        restored.cacheWarning == null
            ? '已恢复并追加一条提交'
            : '已恢复并追加一条提交；${restored.cacheWarning}',
      );
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '恢复到选中的版本',
          kind: 'data_version_restore',
          kept: '当前数据没有改动',
          next: '可以重新选择目标版本后再试',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _undo(RevisionCommit commit) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await AppScope.of(context).data.undo.undoCommit(commit.id);
      if (result.applied && mounted) _showAppendedCommit();
      _report(result.message);
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '撤销这次操作',
          kind: 'data_version_undo',
          kept: '原来的内容保持不变',
          next: '可以再试一次',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportCurrent() async {
    if (_busy) return;
    final scope = AppScope.of(context);
    final day = scope.timePolicy.now;
    final fileName = 'zhixin-current-${compactDate(day)}.zip';
    setState(() => _busy = true);
    try {
      final uri = await saveDataPackage(
        fileName: fileName,
        writePackage: scope.data.versions.exportCurrentData,
      );
      _report(uri == null ? '已取消导出' : '已导出当前数据：$uri');
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '导出当前数据',
          kind: 'data_version_export',
          kept: '本机数据没有改动',
          next: '可以检查剩余存储空间后重试',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _backupRepository() async {
    if (_busy) return;
    final scope = AppScope.of(context);
    final day = scope.timePolicy.now;
    final fileName = 'zhixin-repository-${compactDate(day)}.zip';
    setState(() => _busy = true);
    try {
      final uri = await saveDataPackage(
        fileName: fileName,
        writePackage: scope.data.versions.backupRepository,
      );
      _report(uri == null ? '已取消备份' : '已备份版本库：$uri');
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '备份版本库',
          kind: 'data_version_backup',
          kept: '本机数据没有改动',
          next: '可以检查剩余存储空间后重试',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importCurrent() async {
    if (_busy) return;
    final picked = await FilePicker.pickFile(dialogTitle: '选择数据包');
    final path = picked?.path;
    if (path == null || !mounted) return;
    final scope = AppScope.of(context);
    final int expectedHead;
    final Uint8List bytes;
    try {
      expectedHead = await scope.data.versions.currentHead();
      bytes = await File(path).readAsBytes();
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '读取数据包',
          kind: 'data_version_import_read',
          kept: '当前数据没有改动',
          next: '可以换一个数据包再试',
        ),
      );
      return;
    }
    if (!mounted) return;
    final confirmed = await confirmZhixin(
      context: context,
      title: '导入当前数据',
      content: const Text(
        '数据包里的业务数据与附件会追加为一条提交，现有历史仍保留。'
        '导入前会重新核对当前版本，期间有新的写入时停止。确定导入？',
      ),
      confirmLabel: '导入',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      final imported = await scope.data.versions.importCurrentData(
        bytes,
        expectedHead: expectedHead,
      );
      switch (imported) {
        case Success(:final value):
          _showAppendedCommit();
          _report(value ?? '已导入当前数据');
        case Failure(:final reason):
          if (!mounted) return;
          _report(
            describeFailureReason(
              context,
              reason,
              kind: 'data_version_import',
              kept: '当前数据没有改动',
              next: '可以检查数据包后重试',
            ),
          );
      }
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '导入当前数据',
          kind: 'data_version_import',
          kept: '当前数据没有改动',
          next: '可以检查数据包后重试',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreRepository() async {
    if (_busy) return;
    await _restorePackage();
  }

  /// 数据包与恢复点走同一条恢复流程：预检、说明影响与回退，再整库替换。
  ///
  /// 读包、校验与写入的每一步只在这一页里就地说一句，只有最终结果提示一次。
  Future<void> _restorePackage({Uint8List? preset, String? origin}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _restoreStatus = null;
    });
    try {
      final message = await runPackageRestore(
        context,
        preset: preset,
        origin: origin,
        onStatus: (message) {
          if (mounted) setState(() => _restoreStatus = message);
        },
      );
      if (!mounted) return;
      setState(() => _restoreStatus = null);
      if (message != null) _report(message);
    } catch (error, stack) {
      if (!mounted) return;
      setState(() => _restoreStatus = null);
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '恢复数据包',
          kind: 'restore_apply',
          kept: '当前数据保留',
          next: '可以检查数据包后重试',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restorePoint(RestorePoint point) async {
    if (_busy) return;
    final scope = AppScope.of(context);
    final Uint8List bytes;
    try {
      bytes = await scope.data.versions.readRestorePoint(point);
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '读取恢复点',
          kind: 'data_version_restore_point_read',
          kept: '恢复点文件没有改动',
          next: '可以再试一次',
        ),
      );
      return;
    }
    if (!mounted) return;
    await _restorePackage(
      preset: bytes,
      origin: '恢复点（${_timeText(point.createdAt)}，HEAD ${point.head ?? '未知'}）',
    );
  }

  Future<void> _deletePoint(RestorePoint point) async {
    if (_busy) return;
    final confirmed = await confirmZhixin(
      context: context,
      title: '删除这份恢复点',
      content: const Text('删除后不能再从这份恢复点回到当时的数据；当前记录不受影响。'),
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      await AppScope.of(context).data.versions.deleteRestorePoint(point);
      _report('已删除恢复点');
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '删除恢复点',
          kind: 'data_version_restore_point_delete',
          kept: '恢复点还在',
          next: '可以再试一次',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _prune() async {
    if (_busy) return;
    final usage = _view?.usage;
    final total = usage?.commitCount ?? 0;
    final named = usage?.namedCount ?? 0;
    final removing = total - _keep - named - 1;
    final removable = removing < 0 ? 0 : removing;
    final confirmed = await confirmZhixin(
      context: context,
      title: '按留存清理',
      content: Text(
        removable > 0
            ? '会删除约 $removable 条较早的提交，只保留最近 $_keep 条，'
                  '以及当前 HEAD 与命名版本指向的提交；这些提交对应的“撤销”不再有效，'
                  '删除后无法恢复。当前数据与命名版本保留；'
                  '出现失效回执时还会追加一条不可撤销的清理提交。确定清理？'
            : '当前 $total 条提交没有超过 $_keep 条，这次不会删除提交；'
                  '会清掉不再被引用的检查点与附件。出现失效回执时还会追加一条不可撤销的清理提交。'
                  '确定继续？',
      ),
      confirmLabel: '清理',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      final result = await AppScope.of(context).data.revisions
          .prune(keepCommits: _keep);
      final notice = result.removedCommits > 0 ? '；更早的回执不再提供撤销入口' : '';
      _report(
        '已清理 ${result.removedCommits} 条提交、${result.removedCheckpoints} 个检查点、'
        '${result.removedAssets} 个附件，保留最近的提交与命名版本$notice',
      );
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '清理旧提交',
          kind: 'data_version_prune',
          kept: '当前数据与命名版本保留',
          next: '可以稍后再试',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 删除命名版本：只去掉名称，不删提交；撤销入口由提交本身判断，不受影响。
  Future<void> _deleteName(RevisionRef ref) async {
    if (_busy) return;
    final confirmed = await confirmZhixin(
      context: context,
      title: '删除命名版本',
      content: Text(
        '删除命名版本“${ref.name}”之后，这个名称不再出现在命名版本里。'
        '它不会删除任何提交，指向提交 #${ref.commitId} 的“撤销”仍然有效；'
        '当前数据与提交历史保持原样，仍可以从提交历史恢复到这个版本。',
      ),
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      await AppScope.of(context).data.revisions.deleteName(ref.name);
      _report('已删除命名版本“${ref.name}”');
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '删除命名版本',
          kind: 'data_version_name_delete',
          kept: '命名版本还在',
          next: '可以再试一次',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearHistory() async {
    if (_busy) return;
    final confirmed = await confirmZhixin(
      context: context,
      title: '清理历史',
      content: const Text(
        '将以当前数据为新基线，删除全部提交明细、检查点与命名版本；'
        '当前记录、附件与之后的提交保留。更早的回执会失去撤销入口。确定清理？',
      ),
      confirmLabel: '清理',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      await AppScope.of(context).data.revisions.clearHistory();
      _report('已清理历史，当前数据保留；更早的回执不再提供撤销入口');
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '清理历史',
          kind: 'data_version_clear_history',
          kept: '当前数据保留',
          next: '可以再试一次',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DetailScaffold(
      header: const ZhixinHeader(title: Text('数据版本'), showBack: true),
      child: LiveView<DataVersionOverview>(
        stream: _stream,
        initial: _initial,
        onData: _onView,
        onError: _onViewError,
        builder: (context, view, loading) {
          if (view != null) return _content(context, view);
          if (loading && _loadFailure == null) return _loading(context);
          return _failure(context);
        },
      ),
    );
  }

  /// 首读时标题栏已经就位，内容用与提交行同高的骨架占位。
  Widget _loading(BuildContext context) {
    final theme = context.zhixin;
    return ListView(
      padding: theme.space.pageInsets(bottom: 96),
      children: const [ListSkeleton(rows: 4)],
    );
  }

  /// 首次读取失败时的说明与重试入口；页面的其它入口留在导航栏上。
  Widget _failure(BuildContext context) {
    final theme = context.zhixin;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(theme.space.page),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InlineNotice(message: _loadFailure ?? '暂时无法读取数据版本。'),
            SizedBox(height: theme.space.md),
            forui.FButton(
              variant: forui.FButtonVariant.outline,
              mainAxisSize: MainAxisSize.min,
              onPress: _reload,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(BuildContext context, DataVersionOverview view) {
    final theme = context.zhixin;
    final history = view.history;
    final usage = view.usage;
    final commits = history.commits;
    final shown = commits.take(_historyLimit).toList(growable: false);
    return SingleChildScrollView(
      padding: theme.space.pageInsets(bottom: 96),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 已经显示的内容保留时，读取失败在顶上说明一次并就地重试。
          if (_loadFailure != null)
            InlineNotice(message: _loadFailure!, onRetry: _reload),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  '这一页保存每次改动，可以回到之前的版本，也可以导出成文件保存。',
                  style: theme.text.bodyMedium,
                ),
              ),
              SizedBox(width: theme.space.sm),
              forui.FButton(
                mainAxisSize: MainAxisSize.min,
                onPress: _busy ? null : () => _name(),
                prefix: const Icon(FLucideIcons.bookmarkPlus),
                child: const Text('命名当前版本'),
              ),
            ],
          ),
          const SectionHeading(title: '导出与备份'),
          forui.FTile(
            prefix: const LeadingIcon(FLucideIcons.download),
            title: const Text('导出当前数据'),
            subtitle: const Text('业务数据与仍在使用的图片。'),
            onPress: _busy ? null : _exportCurrent,
          ),
          SizedBox(height: theme.space.sm),
          forui.FTile(
            prefix: const LeadingIcon(FLucideIcons.package),
            title: const Text('备份版本库'),
            subtitle: const Text('整库快照，含历史与附件。'),
            onPress: _busy ? null : _backupRepository,
          ),
          SizedBox(height: theme.space.sm),
          forui.FTile(
            prefix: const LeadingIcon(FLucideIcons.cloud),
            title: const Text('云端备份'),
            subtitle: const Text('登录后把版本库上传到服务端，换机时下载恢复。'),
            onPress: _busy ? null : () => openCloudBackup(context),
          ),
          const SectionHeading(title: '导入与恢复'),
          forui.FTile(
            prefix: const LeadingIcon(FLucideIcons.upload),
            title: const Text('导入当前数据'),
            subtitle: const Text('业务数据追加成一条提交。'),
            onPress: _busy ? null : _importCurrent,
          ),
          SizedBox(height: theme.space.sm),
          forui.FTile(
            prefix: const LeadingIcon(FLucideIcons.rotateCcw),
            title: const Text('从版本库恢复'),
            subtitle: const Text('用版本库备份替换当前数据；恢复前自动保存恢复点。'),
            onPress: _busy ? null : _restoreRepository,
          ),
          if (_restoreStatus case final status?)
            Padding(
              padding: EdgeInsets.only(top: theme.space.sm),
              child: Text(
                status,
                style: theme.text.bodySmall.copyWith(
                  color: theme.colors.onSurfaceVariant,
                ),
              ),
            ),
          SectionHeading(
            title: '留存',
            subtitle:
                '共 ${usage.commitCount} 条保留提交 · '
                '${_sizeLabel(usage.databaseBytes)} · HEAD ${history.head}',
            action: forui.FButton(
              variant: forui.FButtonVariant.ghost,
              size: forui.FButtonSizeVariant.sm,
              mainAxisSize: MainAxisSize.min,
              onPress: _busy ? null : _clearHistory,
              prefix: const Icon(FLucideIcons.eraser),
              child: const Text('清理历史'),
            ),
          ),
          Text(
            '附件 ${_sizeLabel(usage.assetBytes)}（${usage.assetCount} 个） · '
            '检查点 ${usage.checkpointCount} 个 · '
            '命名 ${usage.namedCount} 个',
            style: theme.text.bodySmall,
          ),
          SizedBox(height: theme.space.md),
          Row(
            children: [
              Expanded(
                child: ZhixinSelect<int>(
                  value: _keep,
                  label: '保留最近提交数',
                  options: {
                    for (final count in {
                      20,
                      50,
                      100,
                      200,
                      500,
                      _keep,
                    }.toList()..sort())
                      count: '$count 条',
                  },
                  onChange: _busy
                      ? null
                      : (value) {
                          if (value == null) return;
                          setState(() => _keep = value);
                        },
                ),
              ),
              SizedBox(width: theme.space.sm),
              forui.FButton(
                variant: forui.FButtonVariant.outline,
                mainAxisSize: MainAxisSize.min,
                onPress: _busy ? null : _prune,
                child: const Text('按留存清理'),
              ),
            ],
          ),
          SizedBox(height: theme.space.sm),
          if (history.refs.isNotEmpty) ...[
            const SectionHeading(
              title: '命名版本',
              subtitle: '命名版本在清理时保留；删除名称不会删除提交，仍可从提交历史恢复到这个版本。',
            ),
            for (final ref in history.refs)
              Padding(
                padding: EdgeInsets.only(top: theme.space.tight),
                child: forui.FTile(
                  prefix: const LeadingIcon(FLucideIcons.bookmark),
                  title: Text(
                    ref.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${ref.note?.trim().isNotEmpty == true ? '${ref.note} · ' : ''}'
                    '提交 #${ref.commitId}',
                  ),
                  suffix: ZhixinIconButton(
                    tooltip: '删除命名',
                    onPressed: _busy ? null : () => _deleteName(ref),
                    icon: FLucideIcons.x,
                  ),
                ),
              ),
          ],
          // 没有恢复点时这一节不占位置：它只在恢复过一次之后才有内容可看。
          if (view.restorePoints.isNotEmpty) ...[
            SectionHeading(
              title: '恢复点',
              subtitle:
                  '恢复前自动保存一份，最多保留最近 ${view.restorePointKeep} 份；'
                  '卸载应用或清空全部记录会一起删除。',
            ),
            for (final point in view.restorePoints) _pointTile(theme, point),
          ],
          SectionHeading(key: _historyKey, title: '提交历史'),
          for (final commit in shown) _commitTile(theme, view, commit),
          if (commits.length > shown.length)
            LoadMoreFooter(
              label: '读取更早的提交',
              loading: false,
              onPressed: () =>
                  setState(() => _historyLimit += _historyPageSize),
            ),
        ],
      ),
    );
  }

  Widget _commitTile(
    ZhixinTheme theme,
    DataVersionOverview view,
    RevisionCommit commit,
  ) {
    final history = view.history;
    final names = history.refsByCommit[commit.id] ?? const <RevisionRef>[];
    final current = commit.id == history.head;
    final undoReason = view.undoReasons[commit.id];
    return Padding(
      padding: EdgeInsets.only(top: theme.space.tight),
      child: forui.FTile(
        prefix: Icon(
          current ? FLucideIcons.circleDot : FLucideIcons.gitCommit,
          color: theme.colors.primary,
        ),
        title: Text(
          '${commit.action}${current ? '（HEAD）' : ''}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${_timeText(commit.createdAt)} · ${_actorLabel(commit.actor)} · '
          '${commit.changeCount} 处'
          '${names.isEmpty ? '' : ' · ${names.map((ref) => ref.name).join('、')}'}',
        ),
        suffix: moreMenu(
          items: [
            ZhixinMenuItem(label: '查看明细', onSelected: () => _details(commit)),
            if (!current)
              ZhixinMenuItem(
                label: '与当前比较',
                onSelected: () => _compare(history.head, commit),
              ),
            ZhixinMenuItem(label: '保存命名版本', onSelected: () => _name(commit.id)),
            if (!current)
              ZhixinMenuItem(
                label: '恢复到这个版本',
                onSelected: () => _restore(commit),
              ),
            if (undoReason == null)
              ZhixinMenuItem(label: '撤销这次操作', onSelected: () => _undo(commit))
            else
              ZhixinMenuItem(
                label: '撤销这次操作',
                subtitle: undoReason,
                enabled: false,
              ),
          ],
        ),
        onPress: () => _details(commit),
      ),
    );
  }

  Widget _pointTile(ZhixinTheme theme, RestorePoint point) {
    return forui.FTile(
      prefix: const Icon(FLucideIcons.rotateCcw),
      title: Text(
        '${_timeText(point.createdAt)} · HEAD ${point.head ?? '未知'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${point.commitCount} 条提交 · ${point.namedCount} 个命名 · '
        '${_sizeLabel(point.size)}'
        '${point.reason.isEmpty ? '' : ' · ${point.reason}'}',
      ),
      suffix: moreMenu(
        items: [
          ZhixinMenuItem(
            label: '恢复到这里',
            onSelected: () => _restorePoint(point),
          ),
          ZhixinMenuItem(
            label: '删除这份恢复点',
            onSelected: () => _deletePoint(point),
          ),
        ],
      ),
    );
  }

  String _timeText(DateTime? time) => time == null ? '时间未知' : shortTime(time);

  String _actorLabel(String actor) => switch (actor) {
    'ai' => buddyName,
    'system' => '系统',
    _ => '你',
  };

  String _tableLabel(String table) => switch (table) {
    'app_meta' => '设置',
    'profile' => '档案',
    'learning_goal' => '目标',
    'asset_object' => '附件对象',
    'asset_chunk' => '附件内容',
    'material' => '材料',
    'material_page' => '材料页',
    'conversation' => '讨论',
    'message' => '消息',
    'study_plan' => '学习计划',
    'plan_item' => planItemName,
    'timetable_entry' => '课表',
    'schedule_block' => '预约',
    'study_session' => '学习场次',
    'attempt' => '作答',
    'assessment' => '学习判断',
    'memory' => '记忆',
    _ => table,
  };

  String _opLabel(String op) => switch (op) {
    'insert' => '新增',
    'delete' => '删除',
    _ => '修改',
  };

  /// 明细里显示的字段名；不在这张表里的内部字段不显示。
  static const Map<String, String> _fieldLabels = {
    'parent_id': '上一提交',
    'generation': '数据代次',
    'actor': '执行者',
    'action': '动作',
    'restored_commit_id': '恢复来源提交',
    'reverted_commit_id': '撤销的提交',
    'change_count': '变化处数',
    'name': '名称',
    'note': '备注',
    'key': '设置项',
    'value': '值',
    'day_cutoff_hour': '每日截止小时',
    'title': '标题',
    'scope_text': '范围说明',
    'due_date': '截止日期',
    'due_at': '截止时间',
    'status': '状态',
    'goal_id': '目标',
    'material_id': '材料',
    'conversation_id': '讨论',
    'message_id': '消息',
    'page_no': '页码',
    'page_from': '起始页',
    'page_to': '结束页',
    'current_page': '当前页',
    'content': '内容',
    'source_ref': '出处',
    'source_file_name': '来源文件',
    'source_file_hash': '来源文件校验',
    'kind': '类型',
    'entry_kind': '记录类型',
    'seq': '序号',
    'role': '角色',
    'weekday': '星期',
    'start_time': '开始时间',
    'end_time': '结束时间',
    'location': '地点',
    'start_at': '开始时间',
    'end_at': '结束时间',
    'ended_at': '结束时间',
    'locked': '已固定',
    'source': '来源',
    'plan_item_id': '学习事项',
    'study_plan_id': '学习计划',
    'material_page_id': '材料页',
    'session_id': '学习场次',
    'redo_of_attempt_id': '复查自',
    'user_answer': '作答',
    'solution': '解法',
    'is_correct': '是否正确',
    'independent': '独立完成',
    'delayed': '延后',
    'feedback': '反馈',
    'submitted_at': '提交时间',
    'last_message_at': '最后一条消息时间',
    'attempt_id': '作答',
    'result': '结果',
    'basis': '依据',
    'source_kind': '来源',
    'source_id': '来源编号',
    'valid_until': '有效期',
  };

  static const Set<String> _booleanFields = {
    'locked',
    'independent',
    'delayed',
    'is_correct',
    'suppress',
  };

  static const Set<String> _dateFields = {'due_date', 'valid_until'};

  /// 明细值：状态、类型与来源换成中文，时间按界面习惯显示，其余原样。
  String _fieldText(String table, String key, RevisionValue? value) {
    if (value == null || value.isNull) return '空';
    if (value.type == 'blob') return '二进制内容';
    final raw = '${value.value}';
    if (key == 'op') return _opLabel(raw);
    if (_booleanFields.contains(key)) {
      return raw == '1'
          ? '是'
          : raw == '0'
          ? '否'
          : raw;
    }
    final enumText = _enumText(table, key, raw);
    if (enumText != null) return enumText;
    if (_dateFields.contains(key)) {
      final time = DateTime.tryParse(raw);
      if (time != null) return '${time.month}月${time.day}日';
    }
    if (key.endsWith('_at')) {
      final time = DateTime.tryParse(raw);
      if (time != null) return shortTime(time.toLocal());
    }
    return raw;
  }

  /// 状态、类型与来源这类取值只在表与列对得上时翻译，其余保留原值。
  String? _enumText(String table, String key, String value) {
    final labels = switch ('$table.$key') {
      'learning_goal.status' || 'study_plan.status' => const {
        'active': '进行中',
        'paused': '已暂停',
        'done': '已完成',
      },
      'conversation.status' => const {'open': '进行中', 'ended': '已结束'},
      'conversation.entry_kind' => const {
        'text': '文字',
        'photo': '拍照',
        'text_photo': '文字与照片',
      },
      'plan_item.status' => const {
        'todo': '待开始',
        'doing': '进行中',
        'done': '已完成',
        'deferred': '已暂缓',
      },
      'schedule_block.status' => const {
        'planned': '已安排',
        'done': '已完成',
        'cancelled': '已取消',
      },
      'study_session.outcome' => const {
        'done': '完成',
        'partial': '部分完成',
        'not_done': '没有完成',
      },
      'assessment.kind' => const {'model': '模型判断', 'user': '自评'},
      'memory.kind' => const {
        'preference': '偏好',
        'constraint': '限制',
        'difficulty': '困难',
        'progress': '进展',
      },
      'memory.status' => const {
        'active': '有效',
        'superseded': '已替换',
        'deleted': '已删除',
      },
      'memory.source_kind' => const {
        'user': '你说的',
        'message': '讨论里',
        'attempt': '作答',
        'session': '学习场次',
      },
      'material.kind' => const {
        'text': '文字',
        'slides': '课件',
        'book': '书',
        'other': '其他',
      },
      'message.role' => const {
        'user': '你',
        'assistant': buddyName,
        'system': '系统',
      },
      'plan_item.source' ||
      'schedule_block.source' => const {'user': '你', 'ai': buddyName},
      _ => null,
    };
    return labels?[value];
  }

  String _sizeLabel(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
