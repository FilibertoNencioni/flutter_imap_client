class ImapInvalidRequest implements Exception {
  final String command;
  final List<String> capabilities;
  ImapInvalidRequest(this.command, this.capabilities);

  @override
  String toString() => "The command '$command' cannot be executed in the current IMAP context. IMAP capabilities: ${capabilities.join(", ")}.";
}