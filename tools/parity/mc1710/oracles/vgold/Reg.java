import java.lang.reflect.*;
public class Reg {
  public static void main(String[] a) throws Exception {
    Class<?> aji = Class.forName("aji");
    for (Method m : aji.getDeclaredMethods()) {
      if (m.getName().equals("p") && m.getParameterTypes().length == 0)
        System.out.println("p: " + Modifier.toString(m.getModifiers()) + " returns " + m.getReturnType().getName());
    }
    Class<?> ajn = Class.forName("ajn");
    Field fa = ajn.getDeclaredField("a");
    fa.setAccessible(true);
    System.out.println("ajn.a BEFORE register: " + fa.get(null));
  }
}
