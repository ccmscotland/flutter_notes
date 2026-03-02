import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_notes/main.dart';

void main() {
  testWidgets('App smoke test — launches without crashing',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: FlutterNotesApp()),
    );
    await tester.pump();
    // App bar title 'Notebooks' should appear
    expect(find.text('Notebooks'), findsOneWidget);
  });
}
