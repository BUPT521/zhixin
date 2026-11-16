/// 业务表主键：UUIDv7 文本（ADR-0018）。
///
/// 主键由写入方在插入之前生成，形如 `0190a5b3-8f2c-7a41-b0c6-5d1e2f3a4b5c`，
/// 36 位小写十六进制、带连字符。前 48 位是毫秒时间戳，同一毫秒内用 12 位序号
/// 递增，因此按主键排序与按写入顺序一致；时间回拨时沿用上一次的时间戳，新行
/// 不会排到旧行前面。剩余位取安全随机数，两台设备各自生成的标识不会相撞，
/// 增量同步才能按主键定位同一行。
library;

import 'dart:math';
import 'dart:typed_data';

/// 生成一个业务行主键。
///
/// [now] 只给测试用；正常写入直接取当前时间。同一毫秒内最多生成 4096 个，
/// 超过之后借用下一毫秒的序号位置，仍保持递增。
String newUuidV7({DateTime? now}) {
  var millis = (now ?? DateTime.now()).millisecondsSinceEpoch;
  if (millis <= _lastMillis) {
    millis = _lastMillis;
    _sequence = (_sequence + 1) & 0xfff;
    if (_sequence == 0) {
      // 同一毫秒内的序号用完：借用下一毫秒，继续保证递增。
      millis += 1;
    }
  } else {
    _sequence = 0;
  }
  _lastMillis = millis;

  final bytes = Uint8List(16);
  for (var index = 0; index < 6; index++) {
    bytes[index] = (millis >> (40 - 8 * index)) & 0xff;
  }
  // 版本 7 写在高 4 位，低 4 位与下一字节合起来是同一毫秒内的序号。
  bytes[6] = 0x70 | ((_sequence >> 8) & 0x0f);
  bytes[7] = _sequence & 0xff;
  for (var index = 8; index < 16; index++) {
    bytes[index] = _random.nextInt(256);
  }
  // 变体位：RFC 9562 的 10xx。
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  return _format(bytes);
}

/// 最近一次使用的时间戳与同一毫秒内的序号；只在主线程写入时使用。
int _lastMillis = 0;
int _sequence = 0;

final Random _random = Random.secure();

String _format(Uint8List bytes) {
  final buffer = StringBuffer();
  for (var index = 0; index < bytes.length; index++) {
    if (index == 4 || index == 6 || index == 8 || index == 10) {
      buffer.write('-');
    }
    buffer.write(bytes[index].toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
