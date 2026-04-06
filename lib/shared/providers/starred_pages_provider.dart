import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kStarredPages = 'starred_pages';

final starredPagesProvider =
    AsyncNotifierProvider<StarredPagesNotifier, Set<String>>(
  StarredPagesNotifier.new,
);

class StarredPagesNotifier extends AsyncNotifier<Set<String>> {
  @override
  Future<Set<String>> build() async {
    final p = await SharedPreferences.getInstance();
    return (p.getStringList(_kStarredPages) ?? []).toSet();
  }

  bool isStarred(String pageId) =>
      state.valueOrNull?.contains(pageId) ?? false;

  Future<void> toggle(String pageId) async {
    final current = {...(state.valueOrNull ?? {})};
    if (current.contains(pageId)) {
      current.remove(pageId);
    } else {
      current.add(pageId);
    }
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_kStarredPages, current.toList());
    state = AsyncData(current);
  }
}
