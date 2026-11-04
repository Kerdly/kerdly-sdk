# Applied to the host app's R8/ProGuard run.
#
# The public API stays intact for wrappers that reach it by name (the Expo bridge, Java callers,
# reflection-based bridges). Everything under com.kerdly.sdk.internal may be shrunk and obfuscated.
-keep class com.kerdly.sdk.Kerdly { public *; }
-keep class com.kerdly.sdk.KerdlyOptions { *; }
-keep class com.kerdly.sdk.KerdlyDeepLink { *; }
-keep class com.kerdly.sdk.KerdlyPurchase { *; }
-keep class com.kerdly.sdk.KerdlyNetworkSend { *; }
-keep class com.kerdly.sdk.KerdlyAttribution { *; }
-keep enum com.kerdly.sdk.KerdlyEnvironment { *; }
-keep enum com.kerdly.sdk.KerdlyLogLevel { *; }

# Install Referrer and the advertising-id client are called directly (no reflection) and ship
# their own consumer rules.
