/// Fixed, per-connection 10-second windows measured with a monotonic clock.
///
/// Accepting [elapsedMicroseconds] makes boundary tests synchronous without a
/// production clock injection or sleeps. A rejected request still increments.
final class RequestWindow {
  RequestWindow(this.limit);

  static const windowMicroseconds = 10 * Duration.microsecondsPerSecond;
  final int limit;
  int _start = 0;
  int _requests = 0;

  bool accept(int elapsedMicroseconds) {
    if (elapsedMicroseconds - _start >= windowMicroseconds) {
      _start = elapsedMicroseconds - elapsedMicroseconds % windowMicroseconds;
      _requests = 0;
    }
    _requests++;
    return _requests <= limit;
  }
}
