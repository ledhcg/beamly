package com.mac2tv.receiver.net

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log

/** Quảng bá dịch vụ [Protocol.SERVICE_TYPE] qua mDNS/DNS-SD để Mac tự tìm thấy TV. */
class NsdAdvertiser(context: Context) {

    private val nsd = context.getSystemService(NsdManager::class.java)
    private var registration: NsdManager.RegistrationListener? = null

    fun register(serviceName: String, port: Int) {
        if (registration != null) return
        val info = NsdServiceInfo().apply {
            this.serviceName = serviceName
            serviceType = Protocol.SERVICE_TYPE
            this.port = port
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                Log.i(TAG, "Advertising as \"${info.serviceName}\"")
            }

            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "Registration failed: $errorCode")
                if (registration === this) registration = null
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) = Unit
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) = Unit
        }
        registration = listener
        runCatching { nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener) }
            .onFailure {
                Log.w(TAG, "registerService failed", it)
                registration = null
            }
    }

    fun unregister() {
        registration?.let { runCatching { nsd.unregisterService(it) } }
        registration = null
    }

    private companion object {
        const val TAG = "NsdAdvertiser"
    }
}
