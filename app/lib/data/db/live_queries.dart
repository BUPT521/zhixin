import 'dart:async';

import 'schema.dart';

/// 业务表变更通知：提交成功之后按表名发出一批，订阅中的读取据此重跑。
///
/// 通知只由版本引擎的提交收尾发出（ADR-0014 第 2、3 条）：写入在事务提交之后
/// 才通知，回滚的写入与没有净变化的写入都不通知。整库恢复与清空会换掉连接，
/// [connectionReplaced] 按全部表补发一次，页面因此在换库之后自动重读，不需要
/// 应用根另外通知。
class TableChanges {
  final StreamController<Set<String>> _controller =
      StreamController<Set<String>>.broadcast();

  bool _closed = false;

  Stream<Set<String>> get stream => _controller.stream;

  /// 一批已经提交的表变更。
  void publish(Iterable<String> tables) {
    final changed = {...tables};
    if (changed.isEmpty || _closed) return;
    _controller.add(changed);
  }

  /// 全部表都变了：换连接之后调用一次。
  void connectionReplaced() => publish(schemaTableNames());

  /// 关掉通知；重复调用直接返回，页面退出与测试清理都会各调一次。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _controller.close();
  }
}

/// 跟着写入更新的读取：相关表被写入之后重新执行读取，只回填最新一次结果。
///
/// 页面把一次视图需要的读法整体交给 [watch]，而不是逐条查询各订阅一次：
/// 一次提交往往同时改到几张表，整份读法只重跑一次，回填的也一定是同一
/// 时刻的数据。[tables] 是这份读法读到的全部表，通知与它有交集才重读。
class LiveQueries {
  LiveQueries({required this.changes, required this.run});

  /// 表变更通知，来自 [TableChanges.stream]。
  final Stream<Set<String>> changes;

  /// 读取的执行方式：跟库的实例经 [DatabaseGate] 的共享访问执行，只读副本
  /// 直接执行。读取与独占区因此不会交叉。
  final Future<T> Function<T>(Future<T> Function() read) run;

  Stream<T> watch<T>({
    required Set<String> tables,
    required Future<T> Function() read,
  }) {
    return Stream.multi((listener) {
      var latest = 0;
      var closed = false;

      Future<void> refresh() async {
        final request = ++latest;
        try {
          final value = await run(read);
          if (closed || request != latest) return;
          listener.add(value);
        } catch (error, stack) {
          if (closed || request != latest) return;
          listener.addError(error, stack);
        }
      }

      final subscription = changes.listen((changed) {
        if (!changed.any(tables.contains)) return;
        unawaited(refresh());
      });
      listener.onCancel = () {
        closed = true;
        return subscription.cancel();
      };
      unawaited(refresh());
    }, isBroadcast: false);
  }
}
