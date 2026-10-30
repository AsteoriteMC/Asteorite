public class Dbg2 {
  public static void main(String[] a) throws Exception {
    Class<?> block = Class.forName("aji", true, Dbg2.class.getClassLoader());
    block.getMethod("p").invoke(null);
    Class<?> items = Class.forName("adb", true, Dbg2.class.getClassLoader());
    for (java.lang.reflect.Method m : items.getDeclaredMethods()) {
      if (java.lang.reflect.Modifier.isStatic(m.getModifiers()) && m.getParameterTypes().length==0 && m.getReturnType()==void.class)
        System.out.println("static void(): " + m.getName());
    }
    try { items.getMethod("l").invoke(null); System.out.println("l() OK"); }
    catch (Exception e) { System.out.println("l() failed: "); e.getCause().printStackTrace(System.out); }
  }
}
