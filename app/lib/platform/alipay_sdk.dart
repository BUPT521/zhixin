import 'package:flutter/services.dart';

/// APP 支付时期的支付宝 SDK 通道。
///
/// 改成立刻收托管购买页之后客户端不再调用它，通道与 Android 侧的 `pay` 处理函数
/// 都保留着：需要切回 APP 支付时，直接接回 [pay] 即可，不必重装 SDK 或改清单。
/// 取舍见 ADR-0067。
class AlipaySdk {
  const AlipaySdk();

  static const _channel = MethodChannel('com.zhixin.app/alipay');

  /// 调起支付宝收银台，返回 SDK 的 resultStatus，例如 9000 表示支付成功。
  ///
  /// 仅在切回 APP 支付时使用；结果显示只用于提示，到账以服务端查单为准。
  Future<String?> pay({required String order, required bool sandbox}) =>
      _channel.invokeMethod<String>('pay', {
        'order': order,
        'sandbox': sandbox,
      });
}
