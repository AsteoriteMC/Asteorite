import java.lang.reflect.*;
public class Dec2 {
  public static void main(String[] a) throws Exception {
    Class<?> aia = Class.forName("aia");
    Object dec = aia.getDeclaredConstructor().newInstance();
    StringBuilder sb = new StringBuilder("fresh:");
    for (Field f : aia.getDeclaredFields()) {
      if (f.getType() == int.class || f.getType() == boolean.class) {
        f.setAccessible(true);
        sb.append(" ").append(f.getName()).append("=").append(f.get(dec));
      }
    }
    System.out.println(sb);
  }
}
