import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/page_groups_dao.dart';
import '../../core/models/page.dart';
import '../../core/models/page_group.dart';

final pageGroupsDaoProvider =
    Provider<PageGroupsDao>((ref) => PageGroupsDao());

final groupsProvider =
    AsyncNotifierProvider<GroupsNotifier, List<PageGroup>>(
  GroupsNotifier.new,
);

class GroupsNotifier extends AsyncNotifier<List<PageGroup>> {
  PageGroupsDao get _dao => ref.read(pageGroupsDaoProvider);

  @override
  Future<List<PageGroup>> build() => _dao.getAll();

  Future<PageGroup> create(String name) async {
    final g = await _dao.create(name);
    ref.invalidateSelf();
    return g;
  }

  Future<void> rename(String id, String name) async {
    await _dao.rename(id, name);
    ref.invalidateSelf();
  }

  Future<void> delete(String id) async {
    await _dao.delete(id);
    ref.invalidateSelf();
  }

  Future<void> addPage(String groupId, String pageId) =>
      _dao.addPage(groupId, pageId);

  Future<void> removePage(String groupId, String pageId) =>
      _dao.removePage(groupId, pageId);

  Future<List<String>> getPageIds(String groupId) =>
      _dao.getPageIds(groupId);

  Future<List<String>> getGroupIdsForPage(String pageId) =>
      _dao.getGroupIdsForPage(pageId);

  Future<List<NotePage>> resolvePages(String groupId) =>
      _dao.resolvePages(groupId);
}
