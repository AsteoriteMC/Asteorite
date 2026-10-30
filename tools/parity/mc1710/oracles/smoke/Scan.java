import java.util.Random;
public class Scan {
    public static void main(String[] args) throws Exception {
        long seed = 12345L;
        ahj settings = new ahj(seed, ahk.a(0), false, false, ahm.b);
        FakeWorld w = new FakeWorld(new StubHandler(), "test", new aqq(), settings, new qi(), seed);
        atx villages = new atx();
        int found = 0;
        for (int cx = -60; cx <= 60 && found < 3; cx++)
            for (int cz = -60; cz <= 60 && found < 3; cz++) {
                int before = 0;
                boolean gen = villages.a(w, new Random(seed ^ 1), cx, cz);
                if (gen) { System.out.println("village at chunk " + cx + "," + cz); found++; }
            }
        System.out.println("found=" + found);
    }
}
