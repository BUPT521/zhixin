import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../app_scope.dart';
import '../data/backup/data_version_service.dart';
import '../data/backup/restore_point_store.dart';
import '../data/revisions/revision_models.dart';
import '../domain/models/result.dart';
import '../platform/data_package_export.dart';
import 'copy.dart';
import 'failure_feedback.dart';
import 'format.dart';
import 'live_view.dart';
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

class _DataVersionPageState extends State<DataVersionPage> {
  /// 一屏订阅：历史、撤销判断、存储占用与恢复点随写入更新（ADR-0014）。
  Stream<DataVersionOverview>? _stream;
  DataVersionOverview? _view;

  bool _busy = false;
  int _keep = 100;

  /// 第一次读取失败时的说明；重新订阅之后清除。
  String? _loadFailure;

  /// 下拉刷新之后等新结果回来再收起转圈；没有结果时按超时放行。
  Completer<void>? _refreshWaiter;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 页面一进入就订阅整屏读取，写入之后的重新读取由数据层完成。
    _stream ??= _createStream();
  }

  @override
  void dispose() {
    _refreshWaiter?.complete();
    _refreshWaiter = null;
    super.dispose();
  }

  Stream<DataVersionOverview> _createStream() =>
      AppScope.of(context).data.versions.watchOverview();

  /// 下拉刷新与首读失败后的重试：换一条新流，等新结果回来再收起转圈。
  Future<void> _reload() {
    final waiter = Completer<void>();
    _refreshWaiter?.complete();
    _refreshWaiter = waiter;
    setState(() {
      _loadFailure = null;
      _stream = _createStream();
    });
    return waiter.future.timeout(const Duration(seconds: 3), onTimeout: () {});
  }

  /// 结果到达：换掉页面上的历史与恢复点，并放行等待中的刷新。
  void _onView(DataVersionOverview view) {
    _view = view;
    final waiter = _refreshWaiter;
    _refreshWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    if (_loadFailure != null) setState(() => _loadFailure = null);
  }

  void _onViewError(Object error, StackTrace stack) {
    final waiter = _refreshWaiter;
    _refreshWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    if (!mounted) return;
    final message = describeFailure(
      context,
      error,
      stack,
      action: '读取数据版本',
      kind: 'data_version_read',
      kept: '本机数据没有改动',
      next: '可以下拉刷新再试',
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
        forui.FButton(
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(true),
          child: const Text('保存'),
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
    final details = await scope.data.revisions.details(commit.id);
    if (!mounted || details == null) return;
    final theme = context.zhixin;
    await showZhixinSheet<void>(
      context: context,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
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
            SizedBox(height: context.zhixin.space.gap),
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

  Widget _changeTile(ZhixinTheme theme, RevisionChange change) {
    final hidden = {'id', 'created_at', 'updated_at'};
    final keys = <String>{
      ...?change.before?.keys,
      ...?change.after?.keys,
    }.where((key) => !hidden.contains(key)).toList()..sort();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_tableLabel(change.table)} · ${_opLabel(change.op)}',
            style: theme.text.labelLarge,
          ),
          for (final key in keys)
            Text(
              '$key：${_valueText(change.before?[key])}'
              '${change.op == 'update' ? ' → ${_valueText(change.after?[key])}' : ''}',
              style: theme.text.bodySmall,
            ),
        ],
      ),
    );
  }

  Future<void> _compare(int head, RevisionCommit commit) async {
    final scope = AppScope.of(context);
    final diff = await scope.data.revisions.compare(commit.id, head);
    if (!mounted) return;
    final theme = context.zhixin;
    await showZhixinSheet<void>(
      context: context,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
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
            SizedBox(height: context.zhixin.space.gap),
            if (diff.isEmpty)
              const Text('两个版本的业务数据一致。')
            else
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final entry in diff.entries)
                        Text(
                          '${_tableLabel(entry.table)} · '
                          '${_opLabel(entry.op)} · ${entry.rowKey}'
                          '${entry.columns.isEmpty ? '' : '（${entry.columns.join('、')}）'}',
                          style: theme.text.bodySmall,
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
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
    final expectedHead = await scope.data.versions.currentHead();
    final bytes = await File(path).readAsBytes();
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
  Future<void> _restorePackage({Uint8List? preset, String? origin}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final message = await runPackageRestore(
        context,
        preset: preset,
        origin: origin,
        onStatus: _report,
      );
      if (!mounted || message == null) return;
      _report(message);
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
        onData: _onView,
        onError: _onViewError,
        builder: (context, view, loading) {
          if (view != null) return _content(context, view);
          if (loading && _loadFailure == null) return const PageLoading();
          return _failure(context);
        },
      ),
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
            const SizedBox(height: 12),
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
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: theme.space.pageInsets(bottom: 96),
        children: [
          Text(
            '每次写入形成一条提交，当前数据对应本机 HEAD。'
            '任一保留版本都能从检查点重建；图片按内容哈希去重后保存在同一个库里。'
            '清理或裁剪之后，消息里指向已删除提交的回执会去掉提交编号，不再提供撤销入口。',
            style: theme.text.bodySmall,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              forui.FButton(
                mainAxisSize: MainAxisSize.min,
                onPress: _busy ? null : () => _name(),
                prefix: const Icon(FLucideIcons.bookmarkPlus),
                child: const Text('命名当前版本'),
              ),
              forui.FButton(
                variant: forui.FButtonVariant.outline,
                mainAxisSize: MainAxisSize.min,
                onPress: _busy ? null : _exportCurrent,
                prefix: const Icon(FLucideIcons.download),
                child: const Text('导出当前数据'),
              ),
              forui.FButton(
                variant: forui.FButtonVariant.outline,
                mainAxisSize: MainAxisSize.min,
                onPress: _busy ? null : _backupRepository,
                prefix: const Icon(FLucideIcons.package),
                child: const Text('备份版本库'),
              ),
              forui.FButton(
                variant: forui.FButtonVariant.outline,
                mainAxisSize: MainAxisSize.min,
                onPress: _busy ? null : _importCurrent,
                prefix: const Icon(FLucideIcons.upload),
                child: const Text('导入当前数据'),
              ),
              forui.FButton(
                variant: forui.FButtonVariant.outline,
                mainAxisSize: MainAxisSize.min,
                onPress: _busy ? null : _restoreRepository,
                prefix: const Icon(FLucideIcons.rotateCcw),
                child: const Text('从版本库恢复'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _section(theme, '留存'),
          Text(
            '共 ${history.commits.length} 条保留提交 · '
            '${_sizeLabel(usage.databaseBytes)} · HEAD ${history.head}',
            style: theme.text.bodySmall,
          ),
          Text(
            '附件 ${_sizeLabel(usage.assetBytes)}（${usage.assetCount} 个） · '
            '检查点 ${usage.checkpointCount} 个 · '
            '命名 ${usage.namedCount} 个',
            style: theme.text.bodySmall,
          ),
          SizedBox(height: context.zhixin.space.gap),
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
              const SizedBox(width: 8),
              forui.FButton(
                variant: forui.FButtonVariant.outline,
                mainAxisSize: MainAxisSize.min,
                onPress: _busy ? null : _prune,
                child: const Text('按留存清理'),
              ),
            ],
          ),
          SizedBox(height: context.zhixin.space.gap),
          Align(
            alignment: Alignment.centerLeft,
            child: forui.FButton(
              variant: forui.FButtonVariant.ghost,
              mainAxisSize: MainAxisSize.min,
              onPress: _busy ? null : _clearHistory,
              prefix: const Icon(FLucideIcons.eraser),
              child: const Text('清理历史并保留当前数据'),
            ),
          ),
          if (history.refs.isNotEmpty) ...[
            const Divider(height: 28),
            _section(theme, '命名版本'),
            for (final ref in history.refs)
              forui.FTile(
                prefix: const Icon(FLucideIcons.bookmark),
                title: Text(ref.name),
                subtitle: Text(
                  '${ref.note?.trim().isNotEmpty == true ? '${ref.note} · ' : ''}'
                  '提交 ${ref.commitId}',
                ),
                suffix: ZhixinIconButton(
                  tooltip: '删除命名',
                  onPressed: _busy
                      ? null
                      : () async {
                          setState(() => _busy = true);
                          try {
                            await AppScope.of(context).data.revisions
                                .deleteName(ref.name);
                          } catch (error, stack) {
                            if (!mounted || !context.mounted) return;
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
                        },
                  icon: FLucideIcons.x,
                ),
              ),
          ],
          const Divider(height: 28),
          _section(theme, '恢复点'),
          Text(
            '从数据包或恢复点恢复之前，会先把当前状态保存成一份恢复点，'
            '最多保留最近 ${view.restorePointKeep} 份。恢复点写在应用私有目录，'
            '卸载应用或清空全部记录会一起删除。',
            style: theme.text.bodySmall,
          ),
          if (view.restorePoints.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('还没有恢复点；恢复数据包时会自动保存。', style: theme.text.bodySmall),
            )
          else
            for (final point in view.restorePoints) _pointTile(theme, point),
          const Divider(height: 28),
          _section(theme, '提交历史'),
          for (final commit in history.commits)
            _commitTile(theme, view, commit),
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
      padding: const EdgeInsets.only(top: 6),
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

  Widget _section(ZhixinTheme theme, String title) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      title,
      style: theme.text.titleSmall.copyWith(color: theme.colors.primary),
    ),
  );

  String _timeText(DateTime? time) => time == null ? '时间未知' : shortTime(time);

  String _actorLabel(String actor) => switch (actor) {
    'ai' => buddyName,
    'system' => '系统',
    _ => '你',
  };

  String _tableLabel(String table) => switch (table) {
    'learning_goal' => '目标',
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
    'profile' => '档案',
    _ => table,
  };

  String _opLabel(String op) => switch (op) {
    'insert' => '新增',
    'delete' => '删除',
    _ => '修改',
  };

  String _valueText(RevisionValue? value) {
    if (value == null || value.isNull) return '空';
    if (value.type == 'blob') return '二进制 ${value.value}';
    return '${value.value}';
  }

  String _sizeLabel(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
