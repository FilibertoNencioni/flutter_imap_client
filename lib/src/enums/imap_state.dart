enum ImapState{
  /// In non-authenticated state, the user must supply authentication
  /// credentials before most commands will be permitted.  This state is
  /// entered when a connection starts unless the connection has been
  /// pre-authenticated.
  nonAuthenticated,

  /// In authenticated state, the user is authenticated and must select a
  /// mailbox to access before commands that affect messages will be
  /// permitted.  This state is entered when a pre-authenticated connection
  /// starts, when acceptable authentication credentials have been
  /// provided, or after an error in selecting a mailbox.
  authenticated,

  /// In selected state, a mailbox has been selected to access.  This state
  /// is entered when a mailbox has been successfully selected.
  selected,

  /// In logout state, the session is being terminated, and the server will
  /// close the connection.  This state can be entered as a result of a
  /// client request or by unilateral server decision.
  logout
}