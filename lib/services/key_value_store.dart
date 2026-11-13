/// Minimal KV interface so secure vs. plain storage is swappable.
///
/// All values are strings; callers encode structured data themselves. Nothing
/// in this abstraction talks to the platform directly; implementations do.
abstract class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}
