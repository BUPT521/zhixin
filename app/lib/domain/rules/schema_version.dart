/// 客户端数据库的 schema 版本。
///
/// 与 `data/db/app_database.dart` 打开的库文件对应：版本不一致时清空所有表并按
/// 当前结构重建（ADR-0002）。同步与服务端之间也按这个版本判断能不能互通。
const int zhixinSchemaVersion = 33;
