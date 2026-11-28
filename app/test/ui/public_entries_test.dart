import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/application/paged_result.dart';
import 'package:zhixin/ui/format.dart';
import 'package:zhixin/ui/search_state.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/workspace_widgets.dart';

/// 公共入口的宿主：页面读 `context.zhixin`，与真实界面用同一份 Forui 主题。
Widget _host(Widget child) => forui.FTheme(
  data: zhixinForuiTheme,
  child: MaterialApp(
    home: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  group('设备标识脱敏', () {
    test('只保留前八位，短标识原样，空值给空串', () {
      expect(maskedDeviceId(null), '');
      expect(maskedDeviceId('   '), '');
      expect(maskedDeviceId('abc'), 'abc');
      expect(maskedDeviceId('abcdefgh'), 'abcdefgh');
      expect(maskedDeviceId('abcdefghij'), 'abcdefgh');
      expect(maskedDeviceId('  abcdefghij  '), 'abcdefgh');
      expect(maskedDeviceId('abcdefghij', keep: 4), 'abcd');
    });
  });

  group('字节格式化', () {
    test('1025 B 只有一个结果，各档按四舍五入取整', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1023), '1023 B');
      expect(formatBytes(1024), '1 KB');
      expect(formatBytes(1025), '1 KB');
      expect(formatBytes(1536), '2 KB');
      expect(formatBytes(1024 * 1024 - 1), '1024 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
      expect(formatBytes(3 * 1024 * 1024 * 1024), '3.0 GB');
    });
  });

  group('防抖', () {
    test('连续调用只执行最后一次', () async {
      var calls = 0;
      final debouncer = Debouncer(duration: const Duration(milliseconds: 10));
      debouncer(() => calls++);
      debouncer(() => calls++);
      debouncer(() => calls++);
      expect(debouncer.isPending, isTrue);
      expect(calls, 0);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(calls, 1);
      expect(debouncer.isPending, isFalse);
      debouncer.dispose();
    });

    test('取消之后不再执行', () async {
      var calls = 0;
      final debouncer = Debouncer(duration: const Duration(milliseconds: 10));
      debouncer(() => calls++);
      debouncer.cancel();
      expect(debouncer.isPending, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(calls, 0);
    });
  });

  group('分隔线', () {
    testWidgets('一像素高，上下各留一档，取容器描边色', (tester) async {
      await tester.pumpWidget(_host(const CardDivider()));
      expect(tester.getSize(find.byType(CardDivider)).height, 25);
      final lineFinder = find.descendant(
        of: find.byType(CardDivider),
        matching: find.byType(ColoredBox),
      );
      expect(tester.getSize(lineFinder).height, 1);
      final line = tester.widget<ColoredBox>(lineFinder);
      final colors = zhixinForuiTheme.extension<ZhixinTheme>().colors;
      expect(line.color, colors.outlineVariant);
    });

    testWidgets('紧凑的分组可以改成更小的间距', (tester) async {
      await tester.pumpWidget(_host(const CardDivider(gap: 8)));
      expect(tester.getSize(find.byType(CardDivider)).height, 17);
    });
  });

  group('一次性结果提示', () {
    testWidgets('成功说明是一行小字，不画错误描边', (tester) async {
      await tester.pumpWidget(_host(const ResultNotice(message: '已保存')));
      expect(find.text('已保存'), findsOneWidget);
      expect(find.byType(InlineNotice), findsNothing);
    });

    testWidgets('失败说明可以带重试', (tester) async {
      var retried = 0;
      await tester.pumpWidget(
        _host(
          ResultNotice(message: '没有保存', failed: true, onRetry: () => retried++),
        ),
      );
      expect(find.byType(InlineNotice), findsOneWidget);
      expect(find.text('没有保存'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(retried, 1);
    });

    testWidgets('失败说明不给重试动作时没有按钮', (tester) async {
      await tester.pumpWidget(
        _host(const ResultNotice(message: '没有保存', failed: true)),
      );
      expect(find.byType(InlineNotice), findsOneWidget);
      expect(find.text('重试'), findsNothing);
    });
  });

  group('分页结果', () {
    test('追加时按给定的键去重，总数取新一页的或沿用上一页', () {
      const first = PagedResult<int>(
        items: [1, 2],
        hasMore: true,
        nextOffset: 2,
        total: 5,
      );
      final merged = first.append(
        const PagedResult<int>(items: [2, 3], nextOffset: 4),
        key: (item) => item,
      );
      expect(merged.items, [1, 2, 3]);
      expect(merged.hasMore, isFalse);
      expect(merged.nextOffset, 4);
      expect(merged.total, 5);
      expect(merged.isEmpty, isFalse);
    });
  });

  group('查找状态', () {
    test('翻页按下一页起点取，读完不再发请求', () async {
      const all = ['a', 'b', 'c', 'd', 'e'];
      final offsets = <int>[];
      Future<PagedResult<String>> fetch(int offset) async {
        offsets.add(offset);
        final page = all.skip(offset).take(2).toList();
        return PagedResult(
          items: page,
          hasMore: offset + page.length < all.length,
          nextOffset: offset + page.length,
        );
      }

      final state = SearchState<String>();
      expect(state.pageSize, kSearchPageSize);
      expect(kSearchPageSize, 20);
      await state.refresh(active: true, fetch: fetch);
      expect(state.items, ['a', 'b']);
      expect(state.canLoadMore, isTrue);
      await state.loadMore();
      expect(state.items, ['a', 'b', 'c', 'd']);
      await state.loadMore();
      expect(state.items, all);
      expect(state.canLoadMore, isFalse);
      await state.loadMore();
      expect(offsets, [0, 2, 4]);
      state.dispose();
    });

    test('翻页按键去重，同一条不出现两次', () async {
      final state = SearchState<String>(key: (item) => item);
      Future<PagedResult<String>> fetch(int offset) async => offset == 0
          ? const PagedResult<String>(
              items: ['a', 'b'],
              hasMore: true,
              nextOffset: 2,
            )
          : const PagedResult<String>(items: ['b', 'c'], nextOffset: 4);
      await state.refresh(active: true, fetch: fetch);
      await state.loadMore();
      expect(state.items, ['a', 'b', 'c']);
      state.dispose();
    });

    test('晚到的旧结果按请求序号丢弃', () async {
      final slow = Completer<PagedResult<String>>();
      final fast = Completer<PagedResult<String>>();
      var call = 0;
      Future<PagedResult<String>> fetch(int offset) =>
          (call++ == 0 ? slow : fast).future;

      final state = SearchState<String>();
      final first = state.refresh(active: true, fetch: fetch);
      final second = state.refresh(active: true, fetch: fetch);
      fast.complete(const PagedResult<String>(items: ['新'], nextOffset: 1));
      await second;
      slow.complete(const PagedResult<String>(items: ['旧'], nextOffset: 1));
      await first;
      expect(state.items, ['新']);
      expect(state.phase, SearchPhase.ready);
      state.dispose();
    });

    test('连续输入只查最后一次', () async {
      var calls = 0;
      Future<PagedResult<String>> fetch(int offset) async {
        calls++;
        return PagedResult(items: ['第 $calls 次'], nextOffset: 1);
      }

      final state = SearchState<String>(
        debounceDuration: const Duration(milliseconds: 10),
      );
      state.onQueryChanged(active: true, fetch: fetch);
      state.onQueryChanged(active: true, fetch: fetch);
      state.onQueryChanged(active: true, fetch: fetch);
      expect(state.phase, SearchPhase.loading);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(calls, 1);
      expect(state.items, ['第 1 次']);
      expect(state.phase, SearchPhase.ready);
      state.dispose();
    });

    test('查到空结果算空态，条件清空回到入口状态', () async {
      final state = SearchState<String>();
      await state.refresh(
        active: true,
        fetch: (offset) async => const PagedResult<String>(),
      );
      expect(state.phase, SearchPhase.ready);
      expect(state.isEmpty, isTrue);
      await state.refresh(
        active: false,
        fetch: (offset) async => const PagedResult<String>(),
      );
      expect(state.phase, SearchPhase.idle);
      expect(state.isEmpty, isFalse);
      state.dispose();
    });

    test('第一页失败记下错误，翻页失败保留已经显示的结果', () async {
      final state = SearchState<String>();
      await state.refresh(
        active: true,
        fetch: (offset) async => throw StateError('读不到'),
      );
      expect(state.phase, SearchPhase.failed);
      expect(state.error, isA<StateError>());

      await state.refresh(
        active: true,
        fetch: (offset) async {
          if (offset > 0) throw StateError('下一页读不到');
          return const PagedResult<String>(
            items: ['a'],
            hasMore: true,
            nextOffset: 1,
          );
        },
      );
      await state.loadMore();
      expect(state.loadMoreFailed, isTrue);
      expect(state.items, ['a']);
      expect(state.phase, SearchPhase.ready);
      state.dispose();
    });
  });
}
