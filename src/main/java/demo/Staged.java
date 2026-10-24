package demo;

/** SpotBugs regression fixture. */
public final class Staged {
  private Staged() {}

  /** Nested class fixture. */
  public static final class Nested {
    private Nested() {}

    /** Compares a value. */
    public static boolean broken(String value) {
      return "bad".equals(value);
    }
  }
}
