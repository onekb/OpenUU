package ren.onekb.openuu

import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
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
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
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
import androidx.compose.material.icons.automirrored.rounded.HelpOutline
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Apps
import androidx.compose.material.icons.rounded.AspectRatio
import androidx.compose.material.icons.rounded.BugReport
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.ContentPaste
import androidx.compose.material.icons.rounded.CropFree
import androidx.compose.material.icons.rounded.DesktopMac
import androidx.compose.material.icons.rounded.FitScreen
import androidx.compose.material.icons.rounded.Fullscreen
import androidx.compose.material.icons.rounded.FullscreenExit
import androidx.compose.material.icons.rounded.Keyboard
import androidx.compose.material.icons.rounded.KeyboardHide
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.Mouse
import androidx.compose.material.icons.rounded.PowerSettingsNew
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Remove
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.TouchApp
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material.icons.rounded.UploadFile
import androidx.compose.material.icons.rounded.ViewAgenda
import androidx.compose.material.icons.rounded.ZoomOutMap
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
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
import androidx.compose.ui.unit.IntOffset
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

private enum class GestureSubMode {
    PENDING_SINGLE,
    REMOTE_DRAG,
    VIEWPORT_PAN,
    TRACKPAD_MOVE,
    TWO_FINGER_PENDING,
    TWO_FINGER_PINCH,
    TWO_FINGER_SCROLL,
    THREE_FINGER,
    CONSUMED_WAIT_UP
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
    val remoteApps by viewModel.remoteApps.collectAsState()
    val appIcons by viewModel.appIcons.collectAsState()
    val remoteWindows by viewModel.remoteWindows.collectAsState()
    val selectedWindowId by viewModel.selectedWindowId.collectAsState()
    val showAppLauncher by viewModel.showAppLauncher.collectAsState()
    val showDebugHud by viewModel.showDebugHud.collectAsState()
    val touchMode by viewModel.touchMode.collectAsState()
    val videoFitMode by viewModel.videoFitMode.collectAsState()
    val manualFullscreen by viewModel.manualFullscreen.collectAsState()
    val cursorPos by viewModel.cursorPos.collectAsState()
    val cursorKind by viewModel.cursorKind.collectAsState()
    val stickyModifiers by viewModel.stickyModifiers.collectAsState()
    val videoTelemetry by viewModel.videoTelemetry.collectAsState()

    if (!connectionPhase.isConnected) {
        DisconnectedRemotePlaceholder(
            connectionPhase = connectionPhase,
            onGoConnect = { viewModel.selectTab(MainTab.CONNECT) },
            modifier = modifier
        )
        return
    }

    val hostName = (connectionPhase as? ConnectionPhase.Connected)?.hostName ?: "Mac"
    var showKeyboardDock by remember { mutableStateOf(false) }
    var showGestureGuide by remember { mutableStateOf(false) }
    var imeText by remember { mutableStateOf("") }
    var viewportLogicalSize by remember { mutableStateOf(Size(960f, 640f)) }

    // Hoisted zoom/pan per active window so Floating HUD controls & gestures stay in sync
    var zoom by remember(selectedWindowId) { mutableFloatStateOf(1f) }
    var pan by remember(selectedWindowId) { mutableStateOf(Offset.Zero) }

    // Auto-collapse floating overlay HUD whenever entering/exiting immersive fullscreen
    var expandedFloatingBar by remember(isImmersiveFullscreen) { mutableStateOf(false) }
    var showFullToolbarOverlay by remember(isImmersiveFullscreen) { mutableStateOf(false) }

    // Transient toast badge for gesture actions
    var transientToast by remember { mutableStateOf<String?>(null) }
    var transientToastSeq by remember { mutableLongStateOf(0L) }

    fun showGestureToast(message: String) {
        transientToast = message
        transientToastSeq++
    }

    LaunchedEffect(transientToastSeq) {
        if (transientToast != null) {
            delay(1300L)
            transientToast = null
        }
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(if (isImmersiveFullscreen) Color.Black else MaterialTheme.colorScheme.background)
    ) {
        // Keep RemoteVideoCanvas in the exact same Column slot across orientation/fullscreen
        // changes so SurfaceView & hardware MediaCodec decoder never re-initialize on rotation!
        Column(modifier = Modifier.fillMaxSize()) {
            // 1. Portrait Top Status & Quick Action Bar (auto-collapsed in immersive fullscreen)
            if (!isImmersiveFullscreen) {
                RemoteTopToolbar(
                    hostName = hostName,
                    linkBadge = linkBadge,
                    showAppLauncher = showAppLauncher,
                    showDebugHud = showDebugHud,
                    showKeyboardDock = showKeyboardDock,
                    touchMode = touchMode,
                    videoFitMode = videoFitMode,
                    hasActiveWindow = selectedWindowId != 0,
                    onToggleLauncher = { viewModel.setShowAppLauncher(!showAppLauncher) },
                    onEnterFullscreen = { viewModel.setManualFullscreen(true) },
                    onToggleFitMode = {
                        viewModel.toggleVideoFitMode()
                        if (zoom <= 1.01f) pan = Offset.Zero
                    },
                    onOpenGestureGuide = { showGestureGuide = true },
                    onCloseActiveWindow = {
                        if (selectedWindowId != 0) {
                            viewModel.sendKeyTap(MacKeyCodes.W, MacModifiers.COMMAND)
                            viewModel.stopRemoteWindow(selectedWindowId)
                        }
                    },
                    onRefreshKeyframe = { viewModel.requestKeyframeNow() },
                    onResizeToViewport = {
                        if (selectedWindowId != 0) {
                            val w = viewportLogicalSize.width.coerceIn(480f, 1920f)
                            val h = viewportLogicalSize.height.coerceIn(360f, 1440f)
                            viewModel.resizeActiveWindow(w, h)
                        }
                    },
                    onToggleDebugHud = { viewModel.toggleDebugHud() },
                    onToggleTouchMode = {
                        val next = if (touchMode == TouchMode.DIRECT_TOUCH) {
                            TouchMode.TRACKPAD
                        } else {
                            TouchMode.DIRECT_TOUCH
                        }
                        viewModel.setTouchMode(next)
                    },
                    onPickFile = onPickFile,
                    onPushClipboard = { viewModel.pushLocalClipboardToHost(silent = false) },
                    onToggleKeyboard = { showKeyboardDock = !showKeyboardDock },
                    onDisconnect = { viewModel.disconnect() }
                )

                // 2. Multi-Window Topology Switcher Chips
                if (remoteWindows.isNotEmpty()) {
                    WindowTopologyStrip(
                        windows = remoteWindows,
                        selectedWindowId = if (showAppLauncher) 0 else selectedWindowId,
                        onSelectWindow = { viewModel.selectRemoteWindow(it) },
                        onStopWindow = { viewModel.stopRemoteWindow(it) }
                    )
                }
            }

            // 3. Main Workspace Area: App Launcher OR Hardware Video Stream Surface
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
            ) {
                if (showAppLauncher || selectedWindowId == 0) {
                    RemoteAppLauncherGrid(
                        apps = remoteApps,
                        appIcons = appIcons,
                        onRefreshApps = { viewModel.refreshRemoteApps() },
                        onOpenFullDesktop = { viewModel.openFullDesktop() },
                        onOpenApp = { app -> viewModel.openRemoteApp(app.bundleId, app.name) }
                    )
                } else {
                    RemoteVideoCanvas(
                        viewModel = viewModel,
                        activeWindowId = selectedWindowId,
                        touchMode = touchMode,
                        videoFitMode = videoFitMode,
                        zoom = zoom,
                        pan = pan,
                        onZoomPanChanged = { newZoom, newPan ->
                            zoom = newZoom
                            pan = newPan
                        },
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
                            if (isImmersiveFullscreen) {
                                expandedFloatingBar = !expandedFloatingBar
                                showGestureToast(if (expandedFloatingBar) "三指 · 已展开控制栏" else "三指 · 已收起控制栏")
                            } else {
                                viewModel.toggleManualFullscreen()
                                showGestureToast("三指 · 切换全屏")
                            }
                        },
                        onViewportLogicalSizeChanged = { viewportLogicalSize = it }
                    )
                }
            }

            // 4. Native Chinese/English IME Input + Collapsible Mac Shortcuts Dock
            AnimatedVisibility(
                visible = !showAppLauncher && selectedWindowId != 0 && showKeyboardDock,
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
                    onSendKeyTap = { code, explicitMods -> viewModel.sendKeyTap(code, explicitMods) }
                )
            }
        }

        // 5. Immersive Fullscreen Floating HUD + Draggable Floating Control Pill
        if (isImmersiveFullscreen) {
            // Optional full portrait-style toolbar overlay if user explicitly toggles it in landscape
            AnimatedVisibility(
                visible = showFullToolbarOverlay,
                enter = slideInVertically { -it } + fadeIn(),
                exit = slideOutVertically { -it } + fadeOut(),
                modifier = Modifier.align(Alignment.TopCenter)
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(Color(0xE60B1120))
                ) {
                    RemoteTopToolbar(
                        hostName = hostName,
                        linkBadge = linkBadge,
                        showAppLauncher = showAppLauncher,
                        showDebugHud = showDebugHud,
                        showKeyboardDock = showKeyboardDock,
                        touchMode = touchMode,
                        videoFitMode = videoFitMode,
                        hasActiveWindow = selectedWindowId != 0,
                        isFullscreenOverlay = true,
                        onToggleLauncher = {
                            showFullToolbarOverlay = false
                            viewModel.setShowAppLauncher(true)
                        },
                        onEnterFullscreen = { showFullToolbarOverlay = false },
                        onToggleFitMode = {
                            viewModel.toggleVideoFitMode()
                            if (zoom <= 1.01f) pan = Offset.Zero
                        },
                        onOpenGestureGuide = { showGestureGuide = true },
                        onCloseActiveWindow = {
                            if (selectedWindowId != 0) {
                                viewModel.sendKeyTap(MacKeyCodes.W, MacModifiers.COMMAND)
                                viewModel.stopRemoteWindow(selectedWindowId)
                            }
                        },
                        onRefreshKeyframe = { viewModel.requestKeyframeNow() },
                        onResizeToViewport = {
                            if (selectedWindowId != 0) {
                                val w = viewportLogicalSize.width.coerceIn(480f, 1920f)
                                val h = viewportLogicalSize.height.coerceIn(360f, 1440f)
                                viewModel.resizeActiveWindow(w, h)
                            }
                        },
                        onToggleDebugHud = { viewModel.toggleDebugHud() },
                        onToggleTouchMode = {
                            val next = if (touchMode == TouchMode.DIRECT_TOUCH) {
                                TouchMode.TRACKPAD
                            } else {
                                TouchMode.DIRECT_TOUCH
                            }
                            viewModel.setTouchMode(next)
                        },
                        onPickFile = onPickFile,
                        onPushClipboard = { viewModel.pushLocalClipboardToHost(silent = false) },
                        onToggleKeyboard = { showKeyboardDock = !showKeyboardDock },
                        onDisconnect = { viewModel.disconnect() }
                    )
                    if (remoteWindows.isNotEmpty()) {
                        WindowTopologyStrip(
                            windows = remoteWindows,
                            selectedWindowId = selectedWindowId,
                            onSelectWindow = { viewModel.selectRemoteWindow(it) },
                            onStopWindow = { viewModel.stopRemoteWindow(it) }
                        )
                    }
                }
            }

            // Compact Translucent Floating HUD Bar (expanded via Floating Ball or 3-finger swipe)
            AnimatedVisibility(
                visible = expandedFloatingBar && !showFullToolbarOverlay,
                enter = slideInVertically { -it } + fadeIn(),
                exit = slideOutVertically { -it } + fadeOut(),
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .padding(horizontal = 12.dp, vertical = 10.dp)
            ) {
                ImmersiveFloatingHudBar(
                    windows = remoteWindows,
                    selectedWindowId = selectedWindowId,
                    touchMode = touchMode,
                    videoFitMode = videoFitMode,
                    zoom = zoom,
                    showKeyboardDock = showKeyboardDock,
                    showDebugHud = showDebugHud,
                    isLandscape = isLandscape,
                    manualFullscreen = manualFullscreen,
                    onSelectWindow = { viewModel.selectRemoteWindow(it) },
                    onOpenAppLauncher = {
                        expandedFloatingBar = false
                        viewModel.setShowAppLauncher(true)
                    },
                    onToggleTouchMode = {
                        val next = if (touchMode == TouchMode.DIRECT_TOUCH) {
                            TouchMode.TRACKPAD
                        } else {
                            TouchMode.DIRECT_TOUCH
                        }
                        viewModel.setTouchMode(next)
                        showGestureToast("已切换至 ${next.label} 模式")
                    },
                    onToggleFitMode = {
                        viewModel.toggleVideoFitMode()
                        if (zoom <= 1.01f) pan = Offset.Zero
                        val nextLabel = if (videoFitMode == VideoFitMode.FIT) VideoFitMode.FILL.label else VideoFitMode.FIT.label
                        showGestureToast("画面比例: $nextLabel")
                    },
                    onZoomOut = {
                        val next = (zoom - 0.5f).coerceIn(MIN_ZOOM, MAX_ZOOM)
                        zoom = next
                        if (next <= 1.01f) pan = Offset.Zero
                    },
                    onZoomReset = {
                        zoom = 1f
                        pan = Offset.Zero
                    },
                    onZoomIn = {
                        zoom = (zoom + 0.5f).coerceIn(MIN_ZOOM, MAX_ZOOM)
                    },
                    onToggleKeyboard = { showKeyboardDock = !showKeyboardDock },
                    onToggleDebugHud = { viewModel.toggleDebugHud() },
                    onPickFile = onPickFile,
                    onPushClipboard = { viewModel.pushLocalClipboardToHost(silent = false) },
                    onOpenGestureGuide = { showGestureGuide = true },
                    onToggleFullToolbar = {
                        expandedFloatingBar = false
                        showFullToolbarOverlay = !showFullToolbarOverlay
                    },
                    onExitFullscreen = {
                        expandedFloatingBar = false
                        if (!isLandscape && manualFullscreen) {
                            viewModel.setManualFullscreen(false)
                        } else {
                            viewModel.setManualFullscreen(false)
                            viewModel.setShowAppLauncher(true)
                        }
                    },
                    onCollapse = { expandedFloatingBar = false }
                )
            }

            // Draggable Semi-Transparent Floating Quick-Control Pill
            DraggableFloatingControlPill(
                expanded = expandedFloatingBar || showFullToolbarOverlay,
                touchMode = touchMode,
                onClick = {
                    if (showFullToolbarOverlay) {
                        showFullToolbarOverlay = false
                    } else {
                        expandedFloatingBar = !expandedFloatingBar
                    }
                }
            )
        }
    }

    if (showGestureGuide) {
        GestureGuideDialog(onDismiss = { showGestureGuide = false })
    }
}

@Composable
private fun DraggableFloatingControlPill(
    expanded: Boolean,
    touchMode: TouchMode,
    onClick: () -> Unit
) {
    val density = LocalDensity.current
    var lastInteractionMs by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var isIdle by remember { mutableStateOf(false) }

    LaunchedEffect(lastInteractionMs, expanded) {
        if (expanded) {
            isIdle = false
        } else {
            isIdle = false
            delay(2800L)
            isIdle = true
        }
    }

    val pillAlpha by animateFloatAsState(
        targetValue = if (expanded || !isIdle) 0.94f else 0.55f,
        animationSpec = tween(durationMillis = 320),
        label = "floatingPillAlpha"
    )

    val onClickLatest by rememberUpdatedState(onClick)

    BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
        val containerW = constraints.maxWidth.toFloat().coerceAtLeast(1f)
        val containerH = constraints.maxHeight.toFloat().coerceAtLeast(1f)
        val pillW = with(density) { 82.dp.toPx() }
        val pillH = with(density) { 36.dp.toPx() }
        val edgeMargin = with(density) { 12.dp.toPx() }

        var offsetPx by remember(containerW, containerH) {
            mutableStateOf(
                Offset(
                    x = (containerW - pillW - edgeMargin).coerceAtLeast(edgeMargin),
                    y = edgeMargin
                )
            )
        }

        fun clampOffset(raw: Offset): Offset {
            val maxX = (containerW - pillW - edgeMargin).coerceAtLeast(edgeMargin)
            val maxY = (containerH - pillH - edgeMargin).coerceAtLeast(edgeMargin)
            return Offset(
                x = raw.x.coerceIn(edgeMargin, maxX),
                y = raw.y.coerceIn(edgeMargin, maxY)
            )
        }

        Surface(
            color = if (expanded) Color(0xEE064E3B) else Color(0xCC0F172A),
            shape = RoundedCornerShape(999.dp),
            border = BorderStroke(
                1.dp,
                if (expanded) Color(0xFF34D399) else Color(0x88334155)
            ),
            shadowElevation = 6.dp,
            modifier = Modifier
                .offset { IntOffset(offsetPx.x.roundToInt(), offsetPx.y.roundToInt()) }
                .alpha(pillAlpha)
                .pointerInput(containerW, containerH) {
                    val slop = viewConfiguration.touchSlop
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false)
                        lastInteractionMs = System.currentTimeMillis()
                        var dragged = false
                        var totalDrag = 0f
                        var prevPos = down.position
                        while (true) {
                            val evt = awaitPointerEvent()
                            val active = evt.changes.firstOrNull { it.id == down.id }
                            if (active == null || !active.pressed) {
                                if (!dragged) {
                                    onClickLatest()
                                }
                                lastInteractionMs = System.currentTimeMillis()
                                break
                            }
                            val delta = active.position - prevPos
                            prevPos = active.position
                            totalDrag += hypot(delta.x.toDouble(), delta.y.toDouble()).toFloat()
                            if (totalDrag > slop) {
                                dragged = true
                            }
                            if (dragged && delta != Offset.Zero) {
                                offsetPx = clampOffset(offsetPx + delta)
                                active.consume()
                            }
                        }
                    }
                }
        ) {
            Row(
                modifier = Modifier.padding(horizontal = 11.dp, vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp)
            ) {
                Box(
                    modifier = Modifier
                        .size(7.dp)
                        .clip(CircleShape)
                        .background(Color(0xFF10B981))
                )
                Icon(
                    imageVector = if (expanded) Icons.Rounded.Close else Icons.Rounded.Tune,
                    contentDescription = "悬浮控制菜单",
                    tint = Color(0xFFF1F5F9),
                    modifier = Modifier.size(16.dp)
                )
                Text(
                    text = if (expanded) "收起" else touchMode.label,
                    style = MaterialTheme.typography.labelSmall,
                    color = Color(0xFFF1F5F9),
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1
                )
            }
        }
    }
}

@Composable
private fun ImmersiveFloatingHudBar(
    windows: List<WindowTopologyItem>,
    selectedWindowId: Int,
    touchMode: TouchMode,
    videoFitMode: VideoFitMode,
    zoom: Float,
    showKeyboardDock: Boolean,
    showDebugHud: Boolean,
    isLandscape: Boolean,
    manualFullscreen: Boolean,
    onSelectWindow: (Int) -> Unit,
    onOpenAppLauncher: () -> Unit,
    onToggleTouchMode: () -> Unit,
    onToggleFitMode: () -> Unit,
    onZoomOut: () -> Unit,
    onZoomReset: () -> Unit,
    onZoomIn: () -> Unit,
    onToggleKeyboard: () -> Unit,
    onToggleDebugHud: () -> Unit,
    onPickFile: () -> Unit,
    onPushClipboard: () -> Unit,
    onOpenGestureGuide: () -> Unit,
    onToggleFullToolbar: () -> Unit,
    onExitFullscreen: () -> Unit,
    onCollapse: () -> Unit
) {
    Surface(
        color = Color(0xDE0B1120),
        shape = RoundedCornerShape(16.dp),
        border = BorderStroke(1.dp, Color(0x6610B981)),
        shadowElevation = 10.dp,
        modifier = Modifier.fillMaxWidth(0.96f)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 10.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            // Row 1: Multi-window switcher pills + "+ 应用台" + Collapse
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                LazyRow(
                    modifier = Modifier.weight(1f),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    items(windows, key = { it.windowId }) { win ->
                        val active = win.windowId == selectedWindowId
                        val title = when {
                            win.windowId == OpenUUConstants.FULL_DESKTOP_WINDOW_ID -> "整台桌面"
                            win.title.isNotBlank() -> win.title
                            else -> "窗口 #${win.unsignedWindowId}"
                        }
                        HudCompactPill(
                            label = title,
                            active = active,
                            onClick = { onSelectWindow(win.windowId) }
                        )
                    }
                    item(key = "open_launcher") {
                        HudCompactPill(
                            icon = Icons.Rounded.Add,
                            label = "应用台",
                            accent = true,
                            onClick = onOpenAppLauncher
                        )
                    }
                }
                IconButton(
                    onClick = onCollapse,
                    modifier = Modifier.size(28.dp)
                ) {
                    Icon(
                        imageVector = Icons.Rounded.Close,
                        contentDescription = "收起悬浮栏",
                        tint = Color(0xFFCBD5E1),
                        modifier = Modifier.size(16.dp)
                    )
                }
            }

            // Row 2: Quick controls (TouchMode, Fit/Fill, Zoom -/100%/+, Keyboard, Guide, Exit)
            LazyRow(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                item {
                    HudCompactPill(
                        icon = if (touchMode == TouchMode.DIRECT_TOUCH) Icons.Rounded.TouchApp else Icons.Rounded.Mouse,
                        label = touchMode.label,
                        active = touchMode == TouchMode.TRACKPAD,
                        onClick = onToggleTouchMode
                    )
                }
                item {
                    HudCompactPill(
                        icon = if (videoFitMode == VideoFitMode.FILL) Icons.Rounded.CropFree else Icons.Rounded.FitScreen,
                        label = videoFitMode.label,
                        active = videoFitMode == VideoFitMode.FILL,
                        onClick = onToggleFitMode
                    )
                }
                // Zoom stepper: - | 100% | +
                item {
                    Surface(
                        color = Color(0xFF162033),
                        shape = RoundedCornerShape(10.dp),
                        border = BorderStroke(1.dp, Color(0xFF334155))
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.padding(horizontal = 2.dp)
                        ) {
                            IconButton(
                                onClick = onZoomOut,
                                enabled = zoom > MIN_ZOOM + 0.01f,
                                modifier = Modifier.size(28.dp)
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.Remove,
                                    contentDescription = "缩小",
                                    tint = if (zoom > MIN_ZOOM + 0.01f) Color(0xFFF1F5F9) else Color(0xFF475569),
                                    modifier = Modifier.size(14.dp)
                                )
                            }
                            Text(
                                text = "${(zoom * 100f).roundToInt()}%",
                                style = MaterialTheme.typography.labelSmall,
                                fontFamily = FontFamily.Monospace,
                                color = if (zoom > 1.01f) Color(0xFF34D399) else Color(0xFFE2E8F0),
                                modifier = Modifier
                                    .clip(RoundedCornerShape(6.dp))
                                    .clickable(onClick = onZoomReset)
                                    .padding(horizontal = 6.dp, vertical = 4.dp)
                            )
                            IconButton(
                                onClick = onZoomIn,
                                enabled = zoom < MAX_ZOOM - 0.01f,
                                modifier = Modifier.size(28.dp)
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.Add,
                                    contentDescription = "放大",
                                    tint = if (zoom < MAX_ZOOM - 0.01f) Color(0xFFF1F5F9) else Color(0xFF475569),
                                    modifier = Modifier.size(14.dp)
                                )
                            }
                        }
                    }
                }
                item {
                    HudCompactPill(
                        icon = if (showKeyboardDock) Icons.Rounded.KeyboardHide else Icons.Rounded.Keyboard,
                        label = "键盘",
                        active = showKeyboardDock,
                        onClick = onToggleKeyboard
                    )
                }
                item {
                    HudCompactPill(
                        icon = Icons.AutoMirrored.Rounded.HelpOutline,
                        label = "手势",
                        onClick = onOpenGestureGuide
                    )
                }
                item {
                    HudCompactPill(
                        icon = Icons.Rounded.UploadFile,
                        label = "传文件",
                        onClick = onPickFile
                    )
                }
                item {
                    HudCompactPill(
                        icon = Icons.Rounded.ContentPaste,
                        label = "剪贴板",
                        onClick = onPushClipboard
                    )
                }
                item {
                    HudCompactPill(
                        icon = Icons.Rounded.BugReport,
                        label = "HUD",
                        active = showDebugHud,
                        onClick = onToggleDebugHud
                    )
                }
                if (isLandscape) {
                    item {
                        HudCompactPill(
                            icon = Icons.Rounded.ViewAgenda,
                            label = "完整栏",
                            onClick = onToggleFullToolbar
                        )
                    }
                }
                item {
                    HudCompactPill(
                        icon = Icons.Rounded.FullscreenExit,
                        label = if (!isLandscape && manualFullscreen) "退出全屏" else "返回应用台",
                        danger = true,
                        onClick = onExitFullscreen
                    )
                }
            }
        }
    }
}

@Composable
private fun HudCompactPill(
    label: String,
    icon: ImageVector? = null,
    active: Boolean = false,
    accent: Boolean = false,
    danger: Boolean = false,
    onClick: () -> Unit
) {
    val bg = when {
        danger -> Color(0x55881337)
        active -> Color(0xFF065F46)
        accent -> Color(0xFF312E81)
        else -> Color(0xFF162033)
    }
    val border = when {
        danger -> Color(0xFFF43F5E).copy(alpha = 0.65f)
        active -> Color(0xFF34D399)
        accent -> Color(0xFF818CF8)
        else -> Color(0xFF334155)
    }
    val fg = when {
        danger -> Color(0xFFFFCDD2)
        active -> Color(0xFFA7F3D0)
        accent -> Color(0xFFE0E7FF)
        else -> Color(0xFFE2E8F0)
    }
    Surface(
        onClick = onClick,
        color = bg,
        shape = RoundedCornerShape(10.dp),
        border = BorderStroke(1.dp, border)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 9.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            if (icon != null) {
                Icon(
                    imageVector = icon,
                    contentDescription = label,
                    tint = fg,
                    modifier = Modifier.size(14.dp)
                )
            }
            Text(
                text = label,
                style = MaterialTheme.typography.labelSmall,
                color = fg,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}

@Composable
private fun GestureGuideDialog(onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
        title = {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Icon(
                    imageVector = Icons.AutoMirrored.Rounded.HelpOutline,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary
                )
                Text(
                    text = "远控手势操作指南",
                    style = MaterialTheme.typography.titleMedium
                )
            }
        },
        text = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                GestureSectionHeader("单指手势")
                GestureGuideItem("单指轻点", "左键单击")
                GestureGuideItem("单指双击", "左键双击")
                GestureGuideItem("长按 (0.3s) 后移动", "左键拖拽（直触 / 触控板及放大状态下均支持）")
                GestureGuideItem("长按 (0.42s) 不动后抬起", "触发鼠标右键菜单")
                GestureGuideItem("双击按住并拖动", "快速左键拖拽（macOS / Jump 风格）")
                GestureGuideItem("直触放大后单指滑动", "平滑浏览放大画布，避免误拖窗口")
                GestureGuideItem("触控板边缘移动", "放大时指针移近屏幕边缘自动平移视口")

                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)

                GestureSectionHeader("双指手势（直触 & 触控板通用）")
                GestureGuideItem("双指轻点 / 按住一指轻点第二指", "鼠标右键点击")
                GestureGuideItem("双指捏合 / 张开", "无级缩放画面（1.0x – 5.0x）")
                GestureGuideItem("双指平行滑动", "Mac 平滑滚轮滚动")

                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)

                GestureSectionHeader("三指手势 & 沉浸全屏")
                GestureGuideItem("三指轻点", "呼出 / 收起中英文输入法与 Mac 快捷键栏")
                GestureGuideItem("三指上下滑动", "展开 / 收起全屏悬浮控制栏")
                GestureGuideItem("横屏自动全屏", "旋转手机至横屏自动隐藏状态栏与导航栏，拖动悬浮胶囊随时切换窗口与比例")
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text("知道了")
            }
        }
    )
}

@Composable
private fun GestureSectionHeader(title: String) {
    Text(
        text = title,
        style = MaterialTheme.typography.labelMedium,
        fontWeight = FontWeight.Bold,
        color = MaterialTheme.colorScheme.primary
    )
}

@Composable
private fun GestureGuideItem(gesture: String, action: String) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(
            text = gesture,
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface
        )
        Text(
            text = action,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
private fun DisconnectedRemotePlaceholder(
    connectionPhase: ConnectionPhase,
    onGoConnect: () -> Unit,
    modifier: Modifier = Modifier
) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .padding(24.dp),
        contentAlignment = Alignment.Center
    ) {
        Card(
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
            shape = RoundedCornerShape(20.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(28.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Box(
                    modifier = Modifier
                        .size(64.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.primaryContainer),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        imageVector = Icons.Rounded.DesktopMac,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(34.dp)
                    )
                }
                Text(
                    text = if (connectionPhase.isConnecting) "正在连接远程 Mac..." else "尚未连接 Mac 主机",
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Text(
                    text = when (connectionPhase) {
                        is ConnectionPhase.Connecting -> connectionPhase.detail
                        is ConnectionPhase.Error -> "连接失败: ${connectionPhase.reason}"
                        else -> "前往「连接」或「设备簿」页面，使用 9 位设备码、连接串或局域网发现快速连接。"
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center
                )
                Spacer(modifier = Modifier.height(4.dp))
                Button(
                    onClick = onGoConnect,
                    shape = RoundedCornerShape(12.dp)
                ) {
                    Icon(Icons.Rounded.Link, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(modifier = Modifier.width(6.dp))
                    Text("去连接 Mac")
                }
            }
        }
    }
}

@Composable
private fun RemoteTopToolbar(
    hostName: String,
    linkBadge: String,
    showAppLauncher: Boolean,
    showDebugHud: Boolean,
    showKeyboardDock: Boolean,
    touchMode: TouchMode,
    videoFitMode: VideoFitMode,
    hasActiveWindow: Boolean,
    isFullscreenOverlay: Boolean = false,
    onToggleLauncher: () -> Unit,
    onEnterFullscreen: () -> Unit,
    onToggleFitMode: () -> Unit,
    onOpenGestureGuide: () -> Unit,
    onCloseActiveWindow: () -> Unit,
    onRefreshKeyframe: () -> Unit,
    onResizeToViewport: () -> Unit,
    onToggleDebugHud: () -> Unit,
    onToggleTouchMode: () -> Unit,
    onPickFile: () -> Unit,
    onPushClipboard: () -> Unit,
    onToggleKeyboard: () -> Unit,
    onDisconnect: () -> Unit
) {
    Surface(
        color = if (isFullscreenOverlay) Color.Transparent else MaterialTheme.colorScheme.surface,
        tonalElevation = if (isFullscreenOverlay) 0.dp else 2.dp
    ) {
        Column(modifier = Modifier.fillMaxWidth()) {
            // Row 1: Host status + Quick Fullscreen + Gesture Guide + Disconnect
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.weight(1f)
                ) {
                    Box(
                        modifier = Modifier
                            .size(8.dp)
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.primary)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = hostName,
                        style = MaterialTheme.typography.titleSmall,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    if (linkBadge.isNotBlank()) {
                        Spacer(modifier = Modifier.width(8.dp))
                        Surface(
                            color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.7f),
                            shape = RoundedCornerShape(6.dp)
                        ) {
                            Text(
                                text = linkBadge,
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onPrimaryContainer,
                                modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                            )
                        }
                    }
                }

                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(2.dp)
                ) {
                    if (hasActiveWindow && !showAppLauncher) {
                        IconButton(
                            onClick = onEnterFullscreen,
                            modifier = Modifier.size(32.dp)
                        ) {
                            Icon(
                                imageVector = if (isFullscreenOverlay) Icons.Rounded.FullscreenExit else Icons.Rounded.Fullscreen,
                                contentDescription = if (isFullscreenOverlay) "收起工具栏" else "全屏",
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(19.dp)
                            )
                        }
                    }
                    IconButton(
                        onClick = onOpenGestureGuide,
                        modifier = Modifier.size(32.dp)
                    ) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Rounded.HelpOutline,
                            contentDescription = "手势指南",
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(18.dp)
                        )
                    }
                    IconButton(
                        onClick = onDisconnect,
                        modifier = Modifier.size(32.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.PowerSettingsNew,
                            contentDescription = "断开连接",
                            tint = MaterialTheme.colorScheme.error,
                            modifier = Modifier.size(18.dp)
                        )
                    }
                }
            }

            // Row 2: Compact scrollable remote action strip
            LazyRow(
                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                item {
                    ToolbarPillButton(
                        icon = Icons.Rounded.Apps,
                        label = if (showAppLauncher) "返回画面" else "应用列表",
                        active = showAppLauncher,
                        onClick = onToggleLauncher
                    )
                }
                item {
                    ToolbarPillButton(
                        icon = if (touchMode == TouchMode.DIRECT_TOUCH) Icons.Rounded.TouchApp else Icons.Rounded.Mouse,
                        label = touchMode.label,
                        active = touchMode == TouchMode.TRACKPAD,
                        onClick = onToggleTouchMode
                    )
                }
                item {
                    ToolbarPillButton(
                        icon = if (isFullscreenOverlay) Icons.Rounded.FullscreenExit else Icons.Rounded.Fullscreen,
                        label = if (isFullscreenOverlay) "收起栏" else "全屏",
                        enabled = hasActiveWindow && !showAppLauncher,
                        onClick = onEnterFullscreen
                    )
                }
                item {
                    ToolbarPillButton(
                        icon = if (videoFitMode == VideoFitMode.FILL) Icons.Rounded.CropFree else Icons.Rounded.FitScreen,
                        label = videoFitMode.label,
                        active = videoFitMode == VideoFitMode.FILL,
                        enabled = hasActiveWindow && !showAppLauncher,
                        onClick = onToggleFitMode
                    )
                }
                item {
                    ToolbarPillButton(
                        icon = if (showKeyboardDock) Icons.Rounded.KeyboardHide else Icons.Rounded.Keyboard,
                        label = "键盘",
                        active = showKeyboardDock,
                        enabled = hasActiveWindow && !showAppLauncher,
                        onClick = onToggleKeyboard
                    )
                }
                item {
                    ToolbarPillButton(
                        icon = Icons.AutoMirrored.Rounded.HelpOutline,
                        label = "手势",
                        onClick = onOpenGestureGuide
                    )
                }
                item {
                    ToolbarPillButton(
                        icon = Icons.Rounded.UploadFile,
                        label = "传文件",
                        enabled = hasActiveWindow,
                        onClick = onPickFile
                    )
                }
                item {
                    ToolbarPillButton(
                        icon = Icons.Rounded.ContentPaste,
                        label = "推剪贴板",
                        onClick = onPushClipboard
                    )
                }
                item {
                    ToolbarPillButton(
                        icon = Icons.Rounded.AspectRatio,
                        label = "适配尺寸",
                        enabled = hasActiveWindow && !showAppLauncher,
                        onClick = onResizeToViewport
                    )
                }
                item {
                    ToolbarPillButton(
                        icon = Icons.Rounded.Refresh,
                        label = "刷新帧",
                        enabled = hasActiveWindow && !showAppLauncher,
                        onClick = onRefreshKeyframe
                    )
                }
                item {
                    ToolbarPillButton(
                        icon = Icons.Rounded.Close,
                        label = "关闭 ⌘W",
                        enabled = hasActiveWindow,
                        tint = MaterialTheme.colorScheme.error,
                        onClick = onCloseActiveWindow
                    )
                }
                item {
                    ToolbarPillButton(
                        icon = Icons.Rounded.BugReport,
                        label = "HUD",
                        active = showDebugHud,
                        onClick = onToggleDebugHud
                    )
                }
            }
        }
    }
}

@Composable
private fun ToolbarPillButton(
    icon: ImageVector,
    label: String,
    active: Boolean = false,
    enabled: Boolean = true,
    tint: Color? = null,
    onClick: () -> Unit
) {
    val bg = when {
        !enabled -> MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
        active -> MaterialTheme.colorScheme.primaryContainer
        else -> MaterialTheme.colorScheme.surfaceContainerHigh
    }
    val fg = when {
        !enabled -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.45f)
        tint != null -> tint
        active -> MaterialTheme.colorScheme.onPrimaryContainer
        else -> MaterialTheme.colorScheme.onSurface
    }
    Surface(
        onClick = onClick,
        enabled = enabled,
        color = bg,
        shape = RoundedCornerShape(10.dp),
        border = BorderStroke(
            width = 1.dp,
            color = if (active) MaterialTheme.colorScheme.primary.copy(alpha = 0.6f)
            else MaterialTheme.colorScheme.outlineVariant
        )
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 9.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Icon(icon, contentDescription = label, tint = fg, modifier = Modifier.size(15.dp))
            Text(
                text = label,
                style = MaterialTheme.typography.labelMedium,
                color = fg,
                maxLines = 1
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun WindowTopologyStrip(
    windows: List<WindowTopologyItem>,
    selectedWindowId: Int,
    onSelectWindow: (Int) -> Unit,
    onStopWindow: (Int) -> Unit
) {
    LazyRow(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceContainerLow)
            .padding(vertical = 4.dp),
        contentPadding = PaddingValues(horizontal = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        items(windows, key = { it.windowId }) { win ->
            val selected = win.windowId == selectedWindowId
            val displayTitle = when {
                win.windowId == OpenUUConstants.FULL_DESKTOP_WINDOW_ID -> "整台桌面"
                win.title.isNotBlank() -> win.title
                else -> "窗口 #${win.unsignedWindowId}"
            }
            FilterChip(
                selected = selected,
                onClick = { onSelectWindow(win.windowId) },
                label = {
                    Text(
                        text = displayTitle,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        style = MaterialTheme.typography.labelMedium
                    )
                },
                trailingIcon = {
                    Icon(
                        imageVector = Icons.Rounded.Close,
                        contentDescription = "停止窗口",
                        modifier = Modifier
                            .size(14.dp)
                            .clickable { onStopWindow(win.windowId) }
                    )
                },
                colors = FilterChipDefaults.filterChipColors(
                    selectedContainerColor = MaterialTheme.colorScheme.secondaryContainer,
                    selectedLabelColor = MaterialTheme.colorScheme.onSecondaryContainer,
                    selectedTrailingIconColor = MaterialTheme.colorScheme.onSecondaryContainer
                )
            )
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
        else apps.filter {
            it.name.lowercase().contains(q) || it.bundleId.lowercase().contains(q)
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 12.dp, vertical = 8.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            OutlinedTextField(
                value = searchQuery,
                onValueChange = { searchQuery = it },
                placeholder = { Text("搜索远程 Mac 应用...", style = MaterialTheme.typography.bodySmall) },
                leadingIcon = { Icon(Icons.Rounded.Search, contentDescription = null, modifier = Modifier.size(18.dp)) },
                trailingIcon = {
                    if (searchQuery.isNotEmpty()) {
                        IconButton(onClick = { searchQuery = "" }) {
                            Icon(Icons.Rounded.Close, contentDescription = "清除", modifier = Modifier.size(16.dp))
                        }
                    }
                },
                singleLine = true,
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.weight(1f),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedContainerColor = MaterialTheme.colorScheme.surfaceContainer,
                    unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainer
                )
            )
            FilledTonalIconButton(onClick = onRefreshApps) {
                Icon(Icons.Rounded.Refresh, contentDescription = "刷新应用列表")
            }
        }

        Spacer(modifier = Modifier.height(10.dp))

        LazyVerticalGrid(
            columns = GridCells.Adaptive(minSize = 104.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            contentPadding = PaddingValues(bottom = 16.dp),
            modifier = Modifier.fillMaxSize()
        ) {
            item(span = { GridItemSpan(maxLineSpan) }, key = OpenUUConstants.FULL_DESKTOP_BUNDLE_ID) {
                Card(
                    onClick = onOpenFullDesktop,
                    shape = RoundedCornerShape(16.dp),
                    border = BorderStroke(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.55f)),
                    colors = CardDefaults.cardColors(containerColor = Color.Transparent)
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(
                                Brush.horizontalGradient(
                                    listOf(
                                        Color(0xFF064E3B),
                                        Color(0xFF1E1B4B)
                                    )
                                )
                            )
                            .padding(16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(14.dp)
                    ) {
                        Box(
                            modifier = Modifier
                                .size(46.dp)
                                .clip(RoundedCornerShape(12.dp))
                                .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.2f)),
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.DesktopMac,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(28.dp)
                            )
                        }
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = "整台桌面",
                                style = MaterialTheme.typography.titleMedium,
                                color = Color.White
                            )
                            Text(
                                text = "镜像完整 macOS 显示器画面 · ${OpenUUConstants.FULL_DESKTOP_BUNDLE_ID}",
                                style = MaterialTheme.typography.bodySmall,
                                color = Color(0xFFA7F3D0),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    }
                }
            }

            if (filteredApps.isEmpty()) {
                item(span = { GridItemSpan(maxLineSpan) }) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 32.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = if (apps.isEmpty()) "正在获取 Mac 运行中的应用列表..." else "没有匹配的远程应用",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            } else {
                items(filteredApps, key = { "${it.bundleId}_${it.pid}" }) { app ->
                    RemoteAppCard(
                        app = app,
                        icon = appIcons[app.bundleId],
                        onClick = { onOpenApp(app) }
                    )
                }
            }
        }
    }
}

@Composable
private fun RemoteAppCard(
    app: RemoteAppSummary,
    icon: ImageBitmap?,
    onClick: () -> Unit
) {
    Card(
        onClick = onClick,
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            if (icon != null) {
                Image(
                    bitmap = icon,
                    contentDescription = app.name,
                    contentScale = ContentScale.Fit,
                    modifier = Modifier
                        .size(48.dp)
                        .clip(RoundedCornerShape(10.dp))
                )
            } else {
                Box(
                    modifier = Modifier
                        .size(48.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(MaterialTheme.colorScheme.secondaryContainer),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = app.name.firstOrNull()?.uppercase() ?: "A",
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onSecondaryContainer
                    )
                }
            }
            Text(
                text = app.name.ifBlank { app.bundleId },
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.Center
            )
            if (app.windowCount > 0) {
                Surface(
                    color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.6f),
                    shape = RoundedCornerShape(6.dp)
                ) {
                    Text(
                        text = "${app.windowCount} 窗口",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onPrimaryContainer,
                        modifier = Modifier.padding(horizontal = 6.dp, vertical = 1.dp)
                    )
                }
            }
        }
    }
}

@Composable
private fun RemoteVideoCanvas(
    viewModel: OpenUUViewModel,
    activeWindowId: Int,
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
        onDispose {
            viewModel.attachVideoSurface(null)
        }
    }

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .clipToBounds()
    ) {
        val containerW = constraints.maxWidth.toFloat().coerceAtLeast(1f)
        val containerH = constraints.maxHeight.toFloat().coerceAtLeast(1f)

        // Report logical viewport size for "Resize to Viewport"
        val logicalW = with(density) { (containerW / density.density) * 1.4f }.coerceIn(600f, 1600f)
        val logicalH = with(density) { (containerH / density.density) * 1.4f }.coerceIn(400f, 1200f)
        LaunchedEffect(logicalW, logicalH) {
            onViewportLogicalSizeChanged(Size(logicalW, logicalH))
        }

        // Compute base FIT rect preserving remote aspect ratio
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

        // FILL mode applies a cover scale via graphicsLayer so SurfaceView layout size never overflows
        val fillBaseScale = if (videoFitMode == VideoFitMode.FILL) {
            max(containerW / fittedW.coerceAtLeast(1f), containerH / fittedH.coerceAtLeast(1f))
        } else {
            1f
        }
        val effectiveScale = zoom * fillBaseScale

        // Keep latest values for long-lived pointerInput coroutine without restarting mid-gesture
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
            val effScale = targetZoom * currentFillScale
            val renderedW = rect.width * effScale
            val renderedH = rect.height * effScale
            val maxX = ((renderedW - cSize.width) / 2f).coerceAtLeast(0f)
            val maxY = ((renderedH - cSize.height) / 2f).coerceAtLeast(0f)
            return Offset(
                x = raw.x.coerceIn(-maxX, maxX),
                y = raw.y.coerceIn(-maxY, maxY)
            )
        }

        fun screenToNormalized(pt: Offset): Offset {
            val rect = currentBaseRect
            val effScale = currentZoom * currentFillScale
            val cx = rect.center.x
            val cy = rect.center.y
            val unscaledX = (pt.x - cx - currentPan.x) / effScale + cx
            val unscaledY = (pt.y - cy - currentPan.y) / effScale + cy
            val nx = ((unscaledX - rect.left) / rect.width.coerceAtLeast(1f)).coerceIn(0f, 1f)
            val ny = ((unscaledY - rect.top) / rect.height.coerceAtLeast(1f)).coerceIn(0f, 1f)
            return Offset(nx, ny)
        }

        fun autoPanForTrackpadCursor(nextCursor: Offset) {
            val z = currentZoom
            if (z <= 1.03f && currentFillScale <= 1.03f) return
            val rect = currentBaseRect
            val cSize = currentContainerSize
            val effScale = z * currentFillScale
            val cx = rect.center.x
            val cy = rect.center.y
            val rawX = rect.left + nextCursor.x * rect.width
            val rawY = rect.top + nextCursor.y * rect.height
            val screenX = (rawX - cx) * effScale + cx + currentPan.x
            val screenY = (rawY - cy) * effScale + cy + currentPan.y

            val marginX = min(cSize.width * 0.16f, edgeMarginPx)
            val marginY = min(cSize.height * 0.16f, edgeMarginPx)

            var dx = 0f
            var dy = 0f
            if (screenX < marginX) dx = marginX - screenX
            else if (screenX > cSize.width - marginX) dx = (cSize.width - marginX) - screenX

            if (screenY < marginY) dy = marginY - screenY
            else if (screenY > cSize.height - marginY) dy = (cSize.height - marginY) - screenY

            if (dx != 0f || dy != 0f) {
                val updatedPan = clampPanFor(currentPan + Offset(dx, dy), z)
                if (updatedPan != currentPan) {
                    onZoomPanLatest(z, updatedPan)
                }
            }
        }

        // Re-clamp pan automatically whenever container dimensions / fit mode / zoom change
        LaunchedEffect(containerW, containerH, videoFitMode, zoom) {
            val clamped = clampPanFor(pan, zoom)
            if (clamped != pan) {
                onZoomPanChanged(zoom, clamped)
            }
        }

        val fittedWDp = with(density) { fittedW.toDp() }
        val fittedHDp = with(density) { fittedH.toDp() }

        // Hardware SurfaceView fitted to video aspect ratio with zoom/fill/pan transform
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
                            override fun surfaceCreated(holder: SurfaceHolder) {
                                viewModel.attachVideoSurface(holder.surface)
                            }

                            override fun surfaceChanged(
                                holder: SurfaceHolder,
                                format: Int,
                                width: Int,
                                height: Int
                            ) {
                                viewModel.attachVideoSurface(holder.surface)
                            }

                            override fun surfaceDestroyed(holder: SurfaceHolder) {
                                viewModel.attachVideoSurface(null)
                            }
                        })
                    }
                }
            )
        }

        // Unified Professional Multi-Touch Gesture Overlay (Direct Touch + Trackpad)
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
                            val clampedZoom = newZoom.coerceIn(MIN_ZOOM, MAX_ZOOM)
                            val clampedPan = if (clampedZoom <= 1.01f && currentFillScale <= 1.01f) {
                                Offset.Zero
                            } else {
                                clampPanFor(newPan, clampedZoom)
                            }
                            onZoomPanLatest(clampedZoom, clampedPan)
                        },
                        onUpdateCursorAndAutoPan = { next ->
                            viewModel.updateCursorPos(next)
                            autoPanForTrackpadCursor(next)
                        },
                        onMove = { norm ->
                            viewModel.sendMouseNormalized(norm.x, norm.y, MOUSE_MOVE, BUTTON_LEFT, 0)
                        },
                        onLeftClick = { norm, clicks ->
                            viewModel.sendMouseNormalized(norm.x, norm.y, MOUSE_MOVE, BUTTON_LEFT, 0)
                            viewModel.sendMouseNormalized(norm.x, norm.y, MOUSE_DOWN, BUTTON_LEFT, clicks)
                            viewModel.sendMouseNormalized(norm.x, norm.y, MOUSE_UP, BUTTON_LEFT, clicks)
                        },
                        onRightClick = { norm ->
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            viewModel.sendMouseNormalized(norm.x, norm.y, MOUSE_MOVE, BUTTON_RIGHT, 0)
                            viewModel.sendMouseNormalized(norm.x, norm.y, MOUSE_DOWN, BUTTON_RIGHT, 1)
                            viewModel.sendMouseNormalized(norm.x, norm.y, MOUSE_UP, BUTTON_RIGHT, 1)
                            onTransientToastLatest("右键点击")
                        },
                        onDragStart = { norm ->
                            viewModel.sendMouseNormalized(norm.x, norm.y, MOUSE_MOVE, BUTTON_LEFT, 0)
                            viewModel.sendMouseNormalized(norm.x, norm.y, MOUSE_DOWN, BUTTON_LEFT, 1)
                        },
                        onDragMove = { norm ->
                            viewModel.sendMouseNormalized(norm.x, norm.y, MOUSE_DRAG, BUTTON_LEFT, 1)
                        },
                        onDragEnd = { norm ->
                            viewModel.sendMouseNormalized(norm.x, norm.y, MOUSE_UP, BUTTON_LEFT, 1)
                        },
                        onScroll = { norm, dx, dy ->
                            viewModel.sendScrollNormalized(norm.x, norm.y, dx, dy)
                        },
                        onThreeFingerTap = { onThreeFingerTapLatest() },
                        onThreeFingerVerticalSwipe = { isDown -> onThreeFingerSwipeLatest(isDown) },
                        onVisualStateChange = { gestureVisual = it },
                        onToast = { msg -> onTransientToastLatest(msg) }
                    )
                }
        )

        // Direct-Touch Long-Press / Drag Visual Ring Indicator
        if (touchMode == TouchMode.DIRECT_TOUCH && gestureVisual.directTouchRingPos != null) {
            val ringPos = gestureVisual.directTouchRingPos!!
            val ringColor = if (gestureVisual.isDragging) Color(0xFF10B981) else Color(0xFFF59E0B)
            Canvas(modifier = Modifier.fillMaxSize()) {
                val outerR = 24.dp.toPx()
                val innerR = 8.dp.toPx()
                drawCircle(
                    color = ringColor.copy(alpha = 0.22f),
                    radius = outerR,
                    center = ringPos
                )
                drawCircle(
                    color = ringColor,
                    radius = outerR,
                    center = ringPos,
                    style = Stroke(width = 2.5.dp.toPx())
                )
                drawCircle(
                    color = Color.White,
                    radius = innerR,
                    center = ringPos
                )
            }
        }

        // Virtual Mac Pointer Overlay in Trackpad Mode (with drag/long-press highlight ring)
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

        // Waiting for first frame indicator
        if (telemetry.decodedFrames == 0L) {
            Surface(
                color = Color.Black.copy(alpha = 0.65f),
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.align(Alignment.Center)
            ) {
                Text(
                    text = "正在等待 Mac 视频关键帧...",
                    style = MaterialTheme.typography.bodySmall,
                    color = Color.White,
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp)
                )
            }
        }

        // On-Screen Gesture Status / Toast Badge (e.g. "拖拽中...", "拖拽就绪", "右键点击")
        val badgeText = gestureVisual.persistentBadge ?: transientToast
        AnimatedVisibility(
            visible = badgeText != null,
            enter = fadeIn(tween(120)),
            exit = fadeOut(tween(200)),
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(bottom = 18.dp)
        ) {
            badgeText?.let { label ->
                val accentColor = when {
                    gestureVisual.isDragging -> Color(0xFF10B981)
                    gestureVisual.isLongPressArmed -> Color(0xFFF59E0B)
                    else -> Color(0xFF38BDF8)
                }
                Surface(
                    color = Color(0xD90B1120),
                    shape = RoundedCornerShape(999.dp),
                    border = BorderStroke(1.dp, accentColor.copy(alpha = 0.75f)),
                    shadowElevation = 6.dp
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Box(
                            modifier = Modifier
                                .size(7.dp)
                                .clip(CircleShape)
                                .background(accentColor)
                        )
                        Text(
                            text = label,
                            style = MaterialTheme.typography.labelSmall,
                            fontWeight = FontWeight.SemiBold,
                            color = Color(0xFFF8FAFC)
                        )
                    }
                }
            }
        }

        // Reset Zoom floating pill when zoomed in
        if (zoom > 1.02f) {
            Surface(
                onClick = {
                    onZoomPanChanged(1f, Offset.Zero)
                },
                color = MaterialTheme.colorScheme.secondaryContainer.copy(alpha = 0.9f),
                shape = RoundedCornerShape(16.dp),
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(12.dp)
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Icon(
                        imageVector = Icons.Rounded.ZoomOutMap,
                        contentDescription = "重置缩放",
                        tint = MaterialTheme.colorScheme.onSecondaryContainer,
                        modifier = Modifier.size(14.dp)
                    )
                    Text(
                        text = String.format(Locale.US, "%.1fx 重置", zoom),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSecondaryContainer
                    )
                }
            }
        }

        // Live Debug Telemetry HUD Overlay
        if (showDebugHud) {
            DebugTelemetryHud(
                telemetry = telemetry,
                linkBadge = linkBadge,
                touchMode = touchMode,
                videoFitMode = videoFitMode,
                zoom = zoom,
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .padding(10.dp)
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
    onVisualStateChange: (GestureVisualState) -> Unit,
    onToast: (String) -> Unit
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

    fun computeTrackpadNextCursor(delta: Offset): Offset {
        val rect = getBaseRect()
        val z = getZoom()
        val sensitivity = 1.35f / (1f + (z - 1f).coerceAtLeast(0f) * 0.45f)
        val cur = getCursor()
        val nx = (cur.x + (delta.x * sensitivity) / rect.width.coerceAtLeast(1f)).coerceIn(0f, 1f)
        val ny = (cur.y + (delta.y * sensitivity) / rect.height.coerceAtLeast(1f)).coerceIn(0f, 1f)
        return Offset(nx, ny)
    }

    awaitEachGesture {
        val firstDown = awaitFirstDown(requireUnconsumed = false)
        val downTimeMs = System.currentTimeMillis()
        val downPos = firstDown.position
        val firstPointerId: PointerId = firstDown.id

        val isDoubleTapCandidate = if (touchMode == TouchMode.DIRECT_TOUCH) {
            (downTimeMs - lastSingleTapTimeMs) <= doubleTapTimeoutMs &&
                hypot(
                    (downPos.x - lastSingleTapPos.x).toDouble(),
                    (downPos.y - lastSingleTapPos.y).toDouble()
                ).toFloat() <= doubleTapSlopPx
        } else {
            (downTimeMs - lastSingleTapTimeMs) <= doubleTapTimeoutMs
        }

        var mode = GestureSubMode.PENDING_SINGLE
        var longPressArmed = false
        var rightClickArmed = false
        var lastSinglePos = downPos
        var currentDragNorm = if (touchMode == TouchMode.DIRECT_TOUCH) {
            screenToNormalized(downPos)
        } else {
            getCursor()
        }

        // 2-finger state
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

        // 3-finger state
        var threeFingerStartTimeMs = 0L
        var threeFingerTotalDeltaY = 0f
        var threeFingerTotalMove = 0f
        var threeFingerSwipeTriggered = false

        fun clearVisual() {
            onVisualStateChange(GestureVisualState())
        }

        try {
            while (true) {
                // Proactive timeout right at 300ms (arm drag) and 420ms (arm right-click)
                // while finger is STILL held stationary!
                val event = if (mode == GestureSubMode.PENDING_SINGLE && !rightClickArmed) {
                    val now = System.currentTimeMillis()
                    val targetMs = if (!longPressArmed) longPressArmMs else longPressRightClickMs
                    val remaining = (targetMs - (now - downTimeMs)).coerceAtLeast(1L)
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

                // ---------- ALL FINGERS LIFTED ----------
                if (pressed.isEmpty()) {
                    when (mode) {
                        GestureSubMode.REMOTE_DRAG -> {
                            onDragEnd(currentDragNorm)
                            lastSingleTapTimeMs = 0L
                        }
                        GestureSubMode.PENDING_SINGLE -> {
                            val heldMs = now - downTimeMs
                            val anchor = if (touchMode == TouchMode.DIRECT_TOUCH) {
                                screenToNormalized(lastSinglePos)
                            } else {
                                getCursor()
                            }
                            if (heldMs >= longPressRightClickMs) {
                                onRightClick(anchor)
                                lastSingleTapTimeMs = 0L
                            } else if (isDoubleTapCandidate) {
                                onLeftClick(anchor, 2)
                                lastSingleTapTimeMs = 0L
                            } else {
                                onLeftClick(anchor, 1)
                                lastSingleTapTimeMs = now
                                lastSingleTapPos = lastSinglePos
                            }
                        }
                        GestureSubMode.TWO_FINGER_PENDING -> {
                            val elapsed = now - twoFingerStartTimeMs
                            if (!secondFingerRightClickFired &&
                                elapsed <= twoFingerTapMaxMs &&
                                twoFingerTotalCentroidMove <= twoFingerTapMaxMovePx
                            ) {
                                val anchor = if (touchMode == TouchMode.DIRECT_TOUCH) {
                                    screenToNormalized(twoFingerStartCentroid)
                                } else {
                                    getCursor()
                                }
                                onRightClick(anchor)
                            }
                        }
                        GestureSubMode.THREE_FINGER -> {
                            val elapsed = now - threeFingerStartTimeMs
                            if (!threeFingerSwipeTriggered &&
                                elapsed <= threeFingerTapMaxMs &&
                                threeFingerTotalMove <= touchSlop * 2.4f
                            ) {
                                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                onThreeFingerTap()
                            }
                        }
                        else -> Unit
                    }
                    clearVisual()
                    break
                }

                // ---------- 3+ FINGERS ACTIVE ----------
                if (pressed.size >= 3) {
                    if (mode == GestureSubMode.REMOTE_DRAG) {
                        onDragEnd(currentDragNorm)
                    }
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

                // Never downgrade out of THREE_FINGER while fingers are still lifting sequentially
                if (mode == GestureSubMode.THREE_FINGER) {
                    event.changes.forEach { if (it.positionChanged()) it.consume() }
                    continue
                }

                // ---------- 2 FINGERS ACTIVE ----------
                if (pressed.size == 2) {
                    if (mode == GestureSubMode.REMOTE_DRAG) {
                        onDragEnd(currentDragNorm)
                    }
                    val p0 = pressed[0].position
                    val p1 = pressed[1].position
                    val span = hypot((p1.x - p0.x).toDouble(), (p1.y - p0.y).toDouble()).toFloat()
                    val centroid = Offset((p0.x + p1.x) / 2f, (p0.y + p1.y) / 2f)

                    if (!twoFingerEntered ||
                        (mode != GestureSubMode.TWO_FINGER_PENDING &&
                            mode != GestureSubMode.TWO_FINGER_PINCH &&
                            mode != GestureSubMode.TWO_FINGER_SCROLL)
                    ) {
                        twoFingerEntered = true
                        mode = GestureSubMode.TWO_FINGER_PENDING
                        initialSpan = span
                        twoFingerStartTimeMs = now
                        twoFingerStartCentroid = centroid
                        twoFingerTotalCentroidMove = 0f
                        secondFingerRightClickFired = false
                        val secondPtr = pressed.firstOrNull { it.id != firstPointerId } ?: pressed[1]
                        secondFingerId = secondPtr.id
                        secondFingerDownTimeMs = now
                        secondFingerDownPos = secondPtr.position
                        secondFingerMaxDisp = 0f
                        clearVisual()
                        event.changes.forEach { if (it.positionChanged()) it.consume() }
                        continue
                    }

                    // Track 2nd finger displacement for "Hold 1st + Tap 2nd = Right Click"
                    val secPtr = pressed.firstOrNull { it.id == secondFingerId }
                    if (secPtr != null) {
                        val disp = hypot(
                            (secPtr.position.x - secondFingerDownPos.x).toDouble(),
                            (secPtr.position.y - secondFingerDownPos.y).toDouble()
                        ).toFloat()
                        if (disp > secondFingerMaxDisp) secondFingerMaxDisp = disp
                    }

                    val zoomChange = event.calculateZoom()
                    val panChange = event.calculatePan()
                    twoFingerTotalCentroidMove += hypot(panChange.x.toDouble(), panChange.y.toDouble()).toFloat()
                    val spanDelta = abs(span - initialSpan)

                    if (mode == GestureSubMode.TWO_FINGER_PENDING) {
                        if (spanDelta > pinchLockThresholdPx) {
                            mode = GestureSubMode.TWO_FINGER_PINCH
                        } else if (twoFingerTotalCentroidMove > touchSlop * 1.15f) {
                            mode = GestureSubMode.TWO_FINGER_SCROLL
                        }
                    }

                    when (mode) {
                        GestureSubMode.TWO_FINGER_PINCH -> {
                            val curZoom = getZoom()
                            val nextZoom = (curZoom * zoomChange).coerceIn(MIN_ZOOM, MAX_ZOOM)
                            val scaleRatio = if (curZoom > 0f) nextZoom / curZoom else 1f
                            val rectCenter = getBaseRect().center
                            val centroidRel = centroid - rectCenter
                            val nextPan = (getPan() - centroidRel) * scaleRatio + centroidRel + panChange
                            onUpdateZoomPan(nextZoom, nextPan)
                            onVisualStateChange(
                                GestureVisualState(
                                    persistentBadge = String.format(Locale.US, "缩放 %.1fx", nextZoom)
                                )
                            )
                        }
                        GestureSubMode.TWO_FINGER_SCROLL -> {
                            if (panChange != Offset.Zero) {
                                val scrollAnchor = if (touchMode == TouchMode.DIRECT_TOUCH) {
                                    screenToNormalized(centroid)
                                } else {
                                    getCursor()
                                }
                                onScroll(scrollAnchor, panChange.x * 0.75f, panChange.y * 0.75f)
                            }
                        }
                        else -> Unit
                    }

                    event.changes.forEach { if (it.positionChanged()) it.consume() }
                    continue
                }

                // ---------- 1 FINGER ACTIVE ----------
                val change = pressed.first()

                // Transition from 2 fingers -> 1 finger:
                // Support Moonlight-style "Hold 1st finger + Tap 2nd finger = Right Click"
                if (mode == GestureSubMode.TWO_FINGER_PENDING) {
                    if (change.id == firstPointerId && !secondFingerRightClickFired) {
                        val secHeldMs = now - secondFingerDownTimeMs
                        if (secHeldMs <= twoFingerTapMaxMs && secondFingerMaxDisp <= twoFingerTapMaxMovePx) {
                            val anchor = if (touchMode == TouchMode.DIRECT_TOUCH) {
                                screenToNormalized(change.position)
                            } else {
                                getCursor()
                            }
                            onRightClick(anchor)
                            secondFingerRightClickFired = true
                            mode = GestureSubMode.CONSUMED_WAIT_UP
                            clearVisual()
                        }
                    }
                    // If 1st finger lifted first (2nd remains), keep TWO_FINGER_PENDING so lift of 2nd triggers 2-finger tap!
                    lastSinglePos = change.position
                    if (change.positionChanged()) change.consume()
                    continue
                }

                if (mode == GestureSubMode.TWO_FINGER_PINCH ||
                    mode == GestureSubMode.TWO_FINGER_SCROLL ||
                    mode == GestureSubMode.CONSUMED_WAIT_UP
                ) {
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
                        val distFromDown = hypot(
                            (curPos.x - downPos.x).toDouble(),
                            (curPos.y - downPos.y).toDouble()
                        ).toFloat()

                        if (distFromDown > touchSlop) {
                            val shouldStartRemoteDrag = longPressArmed ||
                                isDoubleTapCandidate ||
                                (touchMode == TouchMode.DIRECT_TOUCH && getZoom() <= 1.03f)

                            if (shouldStartRemoteDrag) {
                                mode = GestureSubMode.REMOTE_DRAG
                                if (!longPressArmed) {
                                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                }
                                if (touchMode == TouchMode.DIRECT_TOUCH) {
                                    val startNorm = screenToNormalized(downPos)
                                    val moveNorm = screenToNormalized(curPos)
                                    currentDragNorm = moveNorm
                                    onDragStart(startNorm)
                                    onDragMove(moveNorm)
                                    onVisualStateChange(
                                        GestureVisualState(
                                            persistentBadge = "拖拽中...",
                                            isDragging = true,
                                            directTouchRingPos = curPos
                                        )
                                    )
                                } else {
                                    val startCursor = getCursor()
                                    val nextCursor = computeTrackpadNextCursor(curPos - downPos)
                                    currentDragNorm = nextCursor
                                    onDragStart(startCursor)
                                    onUpdateCursorAndAutoPan(nextCursor)
                                    onDragMove(nextCursor)
                                    onVisualStateChange(
                                        GestureVisualState(
                                            persistentBadge = "拖拽中...",
                                            isDragging = true
                                        )
                                    )
                                }
                            } else if (touchMode == TouchMode.DIRECT_TOUCH) {
                                // Direct Touch zoomed > 1.03f without long-press/double-tap: pan zoomed viewport!
                                mode = GestureSubMode.VIEWPORT_PAN
                                clearVisual()
                                onUpdateZoomPan(getZoom(), getPan() + (curPos - downPos))
                            } else {
                                // Trackpad normal 1-finger move
                                mode = GestureSubMode.TRACKPAD_MOVE
                                clearVisual()
                                val nextCursor = computeTrackpadNextCursor(curPos - downPos)
                                onUpdateCursorAndAutoPan(nextCursor)
                                onMove(nextCursor)
                            }
                            change.consume()
                        }
                    }

                    GestureSubMode.REMOTE_DRAG -> {
                        if (delta != Offset.Zero) {
                            if (touchMode == TouchMode.DIRECT_TOUCH) {
                                val nextNorm = screenToNormalized(curPos)
                                currentDragNorm = nextNorm
                                onDragMove(nextNorm)
                                onVisualStateChange(
                                    GestureVisualState(
                                        persistentBadge = "拖拽中...",
                                        isDragging = true,
                                        directTouchRingPos = curPos
                                    )
                                )
                            } else {
                                val nextCursor = computeTrackpadNextCursor(delta)
                                currentDragNorm = nextCursor
                                onUpdateCursorAndAutoPan(nextCursor)
                                onDragMove(nextCursor)
                            }
                            change.consume()
                        }
                    }

                    GestureSubMode.VIEWPORT_PAN -> {
                        if (delta != Offset.Zero) {
                            onUpdateZoomPan(getZoom(), getPan() + delta)
                            change.consume()
                        }
                    }

                    GestureSubMode.TRACKPAD_MOVE -> {
                        if (delta != Offset.Zero) {
                            val nextCursor = computeTrackpadNextCursor(delta)
                            onUpdateCursorAndAutoPan(nextCursor)
                            onMove(nextCursor)
                            change.consume()
                        }
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
        val rawX = videoRect.left + cursorPos.x * videoRect.width
        val rawY = videoRect.top + cursorPos.y * videoRect.height
        val cx = videoRect.center.x
        val cy = videoRect.center.y
        val x = (rawX - cx) * effectiveScale + cx + pan.x
        val y = (rawY - cy) * effectiveScale + cy + pan.y

        if (isDragging || isLongPressArmed) {
            val haloColor = if (isDragging) Color(0xFF10B981) else Color(0xFFF59E0B)
            val haloR = 16.dp.toPx()
            drawCircle(
                color = haloColor.copy(alpha = 0.26f),
                radius = haloR,
                center = Offset(x, y)
            )
            drawCircle(
                color = haloColor,
                radius = haloR,
                center = Offset(x, y),
                style = Stroke(width = 2.dp.toPx())
            )
        }

        when (cursorKind.lowercase()) {
            "ibeam", "text" -> {
                val h = 18.dp.toPx()
                val serif = 4.dp.toPx()
                drawLine(Color.White, Offset(x, y - h / 2f), Offset(x, y + h / 2f), strokeWidth = 4.5f, cap = StrokeCap.Round)
                drawLine(Color.Black, Offset(x, y - h / 2f), Offset(x, y + h / 2f), strokeWidth = 2.2f, cap = StrokeCap.Round)
                drawLine(Color.White, Offset(x - serif, y - h / 2f), Offset(x + serif, y - h / 2f), strokeWidth = 4f)
                drawLine(Color.Black, Offset(x - serif, y - h / 2f), Offset(x + serif, y - h / 2f), strokeWidth = 2f)
                drawLine(Color.White, Offset(x - serif, y + h / 2f), Offset(x + serif, y + h / 2f), strokeWidth = 4f)
                drawLine(Color.Black, Offset(x - serif, y + h / 2f), Offset(x + serif, y + h / 2f), strokeWidth = 2f)
            }
            "pointing_hand", "hand", "pointer" -> {
                val r = 6.dp.toPx()
                drawCircle(Color(0xFF10B981).copy(alpha = 0.35f), radius = r * 1.9f, center = Offset(x, y))
                drawCircle(Color.White, radius = r, center = Offset(x, y))
                drawCircle(Color(0xFF10B981), radius = r * 0.65f, center = Offset(x, y))
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
                drawPath(path = path, color = Color.Black)
                drawPath(
                    path = path,
                    color = Color.White,
                    style = Stroke(width = 2.2f, join = StrokeJoin.Round)
                )
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
        color = Color(0xCC090D16),
        shape = RoundedCornerShape(10.dp),
        border = BorderStroke(1.dp, Color(0xFF10B981).copy(alpha = 0.45f)),
        modifier = modifier
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 7.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp)
        ) {
            Text(
                text = "${telemetry.codec}  ${telemetry.width}×${telemetry.height}  ${telemetry.fps} FPS",
                color = Color(0xFF34D399),
                fontFamily = FontFamily.Monospace,
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold
            )
            Text(
                text = String.format(
                    Locale.US,
                    "%.2f Mbps · Frames: %d · %s/%s",
                    telemetry.bitrateMbps,
                    telemetry.decodedFrames,
                    touchMode.label,
                    videoFitMode.label
                ),
                color = Color(0xFFE2E8F0),
                fontFamily = FontFamily.Monospace,
                fontSize = 10.sp
            )
            Text(
                text = buildString {
                    append(linkBadge.ifBlank { "Link: -" })
                    if (zoom > 1.01f) {
                        append(String.format(Locale.US, " · Zoom %.1fx", zoom))
                    }
                },
                color = Color(0xFF94A3B8),
                fontFamily = FontFamily.Monospace,
                fontSize = 10.sp
            )
        }
    }
}

private data class MacShortcutKey(
    val label: String,
    val keyCode: Int,
    val explicitModifiers: Int? = null
)

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
    Surface(
        color = MaterialTheme.colorScheme.surface,
        tonalElevation = 4.dp,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 10.dp, vertical = 8.dp),
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
                    placeholder = {
                        Text(
                            text = "输入中英文，点击发送直达 Mac...",
                            style = MaterialTheme.typography.bodySmall
                        )
                    },
                    singleLine = true,
                    shape = RoundedCornerShape(12.dp),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                    keyboardActions = KeyboardActions(onSend = { onCommitImeText() }),
                    modifier = Modifier.weight(1f),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedContainerColor = MaterialTheme.colorScheme.surfaceContainer,
                        unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainer
                    )
                )
                Button(
                    onClick = onCommitImeText,
                    enabled = imeText.isNotEmpty(),
                    shape = RoundedCornerShape(12.dp),
                    contentPadding = PaddingValues(horizontal = 14.dp, vertical = 12.dp)
                ) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Rounded.Send,
                        contentDescription = "发送文本",
                        modifier = Modifier.size(18.dp)
                    )
                }
            }

            LazyRow(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                val modItems = listOf(
                    "⌘" to MacModifiers.COMMAND,
                    "⌥" to MacModifiers.OPTION,
                    "⌃" to MacModifiers.CONTROL,
                    "⇧" to MacModifiers.SHIFT
                )
                items(modItems, key = { it.second }) { (symbol, bit) ->
                    val active = (stickyModifiers and bit) != 0
                    KeyCapChip(
                        label = symbol,
                        active = active,
                        onClick = { onToggleModifier(bit) }
                    )
                }
                items(MacShortcutKeys, key = { it.label }) { item ->
                    KeyCapChip(
                        label = item.label,
                        active = false,
                        accent = item.explicitModifiers != null,
                        onClick = { onSendKeyTap(item.keyCode, item.explicitModifiers) }
                    )
                }
            }
        }
    }
}

@Composable
private fun KeyCapChip(
    label: String,
    active: Boolean,
    accent: Boolean = false,
    onClick: () -> Unit
) {
    val bg = when {
        active -> MaterialTheme.colorScheme.primary
        accent -> MaterialTheme.colorScheme.secondaryContainer
        else -> MaterialTheme.colorScheme.surfaceContainerHigh
    }
    val fg = when {
        active -> MaterialTheme.colorScheme.onPrimary
        accent -> MaterialTheme.colorScheme.onSecondaryContainer
        else -> MaterialTheme.colorScheme.onSurface
    }
    Surface(
        onClick = onClick,
        color = bg,
        shape = RoundedCornerShape(8.dp),
        border = BorderStroke(
            1.dp,
            if (active) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline
        )
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.SemiBold,
            color = fg,
            modifier = Modifier.padding(horizontal = 11.dp, vertical = 7.dp)
        )
    }
}
