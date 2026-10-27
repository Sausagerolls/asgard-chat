package com.giantmushroom.asgardchat.ui.onboarding

import androidx.compose.animation.AnimatedContent
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.giantmushroom.asgardchat.AsgardApp
import com.giantmushroom.asgardchat.R
import com.giantmushroom.asgardchat.net.ApiClient
import com.giantmushroom.asgardchat.net.ApiError
import com.giantmushroom.asgardchat.net.ServerInfo
import com.giantmushroom.asgardchat.ui.components.AuroraBackground
import com.giantmushroom.asgardchat.ui.components.glass
import com.giantmushroom.asgardchat.ui.theme.Brand
import kotlinx.coroutines.launch

@Composable
fun Onboarding() {
    var step by remember { mutableStateOf(0) }
    Box(Modifier.fillMaxSize()) {
        AuroraBackground()
        AnimatedContent(step, label = "onboarding") { s ->
            if (s == 0) Welcome { step = 1 } else Connect { step = 0 }
        }
    }
}

@Composable
private fun Welcome(next: () -> Unit) {
    Column(Modifier.fillMaxSize().safeDrawingPadding().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Spacer(Modifier.weight(1f))
        Image(painterResource(R.drawable.brand_mark), null, Modifier.size(96.dp))
        Spacer(Modifier.height(20.dp))
        Text("Asgard", fontSize = 44.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurface)
        Text("Private messaging on a server you own.\nEnd-to-end encrypted, always.", textAlign = TextAlign.Center,
            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 8.dp))
        Spacer(Modifier.weight(1f))
        Column(Modifier.fillMaxWidth().glass(RoundedCornerShape(24.dp)).padding(18.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Feature(Icons.Filled.Lock, "Messages, calls and media are encrypted on your device")
            Feature(Icons.Filled.Storage, "Your server, your rules, your data")
            Feature(Icons.Filled.AutoAwesome, "Drop into voice rooms from any group")
        }
        Spacer(Modifier.height(28.dp))
        Button(next, Modifier.fillMaxWidth().height(54.dp), shape = RoundedCornerShape(27.dp)) { Text("Get started", fontWeight = FontWeight.SemiBold) }
    }
}

@Composable
private fun Feature(icon: ImageVector, text: String) = Row(verticalAlignment = Alignment.CenterVertically) {
    Icon(icon, null, tint = Brand.teal, modifier = Modifier.size(22.dp))
    Text(text, Modifier.padding(start = 12.dp), style = MaterialTheme.typography.bodyMedium)
}

private enum class Mode(val title: String) { SignUp("Create account"), SignIn("Sign in"), Link("Link device") }

@Composable
private fun Connect(back: () -> Unit) {
    val engine = AsgardApp.engine
    val scope = rememberCoroutineScope()
    var server by remember { mutableStateOf(engine.accounts.lastServer) }
    var info by remember { mutableStateOf<ServerInfo?>(null) }
    var mode by remember { mutableStateOf(Mode.SignUp) }
    var invite by remember { mutableStateOf("") }
    var username by remember { mutableStateOf("") }
    var displayName by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    fun url(): String { val s = server.trim().trimEnd('/'); return if ("://" in s) s else "https://$s" }
    fun check() = scope.launch {
        working = true; error = null
        try { info = ApiClient(url(), null).info(); server = url(); engine.accounts.lastServer = server }
        catch (e: Exception) { info = null; error = (e as? ApiError)?.message ?: e.message }
        working = false
    }
    fun submit() = scope.launch {
        working = true; error = null
        try {
            when (mode) {
                Mode.SignUp -> engine.signUp(url(), invite.trim(), username.trim(), displayName.ifBlank { username }.trim(), password)
                Mode.SignIn -> engine.signIn(url(), username.trim(), password)
                Mode.Link -> engine.claimDeviceLink(url(), code.trim().uppercase())
            }
        } catch (e: Exception) { error = (e as? ApiError)?.message ?: e.message }
        working = false
    }

    Column(Modifier.fillMaxSize().safeDrawingPadding().imePadding().verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)) {
        IconButton(back, Modifier.glass(RoundedCornerShape(50))) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
        Text("Connect", fontSize = 34.sp, fontWeight = FontWeight.Bold)
        Column(Modifier.glass().padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Your server", style = MaterialTheme.typography.titleSmall)
            OutlinedTextField(server, { server = it; info = null }, Modifier.fillMaxWidth(), singleLine = true, placeholder = { Text("https://chat.example.com") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
            info?.let { Text("✓ ${it.name} · Asgard ${it.version}", color = Brand.teal, style = MaterialTheme.typography.bodySmall) }
            if (info == null) Button(::check, enabled = !working) { Text("Check") }
        }
        if (info != null) {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                Mode.entries.forEachIndexed { i, m ->
                    SegmentedButton(mode == m, { mode = m }, SegmentedButtonDefaults.itemShape(i, Mode.entries.size)) { Text(m.title, fontSize = 12.sp) }
                }
            }
            Column(Modifier.glass().padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                when (mode) {
                    Mode.SignUp -> {
                        OutlinedTextField(invite, { invite = it }, Modifier.fillMaxWidth(), label = { Text("Invite code") }, singleLine = true)
                        OutlinedTextField(username, { username = it }, Modifier.fillMaxWidth(), label = { Text("Username") }, singleLine = true)
                        OutlinedTextField(displayName, { displayName = it }, Modifier.fillMaxWidth(), label = { Text("Display name") }, singleLine = true)
                        OutlinedTextField(password, { password = it }, Modifier.fillMaxWidth(), label = { Text("Password (10+ characters)") }, singleLine = true,
                            visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
                    }
                    Mode.SignIn -> {
                        OutlinedTextField(username, { username = it }, Modifier.fillMaxWidth(), label = { Text("Username") }, singleLine = true)
                        OutlinedTextField(password, { password = it }, Modifier.fillMaxWidth(), label = { Text("Password") }, singleLine = true,
                            visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
                        Text("Signing in adds this phone as a new device. You'll be asked for your recovery key to bring your message history.",
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Mode.Link -> {
                        Text("On a device you already use: Settings › Devices › Link a device, then enter the code shown under the QR code. Your message history comes across automatically.",
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        val scan = com.giantmushroom.asgardchat.ui.components.rememberQrScanner("Scan the QR code on your other device") { payload ->
                            val uri = android.net.Uri.parse(payload)
                            if (uri.scheme == "asgard" && uri.host == "link" && uri.getQueryParameter("code") != null) {
                                code = uri.getQueryParameter("code")!!
                                submit()
                            } else error = "That isn't an Asgard link code."
                        }
                        Button(scan, Modifier.fillMaxWidth()) { Text("Scan QR code") }
                        OutlinedTextField(code, { code = it }, Modifier.fillMaxWidth(), label = { Text("…or type the code") }, singleLine = true)
                    }
                }
            }
            val valid = when (mode) { Mode.SignUp -> invite.isNotBlank() && username.length >= 3 && password.length >= 10; Mode.SignIn -> username.isNotBlank() && password.isNotBlank(); Mode.Link -> code.length >= 8 }
            Button(::submit, Modifier.fillMaxWidth().height(52.dp), enabled = valid && !working, shape = RoundedCornerShape(26.dp)) {
                if (working) CircularProgressIndicator(Modifier.size(20.dp), color = Color.White, strokeWidth = 2.dp) else Text(mode.title, fontWeight = FontWeight.SemiBold)
            }
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        if (working && info == null) CircularProgressIndicator()
    }
    androidx.compose.runtime.LaunchedEffect(Unit) { check() }
}
