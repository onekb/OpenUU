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
    primary = Color(0xFFF4F4F6),           // Solid crisp off-white
    onPrimary = Color(0xFF09090B),         // Zinc 950
    primaryContainer = Color(0xFF27272F),
    onPrimaryContainer = Color(0xFFF4F4F6),
    secondary = Color(0xFF27272F),
    onSecondary = Color(0xFFE4E4E7),
    secondaryContainer = Color(0xFF1E1E24),
    onSecondaryContainer = Color(0xFFE4E4E7),
    tertiary = Color(0xFFA1A1AA),
    onTertiary = Color(0xFF09090B),
    tertiaryContainer = Color(0xFF27272F),
    onTertiaryContainer = Color(0xFFE4E4E7),
    background = Color(0xFF09090B),        // Zinc 950 Obsidian
    onBackground = Color(0xFFF4F4F6),
    surface = Color(0xFF111114),
    onSurface = Color(0xFFF4F4F6),
    surfaceVariant = Color(0xFF1E1E24),
    onSurfaceVariant = Color(0xFF8E8E98),
    surfaceContainerLowest = Color(0xFF070709),
    surfaceContainerLow = Color(0xFF121215),
    surfaceContainer = Color(0xFF16161A),
    surfaceContainerHigh = Color(0xFF1E1E24),
    surfaceContainerHighest = Color(0xFF27272F),
    outline = Color(0xFF27272E),
    outlineVariant = Color(0xFF232329),
    error = Color(0xFFFF453A),
    onError = Color(0xFFFFFFFF),
    errorContainer = Color(0xFF2C1214),
    onErrorContainer = Color(0xFFFF6961)
)

private val OpenUUTypography = Typography(
    headlineSmall = TextStyle(
        fontWeight = FontWeight.SemiBold,
        fontSize = 20.sp,
        lineHeight = 26.sp,
        letterSpacing = (-0.4).sp
    ),
    titleMedium = TextStyle(
        fontWeight = FontWeight.SemiBold,
        fontSize = 16.sp,
        lineHeight = 22.sp,
        letterSpacing = (-0.2).sp
    ),
    titleSmall = TextStyle(
        fontWeight = FontWeight.Medium,
        fontSize = 14.sp,
        lineHeight = 20.sp,
        letterSpacing = (-0.1).sp
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
        fontSize = 11.sp,
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

    private val mediaProjectionLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        val data = result.data
        if (result.resultCode == RESULT_OK && data != null) {
            viewModel.startLocalHostWithProjection(result.resultCode, data)
        }
    }

    private val audioRecordPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) {
        launchScreenCaptureConsent()
    }

    private fun requestStartLocalHost() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val audioGranted = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.RECORD_AUDIO
            ) == PackageManager.PERMISSION_GRANTED
            if (!audioGranted) {
                audioRecordPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                return
            }
        }
        launchScreenCaptureConsent()
    }

    private fun launchScreenCaptureConsent() {
        val mpm = getSystemService(MEDIA_PROJECTION_SERVICE) as? android.media.projection.MediaProjectionManager
            ?: return
        mediaProjectionLauncher.launch(mpm.createScreenCaptureIntent())
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
                val selectedWindowId by viewModel.selectedWindowId.collectAsState()
                val manualFullscreen by viewModel.manualFullscreen.collectAsState()

                val isLandscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
                val isImmersiveFullscreen = (
                    selectedTab == MainTab.REMOTE &&
                        connectionPhase.isConnected &&
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
                        onPickFile = { filePickerLauncher.launch("*/*") },
                        onRequestStartHost = { requestStartLocalHost() }
                    )
                }
            }
        }

        handleE2ELaunchIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        viewModel.refreshAccessibilityStatus()
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
        val hostStartRaw = intent.extras?.get("e2e_start_host")
        val shouldStartHost = when (hostStartRaw) {
            is Boolean -> hostStartRaw
            is String -> hostStartRaw.trim().lowercase().let { it == "true" || it == "1" }
            else -> false
        }
        if (shouldStartHost) {
            val hostPort = intent.getIntExtra("e2e_host_port", OpenUUConstants.DEFAULT_PORT)
            val hostPin = intent.getStringExtra("e2e_host_pin")?.trim().orEmpty()
            intent.removeExtra("e2e_start_host")
            viewModel.startLocalHostSyntheticE2E(port = hostPort, pin = hostPin)
            return
        }

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
