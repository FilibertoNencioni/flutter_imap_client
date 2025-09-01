import 'package:flutter_imap_client/src/enums/imap_state.dart';

class ImapCommandBadState implements Exception {
  final String command;
  final ImapState currentState;
  final ImapState expectedState;

  ImapCommandBadState({
    required this.command,
    required this.currentState,
    required this.expectedState,
  });

  @override
  String toString() {
    return 'Command "$command" cannot be executed in state "$currentState". Expected state: "$expectedState".';
  }
}