/// A failure with an HTTP status, answered as `{error, message}` JSON.
class ApiError implements Exception {
  ApiError(this.status, this.code, [this.message]);
  final int status;
  final String code;
  final String? message;
}
