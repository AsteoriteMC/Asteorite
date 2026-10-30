import java.net.*;
import java.lang.reflect.*;
import java.io.File;
import java.util.*;

public class WidthDump {
    public static void main(String[] args) throws Exception {
        URL[] urls = new URL[]{
            new File(args[0]).toURI().toURL(),
            new File(args[1]).toURI().toURL(),
            new File(args[2]).toURI().toURL(),
            new File(args[3]).toURI().toURL(),
            new File(args[4]).toURI().toURL(),
        };
        URLClassLoader cl = new URLClassLoader(urls, WidthDump.class.getClassLoader());
        Class<?> ecs = Class.forName("eo", true, cl);
        Object play = null;
        for (Object st : ecs.getEnumConstants())
            if (st.toString().equals("PLAY")) play = st;
        Field ff = ecs.getDeclaredField("i");
        ff.setAccessible(true);
        Map<?,?> m = (Map<?,?>) ff.get(play);
        int[] ids = {0x0B,0x0C,0x0D,0x0E,0x0F,0x10,0x11,0x12,0x13,0x14,0x15,0x16,0x17,0x18,0x19,0x1A,0x1B,0x1C,0x1D,0x1E,0x04,0x09};
        for (int id : ids) {
            Class<?> pc = (Class<?>) m.get(id);
            if (pc == null) { System.out.println(String.format("0x%02X = <none>", id)); continue; }
            StringBuilder sb = new StringBuilder();
            sb.append(String.format("0x%02X = %s first-reads: ", id, pc.getName()));
            // find read(et) method, disassemble first few et calls via reflection on code? use javap output instead
            for (java.lang.reflect.Method mm : pc.getDeclaredMethods()) {
                if (mm.getName().equals("a") && mm.getParameterTypes().length == 1
                        && mm.getParameterTypes()[0].getSimpleName().equals("et")) {
                    sb.append("has-read ");
                }
            }
            System.out.println(sb);
        }
    }
}
