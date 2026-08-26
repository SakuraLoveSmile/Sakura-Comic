/// Local series row mirror (multi-server safe).
class Series {
  const Series({
    required this.remoteId,
    required this.libraryId,
    required this.name,
    this.status,
    this.sortName,
    this.booksCount,
    this.booksReadCount,
    this.booksUnreadCount,
    this.booksInProgressCount,
  });

  final String remoteId;
  final String libraryId;
  final String name;
  final String? status;
  final String? sortName;
  final int? booksCount;
  final int? booksReadCount;
  final int? booksUnreadCount;
  final int? booksInProgressCount;
}
