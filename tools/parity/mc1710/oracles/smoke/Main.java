import java.util.Random;
public class Main {
    public static void main(String[] args) throws Exception {
        long seed = 12345L;
        ahj settings = new ahj(seed, ahk.a(0), false, false, ahm.b);
        aqq provider = new aqq();
        qi profiler = new qi();
        FakeWorld w = new FakeWorld(new StubHandler(), "test", provider, settings, profiler, seed);
        System.out.println("seed=" + w.H());
        Random r = w.A(1, 2, 3);
        System.out.println("rand=" + r.nextInt());
        ahu b = w.a(0, 0);
        System.out.println("biome=" + b.af + " id=" + b.ay);
        System.out.println("topY=" + w.h(0, 0));
        // village generator smoke: canSpawn + generate chunk (0,0)
        atx villages = new atx();
        boolean gen = villages.a(w, new Random(seed), 0, 0);
        System.out.println("villageGen(0,0)=" + gen);
        System.out.println("SMOKE-OK");
    }
}
