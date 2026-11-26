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

  test('免费额度折成积分向下取整，用量向上取整', () {
    // 额度不是比例整数倍时，向上取整会把额度写成 3 积分、同时又说已扣 1 分。
    expect(quotaPoints(25000, 10000), 3);
    expect(freeQuotaPoints(25000, 10000), 2);
    expect(freeQuotaPoints(9999, 10000), 0);
    expect(freeQuotaPoints(10000, 10000), 1);
    expect(freeQuotaPoints(30000, 10000), 3);
    expect(freeQuotaPoints(0, 10000), 0);
    expect(freeQuotaPoints(25000, null), 0);
  });

  test('等待时长按时长换单位并向上取整', () {
    expect(waitText(30), '30 秒');
    expect(waitText(60), '60 秒');
    expect(waitText(90), '2 分钟');
    expect(waitText(3600), '1 小时');
    expect(waitText(21600), '6 小时');
  });
}
