import java.lang.reflect.*;
public class Dec3 {
  public static void main(String[] args) throws Exception {
    Class<?> ahu = Class.forName("ahu");
    Class<?> aia = Class.forName("aia");
    Field decF = null;
    for (Field f : ahu.getDeclaredFields()) if (f.getType() == aia) decF = f;
    decF.setAccessible(true);
    Field bf = ahu.getDeclaredField("p");
    bf.setAccessible(true);
    Object biome = bf.get(null);
    Object dec = decF.get(biome);
    // find which field the z-loop gate reads: it's the one compared in the loop at relative ~627. Just dump all int fields.
    StringBuilder sb = new StringBuilder("plains decor:");
    for (Field f : aia.getDeclaredFields()) {
      f.setAccessible(true);
      try {
        if (f.getType() == int.class) sb.append(" ").append(f.getName()).append("=").append(f.getInt(dec));
        else if (f.getType() == boolean.class) sb.append(" ").append(f.getName()).append("=").append(f.getBoolean(dec));
      } catch (Throwable t) {}
    }
    System.out.println(sb);
  }
}
