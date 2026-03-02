import 'package:flutter/widgets.dart';

const double kPhoneBreakpoint   = 600.0;
const double kDesktopBreakpoint = 900.0;
const double kRailCollapsed     = 72.0;
const double kRailExpanded      = 200.0;
const double kBrowsePaneWidth   = 280.0;

enum LayoutMode { phone, tablet, desktop }

class ResponsiveLayout {
  const ResponsiveLayout._({required this.mode, required this.width});

  final LayoutMode mode;
  final double width;

  bool get isPhone        => mode == LayoutMode.phone;
  bool get isWide         => mode != LayoutMode.phone;
  bool get isRailExpanded => mode == LayoutMode.desktop;

  /// Adaptive grid column count for the notebooks grid.
  int adaptiveGridColumns() {
    if (width < 750)  return 2;
    if (width < 1050) return 3;
    if (width < 1350) return 4;
    return 5;
  }

  static ResponsiveLayout of(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final mode  = width < kPhoneBreakpoint
        ? LayoutMode.phone
        : width < kDesktopBreakpoint
            ? LayoutMode.tablet
            : LayoutMode.desktop;
    return ResponsiveLayout._(mode: mode, width: width);
  }
}
