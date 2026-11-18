/// Implemented by the State of each main tab so the app can drive
/// in-app keyboard navigation (Up/Down/Enter) independently of the view.
abstract class KeyboardNavigableView {
  void selectPrevious();
  void selectNext();
  Future<void> confirm();

  /// Secondary action: type only the username of the selected item.
  ///
  /// Tabs that have no username/password concept return `false`, which lets
  /// the key press fall through. The Credentials tab returns `true` after it
  /// has typed (or reported why it could not).
  Future<bool> typeUsername() async => false;

  /// Secondary action: type only the password of the selected item.
  Future<bool> typePassword() async => false;
}
