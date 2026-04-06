import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/database/sections_dao.dart';

@immutable
class NavState {
  const NavState({this.selectedNotebookId, this.selectedSectionId});

  final String? selectedNotebookId;
  final String? selectedSectionId;

  NavState copyWith({String? selectedNotebookId, String? selectedSectionId}) =>
      NavState(
        selectedNotebookId: selectedNotebookId ?? this.selectedNotebookId,
        selectedSectionId: selectedSectionId ?? this.selectedSectionId,
      );
}

class NavStateNotifier extends Notifier<NavState> {
  @override
  NavState build() => const NavState();

  /// Selects [notebookId]. If the notebook has no user-created sections,
  /// automatically selects its hidden default section so the browse pane
  /// shows pages immediately without requiring a section tap.
  Future<void> selectNotebook(String notebookId) async {
    state = NavState(selectedNotebookId: notebookId, selectedSectionId: null);
    final dao = SectionsDao();
    final hasUser = await dao.hasUserSections(notebookId);
    if (!hasUser) {
      final defaultSection = await dao.getOrCreateDefault(notebookId);
      state = NavState(
        selectedNotebookId: notebookId,
        selectedSectionId: defaultSection.id,
      );
    }
  }

  void selectSection(String sectionId) {
    state = state.copyWith(selectedSectionId: sectionId);
  }

  void clear() => state = const NavState();
}

final navStateProvider =
    NotifierProvider<NavStateNotifier, NavState>(NavStateNotifier.new);

/// Controls whether the navigation rail and browse pane are visible (wide mode).
final navVisibleProvider = StateProvider<bool>((ref) => true);
