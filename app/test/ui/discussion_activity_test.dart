import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ui/discussion_activity.dart';

void main() {
  tearDown(() {
    DiscussionActivity.generating.value = const <String>{};
  });

  test('开始与结束只改变对应讨论', () {
    DiscussionActivity.begin('conv-1');
    DiscussionActivity.begin('conv-2');
    expect(DiscussionActivity.isGenerating('conv-1'), isTrue);
    expect(DiscussionActivity.isGenerating('conv-2'), isTrue);

    DiscussionActivity.end('conv-1');
    expect(DiscussionActivity.isGenerating('conv-1'), isFalse);
    expect(DiscussionActivity.isGenerating('conv-2'), isTrue);
  });

  test('重复开始不会留下多余的计数，未开始的结束不改状态', () {
    DiscussionActivity.begin('conv-3');
    DiscussionActivity.begin('conv-3');
    DiscussionActivity.end('conv-3');
    expect(DiscussionActivity.isGenerating('conv-3'), isFalse);

    DiscussionActivity.end('conv-4');
    expect(DiscussionActivity.generating.value, isEmpty);
  });
}
