import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3_vec/sqlite3_vec.dart';

import '../../domain/rules/embedding.dart';

/// 语义索引里的一条向量。
class StoredVector {
  const StoredVector({
    required this.sourceKey,
    required this.chunk,
    required this.content,
    required this.sourceVersion,
    required this.distance,
  });

  final String sourceKey;
  final int chunk;
  final String content;
  final String sourceVersion;
  final double distance;
}

/// 索引条目的当前状态：用于判断来源是否需要重新嵌入。
class IndexedSource {
  const IndexedSource({required this.sourceVersion, required this.chunks});

  final String sourceVersion;
  final int chunks;
}

/// 独立的 sqlite3_vec 索引库。
///
/// 业务库不保存向量，这里只放能从当前记录重建的数据。每条向量关联来源标识、
/// 片段位置、来源版本与嵌入模型；模型、维度或文本处理版本改变时，整份索引
/// 重建，旧向量不与新向量混用。
class VectorIndex {
  VectorIndex._(this._db, this.spec);

  final Database _db;
  final EmbeddingModelSpec spec;

  static const String _metaTable = '''
CREATE TABLE IF NOT EXISTS vector_index_meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
)''';

  static const String _entryTable = '''
CREATE TABLE IF NOT EXISTS vector_entry (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  source_key     TEXT NOT NULL,
  locator_json   TEXT NOT NULL,
  source_version TEXT NOT NULL,
  chunk          INTEGER NOT NULL,
  content        TEXT NOT NULL,
  model_id       TEXT NOT NULL,
  text_version   TEXT NOT NULL,
  created_at     TEXT NOT NULL,
  UNIQUE (source_key, chunk)
)''';

  String get _vecTable => 'vec_rows_${spec.dim}';

  /// 打开索引库；模型、维度或文本处理版本与库里的不同时清空并重建结构。
  static VectorIndex open({
    String path = '',
    required EmbeddingModelSpec spec,
    bool inMemory = false,
  }) {
    loadSqliteVec();
    final db = inMemory ? sqlite3.openInMemory() : sqlite3.open(path);
    final index = VectorIndex._(db, spec);
    index._prepare();
    return index;
  }

  void _prepare() {
    _db.execute('PRAGMA journal_mode=WAL');
    _db.execute('PRAGMA foreign_keys=ON');
    _db.execute(_metaTable);
    _db.execute(_entryTable);
    final stored = meta('model_key');
    if (stored != spec.indexKey) {
      _dropVectorTables();
      _db.execute('DELETE FROM vector_entry');
      setMeta('model_key', spec.indexKey);
      setMeta('dim', '${spec.dim}');
      setMeta('text_version', spec.textVersion);
    }
    if (meta('epoch') == null) setMeta('epoch', '0');
    _db.execute(
      'CREATE VIRTUAL TABLE IF NOT EXISTS $_vecTable USING vec0('
      'embedding float[${spec.dim}] distance_metric=cosine)',
    );
  }

  void _dropVectorTables() {
    final rows = _db.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name LIKE 'vec_rows_%'",
    );
    for (final row in rows) {
      final name = row['name'] as String;
      _db.execute('DROP TABLE IF EXISTS $name');
    }
  }

  String? meta(String key) {
    final rows = _db.select(
      'SELECT value FROM vector_index_meta WHERE key = ?',
      [key],
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void setMeta(String key, String value) {
    _db.execute(
      'INSERT INTO vector_index_meta(key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }

  int get entryCount {
    final rows = _db.select('SELECT COUNT(*) AS n FROM vector_entry');
    return rows.first['n'] as int;
  }

  /// 来源条数：只取一个数，不把每个来源的版本与片段数读进内存。
  int get sourceCount {
    final rows = _db.select(
      'SELECT COUNT(DISTINCT source_key) AS n FROM vector_entry',
    );
    return rows.first['n'] as int;
  }

  /// 当前索引里每个来源的版本与片段数，用于跳过没有变化的来源。
  Map<String, IndexedSource> indexedSources() {
    final rows = _db.select(
      'SELECT source_key, source_version, COUNT(*) AS n FROM vector_entry '
      'GROUP BY source_key, source_version',
    );
    final result = <String, IndexedSource>{};
    for (final row in rows) {
      result[row['source_key'] as String] = IndexedSource(
        sourceVersion: row['source_version'] as String,
        chunks: row['n'] as int,
      );
    }
    return result;
  }

  /// 一批写入；整批成功或整批回滚，中断后重跑会接着补齐。
  void replaceSource({
    required SemanticLocator locator,
    required String sourceVersion,
    required List<String> chunks,
    required List<List<double>> vectors,
    required String createdAt,
  }) {
    if (chunks.length != vectors.length) {
      throw ArgumentError('片段数与向量数不一致');
    }
    _db.execute('BEGIN IMMEDIATE');
    try {
      removeSource(locator.sourceKey);
      for (var index = 0; index < chunks.length; index++) {
        final id = _insertEntry(
          locator: locator,
          sourceVersion: sourceVersion,
          chunk: index,
          content: chunks[index],
          createdAt: createdAt,
        );
        _db.execute('INSERT INTO $_vecTable(rowid, embedding) VALUES (?, ?)', [
          id,
          encodeVector(normalizeVector(vectors[index])),
        ]);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  int _insertEntry({
    required SemanticLocator locator,
    required String sourceVersion,
    required int chunk,
    required String content,
    required String createdAt,
  }) {
    _db.execute(
      'INSERT INTO vector_entry(source_key, locator_json, source_version, '
      'chunk, content, model_id, text_version, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [
        locator.sourceKey,
        jsonOf(locator),
        sourceVersion,
        chunk,
        content,
        spec.id,
        spec.textVersion,
        createdAt,
      ],
    );
    return _db.lastInsertRowId;
  }

  void removeSource(String sourceKey) {
    final rows = _db.select(
      'SELECT id FROM vector_entry WHERE source_key = ?',
      [sourceKey],
    );
    for (final row in rows) {
      _db.execute('DELETE FROM $_vecTable WHERE rowid = ?', [row['id'] as int]);
    }
    _db.execute('DELETE FROM vector_entry WHERE source_key = ?', [sourceKey]);
  }

  /// 删除已经不在业务库里的来源，返回删除的条数。
  int pruneSources(Set<String> keep) {
    final rows = _db.select('SELECT DISTINCT source_key FROM vector_entry');
    var removed = 0;
    for (final row in rows) {
      final key = row['source_key'] as String;
      if (keep.contains(key)) continue;
      removeSource(key);
      removed++;
    }
    return removed;
  }

  /// 按查询向量取最近的 k 条；范围与有效性由调用方重新核对业务记录。
  List<StoredVector> search(List<double> query, {int k = 20}) {
    final candidates = _db.select(
      'SELECT rowid, distance FROM $_vecTable '
      'WHERE embedding MATCH ? AND k = $k ORDER BY distance',
      [encodeVector(normalizeVector(query))],
    );
    final result = <StoredVector>[];
    for (final candidate in candidates) {
      final rowid = candidate['rowid'] as int;
      final rows = _db.select(
        'SELECT source_key, chunk, content, source_version '
        'FROM vector_entry WHERE id = ?',
        [rowid],
      );
      if (rows.isEmpty) continue;
      final row = rows.first;
      result.add(
        StoredVector(
          sourceKey: row['source_key'] as String,
          chunk: row['chunk'] as int,
          content: row['content'] as String,
          sourceVersion: row['source_version'] as String,
          distance: (candidate['distance'] as num).toDouble(),
        ),
      );
    }
    return result;
  }

  String? locatorJson(String sourceKey) {
    final rows = _db.select(
      'SELECT locator_json FROM vector_entry WHERE source_key = ? LIMIT 1',
      [sourceKey],
    );
    return rows.isEmpty ? null : rows.first['locator_json'] as String;
  }

  void clear() {
    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute('DELETE FROM $_vecTable');
      _db.execute('DELETE FROM vector_entry');
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void close() => _db.close();

  static String jsonOf(SemanticLocator locator) => jsonEncode(locator.toJson());
}
