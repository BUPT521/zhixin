import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/application/docx_import.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/application/evidence_service.dart';
import 'package:zhixin/application/material_service.dart';
import 'package:zhixin/application/search_service.dart';
import 'package:zhixin/data/db/app_database.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/repository/evidence_repository.dart';
import 'package:zhixin/data/repository/material_repository.dart';
import 'package:zhixin/data/revisions/revision_package.dart';
import 'package:zhixin/domain/models/evidence.dart';

import '../support/docx_fixture.dart';
import '../support/service_runtime.dart';
import '../support/test_db.dart';

void main() {
  test('读取自定义正文路径、继承的标题、中文和表格内文字', () async {
    final bytes = docxFixture();
    final document = await DocxImport.read('讲义.DOCX', Stream.value(bytes));
    expect(document.sections.map((section) => section.label), ['条件概率', '独立事件']);
    expect(document.sections.first.content, contains('定义是 P(A|B)=P(AB)/P(B)'));
    expect(document.sections.last.content, contains('用乘法公式检验独立性。'));
    expect(document.bytes, bytes);
  });

  test('保留表格行序、空单元格和嵌套内容，单元格标题不切断表格', () async {
    final bytes = docxFixture(
      body: '''
      <w:p><w:r><w:t>表前说明</w:t></w:r></w:p>
      <w:tbl>
        <w:tr>
          <w:tc><w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>变量</w:t></w:r></w:p></w:tc>
          <w:tc><w:p><w:r><w:t>取值</w:t></w:r></w:p></w:tc>
          <w:tc><w:p><w:r><w:t>备注</w:t></w:r></w:p></w:tc>
        </w:tr>
        <w:tr>
          <w:tc><w:p><w:r><w:t>X</w:t></w:r></w:p></w:tc>
          <w:tc><w:p/></w:tc>
          <w:tc>
            <w:p><w:r><w:t>见子表</w:t></w:r></w:p>
            <w:tbl><w:tr><w:tc><w:p><w:r><w:t>离散</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
            <w:p/>
          </w:tc>
        </w:tr>
      </w:tbl>
      <w:p><w:r><w:t>表后说明</w:t></w:r></w:p>
    ''',
    );
    final document = await DocxImport.read('表格.docx', Stream.value(bytes));
    expect(document.sections.single.label, isNull);
    expect(
      document.sections.single.content,
      '表前说明\n\n│ 变量 │ 取值 │ 备注 │\n'
      '│ X │  │ 见子表 / 〔│ 离散 │〕 │\n\n表后说明',
    );
  });

  test('转写行内与独立公式，保留运算分组并标注不支持的结构', () async {
    final bytes = docxFixture(
      body: '''
      <w:p>
        <w:r><w:t>计算 </w:t></w:r>
        <m:oMath>
          <m:f>
            <m:num><m:sSup><m:e><m:r><w:t>x</w:t></m:r></m:e><m:sup><m:r><m:t>2</m:t></m:r></m:sup></m:sSup></m:num>
            <m:den><m:rad><m:radPr><m:degHide/></m:radPr><m:deg/><m:e><m:r><m:t>y+1</m:t></m:r></m:e></m:rad></m:den>
          </m:f>
        </m:oMath>
        <w:del w:id="1"><m:oMath><m:r><m:t>已删除</m:t></m:r></m:oMath></w:del>
        <w:r><w:t>。</w:t></w:r>
      </w:p>
      <m:oMathPara>
        <m:oMath>
          <m:d>
            <m:dPr><m:begChr m:val="["/><m:endChr m:val="]"/><m:sepChr m:val=","/></m:dPr>
            <m:e><m:r><m:t>a</m:t></m:r></m:e><m:e><m:r><m:t>b</m:t></m:r></m:e>
          </m:d>
        </m:oMath>
        <m:oMath>
          <m:m>
            <m:mr><m:e><m:r><m:t>1</m:t></m:r></m:e><m:e><m:r><m:t>2</m:t></m:r></m:e></m:mr>
            <m:mr><m:e><m:r><m:t>3</m:t></m:r></m:e><m:e><m:r><m:t>4</m:t></m:r></m:e></m:mr>
          </m:m>
        </m:oMath>
      </m:oMathPara>
      <w:p><w:r><w:t>下式</w:t></w:r><m:oMath><m:acc><m:e><m:r><m:t>x</m:t></m:r></m:e></m:acc></m:oMath></w:p>
    ''',
    );
    final document = await DocxImport.read('公式.docx', Stream.value(bytes));
    expect(
      document.sections.single.content,
      '计算 ((x)^(2))/(√(y+1))。\n\n[a,b]\n[[1, 2], [3, 4]]\n\n下式［公式见原文件］',
    );
  });

  test('长正文按片段长度切分且保留跨边界的补充平面字符', () async {
    final text = '字' * 1799 + '𝑥' * 900;
    final bytes = docxFixture(body: '<w:p><w:r><w:t>$text</w:t></w:r></w:p>');
    final document = await DocxImport.read('长正文.docx', Stream.value(bytes));
    final fragments = document.sections.map((section) => section.content);
    expect(fragments.map((fragment) => fragment.length), [1799, 1800]);
    expect(fragments.join(), text);
  });

  test('旧 Word 格式、坏包、空正文和超限文件都无法进入预览', () async {
    await expectLater(
      DocxImport.read('讲义.doc', Stream.value(docxFixture())),
      throwsFormatException,
    );
    await expectLater(
      DocxImport.read('讲义.docx', Stream.value(Uint8List(4))),
      throwsFormatException,
    );
    await expectLater(
      DocxImport.read('讲义.docx', Stream.value(docxFixture(body: '<w:p/>'))),
      throwsFormatException,
    );
    await expectLater(
      DocxImport.read('讲义.docx', Stream.value(Uint8List(maxDocxBytes + 1))),
      throwsFormatException,
    );
  });

  test('导入后可按片段检索，更正可撤销，恢复数据包后保留原文件', () async {
    final rig = await openTestRig();
    final target = await openTestRig();
    addTearDown(() async {
      for (final item in [rig, target]) {
        await item.close();
        await Directory(item.filesDir).delete(recursive: true);
      }
    });
    var epoch = 0;
    final repository = MaterialRepository(rig.db.rawDb);
    final service = MaterialService(
      materials: repository,
      transactions: WriteTransactions(rig.db),
      runtime: testRuntime(dataEpoch: () => epoch),
    );
    final bytes = docxFixture();
    final document = await DocxImport.read('概率讲义.docx', Stream.value(bytes));
    epoch++;
    await expectLater(
      service.importDocx(document: document, title: '已过期', expectedEpoch: 0),
      throwsStateError,
    );
    expect(await rig.engine.assets.objectHashes(rig.raw.rawDb), isEmpty);
    await expectLater(
      service.importDocx(
        document: document,
        title: '目标已删除',
        goalId: -1,
        expectedEpoch: epoch,
      ),
      throwsA(isA<SqliteException>()),
    );
    expect(await rig.engine.assets.objectHashes(rig.raw.rawDb), isEmpty);

    final id = await service.importDocx(
      document: document,
      title: '概率讲义',
      expectedEpoch: epoch,
    );
    final search = SearchService(
      evidence: EvidenceService(repository: EvidenceRepository(rig.db.rawDb)),
    );
    final hits = await search.search(
      '用乘法公式检验独立性',
      scope: EvidenceScope.userMaterial(id),
    );
    expect(hits.entries.single.hits.first.title, '《概率讲义》第 2 个片段');
    expect(hits.entries.single.hits.first.location.pageNo, 2);
    final formulaHits = await search.search(
      '独立性判据',
      scope: EvidenceScope.userMaterial(id),
    );
    expect(formulaHits.entries.single.hits.first.location.pageNo, 2);
    final second = (await service.page(id, 2))!;
    expect(second.content, contains('独立性判据 P(AB)=P(A)P(B)'));
    final correction = await service.correctPage(
      page: second,
      corrected: '已校对的正文',
    );
    expect((await service.page(id, 2))!.content, '已校对的正文');
    await rig.revisions.undoCommit(correction!);
    expect((await service.page(id, 2))!.content, second.content);

    final packages = RevisionPackageService(
      factory: databaseFactoryFfi,
      engine: rig.engine,
      assets: rig.engine.assets,
      schemaVersion: zhixinSchemaVersion,
      appVersion: 'test',
    );
    final path = '${rig.filesDir}/current.zip';
    await packages.exportCurrent(rig.db.rawDb, path);
    await packages.importCurrent(
      target.raw.rawDb,
      await File(path).readAsBytes(),
      expectedHead: await target.engine.headId(target.raw.rawDb),
    );
    final restored = MaterialRepository(target.db.rawDb);
    expect((await restored.byId(id))!.sourceFileName, '概率讲义.docx');
    expect((await restored.page(id, 2))!.content, second.content);
    expect(await restored.sourceFileBytes(id), bytes);
  });
}
