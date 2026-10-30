import java.util.*;
import java.util.jar.*;
import java.net.*;

// Dump every enum in the jar WITHOUT running static initializers.
public class MapDump {
    public static void main(String[] args) throws Exception {
        String jar = args[0];
        URLClassLoader cl = new URLClassLoader(new URL[]{ new java.io.File(jar).toURI().toURL() }, MapDump.class.getClassLoader());
        JarFile jf = new JarFile(jar);
        List<String> names = new ArrayList<String>();
        Enumeration<JarEntry> e = jf.entries();
        while (e.hasMoreElements()) {
            String n = e.nextElement().getName();
            if (n.endsWith(".class") && n.indexOf('/') < 0 && n.indexOf('$') < 0)
                names.add(n.substring(0, n.length() - 6));
        }
        System.out.println("classes: " + names.size());
        int enums = 0, failed = 0;
        for (String n : names) {
            Class<?> c;
            try {
                c = Class.forName(n, false, cl);
            } catch (Throwable t) {
                failed++;
                continue;
            }
            if (!c.isEnum()) continue;
            enums++;
            Object[] consts;
            try {
                consts = c.getEnumConstants();
            } catch (Throwable t) {
                System.out.println(n + " <consts failed: " + t + ">");
                continue;
            }
            StringBuilder sb = new StringBuilder();
            sb.append(n).append(" nconst=").append(consts.length).append(" fields=[");
            for (java.lang.reflect.Field f : c.getDeclaredFields()) {
                if (f.isSynthetic()) continue;
                sb.append(f.getType().getSimpleName()).append(";");
            }
            sb.append("]");
            System.out.println(sb);
        }
        System.out.println("enums: " + enums + " failed: " + failed);
    }
}
