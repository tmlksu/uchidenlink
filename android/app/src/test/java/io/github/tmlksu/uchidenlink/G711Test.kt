package io.github.tmlksu.uchidenlink

import java.io.File
import java.util.zip.CRC32
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * G.711 の ITU 標準ベクタ検証。
 * デコードの正解値はリポジトリ直下の spec/fixtures/g711/ (ITU-T G.191 STL g711.c から生成。
 * 規約と出どころは同ディレクトリの README.md)。
 */
class G711Test {

    private fun fixtureDir(): File {
        var d: File? = File(System.getProperty("user.dir")).absoluteFile
        while (d != null) {
            val f = File(d, "spec/fixtures/g711")
            if (f.isDirectory) return f
            d = d.parentFile
        }
        throw IllegalStateException("spec/fixtures/g711 が見つからない (user.dir=${System.getProperty("user.dir")})")
    }

    /** "<code hex> <linear>" の 256 行を読む。 */
    private fun loadDecodeGolden(name: String): IntArray {
        val out = IntArray(256) { Int.MIN_VALUE }
        File(fixtureDir(), name).readLines()
            .filter { it.isNotBlank() && !it.startsWith("#") }
            .forEach { line ->
                val (c, v) = line.trim().split(Regex("\\s+"))
                out[c.removePrefix("0x").toInt(16)] = v.toInt()
            }
        assertTrue("$name に 256 コード全部が無い", out.none { it == Int.MIN_VALUE })
        return out
    }

    // ---- デコード: 全 256 コードの絶対値を golden と比較 ----

    @Test
    fun `alaw decode matches ITU golden for all 256 codes`() {
        val golden = loadDecodeGolden("alaw_decode.txt")
        val bad = (0..255).filter { G711.alawToLinear(it.toByte()).toInt() != golden[it] }
        assertEquals(
            "A-law デコードのずれ: " + bad.take(8).joinToString {
                "0x%02X=%d (ITU %d)".format(it, G711.alawToLinear(it.toByte()), golden[it])
            },
            emptyList<Int>(), bad
        )
    }

    @Test
    fun `ulaw decode matches ITU golden for all 256 codes`() {
        val golden = loadDecodeGolden("ulaw_decode.txt")
        val bad = (0..255).filter { G711.ulawToLinear(it.toByte()).toInt() != golden[it] }
        assertEquals(emptyList<Int>(), bad)
    }

    @Test
    fun `decode anchors`() {
        // ITU 表の代表値 (iOS 版のアンカーと同じ)
        assertEquals(-5504, G711.alawToLinear(0x00).toInt())
        assertEquals(5504, G711.alawToLinear(0x80.toByte()).toInt())
        assertEquals(8, G711.alawToLinear(0xD5.toByte()).toInt())
        assertEquals(-8, G711.alawToLinear(0x55).toInt())
        assertEquals(32256, G711.alawToLinear(0xAA.toByte()).toInt())
        assertEquals(-32256, G711.alawToLinear(0x2A).toInt())
        assertEquals(-32124, G711.ulawToLinear(0x00).toInt())
        assertEquals(32124, G711.ulawToLinear(0x80.toByte()).toInt())
        assertEquals(0, G711.ulawToLinear(0xFF.toByte()).toInt())
        assertEquals(0, G711.ulawToLinear(0x7F).toInt())
        assertEquals(5372, G711.ulawToLinear(0xAA.toByte()).toInt())
        assertEquals(-716, G711.ulawToLinear(0x55).toInt())
    }

    // ---- 往復: decode -> encode で元のコードに戻る ----

    @Test
    fun `alaw round trip for all 256 codes`() {
        val bad = (0..255).filter { (G711.linearToAlaw(G711.alawToLinear(it.toByte()).toInt()).toInt() and 0xFF) != it }
        assertEquals(emptyList<Int>(), bad)
    }

    /** µ-law の 0x7F (負のゼロ) は 0 に復号され、0 は 0xFF (正のゼロ) に符号化されるので往復の例外。 */
    @Test
    fun `ulaw round trip for all codes except negative zero`() {
        val bad = (0..255).filter { it != 0x7F }
            .filter { (G711.linearToUlaw(G711.ulawToLinear(it.toByte()).toInt()).toInt() and 0xFF) != it }
        assertEquals(emptyList<Int>(), bad)
        assertEquals(0xFF, G711.linearToUlaw(G711.ulawToLinear(0x7F).toInt()).toInt() and 0xFF)
    }

    // ---- エンコード: 境界値 ----

    private fun a(p: Int) = G711.linearToAlaw(p).toInt() and 0xFF
    private fun u(p: Int) = G711.linearToUlaw(p).toInt() and 0xFF

    /**
     * 期待値は ITU-T G.191 STL alaw_compress と一致する。ただし (*) は負側の丸め規約の差で
     * STL と 1 段ずれる入力で、アプリの規約 (旧版 Sun g711.c の 16-bit 入力形式) の値を置く。
     * 規約は spec/fixtures/g711/README.md 参照。
     */
    @Test
    fun `alaw encode at segment boundaries`() {
        val cases = linkedMapOf(
            0 to 0xD5, 1 to 0xD5, 7 to 0xD5, 8 to 0xD5, 15 to 0xD5, 16 to 0xD4,
            255 to 0xDA, 256 to 0xC5, 511 to 0xCA, 512 to 0xF5, 1023 to 0xFA, 1024 to 0xE5,
            2047 to 0xEA, 2048 to 0x95, 4095 to 0x9A, 4096 to 0x85, 8191 to 0x8A, 8192 to 0xB5,
            16383 to 0xBA, 16384 to 0xA5, 32766 to 0xAA, 32767 to 0xAA,
            // 0 の直下: -1〜-7 も負の最小 (0x55)。正の最大 (0xAA) になってはいけない
            -1 to 0x55, -2 to 0x55, -7 to 0x55, -8 to 0x55, -9 to 0x55, -15 to 0x55, -16 to 0x55,
            -17 to 0x55, // (*) STL 0x54
            -255 to 0x5A, -256 to 0x5A,
            -263 to 0x5A, // (*) STL 0x45
            -264 to 0x45,
            -511 to 0x4A, -512 to 0x4A,
            -519 to 0x4A, // (*) STL 0x75
            -520 to 0x75,
            -1023 to 0x7A, -1024 to 0x7A, -1031 to 0x7A /* (*) */, -1032 to 0x65,
            -2047 to 0x6A, -2048 to 0x6A, -2055 to 0x6A /* (*) */, -2056 to 0x15,
            -4095 to 0x1A, -4096 to 0x1A, -4103 to 0x1A /* (*) */, -4104 to 0x05,
            -8191 to 0x0A, -8192 to 0x0A, -8199 to 0x0A /* (*) */, -8200 to 0x35,
            -16383 to 0x3A, -16384 to 0x3A, -16391 to 0x3A /* (*) */, -16392 to 0x25,
            -32767 to 0x2A, -32768 to 0x2A,
        )
        val bad = cases.filter { (p, want) -> a(p) != want }
            .map { (p, want) -> "%d -> 0x%02X (want 0x%02X)".format(p, a(p), want) }
        assertEquals(emptyList<String>(), bad)
    }

    /** 期待値の読み方は alaw と同じ。(*) は STL ulaw_compress と 1 段ずれる入力。 */
    @Test
    fun `ulaw encode at segment boundaries`() {
        val cases = linkedMapOf(
            0 to 0xFF, 1 to 0xFF, 123 to 0xF0, 124 to 0xEF, 379 to 0xE0, 380 to 0xDF,
            891 to 0xD0, 892 to 0xCF, 1915 to 0xC0, 1916 to 0xBF, 3963 to 0xB0, 3964 to 0xAF,
            8059 to 0xA0, 8060 to 0x9F, 16251 to 0x90, 16252 to 0x8F, 32124 to 0x80, 32767 to 0x80,
            -1 to 0x7F, -2 to 0x7F, -3 to 0x7F,
            -4 to 0x7E, // (*) STL 0x7F
            -5 to 0x7E,
            -123 to 0x70, -124 to 0x6F /* (*) */, -379 to 0x60, -380 to 0x5F /* (*) */,
            -891 to 0x50, -892 to 0x4F /* (*) */, -1915 to 0x40, -1916 to 0x3F /* (*) */,
            -3963 to 0x30, -3964 to 0x2F /* (*) */, -8059 to 0x20, -8060 to 0x1F /* (*) */,
            -16251 to 0x10, -16252 to 0x0F /* (*) */,
            -32124 to 0x00, -32767 to 0x00, -32768 to 0x00,
        )
        val bad = cases.filter { (p, want) -> u(p) != want }
            .map { (p, want) -> "%d -> 0x%02X (want 0x%02X)".format(p, u(p), want) }
        assertEquals(emptyList<String>(), bad)
    }

    @Test
    fun `encode keeps sign for all 16-bit inputs`() {
        // 符号ビット: A-law は 0x55 を戻した後の bit7、µ-law はそのまま bit7 (1 = 正 / ゼロ)
        val badA = (-32768..32767).filter { p -> (((a(p) xor 0x55) and 0x80) == 0) != (p < 0) }
        val badU = (-32768..32767).filter { p -> ((u(p) and 0x80) == 0) != (p < 0) }
        assertEquals("A-law 符号反転: ${badA.take(10)}", emptyList<Int>(), badA)
        assertEquals("µ-law 符号反転: ${badU.take(10)}", emptyList<Int>(), badU)
    }

    /**
     * 全 65536 入力 (-32768..32767 の順) のエンコード出力の CRC32 スナップショット。
     * エンコード挙動 (送信音声) が意図せず変わったら落ちる。変えるときは理由を残して値を更新すること。
     */
    @Test
    fun `encode output snapshot for all 16-bit inputs`() {
        val ca = CRC32().apply { for (p in -32768..32767) update(a(p)) }.value
        val cu = CRC32().apply { for (p in -32768..32767) update(u(p)) }.value
        assertEquals("A-law", 0x45BECD99L, ca)
        assertEquals("µ-law", 0xEB8EDAA8L, cu)
    }
}
