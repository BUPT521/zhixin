/// 各界面首屏订阅的数据表：写入这些表之后，对应的一屏整份重读一次（ADR-0014）。
///
/// 表名与 `data/db/drift/tables.dart` 的表类一致。清单集中在这里，新增界面或
/// 调整订阅范围时只改一处，不在各个应用服务里各留一份集合（A31）。
abstract final class ScreenTables {
  /// 首页摘要：计划行、步骤、材料、目标、讨论、消息、作答与待办。
  ///
  /// 一次提交常同时改到其中几张表，整屏读法只重跑一次，回填的也一定是同一
  /// 时刻的数据。
  static const Set<String> home = {
    'study_plan',
    'plan_item',
    'material',
    'learning_goal',
    'conversation',
    'message',
    'attempt',
  };

  /// 讨论页：记录行自身还会补出材料标题、是否有作答与是否有草稿，因此
  /// `attempt` 与 `material` 也在其中；目标选择读 `learning_goal`。
  static const Set<String> conversation = {
    'conversation',
    'message',
    'attempt',
    'material',
    'learning_goal',
  };

  /// 学习页：题目视图里的出处与材料标题来自 `material`，材料改名之后也要重读；
  /// 判断与记忆建议分别来自 `assessment` 与 `attempt`，接受记忆卡片时写入的
  /// `memory` 一并列上，避免漏掉只写记忆的那一次提交。
  static const Set<String> question = {
    'conversation',
    'message',
    'attempt',
    'assessment',
    'material',
    'memory',
  };

  /// 记录页：目标、这一页记录，以及每题最近一次尝试的判断。
  ///
  /// 分页仍按屏幕上的“继续读取”逐页追加，订阅只负责在这几张表被写入时整屏
  /// 重读。
  static const Set<String> records = {
    'conversation',
    'message',
    'attempt',
    'assessment',
    'learning_goal',
    'material',
    'study_session',
  };

  /// 记忆建议页：有作答的记录连同题干、最近一次作答与记忆。
  ///
  /// 记忆也列在这里，因为哪些来源已经处理过由记忆表判断：接受建议或撤销之后
  /// 重读一次，页面与“已经处理过”的判断保持同一时刻。
  static const Set<String> memoryProposal = {
    'conversation',
    'message',
    'attempt',
    'material',
    'memory',
  };

  /// 材料列表：材料行、页码与所属目标。
  ///
  /// 任一表被写入之后整份重读一次，材料列表与材料详情因此跟随其它入口的导入、
  /// 更正与归属调整。
  static const Set<String> materialList = {
    'material',
    'material_page',
    'learning_goal',
  };

  /// 材料详情与单页原文：材料行的时间与页码计数随页码一起变化。
  static const Set<String> materialPages = {'material', 'material_page'};

  /// 记忆页：记忆条目、目标与材料标题，材料列表还读页码数量。
  static const Set<String> memoryPage = {
    'memory',
    'learning_goal',
    'material',
    'material_page',
  };

  /// 设置页：截止小时与拍照方式都在 `app_meta` 里。
  static const Set<String> settings = {'app_meta'};

  /// 系统学习页：计划、步骤、材料与场次。
  static const Set<String> studyPlan = {
    'study_plan',
    'plan_item',
    'material',
    'study_session',
  };

  /// 安排页的目标选项。
  static const Set<String> goals = {'learning_goal'};

  /// 安排页概览：事项与目标。
  static const Set<String> planOverview = {'plan_item', 'learning_goal'};

  /// 已完成事项的分页。
  static const Set<String> planItems = {'plan_item'};
}
