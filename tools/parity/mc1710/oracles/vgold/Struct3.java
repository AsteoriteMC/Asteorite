import java.lang.reflect.*;
import java.util.*;
public class Struct3 {
  public static void main(String[] args) throws Exception {
    // FakeWorld + WorldInfo(seed 42)
    Class<?> vw = Class.forName("VGold$FakeWorld");
    sun.misc.Unsafe u = null;
    Field f = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
    f.setAccessible(true);
    u = (sun.misc.Unsafe) f.get(null);
    Class<?> ahu = Class.forName("ahu");
    Class<?> ajn = Class.forName("ajn");
    Class<?> aji = Class.forName("aji");
    Method reg = null;
    for (Method m : aji.getDeclaredMethods())
      if (m.getName().equals("p") && m.getParameterTypes().length == 0) reg = m;
    reg.setAccessible(true);
    reg.invoke(null);
    Field fa = ajn.getDeclaredField("a"); fa.setAccessible(true);
    Object air = fa.get(null);
    Object w = u.allocateInstance(vw);
    Field bf = ahu.getDeclaredField("p"); bf.setAccessible(true);
    Object plains = bf.get(null);
    Method init = vw.getDeclaredMethod("init", int.class, int.class, int.class, int.class, ahu, aji);
    init.setAccessible(true);
    init.invoke(w, 48, 48, -16, -16, plains, air);
    Class<?> ahb = Class.forName("ahb");
    Class<?> ays = Class.forName("ays");
    Object wi = u.allocateInstance(ays);
    Field fseed = ays.getDeclaredField("a"); fseed.setAccessible(true);
    fseed.setLong(wi, 42L);
    for (Field ff : ahb.getDeclaredFields()) {
      if (ff.getType() == ays) { ff.setAccessible(true); ff.set(w, wi); }
      if (ff.getType() == Random.class) { ff.setAccessible(true); ff.set(w, new Random(1L)); }
    }
    String[] cls = {"asw", "avn", "aug", "atx"};
    for (String cn : cls) {
      Class<?> c = Class.forName(cn);
      Object inst = c.getDeclaredConstructor().newInstance();
      for (Class<?> k = c; k != null; k = k.getSuperclass())
        for (Field ff : k.getDeclaredFields())
          if (ff.getType() == ahb) { ff.setAccessible(true); ff.set(inst, w); }
      // run terrain-time generate() for chunks -3..3 (method lives on aqx)
      Method gen = null;
      for (Class<?> k = c; k != null && gen == null; k = k.getSuperclass())
        for (Method m : k.getDeclaredMethods()) {
          if (m.getParameterTypes().length == 5) { gen = m; break; }
        }
      gen.setAccessible(true);
      Object blocks = java.lang.reflect.Array.newInstance(aji, 256 * 16 * 16);
      for (int cx = -3; cx <= 3; cx++) for (int cz = -3; cz <= 3; cz++) {
        try { gen.invoke(inst, null, w, cx, cz, blocks); }
        catch (Throwable t) { System.out.println(cn + " gen ERR at " + cx + "," + cz); t.getCause().printStackTrace(System.out); break; }
      }
      // inspect structureMap for starts intersecting chunk (0,0) = blocks x0..15,z0..15
      Field dmap = null;
      for (Class<?> k = c; k != null; k = k.getSuperclass()) {
        for (Field ff : k.getDeclaredFields())
          if (Map.class.isAssignableFrom(ff.getType())) { dmap = ff; break; }
        if (dmap != null) break;
      }
      dmap.setAccessible(true);
      Map<?,?> map = (Map<?,?>) dmap.get(inst);
      System.out.println(cn + ": starts=" + map.size());
      for (Object st : map.values()) {
        // StructureStart bounding box via methods? use reflection on fields
        System.out.println("  start: " + st.getClass().getName());
        for (Field ff : st.getClass().getDeclaredFields()) {
          if (ff.getType() == int.class || ff.getType() == boolean.class) {
            ff.setAccessible(true);
            try { System.out.print(" " + ff.getName() + "=" + ff.get(st)); } catch (Throwable t) {}
          }
        }
        System.out.println();
        break; // first only
      }
    }
  }
}
