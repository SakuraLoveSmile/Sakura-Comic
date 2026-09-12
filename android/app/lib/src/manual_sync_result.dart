/// Outcome of a user-triggered sync, kept distinct from a completed request.
enum ManualSyncStatus { success, failed, notRun }

class ManualSyncResult {
  const ManualSyncResult({
    required this.status,
    this.message,
    this.error,
  });

  const ManualSyncResult.success({String? message})
      : this(status: ManualSyncStatus.success, message: message);

  const ManualSyncResult.failed(Object error, {String? message})
      : this(status: ManualSyncStatus.failed, message: message, error: error);

  const ManualSyncResult.notRun({String? message})
      : this(status: ManualSyncStatus.notRun, message: message);

  final ManualSyncStatus status;
  final String? message;
  final Object? error;

  bool get isSuccess => status == ManualSyncStatus.success;
}
