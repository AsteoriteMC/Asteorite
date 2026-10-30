import java.util.Random;
public class Scan2 {
    public static void main(String[] args) throws Exception {
        long seed = Long.parseLong(args[0]);
        int R = Integer.parseInt(args[1]);
        ahj settings = new ahj(seed, ahk.a(0), false, false, ahm.b);
        FakeWorld w = new FakeWorld(new StubHandler(), "test", new aqq(), settings, new qi(), seed);
        atx villages = new atx();
        aji[] dummy = new aji[65536];
        for (int cx = -R; cx <= R; cx++)
            for (int cz = -R; cz <= R; cz++)
                villages.a((apu)null, w, cx, cz, dummy); // prepare starts (vanilla chunk-provider hook)
        int gen = 0; String first = null;
        for (int cx = -R; cx <= R; cx++)
            for (int cz = -R; cz <= R; cz++)
                if (villages.a(w, new Random(0), cx, cz)) { gen++; if (first==null) first = cx+","+cz; }
        System.out.println("seed=" + seed + " R=" + R + " genChunks=" + gen + " first=" + first + " blocks=" + w.countBlocks());
    }
}
