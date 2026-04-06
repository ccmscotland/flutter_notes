import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../core/models/section.dart';
import '../../core/database/sections_dao.dart';

final sectionsDaoProvider = Provider<SectionsDao>((ref) => SectionsDao());

/// Returns the ID of the hidden default section for [notebookId], creating it
/// if it does not yet exist.  Used by navigation and UI to identify pages that
/// belong to no user-created section.
final defaultSectionIdProvider = FutureProvider.family<String, String>(
  (ref, notebookId) async {
    final dao = ref.read(sectionsDaoProvider);
    final s = await dao.getOrCreateDefault(notebookId);
    return s.id;
  },
);

final sectionsProvider = AsyncNotifierProviderFamily<SectionsNotifier,
    List<Section>, String>(SectionsNotifier.new);

class SectionsNotifier
    extends FamilyAsyncNotifier<List<Section>, String> {
  SectionsDao get _dao => ref.read(sectionsDaoProvider);

  @override
  Future<List<Section>> build(String notebookId) =>
      _dao.getByNotebook(notebookId);

  Future<Section> create(String name, int color) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final s = Section(
      id: const Uuid().v4(),
      notebookId: arg,
      name: name,
      color: color,
      createdAt: now,
      updatedAt: now,
    );
    await _dao.insert(s);
    ref.invalidateSelf();
    return s;
  }

  Future<void> edit(Section section) async {
    await _dao.update(section.copyWith(
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    ref.invalidateSelf();
  }

  Future<void> delete(String id) async {
    await _dao.delete(id);
    ref.invalidateSelf();
  }
}
