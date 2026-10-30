import java.util.Random;
public class Scan3 {
    public static void main(String[] args) throws Exception {
        long seed = Long.parseLong(args[0]);
        int R = Integer.parseInt(args[1]);
        ahj settings = new ahj(seed, ahk.a(0), false, false, ahm.b);
        FakeWorld w = new FakeWorld(new StubHandler(), "test", new aqq(), settings, new qi(), seed);
        atx villages = new atx();
        villages.a((apu)null, w, 0, 0, new aji[65536]); // init world field c
        int n = 0;
        for (int cx = -R; cx <= R; cx++)
            for (int cz = -R; cz <= R; cz++)
                if (villages.a(cx, cz)) { System.out.println("candidate " + cx + "," + cz + " biome=" + w.a(cx*16+8, cz*16+8).af); n++; }
        System.out.println("candidates=" + n);
    }
}
