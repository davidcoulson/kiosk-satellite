package me.jxl.kiosk_satellite.airplay

import org.junit.Assert.assertEquals
import org.junit.Test

class MonoUpmixTest {
    @Test
    fun monoAlacDecodesThenPlaysAsDuplicatedStereo() {
        // A mono element, uncompressed: tag 0, instance 0, 12 unused bits,
        // no size, no extra bits, verbatim, then three samples.
        val bits = StringBuilder()
        bits.append("000").append("0000").append("0".repeat(12)).append("0").append("00").append("1")
        for (s in intArrayOf(1000, -1000, 32767)) {
            bits.append(Integer.toBinaryString(s and 0xFFFF).padStart(16, '0'))
        }
        bits.append("111")
        while (bits.length % 8 != 0) bits.append('0')
        val bytes = ByteArray(bits.length / 8) { i -> bits.substring(i * 8, i * 8 + 8).toInt(2).toByte() }
        val pcm = ShortArray(3 * 2)
        val n = AlacDecoder(frameLength = 3, channels = 1).decode(bytes, 0, bytes.size, pcm)
        upmixMono(pcm, n)
        assertEquals(3, n)
        assertEquals(listOf<Short>(1000, 1000, -1000, -1000, 32767, 32767), pcm.toList())
    }
}
