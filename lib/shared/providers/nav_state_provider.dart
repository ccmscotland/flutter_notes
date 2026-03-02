import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  void selectNotebook(String notebookId) {
    // Selecting a new notebook clears any previously selected section.
    state = NavState(selectedNotebookId: notebookId, selectedSectionId: null);
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
