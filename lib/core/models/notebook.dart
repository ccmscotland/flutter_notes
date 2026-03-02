import 'package:freezed_annotation/freezed_annotation.dart';

part 'notebook.freezed.dart';
part 'notebook.g.dart';

@freezed
class Notebook with _$Notebook {
  const factory Notebook({
    required String id,
    required String name,
    required int color,
    String? icon,
    required int createdAt,
    required int updatedAt,
    @Default(0) int sortOrder,
    @Default(false) bool isDeleted,
  }) = _Notebook;

  factory Notebook.fromJson(Map<String, dynamic> json) =>
      _$NotebookFromJson(json);
}
