import java.lang.reflect.*;
import java.util.Random;
public class Trees {
  public static void main(String[] args) throws Exception {
    Class<?> aji0 = Class.forName("aji");
    Method reg = null;
    for (Method m : aji0.getDeclaredMethods())
      if (m.getName().equals("p") && m.getParameterTypes().length == 0) reg = m;
    reg.setAccessible(true);
    reg.invoke(null);
    // reuse FakeWorld via VGold
    Class<?> vw = Class.forName("VGold$FakeWorld");
    sun.misc.Unsafe u = null;
    Field f = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
    f.setAccessible(true);
    u = (sun.misc.Unsafe) f.get(null);
    Object w = u.allocateInstance(vw);
    Class<?> ahu = Class.forName("ahu");
    Field bf = ahu.getDeclaredField("s");
    bf.setAccessible(true);
    Object biome = bf.get(null);
    Class<?> ajn = Class.forName("ajn");
    Field fa = ajn.getDeclaredField("a"); fa.setAccessible(true);
    Field fb = ajn.getDeclaredField("b"); fb.setAccessible(true);
    Field fc = ajn.getDeclaredField("c"); fc.setAccessible(true);
    Object air = fa.get(null), stone = fb.get(null), grass = fc.get(null);
    java.lang.reflect.Method init = vw.getDeclaredMethod("init", int.class, int.class, int.class, int.class, ahu, Class.forName("aji"));
    init.setAccessible(true);
    init.invoke(w, 48, 48, -16, -16, biome, air);
    // flat terrain via blocks field
    Field bfl = vw.getDeclaredField("blocks");
    bfl.setAccessible(true);
    Object[] blocks = (Object[]) bfl.get(w);
    for (int x = 0; x < 48; x++) for (int z = 0; z < 48; z++)
      for (int y = 0; y < 256; y++)
        blocks[(x * 48 + z) * 256 + y] = y < 70 ? stone : (y == 70 ? grass : air);
    Random rand = new Random(42L);
    // replicate seedForChunk(42,0,0): setSeed(42)
    rand.setSeed(42L);
    // skip ore draws? call select+tree directly 3 times
    Method sel = null;
    for (Method m : ahu.getDeclaredMethods())
      if (m.getName().equals("a") && m.getParameterTypes().length == 1 && m.getParameterTypes()[0] == Random.class
          && m.getReturnType().getName().equals("arc")) sel = m;
    // forest override is on aif; biome.getClass() method
    Method selF = biome.getClass().getDeclaredMethod("a", Random.class);
    for (int i = 0; i < 3; i++) {
      int wx = 8 + rand.nextInt(16), wz = 8 + rand.nextInt(16);
      Object tree = selF.invoke(biome, rand);
      System.out.println("tree " + i + " at " + wx + "," + wz + " kind=" + tree.getClass().getName());
      Method gen = tree.getClass().getMethod("a", Class.forName("ahb"), Random.class, int.class, int.class, int.class);
      boolean ok = (Boolean) gen.invoke(tree, w, rand, wx, 71, wz);
      System.out.println("  placed=" + ok);
    }
  }
}
