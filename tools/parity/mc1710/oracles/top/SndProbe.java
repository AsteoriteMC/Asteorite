import java.net.*;
import java.lang.reflect.*;
import java.io.File;

public class SndProbe {
    public static void main(String[] args) throws Exception {
        URL[] urls = new URL[]{ new File(args[0]).toURI().toURL() };
        URLClassLoader cl = new URLClassLoader(urls, SndProbe.class.getClassLoader());
        // TileEntityChest class: has numPlayersUsing field + openInventory/closeInventory
        int found = 0;
        java.util.Enumeration<java.util.jar.JarEntry> e = new java.util.jar.JarFile(args[0]).entries();
        while (e.hasMoreElements()) {
            String n = e.nextElement().getName();
            if (!n.endsWith(".class") || n.indexOf('/') >= 0 || n.indexOf('$') >= 0) continue;
            String cn = n.substring(0, n.length() - 6);
            Class<?> c;
            try { c = Class.forName(cn, false, cl); } catch (Throwable t) { continue; }
            boolean hasOpen = false, hasNum = false;
            for (java.lang.reflect.Method m : c.getDeclaredMethods()) {
                try {
                    if ((m.getName().equals("o") || m.getName().equals("openInventory")) && m.getParameterTypes().length == 0) hasOpen = true;
                } catch (Throwable t) {}
            }
            for (Field f : c.getDeclaredFields()) {
                try {
                    if (f.getType() == int.class && (f.getName().equals("h") || f.getName().equals("numPlayersUsing"))) hasNum = true;
                } catch (Throwable t) {}
            }
            if (hasOpen && hasNum) { System.out.println("TE-chest candidate: " + cn); found++; }
        }
        System.out.println("done " + found);
    }
}
