# 长期记忆对照脚本

`history.json` 与 `app/test/evaluation/longmem_eval_test.dart` 使用同一批合成历史：同一道题三次作答（提示下完成、做错、隔天独立完成）、材料页更正、无归属讨论与一组查询。查询写明查询时间、范围与必要证据标识。

`run_compare.py` 用 Mem0 OSS 与 Hindsight 跑这份历史：

```bash
pip install mem0ai
$env:OPENAI_API_KEY = "..."   # 或 Anthropic / DeepSeek 等等价密钥
python tools/long_memory_compare/run_compare.py mem0

$env:HINDSIGHT_API_KEY = "..."
python tools/long_memory_compare/run_compare.py hindsight
```

Mem0 的提取与检索都需要模型，Hindsight 需要远端服务凭据；缺少依赖或凭据时脚本会说明缺少项并退出，不编造结果。本机没有配置模型提供方与 Hindsight 凭据，因此这两项对照尚未运行，缺口与固定用例记录在 `app/test/evaluation/longmem_eval_test.dart`。

对照时检查三件事：提取结果是否保留来源作答与适用范围；是否区分提示下完成、独立完成与延迟后的独立完成；用户纠正或删除之后，同一来源是否还会生成旧判断。Hindsight 的返回内容按 `history.json` 里的必要证据标识人工核对，重点看是否引用各次作答、是否区分当时的帮助条件与后来的独立表现、证据不足时是否说明待确认。
