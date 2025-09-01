import 'package:flutter_imap_client/flutter_imap_client.dart';

void main(List<String> arguments) async {
  var client = ImapClient(host: "localhost", port: 143);
  await client.connect();

  await client.capability();
  
  await client.disconnect();
  

}
