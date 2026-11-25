import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ui/format.dart';

void main() {
  test('计费 token 按万与亿简写，没到一万的加千位分隔', () {
    expect(tokenAmount(1000), '1,000');
    expect(tokenAmount(12480), '1.2 万');
    expect(tokenAmount(1000000), '100 万');
    expect(tokenAmount(3200000), '320 万');
    expect(tokenAmount(9000000), '900 万');
    expect(tokenAmount(100000000), '1 亿');
  });

  test('天数十以下保留一位小数，十以上取整', () {
    expect(quotaDays(3.125), '3.1');
    expect(quotaDays(10), '10');
    expect(quotaDays(28.125), '28');
  });

  test('积分只加千位分隔，不换算成万', () {
    expect(groupDigits(1000), '1,000');
    expect(groupDigits(9000), '9,000');
    expect(groupDigits(0), '0');
  });

  test('计费 token 按比例折成积分并向上取整', () {
    expect(quotaPoints(0, 1000), 0);
    expect(quotaPoints(1000, 1000), 1);
    expect(quotaPoints(1001, 1000), 2);
    expect(quotaPoints(320000, 1000), 320);
    expect(quotaPoints(12480, 1000), 13);
    expect(quotaPoints(1000, null), 0);
    expect(quotaPoints(1000, 0), 0);
  });
}
