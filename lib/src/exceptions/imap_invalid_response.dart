class ImapInvalidResponse implements Exception{
  final String serverResponse;

  ImapInvalidResponse(this.serverResponse);

  @override
  String toString() => "Recieved invalid response from IMAP server: $serverResponse";
}