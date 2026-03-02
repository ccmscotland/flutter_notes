import 'package:flutter_riverpod/flutter_riverpod.dart';

class TabEntry {
  final String pageId;
  final String sectionId;
  final String notebookId;
  final String title;

  const TabEntry({
    required this.pageId,
    required this.sectionId,
    required this.notebookId,
    required this.title,
  });

  TabEntry copyWith({String? title}) => TabEntry(
        pageId: pageId,
        sectionId: sectionId,
        notebookId: notebookId,
        title: title ?? this.title,
      );
}

class TabsState {
  final List<TabEntry> tabs;
  final String? activePageId;

  const TabsState({this.tabs = const [], this.activePageId});

  TabsState copyWith({List<TabEntry>? tabs, String? activePageId}) => TabsState(
        tabs: tabs ?? this.tabs,
        activePageId: activePageId ?? this.activePageId,
      );

  TabsState withNoActive() =>
      TabsState(tabs: tabs, activePageId: null);
}

class TabsNotifier extends Notifier<TabsState> {
  @override
  TabsState build() => const TabsState();

  void openTab(TabEntry entry) {
    final idx = state.tabs.indexWhere((t) => t.pageId == entry.pageId);
    if (idx >= 0) {
      final updated = state.tabs[idx].copyWith(title: entry.title);
      final newTabs = List<TabEntry>.from(state.tabs)..[idx] = updated;
      state = state.copyWith(tabs: newTabs, activePageId: entry.pageId);
    } else {
      state = state.copyWith(
        tabs: [...state.tabs, entry],
        activePageId: entry.pageId,
      );
    }
  }

  /// Closes the tab and returns the entry the caller should navigate to next,
  /// or null if there are no remaining tabs.
  TabEntry? closeTab(String pageId) {
    final idx = state.tabs.indexWhere((t) => t.pageId == pageId);
    if (idx < 0) return null;

    final wasActive = state.activePageId == pageId;
    final newTabs = List<TabEntry>.from(state.tabs)..removeAt(idx);

    if (newTabs.isEmpty) {
      state = const TabsState();
      return null;
    }

    TabEntry? nextActive;
    if (wasActive) {
      nextActive = newTabs[idx > 0 ? idx - 1 : 0];
      state = TabsState(tabs: newTabs, activePageId: nextActive.pageId);
    } else {
      state = state.copyWith(tabs: newTabs);
    }
    return nextActive;
  }

  void setActive(String pageId) {
    if (state.tabs.any((t) => t.pageId == pageId)) {
      state = state.copyWith(activePageId: pageId);
    }
  }

  /// Switch to browse mode: keep all tabs alive but show the nav child instead
  /// of any editor. Sets activePageId to null.
  void goToBrowse() {
    if (state.tabs.isNotEmpty) {
      state = TabsState(tabs: state.tabs, activePageId: null);
    }
  }

  void updateTitle(String pageId, String title) {
    final idx = state.tabs.indexWhere((t) => t.pageId == pageId);
    if (idx < 0) return;
    final newTabs = List<TabEntry>.from(state.tabs)
      ..[idx] = state.tabs[idx].copyWith(title: title);
    state = state.copyWith(tabs: newTabs);
  }
}

final tabsProvider = NotifierProvider<TabsNotifier, TabsState>(
  TabsNotifier.new,
);
