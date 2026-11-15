import 'dart:convert';

/// 一次写动作的幂等编号，按“动作 + 稳定输入”生成。
///
/// 编号由动作名和这次动作的稳定输入拼成，不取随机数与当前时间：同一个动作用
/// 同样的输入重试会得到同一个编号，[WriteTransactions.run] 据此只形成一条提交；
/// 输入不同的两个动作得到不同编号，不会互相误判成重试。界面不再手拼编号，
/// 服务层在入口生成后传下去，界面只负责触发。
///
/// 输入里的空值写成空串，字符串去掉首尾空白，时刻统一按 UTC 写入；[input]
/// 的顺序就是编号的一部分，同一个动作的调用方必须按固定顺序传。
String commandId(String action, [Iterable<Object?> input = const []]) =>
    jsonEncode([action, for (final value in input) _stablePart(value)]);

String _stablePart(Object? value) => switch (value) {
  null => '',
  DateTime moment => moment.toUtc().toIso8601String(),
  String text => text.trim(),
  _ => '$value',
};
