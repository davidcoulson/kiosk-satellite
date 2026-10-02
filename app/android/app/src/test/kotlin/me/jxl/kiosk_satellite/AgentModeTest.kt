package me.jxl.kiosk_satellite

import android.app.AlarmManager
import android.app.Application
import android.content.Context
import android.content.Intent
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** An agent comes back headless: every relaunch path starts the service and
 *  never the Activity, whose start fronts it over the box's own app. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 33], manifest = Config.NONE, application = Application::class)
class AgentModeTest {
    private lateinit var context: Application

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .edit().putBoolean("flutter.ks.device.agent_mode", true)
            .putBoolean("flutter.ks.kiosk.start_on_boot", true).commit()
    }

    private fun assertHeadless() {
        assertNull(shadowOf(context).nextStartedActivity)
        val service = checkNotNull(shadowOf(context).nextStartedService)
        assertEquals(KioskSatelliteService::class.java.name, service.component?.className)
    }

    @Test
    fun anUpdateBringsBackTheServiceOnly() {
        UpdateRelaunchReceiver().onReceive(context, Intent(Intent.ACTION_MY_PACKAGE_REPLACED))
        assertHeadless()
    }

    @Test
    fun aBootStartsTheServiceOnly() {
        BootReceiver().onReceive(context, Intent(Intent.ACTION_BOOT_COMPLETED))
        assertHeadless()
    }

    @Test
    fun theRestartAlarmIsABroadcastToTheHeadlessStart() {
        val alarms = shadowOf(context.getSystemService(Context.ALARM_SERVICE) as AlarmManager)
        BackgroundBridge.scheduleRestartAlarm(context)
        val scheduled = alarms.scheduledAlarms.single().operation
        val intent = shadowOf(scheduled).savedIntent
        assertTrue(shadowOf(scheduled).isBroadcastIntent)
        assertEquals(AgentRestartReceiver::class.java.name, intent.component?.className)
        AgentRestartReceiver().onReceive(context, intent)
        assertHeadless()
    }

    @Test
    fun theCrashSelfHealLeavesAnAgentAlone() {
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .edit().putBoolean("flutter.ks.crash.was_foreground", true).commit()
        CrashSelfHeal.maybeRelaunch(context)
        assertNull(shadowOf(context).nextStartedActivity)
    }

    @Test
    fun aKioskStillRelaunchesItsActivity() {
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .edit().putBoolean("flutter.ks.device.agent_mode", false).commit()
        assertFalse(AgentMode.isOn(context))
    }
}
