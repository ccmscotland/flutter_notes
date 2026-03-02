import 'package:freezed_annotation/freezed_annotation.dart';

part 'section.freezed.dart';
part 'section.g.dart';

@freezed
class Section with _$Section {
  const factory Section({
    required String id,
    required String notebookId,
    required String name,
    required int color,
    required int createdAt,
    required int updatedAt,
    @Default(0) int sortOrder,
    @Default(false) bool isDeleted,
  }) = _Section;

  factory Section.fromJson(Map<String, dynamic> json) =>
      _$SectionFromJson(json);
}
