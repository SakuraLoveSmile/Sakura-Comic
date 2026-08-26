/// Local series row mirror (multi-server safe).
class Series {
  const Series({
    required this.remoteId,
    required this.libraryId,
    required this.name,
    this.status,
  });

  final String remoteId;
  final String libraryId;
  final String name;
  final String? status;
}
