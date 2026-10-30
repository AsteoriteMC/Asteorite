import java.lang.reflect.*;
public class Which2 {
  public static void main(String[] a) throws Exception {
    Class<?> aji = Class.forName("aji");
    Method reg = null;
    for (Method m : aji.getDeclaredMethods())
      if (m.getName().equals("p") && m.getParameterTypes().length == 0) reg = m;
    reg.setAccessible(true);
    reg.invoke(null);
    Class<?> ajn = Class.forName("ajn");
    Method getId = null;
    for (Method m : aji.getDeclaredMethods()) {
      if (Modifier.isStatic(m.getModifiers()) && m.getReturnType() == int.class
          && m.getParameterTypes().length == 1 && m.getParameterTypes()[0] == aji) { getId = m; break; }
    }
    getId.setAccessible(true);
    for (String fn : new String[]{"r", "s", "t", "u", "H", "I", "c", "d"}) {
      Field f = ajn.getDeclaredField(fn);
      f.setAccessible(true);
      Object b = f.get(null);
      System.out.println(fn + " -> id " + getId.invoke(null, b));
    }
  }
}
