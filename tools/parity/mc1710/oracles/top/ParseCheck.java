import java.util.*;
import java.net.*;
import java.lang.reflect.*;
import java.io.*;

// Vanilla-parse check: feed captured server->client frames through the
// REAL 1.7.10 packet parsers (S-classes from the jar) and report any
// packet the vanilla client would choke on (the "Internal Exception"
// behind Failed-to-connect). Also flags trailing bytes (client advances
// by what IT reads: under-read desyncs every later frame).
//
// Usage: ParseCheck <mc.jar> <cap.bin> <netty-buffer> <netty-common> <guava> <trove>
public class ParseCheck {
    static sun.misc.Unsafe U;

    public static void main(String[] args) throws Exception {
        Field f = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
        f.setAccessible(true);
        U = (sun.misc.Unsafe) f.get(null);
        java.util.List<URL> urlList = new java.util.ArrayList<URL>();
        urlList.add(new File(args[0]).toURI().toURL());
        urlList.add(new File(args[2]).toURI().toURL());
        urlList.add(new File(args[3]).toURI().toURL());
        urlList.add(new File(args[4]).toURI().toURL());
        urlList.add(new File(args[5]).toURI().toURL());
        // args[6..]: extra dependency jars (log4j, gson, ...)
        for (int ai = 6; ai < args.length; ai++) urlList.add(new File(args[ai]).toURI().toURL());
        URL[] urls = urlList.toArray(new URL[0]);
        URLClassLoader cl = new URLClassLoader(urls, ParseCheck.class.getClassLoader());
        Thread.currentThread().setContextClassLoader(cl);

        // eo = EnumConnectionState (HANDSHAKING, PLAY, STATUS, LOGIN).
        // Per-state field `i` maps clientbound packet id -> class.
        Class<?> ecs = Class.forName("eo", true, cl);
        Object play = null, login = null;
        for (Object st : ecs.getEnumConstants()) {
            if (st.toString().equals("PLAY")) play = st;
            if (st.toString().equals("LOGIN")) login = st;
        }
        Map<Integer, Class<?>> playMap = extractMap(ecs, play);
        Map<Integer, Class<?>> loginMap = extractMap(ecs, login);
        System.out.println("play clientbound classes: " + playMap.size() + ", login: " + loginMap.size());

        Class<?> etCls = Class.forName("et", true, cl);
        Constructor<?> etCtor = etCls.getConstructor(Class.forName("io.netty.buffer.ByteBuf", false, cl));
        // Heap buffer with a real array(): 1.7.10's readString calls
        // ByteBuf.array() directly (pooled/default allocators prefer
        // direct memory in netty 4.1, which throws here).
        Class<?> allocCls = Class.forName("io.netty.buffer.UnpooledByteBufAllocator", false, cl);
        Constructor<?> allocCtor = allocCls.getDeclaredConstructor(boolean.class);
        allocCtor.setAccessible(true);
        Object heapAlloc = allocCtor.newInstance(Boolean.FALSE);
        Class<?> heapCls = Class.forName("io.netty.buffer.UnpooledHeapByteBuf", false, cl);
        Class<?> allocIface = Class.forName("io.netty.buffer.ByteBufAllocator", false, cl);
        Constructor<?> heapCtor = heapCls.getDeclaredConstructor(allocIface, byte[].class, int.class);
        heapCtor.setAccessible(true);

        DataInputStream in = new DataInputStream(new BufferedInputStream(new FileInputStream(args[1])));
        int n = in.readInt();
        int ok = 0, failed = 0;
        for (int i = 0; i < n; i++) {
            int st = in.readUnsignedByte();
            int id = readVarint(in);
            int len = readVarint(in);
            byte[] body = new byte[len];
            in.readFully(body);
            Map<Integer, Class<?>> map = (st == 1) ? playMap : loginMap;
            Class<?> pc = map.get(id);
            if (pc == null) {
                System.out.println("frame " + i + " state=" + st + " id=0x" + Integer.toHexString(id) + " len=" + len + " NO SUCH PACKET (unknown id)");
                failed++;
                continue;
            }
            Object pkt;
            try {
                pkt = U.allocateInstance(pc);
            } catch (Throwable t) {
                System.out.println("frame " + i + " " + pc.getName() + " alloc failed: " + t);
                failed++;
                continue;
            }
            Method read = null;
            for (Method m : pc.getDeclaredMethods()) {
                if (m.getName().equals("a") && m.getParameterTypes().length == 1 && m.getParameterTypes()[0] == etCls) {
                    read = m;
                    break;
                }
            }
            if (read == null) {
                System.out.println("frame " + i + " " + pc.getName() + " no read(et) method");
                failed++;
                continue;
            }
            read.setAccessible(true);
            Object heap = heapCtor.newInstance(heapAlloc, body, body.length);
            Object buf = etCtor.newInstance(heap);
            try {
                read.invoke(pkt, buf);
            } catch (Throwable t) {
                System.out.println("frame " + i + " state=" + st + " id=0x" + Integer.toHexString(id) + " " + pc.getName() + " len=" + len + " THREW " + t.getCause());
                if (System.getenv("STACK") != null) t.getCause().printStackTrace(System.out);
                failed++;
                continue;
            }
            try {
                Method readable = buf.getClass().getMethod("readableBytes");
                int left = (Integer) readable.invoke(buf);
                if (left != 0) {
                    System.out.println("frame " + i + " " + pc.getName() + " TRAILING " + left + "/" + len + " bytes unread");
                    failed++;
                    continue;
                }
            } catch (NoSuchMethodException nsme) {
                // inherited readableBytes is found via getMethod; unreachable
            }
            ok++;
        }
        System.out.println("parsed ok=" + ok + " failed=" + failed + " total=" + n);
    }

    static int readVarint(DataInputStream in) throws Exception {
        int n = 0, shift = 0;
        while (true) {
            int b = in.readUnsignedByte();
            n |= (b & 0x7F) << shift;
            shift += 7;
            if ((b & 0x80) == 0) return n;
        }
    }

    static Map<Integer, Class<?>> extractMap(Class<?> ecs, Object state) throws Exception {
        Map<Integer, Class<?>> out = new HashMap<Integer, Class<?>>();
        Field ff = ecs.getDeclaredField("i");
        ff.setAccessible(true);
        Map<?, ?> m = (Map<?, ?>) ff.get(state);
        for (Map.Entry<?, ?> en : m.entrySet())
            out.put((Integer) en.getKey(), (Class<?>) en.getValue());
        return out;
    }
}
