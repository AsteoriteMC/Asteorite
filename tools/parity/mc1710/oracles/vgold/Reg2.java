import java.lang.reflect.*;
public class Reg2 {
  public static void main(String[] a) throws Exception {
    Class<?> aji = Class.forName("aji");
    Method reg = null;
    for (Method m : aji.getDeclaredMethods())
      if (m.getName().equals("p") && m.getParameterTypes().length == 0 && Modifier.isStatic(m.getModifiers())) reg = m;
    System.out.println("reg=" + reg);
    reg.setAccessible(true);
    reg.invoke(null);
    System.out.println("invoked ok");
    Field fc = null;
    for (Field f : aji.getDeclaredFields()) if (f.getName().equals("c")) fc = f;
    fc.setAccessible(true);
    Object registry = fc.get(null);
    System.out.println("registry=" + registry.getClass().getName());
    java.util.Map<?,?> map = null;
    for (Field f : registry.getClass().getDeclaredFields()) {
      if (java.util.Map.class.isAssignableFrom(f.getType())) { f.setAccessible(true); map = (java.util.Map<?,?>) f.get(registry); break; }
    }
    System.out.println("map size=" + (map == null ? "null" : map.size()));
  }
}
