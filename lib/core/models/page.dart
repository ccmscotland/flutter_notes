import 'package:freezed_annotation/freezed_annotation.dart';

part 'page.freezed.dart';
part 'page.g.dart';

@freezed
class NotePage with _$NotePage {
  const factory NotePage({
    required String id,
    required String sectionId,
    String? parentPageId,
    @Default('Untitled') String title,
    @Default('[]') String content,
    required int createdAt,
    required int updatedAt,
    @Default(0) int sortOrder,
    @Default(false) bool isDeleted,
    @Default('none') String backgroundStyle,
    @Default(0)      int    backgroundColor,
    @Default(28.0)   double backgroundSpacing,
    @Default('infinite') String pageSize,
    @Default('portrait') String pageOrientation,
    @Default('') String inkStrokes,
  }) = _NotePage;

  factory NotePage.fromJson(Map<String, dynamic> json) =>
      _$NotePageFromJson(json);
}
