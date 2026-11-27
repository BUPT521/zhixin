import 'package:flutter/widgets.dart';
import 'package:image_picker/image_picker.dart';

import '../app_scope.dart';
import 'capture_entry.dart';

/// 讨论页输入区的图片：待发送的几张、正在取图的状态与存图。
///
/// 页面原来把这几个字段与“最多两张”、取图失败说明、存图之后的部分失败提示
/// 都写在 State 里；现在收进一个普通控制器，取图上限与失败说明走
/// `capture_entry.dart` 的同一入口，页面只把列表画成缩略图。
class DiscussionAttachments {
  DiscussionAttachments({required this.onChanged});

  /// 列表或取图状态变了让页面重建。
  final VoidCallback onChanged;

  List<XFile> picked = const [];
  bool picking = false;

  /// 进页面时首页已经取好的图片：只摆进输入区，等用户确认后再发。
  void adopt(List<XFile> images) => picked = [...images];

  void removeAt(int index) {
    picked = [
      for (var i = 0; i < picked.length; i++)
        if (i != index) picked[i],
    ];
    onChanged();
  }

  void clear() => picked = const [];

  /// 选来源并取一张图；上限、框选与失败说明都由取图入口给出。
  Future<void> choose(BuildContext context) async {
    final source = await chooseCaptureSource(context);
    if (source == null || !context.mounted) return;
    await pick(context, source);
  }

  Future<void> pick(BuildContext context, ImageSource source) async {
    if (picking) return;
    picking = true;
    onChanged();
    try {
      final image = await pickCaptureWithinLimit(
        context,
        source,
        current: picked.length,
      );
      if (image != null && context.mounted) picked = [...picked, image];
    } finally {
      picking = false;
      if (context.mounted) onChanged();
    }
  }

  /// 把选好的图片存进应用图片目录，返回可以写进记录的文件名。
  ///
  /// 单张存不进去时跳过，本次改为只发送存下来的那几张；调用方按返回的数量
  /// 决定是否提示。
  Future<List<String>> persist(AppScopeState scope) async {
    if (picked.isEmpty) return const [];
    final paths = await persistCaptureImages(
      picked,
      scope.paths.imagesDir,
      prefix: 'm',
    );
    return paths;
  }
}
