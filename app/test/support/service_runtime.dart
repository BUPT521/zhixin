import 'package:zhixin/application/service_runtime.dart';
import 'package:zhixin/domain/rules/time_policy.dart';

export 'package:zhixin/application/service_runtime.dart';

/// 测试用的服务运行环境：时间口径由用例给出，附件目录与数据代次按需覆盖。
///
/// 不需要附件目录或数据代次的用例不重复写 `() => '.'` 与 `() => 0`，需要
/// 时各自传入；这样装配写法和生产入口保持一致，也不给每个用例各搭一份。
ServiceRuntime testRuntime({
  TimePolicy Function()? policy,
  String Function()? filesDir,
  int Function()? dataEpoch,
  ModelFailureRecorder? recordFailure,
}) => ServiceRuntime(
  policySource: policy ?? _defaultPolicy,
  filesDirSource: filesDir ?? _unusedFilesDir,
  dataEpochSource: dataEpoch ?? _zeroEpoch,
  recordFailure: recordFailure,
);

TimePolicy _defaultPolicy() => TimePolicy(clock: systemClock);
String _unusedFilesDir() => '.';
int _zeroEpoch() => 0;
