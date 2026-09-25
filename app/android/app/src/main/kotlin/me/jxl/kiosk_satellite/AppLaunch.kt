package me.jxl.kiosk_satellite

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.util.Log

/**
 * Starting another app, a URI or the system settings from any context: the
 * engine-scoped bridge (the remote admin, ESPHome, gestures) and the
 * accessibility service (remote keys, with no Activity of ours anywhere)
 * share these, so a remote key and a gesture open exactly the same thing.
 *
 * Every start carries [Intent.FLAG_ACTIVITY_NEW_TASK], since the caller is
 * never an Activity. Each returns false rather than throwing, so the caller
 * can say why nothing opened.
 */
object AppLaunch {
    private const val TAG = "kiosk_satellite"

    /** The app's launcher entry. Android TV apps often declare only a
     *  leanback launcher entry, which [android.content.pm.PackageManager.getLaunchIntentForPackage]
     *  does not see, so that is the fallback. */
    fun launchApp(context: Context, packageName: String?): Boolean {
        if (packageName.isNullOrBlank()) return false
        val pm = context.packageManager
        val intent = pm.getLaunchIntentForPackage(packageName)
            ?: pm.getLeanbackLaunchIntentForPackage(packageName)
            ?: return false
        return start(context, intent, "launchApp $packageName")
    }

    /** Whatever app claims [uri] (ACTION_VIEW). */
    fun openUri(context: Context, uri: String?): Boolean {
        if (uri.isNullOrBlank()) return false
        return start(context, Intent(Intent.ACTION_VIEW, Uri.parse(uri)), "openUri $uri")
    }

    /** The Android Settings app (on Android TV, the TV settings). */
    fun openSystemSettings(context: Context): Boolean =
        start(context, Intent(Settings.ACTION_SETTINGS), "openSystemSettings")

    private fun start(context: Context, intent: Intent, what: String): Boolean = try {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        true
    } catch (e: Exception) {
        Log.w(TAG, "$what failed", e)
        false
    }
}
