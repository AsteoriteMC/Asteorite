import java.lang.reflect.*;
import java.util.Random;
public class Probe {
  public static void main(String[] args) throws Exception {
    Class<?> aji0 = Class.forName("aji");
    Method reg = null;
    for (Method m : aji0.getDeclaredMethods())
      if (m.getName().equals("p") && m.getParameterTypes().length == 0) reg = m;
    reg.setAccessible(true);
    reg.invoke(null);
    Class<?> ajn = Class.forName("ajn");
    Field fb = ajn.getDeclaredField("b"); fb.setAccessible(true);
    Field fg = ajn.getDeclaredField("c"); fg.setAccessible(true);
    Field fa = ajn.getDeclaredField("a"); fa.setAccessible(true);
    Object stone = fb.get(null), grass = fg.get(null), air = fa.get(null);
    System.out.println("stone=" + stone + " grass=" + grass + " air=" + air);
    // direct minable call
    Class<?> ase = Class.forName("ase");
    Object vein = ase.getDeclaredConstructor(Class.forName("aji"), int.class).newInstance(stone, 16);
    System.out.println("vein=" + vein);
  }
}
