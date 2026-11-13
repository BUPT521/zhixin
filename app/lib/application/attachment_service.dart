import 'dart:io';

import '../ai/llm_client.dart';
import '../domain/rules/attachments.dart';

enum AttachmentOmissionReason {
  uploadDisabled,
  tooMany,
  missing,
  tooLarge,
  unreadable,
}

class AttachmentOmission {
  const AttachmentOmission(this.reason);

  final AttachmentOmissionReason reason;
}

class PreparedAttachments {
  const PreparedAttachments({required this.images, required this.omitted});

  final List<LlmImage> images;
  final List<AttachmentOmission> omitted;

  String? get notice {
    if (omitted.isEmpty) return null;
    final counts = <AttachmentOmissionReason, int>{};
    for (final item in omitted) {
      counts.update(item.reason, (count) => count + 1, ifAbsent: () => 1);
    }
    final details = <String>[];
    if (counts.containsKey(AttachmentOmissionReason.uploadDisabled)) {
      details.add('图片上传已关闭');
    }
    if (counts.containsKey(AttachmentOmissionReason.tooMany)) {
      details.add('超过两张的图片未发送');
    }
    if (counts.containsKey(AttachmentOmissionReason.missing)) {
      details.add('部分图片文件已找不到');
    }
    if (counts.containsKey(AttachmentOmissionReason.tooLarge)) {
      details.add('超过 4 MB 的图片未发送');
    }
    if (counts.containsKey(AttachmentOmissionReason.unreadable)) {
      details.add('部分图片无法读取');
    }
    return '${details.join('；')}。';
  }
}

/// 统一准备模型图片，并保留每张未发送图片的原因供界面说明。
class AttachmentService {
  AttachmentService({required this.filesDir});

  final String Function() filesDir;

  Future<PreparedAttachments> prepare(
    List<String> storedPaths, {
    required bool enabled,
  }) async {
    final images = <LlmImage>[];
    final omitted = <AttachmentOmission>[];
    final seenPaths = <String>{};
    final seenImages = <String>{};
    for (final storedPath in storedPaths) {
      if (!seenPaths.add(storedPath.trim())) continue;
      if (!enabled) {
        omitted.add(
          const AttachmentOmission(AttachmentOmissionReason.uploadDisabled),
        );
        continue;
      }
      try {
        final file = File(resolveAttachment(filesDir(), storedPath));
        if (!await file.exists()) {
          omitted.add(
            const AttachmentOmission(AttachmentOmissionReason.missing),
          );
          continue;
        }
        const maxBytes = 4 * 1024 * 1024;
        if (await file.length() > maxBytes) {
          omitted.add(
            const AttachmentOmission(AttachmentOmissionReason.tooLarge),
          );
          continue;
        }
        final bytes = await file.readAsBytes();
        if (bytes.length > maxBytes) {
          omitted.add(
            const AttachmentOmission(AttachmentOmissionReason.tooLarge),
          );
          continue;
        }
        final image = LlmImage(bytes: bytes);
        if (!seenImages.add(image.id)) continue;
        if (images.length == 2) {
          omitted.add(
            const AttachmentOmission(AttachmentOmissionReason.tooMany),
          );
          continue;
        }
        images.add(image);
      } catch (_) {
        omitted.add(
          const AttachmentOmission(AttachmentOmissionReason.unreadable),
        );
      }
    }
    return PreparedAttachments(images: images, omitted: omitted);
  }
}
