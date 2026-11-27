/// 一条已提交作答进入索引与查找时使用的正文。
///
/// 三段各自可空，空的段不参与拼接：缺解答或反馈的作答与补齐之后的正文不同，
/// 但同一份数据在任何路径上都必须拼出同一个字符串。索引写入、写回前的版本
/// 核对与字面命中三处共用这一份拼法；各处自己拼时，缺一段就少一个分隔符，
/// 来源版本随之不同，索引里仍然有效的作答会被判成过期而从语义检索里消失。
String answerText(String? userAnswer, String? solution, String? feedback) {
  final parts = <String>[
    for (final part in [userAnswer, solution, feedback])
      if (part != null && part.trim().isNotEmpty) part,
  ];
  return parts.join('\n');
}
