import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoPageTransitionsBuilder;
import 'package:forui/forui.dart' as forui;
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:material_ui/material_ui.dart';

import 'motion.dart';

export 'motion.dart';

part 'theme_palette.dart';
part 'theme_tokens.dart';
part 'theme_forui.dart';
part 'theme_material.dart';

/// 应用的两套外观：色值与字号只在这一组文件里定义一次，Forui 主题、页面读到的
/// 字号与颜色、回答正文的 Markdown 主题都从同一份生成。
///
/// 文件按职责分开：[theme_tokens.dart] 是间距、圆角、字号与颜色这些令牌，
/// [theme_palette.dart] 由主题色换算出主色家族与提醒色，[theme_forui.dart] 与
/// [theme_material.dart] 分别把它们装配成两套主题。四份文件同属这一个库，
/// 页面仍然只从 `theme.dart` 导入。
///
/// 色板分成两部分：背景、表面、描边、文字与错误色是固定的中性色，深浅两套
/// 各一份，不随主题色改变；主色家族（主色、压在主色上的文字、主色浅底、
/// 主色容器与容器上的文字）与提醒色由 [ZhixinAccent] 生成，见 [_palette]。
/// 所以换主题色时只有按钮、链接、选中态与强调卡片的颜色变，页面与卡片的
/// 底色始终是纯白或纯黑，不带主题色的色相。
///
/// 页面不再读 Material 的 `Theme.of`，统一读 Forui 主题里的 [ZhixinTheme]；
/// Material 的 `ThemeData` 只留给 `gpt_markdown`（它要 `GptMarkdownThemeData`
/// 与 `TextTheme`）和本地化，不再是一份需要单独维护的色板。
///
/// 六个主题色的浅色与深色两套主题由 [foruiThemesFor] 与 [materialThemesFor]
/// 生成；[zhixinForuiTheme] 与 [zhixinTheme] 是默认蓝色主题，[zhixinDarkForuiTheme]
/// 与 [zhixinDarkTheme] 是它的深色一套。
