import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'zhixin_icon_button.dart';
import 'zhixin_toast.dart';

/// 语音输入（02 第 5 章）：只在每日记录与备注里出现，转成文字后仍可改。
///
/// 设备没有识别服务、没有麦克风权限或识别失败时只提示一句，不阻塞键盘输入。
/// 识别结果写在输入框的光标处，已经手写的文字保留，不会整段替换输入框。
class VoiceInputButton extends StatefulWidget {
  const VoiceInputButton({
    super.key,
    required this.controller,
    required this.style,
    this.iconSize,
  });

  final TextEditingController controller;

  /// 输入框后缀按钮的样式，取 FTextField 的 clearButtonStyle，尺寸与颜色才与输入框一致。
  final forui.FButtonStyle style;
  final double? iconSize;

  @override
  State<VoiceInputButton> createState() => _VoiceInputButtonState();
}

class _VoiceInputButtonState extends State<VoiceInputButton> {
  final SpeechToText _speech = SpeechToText();

  /// 每次开始识别时新建，按这一次的光标位置合入文字。
  late final VoiceInsertion _insertion = VoiceInsertion(widget.controller);

  bool _listening = false;
  bool _disposed = false;

  @override
  void dispose() {
    // 先停识别再标记，迟到的识别结果不再往已经释放的输入框里写。
    _disposed = true;
    _speech.cancel();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    showToast(context, message);
  }

  /// 识别结果一边生成一边写进输入框；中间结果覆盖上一次写的那一段。
  void _onResult(SpeechRecognitionResult result) {
    if (_disposed) return;
    _insertion.write(result.recognizedWords);
    // 一句话结束后另起一段，下一句接在后面，而不是替换这一句。
    if (result.finalResult) _insertion.commit();
  }

  Future<void> _toggle() async {
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }

    try {
      final available = await _speech.initialize(
        onError: (_) {
          if (!mounted) return;
          setState(() => _listening = false);
          _snack('语音识别没有完成，可以检查麦克风权限后再试。');
        },
        onStatus: (status) {
          if (!mounted) return;
          if (status == 'done' || status == 'notListening') {
            setState(() => _listening = false);
          }
        },
      );
      if (!available) {
        _snack('设备未提供语音识别服务');
        return;
      }
      if (!mounted) return;
      _insertion.begin();
      setState(() => _listening = true);
      await _speech.listen(
        onResult: _onResult,
        listenOptions: SpeechListenOptions(
          localeId: 'zh_CN',
          listenFor: const Duration(minutes: 5),
          pauseFor: const Duration(seconds: 4),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _listening = false);
      _snack('语音输入没有打开，可以改用键盘输入。');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ZhixinIconButton(
      tooltip: _listening ? '停止语音输入' : '语音输入',
      onPressed: _toggle,
      icon: FLucideIcons.mic,
      iconSize: widget.iconSize,
      iconColor: _listening ? context.zhixin.colors.error : null,
      style: widget.style,
    );
  }
}

/// 一次识别会话往输入框写字的规则。
///
/// 识别开始时记下光标，识别结果从那里插入；同一句的中间结果替换上一次写的
/// 那一段，不会重复追加；一句话结束之后另起一段，下一句接在后面。识别期间
/// 用户改过这一段或者挪了光标时，改为从当前光标处接着写，已经写下的内容
/// 与先写好的文字都不覆盖。
class VoiceInsertion {
  VoiceInsertion(this.controller);

  final TextEditingController controller;

  /// 本次识别开始写字的位置。
  int? _start;

  /// 上一次写进去的识别文字。
  String _written = '';

  /// 开始识别时选中的长度，第一次写入时替换掉，和打字的行为一致。
  int _selected = 0;

  static int _atMost(int value, int limit) =>
      value > limit ? limit : (value < 0 ? 0 : value);

  /// 开始识别时调用，记下光标与选区。
  void begin() {
    final selection = controller.selection;
    final length = controller.text.length;
    _start = selection.isValid ? _atMost(selection.start, length) : length;
    _selected = selection.isValid ? selection.end - selection.start : 0;
    _written = '';
  }

  /// 合入一次识别结果；[words] 是识别服务给出的当前这句。
  void write(String words) {
    final text = words.trim();
    final start = _start;
    if (start == null || text.isEmpty) return;
    final current = controller.text;
    var from = _atMost(start, current.length);
    var to = _atMost(from + _written.length, current.length);
    // 识别期间用户改过这一段或者挪了光标：按当前光标重新落笔，不删他写的字。
    if (_written.isNotEmpty && current.substring(from, to) != _written) {
      final selection = controller.selection;
      from = selection.isValid
          ? _atMost(selection.start, current.length)
          : current.length;
      to = from;
      _written = '';
    }
    if (_written.isEmpty && _selected > 0) {
      to = _atMost(from + _selected, current.length);
      _selected = 0;
    }
    final next = current.replaceRange(from, to, text);
    controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: from + text.length),
    );
    _start = from;
    _written = text;
  }

  /// 一句识别结束之后另起一段，下一句接在后面而不是替换这一句。
  void commit() {
    final selection = controller.selection;
    final length = controller.text.length;
    _start = selection.isValid ? _atMost(selection.start, length) : length;
    _written = '';
    _selected = 0;
  }
}
