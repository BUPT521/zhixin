import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../domain/models/material.dart';
import '../domain/rules/content_identity.dart';

const docxMimeType =
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
const maxDocxBytes = 16 * 1024 * 1024;
const _maxXmlBytes = 4 * 1024 * 1024;
const _sectionSize = 1800;
const _mathNamespaces = {
  'http://schemas.openxmlformats.org/officeDocument/2006/math',
  'http://purl.oclc.org/ooxml/officeDocument/math',
};

class DocxImport {
  const DocxImport._(this.fileName, this.bytes, this.hash, this.sections);

  final String fileName;
  final Uint8List bytes;
  final String hash;
  final List<MaterialPageDraft> sections;

  static Future<DocxImport> read(
    String fileName,
    Stream<Uint8List> source,
  ) async {
    final name = fileName.trim();
    if (!isDocxFile(name) || name.contains(RegExp(r'[/\\\x00-\x1f]'))) {
      throw const FormatException('请选择扩展名为 .docx 的 Word 文件');
    }
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in source) {
      if (buffer.length + chunk.length > maxDocxBytes) {
        throw const FormatException('Word 文件超过 16 MB');
      }
      buffer.add(chunk);
    }
    final bytes = buffer.takeBytes();
    return Isolate.run(() => _parseDocx(name, bytes));
  }
}

DocxImport _parseDocx(String fileName, Uint8List bytes) {
  try {
    final archive = _DocxPackage(bytes);
    final mainPart = archive.relatedPart('', 'officeDocument');
    final types = archive.xml('[Content_Types].xml');
    if (mainPart == null ||
        types == null ||
        !types.childElements.any(
          (element) =>
              element.localName == 'Override' &&
              element.getAttribute('PartName') == '/$mainPart' &&
              element.getAttribute('ContentType') == '$docxMimeType.main+xml',
        )) {
      throw const FormatException('文件中没有可读取的 Word 正文');
    }
    final document = archive.xml(mainPart);
    final namespace = document?.namespaceUri;
    if (document?.localName != 'document' ||
        !const {
          'http://schemas.openxmlformats.org/wordprocessingml/2006/main',
          'http://purl.oclc.org/ooxml/wordprocessingml/main',
        }.contains(namespace)) {
      throw const FormatException('文件中没有可读取的 Word 正文');
    }
    final body = document!.getElement('body', namespaceUri: namespace);
    final styles = archive.relatedPart(mainPart, 'styles');
    final headings = _headingStyles(
      styles == null ? null : archive.xml(styles),
      namespace!,
    );
    final sections = _sections(body, namespace, headings);
    if (sections.isEmpty) {
      throw const FormatException('文档正文没有可导入的文字');
    }
    return DocxImport._(fileName, bytes, contentHash(bytes), sections);
  } on ArchiveException {
    throw const FormatException('无法读取 Word 文件，请确认文件完整且未加密');
  } on XmlException {
    throw const FormatException('Word 文件中的正文结构已损坏');
  }
}

class _DocxPackage {
  _DocxPackage(Uint8List bytes) {
    final directory = ZipDirectory();
    for (final entry in directory.headers(
      InputMemoryStream(bytes),
      verify: true,
    )) {
      if (!_parts.containsKey(entry.filename)) {
        _parts[entry.filename] = entry;
      } else {
        throw const FormatException('Word 文件包含重复的内部文件');
      }
    }
    if (directory.filePosition < 0) {
      throw const FormatException('无法读取 Word 文件，请确认文件完整且未加密');
    }
  }

  final _parts = <String, ZipFileHeader>{};

  XmlElement? xml(String name) {
    final entry = _parts[name]?.file;
    if (entry == null) return null;
    if (entry.uncompressedSize > _maxXmlBytes) {
      throw const FormatException('Word 文件的正文结构超过 4 MB');
    }
    entry.verify = true;
    entry.throwOnError = true;
    final bytes = entry.getStream().toUint8List();
    final document = XmlDocument.parse(_decodeXml(bytes));
    if (document.children.whereType<XmlDoctype>().isNotEmpty) {
      throw const FormatException('Word 文件含有不支持的 XML 文档类型声明');
    }
    return document.rootElement;
  }

  String? relatedPart(String source, String kind) {
    final lastSlash = source.lastIndexOf('/');
    final directory = source.substring(0, lastSlash + 1);
    final baseName = source.substring(lastSlash + 1);
    final relationships = xml('${directory}_rels/$baseName.rels');
    final relationship = relationships?.childElements
        .where(
          (element) =>
              element.localName == 'Relationship' &&
              (element.getAttribute('Type')?.endsWith('/$kind') ?? false) &&
              element.getAttribute('TargetMode') != 'External',
        )
        .firstOrNull;
    final target = Uri.tryParse(relationship?.getAttribute('Target') ?? '');
    if (target == null ||
        target.path.isEmpty ||
        target.hasScheme ||
        target.hasAuthority ||
        target.hasQuery ||
        target.hasFragment) {
      return null;
    }
    return Uri(path: '/$source').resolveUri(target).pathSegments.join('/');
  }
}

String _decodeXml(Uint8List bytes) {
  if (bytes.length >= 2) {
    final signature = (bytes[0], bytes[1]);
    final endian = switch (signature) {
      (0xff, 0xfe) || (0x3c, 0) => Endian.little,
      (0xfe, 0xff) || (0, 0x3c) => Endian.big,
      _ => null,
    };
    if (endian != null) {
      if (bytes.length.isOdd) throw const FormatException('Word 文件的文字编码已损坏');
      final view = ByteData.sublistView(bytes);
      final start = bytes[0] >= 0xfe ? 2 : 0;
      return String.fromCharCodes([
        for (var i = start; i < bytes.length; i += 2) view.getUint16(i, endian),
      ]);
    }
  }
  return utf8.decode(bytes);
}

Set<String> _headingStyles(XmlElement? root, String ns) {
  final styles = <String, String?>{};
  final headings = <String>{};
  for (final style
      in root?.findElements('style', namespaceUri: ns) ??
          const <XmlElement>[]) {
    if (style.getAttribute('type', namespaceUri: ns) != 'paragraph') continue;
    final id = style.getAttribute('styleId', namespaceUri: ns);
    if (id == null) continue;
    final properties = style.getElement('pPr', namespaceUri: ns);
    final level = _outlineLevel(properties, ns);
    if (level != null) {
      if (level < 9) headings.add(id);
      continue;
    }
    styles[id] = style
        .getElement('basedOn', namespaceUri: ns)
        ?.getAttribute('val', namespaceUri: ns);
  }
  for (final id in styles.keys) {
    final visited = <String>{id};
    var parent = styles[id];
    while (parent != null && visited.add(parent)) {
      if (headings.contains(parent)) {
        headings.add(id);
        break;
      }
      parent = styles[parent];
    }
  }
  return headings;
}

int? _outlineLevel(XmlElement? properties, String ns) => int.tryParse(
  properties
          ?.getElement('outlineLvl', namespaceUri: ns)
          ?.getAttribute('val', namespaceUri: ns) ??
      '',
);

final _builtInHeading = RegExp(r'^heading[1-9]$', caseSensitive: false);

List<MaterialPageDraft> _sections(
  XmlElement? body,
  String ns,
  Set<String> headingStyles,
) {
  final result = <MaterialPageDraft>[];
  final buffer = StringBuffer();
  String? heading;
  void flush() {
    if (buffer.isEmpty) return;
    result.add((
      pageNo: result.length + 1,
      content: buffer.toString(),
      label: heading,
    ));
    buffer.clear();
  }

  void append(String text, {String separator = '\n\n'}) {
    if (buffer.length + text.length + separator.length > _sectionSize) flush();
    if (buffer.isNotEmpty) buffer.write(separator);
    var start = 0;
    while (text.length - start > _sectionSize) {
      var end = start + _sectionSize;
      // Keep a UTF-16 surrogate pair together at a fragment boundary.
      if ((text.codeUnitAt(end) & 0xfc00) == 0xdc00) end--;
      buffer.write(text.substring(start, end));
      flush();
      start = end;
    }
    buffer.write(text.substring(start));
  }

  if (body == null) return result;
  for (final block in _wordBlocks(body, ns)) {
    if (_isEquation(block)) {
      final equation = _equationText(block, ns);
      if (equation.isNotEmpty) append(equation);
      continue;
    }
    if (block.localName == 'tbl') {
      final rows = _tableRows(block, ns);
      for (var index = 0; index < rows.length; index++) {
        append(rows[index], separator: index == 0 ? '\n\n' : '\n');
      }
      continue;
    }
    final text = _paragraphText(block, ns);
    if (text.isEmpty) continue;
    final properties = block.getElement('pPr', namespaceUri: ns);
    final style = properties
        ?.getElement('pStyle', namespaceUri: ns)
        ?.getAttribute('val', namespaceUri: ns);
    final level = _outlineLevel(properties, ns);
    final isHeading = level != null
        ? level < 9
        : style != null &&
              (headingStyles.contains(style) ||
                  _builtInHeading.hasMatch(style));
    if (isHeading) {
      flush();
      heading = String.fromCharCodes(text.runes.take(100));
    }
    append(text);
  }
  flush();
  return List.unmodifiable(result);
}

// Walk transparent wrappers such as content controls and inserted revisions,
// but leave each matched block or inline object for its own reader.
Iterable<XmlElement> _visibleContent(
  XmlElement root,
  String ns,
  bool Function(XmlElement) matches,
) sync* {
  final pending = root.children.reversed.whereType<XmlElement>().toList();
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    if (node.namespaceUri == ns &&
        const {
          'del',
          'moveFrom',
          'txbxContent',
          'pPr',
          'rPr',
          'sdtPr',
          'sdtEndPr',
        }.contains(node.localName)) {
      continue;
    }
    if (matches(node)) {
      yield node;
    } else {
      pending.addAll(node.children.reversed.whereType<XmlElement>());
    }
  }
}

Iterable<XmlElement> _wordBlocks(XmlElement root, String ns) => _visibleContent(
  root,
  ns,
  (node) =>
      _isEquation(node) ||
      (node.namespaceUri == ns && const {'p', 'tbl'}.contains(node.localName)),
);

List<String> _tableRows(XmlElement table, String ns, {int depth = 0}) {
  if (depth >= 128) throw const FormatException('Word 文件的表格嵌套过深');
  final rows = <String>[];
  var containsText = false;
  for (final row in _visibleContent(
    table,
    ns,
    (node) => node.namespaceUri == ns && node.localName == 'tr',
  )) {
    final cells = <String>[];
    for (final cell in _visibleContent(
      row,
      ns,
      (node) => node.namespaceUri == ns && node.localName == 'tc',
    )) {
      final blocks = <String>[];
      for (final block in _wordBlocks(cell, ns)) {
        final String text;
        if (block.localName == 'tbl') {
          final nested = _tableRows(block, ns, depth: depth + 1);
          text = nested.isEmpty ? '' : '〔${nested.join(' / ')}〕';
        } else {
          text = _isEquation(block)
              ? _equationText(block, ns)
              : _paragraphText(block, ns);
        }
        if (text.isNotEmpty) blocks.add(text.replaceAll('\n', ' / '));
      }
      final text = blocks.join(' / ');
      if (text.isNotEmpty) containsText = true;
      cells.add(text);
    }
    if (cells.isNotEmpty) rows.add('│ ${cells.join(' │ ')} │');
  }
  return containsText ? rows : const [];
}

bool _isEquation(XmlElement node) =>
    _mathNamespaces.contains(node.namespaceUri) &&
    const {'oMath', 'oMathPara'}.contains(node.localName);

bool _isWordText(XmlElement node, String ns) =>
    node.namespaceUri == ns &&
    const {'t', 'tab', 'br', 'cr', 'noBreakHyphen'}.contains(node.localName);

String _wordText(XmlElement node) => switch (node.localName) {
  't' => node.innerText,
  'tab' => '\t',
  'noBreakHyphen' => '‑',
  _ => '\n',
};

String _paragraphText(XmlElement paragraph, String ns) {
  final text = StringBuffer();
  for (final node in _visibleContent(
    paragraph,
    ns,
    (node) => _isEquation(node) || _isWordText(node, ns),
  )) {
    text.write(switch (node.localName) {
      'oMath' => _equationText(node, ns),
      'oMathPara' => '\n${_equationText(node, ns)}\n',
      _ => _wordText(node),
    });
  }
  return text.toString().trim();
}

String _equationText(XmlElement equation, String wordNs) {
  final mathNs = equation.namespaceUri!;
  if (equation.localName == 'oMathPara') {
    return _visibleContent(
      equation,
      wordNs,
      (node) =>
          node.namespaceUri == mathNs &&
          const {'oMath', 'r'}.contains(node.localName),
    ).map((node) => _equationText(node, wordNs)).join('\n');
  }
  try {
    return _linearMath(equation, wordNs, mathNs, 0);
  } on FormatException {
    return '［公式见原文件］';
  }
}

String _linearMath(XmlElement node, String wordNs, String mathNs, int depth) {
  if (depth >= 128) throw const FormatException('Word 公式嵌套过深');
  if (_isWordText(node, wordNs)) return _wordText(node);

  String render(XmlElement child) =>
      _linearMath(child, wordNs, mathNs, depth + 1);
  String argument(String name) {
    final child = node.getElement(name, namespaceUri: mathNs);
    if (child == null) throw FormatException('Word 公式缺少 $name');
    return render(child);
  }

  final properties = node.getElement(
    '${node.localName}Pr',
    namespaceUri: mathNs,
  );
  String? property(String name, {String? ifEmpty}) {
    final element = properties?.getElement(name, namespaceUri: mathNs);
    if (element == null) return null;
    return element.getAttribute('val', namespaceUri: mathNs) ?? ifEmpty;
  }

  switch (node.localName) {
    case 't':
      return node.innerText;
    case 'oMath' ||
        'r' ||
        'e' ||
        'num' ||
        'den' ||
        'sub' ||
        'sup' ||
        'deg' ||
        'fName':
      return _visibleContent(
        node,
        wordNs,
        (child) => child.namespaceUri == mathNs || _isWordText(child, wordNs),
      ).where((child) => !child.localName.endsWith('Pr')).map(render).join();
    case 'f':
      final numerator = argument('num');
      final denominator = argument('den');
      return property('type') == 'noBar'
          ? 'binom($numerator, $denominator)'
          : '($numerator)/($denominator)';
    case 'rad':
      final base = argument('e');
      final hidden = property('degHide', ifEmpty: '1');
      final degree = const {'1', 'true', 'on'}.contains(hidden)
          ? ''
          : argument('deg');
      return degree.isEmpty ? '√($base)' : 'root($degree, $base)';
    case 'sSub':
      return '(${argument('e')})_(${argument('sub')})';
    case 'sSup':
      return '(${argument('e')})^(${argument('sup')})';
    case 'sSubSup':
      return '(${argument('e')})_(${argument('sub')})^(${argument('sup')})';
    case 'func':
      return '${argument('fName')}(${argument('e')})';
    case 'd':
      final left = property('begChr', ifEmpty: '') ?? '(';
      final right = property('endChr', ifEmpty: '') ?? ')';
      final separator = property('sepChr', ifEmpty: '') ?? '|';
      final terms = node.findElements('e', namespaceUri: mathNs).map(render);
      return '$left${terms.join(separator)}$right';
    case 'm':
      final rows = node.findElements('mr', namespaceUri: mathNs).map(render);
      return '[${rows.join(', ')}]';
    case 'mr':
      final cells = node.findElements('e', namespaceUri: mathNs).map(render);
      return '[${cells.join(', ')}]';
    default:
      // A partial equation can change its meaning, so keep a location marker.
      throw FormatException('暂不支持的 Word 公式结构 ${node.localName}');
  }
}
