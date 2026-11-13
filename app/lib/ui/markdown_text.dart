import 'dart:math' as math;

import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import 'package:url_launcher/url_launcher.dart';

import 'zhixin_toast.dart';

/// 回答正文的 Markdown 渲染，流式与完成态共用这一处配置。
///
/// 完成态才套选择区，生成过程中不套，避免每个分片重建选择区域；模型输出
/// 里的 HTML 不解析，防止标签在回答里触发网络请求；`$...$` 按公式渲染。
/// Markdown 图片也不自动加载，只显示文字提示，用户点击后才交给系统浏览器，
/// 因为默认实现会立即请求图片地址，打开历史讨论时就可能访问模型服务之外的地址。
class MarkdownText extends StatelessWidget {
  const MarkdownText(this.text, {super.key, this.streaming = false});

  final String text;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final markdown = GptMarkdown(
      text,
      style: context.zhixin.text.bodyMedium,
      isStreaming: streaming,
      html: false,
      useDollarSignsForLatex: true,
      imageBuilder: _blockedImage,
      onLinkTap: (url, _) => _openLink(context, url),
    );
    if (!streaming) return SelectionArea(child: markdown);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        markdown,
        const Padding(padding: EdgeInsets.only(top: 8), child: StreamingHint()),
      ],
    );
  }

  Widget _blockedImage(
    BuildContext context,
    String url,
    double? width,
    double? height,
  ) {
    final uri = Uri.tryParse(url);
    final openable =
        uri != null && (uri.scheme == 'https' || uri.scheme == 'http');
    final theme = context.zhixin;
    return Semantics(
      label: openable ? '外链图片未加载，点击打开' : '图片未加载',
      button: openable,
      child: GestureDetector(
        onTap: openable ? () => _openLink(context, url) : null,
        child: Text(
          openable ? '[外链图片：点击打开]' : '[图片未加载]',
          style: theme.text.bodySmall.copyWith(
            color: openable
                ? theme.colors.primary
                : theme.colors.onSurfaceVariant,
            decoration: openable ? TextDecoration.underline : null,
          ),
        ),
      ),
    );
  }

  Future<void> _openLink(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    final supported =
        uri != null &&
        (uri.scheme == 'https' ||
            uri.scheme == 'http' ||
            uri.scheme == 'mailto');
    if (!supported) {
      _notice(context, '这个链接的格式不支持打开');
      return;
    }
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && context.mounted) {
        _notice(context, '没有可以打开这个链接的应用');
      }
    } catch (_) {
      if (context.mounted) _notice(context, '没有可以打开这个链接的应用');
    }
  }

  void _notice(BuildContext context, String message) {
    if (!context.mounted) return;
    showToast(context, message);
  }
}

/// 生成中的三点提示：放在正文末尾，长回答在中段也能看出还在生成。
class StreamingHint extends StatefulWidget {
  const StreamingHint({super.key});

  @override
  State<StreamingHint> createState() => _StreamingHintState();
}

class _StreamingHintState extends State<StreamingHint>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = context.zhixin.colors.onSurfaceVariant;
    return Semantics(
      label: '正在生成回答',
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var index = 0; index < 3; index++) ...[
              if (index > 0) const SizedBox(width: 3),
              Opacity(
                opacity: 0.25 + 0.75 * _wave(index),
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  double _wave(int index) {
    final phase = (_controller.value + index / 3) % 1;
    return (math.sin(phase * 2 * math.pi) + 1) / 2;
  }
}
