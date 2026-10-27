package com.giantmushroom.asgardchat

import android.content.Context
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_WEAK
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity

/** Fingerprint / face / screen-lock gate, like Face ID lock on iPhone. */
object AppLock {
    private const val AUTHENTICATORS = BIOMETRIC_WEAK or DEVICE_CREDENTIAL
    @Volatile var backgroundedAt = 0L

    fun available(context: Context) = BiometricManager.from(context).canAuthenticate(AUTHENTICATORS) == BiometricManager.BIOMETRIC_SUCCESS

    /** True when the app should ask to unlock now. */
    fun required(): Boolean {
        val prefs = AsgardApp.prefs
        if (!prefs.appLock) return false
        if (backgroundedAt == 0L) return true
        return System.currentTimeMillis() - backgroundedAt >= prefs.lockGraceSeconds * 1000
    }

    fun confirm(context: Context, reason: String, success: () -> Unit) {
        val activity = context as? FragmentActivity ?: run { success(); return }
        if (!available(activity)) { success(); return }
        BiometricPrompt(activity, ContextCompat.getMainExecutor(activity), object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) = success()
        }).authenticate(BiometricPrompt.PromptInfo.Builder().setTitle("Asgard").setSubtitle(reason).setAllowedAuthenticators(AUTHENTICATORS).build())
    }
}
