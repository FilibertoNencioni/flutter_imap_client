class ImapInvalidCapabilities implements Exception {
  final List<String> responseMsgs;
  ImapInvalidCapabilities(this.responseMsgs);

  @override
  String toString() => "Capabilities command returned no capabilities. ${responseMsgs.join(", ")}";

}