class FTPUnknownCommandException implements Exception {
  final String message;

  const FTPUnknownCommandException(this.message);

  @override
  String toString() => message;
}
