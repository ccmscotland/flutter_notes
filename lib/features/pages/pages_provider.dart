import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../core/models/page.dart';
import '../../core/database/pages_dao.dart';

final pagesDaoProvider = Provider<PagesDao>((ref) => PagesDao());

final pagesProvider =
    AsyncNotifierProviderFamily<PagesNotifier, List<NotePage>, String>(
  PagesNotifier.new,
);

class PagesNotifier extends FamilyAsyncNotifier<List<NotePage>, String> {
  PagesDao get _dao => ref.read(pagesDaoProvider);

  @override
  Future<List<NotePage>> build(String sectionId) =>
      _dao.getBySection(sectionId);

  Future<NotePage> create({String title = 'Untitled'}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final p = NotePage(
      id: const Uuid().v4(),
      sectionId: arg,
      title: title,
      createdAt: now,
      updatedAt: now,
    );
    await _dao.insert(p);
    ref.invalidateSelf();
    return p;
  }

  Future<void> edit(NotePage page) async {
    await _dao.update(page.copyWith(
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    ref.invalidateSelf();
  }

  Future<void> delete(String id) async {
    await _dao.delete(id);
    ref.invalidateSelf();
  }
}

// Single-page provider used by editor
final pageProvider =
    FutureProvider.family<NotePage?, String>((ref, pageId) async {
  final dao = ref.read(pagesDaoProvider);
  return dao.getById(pageId);
});
