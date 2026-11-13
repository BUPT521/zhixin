import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ui/discussion_activity.dart';

void main() {
  tearDown(() {
    DiscussionActivity.generating.value = const <int>{};
  });

  test('开始与结束只改变对应讨论', () {
    DiscussionActivity.begin(1);
    DiscussionActivity.begin(2);
    expect(DiscussionActivity.isGenerating(1), isTrue);
    expect(DiscussionActivity.isGenerating(2), isTrue);

    DiscussionActivity.end(1);
    expect(DiscussionActivity.isGenerating(1), isFalse);
    expect(DiscussionActivity.isGenerating(2), isTrue);
  });

  test('重复开始不会留下多余的计数，未开始的结束不改状态', () {
    DiscussionActivity.begin(3);
    DiscussionActivity.begin(3);
    DiscussionActivity.end(3);
    expect(DiscussionActivity.isGenerating(3), isFalse);

    DiscussionActivity.end(4);
    expect(DiscussionActivity.generating.value, isEmpty);
  });
}
