/// 界面文案表：同一件事的说法只在这里定一次。
///
/// 只收跨页面重复出现、或者容易写岔的字面量；一页只出现一次的按钮与说明仍
/// 写在页面里。角色名与页签名以 docs/00-产品定义.md 与 docs/02-产品与交互.md
/// 为准。
library;

/// 角色名。00 产品定义把产品写成“一个懂你的学习搭子”，界面不再用“AI”称呼
/// 这个角色。
const buddyName = '搭子';

/// 安排页的板块名：程序写入的变更。
///
/// 02 文档把它写作「AI 的改动」，这里的“AI”指写入方式而不是角色，所以与
/// [buddyName] 分开保留；页签与板块标题共用这一份，不再一处写“AI 改动”。
const aiChanges = 'AI 的改动';

/// 底栏三个入口；页面标题引用同一组常量，不另写一份。
const tabNow = '现在';
const tabRecords = '记录';
const tabPlan = '安排';

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
