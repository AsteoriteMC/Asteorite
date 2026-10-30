import java.lang.reflect.*;
public class Alc {
  public static void main(String[] a) throws Exception {
    Class<?> alc = Class.forName("alc");
    for (String fn : new String[]{"a", "b"}) {
      Field f = alc.getDeclaredField(fn);
      f.setAccessible(true);
      Object arr = f.get(null);
      System.out.print(fn + "=[");
      int n = Array.getLength(arr);
      for (int i = 0; i < n; i++) System.out.print(Array.get(arr, i) + (i+1<n?",":""));
      System.out.println("]");
    }
    // M too (first row)
    Field fm = alc.getDeclaredField("M");
    fm.setAccessible(true);
    Object m = fm.get(null);
    System.out.println("M rows=" + Array.getLength(m));
    Object row0 = Array.get(m, 0);
    System.out.print("M[0]=[");
    for (int i = 0; i < Array.getLength(row0); i++) System.out.print(Array.get(row0, i) + (i+1<Array.getLength(row0)?",":""));
    System.out.println("]");
  }
}
