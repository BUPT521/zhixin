import 'dart:io';

import '../ai/llm_client.dart';
import '../domain/rules/attachments.dart';

/// 一张图片没有随这次请求发送的原因。
enum AttachmentOmissionReason {
  uploadDisabled,
  tooMany,
  missing,
  tooLarge,
  unreadable,
}

class PreparedAttachments {
  const PreparedAttachments({required this.images, required this.omitted});

  final List<LlmImage> images;

  /// 没有发送的图片原因；界面按原因写说明，不再从文案反推。
  final List<AttachmentOmissionReason> omitted;
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
    final omitted = <AttachmentOmissionReason>[];
    final seenPaths = <String>{};
    final seenImages = <String>{};
    for (final storedPath in storedPaths) {
      if (!seenPaths.add(storedPath.trim())) continue;
      if (!enabled) {
        omitted.add(AttachmentOmissionReason.uploadDisabled);
        continue;
      }
      try {
        final file = File(resolveAttachment(filesDir(), storedPath));
        if (!await file.exists()) {
          omitted.add(AttachmentOmissionReason.missing);
          continue;
        }
        const maxBytes = 4 * 1024 * 1024;
        if (await file.length() > maxBytes) {
          omitted.add(AttachmentOmissionReason.tooLarge);
          continue;
        }
        final bytes = await file.readAsBytes();
        if (bytes.length > maxBytes) {
          omitted.add(AttachmentOmissionReason.tooLarge);
          continue;
        }
        final image = LlmImage(bytes: bytes);
        if (!seenImages.add(image.id)) continue;
        if (images.length == 2) {
          omitted.add(AttachmentOmissionReason.tooMany);
          continue;
        }
        images.add(image);
      } catch (_) {
        omitted.add(AttachmentOmissionReason.unreadable);
      }
    }
    return PreparedAttachments(images: images, omitted: omitted);
  }
}
