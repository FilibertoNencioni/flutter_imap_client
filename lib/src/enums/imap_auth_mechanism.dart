// enum ImapAuthMechanism {
//   plain, //username and password
//   login, //username and password
//   cramMd5, //username and password
//   digestMd5, //username and password
//   scramSha1,//username and password
//   scramSha256,//username and password
//   // gssapi, //TODO: implement
//   xoauth2, //username and access token
// }

enum ImapAuthMechanism {
  plain(0),
  login(1),
  cramMd5(3),
  digestMd5(2),
  scramSha1(4),
  scramSha256(5),
  // gssapi(6),
  xoauth2(7);

  final int securityLevel;

  const ImapAuthMechanism(this.securityLevel);

  String get name {
    switch (this) {
      case ImapAuthMechanism.plain:
        return "PLAIN";
      case ImapAuthMechanism.login:
        return "LOGIN";
      case ImapAuthMechanism.cramMd5:
        return "CRAM-MD5";
      case ImapAuthMechanism.digestMd5:
        return "DIGEST-MD5";
      case ImapAuthMechanism.scramSha1:
        return "SCRAM-SHA-1";
      case ImapAuthMechanism.scramSha256:
        return "SCRAM-SHA-256";
      // case ImapAuthMechanism.gssapi:
      //   return "GSSAPI";
      case ImapAuthMechanism.xoauth2:
        return "XOAUTH2";
    }
  }

  static ImapAuthMechanism? fromString(String mechanism) {
    switch (mechanism.toUpperCase()) {
      case "PLAIN":
        return ImapAuthMechanism.plain;
      case "LOGIN":
        return ImapAuthMechanism.login;
      case "CRAM-MD5":
        return ImapAuthMechanism.cramMd5;
      case "DIGEST-MD5":
        return ImapAuthMechanism.digestMd5;
      case "SCRAM-SHA-1":
        return ImapAuthMechanism.scramSha1;
      case "SCRAM-SHA-256":
        return ImapAuthMechanism.scramSha256;
      // case "GSSAPI":
      //   return ImapAuthMechanism.gssapi;
      case "XOAUTH2":
        return ImapAuthMechanism.xoauth2;
      default:
        return null;
    }
  }
}