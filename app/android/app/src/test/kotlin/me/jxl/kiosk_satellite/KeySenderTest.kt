package me.jxl.kiosk_satellite

import android.app.Application
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** Sending keys from Home Assistant: what works without root, and a
 *  reason instead of silence for what does not. */
@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, application = Application::class, sdk = [30])
class KeySenderTest {
    private val context: Application get() = RuntimeEnvironment.getApplication()

    @Test
    fun `media and volume keys need nothing`() {
        assertEquals(true, KeySender.send(context, "play_pause")["ok"])
        assertEquals(true, KeySender.send(context, "volume_up")["ok"])
    }

    @Test
    fun `the D-pad says it needs Android 13`() {
        val answer = KeySender.send(context, "dpad_up")
        assertEquals(false, answer["ok"])
        assertTrue("${answer["error"]}".contains("Android 13"))
    }

    @Test
    fun `back says it needs the accessibility service`() {
        val answer = KeySender.send(context, "back")
        assertEquals(false, answer["ok"])
        assertTrue("${answer["error"]}".contains("accessibility service"))
    }

    @Test
    fun `an unknown key lists the ones that exist`() {
        val answer = KeySender.send(context, "self_destruct")
        assertEquals(false, answer["ok"])
        assertTrue("${answer["error"]}".contains("play_pause"))
    }
}
