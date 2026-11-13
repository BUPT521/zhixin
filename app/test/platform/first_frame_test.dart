import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/platform/first_frame.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    // 每个用例都放行，避免压住的帧数带到下一个用例。
    FirstFrameGate.release();
    FirstFrameGate.resetForTest();
  });

  test('压住之后放行一次就够，重复放行不再动框架', () {
    expect(FirstFrameGate.isDeferred, isFalse);
    FirstFrameGate.defer();
    expect(FirstFrameGate.isDeferred, isTrue);

    FirstFrameGate.release();
    expect(FirstFrameGate.isDeferred, isFalse);
    // 再放行一次不接受，避免把框架的压帧计数减成负数。
    FirstFrameGate.release();
    expect(FirstFrameGate.isDeferred, isFalse);
  });

  test('没有压过第一帧时放行是空操作，测试与不压帧的入口可以照常调用', () {
    expect(FirstFrameGate.isDeferred, isFalse);
    FirstFrameGate.release();
    FirstFrameGate.release();
    expect(FirstFrameGate.isDeferred, isFalse);
  });

  test('重复压帧只算一次', () {
    FirstFrameGate.defer();
    FirstFrameGate.defer();
    expect(FirstFrameGate.isDeferred, isTrue);
    FirstFrameGate.release();
    expect(FirstFrameGate.isDeferred, isFalse);
  });
}
