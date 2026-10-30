public class Probe {
    public static void main(String[] args) throws Exception {
        for (String n : new String[]{"eg", "eh", "ei", "ej", "ek", "fh", "fi", "fj", "fk", "fl"}) {
            try {
                Class<?> c = Class.forName(n, false, Probe.class.getClassLoader());
                System.out.println(n + " enum=" + c.isEnum() + " iface=" + c.isInterface());
            } catch (Throwable t) {
                System.out.println(n + " FAIL " + t.toString().substring(0, Math.min(80, t.toString().length())));
            }
        }
    }
}
