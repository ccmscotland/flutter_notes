import 'dart:convert';

/// Extracts all plain text from a Quill Delta JSON string.
String deltaToPlainText(String deltaJson) {
  try {
    final ops = jsonDecode(deltaJson) as List;
    final buf = StringBuffer();
    for (final op in ops) {
      if (op is Map) {
        final insert = op['insert'];
        if (insert is String) buf.write(insert);
      }
    }
    return buf.toString();
  } catch (_) {
    return '';
  }
}

/// Counts the words in a Quill Delta JSON string.
int countWords(String deltaJson) {
  final text = deltaToPlainText(deltaJson).trim();
  if (text.isEmpty) return 0;
  return text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
}

/// Returns a human-readable reading-time string, e.g. "2 min read".
/// Assumes an average reading speed of 200 words per minute.
String readingTime(int wordCount) {
  if (wordCount == 0) return '';
  final minutes = (wordCount / 200).ceil();
  return '$minutes min read';
}
