import java.util.*;
import java.net.*;
import java.lang.reflect.*;
import java.io.File;

public class EoDump {
    public static void main(String[] args) throws Exception {
        URL[] urls = new URL[]{
            new File(args[0]).toURI().toURL(),
            new File(args[1]).toURI().toURL(),
            new File(args[2]).toURI().toURL(),
            new File(args[3]).toURI().toURL(),
            new File(args[4]).toURI().toURL(),
        };
        URLClassLoader cl = new URLClassLoader(urls, EoDump.class.getClassLoader());
        Class<?> eo = Class.forName("eo", true, cl);
        Object[] states = (Object[]) eo.getEnumConstants();
        for (Object st : states) {
            System.out.println("== " + st);
            for (Field ff : eo.getDeclaredFields()) {
                if (ff.isSynthetic() || ff.getType().isPrimitive() && !ff.getType().getName().equals("int")) continue;
                if (ff.getType().getName().equals("int")) continue;
                if (ff.getName().equals("ENUM$VALUES")) continue;
                ff.setAccessible(true);
                Object v = ff.get(st);
                if (v instanceof Map) {
                    Map<?,?> m = (Map<?,?>) v;
                    System.out.println("  Map " + ff.getName() + " size=" + m.size());
                    int shown = 0;
                    for (Map.Entry<?,?> en : m.entrySet()) {
                        if (shown++ > 4) break;
                        System.out.println("    " + en.getKey() + " -> " + en.getValue());
                    }
                } else {
                    System.out.println("  " + ff.getType().getSimpleName() + " " + ff.getName());
                }
            }
        }
    }
}
