import 'dart:convert';

export '../../domain/models/backup_error.dart';

/// 数据包里的 `manifest.json`；结构与格式规则见 01 第 7 章。
///
/// 导出与恢复都只处理当前 schema，其他版本的包在恢复入口拒绝。
class BackupManifest {
  const BackupManifest({
    required this.schemaVersion,
    required this.appVersion,
    required this.exportedAt,
    required this.imageCount,
    required this.images,
  });

  final int schemaVersion;
  final String appVersion;
  final String exportedAt;

  final int imageCount;

  /// 相对 `filesDir` 的图片路径 → sha256。
  final Map<String, String> images;

  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'app_version': appVersion,
    'exported_at': exportedAt,
    'image_count': imageCount,
    'images': images,
  };

  factory BackupManifest.fromJson(Map<String, Object?> json) {
    final schemaVersion = json['schema_version'];
    if (schemaVersion is! int) {
      throw FormatException('manifest 缺少 schema_version');
    }
    final appVersion = json['app_version'];
    if (appVersion is! String) {
      throw FormatException('manifest 缺少 app_version');
    }
    final exportedAt = json['exported_at'];
    if (exportedAt is! String) {
      throw FormatException('manifest 缺少 exported_at');
    }

    final imageCount = json['image_count'];
    if (imageCount is! int) {
      throw FormatException('manifest 缺少 image_count');
    }
    final rawImages = json['images'];
    if (rawImages is! Map) {
      throw FormatException('manifest 缺少 images');
    }
    final images = <String, String>{};
    rawImages.forEach((key, value) {
      if (key is! String || value is! String) {
        throw FormatException('manifest.images 格式不对');
      }
      images[key] = value;
    });

    if (imageCount != images.length) {
      throw FormatException('image_count 与 images 数量不一致');
    }

    return BackupManifest(
      schemaVersion: schemaVersion,
      appVersion: appVersion,
      exportedAt: exportedAt,
      imageCount: imageCount,
      images: images,
    );
  }

  static BackupManifest parse(List<int> bytes) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('manifest.json 不是对象');
    }
    return BackupManifest.fromJson(decoded);
  }
}
