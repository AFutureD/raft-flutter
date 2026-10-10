bool unsafeSharedText(String text) {
  if (RegExp(r'raft://oauth(?:/|\?|$)', caseSensitive: false).hasMatch(text)) {
    return true;
  }
  for (final match in RegExp(r'https?://[^\s]+').allMatches(text)) {
    final uri = Uri.tryParse(match.group(0)!);
    if (uri == null || uri.userInfo.isNotEmpty) return true;
    if (uri.queryParameters.keys.any(
      (key) => RegExp(
        r'^(token|access_token|refresh_token|signature|x-amz-.+|oauth_code)$',
        caseSensitive: false,
      ).hasMatch(key),
    )) {
      return true;
    }
  }
  return false;
}
