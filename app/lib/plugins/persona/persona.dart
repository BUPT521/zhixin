/// 人格对象：名称、说明、作者与设定文本，按 JSON 存在 `app_meta` 里。
///
/// 人格是纯文本配置，不含代码；同一时间只启用一个。设定文本按 Unicode 码位
/// 计数，上限 [personaTextLimit]，超过时拒绝并说明超出多少字，不静默截断。
library;

import 'dart:convert';

import '../../domain/rules/text.dart';

/// 人格标识的规则与插件标识一致：小写字母、数字与连字符。
final RegExp _personaIdPattern = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');

/// 一份人格配置；字段在运行时只读。
final class Persona {
  const Persona({
    required this.id,
    required this.name,
    required this.description,
    required this.author,
    required this.text,
  });

  final String id;
  final String name;
  final String description;
  final String author;

  /// 写进系统提示的设定文本；保存前按 [personaTextLimit] 校验。
  final String text;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'author': author,
    'text': text,
  };

  /// 从 JSON 读取一份人格；字段缺失或类型不对时返回空，由调用方决定跳过。
  static Persona? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final name = value['name'];
    final description = value['description'];
    final author = value['author'];
    final text = value['text'];
    if (id is! String ||
        name is! String ||
        description is! String ||
        author is! String ||
        text is! String) {
      return null;
    }
    return Persona(
      id: id,
      name: name,
      description: description,
      author: author,
      text: text,
    );
  }
}

/// 人格设定文本按码位计数，超过上限时说明超出的字数；通过时返回空。
///
/// 这里不做截断：保存入口直接拒绝并把超出的字数告诉用户，提示词构建处只在
/// 读取到异常数据时用 [truncateCodePoints] 兜底。
String? validatePersonaText(String text) {
  final length = text.runes.length;
  if (length == 0) return '人格设定不能为空';
  if (length > personaTextLimit) {
    return '人格设定 $length 字，超出上限 ${length - personaTextLimit} 字'
        '（上限 $personaTextLimit 字）';
  }
  return null;
}

/// 校验一份人格的全部字段，返回第一条不合格项；通过时返回空。
String? validatePersona(Persona persona) {
  final id = persona.id.trim();
  if (id.isEmpty) return '人格标识不能为空';
  if (!_personaIdPattern.hasMatch(id)) {
    return '人格标识只能用半角小写字母、数字与连字符，并以字母或数字开头和结尾：${persona.id}';
  }
  if (persona.name.trim().isEmpty) return '人格名称不能为空';
  if (persona.description.trim().isEmpty) return '人格说明不能为空';
  if (persona.author.trim().isEmpty) return '人格作者不能为空';
  return validatePersonaText(persona.text);
}

/// 保存人格时校验失败；消息已经是给人看的说明。
final class PersonaValidationException implements Exception {
  const PersonaValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 请求的人格标识不在当前清单里。
final class PersonaNotFound implements Exception {
  const PersonaNotFound(this.id);

  final String id;

  @override
  String toString() => '没有这个人格：$id';
}

/// 把人格列表编码成 `persona.items` 的 JSON；只写展示与提示词需要的字段。
String encodePersonaItems(List<Persona> items) =>
    jsonEncode([for (final item in items) item.toJson()]);

/// 读取 `persona.items`；整体不是 JSON 数组时返回空值，条目不合格的跳过。
///
/// 返回空值表示这一项内容坏了，与“清单是空列表”分开：调用方据此保留上一次
/// 读到的人格并给出说明，而不是静默换回内置人格。
List<Persona>? decodePersonaItems(String raw) {
  Object? value;
  try {
    value = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (value is! List) return null;
  return [for (final entry in value) ?Persona.tryFromJson(entry)];
}
