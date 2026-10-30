public class Ids {
    public static void main(String[] args) throws Exception {
        Object[][] m = {{"q",ahu.q},{"F",ahu.F},{"J",ahu.J},{"K",ahu.K},{"u",ahu.u},{"o",ahu.o},{"p",ahu.p},{"r",ahu.r}};
        for (Object[] e : m) { ahu b = (ahu)e[1]; System.out.println(e[0] + " -> id=" + b.ay + " name=" + b.af); }
        System.out.println("total biomes=" + ahu.n().length);
    }
}
