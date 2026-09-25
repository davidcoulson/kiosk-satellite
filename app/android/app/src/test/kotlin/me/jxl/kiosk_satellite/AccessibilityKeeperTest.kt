package me.jxl.kiosk_satellite

import android.Manifest
import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.provider.Settings
import org.robolectric.RuntimeEnvironment
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** Putting the accessibility service back after firmware turns it off
 *  (the HY260 projector), without ever writing over another service. */
@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, application = Application::class)
class AccessibilityKeeperTest {
    private lateinit var context: Application
    private val projectivy =
        "com.spocky.projengmenu/com.spocky.projengmenu.services.ProjectivyAccessibilityService"
    private lateinit var me: String

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        me = ComponentName(context, KioskAccessibilityService::class.java).flattenToString()
    }

    private fun enabled(): String? =
        Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)

    private fun a11yOn(): Int =
        Settings.Secure.getInt(context.contentResolver, Settings.Secure.ACCESSIBILITY_ENABLED, 0)

    private fun grant() = shadowOf(context).grantPermissions(Manifest.permission.WRITE_SECURE_SETTINGS)

    @Test
    fun `an empty or unset list gets just the service`() {
        val service = ComponentName(context, KioskAccessibilityService::class.java)
        assertEquals(me, AccessibilityKeeper.withService(null, service))
        assertEquals(me, AccessibilityKeeper.withService("", service))
        assertEquals(me, AccessibilityKeeper.withService("null", service))
    }

    @Test
    fun `another service stays, and ours is not added twice`() {
        val service = ComponentName(context, KioskAccessibilityService::class.java)
        assertEquals("$projectivy:$me", AccessibilityKeeper.withService(projectivy, service))
        assertNull(AccessibilityKeeper.withService("$projectivy:$me", service))
        // The short form Android also accepts counts as present.
        val short = "${context.packageName}/.KioskAccessibilityService"
        assertNull(AccessibilityKeeper.withService(short, service))
    }

    @Test
    fun `with the grant a cleared service comes back beside the others`() {
        grant()
        Settings.Secure.putString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, projectivy)
        Settings.Secure.putInt(context.contentResolver, Settings.Secure.ACCESSIBILITY_ENABLED, 0)
        AccessibilityKeeper.ensure(context)
        assertEquals("$projectivy:$me", enabled())
        assertEquals(1, a11yOn())
    }

    @Test
    fun `without the grant nothing is written`() {
        Settings.Secure.putString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, "")
        AccessibilityKeeper.ensure(context)
        assertEquals("", enabled())
        assertEquals(0, a11yOn())
    }

    private fun listeners(): String? =
        Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners")

    private fun prefs() = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

    @Test
    fun `now playing on grants notification access, beside others`() {
        grant()
        val other = "com.example/.Listener"
        Settings.Secure.putString(context.contentResolver, "enabled_notification_listeners", other)
        prefs().edit().putBoolean("flutter.ks.device.now_playing", true).commit()
        AccessibilityKeeper.ensure(context)
        val me = MediaSessions.listener(context).flattenToString()
        assertEquals("$other:$me", listeners())
    }

    @Test
    fun `now playing off takes back only what the keeper granted`() {
        grant()
        val other = "com.example/.Listener"
        Settings.Secure.putString(context.contentResolver, "enabled_notification_listeners", other)
        prefs().edit().putBoolean("flutter.ks.device.now_playing", true).commit()
        AccessibilityKeeper.ensure(context)
        prefs().edit().putBoolean("flutter.ks.device.now_playing", false).commit()
        AccessibilityKeeper.ensure(context)
        assertEquals(other, listeners())

        // Granted by the owner, not the keeper: left alone.
        val me = MediaSessions.listener(context).flattenToString()
        Settings.Secure.putString(context.contentResolver, "enabled_notification_listeners", "$other:$me")
        AccessibilityKeeper.ensure(context)
        assertEquals("$other:$me", listeners())
    }

    @Test
    fun `a restore is counted`() {
        grant()
        Settings.Secure.putString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, "")
        AccessibilityKeeper.ensure(context)
        val record = AccessibilityKeeper.record(context)
        assertEquals(1, record["count"])
        assertEquals("Accessibility service turned back on", record["what"])
    }

    @Test
    fun `the switch turned off leaves it alone`() {
        grant()
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .edit().putBoolean("flutter.ks.device.keep_accessibility", false).commit()
        Settings.Secure.putString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, "")
        AccessibilityKeeper.ensure(context)
        assertEquals("", enabled())
    }
}
