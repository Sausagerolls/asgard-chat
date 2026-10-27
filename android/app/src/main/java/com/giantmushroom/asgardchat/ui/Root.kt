package com.giantmushroom.asgardchat.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.giantmushroom.asgardchat.AsgardApp
import com.giantmushroom.asgardchat.engine.Phase
import com.giantmushroom.asgardchat.ui.components.AuroraBackground
import com.giantmushroom.asgardchat.ui.main.MainScreen
import com.giantmushroom.asgardchat.ui.onboarding.Onboarding

@Composable
fun Root(openChat: MutableState<String?>) {
    val phase by AsgardApp.engine.phase.collectAsState()
    AnimatedContent(phase, transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "phase") { p ->
        when (p) {
            Phase.Loading -> Box(Modifier.fillMaxSize()) { AuroraBackground(); CircularProgressIndicator(Modifier.align(Alignment.Center)) }
            Phase.SignedOut -> Onboarding()
            Phase.Ready -> MainScreen(openChat)
        }
    }
}
