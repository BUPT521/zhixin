import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/revisions/revision_engine.dart'
    show versionedTableNames;
import 'package:zhixin/ui/copy.dart';

void main() {
  test('参与数据版本采集的表都有中文名', () {
    final missing = [
      for (final name in versionedTableNames)
        if (tableLabel(name) == name) name,
    ];
    expect(missing, isEmpty, reason: '没有登记中文名的表会直接把内部表名显示给用户，见 docs/02 第 3 章');
  });
}
