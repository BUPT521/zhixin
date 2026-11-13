import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:zhixin/application/docx_import.dart';

const _wordNs = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const _relationshipNs =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _packageNs = 'http://schemas.openxmlformats.org/package/2006';

Uint8List docxFixture({
  String body = '''
  <w:p><w:pPr><w:pStyle w:val="CourseTitle"/></w:pPr><w:r><w:t>条件概率</w:t></w:r></w:p>
  <w:p><w:r><w:t>条件概率的定义是 </w:t></w:r><w:r><w:t>P(A|B)=P(AB)/P(B)。</w:t></w:r></w:p>
  <w:p><w:pPr><w:outlineLvl w:val="1"/></w:pPr><w:r><w:t>独立事件</w:t></w:r></w:p>
  <w:tbl><w:tr>
    <w:tc><w:p><w:r><w:t>用乘法公式检验独立性。</w:t></w:r></w:p></w:tc>
    <w:tc><w:p><m:oMath><m:r><m:t>独立性判据 P(AB)=P(A)P(B)</m:t></m:r></m:oMath></w:p></w:tc>
  </w:tr></w:tbl>
''',
}) {
  final parts = {
    '[Content_Types].xml':
        '''
      <Types xmlns="$_packageNs/content-types">
        <Override PartName="/content/main.xml" ContentType="$docxMimeType.main+xml"/>
      </Types>''',
    '_rels/.rels':
        '''
      <Relationships xmlns="$_packageNs/relationships">
        <Relationship Id="rId1" Type="$_relationshipNs/officeDocument" Target="content/main.xml"/>
      </Relationships>''',
    'content/_rels/main.xml.rels':
        '''
      <Relationships xmlns="$_packageNs/relationships">
        <Relationship Id="rId1" Type="$_relationshipNs/styles" Target="styles.xml"/>
      </Relationships>''',
    'content/main.xml':
        '<w:document xmlns:w="$_wordNs" '
        'xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math">'
        '<w:body>$body</w:body></w:document>',
    'content/styles.xml':
        '''
      <w:styles xmlns:w="$_wordNs">
        <w:style w:type="paragraph" w:styleId="CourseTitle"><w:basedOn w:val="CourseBase"/></w:style>
        <w:style w:type="paragraph" w:styleId="CourseBase"><w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style>
      </w:styles>''',
  };
  final archive = Archive();
  for (final part in parts.entries) {
    final bytes = utf8.encode(part.value);
    archive.addFile(ArchiveFile.bytes(part.key, bytes));
  }
  return ZipEncoder().encodeBytes(archive);
}
