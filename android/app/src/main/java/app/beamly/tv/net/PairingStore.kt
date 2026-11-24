package app.beamly.tv.net

import android.content.Context
import android.util.Base64
import java.security.KeyPair
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

/** A Mac this TV accepts streams from. */
data class PairedMac(val name: String, val identityKey: String, val pairedAt: Long)

/**
 * This TV's identity key and the Macs it has paired with, in the app's private storage (not backed up:
 * `allowBackup` is false). Thread-safe.
 */
class PairingStore(context: Context) {
    private val prefs = context.getSharedPreferences("beamly_pairing", Context.MODE_PRIVATE)
    private val lock = Any()
    private var identity: KeyPair? = null

    private val _pairedMacs = MutableStateFlow(load())
    val pairedMacs: StateFlow<List<PairedMac>> = _pairedMacs.asStateFlow()

    /** The TV's identity key pair, created on first use. */
    fun identity(): KeyPair = synchronized(lock) {
        identity?.let { return it }
        val stored = runCatching {
            val scalar = prefs.getString(KEY_PRIVATE, null)?.let(::decode)
            val public = prefs.getString(KEY_PUBLIC, null)?.let(::decode)
            if (scalar != null && public != null) SessionCrypto.keyPair(scalar, public) else null
        }.getOrNull()
        val pair = stored ?: SessionCrypto.generateKeyPair().also {
            prefs.edit()
                .putString(KEY_PRIVATE, encode(SessionCrypto.encodePrivateKey(it.private)))
                .putString(KEY_PUBLIC, encode(SessionCrypto.encodePublicKey(it.public)))
                .apply()
        }
        identity = pair
        pair
    }

    fun isPaired(identityKey: ByteArray): Boolean = encode(identityKey).let { key -> _pairedMacs.value.any { it.identityKey == key } }

    fun pair(name: String, identityKey: ByteArray) = synchronized(lock) {
        val key = encode(identityKey)
        save(_pairedMacs.value.filter { it.identityKey != key } + PairedMac(name, key, System.currentTimeMillis()))
    }

    fun forget(mac: PairedMac) = synchronized(lock) {
        save(_pairedMacs.value.filter { it.identityKey != mac.identityKey })
    }

    private fun save(list: List<PairedMac>) {
        val json = JSONArray()
        list.forEach { json.put(JSONObject().put("name", it.name).put("key", it.identityKey).put("pairedAt", it.pairedAt)) }
        prefs.edit().putString(KEY_PAIRED, json.toString()).apply()
        _pairedMacs.value = list
    }

    private fun load(): List<PairedMac> = runCatching {
        val json = JSONArray(prefs.getString(KEY_PAIRED, "[]"))
        (0 until json.length()).map {
            val item = json.getJSONObject(it)
            PairedMac(item.getString("name"), item.getString("key"), item.getLong("pairedAt"))
        }
    }.getOrDefault(emptyList())

    private fun encode(bytes: ByteArray) = Base64.encodeToString(bytes, Base64.NO_WRAP)
    private fun decode(text: String) = Base64.decode(text, Base64.NO_WRAP)

    private companion object {
        const val KEY_PRIVATE = "identity_private"
        const val KEY_PUBLIC = "identity_public"
        const val KEY_PAIRED = "paired_macs"
    }
}
