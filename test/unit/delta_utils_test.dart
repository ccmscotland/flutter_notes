import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_notes/features/editor/delta_utils.dart';

void main() {
  group('deltaToPlainText', () {
    test('extracts text from string inserts', () {
      final ops = [
        {'insert': 'Hello '},
        {'insert': 'world'},
        {'insert': '\n'},
      ];
      expect(deltaToPlainText(jsonEncode(ops)), 'Hello world\n');
    });

    test('ignores embed ops', () {
      final ops = [
        {'insert': 'before'},
        {
          'insert': {'image': '/path/to/img.png'}
        },
        {'insert': 'after'},
      ];
      expect(deltaToPlainText(jsonEncode(ops)), 'beforeafter');
    });

    test('returns empty string for empty delta', () {
      expect(deltaToPlainText('[]'), '');
    });

    test('returns empty string for invalid JSON', () {
      expect(deltaToPlainText('not-json'), '');
    });

    test('handles multiple paragraphs', () {
      final ops = [
        {'insert': 'Line one\nLine two\n'},
      ];
      expect(deltaToPlainText(jsonEncode(ops)), 'Line one\nLine two\n');
    });
  });

  group('countWords', () {
    test('counts words separated by spaces', () {
      final ops = [
        {'insert': 'one two three\n'},
      ];
      expect(countWords(jsonEncode(ops)), 3);
    });

    test('returns 0 for empty delta', () {
      expect(countWords('[]'), 0);
    });

    test('returns 0 for whitespace-only content', () {
      final ops = [
        {'insert': '   \n  '},
      ];
      expect(countWords(jsonEncode(ops)), 0);
    });

    test('handles multiple spaces between words', () {
      final ops = [
        {'insert': 'a   b   c\n'},
      ];
      expect(countWords(jsonEncode(ops)), 3);
    });
  });

  group('readingTime', () {
    test('returns empty string for 0 words', () {
      expect(readingTime(0), '');
    });

    test('returns 1 min read for < 200 words', () {
      expect(readingTime(100), '1 min read');
    });

    test('returns 1 min read for exactly 200 words', () {
      expect(readingTime(200), '1 min read');
    });

    test('returns 2 min read for 201 words', () {
      expect(readingTime(201), '2 min read');
    });

    test('returns correct minutes for large count', () {
      expect(readingTime(600), '3 min read');
    });
  });
}
