import 'dart:async';

class ImapPendingCommand {
  final Completer<List<String>> completer = Completer<List<String>>();
  final void Function(String continuation)? onContinuation;

  final List<String> lines = [];

  ImapPendingCommand({this.onContinuation});
}
