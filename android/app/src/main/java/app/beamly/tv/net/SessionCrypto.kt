package app.beamly.tv.net

import java.math.BigInteger
import java.net.ProtocolException
import java.nio.ByteBuffer
import java.security.GeneralSecurityException
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.interfaces.ECPrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECFieldFp
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Cryptography of protocol version 2 (docs/PROTOCOL.md §4.2, §6, §7), on the platform JCA so it runs on
 * Android 8+ and in JVM unit tests. Verified against `protocol/test-vectors/crypto.json`.
 */
object SessionCrypto {
    const val PUBLIC_KEY_LENGTH = 65
    const val NONCE_LENGTH = 32
    private const val COORDINATE_LENGTH = 32

    private val random = SecureRandom()

    /** NIST P-256 domain parameters, taken from a generated key so no provider-specific name lookup is needed. */
    private val curve: ECParameterSpec by lazy { (generateKeyPair().public as ECPublicKey).params }

    fun generateKeyPair(): KeyPair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1"), random) }
        .generateKeyPair()

    /** Uncompressed SEC 1 encoding: `0x04 ‖ X ‖ Y`. */
    fun encodePublicKey(key: PublicKey): ByteArray {
        val point = (key as ECPublicKey).w
        return byteArrayOf(4) + fixedLength(point.affineX) + fixedLength(point.affineY)
    }

    /** Decodes and validates an uncompressed P-256 point; rejects points that are not on the curve. */
    fun decodePublicKey(bytes: ByteArray): PublicKey {
        if (bytes.size != PUBLIC_KEY_LENGTH || bytes[0] != 4.toByte()) throw ProtocolException("Malformed public key")
        val x = BigInteger(1, bytes.copyOfRange(1, 33))
        val y = BigInteger(1, bytes.copyOfRange(33, 65))
        val p = (curve.curve.field as ECFieldFp).p
        val onCurve = y.pow(2).mod(p) == x.pow(3).add(curve.curve.a.multiply(x)).add(curve.curve.b).mod(p)
        if (x >= p || y >= p || !onCurve) throw ProtocolException("Public key is not on the curve")
        return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(x, y), curve))
    }

    fun encodePrivateKey(key: PrivateKey): ByteArray = fixedLength((key as ECPrivateKey).s)

    fun decodePrivateKey(scalar: ByteArray): PrivateKey =
        KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(BigInteger(1, scalar), curve))

    /** Rebuilds a key pair from a stored private scalar and public key. */
    fun keyPair(privateScalar: ByteArray, publicKey: ByteArray): KeyPair =
        KeyPair(decodePublicKey(publicKey), decodePrivateKey(privateScalar))

    /** ECDH: the 32-byte X coordinate of the shared point. */
    fun ecdh(privateKey: PrivateKey, publicKey: PublicKey): ByteArray = KeyAgreement.getInstance("ECDH").run {
        init(privateKey)
        doPhase(publicKey, true)
        generateSecret()
    }

    fun sha256(vararg parts: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").run {
        parts.forEach(::update)
        digest()
    }

    fun hmacSha256(key: ByteArray, vararg parts: ByteArray): ByteArray = Mac.getInstance("HmacSHA256").run {
        init(SecretKeySpec(key, "HmacSHA256"))
        parts.forEach(::update)
        doFinal()
    }

    /** HKDF-SHA256 (RFC 5869). */
    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val prk = hmacSha256(salt, ikm)
        val out = ByteArray(length)
        var previous = ByteArray(0)
        var offset = 0
        var counter = 1
        while (offset < length) {
            previous = hmacSha256(prk, previous, info, byteArrayOf(counter.toByte()))
            val count = minOf(previous.size, length - offset)
            System.arraycopy(previous, 0, out, offset, count)
            offset += count
            counter++
        }
        return out
    }

    /** `HMAC-SHA256(Nt, "beamly-pair-commit" ‖ IDt ‖ IDm)`. */
    fun commitment(tvNonce: ByteArray, tvIdentity: ByteArray, macIdentity: ByteArray): ByteArray =
        hmacSha256(tvNonce, "beamly-pair-commit".toByteArray(Charsets.US_ASCII), tvIdentity, macIdentity)

    /** `uint32(SHA-256("beamly-pair-code" ‖ IDm ‖ IDt ‖ Nm ‖ Nt)[0..4]) mod 10⁶`, as six digits. */
    fun pairingCode(macIdentity: ByteArray, tvIdentity: ByteArray, macNonce: ByteArray, tvNonce: ByteArray): String {
        val digest = sha256("beamly-pair-code".toByteArray(Charsets.US_ASCII), macIdentity, tvIdentity, macNonce, tvNonce)
        val value = ByteBuffer.wrap(digest, 0, 4).int.toLong() and 0xffffffffL
        return "%06d".format(value % 1_000_000)
    }

    /** Session keys as seen by the TV (the receiver): returns (Mac → TV key, TV → Mac key). */
    fun sessionKeysForTv(
        tvIdentity: PrivateKey,
        tvEphemeral: PrivateKey,
        macIdentity: PublicKey,
        macEphemeral: PublicKey,
        helloPayload: ByteArray,
        serverHelloPayload: ByteArray
    ): Pair<ByteArray, ByteArray> {
        val ikm = ecdh(tvEphemeral, macEphemeral) + // ss1
            ecdh(tvEphemeral, macIdentity) + // ss2
            ecdh(tvIdentity, macEphemeral) // ss3
        val okm = hkdf(ikm, sha256(helloPayload, serverHelloPayload), "beamly v2 session".toByteArray(Charsets.US_ASCII), 64)
        return okm.copyOfRange(0, 32) to okm.copyOfRange(32, 64)
    }

    fun randomBytes(count: Int): ByteArray = ByteArray(count).also(random::nextBytes)

    private fun fixedLength(value: BigInteger): ByteArray {
        val bytes = value.toByteArray()
        return when {
            bytes.size == COORDINATE_LENGTH -> bytes
            bytes.size > COORDINATE_LENGTH -> bytes.copyOfRange(bytes.size - COORDINATE_LENGTH, bytes.size)
            else -> ByteArray(COORDINATE_LENGTH - bytes.size) + bytes
        }
    }
}

/**
 * AES-256-GCM record layer for one direction (docs/PROTOCOL.md §4.2). Not thread-safe.
 * Plaintext: `u8 type ‖ u64 ptsMicros ‖ payload`; nonce `0x00000000 ‖ u64 counter`.
 */
class RecordCipher(key: ByteArray) {
    private val secretKey = SecretKeySpec(key, "AES")
    private val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    var counter = 0L
        private set

    /** Encrypts one packet and returns the complete record: `u32 length ‖ ciphertext ‖ tag`. */
    fun seal(type: Int, ptsMicros: Long, payload: ByteArray, offset: Int = 0, length: Int = payload.size): ByteArray {
        val plaintext = ByteBuffer.allocate(HEADER + length).put(type.toByte()).putLong(ptsMicros).put(payload, offset, length).array()
        cipher.init(Cipher.ENCRYPT_MODE, secretKey, GCMParameterSpec(TAG_BITS, nextNonce()))
        val sealed = cipher.doFinal(plaintext)
        return ByteBuffer.allocate(4 + sealed.size).putInt(sealed.size).put(sealed).array()
    }

    /**
     * Decrypts [length] bytes of [ciphertext] (without the length prefix) into [output].
     * @return the plaintext length.
     * @throws ProtocolException if authentication fails (tampering, replay or reordering).
     */
    fun open(ciphertext: ByteArray, length: Int, output: ByteArray): Int {
        if (length < OVERHEAD) throw ProtocolException("Encrypted record is too short")
        return try {
            cipher.init(Cipher.DECRYPT_MODE, secretKey, GCMParameterSpec(TAG_BITS, nextNonce()))
            cipher.doFinal(ciphertext, 0, length, output, 0)
        } catch (e: GeneralSecurityException) {
            throw ProtocolException("Record authentication failed").apply { initCause(e) }
        }
    }

    private fun nextNonce(): ByteArray {
        if (counter == -1L) throw ProtocolException("Record counter exhausted")
        return ByteBuffer.allocate(12).putInt(0).putLong(counter++).array()
    }

    companion object {
        private const val TAG_BITS = 128
        private const val HEADER = 9

        /** Header (9) + GCM tag (16). */
        const val OVERHEAD = HEADER + 16
    }
}
