# Keep JNI callbacks and native bridge methods
-keep class ren.onekb.openuu.OpenUUNativeBridge { *; }
-keep interface ren.onekb.openuu.NativeCallbackListener { *; }
-keep class * implements ren.onekb.openuu.NativeCallbackListener { *; }
-keep class ren.onekb.openuu.priv.** { *; }
-keep, includedescriptorclasses class org.rustls.platformverifier.** { *; }
