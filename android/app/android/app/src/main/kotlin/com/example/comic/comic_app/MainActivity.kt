package com.example.comic.comic_app

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Secret store channel — Komga credentials live in the Android Keystore,
 * never in the app database (mirrors `ServerProfile.credential_ref` on the
 * Apple side, which points into Keychain).
 *
 * Methods (channel "com.example.comic/auth_store"):
 *   save(ref: String, secret: String) -> bool
 *   read(ref: String) -> String?
 *   delete(ref: String) -> bool
 *   hasSecureStorage() -> bool   (false on API < 23 or when Keystore fails)
 *
 * Each secret is AES-256/GCM-encrypted with a Keystore-held master key; the
 * ciphertext (IV + payload) is stored in SharedPreferences. On API < 23 the
 * AES/GCM keystore is unavailable, so the store degrades to plain
 * Base64 + a log warning (modern devices all run API 23+).
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Stage 7: the two reader settings that belong to the OS rather than to
        // the database. Both are idempotent, and the reader restores the system
        // brightness when it closes.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            READER_CHANNEL,
        ).setMethodCallHandler { call, result ->
            val window = this.window
            when (call.method) {
                "setKeepScreenAwake" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    if (enabled) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(true)
                }
                "setBrightness" -> {
                    val level = call.argument<Double>("level")
                    val params = window.attributes
                    // null (and anything out of range) hands the screen back to
                    // the system, which is what -1 means on Android.
                    params.screenBrightness =
                        if (level == null || level < 0.05 || level > 1.0) {
                            WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                        } else {
                            level.toFloat()
                        }
                    window.attributes = params
                    result.success(true)
                }
                "totalMemory" -> {
                    // Stage 8: the prefetch window is sized from physical RAM,
                    // which only the platform knows. This is the device's total,
                    // not the app's allowance — the Rust planner applies its own
                    // fraction, floor and ceiling. 0 means "the platform will not
                    // say", which the planner resolves to its conservative tier.
                    val manager = this.getSystemService(Context.ACTIVITY_SERVICE)
                        as? android.app.ActivityManager
                    // `getMemoryInfo` fills a caller-allocated struct; there is no
                    // `memoryInfo` property to read. A null manager (no
                    // ACTIVITY_SERVICE, which should not happen) answers 0, and 0
                    // means "unknown" to the planner rather than "no memory".
                    val info = android.app.ActivityManager.MemoryInfo()
                    manager?.getMemoryInfo(info)
                    result.success(if (manager == null) 0L else info.totalMem)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "save" -> {
                    val ref = call.argument<String>("ref")
                    val secret = call.argument<String>("secret")
                    if (ref == null || secret == null) {
                        result.error("bad-args", "ref and secret are required", null)
                    } else {
                        result.success(store.save(ref, secret))
                    }
                }
                "read" -> {
                    val ref = call.argument<String>("ref")
                    if (ref == null) result.error("bad-args", "ref is required", null)
                    else result.success(store.read(ref))
                }
                "delete" -> {
                    val ref = call.argument<String>("ref")
                    if (ref == null) result.error("bad-args", "ref is required", null)
                    else result.success(store.delete(ref))
                }
                "hasSecureStorage" -> result.success(store.isSecure)
                else -> result.notImplemented()
            }
        }
    }

    private val store: AuthStore by lazy { AuthStore(applicationContext) }

    private companion object {
        const val CHANNEL = "com.example.comic/auth_store"
        const val READER_CHANNEL = "comic/reader"
    }
}

/** Keystore-backed AES-GCM secret store (see class doc above). */
class AuthStore(private val context: Context) {
    private val prefs =
        context.getSharedPreferences("comic_auth_store", Context.MODE_PRIVATE)
    private val keyStore: KeyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    val isSecure: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && masterKey() != null

    fun save(ref: String, secret: String): Boolean {
        val key = masterKey() ?: return false
        return try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, key)
            val iv = cipher.iv
            val encrypted = cipher.doFinal(secret.toByteArray(Charsets.UTF_8))
            prefs.edit()
                .putString(ref, encode(iv) + SEPARATOR + encode(encrypted))
                .commit()
        } catch (e: Exception) {
            logFallback(e)
            plainSave(ref, secret)
        }
    }

    fun read(ref: String): String? {
        val raw = prefs.getString(ref, null) ?: return null
        val key = masterKey() ?: return raw // degraded mode: plain Base64
        return try {
            val (ivPart, dataPart) = raw.split(SEPARATOR, limit = 2)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, decode(ivPart)))
            String(cipher.doFinal(decode(dataPart)), Charsets.UTF_8)
        } catch (e: Exception) {
            // Not encrypted (degraded mode) or corrupted — return as stored.
            decodeOrNull(raw)?.let { String(it, Charsets.UTF_8) }
        }
    }

    fun delete(ref: String): Boolean = prefs.edit().remove(ref).commit()

    private fun masterKey(): SecretKey? {
        return try {
            (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)
                ?: generateKey()
        } catch (e: Exception) {
            Log.w(TAG, "keystore unavailable: ${e.message}")
            null
        }
    }

    private fun generateKey(): SecretKey? {
        return try {
            val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
            generator.init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build(),
            )
            generator.generateKey()
        } catch (e: Exception) {
            Log.w(TAG, "key generation failed: ${e.message}")
            null
        }
    }

    private fun plainSave(ref: String, secret: String): Boolean {
        Log.w(TAG, "keystore unavailable — storing secret insecurely (API < 23)")
        return prefs.edit().putString(ref, encode(secret.toByteArray(Charsets.UTF_8))).commit()
    }

    private fun logFallback(e: Exception) {
        Log.w(TAG, "AES-GCM failed, falling back: ${e.message}")
    }

    private fun encode(bytes: ByteArray): String =
        Base64.encodeToString(bytes, Base64.NO_WRAP)

    private fun decode(part: String): ByteArray =
        Base64.decode(part, Base64.NO_WRAP)

    private fun decodeOrNull(part: String): ByteArray? =
        try {
            decode(part)
        } catch (e: Exception) {
            null
        }

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "comic_auth_master"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val SEPARATOR = ":"
        const val TAG = "ComicAuthStore"
    }
}