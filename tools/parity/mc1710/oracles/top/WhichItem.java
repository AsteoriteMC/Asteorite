import java.net.*;
import java.lang.reflect.*;
import java.io.File;
import java.util.*;

public class WhichItem {
    public static void main(String[] args) throws Exception {
        URL[] urls = new URL[]{ new File(args[0]).toURI().toURL() };
        URLClassLoader cl = new URLClassLoader(urls, WhichItem.class.getClassLoader());
        // ItemBlock class: has a Block field; find via adb (Item) subclasses is slow; try known: abx?
        // Instead: find class with a field of type aji (Block) + method onItemUse-like (yz,ahl,III,IFFF)->boolean
        java.util.Enumeration<java.util.jar.JarEntry> e = new java.util.jar.JarFile(args[0]).entries();
        while (e.hasMoreElements()) {
            String n = e.nextElement().getName();
            if (!n.endsWith(".class") || n.indexOf('/') >= 0 || n.indexOf('$') >= 0) continue;
            String cn = n.substring(0, n.length() - 6);
            Class<?> c;
            try { c = Class.forName(cn, false, cl); } catch (Throwable t) { continue; }
            boolean hasBlock = false, hasUse = false;
            try {
                for (Field f : c.getDeclaredFields()) {
                    if (f.getType().getSimpleName().equals("aji")) hasBlock = true;
                }
                for (Method m : c.getDeclaredMethods()) {
                    Class<?>[] ps = m.getParameterTypes();
                    if (ps.length == 10 && ps[1].getSimpleName().equals("yz")) hasUse = true;
                }
            } catch (Throwable t) { continue; }
            if (hasBlock && hasUse) System.out.println("ItemBlock candidate: " + cn);
        }
    }
}
