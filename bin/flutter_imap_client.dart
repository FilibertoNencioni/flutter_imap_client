import 'package:flutter_imap_client/flutter_imap_client.dart';

void main(List<String> arguments) async {
  var client = ImapClient(host: "localhost", port: 143, ignoreSsl: true);
  // var client = ImapClient(host: "localhost", port: 993, ignoreSsl: true);
  await client.connect();

  await client.startTls();
  
  await client.disconnect();
  

}
