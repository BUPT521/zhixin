import '../ai/llm_config.dart' show LlmConfig;
import '../data/backup/data_version_service.dart' show DataVersionOverview;
import '../domain/models/embedding_config.dart' show EmbeddingConfig;
import '../domain/models/material.dart' show Material;
import '../domain/models/result.dart' show Result;
import '../domain/models/server_models.dart' show ServerBackup;
import '../domain/models/study.dart' show LearningGoal;
import 'account_service.dart' show AccountSnapshot;
import 'account_summary.dart' show AccountSummary;
import 'embedding_settings.dart' show EmbeddingSummary;
import 'memory_service.dart' show MemoryPageView;
import 'search_index_service.dart' show IndexStats;

/// 二级界面首屏的预读结果类型：每个 [PrefetchKey] 一个名字。
///
/// 生产方 `AppPrefetchPolicy` 与消费方页面引用同一份声明，字段增删由编译器
/// 拦下，不再各自手抄一份记录字面量（A20）。结果本来就是单个具名类型的键，
/// 这里用别名把“哪个键对应哪个类型”写在类型名上，页面按别名读取即可。
typedef MemoryPagePrewarm = MemoryPageView;

/// 数据版本页的一屏：提交历史、撤销判断、存储占用与恢复点。
typedef DataVersionPrewarm = DataVersionOverview;

/// 设置页本机读取的一组结果：模型配置、账号、可选模型与索引概况。
typedef SettingsPagePrewarm = ({
  Result<LlmConfig?> config,
  AccountSnapshot account,
  List<String> models,
  EmbeddingSummary embedding,
  bool reportCrashes,
  bool reportUsage,
});

/// 云端备份列表；未登录时这一项不读。
typedef CloudBackupsPrewarm = List<ServerBackup>;

/// 账号与云同步页的首屏：账号、同步状态与今日额度。
typedef AccountPagePrewarm = AccountSummary;

/// 记录查找的范围选项：目标与材料。
typedef RecordsSearchOptionsPrewarm = ({
  List<LearningGoal> goals,
  List<Material> materials,
});

/// 安排查找的目标选项。
typedef PlanSearchGoalsPrewarm = List<LearningGoal>;

/// 语义索引设置页的一组结果：配置、材料、登录状态与索引状态。
typedef EmbeddingSettingsPrewarm = ({
  EmbeddingConfig? config,
  List<Material> materials,
  bool signedIn,
  IndexStats? stats,
});

/// 人格与插件页读的 `app_meta`：运行时已经加载完成时为真。
typedef PluginSettingsPrewarm = bool;
