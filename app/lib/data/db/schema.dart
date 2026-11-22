/// 当前库的结构信息，由 drift 生成代码里的表类派生。
///
/// 建表语句与索引写在 [AppDatabase] 的表类上，由 drift 负责执行；恢复预检、
/// 版本引擎与文档比对只读这里，不再手写第二份表清单或 DDL 文本。drift 的
/// `allTables` 与 `allSchemaEntities` 是实例成员，[schemaProbe] 复用 [schemaMetadata]
/// 这一个不打开连接的实例来读取它们，避免为了拿结构信息多开一个数据库。
library;

import 'package:drift/drift.dart' show Index, Table, TableInfo;

import 'drift/app_database.dart';

/// 只读取生成代码里表、列与索引定义的实例；不打开数据库，任何查询都会抛出。
///
/// 按需构造会让 drift 每次都按 [AppDatabase] 记一个实例，drift 自带的“开了多个
/// 库”告警会因此指向它，因此固定为 [schemaMetadata] 这一个。
final AppDatabase schemaProbe = schemaMetadata;

/// 生成代码登记的全部表，顺序与表类登记顺序一致：外键被引用的表在前。
List<TableInfo<Table, Object?>> schemaTables() =>
    schemaProbe.allTables.toList(growable: false);

/// 库里应当存在的表，恢复校验按这份清单核对。
Set<String> schemaTableNames() => {
  for (final table in schemaTables()) table.entityName,
};

/// 每张表必须有的字段；恢复时缺一列就拒绝，不让半套结构进正式库。
final Map<String, List<String>> requiredColumns = {
  for (final table in schemaTables())
    table.entityName: [for (final column in table.$columns) column.name],
};

/// 表类上声明的索引名；建表时由 drift 创建，恢复预检按它核对包里的索引。
Set<String> schemaIndexNames() => {
  for (final entity in schemaProbe.allSchemaEntities.whereType<Index>())
    entity.entityName,
};
