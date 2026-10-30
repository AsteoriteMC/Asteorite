import java.lang.reflect.*;
import java.util.Random;

// Parity oracle for tools/parity chunk area: real 1.7.10 ChunkProvider
// (aqz) base fill + surface replacement over one chunk, with per-stage
// digests a Zig probe reproduces cell-for-cell (linear array order on
// both sides; wire ids via aji.b). Carvers deliberately NOT run: the
// Zig carver currently ships caves-only (ravines disabled), so carve
// parity stays T1 until that gap closes. Adapted from the rescued
// smoke/TerrainOracle.java harness (same scaffolding, plus base stage).
public class ChunkOracle {
    static class World extends ahb {
        aib manager; ays info; long seed;
        World() { super(null,"oracle",(ahj)null,(aqo)null,null); }
        protected apu j() { return null; }
        protected int p() { return 0; }
        public sa a(int id) { return null; }
        public aib v() { return manager; }
        public ays N() { return info; }
        public long H() { return seed; }
    }
    static void digest(String stage, aji[] blocks, byte[] meta) {
        long bc=0, mc=0;
        java.util.Map<Integer,Integer> counts=new java.util.TreeMap<>();
        for (aji b: blocks) { int id=b==null?0:aji.b(b); bc=bc*31+id; counts.put(id,counts.getOrDefault(id,0)+1); }
        for (byte m: meta) mc=mc*31+(m&255);
        System.out.println(stage+"_blocks="+bc+" "+stage+"_meta="+mc);
        System.out.println(stage+"_counts "+counts);
    }
    public static void main(String[] args) throws Exception {
        aji.p();
        long seed=Long.parseLong(args[0]);
        int cx=Integer.parseInt(args[1]), cz=Integer.parseInt(args[2]);
        ahj settings=new ahj(seed, ahk.a(0), false, false, ahm.b);
        Field uf=sun.misc.Unsafe.class.getDeclaredField("theUnsafe"); uf.setAccessible(true);
        World world=(World)((sun.misc.Unsafe)uf.get(null)).allocateInstance(World.class);
        world.seed=seed; world.manager=new aib(seed,ahm.b); world.info=new ays(settings,"oracle");
        aqz gen=new aqz(world,seed,false);
        aji[] blocks=new aji[65536]; byte[] meta=new byte[65536];
        // Same per-chunk seed as aqz.d (provideChunk) — surface RNG must
        // continue from here, not from the constructor-state Random.
        Field prand=aqz.class.getDeclaredField("i"); prand.setAccessible(true);
        ((Random)prand.get(gen)).setSeed((long)cx*341873128712L+(long)cz*132897987541L);
        gen.a(cx,cz,blocks);
        digest("base",blocks,meta);
        ahu[] biomes=world.v().b(null,cx*16,cz*16,16,16);
        gen.a(cx,cz,blocks,meta,biomes);
        digest("surface",blocks,meta);
        System.out.println("biome0="+biomes[0].ay+" population="+world.v().a(cx*16+16,cz*16+16).ay);
    }
}
