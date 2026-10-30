import java.lang.reflect.*;
public class InitCheck {
  public static void main(String[] a) throws Exception {
    Class<?> ajn = Class.forName("ajn");
    System.out.println("ajn loaded");
    Field f = ajn.getDeclaredField("b");
    f.setAccessible(true);
    try {
      Object v = f.get(null);
      System.out.println("b = " + v);
    } catch (Throwable t) {
      System.out.println("ERR: " + t);
      Throwable c = t.getCause();
      while (c != null) { System.out.println("caused: " + c); c = c.getCause(); }
    }
  }
}
