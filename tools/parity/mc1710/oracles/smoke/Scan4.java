import java.util.Random;
public class Scan4 {
    public static void main(String[] args) throws Exception {
        long seed = Long.parseLong(args[0]);
        ahj settings = new ahj(seed, ahk.a(0), false, false, ahm.b);
        FakeWorld w = new FakeWorld(new StubHandler(), "test", new aqq(), settings, new qi(), seed);
        // biome sample grid (block coords)
        java.util.Map<String,Integer> hist = new java.util.TreeMap<String,Integer>();
        for (int x = -640; x <= 640; x += 32)
            for (int z = -640; z <= 640; z += 32) {
                String n = w.a(x, z).af;
                hist.put(n, hist.containsKey(n) ? hist.get(n)+1 : 1);
            }
        System.out.println(hist);
        // manual canSpawn replication for chunk (0,0): region = 0,0; rand = world.A(0,0,14357617)
        Random r = w.A(0, 0, 14357617);
        System.out.println("region pick: " + (0*32 + r.nextInt(32-8)) + "," + (0*32 + r.nextInt(32-8)));
        System.out.println("biome at 8,8: " + w.a(8, 8).af);
    }
}
