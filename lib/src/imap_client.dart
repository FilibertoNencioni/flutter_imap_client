import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_imap_client/src/classes/imap_pending_command.dart';
import 'package:flutter_imap_client/src/enums/imap_auth_mechanism.dart';
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

  /// Generates a unique tag for the IMAP command (4 hex digits starting from 1)
  String _generateUniqueTag(){
    String strTag = "";
    int numTag = 0;
    do{
      numTag++;
      strTag = numTag.toRadixString(16).padLeft(4, '0'). toUpperCase();
    }while(_pending.containsKey(strTag));

    return strTag;
  }

  /// Handle a single IMAP line.
  /// 
  /// Is the function responsable for handling IMAP responses and assigning them 
  /// to the correct pending command, requesting continuations if needed or 
  /// completing the command (when the tagged OK response arrives).
  void _handleLine(String line) {
    if (line.isEmpty) return;

    print("SERVER: $line");

    if (line.startsWith("*")) {
      // ****** UNTAGGED RESPONSE ******
      // Append to all pending commands (they may all care about untagged updates)
      for (var pending in _pending.values) {
        pending.lines.add(line);
      }
    } else if (line.startsWith("+")){
      // ****** CONTINUATION RESPONSE ******
      // Find the current pending command (usually the last inserted)
      for(int i = _pending.length -1; i >=0; i--){
        var pending = _pending.values.elementAt(i);
        if(!pending.completer.isCompleted){
          if(pending.onContinuation != null) {
            pending.onContinuation!(line.substring(1).trim());
          }
          break;
        }
      }
    } else {
      // ****** TAGGED RESPONSE ******
      String tag = line.split(" ")[0];
      if (_pending.containsKey(tag)) {
        var pending = _pending[tag]!;
        pending.lines.add(line); // include final tagged line
        pending.completer.complete(pending.lines);
        _pending.remove(tag);
      }
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


  /// Sends a command and returns a Future that completes when the tagged 
  /// response arrives.
  /// 
  /// If [onContinuation] is provided, it will be called when a continuation 
  /// response (starts with "+") is received. Only when the tagged reponse 
  /// arrives, the Future completes.
  /// 
  /// 
  /// throws [Exception] if the socket is not connected or if TLS processing is 
  /// active.
  /// 
  /// throws [ImapInvalidResponse] if the response is invalid.
  /// 
  /// throws [ImapBadResponse] if the response is BAD.
  /// 
  /// throws [ImapNoResponse] if the response is NO.
  Future<List<String>> _sendCommand(String command, {void Function(String continuation)? onContinuation}) async {
    if (socket == null) {
      throw Exception("Socket is not connected.");
    } else if (tlsState == TlsState.processing && command != "STARTTLS") {
      throw Exception("Cannot send commands while TLS processing is active.");
    }

    String tag = _generateUniqueTag();
    var pending = ImapPendingCommand(onContinuation: onContinuation);
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

  /// Reloads the capabilities after a login response.
  /// 
  /// If the login response contains a CAPABILITY untagged response, it uses that.
  /// Otherwise, it calls [_reloadCapabilities].
  Future _reloadCapabilitiesAfterLogin(List<String> loginResponse) async {
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

  /// Disconnects from the IMAP server.
  Future disconnect() async {
    //FIXME: could be better if the object is disposed and can't be used again
    await _sendCommand("LOGOUT");

    // Once completed reset IMAP client state
    socket!.close();
    socket = null;
    state = ImapState.nonAuthenticated;
    tlsState = TlsState.none;
    _capabilities.clear();
    _pending.clear();
    _buffer.clear();
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

    if(!_capabilities.contains("STARTTLS")) {
      throw ImapInvalidRequest("STARTTLS", _capabilities);
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
  /// 
  /// throws [ImapCommandBadState] if the current state is not "NOT AUTHENTICATED".
  /// 
  /// throws [ImapInvalidRequest] if the server does not support the specified authentication mechanism.
  /// Or, if null, the one chosen by the algorithm.
  Future authenticate(String username, String password, {ImapAuthMechanism? mechanism}) async {
    if(state != ImapState.nonAuthenticated) {
      throw ImapCommandBadState(
        command: "AUTHENTICATE",
        currentState: state,
        expectedState: ImapState.nonAuthenticated
      );
    }else if(
      tlsState != TlsState.established &&
      _capabilities
        .where((cap) => cap.startsWith("AUTH="))
        .isEmpty
    ){
      if(_capabilities.contains("STARTTLS")){
        await startTls(); //This also reloads capabilities
      }else{
        throw ImapInvalidRequest("AUTHENTICATE", _capabilities);
      }
    }


    if(mechanism != null && !_capabilities.contains("AUTH=${mechanism.name}")) {
      throw ImapInvalidRequest("AUTHENTICATE", _capabilities);
    } else if(mechanism == null){
      
      //Choose the best available mechanism
      List<ImapAuthMechanism> availableMechanisms = _capabilities
        .where((cap) => cap.startsWith("AUTH="))
        .map((cap) => cap.substring(5).toLowerCase())
        .map((mech) => ImapAuthMechanism.fromString(mech))
        .where((mech)=> mech != null)
        .map((mech)=>mech!)
        .toList();

      if(availableMechanisms.isEmpty){
        throw ImapInvalidRequest("AUTHENTICATE", _capabilities);
      }
    
      availableMechanisms.sort((a,b) => b.securityLevel.compareTo(a.securityLevel));
      mechanism = availableMechanisms.first;
    }

    List<String> authResponse = [];

    //TODO: implement
    switch (mechanism) {
      case ImapAuthMechanism.plain:
        // See docs at https://www.rfc-editor.org/rfc/rfc4616

        Uint8List encodedUser = utf8.encode(username);
        Uint8List encodedPass = utf8.encode(password);
        Uint8List authBytes = Uint8List(encodedUser.length + encodedPass.length + 2);
        authBytes[0] = 0;
        authBytes.setRange(1, encodedUser.length + 1, encodedUser);
        authBytes[encodedUser.length + 1] = 0;
        authBytes.setRange(encodedUser.length + 2, authBytes.length, encodedPass);
        
        String base64Auth = "${base64.encode(authBytes)}==";
        authResponse = await _sendCommand('AUTHENTICATE PLAIN $base64Auth');
        break;
      case ImapAuthMechanism.login:
        // Not in RFC

        authResponse = await _sendCommand(
          "AUTHENTICATE LOGIN", 
          onContinuation: (response) {
            if(response == "VXNlcm5hbWU6"){ //Base64 for "Username:"
              String base64User = base64.encode(utf8.encode(username));
              socket!.write("$base64User\r\n");
            }else if(response == "UGFzc3dvcmQ6"){ //Base64 for "Password:"
              String base64Pass = base64.encode(utf8.encode(password));
              socket!.write("$base64Pass\r\n");
            }else{
              throw ImapInvalidResponse("(Unexpected continuation response) $response");
            }
          }
        );
      default:
        break;

    }

    state = ImapState.authenticated;
    await _reloadCapabilitiesAfterLogin(authResponse);
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

    await _reloadCapabilitiesAfterLogin(loginResponse);
  }

  //#endregion

  //#endregion
}



