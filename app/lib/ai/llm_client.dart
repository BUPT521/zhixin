/// 模型客户端入口：失败与预算、传输、协议三组文件在此汇总。
///
/// 其他文件继续 import 本文件；公开符号与拆分前一致。
library;

export 'llm_failure.dart';
export 'llm_protocol.dart' show LlmImage, LlmMessage, LlmTool;
export 'llm_transport.dart';
