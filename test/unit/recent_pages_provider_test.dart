import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_notes/shared/providers/recent_pages_provider.dart';

RecentPageRef _ref(String id, {String title = 'Page'}) => RecentPageRef(
      pageId: id,
      sectionId: 'sec',
      notebookId: 'nb',
      title: title,
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer makeContainer() => ProviderContainer();

  group('RecentPagesNotifier', () {
    test('initial state is empty', () async {
      final c = makeContainer();
      addTearDown(c.dispose);
      final pages = await c.read(recentPagesProvider.future);
      expect(pages, isEmpty);
    });

    test('add inserts page at the front', () async {
      final c = makeContainer();
      addTearDown(c.dispose);
      await c.read(recentPagesProvider.notifier).add(_ref('p1'));
      final pages = c.read(recentPagesProvider).value!;
      expect(pages.first.pageId, 'p1');
    });

    test('add deduplicates — same page moves to front', () async {
      final c = makeContainer();
      addTearDown(c.dispose);
      final notifier = c.read(recentPagesProvider.notifier);
      await notifier.add(_ref('p1'));
      await notifier.add(_ref('p2'));
      await notifier.add(_ref('p1')); // re-add p1
      final pages = c.read(recentPagesProvider).value!;
      expect(pages.first.pageId, 'p1');
      expect(pages.length, 2); // no duplicate
    });

    test('add enforces maximum of 10 entries', () async {
      final c = makeContainer();
      addTearDown(c.dispose);
      final notifier = c.read(recentPagesProvider.notifier);
      for (var i = 0; i < 12; i++) {
        await notifier.add(_ref('p$i'));
      }
      final pages = c.read(recentPagesProvider).value!;
      expect(pages.length, 10);
      expect(pages.first.pageId, 'p11'); // most recent first
    });

    test('remove deletes the page from the list', () async {
      final c = makeContainer();
      addTearDown(c.dispose);
      final notifier = c.read(recentPagesProvider.notifier);
      await notifier.add(_ref('p1'));
      await notifier.add(_ref('p2'));
      await notifier.remove('p1');
      final pages = c.read(recentPagesProvider).value!;
      expect(pages.map((p) => p.pageId), isNot(contains('p1')));
      expect(pages.length, 1);
    });

    test('remove of unknown id is a no-op', () async {
      final c = makeContainer();
      addTearDown(c.dispose);
      final notifier = c.read(recentPagesProvider.notifier);
      await notifier.add(_ref('p1'));
      await notifier.remove('no-such-id');
      expect(c.read(recentPagesProvider).value!.length, 1);
    });

    test('state persists across provider reloads (SharedPreferences)', () async {
      // Add using one container
      {
        final c = makeContainer();
        await c.read(recentPagesProvider.notifier).add(_ref('p1', title: 'Persisted'));
        c.dispose();
      }
      // New container reads from the same SharedPreferences mock
      {
        final c = makeContainer();
        addTearDown(c.dispose);
        final pages = await c.read(recentPagesProvider.future);
        expect(pages.first.pageId, 'p1');
        expect(pages.first.title, 'Persisted');
      }
    });
  });
}
