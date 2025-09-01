class ImapNoResponse implements Exception{
  final String message;

  ImapNoResponse(this.message);

  @override
  String toString() => "Received NO response from IMAP server: $message";
}