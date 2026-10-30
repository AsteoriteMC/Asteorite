import java.lang.reflect.*;
import java.util.*;
public class Struct4 {
  static Object W;
  public static void main(String[] args) throws Exception {
    // world + seed 42 (reuse VGold FakeWorld)
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
    W = w;
    try {
      Class<?> fp = Class.forName("VGold$FakeProvider");
      Object prov = fp.getDeclaredConstructor().newInstance();
      for (Field ff : ahb.getDeclaredFields()) {
        if (ff.getType().getName().equals("aqo")) { ff.setAccessible(true); ff.set(w, prov); }
      }
      // WorldChunkManager(seed, DEFAULT) onto provider.e
      Class<?> ahm = Class.forName("ahm");
      Object wtype = null;
      for (Field ff : ahm.getDeclaredFields()) {
        if (Modifier.isStatic(ff.getModifiers()) && ff.getType() == ahm) {
          ff.setAccessible(true);
          if (wtype == null) wtype = ff.get(null);
        }
      }
      Class<?> aib = Class.forName("aib");
      Object wcm = aib.getDeclaredConstructor(long.class, ahm).newInstance(42L, wtype);
      for (Field ff : Class.forName("aqo").getDeclaredFields()) {
        if (ff.getType() == aib) { ff.setAccessible(true); ff.set(prov, wcm); }
      }
      System.out.println("world ready");
    } catch (Throwable t) { System.out.println("providerFAIL: " + t); t.printStackTrace(System.out); }
    // proper per-chunk seeding replicating aqx.generate
    String[] cls = {"asw", "avn", "aug", "atx"};
    int[] ranges = {8, 8, 32, 32}; // approx MapGen ranges
    for (int ci = 0; ci < cls.length; ci++) {
      String cn = cls[ci];
      Class<?> c = Class.forName(cn);
      Object inst = c.getDeclaredConstructor().newInstance();
      for (Class<?> k = c; k != null; k = k.getSuperclass())
        for (Field ff : k.getDeclaredFields())
          if (ff.getType() == ahb) { ff.setAccessible(true); ff.set(inst, w); }
      // find shared rand field b on aqx
      Field brand = null;
      for (Class<?> k = c; k != null && brand == null; k = k.getSuperclass())
        for (Field ff : k.getDeclaredFields())
          if (ff.getType() == Random.class) brand = ff;
      brand.setAccessible(true);
      Random br = (Random) brand.get(inst);
      Method can = null;
      for (Method m : c.getDeclaredMethods())
        if (m.getParameterTypes().length == 2 && m.getReturnType() == boolean.class && Modifier.isProtected(m.getModifiers())) { can = m; break; }
      can.setAccessible(true);
      int R = ranges[ci];
      boolean any = false;
      StringBuilder hits = new StringBuilder();
      for (int x = -R; x <= R; x++) for (int z = -R; z <= R; z++) {
        try {
          br.setSeed(42L);
          long l = br.nextLong() / 2L * 2L + 1L;
          long l1 = br.nextLong() / 2L * 2L + 1L;
          br.setSeed((long) x * l + (long) z * l1 ^ 42L);
          boolean r = (Boolean) can.invoke(inst, x, z);
          if (r) { hits.append("[").append(x).append(",").append(z).append("]"); any = true; }
        } catch (Throwable t) { System.out.println(cn + " ERR " + t.getCause()); }
      }
      System.out.println(cn + ": " + (any ? hits.toString() : "clean radius " + R));
    }
  }
}
