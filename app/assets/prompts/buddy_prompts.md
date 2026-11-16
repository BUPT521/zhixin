# 知新提示词请求文本

<!-- 与 buddy_system.md 一起由 app/lib/platform/prompt_assets.dart 读取；只改文案时不需要动 Dart 代码。 -->

## request.chat

看看这道题，告诉我现在最该做的一步。

## request.hint

给我一个提示，不直接给答案。

## request.explain

完整讲这道题，讲清依据。

## request.check

检查我的做法，指出第一个需要改的地方。

## request.plan

按材料范围提出学习顺序。

## request.study_steps

按本次提供的材料提出学习步骤，覆盖{{range}}，每一步写清{{unit}}范围与结束条件；材料里没有展开但完成目标必需的内容，标为前置内容。不得引用本次范围之外的{{unit}}。

## request.study_earlier

前面批次已经给出的步骤：
{{earlier}}
不要重复这些步骤；本批次的内容如果依赖前面的步骤，在说明里写明依赖第几步。

## request.previous_prefix

前面共 {{count}} 步，以下只列最近 12 步。

## request.previous_line

{{index}}. {{title}}{{range}}

## request.previous_range

（{{range}}）
