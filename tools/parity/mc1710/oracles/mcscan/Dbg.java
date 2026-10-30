public class Dbg {
  public static void main(String[] a) throws Exception {
    Class<?> ajn = Class.forName("ajn", true, Dbg.class.getClassLoader());
    System.out.println("ajn loaded: " + ajn);
    java.lang.reflect.Field f = ajn.getDeclaredField("a");
    f.setAccessible(true);
    Object v = f.get(null);
    System.out.println("ajn.a = " + v);
    Class<?> aji = Class.forName("aji");
    System.out.println("aji ok");
    java.lang.reflect.Method m = aji.getMethod("b", aji);
    System.out.println("m=" + m);
    if (v != null) System.out.println("id=" + m.invoke(null, v));
  }
}
