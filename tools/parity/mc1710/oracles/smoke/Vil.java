import java.util.Random;
public class Vil {
    public static void main(String[] args) throws Exception {
        long seed = Long.parseLong(args[0]);
        int R = Integer.parseInt(args[1]);
        aji.p(); System.out.println("X -> id=" + ahu.X.ay + " name=" + ahu.X.af);
        ahj settings = new ahj(seed, ahk.a(0), false, false, ahm.b);
        FakeWorld w = new FakeWorld(new StubHandler(), "test", new aqq(), settings, new qi(), seed);
        System.out.println("after-world ajn.a=" + ajn.a + " e0=" + aji.e(0));
        System.out.println("after-rep ajn.a=" + ajn.a + " e0=" + aji.e(0));
        avn villages = new avn();
        villages.a((apu)null, w, 0, 0, new aji[65536]);
        int n = 0; String first = null;
        for (int cx = -R; cx <= R; cx++)
            for (int cz = -R; cz <= R; cz++)
                if (villages.a(cx, cz)) { n++; if (first == null) first = cx+","+cz+"("+w.a(cx*16+8,cz*16+8).af+")"; }
        System.out.println("village candidates=" + n + " first=" + first);
        // prepare + generate around first candidate
        String[] xy = first.split("[(),]"); int fx = Integer.parseInt(xy[0]), fz = Integer.parseInt(xy[1]);
        avn v2 = new avn();
        aji[] dummy = new aji[65536];
        int PR = 2;
        for (int cx = fx-PR; cx <= fx+PR; cx++)
            for (int cz = fz-PR; cz <= fz+PR; cz++)
                v2.a((apu)null, w, cx, cz, dummy);
        int gen = 0;
        for (int cx = fx-PR; cx <= fx+PR; cx++)
            for (int cz = fz-PR; cz <= fz+PR; cz++)
                try { if (v2.a(w, new Random(0), cx, cz)) gen++; }
                catch (Throwable t) { System.out.println("CHUNK " + cx + "," + cz + " FAIL: " + t + " ajn.a=" + ajn.a); }
        System.out.println("genChunks=" + gen + " blocks=" + w.countBlocks() + " entities=" + w.countEntities());
        System.out.println("VIL-OK");
    }
}
