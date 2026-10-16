// Offline gallery of the Raft UI hands-free design system: the four screens
// of the design review (a attention, b generated list, c detail, d confirm),
// built only from the hands-free components with invented sample data.
//
//   tool/flutter run -d linux -t integration_test/handsfree_gallery_main.dart \
//     --dart-define=HF_SCREEN=a|b|c|d|all --dart-define=HF_SURFACE=phone|desktop|tv
//
// Or the same names as environment variables (HF_SCREEN, HF_SURFACE). Without
// HF_SURFACE the surface follows the window size (a TV is only ever forced).
// `all` shows a, b, c, d in turn (HF_STEP_MS each, default 3000) and appends
// the name of each screen, once it is drawn, to the file HF_MARKS (else it
// prints `HF_MARK <name>`), for a screenshot harness.
import 'dart:async';
import 'dart:io' show File, FileMode, Platform;

import 'package:flutter/material.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_ui/raft_ui.dart';

String _setting(String name, String fallback) {
  final env = Platform.environment[name];
  if (env != null && env.isNotEmpty) return env;
  return switch (name) {
    'HF_SCREEN' => const String.fromEnvironment('HF_SCREEN'),
    'HF_SURFACE' => const String.fromEnvironment('HF_SURFACE'),
    'HF_STEP_MS' => const String.fromEnvironment('HF_STEP_MS'),
    _ => '',
  }.ifEmpty(fallback);
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final surface = switch (_setting('HF_SURFACE', '')) {
    'phone' => HfSurface.phone,
    'desktop' => HfSurface.desktop,
    'tv' => HfSurface.tv,
    _ => null,
  };
  runApp(
    _Gallery(
      screens: _setting('HF_SCREEN', 'all') == 'all'
          ? const ['a', 'b', 'c', 'd']
          : _setting('HF_SCREEN', 'a').split(','),
      surface: surface,
      step: Duration(
        milliseconds: int.tryParse(_setting('HF_STEP_MS', '3000')) ?? 3000,
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Sample data. Invented: nothing here is a real person, task or channel.
// ---------------------------------------------------------------------------

class _Ask {
  const _Ask({
    required this.tone,
    required this.channel,
    required this.reason,
    required this.headline,
    required this.waited,
    required this.unit,
    this.idle = false,
    this.detail,
    this.badge,
  });
  final HfTone tone;
  final String channel, reason, headline, unit, waited;
  final String? detail, badge;
  final bool idle;
}

const _asks = [
  _Ask(
    tone: HfTone.decision,
    channel: 'app-dev',
    reason: '等你验收',
    headline: '#12 修复登录跳转',
    waited: '3',
    unit: '天',
    detail: 'Bo 做完了，附 2 条进展',
    badge: '最急',
  ),
  _Ask(
    tone: HfTone.decision,
    channel: 'release',
    reason: '要你批准',
    headline: '批准 Cleo 发布 v1.4',
    waited: '5',
    unit: '时',
    detail: '改动 3 处，已过测试',
  ),
  _Ask(
    tone: HfTone.blocked,
    channel: 'data',
    reason: '卡住了',
    headline: '#9 导出报表',
    waited: '2',
    unit: '天',
    idle: true,
    detail: 'Dex 缺一份数据权限',
  ),
  _Ask(
    tone: HfTone.mention,
    channel: 'design',
    reason: '点名你',
    headline: 'Aria 点了你',
    waited: '20',
    unit: '分',
    detail: '评审里问配色选哪版',
  ),
];

const _sectionNames = {
  HfTone.decision: '等你决定',
  HfTone.blocked: '卡住了',
  HfTone.mention: '点名你',
};

class _Agent {
  const _Agent(this.name, this.status, this.tone, this.fact);
  final String name, status, fact;
  final HfTone tone;
}

const _agents = [
  _Agent('Aria', '进行中 · 18 分钟', HfTone.progress, '#14 整理接口文档'),
  _Agent('Bo', '等你决定 · 3 天', HfTone.decision, '#12 修复登录跳转'),
  _Agent('Cleo', '进行中 · 1 小时', HfTone.progress, '#15 准备 v1.4 发布'),
  _Agent('Dex', '卡住了 · 2 天', HfTone.blocked, '#9 导出报表'),
  _Agent('Eli', '空闲', HfTone.info, '最近完成 #11 清理日志'),
  _Agent('Fay', '进行中 · 6 分钟', HfTone.progress, '#16 回复用户反馈'),
  _Agent('Gus', '空闲', HfTone.info, '最近完成 #8 更新图标'),
];

const _facts = [
  HfFact('谁', 'Bo'),
  HfFact('哪', '#app-dev'),
  HfFact('多久', '已等 3 天'),
];

const _progress = [
  HfProgressLine('10:32', 'Bo', '修复已提交，等你验收'),
  HfProgressLine('09:10', 'Bo', '跳转逻辑改完，补了两条测试'),
  HfProgressLine('昨天', 'Aria', '复现了问题，原因在回调'),
];

// ---------------------------------------------------------------------------

class _Gallery extends StatefulWidget {
  const _Gallery({
    required this.screens,
    required this.surface,
    required this.step,
  });
  final List<String> screens;
  final HfSurface? surface;
  final Duration step;

  @override
  State<_Gallery> createState() => _GalleryState();
}

class _GalleryState extends State<_Gallery> {
  final _spotlight = AgentSpotlightController();
  final _marks = AgentMarkController();
  int _at = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  void _mark(String name) {
    final file = Platform.environment['HF_MARKS'];
    if (file == null) {
      debugPrint('HF_MARK $name');
    } else {
      File(
        file,
      ).writeAsStringSync('$name\n', mode: FileMode.append, flush: true);
    }
  }

  Future<void> _run() async {
    // Let the first frame and the fonts settle before the first mark.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    for (var i = 0; i < widget.screens.length; i++) {
      if (!mounted) return;
      setState(() => _at = i);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      _mark(widget.screens[i]);
      if (widget.screens.length == 1) return;
      await Future<void>.delayed(widget.step);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.screens[_at];
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: raftTheme(RaftFamily.brutal),
      home: Scaffold(
        body: AgentMarks(
          controller: _marks,
          child: AgentSpotlight(
            controller: _spotlight,
            child: HandsFree(
              surface: widget.surface,
              child: switch (name) {
                'b' => const _ListScreen(),
                'c' => const _DetailScreen(),
                'd' => const _ConfirmScreen(),
                _ => const _AttentionScreen(),
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// The caption strip and dock every screen ends with. The mood sits in the
/// dock where there is one, in the strip where there is none (a TV).
({Widget caption, Widget dock}) _foot(HfData hf, String say, String mood) => (
  caption: HfCaptionStrip(caption: say, mood: hf.interactive ? null : mood),
  dock: HfDock(mood: mood),
);

HfCountLine _askCounts() => HfCountLine(
  counts: [
    for (final t in [HfTone.decision, HfTone.blocked])
      HfCount(
        t,
        _asks.where((a) => a.tone == t).length,
        '件${_sectionNames[t]}',
      ),
  ],
);

// a. 注意力 -----------------------------------------------------------------

class _AttentionScreen extends StatelessWidget {
  const _AttentionScreen();

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final shown = _asks.take(hf.attentionRows).toList();
    final foot = _foot(hf, '先看第一件：Bo 做完了 #12，要验收吗？', '🤔');
    final rows = <Widget>[];
    for (var i = 0; i < shown.length; i++) {
      final a = shown[i];
      if (i == 0 || a.tone != shown[i - 1].tone) {
        if (i > 0) rows.add(SizedBox(height: hf.sp(10)));
        rows.add(
          HfSectionLabel(
            _sectionNames[a.tone]!,
            tone: a.tone,
            count: _asks.where((x) => x.tone == a.tone).length,
          ),
        );
        rows.add(SizedBox(height: hf.sp(8)));
      } else {
        rows.add(SizedBox(height: hf.rowGap));
      }
      rows.add(
        HfRow(
          index: i + 1,
          tone: a.tone,
          focusId: 'attention#${i + 1}',
          onTap: hf.interactive ? () {} : null,
          selected: hf.split && i == 0,
          badge: a.badge,
          meta: '#${a.channel} · ${a.reason}',
          title: a.headline,
          detail: a.detail,
          stat: HfStatBlock(
            label: a.idle ? '没动' : '已等',
            value: a.waited,
            unit: a.unit,
          ),
        ),
      );
    }
    if (_asks.length > shown.length) {
      rows.add(SizedBox(height: hf.sp(12)));
      rows.add(
        HfPager(from: 1, to: shown.length, total: _asks.length, onNext: () {}),
      );
    }
    final list = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
    return HfScreen(
      header: HfHeader(title: '现在需要你', count: _askCounts()),
      body: hf.split
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 53, child: list),
                SizedBox(width: hf.sp(28)),
                Expanded(
                  flex: 47,
                  child: HfDetail(
                    titleMode: HfDetailTitle.heading,
                    title: '#12 修复登录跳转',
                    status: '#app-dev · 等你验收',
                    tone: HfTone.decision,
                    facts: _facts,
                    progress: _progress.take(2).toList(),
                    actions: _actions(),
                  ),
                ),
              ],
            )
          : list,
      caption: foot.caption,
      dock: foot.dock,
    );
  }
}

List<HfAction> _actions() => [
  HfAction(
    '通过',
    kind: HfActionKind.primary,
    icon: Icons.check_rounded,
    onPressed: () {},
    focusId: 'detail#approve',
  ),
  HfAction('打开讨论', onPressed: () {}, focusId: 'detail#discuss'),
  HfAction('稍后', kind: HfActionKind.text, onPressed: () {}),
];

// b. 生成的列表 ---------------------------------------------------------------

class _ListScreen extends StatelessWidget {
  const _ListScreen();

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final shown = _agents.take(hf.listRows).toList();
    final foot = _foot(hf, 'Dex 卡住了，Bo 在等你。', '😮');
    int n(HfTone t) => _agents.where((a) => a.tone == t).length;
    return HfScreen(
      header: HfHeader(
        title: '所有 Agent 在做什么',
        phoneHint: false,
        count: HfCountLine(
          counts: [
            HfCount(HfTone.progress, n(HfTone.progress), '个在忙'),
            HfCount(
              HfTone.decision,
              n(HfTone.decision) + n(HfTone.blocked),
              '个要你管',
            ),
          ],
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < shown.length; i++) ...[
            if (i > 0) SizedBox(height: hf.rowGap),
            HfEntityRow(
              index: i + 1,
              tone: shown[i].tone,
              focusId: 'agents#${i + 1}',
              onTap: hf.interactive ? () {} : null,
              status: shown[i].status,
              title: shown[i].name,
              detail: shown[i].fact,
            ),
          ],
          SizedBox(height: hf.sp(hf.phone ? 12 : 6)),
          HfPager(
            from: 1,
            to: shown.length,
            total: _agents.length,
            onNext: () {},
          ),
        ],
      ),
      caption: foot.caption,
      dock: foot.dock,
    );
  }
}

// c. 详情 --------------------------------------------------------------------

class _DetailScreen extends StatelessWidget {
  const _DetailScreen();

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final foot = _foot(hf, '修复已提交，现在通过吗？', '😊');
    return HfScreen(
      header: const HfHeader(title: '#12 修复登录跳转', phoneHint: false),
      body: HfDetail(
        titleMode: HfDetailTitle.none,
        title: '#12 修复登录跳转',
        status: '等你验收',
        tone: HfTone.decision,
        facts: _facts,
        progress: _progress,
        actions: _actions(),
      ),
      caption: foot.caption,
      dock: foot.dock,
    );
  }
}

// d. 确认卡 -------------------------------------------------------------------

class _ConfirmScreen extends StatelessWidget {
  const _ConfirmScreen();

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final foot = _foot(hf, '指派给 Bo 吗？说“对”就行。', '🙂');
    return HfScreen(
      header: const HfHeader(title: '确认一下'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.only(bottom: hf.sp(22)),
            child: HfRow(
              index: 1,
              tone: HfTone.info,
              focusId: 'confirm#1',
              meta: '#app-dev · 任务 · 没人负责',
              title: '#12 修复登录跳转',
              detail: '创建于 3 天前',
            ),
          ),
          HfConfirm(
            message: '将把 #12 指派给 Bo —— 确认？',
            onConfirm: () {},
            onCancel: () {},
            focusId: 'confirm#2',
          ),
        ],
      ),
      caption: foot.caption,
      dock: foot.dock,
    );
  }
}
