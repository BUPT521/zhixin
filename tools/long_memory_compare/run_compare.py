#!/usr/bin/env python3
"""长期记忆对照脚本：用同一批合成历史跑 Mem0 OSS 与 Hindsight。

本机没有配置模型提供方，也没有 Hindsight 凭据，因此这两个对照尚未运行；
脚本只依赖标准库，缺依赖或缺凭据时报出具体缺少项并退出，不会伪造结果。

用法：
    python tools/long_memory_compare/run_compare.py mem0
    python tools/long_memory_compare/run_compare.py hindsight

Mem0 需要 `pip install mem0ai`，并通过环境变量配置一个模型提供方，例如
    OPENAI_API_KEY=...
Mem0 的提取与检索都调用模型，没有 key 时无法离线得到结果。

Hindsight 需要 `HINDSIGHT_API_KEY`，可选 `HINDSIGHT_BASE_URL` 与
`HINDSIGHT_BANK_ID`；脚本按 recall 接口发送查询并打印返回内容，再对照
history.json 里的必要证据标识人工核对。
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

HISTORY = Path(__file__).with_name("history.json")


def load_history() -> dict:
    with HISTORY.open(encoding="utf-8") as handle:
        return json.load(handle)


def messages_for(history: dict) -> list[dict]:
    messages: list[dict] = []
    for conversation in history["conversations"]:
        for message in conversation["messages"]:
            messages.append(
                {
                    "role": message["role"],
                    "content": message["content"],
                    "created_at": message["created_at"],
                }
            )
        for attempt in conversation.get("attempts", []):
            if not attempt.get("answer"):
                continue
            messages.append(
                {
                    "role": "assistant",
                    "content": (
                        f"作答：{attempt['answer']}；"
                        f"帮助次数：{attempt.get('help_count', 0)}；"
                        f"独立性：{attempt.get('independent')}；"
                        f"隔后重做：{attempt.get('delayed')}"
                    ),
                    "created_at": attempt["submitted_at"],
                }
            )
    return messages


def run_mem0(history: dict) -> int:
    try:
        from mem0 import Memory  # type: ignore
    except ImportError:
        print("缺少 mem0ai：先执行 pip install mem0ai，并配置模型提供方。")
        return 2
    if not any(
        os.environ.get(name)
        for name in ("OPENAI_API_KEY", "ANTHROPIC_API_KEY", "DEEPSEEK_API_KEY")
    ):
        print("缺少模型凭据：Mem0 的提取与检索需要模型，设置对应 API key 后再运行。")
        return 3

    memory = Memory()
    user_id = "zhixin-synthetic"
    messages = messages_for(history)
    memory.add(messages, user_id=user_id)
    print("== Mem0 提取结果 ==")
    for item in memory.get_all(user_id=user_id):
        print("-", item.get("memory", item))

    print("== 查询对照 ==")
    for case in history["queries"]:
        results = memory.search(case["query"], user_id=user_id)
        texts = [item.get("memory", "") for item in results]
        matched = [
            evidence
            for evidence in case["required_evidence"]
            if any(evidence.split(":")[-1] in text for text in texts)
        ]
        print(
            f"{case['id']}: 找回 {len(matched)}/{len(case['required_evidence'])} "
            f"必要证据；返回 {len(texts)} 条记忆"
        )
        for text in texts:
            print("   ", text)
    return 0


def run_hindsight(history: dict) -> int:
    api_key = os.environ.get("HINDSIGHT_API_KEY")
    if not api_key:
        print("缺少 HINDSIGHT_API_KEY：先配置服务凭据，再运行该对照。")
        return 3
    base = os.environ.get("HINDSIGHT_BASE_URL", "https://api.hindsight.vectorize.io")
    bank = os.environ.get("HINDSIGHT_BANK_ID", "zhixin-synthetic")

    import urllib.error
    import urllib.request

    for case in history["queries"]:
        payload = json.dumps({"query": case["query"], "bank_id": bank}).encode("utf-8")
        request = urllib.request.Request(
            f"{base.rstrip('/')}/v1/recall",
            data=payload,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {api_key}",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = response.read().decode("utf-8")
        except urllib.error.URLError as error:
            print(f"{case['id']}: 请求失败 {error}")
            continue
        print(f"== {case['id']} ==")
        print(body)
        print("必要证据：", ", ".join(case["required_evidence"]))
    return 0


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[1] not in {"mem0", "hindsight"}:
        print(__doc__)
        return 1
    history = load_history()
    return run_mem0(history) if argv[1] == "mem0" else run_hindsight(history)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
