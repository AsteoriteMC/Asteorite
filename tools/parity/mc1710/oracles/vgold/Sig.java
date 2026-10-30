import java.lang.reflect.*;
public class Sig {
  public static void main(String[] a) throws Exception {
    Class<?> aia = Class.forName("aia");
    for (Method m : aia.getDeclaredMethods()) {
      if (m.getName().equals("a")) {
        StringBuilder sb = new StringBuilder("a(");
        for (Class<?> p : m.getParameterTypes()) sb.append(p.getName()).append(",");
        System.out.println(sb + ") " + Modifier.toString(m.getModifiers()));
      }
    }
  }
}
