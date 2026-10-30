import java.lang.reflect.*;
public class Opac {
  public static void main(String[] a) throws Exception {
    Class<?> aji = Class.forName("aji");
    Method reg = null;
    for (Method m : aji.getDeclaredMethods())
      if (m.getName().equals("p") && m.getParameterTypes().length == 0) reg = m;
    reg.setAccessible(true);
    reg.invoke(null);
    Class<?> ajn = Class.forName("ajn");
    Method getId = null, kop = null, dop = null;
    for (Method m : aji.getDeclaredMethods()) {
      if (Modifier.isStatic(m.getModifiers()) && m.getReturnType() == int.class
          && m.getParameterTypes().length == 1 && m.getParameterTypes()[0] == aji) getId = m;
      if (!Modifier.isStatic(m.getModifiers()) && m.getReturnType() == int.class && m.getParameterTypes().length == 0) {
        if (kop == null) kop = m; // first no-arg int method (k or m or b...)
      }
    }
    // find k() specifically: field r reader. Identify by comparing? Just print all no-arg int/boolean methods per block for ids of interest.
    java.util.TreeMap<Integer,String> names = new java.util.TreeMap<>();
    for (Field f : ajn.getDeclaredFields()) {
      if (!Modifier.isStatic(f.getModifiers())) continue;
      f.setAccessible(true);
      Object v; try { v = f.get(null); } catch (Throwable t) { continue; }
      if (v == null || !aji.isInstance(v)) continue;
      int id = (Integer) getId.invoke(null, v);
      names.put(id, f.getName());
    }
    for (java.util.Map.Entry<Integer,String> e : names.entrySet()) {
      int id = e.getKey();
      if (id > 175) break;
      Object b = null;
      for (Field f : ajn.getDeclaredFields()) {
        if (!Modifier.isStatic(f.getModifiers())) continue;
        f.setAccessible(true);
        Object v; try { v = f.get(null); } catch (Throwable t) { continue; }
        if (v != null && aji.isInstance(v) && ((Integer)getId.invoke(null, v)) == id) { b = v; break; }
      }
      StringBuilder sb = new StringBuilder(id + " " + e.getValue() + ":");
      for (Method m : aji.getDeclaredMethods()) {
        if (Modifier.isStatic(m.getModifiers()) || m.getParameterTypes().length != 0) continue;
        if (m.getReturnType() == int.class || m.getReturnType() == boolean.class) {
          m.setAccessible(true);
          try { sb.append(" ").append(m.getName()).append("=").append(m.invoke(b)); } catch (Throwable t) {}
        }
      }
      System.out.println(sb);
    }
  }
}
