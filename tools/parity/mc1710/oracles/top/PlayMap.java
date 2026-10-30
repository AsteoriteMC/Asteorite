import java.net.*;
import java.lang.reflect.*;
import java.io.File;
import java.util.*;

public class PlayMap {
    public static void main(String[] args) throws Exception {
        URL[] urls = new URL[]{
            new File(args[0]).toURI().toURL(),
            new File(args[1]).toURI().toURL(),
            new File(args[2]).toURI().toURL(),
            new File(args[3]).toURI().toURL(),
            new File(args[4]).toURI().toURL(),
        };
        URLClassLoader cl = new URLClassLoader(urls, PlayMap.class.getClassLoader());
        Class<?> ecs = Class.forName("eo", true, cl);
        Object play = null;
        for (Object st : ecs.getEnumConstants())
            if (st.toString().equals("PLAY")) play = st;
        Field ff = ecs.getDeclaredField("i");
        ff.setAccessible(true);
        Map<?,?> m = (Map<?,?>) ff.get(play);
        TreeMap<Integer,String> sorted = new TreeMap<Integer,String>();
        for (Map.Entry<?,?> en : m.entrySet())
            sorted.put((Integer) en.getKey(), ((Class<?>) en.getValue()).getName());
        for (Map.Entry<Integer,String> en : sorted.entrySet())
            System.out.println(String.format("0x%02X = %s", en.getKey(), en.getValue()));
    }
}
