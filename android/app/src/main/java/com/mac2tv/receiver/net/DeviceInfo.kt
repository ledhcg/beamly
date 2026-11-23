package com.mac2tv.receiver.net

import android.content.Context
import android.net.ConnectivityManager
import android.os.Build
import android.provider.Settings
import java.net.Inet4Address

object DeviceInfo {

    /** Tên TV người dùng đặt trong Cài đặt (vd. "TV Phòng Khách"), mặc định là model. */
    fun deviceName(context: Context): String =
        Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
            ?.takeIf { it.isNotBlank() }
            ?: Build.MODEL

    /** IPv4 của mạng đang dùng (Wi-Fi/Ethernet), hoặc null nếu chưa có mạng. */
    fun localIpv4(context: Context): String? {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return null
        val props = cm.getLinkProperties(cm.activeNetwork) ?: return null
        return props.linkAddresses
            .map { it.address }
            .firstOrNull { it is Inet4Address && !it.isLoopbackAddress }
            ?.hostAddress
    }
}
