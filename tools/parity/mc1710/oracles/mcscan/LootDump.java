import java.lang.reflect.*;
public class LootDump {
  public static void main(String[] a) throws Exception {
    Class<?> block = Class.forName("aji", true, LootDump.class.getClassLoader());
    block.getMethod("p").invoke(null);
    Class<?> items = Class.forName("adb", true, LootDump.class.getClassLoader());
    try { items.getMethod("l").invoke(null); } catch (Exception e) { System.out.println("items bootstrap note: "+e); }
    Class<?> qx = Class.forName("qx");
    Field fb = null, fc = null, fd = null;
    for (Field f : qx.getDeclaredFields()) { f.setAccessible(true);
      if (f.getName().equals("b")) fb=f; if (f.getName().equals("c")) fc=f; if (f.getName().equals("d")) fd=f; }
    Method itemId = items.getMethod("b", items);
    Method itemName = null;
    for (Method m : items.getDeclaredMethods()) if (m.getReturnType()==String.class && m.getParameterTypes().length==0 && !m.getName().equals("toString")) {}
    // use adb.a() no-arg if exists
    try { itemName = items.getMethod("a"); } catch (Exception e) {}
    String[] holders = {"asx","ats","aub","auc","aum","auq","auv","avz","asd","mt","arg"};
    for (String h : holders) {
      Class<?> c;
      try { c = Class.forName(h); } catch (Exception e) { System.out.println(h+": MISSING"); continue; }
      for (Field f : c.getDeclaredFields()) {
        if (!Modifier.isStatic(f.getModifiers())) continue;
        if (!f.getType().isArray() || !f.getType().getComponentType().equals(qx)) continue;
        f.setAccessible(true);
        Object arr = f.get(null);
        if (arr == null) { System.out.println(h+"."+f.getName()+": null"); continue; }
        int n = Array.getLength(arr);
        System.out.println(h+"."+f.getName()+" len="+n);
        for (int i=0;i<n;i++) {
          Object e = Array.get(arr,i);
          Object stack = fb.get(e);
          int lo=(Integer)fc.get(e), hi=(Integer)fd.get(e);
          // add: public int b (size), c (meta), b() -> adb
          Class<?> addCl = stack.getClass();
          Object item = addCl.getMethod("b").invoke(stack);
          int iid = (Integer) itemId.invoke(null, item);
          int sz = addCl.getField("b").getInt(stack);
          int meta = addCl.getField("c").getInt(stack);
          String nm = "?";
          if (itemName != null) { try { nm = (String) itemName.invoke(item); } catch (Exception ex) { nm="err"; } }
          System.out.println("  item="+iid+" name="+nm+" stack="+sz+" meta="+meta+" n="+lo+"-"+hi);
        }
      }
    }
  }
}
