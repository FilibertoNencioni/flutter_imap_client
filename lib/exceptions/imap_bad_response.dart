class ImapBadResponse implements Exception{
  final String serverResponse;

  ImapBadResponse(this.serverResponse);

  @override
  String toString() => "Received BAD response from IMAP server: $serverResponse";
}