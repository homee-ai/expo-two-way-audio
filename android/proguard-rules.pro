# Keep the JNI bridge: the native methods are resolved by name at runtime, and
# the class hosting them must not be renamed/removed by release minification.
-keep class expo.modules.twowayaudio.QuailProcessor { *; }
-keepclasseswithmembernames class * {
    native <methods>;
}
