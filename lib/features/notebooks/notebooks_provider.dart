import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../core/models/notebook.dart';
import '../../core/database/notebooks_dao.dart';

final notebooksDaoProvider = Provider<NotebooksDao>((ref) => NotebooksDao());

final notebooksProvider =
    AsyncNotifierProvider<NotebooksNotifier, List<Notebook>>(
  NotebooksNotifier.new,
);

class NotebooksNotifier extends AsyncNotifier<List<Notebook>> {
  NotebooksDao get _dao => ref.read(notebooksDaoProvider);

  @override
  Future<List<Notebook>> build() => _dao.getAll();

  Future<Notebook> create(String name, int color) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final nb = Notebook(
      id: const Uuid().v4(),
      name: name,
      color: color,
      createdAt: now,
      updatedAt: now,
    );
    await _dao.insert(nb);
    ref.invalidateSelf();
    return nb;
  }

  Future<void> edit(Notebook nb) async {
    await _dao.update(nb.copyWith(
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    ref.invalidateSelf();
  }

  Future<void> delete(String id) async {
    await _dao.delete(id);
    ref.invalidateSelf();
  }
}
