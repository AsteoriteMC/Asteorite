import java.lang.reflect.*;
public class Dec {
  public static void main(String[] a) throws Exception {
    Class<?> ahu = Class.forName("ahu");
    Class<?> aia = Class.forName("aia");
    Field decF = null;
    for (Field f : ahu.getDeclaredFields()) if (f.getType() == aia) decF = f;
    decF.setAccessible(true);
    for (String b : new String[]{"s", "p"}) {
      Field bf = ahu.getDeclaredField(b);
      bf.setAccessible(true);
      Object biome = bf.get(null);
      Object dec = decF.get(biome);
      StringBuilder sb = new StringBuilder(b + ":");
      for (Field f : aia.getDeclaredFields()) {
        if (f.getType() == int.class || f.getType() == boolean.class) {
          f.setAccessible(true);
          sb.append(" ").append(f.getName()).append("=").append(f.get(dec));
        }
      }
      System.out.println(sb);
    }
  }
}
