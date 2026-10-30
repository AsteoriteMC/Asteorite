import java.lang.reflect.*;
public class BlockIdDump {
  public static void main(String[] a) throws Exception {
    Class<?> block = Class.forName("aji", true, BlockIdDump.class.getClassLoader());
    block.getMethod("p").invoke(null); // register blocks FIRST, before ajn loads
    Class<?> blocks = Class.forName("ajn", true, BlockIdDump.class.getClassLoader());
    java.lang.reflect.Method getId = block.getMethod("b", block);
    java.util.TreeMap<Integer,java.util.List<String>> map = new java.util.TreeMap<Integer,java.util.List<String>>();
    int total = 0, nulls = 0;
    for (Field f : blocks.getDeclaredFields()) {
      if (Modifier.isStatic(f.getModifiers()) && block.isAssignableFrom(f.getType())) {
        f.setAccessible(true);
        Object b = f.get(null);
        total++;
        if (b == null) { nulls++; continue; }
        int id = (Integer) getId.invoke(null, b);
        map.computeIfAbsent(id, k -> new java.util.ArrayList<String>()).add(f.getName() + ":" + f.getType().getSimpleName());
      }
    }
    for (java.util.Map.Entry<Integer,java.util.List<String>> e : map.entrySet())
      for (String s : e.getValue()) System.out.println(e.getKey() + " ajn." + s);
    System.out.println("TOTAL_FIELDS=" + total + " NULLS=" + nulls + " DISTINCT_IDS=" + map.size());
  }
}
