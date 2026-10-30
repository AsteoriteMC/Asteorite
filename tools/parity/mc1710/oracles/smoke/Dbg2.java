import java.util.Random;
public class Dbg2 {
    public static void main(String[] a) throws Exception {
        long seed = 12345L;
        ahj settings = new ahj(seed, ahk.a(0), false, false, ahm.b);
        FakeWorld w = new FakeWorld(new StubHandler(), "test", new aqq(), settings, new qi(), seed);
        System.out.println("pre ajn.a=" + ajn.a);
        avn v2 = new avn();
        aji[] dummy = new aji[65536];
        int fx = -47, fz = -26, PR = 2;
        for (int cx = fx-PR; cx <= fx+PR; cx++)
            for (int cz = fz-PR; cz <= fz+PR; cz++)
                v2.a((apu)null, w, cx, cz, dummy);
        System.out.println("prepared ajn.a=" + ajn.a);
        try {
            for (int cx = fx-PR; cx <= fx+PR; cx++)
                for (int cz = fz-PR; cz <= fz+PR; cz++)
                    v2.a(w, new Random(0), cx, cz);
            System.out.println("gen ok blocks=" + w.countBlocks());
        } catch (Throwable t) {
            System.out.println("post ajn.a=" + ajn.a);
            System.out.println("post e(0)=" + aji.e(0));
            throw t;
        }
    }
}
