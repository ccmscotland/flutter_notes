import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_notes/features/export/delta_converter.dart';

void main() {
  // ── toMarkdown ──────────────────────────────────────────────────────────────

  group('DeltaConverter.toMarkdown', () {
    test('plain paragraph', () {
      final ops = [
        {'insert': 'Hello world\n'},
      ];
      expect(DeltaConverter.toMarkdown(ops).trim(), 'Hello world');
    });

    test('bold inline', () {
      final ops = [
        {
          'insert': 'bold',
          'attributes': {'bold': true}
        },
        {'insert': '\n'},
      ];
      expect(DeltaConverter.toMarkdown(ops), contains('**bold**'));
    });

    test('italic inline', () {
      final ops = [
        {
          'insert': 'italic',
          'attributes': {'italic': true}
        },
        {'insert': '\n'},
      ];
      expect(DeltaConverter.toMarkdown(ops), contains('*italic*'));
    });

    test('strikethrough inline', () {
      final ops = [
        {
          'insert': 'strike',
          'attributes': {'strikethrough': true}
        },
        {'insert': '\n'},
      ];
      expect(DeltaConverter.toMarkdown(ops), contains('~~strike~~'));
    });

    test('inline code', () {
      final ops = [
        {
          'insert': 'code',
          'attributes': {'code': true}
        },
        {'insert': '\n'},
      ];
      expect(DeltaConverter.toMarkdown(ops), contains('`code`'));
    });

    test('h1 header', () {
      final ops = [
        {'insert': 'Title'},
        {
          'insert': '\n',
          'attributes': {'header': 1}
        },
      ];
      expect(DeltaConverter.toMarkdown(ops).trim(), '# Title');
    });

    test('h2 header', () {
      final ops = [
        {'insert': 'Sub'},
        {
          'insert': '\n',
          'attributes': {'header': 2}
        },
      ];
      expect(DeltaConverter.toMarkdown(ops).trim(), '## Sub');
    });

    test('bullet list', () {
      final ops = [
        {'insert': 'item'},
        {
          'insert': '\n',
          'attributes': {'list': 'bullet'}
        },
      ];
      expect(DeltaConverter.toMarkdown(ops), contains('- item'));
    });

    test('ordered list', () {
      final ops = [
        {'insert': 'first'},
        {
          'insert': '\n',
          'attributes': {'list': 'ordered'}
        },
        {'insert': 'second'},
        {
          'insert': '\n',
          'attributes': {'list': 'ordered'}
        },
      ];
      final md = DeltaConverter.toMarkdown(ops);
      expect(md, contains('1. first'));
      expect(md, contains('2. second'));
    });

    test('checked list', () {
      final ops = [
        {'insert': 'done'},
        {
          'insert': '\n',
          'attributes': {'list': 'checked'}
        },
      ];
      expect(DeltaConverter.toMarkdown(ops), contains('- [x] done'));
    });

    test('blockquote', () {
      final ops = [
        {'insert': 'quote text'},
        {
          'insert': '\n',
          'attributes': {'blockquote': true}
        },
      ];
      expect(DeltaConverter.toMarkdown(ops), contains('> quote text'));
    });

    test('hyperlink', () {
      final ops = [
        {
          'insert': 'link',
          'attributes': {'link': 'https://example.com'}
        },
        {'insert': '\n'},
      ];
      expect(DeltaConverter.toMarkdown(ops), contains('[link](https://example.com)'));
    });

    test('image embed', () {
      final ops = [
        {
          'insert': {'image': '/path/to/image.png'}
        },
      ];
      expect(DeltaConverter.toMarkdown(ops), contains('![image](/path/to/image.png)'));
    });

    test('table embed produces markdown table', () {
      final tableJson = jsonEncode([
        ['Name', 'Age'],
        ['Alice', '30'],
      ]);
      final ops = [
        {
          'insert': {'table': tableJson}
        },
      ];
      final md = DeltaConverter.toMarkdown(ops);
      expect(md, contains('| Name | Age |'));
      expect(md, contains('| Alice | 30 |'));
    });
  });

  // ── toHtml ──────────────────────────────────────────────────────────────────

  group('DeltaConverter.toHtml', () {
    test('wraps output in full HTML document', () {
      final ops = [
        {'insert': 'Hello\n'},
      ];
      final html = DeltaConverter.toHtml(ops, title: 'Test');
      expect(html, contains('<!DOCTYPE html>'));
      expect(html, contains('<title>Test</title>'));
      expect(html, contains('<p>Hello</p>'));
    });

    test('escapes HTML special characters', () {
      final ops = [
        {'insert': '<b>not bold</b> & "quoted"\n'},
      ];
      final html = DeltaConverter.toHtml(ops);
      expect(html, contains('&lt;b&gt;not bold&lt;/b&gt;'));
      expect(html, contains('&amp;'));
      expect(html, contains('&quot;quoted&quot;'));
    });

    test('h1 header', () {
      final ops = [
        {'insert': 'Head'},
        {
          'insert': '\n',
          'attributes': {'header': 1}
        },
      ];
      expect(DeltaConverter.toHtml(ops), contains('<h1>Head</h1>'));
    });

    test('bullet list produces ul/li', () {
      final ops = [
        {'insert': 'item'},
        {
          'insert': '\n',
          'attributes': {'list': 'bullet'}
        },
      ];
      final html = DeltaConverter.toHtml(ops);
      expect(html, contains('<ul>'));
      expect(html, contains('<li>item</li>'));
    });

    test('ordered list produces ol/li', () {
      final ops = [
        {'insert': 'first'},
        {
          'insert': '\n',
          'attributes': {'list': 'ordered'}
        },
      ];
      final html = DeltaConverter.toHtml(ops);
      expect(html, contains('<ol>'));
      expect(html, contains('<li>first</li>'));
    });

    test('blockquote', () {
      final ops = [
        {'insert': 'quote'},
        {
          'insert': '\n',
          'attributes': {'blockquote': true}
        },
      ];
      expect(DeltaConverter.toHtml(ops), contains('<blockquote>quote</blockquote>'));
    });

    test('code block', () {
      final ops = [
        {'insert': 'var x = 1;'},
        {
          'insert': '\n',
          'attributes': {'code-block': true}
        },
      ];
      expect(DeltaConverter.toHtml(ops), contains('<pre><code>'));
    });

    test('bold and italic inline', () {
      final ops = [
        {
          'insert': 'B',
          'attributes': {'bold': true}
        },
        {
          'insert': 'I',
          'attributes': {'italic': true}
        },
        {'insert': '\n'},
      ];
      final html = DeltaConverter.toHtml(ops);
      expect(html, contains('<strong>B</strong>'));
      expect(html, contains('<em>I</em>'));
    });
  });
}
