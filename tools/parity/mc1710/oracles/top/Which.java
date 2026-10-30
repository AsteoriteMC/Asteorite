import java.net.*;
import java.lang.reflect.*;
import java.io.File;
import java.util.*;

public class Which {
    public static void main(String[] args) throws Exception {
        URL[] urls = new URL[]{
            new File(args[0]).toURI().toURL(),
            new File(args[1]).toURI().toURL(),
            new File(args[2]).toURI().toURL(),
            new File(args[3]).toURI().toURL(),
            new File(args[4]).toURI().toURL(),
        };
        URLClassLoader cl = new URLClassLoader(urls, Which.class.getClassLoader());
        Class<?> ecs = Class.forName("eo", true, cl);
        Object play = null;
        for (Object st : ecs.getEnumConstants())
            if (st.toString().equals("PLAY")) play = st;
        Field ff = ecs.getDeclaredField("i");
        ff.setAccessible(true);
        Map<?,?> m = (Map<?,?>) ff.get(play);
        Class<?> s1d = (Class<?>) m.get(0x1D);
        System.out.println("0x1D = " + s1d.getName());
        for (Field f : s1d.getDeclaredFields())
            System.out.println("  field " + f.getName() + " : " + f.getType().getSimpleName());
        // print read method bytecode size as sanity
        for (Method mm : s1d.getDeclaredMethods()) {
            if (mm.getName().equals("a") && mm.getParameterTypes().length == 1
                    && mm.getParameterTypes()[0].getSimpleName().equals("et"))
                System.out.println("  read method found");
        }
    }
}
