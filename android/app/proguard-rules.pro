# App không dùng reflection; các thư viện AndroidX/Compose tự mang consumer rules.
# Bỏ log verbose/debug trong bản release.
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
}
