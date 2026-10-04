package uk.pixxula.habytes

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import com.linusu.flutter_web_auth_2.FlutterWebAuth2Plugin

/**
 * Receives `habitd://auth?code=...` at the end of the sign-in and hands it to
 * the waiting `flutter_web_auth_2` call.
 *
 * Used in place of the plugin's own callback activity, which leaves the
 * browser tab open when the browser delivers the redirect in a separate task
 * (Firefox does). Returning to [MainActivity] with `CLEAR_TOP` closes whatever
 * sits above it, whichever browser was used.
 */
class AuthCallbackActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val url = intent?.data
        val scheme = url?.scheme
        if (scheme != null) {
            FlutterWebAuth2Plugin.callbacks.remove(scheme)?.success(url.toString())
        }
        startActivity(
            Intent(this, MainActivity::class.java).addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            ),
        )
        finish()
    }
}
