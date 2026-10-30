import java.lang.reflect.*;
public class Cls {
  public static void main(String[] a) throws Exception {
    Class<?> ahu = Class.forName("ahu");
    for (Field f : ahu.getDeclaredFields()) {
      if (!Modifier.isStatic(f.getModifiers())) continue;
      if (f.getType() != ahu) continue;
      f.setAccessible(true);
      Object b = f.get(null);
      if (b == null) continue;
      // biome id field?
      String extra = "";
      for (Field g : ahu.getDeclaredFields()) {
        if (g.getType() == byte.class || g.getType() == int.class) {
          g.setAccessible(true);
          try { extra += " " + g.getName() + "=" + g.get(b); } catch (Throwable t) {}
          if (extra.length() > 60) break;
        }
      }
      System.out.println(f.getName() + " -> " + b.getClass().getName() + extra);
    }
  }
}
