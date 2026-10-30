import java.net.*;
import java.lang.reflect.*;
import java.io.File;

public class BlkProbe {
    public static void main(String[] args) throws Exception {
        URL[] urls = new URL[]{ new File(args[0]).toURI().toURL() };
        URLClassLoader cl = new URLClassLoader(urls, BlkProbe.class.getClassLoader());
        Class<?> ajn = Class.forName("aji", true, cl);
        // init Blocks registry like WhichBlock
        Class<?> AJI = Class.forName("aji", true, cl);
        for (Method m : AJI.getDeclaredMethods())
            if (m.getName().equals("p") && m.getParameterTypes().length == 0) {
                m.setAccessible(true); m.invoke(null); break;
            }
        Class<?> blocks = null;
        // find Blocks class: has static aji fields incl bd/H/I — it's ajn per ItemBlock refs (ajn.bd)
        try { blocks = Class.forName("ajn", true, cl); } catch (Throwable t) { System.out.println("no ajn"); return; }
        for (String fn : new String[]{"bd", "H", "I"}) {
            try {
                Field f = blocks.getDeclaredField(fn);
                f.setAccessible(true);
                Object v = f.get(null);
                System.out.println(fn + " : " + (v == null ? "null" : v.getClass().getName() + " = " + v));
            } catch (Throwable t) { System.out.println(fn + " FAIL " + t); }
        }
    }
}
