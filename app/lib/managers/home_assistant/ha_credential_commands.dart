/// Whether a Home Assistant websocket command of [type] manages credentials
/// or users.
///
/// The shared connections (custom pages, plugins) sign in with the kiosk's
/// token and never hand it out. They must not let a page or plugin mint a
/// long-lived token of its own over that connection, set a password, add a
/// user or revoke the kiosk's token, so these commands never reach Home
/// Assistant through them. `auth/current_user` and `auth/sign_path` stay
/// open: the first says who the kiosk is signed in as, the second signs one
/// path for a few seconds, the way the frontend fetches camera images.
bool isHaCredentialCommand(Object? type) {
  if (type is! String) return false;
  if (type == 'auth') return true;
  if (type.startsWith('auth/')) {
    return type != 'auth/current_user' && type != 'auth/sign_path';
  }
  // config/auth/* manages users, config/auth_provider/* their passwords.
  return type.startsWith('config/auth');
}

/// The answer Home Assistant would give a refused command, so a client
/// waiting on [id] hears no and moves on.
Map<String, Object?> haCredentialRefusal(Object? id) => {
  'id': id,
  'type': 'result',
  'success': false,
  'error': {
    'code': 'not_allowed',
    'message':
        'Credential and user management commands are not available over '
        'the shared Home Assistant connection',
  },
};
