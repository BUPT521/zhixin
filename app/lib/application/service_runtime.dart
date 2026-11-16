import '../data/db/live_queries.dart';
import '../domain/rules/time_policy.dart';

/// 模型调用失败时写进本机诊断记录；界面只拿归类后的说明。
typedef ModelFailureRecorder = void Function(
  Object error,
  StackTrace? stack, {
  required String kind,
});

/// 服务共用的运行环境：时间口径、数据代次、附件目录与失败记录。
///
/// 这几项在应用根上会变：保存或撤销每日截止小时之后时间口径换新，整库恢复、
/// 清空与导入之后数据代次加一，应用私有目录要到启动时才确定。服务不自己保存
/// 这些值，每次从运行环境读当前值，因此应用根只装配一次，不必给每个服务各传
/// 一个闭包。
class ServiceRuntime {
  ServiceRuntime({
    required this.policySource,
    required this.filesDirSource,
    this.dataEpochSource = _zeroDataEpoch,
    this.live,
    this.recordFailure,
  });

  /// 时间口径的来源；应用根按当前截止小时现给一份。
  final TimePolicy Function() policySource;

  /// 附件目录的来源；启动时才确定路径。
  final String Function() filesDirSource;

  /// 数据代次的来源；恢复、清空与导入之后加一。
  final int Function() dataEpochSource;

  /// 跟随写入更新的读取；单元测试没有接库时为空，读取只执行一次。
  final LiveQueries? live;

  /// 当前的时间口径；截止小时改变后返回新值，服务不缓存旧口径。
  TimePolicy get policy => policySource();

  /// 应用私有目录；图片按文件名保存在这里，读取时拼回目录。
  String get filesDir => filesDirSource();

  /// 当前数据代次；异步回答据此判断恢复之后能否写回。
  int get dataEpoch => dataEpochSource();

  /// 跟随写入更新的读取：[tables] 里任一表被写入后重新执行 [read]。
  ///
  /// 服务的流式读法都从这里出去（ADR-0014）：页面订阅之后不再在写入之后
  /// 自己重读，恢复与清空换库时也由数据层补发一次。
  Stream<T> watch<T>({
    required Set<String> tables,
    required Future<T> Function() read,
  }) {
    final queries = live;
    if (queries == null) return Stream.fromFuture(read());
    return queries.watch(tables: tables, read: read);
  }

  /// 模型调用的类型、消息与调用栈只交给本机诊断记录，不进入界面说明。
  final ModelFailureRecorder? recordFailure;
}

int _zeroDataEpoch() => 0;
