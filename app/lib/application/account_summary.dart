import '../domain/models/server_models.dart';
import 'account_service.dart';
import 'sync_service.dart';

/// 一份账号摘要：账号快照、同步状态、今日额度与本机设备标识。
///
/// 账号页原先走网络刷新账号（`refreshAccount`），“我的”页读本机快照
/// （`snapshot`），预读又把这两样与额度各读一遍，三处各拼一次结果；字段与容错
/// 因此已经分叉，额度读不到时一处保留上次的数字、一处清空（A22）。现在两个页面
/// 与预读都经 [AccountSummaryReader] 取同一份结果。
class AccountSummary {
  const AccountSummary({
    required this.snapshot,
    required this.sync,
    this.quota,
    this.localDeviceId,
  });

  final AccountSnapshot snapshot;
  final SyncStatus sync;

  /// 今日额度；没有登录或读不到时为空，页面按“暂时无法读取”显示。
  final ServerQuota? quota;

  /// 本机设备标识：设备一节按它给这一行标“本机”（ADR-0048）。读不到时为空。
  final String? localDeviceId;

  bool get signedIn => snapshot.signedIn;

  /// 复制一份摘要，只替换给出的字段；额度是后读的一步，读到之后并进同一份结果。
  AccountSummary copyWith({
    AccountSnapshot? snapshot,
    SyncStatus? sync,
    ServerQuota? quota,
    String? localDeviceId,
  }) => AccountSummary(
    snapshot: snapshot ?? this.snapshot,
    sync: sync ?? this.sync,
    quota: quota ?? this.quota,
    localDeviceId: localDeviceId ?? this.localDeviceId,
  );
}

/// 账号摘要的唯一读取入口。
///
/// [refresh] 为真时先用网络核对一次登录方式（账号页），为假时只读本机记录
/// （“我的”页与预读）；两种读法只有这一步不同，后面的同步状态、额度、设备名册
/// 与设备标识都由这里按同一顺序取，页面不再各写一份。
class AccountSummaryReader {
  const AccountSummaryReader({required this.account, required this.sync});

  final AccountService account;
  final SyncService sync;

  /// 读一份摘要。
  ///
  /// 额度要走网络，默认不读：[withQuota] 为真时一起读（账号页首读），否则由
  /// 页面先显示本机状态，再用 [readQuota] 补上（“我的”页的账号卡）。
  Future<AccountSummary> read({
    bool refresh = false,
    bool withQuota = false,
  }) async {
    final snapshot = refresh
        ? await account.refreshAccount()
        : await account.snapshot();
    final status = await sync.status();
    String? localDeviceId;
    ServerQuota? quota;
    if (snapshot.signedIn) {
      if (withQuota) quota = await readQuota();
      localDeviceId = await readDeviceId();
      // 设备一节读同步服务缓存的名册；读取失败只记诊断，不阻塞这一页。
      await sync.refreshDevices();
    }
    return AccountSummary(
      snapshot: snapshot,
      sync: status,
      quota: quota,
      localDeviceId: localDeviceId,
    );
  }

  /// 今日额度；没有登录或读不到时为空，调用方按“暂时无法读取”显示。
  ///
  /// 额度只用于显示，读不到时不影响同步与备份，所以这里不抛异常。
  Future<ServerQuota?> readQuota() async {
    try {
      return await account.quota();
    } catch (_) {
      return null;
    }
  }

  /// 本机设备标识；读不到时为空，设备一节不标“本机”，其他内容照常显示。
  Future<String?> readDeviceId() async {
    try {
      return await account.deviceId();
    } catch (_) {
      return null;
    }
  }
}
