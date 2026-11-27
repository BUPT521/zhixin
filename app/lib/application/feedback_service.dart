/// 应用内反馈：不要求登录，提交到当前知新服务地址（没有登录或没有
/// 自定义时是编译时的默认地址），服务端据此限流与保存（ADR-0025）。
///
/// 版本名与平台由页面从应用信息填入；字段长度与格式的服务端口径见
/// server/README.md 的“应用内反馈”，客户端先做一次同样的轻量核对，改动仍在
/// 服务端，两处不一致时以服务端为准。
library;

import '../data/cloud/server_client.dart';
import '../domain/models/server_models.dart';

/// 一条待提交的反馈：正文必填，联系邮箱、诊断摘要可选。
class FeedbackDraft {
  const FeedbackDraft({
    required this.content,
    required this.appVersion,
    this.contact = '',
    this.platform = 'android',
    this.diagnostics = '',
  });

  final String content;
  final String contact;
  final String diagnostics;
  final String appVersion;
  final String platform;
}

/// 提交反馈的入口；测试可以把它换成固定回执或固定异常。
typedef FeedbackSubmitter = Future<ServerFeedbackReceipt> Function(
  FeedbackDraft draft,
);

/// 建服务端客户端的方式；测试注入进程内的假服务，生产留空。
typedef FeedbackClientFactory = ServerClient Function(String baseUrl);

class FeedbackService {
  FeedbackService({
    required this.serverBaseUrl,
    this.clientFactory,
    this.timeout = const Duration(seconds: 30),
  });

  /// 当前知新服务地址，登录与否都可用。
  final Future<String> Function() serverBaseUrl;

  final FeedbackClientFactory? clientFactory;
  final Duration timeout;

  /// 提交一条反馈；网络与格式问题原样抛出，由页面按 [ServerProblem] 说明。
  Future<ServerFeedbackReceipt> submit(FeedbackDraft draft) async {
    final baseUrl = await serverBaseUrl();
    final client =
        clientFactory?.call(baseUrl) ??
        ServerClient(baseUrl: baseUrl, timeout: timeout);
    try {
      return await client.sendFeedback(
        content: draft.content,
        contact: draft.contact,
        appVersion: draft.appVersion,
        platform: draft.platform,
        diagnostics: draft.diagnostics,
      );
    } finally {
      // 注入的客户端归调用方管，自己建的用完就关。
      if (clientFactory == null) client.dispose();
    }
  }
}
