import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/domain/rules/notices.dart';

void main() {
  test('每个提示状态的值互不相同，并能按值读回', () {
    final values = Notice.values.map((notice) => notice.value).toSet();
    expect(values, hasLength(Notice.values.length));
    for (final notice in Notice.values) {
      expect(noticeFromValue(notice.value), notice);
      expect(notice.label, isNotEmpty);
    }
  });

  test('认不出的值与空值读回为空，界面不显示未知提示', () {
    expect(noticeFromValue('not_a_notice'), isNull);
    expect(noticeFromValue(''), isNull);
    expect(noticeFromValue(null), isNull);
  });
}
