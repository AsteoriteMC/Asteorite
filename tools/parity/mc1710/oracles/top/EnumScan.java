import java.util.*;
import java.util.jar.*;
import java.net.*;
import java.io.File;
import java.lang.reflect.*;

public class EnumScan {
    public static void main(String[] args) throws Exception {
        URL[] urls = new URL[]{
            new File(args[0]).toURI().toURL(),
            new File(args[1]).toURI().toURL(),
            new File(args[2]).toURI().toURL(),
            new File(args[3]).toURI().toURL(),
        };
        URLClassLoader cl = new URLClassLoader(urls, EnumScan.class.getClassLoader());
        JarFile jf = new JarFile(args[0]);
        Enumeration<JarEntry> e = jf.entries();
        while (e.hasMoreElements()) {
            String n = e.nextElement().getName();
            if (!n.endsWith(".class") || n.indexOf('/') >= 0 || n.indexOf('$') >= 0) continue;
            String cn = n.substring(0, n.length() - 6);
            Class<?> c;
            try { c = Class.forName(cn, false, cl); } catch (Throwable t) { continue; }
            if (!c.isEnum()) continue;
            Object[] consts;
            try { consts = c.getEnumConstants(); } catch (Throwable t) {
                System.out.println(cn + " <init failed: " + t + ">");
                continue;
            }
            if (consts == null || consts.length != 4) continue;
            StringBuilder sb = new StringBuilder();
            sb.append(cn).append(" consts=[");
            for (Object k : consts) sb.append(k).append(",");
            sb.append("] fields=[");
            for (Field ff : c.getDeclaredFields()) {
                if (ff.isSynthetic()) continue;
                sb.append(ff.getType().getSimpleName()).append(";");
            }
            sb.append("]");
            System.out.println(sb);
        }
    }
}
