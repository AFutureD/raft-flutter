import 'briefing/orb_briefing_models.dart';

/// What the layer shows while driving, apart from the deck of cards. The app
/// decides it (no model draws anything): a voice command or a tool names the
/// surface, this class holds where the person is and where "返回" goes. It has
/// no widgets and no clock, so a test can walk through it.
///
/// * deck: the briefing's cards, one at a time (the base; "返回" ends here);
/// * list: the rows of a source, [orbListPageSize] to a page;
/// * detail: one row of the list, large;
/// * (the confirm card and "就这些" are not surfaces: a pending card is drawn
///   over everything, and the end of the deck is the deck's own).

/// How many rows a page of a list has (a phone in a holder: glanced at, not
/// read).
const orbListPageSize = 4;

enum OrbSurfaceKind { deck, list, detail }

/// What a list is made of.
enum OrbListKind { unread, mentions, tasks, channel, person }

/// One row of a list: what the card shows, what the app says of it, and how it
/// opens.
class OrbListRow {
  const OrbListRow({
    required this.id,
    required this.who,
    required this.meta,
    required this.title,
    required this.fact,
    required this.say,
    this.summary = '',
    this.clipped = false,
    this.item,
    this.openArgs,
    this.canReply = false,
  });

  /// Stable across lists: the Activity row, task or message behind it.
  final String id;

  /// Who it is from (empty for a task with no owner).
  final String who;

  /// "Alice · #design": the small line over the headline.
  final String meta;

  /// The headline: one line on the card.
  final String title;

  /// The one quiet fact at the right: how long, how many unread, the state.
  final String fact;

  /// The row in a sentence of the agent's: "Alice：周五评审你来吗".
  final String say;

  /// A sentence more, for the detail (why it is here).
  final String summary;

  /// The text was cut: the detail says the whole is for when the car stops.
  final bool clipped;

  /// The briefing item behind it (opening it, replying to it).
  final OrbBriefItem? item;

  /// The `navigate` arguments that open the thing behind a row that has no
  /// briefing item (a task, a message).
  final Map<String, Object?>? openArgs;

  /// The detail offers "回复": a person asks something of the driver.
  final bool canReply;
}

/// A list of rows from one source, taken at one moment: it does not reshuffle
/// when something new comes in.
class OrbList {
  const OrbList({
    required this.kind,
    required this.rows,
    this.target = '',
    this.routine = 0,
    this.loading = false,
  });

  /// A list that is being read: placeholders on the screen.
  const OrbList.loading(this.kind, {this.target = ''})
    : rows = const [],
      routine = 0,
      loading = true;

  final OrbListKind kind;

  /// The channel or person, for those lists.
  final String target;
  final List<OrbListRow> rows;

  /// Items counted and not listed ("其余 5 条是常规进度").
  final int routine;
  final bool loading;

  int get total => rows.length;

  /// "未读 7", "点名你 2", "任务 3", "#design 6", "Cody 6".
  String get title => switch (kind) {
    OrbListKind.unread => '未读',
    OrbListKind.mentions => '点名你',
    OrbListKind.tasks => '任务',
    OrbListKind.channel => target.startsWith('#') ? target : '#$target',
    OrbListKind.person => target,
  };

  /// The heading line: the title, then the count.
  String get heading => loading ? title : '$title $total';

  /// "7 条未读": the count said.
  String get countSay => switch (kind) {
    OrbListKind.unread => '$total 条未读',
    OrbListKind.mentions => '$total 条点名你的',
    OrbListKind.tasks => '$total 个任务',
    OrbListKind.channel || OrbListKind.person => '$title 最近 $total 条',
  };

  String get _lead => switch (kind) {
    OrbListKind.unread || OrbListKind.mentions => '最急的是',
    OrbListKind.tasks => '排第一的是',
    OrbListKind.channel || OrbListKind.person => '最新的是',
  };

  /// What is said when a list appears: the total and the top one or two; the
  /// rest is for the eyes.
  String? get say {
    if (loading) return null;
    if (rows.isEmpty) {
      return switch (kind) {
        OrbListKind.unread => '没有未读的。',
        OrbListKind.mentions => '没有点名你的。',
        OrbListKind.tasks => '没有任务在你名下。',
        OrbListKind.channel || OrbListKind.person => '$title 里还没有消息。',
      };
    }
    final top = rows.take(2).map((r) => _tidy(r.say)).toList();
    final first = top.first;
    final tail = top.length > 1 ? '，还有${top[1]}' : '';
    final rest = total > 2 ? '其余看屏幕。' : '';
    return '$countSay。$_lead$first$tail。$rest';
  }
}

String _tidy(String text) => text.replaceAll(RegExp(r'[。！？.!?]+$'), '');

/// What the app says on a new page: the first one or two rows of it.
String orbPageSay(OrbList list, int page) {
  final from = page * orbListPageSize;
  final rest = list.total - from;
  final shown = list.rows.skip(from).take(2).map((r) => _tidy(r.say)).toList();
  final more = list.total - (from + orbListPageSize);
  return '还有 $rest 条：${shown.join('；')}。'
      '${more > 0 ? '后面还有 $more 条。' : '就这些了。'}';
}

/// What the app says of an opened row: who and what, how long, and whether to
/// answer.
String orbRowSay(OrbListRow row) {
  final fact = row.fact.isEmpty ? '' : '，${_waited(row.fact)}';
  return '${_tidy(row.say)}$fact。'
      '${row.summary.isEmpty ? '' : '${_tidy(row.summary)}。'}'
      '${row.clipped ? '后面还很长，停车后看。' : ''}'
      '${row.canReply ? '要回复吗？' : ''}';
}

/// "已等 20 分钟" as a clause: "已经等了 20 分钟".
String _waited(String since) {
  final s = since.trim();
  return s.startsWith('已等') ? '已经等了${s.substring(2)}' : s;
}

class _Frame {
  _Frame(this.kind, this.list, this.page, this.detail);
  final OrbSurfaceKind kind;
  final OrbList? list;
  final int page;
  final int? detail;
}

/// The surface the driving layer is on, and the way back.
class OrbDrivingSurface {
  OrbSurfaceKind _kind = OrbSurfaceKind.deck;
  OrbList? _list;
  int _page = 0;
  int? _detail;
  int? _speaking;
  final _back = <_Frame>[];
  final _marks = <String, String>{};

  OrbSurfaceKind get kind => _kind;
  bool get isDeck => _kind == OrbSurfaceKind.deck;

  /// The list on the screen (also behind a detail); null on the deck.
  OrbList? get list => _list;
  bool get loading => _list?.loading ?? false;

  /// The page of the list, counted from 0.
  int get page => _page;

  int get pageCount {
    final total = _list?.total ?? 0;
    return total == 0 ? 1 : (total + orbListPageSize - 1) ~/ orbListPageSize;
  }

  bool get hasNextPage => _list != null && _page + 1 < pageCount;

  /// The rows of the page on the screen.
  List<OrbListRow> get pageRows {
    final list = _list;
    if (list == null) return const [];
    return list.rows
        .skip(_page * orbListPageSize)
        .take(orbListPageSize)
        .toList();
  }

  /// The row the agent is talking about (an index into [OrbList.rows]); the
  /// card of it is lifted and ringed.
  int? get speaking => _speaking;

  /// The opened row (an index into [OrbList.rows]).
  int? get detailIndex => _detail;

  OrbListRow? get detailRow {
    final at = _detail;
    final rows = _list?.rows;
    return at == null || rows == null || at >= rows.length ? null : rows[at];
  }

  /// The words on a row that was dealt with ("已回复"); null while it is open.
  String? markOf(OrbListRow row) => _marks[row.id];

  /// Leaves the lists: the deck again (also when a new briefing is laid out).
  void reset() {
    _kind = OrbSurfaceKind.deck;
    _list = null;
    _page = 0;
    _detail = null;
    _speaking = null;
    _back.clear();
    _marks.clear();
  }

  void _push() => _back.add(_Frame(_kind, _list, _page, _detail));

  /// [list] takes the deck's (or the list's) place; "返回" comes back.
  void showList(OrbList list) {
    _push();
    _kind = OrbSurfaceKind.list;
    _list = list;
    _page = 0;
    _detail = null;
    _speaking = list.rows.isEmpty ? null : 0;
  }

  /// The rows of [loading] have been read: [read] is what to show, if the
  /// person is still looking at [loading] (a "返回" meanwhile drops it).
  bool resolve(OrbList loading, OrbList read) {
    if (!identical(_list, loading) || _kind != OrbSurfaceKind.list) {
      return false;
    }
    _list = read;
    _speaking = read.rows.isEmpty ? null : 0;
    return true;
  }

  /// The next page. False at the last one.
  bool nextPage() {
    if (_kind != OrbSurfaceKind.list || !hasNextPage) return false;
    _push();
    _page++;
    _speaking = _page * orbListPageSize;
    return true;
  }

  /// Which row "第 [n] 个" means: the n-th of the page on the screen, else the
  /// n-th of the whole list (said of a row on another page); null when there
  /// is none.
  int? indexOfNth(int n) {
    final list = _list;
    if (list == null || list.loading || n < 1) return null;
    final onPage = pageRows.length;
    if (n <= onPage) return _page * orbListPageSize + n - 1;
    return n <= list.total ? n - 1 : null;
  }

  /// Opens the row [index] of the list. False when there is none.
  bool openRow(int index) {
    final list = _list;
    if (list == null ||
        list.loading ||
        index < 0 ||
        index >= list.total ||
        _kind == OrbSurfaceKind.deck) {
      return false;
    }
    if (_kind == OrbSurfaceKind.list) _push();
    _kind = OrbSurfaceKind.detail;
    _detail = index;
    _page = index ~/ orbListPageSize;
    _speaking = index;
    return true;
  }

  /// The detail moves on to the next (or the one before) row. False at an end.
  bool stepDetail(int by) {
    final at = _detail;
    final list = _list;
    if (_kind != OrbSurfaceKind.detail || at == null || list == null) {
      return false;
    }
    final to = at + by;
    if (to < 0 || to >= list.total) return false;
    _detail = to;
    _page = to ~/ orbListPageSize;
    _speaking = to;
    return true;
  }

  /// Goes back to the surface before. False on the deck (nowhere to go).
  bool back() {
    if (_back.isEmpty) return false;
    final from = _detail;
    final frame = _back.removeLast();
    _kind = frame.kind;
    _list = frame.list;
    _page = frame.page;
    _detail = frame.detail;
    // The list is back with the row that was open lifted.
    _speaking =
        from ?? (_list?.rows.isEmpty ?? true ? null : _page * orbListPageSize);
    if (_kind == OrbSurfaceKind.deck) {
      _list = null;
      _speaking = null;
    }
    return true;
  }

  /// The row now open is dealt with ([label]: "已回复"): the list comes back
  /// with that card dimmed and ticked. False when no row is open.
  bool finishDetail(String label) {
    final row = detailRow;
    if (row == null) return false;
    _marks[row.id] = label;
    return back();
  }

  /// Marks [id] without moving.
  void mark(String id, String label) => _marks[id] = label;
}
