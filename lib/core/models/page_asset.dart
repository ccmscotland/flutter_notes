import 'package:freezed_annotation/freezed_annotation.dart';

part 'page_asset.freezed.dart';
part 'page_asset.g.dart';

@freezed
class PageAsset with _$PageAsset {
  const factory PageAsset({
    required String id,
    required String pageId,
    required String fileName,
    required String localPath,
    required String mimeType,
    required int createdAt,
  }) = _PageAsset;

  factory PageAsset.fromJson(Map<String, dynamic> json) =>
      _$PageAssetFromJson(json);
}
