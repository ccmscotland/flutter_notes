import 'package:go_router/go_router.dart';
import 'features/notebooks/notebooks_screen.dart';
import 'features/sections/sections_screen.dart';
import 'features/pages/pages_screen.dart';
import 'features/editor/editor_screen.dart';
import 'features/search/search_screen.dart';
import 'features/sync/sync_settings_screen.dart';
import 'shared/widgets/app_shell.dart';

final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    ShellRoute(
      builder: (context, state, child) => AppShell(child: child),
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => const NotebooksScreen(),
        ),
        GoRoute(
          path: '/notebook/:nid',
          builder: (_, state) =>
              SectionsScreen(notebookId: state.pathParameters['nid']!),
        ),
        GoRoute(
          path: '/notebook/:nid/section/:sid',
          builder: (_, state) => PagesScreen(
            notebookId: state.pathParameters['nid']!,
            sectionId: state.pathParameters['sid']!,
          ),
        ),
        GoRoute(
          path: '/notebook/:nid/section/:sid/page/:pid',
          builder: (_, state) => EditorScreen(
            notebookId: state.pathParameters['nid']!,
            sectionId: state.pathParameters['sid']!,
            pageId: state.pathParameters['pid']!,
          ),
        ),
        GoRoute(
          path: '/search',
          builder: (_, __) => const SearchScreen(),
        ),
        GoRoute(
          path: '/settings/sync',
          builder: (_, __) => const SyncSettingsScreen(),
        ),
      ],
    ),
  ],
);
