import 'coded_enum.dart';

/// 一次回答过程中需要界面区分的情况。
///
/// 应用层只给出状态与具体原因，说明语句由界面按枚举写；[value] 写进回答的
/// 结构化字段，重新打开讨论时据此恢复提示与恢复入口，[label] 是界面可显示的
/// 说法，不参与状态判断。
enum Notice implements CodedEnum {
  modelNotConfigured('model_not_configured', '还没有登录知新服务'),
  modelConfigReadFailed('model_config_read_failed', '模型配置读取失败'),
  modelCallFailed('model_call_failed', '模型调用失败'),
  noSendableContent('no_sendable_content', '没有可发送的内容'),
  imagesUnavailable('images_unavailable', '图片不可用'),
  answerTruncated('answer_truncated', '回答被截断'),
  userStopped('user_stopped', '用户停止生成'),
  generationInterrupted('generation_interrupted', '生成中断'),
  memorySaveFailed('memory_save_failed', '记忆保存失败');

  const Notice(this.value, this.label);

  @override
  final String value;

  @override
  final String label;
}

/// 按写进结构化字段的值读回提示状态；认不出的值返回空，界面不显示未知提示。
Notice? noticeFromValue(String? value) =>
    codedValueOrNull(Notice.values, value);
