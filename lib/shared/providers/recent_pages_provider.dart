import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kRecentPages = 'recent_pages';
const _maxRecent = 10;

/// A lightweight reference to a recently-viewed page — enough to navigate and
/// display without hitting the database.
class RecentPageRef {
  final String pageId;
  final String sectionId;
  final String notebookId;
  final String title;

  const RecentPageRef({
    required this.pageId,
    required this.sectionId,
    required this.notebookId,
    required this.title,
  });

  Map<String, dynamic> toJson() => {
        'pageId': pageId,
        'sectionId': sectionId,
        'notebookId': notebookId,
        'title': title,
      };

  factory RecentPageRef.fromJson(Map<String, dynamic> m) => RecentPageRef(
        pageId: m['pageId'] as String,
        sectionId: m['sectionId'] as String,
        notebookId: m['notebookId'] as String,
        title: m['title'] as String? ?? 'Untitled',
      );
}

final recentPagesProvider =
    AsyncNotifierProvider<RecentPagesNotifier, List<RecentPageRef>>(
  RecentPagesNotifier.new,
);

class RecentPagesNotifier extends AsyncNotifier<List<RecentPageRef>> {
  @override
  Future<List<RecentPageRef>> build() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getStringList(_kRecentPages) ?? [];
    return raw
        .map((s) {
          try {
            return RecentPageRef.fromJson(
                jsonDecode(s) as Map<String, dynamic>);
          } catch (_) {
            return null;
          }
        })
        .whereType<RecentPageRef>()
        .toList();
  }

  Future<void> add(RecentPageRef ref) async {
    final current = state.valueOrNull ?? [];
    final updated = [
      ref,
      ...current.where((r) => r.pageId != ref.pageId),
    ].take(_maxRecent).toList();
    final p = await SharedPreferences.getInstance();
    await p.setStringList(
        _kRecentPages, updated.map((r) => jsonEncode(r.toJson())).toList());
    state = AsyncData(updated);
  }

  Future<void> remove(String pageId) async {
    final current = state.valueOrNull ?? [];
    final updated = current.where((r) => r.pageId != pageId).toList();
    final p = await SharedPreferences.getInstance();
    await p.setStringList(
        _kRecentPages, updated.map((r) => jsonEncode(r.toJson())).toList());
    state = AsyncData(updated);
  }
}
