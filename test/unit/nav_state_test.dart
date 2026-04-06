import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_notes/shared/providers/nav_state_provider.dart';

void main() {
  group('NavState.copyWith', () {
    test('copies with new notebookId', () {
      const s = NavState(selectedNotebookId: 'nb1', selectedSectionId: 'sec1');
      final next = s.copyWith(selectedNotebookId: 'nb2');
      expect(next.selectedNotebookId, 'nb2');
      expect(next.selectedSectionId, 'sec1');
    });

    test('copies with new sectionId', () {
      const s = NavState(selectedNotebookId: 'nb1', selectedSectionId: 'sec1');
      final next = s.copyWith(selectedSectionId: 'sec2');
      expect(next.selectedNotebookId, 'nb1');
      expect(next.selectedSectionId, 'sec2');
    });

    test('initial state has null fields', () {
      const s = NavState();
      expect(s.selectedNotebookId, isNull);
      expect(s.selectedSectionId, isNull);
    });
  });
}
