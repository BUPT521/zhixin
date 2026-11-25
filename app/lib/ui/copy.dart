/// 界面文案表：同一件事的说法只在这里定一次。
///
/// 只收跨页面重复出现、或者容易写岔的字面量；一页只出现一次的按钮与说明仍
/// 写在页面里。角色名与页签名以 docs/00-产品定义.md 与 docs/02-产品与交互.md
/// 为准。
library;

import '../plugins/runtime/plugin_manifest.dart';

/// 角色名。00 产品定义把产品写成“一个懂你的学习搭子”，界面不再用“AI”称呼
/// 这个角色。
const buddyName = '搭子';

/// 安排页的板块名：模型写入的变更。
///
/// 02 文档把它写作「AI 的改动」，这里的“AI”指写入者而不是角色，所以与
/// [buddyName] 分开保留；板块标题用这一份完整写法，安排页的页签为了四项等分
/// 只显示“AI”，读屏仍读这一份，见 `plan_page.dart`。
/// 用户在记忆页手动改的记忆不算模型写入，由 `plan_service.dart` 的动作名单排除。
const aiChanges = 'AI 的改动';

/// 底栏四个入口；页面标题引用同一组常量，不另写一份。
const tabNow = '现在';
const tabRecords = '记录';
const tabPlan = '安排';
const tabMine = '我的';

/// 记录页的两个页签。
///
/// 02 文档用“记录”称呼整页，页内第一个页签写“学习记录”，与“材料”并列。
const recordsTabLearning = '学习记录';
const recordsTabMaterials = '材料';

/// 安排页的四个页签。
const planTabSchedule = '日程';
const planTabItems = '事项';
const planTabGoals = '目标';

/// 事项的实体名。页签写 [planTabItems]，板块标题与提交明细写“学习事项”。
const planItemName = '学习事项';

/// 数据版本与同步状态里的表名：提交明细、恢复预检与账号页的差异表共用这一份。
///
/// 键是库里的表名，值是界面上的叫法；没有登记的表按表名原样显示，新增表时要
/// 在这里补一行，`test/ui/table_labels_test.dart` 会核对参与采集的表都有中文名。
String tableLabel(String table) => switch (table) {
  'app_meta' => '设置',
  'learning_goal' => '目标',
  'asset_object' => '附件对象',
  'asset_chunk' => '附件内容',
  'attachment' => '附件',
  'material' => '材料',
  'material_page' => '材料页',
  'conversation' => '讨论',
  'message' => '消息',
  'study_plan' => '学习计划',
  'plan_item' => planItemName,
  'timetable_entry' => '课表',
  'schedule_block' => '预约',
  'study_session' => '学习场次',
  'attempt' => '作答',
  'assessment' => '学习判断',
  'memory' => '记忆',
  'memory_usage' => '记忆使用',
  _ => table,
};

/// 空态标题的句式：写“还没有 X”，不写“暂无 X”，说明里再给下一步。
///
/// 记录页的学习记录、事项页的两处、安排页的 [aiChanges] 与本周预约、记忆页
/// 都用这一组，句式一致。
const emptyRecords = '还没有学习记录';
const emptyPlanItems = '还没有学习事项';
const emptyPlanItemsNoneOpen = '还没有未完成的学习事项';
const emptyWeekAppointments = '本周还没有预约';
const emptyOtherWeekAppointments = '这一周还没有预约';
const emptyMemory = '还没有学习记忆';
const emptyChangesTitle = '还没有改动';
const emptyChangesDescription = '$buddyName执行过的变更会出现在这里。';

/// “我的”页的插件与人格入口，以及这两页的标题。
const pluginsPageTitle = '插件';
const personaPageTitle = '人格';
const pluginsEntrySubtitle = '启停随应用编译的插件。';
const personaEntrySubtitle = '选择搭子的语气、称呼与讲解风格。';

/// 人格页的顺序与边界说明；设置页与人格页共用同一句。
const personaBoundaryNotice =
    '人格只影响语气、称呼、讲解风格与篇幅倾向，判分、引用与写入不随人格改变。'
    '启用的人格优先于记忆中记下的讲解偏好，用户本轮的说明又优先于人格。';

/// 人格的导入、编辑与分享本次不开放；页面写明，不放死按钮。
const personaExtrasUnavailable = '导入、编辑与分享暂未开放，当前只有内置人格。';

/// 人格插件在插件页被停用时的说明。
const personaPluginDisabled = '人格插件已在插件页停用，启用之后人格设定才会进入提示词。';

/// 人格页没有启用项时的状态行。
const personaDefaultTone = '当前未启用人格，搭子使用默认语气。';

/// 插件不需要任何权限时的说法。
const noPluginPermissions = '不需要权限';

/// 插件类型的显示名。
String pluginKindLabel(PluginKind kind) => switch (kind) {
  PluginKind.capability => '能力插件',
  PluginKind.persona => '人格插件',
};

/// 把清单声明的四项权限写成一句中文说明；全空时写“不需要权限”。
String pluginPermissionSummary(PluginPermissions permissions) {
  if (permissions.isEmpty) return noPluginPermissions;
  return [
    if (permissions.networkDomains.isNotEmpty)
      '网络访问：${permissions.networkDomains.join('、')}',
    if (permissions.readDataScopes.isNotEmpty)
      '读取数据：${permissions.readDataScopes.join('、')}',
    if (permissions.writeTypes.isNotEmpty)
      '提交草稿：${permissions.writeTypes.join('、')}',
    if (permissions.callModel) '调用模型',
  ].join('；');
}
