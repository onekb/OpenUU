package ren.onekb.openuu

import android.content.Context
import android.graphics.SurfaceTexture
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.KeyEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.TextureView
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputConnectionWrapper
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.HelpOutline
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Apps
import androidx.compose.material.icons.rounded.AspectRatio
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.ContentPaste
import androidx.compose.material.icons.rounded.DesktopMac
import androidx.compose.material.icons.rounded.Keyboard
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.KeyboardArrowUp
import androidx.compose.material.icons.rounded.KeyboardHide
import androidx.compose.material.icons.rounded.Mouse
import androidx.compose.material.icons.rounded.PowerSettingsNew
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Remove
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.TouchApp
import androidx.compose.material.icons.rounded.UploadFile
import androidx.compose.material.icons.rounded.ZoomOutMap
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.PointerId
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.delay
import java.util.Locale
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

private const val MOUSE_MOVE = 0
private const val MOUSE_DOWN = 1
private const val MOUSE_UP = 2
private const val MOUSE_DRAG = 3
private const val BUTTON_LEFT = 0
private const val BUTTON_RIGHT = 1
private const val MIN_ZOOM = 1f
private const val MAX_ZOOM = 5f

private val WsBg = Color(0xFF09090B)
private val WsBarBg = Color(0xFF111114)
private val WsCardBg = Color(0xFF121215)
private val WsElevatedBg = Color(0xFF1A1A20)
private val WsActiveTabBg = Color(0xFF1E1E24)
private val WsKeycapBg = Color(0xFF222228)
private val WsBorder = Color(0xFF27272E)
private val WsDivider = Color(0xFF232329)
private val WsPopoverBorder = Color(0xFF3F3F46)
private val WsTextPrimary = Color(0xFFF4F4F6)
private val WsTextMuted = Color(0xFF8E8E98)
private val WsOnline = Color(0xFF30D158)
private val WsWarn = Color(0xFFFF9F0A)
private val WsDanger = Color(0xFFFF453A)

private enum class GestureSubMode {
    PENDING_SINGLE, REMOTE_DRAG, VIEWPORT_PAN, TRACKPAD_MOVE,
    TWO_FINGER_PENDING, TWO_FINGER_PINCH, TWO_FINGER_SCROLL,
    THREE_FINGER, CONSUMED_WAIT_UP
}

private data class GestureVisualState(
    val persistentBadge: String? = null,
    val isDragging: Boolean = false,
    val isLongPressArmed: Boolean = false,
    val directTouchRingPos: Offset? = null
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RemoteWorkspaceView(
    viewModel: OpenUUViewModel,
    isImmersiveFullscreen: Boolean = false,
    isLandscape: Boolean = false,
    onPickFile: () -> Unit,
    modifier: Modifier = Modifier
) {
    val connectionPhase by viewModel.connectionPhase.collectAsState()
    val linkBadge by viewModel.linkBadge.collectAsState()
    val linkRttMs by viewModel.linkRttMs.collectAsState()
    val remoteApps by viewModel.remoteApps.collectAsState()
    val appIcons by viewModel.appIcons.collectAsState()
    val normalWindows by viewModel.normalWindows.collectAsState()
    val activePopovers by viewModel.activePopovers.collectAsState()
    val popoverReadyIds by viewModel.popoverReadyIds.collectAsState()
    val selectedWindowId by viewModel.selectedWindowId.collectAsState()
    val windowSwitchNotice by viewModel.windowSwitchNotice.collectAsState()
    val proactiveTabRevealTick by viewModel.proactiveTabRevealTick.collectAsState()
    val pinLandscapeTabBar by viewModel.pinLandscapeTabBar.collectAsState()
    val showAppLauncher by viewModel.showAppLauncher.collectAsState()
    val showDebugHud by viewModel.showDebugHud.collectAsState()
    val remoteAudioEnabled by viewModel.remoteAudioEnabled.collectAsState()
    val muteHostAudio by viewModel.muteHostAudio.collectAsState()
    val touchMode by viewModel.touchMode.collectAsState()
    val videoFitMode by viewModel.videoFitMode.collectAsState()
    val manualFullscreen by viewModel.manualFullscreen.collectAsState()
    val cursorPos by viewModel.cursorPos.collectAsState()
    val cursorKind by viewModel.cursorKind.collectAsState()
    val stickyModifiers by viewModel.stickyModifiers.collectAsState()
    val videoTelemetry by viewModel.videoTelemetry.collectAsState()

    val hostName = (connectionPhase as? ConnectionPhase.Connected)?.hostName ?: "Mac"
    var showKeyboardDock by remember { mutableStateOf(false) }
    var imeSoftKeyboardRequested by remember { mutableStateOf(false) }
    var imeRequestSeq by remember { mutableLongStateOf(0L) }
    var imeComposingPreview by remember { mutableStateOf("") }
    var showSessionSheet by remember { mutableStateOf(false) }
    var showGestureGuide by remember { mutableStateOf(false) }
    var showLastWindowCloseSheet by remember { mutableStateOf(false) }
    var viewportLogicalSize by remember { mutableStateOf(Size(960f, 640f)) }

    val density = LocalDensity.current
    val isSystemImeVisible = WindowInsets.ime.getBottom(density) > 0
    var sawImeVisibleForRequest by remember { mutableStateOf(false) }
    LaunchedEffect(isSystemImeVisible, imeRequestSeq) {
        if (isSystemImeVisible) {
            sawImeVisibleForRequest = true
        } else if (sawImeVisibleForRequest && imeSoftKeyboardRequested) {
            // User dismissed system IME via system Back or keyboard's hide chevron
            sawImeVisibleForRequest = false
            imeSoftKeyboardRequested = false
            imeComposingPreview = ""
        }
    }
    LaunchedEffect(selectedWindowId) {
        if (selectedWindowId == 0) {
            imeSoftKeyboardRequested = false
            sawImeVisibleForRequest = false
            imeComposingPreview = ""
        }
    }

    val openKeyboardAndIme: () -> Unit = {
        showKeyboardDock = true
        sawImeVisibleForRequest = false
        imeSoftKeyboardRequested = true
        imeRequestSeq++
    }
    val closeKeyboardAndIme: () -> Unit = {
        imeSoftKeyboardRequested = false
        sawImeVisibleForRequest = false
        imeComposingPreview = ""
        showKeyboardDock = false
    }
    val toggleKeyboardDockAndIme: () -> Unit = {
        if (!showKeyboardDock) {
            openKeyboardAndIme()
        } else {
            closeKeyboardAndIme()
        }
    }
    val toggleSystemImeOnly: () -> Unit = {
        if (isSystemImeVisible || imeSoftKeyboardRequested) {
            imeSoftKeyboardRequested = false
            sawImeVisibleForRequest = false
            imeComposingPreview = ""
        } else {
            showKeyboardDock = true
            sawImeVisibleForRequest = false
            imeSoftKeyboardRequested = true
            imeRequestSeq++
        }
    }

    var zoom by remember(selectedWindowId) { mutableFloatStateOf(1f) }
    var pan by remember(selectedWindowId) { mutableStateOf(Offset.Zero) }

    // Proactive 4s reveal of WindowTabStrip in immersive/landscape mode on new window opened
    var tabStripAutoRevealed by remember { mutableStateOf(false) }
    var manualTabStripRevealed by remember(isImmersiveFullscreen) { mutableStateOf(false) }
    LaunchedEffect(proactiveTabRevealTick) {
        if (proactiveTabRevealTick > 0L && isImmersiveFullscreen) {
            tabStripAutoRevealed = true
            delay(4000L)
            tabStripAutoRevealed = false
        }
    }

    var transientToast by remember { mutableStateOf<String?>(null) }
    var transientToastSeq by remember { mutableLongStateOf(0L) }
    fun showGestureToast(msg: String) {
        transientToast = msg
        transientToastSeq++
    }
    LaunchedEffect(transientToastSeq) {
        if (transientToast != null) {
            delay(1300L)
            transientToast = null
        }
    }

    val rttPillText = when {
        linkRttMs > 0 -> "${linkRttMs}ms"
        linkBadge.isNotBlank() -> linkBadge.substringBefore(" ")
        else -> "在线"
    }

    val handleCloseTab: (Int) -> Unit = { winId ->
        if (normalWindows.size >= 2) {
            viewModel.closeRemoteWindowTab(winId)
        } else {
            showLastWindowCloseSheet = true
        }
    }

    val toggleTouch: () -> Unit = {
        val next = if (touchMode == TouchMode.DIRECT_TOUCH) TouchMode.TRACKPAD else TouchMode.DIRECT_TOUCH
        viewModel.setTouchMode(next)
        showGestureToast("已切换至 ${next.label}")
    }

    val dockTabStrip = !isImmersiveFullscreen || pinLandscapeTabBar
    val overlayTabStripVisible = isImmersiveFullscreen && !pinLandscapeTabBar && (tabStripAutoRevealed || manualTabStripRevealed)

    val handleStepBack: () -> Unit = {
        when {
            showGestureGuide -> showGestureGuide = false
            showLastWindowCloseSheet -> showLastWindowCloseSheet = false
            showSessionSheet -> showSessionSheet = false
            showAppLauncher && selectedWindowId != 0 -> viewModel.setShowAppLauncher(false)
            overlayTabStripVisible -> {
                manualTabStripRevealed = false
                tabStripAutoRevealed = false
            }
            selectedWindowId != 0 && (isSystemImeVisible || imeSoftKeyboardRequested) -> {
                imeSoftKeyboardRequested = false
                sawImeVisibleForRequest = false
                imeComposingPreview = ""
            }
            selectedWindowId != 0 && showKeyboardDock -> closeKeyboardAndIme()
            selectedWindowId != 0 && activePopovers.isNotEmpty() -> {
                viewModel.dismissActivePopoversViaEsc()
                showGestureToast("已关闭右键菜单")
            }
            selectedWindowId != 0 && manualFullscreen -> {
                viewModel.setManualFullscreen(false)
                showGestureToast("已退出全屏")
            }
            selectedWindowId != 0 && zoom > 1.02f -> {
                zoom = 1f
                pan = Offset.Zero
                showGestureToast("已恢复默认比例")
            }
            selectedWindowId != 0 && viewModel.canNavigateBackWindow() -> {
                viewModel.navigateBackWindow()
            }
            selectedWindowId != 0 -> {
                viewModel.enterAppLauncherPage()
            }
            else -> {
                viewModel.selectTab(MainTab.CONNECT)
            }
        }
    }

    BackHandler(enabled = true, onBack = handleStepBack)

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(if (isImmersiveFullscreen) Color.Black else WsBg)
            .then(if (isImmersiveFullscreen) Modifier else Modifier.statusBarsPadding().navigationBarsPadding())
            .imePadding()
    ) {
        // Keep RemoteVideoCanvas in the exact same Column slot across orientation/fullscreen changes
        // so SurfaceView & hardware MediaCodec never re-initialize on rotation!
        Column(modifier = Modifier.fillMaxSize()) {
            if (dockTabStrip) {
                WindowTabStrip(
                    normalWindows = normalWindows,
                    selectedWindowId = selectedWindowId,
                    showAppLauncher = showAppLauncher,
                    touchMode = touchMode,
                    showKeyboardDock = showKeyboardDock,
                    rttText = rttPillText,
                    onStepBack = handleStepBack,
                    onOpenApps = {
                        if (selectedWindowId == 0) {
                            viewModel.refreshRemoteApps()
                        } else {
                            viewModel.setShowAppLauncher(!showAppLauncher)
                        }
                    },
                    onSelectWindow = { viewModel.selectRemoteWindow(it) },
                    onCloseWindow = handleCloseTab,
                    onToggleTouchMode = toggleTouch,
                    onToggleKeyboard = toggleKeyboardDockAndIme,
                    onOpenSessionMenu = { showSessionSheet = true }
                )
            }

            Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
                if (selectedWindowId == 0) {
                    RemoteAppLauncherGrid(
                        apps = remoteApps,
                        appIcons = appIcons,
                        onRefreshApps = { viewModel.refreshRemoteApps() },
                        onOpenFullDesktop = { viewModel.openFullDesktop() },
                        onOpenApp = { viewModel.openRemoteApp(it.bundleId, it.name) }
                    )
                } else {
                    RemoteVideoCanvas(
                        viewModel = viewModel,
                        activeWindowId = selectedWindowId,
                        activePopovers = activePopovers,
                        popoverReadyIds = popoverReadyIds,
                        touchMode = touchMode,
                        videoFitMode = videoFitMode,
                        zoom = zoom,
                        pan = pan,
                        onZoomPanChanged = { z, p -> zoom = z; pan = p },
                        cursorPos = cursorPos,
                        cursorKind = cursorKind,
                        telemetry = videoTelemetry,
                        linkBadge = linkBadge,
                        showDebugHud = showDebugHud,
                        transientToast = transientToast,
                        onTransientToast = ::showGestureToast,
                        onThreeFingerTap = {
                            toggleKeyboardDockAndIme()
                            showGestureToast(if (showKeyboardDock) "三指 · 已呼出输入法与按键栏" else "三指 · 已收起键盘栏")
                        },
                        onThreeFingerVerticalSwipe = {
                            if (isImmersiveFullscreen && !pinLandscapeTabBar) {
                                manualTabStripRevealed = !manualTabStripRevealed
                                showGestureToast(if (manualTabStripRevealed) "三指 · 已展开标签栏" else "三指 · 已收起标签栏")
                            } else {
                                viewModel.toggleManualFullscreen()
                                showGestureToast("三指 · 切换全屏")
                            }
                        },
                        onViewportLogicalSizeChanged = { viewportLogicalSize = it }
                    )
                }

                if (selectedWindowId != 0 && showKeyboardDock) {
                    DirectRemoteImeHost(
                        imeRequested = imeSoftKeyboardRequested,
                        imeRequestSeq = imeRequestSeq,
                        onCommitText = { text -> viewModel.handleDirectImeInput(text) },
                        onBackspace = { isRepeat -> viewModel.sendKeyTap(MacKeyCodes.DELETE, null, isRepeat) },
                        onKeyTap = { keyCode, isRepeat -> viewModel.sendKeyTap(keyCode, null, isRepeat) },
                        onComposingPreviewChanged = { imeComposingPreview = it },
                        modifier = Modifier
                            .align(Alignment.BottomStart)
                            .size(1.dp)
                            .graphicsLayer { alpha = 0.01f }
                    )
                }
            }

            AnimatedVisibility(
                visible = selectedWindowId != 0 && showKeyboardDock,
                enter = expandVertically(),
                exit = shrinkVertically()
            ) {
                MacKeyboardAndImeDock(
                    isImeActive = isSystemImeVisible || imeSoftKeyboardRequested,
                    composingPreview = imeComposingPreview,
                    stickyModifiers = stickyModifiers,
                    onToggleModifier = { viewModel.toggleStickyModifier(it) },
                    onSendKeyTap = { code, mods, isRepeat -> viewModel.sendKeyTap(code, mods, isRepeat) },
                    onToggleIme = toggleSystemImeOnly,
                    onCloseDock = closeKeyboardAndIme
                )
            }
        }

        // Fullscreen Auto-Revealed / Manual Overlay WindowTabStrip
        AnimatedVisibility(
            visible = overlayTabStripVisible,
            enter = slideInVertically { -it } + fadeIn(),
            exit = slideOutVertically { -it } + fadeOut(),
            modifier = Modifier.align(Alignment.TopCenter)
        ) {
            WindowTabStrip(
                normalWindows = normalWindows,
                selectedWindowId = selectedWindowId,
                showAppLauncher = showAppLauncher,
                touchMode = touchMode,
                showKeyboardDock = showKeyboardDock,
                rttText = rttPillText,
                showCollapseBtn = true,
                onCollapse = {
                    manualTabStripRevealed = false
                    tabStripAutoRevealed = false
                },
                onStepBack = {
                    manualTabStripRevealed = false
                    tabStripAutoRevealed = false
                    if (selectedWindowId != 0 && viewModel.canNavigateBackWindow()) {
                        viewModel.navigateBackWindow()
                    } else if (selectedWindowId != 0) {
                        viewModel.enterAppLauncherPage()
                    } else {
                        viewModel.selectTab(MainTab.CONNECT)
                    }
                },
                onOpenApps = {
                    manualTabStripRevealed = false
                    viewModel.setShowAppLauncher(true)
                },
                onSelectWindow = { viewModel.selectRemoteWindow(it) },
                onCloseWindow = handleCloseTab,
                onToggleTouchMode = toggleTouch,
                onToggleKeyboard = {
                    manualTabStripRevealed = false
                    tabStripAutoRevealed = false
                    toggleKeyboardDockAndIme()
                },
                onOpenSessionMenu = {
                    manualTabStripRevealed = false
                    showSessionSheet = true
                }
            )
        }

        // Minimal Collapsed Fullscreen Edge Pill (Top-End)
        if (isImmersiveFullscreen && !pinLandscapeTabBar && !overlayTabStripVisible) {
            Surface(
                color = Color(0xCC16161A),
                shape = RoundedCornerShape(999.dp),
                border = BorderStroke(0.5.dp, WsBorder),
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(top = 8.dp, end = 10.dp)
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.height(28.dp)
                ) {
                    Row(
                        modifier = Modifier
                            .clickable { manualTabStripRevealed = true }
                            .padding(start = 10.dp, end = 8.dp, top = 4.dp, bottom = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(5.dp)
                    ) {
                        Box(Modifier.size(6.dp).clip(CircleShape).background(WsOnline))
                        Text(
                            text = "${normalWindows.size} 窗",
                            fontSize = 11.5.sp,
                            fontWeight = FontWeight.Medium,
                            color = WsTextPrimary
                        )
                    }
                    Box(Modifier.width(0.5.dp).height(14.dp).background(WsBorder))
                    Text(
                        text = "菜单",
                        fontSize = 11.5.sp,
                        fontWeight = FontWeight.Medium,
                        color = WsTextMuted,
                        modifier = Modifier
                            .clickable { showSessionSheet = true }
                            .padding(start = 8.dp, end = 10.dp, top = 4.dp, bottom = 4.dp)
                    )
                }
            }
        }

        // Auto-Jump Top Notice Toast Pill when a new Mac window opens
        AnimatedVisibility(
            visible = windowSwitchNotice != null,
            enter = slideInVertically { -it } + fadeIn(),
            exit = slideOutVertically { -it } + fadeOut(),
            modifier = Modifier
                .align(Alignment.TopCenter)
                .padding(top = if (dockTabStrip || overlayTabStripVisible) 44.dp else 10.dp)
        ) {
            windowSwitchNotice?.let { notice ->
                Surface(
                    color = Color(0xE616161A),
                    shape = RoundedCornerShape(999.dp),
                    border = BorderStroke(0.5.dp, WsPopoverBorder),
                    shadowElevation = 6.dp
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Box(Modifier.size(6.dp).clip(CircleShape).background(WsOnline))
                        Text(
                            text = notice,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Medium,
                            color = WsTextPrimary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }
        }
    }

    // App Switcher ModalBottomSheet over live video stream
    if (showAppLauncher && selectedWindowId != 0) {
        val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
        ModalBottomSheet(
            onDismissRequest = { viewModel.setShowAppLauncher(false) },
            sheetState = sheetState,
            containerColor = WsCardBg,
            contentColor = WsTextPrimary
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 320.dp, max = 560.dp)
                    .padding(bottom = 16.dp)
            ) {
                RemoteAppLauncherGrid(
                    apps = remoteApps,
                    appIcons = appIcons,
                    onRefreshApps = { viewModel.refreshRemoteApps() },
                    onOpenFullDesktop = { viewModel.openFullDesktop() },
                    onOpenApp = { viewModel.openRemoteApp(it.bundleId, it.name) }
                )
            }
        }
    }

    // Session Control Sheet
    if (showSessionSheet) {
        SessionControlSheet(
            hostName = hostName,
            linkBadge = linkBadge,
            videoFitMode = videoFitMode,
            zoom = zoom,
            pinLandscapeTabBar = pinLandscapeTabBar,
            showDebugHud = showDebugHud,
            remoteAudioEnabled = remoteAudioEnabled,
            muteHostAudio = muteHostAudio,
            isLandscape = isLandscape,
            manualFullscreen = manualFullscreen,
            hasActiveWindow = selectedWindowId != 0,
            onDismiss = { showSessionSheet = false },
            onToggleFitMode = {
                viewModel.toggleVideoFitMode()
                if (zoom <= 1.01f) pan = Offset.Zero
            },
            onZoomOut = {
                val next = (zoom - 0.5f).coerceIn(MIN_ZOOM, MAX_ZOOM)
                zoom = next
                if (next <= 1.01f) pan = Offset.Zero
            },
            onZoomReset = { zoom = 1f; pan = Offset.Zero },
            onZoomIn = { zoom = (zoom + 0.5f).coerceIn(MIN_ZOOM, MAX_ZOOM) },
            onToggleRemoteAudio = { viewModel.toggleRemoteAudio() },
            onToggleMuteHostAudio = { viewModel.toggleMuteHostAudio() },
            onTogglePinLandscape = { viewModel.togglePinLandscapeTabBar() },
            onToggleManualFullscreen = { viewModel.toggleManualFullscreen() },
            onToggleDebugHud = { viewModel.toggleDebugHud() },
            onPickFile = { showSessionSheet = false; onPickFile() },
            onPushClipboard = {
                showSessionSheet = false
                viewModel.pushLocalClipboardToHost(silent = false)
                showGestureToast("已推送剪贴板至 Mac")
            },
            onRefreshKeyframe = {
                showSessionSheet = false
                viewModel.requestKeyframeNow()
                showGestureToast("已请求刷新关键帧")
            },
            onResizeToViewport = {
                showSessionSheet = false
                val w = viewportLogicalSize.width.coerceIn(480f, 1920f)
                val h = viewportLogicalSize.height.coerceIn(360f, 1440f)
                viewModel.resizeActiveWindow(w, h)
            },
            onOpenGestureGuide = { showSessionSheet = false; showGestureGuide = true },
            onBackToHosts = { showSessionSheet = false; viewModel.selectTab(MainTab.CONNECT) },
            onDisconnect = { showSessionSheet = false; viewModel.disconnect() }
        )
    }

    // Unambiguous Last-Window Close Sheet
    if (showLastWindowCloseSheet) {
        val soleWindow = normalWindows.firstOrNull()
        LastWindowCloseSheet(
            windowTitle = soleWindow?.displayTitle ?: "当前窗口",
            hostName = hostName,
            onDismiss = { showLastWindowCloseSheet = false },
            onCloseRemoteWindow = {
                showLastWindowCloseSheet = false
                val targetId = soleWindow?.windowId ?: selectedWindowId
                if (targetId != 0) viewModel.closeRemoteWindowTab(targetId)
            },
            onSwitchApps = {
                showLastWindowCloseSheet = false
                viewModel.setShowAppLauncher(true)
            },
            onDisconnect = {
                showLastWindowCloseSheet = false
                viewModel.disconnect()
            }
        )
    }

    if (showGestureGuide) {
        GestureGuideDialog(onDismiss = { showGestureGuide = false })
    }
}

@Composable
private fun WindowTabStrip(
    normalWindows: List<WindowTopologyItem>,
    selectedWindowId: Int,
    showAppLauncher: Boolean,
    touchMode: TouchMode,
    showKeyboardDock: Boolean,
    rttText: String,
    showCollapseBtn: Boolean = false,
    onCollapse: () -> Unit = {},
    onStepBack: () -> Unit = {},
    onOpenApps: () -> Unit,
    onSelectWindow: (Int) -> Unit,
    onCloseWindow: (Int) -> Unit,
    onToggleTouchMode: () -> Unit,
    onToggleKeyboard: () -> Unit,
    onOpenSessionMenu: () -> Unit
) {
    Column(modifier = Modifier.fillMaxWidth().background(WsBarBg)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(38.dp)
                .padding(horizontal = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp)
        ) {
            // Leading step-back button (previous window -> app launcher -> host list)
            Surface(
                onClick = onStepBack,
                color = WsElevatedBg,
                shape = RoundedCornerShape(7.dp),
                border = BorderStroke(0.5.dp, WsBorder)
            ) {
                Box(modifier = Modifier.size(26.dp), contentAlignment = Alignment.Center) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Rounded.ArrowBack,
                        contentDescription = "返回上一步",
                        tint = WsTextPrimary,
                        modifier = Modifier.size(15.dp)
                    )
                }
            }

            // [应用] switcher pill
            if (selectedWindowId != 0) {
                Surface(
                    onClick = onOpenApps,
                    color = if (showAppLauncher) WsTextPrimary else WsElevatedBg,
                    shape = RoundedCornerShape(7.dp),
                    border = BorderStroke(0.5.dp, if (showAppLauncher) WsTextPrimary else WsBorder)
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 5.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.Apps,
                            contentDescription = "应用",
                            tint = if (showAppLauncher) WsBg else WsTextPrimary,
                            modifier = Modifier.size(14.dp)
                        )
                        Text(
                            text = "应用",
                            fontSize = 11.5.sp,
                            fontWeight = FontWeight.Medium,
                            color = if (showAppLauncher) WsBg else WsTextPrimary
                        )
                    }
                }
            }

            // Center scrollable browser-style window tabs
            LazyRow(
                modifier = Modifier.weight(1f).fillMaxHeight(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                items(normalWindows, key = { it.windowId }) { win ->
                    val active = win.windowId == selectedWindowId
                    Surface(
                        onClick = { onSelectWindow(win.windowId) },
                        color = if (active) WsActiveTabBg else Color.Transparent,
                        shape = RoundedCornerShape(7.dp),
                        border = if (active) BorderStroke(0.5.dp, WsPopoverBorder) else null
                    ) {
                        Row(
                            modifier = Modifier.padding(start = 8.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Text(
                                text = win.displayTitle,
                                fontSize = 11.5.sp,
                                fontWeight = if (active) FontWeight.Medium else FontWeight.Normal,
                                color = if (active) WsTextPrimary else WsTextMuted,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.widthIn(max = 112.dp)
                            )
                            Box(
                                modifier = Modifier
                                    .size(18.dp)
                                    .clip(RoundedCornerShape(4.dp))
                                    .clickable { onCloseWindow(win.windowId) },
                                contentAlignment = Alignment.Center
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.Close,
                                    contentDescription = "关闭窗口",
                                    tint = if (active) WsTextMuted else Color(0xFF63636E),
                                    modifier = Modifier.size(12.dp)
                                )
                            }
                        }
                    }
                }
            }

            // Right compact controls: TouchMode, Keyboard, RTT/Menu pill
            Surface(
                onClick = onToggleTouchMode,
                color = if (touchMode == TouchMode.TRACKPAD) WsActiveTabBg else Color.Transparent,
                shape = RoundedCornerShape(7.dp),
                border = BorderStroke(0.5.dp, if (touchMode == TouchMode.TRACKPAD) WsPopoverBorder else WsBorder)
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 7.dp, vertical = 5.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(3.dp)
                ) {
                    Icon(
                        imageVector = if (touchMode == TouchMode.DIRECT_TOUCH) Icons.Rounded.TouchApp else Icons.Rounded.Mouse,
                        contentDescription = touchMode.label,
                        tint = WsTextPrimary,
                        modifier = Modifier.size(13.dp)
                    )
                    Text(
                        text = touchMode.label,
                        fontSize = 11.sp,
                        color = WsTextPrimary
                    )
                }
            }

            Surface(
                onClick = onToggleKeyboard,
                color = if (showKeyboardDock) WsTextPrimary else WsElevatedBg,
                shape = RoundedCornerShape(7.dp),
                border = BorderStroke(0.5.dp, if (showKeyboardDock) WsTextPrimary else WsBorder)
            ) {
                Box(modifier = Modifier.size(26.dp), contentAlignment = Alignment.Center) {
                    Icon(
                        imageVector = Icons.Rounded.Keyboard,
                        contentDescription = "键盘",
                        tint = if (showKeyboardDock) WsBg else WsTextPrimary,
                        modifier = Modifier.size(15.dp)
                    )
                }
            }

            Surface(
                onClick = onOpenSessionMenu,
                color = WsElevatedBg,
                shape = RoundedCornerShape(7.dp),
                border = BorderStroke(0.5.dp, WsBorder)
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 7.dp, vertical = 5.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Box(Modifier.size(6.dp).clip(CircleShape).background(WsOnline))
                    Text(
                        text = rttText,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 11.sp,
                        color = WsTextPrimary,
                        maxLines = 1
                    )
                    Icon(
                        imageVector = Icons.Rounded.KeyboardArrowDown,
                        contentDescription = "会话菜单",
                        tint = WsTextMuted,
                        modifier = Modifier.size(13.dp)
                    )
                }
            }

            if (showCollapseBtn) {
                Box(
                    modifier = Modifier
                        .size(24.dp)
                        .clip(RoundedCornerShape(6.dp))
                        .clickable(onClick = onCollapse),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        imageVector = Icons.Rounded.Close,
                        contentDescription = "收起标签栏",
                        tint = WsTextMuted,
                        modifier = Modifier.size(14.dp)
                    )
                }
            }
        }
        HorizontalDivider(thickness = 0.5.dp, color = WsDivider)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SessionControlSheet(
    hostName: String,
    linkBadge: String,
    videoFitMode: VideoFitMode,
    zoom: Float,
    pinLandscapeTabBar: Boolean,
    showDebugHud: Boolean,
    remoteAudioEnabled: Boolean,
    muteHostAudio: Boolean,
    isLandscape: Boolean,
    manualFullscreen: Boolean,
    hasActiveWindow: Boolean,
    onDismiss: () -> Unit,
    onToggleFitMode: () -> Unit,
    onZoomOut: () -> Unit,
    onZoomReset: () -> Unit,
    onZoomIn: () -> Unit,
    onToggleRemoteAudio: () -> Unit,
    onToggleMuteHostAudio: () -> Unit,
    onTogglePinLandscape: () -> Unit,
    onToggleManualFullscreen: () -> Unit,
    onToggleDebugHud: () -> Unit,
    onPickFile: () -> Unit,
    onPushClipboard: () -> Unit,
    onRefreshKeyframe: () -> Unit,
    onResizeToViewport: () -> Unit,
    onOpenGestureGuide: () -> Unit,
    onBackToHosts: () -> Unit,
    onDisconnect: () -> Unit
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = WsCardBg,
        contentColor = WsTextPrimary
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .padding(bottom = 26.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Column {
                    Text(hostName, style = MaterialTheme.typography.titleMedium, color = WsTextPrimary)
                    if (linkBadge.isNotBlank()) {
                        Text(linkBadge, fontFamily = FontFamily.Monospace, fontSize = 11.5.sp, color = WsTextMuted)
                    }
                }
                Box(Modifier.size(8.dp).clip(CircleShape).background(WsOnline))
            }

            // Fit/Fill + Zoom row
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Surface(
                    onClick = onToggleFitMode,
                    color = WsElevatedBg,
                    shape = RoundedCornerShape(9.dp),
                    border = BorderStroke(0.5.dp, WsBorder),
                    modifier = Modifier.weight(1f)
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text("画面比例", fontSize = 13.sp, color = WsTextMuted)
                        Text(videoFitMode.label, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = WsTextPrimary)
                    }
                }

                Surface(
                    color = WsElevatedBg,
                    shape = RoundedCornerShape(9.dp),
                    border = BorderStroke(0.5.dp, WsBorder)
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        IconButton(onClick = onZoomOut, enabled = zoom > MIN_ZOOM + 0.01f, modifier = Modifier.size(36.dp)) {
                            Icon(Icons.Rounded.Remove, contentDescription = "缩小", tint = WsTextPrimary, modifier = Modifier.size(16.dp))
                        }
                        Text(
                            text = "${(zoom * 100).roundToInt()}%",
                            fontFamily = FontFamily.Monospace,
                            fontSize = 12.sp,
                            color = WsTextPrimary,
                            modifier = Modifier
                                .clickable(onClick = onZoomReset)
                                .padding(horizontal = 6.dp, vertical = 8.dp)
                        )
                        IconButton(onClick = onZoomIn, enabled = zoom < MAX_ZOOM - 0.01f, modifier = Modifier.size(36.dp)) {
                            Icon(Icons.Rounded.Add, contentDescription = "放大", tint = WsTextPrimary, modifier = Modifier.size(16.dp))
                        }
                    }
                }
            }

            // Switches group
            Surface(
                color = WsElevatedBg,
                shape = RoundedCornerShape(10.dp),
                border = BorderStroke(0.5.dp, WsBorder),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column {
                    SheetSwitchRow("接收远程电脑声音", remoteAudioEnabled, onToggleRemoteAudio)
                    HorizontalDivider(thickness = 0.5.dp, color = WsDivider)
                    SheetSwitchRow("远控时被控 Mac 静音", muteHostAudio, onToggleMuteHostAudio, enabled = remoteAudioEnabled)
                    HorizontalDivider(thickness = 0.5.dp, color = WsDivider)
                    SheetSwitchRow("横屏固定顶部标签栏", pinLandscapeTabBar, onTogglePinLandscape)
                    HorizontalDivider(thickness = 0.5.dp, color = WsDivider)
                    if (!isLandscape && hasActiveWindow) {
                        SheetSwitchRow("沉浸全屏模式", manualFullscreen, onToggleManualFullscreen)
                        HorizontalDivider(thickness = 0.5.dp, color = WsDivider)
                    }
                    SheetSwitchRow("显示性能调试浮窗 (HUD)", showDebugHud, onToggleDebugHud)
                }
            }

            // Actions group
            Surface(
                color = WsElevatedBg,
                shape = RoundedCornerShape(10.dp),
                border = BorderStroke(0.5.dp, WsBorder),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column {
                    SheetActionRow(Icons.Rounded.UploadFile, "上传文件到当前窗口", onPickFile)
                    HorizontalDivider(thickness = 0.5.dp, color = WsDivider)
                    SheetActionRow(Icons.Rounded.ContentPaste, "推送本机剪贴板到 Mac", onPushClipboard)
                    if (hasActiveWindow) {
                        HorizontalDivider(thickness = 0.5.dp, color = WsDivider)
                        SheetActionRow(Icons.Rounded.AspectRatio, "调整远程窗口适应屏幕", onResizeToViewport)
                        HorizontalDivider(thickness = 0.5.dp, color = WsDivider)
                        SheetActionRow(Icons.Rounded.Refresh, "刷新视频关键帧", onRefreshKeyframe)
                    }
                    HorizontalDivider(thickness = 0.5.dp, color = WsDivider)
                    SheetActionRow(Icons.AutoMirrored.Rounded.HelpOutline, "触控手势指南", onOpenGestureGuide)
                    HorizontalDivider(thickness = 0.5.dp, color = WsDivider)
                    SheetActionRow(Icons.AutoMirrored.Rounded.ArrowBack, "返回主机列表（保持连接）", onBackToHosts)
                }
            }

            // Separated destructive disconnect
            Surface(
                onClick = onDisconnect,
                color = Color(0xFF1F1214),
                shape = RoundedCornerShape(10.dp),
                border = BorderStroke(0.5.dp, Color(0xFF4C1D24)),
                modifier = Modifier.fillMaxWidth()
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 13.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.Center
                ) {
                    Icon(Icons.Rounded.PowerSettingsNew, contentDescription = null, tint = WsDanger, modifier = Modifier.size(17.dp))
                    Spacer(Modifier.width(7.dp))
                    Text("断开远控连接", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = WsDanger)
                }
            }
        }
    }
}

@Composable
private fun SheetSwitchRow(label: String, checked: Boolean, onToggle: () -> Unit, enabled: Boolean = true) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onToggle)
            .padding(horizontal = 14.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(label, fontSize = 13.5.sp, color = if (enabled) WsTextPrimary else WsTextMuted)
        Switch(checked = checked, onCheckedChange = { onToggle() }, enabled = enabled)
    }
}

@Composable
private fun SheetActionRow(icon: ImageVector, label: String, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Icon(icon, contentDescription = null, tint = WsTextMuted, modifier = Modifier.size(18.dp))
        Text(label, fontSize = 13.5.sp, color = WsTextPrimary)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LastWindowCloseSheet(
    windowTitle: String,
    hostName: String,
    onDismiss: () -> Unit,
    onCloseRemoteWindow: () -> Unit,
    onSwitchApps: () -> Unit,
    onDisconnect: () -> Unit
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = WsCardBg,
        contentColor = WsTextPrimary
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(bottom = 26.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Text(
                text = "关闭「$windowTitle」",
                style = MaterialTheme.typography.titleMedium,
                color = WsTextPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            Text(
                text = "这是当前会话中最后一个打开的窗口，请选择操作：",
                style = MaterialTheme.typography.bodySmall,
                color = WsTextMuted
            )

            Surface(
                color = WsElevatedBg,
                shape = RoundedCornerShape(10.dp),
                border = BorderStroke(0.5.dp, WsBorder),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column {
                    SheetActionRow(Icons.Rounded.Close, "在 Mac 上关闭该窗口 (⌘W)", onCloseRemoteWindow)
                    HorizontalDivider(thickness = 0.5.dp, color = WsDivider)
                    SheetActionRow(Icons.Rounded.Apps, "切换其他远程应用", onSwitchApps)
                }
            }

            Surface(
                onClick = onDisconnect,
                color = Color(0xFF1F1214),
                shape = RoundedCornerShape(10.dp),
                border = BorderStroke(0.5.dp, Color(0xFF4C1D24)),
                modifier = Modifier.fillMaxWidth()
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 13.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.Center
                ) {
                    Icon(Icons.Rounded.PowerSettingsNew, contentDescription = null, tint = WsDanger, modifier = Modifier.size(17.dp))
                    Spacer(Modifier.width(7.dp))
                    Text("断开与 $hostName 的远控连接", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = WsDanger)
                }
            }
        }
    }
}

@Composable
private fun RemoteAppLauncherGrid(
    apps: List<RemoteAppSummary>,
    appIcons: Map<String, ImageBitmap>,
    onRefreshApps: () -> Unit,
    onOpenFullDesktop: () -> Unit,
    onOpenApp: (RemoteAppSummary) -> Unit
) {
    var searchQuery by remember { mutableStateOf("") }
    val filteredApps = remember(apps, searchQuery) {
        val q = searchQuery.trim().lowercase()
        if (q.isEmpty()) apps
        else apps.filter { it.name.lowercase().contains(q) || it.bundleId.lowercase().contains(q) }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            OutlinedTextField(
                value = searchQuery,
                onValueChange = { searchQuery = it },
                placeholder = { Text("搜索远程 Mac 应用...", style = MaterialTheme.typography.bodySmall, color = WsTextMuted) },
                leadingIcon = { Icon(Icons.Rounded.Search, contentDescription = null, tint = WsTextMuted, modifier = Modifier.size(18.dp)) },
                trailingIcon = {
                    if (searchQuery.isNotEmpty()) {
                        IconButton(onClick = { searchQuery = "" }, modifier = Modifier.size(28.dp)) {
                            Icon(Icons.Rounded.Close, contentDescription = "清除", tint = WsTextMuted, modifier = Modifier.size(16.dp))
                        }
                    }
                },
                singleLine = true,
                shape = RoundedCornerShape(9.dp),
                modifier = Modifier.weight(1f),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedContainerColor = WsElevatedBg,
                    unfocusedContainerColor = WsElevatedBg,
                    focusedBorderColor = WsPopoverBorder,
                    unfocusedBorderColor = WsBorder,
                    focusedTextColor = WsTextPrimary,
                    unfocusedTextColor = WsTextPrimary
                )
            )
            Surface(
                onClick = onRefreshApps,
                color = WsElevatedBg,
                shape = RoundedCornerShape(9.dp),
                border = BorderStroke(0.5.dp, WsBorder)
            ) {
                Box(modifier = Modifier.size(48.dp), contentAlignment = Alignment.Center) {
                    Icon(Icons.Rounded.Refresh, contentDescription = "刷新应用列表", tint = WsTextPrimary, modifier = Modifier.size(19.dp))
                }
            }
        }

        LazyVerticalGrid(
            columns = GridCells.Adaptive(minSize = 96.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            contentPadding = PaddingValues(bottom = 14.dp),
            modifier = Modifier.fillMaxSize()
        ) {
            item(span = { GridItemSpan(maxLineSpan) }, key = OpenUUConstants.FULL_DESKTOP_BUNDLE_ID) {
                Surface(
                    onClick = onOpenFullDesktop,
                    color = WsElevatedBg,
                    shape = RoundedCornerShape(10.dp),
                    border = BorderStroke(0.5.dp, WsPopoverBorder)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Box(
                            modifier = Modifier.size(38.dp).clip(RoundedCornerShape(8.dp)).background(WsKeycapBg),
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(Icons.Rounded.DesktopMac, contentDescription = null, tint = WsTextPrimary, modifier = Modifier.size(20.dp))
                        }
                        Column(modifier = Modifier.weight(1f)) {
                            Text("整台桌面", style = MaterialTheme.typography.titleSmall, color = WsTextPrimary)
                            Text("镜像完整 macOS 主显示器画面", style = MaterialTheme.typography.bodySmall, color = WsTextMuted)
                        }
                    }
                }
            }

            if (filteredApps.isEmpty()) {
                item(span = { GridItemSpan(maxLineSpan) }) {
                    Box(modifier = Modifier.fillMaxWidth().padding(vertical = 28.dp), contentAlignment = Alignment.Center) {
                        Text(
                            text = if (apps.isEmpty()) "正在获取 Mac 运行中的应用..." else "无匹配应用",
                            style = MaterialTheme.typography.bodySmall,
                            color = WsTextMuted
                        )
                    }
                }
            } else {
                items(filteredApps, key = { "${it.bundleId}_${it.pid}" }) { app ->
                    Surface(
                        onClick = { onOpenApp(app) },
                        color = WsCardBg,
                        shape = RoundedCornerShape(10.dp),
                        border = BorderStroke(0.5.dp, WsBorder)
                    ) {
                        Column(
                            modifier = Modifier.fillMaxWidth().padding(10.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            val icon = appIcons[app.bundleId]
                            if (icon != null) {
                                Image(
                                    bitmap = icon,
                                    contentDescription = app.name,
                                    contentScale = ContentScale.Fit,
                                    modifier = Modifier.size(42.dp).clip(RoundedCornerShape(9.dp))
                                )
                            } else {
                                Box(
                                    modifier = Modifier.size(42.dp).clip(RoundedCornerShape(9.dp)).background(WsElevatedBg),
                                    contentAlignment = Alignment.Center
                                ) {
                                    Text(
                                        text = app.name.firstOrNull()?.uppercase() ?: "A",
                                        style = MaterialTheme.typography.titleSmall,
                                        color = WsTextPrimary
                                    )
                                }
                            }
                            Text(
                                text = app.name.ifBlank { app.bundleId },
                                fontSize = 12.sp,
                                color = WsTextPrimary,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                textAlign = TextAlign.Center
                            )
                            if (app.windowCount > 0) {
                                Text(
                                    text = "${app.windowCount} 窗",
                                    fontSize = 10.5.sp,
                                    color = WsTextMuted
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

private data class PlacedPopoverVisual(
    val item: WindowTopologyItem,
    val leftPx: Float,
    val topPx: Float,
    val widthPx: Float,
    val heightPx: Float,
    val normLeft: Float,
    val normTop: Float,
    val normRight: Float,
    val normBottom: Float,
    val effRelX: Float,
    val effRelY: Float
)

@Composable
private fun RemoteVideoCanvas(
    viewModel: OpenUUViewModel,
    activeWindowId: Int,
    activePopovers: List<WindowTopologyItem>,
    popoverReadyIds: Set<Int>,
    touchMode: TouchMode,
    videoFitMode: VideoFitMode,
    zoom: Float,
    pan: Offset,
    onZoomPanChanged: (Float, Offset) -> Unit,
    cursorPos: Offset,
    cursorKind: String,
    telemetry: VideoTelemetry,
    linkBadge: String,
    showDebugHud: Boolean,
    transientToast: String?,
    onTransientToast: (String) -> Unit,
    onThreeFingerTap: () -> Unit,
    onThreeFingerVerticalSwipe: (Boolean) -> Unit,
    onViewportLogicalSizeChanged: (Size) -> Unit
) {
    val density = LocalDensity.current
    val haptic = LocalHapticFeedback.current
    var gestureVisual by remember(activeWindowId) { mutableStateOf(GestureVisualState()) }

    DisposableEffect(Unit) {
        onDispose { viewModel.attachVideoSurface(null) }
    }

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .clipToBounds()
    ) {
        val containerW = constraints.maxWidth.toFloat().coerceAtLeast(1f)
        val containerH = constraints.maxHeight.toFloat().coerceAtLeast(1f)

        val logicalW = with(density) { (containerW / density.density) * 1.4f }.coerceIn(600f, 1600f)
        val logicalH = with(density) { (containerH / density.density) * 1.4f }.coerceIn(400f, 1200f)
        LaunchedEffect(logicalW, logicalH) { onViewportLogicalSizeChanged(Size(logicalW, logicalH)) }

        val (streamW, streamH) = if (telemetry.width > 0 && telemetry.height > 0) {
            telemetry.width.toFloat() to telemetry.height.toFloat()
        } else {
            viewModel.currentLogicalSize()
        }
        val aspect = (streamW / streamH.coerceAtLeast(1f)).coerceIn(0.35f, 3.5f)
        val containerAspect = containerW / containerH

        val fittedW: Float
        val fittedH: Float
        if (containerAspect > aspect) {
            fittedH = containerH
            fittedW = containerH * aspect
        } else {
            fittedW = containerW
            fittedH = containerW / aspect
        }
        val offsetX = (containerW - fittedW) / 2f
        val offsetY = (containerH - fittedH) / 2f
        val baseRect = Rect(offsetX, offsetY, offsetX + fittedW, offsetY + fittedH)

        val fillBaseScale = if (videoFitMode == VideoFitMode.FILL) {
            max(containerW / fittedW.coerceAtLeast(1f), containerH / fittedH.coerceAtLeast(1f))
        } else {
            1f
        }
        val effectiveScale = zoom * fillBaseScale

        val (parentW, parentH) = viewModel.currentLogicalSize()
        val safeParentW = parentW.coerceAtLeast(1f)
        val safeParentH = parentH.coerceAtLeast(1f)

        val placedPopovers = remember(activePopovers, fittedW, fittedH, containerW, containerH, safeParentW, safeParentH) {
            activePopovers.mapNotNull { pop ->
                if (pop.width <= 1f || pop.height <= 1f) return@mapNotNull null
                val popWPx = ((pop.width / safeParentW) * fittedW).coerceIn(1f, containerW)
                val popHPx = ((pop.height / safeParentH) * fittedH).coerceIn(1f, containerH)
                val rawLeftPx = (pop.relX / safeParentW) * fittedW
                val rawTopPx = (pop.relY / safeParentH) * fittedH
                val clampedLeftPx = rawLeftPx.coerceIn(-offsetX, max(-offsetX, fittedW + offsetX - popWPx))
                val clampedTopPx = rawTopPx.coerceIn(-offsetY, max(-offsetY, fittedH + offsetY - popHPx))
                val safeFittedW = fittedW.coerceAtLeast(1f)
                val safeFittedH = fittedH.coerceAtLeast(1f)
                PlacedPopoverVisual(
                    item = pop,
                    leftPx = clampedLeftPx,
                    topPx = clampedTopPx,
                    widthPx = popWPx,
                    heightPx = popHPx,
                    normLeft = clampedLeftPx / safeFittedW,
                    normTop = clampedTopPx / safeFittedH,
                    normRight = (clampedLeftPx + popWPx) / safeFittedW,
                    normBottom = (clampedTopPx + popHPx) / safeFittedH,
                    effRelX = (clampedLeftPx / safeFittedW) * safeParentW,
                    effRelY = (clampedTopPx / safeFittedH) * safeParentH
                )
            }
        }

        val currentZoom by rememberUpdatedState(zoom)
        val currentPan by rememberUpdatedState(pan)
        val currentBaseRect by rememberUpdatedState(baseRect)
        val currentFillScale by rememberUpdatedState(fillBaseScale)
        val currentContainerSize by rememberUpdatedState(Size(containerW, containerH))
        val currentPlacedPopovers by rememberUpdatedState(placedPopovers)
        val onZoomPanLatest by rememberUpdatedState(onZoomPanChanged)
        val onTransientToastLatest by rememberUpdatedState(onTransientToast)
        val onThreeFingerTapLatest by rememberUpdatedState(onThreeFingerTap)
        val onThreeFingerSwipeLatest by rememberUpdatedState(onThreeFingerVerticalSwipe)
        val edgeMarginPx = with(density) { 64.dp.toPx() }

        fun clampPanFor(raw: Offset, targetZoom: Float): Offset {
            val rect = currentBaseRect
            val cSize = currentContainerSize
            val eff = targetZoom * currentFillScale
            val maxX = ((rect.width * eff - cSize.width) / 2f).coerceAtLeast(0f)
            val maxY = ((rect.height * eff - cSize.height) / 2f).coerceAtLeast(0f)
            return Offset(raw.x.coerceIn(-maxX, maxX), raw.y.coerceIn(-maxY, maxY))
        }

        fun screenToNormalized(pt: Offset): Offset {
            val rect = currentBaseRect
            val eff = currentZoom * currentFillScale
            val cx = rect.center.x
            val cy = rect.center.y
            val ux = (pt.x - cx - currentPan.x) / eff + cx
            val uy = (pt.y - cy - currentPan.y) / eff + cy
            val rawNx = (ux - rect.left) / rect.width.coerceAtLeast(1f)
            val rawNy = (uy - rect.top) / rect.height.coerceAtLeast(1f)
            return if (currentPlacedPopovers.isNotEmpty()) {
                Offset(rawNx, rawNy)
            } else {
                Offset(rawNx.coerceIn(0f, 1f), rawNy.coerceIn(0f, 1f))
            }
        }

        fun dispatchMouseEvent(n: Offset, eventType: Int, button: Int, clickCount: Int) {
            if (eventType == MOUSE_MOVE || eventType == MOUSE_DOWN) {
                val hit = currentPlacedPopovers.asReversed().firstOrNull { p ->
                    n.x >= p.normLeft && n.x <= p.normRight && n.y >= p.normTop && n.y <= p.normBottom
                }
                if (hit != null) {
                    val lx = ((n.x - hit.normLeft) / (hit.normRight - hit.normLeft).coerceAtLeast(0.0001f)) * hit.item.width
                    val ly = ((n.y - hit.normTop) / (hit.normBottom - hit.normTop).coerceAtLeast(0.0001f)) * hit.item.height
                    viewModel.sendPopoverMouseDirect(
                        popoverWindowId = hit.item.windowId,
                        lx = lx,
                        ly = ly,
                        effectiveRelX = hit.effRelX,
                        effectiveRelY = hit.effRelY,
                        eventType = eventType,
                        button = button,
                        clickCount = clickCount
                    )
                    return
                }
            }
            viewModel.sendMouseNormalized(n.x, n.y, eventType, button, clickCount)
        }

        fun dispatchScrollEvent(n: Offset, dx: Float, dy: Float) {
            val hit = currentPlacedPopovers.asReversed().firstOrNull { p ->
                n.x >= p.normLeft && n.x <= p.normRight && n.y >= p.normTop && n.y <= p.normBottom
            }
            if (hit != null) {
                val lx = ((n.x - hit.normLeft) / (hit.normRight - hit.normLeft).coerceAtLeast(0.0001f)) * hit.item.width
                val ly = ((n.y - hit.normTop) / (hit.normBottom - hit.normTop).coerceAtLeast(0.0001f)) * hit.item.height
                viewModel.sendPopoverScrollDirect(hit.item.windowId, lx, ly, dx, dy)
                return
            }
            viewModel.sendScrollNormalized(n.x, n.y, dx, dy)
        }

        fun autoPanForTrackpadCursor(nextCursor: Offset) {
            val z = currentZoom
            if (z <= 1.03f && currentFillScale <= 1.03f) return
            val rect = currentBaseRect
            val cSize = currentContainerSize
            val eff = z * currentFillScale
            val sx = (rect.left + nextCursor.x * rect.width - rect.center.x) * eff + rect.center.x + currentPan.x
            val sy = (rect.top + nextCursor.y * rect.height - rect.center.y) * eff + rect.center.y + currentPan.y
            val mx = min(cSize.width * 0.16f, edgeMarginPx)
            val my = min(cSize.height * 0.16f, edgeMarginPx)
            val dx = when {
                sx < mx -> mx - sx
                sx > cSize.width - mx -> (cSize.width - mx) - sx
                else -> 0f
            }
            val dy = when {
                sy < my -> my - sy
                sy > cSize.height - my -> (cSize.height - my) - sy
                else -> 0f
            }
            if (dx != 0f || dy != 0f) {
                val updated = clampPanFor(currentPan + Offset(dx, dy), z)
                if (updated != currentPan) onZoomPanLatest(z, updated)
            }
        }

        LaunchedEffect(containerW, containerH, videoFitMode, zoom) {
            val clamped = clampPanFor(pan, zoom)
            if (clamped != pan) onZoomPanChanged(zoom, clamped)
        }

        val fittedWDp = with(density) { fittedW.toDp() }
        val fittedHDp = with(density) { fittedH.toDp() }

        // Main SurfaceView + Floating kind == 2 Right-Click Menu / Popover TextureView Overlays
        Box(
            modifier = Modifier
                .align(Alignment.Center)
                .size(width = fittedWDp, height = fittedHDp)
                .graphicsLayer {
                    scaleX = effectiveScale
                    scaleY = effectiveScale
                    translationX = pan.x
                    translationY = pan.y
                }
        ) {
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { ctx ->
                    SurfaceView(ctx).apply {
                        holder.addCallback(object : SurfaceHolder.Callback {
                            override fun surfaceCreated(holder: SurfaceHolder) = viewModel.attachVideoSurface(holder.surface)
                            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) =
                                viewModel.attachVideoSurface(holder.surface)
                            override fun surfaceDestroyed(holder: SurfaceHolder) = viewModel.attachVideoSurface(null)
                        })
                    }
                }
            )

            // Floating Popover / Context Menu GPU TextureView overlays (kind == 2).
            // Using TextureView instead of a nested SurfaceView renders directly inside the Compose UI layer
            // above the main SurfaceView (zero SurfaceFlinger Z-order punch-through holes!) and scales/pans cleanly.
            for (placed in placedPopovers) {
                val pop = placed.item
                val isPopReady = pop.windowId in popoverReadyIds
                key(pop.windowId) {
                    val popDecoder = remember(pop.windowId) { viewModel.getOrCreatePopoverDecoder(pop.windowId) }
                    DisposableEffect(pop.windowId) {
                        onDispose { popDecoder.attachSurface(null) }
                    }
                    val popLeftDp = with(density) { placed.leftPx.toDp() }
                    val popTopDp = with(density) { placed.topPx.toDp() }
                    val popWDp = with(density) { placed.widthPx.toDp() }
                    val popHDp = with(density) { placed.heightPx.toDp() }
                    val popShape = RoundedCornerShape(6.dp)
                    Box(
                        modifier = Modifier
                            .offset(x = popLeftDp, y = popTopDp)
                            .size(width = popWDp, height = popHDp)
                            .graphicsLayer { alpha = if (isPopReady) 1f else 0f }
                            .shadow(if (isPopReady) 8.dp else 0.dp, popShape)
                            .clip(popShape)
                            .border(0.75.dp, WsPopoverBorder, popShape)
                    ) {
                        AndroidView(
                            modifier = Modifier.fillMaxSize(),
                            factory = { ctx ->
                                TextureView(ctx).apply {
                                    isOpaque = false
                                    surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                                        private var boundSurface: Surface? = null

                                        override fun onSurfaceTextureAvailable(st: SurfaceTexture, width: Int, height: Int) {
                                            boundSurface?.release()
                                            val s = Surface(st)
                                            boundSurface = s
                                            popDecoder.attachSurface(s)
                                        }

                                        override fun onSurfaceTextureSizeChanged(st: SurfaceTexture, width: Int, height: Int) = Unit

                                        override fun onSurfaceTextureDestroyed(st: SurfaceTexture): Boolean {
                                            popDecoder.attachSurface(null)
                                            boundSurface?.release()
                                            boundSurface = null
                                            return true
                                        }

                                        override fun onSurfaceTextureUpdated(st: SurfaceTexture) = Unit
                                    }
                                }
                            }
                        )
                    }
                }
            }
        }

        // Unified Multi-Touch Gesture Overlay
        Box(
            modifier = Modifier
                .fillMaxSize()
                .pointerInput(touchMode, activeWindowId) {
                    detectRemoteWorkspaceGestures(
                        touchMode = touchMode,
                        haptic = haptic,
                        getBaseRect = { currentBaseRect },
                        getZoom = { currentZoom },
                        getPan = { currentPan },
                        getCursor = { viewModel.cursorPos.value },
                        screenToNormalized = ::screenToNormalized,
                        onUpdateZoomPan = { newZoom, newPan ->
                            val z = newZoom.coerceIn(MIN_ZOOM, MAX_ZOOM)
                            val p = if (z <= 1.01f && currentFillScale <= 1.01f) Offset.Zero else clampPanFor(newPan, z)
                            onZoomPanLatest(z, p)
                        },
                        onUpdateCursorAndAutoPan = { next ->
                            viewModel.updateCursorPos(next)
                            autoPanForTrackpadCursor(next)
                        },
                        onMove = { n -> dispatchMouseEvent(n, MOUSE_MOVE, BUTTON_LEFT, 0) },
                        onLeftClick = { n, clicks ->
                            dispatchMouseEvent(n, MOUSE_MOVE, BUTTON_LEFT, 0)
                            dispatchMouseEvent(n, MOUSE_DOWN, BUTTON_LEFT, clicks)
                            dispatchMouseEvent(n, MOUSE_UP, BUTTON_LEFT, clicks)
                        },
                        onRightClick = { n ->
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            dispatchMouseEvent(n, MOUSE_MOVE, BUTTON_RIGHT, 0)
                            dispatchMouseEvent(n, MOUSE_DOWN, BUTTON_RIGHT, 1)
                            dispatchMouseEvent(n, MOUSE_UP, BUTTON_RIGHT, 1)
                            onTransientToastLatest("右键点击")
                        },
                        onDragStart = { n ->
                            dispatchMouseEvent(n, MOUSE_MOVE, BUTTON_LEFT, 0)
                            dispatchMouseEvent(n, MOUSE_DOWN, BUTTON_LEFT, 1)
                        },
                        onDragMove = { n -> dispatchMouseEvent(n, MOUSE_DRAG, BUTTON_LEFT, 1) },
                        onDragEnd = { n -> dispatchMouseEvent(n, MOUSE_UP, BUTTON_LEFT, 1) },
                        onScroll = { n, dx, dy -> dispatchScrollEvent(n, dx, dy) },
                        onThreeFingerTap = { onThreeFingerTapLatest() },
                        onThreeFingerVerticalSwipe = { onThreeFingerSwipeLatest(it) },
                        onVisualStateChange = { gestureVisual = it }
                    )
                }
        )

        // Direct-Touch Drag/Long-Press Ring
        if (touchMode == TouchMode.DIRECT_TOUCH && gestureVisual.directTouchRingPos != null) {
            val ringPos = gestureVisual.directTouchRingPos!!
            val ringColor = if (gestureVisual.isDragging) WsOnline else WsWarn
            Canvas(modifier = Modifier.fillMaxSize()) {
                val outerR = 22.dp.toPx()
                drawCircle(ringColor.copy(alpha = 0.2f), radius = outerR, center = ringPos)
                drawCircle(ringColor, radius = outerR, center = ringPos, style = Stroke(width = 2.dp.toPx()))
                drawCircle(Color.White, radius = 6.dp.toPx(), center = ringPos)
            }
        }

        if (touchMode == TouchMode.TRACKPAD) {
            MacCursorOverlay(
                cursorPos = cursorPos,
                cursorKind = cursorKind,
                videoRect = baseRect,
                effectiveScale = effectiveScale,
                pan = pan,
                isDragging = gestureVisual.isDragging,
                isLongPressArmed = gestureVisual.isLongPressArmed
            )
        }

        if (telemetry.decodedFrames == 0L) {
            Surface(
                color = Color(0xCC121215),
                shape = RoundedCornerShape(8.dp),
                border = BorderStroke(0.5.dp, WsBorder),
                modifier = Modifier.align(Alignment.Center)
            ) {
                Text(
                    text = "正在等待 Mac 视频关键帧...",
                    style = MaterialTheme.typography.bodySmall,
                    color = WsTextPrimary,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 7.dp)
                )
            }
        }

        // Gesture status / transient toast badge
        val badgeText = gestureVisual.persistentBadge ?: transientToast
        AnimatedVisibility(
            visible = badgeText != null,
            enter = fadeIn(tween(120)),
            exit = fadeOut(tween(180)),
            modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 16.dp)
        ) {
            badgeText?.let { label ->
                val dotColor = when {
                    gestureVisual.isDragging -> WsOnline
                    gestureVisual.isLongPressArmed -> WsWarn
                    else -> WsTextPrimary
                }
                Surface(
                    color = Color(0xE0121215),
                    shape = RoundedCornerShape(999.dp),
                    border = BorderStroke(0.5.dp, WsPopoverBorder)
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 11.dp, vertical = 5.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Box(Modifier.size(6.dp).clip(CircleShape).background(dotColor))
                        Text(label, fontSize = 11.5.sp, fontWeight = FontWeight.Medium, color = WsTextPrimary)
                    }
                }
            }
        }

        // Reset zoom pill
        if (zoom > 1.02f) {
            Surface(
                onClick = { onZoomPanChanged(1f, Offset.Zero) },
                color = Color(0xE01A1A20),
                shape = RoundedCornerShape(999.dp),
                border = BorderStroke(0.5.dp, WsPopoverBorder),
                modifier = Modifier.align(Alignment.BottomEnd).padding(12.dp)
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Icon(Icons.Rounded.ZoomOutMap, contentDescription = "重置缩放", tint = WsTextPrimary, modifier = Modifier.size(13.dp))
                    Text(String.format(Locale.US, "%.1fx 重置", zoom), fontFamily = FontFamily.Monospace, fontSize = 11.sp, color = WsTextPrimary)
                }
            }
        }

        if (showDebugHud) {
            DebugTelemetryHud(
                telemetry = telemetry,
                linkBadge = linkBadge,
                touchMode = touchMode,
                videoFitMode = videoFitMode,
                zoom = zoom,
                modifier = Modifier.align(Alignment.TopStart).padding(10.dp)
            )
        }
    }
}

private suspend fun PointerInputScope.detectRemoteWorkspaceGestures(
    touchMode: TouchMode,
    haptic: HapticFeedback,
    getBaseRect: () -> Rect,
    getZoom: () -> Float,
    getPan: () -> Offset,
    getCursor: () -> Offset,
    screenToNormalized: (Offset) -> Offset,
    onUpdateZoomPan: (Float, Offset) -> Unit,
    onUpdateCursorAndAutoPan: (Offset) -> Unit,
    onMove: (Offset) -> Unit,
    onLeftClick: (Offset, Int) -> Unit,
    onRightClick: (Offset) -> Unit,
    onDragStart: (Offset) -> Unit,
    onDragMove: (Offset) -> Unit,
    onDragEnd: (Offset) -> Unit,
    onScroll: (Offset, Float, Float) -> Unit,
    onThreeFingerTap: () -> Unit,
    onThreeFingerVerticalSwipe: (Boolean) -> Unit,
    onVisualStateChange: (GestureVisualState) -> Unit
) {
    val touchSlop = viewConfiguration.touchSlop
    val longPressArmMs = 300L
    val longPressRightClickMs = 420L
    val doubleTapTimeoutMs = 300L
    val doubleTapSlopPx = max(60f, touchSlop * 3f)
    val twoFingerTapMaxMs = 350L
    val twoFingerTapMaxMovePx = touchSlop * 1.6f
    val pinchLockThresholdPx = 22f
    val threeFingerTapMaxMs = 350L
    val threeFingerSwipeThresholdPx = max(48f, touchSlop * 2.4f)

    var lastSingleTapTimeMs = 0L
    var lastSingleTapPos = Offset.Zero

    fun trackpadNextCursor(delta: Offset): Offset {
        val rect = getBaseRect()
        val sens = 1.35f / (1f + (getZoom() - 1f).coerceAtLeast(0f) * 0.45f)
        val cur = getCursor()
        return Offset(
            (cur.x + (delta.x * sens) / rect.width.coerceAtLeast(1f)).coerceIn(0f, 1f),
            (cur.y + (delta.y * sens) / rect.height.coerceAtLeast(1f)).coerceIn(0f, 1f)
        )
    }

    awaitEachGesture {
        val firstDown = awaitFirstDown(requireUnconsumed = false)
        val downTimeMs = System.currentTimeMillis()
        val downPos = firstDown.position
        val firstPointerId: PointerId = firstDown.id

        val isDoubleTapCandidate = if (touchMode == TouchMode.DIRECT_TOUCH) {
            (downTimeMs - lastSingleTapTimeMs) <= doubleTapTimeoutMs &&
                hypot((downPos.x - lastSingleTapPos.x).toDouble(), (downPos.y - lastSingleTapPos.y).toDouble()).toFloat() <= doubleTapSlopPx
        } else {
            (downTimeMs - lastSingleTapTimeMs) <= doubleTapTimeoutMs
        }

        var mode = GestureSubMode.PENDING_SINGLE
        var longPressArmed = false
        var rightClickArmed = false
        var lastSinglePos = downPos
        var currentDragNorm = if (touchMode == TouchMode.DIRECT_TOUCH) screenToNormalized(downPos) else getCursor()

        var twoFingerEntered = false
        var initialSpan = 0f
        var twoFingerStartTimeMs = 0L
        var twoFingerStartCentroid = Offset.Zero
        var twoFingerTotalCentroidMove = 0f
        var secondFingerId: PointerId? = null
        var secondFingerDownTimeMs = 0L
        var secondFingerDownPos = Offset.Zero
        var secondFingerMaxDisp = 0f
        var secondFingerRightClickFired = false

        var threeFingerStartTimeMs = 0L
        var threeFingerTotalDeltaY = 0f
        var threeFingerTotalMove = 0f
        var threeFingerSwipeTriggered = false

        fun clearVisual() = onVisualStateChange(GestureVisualState())

        try {
            while (true) {
                val event = if (mode == GestureSubMode.PENDING_SINGLE && !rightClickArmed) {
                    val targetMs = if (!longPressArmed) longPressArmMs else longPressRightClickMs
                    val remaining = (targetMs - (System.currentTimeMillis() - downTimeMs)).coerceAtLeast(1L)
                    val awaited = withTimeoutOrNull(remaining) { awaitPointerEvent() }
                    if (awaited == null) {
                        if (!longPressArmed) {
                            longPressArmed = true
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            onVisualStateChange(
                                GestureVisualState(
                                    persistentBadge = "拖拽就绪 · 移动拖拽",
                                    isLongPressArmed = true,
                                    directTouchRingPos = if (touchMode == TouchMode.DIRECT_TOUCH) lastSinglePos else null
                                )
                            )
                        } else {
                            rightClickArmed = true
                            onVisualStateChange(
                                GestureVisualState(
                                    persistentBadge = "按住拖动 / 抬起右键",
                                    isLongPressArmed = true,
                                    directTouchRingPos = if (touchMode == TouchMode.DIRECT_TOUCH) lastSinglePos else null
                                )
                            )
                        }
                        continue
                    }
                    awaited
                } else {
                    awaitPointerEvent()
                }

                val now = System.currentTimeMillis()
                val pressed = event.changes.filter { it.pressed }

                if (pressed.isEmpty()) {
                    when (mode) {
                        GestureSubMode.REMOTE_DRAG -> {
                            onDragEnd(currentDragNorm)
                            lastSingleTapTimeMs = 0L
                        }
                        GestureSubMode.PENDING_SINGLE -> {
                            val heldMs = now - downTimeMs
                            val anchor = if (touchMode == TouchMode.DIRECT_TOUCH) screenToNormalized(lastSinglePos) else getCursor()
                            when {
                                heldMs >= longPressRightClickMs -> { onRightClick(anchor); lastSingleTapTimeMs = 0L }
                                isDoubleTapCandidate -> { onLeftClick(anchor, 2); lastSingleTapTimeMs = 0L }
                                else -> { onLeftClick(anchor, 1); lastSingleTapTimeMs = now; lastSingleTapPos = lastSinglePos }
                            }
                        }
                        GestureSubMode.TWO_FINGER_PENDING -> {
                            val elapsed = now - twoFingerStartTimeMs
                            if (!secondFingerRightClickFired && elapsed <= twoFingerTapMaxMs && twoFingerTotalCentroidMove <= twoFingerTapMaxMovePx) {
                                val anchor = if (touchMode == TouchMode.DIRECT_TOUCH) screenToNormalized(twoFingerStartCentroid) else getCursor()
                                onRightClick(anchor)
                            }
                        }
                        GestureSubMode.THREE_FINGER -> {
                            if (!threeFingerSwipeTriggered && (now - threeFingerStartTimeMs) <= threeFingerTapMaxMs && threeFingerTotalMove <= touchSlop * 2.4f) {
                                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                onThreeFingerTap()
                            }
                        }
                        else -> Unit
                    }
                    clearVisual()
                    break
                }

                if (pressed.size >= 3) {
                    if (mode == GestureSubMode.REMOTE_DRAG) onDragEnd(currentDragNorm)
                    if (mode != GestureSubMode.THREE_FINGER) {
                        mode = GestureSubMode.THREE_FINGER
                        threeFingerStartTimeMs = now
                        threeFingerTotalDeltaY = 0f
                        threeFingerTotalMove = 0f
                        threeFingerSwipeTriggered = false
                        clearVisual()
                    } else {
                        val panChange = event.calculatePan()
                        threeFingerTotalDeltaY += panChange.y
                        threeFingerTotalMove += hypot(panChange.x.toDouble(), panChange.y.toDouble()).toFloat()
                        if (!threeFingerSwipeTriggered && abs(threeFingerTotalDeltaY) >= threeFingerSwipeThresholdPx) {
                            threeFingerSwipeTriggered = true
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            onThreeFingerVerticalSwipe(threeFingerTotalDeltaY > 0f)
                        }
                    }
                    event.changes.forEach { if (it.positionChanged()) it.consume() }
                    continue
                }

                if (mode == GestureSubMode.THREE_FINGER) {
                    event.changes.forEach { if (it.positionChanged()) it.consume() }
                    continue
                }

                if (pressed.size == 2) {
                    if (mode == GestureSubMode.REMOTE_DRAG) onDragEnd(currentDragNorm)
                    val p0 = pressed[0].position
                    val p1 = pressed[1].position
                    val span = hypot((p1.x - p0.x).toDouble(), (p1.y - p0.y).toDouble()).toFloat()
                    val centroid = Offset((p0.x + p1.x) / 2f, (p0.y + p1.y) / 2f)

                    if (!twoFingerEntered || (mode != GestureSubMode.TWO_FINGER_PENDING && mode != GestureSubMode.TWO_FINGER_PINCH && mode != GestureSubMode.TWO_FINGER_SCROLL)) {
                        twoFingerEntered = true
                        mode = GestureSubMode.TWO_FINGER_PENDING
                        initialSpan = span
                        twoFingerStartTimeMs = now
                        twoFingerStartCentroid = centroid
                        twoFingerTotalCentroidMove = 0f
                        secondFingerRightClickFired = false
                        val sec = pressed.firstOrNull { it.id != firstPointerId } ?: pressed[1]
                        secondFingerId = sec.id
                        secondFingerDownTimeMs = now
                        secondFingerDownPos = sec.position
                        secondFingerMaxDisp = 0f
                        clearVisual()
                        event.changes.forEach { if (it.positionChanged()) it.consume() }
                        continue
                    }

                    pressed.firstOrNull { it.id == secondFingerId }?.let { sec ->
                        val disp = hypot((sec.position.x - secondFingerDownPos.x).toDouble(), (sec.position.y - secondFingerDownPos.y).toDouble()).toFloat()
                        if (disp > secondFingerMaxDisp) secondFingerMaxDisp = disp
                    }

                    val zoomChange = event.calculateZoom()
                    val panChange = event.calculatePan()
                    twoFingerTotalCentroidMove += hypot(panChange.x.toDouble(), panChange.y.toDouble()).toFloat()
                    val spanDelta = abs(span - initialSpan)

                    if (mode == GestureSubMode.TWO_FINGER_PENDING) {
                        if (spanDelta > pinchLockThresholdPx) mode = GestureSubMode.TWO_FINGER_PINCH
                        else if (twoFingerTotalCentroidMove > touchSlop * 1.15f) mode = GestureSubMode.TWO_FINGER_SCROLL
                    }

                    when (mode) {
                        GestureSubMode.TWO_FINGER_PINCH -> {
                            val curZ = getZoom()
                            val nextZ = (curZ * zoomChange).coerceIn(MIN_ZOOM, MAX_ZOOM)
                            val ratio = if (curZ > 0f) nextZ / curZ else 1f
                            val rel = centroid - getBaseRect().center
                            onUpdateZoomPan(nextZ, (getPan() - rel) * ratio + rel + panChange)
                            onVisualStateChange(GestureVisualState(persistentBadge = String.format(Locale.US, "缩放 %.1fx", nextZ)))
                        }
                        GestureSubMode.TWO_FINGER_SCROLL -> if (panChange != Offset.Zero) {
                            val anchor = if (touchMode == TouchMode.DIRECT_TOUCH) screenToNormalized(centroid) else getCursor()
                            onScroll(anchor, panChange.x * 0.75f, panChange.y * 0.75f)
                        }
                        else -> Unit
                    }
                    event.changes.forEach { if (it.positionChanged()) it.consume() }
                    continue
                }

                // 1 finger active
                val change = pressed.first()
                if (mode == GestureSubMode.TWO_FINGER_PENDING) {
                    if (change.id == firstPointerId && !secondFingerRightClickFired &&
                        (now - secondFingerDownTimeMs) <= twoFingerTapMaxMs &&
                        secondFingerMaxDisp <= twoFingerTapMaxMovePx
                    ) {
                        val anchor = if (touchMode == TouchMode.DIRECT_TOUCH) screenToNormalized(change.position) else getCursor()
                        onRightClick(anchor)
                        secondFingerRightClickFired = true
                        mode = GestureSubMode.CONSUMED_WAIT_UP
                        clearVisual()
                    }
                    lastSinglePos = change.position
                    if (change.positionChanged()) change.consume()
                    continue
                }

                if (mode == GestureSubMode.TWO_FINGER_PINCH || mode == GestureSubMode.TWO_FINGER_SCROLL || mode == GestureSubMode.CONSUMED_WAIT_UP) {
                    mode = GestureSubMode.CONSUMED_WAIT_UP
                    clearVisual()
                    if (change.positionChanged()) change.consume()
                    continue
                }

                val curPos = change.position
                val delta = curPos - lastSinglePos
                lastSinglePos = curPos

                when (mode) {
                    GestureSubMode.PENDING_SINGLE -> {
                        val dist = hypot((curPos.x - downPos.x).toDouble(), (curPos.y - downPos.y).toDouble()).toFloat()
                        if (dist > touchSlop) {
                            val startDrag = longPressArmed || isDoubleTapCandidate || (touchMode == TouchMode.DIRECT_TOUCH && getZoom() <= 1.03f)
                            if (startDrag) {
                                mode = GestureSubMode.REMOTE_DRAG
                                if (!longPressArmed) haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                if (touchMode == TouchMode.DIRECT_TOUCH) {
                                    val startN = screenToNormalized(downPos)
                                    val moveN = screenToNormalized(curPos)
                                    currentDragNorm = moveN
                                    onDragStart(startN)
                                    onDragMove(moveN)
                                    onVisualStateChange(GestureVisualState("拖拽中...", isDragging = true, directTouchRingPos = curPos))
                                } else {
                                    val startC = getCursor()
                                    val nextC = trackpadNextCursor(curPos - downPos)
                                    currentDragNorm = nextC
                                    onDragStart(startC)
                                    onUpdateCursorAndAutoPan(nextC)
                                    onDragMove(nextC)
                                    onVisualStateChange(GestureVisualState("拖拽中...", isDragging = true))
                                }
                            } else if (touchMode == TouchMode.DIRECT_TOUCH) {
                                mode = GestureSubMode.VIEWPORT_PAN
                                clearVisual()
                                onUpdateZoomPan(getZoom(), getPan() + (curPos - downPos))
                            } else {
                                mode = GestureSubMode.TRACKPAD_MOVE
                                clearVisual()
                                val nextC = trackpadNextCursor(curPos - downPos)
                                onUpdateCursorAndAutoPan(nextC)
                                onMove(nextC)
                            }
                            change.consume()
                        }
                    }
                    GestureSubMode.REMOTE_DRAG -> if (delta != Offset.Zero) {
                        if (touchMode == TouchMode.DIRECT_TOUCH) {
                            val nextN = screenToNormalized(curPos)
                            currentDragNorm = nextN
                            onDragMove(nextN)
                            onVisualStateChange(GestureVisualState("拖拽中...", isDragging = true, directTouchRingPos = curPos))
                        } else {
                            val nextC = trackpadNextCursor(delta)
                            currentDragNorm = nextC
                            onUpdateCursorAndAutoPan(nextC)
                            onDragMove(nextC)
                        }
                        change.consume()
                    }
                    GestureSubMode.VIEWPORT_PAN -> if (delta != Offset.Zero) {
                        onUpdateZoomPan(getZoom(), getPan() + delta)
                        change.consume()
                    }
                    GestureSubMode.TRACKPAD_MOVE -> if (delta != Offset.Zero) {
                        val nextC = trackpadNextCursor(delta)
                        onUpdateCursorAndAutoPan(nextC)
                        onMove(nextC)
                        change.consume()
                    }
                    else -> Unit
                }
            }
        } finally {
            clearVisual()
        }
    }
}

@Composable
private fun MacCursorOverlay(
    cursorPos: Offset,
    cursorKind: String,
    videoRect: Rect,
    effectiveScale: Float,
    pan: Offset,
    isDragging: Boolean = false,
    isLongPressArmed: Boolean = false
) {
    Canvas(modifier = Modifier.fillMaxSize()) {
        val x = (videoRect.left + cursorPos.x * videoRect.width - videoRect.center.x) * effectiveScale + videoRect.center.x + pan.x
        val y = (videoRect.top + cursorPos.y * videoRect.height - videoRect.center.y) * effectiveScale + videoRect.center.y + pan.y

        if (isDragging || isLongPressArmed) {
            val halo = if (isDragging) WsOnline else WsWarn
            val r = 15.dp.toPx()
            drawCircle(halo.copy(alpha = 0.24f), radius = r, center = Offset(x, y))
            drawCircle(halo, radius = r, center = Offset(x, y), style = Stroke(width = 2.dp.toPx()))
        }

        when (cursorKind.lowercase()) {
            "ibeam", "text" -> {
                val h = 18.dp.toPx()
                val s = 4.dp.toPx()
                drawLine(Color.White, Offset(x, y - h / 2f), Offset(x, y + h / 2f), strokeWidth = 4.5f, cap = StrokeCap.Round)
                drawLine(Color.Black, Offset(x, y - h / 2f), Offset(x, y + h / 2f), strokeWidth = 2.2f, cap = StrokeCap.Round)
                drawLine(Color.White, Offset(x - s, y - h / 2f), Offset(x + s, y - h / 2f), strokeWidth = 4f)
                drawLine(Color.Black, Offset(x - s, y - h / 2f), Offset(x + s, y - h / 2f), strokeWidth = 2f)
                drawLine(Color.White, Offset(x - s, y + h / 2f), Offset(x + s, y + h / 2f), strokeWidth = 4f)
                drawLine(Color.Black, Offset(x - s, y + h / 2f), Offset(x + s, y + h / 2f), strokeWidth = 2f)
            }
            "pointing_hand", "hand", "pointer" -> {
                val r = 5.5.dp.toPx()
                drawCircle(Color.White.copy(alpha = 0.3f), radius = r * 1.9f, center = Offset(x, y))
                drawCircle(Color.White, radius = r, center = Offset(x, y))
                drawCircle(WsOnline, radius = r * 0.6f, center = Offset(x, y))
            }
            else -> {
                val s = 18.dp.toPx()
                val path = Path().apply {
                    moveTo(x, y)
                    lineTo(x, y + s)
                    lineTo(x + s * 0.32f, y + s * 0.72f)
                    lineTo(x + s * 0.56f, y + s * 1.08f)
                    lineTo(x + s * 0.74f, y + s * 0.96f)
                    lineTo(x + s * 0.50f, y + s * 0.62f)
                    lineTo(x + s * 0.85f, y + s * 0.58f)
                    close()
                }
                drawPath(path, Color.Black)
                drawPath(path, Color.White, style = Stroke(width = 2.2f, join = StrokeJoin.Round))
            }
        }
    }
}

@Composable
private fun DebugTelemetryHud(
    telemetry: VideoTelemetry,
    linkBadge: String,
    touchMode: TouchMode,
    videoFitMode: VideoFitMode,
    zoom: Float,
    modifier: Modifier = Modifier
) {
    Surface(
        color = Color(0xCC121215),
        shape = RoundedCornerShape(8.dp),
        border = BorderStroke(0.5.dp, WsPopoverBorder),
        modifier = modifier
    ) {
        Column(modifier = Modifier.padding(horizontal = 9.dp, vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                text = "${telemetry.codec}  ${telemetry.width}×${telemetry.height}  ${telemetry.fps} FPS",
                color = WsOnline,
                fontFamily = FontFamily.Monospace,
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold
            )
            Text(
                text = String.format(Locale.US, "%.2f Mbps · %d帧 · %s/%s", telemetry.bitrateMbps, telemetry.decodedFrames, touchMode.label, videoFitMode.label),
                color = WsTextPrimary,
                fontFamily = FontFamily.Monospace,
                fontSize = 10.sp
            )
            Text(
                text = buildString {
                    append(linkBadge.ifBlank { "Link: -" })
                    if (zoom > 1.01f) append(String.format(Locale.US, " · %.1fx", zoom))
                },
                color = WsTextMuted,
                fontFamily = FontFamily.Monospace,
                fontSize = 10.sp
            )
        }
    }
}

private const val IME_SENTINEL = "\u200B\u200B\u200B\u200B"

/**
 * Invisible native EditText responder that connects directly to the system IME (Chinese Pinyin,
 * English, Emoji, Swipe, Voice) without displaying any text input box:
 * - Committed text is streamed immediately to the remote Mac.
 * - Pressing Backspace (⌫) even with no pending text deletes characters directly on the remote Mac
 *   by maintaining a 4-char zero-width-space sentinel buffer below any active IME composition.
 */
@Composable
private fun DirectRemoteImeHost(
    imeRequested: Boolean,
    imeRequestSeq: Long,
    onCommitText: (String) -> Unit,
    onBackspace: (isRepeat: Boolean) -> Unit,
    onKeyTap: (keyCode: Int, isRepeat: Boolean) -> Unit,
    onComposingPreviewChanged: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    val currentOnCommit by rememberUpdatedState(onCommitText)
    val currentOnBackspace by rememberUpdatedState(onBackspace)
    val currentOnKeyTap by rememberUpdatedState(onKeyTap)
    val currentOnComposing by rememberUpdatedState(onComposingPreviewChanged)

    var hostEditText by remember { mutableStateOf<DirectRemoteImeEditText?>(null) }

    DisposableEffect(Unit) {
        onDispose {
            hostEditText?.let { et ->
                val imm = et.context.getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
                imm?.hideSoftInputFromWindow(et.windowToken, 0)
                et.clearFocus()
            }
            currentOnComposing("")
        }
    }

    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            DirectRemoteImeEditText(ctx).apply {
                onCommitCallback = { currentOnCommit(it) }
                onBackspaceCallback = { currentOnBackspace(it) }
                onKeyTapCallback = { code, rep -> currentOnKeyTap(code, rep) }
                onComposingCallback = { currentOnComposing(it) }
                hostEditText = this
            }
        },
        update = { et ->
            et.onCommitCallback = { currentOnCommit(it) }
            et.onBackspaceCallback = { currentOnBackspace(it) }
            et.onKeyTapCallback = { code, rep -> currentOnKeyTap(code, rep) }
            et.onComposingCallback = { currentOnComposing(it) }

            if (imeRequested) {
                if (et.lastShownSeq != imeRequestSeq) {
                    et.lastShownSeq = imeRequestSeq
                    et.wasRequested = true
                    et.post {
                        if (!et.hasFocus()) {
                            et.requestFocus()
                        }
                        et.ensureCursorAtEndIfIdle()
                        val imm = et.context.getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
                        imm?.showSoftInput(et, 0)
                    }
                }
            } else if (et.wasRequested) {
                et.wasRequested = false
                et.post {
                    val imm = et.context.getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
                    imm?.hideSoftInputFromWindow(et.windowToken, 0)
                    et.clearFocus()
                }
            }
        }
    )
}

private class DirectRemoteImeEditText(context: Context) : EditText(context) {
    var onCommitCallback: ((String) -> Unit)? = null
    var onBackspaceCallback: ((Boolean) -> Unit)? = null
    var onKeyTapCallback: ((Int, Boolean) -> Unit)? = null
    var onComposingCallback: ((String) -> Unit)? = null

    var lastShownSeq: Long = -1L
    var wasRequested: Boolean = false
    private var internalMutation: Boolean = false

    init {
        background = null
        isCursorVisible = false
        setPadding(0, 0, 0, 0)
        textSize = 1f
        setTextColor(android.graphics.Color.TRANSPARENT)
        isFocusable = true
        isFocusableInTouchMode = true
        isSingleLine = false
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
        imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_ACTION_NONE
        resetToSentinel()

        addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
            override fun afterTextChanged(s: Editable?) {
                if (internalMutation || s == null) return
                val compStart = BaseInputConnection.getComposingSpanStart(s)
                val compEnd = BaseInputConnection.getComposingSpanEnd(s)
                if (compStart >= 0 && compEnd > compStart && compEnd <= s.length) {
                    val preview = s.subSequence(compStart, compEnd).toString().replace("\u200B", "")
                    onComposingCallback?.invoke(preview)
                    return
                }
                onComposingCallback?.invoke("")

                val raw = s.toString()
                var sentinelCount = 0
                val committed = StringBuilder()
                for (ch in raw) {
                    if (ch == '\u200B') sentinelCount++ else committed.append(ch)
                }

                if (committed.isNotEmpty()) {
                    resetToSentinel()
                    onCommitCallback?.invoke(committed.toString())
                } else if (sentinelCount < IME_SENTINEL.length) {
                    val deletes = (IME_SENTINEL.length - sentinelCount).coerceIn(1, 8)
                    resetToSentinel()
                    for (i in 0 until deletes) {
                        onBackspaceCallback?.invoke(i > 0 || deletes > 1)
                    }
                } else if (raw != IME_SENTINEL) {
                    resetToSentinel()
                }
            }
        })
    }

    fun resetToSentinel() {
        internalMutation = true
        try {
            setText(IME_SENTINEL)
            setSelection(IME_SENTINEL.length)
        } finally {
            internalMutation = false
        }
    }

    fun ensureCursorAtEndIfIdle() {
        val s = text ?: return
        val compStart = BaseInputConnection.getComposingSpanStart(s)
        if (compStart < 0 && selectionStart != s.length) {
            internalMutation = true
            try {
                setSelection(s.length)
            } finally {
                internalMutation = false
            }
        }
    }

    override fun onSelectionChanged(selStart: Int, selEnd: Int) {
        super.onSelectionChanged(selStart, selEnd)
        if (internalMutation) return
        val s = text ?: return
        val compStart = BaseInputConnection.getComposingSpanStart(s)
        if (compStart < 0 && (selStart != s.length || selEnd != s.length)) {
            internalMutation = true
            try {
                setSelection(s.length)
            } finally {
                internalMutation = false
            }
        }
    }

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? {
        val base = super.onCreateInputConnection(outAttrs) ?: return null
        outAttrs.imeOptions = outAttrs.imeOptions or EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_ACTION_NONE
        return object : InputConnectionWrapper(base, true) {
            private fun isComposingNow(): Boolean {
                val s = text ?: return false
                val cs = BaseInputConnection.getComposingSpanStart(s)
                val ce = BaseInputConnection.getComposingSpanEnd(s)
                return cs >= 0 && ce > cs
            }

            override fun sendKeyEvent(event: KeyEvent): Boolean {
                if (!isComposingNow()) {
                    val isRepeat = event.repeatCount > 0
                    when (event.keyCode) {
                        KeyEvent.KEYCODE_DEL -> {
                            if (event.action == KeyEvent.ACTION_DOWN) {
                                resetToSentinel()
                                onBackspaceCallback?.invoke(isRepeat)
                            }
                            return true
                        }
                        KeyEvent.KEYCODE_FORWARD_DEL -> {
                            if (event.action == KeyEvent.ACTION_DOWN) {
                                resetToSentinel()
                                onKeyTapCallback?.invoke(MacKeyCodes.FORWARD_DELETE, isRepeat)
                            }
                            return true
                        }
                        KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> {
                            if (event.action == KeyEvent.ACTION_DOWN) {
                                resetToSentinel()
                                onKeyTapCallback?.invoke(MacKeyCodes.RETURN, isRepeat)
                            }
                            return true
                        }
                        KeyEvent.KEYCODE_TAB -> {
                            if (event.action == KeyEvent.ACTION_DOWN) {
                                resetToSentinel()
                                onKeyTapCallback?.invoke(MacKeyCodes.TAB, isRepeat)
                            }
                            return true
                        }
                        KeyEvent.KEYCODE_ESCAPE -> {
                            if (event.action == KeyEvent.ACTION_DOWN) {
                                resetToSentinel()
                                onKeyTapCallback?.invoke(MacKeyCodes.ESCAPE, false)
                            }
                            return true
                        }
                        KeyEvent.KEYCODE_DPAD_LEFT -> {
                            if (event.action == KeyEvent.ACTION_DOWN) onKeyTapCallback?.invoke(MacKeyCodes.LEFT, isRepeat)
                            return true
                        }
                        KeyEvent.KEYCODE_DPAD_RIGHT -> {
                            if (event.action == KeyEvent.ACTION_DOWN) onKeyTapCallback?.invoke(MacKeyCodes.RIGHT, isRepeat)
                            return true
                        }
                        KeyEvent.KEYCODE_DPAD_UP -> {
                            if (event.action == KeyEvent.ACTION_DOWN) onKeyTapCallback?.invoke(MacKeyCodes.UP, isRepeat)
                            return true
                        }
                        KeyEvent.KEYCODE_DPAD_DOWN -> {
                            if (event.action == KeyEvent.ACTION_DOWN) onKeyTapCallback?.invoke(MacKeyCodes.DOWN, isRepeat)
                            return true
                        }
                        KeyEvent.KEYCODE_MOVE_HOME -> {
                            if (event.action == KeyEvent.ACTION_DOWN) onKeyTapCallback?.invoke(MacKeyCodes.HOME, isRepeat)
                            return true
                        }
                        KeyEvent.KEYCODE_MOVE_END -> {
                            if (event.action == KeyEvent.ACTION_DOWN) onKeyTapCallback?.invoke(MacKeyCodes.END, isRepeat)
                            return true
                        }
                        KeyEvent.KEYCODE_PAGE_UP -> {
                            if (event.action == KeyEvent.ACTION_DOWN) onKeyTapCallback?.invoke(MacKeyCodes.PAGE_UP, isRepeat)
                            return true
                        }
                        KeyEvent.KEYCODE_PAGE_DOWN -> {
                            if (event.action == KeyEvent.ACTION_DOWN) onKeyTapCallback?.invoke(MacKeyCodes.PAGE_DOWN, isRepeat)
                            return true
                        }
                        KeyEvent.KEYCODE_F1 -> { if (event.action == KeyEvent.ACTION_DOWN) onKeyTapCallback?.invoke(MacKeyCodes.F1, false); return true }
                        KeyEvent.KEYCODE_F2 -> { if (event.action == KeyEvent.ACTION_DOWN) onKeyTapCallback?.invoke(MacKeyCodes.F2, false); return true }
                        KeyEvent.KEYCODE_F3 -> { if (event.action == KeyEvent.ACTION_DOWN) onKeyTapCallback?.invoke(MacKeyCodes.F3, false); return true }
                        KeyEvent.KEYCODE_F4 -> { if (event.action == KeyEvent.ACTION_DOWN) onKeyTapCallback?.invoke(MacKeyCodes.F4, false); return true }
                        KeyEvent.KEYCODE_F5 -> { if (event.action == KeyEvent.ACTION_DOWN) onKeyTapCallback?.invoke(MacKeyCodes.F5, false); return true }
                        KeyEvent.KEYCODE_F6 -> { if (event.action == KeyEvent.ACTION_DOWN) onKeyTapCallback?.invoke(MacKeyCodes.F6, false); return true }
                        KeyEvent.KEYCODE_F7 -> { if (event.action == KeyEvent.ACTION_DOWN) onKeyTapCallback?.invoke(MacKeyCodes.F7, false); return true }
                        KeyEvent.KEYCODE_F8 -> { if (event.action == KeyEvent.ACTION_DOWN) onKeyTapCallback?.invoke(MacKeyCodes.F8, false); return true }
                        KeyEvent.KEYCODE_F9 -> { if (event.action == KeyEvent.ACTION_DOWN) onKeyTapCallback?.invoke(MacKeyCodes.F9, false); return true }
                        KeyEvent.KEYCODE_F10 -> { if (event.action == KeyEvent.ACTION_DOWN) onKeyTapCallback?.invoke(MacKeyCodes.F10, false); return true }
                        KeyEvent.KEYCODE_F11 -> { if (event.action == KeyEvent.ACTION_DOWN) onKeyTapCallback?.invoke(MacKeyCodes.F11, false); return true }
                        KeyEvent.KEYCODE_F12 -> { if (event.action == KeyEvent.ACTION_DOWN) onKeyTapCallback?.invoke(MacKeyCodes.F12, false); return true }
                    }
                }
                return super.sendKeyEvent(event)
            }
        }
    }
}

private enum class SimKeyPage(val label: String) {
    MAIN("常用按键"),
    COMBOS("组合键"),
    FKEYS("F1-F12")
}

private data class SimComboDef(
    val keyHint: String,
    val subtitle: String,
    val keyCode: Int,
    val modifiers: Int
)

private val SimComboRows: List<List<SimComboDef>> = listOf(
    listOf(
        SimComboDef("⌘A", "全选", MacKeyCodes.A, MacModifiers.COMMAND),
        SimComboDef("⌘S", "保存", MacKeyCodes.S, MacModifiers.COMMAND),
        SimComboDef("⌘F", "查找", MacKeyCodes.F, MacModifiers.COMMAND),
        SimComboDef("⌘R", "刷新", MacKeyCodes.R, MacModifiers.COMMAND)
    ),
    listOf(
        SimComboDef("⌘T", "新标签", MacKeyCodes.T, MacModifiers.COMMAND),
        SimComboDef("⌘W", "关窗口", MacKeyCodes.W, MacModifiers.COMMAND),
        SimComboDef("⌘N", "新建", MacKeyCodes.N, MacModifiers.COMMAND),
        SimComboDef("⌘Space", "搜索", MacKeyCodes.SPACE, MacModifiers.COMMAND)
    ),
    listOf(
        SimComboDef("⌘Tab", "切应用", MacKeyCodes.TAB, MacModifiers.COMMAND),
        SimComboDef("⌃←", "左桌面", MacKeyCodes.LEFT, MacModifiers.CONTROL),
        SimComboDef("⌃→", "右桌面", MacKeyCodes.RIGHT, MacModifiers.CONTROL),
        SimComboDef("⌃↑", "调度中心", MacKeyCodes.UP, MacModifiers.CONTROL)
    )
)

@Composable
private fun MacKeyboardAndImeDock(
    isImeActive: Boolean,
    composingPreview: String,
    stickyModifiers: Int,
    onToggleModifier: (Int) -> Unit,
    onSendKeyTap: (keyCode: Int, explicitModifiers: Int?, isRepeat: Boolean) -> Unit,
    onToggleIme: () -> Unit,
    onCloseDock: () -> Unit
) {
    var isExpanded by rememberSaveable { mutableStateOf(true) }
    var activePage by rememberSaveable { mutableStateOf(SimKeyPage.MAIN) }

    Column(modifier = Modifier.fillMaxWidth().background(WsBarBg)) {
        HorizontalDivider(thickness = 0.5.dp, color = WsDivider)

        // Optional live Pinyin composition preview pill when collapsed
        if (!isExpanded && composingPreview.isNotBlank()) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 8.dp, vertical = 3.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "输入中: $composingPreview",
                    fontSize = 11.5.sp,
                    color = WsOnline,
                    fontFamily = FontFamily.Monospace,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }

        if (!isExpanded) {
            // Collapsed compact 1-row quick bar (full-width, large tap targets, no scrolling needed)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 6.dp, vertical = 5.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                SimKeyCap(
                    label = "Esc",
                    modifier = Modifier.weight(1.05f),
                    height = 36.dp,
                    onTrigger = { rep -> onSendKeyTap(MacKeyCodes.ESCAPE, null, rep) }
                )
                SimKeyCap(
                    label = "Tab",
                    modifier = Modifier.weight(1.05f),
                    height = 36.dp,
                    onTrigger = { rep -> onSendKeyTap(MacKeyCodes.TAB, null, rep) }
                )
                SimKeyCap(
                    label = "⌘",
                    active = (stickyModifiers and MacModifiers.COMMAND) != 0,
                    modifier = Modifier.weight(0.95f),
                    height = 36.dp,
                    onTrigger = { onToggleModifier(MacModifiers.COMMAND) }
                )
                SimKeyCap(
                    label = "⌃",
                    active = (stickyModifiers and MacModifiers.CONTROL) != 0,
                    modifier = Modifier.weight(0.95f),
                    height = 36.dp,
                    onTrigger = { onToggleModifier(MacModifiers.CONTROL) }
                )
                SimKeyCap(
                    label = "⌥",
                    active = (stickyModifiers and MacModifiers.OPTION) != 0,
                    modifier = Modifier.weight(0.95f),
                    height = 36.dp,
                    onTrigger = { onToggleModifier(MacModifiers.OPTION) }
                )
                SimKeyCap(
                    label = "⇧",
                    active = (stickyModifiers and MacModifiers.SHIFT) != 0,
                    modifier = Modifier.weight(0.95f),
                    height = 36.dp,
                    onTrigger = { onToggleModifier(MacModifiers.SHIFT) }
                )
                SimKeyCap(
                    label = "⌫",
                    repeatable = true,
                    modifier = Modifier.weight(1.05f),
                    height = 36.dp,
                    onTrigger = { rep -> onSendKeyTap(MacKeyCodes.DELETE, null, rep) }
                )
                // Toggle system soft keyboard up/down
                Surface(
                    onClick = onToggleIme,
                    color = if (isImeActive) WsTextPrimary else WsElevatedBg,
                    shape = RoundedCornerShape(7.dp),
                    border = BorderStroke(0.5.dp, if (isImeActive) WsTextPrimary else WsPopoverBorder),
                    modifier = Modifier.weight(1.05f).height(36.dp)
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Icon(
                            imageVector = if (isImeActive) Icons.Rounded.KeyboardHide else Icons.Rounded.Keyboard,
                            contentDescription = if (isImeActive) "收起输入法" else "唤起输入法",
                            tint = if (isImeActive) WsBg else WsTextPrimary,
                            modifier = Modifier.size(16.dp)
                        )
                    }
                }
                // Expand to multi-row dock
                Surface(
                    onClick = { isExpanded = true },
                    color = WsElevatedBg,
                    shape = RoundedCornerShape(7.dp),
                    border = BorderStroke(0.5.dp, WsPopoverBorder),
                    modifier = Modifier.weight(1.25f).height(36.dp)
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.Center
                    ) {
                        Text("展开", fontSize = 11.5.sp, fontWeight = FontWeight.Medium, color = WsTextPrimary)
                        Icon(
                            imageVector = Icons.Rounded.KeyboardArrowUp,
                            contentDescription = "展开多行按键",
                            tint = WsTextMuted,
                            modifier = Modifier.size(14.dp)
                        )
                    }
                }
            }
        } else {
            // Expanded multi-row Mac auxiliary keyboard
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 6.dp, vertical = 6.dp),
                verticalArrangement = Arrangement.spacedBy(5.dp)
            ) {
                // Header control bar: Page switcher + Pinyin preview + [输入法] + [收起] + [关闭]
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(5.dp)
                ) {
                    SimKeyPage.entries.forEach { page ->
                        val selected = (activePage == page)
                        Surface(
                            onClick = { activePage = page },
                            color = if (selected) WsActiveTabBg else Color.Transparent,
                            shape = RoundedCornerShape(6.dp),
                            border = BorderStroke(0.5.dp, if (selected) WsPopoverBorder else WsBorder)
                        ) {
                            Text(
                                text = page.label,
                                fontSize = 11.5.sp,
                                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                                color = if (selected) WsTextPrimary else WsTextMuted,
                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp)
                            )
                        }
                    }

                    if (composingPreview.isNotBlank()) {
                        Text(
                            text = composingPreview,
                            fontSize = 11.sp,
                            color = WsOnline,
                            fontFamily = FontFamily.Monospace,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f).padding(horizontal = 4.dp)
                        )
                    } else {
                        Spacer(Modifier.weight(1f))
                    }

                    // System IME soft keyboard toggle
                    Surface(
                        onClick = onToggleIme,
                        color = if (isImeActive) WsTextPrimary else WsElevatedBg,
                        shape = RoundedCornerShape(6.dp),
                        border = BorderStroke(0.5.dp, if (isImeActive) WsTextPrimary else WsPopoverBorder)
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(3.dp)
                        ) {
                            Icon(
                                imageVector = if (isImeActive) Icons.Rounded.KeyboardHide else Icons.Rounded.Keyboard,
                                contentDescription = null,
                                tint = if (isImeActive) WsBg else WsTextPrimary,
                                modifier = Modifier.size(13.5.dp)
                            )
                            Text(
                                text = if (isImeActive) "收输入法" else "输入法",
                                fontSize = 11.sp,
                                fontWeight = FontWeight.Medium,
                                color = if (isImeActive) WsBg else WsTextPrimary
                            )
                        }
                    }

                    // Collapse to 1-row
                    Surface(
                        onClick = { isExpanded = false },
                        color = WsElevatedBg,
                        shape = RoundedCornerShape(6.dp),
                        border = BorderStroke(0.5.dp, WsBorder)
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 7.dp, vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(2.dp)
                        ) {
                            Text("收起", fontSize = 11.sp, color = WsTextPrimary)
                            Icon(
                                imageVector = Icons.Rounded.KeyboardArrowDown,
                                contentDescription = "收起为单行",
                                tint = WsTextMuted,
                                modifier = Modifier.size(14.dp)
                            )
                        }
                    }

                    // Close entire dock
                    Box(
                        modifier = Modifier
                            .size(26.dp)
                            .clip(RoundedCornerShape(6.dp))
                            .clickable(onClick = onCloseDock),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.Close,
                            contentDescription = "关闭按键栏",
                            tint = WsTextMuted,
                            modifier = Modifier.size(15.dp)
                        )
                    }
                }

                when (activePage) {
                    SimKeyPage.MAIN -> {
                        // Row 1: Esc | Tab | Space | ⌫ | ⌦ | ⏎
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(5.dp)
                        ) {
                            SimKeyCap(
                                label = "Esc",
                                modifier = Modifier.weight(1f),
                                onTrigger = { rep -> onSendKeyTap(MacKeyCodes.ESCAPE, null, rep) }
                            )
                            SimKeyCap(
                                label = "Tab",
                                modifier = Modifier.weight(1f),
                                onTrigger = { rep -> onSendKeyTap(MacKeyCodes.TAB, null, rep) }
                            )
                            SimKeyCap(
                                label = "Space 空格",
                                repeatable = true,
                                modifier = Modifier.weight(1.85f),
                                onTrigger = { rep -> onSendKeyTap(MacKeyCodes.SPACE, null, rep) }
                            )
                            SimKeyCap(
                                label = "⌫",
                                repeatable = true,
                                modifier = Modifier.weight(1.1f),
                                onTrigger = { rep -> onSendKeyTap(MacKeyCodes.DELETE, null, rep) }
                            )
                            SimKeyCap(
                                label = "⌦",
                                repeatable = true,
                                modifier = Modifier.weight(0.95f),
                                onTrigger = { rep -> onSendKeyTap(MacKeyCodes.FORWARD_DELETE, null, rep) }
                            )
                            SimKeyCap(
                                label = "⏎ 回车",
                                emphasized = true,
                                modifier = Modifier.weight(1.25f),
                                onTrigger = { rep -> onSendKeyTap(MacKeyCodes.RETURN, null, rep) }
                            )
                        }

                        // Row 2: ⌘ | ⌃ | ⌥ | ⇧ | Home | PgUp | ↑ | End (8 equal columns)
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(5.dp)
                        ) {
                            SimKeyCap(
                                label = "⌘",
                                subtitle = "Cmd",
                                active = (stickyModifiers and MacModifiers.COMMAND) != 0,
                                modifier = Modifier.weight(1f),
                                onTrigger = { onToggleModifier(MacModifiers.COMMAND) }
                            )
                            SimKeyCap(
                                label = "⌃",
                                subtitle = "Ctrl",
                                active = (stickyModifiers and MacModifiers.CONTROL) != 0,
                                modifier = Modifier.weight(1f),
                                onTrigger = { onToggleModifier(MacModifiers.CONTROL) }
                            )
                            SimKeyCap(
                                label = "⌥",
                                subtitle = "Opt",
                                active = (stickyModifiers and MacModifiers.OPTION) != 0,
                                modifier = Modifier.weight(1f),
                                onTrigger = { onToggleModifier(MacModifiers.OPTION) }
                            )
                            SimKeyCap(
                                label = "⇧",
                                subtitle = "Shift",
                                active = (stickyModifiers and MacModifiers.SHIFT) != 0,
                                modifier = Modifier.weight(1f),
                                onTrigger = { onToggleModifier(MacModifiers.SHIFT) }
                            )
                            SimKeyCap(
                                label = "Home",
                                modifier = Modifier.weight(1f),
                                onTrigger = { rep -> onSendKeyTap(MacKeyCodes.HOME, null, rep) }
                            )
                            SimKeyCap(
                                label = "PgUp",
                                repeatable = true,
                                modifier = Modifier.weight(1f),
                                onTrigger = { rep -> onSendKeyTap(MacKeyCodes.PAGE_UP, null, rep) }
                            )
                            SimKeyCap(
                                label = "↑",
                                emphasized = true,
                                repeatable = true,
                                modifier = Modifier.weight(1f),
                                onTrigger = { rep -> onSendKeyTap(MacKeyCodes.UP, null, rep) }
                            )
                            SimKeyCap(
                                label = "End",
                                modifier = Modifier.weight(1f),
                                onTrigger = { rep -> onSendKeyTap(MacKeyCodes.END, null, rep) }
                            )
                        }

                        // Row 3: ⌘C | ⌘V | ⌘X | ⌘Z | PgDn | ← | ↓ | → (Inverted-T arrow cluster aligned with ↑ above!)
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(5.dp)
                        ) {
                            SimKeyCap(
                                label = "⌘C",
                                subtitle = "复制",
                                modifier = Modifier.weight(1f),
                                onTrigger = { onSendKeyTap(MacKeyCodes.C, MacModifiers.COMMAND, false) }
                            )
                            SimKeyCap(
                                label = "⌘V",
                                subtitle = "粘贴",
                                modifier = Modifier.weight(1f),
                                onTrigger = { onSendKeyTap(MacKeyCodes.V, MacModifiers.COMMAND, false) }
                            )
                            SimKeyCap(
                                label = "⌘X",
                                subtitle = "剪切",
                                modifier = Modifier.weight(1f),
                                onTrigger = { onSendKeyTap(MacKeyCodes.X, MacModifiers.COMMAND, false) }
                            )
                            SimKeyCap(
                                label = "⌘Z",
                                subtitle = "撤销",
                                modifier = Modifier.weight(1f),
                                onTrigger = { onSendKeyTap(MacKeyCodes.Z, MacModifiers.COMMAND, false) }
                            )
                            SimKeyCap(
                                label = "PgDn",
                                repeatable = true,
                                modifier = Modifier.weight(1f),
                                onTrigger = { rep -> onSendKeyTap(MacKeyCodes.PAGE_DOWN, null, rep) }
                            )
                            SimKeyCap(
                                label = "←",
                                emphasized = true,
                                repeatable = true,
                                modifier = Modifier.weight(1f),
                                onTrigger = { rep -> onSendKeyTap(MacKeyCodes.LEFT, null, rep) }
                            )
                            SimKeyCap(
                                label = "↓",
                                emphasized = true,
                                repeatable = true,
                                modifier = Modifier.weight(1f),
                                onTrigger = { rep -> onSendKeyTap(MacKeyCodes.DOWN, null, rep) }
                            )
                            SimKeyCap(
                                label = "→",
                                emphasized = true,
                                repeatable = true,
                                modifier = Modifier.weight(1f),
                                onTrigger = { rep -> onSendKeyTap(MacKeyCodes.RIGHT, null, rep) }
                            )
                        }
                    }

                    SimKeyPage.COMBOS -> {
                        SimComboRows.forEach { rowItems ->
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.spacedBy(5.dp)
                            ) {
                                rowItems.forEach { item ->
                                    SimKeyCap(
                                        label = item.keyHint,
                                        subtitle = item.subtitle,
                                        modifier = Modifier.weight(1f),
                                        onTrigger = { onSendKeyTap(item.keyCode, item.modifiers, false) }
                                    )
                                }
                            }
                        }
                    }

                    SimKeyPage.FKEYS -> {
                        val fRow1 = listOf(
                            "F1" to MacKeyCodes.F1, "F2" to MacKeyCodes.F2, "F3" to MacKeyCodes.F3,
                            "F4" to MacKeyCodes.F4, "F5" to MacKeyCodes.F5, "F6" to MacKeyCodes.F6
                        )
                        val fRow2 = listOf(
                            "F7" to MacKeyCodes.F7, "F8" to MacKeyCodes.F8, "F9" to MacKeyCodes.F9,
                            "F10" to MacKeyCodes.F10, "F11" to MacKeyCodes.F11, "F12" to MacKeyCodes.F12
                        )
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(5.dp)
                        ) {
                            fRow1.forEach { (lbl, code) ->
                                SimKeyCap(
                                    label = lbl,
                                    modifier = Modifier.weight(1f),
                                    onTrigger = { onSendKeyTap(code, null, false) }
                                )
                            }
                        }
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(5.dp)
                        ) {
                            fRow2.forEach { (lbl, code) ->
                                SimKeyCap(
                                    label = lbl,
                                    modifier = Modifier.weight(1f),
                                    onTrigger = { onSendKeyTap(code, null, false) }
                                )
                            }
                        }
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(5.dp)
                        ) {
                            SimKeyCap(
                                label = "⌘[",
                                subtitle = "后退",
                                modifier = Modifier.weight(1f),
                                onTrigger = { onSendKeyTap(MacKeyCodes.LEFT_BRACKET, MacModifiers.COMMAND, false) }
                            )
                            SimKeyCap(
                                label = "⌘]",
                                subtitle = "前进",
                                modifier = Modifier.weight(1f),
                                onTrigger = { onSendKeyTap(MacKeyCodes.RIGHT_BRACKET, MacModifiers.COMMAND, false) }
                            )
                            SimKeyCap(
                                label = "⌘⇧Z",
                                subtitle = "重做",
                                modifier = Modifier.weight(1f),
                                onTrigger = {
                                    onSendKeyTap(MacKeyCodes.Z, MacModifiers.COMMAND or MacModifiers.SHIFT, false)
                                }
                            )
                            SimKeyCap(
                                label = "⌘Q",
                                subtitle = "退出应用",
                                modifier = Modifier.weight(1f),
                                onTrigger = { onSendKeyTap(MacKeyCodes.Q, MacModifiers.COMMAND, false) }
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SimKeyCap(
    label: String,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    active: Boolean = false,
    emphasized: Boolean = false,
    repeatable: Boolean = false,
    height: androidx.compose.ui.unit.Dp = 39.dp,
    onTrigger: (isRepeat: Boolean) -> Unit
) {
    val haptic = LocalHapticFeedback.current
    val repeatScope = rememberCoroutineScope()
    val currentOnTrigger by rememberUpdatedState(onTrigger)
    var isPressed by remember { mutableStateOf(false) }

    val bgColor = when {
        active -> WsTextPrimary
        isPressed -> Color(0xFF3A3A44)
        emphasized -> WsElevatedBg
        else -> WsKeycapBg
    }
    val borderColor = when {
        active -> WsTextPrimary
        isPressed -> WsTextMuted
        emphasized -> WsPopoverBorder
        else -> Color(0xFF32323A)
    }
    val fgColor = if (active) WsBg else WsTextPrimary
    val subColor = if (active) WsBg.copy(alpha = 0.72f) else WsTextMuted

    Box(
        modifier = modifier
            .height(height)
            .clip(RoundedCornerShape(7.dp))
            .background(bgColor)
            .border(0.5.dp, borderColor, RoundedCornerShape(7.dp))
            .pointerInput(repeatable) {
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false)
                    isPressed = true
                    haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                    currentOnTrigger(false)
                    val repeatJob = if (repeatable) {
                        repeatScope.launch {
                            delay(360L)
                            while (true) {
                                currentOnTrigger(true)
                                delay(62L)
                            }
                        }
                    } else {
                        null
                    }
                    try {
                        waitForUpOrCancellation()
                    } finally {
                        repeatJob?.cancel()
                        isPressed = false
                    }
                }
            },
        contentAlignment = Alignment.Center
    ) {
        if (subtitle != null) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center
            ) {
                Text(
                    text = label,
                    fontSize = 11.5.sp,
                    lineHeight = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = fgColor,
                    maxLines = 1
                )
                Text(
                    text = subtitle,
                    fontSize = 9.sp,
                    lineHeight = 10.sp,
                    color = subColor,
                    maxLines = 1
                )
            }
        } else {
            Text(
                text = label,
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
                color = fgColor,
                maxLines = 1
            )
        }
    }
}

@Composable
private fun GestureGuideDialog(onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = WsCardBg,
        title = { Text("触控手势指南", style = MaterialTheme.typography.titleMedium, color = WsTextPrimary) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                val items = listOf(
                    "单指轻点 / 双击" to "左键单击 / 双击",
                    "长按或双击按住拖动" to "左键拖拽框选与移动窗口",
                    "双指轻点 / 一指按住+另一指轻点" to "鼠标右键菜单",
                    "双指捏合 / 双指滑动" to "1x–5x 画面缩放 / 平滑滚轮",
                    "三指轻点 / 顶部键盘键" to "直接唤起手机输入法直输文字（支持退格删除）与多行模拟按键",
                    "三指上下滑" to "展开或收起顶部窗口标签栏 / 切换全屏"
                )
                items.forEach { (gesture, desc) ->
                    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                        Text(gesture, fontSize = 13.sp, fontWeight = FontWeight.Medium, color = WsTextPrimary)
                        Text(desc, fontSize = 12.sp, color = WsTextMuted)
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text("知道了", color = WsTextPrimary, fontWeight = FontWeight.SemiBold)
            }
        }
    )
}
