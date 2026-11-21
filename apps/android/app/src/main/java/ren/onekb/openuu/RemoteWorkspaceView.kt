package ren.onekb.openuu

import android.view.SurfaceHolder
import android.view.SurfaceView
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
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
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
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.HelpOutline
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Apps
import androidx.compose.material.icons.rounded.AspectRatio
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.ContentPaste
import androidx.compose.material.icons.rounded.DesktopMac
import androidx.compose.material.icons.rounded.Keyboard
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.Mouse
import androidx.compose.material.icons.rounded.PowerSettingsNew
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Remove
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.TouchApp
import androidx.compose.material.icons.rounded.UploadFile
import androidx.compose.material.icons.rounded.ZoomOutMap
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
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
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
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
    val selectedWindowId by viewModel.selectedWindowId.collectAsState()
    val windowSwitchNotice by viewModel.windowSwitchNotice.collectAsState()
    val proactiveTabRevealTick by viewModel.proactiveTabRevealTick.collectAsState()
    val pinLandscapeTabBar by viewModel.pinLandscapeTabBar.collectAsState()
    val showAppLauncher by viewModel.showAppLauncher.collectAsState()
    val showDebugHud by viewModel.showDebugHud.collectAsState()
    val touchMode by viewModel.touchMode.collectAsState()
    val videoFitMode by viewModel.videoFitMode.collectAsState()
    val manualFullscreen by viewModel.manualFullscreen.collectAsState()
    val cursorPos by viewModel.cursorPos.collectAsState()
    val cursorKind by viewModel.cursorKind.collectAsState()
    val stickyModifiers by viewModel.stickyModifiers.collectAsState()
    val videoTelemetry by viewModel.videoTelemetry.collectAsState()

    val hostName = (connectionPhase as? ConnectionPhase.Connected)?.hostName ?: "Mac"
    var showKeyboardDock by remember { mutableStateOf(false) }
    var showSessionSheet by remember { mutableStateOf(false) }
    var showGestureGuide by remember { mutableStateOf(false) }
    var showLastWindowCloseSheet by remember { mutableStateOf(false) }
    var imeText by remember { mutableStateOf("") }
    var viewportLogicalSize by remember { mutableStateOf(Size(960f, 640f)) }

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
                    onOpenApps = { viewModel.setShowAppLauncher(!showAppLauncher || selectedWindowId == 0) },
                    onSelectWindow = { viewModel.selectRemoteWindow(it) },
                    onCloseWindow = handleCloseTab,
                    onToggleTouchMode = toggleTouch,
                    onToggleKeyboard = { showKeyboardDock = !showKeyboardDock },
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
                            showKeyboardDock = !showKeyboardDock
                            showGestureToast(if (showKeyboardDock) "三指 · 已呼出键盘栏" else "三指 · 已收起键盘栏")
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
            }

            AnimatedVisibility(
                visible = selectedWindowId != 0 && showKeyboardDock,
                enter = expandVertically(),
                exit = shrinkVertically()
            ) {
                MacKeyboardAndImeDock(
                    imeText = imeText,
                    onImeTextChange = { imeText = it },
                    onCommitImeText = {
                        if (imeText.isNotEmpty()) {
                            viewModel.sendTextCommit(imeText)
                            imeText = ""
                        }
                    },
                    stickyModifiers = stickyModifiers,
                    onToggleModifier = { viewModel.toggleStickyModifier(it) },
                    onSendKeyTap = { code, mods -> viewModel.sendKeyTap(code, mods) }
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
                onOpenApps = {
                    manualTabStripRevealed = false
                    viewModel.setShowAppLauncher(true)
                },
                onSelectWindow = { viewModel.selectRemoteWindow(it) },
                onCloseWindow = handleCloseTab,
                onToggleTouchMode = toggleTouch,
                onToggleKeyboard = { showKeyboardDock = !showKeyboardDock },
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
            // Left [应用] pill
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
    isLandscape: Boolean,
    manualFullscreen: Boolean,
    hasActiveWindow: Boolean,
    onDismiss: () -> Unit,
    onToggleFitMode: () -> Unit,
    onZoomOut: () -> Unit,
    onZoomReset: () -> Unit,
    onZoomIn: () -> Unit,
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
private fun SheetSwitchRow(label: String, checked: Boolean, onToggle: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onToggle)
            .padding(horizontal = 14.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(label, fontSize = 13.5.sp, color = WsTextPrimary)
        Switch(checked = checked, onCheckedChange = { onToggle() })
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

@Composable
private fun RemoteVideoCanvas(
    viewModel: OpenUUViewModel,
    activeWindowId: Int,
    activePopovers: List<WindowTopologyItem>,
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

        val currentZoom by rememberUpdatedState(zoom)
        val currentPan by rememberUpdatedState(pan)
        val currentBaseRect by rememberUpdatedState(baseRect)
        val currentFillScale by rememberUpdatedState(fillBaseScale)
        val currentContainerSize by rememberUpdatedState(Size(containerW, containerH))
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
            return Offset(
                ((ux - rect.left) / rect.width.coerceAtLeast(1f)).coerceIn(0f, 1f),
                ((uy - rect.top) / rect.height.coerceAtLeast(1f)).coerceIn(0f, 1f)
            )
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
        val (parentW, parentH) = viewModel.currentLogicalSize()
        val safeParentW = parentW.coerceAtLeast(1f)
        val safeParentH = parentH.coerceAtLeast(1f)

        // Main SurfaceView + Floating kind == 2 Right-Click Menu / Popover Video Overlays
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

            // Floating Popover / Context Menu SurfaceView overlays (kind == 2)
            for (pop in activePopovers) {
                if (pop.width <= 1f || pop.height <= 1f) continue
                key(pop.windowId) {
                    val popDecoder = remember(pop.windowId) { viewModel.getOrCreatePopoverDecoder(pop.windowId) }
                    DisposableEffect(pop.windowId) {
                        onDispose { popDecoder.attachSurface(null) }
                    }
                    val popLeftDp = with(density) { ((pop.relX / safeParentW) * fittedW).toDp() }
                    val popTopDp = with(density) { ((pop.relY / safeParentH) * fittedH).toDp() }
                    val popWDp = with(density) { ((pop.width / safeParentW) * fittedW).coerceAtLeast(1f).toDp() }
                    val popHDp = with(density) { ((pop.height / safeParentH) * fittedH).coerceAtLeast(1f).toDp() }
                    Box(
                        modifier = Modifier
                            .offset(x = popLeftDp, y = popTopDp)
                            .size(width = popWDp, height = popHDp)
                            .border(1.dp, WsPopoverBorder)
                    ) {
                        AndroidView(
                            modifier = Modifier.fillMaxSize(),
                            factory = { ctx ->
                                SurfaceView(ctx).apply {
                                    setZOrderMediaOverlay(true)
                                    holder.addCallback(object : SurfaceHolder.Callback {
                                        override fun surfaceCreated(holder: SurfaceHolder) = popDecoder.attachSurface(holder.surface)
                                        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) =
                                            popDecoder.attachSurface(holder.surface)
                                        override fun surfaceDestroyed(holder: SurfaceHolder) = popDecoder.attachSurface(null)
                                    })
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
                        onMove = { n -> viewModel.sendMouseNormalized(n.x, n.y, MOUSE_MOVE, BUTTON_LEFT, 0) },
                        onLeftClick = { n, clicks ->
                            viewModel.sendMouseNormalized(n.x, n.y, MOUSE_MOVE, BUTTON_LEFT, 0)
                            viewModel.sendMouseNormalized(n.x, n.y, MOUSE_DOWN, BUTTON_LEFT, clicks)
                            viewModel.sendMouseNormalized(n.x, n.y, MOUSE_UP, BUTTON_LEFT, clicks)
                        },
                        onRightClick = { n ->
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            viewModel.sendMouseNormalized(n.x, n.y, MOUSE_MOVE, BUTTON_RIGHT, 0)
                            viewModel.sendMouseNormalized(n.x, n.y, MOUSE_DOWN, BUTTON_RIGHT, 1)
                            viewModel.sendMouseNormalized(n.x, n.y, MOUSE_UP, BUTTON_RIGHT, 1)
                            onTransientToastLatest("右键点击")
                        },
                        onDragStart = { n ->
                            viewModel.sendMouseNormalized(n.x, n.y, MOUSE_MOVE, BUTTON_LEFT, 0)
                            viewModel.sendMouseNormalized(n.x, n.y, MOUSE_DOWN, BUTTON_LEFT, 1)
                        },
                        onDragMove = { n -> viewModel.sendMouseNormalized(n.x, n.y, MOUSE_DRAG, BUTTON_LEFT, 1) },
                        onDragEnd = { n -> viewModel.sendMouseNormalized(n.x, n.y, MOUSE_UP, BUTTON_LEFT, 1) },
                        onScroll = { n, dx, dy -> viewModel.sendScrollNormalized(n.x, n.y, dx, dy) },
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

private data class MacShortcutKey(val label: String, val keyCode: Int, val explicitModifiers: Int? = null)

private val MacShortcutKeys = listOf(
    MacShortcutKey("Esc", MacKeyCodes.ESCAPE),
    MacShortcutKey("Tab", MacKeyCodes.TAB),
    MacShortcutKey("Space", MacKeyCodes.SPACE),
    MacShortcutKey("⌫", MacKeyCodes.DELETE),
    MacShortcutKey("⏎", MacKeyCodes.RETURN),
    MacShortcutKey("←", MacKeyCodes.LEFT),
    MacShortcutKey("↑", MacKeyCodes.UP),
    MacShortcutKey("↓", MacKeyCodes.DOWN),
    MacShortcutKey("→", MacKeyCodes.RIGHT),
    MacShortcutKey("⌘C", MacKeyCodes.C, MacModifiers.COMMAND),
    MacShortcutKey("⌘V", MacKeyCodes.V, MacModifiers.COMMAND),
    MacShortcutKey("⌘W", MacKeyCodes.W, MacModifiers.COMMAND),
    MacShortcutKey("⌘Space", MacKeyCodes.SPACE, MacModifiers.COMMAND),
    MacShortcutKey("⌘Z", MacKeyCodes.Z, MacModifiers.COMMAND),
    MacShortcutKey("⌘A", MacKeyCodes.A, MacModifiers.COMMAND)
)

@Composable
private fun MacKeyboardAndImeDock(
    imeText: String,
    onImeTextChange: (String) -> Unit,
    onCommitImeText: () -> Unit,
    stickyModifiers: Int,
    onToggleModifier: (Int) -> Unit,
    onSendKeyTap: (Int, Int?) -> Unit
) {
    Column(modifier = Modifier.fillMaxWidth().background(WsBarBg)) {
        HorizontalDivider(thickness = 0.5.dp, color = WsDivider)
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                OutlinedTextField(
                    value = imeText,
                    onValueChange = onImeTextChange,
                    placeholder = { Text("输入中英文并发送至 Mac...", style = MaterialTheme.typography.bodySmall, color = WsTextMuted) },
                    singleLine = true,
                    shape = RoundedCornerShape(9.dp),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                    keyboardActions = KeyboardActions(onSend = { onCommitImeText() }),
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
                Button(
                    onClick = onCommitImeText,
                    enabled = imeText.isNotEmpty(),
                    shape = RoundedCornerShape(9.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = WsTextPrimary,
                        contentColor = WsBg,
                        disabledContainerColor = WsKeycapBg,
                        disabledContentColor = WsTextMuted
                    ),
                    contentPadding = PaddingValues(horizontal = 13.dp, vertical = 12.dp)
                ) {
                    Icon(Icons.AutoMirrored.Rounded.Send, contentDescription = "发送文本", modifier = Modifier.size(17.dp))
                }
            }

            LazyRow(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                val mods = listOf("⌘" to MacModifiers.COMMAND, "⌥" to MacModifiers.OPTION, "⌃" to MacModifiers.CONTROL, "⇧" to MacModifiers.SHIFT)
                items(mods, key = { it.second }) { (symbol, bit) ->
                    KeyCapChip(label = symbol, active = (stickyModifiers and bit) != 0, onClick = { onToggleModifier(bit) })
                }
                items(MacShortcutKeys, key = { it.label }) { item ->
                    KeyCapChip(label = item.label, active = false, onClick = { onSendKeyTap(item.keyCode, item.explicitModifiers) })
                }
            }
        }
    }
}

@Composable
private fun KeyCapChip(label: String, active: Boolean, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        color = if (active) WsTextPrimary else WsKeycapBg,
        shape = RoundedCornerShape(7.dp),
        border = BorderStroke(0.5.dp, if (active) WsTextPrimary else Color(0xFF32323A))
    ) {
        Text(
            text = label,
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            color = if (active) WsBg else WsTextPrimary,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp)
        )
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
                    "三指轻点 / 三指上下滑" to "呼出键盘栏 / 展开或收起顶部栏"
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
