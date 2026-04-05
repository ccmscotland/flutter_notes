/// A named collection of pages that can span notebooks and sections.
class PageGroup {
  final String id;
  final String name;
  final int createdAt;

  const PageGroup({
    required this.id,
    required this.name,
    required this.createdAt,
  });

  PageGroup copyWith({String? name}) => PageGroup(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
      );
}
