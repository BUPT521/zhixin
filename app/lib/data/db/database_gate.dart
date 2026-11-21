import 'dart:async';

/// 数据库访问协调：读共享、写独占，恢复与导出也独占（01 第 7 章）。
///
/// 独占请求一旦排队，新的共享请求就等待，避免恢复期间还有页面在读旧库。
///
/// 同一个调用链里重复获取同一档权限时直接执行，不再次排队：事务回调里再取
/// 独占、独占区里再读一次都会走到这里，没有这层判断就会自己等自己。
class DatabaseGate {
  static final Object _exclusiveScope = Object();
  static final Object _sharedScope = Object();

  int _readers = 0;
  bool _writerActive = false;
  bool _writerWaiting = false;
  final List<Completer<void>> _readWaiters = [];
  final List<Completer<void>> _writeWaiters = [];
  final List<Completer<void>> _idleWaiters = [];

  /// 已经排上队的访问累计次数；测试用它判断界面在我们等完之后有没有又发起读取。
  int _accessCount = 0;

  /// 当前调用是否已经在独占区内。
  bool get holdsExclusive => Zone.current[_exclusiveScope] == true;

  /// 现在没有读者在跑，也没有写者在执行或排队。
  ///
  /// 页面测试靠这一项等应用自己把排队的读写放完，不再按固定时长反复推进：
  /// 读取与写入都经过这里，队列空下来就说明界面这一轮的访问已经结束。
  bool get idle =>
      _readers == 0 &&
      !_writerActive &&
      !_writerWaiting &&
      _readWaiters.isEmpty &&
      _writeWaiters.isEmpty;

  /// 排上队的访问累计次数；[idle] 成立时这一项不再变化才算真的静下来。
  int get accessCount => _accessCount;

  /// 队列空下来时完成；已经空闲时立即完成。
  ///
  /// 只在测试里使用：生产代码没有等待整库空闲的需求，恢复与导出的互斥由
  /// 独占排队解决。
  Future<void> whenIdle() {
    if (idle) return Future<void>.value();
    final waiter = Completer<void>();
    _idleWaiters.add(waiter);
    return waiter.future;
  }

  /// 队列清空之后放行 [whenIdle] 的等待者；有新的访问在排队时继续等。
  void _completeIdleIfNeeded() {
    if (_idleWaiters.isEmpty || !idle) return;
    final waiters = List<Completer<void>>.of(_idleWaiters);
    _idleWaiters.clear();
    for (final waiter in waiters) {
      waiter.complete();
    }
  }

  /// 共享访问：同一调用链里已经持有共享或独占时直接执行，不重复排队。
  ///
  /// [newReader] 为真时即使已经处在独占区里也登记一个读者：提交收尾发出的
  /// 重读就是这种情况，它要在独占区结束前就排上，让后面的写入等它读完，
  /// 读到的也一定是这次提交之后的数据。
  Future<T> shared<T>(
    Future<T> Function() action, {
    bool newReader = false,
  }) async {
    if (!newReader && (holdsExclusive || Zone.current[_sharedScope] == true)) {
      return action();
    }
    await _acquireRead();
    try {
      return await runZoned(action, zoneValues: {_sharedScope: true});
    } finally {
      _releaseRead();
    }
  }

  Future<T> exclusive<T>(Future<T> Function() action) async {
    if (holdsExclusive) {
      return action();
    }
    if (Zone.current[_sharedScope] == true) {
      // 共享区内再要独占会互相等待，这里直接报错，避免界面无响应。
      throw StateError('共享访问还没结束，不能发起独占访问');
    }
    await _acquireWrite();
    try {
      return await runZoned(action, zoneValues: {_exclusiveScope: true});
    } finally {
      _releaseWrite();
    }
  }

  Future<void> _acquireRead() {
    _accessCount++;
    if (_canRead()) {
      _readers++;
      return Future.value();
    }
    final waiter = Completer<void>();
    _readWaiters.add(waiter);
    return waiter.future;
  }

  bool _canRead() => !_writerActive && !_writerWaiting;

  void _releaseRead() {
    if (_readers > 0) _readers--;
    if (_readers > 0) return;
    _drainWaiters();
    _completeIdleIfNeeded();
  }

  Future<void> _acquireWrite() {
    _accessCount++;
    if (!_writerActive && _readers == 0) {
      _writerActive = true;
      return Future.value();
    }
    _writerWaiting = true;
    final waiter = Completer<void>();
    _writeWaiters.add(waiter);
    return waiter.future;
  }

  /// 关库专用的独占访问：不再等还在进行的读，直接把库关掉。
  ///
  /// 关库发生在页面退出与测试清理时，读者可能停在一个再也不会推进的执行区里，
  /// 等下去就是永久等待；库关掉之后这些读取会拿到错误，而它们的结果已经没人
  /// 接收。读者计数在这里清零，之后迟到的释放不会再把它减成负数。
  Future<T> closeExclusive<T>(Future<T> Function() action) async {
    _accessCount++;
    _writerActive = true;
    try {
      return await action();
    } finally {
      _writerActive = false;
      _writerWaiting = false;
      _readers = 0;
      _drainWaiters();
      _completeIdleIfNeeded();
    }
  }

  void _releaseWrite() {
    _writerActive = false;
    _writerWaiting = false;
    _drainWaiters();
    _completeIdleIfNeeded();
  }

  void _drainWaiters() {
    if (_writerActive || _readers > 0) return;
    if (_writeWaiters.isNotEmpty) {
      final waiter = _writeWaiters.removeAt(0);
      _writerActive = true;
      _writerWaiting = _writeWaiters.isNotEmpty;
      waiter.complete();
      return;
    }
    if (_readWaiters.isEmpty) return;
    final waiters = List<Completer<void>>.of(_readWaiters);
    _readWaiters.clear();
    _readers = waiters.length;
    for (final waiter in waiters) {
      waiter.complete();
    }
  }
}
