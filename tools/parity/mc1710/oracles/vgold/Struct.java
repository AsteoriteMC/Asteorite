import java.lang.reflect.*;
import java.util.Random;
public class Struct {
  static Object newInst(Class<?> c) throws Exception {
    Constructor<?> k = c.getDeclaredConstructor();
    k.setAccessible(true);
    return k.newInstance();
  }
  public static void main(String[] args) throws Exception {
    // canSpawnStructureAtChunk(x,z) for mineshaft/village/stronghold/scattered in radius R of (0,0)
    int R = 12;
    String[] cls = {"asw", "avn", "aug", "atx"};
    for (String cn : cls) {
      Class<?> c = Class.forName(cn);
      Object inst = newInst(c);
      // MapGen structures hold a world ref (field c); point at a dummy holder is complex,
      // so instead replicate canSpawn logic is skipped: use generateStructuresInChunk path later.
      // Here: set world field to null-safe stub is impossible; catch per-call below.
      Method can = null;
      for (Method m : c.getDeclaredMethods()) {
        if (m.getParameterTypes().length == 2 && m.getReturnType() == boolean.class
            && Modifier.isProtected(m.getModifiers())) { can = m; break; }
      }
      if (can == null) { System.out.println(cn + ": no canSpawn found"); continue; }
      can.setAccessible(true);
      // init internal rand/seed state? MapGen needs world seed: look for a field or init method
      System.out.print(cn + " hits: ");
      boolean any = false;
      for (int x = -R; x <= R; x++) for (int z = -R; z <= R; z++) {
        try {
          boolean r = (Boolean) can.invoke(inst, x, z);
          if (r) { System.out.print("[" + x + "," + z + "]"); any = true; }
        } catch (Throwable t) { System.out.print("ERR(" + x + "," + z + ":" + t.getCause() + ")"); any = true; break; }
      }
      if (!any) System.out.print("(none)");
      System.out.println();
    }
  }
}
