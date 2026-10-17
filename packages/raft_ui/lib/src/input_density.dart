import 'package:flutter/material.dart';

enum RaftDensity { desktop, touch }

/// Input density changes hit/layout bounds, never the source visual recipe.
class RaftDensityScope extends InheritedWidget {
  const RaftDensityScope({
    super.key,
    required this.density,
    required super.child,
  });
  final RaftDensity density;
  static RaftDensity of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RaftDensityScope>()?.density ??
      switch (Theme.of(context).platform) {
        TargetPlatform.android ||
        TargetPlatform.iOS ||
        TargetPlatform.fuchsia => RaftDensity.touch,
        _ => RaftDensity.desktop,
      };
  @override
  bool updateShouldNotify(RaftDensityScope oldWidget) =>
      density != oldWidget.density;
}
