import java.lang.reflect.*;
public class Dump {
  public static void main(String[] args) throws Exception {
    Class<?> ajn = Class.forName("ajn");
    Class<?> aji = Class.forName("aji");
    Method getId = null;
    for (Method m : aji.getDeclaredMethods()) {
      if (Modifier.isStatic(m.getModifiers()) && m.getReturnType() == int.class
          && m.getParameterTypes().length == 1 && m.getParameterTypes()[0] == aji) { getId = m; break; }
    }
    getId.setAccessible(true);
    System.out.println("--- blocks ajn.field = id ---");
    for (Field f : ajn.getDeclaredFields()) {
      if (!Modifier.isStatic(f.getModifiers())) continue;
      f.setAccessible(true);
      Object v = null;
      try { v = f.get(null); } catch (Throwable t) { continue; }
      if (v != null && aji.isInstance(v)) System.out.println(f.getName() + " = " + getId.invoke(null, v));
    }
    System.out.println("--- biome decorators ---");
    Class<?> ahu = Class.forName("ahu");
    Class<?> aia = Class.forName("aia");
    Field decF = null;
    for (Field f : ahu.getDeclaredFields()) {
      if (f.getType() == aia) { decF = f; break; }
    }
    decF.setAccessible(true);
    Field[] ints = java.util.Arrays.stream(aia.getDeclaredFields())
      .filter(f -> f.getType() == int.class).toArray(Field[]::new);
    for (Field bf : ahu.getDeclaredFields()) {
      if (!Modifier.isStatic(bf.getModifiers())) continue;
      if (bf.getType() != ahu) continue;
      bf.setAccessible(true);
      Object biome = bf.get(null);
      if (biome == null) continue;
      Object dec = decF.get(biome);
      StringBuilder sb = new StringBuilder(bf.getName() + ":");
      for (Field inf : ints) { inf.setAccessible(true); sb.append(" ").append(inf.getName()).append("=").append(inf.getInt(dec)); }
      System.out.println(sb);
    }
  }
}
