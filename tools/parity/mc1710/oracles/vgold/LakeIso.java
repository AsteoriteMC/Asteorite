import java.lang.reflect.*;
import java.util.Random;
public class LakeIso {
  public static void main(String[] args) throws Exception {
    Class<?> vw = Class.forName("VGold$FakeWorld");
    sun.misc.Unsafe u = null;
    Field f = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
    f.setAccessible(true);
    u = (sun.misc.Unsafe) f.get(null);
    Class<?> aji0 = Class.forName("aji");
    Method reg = null;
    for (Method m : aji0.getDeclaredMethods())
      if (m.getName().equals("p") && m.getParameterTypes().length == 0) reg = m;
    reg.setAccessible(true);
    reg.invoke(null);
    Object w = u.allocateInstance(vw);
    Class<?> ahu = Class.forName("ahu");
    Class<?> ajn = Class.forName("ajn");
    Field fa = ajn.getDeclaredField("a"); fa.setAccessible(true);
    Field fb = ajn.getDeclaredField("b"); fb.setAccessible(true);
    Field fc = ajn.getDeclaredField("c"); fc.setAccessible(true);
    Field fl = ajn.getDeclaredField("l"); fl.setAccessible(true);
    Object air = fa.get(null), stone = fb.get(null), grass = fc.get(null), lava = fl.get(null);
    Field bf = ahu.getDeclaredField("p"); bf.setAccessible(true);
    Object plains = bf.get(null);
    Method init = vw.getDeclaredMethod("init", int.class, int.class, int.class, int.class, ahu, aji0);
    init.setAccessible(true);
    init.invoke(w, 48, 48, -16, -16, plains, air);
    Field blocksF = vw.getDeclaredField("blocks");
    blocksF.setAccessible(true);
    Object[] blocks = (Object[]) blocksF.get(w);
    for (int x = 0; x < 48; x++) for (int z = 0; z < 48; z++)
      for (int y = 0; y < 256; y++)
        blocks[(x * 48 + z) * 256 + y] = y < 70 ? stone : (y == 70 ? grass : air);
    Random rand = new Random(999L);
    Class<?> arx = Class.forName("arx");
    java.lang.reflect.Constructor<?> k = arx.getDeclaredConstructor(aji0);
    k.setAccessible(true);
    Object lake = k.newInstance(lava);
    Method gen = null;
    for (Method m : arx.getDeclaredMethods())
      if (m.getReturnType() == boolean.class && m.getParameterTypes().length == 5) gen = m;
    gen.setAccessible(true);
    System.out.println("placed=" + gen.invoke(lake, w, rand, 12, 12, 23));
    Method getId = null;
    for (Method m : aji0.getDeclaredMethods()) {
      if (Modifier.isStatic(m.getModifiers()) && m.getReturnType() == int.class
          && m.getParameterTypes().length == 1 && m.getParameterTypes()[0] == aji0) { getId = m; break; }
    }
    getId.setAccessible(true);
    int lav = 0, airN = 0;
    long crc = 0;
    for (int x = 0; x < 48; x++) for (int y = 0; y < 256; y++) for (int z = 0; z < 48; z++) {
      int id = (Integer) getId.invoke(null, blocks[(x * 48 + z) * 256 + y]);
      crc = crc * 31 + id;
      if (id == 11) lav++;
      if (id == 0) airN++;
    }
    System.out.println("lava=" + lav + " air=" + airN + " crc=" + crc);
    StringBuilder sb = new StringBuilder("cells=");
    int nn = 0;
    for (int x = 0; x < 48 && nn < 40; x++) for (int y = 0; y < 256 && nn < 40; y++) for (int z = 0; z < 48 && nn < 40; z++) {
      int id = (Integer) getId.invoke(null, blocks[(x * 48 + z) * 256 + y]);
      if (id == 11) { sb.append(x-16).append(",").append(y).append(",").append(z-16).append(" "); nn++; }
    }
    System.out.println(sb);
    int[] perY = new int[256];
    for (int x = 0; x < 48; x++) for (int y = 0; y < 256; y++) for (int z = 0; z < 48; z++) {
      int id = (Integer) getId.invoke(null, blocks[(x * 48 + z) * 256 + y]);
      if (id == 11) perY[y]++;
    }
    StringBuilder sb = new StringBuilder("yhist=");
    for (int y = 0; y < 256; y++) if (perY[y] > 0) sb.append(y).append(":").append(perY[y]).append(" ");
    System.out.println(sb);
  }
}
