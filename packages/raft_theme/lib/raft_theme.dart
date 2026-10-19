/// The theme contract: what a theme may set, and how a theme pack is read.
///
/// A theme is data. This package owns the vocabulary (colour roles, numeric
/// tokens, structural options) and the `raft-theme/1` file format; it does not
/// import `raft_ui`, and it draws nothing. See `docs/theme-contract.md`.
library;

export 'src/color_value.dart';
export 'src/shadow_value.dart';
export 'src/theme_pack.dart';
