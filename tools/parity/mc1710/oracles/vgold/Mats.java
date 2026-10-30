import java.lang.reflect.*;
import java.util.*;
public class Mats {
  public static void main(String[] a) throws Exception {
    Class<?> aji = Class.forName("aji");
    Method reg = null;
    for (Method m : aji.getDeclaredMethods())
      if (m.getName().equals("p") && m.getParameterTypes().length == 0) reg = m;
    reg.setAccessible(true);
    reg.invoke(null);
    Class<?> ajn = Class.forName("ajn");
    Class<?> awt = Class.forName("awt");
    // material field on aji: find field of type awt
    Field matF = null;
    for (Field f : aji.getDeclaredFields())
      if (f.getType() == awt) { matF = f; break; }
    matF.setAccessible(true);
    // map material instance -> awt field name
    Map<Object,String> matNames = new HashMap<>();
    for (Field f : awt.getDeclaredFields()) {
      if (!Modifier.isStatic(f.getModifiers())) continue;
      if (f.getType() != awt) continue;
      f.setAccessible(true);
      try { matNames.put(f.get(null), f.getName()); } catch (Throwable t) {}
    }
    // id function
    Method getId = null;
    for (Method m : aji.getDeclaredMethods()) {
      if (Modifier.isStatic(m.getModifiers()) && m.getReturnType() == int.class
          && m.getParameterTypes().length == 1 && m.getParameterTypes()[0] == aji) { getId = m; break; }
    }
    getId.setAccessible(true);
    TreeMap<Integer,String> byId = new TreeMap<>();
    for (Field f : ajn.getDeclaredFields()) {
      if (!Modifier.isStatic(f.getModifiers())) continue;
      f.setAccessible(true);
      Object v;
      try { v = f.get(null); } catch (Throwable t) { continue; }
      if (v == null || !aji.isInstance(v)) continue;
      int id = (Integer) getId.invoke(null, v);
      Object mat = matF.get(v);
      byId.put(id, f.getName() + " mat=" + matNames.getOrDefault(mat, "?"));
    }
    for (Map.Entry<Integer,String> e : byId.entrySet())
      System.out.println(e.getKey() + " " + e.getValue());
  }
}
