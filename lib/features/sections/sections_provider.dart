import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../core/models/section.dart';
import '../../core/database/sections_dao.dart';

final sectionsDaoProvider = Provider<SectionsDao>((ref) => SectionsDao());

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
