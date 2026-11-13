/// 知新回答的传输约定：正文是 Markdown，需要附带的数据通过工具调用提交。
///
/// 单步输出的最高上限，实际请求还受模型上下文配置约束。
const int buddyMaxOutputTokens = 8192;
