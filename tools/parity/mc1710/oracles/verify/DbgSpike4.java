import java.lang.reflect.*;
public class DbgSpike4 {
    public static void main(String[] args) throws Exception {
        Class<?> AJN = Class.forName("ajn");
        for (String n : new String[]{"a","cj"}) {
            Field f = AJN.getDeclaredField(n);
            System.out.println(n + " mods=" + Modifier.toString(f.getModifiers()));
        }
    }
}
