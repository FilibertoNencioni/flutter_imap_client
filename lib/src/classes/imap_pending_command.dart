import 'dart:async';

class ImapPendingCommand {
  final Completer<List<String>> completer = Completer<List<String>>();
  final List<String> lines = [];
}
