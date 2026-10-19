import 'raft_pack.g.dart';
import 'theme_pack.dart';

/// The built-in Raft theme, parsed from the compile-time constant.
///
/// Synchronous on purpose: the first frame must already be themed, and reading
/// the same pack from an asset is async — a frame painted before it lands is the
/// theme flash `docs/theme-flash.md` describes. The asset of the same name
/// exists for tooling and for anyone who wants to start from a copy.
RaftThemePack? _raft;

RaftThemePack get builtInRaftTheme =>
    _raft ??= RaftThemePack.parse(raftThemePackJson, origin: 'raft');
