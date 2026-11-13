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

  /// 当前调用是否已经在独占区内。
  bool get holdsExclusive => Zone.current[_exclusiveScope] == true;

  Future<T> shared<T>(Future<T> Function() action) async {
    if (holdsExclusive || Zone.current[_sharedScope] == true) {
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
    _readers--;
    if (_readers > 0) return;
    _drainWaiters();
  }

  Future<void> _acquireWrite() {
    if (!_writerActive && _readers == 0) {
      _writerActive = true;
      return Future.value();
    }
    _writerWaiting = true;
    final waiter = Completer<void>();
    _writeWaiters.add(waiter);
    return waiter.future;
  }

  void _releaseWrite() {
    _writerActive = false;
    _writerWaiting = false;
    _drainWaiters();
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
