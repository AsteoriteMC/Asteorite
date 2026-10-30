import java.lang.reflect.*;
public class Which {
  public static void main(String[] a) throws Exception {
    Class<?> aji = Class.forName("aji");
    Method reg = null;
    for (Method m : aji.getDeclaredMethods())
      if (m.getName().equals("p") && m.getParameterTypes().length == 0) reg = m;
    reg.setAccessible(true);
    reg.invoke(null);
    Class<?> ajn = Class.forName("ajn");
    for (String fn : new String[]{"H", "I", "N", "O", "P", "Q", "G"}) {
      Field f = ajn.getDeclaredField(fn);
      f.setAccessible(true);
      Object b = f.get(null);
      System.out.println(fn + " -> " + b.getClass().getName());
    }
  }
}
