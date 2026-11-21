package ren.onekb.openuu

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Color as AndroidColor
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.ViewModelProvider

private val OpenUUDarkColorScheme = darkColorScheme(
    primary = Color(0xFF10B981),           // Emerald 500
    onPrimary = Color(0xFF022C22),         // Emerald 950
    primaryContainer = Color(0xFF064E3B),  // Emerald 900
    onPrimaryContainer = Color(0xFFA7F3D0),// Emerald 200
    secondary = Color(0xFF6366F1),         // Indigo 500
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFF312E81),// Indigo 900
    onSecondaryContainer = Color(0xFFE0E7FF),
    tertiary = Color(0xFF22D3EE),          // Cyan 400
    onTertiary = Color(0xFF083344),
    tertiaryContainer = Color(0xFF164E63),
    onTertiaryContainer = Color(0xFFCFFAFE),
    background = Color(0xFF0B0F19),        // Deep Slate-Indigo
    onBackground = Color(0xFFF1F5F9),
    surface = Color(0xFF111827),
    onSurface = Color(0xFFF1F5F9),
    surfaceVariant = Color(0xFF1E293B),
    onSurfaceVariant = Color(0xFF94A3B8),
    surfaceContainerLowest = Color(0xFF070A12),
    surfaceContainerLow = Color(0xFF0F1624),
    surfaceContainer = Color(0xFF151E30),
    surfaceContainerHigh = Color(0xFF1C273D),
    surfaceContainerHighest = Color(0xFF24324B),
    outline = Color(0xFF334155),
    outlineVariant = Color(0xFF1E293B),
    error = Color(0xFFF43F5E),
    onError = Color(0xFFFFFFFF),
    errorContainer = Color(0xFF881337),
    onErrorContainer = Color(0xFFFFE4E6)
)

private val OpenUUTypography = Typography(
    headlineSmall = TextStyle(
        fontWeight = FontWeight.Bold,
        fontSize = 22.sp,
        lineHeight = 28.sp,
        letterSpacing = (-0.2).sp
    ),
    titleMedium = TextStyle(
        fontWeight = FontWeight.SemiBold,
        fontSize = 16.sp,
        lineHeight = 22.sp
    ),
    titleSmall = TextStyle(
        fontWeight = FontWeight.SemiBold,
        fontSize = 14.sp,
        lineHeight = 20.sp
    ),
    bodyMedium = TextStyle(
        fontWeight = FontWeight.Normal,
        fontSize = 14.sp,
        lineHeight = 20.sp
    ),
    bodySmall = TextStyle(
        fontWeight = FontWeight.Normal,
        fontSize = 12.sp,
        lineHeight = 16.sp
    ),
    labelMedium = TextStyle(
        fontWeight = FontWeight.Medium,
        fontSize = 12.sp,
        lineHeight = 16.sp
    ),
    labelSmall = TextStyle(
        fontWeight = FontWeight.Medium,
        fontSize = 10.sp,
        lineHeight = 14.sp
    )
)

@Composable
fun OpenUUTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = OpenUUDarkColorScheme,
        typography = OpenUUTypography,
        content = content
    )
}

class MainActivity : ComponentActivity() {

    private val viewModel: OpenUUViewModel by lazy {
        ViewModelProvider(this)[OpenUUViewModel::class.java]
    }

    private val notificationPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { /* Permission result handled gracefully; app works either way */ }

    private val filePickerLauncher = registerForActivityResult(
        ActivityResultContracts.GetContent()
    ) { uri ->
        if (uri != null) {
            viewModel.sendPickedFileUri(uri)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(AndroidColor.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(AndroidColor.TRANSPARENT)
        )
        super.onCreate(savedInstanceState)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }

        requestNotificationPermissionIfNeeded()

        setContent {
            OpenUUTheme {
                val selectedTab by viewModel.selectedTab.collectAsState()
                val connectionPhase by viewModel.connectionPhase.collectAsState()
                val showAppLauncher by viewModel.showAppLauncher.collectAsState()
                val selectedWindowId by viewModel.selectedWindowId.collectAsState()
                val manualFullscreen by viewModel.manualFullscreen.collectAsState()

                val isLandscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
                val isImmersiveFullscreen = (
                    selectedTab == MainTab.REMOTE &&
                        connectionPhase.isConnected &&
                        !showAppLauncher &&
                        selectedWindowId != 0
                    ) && (isLandscape || manualFullscreen)

                val rootView = LocalView.current

                DisposableEffect(connectionPhase.isConnected) {
                    if (connectionPhase.isConnected) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    onDispose {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                }

                DisposableEffect(isImmersiveFullscreen) {
                    val controller = WindowCompat.getInsetsController(window, rootView)
                    val bars = WindowInsetsCompat.Type.statusBars() or WindowInsetsCompat.Type.navigationBars()
                    if (isImmersiveFullscreen) {
                        controller.systemBarsBehavior =
                            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                        controller.hide(bars)
                    } else {
                        controller.show(bars)
                    }
                    onDispose {
                        controller.show(bars)
                    }
                }

                Surface(color = MaterialTheme.colorScheme.background) {
                    MainScreen(
                        viewModel = viewModel,
                        isImmersiveFullscreen = isImmersiveFullscreen,
                        isLandscape = isLandscape,
                        onPickFile = { filePickerLauncher.launch("*/*") }
                    )
                }
            }
        }

        handleE2ELaunchIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleE2ELaunchIntent(intent)
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
            if (!granted) {
                notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
    }

    private fun handleE2ELaunchIntent(intent: Intent?) {
        if (intent == null) return
        val target = intent.getStringExtra("e2e_target")?.trim().orEmpty()
        if (target.isEmpty()) return

        val pin = intent.getStringExtra("e2e_pin")?.trim().orEmpty()
        val appBundleId = intent.getStringExtra("e2e_app")?.trim().orEmpty()
        val autoTestRaw = intent.extras?.get("e2e_autotest")
        val autoTest = when (autoTestRaw) {
            is Boolean -> autoTestRaw
            is String -> autoTestRaw.trim().lowercase().let { it == "true" || it == "1" }
            else -> false
        }

        // Clear extra so configuration changes do not re-trigger
        intent.removeExtra("e2e_target")
        viewModel.handleE2EIntent(
            target = target,
            pin = pin,
            appBundleId = appBundleId,
            autoTest = autoTest
        )
    }
}
