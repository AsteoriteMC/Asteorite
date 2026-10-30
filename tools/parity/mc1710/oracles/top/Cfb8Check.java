import javax.crypto.Cipher;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;

public class Cfb8Check {
    public static void main(String[] a) throws Exception {
        byte[] secret = new byte[16];
        for (int i = 0; i < 16; i++) secret[i] = (byte) (i + 1);
        byte[] pt = "hello minecraft 1.7.10 encryption path".getBytes("UTF-8");
        Cipher c = Cipher.getInstance("AES/CFB8/NoPadding");
        c.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(secret, "AES"), new IvParameterSpec(secret));
        byte[] ct = c.doFinal(pt);
        StringBuilder sb = new StringBuilder();
        for (byte b : ct) sb.append(String.format("%02x", b));
        System.out.println("CT=" + sb);
        // decrypt check
        Cipher d = Cipher.getInstance("AES/CFB8/NoPadding");
        d.init(Cipher.DECRYPT_MODE, new SecretKeySpec(secret, "AES"), new IvParameterSpec(secret));
        System.out.println("PT=" + new String(d.doFinal(ct), "UTF-8"));
    }
}
