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
import '../application/sync_service.dart';
import '../data/backup/data_version_service.dart';
import '../domain/models/restore_point.dart';
import '../domain/models/revision_models.dart';
import '../data/revisions/revision_service.dart'
    show RevisionDetails, RevisionService;
import '../domain/models/result.dart';
import '../domain/rules/package_budget.dart';
import '../domain/rules/revision_retention.dart';
import '../platform/data_package_export.dart';
import 'copy.dart';
import 'data_version_watcher.dart';
import 'failure_feedback.dart';
import 'format.dart';
import 'integrity_check.dart';
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

/// 数据版本：提交历史、比较、命名、撤销与重做、整版恢复、留存清理与两类数据包。
///
/// 撤销一条撤销提交就是重做：提交类型仍是撤销，列表里的标签、菜单动作与确认
/// 文案按回指链的层数说清这次是撤销还是重做（方案 3.11）。
class DataVersionPage extends StatefulWidget {
  const DataVersionPage({super.key, @visibleForTesting this.revisions});

  /// 界面测试注入的版本服务；生产不传，页面走应用根上的那一份。
  ///
  /// 只用于同步冲突、写回本机值与清理阻塞这几处读取：阶段 0 里 `conflicts`、
  /// `keepLocal` 与 `historyBlockers` 还是空实现，界面测试要覆盖有冲突与
  /// 被阻止两种状态，只能由测试传入一个给出结果的替身（ADR-0039 第 3.4 节）。
  @visibleForTesting
  final RevisionService? revisions;

  @override
  State<DataVersionPage> createState() => _DataVersionPageState();
}

class _DataVersionPageState extends State<DataVersionPage>
    with DataVersionWatcher<DataVersionPage> {
  /// 页面业务流程：导出、备份、导入、命名、比较、恢复、裁剪、清理与完整性检查
  /// 的先后顺序与结果文案；State 只调它，不直接持有版本服务。
  late _DataVersionFlows _flows;

  /// 一屏订阅：历史、撤销判断、存储占用与恢复点随写入更新（ADR-0014）。
  Stream<DataVersionOverview>? _stream;
  DataVersionOverview? _view;

  /// 被其他设备覆盖、还没有处理的本机修改；为空时“同步覆盖”一节不出现。
  List<RevisionConflict> _conflicts = const [];

  /// 冲突读取的序号：两次读取之间又发起了新的，前一次的结果不再回填。
  int _conflictRequest = 0;

  /// 同步服务持有的设备名册缓存：远端提交的来源按它显示别名（ADR-0048）。
  SyncService get _sync => AppScope.of(context).accountServices.sync;

  /// 名册是否已经按打开的页面拉过一次；拉取途中不重复发起。
  bool _devicesLoaded = false;
  bool _devicesRefreshing = false;

  /// 一级界面切进来时已经读好的首屏；有它就先显示内容，不再摆骨架。
  DataVersionOverview? _initial;

  bool _busy = false;

  /// 保留天数：最近这么多天的提交全部保留，更早的按字节预算裁剪；自动裁剪
  /// 与手动裁剪共用这个设置。读到设置之前先按默认 14 天显示。
  int _keepDays = revisionDefaultRetentionDays;
  bool _retentionLoaded = false;

  /// 提交历史先渲染的条数；点“读取更早的提交”再加一页。
  static const int _historyPageSize = 30;
  int _historyLimit = _historyPageSize;
  bool _onlyAiChanges = false;

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
    _flows = _DataVersionFlows(
      scope: scope,
      revisions: widget.revisions ?? scope.data.revisions,
    );
    watchDataVersion(scope.dataVersion);
    _stream ??= _createStream();
    // 从“我的”打开时，一级界面切进来之后已经在后台读过一屏。
    _initial ??= scope.prefetch.peek<DataVersionOverview>(
      PrefetchKey.dataVersion,
    );
    _view ??= _initial;
    _loadConflicts();
    if (!_retentionLoaded) {
      _retentionLoaded = true;
      unawaited(_loadRetentionDays());
    }
    if (!_devicesLoaded) {
      _devicesLoaded = true;
      // 打开页面时拉一次名册：提交来源优先显示别名（ADR-0048）。读不到时保持
      // 现有缓存，来源退回设备标识前 8 位，不影响页面上其他内容。
      unawaited(_refreshDevices());
    }
  }

  /// 拉一次设备名册并在结果到达后重绘提交列表。
  ///
  /// 同步服务自己会吞掉读取失败并记一条诊断，这里只负责在成功与失败之后都重绘
  /// 一次，让缓存里已有的别名立即生效。
  Future<void> _refreshDevices() async {
    if (_devicesRefreshing) return;
    _devicesRefreshing = true;
    try {
      await _sync.refreshDevices();
    } finally {
      _devicesRefreshing = false;
    }
    if (!mounted) return;
    setState(() {});
  }

  /// 读保留天数：设置读取失败时沿用默认值，不打断页面上的其他内容。
  Future<void> _loadRetentionDays() async {
    try {
      final days = await _flows.retentionDays();
      if (!mounted || days == _keepDays) return;
      setState(() => _keepDays = days);
    } catch (_) {
      // 读不到设置时按默认 14 天显示；下次打开页面再读一次。
    }
  }

  /// 保存保留天数：自动裁剪与手动裁剪读同一个设置，保存失败时退回原值。
  Future<void> _setRetentionDays(int? days) async {
    if (days == null || days == _keepDays) return;
    final previous = _keepDays;
    setState(() => _keepDays = days);
    try {
      await _flows.saveRetentionDays(days);
    } catch (error, stack) {
      if (!mounted) return;
      setState(() => _keepDays = previous);
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '保存保留天数',
          kind: 'data_version_retention_days',
          kept: '保留天数仍是 $previous 天',
          next: '可以稍后再试',
        ),
      );
    }
  }

  Stream<DataVersionOverview> _createStream() => _flows.watchOverview();

  /// 读取被其他设备覆盖、还没有处理的本机修改。
  ///
  /// 冲突表不在整屏订阅的几张版本表里，所以每次整屏结果到达之后单独读一次；
  /// 读不到时保留上一次的结果，下一次读取再试，不因此打断已经显示的内容。
  void _loadConflicts() {
    final request = ++_conflictRequest;
    unawaited(() async {
      try {
        final conflicts = await _flows.conflicts();
        if (!mounted || request != _conflictRequest) return;
        setState(() => _conflicts = conflicts);
      } catch (_) {
        // 冲突列表是补充信息，读不到时这一节保持原样。
      }
    }());
  }

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
    // 同步覆盖与整屏读取一起刷新：远端提交应用之后冲突会多出来或消失。
    _loadConflicts();
    _refreshDevicesIfUnknown(view);
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

  /// 提交列表里出现了名册里还没有的设备时补拉一次名册。
  ///
  /// 从数据版本页同步之后新增的远端提交带着别的设备的标识，缓存里没有它时来源
  /// 只能显示前 8 位；补拉一次就能显示别名。已经缓存过的设备不重复拉取，页面
  /// 打开时的那一次由 [didChangeDependencies] 负责（ADR-0048）。
  void _refreshDevicesIfUnknown(DataVersionOverview view) {
    if (_devicesRefreshing) return;
    final known = {for (final device in _sync.devices) device.deviceId};
    final unknown = view.history.commits.any((commit) {
      if (!commit.isRemote) return false;
      final device = commit.originDevice?.trim() ?? '';
      return device.isNotEmpty && !known.contains(device);
    });
    if (!unknown) return;
    unawaited(_refreshDevices());
  }

  /// 追加提交之后换一条新流：等新结果到达再滚动，新增的提交已经在列表里。
  void _showAppendedCommit() {
    _revealHistory = true;
    _reload();
  }

  /// 把一处被覆盖的本机修改写回：数据层生成一条普通提交，冲突随之标为已处理。
  Future<void> _keepLocal(RevisionConflict conflict) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final commit = await _flows.keepLocal(conflict.id);
      if (!mounted) return;
      if (commit == null) {
        _report('本机修改还没有写回，可以稍后再试');
        return;
      }
      _report('已把本机原来的值写回为一条新提交');
      _showAppendedCommit();
      _loadConflicts();
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '保留本机修改',
          kind: 'data_version_keep_local',
          kept: '本机数据没有改动',
          next: '可以再试一次',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 消解一条本机已删的覆盖记录：没有可写回的本机值，确认之后直接删掉记录。
  Future<void> _dismissConflict(RevisionConflict conflict) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final dismissed = await _flows.dismissConflict(conflict.id);
      if (!mounted) return;
      _report(dismissed ? '已忽略这条同步覆盖记录' : '这条记录已经处理过了');
      _loadConflicts();
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '忽略同步覆盖',
          kind: 'data_version_dismiss_conflict',
          kept: '本机数据没有改动',
          next: '可以再试一次',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
      await _flows.name(target, label: label, note: memo);
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
    try {
      final details = await _flows.details(commit.id);
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
            '${tableLabel(change.table)} · ${_opLabel(change.op)}',
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
    final RevisionDiff diff;
    try {
      diff = await _flows.compare(commit.id, head);
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
        '${tableLabel(entry.table)} · ${_opLabel(entry.op)} · ${entry.rowKey}'
        '${columns.isEmpty ? '' : '（${columns.join('、')}）'}',
        style: theme.text.bodySmall,
      ),
    );
  }

  Future<void> _restore(RevisionCommit commit) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final preview = await _flows.previewRestore(commit.id);
      if (!mounted) return;
      final confirmed = await showRestoreConfirmDialog(
        context,
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
      if (!confirmed || !mounted) return;
      final restored = await _flows.restoreVersion(
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

  /// 撤销或重做一条提交。
  ///
  /// 撤销普通提交直接写入；撤销一条撤销提交就是重做，先把会发生什么讲清楚再
  /// 执行：写回它撤销掉的内容、追加一条新提交、消息里的回执不恢复。
  Future<void> _undo(RevisionCommit commit, int undoDepth) async {
    if (_busy) return;
    final label = _undoActionLabel(undoDepth);
    if (undoDepth > 0) {
      final confirmed = await _confirmUndoChain(commit, undoDepth);
      if (!confirmed || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      final result = await _flows.undo(commit.id);
      if (result.applied && mounted) _showAppendedCommit();
      _report(result.message);
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: label,
          kind: undoDepth.isOdd ? 'data_version_redo' : 'data_version_undo',
          kept: '原来的内容保持不变',
          next: '可以再试一次',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 撤销一条撤销提交之前的确认：链上第奇数条撤销提交是重做，第偶数条是撤销
  /// 这次重做，两种动作都会追加提交，区别在于写回还是去掉内容。
  Future<bool> _confirmUndoChain(RevisionCommit commit, int undoDepth) async {
    final theme = context.zhixin;
    final redo = undoDepth.isOdd;
    final impact = redo
        ? '会把这条撤销去掉的内容按原来的样子重新写入，并追加一条新提交；'
              '之后有人改过同一项内容时不能重做。'
        : '会重新去掉这次重做写回的内容，回到撤销后的状态，并追加一条新提交；'
              '之后有人改过同一项内容时不能撤销。';
    final rollback = redo
        ? '重做之后原提交重新可以撤销；消息里的回执不会恢复，界面按提交是否仍可撤销重新判断。'
        : '撤销之后原来那条撤销提交重新可以重做；消息里的回执不会恢复。';
    return confirmZhixin(
      context: context,
      title: redo ? '重做这次撤销' : '撤销这次重做',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '来源：${_timeText(commit.createdAt)} 的提交 #${commit.id}'
            '（${commit.action}）。',
          ),
          SizedBox(height: theme.space.xs),
          Text(impact),
          SizedBox(height: theme.space.gap),
          Text(rollback, style: theme.text.bodySmall),
        ],
      ),
      confirmLabel: redo ? '重做' : '撤销',
    );
  }

  Future<void> _exportCurrent() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final uri = await _flows.exportCurrent();
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

  /// 手动检查数据完整性：从检查点重放比对摘要，再核对附件；结果框说明检查范围与建议。
  ///
  /// 检查只读，不改数据；发现问题时逐条列出第几处不一致，并给出处理建议。
  Future<void> _checkIntegrity() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await _flows.checkIntegrity();
      if (!mounted) return;
      await showIntegrityReport(context, result);
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '检查数据完整性',
          kind: 'data_version_integrity_check',
          kept: '本机数据没有改动',
          next: '可以再试一次',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 导出前自动检查：通过时返回真，发现不一致时先说明再由用户决定是否继续。
  ///
  /// 检查本身失败时给出提示并返回空，调用方据此不继续导出：没有核对过的备份
  /// 不能当成完整。返回空与用户取消（假）分开，取消时给一句“已取消”。
  Future<bool?> _confirmIntegrityBeforeExport(String action) async {
    if (_busy) return null;
    setState(() => _busy = true);
    try {
      final result = await _flows.checkIntegrity();
      if (!mounted) return null;
      return await confirmExportAfterIntegrityCheck(
        context,
        result,
        action: action,
      );
    } catch (error, stack) {
      if (!mounted) return null;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '检查数据完整性',
          kind: 'data_version_integrity_check',
          kept: '本机数据没有改动',
          next: '可以稍后再试',
        ),
      );
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 备份版本库：先自动检查完整性，发现不一致时说明并让用户决定是否继续。
  Future<void> _backupRepository() async {
    if (_busy) return;
    final confirmed = await _confirmIntegrityBeforeExport('备份版本库');
    if (confirmed == null || !mounted) return;
    if (!confirmed) {
      _report('已取消备份');
      return;
    }
    setState(() => _busy = true);
    try {
      final uri = await _flows.backupRepository();
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
    if (picked == null || path == null || !mounted) return;
    // 超过上限的包不读进内存：先看文件大小，再决定是否读取。
    final size = await picked.length();
    if (!mounted) return;
    if (size != null && size > dataPackageMaxBytes) {
      _report(dataPackageTooLargeMessage(size));
      return;
    }
    final int expectedHead;
    final Uint8List bytes;
    try {
      expectedHead = await _flows.currentHead();
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
      final imported = await _flows.importCurrent(
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
    final Uint8List bytes;
    try {
      bytes = await _flows.readRestorePoint(point);
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
      await _flows.deleteRestorePoint(point);
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

  /// 清理前的确认：先读历史下游读者的阻塞原因，有原因时写在框里并禁用确认。
  ///
  /// [clearing] 为真时对应“清理本机历史”，否则对应“按留存清理”。读不到原因时
  /// 不弹确认，按读取失败提示一次：不能在没有核对的情况下删提交。
  Future<bool> _confirmCleanup({
    required String title,
    required Widget content,
    required bool clearing,
    required String confirmLabel,
  }) async {
    final List<String> blockers;
    try {
      blockers = await _flows.historyBlockers(clearing: clearing);
    } catch (error, stack) {
      if (!mounted) return false;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '核对清理条件',
          kind: 'data_version_blockers',
          kept: '提交历史没有改动',
          next: '可以稍后再试',
        ),
      );
      return false;
    }
    if (!mounted) return false;
    if (blockers.isEmpty) {
      return confirmZhixin(
        context: context,
        title: title,
        content: content,
        confirmLabel: confirmLabel,
        destructive: true,
      );
    }
    final theme = context.zhixin;
    final confirmed = await showZhixinAlert<bool>(
      context: context,
      title: title,
      cancelLabel: '取消',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          content,
          SizedBox(height: theme.space.md),
          Text('现在还不能清理：', style: theme.text.labelLarge),
          for (final blocker in blockers)
            Padding(
              padding: EdgeInsets.only(top: theme.space.tight),
              child: Text('· $blocker', style: theme.text.bodySmall),
            ),
        ],
      ),
      actions: [
        // 有阻塞时数据层会拒绝执行，按钮直接禁用，用户不会点完才发现没清理。
        forui.FButton(
          variant: forui.FButtonVariant.destructive,
          mainAxisSize: MainAxisSize.min,
          onPress: null,
          child: Text(confirmLabel),
        ),
      ],
    );
    return confirmed ?? false;
  }

  Future<void> _prune() async {
    if (_busy) return;
    final total = _view?.usage.commitCount ?? 0;
    final confirmed = await _confirmCleanup(
      title: '按留存清理',
      clearing: false,
      confirmLabel: '清理',
      content: Text(
        '当前共 $total 条提交。最近 $_keepDays 天内的提交全部保留；'
        '更早的提交在字节预算之内继续保留，超出预算时从最早的开始删，'
        '当前 HEAD 与命名版本指向的提交不会被删除。'
        '被删提交对应的“撤销”不再有效，删除后无法恢复；'
        '当前数据与命名版本保留；出现失效回执时还会追加一条不可撤销的清理提交。确定清理？',
      ),
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      final result = await _flows.prune(retentionDays: _keepDays);
      final notice = result.removedCommits > 0 ? '；更早的回执不再提供撤销入口' : '';
      _report(
        '已清理 ${result.removedCommits} 条提交、${result.removedCheckpoints} 个检查点、'
        '${result.removedAssets} 个附件，保留最近 $_keepDays 天内的提交与命名版本$notice',
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
  ///
  /// 删除会在所有设备上生效：本机写墓碑，下次同步推给云端。
  Future<void> _deleteName(RevisionRef ref) async {
    if (_busy) return;
    final confirmed = await confirmZhixin(
      context: context,
      title: '删除命名版本',
      content: Text(
        '删除命名版本“${ref.name}”之后，这个名称在所有登录了这个账号的设备上都不再出现。'
        '它不会删除任何提交，“撤销”入口仍然有效；当前数据与提交历史保持原样，'
        '仍可以从提交历史恢复到这个版本。',
      ),
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      await _flows.deleteName(ref.name);
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
    final confirmed = await _confirmCleanup(
      title: '清理本机历史',
      clearing: true,
      confirmLabel: '清理',
      content: const Text(
        '将以当前数据为新基线，删除全部提交明细、检查点与命名版本；'
        '当前记录、附件与之后的提交保留。更早的回执会失去撤销入口。确定清理？',
      ),
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      await _flows.clearHistory();
      _report('已清理本机历史，当前数据保留；更早的回执不再提供撤销入口');
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '清理本机历史',
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
    final filtered = _onlyAiChanges
        ? commits.where((commit) => commit.isAiChange).toList(growable: false)
        : commits;
    final shown = filtered.take(_historyLimit).toList(growable: false);
    // 撤销链的层数要看回指的提交，列表里的提交按编号建一份索引给每条提交用。
    final commitsById = {for (final commit in commits) commit.id: commit};
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
            prefix: const LeadingIcon(FLucideIcons.shieldCheck),
            title: const Text('检查数据完整性'),
            subtitle: const Text('从检查点重放到当前版本并比对摘要，核对附件；备份版本库与上传云端备份前也会自动检查。'),
            onPress: _busy ? null : _checkIntegrity,
          ),
          SizedBox(height: theme.space.sm),
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
          if (_restoreStatus case final status?) ResultNotice(message: status),
          // 只有被其他设备覆盖过、还没处理时才占位置；平时这一节不出现。
          if (_conflicts.isNotEmpty) ...[
            const SectionHeading(
              title: '同步覆盖',
              subtitle: '其他设备的修改覆盖了本机内容；可以把本机原来的值写回为一条新提交。',
            ),
            for (final conflict in _conflicts) _conflictTile(theme, conflict),
          ],
          SectionHeading(
            title: '留存',
            subtitle:
                '共 ${usage.commitCount} 条保留提交 · '
                '${formatBytes(usage.databaseBytes)} · HEAD ${history.head}',
            action: SectionLink(
              label: '清理本机历史',
              icon: FLucideIcons.eraser,
              onPressed: _busy ? null : _clearHistory,
            ),
          ),
          Text(
            '附件 ${formatBytes(usage.assetBytes)}（${usage.assetCount} 个） · '
            '检查点 ${usage.checkpointCount} 个 · '
            '命名 ${usage.namedCount} 个',
            style: theme.text.bodySmall,
          ),
          SizedBox(height: theme.space.md),
          Row(
            children: [
              Expanded(
                child: ZhixinSelect<int>(
                  key: const ValueKey('data-version-retention-days'),
                  value: _keepDays,
                  label: '保留天数',
                  options: {
                    for (final days in {
                      ...revisionRetentionDayOptions,
                      _keepDays,
                    }.toList()..sort())
                      days: '$days 天',
                  },
                  onChange: _busy ? null : _setRetentionDays,
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
              subtitle: '命名后在清理本机历史时保留；删除名称不会删除提交，仍可从提交历史恢复到这个版本。',
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
                    '${history.refCommitIds[ref.name] == null ? '该版本的历史不在本机，需要长期保留时请导出版本库备份' : '提交 #${history.refCommitIds[ref.name]}'}',
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
          SectionHeading(
            key: _historyKey,
            title: '提交历史',
            action: forui.FButton(
              variant: _onlyAiChanges
                  ? forui.FButtonVariant.secondary
                  : forui.FButtonVariant.outline,
              mainAxisSize: MainAxisSize.min,
              onPress: () => setState(() {
                _onlyAiChanges = !_onlyAiChanges;
                _historyLimit = _historyPageSize;
              }),
              child: Text(_onlyAiChanges ? '显示全部' : '筛选 AI 改动'),
            ),
          ),
          if (_onlyAiChanges && shown.isEmpty)
            const InlineNotice(message: '没有 AI 改动。'),
          for (final commit in shown)
            _commitTile(theme, view, commit, commitsById),
          if (filtered.length > shown.length)
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
    Map<int, RevisionCommit> commitsById,
  ) {
    final history = view.history;
    final names = history.refsByCommit[commit.id] ?? const <RevisionRef>[];
    final current = commit.id == history.head;
    final undoReason = view.undoReasons[commit.id];
    // 撤销提交按它在回指链上的层数显示：奇数是撤销、偶数是重做。
    final undoDepth = _undoDepth(commit, commitsById);
    final undoLabel = _undoActionLabel(undoDepth);
    return Padding(
      padding: EdgeInsets.only(top: theme.space.tight),
      child: forui.FTile(
        // 图标与标题都按提交类型来；动作文案只作说明，放在副标题最前面。
        // 来自另一台设备的提交用云下载图标，来源与类型分开显示（审查 S23）。
        prefix: Icon(
          _kindIcon(
            commit.kind,
            undoDepth: undoDepth,
            isRemote: commit.isRemote,
          ),
          color: current ? theme.colors.primary : theme.colors.onSurfaceVariant,
        ),
        title: Text(
          '${_kindLabel(commit, undoDepth)}${current ? '（HEAD）' : ''}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${commit.action} · ${_commitTimeAndSource(commit)} · '
          '${_actorLabel(commit.actor)} · ${commit.changeCount} 处'
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
              ZhixinMenuItem(
                label: undoLabel,
                onSelected: () => _undo(commit, undoDepth),
              )
            else
              ZhixinMenuItem(
                label: undoLabel,
                subtitle: undoReason,
                enabled: false,
              ),
          ],
        ),
        onPress: () => _details(commit),
      ),
    );
  }

  /// 撤销链的层数：普通提交是 0，撤销是 1，重做是 2，再撤销是 3，依此类推。
  ///
  /// 链上更早的提交可能已经不在这一页的列表里，走到看不见的父提交就停下，
  /// 按已经确定的层数显示；滚动读取更早的提交之后会重新算对。
  int _undoDepth(RevisionCommit commit, Map<int, RevisionCommit> byId) {
    var depth = 0;
    var current = commit;
    final seen = <int>{};
    while (current.kind == RevisionKind.undo &&
        current.revertedCommitId != null &&
        seen.add(current.id)) {
      depth++;
      final parent = byId[current.revertedCommitId];
      if (parent == null) break;
      current = parent;
    }
    return depth;
  }

  /// 提交类型的中文标签：撤销提交按层数显示“撤销”或“重做”，其余按类型。
  String _kindLabel(RevisionCommit commit, int undoDepth) {
    if (undoDepth == 0) return commit.kind.label;
    return undoDepth.isEven ? '重做' : '撤销';
  }

  /// 菜单里的动作名：撤销普通提交是撤销；撤销一条撤销提交是重做它撤销掉的
  /// 操作；撤销一条重做提交又回到撤销。
  String _undoActionLabel(int undoDepth) {
    if (undoDepth == 0) return '撤销这次操作';
    return undoDepth.isOdd ? '重做这次撤销' : '撤销这次重做';
  }

  /// 提交类型对应的图标；类型由写入路径记录，不从动作文案推断（ADR-0039）。
  ///
  /// 撤销提交按回指链的层数区分图标：奇数是撤销，偶数是重做。来源是另一台
  /// 设备时统一用云下载图标，类型仍由后面的标题说明（审查 S23）。
  IconData _kindIcon(
    RevisionKind kind, {
    int undoDepth = 0,
    bool isRemote = false,
  }) => isRemote
      ? FLucideIcons.cloudDownload
      : switch (kind) {
          RevisionKind.baseline => FLucideIcons.flag,
          RevisionKind.write => FLucideIcons.pencil,
          RevisionKind.undo =>
            undoDepth > 0 && undoDepth.isEven
                ? FLucideIcons.redo2
                : FLucideIcons.undo2,
          RevisionKind.restore => FLucideIcons.rotateCcw,
          RevisionKind.import => FLucideIcons.upload,
          RevisionKind.maintenance => FLucideIcons.wrench,
        };

  /// 一处被远端覆盖的本机修改：写明哪项内容的哪个字段、本机原来的值与现在的值。
  Widget _conflictTile(ZhixinTheme theme, RevisionConflict conflict) {
    final lines = _conflictLines(conflict);
    return Padding(
      padding: EdgeInsets.only(top: theme.space.tight),
      child: forui.FTile(
        prefix: const LeadingIcon(FLucideIcons.cloudDownload),
        title: Text(
          '${_conflictTableLabel(conflict.table)} · '
          '${_conflictFieldLabel(conflict)}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in lines) Text(line, style: theme.text.bodySmall),
          ],
        ),
        suffix: switch (conflict.reason) {
          // 本机已经删掉这一行，或者远端这一行撞上了本机占着的唯一键：都没有
          // 可以写回的本机值，用户确认之后把这条说明删掉即可（审查 S18）。
          RevisionConflict.deletedLocally ||
          RevisionConflict.uniqueKeyTaken => forui.FButton(
            variant: forui.FButtonVariant.outline,
            size: forui.FButtonSizeVariant.sm,
            mainAxisSize: MainAxisSize.min,
            onPress: _busy ? null : () => _dismissConflict(conflict),
            child: const Text('知道了'),
          ),
          _ => forui.FButton(
            variant: forui.FButtonVariant.outline,
            size: forui.FButtonSizeVariant.sm,
            mainAxisSize: MainAxisSize.min,
            onPress: _busy ? null : () => _keepLocal(conflict),
            child: const Text('保留本机修改'),
          ),
        },
      ),
    );
  }

  /// 冲突涉及的内容名：不认识的表不显示英文表名，退成“内容”。
  String _conflictTableLabel(String table) {
    final label = tableLabel(table);
    return label == table ? '内容' : label;
  }

  /// 冲突涉及的字段名：整行冲突（新增撞上同一主键）时列成“整行”，唯一键撞车
  /// 时说明是页码这一类的值被占着（审查 S18）。
  String _conflictFieldLabel(RevisionConflict conflict) {
    if (conflict.reason == RevisionConflict.uniqueKeyTaken) return '页码或序号';
    final column = conflict.column;
    if (column == null) return '整行';
    return _fieldLabels[column] ?? '内容';
  }

  /// 每行的“本机原来的值 → 现在的值”；字段名一律走 [_fieldLabels]，不显示列名。
  List<String> _conflictLines(RevisionConflict conflict) {
    if (conflict.reason == RevisionConflict.uniqueKeyTaken) {
      return const ['远端这一行与本机另一条记录用了同一个唯一值，这一行没有写入；改掉本机那一行的页码或序号之后可以重新同步'];
    }
    final column = conflict.column;
    if (column != null) {
      final label = _fieldLabels[column] ?? '内容';
      final before = _conflictValueText(conflict, column, local: true);
      final after = _conflictValueText(conflict, column, local: false);
      return ['$label：本机原来的值 $before，现在的值 $after'];
    }
    // 整行冲突：只列映射得到中文名的字段，映射不到的内部字段不显示。
    final keys = <String>{
      ...conflict.local.keys,
      ...conflict.remoteAfter.keys,
    }.where(_fieldLabels.containsKey).toList()..sort();
    if (keys.isEmpty) return const ['整行内容与现在不同'];
    return [
      for (final key in keys)
        '${_fieldLabels[key]}：本机原来的值 '
            '${_conflictValueText(conflict, key, local: true)}，现在的值 '
            '${_conflictValueText(conflict, key, local: false)}',
    ];
  }

  /// 冲突记录里一侧的值；本机已删或远端已删时写明“已经删除”，其余缺失按“空”。
  String _conflictValueText(
    RevisionConflict conflict,
    String column, {
    required bool local,
  }) {
    if (local && conflict.reason == RevisionConflict.deletedLocally) {
      return '已经删除';
    }
    if (!local && conflict.reason == RevisionConflict.deletedRemotelyModified) {
      return '已经删除';
    }
    final row = local ? conflict.local : conflict.remoteAfter;
    final value = row[column];
    if (value != null) return _fieldText(conflict.table, column, value);
    return _fieldText(conflict.table, column, null);
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
        '${formatBytes(point.size)}'
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

  /// 提交列表里的时间与来源：远端提交写“来自另一台设备 别名 · 某时某分”，
  /// 本机提交只写时间。
  ///
  /// 时间取作者时间（服务端没有带来时退回落库时间）；来源优先显示名册里的别名，
  /// 没有别名时显示设备标识前 8 位，不把整串设备标识放到界面上（ADR-0048）。
  String _commitTimeAndSource(RevisionCommit commit) {
    final time = _timeText(commit.displayAuthoredAt);
    if (!commit.isRemote) return time;
    final alias = _sync.deviceAlias(commit.originDevice ?? '');
    if (alias != null) return '来自另一台设备 $alias · $time';
    final device = maskedDeviceId(commit.originDevice);
    return device.isEmpty ? '来自另一台设备 · $time' : '来自另一台设备 $device · $time';
  }

  String _actorLabel(String actor) => switch (actor) {
    'ai' => buddyName,
    'system' => '系统',
    _ => '你',
  };

  String _opLabel(ChangeOp op) => op.label;

  /// 明细里显示的字段名；不在这张表里的内部字段不显示。
  static const Map<String, String> _fieldLabels = {
    'parent_id': '上一提交',
    'generation': '数据代次',
    'actor': '执行者',
    'action': '动作',
    'restored_commit_id': '恢复来源提交',
    'reverted_commit_id': '撤销的提交',
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
    'attempt_id': '作答',
    'result': '结果',
    'basis': '依据',
    'source_kind': '来源',
    'source_id': '来源编号',
    'valid_until': '有效期',
    'search_terms': '检索线索',
    'reviewed_at': '确认保留时间',
    'server_seq': '云端序号',
    'table_digests': '分表摘要',
    'head_commit_id': '当前提交',
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
    if (value.type == RevisionValueType.blob) return '二进制内容';
    final raw = '${value.value}';
    if (key == 'op') return _opLabel(ChangeOp.fromValue(raw));
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
  ///
  /// 键里的表名是提交与冲突记录的 `table_name`，即建表的 SQL 名称；写成表类的
  /// 实体名（`Memories`）时翻译不生效、明细退回原样。
  String? _enumText(String table, String key, String value) {
    final labels = switch ('$table.$key') {
      'learning_goal.status' || 'study_plan.status' => const {
        'active': '进行中',
        'paused': '已暂停',
        'done': '已完成',
      },
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
      'study_session.outcome' => const {
        'done': '完成',
        'partial': '部分完成',
        'not_done': '没有完成',
      },
      'assessment.kind' => const {'model': '模型判断', 'user': '自评'},
      'memory.kind' => const {
        'episodic': '情景',
        'semantic': '语义',
        'procedural': '程序',
      },
      'memory.status' => const {'active': '有效', 'deleted': '已删除'},
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
      'plan_item.source' || 'revision_commit.actor' => const {
        'user': '你',
        'ai': buddyName,
        'system': '系统',
      },
      'revision_commit.kind' => const {
        'baseline': '基线',
        'write': '写入',
        'undo': '撤销',
        'restore': '恢复',
        'import': '导入',
        'maintenance': '维护',
      },
      'revision_change.op' => const {
        'insert': '新增',
        'update': '修改',
        'delete': '删除',
      },
      'revision_checkpoint.kind' => const {
        'initial': '初始',
        'periodic': '周期',
        'trimmed': '裁剪后',
        'named': '命名版本',
      },
      'revision_asset_ref.owner_kind' => const {
        'change': '提交',
        'checkpoint': '检查点',
      },
      'revision_conflict.reason' => const {
        'concurrent_update': '两边各改了一列',
        'deleted_locally': '本机已删除',
        'insert_collision': '新增撞上同一编号',
        'deleted_remotely_modified': '云端删除、本机改过',
        'unique_key_taken': '唯一键已被占用',
      },
      'revision_ref.sync_state' => const {'clean': '已同步', 'dirty': '待同步'},
      _ => null,
    };
    return labels?[value];
  }
}

/// 数据版本页的业务顺序：导出、备份、导入、命名、比较、恢复、裁剪、清理、
/// 恢复点与完整性检查。
///
/// 页面只保留确认框与渲染：先做什么、失败时保留什么、结果文案与影响说明都在
/// 这里。`application` 目录不属于批 3 的独占范围，所以它先作为页面私有的普通类
/// 存在，State 不再直接持有版本服务；等应用层接收这些流程时整体上移，页面不需要
/// 再改。整库恢复的选包、预检与确认仍然需要页面上下文，留在 [DataVersionPage] 里。
class _DataVersionFlows {
  _DataVersionFlows({required this.scope, required this.revisions});

  final AppScopeState scope;
  final RevisionService revisions;

  DataVersionService get _versions => scope.data.versions;

  /// 导出文件名带上当天日期；两类数据包各一个前缀。
  String get currentDataFileName =>
      'zhixin-current-${compactDate(scope.timePolicy.now)}.zip';
  String get repositoryFileName =>
      'zhixin-repository-${compactDate(scope.timePolicy.now)}.zip';

  Stream<DataVersionOverview> watchOverview() => _versions.watchOverview();

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

  Future<RevisionUndoResult> undo(int commitId) =>
      scope.data.undo.undoCommit(commitId);

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
      checkRepositoryIntegrity(revisions);

  Future<String?> exportCurrent() => saveDataPackage(
    fileName: currentDataFileName,
    writePackage: _versions.exportCurrentData,
  );

  Future<String?> backupRepository() => saveDataPackage(
    fileName: repositoryFileName,
    writePackage: _versions.backupRepository,
  );

  Future<int> currentHead() => _versions.currentHead();

  Future<Result<String?>> importCurrent(
    Uint8List bytes, {
    required int expectedHead,
  }) => _versions.importCurrentData(bytes, expectedHead: expectedHead);

  Future<int> retentionDays() => scope.settings.edit.revisionRetentionDays();

  Future<void> saveRetentionDays(int days) =>
      scope.settings.edit.saveRevisionRetentionDays(days);

  Future<Uint8List> readRestorePoint(RestorePoint point) =>
      _versions.readRestorePoint(point);

  Future<void> deleteRestorePoint(RestorePoint point) =>
      _versions.deleteRestorePoint(point);
}
