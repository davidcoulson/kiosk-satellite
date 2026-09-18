package me.jxl.kiosk_satellite

import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Wraps the settings that are secrets -- the Home Assistant token, camera and
 * Immich credentials, identity keys, the token-signing secret -- under a key
 * that lives in the Android Keystore and never in the app's files.
 *
 * They used to sit in the preferences XML as typed, so a copy of that file
 * was a copy of the secrets: a cloud backup, a device-to-device transfer, a
 * file pulled off the panel. What the file holds now is useless without the
 * key, and the key cannot be copied off the device; on hardware with a secure
 * element it cannot be read out even by root.
 *
 * It is a narrowing, not a wall. Code running as this app on this device can
 * ask the Keystore to unwrap, and root can become this app. What it ends is
 * the file being enough.
 *
 * Deliberately dumb: it wraps and unwraps strings and decides nothing. Which
 * settings are secrets, what to do when one will not unwrap, and when it is
 * safe to start using this at all are SettingsManager's business, where they
 * can be tested without a Keystore.
 */
class SecretVault(messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "kiosk_satellite/secret_vault")

    // Keystore calls can take tens of milliseconds each where a secure
    // element backs them, and a panel unwraps a dozen at launch.
    private val worker = Executors.newSingleThreadExecutor { r ->
        Thread(r, "secret-vault").apply { isDaemon = true }
    }
    private val main = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler { call, result ->
            val values = call.argument<List<String>>("values") ?: emptyList()
            worker.execute {
                val reply: Any? = try {
                    when (call.method) {
                        // A null entry is one that would not wrap or unwrap;
                        // the rest of the batch is still answered.
                        "wrap" -> values.map { runCatching { wrap(it) }.getOrNull() }
                        "unwrap" -> values.map { runCatching { unwrap(it) }.getOrNull() }
                        "selfTest" -> selfTest()
                        else -> NOT_IMPLEMENTED
                    }
                } catch (e: Throwable) {
                    e
                }
                main.post {
                    when {
                        reply === NOT_IMPLEMENTED -> result.notImplemented()
                        reply is Throwable -> result.error("vault", reply.message, null)
                        else -> result.success(reply)
                    }
                }
            }
        }
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance(STORE).apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, STORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                // A kiosk has no lock screen to authenticate against, and
                // must read its token at boot with nobody there.
                .setUserAuthenticationRequired(false)
                .build(),
        )
        return generator.generateKey()
    }

    /** base64(iv | ciphertext+tag). The Keystore picks the IV. */
    private fun wrap(plain: String): String {
        val cipher = Cipher.getInstance(TRANSFORM)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(cipher.iv + sealed, Base64.NO_WRAP)
    }

    private fun unwrap(wrapped: String): String {
        val bytes = Base64.decode(wrapped, Base64.NO_WRAP)
        require(bytes.size > IV_BYTES) { "too short to be a wrapped value" }
        val cipher = Cipher.getInstance(TRANSFORM)
        cipher.init(
            Cipher.DECRYPT_MODE,
            key(),
            GCMParameterSpec(TAG_BITS, bytes, 0, IV_BYTES),
        )
        return String(cipher.doFinal(bytes, IV_BYTES, bytes.size - IV_BYTES), Charsets.UTF_8)
    }

    /**
     * Whether this device's Keystore really does round-trip a value. Asked
     * before anything is entrusted to it: vendor builds exist whose Keystore
     * generates a key and then cannot use it, and a panel that found that
     * out after wrapping its only copy of a token would need somebody to
     * come and set it up again.
     */
    private fun selfTest(): Boolean = try {
        val probe = "ks-vault-probe-é中"
        unwrap(wrap(probe)) == probe
    } catch (_: Throwable) {
        false
    }

    private companion object {
        const val STORE = "AndroidKeyStore"
        const val ALIAS = "ks_secret_vault_v1"
        const val TRANSFORM = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
        const val TAG_BITS = 128
        val NOT_IMPLEMENTED = Any()
    }
}
