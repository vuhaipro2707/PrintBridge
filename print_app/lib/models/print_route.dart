class PrintRoute {
  final String id;
  final String name;
  final int pendingCount;

  const PrintRoute({
    required this.id,
    required this.name,
    required this.pendingCount,
  });

  factory PrintRoute.fromJson(Map<String, dynamic> json) {
    return PrintRoute(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? json['id'] ?? '').toString(),
      pendingCount: (json['pending_count'] as num?)?.toInt() ?? 0,
    );
  }
}
