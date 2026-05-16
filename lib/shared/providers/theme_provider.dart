import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kThemeMode = 'theme_mode';

final themeProvider =
    AsyncNotifierProvider<ThemeNotifier, ThemeMode>(ThemeNotifier.new);

class ThemeNotifier extends AsyncNotifier<ThemeMode> {
  @override
  Future<ThemeMode> build() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString(_kThemeMode) ?? 'system';
    return ThemeMode.values.firstWhere(
      (m) => m.name == saved,
      orElse: () => ThemeMode.system,
    );
  }

  Future<void> toggle() async {
    final current = state.valueOrNull ?? ThemeMode.system;
    final ThemeMode next;
    if (current == ThemeMode.system) {
      final platformBrightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      next = platformBrightness == Brightness.dark
          ? ThemeMode.light
          : ThemeMode.dark;
    } else {
      next = current == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    }
    final p = await SharedPreferences.getInstance();
    await p.setString(_kThemeMode, next.name);
    state = AsyncData(next);
  }
}
