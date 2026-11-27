import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 一个小文件的读写：先写临时文件再改名，同一路径上的写入排队。
///
/// 改名保证读到的要么是上一次的完整内容，要么是这一次的完整内容，不会读到写了一半
/// 的内容；写入失败时删掉半份临时文件，下一次写入重新生成。
///
/// 排队按路径共享，两个实例指向同一个文件时也排进同一条队列。不做这一层时，两次
/// 写入会共用同一个临时文件，Windows 上先完成的 rename 移走临时文件之后，后到的
/// rename 会报“另一个程序正在使用此文件”。
///
/// 读取分同步与异步两个入口，异常一律按“没有这个文件”处理，由调用方给出兜底值：
/// 外观偏好、诊断开关、引导状态与崩溃记录都只存几个字节，读法不各自再写一遍。
class AtomicFile {
  AtomicFile(this.path);

  final String path;

  /// 临时文件后缀。所有原子写入（含崩溃记录与向量索引状态）共用这一种后缀，
  /// 写到一半留下的文件因此一眼可认，清理时也不会误删真正的小文件。
  static const String temporarySuffix = '.partial';

  /// 每个文件上还没跑完的写入。队列空下来时把这一项删掉，避免长期占用。
  static final Map<String, Future<void>> _tails = {};

  String get _queueKey => p.normalize(p.absolute(path));

  String get _temporaryPath => '$path$temporarySuffix';

  /// 读全文；文件不存在、读不出来或内容不是合法文本时返回空。
  Future<String?> readText() async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// [readText] 的同步版本：崩溃记录与首帧读取这类不能等待异步的地方使用。
  String? readTextSync() {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      return file.readAsStringSync();
    } catch (_) {
      return null;
    }
  }

  /// 整份替换文件内容，排进这条路径的队列。
  Future<void> writeText(String text) => _enqueue(() => _replace(text));

  /// [writeText] 的字节版本：附件缓存这类二进制文件用同一个临时后缀与同一条
  /// 队列，写失败时同样删掉半份文件。
  Future<void> writeBytes(List<int> bytes) =>
      _enqueue(() => _replaceBytes(bytes));

  /// [writeText] 的同步版本，给进程可能马上结束或不能等待异步的调用方使用。
  ///
  /// 与异步写入共用同一种临时文件后缀，但不进入排队：同步写入只在启动与崩溃
  /// 记录这类单点调用里出现，没有并发写入可排。
  void writeTextSync(String text) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final temporary = File(_temporaryPath);
    try {
      temporary.writeAsStringSync(text, flush: true);
      temporary.renameSync(file.path);
    } catch (_) {
      // 失败时不留半份临时文件，下一次写入会重新生成。
      try {
        if (temporary.existsSync()) temporary.deleteSync();
      } catch (_) {
        // 临时文件删不掉时留在原处，不影响本次失败上报。
      }
      rethrow;
    }
  }

  /// 排到队列尾部，前一次结束之后才执行。
  ///
  /// 队列尾只用来放行下一个动作，不携带结果；动作自己的错误照常交给调用方，
  /// 无论成功失败都放行后一个动作。
  Future<T> _enqueue<T>(Future<T> Function() action) {
    final key = _queueKey;
    final previous = _tails[key] ?? Future<void>.value();
    final done = Completer<void>();
    final tail = done.future;
    _tails[key] = tail;

    final result = previous.then((_) => action());
    return result.whenComplete(() {
      done.complete();
      if (identical(_tails[key], tail)) _tails.remove(key);
    });
  }

  /// 已经排队时用这个替换内容，不要在外面再排一次队。
  Future<void> _replace(String text) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final temporary = File(_temporaryPath);
    try {
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(file.path);
    } catch (_) {
      // 失败时不留半份临时文件，下一次写入会重新生成。
      if (await temporary.exists()) {
        await temporary.delete();
      }
      rethrow;
    }
  }

  /// 与 [_replace] 相同，写入的是字节。
  Future<void> _replaceBytes(List<int> bytes) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final temporary = File(_temporaryPath);
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(file.path);
    } catch (_) {
      // 失败时不留半份临时文件，下一次写入会重新生成。
      if (await temporary.exists()) {
        await temporary.delete();
      }
      rethrow;
    }
  }
}

/// 一个 JSON 对象文件：[AtomicFile] 的原子替换之外，还在整份对象上做读改写。
///
/// 读改写单独排队，两个动作不会各自读到同一份旧内容、后写的把先写的键覆盖掉。
class AtomicJsonFile extends AtomicFile {
  AtomicJsonFile(super.path);

  /// 读整份对象；文件不存在、内容损坏或读不出来时按空对象处理。
  Future<Map<String, Object?>> read() async {
    final text = await readText();
    if (text == null) return {};
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return {};
      return decoded.cast<String, Object?>();
    } catch (_) {
      return {};
    }
  }

  /// 读最新的内容交给 [change] 改，改完整体写回；这一段在这条路径的队列里独占
  /// 执行。文件损坏或不存在时，[change] 拿到的是空对象。
  Future<void> update(void Function(Map<String, Object?> data) change) =>
      updateAndGet<void>((data) {
        change(data);
      });

  /// 与 [update] 相同，另外把 [change] 的返回值交给调用方，用于“读到就返回旧的
  /// 值，读不到就生成一个再写回”。
  Future<T> updateAndGet<T>(T Function(Map<String, Object?> data) change) =>
      _enqueue(() async {
        final data = Map<String, Object?>.of(await read());
        final result = change(data);
        await _replace(jsonEncode(data));
        return result;
      });
}
