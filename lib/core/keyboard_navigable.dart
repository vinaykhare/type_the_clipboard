/// Implemented by the State of each main tab so the app can drive
/// in-app keyboard navigation (Up/Down/Enter) independently of the view.
abstract class KeyboardNavigableView {
  void selectPrevious();
  void selectNext();
  Future<void> confirm();
}
