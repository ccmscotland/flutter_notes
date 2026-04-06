import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_notes/shared/providers/starred_pages_provider.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer makeContainer() => ProviderContainer();

  group('StarredPagesNotifier', () {
    test('initial state is empty', () async {
      final c = makeContainer();
      addTearDown(c.dispose);
      final starred = await c.read(starredPagesProvider.future);
      expect(starred, isEmpty);
    });

    test('toggle adds an unstarred page', () async {
      final c = makeContainer();
      addTearDown(c.dispose);
      await c.read(starredPagesProvider.notifier).toggle('p1');
      expect(c.read(starredPagesProvider).value, contains('p1'));
    });

    test('toggle removes an already-starred page', () async {
      final c = makeContainer();
      addTearDown(c.dispose);
      final notifier = c.read(starredPagesProvider.notifier);
      await notifier.toggle('p1');
      await notifier.toggle('p1'); // un-star
      expect(c.read(starredPagesProvider).value, isNot(contains('p1')));
    });

    test('isStarred returns correct value', () async {
      final c = makeContainer();
      addTearDown(c.dispose);
      // Must load the provider first
      await c.read(starredPagesProvider.future);
      final notifier = c.read(starredPagesProvider.notifier);
      expect(notifier.isStarred('p1'), isFalse);
      await notifier.toggle('p1');
      expect(notifier.isStarred('p1'), isTrue);
    });

    test('multiple pages can be starred simultaneously', () async {
      final c = makeContainer();
      addTearDown(c.dispose);
      final notifier = c.read(starredPagesProvider.notifier);
      await notifier.toggle('p1');
      await notifier.toggle('p2');
      await notifier.toggle('p3');
      final starred = c.read(starredPagesProvider).value!;
      expect(starred, containsAll(['p1', 'p2', 'p3']));
    });

    test('starred state persists across containers', () async {
      {
        final c = makeContainer();
        await c.read(starredPagesProvider.notifier).toggle('p1');
        c.dispose();
      }
      {
        final c = makeContainer();
        addTearDown(c.dispose);
        final starred = await c.read(starredPagesProvider.future);
        expect(starred, contains('p1'));
      }
    });
  });
}
