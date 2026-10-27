# kotlinx.serialization
-keepattributes *Annotation*, InnerClasses
-keepclassmembers class com.giantmushroom.asgardchat.** { *** Companion; }
-keepclasseswithmembers class com.giantmushroom.asgardchat.** { kotlinx.serialization.KSerializer serializer(...); }
# BouncyCastle and LiveKit/WebRTC use reflection and JNI.
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**
-keep class org.webrtc.** { *; }
-keep class livekit.** { *; }
