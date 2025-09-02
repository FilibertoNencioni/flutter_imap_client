import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_imap_client/src/classes/imap_pending_command.dart';
import 'package:flutter_imap_client/src/enums/imap_state.dart';
import 'package:flutter_imap_client/src/enums/tls_state.dart';
import 'package:flutter_imap_client/src/exceptions/imap_bad_response.dart';
import 'package:flutter_imap_client/src/exceptions/imap_command_bad_state.dart';
import 'package:flutter_imap_client/src/exceptions/imap_invalid_capabilities.dart';
import 'package:flutter_imap_client/src/exceptions/imap_invalid_request.dart';
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
  final Completer<String> _greetingCompleter = Completer<String>();

  /// TCP data buffer for line parsing
  final StringBuffer _buffer = StringBuffer();

  /// Current TLS state
  TlsState tlsState = TlsState.none;

  /// If true, SSL certificate errors will be ignored (useful for self-signed certificates)
  bool ignoreSsl;

  /// Stores the capabilities of the IMAP server.
  List<String> _capabilities = [];


  ImapClient({required this.host, required this.port, this.ignoreSsl = false});

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
      _greetingCompleter.complete(chunk);
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
    } else if (tlsState == TlsState.processing && command != "STARTTLS") {
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

  /// Reloads the capabilities from the server.
  /// 
  /// Throws [ImapInvalidCapabilities] if no capabilities are returned.
  Future<void> _reloadCapabilities() async {
    print("****Reloading capabilities****");
    var response = await capability();
    _capabilities.clear();

    for(var line in response) {
      if(line.startsWith("* CAPABILITY")) {
        var parts = line.split(" ");
        if(parts.length > 2) {
          _capabilities.addAll(parts.sublist(2));
        }
      }
    }

    if(_capabilities.isEmpty) {
      throw ImapInvalidCapabilities(response);
    }
  }

  /// Connects to the IMAP server.
  /// 
  /// Throws an [Exception] if the socket is already connected or if the greeting from the server is not OK.
  /// Throws [ImapInvalidResponse] if the greeting fails.
  /// Throws [ImapInvalidCapabilities] if no capabilities are returned.
  Future connect() async {
    if(socket != null) {
      throw Exception("Socket is already connected.");
    }

    bool isImplicitTls = port == 993; //RFC8314 (https://www.rfc-editor.org/info/rfc8314)
    if(isImplicitTls){
      socket = await SecureSocket.connect(
        host, 
        port,
        onBadCertificate: ignoreSsl ? (_) => true : null
      );
      tlsState = TlsState.established;
    }else{
      socket = await Socket.connect(host, port);
      tlsState = TlsState.none;
    }
    
    socket!.listen(_onResponse);

    
    // Checks for OK response
    String greetingResponse = await _greetingCompleter.future;

    if(!greetingResponse.startsWith("* OK")){
      print("****Unable to connect to IMAP server****");
      socket!.close();
      throw ImapInvalidResponse(greetingResponse);
    }else {
      print("****Connected to IMAP server****");
      await _reloadCapabilities();
    }

  }


  Future<bool> disconnect() async {
    try{
      await _sendCommand("LOGOUT");
      socket!.close();
      socket = null;
      state = ImapState.nonAuthenticated;
      tlsState = TlsState.none;
      _capabilities.clear();
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
    }else if(tlsState != TlsState.none) {
      return; // Already started or completed
    }

    tlsState = TlsState.processing;

    try{
      await _sendCommand("STARTTLS");
      socket = await SecureSocket.secure(
        socket!,
        onBadCertificate: ignoreSsl ? (_) => true : null
      );
      socket!.listen(_onResponse);
      tlsState = TlsState.established;

      await _reloadCapabilities();

    } on Exception catch(_){
      tlsState = TlsState.none;
      rethrow;
    }


  }

  /// Authenticates the user using the specified authentication mechanism.
  /// Must be used if in the capabilities the server supports the AUTHENTICATE command. (AUTH=...)
  /// 
  /// https://www.ietf.org/rfc/rfc9051.html#name-authenticate-command
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

  /// Logs in the user using the LOGIN command.
  /// https://www.ietf.org/rfc/rfc9051.html#name-login-command
  /// 
  /// Must be used if in the capabilities the server does not support the AUTHENTICATE.
  /// Must be used on a secure connection (TLS established), if not it will start a secure connection.
  /// 
  /// throws [ImapCommandBadState] if the current state is not "NOT AUTHENTICATED".
  /// throws [ImapInvalidRequest] if the server does not support the LOGIN command.
  Future login(String username, String password, ) async {
    if(state != ImapState.nonAuthenticated) {
      throw ImapCommandBadState(
        command: "LOGIN",
        currentState: state,
        expectedState: ImapState.nonAuthenticated
      );
    }else if(tlsState != TlsState.established){
      //CAN'T LOGIN IF TLS IS NOT ESTABLISHED
      await startTls();
    }
    
    // before checking for capabilities, a secure connection is needed (or starttls) 
    if(_capabilities.contains("LOGINDISABLED")) {
      throw ImapInvalidRequest("LOGIN", _capabilities);
    }

    String usernameEscaped = username.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    String passwordEscaped = password.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

    List<String> loginResponse = await _sendCommand('LOGIN "$usernameEscaped" "$passwordEscaped"');
    state = ImapState.authenticated;

    //Reload capabilities
    String capabilityFromLogin = loginResponse.firstWhere(
      (line) => line.startsWith("* CAPABILITY"),
      orElse: () => ""
    );

    var parts = capabilityFromLogin.split(" ");
    if(capabilityFromLogin.isNotEmpty && parts.length > 2) {
      _capabilities = parts.sublist(2);
    }else{
      await _reloadCapabilities();
    }
    
  }

  //#endregion

  //#endregion
}



