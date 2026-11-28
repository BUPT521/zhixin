import 'dart:async';

import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import 'account_login_form.dart';
import 'accent_picker.dart';
import 'failure_feedback.dart';
import 'navigation.dart';
import 'onboarding_controller.dart';
import 'theme.dart';
import 'zhixin_switch.dart';
import 'workspace_widgets.dart';
import 'zhixin_segmented.dart';

/// 首次启动引导：用户须知与隐私政策、登录或注册、外观三步。
///
/// 由应用根部按引导状态显示在首页的位置上，不压在 `HomeShell` 之上。同意用户
/// 须知之前不安排匿名上报与更新检查；不同意时进入纯本机模式，直接跳到外观
/// 这一步。当前步骤与第一页的选择都放在 [OnboardingController] 里，进入下一
/// 步之前先写进设备文件；第一次登录换本机空间、整棵界面重建之后，新的页面按
/// 登录态把第二步补成已完成，不会退回去重新登录。
///
/// 三步常驻在一个页面栈里，左右划动与底栏四栏共用 [TabSlideStack]；划动只
/// 触发这一步的主操作，写设备文件与写完成标记仍由主操作完成。只补第一步时
/// 没有下一页，没勾选同意时向前划不动。
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key, required this.controller});

  final OnboardingController controller;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  bool _busy = false;
  String? _error;

  /// 登录表单里的邮箱；换到登录步骤时由表单与找回密码共用。
  final _identifier = TextEditingController();

  /// 这一页装上之后是否已经读过一次登录态；重建之后新的 State 会再读一次。
  bool _loginStateChecked = false;

  OnboardingController get _controller => widget.controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loginStateChecked) return;
    _loginStateChecked = true;
    unawaited(_advanceIfSignedIn());
  }

  @override
  void dispose() {
    _identifier.dispose();
    super.dispose();
  }

  /// 重建之后按当前登录态决定第二步是否已经完成。
  ///
  /// 登录会在请求途中换本机空间，整棵界面子树重建，登录页在返回之前就已经卸载，
  /// 等不到“登录成功”的返回值；新的应用根装配好之后会话已经写进安全存储，读
  /// 一次登录态就知道这次登录有没有成功。开库失败或读不到时留在第二步，用户
  /// 可以再试。
  Future<void> _advanceIfSignedIn() async {
    if (!mounted || _controller.stage != OnboardingStage.login) return;
    final scope = AppScope.of(context);
    try {
      await scope.ready;
      final snapshot = await scope.accountServices.account.snapshot();
      if (!mounted || !snapshot.signedIn) return;
      await _controller.signedIn();
    } catch (_) {
      // 读不到登录态只影响自动推进，第二步的表单仍然可用。
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _error = describeFailure(
          context,
          error,
          stack,
          action: '保存引导状态',
          kind: 'onboarding',
          kept: '这一页的选择还没有保存',
          next: '可以再试一次',
        );
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 匿名统计的首次说明状态写在设备文件里，不依赖数据库；服务还没装配好时
  /// 跳过，首页起来之后按设置里的开关处理。
  ///
  /// 这里只记开关与“说明已看过”，不发这次上报：第一次匿名上报要等引导走完、
  /// 进入首页之后才发出（ADR-0077）。
  Future<void> _completeTelemetry(
    AppScopeState scope, {
    required bool enabled,
  }) async {
    try {
      await scope.ready;
      await scope.accountServices.activeReport.completeNotice(
        enabled: enabled,
        report: false,
      );
    } catch (_) {
      // 引导本身不依赖数据库；这里失败不影响进入首页。
    }
  }

  Future<void> _accept() async {
    final scope = AppScope.of(context);
    await _run(() async {
      await _controller.acceptTerms();
      await _completeTelemetry(scope, enabled: _controller.telemetryEnabled);
      if (_controller.termsOnly) {
        await _controller.finish();
      } else {
        _controller.continueAfterTerms();
      }
    });
  }

  Future<void> _decline() async {
    final scope = AppScope.of(context);
    await _run(() async {
      await _controller.declineTerms();
      await _completeTelemetry(scope, enabled: false);
      await _controller.skipLogin();
    });
  }

  Future<void> _finish() => _run(_controller.finish);

  /// 找回密码：直接打开账号页的找回密码形态，不再让用户进去之后再点一次。
  ///
  /// 回来之后按当前登录态重画第二步：换空间时导航树整体重建、这一页可能已经
  /// 换过一个新的，没有登录就仍停在第二步。
  Future<void> _openForgotPassword() async {
    final scope = AppScope.of(context);
    if (!scope.dataReady) {
      setState(() => _error = '账号服务还没有准备好，可以稍后再试');
      return;
    }
    await openAccount(
      context,
      reset: true,
      identifier: _identifier.text.trim(),
    );
    if (!mounted) return;
    await _advanceIfSignedIn();
  }

  void _handleBack() {
    if (_controller.stage == OnboardingStage.terms) {
      // 第一步没有上一步：返回键退出应用。
      SystemNavigator.pop();
      return;
    }
    _controller.back();
  }

  /// 这一步能不能往前翻：第一步要先勾选同意。
  bool get _canAdvance =>
      !_busy &&
      switch (_controller.stage) {
        OnboardingStage.terms => _controller.termsChecked,
        OnboardingStage.login => true,
        OnboardingStage.appearance => true,
      };

  /// 底部按钮与左划共用的前进一步；第一步按下同意，第二步先在本机用，
  /// 最后一步完成。三步的动作仍与各自的按钮文案一致，不另做一套。
  Future<void> _advance() async {
    if (!_canAdvance) return;
    switch (_controller.stage) {
      case OnboardingStage.terms:
        await _accept();
      case OnboardingStage.login:
        await _run(_controller.skipLogin);
      case OnboardingStage.appearance:
        await _finish();
    }
  }

  /// 底部“上一步”与右划：第一页没有上一步，交给系统返回键退出应用。
  void _back() {
    if (_busy || _controller.stage == OnboardingStage.terms) return;
    _controller.back();
  }

  /// 顶部进度点能不能点：往回随时可以，往前要先处理须知；选过“不同意”的
  /// 设备没有登录这一步，往前与往回都不出现。
  bool _canGoTo(int index) {
    if (_busy) return false;
    final current = _controller.stage.index;
    if (index == current) return false;
    // 选过“不同意”的设备没有登录这一步，往回也不出现；要登录先去第一步同意。
    if (index == OnboardingStage.login.index &&
        !_controller.record.consentCurrent) {
      return false;
    }
    if (index < current) return true;
    final settled = _controller.record.consentCurrent || _controller.declined;
    if (!settled) return false;
    return true;
  }

  Future<void> _goTo(int index) async {
    if (!_canGoTo(index)) return;
    final target = OnboardingStage.values[index];
    if (target == _controller.stage) return;
    await _run(() => _controller.goTo(target));
  }

  /// 横拖能不能划向某一页：往前与这一步的主操作同一套条件，往回只到“上一步”
  /// 会去的那一步。不同意之后没有登录这一步，外观页往右划因此不跟手，回第一
  /// 步仍用底部按钮。
  bool _canSwipeTo(int index) {
    if (_busy) return false;
    final target = OnboardingStage.values[index];
    if (target.index < _controller.stage.index) {
      return target == _controller.previousStage;
    }
    // 只补第一步时没有下一页，往后走交给“同意并继续”。
    return !_controller.termsOnly && _canAdvance;
  }

  /// 划到相邻的一页：往前沿用这一步的主操作，往回与“上一步”相同。写设备文件、
  /// 换空间这类事情仍由主操作做，划动不另写一套。
  void _swipeTo(int index) {
    if (index < _controller.stage.index) {
      _back();
      return;
    }
    unawaited(_advance());
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: forui.FScaffold(
        child: SafeArea(
          child: PageWidth(
            child: ListenableBuilder(
              listenable: _controller,
              builder: (context, _) => Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _progress(context),
                  ),
                  Expanded(
                    // 与底栏四栏同一套整页滑动：拖动途中相邻两页跟着手指走，
                    // 松手按划过的比例或速度决定翻过去还是退回原处，不满足条件
                    // 的一步不跟手。三步常驻，翻回来时登录表单里填过的内容还在。
                    // 上下滚动仍由每一页自己的滚动区接走。
                    child: TabSlideStack(
                      index: _controller.stage.index,
                      canSwipeTo: _canSwipeTo,
                      onSwipe: _swipeTo,
                      children: [
                        for (final stage in OnboardingStage.values)
                          _step(context, stage),
                      ],
                    ),
                  ),
                  _navigation(context),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 顶部三段进度点；只补第一步时只有一段。点过的点可以直接回去，往前只到
  /// 已经处理完须知的那一步，没勾选时点了也不动。
  Widget _progress(BuildContext context) {
    final count = _controller.progressCount;
    final current = _controller.progressIndex.clamp(0, count - 1);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          _progressDot(context, index: i, current: current),
      ],
    );
  }

  Widget _progressDot(
    BuildContext context, {
    required int index,
    required int current,
  }) {
    final theme = context.zhixin;
    final selected = index == current;
    final reachable = _canGoTo(index);
    // 点本身只有 8 高，外面留 36 的方框当可点区域，读屏与手指都够得到。
    return Semantics(
      key: ValueKey('onboarding-step-$index'),
      button: !selected && reachable,
      enabled: !selected && reachable,
      selected: selected,
      label: selected ? '第 ${index + 1} 步，当前' : '第 ${index + 1} 步',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: reachable ? () => _goTo(index) : null,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Center(
            child: AnimatedContainer(
              duration: context.motionOf(theme.motion.fast),
              curve: theme.motion.move,
              width: selected ? 20 : 8,
              height: 8,
              decoration: BoxDecoration(
                color: index <= current
                    ? theme.colors.primary
                    : theme.colors.outlineVariant,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 底部固定的前后页操作：左边上一步，右边这一步的主操作；需要另一条出路
  /// 时（不同意、跳过）放在主操作上面一行。主操作沿用各步原有的文案，
  /// “上一步”只补一个入口，不改变每步实际发生的事。
  Widget _navigation(BuildContext context) {
    final theme = context.zhixin;
    final stage = _controller.stage;
    final secondary = switch (stage) {
      OnboardingStage.terms => forui.FButton(
        variant: forui.FButtonVariant.ghost,
        mainAxisSize: MainAxisSize.min,
        onPress: _busy ? null : _decline,
        child: const Text('不同意，仅在本机使用'),
      ),
      OnboardingStage.appearance => forui.FButton(
        variant: forui.FButtonVariant.ghost,
        mainAxisSize: MainAxisSize.min,
        onPress: _busy ? null : _finish,
        child: const Text('跳过'),
      ),
      OnboardingStage.login => null,
    };
    final forward = switch (stage) {
      OnboardingStage.terms => forui.FButton(
        mainAxisSize: MainAxisSize.min,
        onPress: _canAdvance ? _accept : null,
        child: Text(_busy ? '正在保存…' : '同意并继续'),
      ),
      OnboardingStage.login => forui.FButton(
        variant: forui.FButtonVariant.outline,
        mainAxisSize: MainAxisSize.min,
        onPress: _busy ? null : () => _run(_controller.skipLogin),
        child: const Text('先在本机用'),
      ),
      OnboardingStage.appearance => forui.FButton(
        mainAxisSize: MainAxisSize.min,
        onPress: _busy ? null : _finish,
        child: Text(_busy ? '正在保存…' : '完成'),
      ),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.colors.outlineVariant)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          theme.space.page,
          theme.space.sm,
          theme.space.page,
          theme.space.sm,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (secondary case final secondary?) ...[
              Center(child: secondary),
              SizedBox(height: theme.space.xs),
            ],
            Row(
              children: [
                if (stage != OnboardingStage.terms)
                  forui.FButton(
                    variant: forui.FButtonVariant.ghost,
                    mainAxisSize: MainAxisSize.min,
                    onPress: _busy ? null : _back,
                    prefix: const Icon(FLucideIcons.chevronLeft),
                    child: const Text('上一步'),
                  ),
                const Spacer(),
                forward,
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _step(BuildContext context, OnboardingStage stage) {
    return switch (stage) {
      OnboardingStage.terms => _termsStep(context),
      OnboardingStage.login => _loginStep(context),
      OnboardingStage.appearance => _appearanceStep(context),
    };
  }

  /// 一页的标题、说明与内容；底部的前后页操作固定在滚动区下面，键盘弹出时
  /// 由页面骨架让出高度，主操作仍然够得到。
  ///
  /// 三步常驻在页面栈里，出错说明只放在当前这一步，不跟着复制到另外两步。
  Widget _page(
    BuildContext context, {
    required OnboardingStage stage,
    required String title,
    required String description,
    required List<Widget> children,
    Widget? leading,
  }) {
    final theme = context.zhixin;
    final error = stage == _controller.stage ? _error : null;
    return ListView(
      padding: theme.space.pageInsets(top: theme.space.section, bottom: 48),
      children: [
        if (leading != null) ...[leading, SizedBox(height: theme.space.lg)],
        Text(title, style: theme.text.titleLarge),
        SizedBox(height: theme.space.sm),
        Text(
          description,
          style: theme.text.bodyMedium.copyWith(
            color: theme.colors.onSurfaceVariant,
          ),
        ),
        SizedBox(height: theme.space.section),
        ...children,
        if (error != null) ...[
          SizedBox(height: theme.space.md),
          InlineNotice(message: error),
        ],
      ],
    );
  }

  Widget _termsStep(BuildContext context) {
    final theme = context.zhixin;
    return _page(
      context,
      stage: OnboardingStage.terms,
      title: _controller.termsOnly ? '用户须知有更新' : '开始使用前，先看这两份说明',
      description: _controller.termsOnly
          ? '用户须知与隐私政策改过，同意之后才能继续使用登录、云同步与自动检查更新；'
                '本机记录、查找与导出不受影响。'
          : '上滑阅读《用户须知》与《隐私政策》，勾选同意之后才能使用登录、云同步、'
                '模型调用与自动检查更新；不同意也可以只在本机使用。',
      children: [
        forui.FTile(
          prefix: const LeadingIcon(FLucideIcons.fileText),
          title: const Text('用户须知'),
          subtitle: const Text('使用规则、账号与内容约定、积分购买说明'),
          suffix: const Icon(FLucideIcons.chevronRight),
          onPress: () => openUserTerms(context, allowAgree: false),
        ),
        SizedBox(height: theme.space.sm),
        forui.FTile(
          prefix: const LeadingIcon(FLucideIcons.shieldCheck),
          title: const Text('隐私政策'),
          subtitle: const Text('收集哪些信息、存在哪里、交给谁处理'),
          suffix: const Icon(FLucideIcons.chevronRight),
          onPress: () => openPrivacyPolicy(context),
        ),
        SizedBox(height: theme.space.md),
        forui.FCard(
          child: Padding(
            padding: EdgeInsets.all(theme.space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                forui.FCheckbox(
                  value: _controller.termsChecked,
                  label: const Text('我已阅读并同意《用户须知》与《隐私政策》'),
                  onChange: (value) => _controller.termsChecked = value,
                ),
                const CardDivider(),
                ZhixinSwitch(
                  label: const Text('匿名使用统计'),
                  description: const Text(
                    '采集范围、用途与保存期限见上面《隐私政策》第二部分；'
                    '可以随时在设置里关闭。',
                  ),
                  value: _controller.telemetryEnabled,
                  onChange: (value) => _controller.telemetryEnabled = value,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _loginStep(BuildContext context) {
    final theme = context.zhixin;
    return _page(
      context,
      stage: OnboardingStage.login,
      leading: const Align(
        alignment: Alignment.centerLeft,
        child: ZhixinMark(size: 44),
      ),
      title: '登录或注册',
      description: '登录之后可以使用知新服务的模型额度、云端备份与多设备同步。',
      children: [
        forui.FCard(
          child: Padding(
            padding: EdgeInsets.all(theme.space.lg),
            child: AccountLoginForm(
              identifier: _identifier,
              onForgotPassword: _openForgotPassword,
              // 不换空间的装配（测试）里页面不会重建，由回调推进到下一步；
              // 换空间时回调到不了这里，推进以重建之后的登录态为准。
              onSignedIn: (snapshot, {required register}) async {
                await _controller.signedIn();
              },
            ),
          ),
        ),
        SizedBox(height: theme.space.md),
        // 登录的好处写在标题下面，这里只交代不登录还能做什么，两段不重复。
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              // 图标比一行说明矮 2，下移 1 与首行文字视觉居中。
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                FLucideIcons.info,
                size: 16,
                color: theme.colors.onSurfaceVariant,
              ),
            ),
            SizedBox(width: theme.space.sm),
            Expanded(
              child: Text(
                '不登录也能用：记录、材料、查找、导出与恢复照常可用；'
                '模型提示与讲解、云同步需要登录。',
                style: theme.text.bodySmall.copyWith(
                  color: theme.colors.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _appearanceStep(BuildContext context) {
    final theme = context.zhixin;
    final scope = AppScope.of(context);
    return _page(
      context,
      stage: OnboardingStage.appearance,
      title: '选择外观',
      description: '深浅色与主题色点选立即生效，也可以跳过；之后在设置里随时可以改。',
      children: [
        forui.FCard(
          child: Padding(
            padding: EdgeInsets.all(theme.space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ZhixinSegmented<ThemeMode>(
                  selected: scope.themeMode.value,
                  onChanged: (value) =>
                      _run(() => scope.themeMode.select(value)),
                  segments: const [
                    ZhixinSegment(value: ThemeMode.system, label: '跟随系统'),
                    ZhixinSegment(value: ThemeMode.light, label: '浅色'),
                    ZhixinSegment(value: ThemeMode.dark, label: '深色'),
                  ],
                ),
                const CardDivider(),
                AccentPicker(
                  selected: scope.themeAccent.value,
                  onSelected: (accent) =>
                      _run(() => scope.themeAccent.select(accent)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
