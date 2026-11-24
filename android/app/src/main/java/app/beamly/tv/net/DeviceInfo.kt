package app.beamly.tv.net

import android.content.Context
import android.net.ConnectivityManager
import android.os.Build
import android.provider.Settings
import java.net.Inet4Address

object DeviceInfo {

    /** The device name set in Settings (e.g. "Living Room TV"), falling back to the model name. */
    fun deviceName(context: Context): String = Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
        ?.takeIf { it.isNotBlank() }
        ?: Build.MODEL

    /** IPv4 address on the active network (Wi-Fi/Ethernet), or null when offline. */
    fun localIpv4(context: Context): String? {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return null
        val props = cm.getLinkProperties(cm.activeNetwork) ?: return null
        return props.linkAddresses
            .map { it.address }
            .firstOrNull { it is Inet4Address && !it.isLoopbackAddress }
            ?.hostAddress
    }
}
