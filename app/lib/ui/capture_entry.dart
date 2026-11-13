import 'dart:io';

import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app_scope.dart';
import 'camera_capture_page.dart';
import 'question_crop_page.dart';
import 'zhixin_icon_button.dart';
import 'zhixin_sheet.dart';

/// 首页提问、讨论页与“贴一道题”共用的图片录入：取图、框选、存图与缩略图。
///
/// 三个入口原来各写一遍，尺寸与压缩参数容易走偏；统一放在这里之后，
/// 换入口也不会换掉保存位置与文件命名。
Future<XFile?> pickCaptureImage(ImageSource source) {
  return ImagePicker().pickImage(
    source: source,
    maxWidth: 2048,
    maxHeight: 2048,
    imageQuality: 90,
  );
}

/// 取图之后先框一道题，再交给保存流程；取消框选等于放弃这张图。
///
/// 取图尺寸放到 2048 是因为框选之后只留一小块，留出余量才不至于把小题目
/// 裁成模糊的图；真正写进记录的图片仍由 [cropToJpeg] 压到长边 1600 以内。
/// 相机拍糊了可以在框选页直接重拍，回到预览再按一次快门，换下来的旧图删掉。
Future<XFile?> pickQuestionImage(
  BuildContext context,
  ImageSource source,
) async {
  // 相机可能走应用内预览，也可能交给系统相机；设置只影响相机，相册不变。
  final systemCamera =
      source == ImageSource.camera && await _usesSystemCamera(context);
  if (!context.mounted) return null;
  final first = await captureQuestionShot(
    context,
    source,
    useSystemCamera: systemCamera,
  );
  if (first == null) return null;
  var picked = first;
  try {
    while (true) {
      final tempDir = await getTemporaryDirectory();
      if (!context.mounted) return null;
      final result = await showQuestionCropPage(
        context,
        sourcePath: picked.path,
        outputDir: tempDir.path,
        allowRetake: source == ImageSource.camera,
      );
      if (result == null) return null;
      if (!result.retake) return XFile(result.path!);
      if (!context.mounted) return null;
      final next = await captureQuestionShot(
        context,
        source,
        useSystemCamera: systemCamera,
      );
      // 重拍时退出相机，回到原来那张继续框选，不再多问一次。
      if (next == null) continue;
      await deleteTemporaryCapture(picked.path);
      picked = next;
    }
  } finally {
    // 原图是取图组件写进缓存的全尺寸副本，框选之后不再需要。
    await deleteTemporaryCapture(picked.path);
  }
}

/// 设置里选了系统相机就交给取图组件，否则用应用内预览。
Future<bool> _usesSystemCamera(BuildContext context) async {
  try {
    return await AppScope.of(context).settings.edit.useSystemCamera();
  } catch (_) {
    // 设置读不出来就按应用内相机走，取图本身不受影响。
    return false;
  }
}

/// 相机走应用内预览，快门之后直接进框选；相册仍用系统选择器。
///
/// 应用内相机给的是传感器最高分辨率的原图，先压到取图上限再交给框选页，
/// 否则一张 1200 万像素的照片光是预览就要几十 MB 内存。系统相机由设置决定，
/// 它已经把图压到 2048 以内，不用再压一次。
Future<XFile?> captureQuestionShot(
  BuildContext context,
  ImageSource source, {
  bool useSystemCamera = false,
}) async {
  if (source != ImageSource.camera) return pickCaptureImage(source);
  if (useSystemCamera) return pickCaptureImage(ImageSource.camera);
  final shot = await showCameraCapturePage(context);
  if (shot == null) return null;
  try {
    final shrunk = await shrinkCaptureImage(await shot.readAsBytes());
    final tempDir = await getTemporaryDirectory();
    final target = File(
      p.join(tempDir.path, 'shot-${DateTime.now().millisecondsSinceEpoch}.jpg'),
    );
    await target.writeAsBytes(shrunk, flush: true);
    await deleteTemporaryCapture(shot.path);
    return XFile(target.path);
  } catch (_) {
    // 压不小就直接用原图，框选与保存照常进行。
    return shot;
  }
}

/// 删除缓存目录里的取图副本；不在缓存目录的路径一律不动。
///
/// 取图组件把相机与相册的图片复制进缓存，框选页也把裁剪结果写在这里；
/// 存进记录之后这些副本不再有用，留着会让缓存目录随拍照次数增长。
Future<void> deleteTemporaryCapture(String path) async {
  try {
    final temp = p.canonicalize((await getTemporaryDirectory()).path);
    final target = p.canonicalize(path);
    if (!p.isWithin(temp, target)) return;
    final file = File(target);
    if (await file.exists()) await file.delete();
  } catch (_) {
    // 删不掉只多占一点缓存，不影响已经保存的记录。
  }
}

/// 取图失败时给用户看的说明。
///
/// 平台异常里的错误码是英文，直接显示等于没说；相机与相册的失败大多来自
/// 权限与硬件，用户能做的只有去系统设置放行，或者改从相册选一张。其余错误
/// 不显示平台原文，只说可以换一张再试。
String captureErrorText(Object error) {
  if (error is! PlatformException) {
    return '这张图片没有读取成功，可以换一张再试。';
  }
  return switch (error.code) {
    'camera_access_denied' => '没有相机权限，请在系统设置里允许知新使用相机。',
    'photo_access_denied' => '没有相册权限，请在系统设置里允许知新读取图片。',
    'no_available_camera' => '这台设备没有可用的相机，可以从相册选择图片。',
    'already_active' => '相机或相册还没有关闭，请先完成当前这一步。',
    'invalid_image' => '这张图片读不出来，换一张再试。',
    _ => '这张图片没有读取成功，可以换一张再试。',
  };
}

/// 把选好的图片存进应用图片目录，返回可以写进记录的文件名。
///
/// 单张存不进去时跳过，其余图片与文字仍然继续；调用方按返回的数量决定提示。
Future<List<String>> persistCaptureImages(
  List<XFile> photos,
  String imagesDir, {
  String prefix = 'q',
}) async {
  if (photos.isEmpty) return const [];
  final dir = Directory(imagesDir);
  await dir.create(recursive: true);
  final names = <String>[];
  for (var index = 0; index < photos.length; index++) {
    final name = '$prefix-${DateTime.now().millisecondsSinceEpoch}-$index.jpg';
    final target = '${dir.path}/$name';
    try {
      await photos[index].saveTo(target);
      names.add(name);
    } catch (_) {
      // 这张存不进去就不带上，剩下的照常保存。
      try {
        final partial = File(target);
        if (await partial.exists()) await partial.delete();
      } catch (_) {
        // 启动时还会回收没有记录引用的图片。
      }
    }
  }
  return names;
}

/// 记录写成功之后，删掉还在缓存里的取图副本。
///
/// 保存失败时调用方要留着这些文件重试，所以不放进 [persistCaptureImages]。
Future<void> deleteTemporaryCaptures(Iterable<XFile> photos) async {
  for (final photo in photos) {
    await deleteTemporaryCapture(photo.path);
  }
}

/// 让用户选择拍摄照片还是从相册取；取消时返回 null。
///
/// 首页、讨论页与“贴一道题”共用同一份选择，三处的按钮文字与顺序不再各写一套。
Future<ImageSource?> chooseCaptureSource(BuildContext context) {
  return showZhixinSheet<ImageSource>(
    context: context,
    builder: (context) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        forui.FTile(
          prefix: const Icon(FLucideIcons.camera),
          title: const Text('拍摄照片'),
          onPress: () => Navigator.of(context).pop(ImageSource.camera),
        ),
        forui.FTile(
          prefix: const Icon(FLucideIcons.images),
          title: const Text('从相册选择'),
          onPress: () => Navigator.of(context).pop(ImageSource.gallery),
        ),
      ],
    ),
  );
}

/// 录入区里的图片缩略图；点叉号移除一张。
class CapturePhotoStrip extends StatelessWidget {
  const CapturePhotoStrip({
    super.key,
    required this.photos,
    required this.onRemove,
    this.size = 56,
  });

  final List<XFile> photos;
  final ValueChanged<int> onRemove;
  final double size;

  @override
  Widget build(BuildContext context) {
    // 缩略图只有几十像素，按屏幕像素解码一张 1600 像素的图会白白占几 MB 内存。
    final cacheWidth = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        for (var index = 0; index < photos.length; index++)
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(photos[index].path),
                  width: size,
                  height: size,
                  cacheWidth: cacheWidth,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      SizedBox(width: size, height: size),
                ),
              ),
              Positioned(
                top: -6,
                right: -6,
                child: ZhixinIconButton(
                  size: forui.FButtonSizeVariant.sm,
                  tooltip: '移除图片',
                  onPressed: () => onRemove(index),
                  icon: FLucideIcons.circleX,
                ),
              ),
            ],
          ),
      ],
    );
  }
}
