package me.jxl.kiosk_satellite

import android.app.Activity
import android.os.Bundle

/**
 * Makes the NexiGo Aurora Pro's gear key mappable, by existing.
 *
 * The projector's window policy handles the gear key (KEYCODE_F4) itself,
 * before the key goes anywhere: it starts `com.zeasn.whale.open.launcher.TabType`,
 * the settings tab of the stock Zeasn launcher. The Aurora ships without
 * that launcher, so the start throws inside the policy, and a policy that
 * throws drops the key - no accessibility service and no app ever sees a
 * gear press. Answering the action here lets the policy finish normally,
 * and the key then travels on like any other: to [RemoteKeys] through the
 * key filter, with capture and long press, and to the focused app when it
 * is not mapped. So this Activity does nothing but finish; firing the
 * mapping here as well would run it twice.
 *
 * The system is the only caller that matters, and it passes any permission
 * check, so the Activity is exported behind android.permission.DUMP like
 * [ProvisionActivity]: no other app can start it. Nothing on a device
 * without this firmware ever sends the action.
 */
class GearKeyActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        finish()
    }
}
