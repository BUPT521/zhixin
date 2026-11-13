import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/brought_sources.dart';

void main() {
  test('带入来源按业务标识记录，只保留认得的写法且不重复', () {
    final sources = BroughtSources();

    expect(sources.add('attempt:12'), isTrue);
    expect(sources.add('message:88'), isTrue);
    expect(sources.add('material_page:3:7'), isTrue);
    expect(sources.add('question:5'), isTrue);
    expect(sources.add('attempt:12'), isFalse);
    expect(sources.add('记录页第一条'), isFalse);
    expect(sources.add('material_page:3'), isFalse);
    expect(sources.length, 4);
    expect(sources.identities, {
      'attempt:12',
      'message:88',
      'material_page:3:7',
      'question:5',
    });

    sources.remove('message:88');
    expect(sources.identities, isNot(contains('message:88')));
    sources.clear();
    expect(sources.isEmpty, isTrue);
  });
}
