import java.net.*;
import java.lang.reflect.*;
import java.io.File;

public class EoDbg {
    public static void main(String[] args) throws Exception {
        URL[] urls = new URL[]{ new File(args[0]).toURI().toURL() };
        URLClassLoader cl = new URLClassLoader(urls, EoDbg.class.getClassLoader());
        Class<?> eo = Class.forName("eo", false, cl);
        for (Field ff : eo.getDeclaredFields())
            System.out.println(ff.getName() + " : " + ff.getType().getName());
    }
}
