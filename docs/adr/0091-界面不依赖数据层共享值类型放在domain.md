# ADR-0091 界面不依赖数据层，共享值类型放在 domain

## 状态

已采纳。

## 日期

2026-11-28

## 背景

批次 A 在 `app/test/architecture_test.dart` 增加了一条用例，约束界面不直接依赖数据层。当时的实测结果是界面有 20 处引用数据层，涉及 12 个文件，用例用一份只减不增的白名单放行。

这些引用按用途分三类。多数只是借用数据层里的值类型，例如 `ServerProblem`、`ServerQuota`、`AccountIdentity`、`RevisionCommit`、`RestoreInspection`、`RestorePoint`、`EmbeddingConfig` 与两个保留天数常量；`settings_page.dart` 直接写 `CrashLog.reportEnabled`；`data_version_page.dart` 与 `integrity_check.dart` 直接持有 `RevisionService` 与 `DataVersionService`。值类型留在 `data` 里，页面就不得不 import 数据层，白名单因此无法缩小。

## 决定

界面不直接依赖数据层。页面需要的值类型放在 `domain/models`，常量放在 `domain/rules`，行为经 `application` 的服务取用。

数据层、应用层与界面层引用同一份声明。依 [ADR-0001](0001-开发阶段不向下兼容.md) 直接改全部引用，不写 `export` 转发，也不留旧路径别名。

页面需要的读写由应用服务提供入口。崩溃报告开关经 `SettingsService.setCrashReporting` 与 `CrashReportingSwitch` 端口，设置页不再直接写 `CrashLog.reportEnabled`；应用层的值类型与端口放在 `application`，平台实现留在 `platform`，应用层因此不引 `platform`、`package:flutter` 与 `dart:io`。

`RevisionService` 与 `DataVersionService` 留在白名单里：`DataServices` 仍把这两个数据层服务公开给页面，是否迁到 `application` 待定。

这条决定由 `app/test/architecture_test.dart` 的两个用例守住。一个约束 domain、ai、data 与 application 的依赖单向；另一个要求界面依赖数据层的文件必须出现在 `_uiDataAllowlist` 里，并且白名单里的文件必须仍然依赖数据层，使清单只减不增。

## 代价与边界

搬家带来大量 import 改动。这一轮搬了服务端响应模型、账号会话与资料、嵌入配置、整库恢复的预检产物、恢复点、版本模型与版本动作常量，`lib` 与 `test` 合计两百余处 import 需要改到新路径。

`domain` 不能引用 `package:http`、`package:flutter` 与 `dart:io`，服务端客户端、文件读写与安全存储仍留在 `data` 与 `platform`。新增这类能力时要先定端口放在哪一层，不能把实现直接放进 `domain`。

白名单只减不增。新增界面不得以“只借一个类型”为由引用数据层，需要新类型时把它放进 `domain/models`。

这条决定不改变运行行为：数据库结构、数据包格式、设置键与文件名都不受影响，搬家提交不夹带行为修改。

## 替代方案

用 `export` 把值类型从 `data` 转发给界面。界面仍然通过数据层取类型，白名单无法缩小，而且同一个类型留下两个路径，没有采纳。

把这些值类型放进 `application`。`data` 会反向依赖 `application`，违反依赖单向，没有采纳。

把 `RevisionService` 与 `DataVersionService` 迁进 `application`。这需要在数据层之上新写一层包装并调整 `DataServices` 的装配，属于需要用户决定的取舍，本轮没有做。

## 影响

用例与白名单见 [architecture_test.dart](../../app/test/architecture_test.dart)。整改批次与各项状态见[分层整改清单与提示词](../分层整改清单与提示词.md)。批 10 的范围与验收见[客户端实现审查与批次](../客户端实现审查与批次.md)。`AGENTS.md`、`CONTRIBUTING.md` 与 [03](../03-团队分工与协作.md) 的分层口径由批 11 统一核对。
