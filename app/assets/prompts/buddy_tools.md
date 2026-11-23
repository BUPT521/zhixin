# 知新工具说明

<!-- 与 buddy_system.md、buddy_prompts.md 一起由 app/lib/platform/prompt_assets.dart 读取、app/lib/ai/prompt_text.dart 解析；只改文案时不需要动 Dart 代码。 -->

## tool.propose_memories

提交这次回答里值得记住的事实。只提交，不直接写数据库；用户明确说出的记忆由程序先记下并可撤销，你推断的记忆由用户点“记下”后才保存。kind 只有三类：episodic 是发生过的一件事，带时间与对象，例如“第 8 题在放缩这一步卡住”；semantic 是关于用户的稳定事实与限制，例如“每周只有两晚能学习”“不喜欢先给完整答案”；procedural 是该怎么做的做法，例如“讲到矩阵时先给 2 阶例子再给定义”。判断口诀：说得出一件发生过的事就填 episodic，说得出长期成立的事实或限制就填 semantic，说得出以后该怎么讲、怎么做就填 procedural。只记长期有用或本次有效的内容，寒暄、一次性情绪和单次卡点不要提交。用户明确说出的内容 source 用 user；你根据记录推断的用 inferred，用户没有说过的不要编造。

## tool.propose_memories.content

一句话，不超过 {{limit}} 字；语义与程序、不加有效期、不限定范围的记忆会每轮带入，所以只写确实长期成立的内容

## tool.propose_memories.valid_until

YYYY-MM-DD HH:MM:SS；长期有效填 null

## tool.propose_memories.source

用户明确说出的用 user，你推断的用 inferred

## tool.propose_next_steps

提交 1–3 条下一步建议。只是建议，不创建待办、不改动日程；用户点“加入安排”后才由程序保存。每条写清做什么与做到什么算结束，材料出处或题号写进标题或动作里。用户没有问下一步时不要提交。

## tool.propose_next_steps.title

动作标题

## tool.propose_next_steps.action

具体动作

## tool.propose_next_steps.end_condition

什么时候算结束

## tool.propose_next_steps.minutes

预计分钟数，可省略

## tool.propose_citations

提交这次回答依据的材料页。quote 必须逐字摘录该页原文，material_id 用材料页前面标的编号；不要改写、拼接或编造页码。没有依据就不要调用。

## tool.propose_citations.quote

原文逐字摘录

## tool.propose_assessment

提交这次学习结果的判断。只提交依据，不替用户判分；结果区分独立完成、辅助完成与待核实。

## tool.propose_assessment.basis

依据哪段原文或哪次提示

## tool.propose_study_steps

按本次给出的材料页提出学习步骤，覆盖本次范围。每步必须填写整数 page_from 与 page_to，从本次范围的第一页起连续覆盖到最后一页，不跳页、不重叠，一步可以覆盖多页；步数不超过范围内的页数。完成目标必需、但材料里没有展开的内容标 is_prerequisite=true 并写进 note。不要替用户安排时间。

## tool.propose_study_steps.title

这一步做什么

## tool.propose_study_steps.note

补充说明

## tool.read_material_page

当材料检索摘录不足以回答时，读取本轮检索命中的指定材料页原文。offset 按 Unicode 字符计数，从页首读取时省略，需要后续原文时用 next_offset。

## tool.search_sources

首轮摘录不足时，在本轮范围与用户带入的来源内改写查询补搜。每轮最多调用两次，每次最多五条候选，摘录约两百字；不能扩大到当前目标、材料与这条讨论之外。

## tool.search_sources.query

改写后的查询，保留题号、公式或原句

## tool.submit_probe

连接测试：确认这个模型或地址可以返回工具调用。

## tool.submit_probe.system

你是连接测试助手。只调用 submit_probe 工具，不要写正文。

## tool.submit_probe.user

连接测试
