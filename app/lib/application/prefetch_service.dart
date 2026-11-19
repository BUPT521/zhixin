import 'dart:async';

import '../domain/rules/time_policy.dart';

/// 一级界面：底栏四栏。页面在这些栏切进来之后预读它下面几个二级界面的首屏。
///
/// 预读只在对应的一栏切进来之后开始，启动时不把四个栏目的二级页面一起读：
/// 首屏只承担首页与其余三栏本身，用不到的内容不占启动时间与内存。
enum PrefetchArea { now, records, plan, mine }

/// 一个二级界面首屏读取的名称；读取方与预读方按同一个键取同一份结果。
///
/// 键只表示“哪个界面的首屏”，不带筛选与分页参数：这类读取参数固定，换了
/// 参数就是另一次读取，页面自己重新订阅，不命中预读结果。
class PrefetchKey {
  const PrefetchKey._(this.name);

  final String name;

  /// 记忆页的一屏：记忆、范围名字与页码数量。
  static const memory = PrefetchKey._('memory');

  /// 数据版本页的一屏：提交历史、撤销判断、存储占用与恢复点。
  static const dataVersion = PrefetchKey._('data_version');

  /// 设置页本机读取的一组结果。
  static const settings = PrefetchKey._('settings');

  /// 云端备份列表；未登录时不读。
  static const cloudBackups = PrefetchKey._('cloud_backups');

  /// 记录查找的范围选项：目标与材料。
  static const recordsSearchOptions = PrefetchKey._('records_search_options');

  /// 安排查找的目标选项。
  static const planSearchGoals = PrefetchKey._('plan_search_goals');

  /// 语义索引设置页的一组结果。
  static const embeddingSettings = PrefetchKey._('embedding_settings');

  @override
  String toString() => 'PrefetchKey($name)';
}

/// 二级界面首屏的预读结果：一级界面切进来之后在后台取一次，页面打开时直接
/// 用这一份结果，读完之前的骨架因此不再出现。
///
/// 预读只取第一份结果，不保持订阅：读取失败时移除这一项，页面按原来的路径
/// 自己读并给出就地说明；页面打开之后仍然订阅数据层的更新，写入、撤销与换库
/// 之后照常重读（ADR-0014）。[ttl] 之后没被取用的结果直接丢弃，避免把很久
/// 以前读到的内容留在内存里。
class PrefetchService {
  PrefetchService({
    required this.tasks,
    required this.clock,
    this.ttl = const Duration(minutes: 5),
  });

  /// 各一级界面切进来之后要预读的内容；按栏分组，同一栏的任务可以并行。
  final Map<PrefetchArea, List<Future<void> Function()>> tasks;

  /// 当前时间；预读结果的失效时间按它计算。
  final Clock clock;

  /// 预读结果保留多久；超过之后没有取用就丢弃。
  final Duration ttl;

  final Map<String, _Entry> _entries = {};

  /// 切到某一栏：执行这一栏的预读任务，已经在有效期内的结果不重读。
  ///
  /// 任务不阻塞切栏，失败只说明这一项没有预读成功；页面自己读时照常处理。
  void enter(PrefetchArea area) {
    for (final task in tasks[area] ?? const <Future<void> Function()>[]) {
      unawaited(() async {
        try {
          await task();
        } catch (_) {
          // 预读失败不打扰界面：页面打开时会按原来的路径读一次并说明原因。
        }
      }());
    }
  }

  /// 预读一份首屏结果；同一个键在有效期内只读一次。
  ///
  /// 返回的是这次读取的 future，页面要等结果时可以直接等它；页面也可以只读
  /// 已经完成的结果（[peek]），没有完成就按原来的路径自己读。
  Future<T> warm<T>(PrefetchKey key, Future<T> Function() read) {
    final existing = _live(key.name);
    if (existing != null) return existing.future as Future<T>;
    final entry = _Entry(clock().add(ttl));
    _entries[key.name] = entry;
    final Future<T> future;
    try {
      future = read();
    } catch (error, stack) {
      // 同步抛出时同样不留下半项：页面自己读的时候重新走一遍。
      _entries.remove(key.name);
      return Future<T>.error(error, stack);
    }
    entry.future = future;
    unawaited(
      future.then<void>(
        (value) => entry.value = value,
        onError: (Object error, StackTrace stack) {
          // 读失败时把这一项移除：页面自己读时重新走一遍并给出说明。
          if (identical(_entries[key.name], entry)) _entries.remove(key.name);
        },
      ),
    );
    return future;
  }

  /// 已经读完的预读结果；还在读、读失败或已经过期时为空。
  ///
  /// 结果可以多次取用：记忆与数据版本这类页面接过去之后仍然订阅数据层的
  /// 更新，首屏只负责不要在读完之前空着。
  T? peek<T>(PrefetchKey key) {
    final entry = _live(key.name);
    return entry?.value as T?;
  }

  /// 取走已经读完的预读结果：设置这类会被同一页改动的数据只用于第一次打开，
  /// 之后再打开按当前状态重新读，避免显示一级界面打开时读到的旧值。
  T? take<T>(PrefetchKey key) {
    final value = peek<T>(key);
    if (value != null) _entries.remove(key.name);
    return value;
  }

  /// 还有效的预读项；过期时顺手移除。
  _Entry? _live(String name) {
    final entry = _entries[name];
    if (entry == null) return null;
    if (!clock().isBefore(entry.deadline)) {
      _entries.remove(name);
      return null;
    }
    return entry;
  }
}

class _Entry {
  _Entry(this.deadline);

  final DateTime deadline;
  Future<Object?>? future;
  Object? value;
}
