import java.lang.reflect.*;
import java.io.File;
import java.net.*;

public class WhichBlock {
    public static void main(String[] args) throws Exception {
        URL[] urls = new URL[]{ new File(args[0]).toURI().toURL() };
        URLClassLoader cl = new URLClassLoader(urls, WhichBlock.class.getClassLoader());
        Class<?> AJI = Class.forName("aji", true, cl);
        for (Method m : AJI.getDeclaredMethods())
            if (m.getName().equals("p") && m.getParameterTypes().length == 0) {
                m.setAccessible(true);
                m.invoke(null);
                break;
            }
        Field regF = null;
        for (Field ff : AJI.getDeclaredFields()) {
            if (ff.getType().getName().equals("cw")) { regF = ff; break; }
        }
        regF.setAccessible(true);
        Object registry = regF.get(null);
        Method byId = null;
        for (Method m : registry.getClass().getDeclaredMethods()) {
            if (m.getParameterTypes().length == 1 && m.getParameterTypes()[0] == int.class
                    && m.getReturnType() == Object.class) { byId = m; break; }
        }
        byId.setAccessible(true);
        for (String s : args[1].split(",")) {
            int id = Integer.parseInt(s);
            Object b = byId.invoke(registry, id);
            System.out.println(id + " -> " + b.getClass().getName());
        }
    }
}
