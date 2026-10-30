import java.net.*;
import java.lang.reflect.*;
import java.io.File;

public class MatProbe {
    public static void main(String[] args) throws Exception {
        URL[] urls = new URL[]{ new File(args[0]).toURI().toURL() };
        URLClassLoader cl = new URLClassLoader(urls, MatProbe.class.getClassLoader());
        Class<?> awt = Class.forName("awt", true, cl);
        Method j = null;
        for (Method m : awt.getDeclaredMethods())
            if (m.getName().equals("j") && m.getReturnType() == boolean.class && m.getParameterTypes().length == 0) j = m;
        j.setAccessible(true);
        for (Field f : awt.getDeclaredFields()) {
            if (!java.lang.reflect.Modifier.isStatic(f.getModifiers())) continue;
            if (!f.getType().getName().equals("awt")) continue;
            f.setAccessible(true);
            Object mat = f.get(null);
            System.out.println(f.getName() + " replaceable=" + j.invoke(mat));
        }
    }
}
