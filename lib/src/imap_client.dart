import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_imap_client/src/classes/imap_pending_command.dart';
import 'package:flutter_imap_client/src/enums/imap_state.dart';
import 'package:flutter_imap_client/src/exceptions/imap_bad_response.dart';
import 'package:flutter_imap_client/src/exceptions/imap_command_bad_state.dart';
import 'package:flutter_imap_client/src/exceptions/imap_invalid_response.dart';
import 'package:flutter_imap_client/src/exceptions/imap_no_response.dart';

//**
//  DOCS!
//  https://www.ietf.org/rfc/rfc9051.html
//  https://datatracker.ietf.org/doc/html/rfc1730#section-6
// */

class ImapClient {
  /// Imap server host
  final String host;

  /// Imap server port
  final int port;
  
  /// The current state of the IMAP client.
  ImapState state = ImapState.nonAuthenticated;

  /// The socket used for communication with the IMAP server.
  Socket? socket;

  /// Stores pending commands by tag
  final Map<String, ImapPendingCommand> _pending = {};

  /// Completer for the initial greeting from the server.
  final Completer<bool> _greetingCompleter = Completer<bool>();

  /// TCP data buffer for line parsing
  final StringBuffer _buffer = StringBuffer();

  /// Is TLS processing (no commands can be sent)
  bool _isTslProcessing = false;



  ImapClient({required this.host, required this.port});

  /// Generates a unique tag for the IMAP command.
  String _generateUniqueTag(){
    String strTag = "";
    int numTag = 0;
    do{
      numTag++;
      strTag = numTag.toRadixString(16).padLeft(4, '0'). toUpperCase();
    }while(_pending.containsKey(strTag));

    return strTag;
  }


  /// Handle a single IMAP line
  void _handleLine(String line) {
    if (line.isEmpty) return;

    print("SERVER: $line");

    // Untagged response
    if (line.startsWith("*")) {
      // Append to all pending commands (they may all care about untagged updates)
      for (var pending in _pending.values) {
        pending.lines.add(line);
      }
      return;
    }

    // Tagged response
    String tag = line.split(" ")[0];
    if (_pending.containsKey(tag)) {
      var pending = _pending[tag]!;
      pending.lines.add(line); // include final tagged line
      pending.completer.complete(pending.lines);
      _pending.remove(tag);
    }
  }


  /// Handles incoming data from the server.
  void _onResponse(Uint8List data) {
    String chunk = String.fromCharCodes(data);

    //CHECKS FOR GREETING (only once)
    if(!_greetingCompleter.isCompleted){
      _greetingCompleter.complete(chunk.startsWith("* OK"));
    }


    _buffer.write(chunk);

    String buffered = _buffer.toString();
    int index;
    while ((index = buffered.indexOf("\r\n")) != -1) {
      String line = buffered.substring(0, index);
      buffered = buffered.substring(index + 2);
      _handleLine(line.trim());
    }

    _buffer
      ..clear()
      ..write(buffered);
  }


  /// Sends a command and returns a Future that completes when the tagged response arrives
  Future<List<String>> _sendCommand(String command) async {
    if (socket == null) {
      throw Exception("Socket is not connected.");
    } else if (_isTslProcessing && command != "STARTTLS") {
      throw Exception("Cannot send commands while TLS processing is active.");
    }

    String tag = _generateUniqueTag();
    var pending = ImapPendingCommand();
    _pending[tag] = pending;

    String fullCommand = "$tag $command\r\n";
    print("\nCLIENT: $tag $command");
    socket!.write(fullCommand);

    // Wait for the response
    var response = await pending.completer.future;


    //Checks for OK
    if(response.isEmpty){
      throw ImapInvalidResponse("");
    }else{
      List<String> lastLineFragments = response.last.split(" ");
      if(lastLineFragments.length < 2){
        throw ImapInvalidResponse(response.last);
      }else if(lastLineFragments[1] == "BAD"){
        throw ImapBadResponse(response.last);
      }else if(lastLineFragments[1] == "NO"){
        throw ImapNoResponse(response.last);
      }
    }
    return response;

  }


  /// Connects to the IMAP server.
  Future connect() async {
    socket = await Socket.connect(host, port);
    socket!.listen(_onResponse);

    
    // Checks for OK response
    bool isGreetingOk = await _greetingCompleter.future;

    if(!isGreetingOk){
      print("****Unable to connect to IMAP server****");
      socket!.close();
      return;
    }else {
      print("****Connected to IMAP server****");
    }

  }

  Future<bool> disconnect() async {
    try{
      await _sendCommand("LOGOUT");
      socket!.close();
      socket = null;
      return true;
    } on Exception catch(e){
      print("****Error while disconnecting: $e****");
      return false;
    }
  }


  //#region Commands

  //#region ANY STATES COMMANDS

  /// Returns the capabilities of the IMAP server.
  /// 
  /// https://www.ietf.org/rfc/rfc9051.html#name-capability-command
  Future<List<String>> capability() async => _sendCommand("CAPABILITY");

  /// Does nothing, used to keep the connection alive and checks for changes.
  /// 
  /// https://www.ietf.org/rfc/rfc9051.html#name-noop-command
  Future<List<String>> noop() async => _sendCommand("NOOP");
  
  /// Logs out from the IMAP server.
  /// 
  /// https://www.ietf.org/rfc/rfc9051.html#name-logout-command
  Future logout() async => _sendCommand("LOGOUT");

  //#endregion


  //#region "NOT AUTHENTICATED" STATE COMMANDS

  /// Starts the TLS handshake to secure the connection.
  /// 
  /// https://www.ietf.org/rfc/rfc9051.html#name-starttls-command
  Future startTls() async {
    if(state != ImapState.nonAuthenticated) {
      throw ImapCommandBadState(
        command: "STARTTLS",
        currentState: state,
        expectedState: ImapState.nonAuthenticated
      );
    }

    _isTslProcessing = true;
    await _sendCommand("STARTTLS");
    _isTslProcessing = false;

    //TODO: capabilities must be refershed

  }

  Future authenticate() async {
    if(state != ImapState.nonAuthenticated) {
      throw ImapCommandBadState(
        command: "AUTHENTICATE",
        currentState: state,
        expectedState: ImapState.nonAuthenticated
      );
    }

    //TODO: implement
  }

  Future login() async {
    if(state != ImapState.nonAuthenticated) {
      throw ImapCommandBadState(
        command: "LOGIN",
        currentState: state,
        expectedState: ImapState.nonAuthenticated
      );
    }
  }

  //#endregion

  //#endregion
}



