import java.net.*;
import java.lang.reflect.*;
import java.io.File;
import java.util.*;

public class MatById {
    public static void main(String[] args) throws Exception {
        URL[] urls = new URL[]{ new File(args[0]).toURI().toURL() };
        URLClassLoader cl = new URLClassLoader(urls, MatById.class.getClassLoader());
        Class<?> AJI = Class.forName("aji", true, cl);
        for (Method m : AJI.getDeclaredMethods())
            if (m.getName().equals("p") && m.getParameterTypes().length == 0) {
                m.setAccessible(true); m.invoke(null); break;
            }
        Field regF = null;
        for (Field ff : AJI.getDeclaredFields()) {
            try { if (ff.getType().getName().equals("cw")) { regF = ff; break; } } catch (Throwable t) {}
        }
        regF.setAccessible(true);
        Object registry = regF.get(null);
        Method byId = null;
        for (Method m : registry.getClass().getDeclaredMethods()) {
            if (m.getParameterTypes().length == 1 && m.getParameterTypes()[0] == int.class
                    && m.getReturnType() == Object.class) { byId = m; break; }
        }
        byId.setAccessible(true);
        Class<?> awt = Class.forName("awt", true, cl);
        Method j = null;
        for (Method m : awt.getDeclaredMethods())
            if (m.getName().equals("j") && m.getReturnType() == boolean.class && m.getParameterTypes().length == 0) j = m;
        j.setAccessible(true);
        for (String s : args[1].split(",")) {
            int id = Integer.parseInt(s);
            Object b = byId.invoke(registry, id);
            Method mat = null;
            for (Method m : b.getClass().getMethods()) {
                try {
                    if (m.getName().equals("o") && m.getParameterTypes().length == 0
                            && m.getReturnType().getName().equals("awt")) { mat = m; break; }
                } catch (Throwable t) {}
            }
            Object mm = mat.invoke(b);
            System.out.println(id + " replaceable=" + j.invoke(mm));
        }
    }
}
