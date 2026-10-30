import java.util.Random;
public class Scan5 {
    static int count(long seed, int R) throws Exception {
        ahj settings = new ahj(seed, ahk.a(0), false, false, ahm.b);
        FakeWorld w = new FakeWorld(new StubHandler(), "test", new aqq(), settings, new qi(), seed);
        atx villages = new atx();
        villages.a((apu)null, w, 0, 0, new aji[65536]);
        int n = 0; String first = null;
        for (int cx = -R; cx <= R; cx++)
            for (int cz = -R; cz <= R; cz++)
                if (villages.a(cx, cz)) { n++; if (first == null) first = cx+","+cz+"("+w.a(cx*16+8,cz*16+8).af+")"; }
        System.out.println("seed=" + seed + " candidates=" + n + " first=" + first);
        return n;
    }
    public static void main(String[] args) throws Exception {
        for (String s : args) count(Long.parseLong(s), 160);
    }
}
