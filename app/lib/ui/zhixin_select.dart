import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

/// 选项以业务标识区分，允许多个目标或事项使用同一个名称。
class ZhixinSelect<T extends Object> extends StatelessWidget {
  const ZhixinSelect({
    required this.value,
    required this.options,
    required this.onChange,
    this.label,
    this.description,
    super.key,
  });

  final T value;
  final Map<T, String> options;
  final ValueChanged<T?>? onChange;
  final String? label;
  final String? description;

  @override
  Widget build(BuildContext context) {
    return forui.FSelect<T>.rich(
      control: .lifted(
        value: options.containsKey(value) ? value : null,
        onChange: onChange ?? (_) {},
      ),
      label: label == null ? null : Text(label!),
      description: description == null ? null : Text(description!),
      enabled: onChange != null,
      format: (value) => options[value] ?? '',
      children: [
        for (final MapEntry(:key, :value) in options.entries)
          .item(
            value: key,
            title: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
      ],
    );
  }
}
