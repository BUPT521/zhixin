import 'package:forui/forui.dart' as forui;
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:material_ui/material_ui.dart';

import 'zhixin_icon_button.dart';
import 'zhixin_toast.dart';

/// 应用内拍照：按下快门直接回到框选页，不再经过系统相机的确认界面。
///
/// 系统相机由相机应用自己决定界面，拍完之后那次确认去不掉；只有把相机换成
/// 应用内预览，才能做到与从相册选择一样，取到图就进入框选。框选页的重拍也
/// 回到这里，预览一直开着，不必重新拉起系统相机。
class CameraCapturePage extends StatefulWidget {
  const CameraCapturePage({super.key});

  @override
  State<CameraCapturePage> createState() => _CameraCapturePageState();
}

/// 打开应用内相机；取消或没有拍到时返回 null。
Future<XFile?> showCameraCapturePage(BuildContext context) {
  return Navigator.of(context).push<XFile>(
    MaterialPageRoute<XFile>(
      fullscreenDialog: true,
      builder: (_) => const CameraCapturePage(),
    ),
  );
}

/// 相机打不开时给用户看的说明。
///
/// 权限被拒是最常见的一种，其次是设备没有相机；其余错误只说明可以换一种
/// 取图方式，错误码留给诊断记录，不把设备内部说法直接摆到界面上。
String cameraErrorText(Object error) {
  if (error is! CameraException) {
    return '相机没有打开，可以改用系统相机或从相册选择图片。';
  }
  return switch (error.code) {
    'CameraAccessDenied' ||
    'CameraAccessDeniedWithoutPrompt' ||
    'cameraPermission' => '没有相机权限，请在系统设置里允许知新使用相机。',
    'CameraAccessRestricted' => '系统限制了相机使用，请检查设备策略后再试。',
    'cameraNotFound' => '这台设备没有可用的相机，可以从相册选择图片。',
    _ => '相机没有打开，可以改用系统相机或从相册选择图片。',
  };
}

class _CameraCapturePageState extends State<CameraCapturePage>
    with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  CameraDescription? _camera;
  bool _opening = false;
  bool _capturing = false;
  bool _torch = false;
  String? _error;

  /// 点按对焦的方框位置，短暂显示之后清除。
  Offset? _focusAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_open());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.inactive && !_opening) {
      // 退到后台先放掉相机；回到前台重新打开，预览不会停在最后一帧。
      _controller = null;
      unawaited(controller.dispose());
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_open());
    }
  }

  Future<void> _open() async {
    if (_opening || _controller != null) return;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw CameraException('cameraNotFound', '没有可用的相机');
      }
      // 默认后置：拍题目用后置更清楚，也不会把字拍成镜像；退到后台再回来时
      // 沿用上次选的那台，不把用户切过去的前置又换回来。
      final preferred = _camera;
      final camera =
          preferred != null &&
              cameras.any((item) => item.name == preferred.name)
          ? cameras.firstWhere((item) => item.name == preferred.name)
          : cameras.firstWhere(
              (item) => item.lensDirection == CameraLensDirection.back,
              orElse: () => cameras.first,
            );
      await _attach(cameras, camera);
      if (!mounted) return;
      setState(() => _opening = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _opening = false;
        _error = cameraErrorText(error);
      });
    }
  }

  /// 换成指定的那台相机；旧相机先放掉，避免两台同时占用摄像头。
  Future<void> _attach(
    List<CameraDescription> cameras,
    CameraDescription camera,
  ) async {
    final controller = CameraController(
      camera,
      ResolutionPreset.max,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    try {
      await controller.initialize();
    } catch (_) {
      // 打不开就把这次的控制器放掉，别让两台相机同时挂着。
      await controller.dispose();
      rethrow;
    }
    if (!mounted) {
      await controller.dispose();
      return;
    }
    _cameras = cameras;
    _camera = camera;
    _controller = controller;
  }

  /// 前置与后置互换；只有一台相机时按钮不出现，这里也不会有动作。
  Future<void> _switchCamera() async {
    final current = _camera;
    final controller = _controller;
    if (current == null || controller == null || _opening || _capturing) return;
    final next = _cameras.firstWhere(
      (camera) => camera.lensDirection != current.lensDirection,
      orElse: () => current,
    );
    if (identical(next, current)) return;

    setState(() {
      _opening = true;
      _torch = false;
    });
    _controller = null;
    await controller.dispose();
    try {
      await _attach(_cameras, next);
      if (!mounted) return;
      setState(() => _opening = false);
    } catch (error) {
      if (!mounted) return;
      showToast(context, cameraErrorText(error));
      // 换不过去就退回原来那台，不把页面停在黑屏上。
      try {
        await _attach(_cameras, current);
      } catch (_) {
        // 原相机也打不开时交给下面的错误提示。
      }
      if (!mounted) return;
      setState(() {
        _opening = false;
        _error = _controller == null ? cameraErrorText(error) : null;
      });
    }
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || _capturing || !controller.value.isInitialized) {
      return;
    }
    setState(() => _capturing = true);
    try {
      final shot = await controller.takePicture();
      if (!mounted) return;
      Navigator.of(context).pop(shot);
    } catch (error) {
      if (!mounted) return;
      setState(() => _capturing = false);
      showToast(context, cameraErrorText(error));
    }
  }

  Future<void> _toggleTorch() async {
    final controller = _controller;
    if (controller == null) return;
    final next = !_torch;
    try {
      await controller.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      if (mounted) setState(() => _torch = next);
    } catch (_) {
      // 有些设备没有补光灯，或者相机正在切换，这一次点了不生效。
      if (!mounted) return;
      showToast(context, '这台设备的闪光灯用不了');
    }
  }

  Future<void> _focus(Offset point, Size size) async {
    final controller = _controller;
    if (controller == null || size.isEmpty) return;
    setState(() => _focusAt = point);
    try {
      final target = Offset(
        (point.dx / size.width).clamp(0.0, 1.0),
        (point.dy / size.height).clamp(0.0, 1.0),
      );
      await controller.setFocusPoint(target);
      await controller.setExposurePoint(target);
    } catch (_) {
      // 对焦失败不影响按快门。
    }
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (mounted) setState(() => _focusAt = null);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return forui.FScaffold(
      scaffoldStyle: forui.FScaffoldStyleDelta.delta(
        backgroundColor: Colors.black,
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) => _focus(details.localPosition, size),
            child: _stage(),
          ),
          const IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black54, Colors.transparent, Colors.black54],
                  stops: [0, 0.5, 1],
                ),
              ),
            ),
          ),
          if (_focusAt != null)
            Positioned(
              left: _focusAt!.dx - 32,
              top: _focusAt!.dy - 32,
              child: IgnorePointer(
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white70, width: 1.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          SafeArea(
            child: Column(children: [_topBar(), const Spacer(), _bottomBar()]),
          ),
        ],
      ),
    );
  }

  Widget _stage() {
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                FLucideIcons.videoOff,
                color: Colors.white70,
                size: 40,
              ),
              const SizedBox(height: 12),
              Text(
                error,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 16),
              forui.FButton(
                mainAxisSize: MainAxisSize.min,
                onPress: () => Navigator.of(context).pop(),
                child: const Text('返回'),
              ),
            ],
          ),
        ),
      );
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: forui.FCircularProgress());
    }
    // 预览按比例铺满整屏：相机给的比例与屏幕比例通常不同，缩放之后才不留黑边。
    var scale =
        1 /
        (MediaQuery.sizeOf(context).aspectRatio * controller.value.aspectRatio);
    if (scale < 1) scale = 1 / scale;
    return Transform.scale(
      scale: scale,
      child: Center(child: CameraPreview(controller)),
    );
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          ZhixinIconButton(
            key: const ValueKey('camera-close'),
            tooltip: '关闭相机',
            onPressed: () => Navigator.of(context).pop(),
            icon: FLucideIcons.x,
            iconColor: Colors.white,
          ),
          const Spacer(),
          if (_cameras.length > 1)
            ZhixinIconButton(
              key: const ValueKey('camera-switch'),
              tooltip: '切换前后摄像头',
              onPressed: _controller == null ? null : _switchCamera,
              icon: FLucideIcons.switchCamera,
              iconColor: Colors.white,
            ),
          ZhixinIconButton(
            key: const ValueKey('camera-torch'),
            tooltip: _torch ? '关闭闪光灯' : '打开闪光灯',
            onPressed: _controller == null ? null : _toggleTorch,
            icon: _torch ? FLucideIcons.flashlight : FLucideIcons.flashlightOff,
            iconColor: _torch ? Colors.amber : Colors.white,
          ),
        ],
      ),
    );
  }

  Widget _bottomBar() {
    final ready = _controller?.value.isInitialized ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            label: '拍照',
            child: GestureDetector(
              key: const ValueKey('camera-shutter'),
              onTap: ready && !_capturing ? _capture : null,
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: ready ? Colors.white : Colors.white38,
                    width: 4,
                  ),
                ),
                child: Container(
                  margin: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: ready ? Colors.white : Colors.white24,
                  ),
                  child: _capturing
                      ? const Center(
                          child: forui.FCircularProgress(
                            style: .delta(
                              iconStyle: .delta(color: Colors.black54),
                            ),
                          ),
                        )
                      : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
